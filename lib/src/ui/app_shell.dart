import 'dart:async';

import 'package:flutter/material.dart';

import '../models/trading.dart';
import '../state/app_controller.dart';
import '../theme.dart';
import 'app_bar_desktop.dart';
import 'auto_approve_dialog.dart';
import 'dashboard_page.dart';
import 'settings_page.dart';
import 'wizard_page.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.controller});

  final AppController controller;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;
  String? _shownApprovalId;
  bool _closeTargetDialogOpen = false;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final pending = widget.controller.pendingApproval;
        if (pending != null && pending.id != _shownApprovalId) {
          _shownApprovalId = pending.id;
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _showApproval(pending),
          );
        }

        if (widget.controller.closeTargetTriggered && !_closeTargetDialogOpen) {
          _closeTargetDialogOpen = true;
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _showCloseTargetDialog(),
          );
        }

        if (widget.controller.requiresSetup) {
          return Scaffold(
            appBar: challengeAppBar(
              title: 'Telegram Challenge - Setup',
              isLive: !widget.controller.config.simulationMode,
              actions: [],
            ),
            body: WizardPage(controller: widget.controller),
          );
        }

        final pages = [
          DashboardPage(controller: widget.controller),
          SettingsPage(controller: widget.controller),
        ];

        return LayoutBuilder(
          builder: (context, constraints) {
            final isMobile = constraints.maxWidth < 600;
            final isLive = !widget.controller.config.simulationMode;
            final labelStyle = TextStyle(
              fontSize: 12,
              color: isLive ? Brand.bg : Brand.text,
            );

            return Scaffold(
              appBar: challengeAppBar(
                title: 'Telegram Challenge',
                isLive: isLive,
                actions: [
                  if (!isMobile) Text('Simulation', style: labelStyle),
                  Switch(
                    value: widget.controller.config.simulationMode,
                    onChanged: widget.controller.setSimulationMode,
                    activeTrackColor: Brand.green,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  if (!isMobile) const SizedBox(width: 12),
                  if (!isMobile) Text('Auto-approve', style: labelStyle),
                  Switch(
                    value: widget.controller.config.autoApprove,
                    onChanged: (value) => handleAutoApproveToggle(context, widget.controller, value),
                    activeTrackColor: Brand.danger,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  const SizedBox(width: 16),
                ],
              ),
              body: isMobile
                  ? pages[_index]
                  : Row(
                      children: [
                        NavigationRail(
                          selectedIndex: _index,
                          onDestinationSelected: (value) =>
                              setState(() => _index = value),
                          backgroundColor: Brand.surface,
                          labelType: NavigationRailLabelType.all,
                          destinations: const [
                            NavigationRailDestination(
                              icon: Icon(Icons.dashboard_outlined),
                              selectedIcon: Icon(Icons.dashboard),
                              label: Text('Dashboard'),
                            ),
                            NavigationRailDestination(
                              icon: Icon(Icons.tune_outlined),
                              selectedIcon: Icon(Icons.tune),
                              label: Text('Settings'),
                            ),
                          ],
                        ),
                        const VerticalDivider(width: 1, color: Brand.border),
                        Expanded(child: pages[_index]),
                      ],
                    ),
              bottomNavigationBar: isMobile
                  ? BottomNavigationBar(
                      currentIndex: _index,
                      onTap: (value) => setState(() => _index = value),
                      backgroundColor: Brand.surface,
                      type: BottomNavigationBarType.fixed,
                      selectedItemColor: Brand.gold,
                      unselectedItemColor: Brand.muted,
                      items: const [
                        BottomNavigationBarItem(
                          icon: Icon(Icons.dashboard_outlined),
                          activeIcon: Icon(Icons.dashboard),
                          label: 'Dashboard',
                        ),
                        BottomNavigationBarItem(
                          icon: Icon(Icons.tune_outlined),
                          activeIcon: Icon(Icons.tune),
                          label: 'Settings',
                        ),
                      ],
                    )
                  : null,
            );
          },
        );
      },
    );
  }

  Future<void> _showApproval(PlannedOrder order) async {
    if (!mounted) return;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Approve Trade'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _kv('Side', order.direction.name.toUpperCase()),
              _kv('Scaled size', '${order.scaledBtc.toStringAsFixed(4)} BTC'),
              _kv(
                'Notional',
                '${order.scaledNotionalUsd.toStringAsFixed(2)} USDT',
              ),
              _kv('Mark price', '${order.markPrice.toStringAsFixed(2)} USDT'),
              const SizedBox(height: 12),
              Text(order.source, style: const TextStyle(color: Brand.muted)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Reject'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.check),
            label: const Text('Approve'),
          ),
        ],
      ),
    );
    _shownApprovalId = null;
    if (result == true) {
      widget.controller.approvePending();
    } else {
      widget.controller.rejectPending();
    }
  }

  Future<void> _showCloseTargetDialog() async {
    if (!mounted) {
      _closeTargetDialogOpen = false;
      return;
    }
    final controller = widget.controller;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Close-target reached'),
        content: AnimatedBuilder(
          animation: controller,
          builder: (context, _) {
            final watch = controller.closeTargetWatch;
            final position = controller.position;
            final live = controller.config.markPrice;
            return SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _kv(
                    'Target',
                    watch == null
                        ? '--'
                        : '${watch.low.toStringAsFixed(0)}–${watch.high.toStringAsFixed(0)} USDT',
                  ),
                  _kv('Live price', '${live.toStringAsFixed(2)} USDT'),
                  _kv('Side', position.direction?.name.toUpperCase() ?? 'FLAT'),
                  _kv('Size', '${position.qty.toStringAsFixed(4)} BTC'),
                  _kv(
                    'Unrealized P&L',
                    '${position.unrealizedPnlUsd.toStringAsFixed(2)} USDT',
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Price reached the advisory close zone. This does not close '
                    'automatically — confirm to flatten, or dismiss to keep the '
                    'position open.',
                    style: TextStyle(color: Brand.muted),
                  ),
                ],
              ),
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Dismiss'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: Brand.danger),
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.close),
            label: const Text('Close now'),
          ),
        ],
      ),
    );
    _closeTargetDialogOpen = false;
    if (result == true) {
      unawaited(widget.controller.manualFlatten());
    }
    widget.controller.cancelCloseTarget();
  }

  Widget _kv(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(label, style: const TextStyle(color: Brand.muted)),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}
