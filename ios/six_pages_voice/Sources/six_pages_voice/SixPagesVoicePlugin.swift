import Flutter
import UIKit
import AVFoundation
import AudioToolbox
import os.log

// ─────────────────────────────────────────────────────────────────────────────
// SixPagesVoicePlugin — iOS
//
// STEP B, LAYER 2: RENDER CALLBACK + PLAYBACK RING BUFFER.
//
// Builds on Layer 1 (VoiceProcessingIO scaffolding). This layer makes
// feedPlayback real: Joe's incoming PCM bytes are written into a ring buffer,
// and a render callback on the OUTPUT bus (bus 0) drains that buffer to the
// speaker THROUGH the voice-processing unit. Playing through the unit is what
// makes Joe's audio the echo reference the AEC subtracts automatically — no
// delay measurement, no alignment math (the OS does it).
//
//   • start        → Layer 1 scaffolding + installs the render callback.
//   • feedPlayback → writes raw bytes into the playback ring buffer.
//   • stop         → tears down unit + clears the ring buffer.
//   • capture      → STILL emits nothing (input callback is Layer 3).
//
// The render callback is a C function pointer and cannot capture Swift context,
// so it reaches the instance via an Unmanaged pointer passed as inRefCon.
//
// Contract (unchanged): MethodChannel "six_pages_voice/control",
// EventChannel "six_pages_voice/capture", feedPlayback arg is raw bytes
// (FlutterStandardTypedData), frames PCM16 / 16 kHz / mono.
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - PlaybackRingBuffer
//
// Single-producer (feedPlayback, Dart thread) / single-consumer (render
// callback, audio thread) byte ring buffer. A lock keeps it correct and simple;
// the critical sections are tiny (memcpy of a few hundred bytes), well within
// the render deadline at 16 kHz. If profiling later shows lock contention we can
// move to a lock-free design, but correctness first.
private final class PlaybackRingBuffer {
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

  /// Producer: append bytes. If the buffer would overflow, drop the OLDEST
  /// bytes (advance read) so the freshest audio wins — a late listener should
  /// hear "now", not a growing backlog.
  func write(_ bytes: UnsafeRawBufferPointer) {
    lock.lock(); defer { lock.unlock() }
    let n = bytes.count
    guard n > 0 else { return }

    // If more than capacity arrives at once, keep only the last `capacity` bytes.
    let start = n > capacity ? n - capacity : 0
    let toCopy = n - start

    for i in 0..<toCopy {
      storage[writeIndex] = bytes[start + i]
      writeIndex = (writeIndex + 1) % capacity
      if filled < capacity {
        filled += 1
      } else {
        // Overwrote unread data: advance read to drop the oldest byte.
        readIndex = (readIndex + 1) % capacity
      }
    }
  }

  /// Consumer: pull up to `count` bytes into `dest`. Returns bytes actually
  /// provided; the caller zero-fills any remainder (silence on underrun).
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

  // ~500 ms of 16 kHz mono PCM16 = 16000 * 0.5 * 2 bytes = 16000 bytes.
  // Headroom for network jitter in Joe's burst delivery; does NOT add fixed
  // latency (the render drain only holds as much as Joe is ahead by).
  private static let playbackBufferBytes = 16000
  private let playback = PlaybackRingBuffer(capacityBytes: playbackBufferBytes)

  private var captureSink: FlutterEventSink?

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
        os_log("start: VoiceProcessingIO unit running (render installed)",
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

    case "feedPlayback":
      if let typed = call.arguments as? FlutterStandardTypedData {
        typed.data.withUnsafeBytes { raw in
          playback.write(raw)
        }
        result(nil)
      } else {
        os_log("feedPlayback: BAD ARG — expected FlutterStandardTypedData, got %{public}@",
               log: SixPagesVoicePlugin.log, type: .error, String(describing: type(of: call.arguments)))
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
      try session.setCategory(.playAndRecord,
                              mode: .voiceChat,
                              options: [.defaultToSpeaker, .allowBluetooth])
      try session.setPreferredSampleRate(SixPagesVoicePlugin.targetSampleRate)
      try session.setActive(true)
    } catch {
      throw AudioError.session(error.localizedDescription)
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

    var format = AudioStreamBasicDescription(
      mSampleRate: SixPagesVoicePlugin.targetSampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
      mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)

    try checkStatus("set input-bus client format",
      AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output,
                           inputBus, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))
    try checkStatus("set output-bus client format",
      AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input,
                           outputBus, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))

    var bypass: UInt32 = 0
    try checkStatus("AEC on (bypass=0)",
      AudioUnitSetProperty(unit, kAUVoiceIOProperty_BypassVoiceProcessing, kAudioUnitScope_Global,
                           0, &bypass, UInt32(MemoryLayout<UInt32>.size)))

    // ── Layer 2: install the RENDER callback on the output bus ────────────────
    // The callback is a C function pointer; it reaches this instance through
    // inRefCon (an Unmanaged pointer). We pass an unretained pointer — the
    // plugin outlives the unit, and we dispose the unit in stopUnit() before
    // the plugin can go away, so there is no dangling reference.
    var renderCallback = AURenderCallbackStruct(
      inputProc: SixPagesVoicePlugin.renderCallback,
      inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
    try checkStatus("set render callback",
      AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input,
                           outputBus, &renderCallback,
                           UInt32(MemoryLayout<AURenderCallbackStruct>.size)))

    playback.clear()

    try checkStatus("AudioUnitInitialize", AudioUnitInitialize(unit))
    try checkStatus("AudioOutputUnitStart", AudioOutputUnitStart(unit))
    isRunning = true
  }

  private func stopUnit() {
    if let unit = ioUnit {
      AudioOutputUnitStop(unit)
      AudioUnitUninitialize(unit)
      AudioComponentInstanceDispose(unit)
      ioUnit = nil
    }
    isRunning = false
    playback.clear()
    try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
  }

  private func checkStatus(_ what: String, _ status: OSStatus) throws {
    if status != noErr {
      os_log("audio: %{public}@ failed (OSStatus %d)",
             log: SixPagesVoicePlugin.log, type: .error, what, status)
      throw AudioError.osStatus(what, status)
    }
  }

  // MARK: - Render callback (C function pointer, audio thread)
  //
  // Called by the unit when it needs `inNumberFrames` of playback audio on
  // bus 0. We drain the ring buffer into the supplied AudioBufferList; any
  // shortfall is zero-filled (silence) so the unit never plays garbage.
  // Must not allocate, lock for long, or call Swift runtime-heavy code — the
  // ring buffer's lock guards a tiny memcpy, which is acceptable here.
  private static let renderCallback: AURenderCallback = {
    (inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData) -> OSStatus in

    let plugin = Unmanaged<SixPagesVoicePlugin>.fromOpaque(inRefCon).takeUnretainedValue()

    guard let abl = ioData else {
      // Nothing to fill; mark silence.
      ioActionFlags.pointee.insert(.unitRenderAction_OutputIsSilence)
      return noErr
    }

    let buffers = UnsafeMutableAudioBufferListPointer(abl)
    for buffer in buffers {
      guard let mData = buffer.mData else { continue }
      let bytesRequested = Int(buffer.mDataByteSize)
      let provided = plugin.playback.read(into: mData, count: bytesRequested)
      if provided < bytesRequested {
        // Zero-fill the remainder → clean silence on underrun, no glitch.
        memset(mData.advanced(by: provided), 0, bytesRequested - provided)
      }
    }
    return noErr
  }
}

// MARK: - EventChannel (capture)

extension SixPagesVoicePlugin: FlutterStreamHandler {

  public func onListen(withArguments arguments: Any?,
                       eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    self.captureSink = events
    os_log("capture onListen: stream connected (layer2 — no frames yet)",
           log: SixPagesVoicePlugin.log, type: .info)
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.captureSink = nil
    os_log("capture onCancel: stream released", log: SixPagesVoicePlugin.log, type: .info)
    return nil
  }
}
