import Flutter
import UIKit
import AVFoundation
import AudioToolbox
import os.log

// ─────────────────────────────────────────────────────────────────────────────
// SixPagesVoicePlugin — iOS
//
// STEP B, LAYER 1: AUDIO SCAFFOLDING ONLY.
//
// This layer stands up the echo-cancelling audio unit and proves it compiles
// and links against the iOS SDK. It does NOT yet move audio:
//   • start        → configures AVAudioSession, creates the VoiceProcessingIO
//                     unit, sets 16 kHz mono PCM16 on both buses, enables AEC,
//                     initializes + starts the unit. Returns true on success.
//   • stop         → stops + uninitializes + disposes the unit.
//   • feedPlayback → still accepted and dropped (ring buffer arrives Layer 2).
//   • capture      → still emits nothing (input callback arrives Layer 3).
//
// Design note (deliberate deviation from the July 7 "raw AUGraph" wording):
// AUGraph was deprecated by Apple at iOS 13, which is our deployment floor.
// This uses the modern raw AudioUnit C API instead — same architecture, same
// VoiceProcessingIO subtype, same callbacks and ring buffers in later layers,
// without building on a deprecated wrapper. The Dart contract is unchanged.
//
// Contract (locked from lib/six_pages_voice_method_channel.dart):
//   MethodChannel "six_pages_voice/control"  → start / stop / feedPlayback
//   EventChannel  "six_pages_voice/capture"  → captureStream (broadcast)
//   feedPlayback argument IS raw bytes (FlutterStandardTypedData), not a map.
//   capture frames: PCM16, 16 kHz, mono.
// ─────────────────────────────────────────────────────────────────────────────

public class SixPagesVoicePlugin: NSObject, FlutterPlugin {

  private static let log = OSLog(subsystem: "com.sixpages.six_pages_voice", category: "SixPagesVoice")

  // The one echo-cancelling I/O unit. nil until start() opens it.
  private var ioUnit: AudioUnit?

  // Whether the unit is currently running (guards double start/stop).
  private var isRunning = false

  // Target format for the whole pipeline: 16 kHz, mono, signed 16-bit, packed.
  // (Layer 1 requests this on both buses; the sample-rate-fallback converter
  //  that handles a refusal is Layer 4, risk 1.)
  private static let targetSampleRate: Double = 16000.0

  // Held so we can push capture frames up once audio exists (Layer 3).
  private var captureSink: FlutterEventSink?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let messenger = registrar.messenger()

    let controlChannel = FlutterMethodChannel(
      name: "six_pages_voice/control",
      binaryMessenger: messenger
    )
    let captureChannel = FlutterEventChannel(
      name: "six_pages_voice/capture",
      binaryMessenger: messenger
    )

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
        os_log("start: VoiceProcessingIO unit running", log: SixPagesVoicePlugin.log, type: .info)
        result(true)
      } catch {
        os_log("start: FAILED — %{public}@", log: SixPagesVoicePlugin.log, type: .error,
               String(describing: error))
        stopUnit() // leave nothing half-open
        result(false)
      }

    case "stop":
      stopUnit()
      os_log("stop: unit torn down", log: SixPagesVoicePlugin.log, type: .info)
      result(nil)

    case "feedPlayback":
      // Contract: the argument is the raw bytes directly (FlutterStandardTypedData).
      if let typed = call.arguments as? FlutterStandardTypedData {
        // Layer 1: accept and drop. Layer 2 writes typed.data into the playback ring buffer.
        os_log("feedPlayback: (layer1) received %d bytes, dropping",
               log: SixPagesVoicePlugin.log, type: .debug, typed.data.count)
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

  // MARK: - Audio unit lifecycle (Layer 1)

  private enum AudioError: Error {
    case session(String)
    case osStatus(String, OSStatus)
    case noComponent
  }

  /// Builds the AVAudioSession + VoiceProcessingIO unit and starts it.
  /// No callbacks are installed yet — that is Layers 2 and 3.
  private func startUnit() throws {
    if isRunning { return }

    // 1. Audio session: play + record, prefer the speaker, voice-chat processing.
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

    // 2. Describe the VoiceProcessingIO audio unit (Apple's echo canceller).
    var desc = AudioComponentDescription(
      componentType: kAudioUnitType_Output,
      componentSubType: kAudioUnitSubType_VoiceProcessingIO,
      componentManufacturer: kAudioUnitManufacturer_Apple,
      componentFlags: 0,
      componentFlagsMask: 0
    )

    guard let comp = AudioComponentFindNext(nil, &desc) else {
      throw AudioError.noComponent
    }

    var unitOptional: AudioUnit?
    try checkStatus("AudioComponentInstanceNew",
                    AudioComponentInstanceNew(comp, &unitOptional))
    guard let unit = unitOptional else { throw AudioError.noComponent }
    self.ioUnit = unit

    // Audio unit element/bus conventions:
    //   bus 1 = input  (mic → app)
    //   bus 0 = output (app → speaker)
    let inputBus: AudioUnitElement = 1
    let outputBus: AudioUnitElement = 0

    // 3. Enable input on the input bus (I/O units default input OFF).
    var enableFlag: UInt32 = 1
    try checkStatus("enable input",
      AudioUnitSetProperty(unit,
                           kAudioOutputUnitProperty_EnableIO,
                           kAudioUnitScope_Input,
                           inputBus,
                           &enableFlag,
                           UInt32(MemoryLayout<UInt32>.size)))
    // Output is enabled by default; set explicitly for clarity.
    try checkStatus("enable output",
      AudioUnitSetProperty(unit,
                           kAudioOutputUnitProperty_EnableIO,
                           kAudioUnitScope_Output,
                           outputBus,
                           &enableFlag,
                           UInt32(MemoryLayout<UInt32>.size)))

    // 4. Stream format: 16 kHz, mono, signed 16-bit, packed, interleaved.
    var format = AudioStreamBasicDescription(
      mSampleRate: SixPagesVoicePlugin.targetSampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 2,
      mFramesPerPacket: 1,
      mBytesPerFrame: 2,
      mChannelsPerFrame: 1,
      mBitsPerChannel: 16,
      mReserved: 0
    )

    // Format the app sees on the mic side (output scope of input bus).
    try checkStatus("set input-bus client format",
      AudioUnitSetProperty(unit,
                           kAudioUnitProperty_StreamFormat,
                           kAudioUnitScope_Output,
                           inputBus,
                           &format,
                           UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))
    // Format the app supplies on the playback side (input scope of output bus).
    try checkStatus("set output-bus client format",
      AudioUnitSetProperty(unit,
                           kAudioUnitProperty_StreamFormat,
                           kAudioUnitScope_Input,
                           outputBus,
                           &format,
                           UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))

    // 5. Explicitly ensure voice processing (AEC) is ON (bypass = 0).
    var bypass: UInt32 = 0
    try checkStatus("AEC on (bypass=0)",
      AudioUnitSetProperty(unit,
                           kAUVoiceIOProperty_BypassVoiceProcessing,
                           kAudioUnitScope_Global,
                           0,
                           &bypass,
                           UInt32(MemoryLayout<UInt32>.size)))

    // NOTE: render + input callbacks are intentionally NOT installed in Layer 1.
    // Layer 2 installs the render callback (drains playback ring buffer to bus 0).
    // Layer 3 installs the input callback (pushes AEC'd mic frames to captureSink).

    // 6. Initialize + start.
    try checkStatus("AudioUnitInitialize", AudioUnitInitialize(unit))
    try checkStatus("AudioOutputUnitStart", AudioOutputUnitStart(unit))

    isRunning = true
  }

  /// Stops + tears down the unit. Safe to call repeatedly.
  private func stopUnit() {
    if let unit = ioUnit {
      AudioOutputUnitStop(unit)
      AudioUnitUninitialize(unit)
      AudioComponentInstanceDispose(unit)
      ioUnit = nil
    }
    isRunning = false
    // Deactivate the session so mic/speaker are released for the rest of iOS.
    try? AVAudioSession.sharedInstance().setActive(false,
                                                   options: [.notifyOthersOnDeactivation])
  }

  /// Turns a non-zero OSStatus into a thrown error with the failing call named.
  private func checkStatus(_ what: String, _ status: OSStatus) throws {
    if status != noErr {
      os_log("audio: %{public}@ failed (OSStatus %d)",
             log: SixPagesVoicePlugin.log, type: .error, what, status)
      throw AudioError.osStatus(what, status)
    }
  }
}

// MARK: - EventChannel (capture)

extension SixPagesVoicePlugin: FlutterStreamHandler {

  public func onListen(withArguments arguments: Any?,
                       eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    // Dart subscribed to captureStream. Hold the sink; Layer 3 feeds AEC'd
    // frames through it. Layer 1 emits nothing — proving only that it connects.
    self.captureSink = events
    os_log("capture onListen: stream connected (layer1 — no frames yet)",
           log: SixPagesVoicePlugin.log, type: .info)
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.captureSink = nil
    os_log("capture onCancel: stream released", log: SixPagesVoicePlugin.log, type: .info)
    return nil
  }
}
