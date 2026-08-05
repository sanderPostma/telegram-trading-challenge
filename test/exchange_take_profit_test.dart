import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trading_challenge/src/models/trading.dart';
import 'package:trading_challenge/src/state/app_controller.dart';

AppController _controllerWithPosition({
  TradeDirection? direction,
  double qtyBtc = 0.0055,
  bool simulationMode = false,
}) {
  return AppController()
    ..config = AppConfig(
      masterBalanceUsd: 10000,
      myBalanceUsd: 2000,
      markPrice: 64000,
      simulationMode: simulationMode,
    )
    ..position = direction == null
        ? const PositionView(
            direction: null,
            qtyBtc: 0,
            notionalUsd: 0,
            unrealizedPnlUsd: 0,
          )
        : PositionView(
            direction: direction,
            qtyBtc: qtyBtc,
            notionalUsd: qtyBtc * 64000,
            unrealizedPnlUsd: 0,
          );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a target with no open position sets nothing', () async {
    final controller = _controllerWithPosition(direction: null);

    await controller.setExchangeTakeProfit(
      low: 64450,
      high: 64450,
      source: 'Telegram',
    );

    expect(controller.exchangeTakeProfit, isNull);
    // Nothing to attach a plan to, so no app-side watch either.
    expect(controller.closeTargetWatch, isNull);
  });

  test('falls back to the app-side watch without live exchange access',
      () async {
    // No Rust bridge in tests, so the exchange cannot hold the plan. The target
    // must not be dropped silently.
    final controller = _controllerWithPosition(direction: TradeDirection.long);

    await controller.setExchangeTakeProfit(
      low: 64450,
      high: 64500,
      source: 'Telegram',
    );

    expect(controller.exchangeTakeProfit, isNull);
    expect(controller.closeTargetWatch, isNotNull);
    expect(controller.closeTargetWatch!.low, 64450);
    expect(controller.closeTargetWatch!.high, 64500);
  });

  test('simulation mode keeps the target app-side', () async {
    final controller = _controllerWithPosition(
      direction: TradeDirection.short,
      simulationMode: true,
    );

    await controller.setExchangeTakeProfit(
      low: 63500,
      high: 63500,
      source: 'Telegram',
    );

    expect(controller.exchangeTakeProfit, isNull);
    expect(controller.closeTargetWatch, isNotNull);
  });

  test('a reversed range is normalized before use', () async {
    final controller = _controllerWithPosition(direction: TradeDirection.long);

    await controller.setExchangeTakeProfit(
      low: 64500,
      high: 64450,
      source: 'Telegram',
    );

    expect(controller.closeTargetWatch!.low, 64450);
    expect(controller.closeTargetWatch!.high, 64500);
  });

  test('the take-profit record survives a round trip through storage', () {
    final tp = ExchangeTakeProfit(
      orderId: '812345678901234900',
      triggerPrice: 64450,
      direction: TradeDirection.short,
      planType: 'STOP_LOSS',
      source: 'Telegram',
      placedAt: DateTime.utc(2026, 8, 5, 16, 11),
    );

    final restored = ExchangeTakeProfit.fromJson(tp.toJson());

    expect(restored, isNotNull);
    expect(restored!.orderId, tp.orderId);
    expect(restored.triggerPrice, tp.triggerPrice);
    expect(restored.direction, TradeDirection.short);
    expect(restored.isStop, isTrue);
    expect(restored.placedAt, tp.placedAt);
  });
}
