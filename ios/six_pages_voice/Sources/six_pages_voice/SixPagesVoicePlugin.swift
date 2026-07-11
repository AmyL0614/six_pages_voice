import Flutter
import UIKit
import AVFoundation
import AudioToolbox
import os.log
import Darwin  // Build 6: OSMemoryBarrier (acquire/release fence) for the lock-free ring

// ───────────────────────────────────────────────────────────────────────────
// SixPagesVoicePlugin — iOS
//
// STEP B, LAYER 12 (BUILD 8): memcpy COPIES + RENDER-TIME DIAGNOSTIC.
//
// CONFIRMED by Build 7 on-device diagnostics (iPad):
//   30 s ring; underruns=6/5229 (0.11%); reprimes=3; droppedBytes=0 (ring did NOT
//   overflow). BY EAR: only the LONGEST reply broke up (later in it); shorter
//   replies clean.
//
// droppedBytes=0 DISPROVED overflow (the ring held the long turn, dropped nothing).
// underruns ~0 disproves starvation. So on a long turn the buffer is perfect yet
// the audio breaks late — a cause invisible to every existing counter. Two
// candidates remain: (1) our copy loops were BYTE-BY-BYTE; the render-callback read
// runs on the real-time thread every ~23 ms, and a per-byte Swift loop could exceed
// that deadline deep in a long turn → chop; (2) the long-turn break-up is UPSTREAM
// (ElevenLabs/WebSocket delivering the tail in a stutter), which our numbers can't
// see.
//
// THIS BUILD does the low-risk likely-fix AND instruments to decide between the two:
//   (1) Replace all three byte-by-byte ring copies with memcpy (two-segment for the
//       circular wrap). memcpy on/near the audio thread is correct practice and
//       removes the per-byte deadline risk.
//   (2) Add maxRenderUs = the longest single render callback this session, in µs.
//       Deadline is ~23000 µs. After a long-reply test: if maxRenderUs is small
//       (say < a few thousand) AND it still broke up → the callback is fine, the
//       problem is UPSTREAM (look at the socket/feed). If maxRenderUs approached
//       23000 → the copy was the cause and memcpy should now fix it.
//
// Everything else (lock-free SPSC ring, 30 s size, VPIO 16k resample, priming,
// capture) is UNCHANGED.
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

// MARK: - ByteRingBuffer (Build 6 / Layer 10: LOCK-FREE SPSC)
//
// WHY THIS EXISTS (the fix that took 7 tries to reach): the render callback runs
// on the real-time audio thread with a hard ~23 ms deadline. The previous version
// guarded every read/write with an NSLock. While ElevenLabs streamed a turn,
// feedPlayback (Dart thread) hammered that lock; whenever a write held it at the
// moment the render callback needed it, the AUDIO THREAD BLOCKED WAITING → missed
// its deadline → the unit got silence → glitch. The instant the stream stopped,
// no contention, callback always got the lock → smooth. That "choppy while audio
// streams, smooth once it stops" is the textbook signature of PRIORITY INVERSION
// from taking a lock on the audio thread — documented by Ross Bencina ("Real-time
// audio programming 101"), Timur Doumler, and Android's own audio docs, which note
// it manifests as "repeated audio when circular buffers are used" (our overlap) and
// dropouts (our skip). Bigger buffers (Builds 3 & 5) only MASKED it — Android's docs
// say so explicitly. The real cure is: the audio thread must NEVER block.
//
// Android doesn't have this problem because its playback writes straight to an OS
// AudioTrack (no app-side render callback pulling from a shared ring). iOS can't
// copy that: Joe's playback MUST pass through the VoiceProcessingIO render callback
// so the OS can echo-cancel it. So iOS needs a lock-free hand-off to that callback.
//
// DESIGN — strict single-producer / single-consumer, lock-free:
//   • Playback: producer = feedPlayback (Dart thread); consumer = render callback.
//   • Capture:  producer = input callback; consumer = drain timer.
//   Both are SPSC — the ONLY safe case for a simple lock-free ring.
//   • Two free-running counters. The PRODUCER owns writeIndex and only ever
//     advances it (atomic release-store after copying data). The CONSUMER owns
//     readIndex and only ever advances it (atomic release-store after copying).
//   • Each side reads the OTHER's counter with an atomic acquire-load. Acquire/
//     release ordering guarantees the bytes are visible before the index that
//     publishes them. No thread ever waits on the other. The render callback can
//     ALWAYS make progress within its deadline.
//   • Overflow policy CHANGED from "drop oldest" to "drop NEWEST (write only what
//     fits)". Drop-oldest required the producer to advance readIndex, which would
//     violate SPSC. With Build 5's full-turn (15 s) ring, overflow effectively
//     never happens for a normal turn; if an over-long turn ever filled it,
//     discarding the newest tail is safe and glitch-free.
//
// Uses Swift's atomics via UnsafeAtomic on raw Int storage — no Foundation lock,
// nothing that can block, allocation-free on the hot path.
private final class ByteRingBuffer {
  private var storage: [UInt8]
  private let capacity: Int

  // Free-running counters (monotonic, wrap via modulo on access). writeIndex is
  // written ONLY by the producer; readIndex ONLY by the consumer. Each is read by
  // the other side with acquire ordering. Stored as atomics so publication of the
  // data (release store) happens-before the other thread observes the new index.
  private let writeIndex: UnsafeMutablePointer<Int>
  private let readIndex: UnsafeMutablePointer<Int>

  // Build 7: total bytes DROPPED because the ring was full when a write arrived
  // (drop-newest overflow). Producer-only writes; read for diagnostics. If this is
  // > 0 after a turn, the ring filled mid-turn and discarded Joe's later audio —
  // the direct measure of "starts great, stumbles mid/late." Plain counter (coarse
  // diagnostic, not correctness-critical).
  private let droppedBytesPtr: UnsafeMutablePointer<Int>
  var droppedBytes: Int { return droppedBytesPtr.pointee }

  init(capacityBytes: Int) {
    self.capacity = capacityBytes
    self.storage = [UInt8](repeating: 0, count: capacityBytes)
    self.writeIndex = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    self.readIndex = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    self.droppedBytesPtr = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    self.writeIndex.initialize(to: 0)
    self.readIndex.initialize(to: 0)
    self.droppedBytesPtr.initialize(to: 0)
  }

  deinit {
    writeIndex.deinitialize(count: 1); writeIndex.deallocate()
    readIndex.deinitialize(count: 1); readIndex.deallocate()
    droppedBytesPtr.deinitialize(count: 1); droppedBytesPtr.deallocate()
  }

  // Bytes currently available to read. Safe to call from either thread.
  var count: Int {
    let w = _load(writeIndex)
    let r = _load(readIndex)
    return w - r
  }

  // ── Atomic helpers (acquire load / release store) ─────────────────────────
  // OSAtomic is deprecated but the memory-barrier free-functions remain the
  // simplest portable acquire/release primitives available without importing the
  // Swift Atomics package (which the plugin does not depend on). A full barrier
  // is stronger than needed but always correct and costs a single fence.
  @inline(__always) private func _load(_ p: UnsafeMutablePointer<Int>) -> Int {
    let v = p.pointee
    OSMemoryBarrier() // acquire: no later read/write is reordered before this
    return v
  }
  @inline(__always) private func _store(_ p: UnsafeMutablePointer<Int>, _ v: Int) {
    OSMemoryBarrier() // release: all prior writes (the data) publish before index
    p.pointee = v
  }

  /// Producer: append bytes. On overflow, drop the NEWEST excess (write only what
  /// fits) so the producer never touches readIndex — preserving SPSC safety.
  func write(_ bytes: UnsafeRawBufferPointer) {
    let n = bytes.count
    guard n > 0 else { return }
    write(from: bytes.baseAddress!, count: n)
  }

  /// Producer variant writing from a raw pointer + length (used by the input
  /// callback, which holds an AudioBuffer's mData/mDataByteSize).
  func write(from ptr: UnsafeRawPointer, count n: Int) {
    guard n > 0 else { return }
    let src = ptr.assumingMemoryBound(to: UInt8.self)
    let w = writeIndex.pointee          // producer owns writeIndex — plain read ok
    let r = _load(readIndex)            // acquire the consumer's progress
    let used = w - r
    let free = capacity - used
    if free <= 0 {
      droppedBytesPtr.pointee += n   // fully full: entire write dropped
      return
    }
    let toCopy = min(n, free)
    if toCopy < n { droppedBytesPtr.pointee += (n - toCopy) } // partial drop
    let wi = w % capacity
    // Build 8: bulk memcpy instead of byte-by-byte. Circular buffer may wrap, so
    // copy in up to two contiguous segments. memcpy on the audio-adjacent path is
    // far faster than a Swift per-byte loop — the loop could blow the render
    // deadline deep in a long turn.
    let firstLen = min(toCopy, capacity - wi)
    storage.withUnsafeMutableBytes { dstRaw in
      let dst = dstRaw.baseAddress!
      memcpy(dst.advanced(by: wi), src, firstLen)
      if toCopy > firstLen {
        memcpy(dst, src.advanced(by: firstLen), toCopy - firstLen)
      }
    }
    _store(writeIndex, w + toCopy)      // release: publish data, then new index
  }

  /// Consumer: pull up to `count` bytes into `dest`. Returns bytes provided.
  func read(into dest: UnsafeMutableRawPointer, count: Int) -> Int {
    let r = readIndex.pointee           // consumer owns readIndex — plain read ok
    let w = _load(writeIndex)           // acquire the producer's progress
    let available = min(count, w - r)
    if available <= 0 { return 0 }
    let d = dest.assumingMemoryBound(to: UInt8.self)
    let ri = r % capacity
    // Build 8: bulk memcpy, up to two segments for the circular wrap. This runs on
    // the REAL-TIME audio thread every render callback — a per-byte loop here was
    // the suspected cause of chop late in long turns (loop time growing with the
    // copy size until it exceeded the ~23 ms deadline). memcpy is O(n) but orders
    // of magnitude faster in constant terms.
    let firstLen = min(available, capacity - ri)
    storage.withUnsafeBytes { srcRaw in
      let base = srcRaw.baseAddress!
      memcpy(d, base.advanced(by: ri), firstLen)
      if available > firstLen {
        memcpy(d.advanced(by: firstLen), base, available - firstLen)
      }
    }
    _store(readIndex, r + available)    // release: publish consumption
    return available
  }

  /// Consumer variant: pull exactly `n` bytes as a Data if available, else nil.
  /// Used by the capture drain to emit whole 640-byte frames only.
  func readFrame(_ n: Int) -> Data? {
    let r = readIndex.pointee
    let w = _load(writeIndex)
    guard (w - r) >= n else { return nil }
    var out = Data(count: n)
    out.withUnsafeMutableBytes { raw in
      let d = raw.bindMemory(to: UInt8.self).baseAddress!
      let ri = r % capacity
      let firstLen = min(n, capacity - ri)
      storage.withUnsafeBytes { srcRaw in
        let base = srcRaw.baseAddress!
        memcpy(d, base.advanced(by: ri), firstLen)
        if n > firstLen {
          memcpy(d.advanced(by: firstLen), base, n - firstLen)
        }
      }
    }
    _store(readIndex, r + n)
    return out
  }

  /// Reset. NOT lock-free-safe against concurrent access — only call when the
  /// audio unit is stopped (start()/stop() paths), never mid-stream. Matches the
  /// previous clear()'s contract (it was only called from stop/start).
  func clear() {
    _store(writeIndex, 0)
    _store(readIndex, 0)
    droppedBytesPtr.pointee = 0
  }
}

public class SixPagesVoicePlugin: NSObject, FlutterPlugin {

  private static let log = OSLog(subsystem: "com.sixpages.six_pages_voice", category: "SixPagesVoice")

  private var ioUnit: AudioUnit?
  private var isRunning = false

  /// Live only for the duration of a session; removed in stopUnit().
  private var routeObserver: NSObjectProtocol?

  private static let targetSampleRate: Double = 16000.0

  // Frame contract (mirrors Android): 640 bytes = 20 ms of 16 kHz mono PCM16.
  private static let frameBytes = 640

  // Playback ring: Build 7 — sized to hold the LONGEST turn (Joe's session
  // summary is the worst case) without overflowing. ElevenLabs delivers a turn
  // FASTER than realtime, so a ring smaller than the turn fills mid-turn and the
  // drop-newest overflow discards Joe's later audio → "starts great, stumbles
  // mid/late." Build 5's 15 s (480000 B) filled mid-turn on longer replies.
  // 30 s of 16 kHz mono PCM16 = 16000 * 2 * 30 = 960000 B (~938 KB — trivial).
  // The droppedBytes diagnostic will confirm whether 30 s is enough; if a turn
  // ever exceeds it, raise again (reflections are bounded, so a finite ring is
  // the right practical fix — true backpressure isn't feasible over the fire-
  // and-forget method channel).
  private static let playbackBufferBytes = 960000
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

  // Build 8: max time a single render callback took, in microseconds. If a
  // per-byte copy (now memcpy) or anything else made the callback exceed the
  // ~23 ms (23000 µs) hardware deadline late in a long turn, we'd see this spike.
  // maxRenderMicros near the deadline = the callback is the chop; staying tiny =
  // the callback is fine and the long-turn break-up is UPSTREAM (socket/feed).
  // mach_absolute_time is cheap and real-time safe; converted to µs via timebase.
  fileprivate var maxRenderMicros: Int = 0
  fileprivate var machTimebaseNumer: UInt32 = 0
  fileprivate var machTimebaseDenom: UInt32 = 0

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
        + "primed=\(primed); reprimes=\(reprimeEvents); primeThresh=\(primeThresholdBytes)B; "
        + "droppedBytes=\(playback.droppedBytes); maxRenderUs=\(maxRenderMicros)"
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

  // MARK: - Audio route (speaker / Bluetooth / wired), mid-session aware
  //
  // OBSERVE-ONLY. This listener reports where audio went. It does NOT steer.
  //
  // That is a deliberate correction of an earlier version that called
  // overrideOutputAudioPort(.speaker) on device removal, and it is the reason long
  // replies chopped and car connections dropped after a moment. Three points from
  // Apple's own documentation, each sufficient on its own:
  //
  //   1. "Apps should treat these changes as authoritative. They should NEVER
  //      immediately attempt to revert the change." Overriding the port mid-stream
  //      is exactly that.
  //
  //   2. The notification is POSTED ON A SECONDARY THREAD. Acting on it means
  //      touching session state at an unpredictable moment relative to the running
  //      audio unit.
  //
  //   3. Most decisive: with kAudioUnitSubType_VoiceProcessingIO, "the system will
  //      automatically manage this for the application. In particular, ports of type
  //      AVAudioSessionPortBluetoothHFP and AVAudioSessionPortCarAudio." VPIO ALREADY
  //      handles Bluetooth and car routing. There is nothing for us to fix, and
  //      intervening breaks what was working.
  //
  // The category options set at session start already encode the priority we want
  // (headset the user chose > built-in speaker). iOS honours it. Our job is to watch,
  // log, and stay out of the way.
  //
  // NOTE the asymmetry with Android, which is correct and intended: Android's
  // AudioManager DOES expect the app to select the device, and there we re-assert
  // deliberately. iOS does not. The platforms have different contracts; matching the
  // Android pattern here is what caused the bug.

  private func registerRouteListener() {
    guard routeObserver == nil else { return }
    routeObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { [weak self] notification in
      self?.handleRouteChange(notification)
    }
  }

  private func unregisterRouteListener() {
    if let observer = routeObserver {
      NotificationCenter.default.removeObserver(observer)
      routeObserver = nil
    }
  }

  /// Logs the new route. Deliberately takes NO corrective action — see above.
  private func handleRouteChange(_ notification: Notification) {
    guard let info = notification.userInfo,
          let reasonRaw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
          let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw)
    else { return }

    switch reason {
    case .newDeviceAvailable:
      // Headphones/car connected mid-conversation. VPIO moves to them itself.
      logCurrentRoute(prefix: "Route change (device connected)")

    case .oldDeviceUnavailable:
      // Headphones/car removed mid-conversation. VPIO falls back itself.
      // We do NOT override the port here. That override was the bug.
      logCurrentRoute(prefix: "Route change (device removed)")

    case .categoryChange, .override, .routeConfigurationChange:
      logCurrentRoute(prefix: "Route change")

    default:
      break
    }
  }

  private func logCurrentRoute(prefix: String = "Route") {
    let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
    let name = outputs.first.map { routeName($0.portType) } ?? "none"
    os_log("%{public}@ -> %{public}@", log: SixPagesVoicePlugin.log, type: .info, prefix, name)
  }

  /// Names match Android's routeName() so both platforms read identically in logs.
  private func routeName(_ port: AVAudioSession.Port) -> String {
    switch port {
    case .bluetoothA2DP, .bluetoothHFP: return "bluetooth"
    case .bluetoothLE:                  return "bluetooth-le"
    case .headphones, .headsetMic:      return "wired-headphones"
    case .usbAudio:                     return "usb-headset"
    case .carAudio:                     return "car-audio"
    case .builtInSpeaker:               return "speaker"
    case .builtInReceiver:              return "earpiece"
    default:                            return port.rawValue
    }
  }

  private func startUnit() throws {
    if isRunning { return }

    let session = AVAudioSession.sharedInstance()
    do {
      // Route options, mirroring Android's priority behaviour:
      //
      //   .defaultToSpeaker  — when NOTHING is attached, use the SPEAKER, not the
      //                        earpiece. (Without this, .playAndRecord defaults to the
      //                        receiver/earpiece — the same bug just fixed on Android.)
      //
      //   HFP (hands-free)   — MANDATORY for a conversation. It is the BIDIRECTIONAL
      //                        profile: mic + speaker on the headset. Apple gives HFP
      //                        ports higher routing priority than A2DP on a device that
      //                        supports both, and — critically — a headset paired AFTER
      //                        the session goes active is only picked up reliably when
      //                        HFP is enabled. A2DP-only misses the mid-session case
      //                        entirely (no route, no notification). That IS our test.
      //                        Spelled .allowBluetooth below iOS 26, .allowBluetoothHFP
      //                        from iOS 26 (the old name was deprecated, not removed).
      //
      //   .allowBluetoothA2DP — additive, for output. Modern AirPods/BLE headsets
      //                        advertise A2DP; without it they may not be offered as an
      //                        output route. Apple explicitly permits HFP + A2DP together.
      //
      // A headset the user CHOSE always outranks the built-in speaker. iOS honours that
      // once the options permit the route: .defaultToSpeaker is the FALLBACK for the
      // no-headset case, never an override. Same contract as Android.
      var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP]
      if #available(iOS 26.0, *) {
        options.insert(.allowBluetoothHFP)
      } else {
        options.insert(.allowBluetooth)   // same bit; renamed in iOS 26
      }

      try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
      try session.setPreferredSampleRate(SixPagesVoicePlugin.targetSampleRate)
      try session.setActive(true)
    } catch {
      throw AudioError.session(error.localizedDescription)
    }

    // Follow the audio if a headset is connected or removed MID-CONVERSATION, and
    // log where it went. Android does this via AudioDeviceCallback; this is the
    // iOS twin, so the two platforms behave — and LOG — identically.
    registerRouteListener()
    logCurrentRoute()

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
    // Build 8: reset render-time max and read the mach timebase once (used to
    // convert render-callback ticks → microseconds on the audio thread).
    maxRenderMicros = 0
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    machTimebaseNumer = tb.numer
    machTimebaseDenom = tb.denom

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
    // Drop the route listener BEFORE deactivating the session, so a deactivation-
    // triggered route change cannot call back into a half-torn-down engine.
    unregisterRouteListener()
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
    let renderStart = mach_absolute_time()  // Build 8: time this callback
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
        plugin.recordRenderTime(since: renderStart) // Build 8
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
    plugin.recordRenderTime(since: renderStart) // Build 8
    return noErr
  }

  // Build 8: convert elapsed mach ticks → microseconds and keep the session max.
  // Runs on the audio thread; timebase is read once at start. Cheap arithmetic
  // only — no allocation, no locks.
  @inline(__always)
  fileprivate func recordRenderTime(since start: UInt64) {
    let elapsedTicks = mach_absolute_time() - start
    if machTimebaseDenom == 0 { return }
    let micros = Int((elapsedTicks * UInt64(machTimebaseNumer))
                     / (UInt64(machTimebaseDenom) * 1000))
    if micros > maxRenderMicros { maxRenderMicros = micros }
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
