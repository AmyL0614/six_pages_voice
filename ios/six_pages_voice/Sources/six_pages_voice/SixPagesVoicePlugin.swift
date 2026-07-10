import Flutter
import UIKit
import AVFoundation
import AudioToolbox
import os.log

// ───────────────────────────────────────────────────────────────────────────
// SixPagesVoicePlugin — iOS
//
// STEP B, LAYER 8 (BUILD 4): LET VPIO RESAMPLE (delete the manual converter).
//
// CONFIRMED by Build 3 on-device diagnostics (iPad):
//   granted=48000Hz; feedConv=16k→48000Hz; output-bus client=48000Hz/1ch;
//   renderCalls=624; underruns=8 (1.3% — priming SOLVED the starve);
//   primed=false; reprimes=4; primeThresh=9600B
//   BY EAR: still finely choppy, words not intelligible.
//
// The verdict that forced this build: Build 3 drove underruns from 89% → 1.3%,
// so the ring is NO LONGER starving — yet the chop survived almost intact. When
// the measured cause is fixed and the symptom stays, the cause was misattributed.
// The chop is in the AUDIO ITSELF, not the buffer timing.
//
// Root cause (now researched, Apple Developer Forums thread/20187 + 104550 +
// 71817): VoiceProcessingIO RESAMPLES INTERNALLY. If you set a 16 kHz client
// format on the output bus, the unit converts 16k→hardware (48k) itself, with
// Apple's own continuous resampler. Build 2 added an AVAudioConverter to do this
// manually — but we ran it PER ElevenLabs CHUNK, with a one-shot input block and
// no state carried across chunks. That injects a discontinuity at EVERY chunk
// boundary → an even, periodic chop that garbles words. The converter WAS the chop.
//
// FIX (this build): stop fighting the OS. Do what the forums document:
//   1. Set the OUTPUT-bus client format back to 16000 Hz (like Build 1).
//   2. DELETE the AVAudioConverter path entirely. Feed Joe's raw 16 kHz bytes
//      straight to the playback ring — no per-chunk conversion, no seams.
//   3. The unit resamples 16k→48k continuously on the way to the speaker.
//   4. KEEP the Build 3 priming gate — it was real and correct (89% → 1.3%).
//      Priming is orthogonal to the converter; it stays exactly as-is.
//
// If this device happens to REJECT a 16 kHz output client format,
// AudioUnitInitialize throws and start() fails loudly (we'll see it) — but the
// forum consensus is 16 kHz client formats are accepted and resampled. This is
// the documented happy path, not a hack.
//
// CAPTURE is UNTOUCHED (transcript proved it clean). Input bus stays 16 kHz —
// which it always was; only the OUTPUT bus changes back from 48k to 16k.
// ───────────────────────────────────────────────────────────────────────────
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
//   • capture      → emits clean 640-byte PCM16 frames.
//   • stop         → tears down unit, stops drain, clears both ring buffers.
//
// July 7 risk 3: AECAudioStream's input callback returns kAudio_ParamError even
// on success. We return noErr correctly on the success path.
// ───────────────────────────────────────────────────────────────────────────

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

  // Build 3 (Layer 7): playback priming state. `primed` gates the render
  // callback — while false, it emits silence (NOT counted as underrun) until
  // the ring accumulates `primeThresholdBytes`. `reprimeEvents` counts how many
  // times a mid-stream full-drain forced a re-prime (network stalls). These are
  // read by getDiagnostics so the next device test proves the cushion filled.
  fileprivate var primed = false
  fileprivate var primeThresholdBytes = 0   // set in startUnit from hwRate (~100 ms)
  fileprivate var reprimeEvents = 0

  // Build 4: actual hardware sample rate read at start (e.g. 48000), kept ONLY
  // for the diagnostic string. Playback no longer converts to it — the output
  // bus is 16 kHz and VoiceProcessingIO resamples 16k→hardware internally.
  private var hwRate: Double = SixPagesVoicePlugin.targetSampleRate

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
      // Build 3: append priming state (primed / reprimes / threshold) so we can
      // prove the cushion filled and underruns collapsed toward 0.
      let live = "renderCalls=\(renderCalls); underruns=\(underrunEvents); "
        + "lastReqBytes=\(lastRenderBytesRequested); lastInputFrames=\(lastInputFrames); "
        + "primed=\(primed); reprimes=\(reprimeEvents); primeThresh=\(primeThresholdBytes)B"
      result(lastDiagnostics + live)

    case "feedPlayback":
      if let typed = call.arguments as? FlutterStandardTypedData {
        // Build 4: write Joe's raw 16 kHz PCM16 straight to the ring. NO manual
        // conversion — the output bus is 16 kHz and VoiceProcessingIO resamples
        // 16k→hardware internally, continuously, with no chunk-boundary seams.
        typed.data.withUnsafeBytes { raw in playback.write(raw) }
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

    // ── Build 4: no manual conversion. Record hwRate for diagnostics only. ────
    // The output bus is set to 16 kHz (below); VoiceProcessingIO resamples
    // 16k→hardware internally. Joe's feed enters the ring as raw 16 kHz bytes.
    hwRate = grantedRate
    lastDiagnostics += "playbackPath=VPIO-internal-resample(16k→\(Int(hwRate))Hz); "

    // ── Build 3: compute the priming cushion (~100 ms). Playback is now 16 kHz
    // (the render callback consumes 16 kHz bytes; the unit resamples downstream),
    // so the cushion is 100 ms of 16 kHz mono PCM16 = 16000 * 2 * 0.1 = 3200 B.
    let hundredMs = Int(SixPagesVoicePlugin.targetSampleRate * 2.0 * 0.1)
    primeThresholdBytes = min(hundredMs, SixPagesVoicePlugin.playbackBufferBytes / 2)
    primed = false
    reprimeEvents = 0
    os_log("Build3: primeThresholdBytes = %d (≈100 ms at %{public}.0f Hz)",
           log: SixPagesVoicePlugin.log, type: .info, primeThresholdBytes, hwRate)

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

    // Output bus (app → speaker): Build 4 — set 16 kHz CLIENT format. The unit
    // accepts it and resamples 16k→hardware(48k) internally and continuously.
    // This is the documented VPIO behavior (Apple Dev Forums thread/20187): as
    // long as the AU doesn't reject the format, rate conversion is automatic.
    var outFormat = AudioStreamBasicDescription(
      mSampleRate: SixPagesVoicePlugin.targetSampleRate,
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

    // ── Layer 4 instrumentation: what formats did the unit NEGOTIATE? ────────
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
    // Build 3: reset priming state so a fresh session re-primes cleanly.
    primed = false
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

  // MARK: - Render callback (playback, audio thread) — Layer 2 + Build 3 priming
  //
  // Build 3: gate consumption on a startup cushion. While NOT primed, output
  // clean silence and DO NOT count an underrun (priming is not starving) until
  // the ring holds primeThresholdBytes (~100 ms). Once primed, read normally.
  // If a normal read returns 0 on a nonzero request (mid-stream stall drained
  // the ring), drop back to unprimed and count a re-prime so the gap re-buffers
  // silently instead of chopping through it.
  private static let renderCallback: AURenderCallback = {
    (inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData) -> OSStatus in
    let plugin = Unmanaged<SixPagesVoicePlugin>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let abl = ioData else {
      ioActionFlags.pointee.insert(.unitRenderAction_OutputIsSilence)
      return noErr
    }
    let buffers = UnsafeMutableAudioBufferListPointer(abl)
    plugin.renderCalls &+= 1

    // Build 3: priming gate. If not yet primed, wait for the cushion. Emit clean
    // silence and return WITHOUT counting an underrun — this is intentional
    // buffering, not a starve.
    if !plugin.primed {
      if plugin.playback.count >= plugin.primeThresholdBytes {
        plugin.primed = true   // cushion built; fall through to normal read
      } else {
        for buffer in buffers {
          if let mData = buffer.mData {
            memset(mData, 0, Int(buffer.mDataByteSize))
          }
        }
        ioActionFlags.pointee.insert(.unitRenderAction_OutputIsSilence)
        return noErr
      }
    }

    for buffer in buffers {
      guard let mData = buffer.mData else { continue }
      let bytesRequested = Int(buffer.mDataByteSize)
      plugin.lastRenderBytesRequested = bytesRequested
      let provided = plugin.playback.read(into: mData, count: bytesRequested)
      if provided < bytesRequested {
        plugin.underrunEvents &+= 1
        memset(mData.advanced(by: provided), 0, bytesRequested - provided)
        // Build 3: a FULL drain (nothing at all provided) on a nonzero request
        // means the ring emptied mid-stream — a network stall. Re-prime so the
        // gap re-buffers rather than chopping through the burst gap.
        if provided == 0 && bytesRequested > 0 {
          plugin.primed = false
          plugin.reprimeEvents &+= 1
        }
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
