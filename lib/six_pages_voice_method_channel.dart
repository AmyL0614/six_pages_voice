import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'six_pages_voice_platform_interface.dart';

/// An implementation of [SixPagesVoicePlatform] that uses method channels.
class MethodChannelSixPagesVoice extends SixPagesVoicePlatform {
  /// Discrete commands to native: start, stop, feedPlayback.
  @visibleForTesting
  final methodChannel = const MethodChannel('six_pages_voice/control');

  /// Continuous clean (echo-cancelled) PCM frames coming up from native.
  @visibleForTesting
  final eventChannel = const EventChannel('six_pages_voice/capture');

  Stream<Uint8List>? _captureStream;

  @override
  Future<bool> start() async {
    final ok = await methodChannel.invokeMethod<bool>('start');
    return ok ?? false;
  }

  @override
  Future<void> stop() async {
    await methodChannel.invokeMethod<void>('stop');
  }

  @override
  Future<void> feedPlayback(Uint8List pcm) async {
    await methodChannel.invokeMethod<void>('feedPlayback', pcm);
  }

  @override
  Stream<Uint8List> get captureStream {
    _captureStream ??= eventChannel
        .receiveBroadcastStream()
        .map((event) => event as Uint8List);
    return _captureStream!;
  }
}
