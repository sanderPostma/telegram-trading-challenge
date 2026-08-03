import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trading_challenge/src/bridge/weex.dart' as rust_weex;
import 'package:trading_challenge/src/state/app_controller.dart';

rust_weex.WeexAccountReconciliation _reconciliation({
  required String direction,
  double qtyBtc = 0,
}) {
  return rust_weex.WeexAccountReconciliation(
    balance: const rust_weex.WeexAccountBalance(
      asset: 'USDT',
      walletBalance: 1000,
      availableBalance: 1000,
      unrealizedPnl: 0,
      equity: 1000,
      usedMargin: 0,
    ),
    position: rust_weex.WeexPositionSnapshot(
      symbol: 'BTCUSDT',
      direction: direction,
      qtyBtc: qtyBtc,
      entryPrice: 63000,
      markPrice: 63000,
      notionalUsdt: qtyBtc * 63000,
      unrealizedPnlUsdt: 0,
      leverage: 10,
      updatedAtMs: 0,
    ),
    recentExecutions: const [],
    timestampMs: 0,
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('armCloseTarget stores a normalized watch and clears triggered', () {
    final c = AppController();
    c.closeTargetTriggered = true;
    c.armCloseTarget(low: 63600, high: 63700, source: 'Telegram');
    expect(c.closeTargetWatch, isNotNull);
    expect(c.closeTargetWatch!.low, 63600);
    expect(c.closeTargetWatch!.high, 63700);
    expect(c.closeTargetTriggered, isFalse);
  });

  test('a newer arm replaces the previous watch', () {
    final c = AppController();
    c.armCloseTarget(low: 63600, high: 63700, source: 'a');
    c.armCloseTarget(low: 64000, high: 64100, source: 'b');
    expect(c.closeTargetWatch!.low, 64000);
    expect(c.closeTargetWatch!.source, 'b');
  });

  test('cancelCloseTarget disarms', () {
    final c = AppController();
    c.armCloseTarget(low: 63600, high: 63700, source: 'a');
    c.cancelCloseTarget();
    expect(c.closeTargetWatch, isNull);
    expect(c.closeTargetTriggered, isFalse);
  });

  test(
    'a watch armed while flat survives a flat reconcile '
    '(arm-while-flat, restart-while-flat)',
    () {
      final c = AppController();
      c.armCloseTarget(low: 63600, high: 63700, source: 'Telegram');
      // No position exists yet; a live-mode reconcile timer tick observes a
      // still-flat exchange position. The watch must not be cleared.
      c.applyWeexReconciliation(_reconciliation(direction: 'none'));
      expect(c.closeTargetWatch, isNotNull);
    },
  );

  test('reconcile disarms only on an open->flat transition it observes', () {
    final c = AppController();
    c.armCloseTarget(low: 63600, high: 63700, source: 'Telegram');
    // First reconcile observes the position open (armed watch persists).
    c.applyWeexReconciliation(
      _reconciliation(direction: 'long', qtyBtc: 0.01),
    );
    expect(c.closeTargetWatch, isNotNull);
    // Second reconcile observes the same position going flat: disarm.
    c.applyWeexReconciliation(_reconciliation(direction: 'none'));
    expect(c.closeTargetWatch, isNull);
    expect(c.closeTargetTriggered, isFalse);
  });
}
