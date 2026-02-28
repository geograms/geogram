/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../../services/audio_service.dart';
import '../../../services/log_service.dart';
import '../../../services/audio_platform_stub.dart'
    if (dart.library.io) '../../../services/audio_platform_io.dart';

/// Voice memo recorder widget for recording audio clips.
///
/// This is a customized version of VoiceRecorderWidget for the Work app.
/// Records audio in WAV format (16kHz mono) for direct Whisper transcription.
/// On Linux uses AudioService (ALSA), on other platforms uses AudioRecorder directly.
/// Shows visual amplitude feedback during recording.
class VoiceMemoRecorderWidget extends StatefulWidget {
  /// Called when user finishes recording.
  /// Receives the file path and duration in seconds.
  final void Function(String filePath, int durationSeconds) onSend;

  /// Called when user cancels recording.
  final VoidCallback onCancel;

  /// Maximum recording duration in seconds (default: 5 minutes)
  final int maxDurationSeconds;

  const VoiceMemoRecorderWidget({
    super.key,
    required this.onSend,
    required this.onCancel,
    this.maxDurationSeconds = 300, // 5 minutes
  });

  @override
  State<VoiceMemoRecorderWidget> createState() => _VoiceMemoRecorderWidgetState();
}

class _VoiceMemoRecorderWidgetState extends State<VoiceMemoRecorderWidget> {
  // On Linux we delegate to AudioService (ALSA); elsewhere use record package
  final bool _useAudioService = isLinuxPlatform;
  AudioService? _audioService;
  AudioRecorder? _recorder;

  _RecorderState _state = _RecorderState.idle;
  Duration _recordingDuration = Duration.zero;
  String? _recordedFilePath;
  int _recordedDurationSeconds = 0;
  double _amplitude = 0.0;

  Timer? _durationTimer;
  Timer? _amplitudeTimer;
  StreamSubscription<double>? _amplitudeSubscription;

  @override
  void initState() {
    super.initState();
    if (_useAudioService) {
      _audioService = AudioService();
      // Listen to ALSA amplitude stream
      _amplitudeSubscription = _audioService!.amplitudeStream.listen((amp) {
        if (!mounted) return;
        setState(() => _amplitude = amp);
      });
    } else {
      _recorder = AudioRecorder();
    }
    _startRecording();
  }

  Future<void> _startRecording() async {
    try {
      if (_useAudioService) {
        await _startRecordingAudioService();
      } else {
        await _startRecordingDirect();
      }
    } catch (e) {
      LogService().log('VoiceMemoRecorderWidget: Exception starting recording: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Recording error: $e')),
        );
        widget.onCancel();
      }
    }
  }

  /// Start recording via AudioService (Linux/ALSA — already produces WAV)
  Future<void> _startRecordingAudioService() async {
    await _audioService!.initialize();

    if (!await _audioService!.hasPermission()) {
      LogService().log('VoiceMemoRecorderWidget: No microphone permission');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission required')),
        );
        widget.onCancel();
      }
      return;
    }

    final path = await _audioService!.startRecording();
    if (path != null && mounted) {
      _recordedFilePath = path;
      setState(() {
        _state = _RecorderState.recording;
        _recordingDuration = Duration.zero;
      });
      _startTimers();
    } else if (mounted) {
      final error = _audioService!.lastError ?? 'Unknown error';
      LogService().log('VoiceMemoRecorderWidget: Recording failed: $error');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to start recording: $error')),
      );
      widget.onCancel();
    }
  }

  /// Start recording via record package (Android/iOS — WAV 16kHz mono)
  Future<void> _startRecordingDirect() async {
    if (!await _recorder!.hasPermission()) {
      LogService().log('VoiceMemoRecorderWidget: No microphone permission');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission required')),
        );
        widget.onCancel();
      }
      return;
    }

    final tempDir = await getTemporaryDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final path = '${tempDir.path}/voicememo_$timestamp.wav';

    // Record in WAV format (16kHz mono) — directly compatible with Whisper
    await _recorder!.start(
      RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: path,
    );

    _recordedFilePath = path;

    if (mounted) {
      setState(() {
        _state = _RecorderState.recording;
        _recordingDuration = Duration.zero;
      });
    }

    _startTimers();

    // Start amplitude polling (record package)
    _amplitudeTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) async {
      if (!mounted) return;
      try {
        final amp = await _recorder!.getAmplitude();
        if (!mounted) return;
        // amp.current is in dBFS (negative, -160 = silence, 0 = max)
        // Normalize to 0.0-1.0 range
        final normalized = ((amp.current + 60) / 60).clamp(0.0, 1.0);
        setState(() {
          _amplitude = normalized;
        });
      } catch (_) {
        // Ignore amplitude errors
      }
    });
  }

  void _startTimers() {
    _durationTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      if (!mounted) return;
      setState(() {
        _recordingDuration += const Duration(milliseconds: 100);
      });
      if (_recordingDuration.inSeconds >= widget.maxDurationSeconds) {
        _stopRecording();
      }
    });
  }

  Future<void> _stopRecording() async {
    _durationTimer?.cancel();
    _amplitudeTimer?.cancel();

    String? path;
    if (_useAudioService) {
      path = await _audioService!.stopRecording();
    } else {
      path = await _recorder!.stop();
    }

    if (path != null && mounted) {
      _recordedFilePath = path;
      _recordedDurationSeconds = _recordingDuration.inSeconds;

      setState(() {
        _state = _RecorderState.preview;
        _amplitude = 0.0;
      });
    } else if (mounted) {
      widget.onCancel();
    }
  }

  Future<void> _cancel() async {
    // If in preview mode (clip already recorded), warn before discarding
    if (_state == _RecorderState.preview && _recordedFilePath != null) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Discard Recording?'),
          content: const Text(
            'The recorded audio clip will be permanently lost. '
            'Are you sure you want to discard it?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error,
              ),
              child: const Text('Discard'),
            ),
          ],
        ),
      );
      if (discard != true) return;
      final file = PlatformFile(_recordedFilePath!);
      if (await file.exists()) {
        await file.delete();
      }
    } else if (_state == _RecorderState.recording) {
      _durationTimer?.cancel();
      _amplitudeTimer?.cancel();
      if (_useAudioService) {
        await _audioService!.cancelRecording();
      } else {
        await _recorder!.stop();
        // Delete the temp file
        if (_recordedFilePath != null) {
          final file = PlatformFile(_recordedFilePath!);
          if (await file.exists()) {
            await file.delete();
          }
        }
      }
    }
    widget.onCancel();
  }

  void _send() {
    if (_recordedFilePath != null) {
      widget.onSend(_recordedFilePath!, _recordedDurationSeconds);
    }
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _durationTimer?.cancel();
    _amplitudeTimer?.cancel();
    _amplitudeSubscription?.cancel();
    _recorder?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: _state == _RecorderState.recording
          ? _buildRecordingUI(theme)
          : _buildPreviewUI(theme),
    );
  }

  Widget _buildRecordingUI(ThemeData theme) {
    final maxDuration = Duration(seconds: widget.maxDurationSeconds);
    final progress = _recordingDuration.inMilliseconds / maxDuration.inMilliseconds;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Amplitude visualizer
        SizedBox(
          height: 48,
          child: _AmplitudeVisualizer(amplitude: _amplitude),
        ),

        const SizedBox(height: 12),

        // Timer and controls
        Row(
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
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _AnimatedRecordingDot(),
                      const SizedBox(width: 8),
                      Text(
                        _formatDuration(_recordingDuration),
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurface,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '/ ${_formatDuration(maxDuration)}',
                        style: TextStyle(
                          fontSize: 14,
                          color: theme.colorScheme.onSurface.withOpacity(0.5),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: progress,
                      backgroundColor: theme.colorScheme.surfaceContainerLowest,
                      valueColor: AlwaysStoppedAnimation<Color>(theme.colorScheme.error),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(width: 8),

            // Stop button
            IconButton(
              icon: Icon(Icons.stop, color: theme.colorScheme.primary, size: 28),
              onPressed: _stopRecording,
              tooltip: 'Stop recording',
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildPreviewUI(ThemeData theme) {
    return Row(
      children: [
        // Delete button
        IconButton(
          icon: Icon(Icons.delete_outline, color: theme.colorScheme.error),
          onPressed: _cancel,
          tooltip: 'Delete',
        ),

        // Duration display
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.mic, size: 20, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                _formatDuration(Duration(seconds: _recordedDurationSeconds)),
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ],
          ),
        ),

        // Save button
        FilledButton.icon(
          onPressed: _send,
          icon: const Icon(Icons.check, size: 20),
          label: const Text('Save'),
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
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.red.withOpacity(_animation.value),
          ),
        );
      },
    );
  }
}

/// Visual amplitude display with animated bars
class _AmplitudeVisualizer extends StatefulWidget {
  final double amplitude;

  const _AmplitudeVisualizer({required this.amplitude});

  @override
  State<_AmplitudeVisualizer> createState() => _AmplitudeVisualizerState();
}

class _AmplitudeVisualizerState extends State<_AmplitudeVisualizer>
    with SingleTickerProviderStateMixin {
  static const int barCount = 20;
  late AnimationController _controller;
  final List<double> _barHeights = List.filled(barCount, 0.1);
  final Random _random = Random();

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 100),
      vsync: this,
    )..addListener(_updateBars);
    _controller.repeat();
  }

  void _updateBars() {
    if (!mounted) return;

    setState(() {
      // Shift bars to the left
      for (int i = 0; i < barCount - 1; i++) {
        _barHeights[i] = _barHeights[i + 1];
      }

      // Add new bar based on amplitude with some randomness for visual appeal
      final baseHeight = widget.amplitude;
      final variation = _random.nextDouble() * 0.2 - 0.1;
      _barHeights[barCount - 1] = (baseHeight + variation).clamp(0.05, 1.0);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;

    return LayoutBuilder(
      builder: (context, constraints) {
        final barWidth = (constraints.maxWidth - (barCount - 1) * 2) / barCount;

        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: List.generate(barCount, (index) {
            final height = _barHeights[index] * constraints.maxHeight;

            return Padding(
              padding: EdgeInsets.only(right: index < barCount - 1 ? 2 : 0),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 50),
                width: barWidth.clamp(2.0, 8.0),
                height: height.clamp(4.0, constraints.maxHeight),
                decoration: BoxDecoration(
                  color: primaryColor.withOpacity(0.3 + _barHeights[index] * 0.7),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}
