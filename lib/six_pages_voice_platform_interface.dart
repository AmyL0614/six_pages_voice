import 'dart:typed_data';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'six_pages_voice_method_channel.dart';

abstract class SixPagesVoicePlatform extends PlatformInterface {
  SixPagesVoicePlatform() : super(token: _token);

  static final Object _token = Object();

  static SixPagesVoicePlatform _instance = MethodChannelSixPagesVoice();

  static SixPagesVoicePlatform get instance => _instance;

  static set instance(SixPagesVoicePlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<bool> start() {
    throw UnimplementedError('start() has not been implemented.');
  }

  Future<void> stop() {
    throw UnimplementedError('stop() has not been implemented.');
  }

  Future<void> feedPlayback(Uint8List pcm) {
    throw UnimplementedError('feedPlayback() has not been implemented.');
  }

  Stream<Uint8List> get captureStream {
    throw UnimplementedError('captureStream has not been implemented.');
  }
}
