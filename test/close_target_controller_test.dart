import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trading_challenge/src/models/trading.dart';
import 'package:trading_challenge/src/state/app_controller.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('armCloseTarget stores a normalized watch and clears triggered', () {
    final c = AppController();
    c.closeTargetTriggered = true;
    c.armCloseTarget(low: 63600, high: 63700, source: 'Telegram');
    expect(c.closeTargetWatch, isNotNull);
    expect(c.closeTargetWatch!.low, 63600);
    expect(c.closeTargetWatch!.high, 63700);
    expect(c.closeTargetTriggered, isFalse);
  });

  test('a newer arm replaces the previous watch', () {
    final c = AppController();
    c.armCloseTarget(low: 63600, high: 63700, source: 'a');
    c.armCloseTarget(low: 64000, high: 64100, source: 'b');
    expect(c.closeTargetWatch!.low, 64000);
    expect(c.closeTargetWatch!.source, 'b');
  });

  test('cancelCloseTarget disarms', () {
    final c = AppController();
    c.armCloseTarget(low: 63600, high: 63700, source: 'a');
    c.cancelCloseTarget();
    expect(c.closeTargetWatch, isNull);
    expect(c.closeTargetTriggered, isFalse);
  });
}
