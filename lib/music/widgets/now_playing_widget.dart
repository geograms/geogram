/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io';

import 'package:flutter/material.dart' hide RepeatMode;

import '../../services/i18n_service.dart';
import '../models/music_models.dart';
import '../services/music_playback_service.dart';
import 'animated_equalizer_widget.dart';

/// Full-screen now playing view
class NowPlayingWidget extends StatelessWidget {
  final MusicPlaybackService playback;
  final MusicLibrary? library;
  final VoidCallback? onClose;

  const NowPlayingWidget({
    super.key,
    required this.playback,
    this.library,
    this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final i18n = I18nService();
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final screenSize = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.keyboard_arrow_down),
          onPressed: onClose ?? () => Navigator.of(context).pop(),
        ),
        title: Text(i18n.t('now_playing')),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.queue_music),
            onPressed: () {
              _showQueue(context);
            },
          ),
        ],
      ),
      body: StreamBuilder<MusicTrack?>(
        stream: playback.trackStream,
        builder: (context, trackSnapshot) {
          final track = trackSnapshot.data ?? playback.currentTrack;
          if (track == null) {
            return Center(child: Text(i18n.t('no_track_playing')));
          }

          final album = library?.getAlbum(track.albumId ?? '');

          // Calculate artwork size based on available space
          final artworkSize = screenSize.width * 0.6;

          return SafeArea(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Column(
                  children: [
                    // Album artwork
                    Container(
                      width: artworkSize,
                      height: artworkSize,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.3),
                            blurRadius: 20,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: _buildArtwork(album, colorScheme),
                      ),
                    ),
                    const SizedBox(height: 24),
                    // Track info
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Column(
                        children: [
                          Text(
                            track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            track.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 18,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                          if (album != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              album.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 14,
                                color: colorScheme.onSurfaceVariant.withOpacity(
                                  0.7,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    // Progress bar
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: _buildProgressBar(context),
                    ),
                    const SizedBox(height: 16),
                    // Playback controls
                    _buildControls(context),
                    const SizedBox(height: 16),
                    // Volume control
                    _buildVolumeControl(context),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildArtwork(MusicAlbum? album, ColorScheme colorScheme) {
    if (album?.artwork != null) {
      final file = File(album!.artwork!);
      return Image.file(
        file,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) {
          return _buildPlaceholder(colorScheme);
        },
      );
    }
    return _buildPlaceholder(colorScheme);
  }

  Widget _buildPlaceholder(ColorScheme colorScheme) {
    return Container(
      color: colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.music_note,
          size: 80,
          color: colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildProgressBar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return StreamBuilder<Duration>(
      stream: playback.positionStream,
      builder: (context, posSnapshot) {
        return StreamBuilder<Duration>(
          stream: playback.durationStream,
          builder: (context, durSnapshot) {
            final position = posSnapshot.data ?? playback.position;
            final duration = durSnapshot.data ?? playback.duration;
            final progress = duration.inMilliseconds > 0
                ? position.inMilliseconds / duration.inMilliseconds
                : 0.0;

            return Column(
              children: [
                SliderTheme(
                  data: SliderThemeData(
                    trackHeight: 4,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 14,
                    ),
                    activeTrackColor: colorScheme.primary,
                    inactiveTrackColor: colorScheme.surfaceContainerHighest,
                    thumbColor: colorScheme.primary,
                    overlayColor: colorScheme.primary.withOpacity(0.2),
                  ),
                  child: Slider(
                    value: progress.clamp(0.0, 1.0),
                    onChanged: (value) {
                      final newPosition = Duration(
                        milliseconds: (value * duration.inMilliseconds).round(),
                      );
                      playback.seek(newPosition);
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _formatDuration(position),
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        _formatDuration(duration),
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildControls(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return StreamBuilder<PlaybackQueue>(
      stream: playback.queueStream,
      builder: (context, queueSnapshot) {
        final queue = queueSnapshot.data ?? playback.queue;

        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Shuffle button
            IconButton(
              icon: Icon(
                Icons.shuffle,
                color: queue.shuffle
                    ? colorScheme.primary
                    : colorScheme.onSurfaceVariant,
              ),
              onPressed: playback.toggleShuffle,
            ),
            const SizedBox(width: 16),
            // Previous button
            IconButton(
              icon: const Icon(Icons.skip_previous, size: 36),
              onPressed: playback.previous,
            ),
            const SizedBox(width: 8),
            // Play/Pause button
            StreamBuilder<MusicPlaybackState>(
              stream: playback.stateStream,
              builder: (context, stateSnapshot) {
                final state = stateSnapshot.data ?? playback.state;
                final isPlaying = state == MusicPlaybackState.playing;
                final isLoading = state == MusicPlaybackState.loading;

                return Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: colorScheme.primary,
                  ),
                  child: isLoading
                      ? const Center(
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            valueColor: AlwaysStoppedAnimation(Colors.white),
                          ),
                        )
                      : IconButton(
                          icon: Icon(
                            isPlaying ? Icons.pause : Icons.play_arrow,
                            color: colorScheme.onPrimary,
                            size: 40,
                          ),
                          onPressed: () {
                            if (isPlaying) {
                              playback.pause();
                            } else {
                              playback.play();
                            }
                          },
                        ),
                );
              },
            ),
            const SizedBox(width: 8),
            // Next button
            IconButton(
              icon: const Icon(Icons.skip_next, size: 36),
              onPressed: playback.next,
            ),
            const SizedBox(width: 16),
            // Repeat button
            IconButton(
              icon: Icon(
                queue.repeat == RepeatMode.one
                    ? Icons.repeat_one
                    : Icons.repeat,
                color: queue.repeat != RepeatMode.off
                    ? Colors.red
                    : colorScheme.onSurfaceVariant,
              ),
              onPressed: () => _cycleRepeat(context),
            ),
          ],
        );
      },
    );
  }

  Widget _buildVolumeControl(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        children: [
          Icon(Icons.volume_down, color: colorScheme.onSurfaceVariant),
          Expanded(
            child: StreamBuilder<double>(
              stream: playback.volumeStream,
              initialData: playback.volume,
              builder: (context, snapshot) {
                final volume = snapshot.data ?? 1.0;
                return Slider(
                  value: volume,
                  onChanged: (value) => playback.setVolume(value),
                );
              },
            ),
          ),
          Icon(Icons.volume_up, color: colorScheme.onSurfaceVariant),
        ],
      ),
    );
  }

  void _showQueue(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        expand: false,
        builder: (context, scrollController) {
          return _QueueSheet(
            playback: playback,
            library: library,
            scrollController: scrollController,
          );
        },
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
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
}

class _QueueSheet extends StatelessWidget {
  final MusicPlaybackService playback;
  final MusicLibrary? library;
  final ScrollController scrollController;

  const _QueueSheet({
    required this.playback,
    this.library,
    required this.scrollController,
  });

  @override
  Widget build(BuildContext context) {
    final i18n = I18nService();
    final colorScheme = Theme.of(context).colorScheme;

    return StreamBuilder<PlaybackQueue>(
      stream: playback.queueStream,
      builder: (context, snapshot) {
        final queue = snapshot.data ?? playback.queue;

        if (queue.isEmpty) {
          return Center(child: Text(i18n.t('queue_is_empty')));
        }

        return Column(
          children: [
            // Handle
            Container(
              margin: const EdgeInsets.symmetric(vertical: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: colorScheme.onSurfaceVariant.withOpacity(0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    i18n.t('queue_header', params: [queue.length.toString()]),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  TextButton(
                    onPressed: playback.clearQueue,
                    child: Text(i18n.t('clear')),
                  ),
                ],
              ),
            ),
            const Divider(),
            // Queue list
            Expanded(
              child: StreamBuilder<MusicPlaybackState>(
                stream: playback.stateStream,
                initialData: playback.state,
                builder: (context, stateSnapshot) {
                  final isActuallyPlaying =
                      stateSnapshot.data == MusicPlaybackState.playing;

                  return ListView.builder(
                    controller: scrollController,
                    itemCount: queue.trackIds.length,
                    itemBuilder: (context, index) {
                      final trackId = queue.trackIds[index];
                      final track = library?.getTrack(trackId);
                      final isCurrent = index == queue.currentIndex;

                      if (track == null) {
                        return ListTile(
                          title: Text(
                            i18n.t('unknown_track', params: [trackId]),
                          ),
                        );
                      }

                      return ListTile(
                        leading: isCurrent
                            ? AnimatedEqualizerWidget(
                                size: 24,
                                color: colorScheme.primary,
                                isPlaying: isActuallyPlaying,
                              )
                            : Text(
                                '${index + 1}',
                                style: TextStyle(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                        title: Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: isCurrent ? FontWeight.bold : null,
                            color: isCurrent ? colorScheme.primary : null,
                          ),
                        ),
                        subtitle: Text(
                          track.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: isCurrent
                                ? colorScheme.primary.withOpacity(0.7)
                                : colorScheme.onSurfaceVariant,
                          ),
                        ),
                        trailing: Text(
                          track.formattedDuration,
                          style: TextStyle(
                            fontSize: 12,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                        onTap: () {
                          if (isCurrent) {
                            // Toggle play/pause for current track
                            if (isActuallyPlaying) {
                              playback.pause();
                            } else {
                              playback.play();
                            }
                          } else {
                            playback.playTrack(trackId);
                          }
                        },
                      );
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
