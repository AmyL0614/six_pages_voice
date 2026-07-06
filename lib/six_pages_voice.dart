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

  /// Pushes Joe's incoming PCM bytes down to native for playback
  /// through the echo-cancelling unit.
  Future<void> feedPlayback(Uint8List pcm) {
    return SixPagesVoicePlatform.instance.feedPlayback(pcm);
  }

  /// The clean, echo-free capture stream (PCM16, 16 kHz, mono) coming up
  /// from native. Feed this to VAD's audioStream.
  Stream<Uint8List> get captureStream {
    return SixPagesVoicePlatform.instance.captureStream;
  }
}
