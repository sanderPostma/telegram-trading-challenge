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
      qty: 0.5,
      notionalUsd: 30000,
      unrealizedPnlUsd: 0,
    );
    const flatPosition = PositionView(
      direction: null,
      qty: 0,
      notionalUsd: 0,
      unrealizedPnlUsd: 0,
    );

    test('auto-approve ON with an open position flattens immediately', () {
      // A close follows the auto-approve toggle like any other action. It can
      // only reduce exposure, so executing one unattended cannot grow a
      // position.
      expect(
        AppController.closeDisposition(
          autoApprove: true,
          position: openPosition,
        ),
        TelegramCloseDisposition.executeImmediately,
      );
    });

    test('an ambiguous asset queues even under auto-approve', () {
      // Auto-approve says "act without asking"; it does not say which book to
      // flatten. Guessing wrong here closes a position nobody asked to close.
      expect(
        AppController.closeDisposition(
          autoApprove: true,
          position: openPosition,
          assetAmbiguous: true,
        ),
        TelegramCloseDisposition.queueForApproval,
      );
    });

    test('an ambiguous asset with no position is still a no-op', () {
      expect(
        AppController.closeDisposition(
          autoApprove: true,
          position: flatPosition,
          assetAmbiguous: true,
        ),
        TelegramCloseDisposition.ignoredNoPosition,
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

    test('no open position does nothing, regardless of auto-approve', () {
      expect(
        AppController.closeDisposition(
          autoApprove: true,
          position: flatPosition,
        ),
        TelegramCloseDisposition.ignoredNoPosition,
      );
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
