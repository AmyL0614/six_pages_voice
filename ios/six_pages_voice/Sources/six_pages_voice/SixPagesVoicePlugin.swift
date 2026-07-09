import Flutter
import UIKit
import AVFoundation
import AudioToolbox
import os.log

// ─────────────────────────────────────────────────────────────────────────────
// SixPagesVoicePlugin — iOS
//
// STEP B, LAYER 6 (BUILD 2): 48 kHz ADAPTIVE PLAYBACK (fixes the chop).
//
// CONFIRMED by Build 1 on-device diagnostics (iPad):
//   granted=48000Hz [MISMATCH]; ioBuf=0.0233s;
//   input-bus client=16000Hz/1ch; output-bus client=16000Hz/1ch;
//   renderCalls=7905; underruns=7689 (97% UNDERRUN); lastReqBytes=736; lastInputFrames=368
//
// Root cause (now certain, not hypothesis): hardware runs 48 kHz. We fed Joe at
// 16 kHz but the render callback consumes at the 48 kHz hardware clock → buffer
// drains ~3× faster than it fills → 97% underrun → even chop, slightly fast.
//
// FIX (this build): make PLAYBACK coherent at the real hardware rate.
//   1. Read granted rate (already have it). Call it hwRate (48000 here).
//   2. Set the OUTPUT bus (playback) client format to hwRate, so the render
//      callback's frame math matches the clock it's actually driven by.
//   3. Joe still arrives from ElevenLabs at 16 kHz. Upsample his bytes 16k→hwRate
//      with an AVAudioConverter in feedPlayback BEFORE they enter the playback
//      ring. Now feed-rate == consume-rate → ring stops starving → chop gone.
//
// CAPTURE is intentionally LEFT ALONE this build. The transcript proved capture
// is already clean at the current settings (AEC works, user turns intact). We
// change ONLY the thing the diagnostics proved broken — playback. If, after this,
// the transcript ever shows a capture-rate problem, that is a separate, later,
// diagnostics-first build. Do not pre-emptively touch capture.
//
// Build 1 diagnostics are RETAINED (getDiagnostics still works) so we can verify
// underruns drop toward 0 on the next device test — prove the fix, don't assume.
// ─────────────────────────────────────────────────────────────────────────────
//
// Frame contract mirrors Android exactly: PCM16 / 16 kHz / mono, 640-byte
// (20 ms) frames, one frame pushed per hop to the platform thread — the iOS
// equivalent of Android's `mainHandler.post { eventSink.success(frame) }`.
//
// Deliberately ABSENT vs Android: no nativeProcessCapture, no stream-delay
// measurement, no playback-clock reads. Android needs those because WebRTC
// AEC3 must be told the render→capture delay. iOS's VoiceProcessingIO cancels
// inside the OS, so the pulled frames are already clean. This simplicity is
// the whole reason Path 1 (VoiceProcessingIO) was chosen (July 7 lock).
//
//   • start        → Layer 2 + installs the input callback; starts drain.
//   • feedPlayback → writes Joe's bytes into the playback ring buffer (Layer 2).
//   • capture      → emits clean 640-byte PCM16 frames (THIS layer).
//   • stop         → tears down unit, stops drain, clears both ring buffers.
//
// July 7 risk 3: AECAudioStream's input callback returns kAudio_ParamError even
// on success. We return noErr correctly on the success path.
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - ByteRingBuffer
//
// Lock-guarded single-producer/single-consumer byte ring. Used for BOTH the
// playback path (Dart writes, render reads) and the capture path (input
// callback writes, drain reads). Tiny critical sections (memcpy of ≤ a frame).
private final class ByteRingBuffer {
  private var storage: [UInt8]
  private let capacity: Int
  private var readIndex = 0
  private var writeIndex = 0
  private var filled = 0
  private let lock = NSLock()

  init(capacityBytes: Int) {
    self.capacity = capacityBytes
    self.storage = [UInt8](repeating: 0, count: capacityBytes)
  }

  var count: Int {
    lock.lock(); defer { lock.unlock() }
    return filled
  }

  /// Producer: append bytes. On overflow, drop OLDEST (advance read) so the
  /// freshest audio wins.
  func write(_ bytes: UnsafeRawBufferPointer) {
    lock.lock(); defer { lock.unlock() }
    let n = bytes.count
    guard n > 0 else { return }
    let start = n > capacity ? n - capacity : 0
    let toCopy = n - start
    for i in 0..<toCopy {
      storage[writeIndex] = bytes[start + i]
      writeIndex = (writeIndex + 1) % capacity
      if filled < capacity { filled += 1 }
      else { readIndex = (readIndex + 1) % capacity }
    }
  }

  /// Producer variant writing from a raw pointer + length (used by the input
  /// callback, which holds an AudioBuffer's mData/mDataByteSize).
  func write(from ptr: UnsafeRawPointer, count n: Int) {
    lock.lock(); defer { lock.unlock() }
    guard n > 0 else { return }
    let src = ptr.assumingMemoryBound(to: UInt8.self)
    let start = n > capacity ? n - capacity : 0
    for i in start..<n {
      storage[writeIndex] = src[i]
      writeIndex = (writeIndex + 1) % capacity
      if filled < capacity { filled += 1 }
      else { readIndex = (readIndex + 1) % capacity }
    }
  }

  /// Consumer: pull up to `count` bytes into `dest`. Returns bytes provided.
  func read(into dest: UnsafeMutableRawPointer, count: Int) -> Int {
    lock.lock(); defer { lock.unlock() }
    let available = min(count, filled)
    let d = dest.assumingMemoryBound(to: UInt8.self)
    for i in 0..<available {
      d[i] = storage[readIndex]
      readIndex = (readIndex + 1) % capacity
      filled -= 1
    }
    return available
  }

  /// Consumer variant: pull exactly `n` bytes as a Data if available, else nil.
  /// Used by the capture drain to emit whole 640-byte frames only.
  func readFrame(_ n: Int) -> Data? {
    lock.lock(); defer { lock.unlock() }
    guard filled >= n else { return nil }
    var out = Data(count: n)
    out.withUnsafeMutableBytes { raw in
      let d = raw.bindMemory(to: UInt8.self)
      for i in 0..<n {
        d[i] = storage[readIndex]
        readIndex = (readIndex + 1) % capacity
        filled -= 1
      }
    }
    return out
  }

  func clear() {
    lock.lock(); defer { lock.unlock() }
    readIndex = 0; writeIndex = 0; filled = 0
  }
}

public class SixPagesVoicePlugin: NSObject, FlutterPlugin {

  private static let log = OSLog(subsystem: "com.sixpages.six_pages_voice", category: "SixPagesVoice")

  private var ioUnit: AudioUnit?
  private var isRunning = false

  private static let targetSampleRate: Double = 16000.0

  // Frame contract (mirrors Android): 640 bytes = 20 ms of 16 kHz mono PCM16.
  private static let frameBytes = 640

  // Playback ring: ~500 ms headroom. Sized for the WORST case (48 kHz mono
  // PCM16 = 48000 B/s → 24000 B for 500 ms). Build 2 feeds upsampled audio, so
  // the ring must hold hwRate-rate bytes, not 16 kHz bytes. Oversized-but-safe.
  private static let playbackBufferBytes = 48000
  private let playback = ByteRingBuffer(capacityBytes: playbackBufferBytes)

  // Capture ring: ~500 ms of clean mic audio waiting to drain up to Dart.
  private static let captureBufferBytes = 16000
  private let capture = ByteRingBuffer(capacityBytes: captureBufferBytes)

  // Scratch AudioBufferList the input callback renders mic frames into.
  private var captureScratch: UnsafeMutablePointer<Int16>?
  private var captureScratchFrameCap = 0

  // Drain: pushes whole 640-byte frames up on the platform thread.
  private var drainTimer: DispatchSourceTimer?

  private var captureSink: FlutterEventSink?

  // Build 1 diagnostics: startUnit() fills this with the actual granted rate and
  // negotiated formats so the app can read it via getDiagnostics (we have no
  // Mac/Console). Plain string, human-readable.
  private var lastDiagnostics: String = "no session started yet"

  // Build 1: the render callback (audio thread) updates these so getDiagnostics
  // can report REAL underrun behavior — the direct measure of the chop. If
  // underrunFrames is high relative to renderCalls, the buffer is starving.
  // Plain Ints updated on one thread and read on another; acceptable for a
  // coarse diagnostic (not a correctness-critical value).
  fileprivate var renderCalls: Int = 0
  fileprivate var underrunEvents: Int = 0
  fileprivate var lastRenderBytesRequested: Int = 0
  fileprivate var lastInputFrames: Int = 0

  // Build 2: actual hardware sample rate read at start (e.g. 48000). The output
  // (playback) bus is formatted to this; Joe's 16 kHz feed is upsampled to it.
  private var hwRate: Double = SixPagesVoicePlugin.targetSampleRate
  // Build 2: converter that resamples Joe 16 kHz mono PCM16 → hwRate mono PCM16.
  // nil when hwRate == 16000 (no conversion needed — best case).
  private var feedConverter: AVAudioConverter?
  private var feedInFormat: AVAudioFormat?
  private var feedOutFormat: AVAudioFormat?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let messenger = registrar.messenger()
    let controlChannel = FlutterMethodChannel(
      name: "six_pages_voice/control", binaryMessenger: messenger)
    let captureChannel = FlutterEventChannel(
      name: "six_pages_voice/capture", binaryMessenger: messenger)
    let instance = SixPagesVoicePlugin()
    registrar.addMethodCallDelegate(instance, channel: controlChannel)
    captureChannel.setStreamHandler(instance)
    os_log("register: control + capture channels registered", log: log, type: .info)
  }

  // MARK: - MethodChannel (control)

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      do {
        try startUnit()
        os_log("start: unit running (render + input installed)",
               log: SixPagesVoicePlugin.log, type: .info)
        result(true)
      } catch {
        os_log("start: FAILED — %{public}@", log: SixPagesVoicePlugin.log, type: .error,
               String(describing: error))
        stopUnit()
        result(false)
      }
    case "stop":
      stopUnit()
      os_log("stop: unit torn down", log: SixPagesVoicePlugin.log, type: .info)
      result(nil)
    case "getDiagnostics":
      // Build 1: return granted rate + negotiated formats + LIVE render/underrun
      // counts. Underrun ratio is the direct measure of the chop: if
      // underrunEvents is a large fraction of renderCalls, the buffer starves.
      // lastRenderBytesRequested vs lastInputFrames reveals rate/frame shape.
      let live = "renderCalls=\(renderCalls); underruns=\(underrunEvents); "
        + "lastReqBytes=\(lastRenderBytesRequested); lastInputFrames=\(lastInputFrames)"
      result(lastDiagnostics + live)

    case "feedPlayback":
      if let typed = call.arguments as? FlutterStandardTypedData {
        // Build 2: if hardware != 16 kHz, upsample Joe 16k→hwRate before the ring
        // so feed-rate matches the render callback's consume-rate. If no converter
        // (hwRate == 16k), write straight through as before.
        if feedConverter != nil {
          let upsampled = convertFeed(typed.data)
          upsampled.withUnsafeBytes { raw in playback.write(raw) }
        } else {
          typed.data.withUnsafeBytes { raw in playback.write(raw) }
        }
        result(nil)
      } else {
        result(FlutterError(code: "BAD_ARG",
                            message: "feedPlayback expected raw bytes (FlutterStandardTypedData)",
                            details: nil))
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Audio unit lifecycle

  private enum AudioError: Error {
    case session(String)
    case osStatus(String, OSStatus)
    case noComponent
  }

  private func startUnit() throws {
    if isRunning { return }

    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playAndRecord, mode: .voiceChat,
                              options: [.defaultToSpeaker, .allowBluetooth])
      try session.setPreferredSampleRate(SixPagesVoicePlugin.targetSampleRate)
      try session.setActive(true)
    } catch {
      throw AudioError.session(error.localizedDescription)
    }

    // ── Layer 4 instrumentation: what rate did the hardware ACTUALLY grant? ───
    // This is the risk-1 verdict. If actualRate == 16000, our clean path is
    // correct and NO converter is needed. If it differs, the frames the unit
    // handles are NOT 16 kHz and a targeted converter is required — but we do
    // not write that until a real device logs the mismatch here.
    let grantedRate = session.sampleRate
    let ioBufDuration = session.ioBufferDuration
    if abs(grantedRate - SixPagesVoicePlugin.targetSampleRate) < 1.0 {
      os_log("SR-CHECK: session granted %{public}.0f Hz — MATCHES 16 kHz. Clean path valid, no converter needed.",
             log: SixPagesVoicePlugin.log, type: .info, grantedRate)
    } else {
      os_log("SR-CHECK: session granted %{public}.0f Hz — DOES NOT MATCH 16 kHz. Converter WILL be required (risk 1 confirmed on this device).",
             log: SixPagesVoicePlugin.log, type: .error, grantedRate)
    }
    os_log("SR-CHECK: ioBufferDuration = %{public}.4f s", log: SixPagesVoicePlugin.log,
           type: .info, ioBufDuration)

    // Build 1: begin building the app-readable diagnostic string.
    let rateVerdict = abs(grantedRate - SixPagesVoicePlugin.targetSampleRate) < 1.0
      ? "MATCHES 16k" : "MISMATCH (converter needed)"
    lastDiagnostics = "granted=\(Int(grantedRate))Hz [\(rateVerdict)]; "
      + "ioBuf=\(String(format: "%.4f", ioBufDuration))s; "

    // ── Build 2: adopt the real hardware rate for the playback path ───────────
    // The render callback is driven by the hardware clock (grantedRate). We make
    // the output-bus client format match it, and upsample Joe's 16 kHz feed to it.
    hwRate = grantedRate
    if abs(hwRate - SixPagesVoicePlugin.targetSampleRate) < 1.0 {
      // Hardware honored 16 kHz — no conversion needed.
      feedConverter = nil
      feedInFormat = nil
      feedOutFormat = nil
    } else {
      // Build the Joe 16 kHz → hwRate converter (mono, Int16, interleaved).
      let inFmt = AVAudioFormat(commonFormat: .pcmFormatInt16,
                               sampleRate: SixPagesVoicePlugin.targetSampleRate,
                               channels: 1, interleaved: true)
      let outFmt = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                sampleRate: hwRate,
                                channels: 1, interleaved: true)
      if let inFmt = inFmt, let outFmt = outFmt,
         let conv = AVAudioConverter(from: inFmt, to: outFmt) {
        feedInFormat = inFmt
        feedOutFormat = outFmt
        feedConverter = conv
        lastDiagnostics += "feedConv=16k→\(Int(hwRate))k; "
      } else {
        os_log("Build2: FAILED to build feed converter 16k→%{public}.0f", 
               log: SixPagesVoicePlugin.log, type: .error, hwRate)
        lastDiagnostics += "feedConv=BUILD_FAILED; "
        feedConverter = nil
      }
    }

    var desc = AudioComponentDescription(
      componentType: kAudioUnitType_Output,
      componentSubType: kAudioUnitSubType_VoiceProcessingIO,
      componentManufacturer: kAudioUnitManufacturer_Apple,
      componentFlags: 0, componentFlagsMask: 0)
    guard let comp = AudioComponentFindNext(nil, &desc) else { throw AudioError.noComponent }

    var unitOptional: AudioUnit?
    try checkStatus("AudioComponentInstanceNew", AudioComponentInstanceNew(comp, &unitOptional))
    guard let unit = unitOptional else { throw AudioError.noComponent }
    self.ioUnit = unit

    let inputBus: AudioUnitElement = 1
    let outputBus: AudioUnitElement = 0

    var enableFlag: UInt32 = 1
    try checkStatus("enable input",
      AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input,
                           inputBus, &enableFlag, UInt32(MemoryLayout<UInt32>.size)))
    try checkStatus("enable output",
      AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output,
                           outputBus, &enableFlag, UInt32(MemoryLayout<UInt32>.size)))

    // Input bus (mic → app): keep 16 kHz. Capture is proven clean; leave it.
    var inFormat = AudioStreamBasicDescription(
      mSampleRate: SixPagesVoicePlugin.targetSampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
      mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)

    // Output bus (app → speaker): Build 2 — use the REAL hardware rate so the
    // render callback's frame math matches the clock it's driven by. Joe's feed
    // is upsampled to this rate in feedPlayback.
    var outFormat = AudioStreamBasicDescription(
      mSampleRate: hwRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
      mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)

    try checkStatus("set input-bus client format",
      AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output,
                           inputBus, &inFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))
    try checkStatus("set output-bus client format",
      AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input,
                           outputBus, &outFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))

    var bypass: UInt32 = 0
    try checkStatus("AEC on (bypass=0)",
      AudioUnitSetProperty(unit, kAUVoiceIOProperty_BypassVoiceProcessing, kAudioUnitScope_Global,
                           0, &bypass, UInt32(MemoryLayout<UInt32>.size)))

    // Render callback (playback) — Layer 2.
    var renderCallback = AURenderCallbackStruct(
      inputProc: SixPagesVoicePlugin.renderCallback,
      inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
    try checkStatus("set render callback",
      AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input,
                           outputBus, &renderCallback,
                           UInt32(MemoryLayout<AURenderCallbackStruct>.size)))

    // ── Layer 3: install the INPUT callback (fires when mic frames are ready) ─
    var inputCallback = AURenderCallbackStruct(
      inputProc: SixPagesVoicePlugin.inputCallback,
      inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
    try checkStatus("set input callback",
      AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global,
                           inputBus, &inputCallback,
                           UInt32(MemoryLayout<AURenderCallbackStruct>.size)))

    // Allocate the scratch buffer the input callback renders into. Sized for a
    // generous callback (VoiceProcessingIO can deliver ~960–1440 frames); we
    // cap at 4096 frames (8192 bytes) which comfortably covers observed sizes.
    captureScratchFrameCap = 4096
    captureScratch = UnsafeMutablePointer<Int16>.allocate(capacity: captureScratchFrameCap)

    playback.clear()
    capture.clear()
    // Build 2: reset diagnostic counters so each session reports fresh numbers
    // (lets us verify underruns drop toward 0 after the fix).
    renderCalls = 0
    underrunEvents = 0
    lastRenderBytesRequested = 0
    lastInputFrames = 0

    try checkStatus("AudioUnitInitialize", AudioUnitInitialize(unit))

    // ── Layer 4 instrumentation: what formats did the unit NEGOTIATE? ─────────
    // We set 16 kHz client formats on both buses. Read them back to confirm the
    // unit accepted them (vs silently coercing to hardware rate). This is the
    // second half of the risk-1 verdict: even if the session rate differs, the
    // unit may still honor a 16 kHz CLIENT format and convert internally — in
    // which case our rings are fed 16 kHz and no converter is needed.
    logNegotiatedFormat(unit, scope: kAudioUnitScope_Output, bus: inputBus,
                        label: "input-bus client (mic→app)")
    logNegotiatedFormat(unit, scope: kAudioUnitScope_Input, bus: outputBus,
                        label: "output-bus client (app→spk)")

    try checkStatus("AudioOutputUnitStart", AudioOutputUnitStart(unit))
    isRunning = true

    startDrain()
  }

  private func stopUnit() {
    stopDrain()
    if let unit = ioUnit {
      AudioOutputUnitStop(unit)
      AudioUnitUninitialize(unit)
      AudioComponentInstanceDispose(unit)
      ioUnit = nil
    }
    isRunning = false
    playback.clear()
    capture.clear()
    // Build 2: release converter refs.
    feedConverter = nil
    feedInFormat = nil
    feedOutFormat = nil
    if let scratch = captureScratch {
      scratch.deallocate()
      captureScratch = nil
      captureScratchFrameCap = 0
    }
    try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
  }

  // MARK: - Capture drain (platform thread → Dart)
  //
  // Pushes whole 640-byte frames up via captureSink, one per available frame.
  // Runs on a serial queue and marshals the sink call — FlutterEventSink must
  // not be invoked from the audio thread. A short interval keeps latency low
  // while emitting Android-identical 640-byte frames. (This is the iOS analog
  // of Android's per-frame `mainHandler.post { eventSink.success(frame) }`.)
  private func startDrain() {
    let queue = DispatchQueue(label: "com.sixpages.voice.capture-drain")
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + .milliseconds(5), repeating: .milliseconds(5))
    timer.setEventHandler { [weak self] in
      guard let self = self else { return }
      // Emit every whole frame currently available.
      while let frame = self.capture.readFrame(SixPagesVoicePlugin.frameBytes) {
        let sink = self.captureSink
        DispatchQueue.main.async {
          sink?(FlutterStandardTypedData(bytes: frame))
        }
      }
    }
    drainTimer = timer
    timer.resume()
  }

  private func stopDrain() {
    drainTimer?.cancel()
    drainTimer = nil
  }

  private func checkStatus(_ what: String, _ status: OSStatus) throws {
    if status != noErr {
      os_log("audio: %{public}@ failed (OSStatus %d)",
             log: SixPagesVoicePlugin.log, type: .error, what, status)
      throw AudioError.osStatus(what, status)
    }
  }

  // Build 2: resample Joe's 16 kHz mono PCM16 bytes up to hwRate mono PCM16.
  // Returns the converted bytes (Data). Called from feedPlayback (Dart thread),
  // not the audio thread, so an allocation-per-call is acceptable here.
  private func convertFeed(_ input16k: Data) -> Data {
    guard let conv = feedConverter,
          let inFmt = feedInFormat,
          let outFmt = feedOutFormat,
          !input16k.isEmpty else {
      return input16k
    }

    let bytesPerFrame = 2 // Int16 mono
    let inFrameCount = AVAudioFrameCount(input16k.count / bytesPerFrame)
    guard inFrameCount > 0,
          let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: inFrameCount) else {
      return input16k
    }
    inBuf.frameLength = inFrameCount

    // Copy Joe's bytes into the input buffer's Int16 channel.
    input16k.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
      if let dst = inBuf.int16ChannelData?[0] {
        memcpy(dst, src.baseAddress!, Int(inFrameCount) * bytesPerFrame)
      }
    }

    // Output capacity: ceil(inFrames * hwRate/16000) + slack.
    let ratio = hwRate / SixPagesVoicePlugin.targetSampleRate
    let outCap = AVAudioFrameCount(Double(inFrameCount) * ratio + 8)
    guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCap) else {
      return input16k
    }

    var fed = false
    var convError: NSError?
    let status = conv.convert(to: outBuf, error: &convError) { _, outStatus in
      if fed {
        outStatus.pointee = .noDataNow
        return nil
      }
      fed = true
      outStatus.pointee = .haveData
      return inBuf
    }

    if status == .error || convError != nil {
      os_log("Build2: convertFeed error -> %{public}@", log: SixPagesVoicePlugin.log,
             type: .error, String(describing: convError))
      return input16k
    }

    let outFrames = Int(outBuf.frameLength)
    guard outFrames > 0, let outData = outBuf.int16ChannelData?[0] else {
      return input16k
    }
    return Data(bytes: outData, count: outFrames * bytesPerFrame)
  }

  /// Layer 4: read back and log the format the unit actually negotiated on a
  /// given scope/bus. Non-throwing — instrumentation must never break start().
  private func logNegotiatedFormat(_ unit: AudioUnit,
                                   scope: AudioUnitScope,
                                   bus: AudioUnitElement,
                                   label: String) {
    var asbd = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let status = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                      scope, bus, &asbd, &size)
    if status == noErr {
      let rateMatches = abs(asbd.mSampleRate - SixPagesVoicePlugin.targetSampleRate) < 1.0
      os_log("FMT-CHECK [%{public}@]: %{public}.0f Hz, %d ch, %d-bit — %{public}@",
             log: SixPagesVoicePlugin.log, type: rateMatches ? .info : .error,
             label, asbd.mSampleRate, asbd.mChannelsPerFrame, asbd.mBitsPerChannel,
             rateMatches ? "16 kHz honored (rings fed correctly)"
                         : "NOT 16 kHz — converter needed on this bus")
      // Build 1: append to app-readable diagnostics.
      lastDiagnostics += "\(label)=\(Int(asbd.mSampleRate))Hz/\(asbd.mChannelsPerFrame)ch; "
    } else {
      os_log("FMT-CHECK [%{public}@]: read failed (OSStatus %d)",
             log: SixPagesVoicePlugin.log, type: .error, label, status)
      lastDiagnostics += "\(label)=readFail(\(status)); "
    }
  }

  // MARK: - Render callback (playback, audio thread) — Layer 2
  private static let renderCallback: AURenderCallback = {
    (inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData) -> OSStatus in
    let plugin = Unmanaged<SixPagesVoicePlugin>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let abl = ioData else {
      ioActionFlags.pointee.insert(.unitRenderAction_OutputIsSilence)
      return noErr
    }
    let buffers = UnsafeMutableAudioBufferListPointer(abl)
    plugin.renderCalls &+= 1
    for buffer in buffers {
      guard let mData = buffer.mData else { continue }
      let bytesRequested = Int(buffer.mDataByteSize)
      plugin.lastRenderBytesRequested = bytesRequested
      let provided = plugin.playback.read(into: mData, count: bytesRequested)
      if provided < bytesRequested {
        plugin.underrunEvents &+= 1
        memset(mData.advanced(by: provided), 0, bytesRequested - provided)
      }
    }
    return noErr
  }

  // MARK: - Input callback (mic, audio thread) — Layer 3
  //
  // Fires when the unit has AEC'd mic frames ready. Unlike the render callback,
  // the input side must PULL: call AudioUnitRender to render `inNumberFrames`
  // into our scratch AudioBufferList, then copy those (already-clean) bytes
  // into the capture ring buffer. The drain (platform thread) emits them.
  private static let inputCallback: AURenderCallback = {
    (inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData) -> OSStatus in
    let plugin = Unmanaged<SixPagesVoicePlugin>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let unit = plugin.ioUnit, let scratch = plugin.captureScratch else { return noErr }

    let frames = Int(inNumberFrames)
    plugin.lastInputFrames = frames
    if frames <= 0 || frames > plugin.captureScratchFrameCap { return noErr }

    let byteCount = frames * 2 // Int16 mono

    // Build an AudioBufferList pointing at our scratch buffer for the render.
    var bufferList = AudioBufferList(
      mNumberBuffers: 1,
      mBuffers: AudioBuffer(
        mNumberChannels: 1,
        mDataByteSize: UInt32(byteCount),
        mData: UnsafeMutableRawPointer(scratch)))

    let status = AudioUnitRender(unit,
                                 ioActionFlags,
                                 inTimeStamp,
                                 inBusNumber,
                                 inNumberFrames,
                                 &bufferList)
    if status != noErr {
      // A render error here is a real failure; report it (do NOT swallow it as
      // noErr — but also do NOT inherit AECAudioStream's inverse bug of
      // returning an error on SUCCESS. This branch is genuine failure only).
      return status
    }

    // Copy the clean frame into the capture ring; drain emits it as 640-byte
    // frames. Variable inNumberFrames is fine — the ring is byte-oriented and
    // the drain reassembles fixed 640-byte frames (July 7 risk 2: buffer-
    // agnostic drain, never assume a fixed callback frame size).
    plugin.capture.write(from: UnsafeRawPointer(scratch), count: byteCount)

    return noErr // July 7 risk 3: return noErr on success.
  }
}

// MARK: - EventChannel (capture)

extension SixPagesVoicePlugin: FlutterStreamHandler {
  public func onListen(withArguments arguments: Any?,
                       eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    self.captureSink = events
    os_log("capture onListen: stream connected", log: SixPagesVoicePlugin.log, type: .info)
    return nil
  }
  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.captureSink = nil
    os_log("capture onCancel: stream released", log: SixPagesVoicePlugin.log, type: .info)
    return nil
  }
}
