package com.sixpages.six_pages_voice

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/**
 * SixPagesVoicePlugin — CAPTURE LAYER ONLY.
 *
 * This layer proves the clean pipe: mic -> AudioRecord (VOICE_COMMUNICATION,
 * 16 kHz, mono, PCM16) -> frames up the /capture EventChannel -> Dart.
 *
 * NOT YET in this layer: AcousticEchoCanceler, AudioTrack playback,
 * feedPlayback (deliberate no-op stub below). Those are the next layers,
 * added only after capture is proven on the wire.
 */
class SixPagesVoicePlugin :
    FlutterPlugin,
    MethodCallHandler,
    EventChannel.StreamHandler {

    private lateinit var controlChannel: MethodChannel
    private lateinit var captureChannel: EventChannel

    // Sink that pushes capture frames up to Dart. Null until Dart subscribes.
    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    private var audioRecord: AudioRecord? = null
    private var captureThread: Thread? = null
    @Volatile private var capturing = false

    // Audio format — the contract: PCM16, 16 kHz, mono.
    private val sampleRate = 16000
    private val channelConfig = AudioFormat.CHANNEL_IN_MONO
    private val audioFormat = AudioFormat.ENCODING_PCM_16BIT

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        controlChannel = MethodChannel(binding.binaryMessenger, "six_pages_voice/control")
        controlChannel.setMethodCallHandler(this)

        captureChannel = EventChannel(binding.binaryMessenger, "six_pages_voice/capture")
        captureChannel.setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "start" -> {
                val ok = startCapture()
                result.success(ok)
            }
            "stop" -> {
                stopCapture()
                result.success(null)
            }
            "feedPlayback" -> {
                // NO-OP in the capture layer. Playback arrives in a later layer.
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

    // --- Capture ---

    private fun startCapture(): Boolean {
        if (capturing) return true

        val minBuf = AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat)
        if (minBuf == AudioRecord.ERROR || minBuf == AudioRecord.ERROR_BAD_VALUE) {
            return false
        }
        // Read in ~20 ms chunks (320 samples = 640 bytes at 16 kHz mono PCM16),
        // but never below the OS minimum buffer.
        val frameBytes = 640
        val bufferBytes = maxOf(minBuf, frameBytes * 4)

        val record = AudioRecord(
            MediaRecorder.AudioSource.VOICE_COMMUNICATION,
            sampleRate,
            channelConfig,
            audioFormat,
            bufferBytes
        )
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            return false
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
        stopCapture()
        controlChannel.setMethodCallHandler(null)
        captureChannel.setStreamHandler(null)
        eventSink = null
    }
}
