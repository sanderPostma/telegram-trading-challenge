enum TradeDirection { long, short }

enum SizeUnit { btc, usdt }

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
    this.simulationMode = true,
    this.minimizeToTray = false,
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
  final bool simulationMode;
  final bool minimizeToTray;

  double get scaleRatio =>
      masterBalanceUsd <= 0 ? 0 : myBalanceUsd / masterBalanceUsd;

  Map<String, Object> toPersistentJson() {
    return {
      'weexApiKey': weexApiKey,
      'weexSecret': weexSecret,
      'weexPassphrase': weexPassphrase,
      'telegramApiId': telegramApiId,
      'telegramApiHash': telegramApiHash,
      'telegramPhone': telegramPhone,
      'masterBalanceUsd': masterBalanceUsd,
      'myBalanceUsd': myBalanceUsd,
      'autoUpdateMaster': autoUpdateMaster,
      'autoApprove': autoApprove,
      'simulationMode': simulationMode,
      'minimizeToTray': minimizeToTray,
    };
  }

  factory AppConfig.fromPersistentJson(Map<String, Object?> json) {
    return AppConfig(
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
      simulationMode: _boolValue(json['simulationMode'], true),
      minimizeToTray: false,
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
    bool? simulationMode,
    bool? minimizeToTray,
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
      simulationMode: simulationMode ?? this.simulationMode,
      minimizeToTray: minimizeToTray ?? this.minimizeToTray,
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

class PatternRule {
  const PatternRule({
    required this.name,
    required this.regex,
    required this.action,
    required this.priority,
    this.enabled = true,
  });

  final String name;
  final String regex;
  final TradeKind action;
  final int priority;
  final bool enabled;

  PatternRule copyWith({
    String? name,
    String? regex,
    TradeKind? action,
    int? priority,
    bool? enabled,
  }) {
    return PatternRule(
      name: name ?? this.name,
      regex: regex ?? this.regex,
      action: action ?? this.action,
      priority: priority ?? this.priority,
      enabled: enabled ?? this.enabled,
    );
  }
}

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
    );
  }
}

class PositionView {
  const PositionView({
    required this.direction,
    required this.qtyBtc,
    required this.notionalUsd,
    required this.unrealizedPnlUsd,
    this.crossCombinedLeverage = 0,
  });

  final TradeDirection? direction;
  final double qtyBtc;
  final double notionalUsd;
  final double unrealizedPnlUsd;
  final double crossCombinedLeverage;

  bool get isFlat => direction == null || qtyBtc == 0;
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
