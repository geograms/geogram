/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

/// Video player widget for local video playback
/// Uses media_kit for cross-platform support (Windows, Linux, macOS, Android, iOS)
class VideoPlayerWidget extends StatefulWidget {
  final String videoPath;
  final bool autoPlay;
  final bool showControls;
  final VoidCallback? onFullscreenToggle;

  const VideoPlayerWidget({
    super.key,
    required this.videoPath,
    this.autoPlay = false,
    this.showControls = true,
    this.onFullscreenToggle,
  });

  @override
  State<VideoPlayerWidget> createState() => _VideoPlayerWidgetState();
}

class _VideoPlayerWidgetState extends State<VideoPlayerWidget> {
  Player? _player;
  VideoController? _controller;
  bool _isInitialized = false;
  bool _isPlaying = false;
  bool _showOverlay = true;
  bool _isFullscreen = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _volume = 1.0;
  bool _isMuted = false;
  String? _errorMessage;
  Timer? _hideOverlayTimer;
  static const _overlayHideDelay = Duration(seconds: 5);

  final List<StreamSubscription> _subscriptions = [];

  @override
  void initState() {
    super.initState();
    _initializePlayer();
    _startHideOverlayTimer();
  }

  @override
  void dispose() {
    _hideOverlayTimer?.cancel();
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _player?.dispose();
    super.dispose();
  }

  /// Start or restart the timer to hide overlay after inactivity
  void _startHideOverlayTimer() {
    _hideOverlayTimer?.cancel();
    _hideOverlayTimer = Timer(_overlayHideDelay, () {
      if (mounted && _isPlaying) {
        setState(() {
          _showOverlay = false;
        });
      }
    });
  }

  /// Show overlay and restart hide timer
  void _onUserInteraction() {
    setState(() {
      _showOverlay = true;
    });
    _startHideOverlayTimer();
  }

  @override
  void didUpdateWidget(VideoPlayerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoPath != widget.videoPath) {
      _player?.dispose();
      for (final sub in _subscriptions) {
        sub.cancel();
      }
      _subscriptions.clear();
      _initializePlayer();
    }
  }

  Future<void> _initializePlayer() async {
    final file = File(widget.videoPath);
    if (!await file.exists()) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Video file not found';
        _isInitialized = false;
      });
      return;
    }

    if (!mounted) return;

    try {
      _player = Player();
      _controller = VideoController(_player!);

      // Listen to player state changes
      _subscriptions.add(
        _player!.stream.playing.listen((playing) {
          if (mounted) {
            setState(() => _isPlaying = playing);
          }
        }),
      );

      _subscriptions.add(
        _player!.stream.position.listen((position) {
          if (mounted) {
            setState(() => _position = position);
          }
        }),
      );

      _subscriptions.add(
        _player!.stream.duration.listen((duration) {
          if (mounted) {
            setState(() => _duration = duration);
          }
        }),
      );

      _subscriptions.add(
        _player!.stream.volume.listen((volume) {
          if (mounted) {
            setState(() {
              _volume = volume / 100.0;
              _isMuted = volume == 0;
            });
          }
        }),
      );

      _subscriptions.add(
        _player!.stream.error.listen((error) {
          if (mounted && error.isNotEmpty) {
            setState(() => _errorMessage = error);
          }
        }),
      );

      // Open the media file
      await _player!.open(Media(widget.videoPath));

      if (!mounted) return;

      setState(() {
        _isInitialized = true;
        _errorMessage = null;
      });

      if (widget.autoPlay) {
        _player?.play();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Failed to load video: $e';
        _isInitialized = false;
      });
    }
  }

  void _togglePlayPause() {
    if (_player == null) return;
    _player!.playOrPause();
  }

  void _seekTo(Duration position) {
    _player?.seek(position);
  }

  void _seekForward() {
    if (_player == null) return;
    final newPosition = _position + const Duration(seconds: 10);
    _seekTo(newPosition > _duration ? _duration : newPosition);
  }

  void _seekBackward() {
    if (_player == null) return;
    final newPosition = _position - const Duration(seconds: 10);
    _seekTo(newPosition < Duration.zero ? Duration.zero : newPosition);
  }

  void _toggleMute() {
    if (_player == null) return;

    if (_isMuted) {
      _player!.setVolume(_volume * 100);
    } else {
      _player!.setVolume(0);
    }

    setState(() {
      _isMuted = !_isMuted;
    });
  }

  void _setVolume(double value) {
    if (_player == null) return;
    _player!.setVolume(value * 100);
    setState(() {
      _volume = value;
      _isMuted = value == 0;
    });
  }

  void _toggleFullscreen() async {
    setState(() {
      _isFullscreen = !_isFullscreen;
      _showOverlay = !_isFullscreen;
    });

    // Auto-play when entering fullscreen
    if (_isFullscreen && _player != null && !_isPlaying) {
      _player!.play();
    }

    // Desktop: use window_manager for true fullscreen
    if (!kIsWeb && (Platform.isLinux || Platform.isWindows || Platform.isMacOS)) {
      await windowManager.setFullScreen(_isFullscreen);
    } else {
      // Mobile: use orientation and system UI mode
      if (_isFullscreen) {
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      } else {
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      }
    }

    widget.onFullscreenToggle?.call();
  }

  /// Take a screenshot of current video frame
  /// Returns PNG-encoded bytes or null on failure
  Future<Uint8List?> takeScreenshot() async {
    if (_player == null) return null;
    return await _player!.screenshot();
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        _isFullscreen) {
      _toggleFullscreen();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_errorMessage != null) {
      return _buildErrorState(theme);
    }

    if (!_isInitialized || _controller == null) {
      return _buildLoadingState(theme);
    }

    return KeyboardListener(
      focusNode: FocusNode(),
      autofocus: _isFullscreen,
      onKeyEvent: _handleKeyEvent,
      child: MouseRegion(
        onHover: (_) => _onUserInteraction(),
        onEnter: (_) => _onUserInteraction(),
        child: GestureDetector(
          onTap: _onUserInteraction,
          onPanDown: (_) => _onUserInteraction(),
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Video
              Video(
                controller: _controller!,
                controls: NoVideoControls,
              ),
              // Controls overlay
              if (widget.showControls && _showOverlay) _buildControlsOverlay(theme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingState(ThemeData theme) {
    return Container(
      color: Colors.black,
      child: const Center(
        child: CircularProgressIndicator(color: Colors.white),
      ),
    );
  }

  Widget _buildErrorState(ThemeData theme) {
    return Container(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              color: theme.colorScheme.error,
              size: 48,
            ),
            const SizedBox(height: 16),
            Text(
              _errorMessage ?? 'Unknown error',
              style: const TextStyle(color: Colors.white),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _initializePlayer,
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControlsOverlay(ThemeData theme) {
    // In fullscreen mode, only show the exit fullscreen button
    if (_isFullscreen) {
      return _buildFullscreenOverlay();
    }

    return Container(
      color: Colors.black.withValues(alpha: 0.4),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Top bar spacer
          const SizedBox(height: 48),
          // Center play/pause area
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Rewind 10s
              IconButton(
                icon: const Icon(Icons.replay_10, color: Colors.white, size: 36),
                onPressed: _seekBackward,
              ),
              const SizedBox(width: 24),
              // Play/Pause
              IconButton(
                icon: Icon(
                  _isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
                  color: Colors.white,
                  size: 64,
                ),
                onPressed: _togglePlayPause,
              ),
              const SizedBox(width: 24),
              // Forward 10s
              IconButton(
                icon: const Icon(Icons.forward_10, color: Colors.white, size: 36),
                onPressed: _seekForward,
              ),
            ],
          ),
          // Bottom bar (progress, volume, time)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              children: [
                // Progress bar
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 4,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                    activeTrackColor: theme.colorScheme.primary,
                    inactiveTrackColor: Colors.white.withValues(alpha: 0.3),
                    thumbColor: theme.colorScheme.primary,
                  ),
                  child: Slider(
                    value: _duration.inMilliseconds > 0
                        ? (_position.inMilliseconds / _duration.inMilliseconds)
                            .clamp(0.0, 1.0)
                        : 0,
                    onChanged: (value) {
                      final newPosition = Duration(
                        milliseconds: (value * _duration.inMilliseconds).round(),
                      );
                      _seekTo(newPosition);
                    },
                  ),
                ),
                // Time and volume controls
                Row(
                  children: [
                    // Current time / Total time
                    Text(
                      '${_formatDuration(_position)} / ${_formatDuration(_duration)}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                      ),
                    ),
                    const Spacer(),
                    // Mute button
                    IconButton(
                      icon: Icon(
                        _isMuted ? Icons.volume_off : Icons.volume_up,
                        color: Colors.white,
                        size: 20,
                      ),
                      onPressed: _toggleMute,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                    // Volume slider
                    SizedBox(
                      width: 80,
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 2,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 4),
                          overlayShape: const RoundSliderOverlayShape(overlayRadius: 8),
                          activeTrackColor: Colors.white,
                          inactiveTrackColor: Colors.white.withValues(alpha: 0.3),
                          thumbColor: Colors.white,
                        ),
                        child: Slider(
                          value: _isMuted ? 0 : _volume,
                          onChanged: _setVolume,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    // Fullscreen button
                    IconButton(
                      icon: const Icon(
                        Icons.fullscreen,
                        color: Colors.white,
                        size: 22,
                      ),
                      onPressed: _toggleFullscreen,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Fullscreen overlay with full controls and exit button
  Widget _buildFullscreenOverlay() {
    final theme = Theme.of(context);
    return Container(
      color: Colors.black.withValues(alpha: 0.4),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Top bar with exit fullscreen
          Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: IconButton(
                icon: const Icon(
                  Icons.fullscreen_exit,
                  color: Colors.white,
                  size: 32,
                ),
                onPressed: _toggleFullscreen,
              ),
            ),
          ),
          // Center play/pause area
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.replay_10, color: Colors.white, size: 36),
                onPressed: _seekBackward,
              ),
              const SizedBox(width: 24),
              IconButton(
                icon: Icon(
                  _isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
                  color: Colors.white,
                  size: 64,
                ),
                onPressed: _togglePlayPause,
              ),
              const SizedBox(width: 24),
              IconButton(
                icon: const Icon(Icons.forward_10, color: Colors.white, size: 36),
                onPressed: _seekForward,
              ),
            ],
          ),
          // Bottom bar (progress, time, exit fullscreen)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 4,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                    activeTrackColor: theme.colorScheme.primary,
                    inactiveTrackColor: Colors.white.withValues(alpha: 0.3),
                    thumbColor: theme.colorScheme.primary,
                  ),
                  child: Slider(
                    value: _duration.inMilliseconds > 0
                        ? (_position.inMilliseconds / _duration.inMilliseconds)
                            .clamp(0.0, 1.0)
                        : 0,
                    onChanged: (value) {
                      final newPosition = Duration(
                        milliseconds: (value * _duration.inMilliseconds).round(),
                      );
                      _seekTo(newPosition);
                    },
                  ),
                ),
                Row(
                  children: [
                    Text(
                      '${_formatDuration(_position)} / ${_formatDuration(_duration)}',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(
                        Icons.fullscreen_exit,
                        color: Colors.white,
                        size: 22,
                      ),
                      onPressed: _toggleFullscreen,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact video player for preview/thumbnail with play overlay
class VideoPreviewWidget extends StatelessWidget {
  final String? thumbnailPath;
  final String formattedDuration;
  final VoidCallback onPlay;

  const VideoPreviewWidget({
    super.key,
    this.thumbnailPath,
    required this.formattedDuration,
    required this.onPlay,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasThumbnail = thumbnailPath != null && thumbnailPath!.isNotEmpty;

    return GestureDetector(
      onTap: onPlay,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Thumbnail or placeholder
          if (hasThumbnail)
            Image.file(
              File(thumbnailPath!),
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) =>
                  _buildPlaceholder(theme),
            )
          else
            _buildPlaceholder(theme),
          // Play button overlay
          Center(
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.play_arrow,
                color: Colors.white,
                size: 48,
              ),
            ),
          ),
          // Duration overlay
          Positioned(
            bottom: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                formattedDuration,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaceholder(ThemeData theme) {
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
    );
  }
}
