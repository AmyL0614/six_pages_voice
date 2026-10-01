import 'dart:typed_data';
import 'six_pages_voice_platform_interface.dart';

/// Public API for the Six Pages echo-cancelling voice plugin.
///
/// Native owns the OS voice-processing unit (mic capture + playback through
/// one echo-cancelling audio unit). This class is the thin Dart wrapper the
/// app calls.
class SixPagesVoice {
  /// Opens the voice-processing unit and begins mic capture + playback.
  /// Returns true if the unit opened successfully.
  Future<bool> start() {
    return SixPagesVoicePlatform.instance.start();
  }

  /// Tears down the unit, releasing mic and speaker.
  Future<void> stop() {
    return SixPagesVoicePlatform.instance.stop();
  }

  /// Pushes the agent's incoming audio (PCM16, 16 kHz, mono) down to native
  /// for playback through the echo-cancelling unit. Returns as soon as the
  /// bytes are queued; it never waits for them to play, so the calling thread
  /// is never blocked while the agent speaks.
  Future<void> feedPlayback(Uint8List pcm) {
    return SixPagesVoicePlatform.instance.feedPlayback(pcm);
  }

  /// Discards the agent's audio that has been fed but not yet played, fading
  /// the last few milliseconds so the cut does not click.
  ///
  /// Call this when ElevenLabs sends an `interruption` event — it is what
  /// ElevenLabs' own SDKs do ("all previously buffered audio output should be
  /// stopped"). Pair it with dropping any later `audio` event whose `event_id`
  /// is at or below the interruption's `event_id`. Audio fed AFTER this call
  /// plays normally.
  ///
  /// Returns true when the clear was handed to a running session. Returns
  /// false when nothing is playing, or when the native side is an older build
  /// without clearPlayback, so it is always safe to call.
  ///
  /// iOS discards within one render buffer. Android discards everything queued
  /// ahead of the AudioTrack; the track's own small buffer (about 100 ms on
  /// tested hardware) plays out, so echo-cancellation timing is never disturbed.
  Future<bool> clearPlayback() {
    return SixPagesVoicePlatform.instance.clearPlayback();
  }

  /// The clean, echo-free capture stream (PCM16, 16 kHz, mono) coming up
  /// from native. Send it wherever your app needs the user's voice, for
  /// example as the user audio of an ElevenLabs conversation.
  Stream<Uint8List> get captureStream {
    return SixPagesVoicePlatform.instance.captureStream;
  }
}
