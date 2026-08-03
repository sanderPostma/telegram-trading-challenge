import 'package:flutter_test/flutter_test.dart';
import 'package:trading_challenge/src/models/trading.dart';

void main() {
  test('CloseTargetWatch round-trips through JSON', () {
    final watch = CloseTargetWatch(
      low: 63600,
      high: 63700,
      source: 'Telegram Signals',
      armedAt: DateTime.parse('2026-08-03T12:00:00.000Z'),
    );
    final restored = CloseTargetWatch.fromJson(watch.toJson());
    expect(restored, isNotNull);
    expect(restored!.low, 63600);
    expect(restored.high, 63700);
    expect(restored.source, 'Telegram Signals');
    expect(restored.armedAt, DateTime.parse('2026-08-03T12:00:00.000Z'));
  });

  test('CloseTargetWatch.fromJson returns null on malformed data', () {
    expect(CloseTargetWatch.fromJson({'low': 'nan'}), isNull);
    expect(CloseTargetWatch.fromJson(const {}), isNull);
  });
}
