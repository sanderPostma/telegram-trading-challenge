import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trading_challenge/src/models/trading.dart';
import 'package:trading_challenge/src/security/credential_store.dart';
import 'package:trading_challenge/src/state/app_controller.dart';

const _configPrefsKey = 'flutter.trading_challenge.app_config.v1';
// A config blob written under an older preference prefix.
const _legacyConfigPrefsKey = 'flutter.legacy_prefix.app_config.v1';

const _fullConfig = AppConfig(
  weexApiKey: 'access-key',
  weexSecret: 'secret-key',
  weexPassphrase: 'passphrase',
  telegramPhone: '+15551234567',
  telegramApiId: '12345',
  telegramApiHash: 'api-hash',
  masterBalanceUsd: 10000,
  myBalanceUsd: 2000,
  markPrice: 104000,
  autoUpdateMaster: false,
  autoApprove: true,
  simulationMode: false,
);

void main() {
  test('persists user setup values across controller restarts', () async {
    SharedPreferences.setMockInitialValues({});
    // Credentials live in the encrypted store in production; tests share one
    // in-memory store between the two controllers to stand in for it.
    final credentials = InMemoryCredentialStore();
    final controller = AppController(credentialStore: credentials);

    await controller.saveConfig(_fullConfig, log: false);

    final reloaded = AppController(credentialStore: credentials);
    await reloaded.loadConfig();

    expect(reloaded.config.weexApiKey, 'access-key');
    expect(reloaded.config.weexSecret, 'secret-key');
    expect(reloaded.config.weexPassphrase, 'passphrase');
    expect(reloaded.config.telegramPhone, '+15551234567');
    expect(reloaded.config.telegramApiId, '12345');
    expect(reloaded.config.telegramApiHash, 'api-hash');
    expect(reloaded.config.masterBalanceUsd, 10000);
    expect(reloaded.config.myBalanceUsd, 2000);
    expect(reloaded.config.autoUpdateMaster, isTrue);
    expect(reloaded.config.autoApprove, isTrue);
    expect(reloaded.config.simulationMode, isFalse);
    expect(reloaded.config.markPrice, 0);
  });

  test('no credential ever reaches the preferences file', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = AppController(credentialStore: InMemoryCredentialStore());

    await controller.saveConfig(_fullConfig, log: false);

    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString('trading_challenge.app_config.v1')!;
    for (final secret in [
      'access-key',
      'secret-key',
      'passphrase',
      '+15551234567',
      '12345',
      'api-hash',
    ]) {
      expect(
        stored,
        isNot(contains(secret)),
        reason: '"$secret" leaked into shared_preferences',
      );
    }
    for (final field in AppConfig.secretFieldNames) {
      expect(stored, isNot(contains(field)));
    }
    // The non-secret half is still there.
    expect(jsonDecode(stored), containsPair('autoApprove', true));
  });

  test('migrates plaintext credentials out of an old preferences blob',
      () async {
    // What an install from before encryption looks like on disk.
    SharedPreferences.setMockInitialValues({
      _configPrefsKey: jsonEncode({
        'weexApiKey': 'legacy-key',
        'weexSecret': 'legacy-secret',
        'weexPassphrase': 'legacy-pass',
        'telegramApiId': '999',
        'telegramApiHash': 'legacy-hash',
        'telegramPhone': '+31600000000',
        'myBalanceUsd': 4321.0,
        'simulationMode': false,
      }),
    });
    final credentials = InMemoryCredentialStore();
    final controller = AppController(credentialStore: credentials);

    await controller.loadConfig();

    // Credentials survived the move...
    expect(controller.config.weexApiKey, 'legacy-key');
    expect(controller.config.weexSecret, 'legacy-secret');
    expect(controller.config.telegramApiHash, 'legacy-hash');
    expect(controller.config.myBalanceUsd, 4321.0);
    expect(await credentials.read(), containsPair('weexSecret', 'legacy-secret'));

    // ...and the plaintext is gone from preferences.
    final prefs = await SharedPreferences.getInstance();
    final rewritten = prefs.getString('trading_challenge.app_config.v1')!;
    expect(rewritten, isNot(contains('legacy-secret')));
    expect(rewritten, isNot(contains('legacy-key')));
  });

  test('deletes obsolete config keys left by earlier builds', () async {
    SharedPreferences.setMockInitialValues({
      _legacyConfigPrefsKey: jsonEncode({
        'weexApiKey': 'stale-key',
        'weexSecret': 'stale-secret',
      }),
    });
    final credentials = InMemoryCredentialStore();
    final controller = AppController(credentialStore: credentials);

    await controller.loadConfig();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('legacy_prefix.app_config.v1'), isNull);
    // The only surviving copy is the encrypted one.
    expect(await credentials.read(), containsPair('weexSecret', 'stale-secret'));
  });

  test('a stale legacy blob never overwrites live credentials', () async {
    SharedPreferences.setMockInitialValues({
      _configPrefsKey: jsonEncode({
        'weexApiKey': 'current-key',
        'weexSecret': 'current-secret',
      }),
      _legacyConfigPrefsKey: jsonEncode({
        'weexApiKey': 'stale-key',
        'weexSecret': 'stale-secret',
      }),
    });
    final controller = AppController(credentialStore: InMemoryCredentialStore());

    await controller.loadConfig();

    expect(controller.config.weexApiKey, 'current-key');
    expect(controller.config.weexSecret, 'current-secret');
  });

  test('risk limits survive a restart', () async {
    SharedPreferences.setMockInitialValues({});
    final credentials = InMemoryCredentialStore();
    final controller = AppController(credentialStore: credentials);

    await controller.setRiskSettings(
      const RiskSettings(
        killSwitch: true,
        maxOrderNotional: RiskLimitValue(15, percent: true),
        maxPositionNotional: RiskLimitValue(2000),
        symbolAllowlist: ['BTCUSDT'],
        dailyLoss: RiskLimitValue(8, percent: true),
        maxSignalAgeSecs: 600,
      ),
    );

    final reloaded = AppController(credentialStore: credentials);
    await reloaded.loadConfig();

    expect(reloaded.config.risk.killSwitch, isTrue);
    // A percentage limit survives as a percentage, not as a resolved amount.
    expect(reloaded.config.risk.maxOrderNotional.value, 15);
    expect(reloaded.config.risk.maxOrderNotional.percent, isTrue);
    expect(reloaded.config.risk.maxPositionNotional.value, 2000);
    expect(reloaded.config.risk.maxPositionNotional.percent, isFalse);
    expect(reloaded.config.risk.dailyLoss.value, 8);
    expect(reloaded.config.risk.dailyLoss.percent, isTrue);
    expect(reloaded.config.risk.maxSignalAgeSecs, 600);
    expect(reloaded.config.risk.symbolAllowlist, ['BTCUSDT']);
  });

  test('forgetting credentials clears both the store and the config', () async {
    SharedPreferences.setMockInitialValues({});
    final credentials = InMemoryCredentialStore();
    final controller = AppController(credentialStore: credentials);
    await controller.saveConfig(_fullConfig, log: false);

    await controller.forgetStoredCredentials();

    expect(controller.config.weexApiKey, isEmpty);
    expect(controller.config.weexSecret, isEmpty);
    expect(controller.config.telegramApiHash, isEmpty);
  });
}
