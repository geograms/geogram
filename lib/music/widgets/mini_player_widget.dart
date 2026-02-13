/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart' hide RepeatMode;

import '../../services/i18n_service.dart';
import '../models/music_track.dart';
import '../models/playback_queue.dart';
import '../services/music_playback_service.dart';

/// Mini player bar shown at bottom of screen
class MiniPlayerWidget extends StatelessWidget {
  final MusicPlaybackService playback;
  final VoidCallback? onTap;

  const MiniPlayerWidget({super.key, required this.playback, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return StreamBuilder<MusicTrack?>(
      stream: playback.trackStream,
      builder: (context, trackSnapshot) {
        final track = trackSnapshot.data ?? playback.currentTrack;
        if (track == null) {
          return const SizedBox.shrink();
        }

        return Material(
          elevation: 8,
          color: colorScheme.surfaceContainerHigh,
          child: SafeArea(
            top: false,
            child: InkWell(
              onTap: onTap,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Progress bar
                  StreamBuilder<Duration>(
                    stream: playback.positionStream,
                    builder: (context, posSnapshot) {
                      return StreamBuilder<Duration>(
                        stream: playback.durationStream,
                        builder: (context, durSnapshot) {
                          final position =
                              posSnapshot.data ?? playback.position;
                          final duration =
                              durSnapshot.data ?? playback.duration;
                          final progress = duration.inMilliseconds > 0
                              ? position.inMilliseconds /
                                    duration.inMilliseconds
                              : 0.0;

                          return LinearProgressIndicator(
                            value: progress,
                            minHeight: 2,
                            backgroundColor:
                                colorScheme.surfaceContainerHighest,
                            valueColor: AlwaysStoppedAnimation(
                              colorScheme.primary,
                            ),
                          );
                        },
                      );
                    },
                  ),
                  // Player controls
                  SizedBox(
                    height: 64,
                    child: Row(
                      children: [
                        // Artwork
                        _buildArtwork(track, colorScheme),
                        // Track info
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  track.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                                Text(
                                  track.artist,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        // Volume slider (moved to left of controls)
                        StreamBuilder<double>(
                          stream: playback.volumeStream,
                          initialData: playback.volume,
                          builder: (context, snapshot) {
                            final volume = snapshot.data ?? 1.0;
                            return SizedBox(
                              width: 100,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    volume == 0
                                        ? Icons.volume_off
                                        : volume < 0.5
                                        ? Icons.volume_down
                                        : Icons.volume_up,
                                    size: 20,
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                  Expanded(
                                    child: SliderTheme(
                                      data: SliderThemeData(
                                        trackHeight: 2,
                                        thumbShape: const RoundSliderThumbShape(
                                          enabledThumbRadius: 6,
                                        ),
                                        overlayShape:
                                            const RoundSliderOverlayShape(
                                              overlayRadius: 12,
                                            ),
                                      ),
                                      child: Slider(
                                        value: volume,
                                        onChanged: (value) =>
                                            playback.setVolume(value),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                        // Repeat button
                        StreamBuilder<PlaybackQueue>(
                          stream: playback.queueStream,
                          builder: (context, queueSnapshot) {
                            final queue = queueSnapshot.data ?? playback.queue;
                            return IconButton(
                              icon: _buildRepeatIcon(queue.repeat, colorScheme),
                              onPressed: () => _cycleRepeat(context),
                              tooltip: _getRepeatTooltip(queue.repeat),
                            );
                          },
                        ),
                        // Play/pause button
                        StreamBuilder<MusicPlaybackState>(
                          stream: playback.stateStream,
                          builder: (context, stateSnapshot) {
                            final state = stateSnapshot.data ?? playback.state;
                            final isPlaying =
                                state == MusicPlaybackState.playing;

                            return IconButton(
                              icon: Icon(
                                isPlaying ? Icons.pause : Icons.play_arrow,
                                size: 32,
                              ),
                              onPressed: () {
                                if (isPlaying) {
                                  playback.pause();
                                } else {
                                  playback.play();
                                }
                              },
                            );
                          },
                        ),
                        // Next button
                        IconButton(
                          icon: const Icon(Icons.skip_next),
                          onPressed: playback.hasNext ? playback.next : null,
                        ),
                        const SizedBox(width: 4),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildArtwork(MusicTrack track, ColorScheme colorScheme) {
    // Try to get album artwork
    Widget placeholder = Container(
      width: 64,
      height: 64,
      color: colorScheme.surfaceContainerHighest,
      child: Icon(Icons.music_note, color: colorScheme.onSurfaceVariant),
    );

    // For now, just show placeholder
    // TODO: Load album artwork from track.albumId
    return placeholder;
  }

  Widget _buildRepeatIcon(RepeatMode mode, ColorScheme colorScheme) {
    final Color iconColor;
    final IconData iconData;

    switch (mode) {
      case RepeatMode.off:
        iconColor = colorScheme.onSurfaceVariant;
        iconData = Icons.repeat;
        break;
      case RepeatMode.one:
        iconColor = Colors.red;
        iconData = Icons.repeat_one;
        break;
      case RepeatMode.all:
        iconColor = Colors.red;
        iconData = Icons.repeat;
        break;
    }

    return Icon(iconData, color: iconColor, size: 20);
  }

  void _cycleRepeat(BuildContext context) {
    final i18n = I18nService();
    final currentMode = playback.queue.repeat;
    playback.cycleRepeat();

    // Show snackbar with next mode
    final nextMode =
        RepeatMode.values[(currentMode.index + 1) % RepeatMode.values.length];
    final String message;
    switch (nextMode) {
      case RepeatMode.off:
        message = i18n.t('repeat_disabled');
        break;
      case RepeatMode.one:
        message = i18n.t('repeating_current_track');
        break;
      case RepeatMode.all:
        message = i18n.t('repeating_all_tracks');
        break;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  String _getRepeatTooltip(RepeatMode mode) {
    final i18n = I18nService();
    switch (mode) {
      case RepeatMode.off:
        return i18n.t('repeat_off');
      case RepeatMode.one:
        return i18n.t('repeat_one');
      case RepeatMode.all:
        return i18n.t('repeat_all');
    }
  }
}
