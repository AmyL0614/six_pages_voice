package com.sixpages.six_pages_voice

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/**
 * SixPagesVoicePlugin — CAPTURE + PLAYBACK + SPEAKER ROUTING + WebRTC AEC3.
 *
 * Owns mic capture and Joe's playback through the OS voice-communication path.
 * Echo cancellation is done by WebRTC's AEC3 (software), via the native shim
 * (libsix_pages_voice_aec3.so), NOT by the Android hardware AcousticEchoCanceler
 * — that hardware unit reported enabled=true on the SM-S928U but did not
 * actually cancel (proven by ElevenLabs transcripts). AEC3 needs BOTH sides:
 *   - the render reference: Joe's playback PCM, fed via nativeProcessRender()
 *     BEFORE it is written to the AudioTrack (feedPlayback()).
 *   - the capture stream: the mic PCM, cleaned in place via nativeProcessCapture()
 *     on the capture thread BEFORE each frame is posted to Dart.
 * Without the render reference, AEC3 has nothing to subtract and cannot cancel.
 *
 * Frame contract: PCM16 / 16 kHz / mono, 640-byte (20 ms) frames. The shim
 * splits each 20 ms frame into two 10 ms halves internally (AEC3 processes 10 ms
 * chunks); that is invisible here.
 *
 * Contract:
 *   MethodChannel  six_pages_voice/control  — start() -> Bool, stop(), feedPlayback(Uint8List)
 *   EventChannel   six_pages_voice/capture  — streams clean PCM16 / 16 kHz / mono frames
 */
class SixPagesVoicePlugin :
    FlutterPlugin,
    MethodCallHandler,
    EventChannel.StreamHandler {

    private val tag = "SixPagesVoice"

    // --- Native AEC3 bridge -------------------------------------------------
    //
    // These are INSTANCE external functions (the JNI symbols in aec3_shim.cpp
    // take jobject thiz, i.e. Java_..._SixPagesVoicePlugin_nativeCreate(env, thiz,
    // ...)). They must NOT live in the companion object, or the generated symbol
    // names would be ..._Companion_native... and fail to bind.
    private external fun nativeCreate(): Long
    private external fun nativeSetStreamDelayMs(handle: Long, delayMs: Int)
    private external fun nativeProcessRender(handle: Long, frame: ByteArray)
    private external fun nativeProcessCapture(handle: Long, frame: ByteArray)
    private external fun nativeDestroy(handle: Long)

    companion object {
        init {
            System.loadLibrary("six_pages_voice_aec3")
        }
    }

    // AEC3 engine handle (opaque native pointer). 0 == no engine.
    @Volatile private var aecHandle: Long = 0L
    // Guards create/destroy against feedPlayback's render calls. The capture
    // thread is fenced separately by the join() in stopCapture(), so the only
    // cross-thread race left is feedPlayback (render) vs stopCapture (destroy).
    private val aecLock = Any()

    private lateinit var controlChannel: MethodChannel
    private lateinit var captureChannel: EventChannel
    private var appContext: Context? = null

    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    private var audioRecord: AudioRecord? = null
    private var captureThread: Thread? = null
    @Volatile private var capturing = false

    private var audioTrack: AudioTrack? = null

    private var savedAudioMode = AudioManager.MODE_NORMAL

    // Live only for the duration of a session; nulled in clearSpeakerRoute().
    private var routeListener: AudioDeviceCallback? = null

    // --- AEC3 render->capture delay, MEASURED (not guessed) --------------
    //
    // AEC3 needs the delay between handing Joe's frame to ProcessReverseStream
    // and the echo of that frame being captured by the mic. Guessing this
    // (Step A: fixed 120 ms) only half-worked. Here we MEASURE it from the
    // AudioTrack's own playback clock:
    //
    //   output_latency = (frames_written - frames_actually_presented) / rate
    //
    // getTimestamp() gives frames_actually_presented + the time it happened.
    // The gap to what we've written is the audio still in the pipeline = the
    // real output latency. We add a small input-side latency for the mic path
    // and feed the sum to set_stream_delay_ms every capture frame.
    //
    // getTimestamp() returns nothing during a warm-up window (documented as up
    // to a few seconds). During that window we fall back to a delay computed
    // from the AudioTrack's ACTUAL buffer size (read at runtime, not assumed).

    // Total PCM frames handed to the AudioTrack. Updated in feedPlayback under
    // playbackLock; read by the capture thread's delay computation.
    @Volatile private var framesWritten: Long = 0
    private val playbackLock = Any()

    // The AudioTrack's real buffer size in frames, read at create time. Drives
    // the warm-up fallback delay. 0 until playback starts.
    @Volatile private var trackBufferFrames: Int = 0

    // Mic input-side latency estimate (ms). The capture path (AudioRecord ->
    // our read -> ProcessStream) adds a small, roughly fixed delay on top of
    // the output latency. 10 ms is a conservative typical value for the
    // VOICE_COMMUNICATION input path; it is a minor additive term, not the
    // dominant one (output latency dominates).
    private val inputLatencyMs = 10

    // Clamp the computed delay to a sane band so a bad timestamp reading can
    // never feed AEC3 a wild value. AEC3 handles up to a few hundred ms.
    private val minDelayMs = 0
    private val maxDelayMs = 500

    // Reusable timestamp object (avoid per-frame allocation on the hot path).
    private val playbackTimestamp = android.media.AudioTimestamp()

    // Audio format — the contract: PCM16, 16 kHz, mono.
    private val sampleRate = 16000
    private val inChannelConfig = AudioFormat.CHANNEL_IN_MONO
    private val outChannelConfig = AudioFormat.CHANNEL_OUT_MONO
    private val audioFormat = AudioFormat.ENCODING_PCM_16BIT

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        controlChannel = MethodChannel(binding.binaryMessenger, "six_pages_voice/control")
        controlChannel.setMethodCallHandler(this)

        captureChannel = EventChannel(binding.binaryMessenger, "six_pages_voice/capture")
        captureChannel.setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "start" -> {
                val ok = startEngine()
                result.success(ok)
            }
            "stop" -> {
                stopEngine()
                result.success(null)
            }
            "feedPlayback" -> {
                val pcm = call.arguments as? ByteArray
                if (pcm != null) {
                    // Feed Joe's playback to AEC3 as the far-end reference
                    // BEFORE it hits the speaker, then play it. Order matters:
                    // AEC3 must see the reference at least as early as the echo
                    // arrives at the mic. Held under aecLock so a concurrent
                    // stop()/destroy cannot free the handle mid-call.
                    synchronized(aecLock) {
                        val h = aecHandle
                        if (h != 0L) {
                            nativeProcessRender(h, pcm)
                        }
                    }
                    // Write to the speaker and account the frames so the delay
                    // measurement knows how much audio we've committed. PCM16
                    // mono => 2 bytes per frame.
                    synchronized(playbackLock) {
                        audioTrack?.write(pcm, 0, pcm.size)
                        framesWritten += (pcm.size / 2).toLong()
                    }
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // --- EventChannel.StreamHandler: Dart subscribing to /capture ---

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    // --- Engine ---

    private fun startEngine(): Boolean {
        // Foreground service FIRST. It must be running before capture begins, or
        // Android 14+ will mute the mic the moment the app backgrounds. It also
        // holds the partial wakelock that keeps the CPU alive with the screen off.
        appContext?.let { VoiceSessionService.start(it) }

        routeToSpeaker()
        val playbackOk = startPlayback()
        if (!playbackOk) {
            clearSpeakerRoute()
            appContext?.let { VoiceSessionService.stop(it) }
            return false
        }
        val captureOk = startCapture()
        if (!captureOk) {
            stopPlayback()
            clearSpeakerRoute()
            appContext?.let { VoiceSessionService.stop(it) }
            return false
        }

        // RE-ASSERT the route now that BOTH streams are live. Starting an audio
        // session in MODE_IN_COMMUNICATION can silently clobber the route we set
        // above and drop us back to the earpiece. Setting it last makes us the
        // final word, and closes the intermittent "sometimes earpiece" race.
        selectBestRoute()
        return true
    }

    private fun stopEngine() {
        stopCapture()
        stopPlayback()
        clearSpeakerRoute()
        // Last: tears down the notification and releases the wakelock.
        appContext?.let { VoiceSessionService.stop(it) }
    }

    // --- Speaker routing ---

    private fun audioManager(): AudioManager? {
        return appContext?.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
    }

    // Preference order. A headset the user CHOSE (paired or plugged in) always
    // wins over the built-in speaker. Speaker is the FALLBACK, not an override:
    // forcing TYPE_BUILTIN_SPEAKER unconditionally would yank audio away from
    // someone's AirPods or car and broadcast Joe out loud — the exact opposite
    // of what a private companion conversation needs.
    private val routePreference = intArrayOf(
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        AudioDeviceInfo.TYPE_BLE_HEADSET,
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_USB_HEADSET,
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER  // default when nothing is attached
    )

    // Enters communication mode ONCE per session and selects the best route.
    private fun routeToSpeaker() {
        val am = audioManager() ?: return
        savedAudioMode = am.mode
        am.mode = AudioManager.MODE_IN_COMMUNICATION
        selectBestRoute()
        registerRouteListener()
    }

    /**
     * Picks the highest-priority available communication device and selects it.
     *
     * Called (a) at session start, (b) AGAIN after the AudioTrack and AudioRecord
     * are live, and (c) whenever devices are added/removed mid-session.
     *
     * The re-assert in (b) is deliberate. setCommunicationDevice() can be silently
     * clobbered when a new audio session starts in MODE_IN_COMMUNICATION — the
     * framework re-evaluates and can fall back to the EARPIECE. That race is
     * boot/state-dependent, which is why routing "worked one session, not the next"
     * with no code change. Setting the route LAST makes us the final word.
     */
    private fun selectBestRoute() {
        val am = audioManager() ?: return

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val available = am.availableCommunicationDevices

            // Explicit loop, explicitly typed. Walk the preference order and take
            // the first device that is actually available.
            var chosen: AudioDeviceInfo? = null
            for (wanted in routePreference) {
                for (device in available) {
                    if (device.type == wanted) {
                        chosen = device
                        break
                    }
                }
                if (chosen != null) break
            }

            if (chosen != null) {
                // No-op if it is already the active route — avoids audio glitches
                // from redundant re-selection on every device callback.
                if (am.communicationDevice?.id != chosen.id) {
                    val ok = am.setCommunicationDevice(chosen)
                    Log.i(tag, "Route -> ${routeName(chosen.type)} (ok=$ok)")
                } else {
                    Log.i(tag, "Route unchanged (${routeName(chosen.type)})")
                }
            } else {
                @Suppress("DEPRECATION")
                am.isSpeakerphoneOn = true
                Log.i(tag, "Route -> speakerphone (no communication device offered)")
            }
        } else {
            // Pre-S: no setCommunicationDevice(). A connected headset (BT or wired)
            // takes the route on its own; speakerphone must be OFF or it overrides.
            @Suppress("DEPRECATION")
            val headsetAttached = am.isBluetoothScoOn || am.isWiredHeadsetOn
            @Suppress("DEPRECATION")
            am.isSpeakerphoneOn = !headsetAttached
            Log.i(tag, "Route -> ${if (headsetAttached) "headset" else "speakerphone"} (legacy path)")
        }
    }

    // Follows the audio to a headset connected MID-CONVERSATION. Someone reaching
    // for headphones while talking to Joe is a "make this private, now" moment;
    // audio has to follow. Also handles the reverse — unplug and fall back to speaker.
    private fun registerRouteListener() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        if (routeListener != null) return
        val am = audioManager() ?: return

        val cb = object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>?) {
                selectBestRoute()
            }
            override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>?) {
                selectBestRoute()
            }
        }
        am.registerAudioDeviceCallback(cb, mainHandler)
        routeListener = cb
    }

    private fun unregisterRouteListener() {
        val cb = routeListener ?: return
        routeListener = null
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        audioManager()?.unregisterAudioDeviceCallback(cb)
    }

    private fun routeName(type: Int): String = when (type) {
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "bluetooth"
        AudioDeviceInfo.TYPE_BLE_HEADSET -> "bluetooth-le"
        AudioDeviceInfo.TYPE_WIRED_HEADSET -> "wired-headset"
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "wired-headphones"
        AudioDeviceInfo.TYPE_USB_HEADSET -> "usb-headset"
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "speaker"
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "earpiece"
        else -> "type-$type"
    }

    private fun clearSpeakerRoute() {
        val am = audioManager() ?: return
        unregisterRouteListener()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            am.clearCommunicationDevice()
        } else {
            @Suppress("DEPRECATION")
            am.isSpeakerphoneOn = false
        }
        am.mode = savedAudioMode
    }

    // --- Playback: comms path ---

    private fun startPlayback(): Boolean {
        if (audioTrack != null) return true
        val minBuf = AudioTrack.getMinBufferSize(sampleRate, outChannelConfig, audioFormat)
        if (minBuf == AudioTrack.ERROR || minBuf == AudioTrack.ERROR_BAD_VALUE) return false
        val bufferBytes = maxOf(minBuf, 640 * 4)

        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()
        val format = AudioFormat.Builder()
            .setSampleRate(sampleRate)
            .setChannelMask(outChannelConfig)
            .setEncoding(audioFormat)
            .build()

        val track = AudioTrack(
            attributes, format, bufferBytes,
            AudioTrack.MODE_STREAM, AudioManager.AUDIO_SESSION_ID_GENERATE
        )
        if (track.state != AudioTrack.STATE_INITIALIZED) {
            track.release()
            return false
        }
        audioTrack = track
        track.play()

        // Read the ACTUAL allocated buffer size (may exceed what we requested)
        // and reset the frame counter. The buffer size drives the warm-up
        // fallback delay. Logged so the real number is visible in logcat.
        synchronized(playbackLock) {
            framesWritten = 0
            trackBufferFrames = try { track.bufferSizeInFrames } catch (_: Exception) { 0 }
        }
        Log.i(tag, "AudioTrack started: bufferSizeInFrames=$trackBufferFrames (fallback delay ~${bufferFallbackDelayMs()} ms until timestamp warms up)")
        return true
    }

    private fun stopPlayback() {
        audioTrack?.let {
            try {
                if (it.playState == AudioTrack.PLAYSTATE_PLAYING) it.stop()
            } catch (_: IllegalStateException) {
            }
            it.release()
        }
        audioTrack = null
        synchronized(playbackLock) {
            framesWritten = 0
            trackBufferFrames = 0
        }
    }

    // Fallback render->capture delay (ms) used during the getTimestamp() warm-up
    // window, computed from the AudioTrack's real buffer plus mic input latency.
    // A full buffer's worth of audio is the worst-case output latency before the
    // pipeline reports timestamps; half-buffer is a reasonable steady estimate.
    private fun bufferFallbackDelayMs(): Int {
        val bufFrames = trackBufferFrames
        if (bufFrames <= 0) {
            // No buffer info yet: use a conservative default near Android's
            // documented cold-output latency ceiling (~100 ms) + input.
            return (100 + inputLatencyMs).coerceIn(minDelayMs, maxDelayMs)
        }
        val bufferMs = (bufFrames.toDouble() / sampleRate * 1000.0)
        // Half the buffer as the typical in-flight amount, + input latency.
        return ((bufferMs / 2.0) + inputLatencyMs).toInt().coerceIn(minDelayMs, maxDelayMs)
    }

    // The MEASURED render->capture delay (ms) for the current instant. Uses the
    // AudioTrack playback timestamp when available; falls back to the buffer
    // estimate during warm-up or if the timestamp is unavailable.
    // Tracks which measurement path drove the last delay, for the throttled
    // diagnostic log: "TS" (getTimestamp), "HEAD" (getPlaybackHeadPosition),
    // or "FALLBACK" (buffer math).
    @Volatile private var lastDelaySource = "FALLBACK"

    private fun currentStreamDelayMs(): Int {
        val track = audioTrack ?: run { lastDelaySource = "FALLBACK"; return bufferFallbackDelayMs() }
        val written: Long
        synchronized(playbackLock) { written = framesWritten }

        // --- Preferred: getTimestamp() (most precise when supported) ---
        val haveTs = try {
            track.getTimestamp(playbackTimestamp)
        } catch (_: Exception) {
            false
        }
        if (haveTs && playbackTimestamp.framePosition > 0L) {
            val inFlight = written - playbackTimestamp.framePosition
            if (inFlight in 0..(sampleRate.toLong())) {  // sanity: < 1s in-flight
                lastDelaySource = "TS"
                val outMs = inFlight.toDouble() / sampleRate * 1000.0
                return (outMs + inputLatencyMs).toInt().coerceIn(minDelayMs, maxDelayMs)
            }
        }

        // --- Primary on this device: getPlaybackHeadPosition() ---
        // getTimestamp() does not report on the VOICE_COMMUNICATION output path
        // on the SM-S928U (framePosition stays 0). getPlaybackHeadPosition() is
        // the older, far more widely supported counter of frames actually
        // played. It returns a 32-bit value that MUST be read as unsigned
        // (ExoPlayer does exactly this). Reset to 0 by stop()/flush().
        val headRaw = try {
            track.playbackHeadPosition
        } catch (_: Exception) {
            0
        }
        val framesPlayed = headRaw.toLong() and 0xFFFFFFFFL  // unsigned
        // DIAGNOSTIC (temporary): show the raw numbers the phone reports so we
        // can see WHY the HEAD measurement is being accepted or rejected.
        val inFlightDiag = written - framesPlayed
        Log.i(tag, "HEAD diag: framesPlayed=$framesPlayed written=$written inFlight=$inFlightDiag bufFrames=$trackBufferFrames")
        if (framesPlayed > 0L) {
            val inFlight = written - framesPlayed
            if (inFlight in 0..(sampleRate.toLong())) {
                lastDelaySource = "HEAD"
                val outMs = inFlight.toDouble() / sampleRate * 1000.0
                return (outMs + inputLatencyMs).toInt().coerceIn(minDelayMs, maxDelayMs)
            }
        }

        // --- Fallback: buffer math (warm-up or both measurements unavailable) ---
        lastDelaySource = "FALLBACK"
        return bufferFallbackDelayMs()
    }

    // --- Capture + WebRTC AEC3 ---

    private fun startCapture(): Boolean {
        if (capturing) return true

        val minBuf = AudioRecord.getMinBufferSize(sampleRate, inChannelConfig, audioFormat)
        if (minBuf == AudioRecord.ERROR || minBuf == AudioRecord.ERROR_BAD_VALUE) return false
        val frameBytes = 640
        val bufferBytes = maxOf(minBuf, frameBytes * 4)

        val record = AudioRecord(
            MediaRecorder.AudioSource.VOICE_COMMUNICATION,
            sampleRate, inChannelConfig, audioFormat, bufferBytes
        )
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            return false
        }

        // Create the AEC3 engine. We do NOT bind the Android hardware
        // AcousticEchoCanceler/NoiseSuppressor — AEC3 replaces both. Noise
        // suppression is enabled inside the shim's APM config.
        synchronized(aecLock) {
            if (aecHandle == 0L) {
                val h = nativeCreate()
                aecHandle = h
                if (h == 0L) {
                    Log.w(tag, "nativeCreate() returned 0 — AEC3 engine not created; capture will be UNCANCELLED")
                } else {
                    // The render->capture delay is now MEASURED and set per
                    // capture frame (see the capture thread below), not fixed
                    // here. Seed it once with the current best estimate so the
                    // very first frames aren't at zero.
                    nativeSetStreamDelayMs(h, currentStreamDelayMs())
                    Log.i(tag, "AEC3 engine created (handle set); measured stream delay in use")
                }
            }
        }

        audioRecord = record
        capturing = true
        record.startRecording()

        captureThread = Thread {
            val buf = ByteArray(frameBytes)
            var frameCounter = 0
            while (capturing) {
                val read = record.read(buf, 0, buf.size)
                if (read > 0) {
                    val frame = if (read == buf.size) buf.copyOf() else buf.copyOf(read)
                    // Clean this frame in place via AEC3 before sending it on.
                    // The capture thread is the ONLY caller of nativeProcessCapture,
                    // and stopCapture() join()s this thread before destroying the
                    // handle, so reading aecHandle here without the lock is safe
                    // against destroy. (feedPlayback/render is a separate path,
                    // which AEC3's threading model permits concurrently.)
                    val h = aecHandle
                    if (h != 0L) {
                        // Feed AEC3 the CURRENT measured render->capture delay,
                        // then clean the frame. Computed from the AudioTrack
                        // playback clock (falls back to buffer estimate during
                        // warm-up). This is what makes cancellation converge.
                        val delayMs = currentStreamDelayMs()
                        nativeSetStreamDelayMs(h, delayMs)
                        nativeProcessCapture(h, frame)

                        // Throttled visibility: log the measured delay ~once/sec
                        // (50 frames * 20 ms) so logcat shows real convergence.
                        frameCounter++
                        if (frameCounter % 50 == 0) {
                            Log.i(tag, "measured stream delay = $delayMs ms (source=$lastDelaySource)")
                        }
                    }
                    mainHandler.post { eventSink?.success(frame) }
                }
            }
        }.apply {
            name = "SixPagesVoiceCapture"
            start()
        }

        return true
    }

    private fun stopCapture() {
        capturing = false
        try {
            captureThread?.join(500)
        } catch (_: InterruptedException) {
        }
        captureThread = null

        // Capture thread is now joined (no more nativeProcessCapture calls).
        // Destroy the AEC3 engine under the lock so any in-flight feedPlayback
        // render call finishes first and no new one starts on a freed handle.
        synchronized(aecLock) {
            val h = aecHandle
            aecHandle = 0L
            if (h != 0L) {
                nativeDestroy(h)
                Log.i(tag, "AEC3 engine destroyed")
            }
        }

        audioRecord?.let {
            try {
                if (it.recordingState == AudioRecord.RECORDSTATE_RECORDING) it.stop()
            } catch (_: IllegalStateException) {
            }
            it.release()
        }
        audioRecord = null
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stopEngine()
        controlChannel.setMethodCallHandler(null)
        captureChannel.setStreamHandler(null)
        eventSink = null
        appContext = null
    }
}
