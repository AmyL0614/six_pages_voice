import Flutter
import UIKit
import AVFoundation
import AudioToolbox
import os.log
import Darwin  // Build 6: OSMemoryBarrier (acquire/release fence) for the lock-free ring

// ───────────────────────────────────────────────────────────────────────────
// SixPagesVoicePlugin — iOS
//
// STEP B, LAYER 13 (BUILD 9): PROPER JITTER BUFFER (deep cushion + hysteresis).
//
// BUILD 8 ANSWERED ITS OWN QUESTION. On-device (iPad), long reply, chop at the tail:
//   maxRenderUs=25   (deadline is 23000 µs — the callback is idle-fast)
//   droppedBytes=0   (the ring never overflowed)
//   underruns=4 / renderCalls=2607  (0.15% — HEALTHY, in line with Build 7's 0.11%)
//   reprimes=2       ← THE BUG
//
// Build 8's own decision rule: "if maxRenderUs is small AND it still broke up → the
// callback is fine, the problem is UPSTREAM (socket/feed)." maxRenderUs=25 is the
// small case. The copy was never the cause; memcpy was right but not the fix.
//
// NOTE what the numbers say and don't say. The underrun RATE is fine — 0.15% is a
// healthy stream, and the feed is NOT degrading. There is no upstream regression to
// chase. The chop is not caused by starvation being frequent. It is caused by our
// RESPONSE to starvation being catastrophic.
//
// ROOT CAUSE — the re-prime was AMPLIFYING jitter instead of absorbing it.
// The old render callback did this on a full drain:
//     if provided == 0 { primed = false; reprimeEvents += 1 }
// Flipping `primed` to false sends the callback back to the startup gate, which then
// emits HARD SILENCE until the ring rebuilds the ENTIRE 3200 B cushion. That is a
// mandatory ~100 ms mute — imposed on top of the original gap, and imposed even if
// Joe's audio is already flowing again on the very next callback.
//
// So ONE late chunk cost 100 ms of silence. reprimes=2 = TWO enforced 100 ms mutes
// inside a single long reply. THAT is the chop. Long replies hit it because every extra
// second of Joe talking is another chance to catch one hiccup — and every hiccup was
// charged the full penalty. Short replies never drained, so they never tripped it.
//
// This is why a 0.15% underrun rate was still audible: a rare, NORMAL event was being
// converted into a 100 ms cut. The stream is healthy. The buffer logic was not.
//
// WORKING WITH THE PLATFORM, NOT AGAINST IT:
//   • ElevenLabs documents that agent audio ARRIVES IN CHUNKS with variable timing, and
//     explicitly instructs the client to "implement a jitter buffer to smooth out
//     variations in packet arrival times" and to use "adaptive buffering." Burstiness is
//     their DESIGN, not a fault. The old code treated normal chunk variance as a fault
//     condition and responded by muting. That is fighting the contract.
//   • A jitter buffer ABSORBS a gap. It does not answer a gap by adding more silence.
//
// THE FIX — a real jitter buffer, the way a production streaming player does it. It
// distinguishes the two events the old code conflated:
//
//   ONE LATE CHUNK (transient)  → zero-fill ONLY the missing bytes and KEEP PLAYING.
//     Stay primed. The instant more audio lands, it plays. No added silence, no mute.
//
//   A SUSTAINED STALL (real)    → after `drainsBeforeRebuffer` CONSECUTIVE fully-empty
//     callbacks — not one blip — drop back to buffering and rebuild only a SHALLOW
//     cushion (rebufferThresholdBytes ≈ 40 ms), NOT the full startup cushion. Machine-
//     gunning ticks through a genuine network stall is worse than a short rebuffer;
//     paying the full 100 ms startup cost for a transient is worse than either.
//
// The old code was a BROKEN version of this: it rebuffered on a SINGLE drain, and it
// rebuffered to the FULL startup cushion. Worst of both. Same instinct, wrong numbers.
//
//   STARTUP cushion : 400 ms (was 100 ms). The ring is 30 s (960000 B) — there is
//     enormous headroom, and the classic guard against underrun is simply a deeper
//     buffer. 400 ms of added latency before Joe's first word is imperceptible in a
//     reflective conversation, and it lets the ring ride out ordinary jitter without
//     ever draining. 100 ms was only ~4.35 render calls deep — far too thin to absorb
//     a network that delivers in bursts.
//   REBUFFER cushion: 40 ms. Enough to get ahead of the drain again, small enough that
//     a real stall recovers fast.
//
// NOT CHANGED, deliberately: the lock-free SPSC ring (correct), memcpy copies (correct),
// the 30 s ring size (correct — droppedBytes=0 proves it), VPIO 16k internal resample
// (correct — 736 B/368 frames = 23.0 ms MATCHES ioBuf=0.0233 s, so the ring units are
// right), the observe-only route listener from c95f26c (correct, and a different bug),
// and the ENTIRE Android path (proven; untouched). The Dart method-channel surface is
// unchanged, so FlutterFlow needs nothing new.
//
// Diagnostic counters are KEPT and EXTENDED (maxConsecutiveDrains, rebufferThresh).
// They are the only reason this was findable, and they are how the next test is read.
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

  // Build 9 (Layer 13): JITTER BUFFER STATE.
  //
  // `primed` gates the render callback: while false it emits silence (NOT counted as
  // an underrun — buffering is not starving) until the ring holds enough bytes.
  //
  // TWO DIFFERENT CUSHIONS, because startup and mid-stream recovery are different
  // problems (the old code wrongly used one number for both):
  //   • primeThresholdBytes    — the STARTUP cushion (~400 ms). Deep, because we get
  //     to pay this latency exactly once, before Joe's first word, and it buys us the
  //     headroom to ride out bursty delivery for the rest of the turn.
  //   • rebufferThresholdBytes — the MID-STREAM cushion (~40 ms). Shallow, because a
  //     stall already cost the listener silence; making them wait another 400 ms to
  //     recover would be worse than the stall.
  //
  // HYSTERESIS: `consecutiveDrains` counts fully-empty callbacks IN A ROW. A single
  // empty callback is one late chunk — we zero-fill it and keep playing. Only when
  // drainsBeforeRebuffer empties land BACK TO BACK do we conclude the stream has
  // genuinely stalled and drop into rebuffering. This is the whole difference between
  // absorbing jitter and amplifying it.
  fileprivate var primed = false
  fileprivate var primeThresholdBytes = 0      // startup cushion  (~400 ms), set in startUnit
  fileprivate var rebufferThresholdBytes = 0   // mid-stream cushion (~40 ms), set in startUnit
  fileprivate var reprimeEvents = 0            // times a SUSTAINED stall forced a rebuffer

  /// Fully-empty render callbacks seen back-to-back. Reset to 0 the moment ANY audio
  /// is provided. Audio-thread only.
  fileprivate var consecutiveDrains = 0

  /// True once the FIRST real audio byte has been rendered this session. This — not
  /// consecutiveDrains — is what distinguishes "startup" from "recovery" at the gate.
  ///
  /// Using consecutiveDrains for that decision is subtly WRONG: on recovery the gate
  /// clears the streak, so if the stream stalls again immediately the streak restarts
  /// from 0 and the gate would mistake a mid-conversation stall for a fresh start —
  /// demanding the full 400 ms cushion and muting Joe mid-sentence. That is the exact
  /// class of bug we are removing, so it must not be reintroduced here.
  ///
  /// Once playback has begun, EVERY subsequent gate entry is a recovery and takes the
  /// shallow cushion. Only the genuine session start takes the deep one.
  fileprivate var hasStartedPlayback = false

  /// How many consecutive fully-empty callbacks constitute a real stall rather than one
  /// late chunk. At ~23 ms per callback, 3 ≈ 70 ms of genuinely nothing arriving — well
  /// past normal chunk variance, and still fast enough to react before it sounds broken.
  fileprivate static let drainsBeforeRebuffer = 3

  /// Diagnostic: the worst back-to-back drain streak this session. If this stays at 1–2,
  /// the stream only ever hiccups and the hysteresis is doing its job (we never rebuffer).
  /// If it climbs, the feed is genuinely stalling and the problem is upstream.
  fileprivate var maxConsecutiveDrains = 0

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
      // Build 9: maxDrainStreak is now the KEY number. underruns alone no longer imply a
      // chop — a short read is absorbed silently by design, and a LOW underrun rate never
      // meant the audio was clean (Build 8 measured a healthy 0.15% and still chopped,
      // because the RESPONSE to those few underruns was a 100 ms mute).
      //
      // What matters is whether the stream ever went BACK-TO-BACK empty:
      //   maxDrainStreak 1–2 → only ever a late chunk; hysteresis absorbed it; reprimes
      //                        should be 0 and the audio should be clean.
      //   maxDrainStreak ≥3  → the feed genuinely stalled and we rebuffered. If this is
      //                        high, the problem is UPSTREAM (voiceAdapter / WebSocket /
      //                        feedPlayback cadence), not the buffer.
      let live = "renderCalls=\(renderCalls); underruns=\(underrunEvents); "
        + "lastReqBytes=\(lastRenderBytesRequested); lastInputFrames=\(lastInputFrames); "
        + "primed=\(primed); reprimes=\(reprimeEvents); "
        + "primeThresh=\(primeThresholdBytes)B; rebufThresh=\(rebufferThresholdBytes)B; "
        + "maxDrainStreak=\(maxConsecutiveDrains); "
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

    // ── Build 9: compute BOTH jitter-buffer cushions. Playback bytes are 16 kHz mono
    // PCM16 (the render callback consumes 16 kHz bytes; VPIO resamples downstream), so
    // bytes = 16000 * 2 * seconds. Confirmed on-device: lastReqBytes=736 over
    // lastInputFrames=368 = 2 B/frame, and 368 frames @ 16 kHz = 23.0 ms, which matches
    // the reported ioBuf of 0.0233 s. The ring units are correct.
    //
    // STARTUP = 400 ms (was 100 ms). 100 ms was only ~4.35 render calls deep — far too
    // thin for a feed that ElevenLabs delivers in bursts. The ring is 30 s, so the
    // headroom is free; the only cost is 400 ms before Joe's first word, paid once, and
    // inaudible in a reflective conversation. A deeper buffer is the classic and correct
    // guard against underrun.
    //
    // REBUFFER = 40 ms. Only used after a SUSTAINED stall (see the render callback).
    // Deliberately shallow: recovery should be fast, because the listener has already
    // been made to wait once.
    let startupCushion  = Int(SixPagesVoicePlugin.targetSampleRate * 2.0 * 0.400)
    let rebufferCushion = Int(SixPagesVoicePlugin.targetSampleRate * 2.0 * 0.040)
    primeThresholdBytes    = min(startupCushion,  SixPagesVoicePlugin.playbackBufferBytes / 2)
    rebufferThresholdBytes = min(rebufferCushion, SixPagesVoicePlugin.playbackBufferBytes / 2)
    primed = false
    hasStartedPlayback = false
    reprimeEvents = 0
    consecutiveDrains = 0
    maxConsecutiveDrains = 0
    os_log("Build9: startup cushion = %d B (≈400 ms); rebuffer cushion = %d B (≈40 ms); hw %{public}.0f Hz",
           log: SixPagesVoicePlugin.log, type: .info,
           primeThresholdBytes, rebufferThresholdBytes, hwRate)

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
    // Build 9: reset the jitter-buffer state so a fresh session primes cleanly.
    // consecutiveDrains MUST be cleared here. The gate picks its cushion by asking
    // "did I get here from a mid-stream stall?" (consecutiveDrains > 0). If a session
    // ended while draining and we left it nonzero, the NEXT session's startup would
    // read as a recovery and prime to the shallow 40 ms cushion instead of the deep
    // 400 ms one — silently reintroducing exactly the thin buffer we just fixed.
    primed = false
    hasStartedPlayback = false
    consecutiveDrains = 0
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

    // Build 9: BUFFERING GATE. While not primed, emit clean silence and return WITHOUT
    // counting an underrun — deliberate buffering is not starving.
    //
    // The gate is used in two situations, and they want DIFFERENT depths:
    //   • startup  → primeThresholdBytes    (~400 ms, deep — paid once, buys headroom)
    //   • recovery → rebufferThresholdBytes (~40 ms, shallow — the listener already waited)
    //
    // hasStartedPlayback — NOT consecutiveDrains — is the correct discriminator. The
    // gate clears the drain streak on recovery, so a stall that resumes immediately would
    // present with streak==0 and be misread as a fresh start, demanding the full 400 ms
    // and muting Joe mid-sentence. Once ANY audio has played this session, every later
    // gate entry is a recovery.
    if !plugin.primed {
      let needed = plugin.hasStartedPlayback
        ? plugin.rebufferThresholdBytes
        : plugin.primeThresholdBytes

      if plugin.playback.count >= needed {
        plugin.primed = true
        plugin.consecutiveDrains = 0   // recovered; back to normal playback
        // fall through to normal read
      } else {
        for buffer in buffers {
          if let mData = buffer.mData {
            memset(mData, 0, Int(buffer.mDataByteSize))
          }
        }
        ioActionFlags.pointee.insert(.unitRenderAction_OutputIsSilence)
        plugin.recordRenderTime(since: renderStart)
        return noErr
      }
    }

    for buffer in buffers {
      guard let mData = buffer.mData else { continue }
      let bytesRequested = Int(buffer.mDataByteSize)
      plugin.lastRenderBytesRequested = bytesRequested
      let provided = plugin.playback.read(into: mData, count: bytesRequested)

      if provided < bytesRequested {
        // Short read. Zero-fill ONLY the shortfall and keep going. This is the jitter
        // buffer absorbing a gap — we do NOT answer a gap by adding more silence.
        plugin.underrunEvents &+= 1
        memset(mData.advanced(by: provided), 0, bytesRequested - provided)
      }

      if provided == 0 && bytesRequested > 0 {
        // FULLY empty callback. On its own this is just ONE late chunk — the old code's
        // mistake was treating it as a stall and muting for a full 100 ms cushion.
        // Count it and keep playing; only a RUN of these means the stream really stalled.
        plugin.consecutiveDrains &+= 1
        if plugin.consecutiveDrains > plugin.maxConsecutiveDrains {
          plugin.maxConsecutiveDrains = plugin.consecutiveDrains
        }
        if plugin.consecutiveDrains >= SixPagesVoicePlugin.drainsBeforeRebuffer {
          // Sustained stall confirmed (~70 ms of nothing arriving). Drop into rebuffering
          // so we recover cleanly instead of machine-gunning ticks — but rebuild only the
          // SHALLOW 40 ms cushion, never the 400 ms startup one.
          plugin.primed = false
          plugin.reprimeEvents &+= 1
        }
      } else if provided > 0 {
        // Real audio went out. The hiccup (if any) is over — reset the streak, and mark
        // that playback has begun so every future gate entry takes the SHALLOW cushion.
        plugin.consecutiveDrains = 0
        plugin.hasStartedPlayback = true
      }
    }
    plugin.recordRenderTime(since: renderStart)
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
