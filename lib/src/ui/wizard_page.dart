import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/trading.dart';
import '../state/app_controller.dart';
import '../theme.dart';

class WizardPage extends StatefulWidget {
  const WizardPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<WizardPage> createState() => _WizardPageState();
}

class _WizardPageState extends State<WizardPage> {
  int _step = 0;
  late final TextEditingController _weexKey;
  late final TextEditingController _weexSecret;
  late final TextEditingController _weexPassphrase;
  late final TextEditingController _phone;
  late final TextEditingController _apiId;
  late final TextEditingController _apiHash;
  late final TextEditingController _telegramCode;
  late final TextEditingController _telegramPassword;
  late final TextEditingController _tmgBalance;
  late final TextEditingController _myBalance;

  @override
  void initState() {
    super.initState();
    final c = widget.controller.config;
    _weexKey = TextEditingController(text: c.weexApiKey);
    _weexSecret = TextEditingController(text: c.weexSecret);
    _weexPassphrase = TextEditingController(text: c.weexPassphrase);
    _phone = TextEditingController(text: c.telegramPhone);
    _apiId = TextEditingController(text: c.telegramApiId);
    _apiHash = TextEditingController(text: c.telegramApiHash);
    _telegramCode = TextEditingController();
    _telegramPassword = TextEditingController();
    _tmgBalance = TextEditingController(
      text: c.masterBalanceUsd.toStringAsFixed(0),
    );
    _myBalance = TextEditingController(text: c.myBalanceUsd.toStringAsFixed(0));
  }

  @override
  void dispose() {
    _weexKey.dispose();
    _weexSecret.dispose();
    _weexPassphrase.dispose();
    _phone.dispose();
    _apiId.dispose();
    _apiHash.dispose();
    _telegramCode.dispose();
    _telegramPassword.dispose();
    _tmgBalance.dispose();
    _myBalance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stepper(
      currentStep: _step,
      onStepTapped: (value) => setState(() => _step = value),
      onStepContinue: _step == 3
          ? _save
          : () async {
              await _save(silent: true);
              if (!mounted) return;
              setState(() => _step += 1);
            },
      onStepCancel: _step == 0 ? null : () => setState(() => _step -= 1),
      controlsBuilder: (context, details) {
        return Padding(
          padding: const EdgeInsets.only(top: 18),
          child: Row(
            children: [
              FilledButton.icon(
                onPressed: details.onStepContinue,
                icon: Icon(_step == 3 ? Icons.check : Icons.arrow_forward),
                label: Text(_step == 3 ? 'Finish Setup' : 'Next'),
              ),
              const SizedBox(width: 10),
              if (_step > 0)
                TextButton(
                  onPressed: details.onStepCancel,
                  child: const Text('Back'),
                ),
            ],
          ),
        );
      },
      steps: [
        Step(
          isActive: _step >= 0,
          title: const Text('WEEX API'),
          content: _stepCard(
            icon: Icons.account_balance_wallet_outlined,
            title: 'Create and enter your WEEX API credentials',
            children: [
              const _InstructionList(
                items: [
                  'Open WEEX API management and create a new API key. Apply for API access first if WEEX asks you to.',
                  'Use any label, for example tmg-bot. The label stays on WEEX and is not needed by this app.',
                  'Set a passphrase and save it here. WEEX uses it as an extra API credential during signed requests.',
                  'Enable Futures permission. Read-only may remain checked; Spot is not required for this app.',
                  'Optional on WEEX: restrict the key to your current public IP address. Use the helper link below if you want to do that on the WEEX form.',
                  'On the next WEEX screen, copy Access API key and Secret key into this app.',
                ],
              ),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  _LinkButton(
                    label: 'Open WEEX API page',
                    url: 'https://www.weex.com/account/newapi',
                  ),
                  _LinkButton(
                    label: 'Find my IP',
                    url: 'https://ipinfo.io/what-is-my-ip',
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _secretField(_weexKey, 'Access API key'),
              _secretField(_weexSecret, 'Secret key'),
              _secretField(_weexPassphrase, 'Passphrase'),
            ],
          ),
        ),
        Step(
          isActive: _step >= 1,
          title: const Text('Telegram API'),
          content: _stepCard(
            icon: Icons.phone_android,
            title: 'Create Telegram api_id and api_hash',
            children: [
              const _InstructionList(
                items: [
                  'Go to my.telegram.org and log in with your phone number in international format, for example +1XXXYYYZZZZ.',
                  'Telegram sends the confirmation code inside the official Telegram app, not by SMS.',
                  'Open API development tools.',
                  'Create a new application. App title can be MyTradingMonitor. Short name can be my_monitor.',
                  'Leave URL and description blank. Select Desktop or Other as the platform.',
                  'After creating the application, copy App api_id and App api_hash here.',
                ],
              ),
              const SizedBox(height: 8),
              const _LinkButton(
                label: 'Open Telegram portal',
                url: 'https://my.telegram.org',
              ),
              const SizedBox(height: 16),
              _field(_phone, 'Phone'),
              _field(_apiId, 'API ID'),
              _secretField(_apiHash, 'API hash'),
              const SizedBox(height: 4),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: () async {
                      await _save(silent: true);
                      await widget.controller.requestTelegramCode();
                    },
                    icon: const Icon(Icons.sms_outlined),
                    label: const Text('Request Telegram code'),
                  ),
                  SizedBox(
                    width: 180,
                    child: TextField(
                      controller: _telegramCode,
                      decoration: const InputDecoration(
                        labelText: 'Login code',
                      ),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: () async {
                      await _save(silent: true);
                      await widget.controller.submitTelegramCode(
                        _telegramCode.text,
                      );
                    },
                    icon: const Icon(Icons.login),
                    label: const Text('Sign in'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 260,
                    child: _RevealTextField(
                      controller: _telegramPassword,
                      label: 'Telegram 2FA password',
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: () async {
                      await _save(silent: true);
                      await widget.controller.submitTelegramPassword(
                        _telegramPassword.text,
                      );
                    },
                    icon: const Icon(Icons.lock_open),
                    label: const Text('Submit 2FA'),
                  ),
                ],
              ),
            ],
          ),
        ),
        Step(
          isActive: _step >= 2,
          title: const Text('Account Scaling'),
          content: _stepCard(
            icon: Icons.calculate_outlined,
            title: 'Scale Challenge trade sizes down to your WEEX balance',
            children: [
              const Text(
                'Example: if Challenge has 10,000 USDT and you have 2,000 USDT, the app copies 20% of every posted trade size.',
                style: TextStyle(color: Brand.muted),
              ),
              const SizedBox(height: 16),
              _field(_tmgBalance, 'Challenge Account Balance', suffix: 'USDT'),
              _field(_myBalance, 'My Account Balance', suffix: 'USDT'),
            ],
          ),
        ),
        Step(
          isActive: _step >= 3,
          title: const Text('Safety Defaults'),
          content: _stepCard(
            icon: Icons.verified_user_outlined,
            title: 'Start in simulation mode',
            children: [
              const Text(
                'Simulation mode stays on until you disable it. Auto-approve starts off, so entries and exits are shown for confirmation first.',
                style: TextStyle(color: Brand.muted),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                value: widget.controller.config.simulationMode,
                onChanged: widget.controller.setSimulationMode,
                title: const Text('Simulation mode'),
              ),
              SwitchListTile(
                value: widget.controller.config.autoApprove,
                onChanged: widget.controller.setAutoApprove,
                title: const Text(
                  'Auto-approve high-confidence parsed actions',
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _stepCard({
    required IconData icon,
    required String title,
    required List<Widget> children,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: Brand.gold),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    String? suffix,
    String? hint,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        keyboardType: suffix == null
            ? TextInputType.text
            : const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: label,
          suffixText: suffix,
          hintText: hint,
        ),
      ),
    );
  }

  Widget _secretField(TextEditingController controller, String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: _RevealTextField(controller: controller, label: label),
    );
  }

  Future<void> _save({bool silent = false}) async {
    double parse(TextEditingController c, double fallback) {
      return double.tryParse(c.text.replaceAll(',', '')) ?? fallback;
    }

    final current = widget.controller.config;
    await widget.controller.saveConfig(
      AppConfig(
        weexApiKey: _weexKey.text,
        weexSecret: _weexSecret.text,
        weexPassphrase: _weexPassphrase.text,
        telegramPhone: _phone.text,
        telegramApiId: _apiId.text,
        telegramApiHash: _apiHash.text,
        masterBalanceUsd: parse(_tmgBalance, current.masterBalanceUsd),
        myBalanceUsd: parse(_myBalance, current.myBalanceUsd),
        markPrice: current.markPrice,
        autoUpdateMaster: current.autoUpdateMaster,
        autoApprove: current.autoApprove,
        simulationMode: current.simulationMode,
        minimizeToTray: false,
      ),
    );
    if (!silent && mounted) {
      widget.controller.finishSetup();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Setup saved')));
    }
  }
}

class _RevealTextField extends StatefulWidget {
  const _RevealTextField({required this.controller, required this.label});

  final TextEditingController controller;
  final String label;

  @override
  State<_RevealTextField> createState() => _RevealTextFieldState();
}

class _RevealTextFieldState extends State<_RevealTextField> {
  bool _visible = false;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      obscureText: !_visible,
      decoration: InputDecoration(
        labelText: widget.label,
        suffixIcon: IconButton(
          tooltip: _visible ? 'Hide' : 'Show',
          onPressed: () => setState(() => _visible = !_visible),
          icon: Icon(_visible ? Icons.visibility_off : Icons.visibility),
        ),
      ),
    );
  }
}

class _InstructionList extends StatelessWidget {
  const _InstructionList({required this.items});

  final List<String> items;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < items.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 24,
                  child: Text(
                    '${i + 1}.',
                    style: const TextStyle(color: Brand.gold),
                  ),
                ),
                Expanded(
                  child: Text(
                    items[i],
                    style: const TextStyle(color: Brand.muted, height: 1.35),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _LinkButton extends StatelessWidget {
  const _LinkButton({required this.label, required this.url});

  final String label;
  final String url;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: () =>
          launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
      icon: const Icon(Icons.open_in_new),
      label: Text(label),
    );
  }
}
