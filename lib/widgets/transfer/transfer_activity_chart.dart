import 'package:flutter/material.dart';

import '../../transfer/models/transfer_metrics.dart';

/// Line chart showing transfer activity over time
///
/// Features:
/// - X-axis: Time (hourly for today, daily for week/month)
/// - Y-axis: Bytes transferred
/// - Two lines: uploads (green) and downloads (blue)
/// - Period selector: Day | Week | Month | All
class TransferActivityChart extends StatefulWidget {
  final List<TransferHistoryPoint> history;
  final TransferPeriodStats? periodStats;
  final Function(Duration period)? onPeriodChanged;

  const TransferActivityChart({
    super.key,
    required this.history,
    this.periodStats,
    this.onPeriodChanged,
  });

  @override
  State<TransferActivityChart> createState() => _TransferActivityChartState();
}

class _TransferActivityChartState extends State<TransferActivityChart> {
  int _selectedPeriod = 0; // 0=Day, 1=Week, 2=Month, 3=All
  static const _periods = ['Day', 'Week', 'Month', 'All'];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header with period selector
            Row(
              children: [
                Text(
                  'Activity',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                SegmentedButton<int>(
                  segments: List.generate(
                    _periods.length,
                    (i) => ButtonSegment(
                      value: i,
                      label: Text(_periods[i]),
                    ),
                  ),
                  selected: {_selectedPeriod},
                  onSelectionChanged: (selected) {
                    setState(() => _selectedPeriod = selected.first);
                    _notifyPeriodChange();
                  },
                  style: ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Chart area
            SizedBox(
              height: 150,
              child: widget.history.isEmpty
                  ? Center(
                      child: Text(
                        'No data for this period',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : _buildChart(theme),
            ),

            const SizedBox(height: 12),

            // Legend
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildLegendItem(
                  context,
                  color: Colors.blue,
                  label: 'Downloads',
                  value: widget.periodStats != null
                      ? _formatBytes(widget.periodStats!.bytesDownloaded)
                      : null,
                ),
                const SizedBox(width: 24),
                _buildLegendItem(
                  context,
                  color: Colors.green,
                  label: 'Uploads',
                  value: widget.periodStats != null
                      ? _formatBytes(widget.periodStats!.bytesUploaded)
                      : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChart(ThemeData theme) {
    if (widget.history.isEmpty) {
      return const SizedBox();
    }

    // Find max value for scaling
    final maxBytes = widget.history
        .map((p) => p.bytesTransferred)
        .reduce((a, b) => a > b ? a : b);

    final scale = maxBytes > 0 ? 140 / maxBytes : 1.0;

    return CustomPaint(
      size: Size.infinite,
      painter: _ChartPainter(
        points: widget.history,
        scale: scale,
        lineColor: Colors.blue,
        fillColor: Colors.blue.withOpacity(0.1),
        gridColor: theme.dividerColor,
      ),
    );
  }

  Widget _buildLegendItem(
    BuildContext context, {
    required Color color,
    required String label,
    String? value,
  }) {
    final theme = Theme.of(context);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: theme.textTheme.bodySmall,
        ),
        if (value != null) ...[
          const SizedBox(width: 4),
          Text(
            '($value)',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  void _notifyPeriodChange() {
    if (widget.onPeriodChanged == null) return;

    switch (_selectedPeriod) {
      case 0:
        widget.onPeriodChanged!(const Duration(days: 1));
        break;
      case 1:
        widget.onPeriodChanged!(const Duration(days: 7));
        break;
      case 2:
        widget.onPeriodChanged!(const Duration(days: 30));
        break;
      case 3:
        widget.onPeriodChanged!(const Duration(days: 365));
        break;
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

class _ChartPainter extends CustomPainter {
  final List<TransferHistoryPoint> points;
  final double scale;
  final Color lineColor;
  final Color fillColor;
  final Color gridColor;

  _ChartPainter({
    required this.points,
    required this.scale,
    required this.lineColor,
    required this.fillColor,
    required this.gridColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;

    // Draw grid lines
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 0.5;

    for (int i = 0; i <= 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    // Calculate points
    final stepX = size.width / (points.length - 1).clamp(1, 1000);
    final chartPoints = <Offset>[];

    for (int i = 0; i < points.length; i++) {
      final x = i * stepX;
      final y = size.height - (points[i].bytesTransferred * scale);
      chartPoints.add(Offset(x, y.clamp(0, size.height)));
    }

    // Draw fill
    final fillPath = Path();
    fillPath.moveTo(0, size.height);
    for (final point in chartPoints) {
      fillPath.lineTo(point.dx, point.dy);
    }
    fillPath.lineTo(size.width, size.height);
    fillPath.close();

    final fillPaint = Paint()
      ..color = fillColor
      ..style = PaintingStyle.fill;
    canvas.drawPath(fillPath, fillPaint);

    // Draw line
    if (chartPoints.length >= 2) {
      final linePath = Path();
      linePath.moveTo(chartPoints[0].dx, chartPoints[0].dy);
      for (int i = 1; i < chartPoints.length; i++) {
        linePath.lineTo(chartPoints[i].dx, chartPoints[i].dy);
      }

      final linePaint = Paint()
        ..color = lineColor
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      canvas.drawPath(linePath, linePaint);
    }

    // Draw dots at each point
    final dotPaint = Paint()
      ..color = lineColor
      ..style = PaintingStyle.fill;

    for (final point in chartPoints) {
      canvas.drawCircle(point, 3, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _ChartPainter oldDelegate) {
    return points != oldDelegate.points ||
        scale != oldDelegate.scale ||
        lineColor != oldDelegate.lineColor;
  }
}

/// Transport breakdown chart (horizontal bar chart)
class TransportBreakdownChart extends StatelessWidget {
  final Map<String, TransportStats> byTransport;

  const TransportBreakdownChart({
    super.key,
    required this.byTransport,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (byTransport.isEmpty) {
      return Card(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: Text(
              'No transport data yet',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    }

    // Calculate total for percentages
    final total =
        byTransport.values.fold<int>(0, (sum, s) => sum + s.bytesTransferred);

    // Sort by bytes transferred
    final sorted = byTransport.entries.toList()
      ..sort((a, b) => b.value.bytesTransferred.compareTo(a.value.bytesTransferred));

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Transport Usage',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            ...sorted.map((entry) => _buildTransportBar(
                  context,
                  entry.key,
                  entry.value,
                  total,
                )),
          ],
        ),
      ),
    );
  }

  Widget _buildTransportBar(
    BuildContext context,
    String transportId,
    TransportStats stats,
    int total,
  ) {
    final theme = Theme.of(context);
    final percentage = total > 0 ? stats.bytesTransferred / total : 0.0;
    final color = _getTransportColor(transportId);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 60,
                child: Text(
                  _getTransportLabel(transportId),
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: percentage,
                    minHeight: 16,
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                    valueColor: AlwaysStoppedAnimation<Color>(color),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 48,
                child: Text(
                  '${(percentage * 100).toStringAsFixed(0)}%',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                  textAlign: TextAlign.right,
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 64,
                child: Text(
                  _formatBytes(stats.bytesTransferred),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Color _getTransportColor(String transportId) {
    switch (transportId.toLowerCase()) {
      case 'lan':
        return Colors.green;
      case 'webrtc':
        return Colors.blue;
      case 'station':
        return Colors.orange;
      case 'ble':
      case 'bluetooth':
        return Colors.purple;
      default:
        return Colors.grey;
    }
  }

  String _getTransportLabel(String transportId) {
    switch (transportId.toLowerCase()) {
      case 'lan':
        return 'LAN';
      case 'webrtc':
        return 'WebRTC';
      case 'station':
        return 'Station';
      case 'ble':
        return 'BLE';
      case 'bluetooth':
        return 'BT';
      default:
        return transportId;
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
