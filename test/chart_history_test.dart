import 'package:flutter_test/flutter_test.dart';
import 'package:trading_challenge/src/models/trading.dart';
import 'package:trading_challenge/src/state/app_controller.dart';

void main() {
  test(
    'controller records margin balance, equity, and pnl chart history',
    () async {
      final controller = AppController()
        ..config = const AppConfig(
          masterBalanceUsd: 10000,
          myBalanceUsd: 2000,
          markPrice: 100000,
          autoApprove: true,
        );

      await controller.loadChartData();
      await controller.openManualTrade(
        amount: 1000,
        unit: SizeUnit.usdt,
        direction: TradeDirection.long,
      );
      await controller.saveConfig(
        controller.config.copyWith(markPrice: 101000),
        log: false,
      );

      expect(controller.balanceHistory.last.value, 2000);
      expect(controller.equityHistory.last.value, closeTo(2002, 0.01));
      expect(controller.pnlHistory.last.value, 0);

      controller.manualFlatten();

      expect(controller.balanceHistory.last.value, closeTo(2002, 0.01));
      expect(controller.equityHistory.last.value, closeTo(2002, 0.01));
      expect(controller.pnlHistory.last.value, closeTo(2, 0.01));
    },
  );

  test('closed pnl does not move when only balance changes', () async {
    final controller = AppController()
      ..config = const AppConfig(
        masterBalanceUsd: 10000,
        myBalanceUsd: 2000,
        markPrice: 100000,
      );

    await controller.loadChartData();
    await controller.saveConfig(
      controller.config.copyWith(myBalanceUsd: 2500),
      log: false,
    );

    expect(controller.balanceHistory.last.value, 2500);
    expect(controller.pnlHistory.last.value, 0);
  });
}
