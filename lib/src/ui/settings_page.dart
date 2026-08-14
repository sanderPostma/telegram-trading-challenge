import 'dart:async';

import 'package:flutter/material.dart';

import '../models/trading.dart';
import '../state/app_controller.dart';
import 'auto_approve_dialog.dart';

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
  late final TextEditingController _maxOrderNotional;
  late final TextEditingController _maxPositionNotional;
  late final TextEditingController _maxLeverage;
  late final TextEditingController _dailyLossLimit;
  late final TextEditingController _maxSignalAge;

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
    final risk = c.risk;
    _maxOrderNotional = TextEditingController(text: risk.maxOrderNotional.text);
    _maxPositionNotional =
        TextEditingController(text: risk.maxPositionNotional.text);
    _maxLeverage = TextEditingController(text: _limitText(risk.maxLeverage));
    _dailyLossLimit = TextEditingController(text: risk.dailyLoss.text);
    _maxSignalAge =
        TextEditingController(text: _limitText(risk.maxSignalAgeSecs.toDouble()));
  }

  /// An unset limit shows as an empty field, not "0".
  static String _limitText(double value) =>
      value > 0 ? value.toStringAsFixed(value.truncateToDouble() == value ? 0 : 2) : '';

  static double _limitValue(String raw) {
    final parsed = double.tryParse(raw.trim().replaceAll(',', '.'));
    if (parsed == null || !parsed.isFinite || parsed <= 0) return 0;
    return parsed;
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
    _maxOrderNotional.dispose();
    _maxPositionNotional.dispose();
    _maxLeverage.dispose();
    _dailyLossLimit.dispose();
    _maxSignalAge.dispose();
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
            onChanged: (value) => handleAutoApproveToggle(context, widget.controller, value),
            title: const Text('Auto-approve high-confidence parsed actions'),
          ),
        ]),
        _riskSection(),
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

  /// Hard limits enforced in Rust on the submit path, below the signal
  /// parser. Blank means the rail is off.
  Widget _riskSection() {
    final risk = widget.controller.config.risk;
    final theme = Theme.of(context);
    return _section('Risk limits', [
      Text(
        'Applied to every order — signal, auto-approved, or manual. '
        'Leave a field blank to leave that limit off. Closing a position is '
        'never blocked.',
        style: theme.textTheme.bodySmall,
      ),
      const SizedBox(height: 14),
      SwitchListTile(
        value: risk.killSwitch,
        onChanged: (value) => widget.controller.setRiskSettings(
          risk.copyWith(killSwitch: value),
        ),
        title: const Text('Kill switch'),
        subtitle: const Text('Block all new positions. Closing still works.'),
        secondary: Icon(
          Icons.power_settings_new,
          color: risk.killSwitch ? theme.colorScheme.error : null,
        ),
      ),
      if (!risk.hasAnyLimit)
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Row(
            children: [
              Icon(
                Icons.warning_amber_rounded,
                size: 18,
                color: theme.colorScheme.error,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'No size or loss limit is set. Nothing caps what a single '
                  'signal can do to this account.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            ],
          ),
        ),
      const SizedBox(height: 8),
      _field(
        _maxOrderNotional,
        'Max order size',
        helper: 'USDT, or % of balance — 5000 or 15%',
      ),
      _field(
        _maxPositionNotional,
        'Max total exposure',
        helper: 'USDT, or % of balance — 20000 or 40%',
      ),
      _field(_maxLeverage, 'Max leverage (x)'),
      _field(
        _dailyLossLimit,
        'Daily loss limit',
        helper: 'USDT, or % of balance — 500 or 8%',
      ),
      _field(_maxSignalAge, 'Ignore signals older than (seconds)'),
      Text(
        'Symbols allowed: ${risk.symbolAllowlist.isEmpty ? 'any' : risk.symbolAllowlist.join(', ')}',
        style: theme.textTheme.bodySmall,
      ),
      if (widget.controller.config.ethAllowlistPromptPending) ...[
        const SizedBox(height: 12),
        _EthAllowlistPrompt(controller: widget.controller),
      ],
      if (widget.controller.config.legacyOrderQtyCapBtc > 0) ...[
        const SizedBox(height: 12),
        _LegacyQtyCapNotice(controller: widget.controller),
      ],
    ]);
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
    String? helper,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: reveal
          ? _RevealTextField(controller: controller, label: label)
          : TextField(
              controller: controller,
              decoration: InputDecoration(labelText: label, helperText: helper),
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
        hasSeenAutoApproveWarning: current.hasSeenAutoApproveWarning,
        simulationMode: current.simulationMode,
        minimizeToTray: false,
        risk: current.risk.copyWith(
          maxOrderNotional: RiskLimitValue.parse(_maxOrderNotional.text),
          maxPositionNotional: RiskLimitValue.parse(_maxPositionNotional.text),
          maxLeverage: _limitValue(_maxLeverage.text),
          dailyLoss: RiskLimitValue.parse(_dailyLossLimit.text),
          maxSignalAgeSecs: _limitValue(_maxSignalAge.text).round(),
        ),
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


/// Shown once after upgrading from a BTC-only config.
///
/// The stored allowlist permits BTCUSDT and nothing else — the default every
/// v1 install carries whether or not it was ever configured — so every ETH
/// signal would be rejected by the risk gate while the UI advertised ETH as
/// supported. The allowlist is not widened without an explicit answer.
class _EthAllowlistPrompt extends StatelessWidget {
  const _EthAllowlistPrompt({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('ETH support was added', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Text(
            'Your symbol allowlist currently permits '
            '${controller.config.risk.symbolAllowlist.join(', ')} only, so ETH '
            'signals will be rejected before they reach the exchange. Add '
            'ETHUSDT to the allowlist?',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              FilledButton(
                onPressed: () =>
                    unawaited(controller.acceptEthAllowlistPrompt()),
                child: const Text('Allow ETHUSDT'),
              ),
              const SizedBox(width: 10),
              TextButton(
                onPressed: () =>
                    unawaited(controller.declineEthAllowlistPrompt()),
                child: const Text('Keep BTC only'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Reports what happened to the v1 BTC-denominated per-order quantity cap.
///
/// That rail cannot mean anything across two assets, so it is retired — but
/// silently dropping a configured cap could leave an account with no per-order
/// limit at all, so the change is surfaced rather than assumed harmless.
class _LegacyQtyCapNotice extends StatelessWidget {
  const _LegacyQtyCapNotice({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cap = controller.config.legacyOrderQtyCapBtc;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Per-order quantity cap retired',
              style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Text(
            'You had a ${cap.toStringAsFixed(4)} BTC per-order cap. A quantity '
            'cap cannot mean the same thing for BTC and ETH, so order size is '
            'now capped by notional instead. Set "Max order notional" above if '
            'you want that rail armed.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: () =>
                unawaited(controller.acknowledgeLegacyQtyCap()),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }
}
