import 'package:flutter_test/flutter_test.dart';
import 'package:trading_challenge/src/models/trading.dart';

/// A stored config written before ETH existed is v1. Upgrading must not
/// silently widen a risk rail (adding ETHUSDT to the allowlist for the user)
/// nor silently drop one (deleting a configured per-order quantity cap). Both
/// are surfaced instead, and this pins that behaviour.
void main() {
  Map<String, Object?> v1Config({
    List<String> allowlist = const ['BTCUSDT'],
    double maxOrderQtyBtc = 0,
    Object? maxOrderNotional,
  }) {
    return {
      'masterBalanceUsd': 10000.0,
      'myBalanceUsd': 2000.0,
      'risk': {
        'killSwitch': false,
        'symbolAllowlist': allowlist,
        'maxOrderQtyBtc': maxOrderQtyBtc,
        'maxOrderNotional': ?maxOrderNotional,
      },
    };
  }

  test('a fresh install allows every tradable asset', () {
    // Not a migration case, but the same failure it guards against: a default
    // allowlist naming only some assets rejects the others at the risk gate
    // while the UI presents them as supported, and no prompt fires for a new
    // install to catch it.
    const fresh = AppConfig();
    expect(fresh.risk.symbolAllowlist, containsAll(['BTCUSDT', 'ETHUSDT']));
    expect(fresh.ethAllowlistPromptPending, isFalse);
  });

  test('an unversioned blob is treated as v1', () {
    final config = AppConfig.fromPersistentJson(v1Config());
    expect(config.configVersion, currentConfigVersion);
  });

  test('a BTC-only allowlist raises the prompt without being widened', () {
    final config = AppConfig.fromPersistentJson(v1Config());
    expect(
      config.ethAllowlistPromptPending,
      isTrue,
      reason: 'ETH would be rejected by the risk gate without an answer',
    );
    expect(
      config.risk.symbolAllowlist,
      ['BTCUSDT'],
      reason: 'the allowlist must not widen on its own',
    );
  });

  test('an allowlist already permitting ETH raises no prompt', () {
    final config = AppConfig.fromPersistentJson(
      v1Config(allowlist: const ['BTCUSDT', 'ETHUSDT']),
    );
    expect(config.ethAllowlistPromptPending, isFalse);
  });

  test('an empty allowlist means no allowlist, so no prompt', () {
    // Empty is "allow anything" — ETH is already permitted.
    final config = AppConfig.fromPersistentJson(v1Config(allowlist: const []));
    expect(config.ethAllowlistPromptPending, isFalse);
  });

  test('a configured quantity cap is carried across, not dropped', () {
    final config = AppConfig.fromPersistentJson(
      v1Config(maxOrderQtyBtc: 0.5),
    );
    expect(
      config.legacyOrderQtyCapBtc,
      0.5,
      reason: 'dropping it silently could leave no per-order cap at all',
    );
    expect(config.hasPendingMigration, isTrue);
  });

  test('no quantity cap set means nothing to carry', () {
    final config = AppConfig.fromPersistentJson(v1Config());
    expect(config.legacyOrderQtyCapBtc, 0);
  });

  test('a v2 blob round-trips without re-running the migration', () {
    final migrated = AppConfig.fromPersistentJson(v1Config());
    final answered = migrated.copyWith(
      ethAllowlistPromptPending: false,
      legacyOrderQtyCapBtc: 0,
    );

    final reloaded =
        AppConfig.fromPersistentJson(answered.toPersistentJson());

    expect(reloaded.configVersion, currentConfigVersion);
    expect(
      reloaded.ethAllowlistPromptPending,
      isFalse,
      reason: 'an answered prompt must not come back on the next launch',
    );
    expect(reloaded.legacyOrderQtyCapBtc, 0);
  });

  test('the retired quantity cap is gone from the persisted risk block', () {
    final config = AppConfig.fromPersistentJson(v1Config(maxOrderQtyBtc: 0.5));
    expect(config.toPersistentJson()['risk'], isNot(contains('maxOrderQtyBtc')));
  });

  test('existing notional limits survive the migration untouched', () {
    final config = AppConfig.fromPersistentJson(
      v1Config(maxOrderNotional: {'value': 15.0, 'percent': true}),
    );
    expect(config.risk.maxOrderNotional.value, 15);
    expect(config.risk.maxOrderNotional.percent, isTrue);
  });
}
