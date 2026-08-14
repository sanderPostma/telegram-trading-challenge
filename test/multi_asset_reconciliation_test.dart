import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trading_challenge/src/bridge/interpreter.dart' show Asset;
import 'package:trading_challenge/src/bridge/weex.dart' as rust_weex;
import 'package:trading_challenge/src/state/app_controller.dart';

rust_weex.WeexExecutionSnapshot _execution({
  required String id,
  required String symbol,
  required double price,
  double qty = 0.1,
  double realizedPnl = 0,
  int timestampMs = 0,
}) {
  return rust_weex.WeexExecutionSnapshot(
    execId: id,
    orderId: id,
    symbol: symbol,
    side: 'buy',
    positionSide: 'long',
    kind: 'open',
    direction: 'long',
    price: price,
    qty: qty,
    notionalUsdt: price * qty,
    realizedPnlUsdt: realizedPnl,
    feeUsdt: 0,
    timestampMs: timestampMs,
  );
}

rust_weex.WeexAccountReconciliation _reconciliation({
  required String symbol,
  required double markPrice,
  String direction = 'flat',
  double qty = 0,
  List<rust_weex.WeexExecutionSnapshot> executions = const [],
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
      symbol: symbol,
      direction: direction,
      qty: qty,
      entryPrice: markPrice,
      markPrice: markPrice,
      notionalUsdt: qty * markPrice,
      unrealizedPnlUsdt: 0,
      leverage: 10,
      updatedAtMs: 0,
    ),
    recentExecutions: executions,
    timestampMs: 0,
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('each book keeps its own position and mark price', () {
    final c = AppController();

    c.applyWeexReconciliation(
      _reconciliation(
        symbol: 'BTCUSDT',
        markPrice: 63000,
        direction: 'long',
        qty: 0.5,
      ),
    );
    c.applyWeexReconciliation(
      _reconciliation(
        symbol: 'ETHUSDT',
        markPrice: 1877,
        direction: 'short',
        qty: 4,
      ),
    );

    expect(c.bookFor(Asset.btc).position.qty, 0.5);
    expect(c.bookFor(Asset.btc).markPrice, 63000);
    expect(c.bookFor(Asset.eth).position.qty, 4);
    expect(c.bookFor(Asset.eth).markPrice, 1877);
    expect(
      c.openAssets,
      containsAll([Asset.btc, Asset.eth]),
      reason: 'both books are open, so both must be listed',
    );
  });

  test('a reconcile is attributed by the symbol the exchange reports', () {
    final c = AppController();
    // selectedAsset is BTC, but this payload is for ETH.
    c.applyWeexReconciliation(
      _reconciliation(
        symbol: 'ETHUSDT',
        markPrice: 1877,
        direction: 'long',
        qty: 3,
      ),
    );

    expect(c.bookFor(Asset.eth).position.qty, 3);
    expect(
      c.bookFor(Asset.btc).position.isFlat,
      isTrue,
      reason: 'an ETH payload must not be written into the BTC book',
    );
  });

  test('trade history spans every book rather than the last one reconciled',
      () {
    // The regression: reconciling book by book used to replace trade history
    // on each pass, so the UI alternated between one asset's fills and the
    // other's on every poll.
    final c = AppController();

    c.applyWeexReconciliation(
      _reconciliation(
        symbol: 'BTCUSDT',
        markPrice: 63000,
        executions: [
          _execution(id: 'btc-1', symbol: 'BTCUSDT', price: 63196, timestampMs: 100),
        ],
      ),
      mergeExecutions: false,
    );
    c.applyWeexReconciliation(
      _reconciliation(
        symbol: 'ETHUSDT',
        markPrice: 1877,
        executions: [
          _execution(id: 'eth-1', symbol: 'ETHUSDT', price: 1877, timestampMs: 200),
        ],
      ),
      mergeExecutions: false,
    );
    c.applyAccountWideExecutionsForTest([
      _execution(id: 'btc-1', symbol: 'BTCUSDT', price: 63196, timestampMs: 100),
      _execution(id: 'eth-1', symbol: 'ETHUSDT', price: 1877, timestampMs: 200),
    ]);

    expect(c.tradeHistory.length, 2);
    expect(
      c.tradeHistory.map((e) => e.avgPrice),
      containsAll([63196.0, 1877.0]),
      reason: 'both books must appear at once, not alternately',
    );
  });

  test('a fill repeated across books is counted once', () {
    final c = AppController();
    c.applyAccountWideExecutionsForTest([
      _execution(id: 'dup', symbol: 'BTCUSDT', price: 63000, realizedPnl: 5),
      _execution(id: 'dup', symbol: 'BTCUSDT', price: 63000, realizedPnl: 5),
    ]);

    expect(
      c.tradeHistory.length,
      1,
      reason: 'each book is fetched separately; a repeated exec id would '
          'otherwise double-count its PnL',
    );
  });
}
