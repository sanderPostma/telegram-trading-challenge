import 'package:flutter/material.dart';

import '../models/trading.dart';
import '../state/app_controller.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _apiKey;
  late final TextEditingController _secret;
  late final TextEditingController _passphrase;
  late final TextEditingController _phone;
  late final TextEditingController _tgApiId;
  late final TextEditingController _tgApiHash;
  late final TextEditingController _tgCode;
  late final TextEditingController _tgPassword;

  @override
  void initState() {
    super.initState();
    final c = widget.controller.config;
    _apiKey = TextEditingController(text: c.weexApiKey);
    _secret = TextEditingController(text: c.weexSecret);
    _passphrase = TextEditingController(text: c.weexPassphrase);
    _phone = TextEditingController(text: c.telegramPhone);
    _tgApiId = TextEditingController(text: c.telegramApiId);
    _tgApiHash = TextEditingController(text: c.telegramApiHash);
    _tgCode = TextEditingController();
    _tgPassword = TextEditingController();
  }

  @override
  void dispose() {
    _apiKey.dispose();
    _secret.dispose();
    _passphrase.dispose();
    _phone.dispose();
    _tgApiId.dispose();
    _tgApiHash.dispose();
    _tgCode.dispose();
    _tgPassword.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('Settings', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 16),
        _section('WEEX', [
          _field(_apiKey, 'Access API key', reveal: true),
          _field(_secret, 'Secret key', reveal: true),
          _field(_passphrase, 'Passphrase', reveal: true),
        ]),
        _section('Telegram', [
          _field(_phone, 'Phone'),
          _field(_tgApiId, 'API ID'),
          _field(_tgApiHash, 'API hash', reveal: true),
          const SizedBox(height: 4),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: () async {
                  await _save();
                  await widget.controller.requestTelegramCode();
                },
                icon: const Icon(Icons.sms_outlined),
                label: const Text('Request Telegram code'),
              ),
              SizedBox(
                width: 180,
                child: TextField(
                  controller: _tgCode,
                  decoration: const InputDecoration(labelText: 'Login code'),
                ),
              ),
              OutlinedButton.icon(
                onPressed: () =>
                    widget.controller.submitTelegramCode(_tgCode.text),
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
                  controller: _tgPassword,
                  label: 'Telegram 2FA password',
                ),
              ),
              OutlinedButton.icon(
                onPressed: () =>
                    widget.controller.submitTelegramPassword(_tgPassword.text),
                icon: const Icon(Icons.lock_open),
                label: const Text('Submit 2FA'),
              ),
            ],
          ),
        ]),
        _section('Behavior', [
          SwitchListTile(
            value: widget.controller.config.simulationMode,
            onChanged: widget.controller.setSimulationMode,
            title: const Text('Simulation mode'),
          ),
          SwitchListTile(
            value: widget.controller.config.autoApprove,
            onChanged: widget.controller.setAutoApprove,
            title: const Text('Auto-approve high-confidence parsed actions'),
          ),
        ]),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            OutlinedButton.icon(
              onPressed: () => widget.controller.restartSetup(),
              icon: const Icon(Icons.refresh),
              label: const Text('Restart Setup Wizard'),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: () => _save(),
              icon: const Icon(Icons.save),
              label: const Text('Save Settings'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _section(String title, List<Widget> children) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 14),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    bool reveal = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: reveal
          ? _RevealTextField(controller: controller, label: label)
          : TextField(
              controller: controller,
              decoration: InputDecoration(labelText: label),
            ),
    );
  }

  Future<void> _save() async {
    final current = widget.controller.config;
    await widget.controller.saveConfig(
      AppConfig(
        weexApiKey: _apiKey.text,
        weexSecret: _secret.text,
        weexPassphrase: _passphrase.text,
        telegramPhone: _phone.text,
        telegramApiId: _tgApiId.text,
        telegramApiHash: _tgApiHash.text,
        masterBalanceUsd: current.masterBalanceUsd,
        myBalanceUsd: current.myBalanceUsd,
        markPrice: current.markPrice,
        autoUpdateMaster: current.autoUpdateMaster,
        autoApprove: current.autoApprove,
        simulationMode: current.simulationMode,
        minimizeToTray: false,
      ),
    );
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
