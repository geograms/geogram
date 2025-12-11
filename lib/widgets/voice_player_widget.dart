import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import '../services/audio_service.dart';
import '../services/log_service.dart';

/// Voice message player widget with download indicator.
///
/// States:
/// 1. **Downloading**: Spinner, disabled play button
/// 2. **Ready**: Play button enabled, shows duration
/// 3. **Playing**: Pause button, progress bar
/// 4. **Paused**: Play button, current position
class VoicePlayerWidget extends StatefulWidget {
  /// Local file path or remote URL to the voice message
  final String filePath;

  /// Duration in seconds (from message metadata, for display before loading)
  final int? durationSeconds;

  /// Whether this is a local file (true) or needs to be downloaded (false)
  final bool isLocal;

  /// Callback when download is needed
  final Future<String?> Function()? onDownloadRequested;

  /// Background color (inherits from message bubble)
  final Color? backgroundColor;

  const VoicePlayerWidget({
    super.key,
    required this.filePath,
    this.durationSeconds,
    this.isLocal = true,
    this.onDownloadRequested,
    this.backgroundColor,
  });

  @override
  State<VoicePlayerWidget> createState() => _VoicePlayerWidgetState();
}

class _VoicePlayerWidgetState extends State<VoicePlayerWidget> {
  final AudioPlayer _player = AudioPlayer();

  _PlayerState _state = _PlayerState.idle;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  String? _localFilePath;
  double _downloadProgress = 0.0;

  StreamSubscription<PlayerState>? _playerStateSubscription;
  StreamSubscription<Duration>? _positionSubscription;

  @override
  void initState() {
    super.initState();
    _setupPlayer();
  }

  void _setupPlayer() {
    // Listen to player state
    _playerStateSubscription = _player.playerStateStream.listen((state) {
      if (!mounted) return;

      setState(() {
        if (state.processingState == ProcessingState.completed) {
          _state = _PlayerState.ready;
          _position = Duration.zero;
          _player.seek(Duration.zero);
          _player.pause();
        } else if (_player.playing) {
          _state = _PlayerState.playing;
        } else if (_duration > Duration.zero) {
          _state = _PlayerState.ready;
        }
      });
    });

    // Listen to position
    _positionSubscription = _player.positionStream.listen((position) {
      if (!mounted) return;
      setState(() {
        _position = position;
      });
    });

    // Initialize based on whether file is local or needs download
    if (widget.isLocal) {
      _loadLocalFile();
    } else {
      // Show known duration from metadata while in idle state
      if (widget.durationSeconds != null) {
        _duration = Duration(seconds: widget.durationSeconds!);
      }
    }
  }

  Future<void> _loadLocalFile() async {
    final path = _localFilePath ?? widget.filePath;

    // Check if file exists
    final file = File(path);
    if (!await file.exists()) {
      LogService().log('VoicePlayerWidget: File not found: $path');
      return;
    }

    setState(() {
      _state = _PlayerState.loading;
    });

    try {
      final duration = await _player.setFilePath(path);
      if (!mounted) return;

      setState(() {
        _duration = duration ?? Duration.zero;
        _state = _PlayerState.ready;
      });
    } catch (e) {
      LogService().log('VoicePlayerWidget: Failed to load: $e');
      if (mounted) {
        setState(() {
          _state = _PlayerState.idle;
        });
      }
    }
  }

  Future<void> _download() async {
    if (widget.onDownloadRequested == null) return;

    setState(() {
      _state = _PlayerState.downloading;
      _downloadProgress = 0.0;
    });

    // Simulate download progress (actual progress depends on implementation)
    final progressTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      if (!mounted || _state != _PlayerState.downloading) {
        timer.cancel();
        return;
      }
      setState(() {
        _downloadProgress = (_downloadProgress + 0.05).clamp(0.0, 0.9);
      });
    });

    try {
      final localPath = await widget.onDownloadRequested!();
      progressTimer.cancel();

      if (localPath != null && mounted) {
        setState(() {
          _localFilePath = localPath;
          _downloadProgress = 1.0;
        });
        await _loadLocalFile();
      } else if (mounted) {
        setState(() {
          _state = _PlayerState.idle;
        });
      }
    } catch (e) {
      progressTimer.cancel();
      LogService().log('VoicePlayerWidget: Download failed: $e');
      if (mounted) {
        setState(() {
          _state = _PlayerState.idle;
        });
      }
    }
  }

  void _togglePlayPause() {
    if (_state == _PlayerState.idle && !widget.isLocal) {
      // Need to download first
      _download();
      return;
    }

    if (_state == _PlayerState.playing) {
      _player.pause();
    } else if (_state == _PlayerState.ready) {
      _player.play();
    }
  }

  void _seek(double value) {
    final position = Duration(milliseconds: (value * _duration.inMilliseconds).round());
    _player.seek(position);
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _playerStateSubscription?.cancel();
    _positionSubscription?.cancel();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bgColor = widget.backgroundColor ?? theme.colorScheme.surfaceContainerHighest;
    final fgColor = theme.colorScheme.onSurface;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor.withOpacity(0.3),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Play/Pause/Download button
          _buildControlButton(theme, fgColor),

          const SizedBox(width: 8),

          // Progress/Duration
          Flexible(
            child: _buildProgressSection(theme, fgColor),
          ),
        ],
      ),
    );
  }

  Widget _buildControlButton(ThemeData theme, Color fgColor) {
    Widget icon;
    VoidCallback? onPressed;

    switch (_state) {
      case _PlayerState.downloading:
      case _PlayerState.loading:
        icon = SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            value: _state == _PlayerState.downloading ? _downloadProgress : null,
            color: fgColor,
          ),
        );
        onPressed = null;
        break;

      case _PlayerState.playing:
        icon = Icon(Icons.pause, color: fgColor, size: 24);
        onPressed = _togglePlayPause;
        break;

      case _PlayerState.ready:
        icon = Icon(Icons.play_arrow, color: fgColor, size: 24);
        onPressed = _togglePlayPause;
        break;

      case _PlayerState.idle:
        // Show download icon if remote, play if local but not loaded
        if (!widget.isLocal) {
          icon = Icon(Icons.download, color: fgColor, size: 24);
        } else {
          icon = Icon(Icons.play_arrow, color: fgColor.withOpacity(0.5), size: 24);
        }
        onPressed = widget.isLocal ? null : _togglePlayPause;
        break;
    }

    return IconButton(
      icon: icon,
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      splashRadius: 18,
    );
  }

  Widget _buildProgressSection(ThemeData theme, Color fgColor) {
    // Show duration from metadata if not yet loaded
    final displayDuration = _duration > Duration.zero
        ? _duration
        : (widget.durationSeconds != null
            ? Duration(seconds: widget.durationSeconds!)
            : Duration.zero);

    final progress = displayDuration.inMilliseconds > 0
        ? (_position.inMilliseconds / displayDuration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Progress bar (only interactive when ready or playing)
        SliderTheme(
          data: SliderThemeData(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            activeTrackColor: fgColor,
            inactiveTrackColor: fgColor.withOpacity(0.3),
            thumbColor: fgColor,
            overlayColor: fgColor.withOpacity(0.2),
          ),
          child: Slider(
            value: progress,
            onChanged: (_state == _PlayerState.ready || _state == _PlayerState.playing)
                ? _seek
                : null,
          ),
        ),

        // Time display
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _formatDuration(_position),
                style: TextStyle(
                  fontSize: 11,
                  color: fgColor.withOpacity(0.7),
                ),
              ),
              Text(
                _formatDuration(displayDuration),
                style: TextStyle(
                  fontSize: 11,
                  color: fgColor.withOpacity(0.7),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

enum _PlayerState {
  idle,        // Not loaded
  downloading, // Downloading from remote
  loading,     // Loading local file
  ready,       // Ready to play (paused)
  playing,     // Currently playing
}
