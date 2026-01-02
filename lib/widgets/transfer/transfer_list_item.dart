import 'package:flutter/material.dart';

import '../../transfer/models/transfer_models.dart';
import 'transfer_progress_widget.dart';

/// Individual transfer list item with:
/// - File icon based on mime type
/// - Filename and remote callsign
/// - Progress bar (if active)
/// - Speed and ETA (if transferring)
/// - Status chip (completed/failed/waiting)
/// - Action buttons (pause/resume/cancel/retry)
class TransferListItem extends StatelessWidget {
  final Transfer transfer;
  final VoidCallback? onTap;
  final VoidCallback? onCancel;
  final VoidCallback? onRetry;
  final VoidCallback? onPause;
  final VoidCallback? onResume;

  const TransferListItem({
    super.key,
    required this.transfer,
    this.onTap,
    this.onCancel,
    this.onRetry,
    this.onPause,
    this.onResume,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header row
              Row(
                children: [
                  // Direction icon
                  _buildDirectionIcon(theme),
                  const SizedBox(width: 8),

                  // File icon
                  _buildFileIcon(theme),
                  const SizedBox(width: 12),

                  // File info
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          transfer.filename ?? 'Unknown file',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _getCallsignLabel(),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Status chip
                  _buildStatusChip(theme),
                ],
              ),

              // Progress section (if active)
              if (transfer.isActive) ...[
                const SizedBox(height: 12),
                TransferProgressWidget(
                  bytesTransferred: transfer.bytesTransferred,
                  totalBytes: transfer.expectedBytes,
                  speedBytesPerSecond: transfer.speedBytesPerSecond,
                  eta: transfer.estimatedTimeRemaining,
                ),
              ],

              // Action buttons
              if (_hasActions) ...[
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (transfer.canPause && onPause != null)
                      TextButton.icon(
                        onPressed: onPause,
                        icon: const Icon(Icons.pause, size: 18),
                        label: const Text('Pause'),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    if (transfer.canResume && onResume != null)
                      TextButton.icon(
                        onPressed: onResume,
                        icon: const Icon(Icons.play_arrow, size: 18),
                        label: const Text('Resume'),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    if (transfer.canRetry && onRetry != null)
                      TextButton.icon(
                        onPressed: onRetry,
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('Retry'),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    if (transfer.canCancel && onCancel != null)
                      TextButton.icon(
                        onPressed: onCancel,
                        icon: const Icon(Icons.close, size: 18),
                        label: const Text('Cancel'),
                        style: TextButton.styleFrom(
                          foregroundColor: theme.colorScheme.error,
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                  ],
                ),
              ],

              // Error message
              if (transfer.error != null && transfer.isFailed) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.error_outline,
                        size: 16,
                        color: theme.colorScheme.onErrorContainer,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          transfer.error!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onErrorContainer,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              // Next retry time
              if (transfer.status == TransferStatus.waiting &&
                  transfer.nextRetryAt != null) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      Icons.schedule,
                      size: 14,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Next retry: ${_formatNextRetry(transfer.nextRetryAt!)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDirectionIcon(ThemeData theme) {
    IconData icon;
    Color color;

    switch (transfer.direction) {
      case TransferDirection.upload:
        icon = Icons.upload;
        color = Colors.green;
        break;
      case TransferDirection.download:
        icon = Icons.download;
        color = Colors.blue;
        break;
      case TransferDirection.stream:
        icon = Icons.swap_vert;
        color = Colors.purple;
        break;
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Icon(icon, size: 16, color: color),
    );
  }

  Widget _buildFileIcon(ThemeData theme) {
    final mimeType = transfer.mimeType ?? '';
    IconData icon;
    Color color;

    if (mimeType.startsWith('image/')) {
      icon = Icons.image;
      color = Colors.pink;
    } else if (mimeType.startsWith('video/')) {
      icon = Icons.video_file;
      color = Colors.red;
    } else if (mimeType.startsWith('audio/')) {
      icon = Icons.audio_file;
      color = Colors.orange;
    } else if (mimeType.startsWith('text/')) {
      icon = Icons.description;
      color = Colors.blue;
    } else if (mimeType.contains('pdf')) {
      icon = Icons.picture_as_pdf;
      color = Colors.red;
    } else if (mimeType.contains('zip') ||
        mimeType.contains('tar') ||
        mimeType.contains('rar')) {
      icon = Icons.folder_zip;
      color = Colors.amber;
    } else {
      icon = Icons.insert_drive_file;
      color = theme.colorScheme.primary;
    }

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, size: 24, color: color),
    );
  }

  Widget _buildStatusChip(ThemeData theme) {
    String label;
    Color color;
    IconData? icon;

    switch (transfer.status) {
      case TransferStatus.queued:
        label = 'Queued';
        color = Colors.grey;
        icon = Icons.schedule;
        break;
      case TransferStatus.connecting:
        label = 'Connecting';
        color = Colors.orange;
        icon = Icons.sync;
        break;
      case TransferStatus.transferring:
        label = 'Transferring';
        color = Colors.blue;
        icon = Icons.sync;
        break;
      case TransferStatus.verifying:
        label = 'Verifying';
        color = Colors.indigo;
        icon = Icons.verified;
        break;
      case TransferStatus.completed:
        label = 'Completed';
        color = Colors.green;
        icon = Icons.check_circle;
        break;
      case TransferStatus.failed:
        label = 'Failed';
        color = Colors.red;
        icon = Icons.error;
        break;
      case TransferStatus.cancelled:
        label = 'Cancelled';
        color = Colors.grey;
        icon = Icons.cancel;
        break;
      case TransferStatus.paused:
        label = 'Paused';
        color = Colors.amber;
        icon = Icons.pause_circle;
        break;
      case TransferStatus.waiting:
        label = 'Waiting';
        color = Colors.orange;
        icon = Icons.hourglass_empty;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  String _getCallsignLabel() {
    final callsign = transfer.direction == TransferDirection.upload
        ? transfer.targetCallsign
        : transfer.sourceCallsign;

    final prefix =
        transfer.direction == TransferDirection.upload ? 'To: ' : 'From: ';

    return '$prefix$callsign';
  }

  bool get _hasActions =>
      (transfer.canPause && onPause != null) ||
      (transfer.canResume && onResume != null) ||
      (transfer.canRetry && onRetry != null) ||
      (transfer.canCancel && onCancel != null);

  String _formatNextRetry(DateTime nextRetry) {
    final now = DateTime.now();
    final diff = nextRetry.difference(now);

    if (diff.isNegative) return 'Soon';

    if (diff.inMinutes < 1) return 'In ${diff.inSeconds}s';
    if (diff.inHours < 1) return 'In ${diff.inMinutes}m';
    if (diff.inDays < 1) return 'In ${diff.inHours}h ${diff.inMinutes % 60}m';

    return 'In ${diff.inDays}d';
  }
}
