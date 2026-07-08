import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../bridge/api.dart' as rust;
import '../bridge/scaling.dart' as rust_scaling;
import '../bridge/weex.dart' as rust_weex;
import '../models/trading.dart';

enum WeexPriceStatus { idle, connecting, live, unavailable }

class AppController extends ChangeNotifier {
  AppController({this.useRustBridge = false});

  static const _configPrefsKey = 'trading_challenge.app_config.v1';
  static const _klineCachePrefsKey = 'trading_challenge.weex_kline_cache.v1';
  static const _chartSnapshotInterval = Duration(minutes: 1);
  static const _exchangeReconcileInterval = Duration(seconds: 5);
  static const _exchangeHistoryLookback = Duration(days: 30);
  static const _historicalCandleCacheFreshFor = Duration(minutes: 10);
  static const _weexPriceStaleAfter = Duration(seconds: 20);

  final bool useRustBridge;
  StreamSubscription? _weexPriceSubscription;
  Timer? _weexRestPollTimer;
  Timer? _weexReconcileTimer;
  Timer? _chartSnapshotTimer;
  bool _weexRestPollInFlight = false;
  bool _weexReconcileInFlight = false;
  bool _hasExchangePnlBaseline = false;
  String? _lastWeexPriceSource;
  DateTime? _lastWeexPriceAt;
  DateTime? _lastChartSnapshotAt;
  double _exchangeRealizedPnlUsd = 0;
  double _localRealizedPnlUsd = 0;
  List<PriceCandle> _historicalCandleCache = const [];
  Future<List<PriceCandle>>? _historicalCandleFetch;
  DateTime? _historicalCandleCacheLoadedAt;
  bool _historicalCandlePrefsLoaded = false;
  List<rust_weex.WeexExecutionSnapshot> _reconciledExecutionCache = const [];
  AppConfig config = const AppConfig();
  List<SeriesPoint> balanceHistory = const [];
  List<SeriesPoint> equityHistory = const [];
  List<SeriesPoint> pnlHistory = const [];

  bool forceSetup = false;

  bool get requiresSetup =>
      forceSetup ||
      config.weexApiKey.isEmpty ||
      config.weexSecret.isEmpty ||
      config.weexPassphrase.isEmpty;

  void restartSetup() {
    forceSetup = true;
    notifyListeners();
  }

  void finishSetup() {
    forceSetup = false;
    notifyListeners();
  }

  final List<PatternRule> patterns = [
    const PatternRule(
      name: 'entry',
      regex:
          r'(?i)\bSTARTED\b.*?(?P<btc>[\d.]+)\s*BTC.*?\b(?P<dir>SHORT|LONG)\b',
      action: TradeKind.enter,
      priority: 10,
    ),
    const PatternRule(
      name: 'add_usd',
      regex: r'(?i)\bADDED\b\s*\$(?P<usd>[\d,]+)',
      action: TradeKind.add,
      priority: 20,
    ),
    const PatternRule(
      name: 'add_btc',
      regex: r'(?i)\bADDED\b\s*(?P<btc>[\d.]+)\s*BTC',
      action: TradeKind.add,
      priority: 21,
    ),
    const PatternRule(
      name: 'reduce_pct',
      regex: r'(?i)\bREDUCE[D]?\b.*?(?P<pct>\d+)\s*%',
      action: TradeKind.reduce,
      priority: 30,
    ),
    const PatternRule(
      name: 'close',
      regex:
          r'(?i)\b(CLOSED|CLOSE|EXIT|EXITED|FLAT|STOPPED OUT|TP HIT|TOOK PROFIT)\b',
      action: TradeKind.close,
      priority: 40,
    ),
  ];

  final List<String> eventLog = [
    'Telegram monitor is running. Simulation mode logs orders locally instead of submitting to WEEX.',
  ];
  final List<PlannedOrder> orders = [];
  List<TradeHistoryEntry> tradeHistory = const [];
  final Set<String> _reservedIds = {};

  bool monitorRunning = true;
  bool weexPriceConnected = false;
  bool weexAccountConnected = false;
  WeexPriceStatus weexPriceStatus = WeexPriceStatus.idle;
  String? weexPriceError;
  String? weexReconciliationError;
  PlannedOrder? pendingApproval;
  PositionView position = const PositionView(
    direction: null,
    qtyBtc: 0,
    notionalUsd: 0,
    unrealizedPnlUsd: 0,
  );

  Future<void> loadConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_configPrefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        _log('Saved settings ignored: unexpected format.');
        return;
      }
      config = AppConfig.fromPersistentJson(
        Map<String, Object?>.from(decoded),
      ).copyWith(autoUpdateMaster: true);
    } catch (error) {
      _log('Saved settings could not be loaded: $error');
    }
    _resetLocalChartHistory();
  }

  Future<void> loadChartData() async {
    if (!useRustBridge) {
      _snapshotChartState(force: true, mirrorToRust: false, notify: false);
      return;
    }

    try {
      final data = await rust.getChartData();
      balanceHistory = _bridgePoints(data.balance);
      equityHistory = _bridgePoints(data.equity);
      pnlHistory = _bridgePoints(data.pnl);
    } catch (error) {
      _log('Chart history could not be loaded from Rust: $error');
    }

    if (balanceHistory.isEmpty && equityHistory.isEmpty && pnlHistory.isEmpty) {
      await _snapshotChartState(force: true, notify: false);
    } else {
      notifyListeners();
    }
  }

  PlannedOrder previewManualOrder(
    double amount,
    SizeUnit unit,
    TradeDirection direction,
  ) {
    return _buildOrder(
      kind: TradeKind.manual,
      direction: direction,
      sourceAmount: amount,
      sourceUnit: unit,
      source: 'Manual dashboard order',
      status: TradeStatus.pendingApproval,
    );
  }

  Future<void> openManualTrade({
    required double amount,
    required SizeUnit unit,
    required TradeDirection direction,
  }) async {
    if (amount <= 0 || !amount.isFinite) {
      _log('Manual order rejected: enter a positive BTC or USDT amount.');
      return;
    }
    if (config.markPrice <= 0) {
      _log('Manual order rejected: waiting for live WEEX BTC price.');
      return;
    }

    final fallbackOrder = _buildOrder(
      kind: TradeKind.manual,
      direction: direction,
      sourceAmount: amount,
      sourceUnit: unit,
      source:
          'Manual ${direction.name.toUpperCase()} ${amount.toStringAsFixed(unit == SizeUnit.btc ? 4 : 2)} ${unit.name.toUpperCase()}',
      status: TradeStatus.pendingApproval,
    );
    _log(
      'Manual trade requested: ${direction.name.toUpperCase()} ${amount.toStringAsFixed(unit == SizeUnit.btc ? 4 : 2)} ${unit.name.toUpperCase()}, mark ${config.markPrice.toStringAsFixed(2)} USDT.',
    );
    final rustScaled = await _scaleWithRust(amount: amount, unit: unit);
    final order = rustScaled == null
        ? fallbackOrder
        : fallbackOrder.copyWithScaled(
            scaledBtc: rustScaled.qtyBtc,
            scaledNotionalUsd: rustScaled.notionalUsd,
          );

    if (_reservedIds.contains(order.id)) {
      _log('Skipped duplicate manual order reservation ${order.id}.');
      return;
    }
    _reservedIds.add(order.id);
    _log(
      'Manual trade scaled: ${order.scaledBtc.toStringAsFixed(4)} BTC, ${order.scaledNotionalUsd.toStringAsFixed(2)} USDT.',
    );

    if (config.autoApprove) {
      await _place(order);
    } else {
      pendingApproval = order;
      orders.insert(0, order);
      _log('Approval required for ${_describe(order)}.');
      notifyListeners();
    }
  }

  Future<rust_scaling.ScaledOrder?> _scaleWithRust({
    required double amount,
    required SizeUnit unit,
  }) async {
    if (!useRustBridge) return null;
    try {
      final result = await rust.scaleManualOrder(
        request: rust.ManualScaleRequest(
          amount: amount,
          unit: unit == SizeUnit.btc
              ? rust.ManualSizeUnit.btc
              : rust.ManualSizeUnit.usdt,
          masterBalanceUsd: config.masterBalanceUsd,
          myBalanceUsd: config.myBalanceUsd,
          markPrice: config.markPrice,
          qtyStep: 0.0001,
        ),
      );
      if (result.ok) return result.value;
      _log(
        'Rust scaling rejected manual order: ${result.error ?? 'unknown error'}',
      );
    } catch (error) {
      _log('Rust scaling failed, using Dart fallback: $error');
    }
    return null;
  }

  void startWeexPriceStream() {
    if (_weexPriceSubscription != null) return;
    _startChartSnapshotTimer();
    weexPriceStatus = WeexPriceStatus.connecting;
    weexPriceError = null;
    notifyListeners();
    _startWeexRestPolling();
    _startWeexReconciliation();
    if (!useRustBridge) {
      _log('Rust bridge unavailable. Using WEEX REST live price polling.');
      return;
    }
    _weexPriceSubscription = rust.weexPublicPriceStream().listen(
      (tick) {
        if (tick.ok && tick.price != null && tick.price! > 0) {
          _applyWeexPrice(tick.price!, source: 'WEEX WebSocket ${tick.source}');
        } else {
          _handleWeexPriceFailure(
            tick.error ?? 'WEEX WebSocket price unavailable',
          );
        }
      },
      onError: (Object error) {
        _handleWeexPriceFailure('WEEX WebSocket failed: $error');
      },
    );
    _log('WEEX public price stream connecting.');
  }

  void _startWeexReconciliation() {
    _weexReconcileTimer?.cancel();
    if (!useRustBridge) return;
    if (!_hasWeexCredentials) {
      weexAccountConnected = false;
      weexReconciliationError =
          'WEEX account reconciliation needs API credentials.';
      return;
    }
    unawaited(reconcileFromExchange());
    _weexReconcileTimer = Timer.periodic(
      _exchangeReconcileInterval,
      (_) => unawaited(reconcileFromExchange()),
    );
  }

  Future<void> reconcileFromExchange() async {
    if (!useRustBridge || _weexReconcileInFlight || !_hasWeexCredentials) {
      return;
    }
    _weexReconcileInFlight = true;
    try {
      final result = await rust.weexReconcileAccount(
        request: rust_weex.WeexAccountRequest(
          apiKey: config.weexApiKey,
          apiSecret: config.weexSecret,
          passphrase: config.weexPassphrase,
          symbol: 'BTCUSDT',
          baseUrl: 'https://api-contract.weex.com',
          recentLookbackMs: _exchangeHistoryLookback.inMilliseconds,
        ),
      );
      if (!result.ok || result.value == null) {
        throw StateError(
          result.error ?? 'WEEX reconciliation returned no data',
        );
      }
      final candles = await _getHistoricalCandles();
      _applyWeexReconciliation(result.value!, candles: candles);
    } catch (error) {
      weexAccountConnected = false;
      weexReconciliationError = error.toString();
      _log('WEEX account reconciliation failed: $error');
      notifyListeners();
    } finally {
      _weexReconcileInFlight = false;
    }
  }

  void _startWeexRestPolling() {
    _weexRestPollTimer?.cancel();
    unawaited(_pollWeexRestPrice());
    _weexRestPollTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_pollWeexRestPrice()),
    );
  }

  Future<void> _pollWeexRestPrice() async {
    if (_weexRestPollInFlight) return;
    _weexRestPollInFlight = true;
    try {
      final snapshot = await fetchWeexRestPrice();
      if (snapshot != null && snapshot.price > 0) {
        _applyWeexPrice(snapshot.price, source: snapshot.source);
      }
    } catch (error) {
      _handleWeexPriceFailure('WEEX REST price failed: $error');
    } finally {
      _weexRestPollInFlight = false;
    }
  }

  void _applyWeexPrice(double price, {required String source}) {
    _lastWeexPriceAt = DateTime.now();
    config = config.copyWith(markPrice: price);
    _markPositionToMarket(price);
    weexPriceConnected = true;
    weexPriceStatus = WeexPriceStatus.live;
    weexPriceError = null;
    if (_lastWeexPriceSource != source) {
      _lastWeexPriceSource = source;
      _log('WEEX BTC price live via $source.');
    }
    unawaited(_snapshotChartState());
    notifyListeners();
  }

  void _handleWeexPriceFailure(String message) {
    weexPriceError = message;
    if (_hasFreshWeexPrice) {
      weexPriceConnected = true;
      weexPriceStatus = WeexPriceStatus.live;
      notifyListeners();
      return;
    }
    weexPriceConnected = false;
    weexPriceStatus = WeexPriceStatus.unavailable;
    _log('WEEX price unavailable: $message');
    notifyListeners();
  }

  bool get _hasFreshWeexPrice {
    final last = _lastWeexPriceAt;
    return last != null &&
        config.markPrice > 0 &&
        DateTime.now().difference(last) < _weexPriceStaleAfter;
  }

  bool get _hasWeexCredentials =>
      config.weexApiKey.trim().isNotEmpty &&
      config.weexSecret.trim().isNotEmpty &&
      config.weexPassphrase.trim().isNotEmpty;

  void _applyWeexReconciliation(
    rust_weex.WeexAccountReconciliation update, {
    List<PriceCandle> candles = const [],
  }) {
    final balance = update.balance;
    final exchangeBalance = balance.walletBalance;
    if (exchangeBalance > 0 && exchangeBalance.isFinite) {
      if (!_hasExchangePnlBaseline) {
        _hasExchangePnlBaseline = true;
        if (balanceHistory.length <= 1 && equityHistory.length <= 1) {
          balanceHistory = const [];
          equityHistory = const [];
          pnlHistory = const [];
          _lastChartSnapshotAt = null;
        }
      }
      config = config.copyWith(myBalanceUsd: exchangeBalance);
    }

    final reconciledPosition = update.position;
    final direction = _directionFromExchange(reconciledPosition.direction);
    final markPrice = reconciledPosition.markPrice > 0
        ? reconciledPosition.markPrice
        : config.markPrice;
    if (markPrice > 0) {
      config = config.copyWith(markPrice: markPrice);
    }
    position = PositionView(
      direction: direction,
      qtyBtc: direction == null ? 0 : reconciledPosition.qtyBtc,
      notionalUsd: direction == null
          ? 0
          : reconciledPosition.notionalUsdt > 0
          ? reconciledPosition.notionalUsdt
          : reconciledPosition.qtyBtc * reconciledPosition.entryPrice,
      unrealizedPnlUsd: direction == null
          ? 0
          : reconciledPosition.unrealizedPnlUsdt,
    );
    _mergeReconciledExecutions(update.recentExecutions, candles: candles);
    weexAccountConnected = true;
    weexReconciliationError = null;
    unawaited(_snapshotChartState(force: true));
    notifyListeners();
  }

  void setWeexPriceUnavailable(String message) {
    weexPriceConnected = false;
    weexPriceStatus = WeexPriceStatus.unavailable;
    weexPriceError = message;
    _log('WEEX price stream unavailable: $message');
    notifyListeners();
  }

  void approvePending() {
    final order = pendingApproval;
    if (order == null) return;
    pendingApproval = null;
    unawaited(_place(order));
  }

  void rejectPending() {
    final order = pendingApproval;
    if (order == null) return;
    pendingApproval = null;
    _replaceOrder(order.copyWith(status: TradeStatus.rejected));
    _log('Rejected ${_describe(order)}.');
    notifyListeners();
  }

  void manualFlatten() {
    if (position.isFlat) {
      _log('Manual flatten ignored: no open position.');
      notifyListeners();
      return;
    }
    final realizedPnl = position.unrealizedPnlUsd;
    _localRealizedPnlUsd += realizedPnl;
    config = config.copyWith(myBalanceUsd: config.myBalanceUsd + realizedPnl);
    position = const PositionView(
      direction: null,
      qtyBtc: 0,
      notionalUsd: 0,
      unrealizedPnlUsd: 0,
    );
    _log(
      'Position flattened in simulation state. Realized ${realizedPnl.toStringAsFixed(2)} USDT.',
    );
    unawaited(_persistConfig());
    unawaited(_snapshotChartState(force: true));
    notifyListeners();
  }

  Future<void> saveConfig(AppConfig next, {bool log = true}) async {
    config = next;
    _markPositionToMarket(config.markPrice);
    if (log) _log('Settings updated.');
    unawaited(_snapshotChartState(force: true, notify: false));
    _startWeexReconciliation();
    notifyListeners();
    await _persistConfig();
  }

  void setAutoApprove(bool value) {
    config = config.copyWith(autoApprove: value);
    _log('Auto-approve ${value ? 'enabled' : 'disabled'}.');
    unawaited(_persistConfig());
    notifyListeners();
  }

  void setSimulationMode(bool value) {
    config = config.copyWith(simulationMode: value);
    _log('Simulation mode ${value ? 'enabled' : 'disabled'}.');
    unawaited(_persistConfig());
    notifyListeners();
  }

  Future<void> _persistConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _configPrefsKey,
        jsonEncode(config.toPersistentJson()),
      );
    } catch (error) {
      _log('Settings could not be saved: $error');
      notifyListeners();
    }
  }

  Future<void> refreshChartHistoryFromCachedExchange() async {
    final executions = _reconciledExecutionCache;
    if (executions.isEmpty) return;
    final candles = await _getHistoricalCandles();
    _rebuildChartHistoryFromTrades(executions: executions, candles: candles);
    await _snapshotChartState(force: true, notify: false);
    notifyListeners();
  }

  Future<List<PriceCandle>> _getHistoricalCandles() async {
    await _loadHistoricalCandleCache();
    if (_hasUsableHistoricalCandleCache()) {
      return Future.value(_historicalCandleCache);
    }
    final inFlight = _historicalCandleFetch;
    if (inFlight != null) return inFlight;

    final fetch = fetchWeexHistoricalCandles()
        .then((candles) async {
          _historicalCandleCache = candles;
          _historicalCandleCacheLoadedAt = DateTime.now();
          _historicalCandleFetch = null;
          await _persistHistoricalCandleCache(candles);
          return candles;
        })
        .catchError((Object error) {
          _historicalCandleFetch = null;
          _log('WEEX historical candles could not be loaded: $error');
          return _historicalCandleCache;
        });
    _historicalCandleFetch = fetch;
    return fetch;
  }

  bool _hasUsableHistoricalCandleCache() {
    if (_historicalCandleCache.isEmpty) return false;
    final loadedAt = _historicalCandleCacheLoadedAt;
    if (loadedAt != null &&
        DateTime.now().difference(loadedAt) < _historicalCandleCacheFreshFor) {
      return true;
    }
    return _historicalCandleCache.last.timestampMs >=
        DateTime.now()
            .subtract(const Duration(minutes: 20))
            .millisecondsSinceEpoch;
  }

  Future<void> _loadHistoricalCandleCache() async {
    if (_historicalCandlePrefsLoaded) return;
    _historicalCandlePrefsLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_klineCachePrefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final fetchedAtMs = _jsonInt(decoded['fetchedAtMs']);
      final items = decoded['candles'];
      if (fetchedAtMs == null || items is! List) return;
      final candles = <PriceCandle>[];
      for (final item in items) {
        if (item is! List || item.length < 2) continue;
        final timestamp = _jsonInt(item[0]);
        final close = _jsonDouble(item[1]);
        if (timestamp != null && close != null && close > 0) {
          candles.add(PriceCandle(timestampMs: timestamp, close: close));
        }
      }
      candles.sort((a, b) => a.timestampMs.compareTo(b.timestampMs));
      _historicalCandleCache = candles;
      _historicalCandleCacheLoadedAt = DateTime.fromMillisecondsSinceEpoch(
        fetchedAtMs,
      );
    } catch (error) {
      _log('WEEX historical candle cache could not be loaded: $error');
    }
  }

  Future<void> _persistHistoricalCandleCache(List<PriceCandle> candles) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _klineCachePrefsKey,
        jsonEncode({
          'fetchedAtMs': DateTime.now().millisecondsSinceEpoch,
          'candles': [
            for (final candle in candles) [candle.timestampMs, candle.close],
          ],
        }),
      );
    } catch (error) {
      _log('WEEX historical candle cache could not be saved: $error');
    }
  }

  void updatePattern(int index, PatternRule rule) {
    patterns[index] = rule;
    _log('Pattern ${rule.name} saved.');
    notifyListeners();
  }

  PlannedOrder _buildOrder({
    required TradeKind kind,
    required TradeDirection direction,
    required double sourceAmount,
    required SizeUnit sourceUnit,
    required String source,
    required TradeStatus status,
  }) {
    final ratio = config.scaleRatio;
    final mark = config.markPrice;
    final scaledBtc = sourceUnit == SizeUnit.btc
        ? sourceAmount * ratio
        : mark > 0
        ? (sourceAmount * ratio) / mark
        : 0.0;
    final notional = mark > 0 ? scaledBtc * mark : 0.0;
    final now = DateTime.now();
    final nonce = '${now.microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}';
    return PlannedOrder(
      id: nonce,
      kind: kind,
      direction: direction,
      sourceAmount: sourceAmount,
      sourceUnit: sourceUnit,
      scaledBtc: _roundDown(scaledBtc, 0.0001),
      scaledNotionalUsd: notional,
      markPrice: mark,
      createdAt: now,
      status: status,
      source: source,
    );
  }

  double _roundDown(double value, double step) {
    if (step <= 0) return value;
    return (value / step).floorToDouble() * step;
  }

  Future<void> _place(PlannedOrder order) async {
    if (!config.simulationMode) {
      _replaceOrder(order.copyWith(status: TradeStatus.pendingApproval));
      notifyListeners();
      _log('Live WEEX submit starting for ${_describe(order)}.');
      final ack = await _submitLiveOrder(order);
      if (ack == null) {
        _replaceOrder(order.copyWith(status: TradeStatus.failed));
        notifyListeners();
        return;
      }
      _log('WEEX accepted order ${ack.orderId}. Waiting for reconciliation.');
    }

    final placed = order.copyWith(
      status: config.simulationMode
          ? TradeStatus.simulated
          : TradeStatus.placed,
    );
    _replaceOrder(placed);
    position = PositionView(
      direction: placed.direction,
      qtyBtc: placed.scaledBtc,
      notionalUsd: placed.scaledNotionalUsd,
      unrealizedPnlUsd: 0,
    );
    _log(
      '${config.simulationMode ? 'Simulated' : 'Placed'} ${_describe(placed)}.',
    );
    unawaited(_snapshotChartState(force: true));
    if (!config.simulationMode) {
      unawaited(reconcileFromExchange());
    }
    notifyListeners();
  }

  Future<rust_weex.WeexMarketOrderAck?> _submitLiveOrder(
    PlannedOrder order,
  ) async {
    if (!useRustBridge) {
      _log('Live WEEX submit failed: Rust bridge is unavailable.');
      return null;
    }
    if (!_hasWeexCredentials) {
      _log('Live WEEX submit failed: API key, secret, or passphrase is empty.');
      return null;
    }
    final side = order.direction == TradeDirection.long ? 'buy' : 'sell';
    _log(
      'Submitting WEEX MARKET $side ${order.scaledBtc.toStringAsFixed(4)} BTC (${order.scaledNotionalUsd.toStringAsFixed(2)} USDT), simulation OFF.',
    );
    try {
      final result = await rust.weexSubmitMarketOrder(
        request: rust_weex.WeexMarketOrderRequest(
          apiKey: config.weexApiKey,
          apiSecret: config.weexSecret,
          passphrase: config.weexPassphrase,
          symbol: 'BTCUSDT',
          baseUrl: 'https://api-contract.weex.com',
          side: side,
          qtyBtc: order.scaledBtc,
          reduceOnly: false,
          clientOrderId: 'tmg-${order.id}',
          qtyStep: 0.0001,
        ),
      );
      if (result.ok && result.value != null) return result.value;
      _log('Live WEEX submit rejected: ${result.error ?? 'unknown error'}');
    } catch (error) {
      _log('Live WEEX submit failed: $error');
    }
    return null;
  }

  void _resetLocalChartHistory() {
    _hasExchangePnlBaseline = false;
    _lastChartSnapshotAt = null;
    _exchangeRealizedPnlUsd = 0;
    _localRealizedPnlUsd = 0;
    balanceHistory = const [];
    equityHistory = const [];
    pnlHistory = const [];
  }

  void _startChartSnapshotTimer() {
    _chartSnapshotTimer?.cancel();
    unawaited(_snapshotChartState(force: true, notify: false));
    _chartSnapshotTimer = Timer.periodic(
      _chartSnapshotInterval,
      (_) => unawaited(_snapshotChartState(force: true)),
    );
  }

  Future<void> _snapshotChartState({
    bool force = false,
    bool mirrorToRust = true,
    bool notify = true,
  }) async {
    final now = DateTime.now();
    if (!force &&
        _lastChartSnapshotAt != null &&
        now.difference(_lastChartSnapshotAt!) < _chartSnapshotInterval) {
      return;
    }
    _lastChartSnapshotAt = now;

    final pointTs = now.millisecondsSinceEpoch;
    final balance = config.myBalanceUsd;
    final equity = balance + position.unrealizedPnlUsd;
    final pnl = _currentRealizedPnlUsd;
    final balancePoint = SeriesPoint(pointTs, balance);
    final equityPoint = SeriesPoint(pointTs, equity);
    final pnlPoint = SeriesPoint(pointTs, pnl);

    balanceHistory = _appendPoint(balanceHistory, balancePoint);
    equityHistory = _appendPoint(equityHistory, equityPoint);
    pnlHistory = _appendPoint(pnlHistory, pnlPoint);

    if (mirrorToRust && useRustBridge) {
      try {
        await rust.recordChartSnapshot(
          timestampMs: pointTs,
          balance: balance,
          equity: equity,
          cumulativePnl: pnl,
        );
      } catch (error) {
        _log('Chart history snapshot could not be written to Rust: $error');
      }
    }

    if (notify) notifyListeners();
  }

  double get _currentRealizedPnlUsd =>
      _exchangeRealizedPnlUsd + _localRealizedPnlUsd;

  List<SeriesPoint> _appendPoint(List<SeriesPoint> series, SeriesPoint point) {
    final next = List<SeriesPoint>.of(series);
    if (next.isNotEmpty && next.last.ts == point.ts) {
      next[next.length - 1] = point;
    } else {
      next.add(point);
    }
    if (next.length > 1440) {
      return next.sublist(next.length - 1440);
    }
    return next;
  }

  List<SeriesPoint> _bridgePoints(List<rust.SeriesPoint> points) {
    return [
      for (final point in points) SeriesPoint(point.timestampMs, point.value),
    ];
  }

  void _markPositionToMarket(double markPrice) {
    if (position.isFlat || markPrice <= 0 || position.qtyBtc <= 0) return;
    final entryPrice = position.notionalUsd / position.qtyBtc;
    final pnl = switch (position.direction) {
      TradeDirection.long => (markPrice - entryPrice) * position.qtyBtc,
      TradeDirection.short => (entryPrice - markPrice) * position.qtyBtc,
      null => 0.0,
    };
    position = PositionView(
      direction: position.direction,
      qtyBtc: position.qtyBtc,
      notionalUsd: position.notionalUsd,
      unrealizedPnlUsd: pnl,
    );
  }

  void _rebuildChartHistoryFromTrades({
    required List<rust_weex.WeexExecutionSnapshot> executions,
    required List<PriceCandle> candles,
  }) {
    if (executions.isEmpty) return;

    final sortedExecutions = List<rust_weex.WeexExecutionSnapshot>.of(
      executions,
    )..sort((a, b) => a.timestampMs.compareTo(b.timestampMs));
    final firstTradeTs = sortedExecutions.first.timestampMs;
    final nowTs = DateTime.now().millisecondsSinceEpoch;

    final totalBalanceImpact = sortedExecutions.fold<double>(
      0,
      (sum, execution) => sum + execution.realizedPnlUsdt + execution.feeUsdt,
    );
    var runningBalance = config.myBalanceUsd - totalBalanceImpact;
    var runningRealized = 0.0;

    final currentSignedQty = switch (position.direction) {
      TradeDirection.long => position.qtyBtc,
      TradeDirection.short => -position.qtyBtc,
      null => 0.0,
    };
    final returnedDelta = sortedExecutions.fold<double>(
      0,
      (sum, execution) => sum + _executionSignedDelta(execution),
    );
    var signedQty = currentSignedQty - returnedDelta;
    var avgEntry = signedQty.abs() > 0 && position.qtyBtc > 0
        ? position.notionalUsd / position.qtyBtc
        : sortedExecutions.first.price;

    final timeline = <int, double>{};
    for (final candle in candles) {
      if (candle.timestampMs >= firstTradeTs && candle.timestampMs <= nowTs) {
        timeline[candle.timestampMs] = candle.close;
      }
    }
    for (final execution in sortedExecutions) {
      timeline[execution.timestampMs] = execution.price;
    }
    if (config.markPrice > 0) {
      timeline[nowTs] = config.markPrice;
    }

    final timestamps = timeline.keys.toList()..sort();
    final rebuiltBalance = <SeriesPoint>[];
    final rebuiltEquity = <SeriesPoint>[];
    final rebuiltPnl = <SeriesPoint>[];
    var executionIndex = 0;

    for (final timestamp in timestamps) {
      while (executionIndex < sortedExecutions.length &&
          sortedExecutions[executionIndex].timestampMs <= timestamp) {
        final execution = sortedExecutions[executionIndex];
        runningBalance += execution.realizedPnlUsdt + execution.feeUsdt;
        runningRealized += execution.realizedPnlUsdt;
        final next = _applyExecutionToPosition(
          signedQty: signedQty,
          avgEntry: avgEntry,
          execution: execution,
        );
        signedQty = next.$1;
        avgEntry = next.$2;
        executionIndex++;
      }

      final price = timeline[timestamp]!;
      final unrealized = _unrealizedPnl(
        signedQty: signedQty,
        avgEntry: avgEntry,
        price: price,
      );
      rebuiltBalance.add(SeriesPoint(timestamp, runningBalance));
      rebuiltEquity.add(SeriesPoint(timestamp, runningBalance + unrealized));
      rebuiltPnl.add(SeriesPoint(timestamp, runningRealized));
    }

    if (rebuiltBalance.isNotEmpty) {
      balanceHistory = rebuiltBalance;
      equityHistory = rebuiltEquity;
      pnlHistory = rebuiltPnl;
      _exchangeRealizedPnlUsd = runningRealized;
      _lastChartSnapshotAt = null;
    }
  }

  double _executionSignedDelta(rust_weex.WeexExecutionSnapshot execution) {
    return execution.side == 'buy' ? execution.qtyBtc : -execution.qtyBtc;
  }

  (double, double) _applyExecutionToPosition({
    required double signedQty,
    required double avgEntry,
    required rust_weex.WeexExecutionSnapshot execution,
  }) {
    final delta = _executionSignedDelta(execution);
    final nextQty = signedQty + delta;
    if (signedQty.abs() <= 0.00000001 || signedQty.sign == delta.sign) {
      final nextAbs = nextQty.abs();
      final nextEntry = nextAbs <= 0.00000001
          ? 0.0
          : ((signedQty.abs() * avgEntry) + (delta.abs() * execution.price)) /
                nextAbs;
      return (nextQty.abs() <= 0.00000001 ? 0.0 : nextQty, nextEntry);
    }
    if (nextQty.abs() <= 0.00000001) return (0.0, 0.0);
    if (signedQty.sign != nextQty.sign) return (nextQty, execution.price);
    return (nextQty, avgEntry);
  }

  double _unrealizedPnl({
    required double signedQty,
    required double avgEntry,
    required double price,
  }) {
    if (signedQty.abs() <= 0.00000001 || avgEntry <= 0 || price <= 0) {
      return 0;
    }
    if (signedQty > 0) return (price - avgEntry) * signedQty;
    return (avgEntry - price) * signedQty.abs();
  }

  void _replaceOrder(PlannedOrder order) {
    final index = orders.indexWhere((item) => item.id == order.id);
    if (index >= 0) {
      orders[index] = order;
    } else {
      orders.insert(0, order);
    }
  }

  void _mergeReconciledExecutions(
    List<rust_weex.WeexExecutionSnapshot> executions, {
    List<PriceCandle> candles = const [],
  }) {
    _reconciledExecutionCache = List<rust_weex.WeexExecutionSnapshot>.of(
      executions,
    );
    _rebuildChartHistoryFromTrades(executions: executions, candles: candles);

    tradeHistory = [
      for (final execution in executions)
        TradeHistoryEntry(
          id: execution.execId,
          time: DateTime.fromMillisecondsSinceEpoch(execution.timestampMs),
          side: _tradeHistorySide(execution),
          filledUsdt: execution.notionalUsdt,
          avgPrice: execution.price,
          realizedPnlUsdt: execution.realizedPnlUsdt,
        ),
    ].reversed.toList(growable: false);

    for (final execution in executions) {
      final id = 'weex:${execution.execId}';
      if (orders.any((order) => order.id == id)) continue;
      final direction =
          _directionFromExchange(execution.direction) ??
          (execution.side == 'sell'
              ? TradeDirection.short
              : TradeDirection.long);
      _replaceOrder(
        PlannedOrder(
          id: id,
          kind: _kindFromExchange(execution.kind),
          direction: direction,
          sourceAmount: execution.qtyBtc,
          sourceUnit: SizeUnit.btc,
          scaledBtc: execution.qtyBtc,
          scaledNotionalUsd: execution.notionalUsdt,
          markPrice: execution.price,
          createdAt: DateTime.fromMillisecondsSinceEpoch(execution.timestampMs),
          status: TradeStatus.placed,
          source: 'WEEX fill history',
        ),
      );
    }
    if (orders.length > 100) {
      orders.removeRange(100, orders.length);
    }
  }

  String _tradeHistorySide(rust_weex.WeexExecutionSnapshot execution) {
    final direction = execution.positionSide.isNotEmpty
        ? execution.positionSide
        : execution.direction;
    final labelDirection = switch (direction.toLowerCase()) {
      'long' => 'long',
      'short' => 'short',
      _ => execution.side,
    };
    return switch (execution.kind.toLowerCase()) {
      'reduce' => 'Reduce $labelDirection',
      'close' => 'Close $labelDirection',
      _ => 'Open $labelDirection',
    };
  }

  TradeDirection? _directionFromExchange(String value) {
    return switch (value.toLowerCase()) {
      'long' => TradeDirection.long,
      'short' => TradeDirection.short,
      _ => null,
    };
  }

  TradeKind _kindFromExchange(String value) {
    return switch (value.toLowerCase()) {
      'enter' => TradeKind.enter,
      'add' => TradeKind.add,
      'reduce' => TradeKind.reduce,
      'close' => TradeKind.close,
      _ => TradeKind.manual,
    };
  }

  void _log(String message) {
    eventLog.insert(
      0,
      '${DateTime.now().toIso8601String().substring(11, 19)}  $message',
    );
    if (eventLog.length > 100) eventLog.removeLast();
  }

  String _describe(PlannedOrder order) {
    return '${order.direction.name.toUpperCase()} ${order.scaledBtc.toStringAsFixed(4)} BTC (${order.scaledNotionalUsd.toStringAsFixed(2)} USDT)';
  }

  @override
  void dispose() {
    _weexPriceSubscription?.cancel();
    _weexRestPollTimer?.cancel();
    _weexReconcileTimer?.cancel();
    _chartSnapshotTimer?.cancel();
    super.dispose();
  }
}

class WeexPriceSnapshot {
  const WeexPriceSnapshot({required this.price, required this.source});

  final double price;
  final String source;
}

Future<WeexPriceSnapshot?> fetchWeexRestPrice() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final bookTicker = await _getJson(
      client,
      Uri.parse(
        'https://api-spot.weex.com/api/v3/market/ticker/bookTicker?symbol=BTCUSDT',
      ),
    );
    final bookPrice = parseWeexBookTickerPrice(bookTicker);
    if (bookPrice != null) {
      return WeexPriceSnapshot(
        price: bookPrice,
        source: 'WEEX REST bookTicker',
      );
    }

    final ticker = await _getJson(
      client,
      Uri.parse(
        'https://api-spot.weex.com/api/v3/market/ticker/24hr?symbol=BTCUSDT',
      ),
    );
    final tickerPrice = parseWeexTickerPrice(ticker);
    if (tickerPrice != null) {
      return WeexPriceSnapshot(price: tickerPrice, source: 'WEEX REST ticker');
    }
    return null;
  } finally {
    client.close(force: true);
  }
}

Future<List<PriceCandle>> fetchWeexHistoricalCandles() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final candles = <int, PriceCandle>{};
    for (final request in const [('15m', 672), ('1h', 720)]) {
      final body = await _getJson(
        client,
        Uri.parse(
          'https://api-contract.weex.com/capi/v3/market/markPriceKlines?symbol=BTCUSDT&interval=${request.$1}&limit=${request.$2}',
        ),
      );
      for (final candle in parseWeexKlines(body)) {
        candles[candle.timestampMs] = candle;
      }
    }
    final result = candles.values.toList()
      ..sort((a, b) => a.timestampMs.compareTo(b.timestampMs));
    return result;
  } finally {
    client.close(force: true);
  }
}

Future<String> _getJson(HttpClient client, Uri uri) async {
  final request = await client.getUrl(uri).timeout(const Duration(seconds: 8));
  request.headers.set(
    HttpHeaders.userAgentHeader,
    'trading-challenge-copytrader/1.0',
  );
  request.headers.set(HttpHeaders.acceptHeader, 'application/json');
  final response = await request.close().timeout(const Duration(seconds: 8));
  final body = await response.transform(utf8.decoder).join();
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw HttpException('HTTP ${response.statusCode}: $body', uri: uri);
  }
  return body;
}

@visibleForTesting
double? parseWeexBookTickerPrice(String body) {
  final decoded = jsonDecode(body);
  if (decoded is! Map<String, dynamic>) return null;
  final bid = _jsonDouble(decoded['bidPrice']);
  final ask = _jsonDouble(decoded['askPrice']);
  if (bid != null && ask != null) return (bid + ask) / 2;
  return bid ?? ask;
}

@visibleForTesting
double? parseWeexTickerPrice(String body) {
  final decoded = jsonDecode(body);
  if (decoded is! Map<String, dynamic>) return null;
  return _jsonDouble(decoded['lastPrice']);
}

@visibleForTesting
List<PriceCandle> parseWeexKlines(String body) {
  final decoded = jsonDecode(body);
  if (decoded is! List) return const [];
  final candles = <PriceCandle>[];
  for (final item in decoded) {
    if (item is! List || item.length < 5) continue;
    final timestamp = _jsonInt(item[0]);
    final close = _jsonDouble(item[4]);
    if (timestamp != null && close != null && close > 0) {
      candles.add(PriceCandle(timestampMs: timestamp, close: close));
    }
  }
  candles.sort((a, b) => a.timestampMs.compareTo(b.timestampMs));
  return candles;
}

double? _jsonDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

int? _jsonInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}
