package com.sixpages.six_pages_voice

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
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
 * SixPagesVoicePlugin — CAPTURE + PLAYBACK + SPEAKER ROUTING + EXPLICIT AEC.
 *
 * Owns mic capture and Joe's playback through the OS voice-communication path,
 * with an AcousticEchoCanceler (and NoiseSuppressor) bound explicitly to the
 * AudioRecord session so echo cancellation is deterministic and ours. The AEC
 * is created AFTER the AudioRecord exists and BEFORE it starts recording, and
 * logs whether it engaged (tag SixPagesVoice) — check logcat to confirm.
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

    private lateinit var controlChannel: MethodChannel
    private lateinit var captureChannel: EventChannel
    private var appContext: Context? = null

    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    private var audioRecord: AudioRecord? = null
    private var captureThread: Thread? = null
    @Volatile private var capturing = false

    private var echoCanceler: AcousticEchoCanceler? = null
    private var noiseSuppressor: NoiseSuppressor? = null

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

    // --- Capture + explicit AEC ---

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

        // Bind explicit AEC + NoiseSuppressor to THIS record's session,
        // after it exists and before it starts recording.
        val sessionId = record.audioSessionId
        if (AcousticEchoCanceler.isAvailable()) {
            val aec = AcousticEchoCanceler.create(sessionId)
            if (aec != null) {
                aec.enabled = true
                echoCanceler = aec
                Log.i(tag, "AEC created and enabled=${aec.enabled} on session $sessionId")
            } else {
                Log.w(tag, "AEC.create returned null on session $sessionId")
            }
        } else {
            Log.w(tag, "AEC not available on this device")
        }

        if (NoiseSuppressor.isAvailable()) {
            val ns = NoiseSuppressor.create(sessionId)
            if (ns != null) {
                ns.enabled = true
                noiseSuppressor = ns
                Log.i(tag, "NoiseSuppressor created and enabled=${ns.enabled}")
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

        echoCanceler?.let {
            try { it.enabled = false } catch (_: Exception) {}
            it.release()
        }
        echoCanceler = null
        noiseSuppressor?.let {
            try { it.enabled = false } catch (_: Exception) {}
            it.release()
        }
        noiseSuppressor = null

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
