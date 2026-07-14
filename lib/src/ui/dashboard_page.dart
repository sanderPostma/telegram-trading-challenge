import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/trading.dart';
import '../state/app_controller.dart';
import '../theme.dart';
import 'series_chart.dart';

enum ChartTimeframe { day, week, month }

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  ChartTimeframe _timeframe = ChartTimeframe.day;

  List<SeriesPoint> _filterSeries(
    List<SeriesPoint> points,
    int visibleStartMs,
    int visibleEndMs,
  ) {
    SeriesPoint? lastBefore;
    final result = <SeriesPoint>[];
    for (final point in points) {
      if (point.ts < visibleStartMs) {
        lastBefore = point;
      } else if (point.ts <= visibleEndMs) {
        if (lastBefore != null) {
          result.add(SeriesPoint(visibleStartMs, lastBefore.value));
          lastBefore = null;
        }
        result.add(point);
      }
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final endMs = nowMs < visibleEndMs ? nowMs : visibleEndMs;
    if (result.isNotEmpty && result.last.ts < endMs - 1000) {
      result.add(SeriesPoint(endMs, result.last.value));
    }

    return result;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final isDesktop = constraints.maxWidth >= 800;
            final controller = widget.controller;
            final nowMs = DateTime.now().millisecondsSinceEpoch;
            final rangeStartMs = switch (_timeframe) {
              ChartTimeframe.day =>
                nowMs - const Duration(hours: 24).inMilliseconds,
              ChartTimeframe.week =>
                nowMs - const Duration(days: 7).inMilliseconds,
              ChartTimeframe.month =>
                nowMs - const Duration(days: 30).inMilliseconds,
            };
            final rangeEndMs = nowMs;
            final balancePoints = _filterSeries(
              controller.balanceHistory,
              rangeStartMs,
              rangeEndMs,
            );
            final equityPoints = _filterSeries(
              controller.equityHistory,
              rangeStartMs,
              rangeEndMs,
            );
            final pnlPoints = _filterSeries(
              controller.pnlHistory,
              rangeStartMs,
              rangeEndMs,
            );

            final leftColumn = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    SegmentedButton<ChartTimeframe>(
                      showSelectedIcon: false,
                      style: SegmentedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        visualDensity: VisualDensity.compact,
                      ),
                      segments: const [
                        ButtonSegment(
                          value: ChartTimeframe.day,
                          label: Text('1D'),
                        ),
                        ButtonSegment(
                          value: ChartTimeframe.week,
                          label: Text('1W'),
                        ),
                        ButtonSegment(
                          value: ChartTimeframe.month,
                          label: Text('1M'),
                        ),
                      ],
                      selected: {_timeframe},
                      onSelectionChanged: (value) {
                        setState(() => _timeframe = value.first);
                        unawaited(
                          widget.controller
                              .refreshChartHistoryFromCachedExchange(),
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                MultiLineChart(
                  title: 'Equity & Margin Balance',
                  minTimestampMs: rangeStartMs,
                  maxTimestampMs: rangeEndMs,
                  series: [
                    ChartSeries(
                      label: 'Margin balance',
                      points: balancePoints,
                      color: const Color(0xFF7E57C2),
                      fill: true,
                    ),
                    ChartSeries(
                      label: 'Equity (incl. unrealized)',
                      points: equityPoints,
                      color: const Color(0xFF42A5F5),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                MiniLineChart(
                  title: 'Cumulative PnL (closed)',
                  points: pnlPoints,
                  minTimestampMs: rangeStartMs,
                  maxTimestampMs: rangeEndMs,
                  color: const Color(0xFF26A69A),
                  trailingLabel:
                      '${(pnlPoints.isEmpty ? 0.0 : pnlPoints.last.value).toStringAsFixed(2)} USDT',
                ),
                const SizedBox(height: 16),
                _TradeHistoryTable(controller: widget.controller),
              ],
            );

            final rightColumn = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AccountScalingPanel(controller: widget.controller),
                const SizedBox(height: 16),
                if (isDesktop)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: ManualTradePanel(controller: widget.controller),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _PositionPanel(controller: widget.controller),
                      ),
                    ],
                  )
                else
                  Column(
                    children: [
                      ManualTradePanel(controller: widget.controller),
                      const SizedBox(height: 16),
                      _PositionPanel(controller: widget.controller),
                    ],
                  ),
                const SizedBox(height: 16),
                _EventLog(controller: widget.controller),
              ],
            );

            final statCards = Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _StatCard(
                  title: 'WEEX BTC live',
                  value: _weexPriceValue(widget.controller),
                  icon: Icons.show_chart,
                ),
                _StatCard(
                  title: 'My balance',
                  value:
                      '${widget.controller.config.myBalanceUsd.toStringAsFixed(2)} USDT',
                  icon: Icons.account_balance_wallet_outlined,
                ),
                _StatCard(
                  title: 'Challenge balance',
                  value:
                      '${widget.controller.config.masterBalanceUsd.toStringAsFixed(2)} USDT',
                  icon: Icons.leaderboard_outlined,
                ),
                _StatCard(
                  title: 'Scale ratio',
                  value:
                      '${(widget.controller.config.scaleRatio * 100).toStringAsFixed(2)}%',
                  icon: Icons.percent,
                ),
              ],
            );

            if (isDesktop) {
              return ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  statCards,
                  const SizedBox(height: 16),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 5, child: rightColumn),
                      const SizedBox(width: 16),
                      Expanded(flex: 5, child: leftColumn),
                    ],
                  ),
                ],
              );
            } else {
              return DefaultTabController(
                length: 2,
                child: Column(
                  children: [
                    const TabBar(
                      tabs: [
                        Tab(text: 'Control'),
                        Tab(text: 'Status'),
                      ],
                    ),
                    Expanded(
                      child: TabBarView(
                        children: [
                          ListView(
                            padding: const EdgeInsets.all(16),
                            children: [
                              statCards,
                              const SizedBox(height: 16),
                              rightColumn,
                            ],
                          ),
                          ListView(
                            padding: const EdgeInsets.all(16),
                            children: [
                              statCards,
                              const SizedBox(height: 16),
                              leftColumn,
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            }
          },
        );
      },
    );
  }
}

class AccountScalingPanel extends StatefulWidget {
  const AccountScalingPanel({super.key, required this.controller});

  final AppController controller;

  @override
  State<AccountScalingPanel> createState() => _AccountScalingPanelState();
}

class _AccountScalingPanelState extends State<AccountScalingPanel> {
  late final TextEditingController _tmgBalance;

  @override
  void initState() {
    super.initState();
    final c = widget.controller.config;
    _tmgBalance = TextEditingController(
      text: c.masterBalanceUsd.toStringAsFixed(0),
    );
  }

  @override
  void dispose() {
    _tmgBalance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.calculate_outlined, color: Brand.gold),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Account Scaling',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        'The app copies Challenge trade sizes by balance ratio: My account balance / Challenge account balance.',
                        style: TextStyle(color: Brand.muted, fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, constraints) {
                final fields = [
                  _amountField(
                    'Challenge Account Balance',
                    _tmgBalance,
                    'USDT',
                  ),
                  _exchangeBalanceField(),
                ];
                if (constraints.maxWidth >= 560) {
                  return Row(
                    children: [
                      for (final field in fields) ...[
                        Expanded(child: field),
                        if (field != fields.last) const SizedBox(width: 12),
                      ],
                    ],
                  );
                }
                return Column(
                  children: [
                    for (final field in fields) ...[
                      field,
                      if (field != fields.last) const SizedBox(height: 12),
                    ],
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _amountField(
    String label,
    TextEditingController controller,
    String suffix,
  ) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(labelText: label, suffixText: suffix),
      onChanged: (_) => _save(),
    );
  }

  Widget _exchangeBalanceField() {
    return InputDecorator(
      decoration: const InputDecoration(
        labelText: 'My Account Balance',
        suffixText: 'USDT',
      ),
      child: Text(
        widget.controller.config.myBalanceUsd.toStringAsFixed(2),
        style: Theme.of(context).textTheme.bodyLarge,
      ),
    );
  }

  void _save() {
    double parse(TextEditingController c, double fallback) {
      return double.tryParse(c.text.replaceAll(',', '')) ?? fallback;
    }

    final c = widget.controller.config;
    unawaited(
      widget.controller.saveConfig(
        c.copyWith(
          masterBalanceUsd: parse(_tmgBalance, c.masterBalanceUsd),
          autoUpdateMaster: true,
        ),
        log: false,
      ),
    );
  }
}

class ManualTradePanel extends StatefulWidget {
  const ManualTradePanel({super.key, required this.controller});

  final AppController controller;

  @override
  State<ManualTradePanel> createState() => _ManualTradePanelState();
}

class _ManualTradePanelState extends State<ManualTradePanel> {
  final _amount = TextEditingController(text: '5000');
  SizeUnit _unit = SizeUnit.usdt;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final parsed = double.tryParse(_amount.text.replaceAll(',', '')) ?? 0;
    final preview = widget.controller.previewManualOrder(
      parsed,
      _unit,
      TradeDirection.long,
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.bolt, color: Brand.gold),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Manual Scaled Entry',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<SizeUnit>(
                segments: const [
                  ButtonSegment(value: SizeUnit.usdt, label: Text('USDT')),
                  ButtonSegment(value: SizeUnit.btc, label: Text('BTC')),
                ],
                selected: {_unit},
                onSelectionChanged: (value) =>
                    setState(() => _unit = value.first),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Challenge Trade Size',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Brand.surface2,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Brand.border),
              ),
              child: Wrap(
                spacing: 20,
                runSpacing: 8,
                children: [
                  _Metric('Scaled BTC', preview.scaledBtc.toStringAsFixed(4)),
                  _Metric(
                    'Scaled USDT',
                    preview.scaledNotionalUsd.toStringAsFixed(2),
                  ),
                  _Metric(
                    'Ratio',
                    '${(widget.controller.config.scaleRatio * 100).toStringAsFixed(2)}%',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, constraints) {
                final narrow = constraints.maxWidth < 280;
                final longBtn = FilledButton.icon(
                  onPressed: () => _open(TradeDirection.long),
                  icon: const Icon(Icons.north_east),
                  label: const Text('Open Long', softWrap: false),
                );
                final shortBtn = FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: Brand.danger),
                  onPressed: () => _open(TradeDirection.short),
                  icon: const Icon(Icons.south_east),
                  label: const Text('Open Short', softWrap: false),
                );

                if (narrow) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [longBtn, const SizedBox(height: 8), shortBtn],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: longBtn),
                    const SizedBox(width: 12),
                    Expanded(child: shortBtn),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void _open(TradeDirection direction) {
    final amount = double.tryParse(_amount.text.replaceAll(',', '')) ?? 0;
    widget.controller.openManualTrade(
      amount: amount,
      unit: _unit,
      direction: direction,
    );
  }
}

class _PositionPanel extends StatelessWidget {
  const _PositionPanel({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final position = controller.position;
    final effectiveLeverage =
        position.isFlat || controller.config.myBalanceUsd <= 0
        ? 0.0
        : position.notionalUsd / controller.config.myBalanceUsd;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Icon(Icons.candlestick_chart, color: Brand.gold),
                Text(
                  'Open Position',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 18),
            _Metric(
              'Direction',
              position.direction?.name.toUpperCase() ?? 'FLAT',
            ),
            const SizedBox(height: 10),
            _Metric('Quantity', '${position.qtyBtc.toStringAsFixed(4)} BTC'),
            const SizedBox(height: 10),
            _Metric(
              'Notional',
              '${position.notionalUsd.toStringAsFixed(2)} USDT',
            ),
            const SizedBox(height: 10),
            _Metric(
              'Cross combined leverage',
              _formatLeverage(position.crossCombinedLeverage),
            ),
            const SizedBox(height: 10),
            _Metric('Effective leverage', _formatLeverage(effectiveLeverage)),
            const SizedBox(height: 10),
            _Metric(
              'Unrealized PnL',
              '${position.unrealizedPnlUsd.toStringAsFixed(2)} USDT',
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _ConnectionDot(
                  label: 'Telegram',
                  active: controller.monitorRunning,
                ),
                _ConnectionDot(
                  label: 'WEEX',
                  active: controller.weexPriceConnected,
                ),
                _ConnectionDot(
                  label: 'WEEX account',
                  active: controller.weexAccountConnected,
                ),
              ],
            ),
            if (controller.weexReconciliationError != null) ...[
              const SizedBox(height: 10),
              Text(
                controller.weexReconciliationError!,
                style: const TextStyle(color: Brand.danger, fontSize: 12),
              ),
            ],
            const SizedBox(height: 18),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _confirmFlatten(context, controller),
                style: TextButton.styleFrom(
                  foregroundColor: Brand.danger,
                  textStyle: const TextStyle(fontWeight: FontWeight.w700),
                ),
                icon: const Icon(Icons.close),
                label: const Text('Flatten position'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatLeverage(double value) {
    if (!value.isFinite || value <= 0) return '--';
    return '${value.toStringAsFixed(2)}x';
  }

  Future<void> _confirmFlatten(
    BuildContext context,
    AppController controller,
  ) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Flatten Position'),
        content: const Text(
          'Are you sure you want to close this position immediately at market price?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          Tooltip(
            message: 'Double-click to confirm',
            child: InkWell(
              onDoubleTap: () => Navigator.of(context).pop(true),
              onTap: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Please double-click the button to confirm.'),
                  ),
                );
              },
              borderRadius: BorderRadius.circular(20),
              child: Ink(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Brand.danger,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.warning_amber, color: Brand.bg, size: 18),
                    SizedBox(width: 8),
                    Text(
                      'Double-Click to Flatten',
                      style: TextStyle(
                        color: Brand.bg,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
    if (result == true) {
      controller.manualFlatten();
    }
  }
}

class _TradeHistoryTable extends StatelessWidget {
  const _TradeHistoryTable({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Position / trade history',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            _HistoryHeader(),
            const Divider(color: Brand.border),
            for (final row in _buildRows())
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: row,
              ),
            if (controller.tradeHistory.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Text(
                  'No exchange trades loaded yet.',
                  style: TextStyle(color: Brand.muted),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildRows() {
    final rows = <Widget>[];
    double remainingQty = controller.position.qtyBtc;
    final currentDir = controller.position.direction?.name.toLowerCase();

    for (final trade in controller.tradeHistory.take(20)) {
      bool isOpen = false;
      final sideLower = trade.side.toLowerCase();
      final isLong = sideLower.contains('long');
      final isShort = sideLower.contains('short');
      final isEntry =
          sideLower.contains('open') ||
          sideLower.contains('add') ||
          sideLower.contains('enter');

      if (isEntry && currentDir != null && remainingQty > 0) {
        if ((isLong && currentDir == 'long') ||
            (isShort && currentDir == 'short')) {
          isOpen = true;
          final qty = trade.avgPrice > 0
              ? (trade.filledUsdt / trade.avgPrice)
              : 0.0;
          remainingQty -= qty;
        }
      }

      rows.add(
        _HistoryRow(
          trade: trade,
          isOpen: isOpen,
          markPrice: controller.config.markPrice,
        ),
      );
    }
    return rows;
  }
}

class _HistoryHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    const style = TextStyle(color: Brand.muted, fontSize: 12);
    return const Row(
      children: [
        SizedBox(width: 112, child: Text('Time', style: style)),
        SizedBox(width: 100, child: Text('Side', style: style)),
        Expanded(child: Text('Filled', style: style)),
        SizedBox(width: 96, child: Text('Avg.', style: style)),
        SizedBox(width: 96, child: Text('PnL', style: style)),
      ],
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    required this.trade,
    required this.isOpen,
    required this.markPrice,
  });

  final TradeHistoryEntry trade;
  final bool isOpen;
  final double markPrice;

  @override
  Widget build(BuildContext context) {
    final sideLower = trade.side.toLowerCase();
    final isEntry =
        sideLower.contains('open') ||
        sideLower.contains('add') ||
        sideLower.contains('enter');

    double? displayPnl;
    bool showLock = false;

    if (isEntry) {
      if (isOpen && markPrice > 0 && trade.avgPrice > 0) {
        final isLong = sideLower.contains('long');
        final qty = trade.filledUsdt / trade.avgPrice;
        displayPnl = isLong
            ? (markPrice - trade.avgPrice) * qty
            : (trade.avgPrice - markPrice) * qty;
      } else {
        showLock = true;
      }
    } else {
      displayPnl = trade.realizedPnlUsdt;
      showLock = true;
    }

    final pnlColor = displayPnl != null && displayPnl > 0
        ? Brand.green
        : displayPnl != null && displayPnl < 0
        ? Brand.danger
        : null;

    return Row(
      children: [
        SizedBox(
          width: 112,
          child: Text(DateFormat('MM/dd HH:mm').format(trade.time)),
        ),
        SizedBox(
          width: 100,
          child: Text(
            trade.side,
            style: TextStyle(
              color: sideLower.contains('short') ? Brand.danger : Brand.green,
            ),
          ),
        ),
        Expanded(child: Text('${trade.filledUsdt.toStringAsFixed(4)} USDT')),
        SizedBox(width: 96, child: Text(trade.avgPrice.toStringAsFixed(1))),
        SizedBox(
          width: 96,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (displayPnl != null)
                Text(
                  displayPnl > 0
                      ? '+${displayPnl.toStringAsFixed(2)}'
                      : displayPnl.toStringAsFixed(2),
                  style: TextStyle(
                    color: pnlColor,
                    fontWeight: FontWeight.bold,
                  ),
                )
              else
                const Text('-', style: TextStyle(color: Brand.muted)),
              if (showLock) ...[
                const SizedBox(width: 4),
                const Icon(Icons.lock, size: 10, color: Brand.muted),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _EventLog extends StatelessWidget {
  const _EventLog({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Event Stream',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            for (final line in controller.eventLog.take(10))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Text(line, style: const TextStyle(color: Brand.muted)),
              ),
          ],
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.title,
    required this.value,
    required this.icon,
  });

  final String title;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 220,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(icon, color: Brand.gold),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(color: Brand.muted)),
                    Text(value, style: Theme.of(context).textTheme.titleMedium),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(color: Brand.muted, fontSize: 12)),
        const SizedBox(height: 3),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
      ],
    );
  }
}

class _ConnectionDot extends StatelessWidget {
  const _ConnectionDot({required this.label, required this.active});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(Icons.circle, size: 10, color: active ? Brand.green : Brand.muted),
        const SizedBox(width: 6),
        Text(label),
      ],
    );
  }
}

String _weexPriceValue(AppController controller) {
  if (controller.weexPriceConnected && controller.config.markPrice > 0) {
    return '${controller.config.markPrice.toStringAsFixed(2)} USDT';
  }
  return switch (controller.weexPriceStatus) {
    WeexPriceStatus.idle => 'Not started',
    WeexPriceStatus.connecting => 'Connecting',
    WeexPriceStatus.live => 'Waiting',
    WeexPriceStatus.unavailable => 'Unavailable',
  };
}
