import Flutter
import UIKit
import AVFoundation
import AudioToolbox
import os.log
import Darwin  // Build 6: OSMemoryBarrier (acquire/release fence) for the lock-free ring

// ───────────────────────────────────────────────────────────────────────────
// SixPagesVoicePlugin — iOS
//
// BUILD 13: THE ROUTE OBSERVER WAS THROWING AWAY THE ANSWER.
//
// MEASURED IN THE CAR (iPad, July 12): interruptions=0; resumeFails=0; route=speaker;
// renderCalls=758; droppedBytes=0.
//
// READ THAT CAREFULLY, IT KILLS TWO THEORIES AT ONCE:
//
//   1. THE CAR DOES NOT INTERRUPT US. interruptions=0. Build 12's theory was WRONG.
//      Keep the interruption handler — Apple requires it and it will matter for phone
//      calls and Siri — but it is NOT the car mechanism. Do not rebuild that theory.
//
//   2. THE SESSION NEVER DIES. renderCalls=758, droppedBytes=0, no teardown. What the
//      user hears as "the call dropped after 5 seconds" is NOT a drop. It is a ROUTE
//      CHANGE: iOS moves the output off the car and back to the built-in speaker while
//      the session keeps happily rendering. route=speaker. The audio is fine. It is
//      just coming out of the wrong hole.
//
// It is also NOT A2DP. The car failed to hold on a build that HAD .allowBluetoothA2DP
// and on this one that does not. A2DP is not the variable. Do not put it back.
//
// SO WHY DOES iOS MOVE THE ROUTE? We have never known — because THIS FILE HAS BEEN
// DELETING THE ANSWER. The route observer took the notification as `_` and ignored
// userInfo, which carries AVAudioSessionRouteChangeReasonKey. iOS NAMES THE CAUSE of
// every route change and we threw it away every single time, then spent nights
// guessing at what it had already told us plainly.
//
// This build captures it: routeAtStart, routeChanges, and why=[reason>destination, ...]
// go ON THE STRIP — the only iOS instrument that exists in this workflow (Windows,
// TestFlight, no Mac, no Console.app). A counter that is not on the strip does not exist.
//
// The reasons are NOT equivalent and point at completely different fixes:
//   oldDeviceUnavailable        — the CAR dropped us; the fight is with its HFP link.
//   noSuitableRouteForCategory  — .playAndRecord cannot live on that route at all.
//   categoryChange              — WE did it to ourselves.
//   override                    — someone called overrideOutputAudioPort. Should be NOBODY.
// Guessing between these has already cost this project multiple nights. Stop guessing.
//
// Diagnostic-only. No behavior change. Nothing routes, nothing overrides.
//
// ── PRIOR ──────────────────────────────────────────────────────────────────
//
// BUILD 12: INTERRUPTION HANDLING. THE CONTRACT WE NEVER IMPLEMENTED.
// (Correct and kept — but NOT the car bug. interruptions=0 in the car, measured.)
//
// Symptom: connect the iPad to a CAR over Bluetooth, the call opens and then DROPS
// about four seconds later. Android showed the same shape (see its focus commit).
//
// This file registered a route-change observer and NOTHING ELSE. It never observed
// AVAudioSession.interruptionNotification. Apple documents interruption handling as
// MANDATORY for a .playAndRecord session: on .began the OS suspends your audio unit,
// on .ended you are expected to reactivate. A car head unit negotiating HFP routinely
// fires exactly that pair within seconds of connecting. Unhandled, the OS stopped our
// unit and nobody ever restarted it — the session opened, then died. Precisely the
// reported symptom, and precisely the delay.
//
// READ THIS BEFORE CALLING IT A ROUTING CHANGE. It is not one:
//   - Route CONTROL is iOS's job. We deleted overrideOutputAudioPort (c95f26c) and
//     .allowBluetoothA2DP (Build 10) and were right both times. Hands OFF the route.
//   - Interruption RESPONSE is OUR job. Apple says so. Not implementing it is us
//     FAILING the platform's contract, not respecting it. Opposite direction, same rule.
//
// The restraint is deliberate and is the whole lesson of this repo:
//   .began  — count it, log it, do nothing. We do NOT stopUnit(): that would dispose
//             the unit and clear the 180 s ring. We want to RESUME, not restart.
//   .ended  — resume ONLY if the system grants .shouldResume. If it does not, the
//             interruptor still owns the audio session, and forcing our way back in
//             is exactly the kind of override that has broken this file before.
//             We stand down and log it.
//
// Diagnostics: interruptionCount / interruptionResumeFailures. The car drive is the
// instrument. If "Interruption BEGAN" never fires, the diagnosis was wrong and we
// look elsewhere WITH DATA instead of guessing. Unproven in a car as of this commit.
//
// ── PRIOR ──────────────────────────────────────────────────────────────────
//
// STEP B, LAYER 14 (BUILD 11): THE RING WAS TOO SMALL FOR THE TURN.
//
// THE ANSWER, after a long night of wrong theories. It is not the route listener, not
// A2DP, not the jitter buffer, not echo, not a duplicate feed. It is the oldest and
// simplest failure in this file, and this repo has now hit it THREE times:
//
//   THE RING CANNOT HOLD A WHOLE JOE TURN, SO THE END OF THE TURN IS THROWN AWAY.
//
// MEASURED (iPad, July 12, ONE tap of Talk with Claude — confirmed against the
// ElevenLabs conversation list: 1 conversation, 1m19s, 3 messages, so NO double feed):
//   droppedBytes = 645178  -> 20.2 s of Joe's audio DELETED before it ever played
//   ring         = 960000  -> 30.0 s capacity
//   960000 + 645178 = 1605178 B = 50.2 s = EXACTLY ONE JOE TURN
//   underruns=4/3117 (0.13%, healthy).  maxRenderUs=42 vs a 23000 deadline (innocent).
//   BY EAR: playback stopped DEAD mid-sentence at "It's almost like..." — precisely
//   where 30 s of buffered audio ran out. Everything after that was already discarded.
//
// ElevenLabs ships a turn FASTER THAN REALTIME. The render callback drains at speech
// rate. So a 50 s turn pours into a 30 s ring in a few seconds; the drop-NEWEST overflow
// policy discards the excess — and drop-newest means it deletes THE END OF WHAT JOE WAS
// ABOUT TO SAY. There is no backpressure: feedPlayback is fire-and-forget by design.
//
// WHY IT LOOKED LIKE A REGRESSION AND WASN'T: nothing broke. Joe's replies simply GREW
// PAST 30 SECONDS. The July 9 "perfect" conversation had shorter turns that fit. The
// droppedBytes=0 that was treated as a baseline was never captured on that conversation
// (the app was closed before reading it) — so the buffer may have been dropping all
// along, just not enough to hear.
//
// FIX: raise the ring to 180 s (5_760_000 B, 5.49 MB). NOT 60 s — the measured turn was
// already 50 s, and a 60 s ring truncates the next slightly-longer reflection. Joe is a
// REFLECTION companion; long considered replies are the PRODUCT, not an edge case.
// 5.49 MB is trivial on an iPad and is allocated once per session.
//
// EVERYTHING ELSE IS BYTE-IDENTICAL TO 7abeb0a (the last known-good build). The prime
// cushion stays 3200 B (100 ms) — it is a min() against half the ring, so growing the
// ring does not move it. The ONE other change is an OBSERVE-ONLY route listener that
// logs and steers NOTHING.
//
// ── HARD-WON RULES. READ BEFORE CHANGING ANYTHING IN THIS FILE. ──────────────
//
// 1. DIAGNOSTIC READ ORDER: droppedBytes FIRST. >0 means OVERFLOW — the ring is too
//    small and Joe's later audio is being deleted. That is a COMPLETE explanation of
//    "degrades late in long replies" and "the ending is missing." Look no further.
//
// 2. LOW UNDERRUNS + BAD AUDIO = OVERFLOW, NOT STARVATION. This signal has now been
//    misread three times. ElevenLabs OUTRUNS the drain, always. The ring's natural
//    failure is overflow. NEVER answer it with a deeper cushion or a rebuffer gate:
//    those PAUSE THE DRAIN and make overflow WORSE. (See ea45974, tried and superseded
//    by eb1be7a; then re-made as Build 9 (01fd01a), which caused droppedBytes=913270.)
//
// 3. maxRenderUs ~25-42 against a 23000 deadline means the render callback is using
//    ~0.1% of its budget and is INNOCENT. This number exists to STOP WRONG FIXES.
//
// 4. EVERY iOS FIX THAT HAS EVER WORKED HERE WAS A REMOVAL:
//      Build 4 deleted the AVAudioConverter  — VPIO already resamples internally.
//      c95f26c deleted overrideOutputAudioPort — VPIO already manages BT/car routing.
//      Build 10 deleted .allowBluetoothA2DP  — VPIO already handles Bluetooth.
//    Android's AudioManager EXPECTS the app to drive the route. iOS does NOT. Importing
//    the Android mechanism across that boundary is what caused the ae4e8e2 regression.
//
// 5. DO NOT "optimize" the ring back down. Read droppedBytes. It must be 0.
//
// UNCHANGED and CORRECT: lock-free SPSC ring, memcpy copies, VPIO 16k internal resample,
// the priming gate, the capture path, and the ENTIRE Android side.
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

  /// Live only for the duration of a session; removed in stopUnit().
  private var interruptionObserver: NSObjectProtocol?

  /// Diagnostics. Proves whether the car actually interrupted the session.
  private var interruptionCount = 0
  private var interruptionResumeFailures = 0

  /// Build 13 diagnostics: WHY did iOS move the route?
  /// The route observer has existed for weeks and has been THROWING THE ANSWER AWAY —
  /// it ignored the notification's userInfo, which carries AVAudioSessionRouteChangeReasonKey.
  /// That reason names the cause outright. It is the single most diagnostic fact in the
  /// car problem and it has never once been readable, because it only ever went to os_log.
  private var routeChangeCount = 0
  private var routeAtStart = "?"
  private var routeHistory: [String] = []   // reason>route, capped; the whole story in one field

  private static let targetSampleRate: Double = 16000.0

  // Frame contract (mirrors Android): 640 bytes = 20 ms of 16 kHz mono PCM16.
  private static let frameBytes = 640

  // Playback ring: sized to hold the LONGEST turn Joe can produce, without overflow.
  //
  // ElevenLabs synthesizes a whole turn in a few seconds and streams it to us FASTER
  // THAN REALTIME. The render callback drains at natural speech rate (~1 s of audio per
  // 1 s). So the ring must hold an ENTIRE turn — whatever arrives beyond its capacity is
  // discarded by the drop-newest overflow policy, which silently deletes the END of what
  // Joe was about to say. There is no backpressure to fall back on: feedPlayback is
  // fire-and-forget across the method channel, by design.
  //
  // SIZING HISTORY — this has now been raised THREE times, and each time the reason was
  // the same: a real reply outgrew the ring.
  //   Build 5  (eb1be7a):  15 s (480000 B)  — "sentences piling on top of each other"
  //   Build 7  (b99678b):  30 s (960000 B)  — "starts great, stumbles mid/late"
  //   Build 11 (this):    180 s (5760000 B) — playback died mid-sentence at ~30 s
  //
  // MEASURED, July 12 (iPad, one turn, ONE tap — verified against the ElevenLabs
  // conversation list, so no duplicate feed):
  //   renderCalls=3117 (~73 s session); droppedBytes=645178 (20.2 s of audio DELETED);
  //   underruns=4 (0.13% — healthy); maxRenderUs=42 (deadline 23000 — callback innocent).
  //   960000 (held) + 645178 (dropped) = 1605178 B = 50.2 s — EXACTLY one Joe turn.
  //   By ear: playback stopped dead mid-sentence at "It's almost like..." — the point
  //   where 30 s of buffered audio ran out. Everything after it was already discarded.
  //
  // WHY 180 s AND NOT 60 s: the measured turn was already 50 s. A 60 s ring passes that
  // test with 10 s to spare and truncates the next slightly-longer reflection. Joe is a
  // REFLECTION companion — long, considered replies are the PRODUCT, not an edge case.
  // 5.49 MB is trivial on an iPad and is allocated ONCE per session, not per turn. This
  // is a place where "too big" costs nothing and "too small" costs a lost conversation.
  //
  // DO NOT "optimize" this back down. Read droppedBytes instead: it must be 0.
  private static let playbackBufferBytes = 5_760_000   // 180 s of 16 kHz mono PCM16
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
      // Build 12: interruptions + live route. The STRIP IS THE ONLY iOS INSTRUMENT.
      // os_log is unreadable in this workflow (Windows + TestFlight, no Mac), so a
      // counter that is not on this line does not exist. The car-drop diagnosis
      // lives or dies on interruptions= — if the car never interrupts us, the
      // theory is wrong and we look elsewhere WITH DATA. route= is here because
      // the very next question after that is "what did iOS actually pick."
      let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
      let liveRoute = outputs.first.map { routeName($0.portType) } ?? "none"
      let live = "renderCalls=\(renderCalls); underruns=\(underrunEvents); "
        + "lastReqBytes=\(lastRenderBytesRequested); lastInputFrames=\(lastInputFrames); "
        + "primed=\(primed); reprimes=\(reprimeEvents); primeThresh=\(primeThresholdBytes)B; "
        + "droppedBytes=\(playback.droppedBytes); maxRenderUs=\(maxRenderMicros); "
        + "interruptions=\(interruptionCount); resumeFails=\(interruptionResumeFailures); "
        + "routeAtStart=\(routeAtStart); route=\(liveRoute); "
        + "routeChanges=\(routeChangeCount); why=[\(routeHistory.joined(separator: " | "))]"
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

  // MARK: - Audio route (OBSERVE-ONLY)
  //
  // This listener REPORTS where audio went. It does NOT steer. Ever.
  //
  // Apple's documented contract, three points, each sufficient alone:
  //   1. "Apps should treat these changes as authoritative. They should NEVER
  //      immediately attempt to revert the change."
  //   2. The notification is POSTED ON A SECONDARY THREAD — acting on it touches
  //      session state at an unpredictable moment relative to the running unit.
  //   3. DECISIVE: with kAudioUnitSubType_VoiceProcessingIO, "the system will
  //      automatically manage this for the application. In particular, ports of
  //      type AVAudioSessionPortBluetoothHFP and AVAudioSessionPortCarAudio."
  //      VPIO ALREADY handles Bluetooth and car routing. There is nothing to fix.
  //
  // A previous build (ae4e8e2) called overrideOutputAudioPort(.speaker) from inside
  // this listener. It caused the long-reply chop and the car drop. DO NOT RE-ADD IT.
  //
  // NOTE the asymmetry with Android, and that it is CORRECT: Android's AudioManager
  // DOES expect the app to select the device, and there we re-assert deliberately.
  // iOS does not. Importing the Android mechanism across that boundary was the bug.
  // Symmetry in the LOGS is good. Symmetry in the MECHANISM is not.

  /// Build 13: iOS names the cause of every route change. Decode it.
  ///
  ///   oldDeviceUnavailable  — the car/headset WENT AWAY. iOS had no choice.
  ///   override              — SOMEONE called overrideOutputAudioPort. Should be nobody: we deleted it.
  ///   categoryChange        — the session category/options were changed mid-flight.
  ///   routeConfigChange     — the route's configuration changed underneath us.
  ///   newDeviceAvailable    — something new appeared and iOS preferred it.
  ///   noSuitableRouteForCategory — .playAndRecord could not be satisfied by the current device.
  ///
  /// For the car, these are NOT equivalent and they point at completely different fixes.
  /// oldDeviceUnavailable means the CAR dropped us and the fight is with the car's HFP link.
  /// noSuitableRouteForCategory means .playAndRecord cannot live on that route at all.
  /// categoryChange means WE did it to ourselves. Guessing between these has cost us nights.
  private func routeChangeReasonName(_ raw: UInt) -> String {
    guard let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return "unknown(\(raw))" }
    switch reason {
    case .unknown:                    return "unknown"
    case .newDeviceAvailable:         return "newDeviceAvailable"
    case .oldDeviceUnavailable:       return "oldDeviceUnavailable"
    case .categoryChange:             return "categoryChange"
    case .override:                   return "override"
    case .wakeFromSleep:              return "wakeFromSleep"
    case .noSuitableRouteForCategory: return "noSuitableRouteForCategory"
    case .routeConfigurationChange:   return "routeConfigChange"
    @unknown default:                 return "unhandled(\(raw))"
    }
  }

  private func registerRouteListener() {
    guard routeObserver == nil else { return }
    routeObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { [weak self] note in
      guard let self = self else { return }
      self.routeChangeCount += 1

      // THE LINE THAT WAS MISSING. The old observer took `_` and discarded userInfo,
      // throwing away the reason on every single route change since this file was written.
      //
      // Read it as NSNumber, which is the DOCUMENTED type in the header:
      //   "value is an NSNumber representing an AVAudioSessionRouteChangeReason"
      // `as? UInt` is the common idiom and does work, but NSNumber->uintValue is the
      // type Apple actually promises. A diagnostic that silently reports the WRONG
      // reason is worse than none at all: this strip gets read once, in a car, after
      // a drive. It does not get a second chance. No fallback sentinel, no ambiguity.
      let reason: String
      if let num = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber {
        reason = self.routeChangeReasonName(UInt(num.uintValue))
      } else {
        // Should be impossible. If this EVER appears on the strip, the notification
        // shape changed and nothing below it can be trusted.
        reason = "NO-REASON-KEY"
      }

      let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
      let now = outputs.first.map { self.routeName($0.portType) } ?? "none"

      // Compact, strip-readable trail: reason>destination, oldest first.
      // Capped so a long drive cannot push the rest of the strip off screen.
      if self.routeHistory.count < 6 {
        self.routeHistory.append("\(reason)>\(now)")
      }

      os_log("Route change #%d: reason=%{public}@ -> %{public}@",
             log: SixPagesVoicePlugin.log, type: .info,
             self.routeChangeCount, reason, now)
    }
  }

  private func unregisterRouteListener() {
    if let observer = routeObserver {
      NotificationCenter.default.removeObserver(observer)
      routeObserver = nil
    }
  }

  // MARK: - Interruption handling (REQUIRED by Apple for .playAndRecord)
  //
  // This is NOT a routing override and does not violate the hands-off rule above.
  // Route CONTROL is iOS's job — we deleted overrideOutputAudioPort and were right to.
  // Interruption RESPONSE is OUR job, and Apple documents it as mandatory:
  //
  //   "Your app must respond to an interruption [...] and, when the interruption ends,
  //    reactivate the audio session."   — AVAudioSession: Handling Audio Interruptions
  //
  // We never implemented it. That is a contract we OWE the platform, not one we are
  // imposing on it. Every phone call, Siri invocation, alarm — and the reason we
  // found this, every CAR BLUETOOTH CONNECT — can interrupt a .playAndRecord session.
  // A car head unit negotiating HFP commonly fires .began then .ended within seconds
  // of connecting. Unhandled, the OS suspends our AudioUnit and NOBODY restarts it.
  // The session "opens, then dies four seconds later." That is the exact symptom.
  //
  //   .began — the OS has ALREADY stopped the unit. Do not fight it. Count it, wait.
  //            We deliberately do NOT call stopUnit(): that would dispose the unit and
  //            clear the ring. We want to RESUME, not restart from nothing.
  //   .ended — reactivate and restart the unit, but ONLY if the system grants
  //            .shouldResume. If it does not, the interruptor still owns audio and
  //            forcing our way back in is exactly the kind of override that has
  //            broken this plugin before. We stand down and log it.
  private func registerInterruptionListener() {
    guard interruptionObserver == nil else { return }
    interruptionObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { [weak self] note in
      self?.handleInterruption(note)
    }
  }

  private func unregisterInterruptionListener() {
    if let observer = interruptionObserver {
      NotificationCenter.default.removeObserver(observer)
      interruptionObserver = nil
    }
  }

  private func handleInterruption(_ note: Notification) {
    // NSNumber is the documented type here too. Same reasoning as the route observer:
    // interruptions=0 must mean "the car did not interrupt us", NEVER "the cast failed
    // and we silently returned." That number was used to KILL a theory. It has to be real.
    guard
      let info = note.userInfo,
      let num = info[AVAudioSessionInterruptionTypeKey] as? NSNumber,
      let type = AVAudioSession.InterruptionType(rawValue: UInt(num.uintValue))
    else {
      os_log("Interruption notification with NO TYPE KEY — notification shape changed",
             log: SixPagesVoicePlugin.log, type: .error)
      return
    }

    switch type {
    case .began:
      interruptionCount += 1
      os_log("Interruption BEGAN (count=%d) - OS has suspended the audio unit",
             log: SixPagesVoicePlugin.log, type: .info, interruptionCount)

    case .ended:
      var shouldResume = false
      if let optsNum = info[AVAudioSessionInterruptionOptionKey] as? NSNumber {
        shouldResume = AVAudioSession.InterruptionOptions(rawValue: UInt(optsNum.uintValue))
          .contains(.shouldResume)
      }
      os_log("Interruption ENDED (shouldResume=%{public}@)",
             log: SixPagesVoicePlugin.log, type: .info, shouldResume ? "true" : "false")

      guard shouldResume else {
        interruptionResumeFailures += 1
        os_log("Interruption ENDED without shouldResume - standing down (failures=%d)",
               log: SixPagesVoicePlugin.log, type: .info, interruptionResumeFailures)
        return
      }
      guard isRunning else {
        os_log("Interruption ENDED but no session is running - nothing to resume",
               log: SixPagesVoicePlugin.log, type: .info)
        return
      }

      do {
        try AVAudioSession.sharedInstance().setActive(true)
        if let unit = ioUnit {
          let status = AudioOutputUnitStart(unit)
          if status == noErr {
            // The ring survived; the unit did not. Re-prime so playback does not
            // resume into a half-empty buffer and immediately underrun.
            primed = false
            os_log("Interruption resume OK - unit restarted, re-priming",
                   log: SixPagesVoicePlugin.log, type: .info)
          } else {
            interruptionResumeFailures += 1
            os_log("Interruption resume FAILED - AudioOutputUnitStart status=%d",
                   log: SixPagesVoicePlugin.log, type: .error, Int(status))
          }
        }
      } catch {
        interruptionResumeFailures += 1
        os_log("Interruption resume FAILED - setActive threw: %{public}@",
               log: SixPagesVoicePlugin.log, type: .error, error.localizedDescription)
      }
      logCurrentRoute(prefix: "Route after interruption")

    @unknown default:
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
      try session.setCategory(.playAndRecord, mode: .voiceChat,
                              options: [.defaultToSpeaker, .allowBluetooth])
      try session.setPreferredSampleRate(SixPagesVoicePlugin.targetSampleRate)
      try session.setActive(true)
    } catch {
      throw AudioError.session(error.localizedDescription)
    }

    // Observe-only: report the route, steer nothing. See the comment block above.
    registerRouteListener()
    // Apple REQUIRES this for .playAndRecord. Its absence is the car-drop suspect.
    registerInterruptionListener()
    interruptionCount = 0
    interruptionResumeFailures = 0
    routeChangeCount = 0
    routeHistory = []
    // Where did we BEGIN? route= on the strip is post-hoc and only says where we ENDED.
    // Without this, "route=speaker" cannot distinguish "never got the car" from
    // "got the car and lost it" — two different bugs.
    let startOutputs = session.currentRoute.outputs
    routeAtStart = startOutputs.first.map { routeName($0.portType) } ?? "none"
    logCurrentRoute(prefix: "Route at start")

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
    unregisterInterruptionListener()
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
