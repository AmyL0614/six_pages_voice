import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:six_pages_voice/six_pages_voice.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('plugin instantiates', (WidgetTester tester) async {
    final plugin = SixPagesVoice();
    expect(plugin, isNotNull);
  });
}
