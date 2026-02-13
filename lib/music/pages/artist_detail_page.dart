/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io';

import 'package:flutter/material.dart';

import '../../services/i18n_service.dart';
import '../models/music_models.dart';
import '../services/music_playback_service.dart';
import '../widgets/music_widgets.dart';
import 'album_detail_page.dart';

/// Artist detail page showing albums
class ArtistDetailPage extends StatelessWidget {
  final MusicArtist artist;
  final MusicLibrary library;
  final MusicPlaybackService playback;
  final I18nService i18n;
  final FetchArtworkCallback? onFetchArtwork;

  const ArtistDetailPage({
    super.key,
    required this.artist,
    required this.library,
    required this.playback,
    required this.i18n,
    this.onFetchArtwork,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final albums = library.getArtistAlbums(artist.id);

    // Get all tracks by this artist
    final allTracks = library.tracks
        .where((t) => t.artistId == artist.id)
        .toList();

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          // App bar with artist image
          SliverAppBar(
            expandedHeight: 250,
            pinned: true,
            flexibleSpace: FlexibleSpaceBar(
              title: Text(
                artist.name,
                style: const TextStyle(
                  shadows: [Shadow(blurRadius: 10, color: Colors.black)],
                ),
              ),
              background: Stack(
                fit: StackFit.expand,
                children: [
                  // Artist image or first album artwork
                  if (artist.artwork != null)
                    Image.file(
                      File(artist.artwork!),
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) {
                        return _buildPlaceholder(colorScheme, albums);
                      },
                    )
                  else
                    _buildPlaceholder(colorScheme, albums),
                  // Gradient overlay
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Colors.black54],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.shuffle),
                onPressed: allTracks.isNotEmpty
                    ? () {
                        playback.playTracks(allTracks);
                        playback.toggleShuffle();
                      }
                    : null,
                tooltip: i18n.t('shuffle_all'),
              ),
            ],
          ),
          // Artist info
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    i18n.t(
                      'albums_dash_tracks',
                      params: [
                        artist.albumCount.toString(),
                        artist.trackCount.toString(),
                      ],
                    ),
                    style: TextStyle(color: colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 16),
                  // Play all button
                  Row(
                    children: [
                      FilledButton.icon(
                        onPressed: allTracks.isNotEmpty
                            ? () {
                                playback.playTracks(allTracks);
                              }
                            : null,
                        icon: const Icon(Icons.play_arrow),
                        label: Text(i18n.t('play_all')),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: allTracks.isNotEmpty
                            ? () {
                                for (final track in allTracks) {
                                  playback.addToQueue(track.id);
                                }
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      i18n.t(
                                        'added_tracks_to_queue',
                                        params: [allTracks.length.toString()],
                                      ),
                                    ),
                                  ),
                                );
                              }
                            : null,
                        icon: const Icon(Icons.playlist_add),
                        label: Text(i18n.t('add_to_queue')),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          // Albums section header
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(
                i18n.t('albums'),
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: colorScheme.onSurface,
                ),
              ),
            ),
          ),
          // Albums grid
          if (albums.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  i18n.t('no_albums_found'),
                  style: TextStyle(color: colorScheme.onSurfaceVariant),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 180,
                  childAspectRatio: 0.75,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                ),
                delegate: SliverChildBuilderDelegate((context, index) {
                  final album = albums[index];
                  return AlbumCardWidget(
                    album: album,
                    onFetchArtwork: onFetchArtwork,
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => AlbumDetailPage(
                            album: album,
                            library: library,
                            playback: playback,
                            i18n: i18n,
                            onFetchArtwork: onFetchArtwork,
                          ),
                        ),
                      );
                    },
                  );
                }, childCount: albums.length),
              ),
            ),
          // All tracks section header
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
              child: Text(
                i18n.t('all_tracks'),
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: colorScheme.onSurface,
                ),
              ),
            ),
          ),
          // All tracks list
          SliverList(
            delegate: SliverChildBuilderDelegate((context, index) {
              final track = allTracks[index];
              return StreamBuilder<MusicTrack?>(
                stream: playback.trackStream,
                builder: (context, trackSnapshot) {
                  final isCurrentTrack =
                      (trackSnapshot.data?.id ?? playback.currentTrack?.id) ==
                      track.id;
                  return StreamBuilder<MusicPlaybackState>(
                    stream: playback.stateStream,
                    initialData: playback.state,
                    builder: (context, stateSnapshot) {
                      final isActuallyPlaying =
                          isCurrentTrack &&
                          stateSnapshot.data == MusicPlaybackState.playing;
                      return TrackTileWidget(
                        track: track,
                        showAlbum: true,
                        showTrackNumber: false,
                        isPlaying: isCurrentTrack,
                        isActuallyPlaying: isActuallyPlaying,
                        onTap: () {
                          if (isCurrentTrack) {
                            // Toggle play/pause for current track
                            if (isActuallyPlaying) {
                              playback.pause();
                            } else {
                              playback.play();
                            }
                          } else {
                            playback.playTracks(allTracks, startIndex: index);
                          }
                        },
                      );
                    },
                  );
                },
              );
            }, childCount: allTracks.length),
          ),
          // Bottom padding for mini player
          const SliverPadding(padding: EdgeInsets.only(bottom: 80)),
        ],
      ),
      bottomNavigationBar: MiniPlayerWidget(
        playback: playback,
        onTap: () {
          showModalBottomSheet(
            context: context,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            builder: (context) => SizedBox(
              height: MediaQuery.of(context).size.height * 0.9,
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(16),
                ),
                child: NowPlayingWidget(playback: playback, library: library),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildPlaceholder(ColorScheme colorScheme, List<MusicAlbum> albums) {
    // Try to use first album's artwork as fallback
    final firstAlbumWithArt = albums
        .where((a) => a.artwork != null)
        .firstOrNull;

    if (firstAlbumWithArt?.artwork != null) {
      return Image.file(
        File(firstAlbumWithArt!.artwork!),
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) {
          return _buildIconPlaceholder(colorScheme);
        },
      );
    }

    return _buildIconPlaceholder(colorScheme);
  }

  Widget _buildIconPlaceholder(ColorScheme colorScheme) {
    return Container(
      color: colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.person,
          size: 80,
          color: colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
