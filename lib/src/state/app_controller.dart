import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../bridge/api.dart' as rust;
import '../bridge/interpreter.dart' as rust_interpreter;
import '../bridge/interpreter.dart' show Asset;
import '../bridge/risk.dart' as rust_risk;
import '../bridge/scaling.dart' as rust_scaling;
import '../bridge/telegram.dart' as rust_telegram;
import '../bridge/weex.dart' as rust_weex;
import '../logging/app_log.dart';
import '../models/trading.dart';
import '../patterns/default_patterns.dart';
import '../patterns/patterns_readme.dart';
import '../security/credential_store.dart';

enum WeexPriceStatus { idle, connecting, live, unavailable }

/// How a parsed Telegram CLOSE signal should be handled.
///
/// A close follows the auto-approve toggle like any other action: with
/// auto-approve on it flattens immediately, with it off it queues for
/// confirmation. It does nothing when the book is already flat.
///
/// Closing only ever reduces exposure — `rust/src/risk.rs` deliberately lets a
/// reduce-only order past every rail — so auto-executing one cannot grow a
/// position. The exception is an ambiguous close: if the message names no
/// asset while both books are open, there is no safe choice to make
/// automatically and it queues regardless of the toggle.
enum TelegramCloseDisposition {
  ignoredNoPosition,
  queueForApproval,
  executeImmediately,
}

class AppController extends ChangeNotifier {
  AppController({this.useRustBridge = false, CredentialStore? credentialStore})
      : _credentialStore = credentialStore ??
            (useRustBridge
                ? EncryptedCredentialStore(AppLog.configDirectory)
                : InMemoryCredentialStore());

  /// Credentials are sealed on disk rather than sitting in the preferences
  /// file. See `lib/src/security/credential_store.dart`.
  final CredentialStore _credentialStore;

  static const _configPrefsKey = 'trading_challenge.app_config.v1';

  /// Suffix identifying a config blob written under an older preference
  /// prefix. Any such key may still hold plaintext credentials, so it is
  /// migrated and then deleted. Matching on the suffix rather than a list of
  /// names catches every prefix this app has ever shipped under.
  static const _configPrefsKeySuffix = '.app_config.v1';
  static const _closeTargetPrefsKey =
      'trading_challenge.close_target_watch.v1';
  static const _exchangeTakeProfitPrefsKey =
      'trading_challenge.exchange_take_profit.v1';
  static const _klineCachePrefsKey = 'trading_challenge.weex_kline_cache.v1';
  static const _chartSnapshotInterval = Duration(minutes: 1);
  static const _exchangeReconcileInterval = Duration(seconds: 5);
  static const _exchangeHistoryLookback = Duration(days: 30);
  static const _historicalCandleCacheFreshFor = Duration(minutes: 10);
  static const _weexPriceStaleAfter = Duration(seconds: 20);
  static const _telegramPatternsUrl =
      'https://telegram-patterns.sander.dnsrouter.nl/telegram_patterns.yaml';
  static const _telegramPatternsRequestTimeout = Duration(seconds: 8);
  static const _telegramChannelId = -1003766320116;
  /// A live close is verified against the exchange and any residual re-submitted
  /// this many times before the controller reports it as still open.
  static const _flattenMaxAttempts = 3;
  static const _flattenSettleDelay = Duration(milliseconds: 750);
  /// Fallback lot step, used only before the Rust asset specs have loaded.
  /// The real per-asset values come from [assetSpecs]; see `Asset::qty_step`.
  static const _lotStep = 0.0001;

  final bool useRustBridge;

  /// Contract facts per asset, owned by Rust so the two sides cannot drift.
  Map<Asset, rust.AssetSpec> assetSpecs = const {};

  /// Live state per traded asset. BTC and ETH can be open simultaneously.
  Map<Asset, AssetBook> books = {
    for (final asset in Asset.values) asset: AssetBook(asset: asset),
  };

  /// The asset whose detail pane is showing. Purely a UI concern — signals are
  /// routed by the asset named in the message, never by this.
  Asset selectedAsset = Asset.btc;

  /// Assets with an open position, in display order. Drives the positions
  /// table, and tells the interpreter which books are live so it knows when an
  /// unqualified "REDUCED 25%" is ambiguous.
  List<Asset> get openAssets =>
      Asset.values.where((a) => !(books[a]?.isFlat ?? true)).toList();

  AssetBook bookFor(Asset asset) => books[asset] ?? AssetBook(asset: asset);

  /// Adds ETHUSDT to the symbol allowlist, answering the v1 -> v2 migration
  /// prompt. Only ever called from an explicit user action: widening a risk
  /// rail is the user's decision, never a side effect of upgrading.
  Future<void> acceptEthAllowlistPrompt() async {
    final allowlist = [...config.risk.symbolAllowlist];
    for (final asset in Asset.values) {
      final symbol = symbolOf(asset);
      if (!allowlist.contains(symbol)) allowlist.add(symbol);
    }
    config = config.copyWith(
      risk: config.risk.copyWith(symbolAllowlist: allowlist),
      ethAllowlistPromptPending: false,
    );
    _log('Symbol allowlist now permits ${allowlist.join(', ')}.');
    await saveConfig(config);
    await _pushRiskLimits();
    notifyListeners();
  }

  /// Leaves the allowlist as it is. ETH signals keep being rejected, which is a
  /// legitimate choice — but it is now an informed one.
  Future<void> declineEthAllowlistPrompt() async {
    config = config.copyWith(ethAllowlistPromptPending: false);
    _log(
      'Symbol allowlist left unchanged; ETH signals will be rejected by the '
      'risk gate.',
    );
    await saveConfig(config);
    notifyListeners();
  }

  /// Dismisses the retired-quantity-cap notice once the user has seen it.
  Future<void> acknowledgeLegacyQtyCap() async {
    config = config.copyWith(legacyOrderQtyCapBtc: 0);
    await saveConfig(config);
    notifyListeners();
  }

  /// Switches which book the detail panels act on. Signals are unaffected —
  /// they are routed by the asset named in the message.
  void selectAsset(Asset asset) {
    if (selectedAsset == asset) return;
    selectedAsset = asset;
    // The manual-trade path reads config.markPrice, so it has to follow the
    // selection or a manual order would be sized off the other book's price.
    final mark = bookFor(asset).markPrice;
    if (mark > 0) config = config.copyWith(markPrice: mark);
    notifyListeners();
  }

  AssetBook get selectedBook => bookFor(selectedAsset);

  void _updateBook(Asset asset, AssetBook Function(AssetBook) update) {
    books = {...books, asset: update(bookFor(asset))};
  }

  /// The quantity step for [asset], from Rust once specs have loaded.
  double lotStepFor(Asset asset) => assetSpecs[asset]?.qtyStep ?? _lotStep;

  double priceStepFor(Asset asset) => assetSpecs[asset]?.priceStep ?? 0.1;

  String displayOf(Asset asset) => assetSpecs[asset]?.display ?? asset.name.toUpperCase();

  String symbolOf(Asset asset) =>
      assetSpecs[asset]?.symbol ?? '${asset.name.toUpperCase()}USDT';

  Future<void> loadAssetSpecs() async {
    if (!useRustBridge) return;
    try {
      final specs = await rust.assetSpecs();
      assetSpecs = {for (final spec in specs) spec.asset: spec};
      notifyListeners();
    } catch (error, stackTrace) {
      _log('Could not load asset specs from Rust: $error',
          error: error, stackTrace: stackTrace);
    }
  }

  final Map<Asset, StreamSubscription> _weexPriceSubscriptions = {};
  StreamSubscription? _weexPriceSubscription;
  StreamSubscription? _telegramSubscription;
  Timer? _weexRestPollTimer;
  Timer? _weexReconcileTimer;
  Timer? _chartSnapshotTimer;
  bool _weexRestPollInFlight = false;
  Future<void>? _weexReconcile;
  bool _hasExchangePnlBaseline = false;
  /// The asset of the most recent actionable signal, used to resolve a
  /// follow-up message that names none while the account is flat.
  Asset? _lastSignalAsset;
  final Map<Asset, String> _lastWeexPriceSource = {};
  final Map<Asset, DateTime> _lastWeexPriceAt = {};
  final Map<Asset, DateTime> _lastWeexPriceLogAt = {};
  final Map<Asset, DateTime> _lastWeexWsPriceAt = {};
  final Map<Asset, int> _lastWeexRestExchangeTimeMs = {};
  final Map<Asset, String> _lastWeexRestPriceSource = {};
  final Map<Asset, int> _lastWeexWsEventTimeMs = {};
  DateTime? _lastWeexReconciledAt;
  DateTime? _lastChartSnapshotAt;
  double _exchangeRealizedPnlUsd = 0;
  double _localRealizedPnlUsd = 0;
  List<PriceCandle> _historicalCandleCache = const [];
  Future<List<PriceCandle>>? _historicalCandleFetch;
  DateTime? _historicalCandleCacheLoadedAt;
  bool _historicalCandlePrefsLoaded = false;
  Future<void>? _patternsInitialization;
  Future<String>? _patternsRefresh;
  String _embeddedPatternsYaml = embeddedTelegramPatternsYaml;
  String _activePatternsYaml = embeddedTelegramPatternsYaml;
  String _localPatternsYaml = localTelegramPatternsTemplate;
  String? _remotePatternsYaml;
  String? _patternsEtag;
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
  /// The selected book's position. Per-asset state lives in [books]; these
  /// proxies keep the single-asset call sites — manual trading, the detail
  /// pane — reading and writing whichever book the user is looking at.
  PositionView get position => selectedBook.position;
  set position(PositionView value) =>
      _updateBook(selectedAsset, (book) => book.copyWith(position: value));

  PositionView positionFor(Asset asset) => bookFor(asset).position;

  CloseTargetWatch? get closeTargetWatch => selectedBook.closeTargetWatch;
  set closeTargetWatch(CloseTargetWatch? value) => _updateBook(
        selectedAsset,
        (book) => value == null
            ? book.copyWith(clearCloseTargetWatch: true)
            : book.copyWith(closeTargetWatch: value),
      );

  bool get closeTargetTriggered => selectedBook.closeTargetTriggered;
  set closeTargetTriggered(bool value) => _updateBook(
      selectedAsset, (book) => book.copyWith(closeTargetTriggered: value));

  /// The take-profit currently resting on WEEX for the open position, if any.
  ExchangeTakeProfit? get exchangeTakeProfit => selectedBook.exchangeTakeProfit;
  set exchangeTakeProfit(ExchangeTakeProfit? value) => _updateBook(
        selectedAsset,
        (book) => value == null
            ? book.copyWith(clearExchangeTakeProfit: true)
            : book.copyWith(exchangeTakeProfit: value),
      );
  bool _evaluatingCloseTarget = false;

  Future<void> loadConfig() async {
    var migratedPlaintext = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_configPrefsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is! Map) {
          _log('Saved settings ignored: unexpected format.');
        } else {
          final json = Map<String, Object?>.from(decoded);
          config = AppConfig.fromPersistentJson(json)
              .copyWith(autoUpdateMaster: true);
          // Builds before credentials were encrypted stored them here in the
          // clear. Take them, seal them, and scrub the preferences file.
          migratedPlaintext = AppConfig.containsPlaintextSecrets(json);
        }
      }
      migratedPlaintext |= await _migrateLegacyConfigKeys(prefs);
    } catch (error, stackTrace) {
      _log(
        'Saved settings could not be loaded: $error',
        error: error,
        stackTrace: stackTrace,
      );
    }
    await _loadSecrets(migratedPlaintext: migratedPlaintext);
    await _loadCloseTarget();
    await _loadExchangeTakeProfit();
    await _initializePatterns();
    _resetLocalChartHistory();
    // Arm the gate before anything can place an order.
    await _pushRiskLimits();
    // Then settle whatever a previous run left in the air.
    unawaited(reconcilePendingActions());
  }

  Future<void> _initializePatterns() {
    return _patternsInitialization ??= _loadLocalPatterns();
  }

  Future<void> _loadLocalPatterns() async {
    try {
      final embeddedFile = File(AppLog.telegramPatternsEmbeddedPath);
      final remoteFile = File(AppLog.telegramPatternsRemotePath);
      final localFile = File(AppLog.telegramPatternsPath);
      await localFile.parent.create(recursive: true);
      final readmeFile = File(AppLog.telegramPatternsReadmePath);
      await _writeIfChanged(readmeFile, telegramPatternsReadme);

      var fallback = embeddedTelegramPatternsYaml;
      if (useRustBridge) {
        try {
          fallback = await rust.defaultPatternsYaml();
        } catch (error, stackTrace) {
          await AppLog.write(
            'Embedded Telegram patterns could not be loaded from Rust; using Dart fallback.',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }
      _embeddedPatternsYaml = fallback;

      await _writeIfChanged(embeddedFile, fallback);

      if (await remoteFile.exists()) {
        final remote = await remoteFile.readAsString();
        if (await _validatePatterns(remote)) {
          _remotePatternsYaml = remote;
        } else {
          await AppLog.write(
            'Cached remote Telegram patterns are invalid; using embedded defaults.',
          );
        }
      }

      if (await localFile.exists()) {
        final local = await localFile.readAsString();
        if (await _mergePatterns(_remotePatternsYaml ?? fallback, local) !=
            null) {
          _localPatternsYaml = local;
        } else {
          await AppLog.write(
            'Local Telegram pattern overrides are invalid; ignoring them.',
          );
        }
      } else {
        await _writeIfChanged(localFile, localTelegramPatternsTemplate);
      }

      final etagFile = File(AppLog.telegramPatternsEtagPath);
      if (await etagFile.exists()) {
        final etag = (await etagFile.readAsString()).trim();
        _patternsEtag = etag.isEmpty ? null : etag;
      }
      _activePatternsYaml =
          await _mergePatterns(
            _remotePatternsYaml ?? fallback,
            _localPatternsYaml,
          ) ??
          fallback;
    } catch (error, stackTrace) {
      await AppLog.write(
        'Telegram pattern cache could not be initialized; using embedded defaults.',
        error: error,
        stackTrace: stackTrace,
      );
      _activePatternsYaml = embeddedTelegramPatternsYaml;
      _localPatternsYaml = localTelegramPatternsTemplate;
    }
  }

  Future<bool> _validatePatterns(String source) async {
    if (source.trim().isEmpty) return false;
    if (!useRustBridge) return true;
    try {
      final result = await rust.validatePatternsYaml(patternsYaml: source);
      return result.ok;
    } catch (error, stackTrace) {
      await AppLog.write(
        'Telegram pattern validation failed.',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  Future<void> _replacePatternCache(String source, String? etag) async {
    final file = File(AppLog.telegramPatternsRemotePath);
    await _writeIfChanged(file, source);

    final etagFile = File(AppLog.telegramPatternsEtagPath);
    if (etag == null || etag.isEmpty) {
      if (await etagFile.exists()) await etagFile.delete();
    } else {
      await etagFile.writeAsString(etag, flush: true);
    }
    _patternsEtag = etag;
  }

  Future<void> _writeIfChanged(File file, String source) async {
    if (await file.exists() && await file.readAsString() == source) return;
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(source, flush: true);
    await temporary.rename(file.path);
  }

  Future<String?> _mergePatterns(String base, String local) async {
    if (!useRustBridge) return base;
    try {
      final result = await rust.mergePatternsYaml(
        baseYaml: base,
        localYaml: local,
      );
      return result.ok ? result.value : null;
    } catch (error, stackTrace) {
      await AppLog.write(
        'Telegram pattern layers could not be merged.',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  Future<String> _patternsForMessage() async {
    await _initializePatterns();
    await _reloadLocalOverrides();
    if (!useRustBridge) return _activePatternsYaml;

    final inFlight = _patternsRefresh;
    if (inFlight != null) return inFlight;
    final refresh = _refreshPatterns();
    _patternsRefresh = refresh;
    try {
      return await refresh;
    } finally {
      if (identical(_patternsRefresh, refresh)) _patternsRefresh = null;
    }
  }

  Future<void> _reloadLocalOverrides() async {
    final localFile = File(AppLog.telegramPatternsPath);
    if (!await localFile.exists()) return;
    try {
      final local = await localFile.readAsString();
      final merged = await _mergePatterns(
        _remotePatternsYaml ?? _embeddedPatternsYaml,
        local,
      );
      if (merged == null) {
        await AppLog.write(
          'Local Telegram pattern overrides are invalid; keeping the last valid version.',
        );
        return;
      }
      _localPatternsYaml = local;
      _activePatternsYaml = merged;
    } catch (error, stackTrace) {
      await AppLog.write(
        'Local Telegram pattern overrides could not be read.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<String> _refreshPatterns() async {
    final client = HttpClient()..autoUncompress = true;
    try {
      final request = await client
          .getUrl(Uri.parse(_telegramPatternsUrl))
          .timeout(_telegramPatternsRequestTimeout);
      final etag = _patternsEtag;
      if (etag != null && etag.isNotEmpty) {
        request.headers.set(HttpHeaders.ifNoneMatchHeader, etag);
      }
      final response = await request.close().timeout(
        _telegramPatternsRequestTimeout,
      );
      if (response.statusCode == HttpStatus.notModified) {
        return _activePatternsYaml;
      }
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'pattern host returned HTTP ${response.statusCode}',
          uri: Uri.parse(_telegramPatternsUrl),
        );
      }

      final body = await utf8.decoder.bind(response).join();
      if (!await _validatePatterns(body)) {
        throw const FormatException('remote Telegram patterns are invalid');
      }
      final remoteEtag = response.headers.value(HttpHeaders.etagHeader);
      await _replacePatternCache(body, remoteEtag);
      _remotePatternsYaml = body;
      _activePatternsYaml =
          await _mergePatterns(body, _localPatternsYaml) ?? _activePatternsYaml;
      await AppLog.write(
        'Telegram patterns updated from remote host${remoteEtag == null ? '' : ' (ETag $remoteEtag)'}.',
      );
    } catch (error, stackTrace) {
      await AppLog.write(
        'Telegram pattern refresh failed; using cached patterns.',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      client.close(force: true);
    }
    return _activePatternsYaml;
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
      _log('Manual order rejected: enter a positive '
          '${displayOf(selectedAsset)} or USDT amount.');
      return;
    }
    if (config.markPrice <= 0) {
      _log('Manual order rejected: waiting for live WEEX '
          '${displayOf(selectedAsset)} price.');
      return;
    }

    final fallbackOrder = _buildOrder(
      kind: TradeKind.manual,
      direction: direction,
      sourceAmount: amount,
      sourceUnit: unit,
      source:
          'Manual ${direction.name.toUpperCase()} ${amount.toStringAsFixed(unit == SizeUnit.coin ? 4 : 2)} ${unit.name.toUpperCase()}',
      status: TradeStatus.pendingApproval,
    );
    _log(
      'Manual trade requested: ${direction.name.toUpperCase()} ${amount.toStringAsFixed(unit == SizeUnit.coin ? 4 : 2)} ${unit.name.toUpperCase()}, mark ${config.markPrice.toStringAsFixed(2)} USDT.',
    );
    final rustScaled = await _scaleWithRust(amount: amount, unit: unit);
    final order = rustScaled == null
        ? fallbackOrder
        : fallbackOrder.copyWithScaled(
            scaledQty: rustScaled.qty,
            scaledNotionalUsd: rustScaled.notionalUsd,
          );

    if (_reservedIds.contains(order.id)) {
      _log('Skipped duplicate manual order reservation ${order.id}.');
      return;
    }
    _reservedIds.add(order.id);
    _log(
      'Manual trade scaled: ${order.scaledQty.toStringAsFixed(4)} ${displayOf(order.asset)}, ${order.scaledNotionalUsd.toStringAsFixed(2)} USDT.',
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

  /// Reduce-only quantity (BTC, rounded to lot and capped at the open position)
  /// for a manual dashboard reduction. Unlike the Telegram reduce path — which
  /// scales the master's size to our book — a manual reduce acts directly on our
  /// own position: a percentage is relative to what we hold, and USDT/BTC are
  /// our own book units. Returns 0 when there is nothing to reduce.
  double previewManualReduceQty({
    required double amount,
    required SizeUnit unit,
    required bool isPercent,
  }) {
    if (position.isFlat || position.qty <= 0 || amount <= 0) return 0;
    final mark = config.markPrice;
    final raw = isPercent
        ? position.qty * (amount / 100)
        : switch (unit) {
            SizeUnit.usdt => mark > 0 ? amount / mark : 0.0,
            SizeUnit.coin => amount,
          };
    return _roundDown(min(raw, position.qty), 0.0001);
  }

  /// Places a manual reduce-only order against the open position. A reduction
  /// that covers the whole position is routed through [manualFlatten] so a live
  /// exit is submitted (and simulation realizes PnL). Mirrors [openManualTrade]:
  /// under auto-approve it places immediately, otherwise it queues for approval.
  Future<void> manualReduce({
    required double amount,
    required SizeUnit unit,
    required bool isPercent,
  }) async {
    if (position.isFlat || position.direction == null || position.qty <= 0) {
      _log('Manual reduce ignored: no open position.');
      notifyListeners();
      return;
    }
    if (config.markPrice <= 0) {
      _log('Manual reduce rejected: waiting for live WEEX '
          '${displayOf(selectedAsset)} price.');
      return;
    }
    final quantity = previewManualReduceQty(
      amount: amount,
      unit: unit,
      isPercent: isPercent,
    );
    if (quantity <= 0) {
      _log(
        'Manual reduce rejected: enter a positive amount within the open position.',
      );
      return;
    }
    // A reduction that reaches the whole position is a flatten; reuse the exit
    // path so it submits live and realizes PnL in simulation.
    if (quantity >= _roundDown(position.qty, 0.0001)) {
      await manualFlatten();
      return;
    }

    final mark = config.markPrice;
    final label = isPercent
        ? 'reduce ${amount.toStringAsFixed(0)}%'
        : unit == SizeUnit.coin
        ? 'reduce ${amount.toStringAsFixed(4)} ${displayOf(selectedAsset)}'
        : 'reduce \$${amount.toStringAsFixed(0)}';
    final order = PlannedOrder(
      id: '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}',
      kind: TradeKind.reduce,
      asset: selectedAsset,
      direction: position.direction!,
      sourceAmount: quantity,
      sourceUnit: SizeUnit.coin,
      scaledQty: quantity,
      scaledNotionalUsd: quantity * mark,
      markPrice: mark,
      createdAt: DateTime.now(),
      status: TradeStatus.pendingApproval,
      source: 'Manual dashboard $label',
    );

    if (config.autoApprove) {
      _log('Manual reduce auto-approved: ${_describe(order)}.');
      await _place(order);
    } else {
      pendingApproval = order;
      orders.insert(0, order);
      _log('Manual reduce requires approval: ${_describe(order)}.');
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

    if (useRustBridge) {
      try {
        final target = await rust.extractCloseTarget(text: rawText);
        if (target != null) {
          // A target is a real TP on the exchange: it closes the position on
          // its own, with no app-side confirmation. Only when it cannot be
          // placed does the app fall back to the advisory close-watch.
          await setExchangeTakeProfit(
            low: target.low,
            high: target.high,
            source: channel,
          );
        }
      } catch (error, stackTrace) {
        await AppLog.write('Close-target extraction failed: $error',
            error: error, stackTrace: stackTrace);
      }

      // A "NEW BALANCE $7,800" (or "Account balance $X") announcement updates
      // the challenge (master) account balance, which drives the scale ratio.
      try {
        final balance = await rust.extractMasterBalance(text: rawText);
        if (balance != null &&
            balance > 0 &&
            balance != config.masterBalanceUsd) {
          config = config.copyWith(masterBalanceUsd: balance);
          _log(
            'Challenge balance updated from $channel: ${balance.toStringAsFixed(2)} USDT.',
          );
          unawaited(_persistConfig());
          notifyListeners();
        }
      } catch (error, stackTrace) {
        await AppLog.write('Challenge balance extraction failed: $error',
            error: error, stackTrace: stackTrace);
      }
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
      final patternsYaml = await _patternsForMessage();
      final result = await rust.classifyMessageActionsWithPatterns(
        text: rawText,
        patternsYaml: patternsYaml,
        // Which books are live decides whether an unqualified "REDUCED 25%"
        // can be resolved at all; Rust refuses to guess when both are open.
        activeAssets: openAssets,
        lastAsset: _lastSignalAsset,
      );
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
      for (var index = 0; index < actions.length; index++) {
        final action = actions[index];
        await AppLog.write(
          'Telegram parse result: ${_parsedActionDebug(action)}',
        );
        statuses.add(
          await _handleParsedTelegramAction(
            action,
            channel: channel,
            // The dedup key seeds the exchange client order id, so a crash
            // mid-submit can still be traced back to an order on WEEX.
            dedupKey: index < dedupKeys.length ? dedupKeys[index] : null,
          ),
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
    String? dedupKey,
  }) async {
    final summary = _parsedActionSummary(action);
    if (action.kind == rust_interpreter.ActionKind.ignore) {
      _log('Telegram ignored: $summary.');
      return rust_telegram.TelegramActionStatus.rejected;
    }

    // CLOSE is never auto-executed. It always queues a full-flatten for the
    // user to confirm via the approval dialog, in both manual and auto-approve
    // mode.
    if (action.kind == rust_interpreter.ActionKind.close) {
      return _handleParsedTelegramClose(
        summary: summary,
        channel: channel,
        asset: action.asset,
        dedupKey: dedupKey,
      );
    }

    final kind = tradeKindFromParsed(action.kind);
    if (kind == null) {
      _log('Telegram parsed but not automated: $summary.');
      return rust_telegram.TelegramActionStatus.rejected;
    }

    // Rust resolves the asset, inheriting it from the live book when the
    // message omits one and refusing to guess when two books are open. A null
    // here is that refusal, not a parse gap, so it must not be defaulted.
    final asset = action.asset;
    if (asset == null) {
      _log(
        'Telegram needs review: $summary — the message names no asset and '
        '${openAssets.length > 1 ? 'both books are open' : 'no book is live'}, '
        'so it is ambiguous.',
      );
      return rust_telegram.TelegramActionStatus.rejected;
    }

    final requiresPositionDirection =
        kind == TradeKind.add && action.direction == null ||
        kind == TradeKind.reduce;
    if (requiresPositionDirection) {
      await _refreshExchangePositionForTelegramAction();
    }

    _lastSignalAsset = asset;
    final signalPosition = positionFor(asset);
    final explicitDirection = _tradeDirectionFromParsed(action.direction);
    final direction = kind == TradeKind.reduce
        ? signalPosition.direction
        : explicitDirection ?? _inferredTelegramDirection();
    if (explicitDirection == null && direction != null) {
      _log(
        'Telegram direction inferred as ${direction.name.toUpperCase()} from ${signalPosition.isFlat ? 'latest trade history' : 'current WEEX position'}.',
      );
    }

    final order = switch (kind) {
      TradeKind.reduce => _buildParsedReductionOrder(
        asset: asset,
        direction: direction,
        size: action.size,
        source: 'Telegram $channel: $summary',
        dedupKey: dedupKey,
      ),
      _ => _buildParsedEntryOrAddOrder(
        kind: kind,
        asset: asset,
        direction: direction,
        size: _sizeFromParsed(action.size),
        triggerPrice: action.triggerPrice,
        source: 'Telegram $channel: $summary',
        dedupKey: dedupKey,
      ),
    };
    if (order == null) {
      _log('Telegram needs review: $summary.');
      return rust_telegram.TelegramActionStatus.rejected;
    }
    if (bookFor(asset).markPrice <= 0) {
      _log('Telegram trade skipped: waiting for live WEEX '
          '${displayOf(asset)} price.');
      return rust_telegram.TelegramActionStatus.failed;
    }

    if (order.scaledQty <= 0 || order.scaledNotionalUsd <= 0) {
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

  /// Handles a parsed CLOSE signal. A close never auto-executes: it always
  /// queues a reduce-only full flatten for the user to confirm via the approval
  /// dialog, in both manual and auto-approve mode. It does nothing when the
  /// book is already flat.
  Future<rust_telegram.TelegramActionStatus> _handleParsedTelegramClose({
    required String summary,
    required String channel,
    Asset? asset,
    String? dedupKey,
  }) async {
    await _refreshExchangePositionForTelegramAction();

    // Resolve which book to flatten. A close that names its asset is
    // unambiguous; one that does not can still be resolved when exactly one
    // book is open. With two open and nothing to go on, the choice goes to the
    // user rather than being guessed — flattening the wrong book would be the
    // most damaging thing this path could do.
    final open = openAssets;
    final ambiguous = asset == null && open.length > 1;
    final target = asset ?? (open.length == 1 ? open.first : selectedAsset);

    final targetPosition = positionFor(target);
    final disposition = closeDisposition(
      autoApprove: config.autoApprove,
      position: targetPosition,
      assetAmbiguous: ambiguous,
    );
    if (disposition == TelegramCloseDisposition.ignoredNoPosition) {
      _log('Telegram CLOSE ignored: no open ${displayOf(target)} position to '
          'flatten ($summary).');
      return rust_telegram.TelegramActionStatus.rejected;
    }

    final mark = bookFor(target).markPrice;
    if (mark <= 0) {
      _log('Telegram CLOSE skipped: waiting for live WEEX '
          '${displayOf(target)} price.');
      return rust_telegram.TelegramActionStatus.failed;
    }

    final quantity = _roundDown(targetPosition.qty, lotStepFor(target));
    if (quantity <= 0) {
      _log('Telegram CLOSE ignored: ${displayOf(target)} position smaller '
          'than one lot ($summary).');
      return rust_telegram.TelegramActionStatus.rejected;
    }
    final order = PlannedOrder(
      id: '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}',
      kind: TradeKind.close,
      asset: target,
      direction: targetPosition.direction!,
      sourceAmount: quantity,
      sourceUnit: SizeUnit.coin,
      scaledQty: quantity,
      scaledNotionalUsd: quantity * mark,
      markPrice: mark,
      createdAt: DateTime.now(),
      status: TradeStatus.pendingApproval,
      source: 'Telegram $channel: $summary, close position',
      dedupKey: dedupKey,
    );

    if (disposition == TelegramCloseDisposition.executeImmediately) {
      orders.insert(0, order);
      await AppLog.write(
        'Telegram CLOSE auto-executing: ${_describe(order)} '
        '(auto-approve on).',
      );
      _log('Telegram CLOSE auto-executing: ${_describe(order)}.');
      notifyListeners();
      await _place(order);
      return rust_telegram.TelegramActionStatus.submitted;
    }

    pendingApproval = order;
    orders.insert(0, order);
    await AppLog.write(
      'Telegram CLOSE queued for approval: ${_describe(order)} '
      '(auto-approve=${config.autoApprove}'
      '${ambiguous ? '; the message names no asset and both books are open' : ''}).',
    );
    _log('Telegram CLOSE requires approval: ${_describe(order)}'
        '${ambiguous ? ' — the message names no asset and both books are open' : ''}.');
    notifyListeners();
    return rust_telegram.TelegramActionStatus.pending;
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
          unit: unit == SizeUnit.coin
              ? rust.ManualSizeUnit.coin
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
    if (_weexPriceSubscriptions.isNotEmpty) return;
    unawaited(loadAssetSpecs());
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
    // One stream per asset: BTC and ETH can be open at the same time, so both
    // books need their own live mark.
    for (final asset in Asset.values) {
      _weexPriceSubscriptions[asset] =
          rust.weexPublicPriceStream(asset: asset).listen(
        (tick) {
          if (tick.ok && tick.price != null && tick.price! > 0) {
            _applyWeexPrice(
              tick.price!,
              source: 'WEEX WebSocket ${tick.source}',
              asset: asset,
              exchangeTimeMs: tick.eventTimeMs,
            );
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
    }
    _weexPriceSubscription = _weexPriceSubscriptions[Asset.btc];
    _log('WEEX public price streams connecting for '
        '${Asset.values.map(displayOf).join(', ')}.');
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

  /// Reconciles against WEEX, joining the in-flight pass when one is already
  /// running rather than dropping the request. Callers that need a snapshot
  /// taken *after* their own order use [_reconcileFreshFromExchange].
  Future<void> reconcileFromExchange() {
    if (!useRustBridge || !_hasWeexCredentials) return Future<void>.value();
    return _weexReconcile ??= _reconcileFromExchangeOnce().whenComplete(
      () => _weexReconcile = null,
    );
  }

  /// Reconciles with a snapshot guaranteed to be newer than any pass already
  /// running: an in-flight read may have been issued before our fill landed, so
  /// it is awaited and then a fresh pass is taken.
  Future<void> _reconcileFreshFromExchange() async {
    final inFlight = _weexReconcile;
    if (inFlight != null) await inFlight;
    await reconcileFromExchange();
  }

  Future<void> _reconcileFromExchangeOnce() async {
    try {
      final candles = await _getHistoricalCandles();
      // One reconcile per book. Balance and chart history are account-level,
      // so only the first pass applies them; the rest carry position and fills
      // for their own symbol.
      var appliedAccountLevel = false;
      // Trade history, the equity chart and today's realized PnL are
      // account-wide, so they are built from every book's fills together.
      // Applying them per book would leave each pass overwriting the last and
      // the UI flip-flopping between one asset's history and the other's.
      final allExecutions = <rust_weex.WeexExecutionSnapshot>[];
      for (final asset in Asset.values) {
        final result = await rust.weexReconcileAccount(
          request: rust_weex.WeexAccountRequest(
            apiKey: config.weexApiKey,
            apiSecret: config.weexSecret,
            passphrase: config.weexPassphrase,
            symbol: symbolOf(asset),
            baseUrl: 'https://api-contract.weex.com',
            recentLookbackMs: _exchangeHistoryLookback.inMilliseconds,
          ),
        );
        if (!result.ok || result.value == null) {
          throw StateError(
            result.error ?? 'WEEX reconciliation returned no data',
          );
        }
        applyWeexReconciliation(
          result.value!,
          candles: candles,
          asset: asset,
          applyAccountLevel: !appliedAccountLevel,
          mergeExecutions: false,
        );
        allExecutions.addAll(result.value!.recentExecutions);
        appliedAccountLevel = true;
      }
      _applyAccountWideExecutions(allExecutions, candles: candles);
    } catch (error, stackTrace) {
      weexAccountConnected = false;
      weexReconciliationError = error.toString();
      _log(
        'WEEX account reconciliation failed: $error',
        error: error,
        stackTrace: stackTrace,
      );
      notifyListeners();
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
      var anySucceeded = false;
      for (final asset in Asset.values) {
        final snapshot = await fetchWeexRestPrice(symbol: symbolOf(asset));
        if (snapshot != null && snapshot.price > 0) {
          anySucceeded = true;
          _applyWeexPrice(
            snapshot.price,
            source: snapshot.source,
            asset: asset,
            exchangeTimeMs: snapshot.exchangeTimeMs,
          );
        }
      }
      if (anySucceeded) {
        // handled per asset above
      } else {
        _handleWeexPriceFailure('WEEX contract REST returned no price');
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

  void _applyWeexPrice(
    double price, {
    required String source,
    required Asset asset,
    int? exchangeTimeMs,
  }) {
    final isWebSocket = source.startsWith('WEEX WebSocket');
    if (isWebSocket) {
      final previousEventTime = _lastWeexWsEventTimeMs[asset];
      if (exchangeTimeMs != null &&
          previousEventTime != null &&
          exchangeTimeMs <= previousEventTime) {
        return;
      }
      if (exchangeTimeMs != null) {
        _lastWeexWsEventTimeMs[asset] = exchangeTimeMs;
      }
      _lastWeexWsPriceAt[asset] = DateTime.now();
    } else {
      final lastWebSocketPrice = _lastWeexWsPriceAt[asset];
      if (lastWebSocketPrice != null &&
          DateTime.now().difference(lastWebSocketPrice) <
              _weexPriceStaleAfter) {
        return;
      }
      if (exchangeTimeMs != null) {
        final previousExchangeTime = _lastWeexRestExchangeTimeMs[asset];
        if (source == _lastWeexRestPriceSource[asset] &&
            previousExchangeTime != null &&
            exchangeTimeMs <= previousExchangeTime) {
          return;
        }
        _lastWeexRestExchangeTimeMs[asset] = exchangeTimeMs;
        _lastWeexRestPriceSource[asset] = source;
      } else if (price == bookFor(asset).markPrice &&
          _lastWeexPriceAt[asset] != null) {
        // A fallback response without an exchange timestamp must not keep a
        // dead feed green forever when an intermediary serves cached JSON.
        return;
      }
    }
    _lastWeexPriceAt[asset] = DateTime.now();
    _updateBook(asset, (book) => book.copyWith(markPrice: price));
    // `config.markPrice` is the selected book's price. It stays for the manual
    // trade path and for persistence, both of which act on one asset at a time.
    if (asset == selectedAsset) {
      config = config.copyWith(markPrice: price);
    }
    _markPositionToMarket(price, asset: asset);
    _maybeTriggerCloseTarget(price, asset: asset);
    weexPriceConnected = true;
    weexPriceStatus = WeexPriceStatus.live;
    weexPriceError = null;
    final sourceKind = isWebSocket ? 'WEEX WebSocket' : source;
    final display = displayOf(asset);
    if (_lastWeexPriceSource[asset] != sourceKind) {
      _lastWeexPriceSource[asset] = sourceKind;
      _log('WEEX $display price live via $sourceKind.');
    }
    final now = DateTime.now();
    final lastPriceLog = _lastWeexPriceLogAt[asset];
    if (lastPriceLog == null ||
        now.difference(lastPriceLog) >= const Duration(minutes: 1)) {
      _lastWeexPriceLogAt[asset] = now;
      unawaited(
        AppLog.write(
          'WEEX $display price update: ${price.toStringAsFixed(2)} USDT via $source.',
        ),
      );
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

  /// True while any book has a recent price. The feed is one connection per
  /// asset, so a single live book is enough to call the feed healthy.
  bool get _hasFreshWeexPrice {
    final now = DateTime.now();
    return Asset.values.any((asset) {
      final last = _lastWeexPriceAt[asset];
      return last != null &&
          bookFor(asset).markPrice > 0 &&
          now.difference(last) < _weexPriceStaleAfter;
    });
  }

  bool get _hasWeexCredentials =>
      config.weexApiKey.trim().isNotEmpty &&
      config.weexSecret.trim().isNotEmpty &&
      config.weexPassphrase.trim().isNotEmpty;

  /// Applies an exchange reconciliation snapshot. Renamed off `_` and marked
  /// [visibleForTesting] so the close-target edge-trigger disarm (only on an
  /// open->flat transition observed *by this reconcile*, never on an
  /// already-flat watch) can be locked by a unit test without touching the
  /// Rust bridge or the network.
  @visibleForTesting
  void applyWeexReconciliation(
    rust_weex.WeexAccountReconciliation update, {
    List<PriceCandle> candles = const [],
    Asset? asset,
    bool applyAccountLevel = true,
    /// False while reconciling book by book: the caller merges every book's
    /// fills together afterwards instead.
    bool mergeExecutions = true,
  }) {
    // Prefer the symbol the exchange reported: it is the authority on which
    // book this payload describes.
    final target = Asset.values.firstWhere(
      (a) => symbolOf(a) == update.position.symbol.toUpperCase(),
      orElse: () => asset ?? selectedAsset,
    );
    final balance = update.balance;
    final exchangeBalance = balance.walletBalance;
    if (applyAccountLevel && exchangeBalance > 0 && exchangeBalance.isFinite) {
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
        : bookFor(target).markPrice;
    if (markPrice > 0) {
      _updateBook(target, (book) => book.copyWith(markPrice: markPrice));
      if (target == selectedAsset) {
        config = config.copyWith(markPrice: markPrice);
      }
    }
    final closeWatchWasOpen = !positionFor(target).isFlat;
    final reconciled = PositionView(
      direction: direction,
      qty: direction == null ? 0 : reconciledPosition.qty,
      notionalUsd: direction == null
          ? 0
          : reconciledPosition.notionalUsdt > 0
          ? reconciledPosition.notionalUsdt
          : reconciledPosition.qty * reconciledPosition.entryPrice,
      unrealizedPnlUsd: direction == null
          ? 0
          : reconciledPosition.unrealizedPnlUsdt,
      crossCombinedLeverage: direction == null
          ? 0
          : reconciledPosition.leverage,
    );
    _updateBook(target, (book) => book.copyWith(position: reconciled));
    // Edge-trigger: only disarm on an open->flat transition observed by this
    // reconcile. A watch armed while flat (or restored from persistence on
    // restart while flat) must persist until a position exists to flatten.
    if (closeWatchWasOpen && reconciled.isFlat) {
      _disarmCloseTarget();
      // The position that carried the exchange TP is gone, so WEEX has already
      // released the plan; drop the local record with it.
      _forgetExchangeTakeProfitIfFlat();
    }
    if (mergeExecutions) {
      _applyAccountWideExecutions(update.recentExecutions, candles: candles);
    }
    _lastWeexReconciledAt = DateTime.now();
    weexAccountConnected = true;
    weexReconciliationError = null;
    notifyListeners();
  }

  @visibleForTesting
  void applyAccountWideExecutionsForTest(
    List<rust_weex.WeexExecutionSnapshot> executions, {
    List<PriceCandle> candles = const [],
  }) =>
      _applyAccountWideExecutions(executions, candles: candles);

  /// Rebuilds the account-wide views from every book's fills at once.
  ///
  /// Fills are deduplicated by exchange execution id: each book is fetched
  /// separately, and a repeated id would otherwise double-count its PnL.
  void _applyAccountWideExecutions(
    List<rust_weex.WeexExecutionSnapshot> executions, {
    List<PriceCandle> candles = const [],
  }) {
    final byId = <String, rust_weex.WeexExecutionSnapshot>{};
    for (final execution in executions) {
      byId[execution.execId] = execution;
    }
    final combined = byId.values.toList()
      ..sort((a, b) => a.timestampMs.compareTo(b.timestampMs));

    _mergeReconciledExecutions(combined, candles: candles);
    // Refresh the facts the risk gate measures limits against, now that
    // position, mark price, and today's realized PnL are all current.
    unawaited(
      _pushRiskContext(realizedPnlTodayUsd: _realizedPnlToday(combined)),
    );
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

  Future<void> manualFlatten() async {
    if (position.isFlat || position.direction == null || position.qty <= 0) {
      _log('Manual flatten ignored: no open position.');
      notifyListeners();
      return;
    }

    // Live mode: send a real reduce-only market order to WEEX rather than only
    // adjusting local state. `_place` submits, reconciles, and logs against the
    // actual (non-simulation) mode.
    if (!config.simulationMode) {
      await _flattenLive();
      return;
    }

    // Simulation mode: settle the position locally and realize its PnL.
    final realizedPnl = position.unrealizedPnlUsd;
    _localRealizedPnlUsd += realizedPnl;
    config = config.copyWith(myBalanceUsd: config.myBalanceUsd + realizedPnl);
    position = const PositionView(
      direction: null,
      qty: 0,
      notionalUsd: 0,
      unrealizedPnlUsd: 0,
    );
    _disarmCloseTargetIfFlat();
    _forgetExchangeTakeProfitIfFlat();
    _log(
      'Position flattened in simulation state. Realized ${realizedPnl.toStringAsFixed(2)} USDT.',
    );
    unawaited(_persistConfig());
    unawaited(_snapshotChartState(force: true));
    notifyListeners();
  }

  /// Submits reduce-only close orders until WEEX confirms the book is flat.
  /// A single submit is not enough on its own: the order can partially fill, or
  /// the position can move between the local snapshot and the submit, and the
  /// residual then shows up as a *partial reduce* fill rather than a close. So
  /// after each submit the position is re-read from the exchange and whatever
  /// is left is submitted again, up to [_flattenMaxAttempts]. A remainder below
  /// one lot cannot be closed at all and is reported instead of retried.
  Future<void> _flattenLive() async {
    final canVerify = useRustBridge && _hasWeexCredentials;
    for (var attempt = 1; ; attempt++) {
      final remaining = position.isFlat || position.direction == null
          ? 0.0
          : position.qty;
      final step = flattenStep(
        remainingBtc: remaining,
        lotStep: _lotStep,
        attempt: attempt,
        maxAttempts: _flattenMaxAttempts,
      );
      if (step != FlattenStep.submit) {
        switch (step) {
          case FlattenStep.done:
            if (attempt > 1) _log('Manual flatten confirmed flat by WEEX.');
          case FlattenStep.dust:
            _log(
              attempt == 1
                  ? 'Manual flatten ignored: position smaller than one lot.'
                  : 'Manual flatten left ${remaining.toStringAsFixed(6)} ${displayOf(selectedAsset)} below one lot; it cannot be closed.',
            );
          case FlattenStep.giveUp:
            _log(
              'Manual flatten gave up after $_flattenMaxAttempts attempts; '
              '${remaining.toStringAsFixed(4)} ${displayOf(selectedAsset)} is still open.',
            );
          case FlattenStep.submit:
            break;
        }
        notifyListeners();
        return;
      }

      final mark = config.markPrice;
      if (mark <= 0) {
        _log('Manual flatten skipped: waiting for live WEEX '
            '${displayOf(selectedAsset)} price.');
        notifyListeners();
        return;
      }
      final quantity = _roundDown(remaining, _lotStep);

      final order = PlannedOrder(
        id: '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}',
        kind: TradeKind.close,
        asset: selectedAsset,
        direction: position.direction!,
        sourceAmount: quantity,
        sourceUnit: SizeUnit.coin,
        scaledQty: quantity,
        scaledNotionalUsd: quantity * mark,
        markPrice: mark,
        createdAt: DateTime.now(),
        status: TradeStatus.pendingApproval,
        source: attempt == 1
            ? 'Manual flatten, close position'
            : 'Manual flatten residual $attempt, close position',
      );
      _log(
        'Manual flatten: submitting reduce-only close ${_describe(order)}'
        '${attempt == 1 ? '' : ' (residual attempt $attempt)'}.',
      );
      final status = await _place(order);
      if (status == TradeStatus.failed || status == TradeStatus.rejected) {
        _log('Manual flatten stopped: close order ${status.name}.');
        notifyListeners();
        return;
      }
      if (!canVerify) {
        notifyListeners();
        return;
      }

      await Future<void>.delayed(_flattenSettleDelay);
      await _reconcileFreshFromExchange();
      if (position.isFlat || position.qty <= 0) {
        _log('Manual flatten confirmed flat by WEEX.');
        notifyListeners();
        return;
      }
      _log(
        'Manual flatten incomplete: WEEX still reports '
        '${position.qty.toStringAsFixed(4)} ${displayOf(selectedAsset)} open.',
      );
    }
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

  void setHasSeenAutoApproveWarning(bool value) {
    config = config.copyWith(hasSeenAutoApproveWarning: value);
    unawaited(_persistConfig());
    notifyListeners();
  }

  void setSimulationMode(bool value) {
    config = config.copyWith(simulationMode: value);
    _log('Simulation mode ${value ? 'enabled' : 'disabled'}.');
    unawaited(_persistConfig());
    notifyListeners();
  }

  void _maybeTriggerCloseTarget(double price, {Asset? asset}) {
    if (!useRustBridge) return;
    final target = asset ?? selectedAsset;
    final book = bookFor(target);
    final watch = book.closeTargetWatch;
    final currentPosition = book.position;
    if (watch == null || book.closeTargetTriggered || _evaluatingCloseTarget) {
      return;
    }
    if (price <= 0 || currentPosition.isFlat || currentPosition.direction == null) {
      return;
    }
    final direction = currentPosition.direction == TradeDirection.long
        ? rust_interpreter.Direction.long
        : rust_interpreter.Direction.short;
    _evaluatingCloseTarget = true;
    unawaited(
      rust
          .closeTargetShouldFire(
            direction: direction,
            price: price,
            low: watch.low,
            high: watch.high,
          )
          .then((fire) {
            if (fire &&
                identical(bookFor(target).closeTargetWatch, watch) &&
                !bookFor(target).closeTargetTriggered) {
              _updateBook(
                  target, (book) => book.copyWith(closeTargetTriggered: true));
              _log(
                '${displayOf(target)} close-target reached ${watch.low.toStringAsFixed(0)}–${watch.high.toStringAsFixed(0)} at ${price.toStringAsFixed(2)} USDT.',
              );
              notifyListeners();
            }
          })
          .whenComplete(() => _evaluatingCloseTarget = false),
    );
  }

  /// Places (or replaces) a take-profit on the exchange for the open position,
  /// in whichever direction it currently runs. The plan carries no quantity, so
  /// WEEX closes the whole position at the trigger — including anything added
  /// afterwards — without the app being involved.
  ///
  /// A range target has one trigger, taken at the edge the price reaches first:
  /// the low for a LONG rising into the zone, the high for a SHORT falling into
  /// it. This mirrors `close_target_should_fire`.
  ///
  /// Falls back to the advisory [armCloseTarget] watch when the exchange cannot
  /// hold the plan — simulation mode, no credentials, or a rejected submit — so
  /// a target is never silently dropped.
  Future<void> setExchangeTakeProfit({
    required double low,
    required double high,
    required String source,
  }) async {
    final lo = low <= high ? low : high;
    final hi = low <= high ? high : low;

    if (position.isFlat || position.direction == null || position.qty <= 0) {
      _log(
        'Take-profit ${lo.toStringAsFixed(0)} ignored: no open position to attach it to.',
      );
      notifyListeners();
      return;
    }
    if (config.simulationMode || !useRustBridge || !_hasWeexCredentials) {
      _log(
        'Take-profit ${lo.toStringAsFixed(0)} kept as an app-side watch '
        '(${config.simulationMode ? 'simulation mode' : 'no live WEEX access'}).',
      );
      armCloseTarget(low: lo, high: hi, source: source);
      return;
    }

    final direction = position.direction!;
    final trigger = direction == TradeDirection.long ? lo : hi;
    if (trigger <= 0) {
      _log('Take-profit ignored: trigger price must be positive.');
      notifyListeners();
      return;
    }

    // Replace rather than stack: two live plans on one position would close it
    // twice, and the second would be rejected as reduce-only with nothing left.
    await cancelExchangeTakeProfit(log: false);

    try {
      final planType = await rust.weexTpSlPlanType(
        direction: direction == TradeDirection.long
            ? rust_interpreter.Direction.long
            : rust_interpreter.Direction.short,
        triggerPrice: trigger,
        markPrice: config.markPrice,
      );
      final result = await rust.weexSubmitTpSlOrder(
        request: rust_weex.WeexTpSlOrderRequest(
          apiKey: config.weexApiKey,
          apiSecret: config.weexSecret,
          passphrase: config.weexPassphrase,
          symbol: symbolOf(selectedAsset),
          baseUrl: 'https://api-contract.weex.com',
          positionSide: direction == TradeDirection.long ? 'LONG' : 'SHORT',
          planType: planType,
          triggerPrice: trigger,
          // Zero closes the entire position at the trigger.
          qty: 0,
          clientAlgoId:
              'tc-tp-${DateTime.now().microsecondsSinceEpoch}',
          qtyStep: _lotStep,
          priceStep: 0.1,
        ),
      );
      final ack = result.value;
      if (!result.ok || ack == null || ack.orderId.isEmpty) {
        _log(
          'Take-profit ${trigger.toStringAsFixed(0)} rejected by WEEX: '
          '${result.error ?? 'unknown error'}. Falling back to an app-side watch.',
        );
        armCloseTarget(low: lo, high: hi, source: source);
        return;
      }
      exchangeTakeProfit = ExchangeTakeProfit(
        orderId: ack.orderId,
        triggerPrice: trigger,
        direction: direction,
        planType: planType,
        source: source,
        placedAt: DateTime.now(),
      );
      // The exchange now owns the close; an app-side watch would only ask a
      // second time for the same level.
      _disarmCloseTarget();
      _log(
        '${planType == 'STOP_LOSS' ? 'Stop' : 'Take-profit'} set on WEEX at '
        '${trigger.toStringAsFixed(0)} USDT for the open '
        '${direction.name.toUpperCase()} (order ${ack.orderId}, from $source).',
      );
      unawaited(_persistExchangeTakeProfit());
      notifyListeners();
    } catch (error, stackTrace) {
      _log(
        'Take-profit submit failed: $error. Falling back to an app-side watch.',
        error: error,
        stackTrace: stackTrace,
      );
      armCloseTarget(low: lo, high: hi, source: source);
    }
  }

  /// Cancels the resting take-profit on the exchange, if any.
  Future<void> cancelExchangeTakeProfit({bool log = true}) async {
    final existing = exchangeTakeProfit;
    if (existing == null) return;
    exchangeTakeProfit = null;
    unawaited(_persistExchangeTakeProfit());
    notifyListeners();
    if (!useRustBridge || !_hasWeexCredentials) return;
    try {
      final result = await rust.weexCancelAlgoOrder(
        request: rust_weex.WeexCancelAlgoRequest(
          apiKey: config.weexApiKey,
          apiSecret: config.weexSecret,
          passphrase: config.weexPassphrase,
          symbol: symbolOf(selectedAsset),
          baseUrl: 'https://api-contract.weex.com',
          orderId: existing.orderId,
        ),
      );
      if (log || !result.ok) {
        _log(
          result.ok
              ? 'Take-profit ${existing.triggerPrice.toStringAsFixed(0)} cancelled on WEEX.'
              : 'Take-profit ${existing.triggerPrice.toStringAsFixed(0)} could not be cancelled: '
                    '${result.error ?? 'unknown error'} (order ${existing.orderId}).',
        );
      }
    } catch (error, stackTrace) {
      _log(
        'Take-profit cancel failed for order ${existing.orderId}: $error',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _persistExchangeTakeProfit() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final tp = exchangeTakeProfit;
      if (tp == null) {
        await prefs.remove(_exchangeTakeProfitPrefsKey);
      } else {
        await prefs.setString(
          _exchangeTakeProfitPrefsKey,
          jsonEncode(tp.toJson()),
        );
      }
    } catch (error, stackTrace) {
      _log('Take-profit could not be saved: $error',
          error: error, stackTrace: stackTrace);
    }
  }

  Future<void> _loadExchangeTakeProfit() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_exchangeTakeProfitPrefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        exchangeTakeProfit = ExchangeTakeProfit.fromJson(decoded);
        notifyListeners();
      }
    } catch (error, stackTrace) {
      _log('Take-profit could not be restored: $error',
          error: error, stackTrace: stackTrace);
    }
  }

  /// Forgets the local record once the position is gone: WEEX cancels a
  /// position-attached plan when that position closes.
  void _forgetExchangeTakeProfitIfFlat() {
    if (exchangeTakeProfit != null && position.isFlat) {
      final tp = exchangeTakeProfit!;
      exchangeTakeProfit = null;
      unawaited(_persistExchangeTakeProfit());
      _log(
        'Take-profit ${tp.triggerPrice.toStringAsFixed(0)} released with the closed position.',
      );
      notifyListeners();
    }
  }

  void armCloseTarget({
    required double low,
    required double high,
    required String source,
  }) {
    final lo = low <= high ? low : high;
    final hi = low <= high ? high : low;
    closeTargetWatch = CloseTargetWatch(
      low: lo,
      high: hi,
      source: source,
      armedAt: DateTime.now(),
    );
    closeTargetTriggered = false;
    _log(
      'Close-watch armed ${lo.toStringAsFixed(0)}–${hi.toStringAsFixed(0)} (from $source).',
    );
    unawaited(_persistCloseTarget());
    notifyListeners();
  }

  void cancelCloseTarget() {
    if (closeTargetWatch == null && !closeTargetTriggered) return;
    _disarmCloseTarget();
    _log('Close-watch cancelled.');
  }

  void _disarmCloseTarget() {
    closeTargetWatch = null;
    closeTargetTriggered = false;
    unawaited(_persistCloseTarget());
    notifyListeners();
  }

  void _disarmCloseTargetIfFlat() {
    if (closeTargetWatch != null && position.isFlat) {
      _disarmCloseTarget();
    }
  }

  Future<void> _persistCloseTarget() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final watch = closeTargetWatch;
      if (watch == null) {
        await prefs.remove(_closeTargetPrefsKey);
      } else {
        await prefs.setString(_closeTargetPrefsKey, jsonEncode(watch.toJson()));
      }
    } catch (error, stackTrace) {
      _log('Close-watch could not be saved: $error',
          error: error, stackTrace: stackTrace);
    }
  }

  Future<void> _loadCloseTarget() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_closeTargetPrefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        closeTargetWatch = CloseTargetWatch.fromJson(decoded);
      }
    } catch (_) {
      // A corrupt cache is non-fatal; start disarmed.
    }
  }

  /// Reads credentials from the encrypted store, or seals the ones that were
  /// just recovered from a plaintext preferences blob.
  Future<void> _loadSecrets({required bool migratedPlaintext}) async {
    if (migratedPlaintext) {
      // `config` already carries the plaintext credentials read above. Seal
      // them, then rewrite preferences without them.
      await _credentialStore.write(config.toSecretsJson());
      await _persistConfig();
      _log('Stored credentials were moved into encrypted storage.');
      await _hardenDataDirectory();
      return;
    }
    try {
      final stored = await _credentialStore.read();
      if (stored != null) {
        config = config.applySecrets(stored);
      }
      final store = _credentialStore;
      if (store is EncryptedCredentialStore && store.errors.isNotEmpty) {
        _log('Encrypted credentials could not be read: ${store.errors.first}');
      }
    } catch (error, stackTrace) {
      _log(
        'Encrypted credentials could not be read: $error',
        error: error,
        stackTrace: stackTrace,
      );
    }
    await _hardenDataDirectory();
  }

  Future<void> _hardenDataDirectory() async {
    final store = _credentialStore;
    if (store is EncryptedCredentialStore) {
      await store.harden();
    }
  }

  /// Migrates and removes config blobs written under earlier preference keys.
  /// Returns true when any of them carried plaintext credentials.
  Future<bool> _migrateLegacyConfigKeys(SharedPreferences prefs) async {
    var foundSecrets = false;
    final legacyKeys = prefs
        .getKeys()
        .where((key) => key != _configPrefsKey && key.endsWith(_configPrefsKeySuffix))
        .toList();
    for (final key in legacyKeys) {
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) continue;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final json = Map<String, Object?>.from(decoded);
          if (AppConfig.containsPlaintextSecrets(json)) {
            // Only adopt them if the current key had none, so a stale blob
            // cannot overwrite live credentials.
            if (config.weexApiKey.isEmpty && config.weexSecret.isEmpty) {
              config = config.applySecrets(json);
            }
            foundSecrets = true;
          }
        }
      } catch (_) {
        // An unparseable legacy blob is still worth deleting.
      }
      await prefs.remove(key);
      _log('Removed obsolete settings key "$key".');
    }
    return foundSecrets;
  }

  // --- risk limits ---------------------------------------------------------

  /// Updates the hard limits and pushes them to the Rust gate.
  Future<void> setRiskSettings(RiskSettings next) async {
    config = config.copyWith(risk: next);
    _log(
      next.killSwitch
          ? 'Risk: kill switch ENGAGED — new positions are blocked.'
          : 'Risk limits updated.',
    );
    notifyListeners();
    await _persistConfig();
  }

  /// Mirrors the configured limits into Rust, which enforces them on the
  /// submit path. Dart holds them only for the UI.
  Future<void> _pushRiskLimits() async {
    if (!useRustBridge) return;
    final risk = config.risk;
    try {
      await rust.riskSetLimits(
        limits: rust_risk.RiskLimits(
          killSwitch: risk.killSwitch,
          maxOrderNotional: _rustLimit(risk.maxOrderNotional),
          maxPositionNotional: _rustLimit(risk.maxPositionNotional),
          symbolAllowlist: risk.symbolAllowlist,
          maxLeverage: risk.maxLeverage,
          dailyLoss: _rustLimit(risk.dailyLoss),
          maxSignalAgeSecs: risk.maxSignalAgeSecs,
        ),
      );
    } catch (error, stackTrace) {
      _log(
        'Risk limits could not be applied: $error',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  static rust_risk.Limit _rustLimit(RiskLimitValue limit) =>
      rust_risk.Limit(value: limit.value, percent: limit.percent);

  /// Feeds the gate the live account facts it measures limits against.
  Future<void> _pushRiskContext({required double realizedPnlTodayUsd}) async {
    if (!useRustBridge) return;
    try {
      // Every book's mark, so the gate values an order at its own symbol's
      // price, and every book's notional, so the account-wide exposure rail
      // sees the whole account rather than the selected asset.
      final prices = [
        for (final asset in Asset.values)
          if (bookFor(asset).markPrice > 0)
            rust_risk.SymbolPrice(
              symbol: symbolOf(asset),
              price: bookFor(asset).markPrice,
            ),
      ];
      final totalNotional = Asset.values.fold<double>(
        0,
        (sum, asset) => sum + positionFor(asset).notionalUsd,
      );
      final leverage = Asset.values
          .map((asset) => positionFor(asset).crossCombinedLeverage)
          .fold<double>(0, (a, b) => a > b ? a : b);
      await rust.riskUpdateContext(
        context: rust_risk.RiskContext(
          referencePrice: config.markPrice,
          referencePrices: prices,
          openPositionNotionalUsd: totalNotional,
          leverage: leverage,
          realizedPnlTodayUsd: realizedPnlTodayUsd,
          // Percentage limits are measured against this.
          accountBalanceUsd: config.myBalanceUsd,
        ),
      );
    } catch (error) {
      // The gate keeps its previous context; a stale mark price only makes it
      // more conservative, never less.
    }
  }

  /// Realized PnL booked since midnight UTC, for the daily loss limit.
  double _realizedPnlToday(List<rust_weex.WeexExecutionSnapshot> executions) {
    final now = DateTime.now().toUtc();
    final startOfDay = DateTime.utc(now.year, now.month, now.day)
        .millisecondsSinceEpoch;
    return executions
        .where((execution) => execution.timestampMs >= startOfDay)
        .fold<double>(
          0,
          (total, execution) =>
              total + execution.realizedPnlUsdt - execution.feeUsdt,
        );
  }

  // --- crash recovery ------------------------------------------------------

  /// Resolves actions that were reserved but never finalized — the app died
  /// between reserving the slot and hearing back from WEEX.
  ///
  /// Nothing is ever re-submitted here. An order confirmed on the exchange is
  /// marked submitted; one the exchange has never heard of is marked failed so
  /// it stops blocking; anything we could not check is left pending and
  /// reported, because "don't know" must not become "try again".
  Future<void> reconcilePendingActions() async {
    if (!useRustBridge) return;
    if (config.weexApiKey.isEmpty || config.weexSecret.isEmpty) return;
    try {
      final result = await rust.dedupPendingActions(
        statePath: AppLog.telegramStatePath,
      );
      final pending = result.value;
      if (!result.ok || pending == null || pending.isEmpty) return;

      _log(
        '${pending.length} unfinished action(s) from a previous run; checking WEEX.',
      );
      var unresolved = 0;
      for (final action in pending) {
        final clientOrderId = PlannedOrder.clientOrderIdForDedupKey(
          action.dedupKey,
        );
        final status = await _lookupExchangeOrder(clientOrderId);
        if (status == null) {
          unresolved++;
          _log(
            'Unfinished action $clientOrderId could not be checked against WEEX; '
            'left pending for manual review.',
          );
          continue;
        }
        if (status.found) {
          await _finalizeTelegramDedup(
            action.dedupKey,
            rust_telegram.TelegramActionStatus.submitted,
          );
          _log(
            'Unfinished action $clientOrderId did reach WEEX '
            '(${status.status}, filled ${status.filledQty.toStringAsFixed(4)} ${displayOf(selectedAsset)}); '
            'recorded as submitted.',
          );
        } else {
          await _finalizeTelegramDedup(
            action.dedupKey,
            rust_telegram.TelegramActionStatus.failed,
          );
          _log(
            'Unfinished action $clientOrderId never reached WEEX; recorded as failed.',
          );
        }
      }
      if (unresolved > 0) {
        weexReconciliationError =
            '$unresolved unfinished order(s) could not be verified against WEEX. '
            'Check your WEEX order history before trading.';
        notifyListeners();
      }
    } catch (error, stackTrace) {
      _log(
        'Pending-action reconciliation failed: $error',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Returns null when the exchange could not be asked — distinct from a
  /// definitive "no such order".
  Future<rust_weex.WeexOrderStatus?> _lookupExchangeOrder(
    String clientOrderId,
  ) async {
    try {
      final result = await rust.weexLookupOrder(
        request: rust_weex.WeexAccountRequest(
          apiKey: config.weexApiKey,
          apiSecret: config.weexSecret,
          passphrase: config.weexPassphrase,
          symbol: symbolOf(selectedAsset),
          baseUrl: 'https://api-contract.weex.com',
          recentLookbackMs: _exchangeHistoryLookback.inMilliseconds,
        ),
        clientOrderId: clientOrderId,
      );
      return result.ok ? result.value : null;
    } catch (_) {
      return null;
    }
  }

  /// Wipes stored credentials — both the sealed blob and its key half.
  Future<void> forgetStoredCredentials() async {
    await _credentialStore.purge();
    config = config.applySecrets(const {});
    await _persistConfig();
    _log('Stored credentials were erased.');
    notifyListeners();
  }

  Future<void> _persistConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _configPrefsKey,
        jsonEncode(config.toPersistentJson()),
      );
      await _credentialStore.write(config.toSecretsJson());
      unawaited(_pushRiskLimits());
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

  PlannedOrder _buildOrder({
    required TradeKind kind,
    required TradeDirection direction,
    Asset? asset,
    required double sourceAmount,
    required SizeUnit sourceUnit,
    required String source,
    required TradeStatus status,
    double? triggerPrice,
    String? dedupKey,
  }) {
    final orderAsset = asset ?? selectedAsset;
    final ratio = config.scaleRatio;
    // Price and lot step both come from the order's own book: sizing an ETH
    // order off the BTC mark, or rounding it to BTC's finer step, would submit
    // a quantity the exchange either rejects or fills at the wrong size.
    final book = bookFor(orderAsset);
    final mark = book.markPrice > 0 ? book.markPrice : config.markPrice;
    final scaledQty = sourceUnit == SizeUnit.coin
        ? sourceAmount * ratio
        : mark > 0
        ? (sourceAmount * ratio) / mark
        : 0.0;
    final roundedQty = _roundDown(scaledQty, lotStepFor(orderAsset));
    final notionalPrice = triggerPrice ?? mark;
    final notional = notionalPrice > 0 ? roundedQty * notionalPrice : 0.0;
    final now = DateTime.now();
    final nonce = '${now.microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}';
    return PlannedOrder(
      id: nonce,
      kind: kind,
      asset: orderAsset,
      direction: direction,
      sourceAmount: sourceAmount,
      sourceUnit: sourceUnit,
      scaledQty: roundedQty,
      scaledNotionalUsd: notional,
      markPrice: mark,
      createdAt: now,
      status: status,
      source: source,
      triggerPrice: triggerPrice,
      dedupKey: dedupKey,
    );
  }

  PlannedOrder? _buildParsedEntryOrAddOrder({
    required TradeKind kind,
    required Asset asset,
    required TradeDirection? direction,
    required (double, SizeUnit)? size,
    required double? triggerPrice,
    required String source,
    String? dedupKey,
  }) {
    if (direction == null || size == null) return null;
    if (triggerPrice != null && (triggerPrice <= 0 || !triggerPrice.isFinite)) {
      return null;
    }
    return _buildOrder(
      kind: kind,
      asset: asset,
      direction: direction,
      sourceAmount: size.$1,
      sourceUnit: size.$2,
      source: triggerPrice == null
          ? source
          : '$source, limit trigger at ${triggerPrice.toStringAsFixed(2)} USDT',
      status: TradeStatus.pendingApproval,
      triggerPrice: triggerPrice,
      dedupKey: dedupKey,
    );
  }

  PlannedOrder? _buildParsedReductionOrder({
    required Asset asset,
    required TradeDirection? direction,
    required rust_interpreter.Size? size,
    required String source,
    String? dedupKey,
  }) {
    if (direction == null) return null;
    // A reduction only makes sense against a live position on the same side;
    // a stray "REDUCED …" with no matching position never trades. This reads
    // the signal's own book, not the selected one — reducing whichever asset
    // the user happens to be looking at would be the wrong position entirely.
    final book = bookFor(asset);
    final position = book.position;
    if (position.isFlat ||
        position.direction != direction ||
        position.qty <= 0) {
      return null;
    }
    final mark = book.markPrice;
    final step = lotStepFor(asset);
    // The channel expresses reductions as a percentage of the position, or as
    // a dollar / coin amount of the master's book. Dollar and coin amounts are
    // scaled like adds and capped at what we actually hold; percentages are
    // relative to our own position and need no scaling. Reductions are always
    // reduce-only, so overshooting simply flattens.
    final (quantity, label) = switch (size) {
      rust_interpreter.Size_Pct(:final field0)
          when field0 > 0 && field0 <= 1 =>
        (
          _roundDown(position.qty * field0, step),
          'reduce ${(field0 * 100).toStringAsFixed(0)}%',
        ),
      rust_interpreter.Size_Usdt(:final field0) when field0 > 0 && mark > 0 =>
        (
          _roundDown(
            min((field0 * config.scaleRatio) / mark, position.qty),
            step,
          ),
          'reduce \$${field0.toStringAsFixed(0)}',
        ),
      rust_interpreter.Size_Coin(:final field0) when field0 > 0 =>
        (
          _roundDown(
            min(field0 * config.scaleRatio, position.qty),
            step,
          ),
          'reduce ${field0.toStringAsFixed(4)} ${displayOf(asset)}',
        ),
      _ => (0.0, ''),
    };
    if (quantity <= 0) return null;
    return PlannedOrder(
      id: '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}',
      kind: TradeKind.reduce,
      asset: asset,
      direction: direction,
      sourceAmount: quantity,
      sourceUnit: SizeUnit.coin,
      scaledQty: quantity,
      scaledNotionalUsd: quantity * mark,
      markPrice: mark,
      createdAt: DateTime.now(),
      status: TradeStatus.pendingApproval,
      source: '$source, $label',
    );
  }

  double _roundDown(double value, double step) => roundDownToLot(value, step);

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
        'Submitting WEEX $orderType LIMIT $side ${order.scaledQty.toStringAsFixed(4)} ${displayOf(order.asset)} at trigger ${triggerPrice.toStringAsFixed(2)} USDT, simulation OFF.',
      );
      try {
        final result = await rust.weexSubmitAlgoOrder(
          request: rust_weex.WeexAlgoOrderRequest(
            apiKey: config.weexApiKey,
            apiSecret: config.weexSecret,
            passphrase: config.weexPassphrase,
            symbol: symbolOf(order.asset),
            baseUrl: 'https://api-contract.weex.com',
            side: side,
            qty: order.scaledQty,
            triggerPrice: triggerPrice,
            limitPrice: triggerPrice,
            orderType: orderType,
            clientAlgoId: 'tc-${order.id}-trigger',
            qtyStep: lotStepFor(order.asset),
            priceStep: priceStepFor(order.asset),
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
      'Submitting WEEX MARKET $side ${order.scaledQty.toStringAsFixed(4)} ${displayOf(order.asset)} (${order.scaledNotionalUsd.toStringAsFixed(2)} USDT), reduce_only=$reduceOnly, simulation OFF.',
    );
    try {
      final result = await rust.weexSubmitMarketOrder(
        request: rust_weex.WeexMarketOrderRequest(
          apiKey: config.weexApiKey,
          apiSecret: config.weexSecret,
          passphrase: config.weexPassphrase,
          symbol: symbolOf(order.asset),
          baseUrl: 'https://api-contract.weex.com',
          side: side,
          qty: order.scaledQty,
          reduceOnly: reduceOnly,
          clientOrderId: order.exchangeClientOrderId,
          qtyStep: lotStepFor(order.asset),
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
      final remaining = (position.qty - order.scaledQty).clamp(
        0.0,
        double.infinity,
      );
      position = PositionView(
        direction: remaining <= 0 ? null : order.direction,
        qty: remaining,
        notionalUsd: remaining * config.markPrice,
        unrealizedPnlUsd: 0,
        crossCombinedLeverage: position.crossCombinedLeverage,
      );
      _disarmCloseTargetIfFlat();
      _forgetExchangeTakeProfitIfFlat();
      return;
    }
    final sameDirection =
        position.direction == order.direction && !position.isFlat;
    final quantity = sameDirection
        ? position.qty + order.scaledQty
        : order.scaledQty;
    final notional = sameDirection
        ? position.notionalUsd + order.scaledNotionalUsd
        : order.scaledNotionalUsd;
    position = PositionView(
      direction: order.direction,
      qty: quantity,
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

  void _markPositionToMarket(double markPrice, {Asset? asset}) {
    final target = asset ?? selectedAsset;
    final current = positionFor(target);
    if (current.isFlat || markPrice <= 0 || current.qty <= 0) return;
    final entryPrice = current.notionalUsd / current.qty;
    final pnl = switch (current.direction) {
      TradeDirection.long => (markPrice - entryPrice) * current.qty,
      TradeDirection.short => (entryPrice - markPrice) * current.qty,
      null => 0.0,
    };
    _updateBook(
      target,
      (book) => book.copyWith(
        position: PositionView(
          direction: current.direction,
          qty: current.qty,
          notionalUsd: current.notionalUsd,
          unrealizedPnlUsd: pnl,
          crossCombinedLeverage: current.crossCombinedLeverage,
        ),
      ),
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
      TradeDirection.long => position.qty,
      TradeDirection.short => -position.qty,
      null => 0.0,
    };
    final returnedDelta = sortedExecutions.fold<double>(
      0,
      (sum, execution) => sum + _executionSignedDelta(execution),
    );
    var signedQty = currentSignedQty - returnedDelta;
    var avgEntry = signedQty.abs() > 0 && position.qty > 0
        ? position.notionalUsd / position.qty
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
    return execution.side == 'buy' ? execution.qty : -execution.qty;
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
          asset: Asset.values.firstWhere(
            (a) => symbolOf(a) == execution.symbol.toUpperCase(),
            orElse: () => selectedAsset,
          ),
          direction: direction,
          sourceAmount: execution.qty,
          sourceUnit: SizeUnit.coin,
          scaledQty: execution.qty,
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

  /// Maps a parsed action to an automatable trade kind. `close` and `ignore`
  /// return null so a parsed CLOSE never flows through the generic
  /// auto-approve path (the "close" verb is a common English word that appears
  /// in commentary). CLOSE is instead handled by [_handleParsedTelegramClose],
  /// which always queues a full flatten for the user to confirm. Kept static and
  /// [visibleForTesting] so this guarantee — CLOSE is never auto-executed — is
  /// locked by a unit test.
  /// Decides how a CLOSE signal is handled. A CLOSE never auto-executes: with a
  /// live position it always queues for the user to confirm, regardless of the
  /// auto-approve setting, so a stray "close" in commentary can never silently
  /// flatten the book. Pure and [visibleForTesting] so the "no auto-close"
  /// guarantee is locked by a test. [autoApprove] is accepted (and ignored) so
  /// the call sites read symmetrically with the other Telegram handlers.
  @visibleForTesting
  static TelegramCloseDisposition closeDisposition({
    required bool autoApprove,
    required PositionView position,
    bool assetAmbiguous = false,
  }) {
    if (position.isFlat ||
        position.qty <= 0 ||
        position.direction == null) {
      return TelegramCloseDisposition.ignoredNoPosition;
    }
    // Which book to flatten is not a question auto-approve can answer.
    if (assetAmbiguous) return TelegramCloseDisposition.queueForApproval;
    return autoApprove
        ? TelegramCloseDisposition.executeImmediately
        : TelegramCloseDisposition.queueForApproval;
  }

  @visibleForTesting
  static TradeKind? tradeKindFromParsed(rust_interpreter.ActionKind value) {
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
      rust_interpreter.Size_Usdt(:final field0) => (field0, SizeUnit.usdt),
      rust_interpreter.Size_Coin(:final field0) => (field0, SizeUnit.coin),
      rust_interpreter.Size_Pct() => null,
      rust_interpreter.Size_FullClose() => null,
      null => null,
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
      rust_interpreter.Size_Usdt(:final field0) =>
        '${field0.toStringAsFixed(2)} USDT',
      rust_interpreter.Size_Coin(:final field0) =>
        '${field0.toStringAsFixed(4)} coin',
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
    return '${order.direction.name.toUpperCase()} ${order.scaledQty.toStringAsFixed(4)} ${displayOf(order.asset)} (${order.scaledNotionalUsd.toStringAsFixed(2)} USDT)$trigger';
  }

  @override
  void dispose() {
    _weexPriceSubscription?.cancel();
    for (final subscription in _weexPriceSubscriptions.values) {
      subscription.cancel();
    }
    _weexPriceSubscriptions.clear();
    _telegramSubscription?.cancel();
    _weexRestPollTimer?.cancel();
    _weexReconcileTimer?.cancel();
    _chartSnapshotTimer?.cancel();
    super.dispose();
  }
}

class WeexPriceSnapshot {
  const WeexPriceSnapshot({
    required this.price,
    required this.source,
    this.exchangeTimeMs,
  });

  final double price;
  final String source;
  final int? exchangeTimeMs;
}

Future<WeexPriceSnapshot?> fetchWeexRestPrice({String symbol = 'BTCUSDT'}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    Object? lastError;
    try {
      final bookTicker = await _getJson(
        client,
        Uri.parse(
          'https://api-contract.weex.com/capi/v3/market/ticker/bookTicker?symbol=$symbol',
        ),
      );
      final bookPrice = parseWeexBookTickerPrice(bookTicker);
      if (bookPrice != null) {
        return WeexPriceSnapshot(
          price: bookPrice,
          source: 'WEEX contract REST bookTicker',
          exchangeTimeMs: parseWeexBookTickerTimeMs(bookTicker),
        );
      }
    } catch (error) {
      lastError = error;
    }

    try {
      final ticker = await _getJson(
        client,
        Uri.parse(
          'https://api-contract.weex.com/capi/v3/market/ticker/24hr?symbol=$symbol',
        ),
      );
      final tickerPrice = parseWeexTickerPrice(ticker);
      if (tickerPrice != null) {
        return WeexPriceSnapshot(
          price: tickerPrice,
          source: 'WEEX contract REST ticker',
          exchangeTimeMs: parseWeexTickerTimeMs(ticker),
        );
      }
    } catch (error) {
      lastError = error;
    }
    if (lastError != null) throw lastError;
    return null;
  } finally {
    client.close(force: true);
  }
}

Future<List<PriceCandle>> fetchWeexHistoricalCandles({
  String symbol = 'BTCUSDT',
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final candles = <int, PriceCandle>{};
    for (final request in const [('15m', 672), ('1h', 720)]) {
      final body = await _getJson(
        client,
        Uri.parse(
          'https://api-contract.weex.com/capi/v3/market/markPriceKlines?symbol=$symbol&interval=${request.$1}&limit=${request.$2}',
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
  final request = await client
      .getUrl(
        uri.replace(
          queryParameters: {
            ...uri.queryParameters,
            '_t': DateTime.now().millisecondsSinceEpoch.toString(),
          },
        ),
      )
      .timeout(const Duration(seconds: 8));
  request.headers.set(
    HttpHeaders.userAgentHeader,
    'trading-challenge-copytrader/1.0',
  );
  request.headers.set(HttpHeaders.acceptHeader, 'application/json');
  request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
  request.headers.set(HttpHeaders.pragmaHeader, 'no-cache');
  final response = await request.close().timeout(const Duration(seconds: 8));
  final body = await response.transform(utf8.decoder).join();
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw HttpException('HTTP ${response.statusCode}: $body', uri: uri);
  }
  return body;
}

/// One iteration of the verified flatten loop: what to do with the position the
/// exchange still reports after the previous close attempt.
enum FlattenStep {
  /// Lots remain and attempts are left — submit a reduce-only close for them.
  submit,

  /// The book is flat; the close is complete.
  done,

  /// A remainder smaller than one lot. It cannot be submitted, so retrying
  /// would loop forever — report it instead.
  dust,

  /// Still open after the last allowed attempt.
  giveUp,
}

/// Decides the next step of a verified flatten. Pure and [visibleForTesting] so
/// the termination guarantees — never loop on sub-lot dust, never exceed
/// [maxAttempts] — are locked by unit tests rather than by a live exchange.
@visibleForTesting
FlattenStep flattenStep({
  required double remainingBtc,
  required double lotStep,
  required int attempt,
  required int maxAttempts,
}) {
  if (remainingBtc <= 0) return FlattenStep.done;
  if (roundDownToLot(remainingBtc, lotStep) <= 0) return FlattenStep.dust;
  if (attempt > maxAttempts) return FlattenStep.giveUp;
  return FlattenStep.submit;
}

/// Floors `value` to a whole multiple of `step`.
///
/// The epsilon mirrors the Rust lot formatter (`weex.rs` `format_qty`). Binary
/// floating point makes 0.0055 / 0.0001 come out as 54.99999999999999, so a
/// bare floor drops a whole lot: a "full" close would submit 0.0054 BTC and
/// leave 0.0001 behind, which the exchange then reports as a partial reduce.
@visibleForTesting
double roundDownToLot(double value, double step) {
  if (step <= 0) return value;
  return ((value / step) + 1e-9).floorToDouble() * step;
}

@visibleForTesting
double? parseWeexBookTickerPrice(String body) {
  final decoded = jsonDecode(body);
  final ticker = decoded is List && decoded.isNotEmpty
      ? decoded.first
      : decoded;
  if (ticker is! Map<String, dynamic>) return null;
  final bid = _jsonDouble(ticker['bidPrice']);
  final ask = _jsonDouble(ticker['askPrice']);
  if (bid != null && ask != null) return (bid + ask) / 2;
  return bid ?? ask;
}

@visibleForTesting
int? parseWeexBookTickerTimeMs(String body) {
  final decoded = jsonDecode(body);
  final ticker = decoded is List && decoded.isNotEmpty
      ? decoded.first
      : decoded;
  if (ticker is! Map<String, dynamic>) return null;
  return _jsonInt(ticker['time']);
}

@visibleForTesting
double? parseWeexTickerPrice(String body) {
  final decoded = jsonDecode(body);
  final ticker = decoded is List && decoded.isNotEmpty
      ? decoded.first
      : decoded;
  if (ticker is! Map<String, dynamic>) return null;
  return _jsonDouble(ticker['lastPrice']) ?? _jsonDouble(ticker['markPrice']);
}

@visibleForTesting
int? parseWeexTickerTimeMs(String body) {
  final decoded = jsonDecode(body);
  final ticker = decoded is List && decoded.isNotEmpty
      ? decoded.first
      : decoded;
  if (ticker is! Map<String, dynamic>) return null;
  return _jsonInt(ticker['time']) ?? _jsonInt(ticker['closeTime']);
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
