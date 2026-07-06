import 'package:flutter_test/flutter_test.dart';
import 'package:six_pages_voice/six_pages_voice_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('MethodChannelSixPagesVoice exposes control channel', () {
    final impl = MethodChannelSixPagesVoice();
    expect(impl.methodChannel.name, 'six_pages_voice/control');
  });
}
