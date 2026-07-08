import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/trading.dart';

/// One named series for [MultiLineChart].
class ChartSeries {
  final String label;
  final List<SeriesPoint> points;
  final Color color;

  /// Show a shaded area below the line (off for overlay lines so they don't
  /// hide each other).
  final bool fill;
  const ChartSeries({
    required this.label,
    required this.points,
    required this.color,
    this.fill = false,
  });
}

/// Compact line chart overlaying several series on a shared (index→date) axis,
/// with a legend showing each series colour, name, and current value. All
/// series are assumed to share the same x positions (same timestamps).
class MultiLineChart extends StatelessWidget {
  final String title;
  final List<ChartSeries> series;
  final double? minY;
  final double? maxY;
  final int? minTimestampMs;
  final int? maxTimestampMs;

  const MultiLineChart({
    super.key,
    required this.title,
    required this.series,
    this.minY,
    this.maxY,
    this.minTimestampMs,
    this.maxTimestampMs,
  });

  static final _money = NumberFormat('#,##0');

  @override
  Widget build(BuildContext context) {
    final xBounds = _xBounds(
      series: [for (final item in series) item.points],
      minTimestampMs: minTimestampMs,
      maxTimestampMs: maxTimestampMs,
    );
    final xRange = xBounds.$2 - xBounds.$1;
    final bottomInterval = xRange <= 0 ? 1.0 : (xRange / 4).ceilToDouble();
    const tiny = TextStyle(fontSize: 9, color: Colors.grey);
    final empty = series.every((s) => s.points.isEmpty);
    final yBounds = _seriesYBounds(series);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(title, style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
              ],
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 14,
              runSpacing: 2,
              children: [
                for (final s in series)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: s.color,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        s.label,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        s.points.isEmpty
                            ? '-'
                            : '${_money.format(s.points.last.value)} USDT',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: s.color,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 132,
              child: empty
                  ? const Center(
                      child: Text(
                        'No data',
                        style: TextStyle(color: Colors.grey),
                      ),
                    )
                  : LineChart(
                      LineChartData(
                        minY: minY ?? yBounds?.$1,
                        maxY: maxY ?? yBounds?.$2,
                        lineTouchData: const LineTouchData(enabled: false),
                        titlesData: FlTitlesData(
                          show: true,
                          topTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false),
                          ),
                          rightTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false),
                          ),
                          leftTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: true,
                              reservedSize: 44,
                              getTitlesWidget: (v, meta) =>
                                  Text(meta.formattedValue, style: tiny),
                            ),
                          ),
                          bottomTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: true,
                              reservedSize: 18,
                              interval: bottomInterval,
                              getTitlesWidget: (v, meta) {
                                if (v < 0 || v > xRange) {
                                  return const SizedBox.shrink();
                                }
                                final dt = DateTime.fromMillisecondsSinceEpoch(
                                  xBounds.$1 + v.round(),
                                );
                                final fmt = xRange <= 86400000 * 2
                                    ? 'HH:mm'
                                    : 'MM/dd';
                                return Text(
                                  DateFormat(fmt).format(dt),
                                  style: tiny,
                                );
                              },
                            ),
                          ),
                        ),
                        gridData: const FlGridData(
                          show: true,
                          drawVerticalLine: false,
                        ),
                        borderData: FlBorderData(
                          show: true,
                          border: const Border(
                            left: BorderSide(color: Colors.white12),
                            bottom: BorderSide(color: Colors.white12),
                          ),
                        ),
                        lineBarsData: [
                          for (final s in series)
                            LineChartBarData(
                              spots: [
                                for (final point in s.points)
                                  FlSpot(
                                    (point.ts - xBounds.$1).toDouble(),
                                    point.value,
                                  ),
                              ],
                              isCurved: true,
                              color: s.color,
                              barWidth: 2,
                              dotData: const FlDotData(show: false),
                              belowBarData: BarAreaData(
                                show: s.fill,
                                color: s.color.withValues(alpha: 0.12),
                              ),
                            ),
                        ],
                        minX: 0,
                        maxX: xRange <= 0 ? 1 : xRange.toDouble(),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact line chart for a timestamped value series (ascending by time), with
/// left (value) and bottom (date) scale markers.
class MiniLineChart extends StatelessWidget {
  final String title;
  final List<SeriesPoint> points;
  final double? threshold;
  final Color color;
  final double? minY;
  final double? maxY;
  final int? minTimestampMs;
  final int? maxTimestampMs;
  final String? trailingLabel;

  const MiniLineChart({
    super.key,
    required this.title,
    required this.points,
    this.threshold,
    this.color = const Color(0xFF42A5F5),
    this.minY,
    this.maxY,
    this.minTimestampMs,
    this.maxTimestampMs,
    this.trailingLabel,
  });

  @override
  Widget build(BuildContext context) {
    final xBounds = _xBounds(
      series: [points],
      minTimestampMs: minTimestampMs,
      maxTimestampMs: maxTimestampMs,
    );
    final xRange = xBounds.$2 - xBounds.$1;
    final spots = [
      for (final point in points)
        FlSpot((point.ts - xBounds.$1).toDouble(), point.value),
    ];
    final bottomInterval = xRange <= 0 ? 1.0 : (xRange / 4).ceilToDouble();
    const tiny = TextStyle(fontSize: 9, color: Colors.grey);
    final yBounds = _pointsYBounds(points);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(title, style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                if (trailingLabel != null)
                  Text(
                    trailingLabel!,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 132,
              child: spots.isEmpty
                  ? const Center(
                      child: Text(
                        'No data',
                        style: TextStyle(color: Colors.grey),
                      ),
                    )
                  : LineChart(
                      LineChartData(
                        minY: minY ?? yBounds?.$1,
                        maxY: maxY ?? yBounds?.$2,
                        lineTouchData: const LineTouchData(enabled: false),
                        titlesData: FlTitlesData(
                          show: true,
                          topTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false),
                          ),
                          rightTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false),
                          ),
                          leftTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: true,
                              reservedSize: 44,
                              getTitlesWidget: (v, meta) =>
                                  Text(meta.formattedValue, style: tiny),
                            ),
                          ),
                          bottomTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: true,
                              reservedSize: 18,
                              interval: bottomInterval,
                              getTitlesWidget: (v, meta) {
                                if (v < 0 || v > xRange) {
                                  return const SizedBox.shrink();
                                }
                                final dt = DateTime.fromMillisecondsSinceEpoch(
                                  xBounds.$1 + v.round(),
                                );
                                final fmt = xRange <= 86400000 * 2
                                    ? 'HH:mm'
                                    : 'MM/dd';
                                return Text(
                                  DateFormat(fmt).format(dt),
                                  style: tiny,
                                );
                              },
                            ),
                          ),
                        ),
                        gridData: const FlGridData(
                          show: true,
                          drawVerticalLine: false,
                        ),
                        borderData: FlBorderData(
                          show: true,
                          border: const Border(
                            left: BorderSide(color: Colors.white12),
                            bottom: BorderSide(color: Colors.white12),
                          ),
                        ),
                        lineBarsData: [
                          LineChartBarData(
                            spots: spots,
                            isCurved: true,
                            color: color,
                            barWidth: 2,
                            dotData: const FlDotData(show: false),
                            belowBarData: BarAreaData(
                              show: true,
                              color: color.withValues(alpha: 0.12),
                            ),
                          ),
                        ],
                        minX: 0,
                        maxX: xRange <= 0 ? 1 : xRange.toDouble(),
                        extraLinesData: threshold == null
                            ? const ExtraLinesData()
                            : ExtraLinesData(
                                horizontalLines: [
                                  HorizontalLine(
                                    y: threshold!,
                                    color: Colors.redAccent,
                                    strokeWidth: 1,
                                    dashArray: [4, 4],
                                  ),
                                ],
                              ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

(double, double)? _seriesYBounds(List<ChartSeries> series) {
  return _valuesYBounds([
    for (final item in series)
      for (final point in item.points) point.value,
  ]);
}

(double, double)? _pointsYBounds(List<SeriesPoint> points) {
  return _valuesYBounds([for (final point in points) point.value]);
}

(int, int) _xBounds({
  required List<List<SeriesPoint>> series,
  int? minTimestampMs,
  int? maxTimestampMs,
}) {
  final all = [for (final points in series) ...points];
  final dataMin = all.isEmpty
      ? DateTime.now().millisecondsSinceEpoch
      : all.map((point) => point.ts).reduce((a, b) => a < b ? a : b);
  final dataMax = all.isEmpty
      ? dataMin + 1
      : all.map((point) => point.ts).reduce((a, b) => a > b ? a : b);
  final min = minTimestampMs ?? dataMin;
  final max = maxTimestampMs ?? dataMax;
  return max <= min ? (min, min + 1) : (min, max);
}

(double, double)? _valuesYBounds(List<double> values) {
  final finite = values.where((value) => value.isFinite).toList();
  if (finite.isEmpty) return null;

  var min = finite.first;
  var max = finite.first;
  for (final value in finite.skip(1)) {
    if (value < min) min = value;
    if (value > max) max = value;
  }

  final span = max - min;
  final anchor = max.abs() > min.abs() ? max.abs() : min.abs();
  final pad = span > 0 ? span * 0.12 : (anchor * 0.002).clamp(1.0, 25.0);
  return (min - pad, max + pad);
}
