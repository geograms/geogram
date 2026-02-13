/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';

import '../../services/i18n_service.dart';
import '../models/music_models.dart';
import '../services/music_playback_service.dart';
import 'animated_equalizer_widget.dart';

/// Home tab widget showing most played tracks of the week
class HomeTabWidget extends StatelessWidget {
  final MusicLibrary library;
  final MusicPlaybackService playback;

  const HomeTabWidget({
    super.key,
    required this.library,
    required this.playback,
  });

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final weekAgo = now.subtract(const Duration(days: 7));

    final topTracks = playback.history.getTopTracksInPeriod(weekAgo, now);

    if (topTracks.isEmpty) {
      return _buildEmptyState(context);
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: topTracks.length,
      itemBuilder: (context, index) {
        final entry = topTracks[index];
        final track = library.getTrack(entry.key);
        if (track == null) return const SizedBox.shrink();

        return _TopTrackTile(
          rank: index + 1,
          track: track,
          playCount: entry.value,
          playback: playback,
        );
      },
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final i18n = I18nService();

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.trending_up,
              size: 80,
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 24),
            Text(
              i18n.t('no_plays_this_week'),
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              i18n.t('start_listening_hint'),
              textAlign: TextAlign.center,
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// A tile for displaying a top track with rank and play count
class _TopTrackTile extends StatelessWidget {
  final int rank;
  final MusicTrack track;
  final int playCount;
  final MusicPlaybackService playback;

  const _TopTrackTile({
    required this.rank,
    required this.track,
    required this.playCount,
    required this.playback,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return StreamBuilder<MusicTrack?>(
      stream: playback.trackStream,
      initialData: playback.currentTrack,
      builder: (context, trackSnapshot) {
        final isCurrentTrack = trackSnapshot.data?.id == track.id;

        return StreamBuilder<MusicPlaybackState>(
          stream: playback.stateStream,
          initialData: playback.state,
          builder: (context, stateSnapshot) {
            final isActuallyPlaying =
                isCurrentTrack &&
                stateSnapshot.data == MusicPlaybackState.playing;

            return ListTile(
              onTap: () {
                if (isCurrentTrack) {
                  // Toggle play/pause for current track
                  if (isActuallyPlaying) {
                    playback.pause();
                  } else {
                    playback.play();
                  }
                } else {
                  playback.playTrack(track.id);
                }
              },
              leading: _buildRankBadge(
                colorScheme,
                isCurrentTrack,
                isActuallyPlaying,
              ),
              title: Text(
                track.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: isCurrentTrack
                      ? FontWeight.bold
                      : FontWeight.normal,
                  color: isCurrentTrack ? colorScheme.primary : null,
                ),
              ),
              subtitle: Text(
                track.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: isCurrentTrack
                      ? colorScheme.primary.withValues(alpha: 0.7)
                      : colorScheme.onSurfaceVariant,
                ),
              ),
              trailing: _buildPlayCountBadge(colorScheme),
            );
          },
        );
      },
    );
  }

  Widget _buildRankBadge(
    ColorScheme colorScheme,
    bool isCurrentTrack,
    bool isActuallyPlaying,
  ) {
    Color badgeColor;
    Color textColor;

    if (isCurrentTrack) {
      badgeColor = colorScheme.primaryContainer;
      textColor = colorScheme.primary;
    } else if (rank <= 3) {
      // Gold, silver, bronze for top 3
      switch (rank) {
        case 1:
          badgeColor = const Color(0xFFFFD700).withValues(alpha: 0.2);
          textColor = const Color(0xFFB8860B);
          break;
        case 2:
          badgeColor = const Color(0xFFC0C0C0).withValues(alpha: 0.3);
          textColor = const Color(0xFF808080);
          break;
        case 3:
          badgeColor = const Color(0xFFCD7F32).withValues(alpha: 0.2);
          textColor = const Color(0xFFCD7F32);
          break;
        default:
          badgeColor = colorScheme.surfaceContainerHighest;
          textColor = colorScheme.onSurfaceVariant;
      }
    } else {
      badgeColor = colorScheme.surfaceContainerHighest;
      textColor = colorScheme.onSurfaceVariant;
    }

    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: badgeColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: isCurrentTrack
            ? AnimatedEqualizerWidget(
                size: 20,
                color: textColor,
                isPlaying: isActuallyPlaying,
              )
            : Text(
                '$rank',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: textColor,
                ),
              ),
      ),
    );
  }

  Widget _buildPlayCountBadge(ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.play_arrow,
            size: 14,
            color: colorScheme.onSecondaryContainer,
          ),
          const SizedBox(width: 2),
          Text(
            '$playCount',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: colorScheme.onSecondaryContainer,
            ),
          ),
        ],
      ),
    );
  }
}
