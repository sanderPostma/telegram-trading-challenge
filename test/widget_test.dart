import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trading_challenge/main.dart';
import 'package:trading_challenge/src/models/trading.dart';
import 'package:trading_challenge/src/state/app_controller.dart';

void main() {
  testWidgets('starts on setup when WEEX credentials are empty', (
    tester,
  ) async {
    await tester.pumpWidget(TradingChallengeApp(controller: AppController()));

    expect(find.text('WEEX API'), findsWidgets);
    expect(find.text('Access API key'), findsOneWidget);
    expect(find.text('Passphrase'), findsOneWidget);
  });

  testWidgets('dashboard exposes manual scaled entry controls', (tester) async {
    final controller = AppController()
      ..config = const AppConfig(
        weexApiKey: 'key',
        weexSecret: 'secret',
        weexPassphrase: 'passphrase',
      );
    await tester.pumpWidget(TradingChallengeApp(controller: controller));

    expect(find.text('Account Scaling'), findsOneWidget);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -420));
    await tester.pumpAndSettle();

    expect(find.text('Manual Scaled Entry'), findsOneWidget);
    expect(find.text('Open Long'), findsOneWidget);
    expect(find.text('Open Short'), findsOneWidget);
    expect(find.text('USDT'), findsWidgets);
    expect(find.text('BTC'), findsWidgets);
  });

  testWidgets('setup wizard exposes Telegram sign-in controls', (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(TradingChallengeApp(controller: AppController()));

    await tester.tap(find.text('Next').first);
    await tester.pumpAndSettle();

    expect(find.text('Request Telegram code'), findsOneWidget);
    expect(find.text('Login code'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Telegram 2FA password'), findsOneWidget);
    expect(find.text('Submit 2FA'), findsOneWidget);
  });
}
