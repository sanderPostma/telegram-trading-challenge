import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:trading_challenge/main.dart';
import 'package:trading_challenge/src/bridge/frb_generated.dart';
import 'package:trading_challenge/src/state/app_controller.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async => await RustLib.init());

  testWidgets('can render app with rust bridge loaded', (tester) async {
    await tester.pumpWidget(
      TradingChallengeApp(controller: AppController(useRustBridge: true)),
    );
    expect(find.text('Manual Scaled Entry'), findsOneWidget);
  });
}
