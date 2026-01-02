import 'package:flutter/material.dart';

/// Compact progress indicator for transfers
///
/// Shows:
/// - Linear progress bar
/// - Percentage
/// - Speed (e.g., "1.5 MB/s")
/// - ETA (e.g., "2m 30s remaining")
class TransferProgressWidget extends StatelessWidget {
  final int bytesTransferred;
  final int totalBytes;
  final double? speedBytesPerSecond;
  final Duration? eta;
  final bool showSpeed;
  final bool showEta;
  final bool showPercentage;
  final Color? progressColor;
  final Color? backgroundColor;

  const TransferProgressWidget({
    super.key,
    required this.bytesTransferred,
    required this.totalBytes,
    this.speedBytesPerSecond,
    this.eta,
    this.showSpeed = true,
    this.showEta = true,
    this.showPercentage = true,
    this.progressColor,
    this.backgroundColor,
  });

  double get progress => totalBytes > 0 ? bytesTransferred / totalBytes : 0;

  double get progressPercent => progress * 100;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Progress bar
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 6,
            backgroundColor:
                backgroundColor ?? theme.colorScheme.surfaceContainerHighest,
            valueColor: AlwaysStoppedAnimation<Color>(
              progressColor ?? theme.colorScheme.primary,
            ),
          ),
        ),
        const SizedBox(height: 4),

        // Stats row
        Row(
          children: [
            // Percentage
            if (showPercentage) ...[
              Text(
                '${progressPercent.toStringAsFixed(1)}%',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 8),
            ],

            // Bytes transferred
            Text(
              '${_formatBytes(bytesTransferred)} / ${_formatBytes(totalBytes)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),

            const Spacer(),

            // Speed
            if (showSpeed && speedBytesPerSecond != null) ...[
              Icon(
                Icons.speed,
                size: 12,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 2),
              Text(
                '${_formatBytes(speedBytesPerSecond!.round())}/s',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],

            // ETA
            if (showEta && eta != null) ...[
              const SizedBox(width: 8),
              Icon(
                Icons.timer_outlined,
                size: 12,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 2),
              Text(
                _formatDuration(eta!),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _formatDuration(Duration duration) {
    if (duration.inSeconds < 60) {
      return '${duration.inSeconds}s';
    }
    if (duration.inMinutes < 60) {
      final seconds = duration.inSeconds % 60;
      return '${duration.inMinutes}m ${seconds}s';
    }
    final minutes = duration.inMinutes % 60;
    return '${duration.inHours}h ${minutes}m';
  }
}

/// Mini progress bar for compact display
class TransferProgressBar extends StatelessWidget {
  final double progress;
  final Color? color;
  final double height;

  const TransferProgressBar({
    super.key,
    required this.progress,
    this.color,
    this.height = 4,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: LinearProgressIndicator(
        value: progress.clamp(0, 1),
        minHeight: height,
        backgroundColor: theme.colorScheme.surfaceContainerHighest,
        valueColor: AlwaysStoppedAnimation<Color>(
          color ?? theme.colorScheme.primary,
        ),
      ),
    );
  }
}
