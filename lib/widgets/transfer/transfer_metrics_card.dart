import 'package:flutter/material.dart';

import '../../transfer/models/transfer_metrics.dart';

/// Summary card showing:
/// - Active connections count (with animated indicator)
/// - Current speed (e.g., "2.5 MB/s")
/// - Today's totals: uploads/downloads/bytes
/// - Quick stats: success rate percentage
class TransferMetricsCard extends StatelessWidget {
  final TransferMetrics metrics;
  final VoidCallback? onTap;

  const TransferMetricsCard({
    super.key,
    required this.metrics,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.all(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  Icon(
                    Icons.analytics_outlined,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Transfer Statistics',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  if (onTap != null)
                    Icon(
                      Icons.arrow_forward_ios,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                ],
              ),
              const SizedBox(height: 16),

              // Real-time stats row
              Row(
                children: [
                  _buildStatItem(
                    context,
                    icon: Icons.sync,
                    iconColor: Colors.blue,
                    value: '${metrics.activeTransfers}',
                    label: 'Active',
                    isAnimated: metrics.activeTransfers > 0,
                  ),
                  const SizedBox(width: 16),
                  _buildStatItem(
                    context,
                    icon: Icons.link,
                    iconColor: Colors.green,
                    value: '${metrics.activeConnections}',
                    label: 'Connections',
                  ),
                  const SizedBox(width: 16),
                  _buildStatItem(
                    context,
                    icon: Icons.speed,
                    iconColor: Colors.orange,
                    value: _formatSpeed(metrics.currentSpeedBytesPerSecond),
                    label: 'Speed',
                  ),
                  const SizedBox(width: 16),
                  _buildStatItem(
                    context,
                    icon: Icons.queue,
                    iconColor: Colors.purple,
                    value: '${metrics.queuedTransfers}',
                    label: 'Queued',
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Divider
              Divider(color: theme.dividerColor),
              const SizedBox(height: 12),

              // Today's summary
              Text(
                'Today',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _buildTodayStat(
                    context,
                    icon: Icons.download,
                    iconColor: Colors.blue,
                    count: metrics.today.downloadCount,
                    bytes: metrics.today.bytesDownloaded,
                    label: 'Downloads',
                  ),
                  const SizedBox(width: 24),
                  _buildTodayStat(
                    context,
                    icon: Icons.upload,
                    iconColor: Colors.green,
                    count: metrics.today.uploadCount,
                    bytes: metrics.today.bytesUploaded,
                    label: 'Uploads',
                  ),
                  const Spacer(),
                  _buildSuccessRate(context, metrics.today.successRate),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatItem(
    BuildContext context, {
    required IconData icon,
    required Color iconColor,
    required String value,
    required String label,
    bool isAnimated = false,
  }) {
    final theme = Theme.of(context);

    return Expanded(
      child: Column(
        children: [
          Stack(
            alignment: Alignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: iconColor.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 20, color: iconColor),
              ),
              if (isAnimated)
                SizedBox(
                  width: 40,
                  height: 40,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      iconColor.withOpacity(0.5),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTodayStat(
    BuildContext context, {
    required IconData icon,
    required Color iconColor,
    required int count,
    required int bytes,
    required String label,
  }) {
    final theme = Theme.of(context);

    return Row(
      children: [
        Icon(icon, size: 16, color: iconColor),
        const SizedBox(width: 4),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$count transfers',
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
            Text(
              _formatBytes(bytes),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSuccessRate(BuildContext context, double rate) {
    final theme = Theme.of(context);
    final percentage = (rate * 100).round();
    final color = percentage >= 90
        ? Colors.green
        : percentage >= 70
            ? Colors.orange
            : Colors.red;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            percentage >= 90 ? Icons.check_circle : Icons.warning,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            '$percentage% success',
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  String _formatSpeed(double bytesPerSecond) {
    if (bytesPerSecond < 1024) return '${bytesPerSecond.round()} B/s';
    if (bytesPerSecond < 1024 * 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
    }
    return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
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

/// Compact metrics widget for app bar or nav rail
class TransferNotificationWidget extends StatelessWidget {
  final int activeTransfers;
  final int queuedTransfers;
  final VoidCallback? onTap;

  const TransferNotificationWidget({
    super.key,
    required this.activeTransfers,
    required this.queuedTransfers,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = activeTransfers + queuedTransfers;

    if (total == 0) {
      return IconButton(
        onPressed: onTap,
        icon: const Icon(Icons.swap_vert),
        tooltip: 'Transfers',
      );
    }

    return IconButton(
      onPressed: onTap,
      icon: Badge(
        label: Text('$total'),
        backgroundColor: activeTransfers > 0 ? Colors.blue : Colors.grey,
        child: Icon(
          activeTransfers > 0 ? Icons.sync : Icons.swap_vert,
        ),
      ),
      tooltip: '$activeTransfers active, $queuedTransfers queued',
    );
  }
}
