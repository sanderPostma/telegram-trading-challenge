import 'package:flutter_test/flutter_test.dart';
import 'package:trading_challenge/src/models/trading.dart';
import 'package:trading_challenge/src/state/app_controller.dart';

void main() {
  // Regression: a 100% reduce (and the Close Position button, which shares the
  // same lot rounding) must ask for the whole position. Flooring qty/step in
  // binary floating point turns 0.0055 / 0.0001 into 54.99999999999999, which
  // floors to 54 and silently leaves one lot of dust behind. The exchange then
  // reports the fill as a partial reduce, not a close.
  test('full reduce covers the whole position for dust-prone lot sizes', () {
    for (final qty in [0.0055, 0.0029, 0.0031, 0.0011, 0.0007, 0.0054]) {
      final controller = AppController()
        ..config = const AppConfig(
          masterBalanceUsd: 10000,
          myBalanceUsd: 2000,
          markPrice: 64000,
        )
        ..position = PositionView(
          direction: TradeDirection.long,
          qty: qty,
          notionalUsd: qty * 64000,
          unrealizedPnlUsd: 0,
        );

      final reduceBtc = controller.previewManualReduceBtc(
        amount: 100,
        unit: SizeUnit.usdt,
        isPercent: true,
      );
      expect(
        reduceBtc,
        closeTo(qty, 1e-9),
        reason: '100% reduce of $qty BTC must leave no dust',
      );
    }
  });

  test('lot rounding keeps whole lots and never rounds up', () {
    expect(roundDownToLot(0.0055, 0.0001), closeTo(0.0055, 1e-12));
    expect(roundDownToLot(0.0031, 0.0001), closeTo(0.0031, 1e-12));
    expect(roundDownToLot(0.00559, 0.0001), closeTo(0.0055, 1e-12));
    expect(roundDownToLot(0.00005, 0.0001), 0);
    expect(roundDownToLot(0.0055, 0), 0.0055);
  });

  group('verified flatten loop', () {
    FlattenStep step(double remaining, int attempt) => flattenStep(
      remainingBtc: remaining,
      lotStep: 0.0001,
      attempt: attempt,
      maxAttempts: 3,
    );

    test('submits while whole lots remain within the attempt budget', () {
      expect(step(0.0055, 1), FlattenStep.submit);
      // A residual left by a partial fill is re-submitted, not abandoned.
      expect(step(0.0001, 2), FlattenStep.submit);
      expect(step(0.0001, 3), FlattenStep.submit);
    });

    test('stops once the exchange reports flat', () {
      expect(step(0, 1), FlattenStep.done);
      expect(step(0, 3), FlattenStep.done);
    });

    test('reports sub-lot dust instead of looping on it forever', () {
      // Below one lot nothing can be submitted, so retrying would never
      // terminate.
      expect(step(0.00005, 2), FlattenStep.dust);
      expect(step(0.00009, 9), FlattenStep.dust);
    });

    test('gives up after the attempt budget while lots still remain', () {
      expect(step(0.0002, 4), FlattenStep.giveUp);
    });
  });
}
