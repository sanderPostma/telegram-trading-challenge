import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../bridge/api.dart' as rust;
import '../bridge/interpreter.dart' as rust_interpreter;
import '../bridge/scaling.dart' as rust_scaling;
import '../bridge/telegram.dart' as rust_telegram;
import '../bridge/weex.dart' as rust_weex;
import '../logging/app_log.dart';
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
  static const _telegramChannelId = -1003766320116;

  final bool useRustBridge;
  StreamSubscription? _weexPriceSubscription;
  StreamSubscription? _telegramSubscription;
  Timer? _weexRestPollTimer;
  Timer? _weexReconcileTimer;
  Timer? _chartSnapshotTimer;
  bool _weexRestPollInFlight = false;
  bool _weexReconcileInFlight = false;
  bool _hasExchangePnlBaseline = false;
  String? _lastWeexPriceSource;
  DateTime? _lastWeexPriceAt;
  DateTime? _lastWeexReconciledAt;
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
  String get logFilePath => AppLog.path;

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
      regex:
          r'(?i)\bADDED\b\s*\$(?P<usd>[\d,]+(?:\.\d+)?)(?:\s*(?:TO\s*)?(?P<dir>SHORT|LONG)\b)?',
      action: TradeKind.add,
      priority: 20,
    ),
    const PatternRule(
      name: 'add_btc',
      regex:
          r'(?i)\bADDED\b\s*(?P<btc>[\d.]+)\s*BTC(?:\s*(?:TO\s*)?(?P<dir>SHORT|LONG)\b)?',
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
    'Telegram monitor starts automatically after Telegram sign-in.',
  ];
  final List<PlannedOrder> orders = [];
  List<TradeHistoryEntry> tradeHistory = const [];
  final Set<String> _reservedIds = {};

  bool monitorRunning = false;
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
    } catch (error, stackTrace) {
      _log(
        'Saved settings could not be loaded: $error',
        error: error,
        stackTrace: stackTrace,
      );
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
    } catch (error, stackTrace) {
      _log(
        'Chart history could not be loaded from Rust: $error',
        error: error,
        stackTrace: stackTrace,
      );
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

  Future<void> handleIncomingTelegramMessage({
    required String text,
    String channel = 'Telegram',
    int? messageId,
    List<String> dedupKeys = const [],
  }) async {
    final rawText = text.trim();
    if (rawText.isEmpty) {
      await AppLog.write('Telegram incoming ignored: empty message.');
      await _finalizeTelegramActions(dedupKeys, const [
        rust_telegram.TelegramActionStatus.rejected,
      ]);
      return;
    }

    await AppLog.write(
      'Telegram incoming: channel="$channel"${messageId == null ? '' : ', message_id=$messageId'}\n$rawText',
    );

    if (!useRustBridge) {
      _log('Telegram parse skipped: Rust bridge unavailable.');
      await _finalizeTelegramActions(dedupKeys, const [
        rust_telegram.TelegramActionStatus.failed,
      ]);
      return;
    }

    try {
      final result = await rust.classifyMessageActions(text: rawText);
      final actions = result.value;
      if (!result.ok || actions == null || actions.isEmpty) {
        await AppLog.write(
          'Telegram parse failed: ${result.error ?? 'no actions returned'}',
        );
        _log(
          'Telegram parse failed: ${result.error ?? 'no actions returned'}.',
        );
        await _finalizeTelegramActions(dedupKeys, const [
          rust_telegram.TelegramActionStatus.failed,
        ]);
        return;
      }

      final statuses = <rust_telegram.TelegramActionStatus>[];
      for (final action in actions) {
        await AppLog.write(
          'Telegram parse result: ${_parsedActionDebug(action)}',
        );
        statuses.add(
          await _handleParsedTelegramAction(action, channel: channel),
        );
      }
      await _finalizeTelegramActions(dedupKeys, statuses);
    } catch (error, stackTrace) {
      _log(
        'Telegram parse failed: $error',
        error: error,
        stackTrace: stackTrace,
      );
      await _finalizeTelegramActions(dedupKeys, const [
        rust_telegram.TelegramActionStatus.failed,
      ]);
    }
  }

  Future<rust_telegram.TelegramActionStatus> _handleParsedTelegramAction(
    rust_interpreter.Action action, {
    required String channel,
  }) async {
    final summary = _parsedActionSummary(action);
    if (action.kind == rust_interpreter.ActionKind.ignore) {
      _log('Telegram ignored: $summary.');
      return rust_telegram.TelegramActionStatus.rejected;
    }

    final kind = _tradeKindFromParsed(action.kind);
    if (kind == null) {
      _log('Telegram parsed but not automated: $summary.');
      return rust_telegram.TelegramActionStatus.rejected;
    }

    final requiresPositionDirection =
        kind == TradeKind.add && action.direction == null ||
        kind == TradeKind.reduce;
    if (requiresPositionDirection) {
      await _refreshExchangePositionForTelegramAction();
    }

    final explicitDirection = _tradeDirectionFromParsed(action.direction);
    final direction = kind == TradeKind.reduce
        ? position.direction
        : explicitDirection ?? _inferredTelegramDirection();
    if (explicitDirection == null && direction != null) {
      _log(
        'Telegram direction inferred as ${direction.name.toUpperCase()} from ${position.isFlat ? 'latest trade history' : 'current WEEX position'}.',
      );
    }

    final order = switch (kind) {
      TradeKind.reduce => _buildParsedReductionOrder(
        direction: direction,
        fraction: _percentFromParsed(action.size),
        source: 'Telegram $channel: $summary',
      ),
      _ => _buildParsedEntryOrAddOrder(
        kind: kind,
        direction: direction,
        size: _sizeFromParsed(action.size),
        triggerPrice: action.triggerPrice,
        source: 'Telegram $channel: $summary',
      ),
    };
    if (order == null) {
      _log('Telegram needs review: $summary.');
      return rust_telegram.TelegramActionStatus.rejected;
    }
    if (config.markPrice <= 0) {
      _log('Telegram trade skipped: waiting for live WEEX BTC price.');
      return rust_telegram.TelegramActionStatus.failed;
    }

    if (order.scaledBtc <= 0 || order.scaledNotionalUsd <= 0) {
      await AppLog.write(
        'Telegram scaled order rejected: ${_describe(order)} from $summary.',
      );
      _log('Telegram trade skipped: scaled size is zero.');
      return rust_telegram.TelegramActionStatus.failed;
    }

    await AppLog.write(
      'Telegram scaled order: ${_describe(order)}, auto_approve=${config.autoApprove}, simulation=${config.simulationMode}.',
    );
    if (config.autoApprove) {
      _log('Telegram auto-approved: ${_describe(order)}.');
      final placedStatus = await _place(order);
      return switch (placedStatus) {
        TradeStatus.simulated => rust_telegram.TelegramActionStatus.simulated,
        TradeStatus.placed => rust_telegram.TelegramActionStatus.submitted,
        TradeStatus.failed => rust_telegram.TelegramActionStatus.failed,
        TradeStatus.rejected => rust_telegram.TelegramActionStatus.rejected,
        TradeStatus.pendingApproval =>
          rust_telegram.TelegramActionStatus.pending,
      };
    } else {
      pendingApproval = order;
      orders.insert(0, order);
      _log('Telegram approval required: ${_describe(order)}.');
      notifyListeners();
      return rust_telegram.TelegramActionStatus.pending;
    }
  }

  Future<void> _finalizeTelegramDedup(
    String? dedupKey,
    rust_telegram.TelegramActionStatus status,
  ) async {
    if (dedupKey == null || dedupKey.isEmpty || !useRustBridge) return;
    try {
      final result = await rust.telegramFinalizeAction(
        statePath: AppLog.telegramStatePath,
        dedupKey: dedupKey,
        status: status,
      );
      if (!result.ok) {
        _log(
          'Telegram dedup finalize failed: ${result.error ?? 'unknown error'}',
        );
      }
    } catch (error, stackTrace) {
      _log(
        'Telegram dedup finalize failed: $error',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _finalizeTelegramActions(
    List<String> dedupKeys,
    List<rust_telegram.TelegramActionStatus> statuses,
  ) async {
    for (var index = 0; index < dedupKeys.length; index++) {
      final status = index < statuses.length
          ? statuses[index]
          : rust_telegram.TelegramActionStatus.rejected;
      await _finalizeTelegramDedup(dedupKeys[index], status);
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
    } catch (error, stackTrace) {
      _log(
        'Rust scaling failed, using Dart fallback: $error',
        error: error,
        stackTrace: stackTrace,
      );
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

  void startTelegramMonitor() {
    if (_telegramSubscription != null) return;
    if (!useRustBridge) {
      monitorRunning = false;
      _log('Telegram monitor unavailable: Rust bridge is unavailable.');
      notifyListeners();
      return;
    }
    final request = _telegramRequest(logMissing: false);
    if (request == null) {
      monitorRunning = false;
      _log(
        'Telegram monitor waiting for API ID, API hash, phone, and sign-in.',
      );
      notifyListeners();
      return;
    }

    monitorRunning = true;
    _log('Telegram monitor connecting via grammers.');
    _telegramSubscription = rust
        .telegramMessageStream(request: request)
        .listen(
          (event) {
            if (!event.ok) {
              monitorRunning = false;
              _log(
                'Telegram monitor stopped: ${event.error ?? 'unknown error'}',
              );
              notifyListeners();
              return;
            }
            unawaited(
              handleIncomingTelegramMessage(
                text: event.text,
                channel: event.channelTitle,
                messageId: event.messageId,
                dedupKeys: event.dedupKeys,
              ),
            );
          },
          onError: (Object error, StackTrace stackTrace) {
            monitorRunning = false;
            _log(
              'Telegram monitor failed: $error',
              error: error,
              stackTrace: stackTrace,
            );
            notifyListeners();
          },
          onDone: () {
            monitorRunning = false;
            _telegramSubscription = null;
            _log('Telegram monitor disconnected.');
            notifyListeners();
          },
        );
    _log('Telegram monitor live via grammers.');
    notifyListeners();
  }

  Future<void> requestTelegramCode() async {
    final request = _telegramRequest();
    if (request == null) return;
    try {
      final result = await rust.telegramRequestCode(request: request);
      final status = result.value;
      if (!result.ok || status == null) {
        _log(
          'Telegram code request failed: ${result.error ?? 'unknown error'}',
        );
        return;
      }
      _log(status.message);
      if (status.authorized) startTelegramMonitor();
    } catch (error, stackTrace) {
      _log(
        'Telegram code request failed: $error',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> submitTelegramCode(String code) async {
    final value = code.trim();
    if (value.isEmpty) {
      _log('Telegram sign-in needs the code from Telegram.');
      return;
    }
    try {
      final result = await rust.telegramSignIn(code: value);
      final status = result.value;
      if (!result.ok || status == null) {
        _log('Telegram sign-in failed: ${result.error ?? 'unknown error'}');
        return;
      }
      _log(status.message);
      if (status.authorized) startTelegramMonitor();
    } catch (error, stackTrace) {
      _log(
        'Telegram sign-in failed: $error',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> submitTelegramPassword(String password) async {
    if (password.isEmpty) {
      _log('Telegram 2FA sign-in needs your password.');
      return;
    }
    try {
      final result = await rust.telegramCheckPassword(password: password);
      final status = result.value;
      if (!result.ok || status == null) {
        _log('Telegram 2FA sign-in failed: ${result.error ?? 'unknown error'}');
        return;
      }
      _log(status.message);
      if (status.authorized) startTelegramMonitor();
    } catch (error, stackTrace) {
      _log(
        'Telegram 2FA sign-in failed: $error',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  rust_telegram.TelegramClientRequest? _telegramRequest({
    bool logMissing = true,
  }) {
    if (!useRustBridge) {
      if (logMissing) _log('Telegram unavailable: Rust bridge is unavailable.');
      return null;
    }
    final apiId = int.tryParse(config.telegramApiId.trim());
    if (apiId == null ||
        config.telegramApiHash.trim().isEmpty ||
        config.telegramPhone.trim().isEmpty) {
      if (logMissing) {
        _log('Telegram needs numeric API ID, API hash, and phone first.');
      }
      return null;
    }
    return rust_telegram.TelegramClientRequest(
      apiId: apiId,
      apiHash: config.telegramApiHash,
      phone: config.telegramPhone,
      channelId: _telegramChannelId,
      sessionPath: AppLog.telegramSessionPath,
      statePath: AppLog.telegramStatePath,
    );
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
    } catch (error, stackTrace) {
      weexAccountConnected = false;
      weexReconciliationError = error.toString();
      _log(
        'WEEX account reconciliation failed: $error',
        error: error,
        stackTrace: stackTrace,
      );
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
    } catch (error, stackTrace) {
      _log(
        'WEEX REST price failed: $error',
        error: error,
        stackTrace: stackTrace,
      );
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
      crossCombinedLeverage: direction == null
          ? 0
          : reconciledPosition.leverage,
    );
    _mergeReconciledExecutions(update.recentExecutions, candles: candles);
    _lastWeexReconciledAt = DateTime.now();
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
    startTelegramMonitor();
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
    } catch (error, stackTrace) {
      _log(
        'Settings could not be saved: $error',
        error: error,
        stackTrace: stackTrace,
      );
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
        .catchError((Object error, StackTrace stackTrace) {
          _historicalCandleFetch = null;
          _log(
            'WEEX historical candles could not be loaded: $error',
            error: error,
            stackTrace: stackTrace,
          );
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
    } catch (error, stackTrace) {
      _log(
        'WEEX historical candle cache could not be loaded: $error',
        error: error,
        stackTrace: stackTrace,
      );
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
    } catch (error, stackTrace) {
      _log(
        'WEEX historical candle cache could not be saved: $error',
        error: error,
        stackTrace: stackTrace,
      );
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
    double? triggerPrice,
  }) {
    final ratio = config.scaleRatio;
    final mark = config.markPrice;
    final scaledBtc = sourceUnit == SizeUnit.btc
        ? sourceAmount * ratio
        : mark > 0
        ? (sourceAmount * ratio) / mark
        : 0.0;
    final roundedBtc = _roundDown(scaledBtc, 0.0001);
    final notionalPrice = triggerPrice ?? mark;
    final notional = notionalPrice > 0 ? roundedBtc * notionalPrice : 0.0;
    final now = DateTime.now();
    final nonce = '${now.microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}';
    return PlannedOrder(
      id: nonce,
      kind: kind,
      direction: direction,
      sourceAmount: sourceAmount,
      sourceUnit: sourceUnit,
      scaledBtc: roundedBtc,
      scaledNotionalUsd: notional,
      markPrice: mark,
      createdAt: now,
      status: status,
      source: source,
      triggerPrice: triggerPrice,
    );
  }

  PlannedOrder? _buildParsedEntryOrAddOrder({
    required TradeKind kind,
    required TradeDirection? direction,
    required (double, SizeUnit)? size,
    required double? triggerPrice,
    required String source,
  }) {
    if (direction == null || size == null) return null;
    if (triggerPrice != null && (triggerPrice <= 0 || !triggerPrice.isFinite)) {
      return null;
    }
    return _buildOrder(
      kind: kind,
      direction: direction,
      sourceAmount: size.$1,
      sourceUnit: size.$2,
      source: triggerPrice == null
          ? source
          : '$source, limit trigger at ${triggerPrice.toStringAsFixed(2)} USDT',
      status: TradeStatus.pendingApproval,
      triggerPrice: triggerPrice,
    );
  }

  PlannedOrder? _buildParsedReductionOrder({
    required TradeDirection? direction,
    required double? fraction,
    required String source,
  }) {
    if (direction == null ||
        fraction == null ||
        fraction <= 0 ||
        fraction > 1) {
      return null;
    }
    if (position.isFlat ||
        position.direction != direction ||
        position.qtyBtc <= 0) {
      return null;
    }
    final quantity = _roundDown(position.qtyBtc * fraction, 0.0001);
    final mark = config.markPrice;
    return PlannedOrder(
      id: '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}',
      kind: TradeKind.reduce,
      direction: direction,
      sourceAmount: fraction * 100,
      sourceUnit: SizeUnit.btc,
      scaledBtc: quantity,
      scaledNotionalUsd: quantity * mark,
      markPrice: mark,
      createdAt: DateTime.now(),
      status: TradeStatus.pendingApproval,
      source: '$source, reduce ${(fraction * 100).toStringAsFixed(0)}%',
    );
  }

  double _roundDown(double value, double step) {
    if (step <= 0) return value;
    return (value / step).floorToDouble() * step;
  }

  Future<TradeStatus> _place(PlannedOrder order) async {
    if (!config.simulationMode) {
      _replaceOrder(order.copyWith(status: TradeStatus.pendingApproval));
      notifyListeners();
      _log(
        'Live WEEX ${order.isConditional ? 'conditional limit' : 'market'} submit starting for ${_describe(order)}.',
      );
      final ack = await _submitLiveOrder(order);
      if (ack == null) {
        _replaceOrder(order.copyWith(status: TradeStatus.failed));
        notifyListeners();
        return TradeStatus.failed;
      }
      _log(
        'WEEX accepted ${order.isConditional ? 'conditional order' : 'order'} ${ack.orderId}. Waiting for reconciliation.',
      );
    }

    final status = config.simulationMode
        ? TradeStatus.simulated
        : TradeStatus.placed;
    final placed = order.copyWith(status: status);
    _replaceOrder(placed);
    if (!placed.isConditional) _applyLocallyPlacedOrder(placed);
    _log(
      '${config.simulationMode ? 'Simulated' : 'Placed'} ${placed.isConditional ? 'conditional ' : ''}${_describe(placed)}.',
    );
    unawaited(_snapshotChartState(force: true));
    if (!config.simulationMode) {
      unawaited(reconcileFromExchange());
    }
    notifyListeners();
    return status;
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
    final reduceOnly =
        order.kind == TradeKind.reduce || order.kind == TradeKind.close;
    final executionDirection = reduceOnly
        ? _oppositeDirection(order.direction)
        : order.direction;
    final side = executionDirection == TradeDirection.long ? 'buy' : 'sell';
    if (order.isConditional) {
      final triggerPrice = order.triggerPrice!;
      final orderType = _conditionalOrderType(order.direction, triggerPrice);
      _log(
        'Submitting WEEX $orderType LIMIT $side ${order.scaledBtc.toStringAsFixed(4)} BTC at trigger ${triggerPrice.toStringAsFixed(2)} USDT, simulation OFF.',
      );
      try {
        final result = await rust.weexSubmitAlgoOrder(
          request: rust_weex.WeexAlgoOrderRequest(
            apiKey: config.weexApiKey,
            apiSecret: config.weexSecret,
            passphrase: config.weexPassphrase,
            symbol: 'BTCUSDT',
            baseUrl: 'https://api-contract.weex.com',
            side: side,
            qtyBtc: order.scaledBtc,
            triggerPrice: triggerPrice,
            limitPrice: triggerPrice,
            orderType: orderType,
            clientAlgoId: 'tmg-${order.id}-trigger',
            qtyStep: 0.0001,
            priceStep: 0.1,
          ),
        );
        return _readWeexOrderResult(result, 'conditional order');
      } catch (error, stackTrace) {
        _log(
          'Live WEEX conditional submit failed: $error',
          error: error,
          stackTrace: stackTrace,
        );
        return null;
      }
    }
    _log(
      'Submitting WEEX MARKET $side ${order.scaledBtc.toStringAsFixed(4)} BTC (${order.scaledNotionalUsd.toStringAsFixed(2)} USDT), reduce_only=$reduceOnly, simulation OFF.',
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
          reduceOnly: reduceOnly,
          clientOrderId: 'tmg-${order.id}',
          qtyStep: 0.0001,
        ),
      );
      return _readWeexOrderResult(result, 'order');
    } catch (error, stackTrace) {
      _log(
        'Live WEEX submit failed: $error',
        error: error,
        stackTrace: stackTrace,
      );
    }
    return null;
  }

  rust_weex.WeexMarketOrderAck? _readWeexOrderResult(
    rust.ApiResultWeexMarketOrderAck result,
    String label,
  ) {
    final ack = result.value;
    if (ack != null) {
      final suffix = ack.errorCode.isEmpty && ack.errorMessage.isEmpty
          ? ''
          : ' (${ack.errorCode} ${ack.errorMessage})'.trimRight();
      _log(
        'WEEX $label ack: success=${ack.success}, order=${ack.orderId.isEmpty ? 'none' : ack.orderId}$suffix.',
      );
    }
    if (result.ok && ack != null) return ack;
    _log('Live WEEX $label rejected: ${result.error ?? 'unknown error'}');
    return null;
  }

  void _applyLocallyPlacedOrder(PlannedOrder order) {
    if (order.kind == TradeKind.reduce || order.kind == TradeKind.close) {
      final remaining = (position.qtyBtc - order.scaledBtc).clamp(
        0.0,
        double.infinity,
      );
      position = PositionView(
        direction: remaining <= 0 ? null : order.direction,
        qtyBtc: remaining,
        notionalUsd: remaining * config.markPrice,
        unrealizedPnlUsd: 0,
        crossCombinedLeverage: position.crossCombinedLeverage,
      );
      return;
    }
    final sameDirection =
        position.direction == order.direction && !position.isFlat;
    final quantity = sameDirection
        ? position.qtyBtc + order.scaledBtc
        : order.scaledBtc;
    final notional = sameDirection
        ? position.notionalUsd + order.scaledNotionalUsd
        : order.scaledNotionalUsd;
    position = PositionView(
      direction: order.direction,
      qtyBtc: quantity,
      notionalUsd: notional,
      unrealizedPnlUsd: 0,
      crossCombinedLeverage: position.crossCombinedLeverage,
    );
  }

  TradeDirection _oppositeDirection(TradeDirection direction) =>
      direction == TradeDirection.long
      ? TradeDirection.short
      : TradeDirection.long;

  String _conditionalOrderType(TradeDirection direction, double triggerPrice) {
    final markPrice = config.markPrice;
    final isStop = direction == TradeDirection.long
        ? triggerPrice >= markPrice
        : triggerPrice <= markPrice;
    return isStop ? 'STOP' : 'TAKE_PROFIT';
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
      } catch (error, stackTrace) {
        _log(
          'Chart history snapshot could not be written to Rust: $error',
          error: error,
          stackTrace: stackTrace,
        );
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
      crossCombinedLeverage: position.crossCombinedLeverage,
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

  TradeKind? _tradeKindFromParsed(rust_interpreter.ActionKind value) {
    return switch (value) {
      rust_interpreter.ActionKind.enter => TradeKind.enter,
      rust_interpreter.ActionKind.add => TradeKind.add,
      rust_interpreter.ActionKind.reduce => TradeKind.reduce,
      rust_interpreter.ActionKind.close => null,
      rust_interpreter.ActionKind.ignore => null,
    };
  }

  TradeDirection? _tradeDirectionFromParsed(rust_interpreter.Direction? value) {
    return switch (value) {
      rust_interpreter.Direction.long => TradeDirection.long,
      rust_interpreter.Direction.short => TradeDirection.short,
      null => null,
    };
  }

  Future<void> _refreshExchangePositionForTelegramAction() async {
    if (!_hasWeexCredentials) return;
    final lastReconciled = _lastWeexReconciledAt;
    if (lastReconciled != null &&
        DateTime.now().difference(lastReconciled) <
            _exchangeReconcileInterval) {
      return;
    }
    await reconcileFromExchange();
  }

  TradeDirection? _inferredTelegramDirection() {
    if (!position.isFlat) return position.direction;
    for (final trade in tradeHistory) {
      final side = trade.side.toLowerCase();
      if (side.contains('short')) return TradeDirection.short;
      if (side.contains('long')) return TradeDirection.long;
    }
    for (final order in orders) {
      if (order.kind == TradeKind.reduce || order.kind == TradeKind.close) {
        continue;
      }
      return order.direction;
    }
    return null;
  }

  (double, SizeUnit)? _sizeFromParsed(rust_interpreter.Size? value) {
    return switch (value) {
      rust_interpreter.Size_Usd(:final field0) => (field0, SizeUnit.usdt),
      rust_interpreter.Size_Btc(:final field0) => (field0, SizeUnit.btc),
      rust_interpreter.Size_Pct() => null,
      rust_interpreter.Size_FullClose() => null,
      null => null,
    };
  }

  double? _percentFromParsed(rust_interpreter.Size? value) {
    return switch (value) {
      rust_interpreter.Size_Pct(:final field0) => field0,
      _ => null,
    };
  }

  String _parsedActionSummary(rust_interpreter.Action action) {
    final kind = action.kind.name.toUpperCase();
    final direction = action.direction?.name.toUpperCase();
    final size = _parsedSizeLabel(action.size);
    final trigger = action.triggerPrice == null
        ? null
        : 'LIMIT TRIGGER ${action.triggerPrice!.toStringAsFixed(2)} USDT';
    return [kind, ?direction, ?size, ?trigger].join(' ');
  }

  String _parsedActionDebug(rust_interpreter.Action action) {
    return [
      'kind=${action.kind.name}',
      'direction=${action.direction?.name ?? 'none'}',
      'size=${_parsedSizeLabel(action.size) ?? 'none'}',
      'trigger_price=${action.triggerPrice?.toStringAsFixed(2) ?? 'none'}',
      'confidence_high=${action.confidenceHigh}',
      'needs_approval=${action.needsApproval}',
    ].join(', ');
  }

  String? _parsedSizeLabel(rust_interpreter.Size? value) {
    return switch (value) {
      rust_interpreter.Size_Usd(:final field0) =>
        '${field0.toStringAsFixed(2)} USDT',
      rust_interpreter.Size_Btc(:final field0) =>
        '${field0.toStringAsFixed(4)} BTC',
      rust_interpreter.Size_Pct(:final field0) =>
        '${(field0 * 100).toStringAsFixed(0)}%',
      rust_interpreter.Size_FullClose() => 'full close',
      null => null,
    };
  }

  void _log(String message, {Object? error, StackTrace? stackTrace}) {
    eventLog.insert(
      0,
      '${DateTime.now().toIso8601String().substring(11, 19)}  $message',
    );
    if (eventLog.length > 100) eventLog.removeLast();
    unawaited(AppLog.write(message, error: error, stackTrace: stackTrace));
  }

  String _describe(PlannedOrder order) {
    final trigger = order.triggerPrice == null
        ? ''
        : ' limit trigger ${order.triggerPrice!.toStringAsFixed(2)} USDT';
    return '${order.direction.name.toUpperCase()} ${order.scaledBtc.toStringAsFixed(4)} BTC (${order.scaledNotionalUsd.toStringAsFixed(2)} USDT)$trigger';
  }

  @override
  void dispose() {
    _weexPriceSubscription?.cancel();
    _telegramSubscription?.cancel();
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
