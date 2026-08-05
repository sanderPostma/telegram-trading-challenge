import 'package:flutter_test/flutter_test.dart';
import 'package:trading_challenge/src/models/trading.dart';

void main() {
  group('parsing what the user typed', () {
    test('a plain number is an absolute USDT amount', () {
      final limit = RiskLimitValue.parse('5000');
      expect(limit.value, 5000);
      expect(limit.percent, isFalse);
      expect(limit.resolve(7000), 5000);
      expect(limit.resolve(1000000), 5000);
    });

    test('a trailing % is a share of balance', () {
      final limit = RiskLimitValue.parse('15%');
      expect(limit.value, 15);
      expect(limit.percent, isTrue);
      expect(limit.resolve(7000), 1050);
      expect(limit.resolve(1000000), 150000);
    });

    test('tolerates spacing, currency signs, and comma decimals', () {
      expect(RiskLimitValue.parse(' 15 % ').percent, isTrue);
      expect(RiskLimitValue.parse('\$5000').value, 5000);
      expect(RiskLimitValue.parse('1500,50').value, 1500.5);
      expect(RiskLimitValue.parse('12,5%').value, 12.5);
    });

    test('blank and nonsense mean the limit is off', () {
      for (final raw in ['', '   ', 'abc', '0', '-5', '0%', 'x%']) {
        expect(
          RiskLimitValue.parse(raw).isOff,
          isTrue,
          reason: '"$raw" should leave the limit off',
        );
      }
    });

    test('round-trips through the text field', () {
      for (final raw in ['5000', '15%', '12.50%', '1500.50']) {
        expect(RiskLimitValue.parse(raw).text, raw);
      }
      // Normalised forms.
      expect(RiskLimitValue.parse('1500,50').text, '1500.50');
      expect(RiskLimitValue.parse(' 15 % ').text, '15%');
      expect(const RiskLimitValue.off().text, '');
    });
  });

  group('resolving against a balance', () {
    test('an off limit resolves to nothing', () {
      expect(const RiskLimitValue.off().resolve(7000), isNull);
    });

    test('a percentage with no known balance resolves to nothing', () {
      // The gate must treat this as "cannot verify", never as "no limit".
      expect(const RiskLimitValue(15, percent: true).resolve(0), isNull);
      expect(const RiskLimitValue(15, percent: true).resolve(-1), isNull);
    });

    test('an absolute limit does not need a balance', () {
      expect(const RiskLimitValue(5000).resolve(0), 5000);
    });

    test('one percentage setting spans the whole challenge', () {
      // 15% of balance, from the starting stake to the target.
      const limit = RiskLimitValue(15, percent: true);
      expect(limit.resolve(7000), closeTo(1050, 0.001));
      expect(limit.resolve(50000), closeTo(7500, 0.001));
      expect(limit.resolve(1000000), closeTo(150000, 0.001));
    });
  });

  group('persistence', () {
    test('survives a JSON round trip in both forms', () {
      for (final limit in [
        const RiskLimitValue(5000),
        const RiskLimitValue(15, percent: true),
        const RiskLimitValue.off(),
      ]) {
        final restored = RiskLimitValue.fromJson(limit.toJson());
        expect(restored.value, limit.value);
        expect(restored.percent, limit.percent);
      }
    });

    test('an older plain-number setting reads as absolute USDT', () {
      final restored = RiskLimitValue.fromJson(500);
      expect(restored.value, 500);
      expect(restored.percent, isFalse);
    });

    test('a missing or malformed setting reads as off', () {
      expect(RiskLimitValue.fromJson(null).isOff, isTrue);
      expect(RiskLimitValue.fromJson('nonsense').isOff, isTrue);
    });
  });
}
