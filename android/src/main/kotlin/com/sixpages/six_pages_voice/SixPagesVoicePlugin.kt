package com.sixpages.six_pages_voice

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
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
 *
 * ---------------------------------------------------------------------------
 * ANDROID BUILD A1 — AN INSTRUMENT, NOT A FIX. NO BEHAVIOR CHANGES.
 * ---------------------------------------------------------------------------
 *
 * OPEN BUG: Bluetooth-to-car is flawless. USB-to-car (Android Auto projection)
 * survives until the SCREEN SLEEPS, then the conversation dies.
 *
 * We do not know why, and we are NOT going to guess. Two hypotheses, each with
 * a different fix, and the logs cannot currently distinguish them:
 *
 *   H1 — CLOBBERED. Under projection, Android Auto is the foreground app and
 *        has its own audio stack talking to the car. setCommunicationDevice()
 *        is arbitrated by whoever most recently owns MODE_IN_COMMUNICATION
 *        (Android docs, AudioManager#setCommunicationDevice). If Android Auto
 *        or the head unit asserts it at screen-off, WE LOSE THE ROUTE and the
 *        code above never finds out — nothing re-reads it.
 *        Fix would be: Telecom / ConnectionService (the Android analogue of the
 *        CallKit fix that solved iOS — declare a CALL, not merely audio).
 *
 *   H2 — MUTED. The foreground service type is `microphone`. That declares
 *        "I am recording." It does not declare "a call is in progress." Under
 *        projection the system may be applying a different policy.
 *        Fix would be: foregroundServiceType="phoneCall" + MANAGE_OWN_CALLS.
 *
 * ALSO SUSPECT, AND CHEAP TO RULE OUT: routePreference does not contain
 * TYPE_BUS (21) or TYPE_DOCK (13). AAOS enumerates automotive audio as
 * AUDIO_DEVICE_OUT_BUS. A projected head unit that offers itself as BUS would
 * never be selected — we would silently fall through to TYPE_BUILTIN_SPEAKER,
 * which is ALWAYS available, so the "no preferred device / Offered: [...]"
 * branch that would have told us NEVER FIRES.
 *
 * WHAT A1 ADDS (all diagnostic, all Log.i, nothing changes what the code does):
 *   - snapshot(): a single-line strip, same discipline as the iOS strip.
 *   - EVERY available communication device logged EVERY time we route, with
 *     its raw integer type — not just when we fail to match one.
 *   - the actual return of setCommunicationDevice(), and a read-back of what
 *     the framework says the device IS afterwards (they can disagree).
 *   - a SCREEN_OFF / SCREEN_ON receiver that dumps the strip at exactly the
 *     moment of death. This is the whole point. The Hard Rules say a strip
 *     read after the event is meaningless; this one is read AT the event.
 *   - a heartbeat that re-reads mode + communicationDevice every ~5s, so a
 *     route we lose while the screen is dark is TIMESTAMPED, not inferred.
 *
 * HOW TO READ IT, next session:
 *   Look at the strip at SCREEN_OFF and the strip 5s later.
 *   commDev CHANGED or went null  -> H1. Build Telecom.
 *   commDev UNCHANGED, mic silent -> H2. Change the service type.
 *   commDev was never the car     -> the routePreference gap. Add TYPE_BUS.
 * ---------------------------------------------------------------------------
 */
class SixPagesVoicePlugin :
    FlutterPlugin,
    MethodCallHandler,
    EventChannel.StreamHandler {

    private val tag = "SixPagesVoice"

    // --- Audio focus state --------------------------------------------------
    // REQUIRED by Android for MODE_IN_COMMUNICATION. See requestFocus().
    private var focusRequest: AudioFocusRequest? = null
    private var focusListener: AudioManager.OnAudioFocusChangeListener? = null
    private var focusLossCount = 0

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

    // --- BUILD A1 DIAGNOSTICS ------------------------------------------------
    // Everything below this line is an INSTRUMENT. None of it changes behavior.
    // It exists because the USB-to-car screen-off failure cannot currently be
    // told apart from three different causes, and we are not going to guess.

    // Screen state, and the strip frozen AT the moment the screen went dark.
    // A reading taken after the fact is worthless (this is the Android version
    // of the iOS post-teardown lesson). We capture at the transition.
    @Volatile private var screenOffCount = 0
    @Volatile private var lastScreenEvent = "-"
    private var screenReceiver: android.content.BroadcastReceiver? = null

    // Heartbeat: re-reads mode + communicationDevice every 5s while a session is
    // live. A route lost with the screen dark gets a TIMESTAMP instead of an
    // inference. Cheap: two getters, once per 5 seconds.
    private var heartbeat: Runnable? = null
    private val heartbeatMs = 5000L
    @Volatile private var heartbeatTicks = 0

    // What we ASKED for vs what the framework SAYS we got. These can disagree,
    // and that disagreement is the entire H1 hypothesis.
    @Volatile private var requestedRouteType = -1
    @Volatile private var lastSetCommDevOk: Boolean? = null
    @Volatile private var routeSelectCount = 0
    @Volatile private var routeLostCount = 0

    // Capture liveness. If the mic is silently muted (H2), frames stop arriving
    // but nothing else in the system reports an error. This counter is how we
    // see that: it simply STOPS INCREASING while everything else looks healthy.
    @Volatile private var captureFrames = 0L
    @Volatile private var renderFrames = 0L

    // Was the session ever routed to something that is plausibly the car?
    @Volatile private var everRoutedTo = "-"

    /**
     * The Android diagnostic strip. One line. Same discipline as iOS.
     *
     * Read it at SCREEN_OFF, then read the next heartbeat 5 seconds later.
     * The DIFFERENCE between those two lines is the answer.
     */
    private fun snapshot(why: String): String {
        val am = audioManager()
        val mode = am?.mode ?: -1
        val modeName = when (mode) {
            AudioManager.MODE_NORMAL -> "NORMAL"
            AudioManager.MODE_IN_CALL -> "IN_CALL"
            AudioManager.MODE_IN_COMMUNICATION -> "IN_COMM"
            AudioManager.MODE_RINGTONE -> "RINGTONE"
            else -> "mode-$mode"
        }

        // THE LOAD-BEARING READ. What does the framework think the comms device
        // is, RIGHT NOW? Not what we asked for. What it IS.
        var commDev = "n/a"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && am != null) {
            val d = try { am.communicationDevice } catch (_: Exception) { null }
            commDev = if (d == null) "NULL" else "${routeName(d.type)}(${d.type})"
        }

        val focus = if (focusRequest != null || focusListener != null) "held" else "none"
        val trackState = audioTrack?.let {
            when (it.playState) {
                AudioTrack.PLAYSTATE_PLAYING -> "playing"
                AudioTrack.PLAYSTATE_PAUSED -> "paused"
                AudioTrack.PLAYSTATE_STOPPED -> "stopped"
                else -> "state-${it.playState}"
            }
        } ?: "null"
        val recState = audioRecord?.let {
            if (it.recordingState == AudioRecord.RECORDSTATE_RECORDING) "recording" else "STOPPED"
        } ?: "null"

        return "STRIP[$why] " +
            "mode=$modeName; commDev=$commDev; wanted=${routeName(requestedRouteType)}($requestedRouteType); " +
            "setCommDevOk=${lastSetCommDevOk ?: "-"}; everRouted=$everRoutedTo; " +
            "routeSelects=$routeSelectCount; routeLost=$routeLostCount; " +
            "focus=$focus; focusLoss=$focusLossCount; " +
            "capturing=$capturing; rec=$recState; track=$trackState; " +
            "captureFrames=$captureFrames; renderFrames=$renderFrames; " +
            "aec=${if (aecHandle != 0L) "up" else "DOWN"}; " +
            "screenOffs=$screenOffCount; lastScreen=$lastScreenEvent; hb=$heartbeatTicks"
    }

    private fun logStrip(why: String) {
        Log.i(tag, snapshot(why))
    }

    /**
     * Dumps EVERY communication device the framework is currently offering, with
     * its RAW INTEGER TYPE.
     *
     * The old code only logged the offered list when NOTHING matched
     * routePreference. But TYPE_BUILTIN_SPEAKER is in routePreference and is
     * ALWAYS available — so that branch could never fire, and a car head unit
     * enumerating as an unlisted type (TYPE_BUS=21, TYPE_DOCK=13) would be
     * invisible while we quietly played to the phone speaker.
     *
     * Now it fires EVERY time. Read the integers. If the car is in this list
     * under a type that is not in routePreference, that alone is the bug.
     */
    private fun logOfferedDevices(why: String) {
        val am = audioManager() ?: return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            Log.i(tag, "OFFERED[$why] pre-S, no availableCommunicationDevices()")
            return
        }
        val available = try { am.availableCommunicationDevices } catch (_: Exception) { emptyList() }
        if (available.isEmpty()) {
            Log.w(tag, "OFFERED[$why] EMPTY — the framework is offering NO communication devices")
            return
        }
        val listed = available.joinToString(", ") { d ->
            val known = routePreference.contains(d.type)
            "${routeName(d.type)}(type=${d.type}${if (known) "" else " *NOT-IN-PREFERENCE*"}, id=${d.id}, name=${d.productName})"
        }
        Log.i(tag, "OFFERED[$why] $listed")
    }

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
                    renderFrames++  // A1: Joe is still being fed to us.
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

        // FOCUS FIRST, before MODE_IN_COMMUNICATION. That is Google's ordering.
        // Requesting focus AFTER entering communication mode is how a car's Bluetooth
        // stack beats us to it. Denial is logged, not fatal - see requestFocus().
        if (!requestFocus()) {
            Log.w(tag, "Proceeding WITHOUT audio focus - expect contention (car / BT)")
        }

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
        selectBestRoute("streams-live")

        // A1 instruments. Both are diagnostic only.
        registerScreenReceiver()
        startHeartbeat()
        logStrip("SESSION_START")
        return true
    }

    private fun stopEngine() {
        // A1: freeze the strip BEFORE teardown wipes it. The iOS Hard Rules were
        // written in blood over exactly this: a strip read after stopUnit() is
        // meaningless, and we reasoned off one for hours. This is the state at
        // the MOMENT OF DEATH, whatever killed it.
        logStrip("SESSION_END")

        stopHeartbeat()
        unregisterScreenReceiver()
        stopCapture()
        stopPlayback()
        clearSpeakerRoute()
        abandonFocus()

        // Reset diagnostic counters for the next session so a stale number from
        // the last run can never be mistaken for a live one.
        captureFrames = 0L
        renderFrames = 0L
        routeSelectCount = 0
        routeLostCount = 0
        focusLossCount = 0
        heartbeatTicks = 0
        screenOffCount = 0
        requestedRouteType = -1
        lastSetCommDevOk = null
        everRoutedTo = "-"
        lastScreenEvent = "-"

        // Last: tears down the notification and releases the wakelock.
        appContext?.let { VoiceSessionService.stop(it) }
    }

    // --- Audio focus (REQUIRED by Android; we never requested it) ------------
    //
    // BUILD: car Bluetooth drop.
    //
    // Google's contract: an app that plays or records audio MUST request audio focus,
    // and MUST register a listener for focus changes. This plugin set
    // MODE_IN_COMMUNICATION and drove the route WITHOUT EVER ASKING FOR FOCUS.
    //
    // That works on a phone on a desk, because nothing else is contending for audio.
    // In a CAR it does not. The head unit's Bluetooth stack requests focus the moment
    // it connects. It wins by default — we were never holding any — and the framework
    // tears our streams down. No callback ever reached us, because we had never
    // registered a listener to receive one. Symptom: the call opens and drops seconds
    // later, FASTER than iOS, because the car's stack claims focus almost immediately.
    //
    // This is the SAME CLASS OF BUG as the missing iOS interruption handler: a contract
    // the platform documents and we did not implement. It is NOT a routing override.
    // Focus is what gives us STANDING to hold the route we are already selecting
    // correctly. Requesting it is following Android's contract, not imposing ours.
    //
    // AUDIOFOCUS_GAIN, not GAIN_TRANSIENT: a conversation with Joe is not a transient
    // beep. It is the foreground audio activity for as long as it lasts.
    //
    // We do NOT fail the session if focus is denied. A denial is logged and we proceed,
    // so it surfaces in logcat as a DIAGNOSIS instead of a silent no-audio.
    private fun requestFocus(): Boolean {
        val am = audioManager() ?: return false

        val listener = AudioManager.OnAudioFocusChangeListener { change ->
            when (change) {
                AudioManager.AUDIOFOCUS_LOSS -> {
                    focusLossCount++
                    Log.w(tag, "Audio focus LOST permanently (count=$focusLossCount) - another app owns audio")
                }
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                    focusLossCount++
                    Log.w(tag, "Audio focus lost TRANSIENTLY (count=$focusLossCount)")
                }
                AudioManager.AUDIOFOCUS_GAIN -> {
                    // Audio is ours again. The route may have been re-evaluated while
                    // we were out; re-assert it, same as we do after the streams go live.
                    Log.i(tag, "Audio focus REGAINED - re-asserting route")
                    selectBestRoute()
                }
                else -> Log.i(tag, "Audio focus change: $change")
            }
        }
        focusListener = listener

        val granted: Int
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val attrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build()
            val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(attrs)
                .setOnAudioFocusChangeListener(listener, mainHandler)
                .setAcceptsDelayedFocusGain(false)
                .setWillPauseWhenDucked(false)
                .build()
            focusRequest = req
            granted = am.requestAudioFocus(req)
        } else {
            @Suppress("DEPRECATION")
            granted = am.requestAudioFocus(
                listener,
                AudioManager.STREAM_VOICE_CALL,
                AudioManager.AUDIOFOCUS_GAIN
            )
        }

        val ok = granted == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        Log.i(tag, "Audio focus request -> " + if (ok) "GRANTED" else "DENIED (code=$granted)")
        return ok
    }

    private fun abandonFocus() {
        val am = audioManager() ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { am.abandonAudioFocusRequest(it) }
        } else {
            @Suppress("DEPRECATION")
            focusListener?.let { am.abandonAudioFocus(it) }
        }
        focusRequest = null
        focusListener = null
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
    private fun selectBestRoute() = selectBestRoute("route")

    private fun selectBestRoute(why: String) {
        val am = audioManager() ?: return
        routeSelectCount++

        // A1: log the full offered list EVERY time, not only on total failure.
        // This is the line that would have caught a car enumerating as TYPE_BUS.
        logOfferedDevices(why)

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
                requestedRouteType = chosen.type
                // No-op if it is already the active route — avoids audio glitches
                // from redundant re-selection on every device callback.
                if (am.communicationDevice?.id != chosen.id) {
                    val ok = am.setCommunicationDevice(chosen)
                    lastSetCommDevOk = ok

                    // A1: READ IT BACK. setCommunicationDevice() returning true
                    // means the REQUEST was accepted. It does NOT mean the route
                    // is what we asked for — arbitration happens after, and the
                    // owner of MODE_IN_COMMUNICATION wins. If these two disagree,
                    // that disagreement IS the bug, and until now nothing looked.
                    val actual = try { am.communicationDevice } catch (_: Exception) { null }
                    val actualName = if (actual == null) "NULL" else "${routeName(actual.type)}(${actual.type})"
                    val agrees = actual?.type == chosen.type
                    if (agrees) {
                        everRoutedTo = routeName(chosen.type)
                        Log.i(tag, "Route[$why] -> ${routeName(chosen.type)}(${chosen.type}) ok=$ok CONFIRMED=$actualName")
                    } else {
                        Log.w(tag, "Route[$why] -> ASKED ${routeName(chosen.type)}(${chosen.type}) ok=$ok but framework says $actualName — MISMATCH")
                    }
                } else {
                    everRoutedTo = routeName(chosen.type)
                    Log.i(tag, "Route[$why] unchanged (${routeName(chosen.type)}(${chosen.type}))")
                }
            } else {
                @Suppress("DEPRECATION")
                am.isSpeakerphoneOn = true
                requestedRouteType = -1
                // Retained from the original. This branch could never fire while
                // TYPE_BUILTIN_SPEAKER sits in routePreference and is always
                // available — which is exactly why logOfferedDevices() above now
                // runs unconditionally instead of only here.
                val offered = available.joinToString(", ") { "${routeName(it.type)}(${it.type})" }
                Log.w(tag, "Route[$why] -> speakerphone (no preferred device). Offered: [$offered]")
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

    // BUILD A1: this map was BLIND to exactly the devices we are hunting.
    // A car under USB projection does not enumerate as any of the six original
    // entries. TYPE_BUS (21) is the AAOS automotive audio device. TYPE_DOCK (13)
    // is what some head units present as. TYPE_USB_DEVICE (11) and
    // TYPE_USB_ACCESSORY (12) are the raw USB audio classes. Without names, the
    // strip printed "type-21" and meant nothing to a human reading it at 2am.
    //
    // NAMING A TYPE DOES NOT SELECT IT. routePreference is UNCHANGED — this is
    // an instrument, not a fix, and adding TYPE_BUS to the preference list would
    // be a second variable in the same build. If the logs show BUS, we add it
    // NEXT build, alone, and prove it.
    private fun routeName(type: Int): String = when (type) {
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "bluetooth"
        AudioDeviceInfo.TYPE_BLE_HEADSET -> "bluetooth-le"
        AudioDeviceInfo.TYPE_WIRED_HEADSET -> "wired-headset"
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "wired-headphones"
        AudioDeviceInfo.TYPE_USB_HEADSET -> "usb-headset"
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "speaker"
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "earpiece"
        // --- A1: the ones we were blind to ---
        AudioDeviceInfo.TYPE_BUS -> "BUS-automotive"
        AudioDeviceInfo.TYPE_DOCK -> "DOCK"
        AudioDeviceInfo.TYPE_USB_DEVICE -> "usb-device"
        AudioDeviceInfo.TYPE_USB_ACCESSORY -> "usb-accessory"
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "bluetooth-a2dp"
        AudioDeviceInfo.TYPE_HEARING_AID -> "hearing-aid"
        AudioDeviceInfo.TYPE_TELEPHONY -> "telephony"
        AudioDeviceInfo.TYPE_LINE_ANALOG -> "line-analog"
        AudioDeviceInfo.TYPE_LINE_DIGITAL -> "line-digital"
        AudioDeviceInfo.TYPE_HDMI -> "hdmi"
        AudioDeviceInfo.TYPE_AUX_LINE -> "aux-line"
        AudioDeviceInfo.TYPE_UNKNOWN -> "unknown"
        -1 -> "none"
        else -> "type-$type"
    }

    // --- BUILD A1: SCREEN TRANSITION WATCH ----------------------------------
    //
    // THE INSTRUMENT THIS BUILD EXISTS FOR.
    //
    // The failure happens AT screen-off, over USB, and nowhere else. So we read
    // the strip AT screen-off — not before (nothing is wrong yet) and not after
    // (the iOS Hard Rules already taught us what a post-mortem strip is worth).
    //
    // Then the heartbeat reads it again 5 seconds later. Two lines, five seconds
    // apart, straddling the exact moment the conversation dies. Whatever changed
    // between them is the bug. There is no third possibility to argue about.
    private fun registerScreenReceiver() {
        val ctx = appContext ?: return
        if (screenReceiver != null) return

        val rx = object : android.content.BroadcastReceiver() {
            override fun onReceive(c: Context?, intent: android.content.Intent?) {
                when (intent?.action) {
                    android.content.Intent.ACTION_SCREEN_OFF -> {
                        screenOffCount++
                        lastScreenEvent = "OFF"
                        Log.w(tag, "=== SCREEN OFF — reading strip AT the transition ===")
                        logOfferedDevices("screen-off")
                        logStrip("SCREEN_OFF")
                    }
                    android.content.Intent.ACTION_SCREEN_ON -> {
                        lastScreenEvent = "ON"
                        Log.i(tag, "=== SCREEN ON ===")
                        logOfferedDevices("screen-on")
                        logStrip("SCREEN_ON")
                    }
                    android.content.Intent.ACTION_USER_PRESENT -> {
                        lastScreenEvent = "UNLOCK"
                        logStrip("USER_PRESENT")
                    }
                }
            }
        }

        val filter = android.content.IntentFilter().apply {
            addAction(android.content.Intent.ACTION_SCREEN_OFF)
            addAction(android.content.Intent.ACTION_SCREEN_ON)
            addAction(android.content.Intent.ACTION_USER_PRESENT)
        }

        // Android 14+ requires the export flag to be explicit. These are protected
        // system broadcasts; NOT_EXPORTED is correct and sufficient.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ctx.registerReceiver(rx, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            ctx.registerReceiver(rx, filter)
        }
        screenReceiver = rx
        Log.i(tag, "Screen transition receiver registered")
    }

    private fun unregisterScreenReceiver() {
        val rx = screenReceiver ?: return
        screenReceiver = null
        try {
            appContext?.unregisterReceiver(rx)
        } catch (e: Exception) {
            Log.w(tag, "Screen receiver unregister failed: ${e.message}")
        }
    }

    // Heartbeat. Two getters every 5 seconds. Its only job is to TIMESTAMP a
    // route we lose while the screen is dark, instead of us inferring it later
    // from a corpse. It also detects the H1 signature directly: if commDev
    // changes out from under us without any device being added or removed,
    // somebody else took the route. That is arbitration, and it is not visible
    // through AudioDeviceCallback — which is precisely why we never saw it.
    private fun startHeartbeat() {
        if (heartbeat != null) return
        val r = object : Runnable {
            override fun run() {
                if (!capturing && audioTrack == null) return  // session gone; stop.
                heartbeatTicks++

                val am = audioManager()
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && am != null) {
                    val actual = try { am.communicationDevice } catch (_: Exception) { null }
                    val actualType = actual?.type ?: -1
                    if (requestedRouteType != -1 && actualType != requestedRouteType) {
                        routeLostCount++
                        Log.e(
                            tag,
                            "!!! ROUTE LOST — we hold ${routeName(requestedRouteType)}($requestedRouteType) " +
                                "but framework now says ${routeName(actualType)}($actualType). " +
                                "Something else won MODE_IN_COMMUNICATION arbitration. THIS IS H1."
                        )
                        logStrip("ROUTE_LOST")
                        logOfferedDevices("route-lost")
                    }
                }

                logStrip("HB")
                mainHandler.postDelayed(this, heartbeatMs)
            }
        }
        heartbeat = r
        mainHandler.postDelayed(r, heartbeatMs)
    }

    private fun stopHeartbeat() {
        heartbeat?.let { mainHandler.removeCallbacks(it) }
        heartbeat = null
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

    // A1: throttles the per-frame HEAD diag line to ~1/sec.
    @Volatile private var headDiagCounter = 0

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
        // DIAGNOSTIC: the raw numbers the phone reports, so we can see WHY the
        // HEAD measurement is accepted or rejected.
        //
        // A1: THROTTLED. This fired on EVERY capture frame — 50 lines/second.
        // Over a car test long enough to reach screen-off, it buries the strip
        // we are actually here to read. Now ~1/sec (every 50th call). Same
        // information, legible logcat. NOT a behavior change; a log-volume fix.
        headDiagCounter++
        if (headDiagCounter % 50 == 0) {
            val inFlightDiag = written - framesPlayed
            Log.i(tag, "HEAD diag: framesPlayed=$framesPlayed written=$written inFlight=$inFlightDiag bufFrames=$trackBufferFrames")
        }
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
                    // A1: the mic is alive. If Android SILENTLY MUTES us under
                    // projection (H2), read() keeps returning bytes but this is
                    // the counter to watch against renderFrames: Joe still
                    // speaking (renderFrames climbing) while captureFrames goes
                    // flat is the signature of a muted mic, and it is otherwise
                    // completely invisible — no error, no callback, nothing.
                    captureFrames++
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
