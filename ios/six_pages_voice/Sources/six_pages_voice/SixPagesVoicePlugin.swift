import Flutter
import UIKit
import os.log

// ─────────────────────────────────────────────────────────────────────────────
// SixPagesVoicePlugin — iOS
//
// STEP A: CHANNEL SKELETON ONLY. No audio unit yet.
//
// This proves the Dart↔Swift seam on iOS before any real-time audio is added:
//   • MethodChannel  "six_pages_voice/control"  → start / stop / feedPlayback
//   • EventChannel   "six_pages_voice/capture"  → captureStream (broadcast)
//
// Contract (locked from lib/six_pages_voice_method_channel.dart @ fc54af1):
//   start        → returns Bool (did the unit open)
//   stop         → returns void
//   feedPlayback → argument IS the raw bytes (FlutterStandardTypedData), not a map
//   capture      → broadcast stream of Uint8List frames (PCM16, 16 kHz, mono)
//
// In Step B, the audio unit (AUGraph + VoiceProcessingIO) is built INTO this
// known-good frame: feedPlayback fills a ring buffer drained by the render
// callback; the input callback pushes AEC'd frames into a ring buffer drained
// to `captureSink`.
// ─────────────────────────────────────────────────────────────────────────────

public class SixPagesVoicePlugin: NSObject, FlutterPlugin {

  private static let log = OSLog(subsystem: "com.sixpages.six_pages_voice", category: "SixPagesVoice")

  // Held so we can push capture frames up once audio exists (Step B).
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
      // Step A: no audio unit yet — report success so the Dart side proceeds
      // and we can confirm the round-trip. Step B opens the real unit here.
      os_log("start: (skeleton) returning true — no audio unit yet", log: SixPagesVoicePlugin.log, type: .info)
      result(true)

    case "stop":
      os_log("stop: (skeleton) no-op", log: SixPagesVoicePlugin.log, type: .info)
      result(nil)

    case "feedPlayback":
      // Contract: the argument is the raw bytes directly (FlutterStandardTypedData).
      if let typed = call.arguments as? FlutterStandardTypedData {
        // Step A: accept and drop. Step B writes typed.data into the playback ring buffer.
        os_log("feedPlayback: (skeleton) received %d bytes, dropping",
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
}

// MARK: - EventChannel (capture)

extension SixPagesVoicePlugin: FlutterStreamHandler {

  public func onListen(withArguments arguments: Any?,
                       eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    // Dart subscribed to captureStream. Hold the sink; Step B feeds AEC'd frames
    // through it. Step A emits nothing — proving only that the stream connects.
    self.captureSink = events
    os_log("capture onListen: stream connected (skeleton — no frames yet)",
           log: SixPagesVoicePlugin.log, type: .info)
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.captureSink = nil
    os_log("capture onCancel: stream released", log: SixPagesVoicePlugin.log, type: .info)
    return nil
  }
}
