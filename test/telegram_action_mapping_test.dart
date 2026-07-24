import 'package:flutter_test/flutter_test.dart';
import 'package:trading_challenge/src/bridge/interpreter.dart' as rust;
import 'package:trading_challenge/src/models/trading.dart';
import 'package:trading_challenge/src/state/app_controller.dart';

void main() {
  group('tradeKindFromParsed', () {
    test('CLOSE is never automated (exits are manual-only)', () {
      // Locks the safety net: the broad "close" pattern (which also matches
      // "so close", "close to", "close the trade" in commentary) must never
      // produce an automated order. A regression here would let stray prose
      // flatten a live position.
      expect(AppController.tradeKindFromParsed(rust.ActionKind.close), isNull);
    });

    test('IGNORE never trades', () {
      expect(AppController.tradeKindFromParsed(rust.ActionKind.ignore), isNull);
    });

    test('enter/add/reduce map to their automatable kinds', () {
      expect(
        AppController.tradeKindFromParsed(rust.ActionKind.enter),
        TradeKind.enter,
      );
      expect(
        AppController.tradeKindFromParsed(rust.ActionKind.add),
        TradeKind.add,
      );
      expect(
        AppController.tradeKindFromParsed(rust.ActionKind.reduce),
        TradeKind.reduce,
      );
    });
  });

  group('closeDisposition', () {
    const openPosition = PositionView(
      direction: TradeDirection.short,
      qtyBtc: 0.5,
      notionalUsd: 30000,
      unrealizedPnlUsd: 0,
    );
    const flatPosition = PositionView(
      direction: null,
      qtyBtc: 0,
      notionalUsd: 0,
      unrealizedPnlUsd: 0,
    );

    test('auto-approve ON never auto-closes, even with an open position', () {
      expect(
        AppController.closeDisposition(
          autoApprove: true,
          position: openPosition,
        ),
        TelegramCloseDisposition.ignoredAutoApprove,
      );
    });

    test('auto-approve OFF with an open position queues for approval', () {
      expect(
        AppController.closeDisposition(
          autoApprove: false,
          position: openPosition,
        ),
        TelegramCloseDisposition.queueForApproval,
      );
    });

    test('auto-approve OFF with no position does nothing', () {
      expect(
        AppController.closeDisposition(
          autoApprove: false,
          position: flatPosition,
        ),
        TelegramCloseDisposition.ignoredNoPosition,
      );
    });
  });
}
