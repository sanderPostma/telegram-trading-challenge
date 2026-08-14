import '../bridge/interpreter.dart' show Asset;

enum TradeDirection { long, short }

/// Manual-entry size unit. [coin] is a quantity of whichever asset the order is
/// for — it is not BTC-specific.
enum SizeUnit { coin, usdt }

/// Bumped whenever a stored config needs rewriting to stay correct.
///
/// v1 is the BTC-only layout. v2 adds ETH, which retires the BTC-denominated
/// per-order quantity cap and makes the BTC-only symbol allowlist inherited
/// from v1 actively harmful — it silently rejects every ETH signal.
const int currentConfigVersion = 2;

enum TradeKind { enter, add, reduce, close, manual }

enum TradeStatus { pendingApproval, simulated, placed, rejected, failed }

class SeriesPoint {
  const SeriesPoint(this.ts, this.value);

  final int ts;
  final double value;
}

class PriceCandle {
  const PriceCandle({required this.timestampMs, required this.close});

  final int timestampMs;
  final double close;
}

/// An armed advisory full-close price watch parsed from the signal channel.
/// [low]/[high] bound the target zone (low <= high). Held on the controller and
/// persisted so it survives an app restart.
class CloseTargetWatch {
  const CloseTargetWatch({
    required this.low,
    required this.high,
    required this.source,
    required this.armedAt,
  });

  final double low;
  final double high;
  final String source;
  final DateTime armedAt;

  Map<String, Object> toJson() => {
    'low': low,
    'high': high,
    'source': source,
    'armedAt': armedAt.toIso8601String(),
  };

  static CloseTargetWatch? fromJson(Map<String, Object?> json) {
    final low = json['low'];
    final high = json['high'];
    if (low is! num || high is! num) return null;
    final armedRaw = json['armedAt'];
    return CloseTargetWatch(
      low: low.toDouble(),
      high: high.toDouble(),
      source: json['source'] is String ? json['source'] as String : '',
      armedAt: (armedRaw is String ? DateTime.tryParse(armedRaw) : null) ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// A take-profit plan resting on the exchange against the open position.
///
/// Unlike [CloseTargetWatch] — an app-side alert that asks before closing —
/// this lives on WEEX: it fires and closes the position even if the app is
/// offline. [orderId] is the exchange id needed to cancel or replace it.
class ExchangeTakeProfit {
  const ExchangeTakeProfit({
    required this.orderId,
    required this.triggerPrice,
    required this.direction,
    required this.planType,
    required this.source,
    required this.placedAt,
  });

  final String orderId;
  final double triggerPrice;
  final TradeDirection direction;

  /// `TAKE_PROFIT` or `STOP_LOSS` — a target below a long (or above a short)
  /// is a stop, and WEEX rejects it as a take-profit.
  final String planType;
  final String source;
  final DateTime placedAt;

  bool get isStop => planType == 'STOP_LOSS';

  Map<String, Object> toJson() => {
    'orderId': orderId,
    'triggerPrice': triggerPrice,
    'direction': direction.name,
    'planType': planType,
    'source': source,
    'placedAt': placedAt.toIso8601String(),
  };

  static ExchangeTakeProfit? fromJson(Map<String, Object?> json) {
    final orderId = json['orderId'];
    final triggerPrice = json['triggerPrice'];
    if (orderId is! String || orderId.isEmpty || triggerPrice is! num) {
      return null;
    }
    final direction = json['direction'] == 'short'
        ? TradeDirection.short
        : TradeDirection.long;
    final placedRaw = json['placedAt'];
    return ExchangeTakeProfit(
      orderId: orderId,
      triggerPrice: triggerPrice.toDouble(),
      direction: direction,
      planType: json['planType'] is String
          ? json['planType'] as String
          : 'TAKE_PROFIT',
      source: json['source'] is String ? json['source'] as String : '',
      placedAt: (placedRaw is String ? DateTime.tryParse(placedRaw) : null) ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// A limit written either as an absolute USD amount or as a percentage of
/// account balance — `5000` or `15%`.
///
/// The percentage form is what makes one setting survive a balance-scaling
/// challenge: a fixed \$500 per-order cap that suits \$7k strangles the same
/// strategy at \$500k, silently. Mirrors `Limit` in `rust/src/risk.rs`.
class RiskLimitValue {
  const RiskLimitValue(this.value, {this.percent = false});

  const RiskLimitValue.off() : value = 0, percent = false;

  final double value;
  final bool percent;

  bool get isOff => !value.isFinite || value <= 0;

  /// The limit in USD for [accountBalanceUsd], or null when it is off or a
  /// percentage with no known balance.
  double? resolve(double accountBalanceUsd) {
    if (isOff) return null;
    if (!percent) return value;
    if (accountBalanceUsd <= 0 || !accountBalanceUsd.isFinite) return null;
    return accountBalanceUsd * value / 100;
  }

  /// Round-trips with [parse]: what the user typed, normalised.
  String get text {
    if (isOff) return '';
    final number = value == value.roundToDouble()
        ? value.round().toString()
        : value.toStringAsFixed(2);
    return percent ? '$number%' : number;
  }

  /// Reads `5000`, `15%`, `1 500,50`, or blank. Anything unparseable is off.
  static RiskLimitValue parse(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return const RiskLimitValue.off();
    final percent = text.endsWith('%');
    if (percent) text = text.substring(0, text.length - 1).trim();
    text = text
        .replaceAll(RegExp(r'[\s\u00a0$]'), '')
        .replaceAll(',', '.');
    final parsed = double.tryParse(text);
    if (parsed == null || !parsed.isFinite || parsed <= 0) {
      return const RiskLimitValue.off();
    }
    return RiskLimitValue(parsed, percent: percent);
  }

  Map<String, Object> toJson() => {'value': value, 'percent': percent};

  /// Accepts the older plain-number form as an absolute USD amount.
  static RiskLimitValue fromJson(Object? json) {
    if (json is num) return RiskLimitValue(json.toDouble());
    if (json is Map) {
      final map = Map<String, Object?>.from(json);
      return RiskLimitValue(
        _doubleValue(map['value'], 0),
        percent: _boolValue(map['percent'], false),
      );
    }
    return const RiskLimitValue.off();
  }
}

/// Hard limits applied to every order, below the signal parser.
///
/// A value of 0 means "not configured" and leaves that rail open, so an
/// upgrade changes nothing until the user sets a number. The exception is
/// [symbolAllowlist], which is empty for "no allowlist".
///
/// The authoritative copy lives in Rust; this mirrors it for the UI and for
/// persistence. See `rust/src/risk.rs`.
class RiskSettings {
  const RiskSettings({
    this.killSwitch = false,
    this.maxOrderNotional = const RiskLimitValue.off(),
    this.maxPositionNotional = const RiskLimitValue.off(),
    this.symbolAllowlist = const ['BTCUSDT'],
    this.maxLeverage = 0,
    this.dailyLoss = const RiskLimitValue.off(),
    this.maxSignalAgeSecs = 0,
  });

  final bool killSwitch;
  final RiskLimitValue maxOrderNotional;
  final RiskLimitValue maxPositionNotional;
  final List<String> symbolAllowlist;
  final double maxLeverage;
  final RiskLimitValue dailyLoss;
  final int maxSignalAgeSecs;

  /// True when at least one numeric rail is armed. The UI nags while false.
  bool get hasAnyLimit =>
      !maxOrderNotional.isOff ||
      !maxPositionNotional.isOff ||
      maxLeverage > 0 ||
      !dailyLoss.isOff ||
      maxSignalAgeSecs > 0;

  RiskSettings copyWith({
    bool? killSwitch,
    RiskLimitValue? maxOrderNotional,
    RiskLimitValue? maxPositionNotional,
    List<String>? symbolAllowlist,
    double? maxLeverage,
    RiskLimitValue? dailyLoss,
    int? maxSignalAgeSecs,
  }) {
    return RiskSettings(
      killSwitch: killSwitch ?? this.killSwitch,
      maxOrderNotional: maxOrderNotional ?? this.maxOrderNotional,
      maxPositionNotional: maxPositionNotional ?? this.maxPositionNotional,
      symbolAllowlist: symbolAllowlist ?? this.symbolAllowlist,
      maxLeverage: maxLeverage ?? this.maxLeverage,
      dailyLoss: dailyLoss ?? this.dailyLoss,
      maxSignalAgeSecs: maxSignalAgeSecs ?? this.maxSignalAgeSecs,
    );
  }

  Map<String, Object> toJson() => {
        'killSwitch': killSwitch,
        'maxOrderNotional': maxOrderNotional.toJson(),
        'maxPositionNotional': maxPositionNotional.toJson(),
        'symbolAllowlist': symbolAllowlist,
        'maxLeverage': maxLeverage,
        'dailyLoss': dailyLoss.toJson(),
        'maxSignalAgeSecs': maxSignalAgeSecs,
      };

  factory RiskSettings.fromJson(Map<String, Object?> json) {
    final allowlistRaw = json['symbolAllowlist'];
    return RiskSettings(
      killSwitch: _boolValue(json['killSwitch'], false),
      // `maxOrderNotionalUsd` etc. are the older plain-number keys.
      maxOrderNotional: RiskLimitValue.fromJson(
        json['maxOrderNotional'] ?? json['maxOrderNotionalUsd'],
      ),
      maxPositionNotional: RiskLimitValue.fromJson(
        json['maxPositionNotional'] ?? json['maxPositionNotionalUsd'],
      ),
      symbolAllowlist: allowlistRaw is List
          ? allowlistRaw
              .map((entry) => entry.toString().trim().toUpperCase())
              .where((entry) => entry.isNotEmpty)
              .toList()
          : const ['BTCUSDT'],
      maxLeverage: _doubleValue(json['maxLeverage'], 0),
      dailyLoss: RiskLimitValue.fromJson(
        json['dailyLoss'] ?? json['dailyLossLimitUsd'],
      ),
      maxSignalAgeSecs: _doubleValue(json['maxSignalAgeSecs'], 0).round(),
    );
  }
}

class AppConfig {
  const AppConfig({
    this.weexApiKey = '',
    this.weexSecret = '',
    this.weexPassphrase = '',
    this.telegramApiId = '',
    this.telegramApiHash = '',
    this.telegramPhone = '',
    this.masterBalanceUsd = 10000,
    this.myBalanceUsd = 2000,
    this.markPrice = 0,
    this.autoUpdateMaster = true,
    this.autoApprove = false,
    this.hasSeenAutoApproveWarning = false,
    this.simulationMode = true,
    this.minimizeToTray = false,
    this.risk = const RiskSettings(),
    this.configVersion = currentConfigVersion,
    this.ethAllowlistPromptPending = false,
    this.legacyOrderQtyCapBtc = 0,
  });

  final String weexApiKey;
  final String weexSecret;
  final String weexPassphrase;
  final String telegramApiId;
  final String telegramApiHash;
  final String telegramPhone;
  final double masterBalanceUsd;
  final double myBalanceUsd;
  final double markPrice;
  final bool autoUpdateMaster;
  final bool autoApprove;
  final bool hasSeenAutoApproveWarning;
  final bool simulationMode;
  final bool minimizeToTray;
  final RiskSettings risk;

  /// Schema version of the stored config. See [currentConfigVersion].
  final int configVersion;

  /// Set by the v1 -> v2 migration when the stored symbol allowlist permits
  /// BTCUSDT but not ETHUSDT, which would silently reject every ETH signal.
  ///
  /// The allowlist is deliberately left untouched until the user answers:
  /// widening a risk rail without being asked is exactly the kind of silent
  /// change this app should never make.
  final bool ethAllowlistPromptPending;

  /// A v1 `maxOrderQtyBtc` carried across the migration, in BTC.
  ///
  /// Non-zero means the rail has not been converted yet. Conversion needs a
  /// mark price, which is not available at load time, so the controller does it
  /// once a price arrives. Dropping the cap silently could leave an account
  /// with no per-order limit at all.
  final double legacyOrderQtyCapBtc;

  bool get hasPendingMigration =>
      ethAllowlistPromptPending || legacyOrderQtyCapBtc > 0;

  double get scaleRatio =>
      masterBalanceUsd <= 0 ? 0 : myBalanceUsd / masterBalanceUsd;

  /// The credential half of the config. Encrypted at rest — never written to
  /// `shared_preferences`. Keep in step with [applySecrets].
  Map<String, Object> toSecretsJson() {
    return {
      'weexApiKey': weexApiKey,
      'weexSecret': weexSecret,
      'weexPassphrase': weexPassphrase,
      'telegramApiId': telegramApiId,
      'telegramApiHash': telegramApiHash,
      'telegramPhone': telegramPhone,
    };
  }

  /// Field names that must never appear in plaintext preferences.
  static const secretFieldNames = <String>{
    'weexApiKey',
    'weexSecret',
    'weexPassphrase',
    'telegramApiId',
    'telegramApiHash',
    'telegramPhone',
  };

  /// Returns a copy carrying the credentials from [json].
  AppConfig applySecrets(Map<String, Object?> json) {
    return copyWith(
      weexApiKey: _stringValue(json['weexApiKey']),
      weexSecret: _stringValue(json['weexSecret']),
      weexPassphrase: _stringValue(json['weexPassphrase']),
      telegramApiId: _stringValue(json['telegramApiId']),
      telegramApiHash: _stringValue(json['telegramApiHash']),
      telegramPhone: _stringValue(json['telegramPhone']),
    );
  }

  /// True when [json] still carries credentials — an unmigrated plaintext blob
  /// left over from before the credentials were encrypted.
  static bool containsPlaintextSecrets(Map<String, Object?> json) {
    return secretFieldNames.any(
      (name) => _stringValue(json[name]).isNotEmpty,
    );
  }

  /// The non-secret half. This is what reaches `shared_preferences`.
  Map<String, Object> toPersistentJson() {
    return {
      'masterBalanceUsd': masterBalanceUsd,
      'myBalanceUsd': myBalanceUsd,
      'autoUpdateMaster': autoUpdateMaster,
      'autoApprove': autoApprove,
      'hasSeenAutoApproveWarning': hasSeenAutoApproveWarning,
      'simulationMode': simulationMode,
      'minimizeToTray': minimizeToTray,
      'risk': risk.toJson(),
      'configVersion': configVersion,
      'ethAllowlistPromptPending': ethAllowlistPromptPending,
      'legacyOrderQtyCapBtc': legacyOrderQtyCapBtc,
    };
  }

  factory AppConfig.fromPersistentJson(Map<String, Object?> json) {
    // A blob written before versioning existed is v1 by definition.
    final storedVersion = _doubleValue(json['configVersion'], 1).round();
    final riskJson = json['risk'] is Map
        ? Map<String, Object?>.from(json['risk'] as Map)
        : const <String, Object?>{};
    final risk = riskJson.isEmpty
        ? const RiskSettings()
        : RiskSettings.fromJson(riskJson);
    final migratingFromV1 = storedVersion < 2;

    // v1 stored a BTC-denominated per-order quantity cap. It cannot mean
    // anything across two assets, so it is retired — but carried, not dropped,
    // until it has been converted to a notional the user can see.
    final legacyQtyCap = migratingFromV1
        ? _doubleValue(riskJson['maxOrderQtyBtc'], 0)
        : _doubleValue(json['legacyOrderQtyCapBtc'], 0);

    // Every v1 install allows BTCUSDT and nothing else, whether or not the user
    // ever configured it, so ETH would be rejected by the risk gate while the
    // UI showed it as supported.
    final allowsBtcOnly = risk.symbolAllowlist.isNotEmpty &&
        !risk.symbolAllowlist.contains('ETHUSDT');
    final promptPending = migratingFromV1
        ? allowsBtcOnly
        : _boolValue(json['ethAllowlistPromptPending'], false);

    return AppConfig(
      configVersion: currentConfigVersion,
      ethAllowlistPromptPending: promptPending,
      legacyOrderQtyCapBtc: legacyQtyCap,
      weexApiKey: _stringValue(json['weexApiKey']),
      weexSecret: _stringValue(json['weexSecret']),
      weexPassphrase: _stringValue(json['weexPassphrase']),
      telegramApiId: _stringValue(json['telegramApiId']),
      telegramApiHash: _stringValue(json['telegramApiHash']),
      telegramPhone: _stringValue(json['telegramPhone']),
      masterBalanceUsd: _doubleValue(json['masterBalanceUsd'], 10000),
      myBalanceUsd: _doubleValue(json['myBalanceUsd'], 2000),
      autoUpdateMaster: _boolValue(json['autoUpdateMaster'], true),
      autoApprove: _boolValue(json['autoApprove'], false),
      hasSeenAutoApproveWarning: _boolValue(json['hasSeenAutoApproveWarning'], false),
      simulationMode: _boolValue(json['simulationMode'], true),
      minimizeToTray: false,
      risk: risk,
    );
  }

  AppConfig copyWith({
    String? weexApiKey,
    String? weexSecret,
    String? weexPassphrase,
    String? telegramApiId,
    String? telegramApiHash,
    String? telegramPhone,
    double? masterBalanceUsd,
    double? myBalanceUsd,
    double? markPrice,
    bool? autoUpdateMaster,
    bool? autoApprove,
    bool? hasSeenAutoApproveWarning,
    bool? simulationMode,
    bool? minimizeToTray,
    RiskSettings? risk,
    int? configVersion,
    bool? ethAllowlistPromptPending,
    double? legacyOrderQtyCapBtc,
  }) {
    return AppConfig(
      weexApiKey: weexApiKey ?? this.weexApiKey,
      weexSecret: weexSecret ?? this.weexSecret,
      weexPassphrase: weexPassphrase ?? this.weexPassphrase,
      telegramApiId: telegramApiId ?? this.telegramApiId,
      telegramApiHash: telegramApiHash ?? this.telegramApiHash,
      telegramPhone: telegramPhone ?? this.telegramPhone,
      masterBalanceUsd: masterBalanceUsd ?? this.masterBalanceUsd,
      myBalanceUsd: myBalanceUsd ?? this.myBalanceUsd,
      markPrice: markPrice ?? this.markPrice,
      autoUpdateMaster: autoUpdateMaster ?? this.autoUpdateMaster,
      autoApprove: autoApprove ?? this.autoApprove,
      hasSeenAutoApproveWarning: hasSeenAutoApproveWarning ?? this.hasSeenAutoApproveWarning,
      simulationMode: simulationMode ?? this.simulationMode,
      minimizeToTray: minimizeToTray ?? this.minimizeToTray,
      risk: risk ?? this.risk,
      configVersion: configVersion ?? this.configVersion,
      ethAllowlistPromptPending:
          ethAllowlistPromptPending ?? this.ethAllowlistPromptPending,
      legacyOrderQtyCapBtc: legacyOrderQtyCapBtc ?? this.legacyOrderQtyCapBtc,
    );
  }
}

String _stringValue(Object? value) => value is String ? value : '';

double _doubleValue(Object? value, double fallback) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? fallback;
  return fallback;
}

bool _boolValue(Object? value, bool fallback) =>
    value is bool ? value : fallback;

class PlannedOrder {
  const PlannedOrder({
    required this.id,
    required this.kind,
    required this.direction,
    required this.sourceAmount,
    required this.sourceUnit,
    required this.scaledBtc,
    required this.scaledNotionalUsd,
    required this.markPrice,
    required this.createdAt,
    required this.status,
    required this.source,
    this.triggerPrice,
    this.dedupKey,
  });

  final String id;
  final TradeKind kind;
  final TradeDirection direction;
  final double sourceAmount;
  final SizeUnit sourceUnit;
  final double scaledBtc;
  final double scaledNotionalUsd;
  final double markPrice;
  final DateTime createdAt;
  final TradeStatus status;
  final String source;
  final double? triggerPrice;

  /// The dedup key of the Telegram action that produced this order, when it
  /// came from a signal. Null for manual orders.
  ///
  /// It is the seed for [exchangeClientOrderId], which is what makes a
  /// crash mid-submit recoverable: the id sent to WEEX can be recomputed from
  /// durable dedup state alone, with nothing extra to persist.
  final String? dedupKey;

  bool get isConditional => triggerPrice != null;

  /// The idempotency id sent to WEEX. Derived from [dedupKey] when present so
  /// it survives a restart; otherwise from the local order id.
  String get exchangeClientOrderId {
    final key = dedupKey;
    if (key == null || key.isEmpty) return 'tc-$id';
    return clientOrderIdForDedupKey(key);
  }

  /// Same derivation, reachable without an order in hand — startup
  /// reconciliation only has the dedup key.
  static String clientOrderIdForDedupKey(String dedupKey) {
    final trimmed = dedupKey.length > 24 ? dedupKey.substring(0, 24) : dedupKey;
    return 'tc-$trimmed';
  }

  PlannedOrder copyWith({TradeStatus? status}) {
    return PlannedOrder(
      id: id,
      kind: kind,
      direction: direction,
      sourceAmount: sourceAmount,
      sourceUnit: sourceUnit,
      scaledBtc: scaledBtc,
      scaledNotionalUsd: scaledNotionalUsd,
      markPrice: markPrice,
      createdAt: createdAt,
      status: status ?? this.status,
      source: source,
      triggerPrice: triggerPrice,
      dedupKey: dedupKey,
    );
  }

  PlannedOrder copyWithScaled({
    required double scaledBtc,
    required double scaledNotionalUsd,
  }) {
    return PlannedOrder(
      id: id,
      kind: kind,
      direction: direction,
      sourceAmount: sourceAmount,
      sourceUnit: sourceUnit,
      scaledBtc: scaledBtc,
      scaledNotionalUsd: scaledNotionalUsd,
      markPrice: markPrice,
      createdAt: createdAt,
      status: status,
      source: source,
      triggerPrice: triggerPrice,
      dedupKey: dedupKey,
    );
  }
}

class PositionView {
  const PositionView({
    required this.direction,
    required this.qty,
    required this.notionalUsd,
    required this.unrealizedPnlUsd,
    this.crossCombinedLeverage = 0,
  });

  final TradeDirection? direction;
  final double qty;
  final double notionalUsd;
  final double unrealizedPnlUsd;
  final double crossCombinedLeverage;

  bool get isFlat => direction == null || qty == 0;
}

class TradeHistoryEntry {
  const TradeHistoryEntry({
    required this.id,
    required this.time,
    required this.side,
    required this.filledUsdt,
    required this.avgPrice,
    required this.realizedPnlUsdt,
  });

  final String id;
  final DateTime time;
  final String side;
  final double filledUsdt;
  final double avgPrice;
  final double realizedPnlUsdt;
}

/// Per-asset trading state.
///
/// BTC and ETH can be open at the same time, so everything that belongs to one
/// instrument — its mark price, its position, its resting take-profit, its
/// close-target watch — lives here rather than on the controller. Account-level
/// facts (balance, equity history, realized PnL) stay on the controller because
/// they are genuinely shared across books.
class AssetBook {
  const AssetBook({
    required this.asset,
    this.markPrice = 0,
    this.position = const PositionView(
      direction: null,
      qty: 0,
      notionalUsd: 0,
      unrealizedPnlUsd: 0,
    ),
    this.closeTargetWatch,
    this.closeTargetTriggered = false,
    this.exchangeTakeProfit,
  });

  final Asset asset;
  final double markPrice;
  final PositionView position;
  final CloseTargetWatch? closeTargetWatch;
  final bool closeTargetTriggered;
  final ExchangeTakeProfit? exchangeTakeProfit;

  bool get isFlat => position.isFlat;
  bool get hasFreshPrice => markPrice > 0;

  AssetBook copyWith({
    double? markPrice,
    PositionView? position,
    CloseTargetWatch? closeTargetWatch,
    bool clearCloseTargetWatch = false,
    bool? closeTargetTriggered,
    ExchangeTakeProfit? exchangeTakeProfit,
    bool clearExchangeTakeProfit = false,
  }) {
    return AssetBook(
      asset: asset,
      markPrice: markPrice ?? this.markPrice,
      position: position ?? this.position,
      closeTargetWatch:
          clearCloseTargetWatch ? null : (closeTargetWatch ?? this.closeTargetWatch),
      closeTargetTriggered: closeTargetTriggered ?? this.closeTargetTriggered,
      exchangeTakeProfit: clearExchangeTakeProfit
          ? null
          : (exchangeTakeProfit ?? this.exchangeTakeProfit),
    );
  }
}
