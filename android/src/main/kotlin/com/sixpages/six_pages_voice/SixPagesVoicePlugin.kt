package com.sixpages.six_pages_voice

import android.content.Context
import android.media.AudioAttributes
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
                    audioTrack?.write(pcm, 0, pcm.size)
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
        routeToSpeaker()
        val playbackOk = startPlayback()
        if (!playbackOk) {
            clearSpeakerRoute()
            return false
        }
        val captureOk = startCapture()
        if (!captureOk) {
            stopPlayback()
            clearSpeakerRoute()
            return false
        }
        return true
    }

    private fun stopEngine() {
        stopCapture()
        stopPlayback()
        clearSpeakerRoute()
    }

    // --- Speaker routing ---

    private fun audioManager(): AudioManager? {
        return appContext?.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
    }

    private fun routeToSpeaker() {
        val am = audioManager() ?: return
        savedAudioMode = am.mode
        am.mode = AudioManager.MODE_IN_COMMUNICATION

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val speaker = am.availableCommunicationDevices.firstOrNull {
                it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
            }
            if (speaker != null) {
                am.setCommunicationDevice(speaker)
            } else {
                @Suppress("DEPRECATION")
                am.isSpeakerphoneOn = true
            }
        } else {
            @Suppress("DEPRECATION")
            am.isSpeakerphoneOn = true
        }
    }

    private fun clearSpeakerRoute() {
        val am = audioManager() ?: return
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
                    Log.i(tag, "AEC3 engine created (handle set)")
                }
            }
        }

        audioRecord = record
        capturing = true
        record.startRecording()

        captureThread = Thread {
            val buf = ByteArray(frameBytes)
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
                        nativeProcessCapture(h, frame)
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
