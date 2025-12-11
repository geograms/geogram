import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import '../services/audio_service.dart';
import '../services/log_service.dart';

/// Voice message recorder widget.
///
/// States:
/// 1. **Recording**: Red dot, timer (max 30s), cancel/send buttons
/// 2. **Preview**: Play button, progress bar, cancel/send buttons (no waveform)
class VoiceRecorderWidget extends StatefulWidget {
  /// Called when user sends the voice message.
  /// Receives the file path and duration in seconds.
  final void Function(String filePath, int durationSeconds) onSend;

  /// Called when user cancels recording.
  final VoidCallback onCancel;

  const VoiceRecorderWidget({
    super.key,
    required this.onSend,
    required this.onCancel,
  });

  @override
  State<VoiceRecorderWidget> createState() => _VoiceRecorderWidgetState();
}

class _VoiceRecorderWidgetState extends State<VoiceRecorderWidget> {
  final AudioService _audioService = AudioService();
  final AudioPlayer _previewPlayer = AudioPlayer();

  _RecorderState _state = _RecorderState.idle;
  Duration _recordingDuration = Duration.zero;
  String? _recordedFilePath;
  int _recordedDurationSeconds = 0;

  // Preview playback
  Duration _previewPosition = Duration.zero;
  Duration _previewDuration = Duration.zero;
  bool _isPreviewPlaying = false;

  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<Duration>? _previewPositionSubscription;
  StreamSubscription<PlayerState>? _previewStateSubscription;

  @override
  void initState() {
    super.initState();
    _setupListeners();
    _startRecording();
  }

  void _setupListeners() {
    // Recording duration updates
    _durationSubscription = _audioService.recordingDurationStream.listen((duration) {
      if (!mounted) return;
      setState(() {
        _recordingDuration = duration;
      });
    });

    // Preview player position
    _previewPositionSubscription = _previewPlayer.positionStream.listen((position) {
      if (!mounted) return;
      setState(() {
        _previewPosition = position;
      });
    });

    // Preview player state
    _previewStateSubscription = _previewPlayer.playerStateStream.listen((state) {
      if (!mounted) return;
      setState(() {
        if (state.processingState == ProcessingState.completed) {
          _isPreviewPlaying = false;
          _previewPosition = Duration.zero;
          _previewPlayer.seek(Duration.zero);
          _previewPlayer.pause();
        } else {
          _isPreviewPlaying = _previewPlayer.playing;
        }
      });
    });
  }

  Future<void> _startRecording() async {
    // Check permission first
    if (!await _audioService.hasPermission()) {
      LogService().log('VoiceRecorderWidget: No microphone permission');
      // Show error and cancel
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission required')),
        );
        widget.onCancel();
      }
      return;
    }

    final path = await _audioService.startRecording();
    if (path != null && mounted) {
      setState(() {
        _state = _RecorderState.recording;
      });
    } else if (mounted) {
      final error = _audioService.lastError ?? 'Unknown error';
      LogService().log('VoiceRecorderWidget: Recording failed: $error');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to start recording: $error')),
      );
      widget.onCancel();
    }
  }

  Future<void> _stopRecording() async {
    final path = await _audioService.stopRecording();
    if (path != null && mounted) {
      _recordedFilePath = path;
      _recordedDurationSeconds = _recordingDuration.inSeconds;

      // Load for preview
      final duration = await _previewPlayer.setFilePath(path);
      setState(() {
        _state = _RecorderState.preview;
        _previewDuration = duration ?? Duration.zero;
        _previewPosition = Duration.zero;
      });
    } else if (mounted) {
      widget.onCancel();
    }
  }

  Future<void> _cancel() async {
    if (_state == _RecorderState.recording) {
      await _audioService.cancelRecording();
    } else if (_recordedFilePath != null) {
      // Delete preview file
      final file = File(_recordedFilePath!);
      if (await file.exists()) {
        await file.delete();
      }
    }
    widget.onCancel();
  }

  void _send() {
    if (_recordedFilePath != null) {
      widget.onSend(_recordedFilePath!, _recordedDurationSeconds);
    }
  }

  void _togglePreviewPlayback() {
    if (_isPreviewPlaying) {
      _previewPlayer.pause();
    } else {
      _previewPlayer.play();
    }
  }

  void _seekPreview(double value) {
    final position = Duration(milliseconds: (value * _previewDuration.inMilliseconds).round());
    _previewPlayer.seek(position);
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _durationSubscription?.cancel();
    _previewPositionSubscription?.cancel();
    _previewStateSubscription?.cancel();
    _previewPlayer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(24),
      ),
      child: _state == _RecorderState.recording
          ? _buildRecordingUI(theme)
          : _buildPreviewUI(theme),
    );
  }

  Widget _buildRecordingUI(ThemeData theme) {
    final maxDuration = AudioService.maxRecordingDuration;
    final progress = _recordingDuration.inMilliseconds / maxDuration.inMilliseconds;

    return Row(
      children: [
        // Cancel button
        IconButton(
          icon: Icon(Icons.close, color: theme.colorScheme.error),
          onPressed: _cancel,
          tooltip: 'Cancel',
        ),

        const SizedBox(width: 8),

        // Recording indicator and timer
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Animated recording dot
              _AnimatedRecordingDot(),
              const SizedBox(width: 8),

              // Timer
              Text(
                _formatDuration(_recordingDuration),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: theme.colorScheme.onSurface,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),

              const SizedBox(width: 8),

              // Max duration indicator
              Text(
                '/ ${_formatDuration(maxDuration)}',
                style: TextStyle(
                  fontSize: 14,
                  color: theme.colorScheme.onSurface.withOpacity(0.5),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(width: 8),

        // Stop/Send button
        IconButton(
          icon: Icon(Icons.stop, color: theme.colorScheme.primary),
          onPressed: _stopRecording,
          tooltip: 'Stop recording',
        ),
      ],
    );
  }

  Widget _buildPreviewUI(ThemeData theme) {
    final progress = _previewDuration.inMilliseconds > 0
        ? (_previewPosition.inMilliseconds / _previewDuration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return Row(
      children: [
        // Cancel button
        IconButton(
          icon: Icon(Icons.delete_outline, color: theme.colorScheme.error),
          onPressed: _cancel,
          tooltip: 'Delete',
        ),

        // Play/Pause button
        IconButton(
          icon: Icon(
            _isPreviewPlaying ? Icons.pause : Icons.play_arrow,
            color: theme.colorScheme.primary,
          ),
          onPressed: _togglePreviewPlayback,
          tooltip: _isPreviewPlaying ? 'Pause' : 'Play',
        ),

        // Progress slider and time
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SliderTheme(
                data: SliderThemeData(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                  activeTrackColor: theme.colorScheme.primary,
                  inactiveTrackColor: theme.colorScheme.primary.withOpacity(0.3),
                  thumbColor: theme.colorScheme.primary,
                  overlayColor: theme.colorScheme.primary.withOpacity(0.2),
                ),
                child: Slider(
                  value: progress,
                  onChanged: _seekPreview,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _formatDuration(_previewPosition),
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.onSurface.withOpacity(0.7),
                      ),
                    ),
                    Text(
                      _formatDuration(_previewDuration),
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.onSurface.withOpacity(0.7),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        // Send button
        IconButton(
          icon: Icon(Icons.send, color: theme.colorScheme.primary),
          onPressed: _send,
          tooltip: 'Send',
        ),
      ],
    );
  }
}

enum _RecorderState {
  idle,
  recording,
  preview,
}

/// Animated recording indicator (pulsing red dot)
class _AnimatedRecordingDot extends StatefulWidget {
  @override
  State<_AnimatedRecordingDot> createState() => _AnimatedRecordingDotState();
}

class _AnimatedRecordingDotState extends State<_AnimatedRecordingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    )..repeat(reverse: true);

    _animation = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.red.withOpacity(_animation.value),
          ),
        );
      },
    );
  }
}
