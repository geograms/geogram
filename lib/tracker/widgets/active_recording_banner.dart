import 'dart:async';

import 'package:flutter/material.dart';

import '../models/tracker_models.dart';
import '../services/path_recording_service.dart';
import '../../services/i18n_service.dart';

/// Banner widget showing active path recording status
class ActiveRecordingBanner extends StatefulWidget {
  final PathRecordingService recordingService;
  final I18nService i18n;
  final VoidCallback? onStop;
  final VoidCallback? onTap;

  const ActiveRecordingBanner({
    super.key,
    required this.recordingService,
    required this.i18n,
    this.onStop,
    this.onTap,
  });

  @override
  State<ActiveRecordingBanner> createState() => _ActiveRecordingBannerState();
}

class _ActiveRecordingBannerState extends State<ActiveRecordingBanner> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // Update timer every second to show elapsed time
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    widget.recordingService.addListener(_onRecordingChanged);
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.recordingService.removeListener(_onRecordingChanged);
    super.dispose();
  }

  void _onRecordingChanged() {
    if (mounted) setState(() {});
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '${hours}h ${minutes.toString().padLeft(2, '0')}m';
    } else if (minutes > 0) {
      return '${minutes}m ${seconds.toString().padLeft(2, '0')}s';
    } else {
      return '${seconds}s';
    }
  }

  String _formatDistance(double meters) {
    if (meters >= 1000) {
      return '${(meters / 1000).toStringAsFixed(2)} km';
    } else {
      return '${meters.toStringAsFixed(0)} m';
    }
  }

  /// "Acquiring GPS…" / "Weak GPS signal" hint shown while no fix has been
  /// accepted yet. Returns an empty widget once the recorder has at least
  /// one accepted point — the existing point counter takes over from there.
  Widget _buildAcquisitionHint(ThemeData theme, ColorScheme colorScheme) {
    final status = widget.recordingService.acquisitionStatus;
    if (status == GpsAcquisitionStatus.none) {
      return const SizedBox.shrink();
    }

    final isAcquiring = status == GpsAcquisitionStatus.acquiring;
    final icon = isAcquiring ? Icons.gps_not_fixed : Icons.gps_off;
    final text = isAcquiring
        ? widget.i18n.t('tracker_acquiring_gps')
        : _weakSignalLabel();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          const SizedBox(width: 20), // align with the indicator dot above
          Icon(
            icon,
            size: 14,
            color: colorScheme.onPrimaryContainer.withValues(alpha: 0.75),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onPrimaryContainer.withValues(alpha: 0.85),
                fontStyle: FontStyle.italic,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  String _weakSignalLabel() {
    final base = widget.i18n.t('tracker_weak_gps');
    final acc = widget.recordingService.lastRejectedAccuracyMeters;
    if (acc == null) return base;
    return '$base (~${acc.toStringAsFixed(0)} m)';
  }

  Widget _buildStatItem(
    IconData icon,
    String label,
    TextStyle? textStyle,
    Color iconColor,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: iconColor),
        const SizedBox(width: 4),
        Text(label, style: textStyle),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.recordingService;
    if (!service.hasActiveRecording) {
      return const SizedBox.shrink();
    }

    final state = service.recordingState;
    final pathType = state != null
        ? TrackerPathType.fromTags(
            [state.activePathId],
          )
        : null;

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final isPaused = service.isPaused;
    final statColor = isPaused
        ? colorScheme.onSecondaryContainer.withValues(alpha: 0.7)
        : colorScheme.onPrimaryContainer.withValues(alpha: 0.7);
    final statTextStyle = theme.textTheme.bodySmall?.copyWith(
      color: statColor,
    );
    final stats = Wrap(
      spacing: 16,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _buildStatItem(
          Icons.emoji_events_outlined,
          '${service.pointCount} ${widget.i18n.t('tracker_points')}',
          statTextStyle,
          statColor,
        ),
        _buildStatItem(
          Icons.straighten,
          _formatDistance(service.totalDistance),
          statTextStyle,
          statColor,
        ),
      ],
    );
    final actions = Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.end,
      children: [
        SizedBox(
          height: 32,
          child: isPaused
              ? OutlinedButton.icon(
                  onPressed: () => service.resumeRecording(),
                  icon: const Icon(Icons.play_arrow, size: 16),
                  label: Text(widget.i18n.t('tracker_resume_path')),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    visualDensity: VisualDensity.compact,
                  ),
                )
              : OutlinedButton.icon(
                  onPressed: () => service.pauseRecording(),
                  icon: const Icon(Icons.pause, size: 16),
                  label: Text(widget.i18n.t('tracker_pause_path')),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
        ),
        SizedBox(
          height: 32,
          child: FilledButton.icon(
            onPressed: () => _showStopConfirmation(context),
            icon: const Icon(Icons.stop, size: 16),
            label: Text(widget.i18n.t('tracker_stop_path')),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              visualDensity: VisualDensity.compact,
              backgroundColor: colorScheme.error,
              foregroundColor: colorScheme.onError,
            ),
          ),
        ),
      ],
    );

    return Material(
      color: isPaused
          ? colorScheme.secondaryContainer
          : colorScheme.primaryContainer,
      child: InkWell(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: isPaused
                    ? colorScheme.secondary.withValues(alpha: 0.3)
                    : colorScheme.primary.withValues(alpha: 0.3),
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
          // Status row
          Row(
            children: [
              // Recording indicator
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isPaused ? colorScheme.secondary : Colors.red,
                ),
                child: isPaused
                    ? null
                    : Center(
                        child: Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.red.shade700,
                          ),
                        ),
                      ),
              ),
              const SizedBox(width: 8),
              Text(
                isPaused
                    ? widget.i18n.t('tracker_recording_paused')
                    : widget.i18n.t('tracker_recording_in_progress'),
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: isPaused
                      ? colorScheme.onSecondaryContainer
                      : colorScheme.onPrimaryContainer,
                ),
              ),
              const Spacer(),
              // Elapsed time
              Icon(
                Icons.timer_outlined,
                size: 16,
                color: isPaused
                    ? colorScheme.onSecondaryContainer
                    : colorScheme.onPrimaryContainer,
              ),
              const SizedBox(width: 4),
              Text(
                _formatDuration(service.elapsedTime),
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                  color: isPaused
                      ? colorScheme.onSecondaryContainer
                      : colorScheme.onPrimaryContainer,
                ),
              ),
            ],
          ),
          if (!isPaused) _buildAcquisitionHint(theme, colorScheme),
          const SizedBox(height: 8),

          // Stats row
          LayoutBuilder(
            builder: (context, constraints) {
              final stackActions = constraints.maxWidth < 420;
              if (stackActions) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    stats,
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: actions,
                    ),
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: stats),
                  const SizedBox(width: 8),
                  actions,
                ],
              );
            },
          ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showStopConfirmation(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.i18n.t('tracker_confirm_stop')),
        content: Text(widget.i18n.t('tracker_confirm_stop_message')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(widget.i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(widget.i18n.t('tracker_stop_path')),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await widget.recordingService.stopRecording();
      widget.onStop?.call();
    }
  }
}
