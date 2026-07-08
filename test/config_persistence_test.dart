import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trading_challenge/src/models/trading.dart';
import 'package:trading_challenge/src/state/app_controller.dart';

void main() {
  test('persists user setup values across controller restarts', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = AppController();

    await controller.saveConfig(
      const AppConfig(
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
      ),
      log: false,
    );

    final reloaded = AppController();
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
}
