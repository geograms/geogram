/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'package:flutter/material.dart';
import '../bot/models/music_track.dart';
import '../services/audio_service.dart';
import '../services/log_service.dart';
import '../services/audio_platform_stub.dart'
    if (dart.library.io) '../services/audio_platform_io.dart';

/// Music player widget for generated music tracks.
/// Displays in chat bubbles with play/pause, progress bar, and track info.
class MusicPlayerWidget extends StatefulWidget {
  /// The music track to play
  final MusicTrack track;

  /// Whether to show the genre label
  final bool showGenre;

  /// Whether to show the model used label
  final bool showModel;

  /// Background color (inherits from message bubble)
  final Color? backgroundColor;

  /// Callback when delete is requested
  final VoidCallback? onDelete;

  const MusicPlayerWidget({
    super.key,
    required this.track,
    this.showGenre = true,
    this.showModel = true,
    this.backgroundColor,
    this.onDelete,
  });

  @override
  State<MusicPlayerWidget> createState() => _MusicPlayerWidgetState();
}

enum _PlayerState { idle, loading, ready, playing, paused }

class _MusicPlayerWidgetState extends State<MusicPlayerWidget> {
  final AudioService _audioService = AudioService();

  _PlayerState _state = _PlayerState.idle;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  Timer? _positionTimer;

  @override
  void initState() {
    super.initState();
    _duration = widget.track.duration;
    _setupPlayer();
    _syncInitialState();
  }

  void _setupPlayer() {
    // Listen to playing state changes
    _playingSubscription = _audioService.playingStream.listen((isPlaying) {
      if (!mounted) return;

      final isOurTrack = _audioService.currentPlaybackPath == widget.track.filePath;

      if (isOurTrack) {
        if (isPlaying) {
          if (_state != _PlayerState.playing) {
            _startPositionTimer();
            setState(() {
              _state = _PlayerState.playing;
            });
          }
          return;
        }

        // Our track stopped or completed - reset to ready
        if (_state == _PlayerState.playing) {
          _stopPositionTimer();
          setState(() {
            _state = _PlayerState.ready;
            _position = Duration.zero;
          });
        } else if (_state == _PlayerState.paused) {
          _stopPositionTimer();
          setState(() {
            _state = _PlayerState.ready;
            _position = Duration.zero;
          });
        }
      } else {
        // A different track is now active - reset our state if we were playing
        if (_state == _PlayerState.playing || _state == _PlayerState.paused) {
          _stopPositionTimer();
          setState(() {
            _state = _PlayerState.ready;
            _position = Duration.zero;
          });
        }
      }
    });

    // Listen to position updates - only update if this is our track
    _positionSubscription = _audioService.positionStream.listen((pos) {
      if (!mounted) return;
      if (_audioService.currentPlaybackPath != widget.track.filePath) return;
      if (_state != _PlayerState.playing) return;

      setState(() {
        _position = pos;
      });
    });
  }

  void _syncInitialState() {
    final isOurTrack =
        _audioService.currentPlaybackPath == widget.track.filePath;
    if (!isOurTrack || !_audioService.isPlaying) return;

    _startPositionTimer();
    setState(() {
      _state = _PlayerState.playing;
      _position = _audioService.position;
    });
  }

  void _startPositionTimer() {
    _positionTimer?.cancel();
    _positionTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted || _state != _PlayerState.playing) return;
      setState(() {
        _position = _audioService.position;
      });
    });
  }

  void _stopPositionTimer() {
    _positionTimer?.cancel();
    _positionTimer = null;
  }

  Future<void> _loadTrack() async {
    final path = widget.track.filePath;

    final file = PlatformFile(path);
    if (!await file.exists()) {
      LogService().log('MusicPlayerWidget: File not found: $path');
      return;
    }

    setState(() {
      _state = _PlayerState.loading;
    });

    try {
      await _audioService.initialize();
      final loadedDuration = await _audioService.load(path);

      if (!mounted) return;

      setState(() {
        _duration = loadedDuration ?? widget.track.duration;
        _state = _PlayerState.ready;
      });
    } catch (e) {
      LogService().log('MusicPlayerWidget: Failed to load: $e');
      if (mounted) {
        setState(() {
          _state = _PlayerState.idle;
        });
      }
    }
  }

  Future<void> _togglePlayPause() async {
    LogService().log('MusicPlayer: _togglePlayPause called, _state=$_state');

    switch (_state) {
      case _PlayerState.idle:
        await _loadTrack();
        if (_state == _PlayerState.ready) {
          await _play();
        }
        break;

      case _PlayerState.ready:
        await _play();
        break;

      case _PlayerState.playing:
        await _pause();
        break;

      case _PlayerState.paused:
        await _resume();
        break;

      case _PlayerState.loading:
        // Ignore while loading
        break;
    }
  }

  Future<void> _play() async {
    setState(() {
      _state = _PlayerState.playing;
    });
    _startPositionTimer();
    await _audioService.play();
  }

  Future<void> _pause() async {
    _stopPositionTimer();
    setState(() {
      _state = _PlayerState.paused;
    });
    await _audioService.pause();
  }

  Future<void> _resume() async {
    setState(() {
      _state = _PlayerState.playing;
    });
    _startPositionTimer();
    await _audioService.play();
  }

  Future<void> _stop() async {
    _stopPositionTimer();
    setState(() {
      _state = _PlayerState.ready;
      _position = Duration.zero;
    });
    await _audioService.stop();
  }

  Future<void> _seek(double value) async {
    final position = Duration(
      milliseconds: (value * _duration.inMilliseconds).round(),
    );
    setState(() {
      _position = position;
    });
    await _audioService.seek(position);
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes;
    final seconds = d.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _playingSubscription?.cancel();
    _positionSubscription?.cancel();
    _positionTimer?.cancel();
    if (_state == _PlayerState.playing || _state == _PlayerState.paused) {
      // Only stop if this widget's track is playing
      if (_audioService.currentPlaybackPath == widget.track.filePath) {
        _audioService.stop();
      }
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bgColor =
        widget.backgroundColor ?? theme.colorScheme.surfaceContainerHighest;
    final fgColor = theme.colorScheme.onSurface;
    final accentColor = theme.colorScheme.primary;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bgColor.withOpacity(0.3),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top row: Play button + time + stop button
          Row(
            children: [
              _buildPlayButton(fgColor, accentColor),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Progress slider
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 6,
                        thumbShape:
                            const RoundSliderThumbShape(enabledThumbRadius: 8),
                        overlayShape:
                            const RoundSliderOverlayShape(overlayRadius: 16),
                        activeTrackColor: accentColor,
                        inactiveTrackColor: fgColor.withOpacity(0.15),
                        thumbColor: accentColor,
                        overlayColor: accentColor.withOpacity(0.2),
                        trackShape: const RoundedRectSliderTrackShape(),
                      ),
                      child: Slider(
                        value: _duration.inMilliseconds > 0
                            ? (_position.inMilliseconds /
                                    _duration.inMilliseconds)
                                .clamp(0.0, 1.0)
                            : 0.0,
                        onChanged: (_state == _PlayerState.playing ||
                                _state == _PlayerState.paused)
                            ? _seek
                            : null,
                      ),
                    ),
                    // Time display
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            _formatDuration(_position),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: fgColor.withOpacity(0.7),
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                          ),
                          Text(
                            _formatDuration(_duration),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: fgColor.withOpacity(0.7),
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if ((_state == _PlayerState.playing ||
                      _state == _PlayerState.paused) &&
                  _audioService.currentPlaybackPath == widget.track.filePath) ...[
                const SizedBox(width: 12),
                Material(
                  color: fgColor.withOpacity(0.15),
                  shape: const CircleBorder(),
                  child: InkWell(
                    onTap: _stop,
                    customBorder: const CircleBorder(),
                    child: SizedBox(
                      width: 40,
                      height: 40,
                      child: Icon(Icons.stop_rounded, color: fgColor, size: 24),
                    ),
                  ),
                ),
              ],
            ],
          ),
          // Bottom row: Genre and model info
          if (widget.showGenre || widget.showModel) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                if (widget.showGenre)
                  _buildChip(
                    icon: Icons.music_note,
                    label: widget.track.genreDisplayName,
                    color: accentColor,
                    theme: theme,
                  ),
                if (widget.showGenre && widget.showModel)
                  const SizedBox(width: 8),
                if (widget.showModel)
                  _buildChip(
                    icon: widget.track.isFMFallback
                        ? Icons.waves
                        : Icons.auto_awesome,
                    label: widget.track.modelDisplayName,
                    color: fgColor.withOpacity(0.6),
                    theme: theme,
                  ),
                const Spacer(),
                if (widget.onDelete != null)
                  IconButton(
                    icon: Icon(Icons.delete_outline,
                        color: fgColor.withOpacity(0.5), size: 18),
                    onPressed: widget.onDelete,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 24, minHeight: 24),
                    splashRadius: 12,
                    tooltip: 'Delete track',
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPlayButton(Color fgColor, Color accentColor) {
    switch (_state) {
      case _PlayerState.loading:
        return Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: accentColor.withOpacity(0.2),
            shape: BoxShape.circle,
          ),
          child: const Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
          ),
        );

      case _PlayerState.playing:
        return Material(
          color: accentColor,
          shape: const CircleBorder(),
          elevation: 4,
          shadowColor: accentColor.withOpacity(0.4),
          child: InkWell(
            onTap: _togglePlayPause,
            customBorder: const CircleBorder(),
            child: const SizedBox(
              width: 52,
              height: 52,
              child: Icon(Icons.pause_rounded, color: Colors.white, size: 32),
            ),
          ),
        );

      case _PlayerState.paused:
      case _PlayerState.ready:
      case _PlayerState.idle:
        return Material(
          color: accentColor,
          shape: const CircleBorder(),
          elevation: 4,
          shadowColor: accentColor.withOpacity(0.4),
          child: InkWell(
            onTap: _togglePlayPause,
            customBorder: const CircleBorder(),
            child: const SizedBox(
              width: 52,
              height: 52,
              child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: 32),
            ),
          ),
        );
    }
  }

  Widget _buildChip({
    required IconData icon,
    required String label,
    required Color color,
    required ThemeData theme,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
