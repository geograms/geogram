/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../services/i18n_service.dart';
import '../models/music_models.dart';
import '../services/music_playback_service.dart';
import 'album_card_widget.dart';

/// Callback for adding a music folder
typedef AddFolderCallback = Future<void> Function();

/// Folder browser widget with grid cards
class FolderBrowserWidget extends StatefulWidget {
  final MusicLibrary library;
  final MusicPlaybackService playback;
  final List<String> sourceFolders;
  final FetchArtworkCallback? onFetchArtwork;
  final AddFolderCallback? onAddFolder;
  final void Function(MusicAlbum album)? onOpenAlbum;

  const FolderBrowserWidget({
    super.key,
    required this.library,
    required this.playback,
    required this.sourceFolders,
    this.onFetchArtwork,
    this.onAddFolder,
    this.onOpenAlbum,
  });

  @override
  State<FolderBrowserWidget> createState() => _FolderBrowserWidgetState();
}

class _FolderBrowserWidgetState extends State<FolderBrowserWidget> {
  // Navigation stack stores folder paths, not full nodes
  final List<String> _navigationStack = [];

  @override
  void didUpdateWidget(FolderBrowserWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sourceFolders != widget.sourceFolders) {
      // Reset navigation when source folders change
      setState(() {
        _navigationStack.clear();
      });
    }
  }

  String? get _currentFolderPath =>
      _navigationStack.isNotEmpty ? _navigationStack.last : null;

  /// Get current folder contents lazily
  MusicFolderContents? get _currentContents {
    if (_currentFolderPath == null) return null;
    return widget.library.getFolderContents(_currentFolderPath!);
  }

  /// Get root folders (source folders that have music)
  List<MusicFolderNode> get _rootFolders {
    final nodes = <MusicFolderNode>[];
    for (final sourceFolder in widget.sourceFolders) {
      // Check if this source folder has any music
      final hasMusic = widget.library.albums.any(
        (a) =>
            a.folderPath == sourceFolder ||
            p.isWithin(sourceFolder, a.folderPath),
      );

      if (hasMusic) {
        // Count tracks in this source folder
        var trackCount = 0;
        for (final album in widget.library.albums) {
          if (album.folderPath == sourceFolder ||
              p.isWithin(sourceFolder, album.folderPath)) {
            trackCount += album.trackCount;
          }
        }

        // Find artwork
        String? artwork = _findFolderArtwork(sourceFolder);
        if (artwork == null) {
          // Use first album's artwork
          for (final album in widget.library.albums) {
            if (album.folderPath == sourceFolder ||
                p.isWithin(sourceFolder, album.folderPath)) {
              if (album.artwork != null) {
                artwork = album.artwork;
                break;
              }
            }
          }
        }

        nodes.add(
          MusicFolderNode(
            path: sourceFolder,
            name: p.basename(sourceFolder),
            totalTrackCount: trackCount,
            artwork: artwork,
          ),
        );
      }
    }
    return nodes;
  }

  String? _findFolderArtwork(String folderPath) {
    const artworkFiles = [
      'cover.jpg',
      'cover.png',
      'artwork.jpg',
      'artwork.png',
      'folder.jpg',
      'folder.png',
    ];
    for (final filename in artworkFiles) {
      final file = File(p.join(folderPath, filename));
      if (file.existsSync()) {
        return file.path;
      }
    }
    return null;
  }

  void _navigateToFolder(MusicFolderNode folder) {
    setState(() {
      _navigationStack.add(folder.path);
    });
  }

  void _navigateBack() {
    if (_navigationStack.isNotEmpty) {
      setState(() {
        _navigationStack.removeLast();
      });
    }
  }

  void _playAll() {
    final tracks = _currentFolderPath != null
        ? widget.library.getTracksInFolder(_currentFolderPath!)
        : widget.library.tracks;

    if (tracks.isNotEmpty) {
      widget.playback.playTracks(tracks);
    }
  }

  void _shuffleAll() {
    final tracks = _currentFolderPath != null
        ? widget.library.getTracksInFolder(_currentFolderPath!)
        : widget.library.tracks;

    if (tracks.isNotEmpty) {
      final shuffled = List<MusicTrack>.from(tracks)..shuffle();
      widget.playback.playTracks(shuffled);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.sourceFolders.isEmpty) {
      return _buildEmptyState(context);
    }

    // Get contents based on current navigation level
    final List<MusicFolderNode> subfolders;
    final List<MusicAlbum> albums;

    if (_currentFolderPath == null) {
      // At root level - show source folders
      subfolders = _rootFolders;
      albums = [];
    } else {
      // Inside a folder - load contents lazily
      final contents = _currentContents;
      subfolders = contents?.subfolders ?? [];
      albums = contents?.albums ?? [];
    }

    if (subfolders.isEmpty && albums.isEmpty && _currentFolderPath == null) {
      return _buildEmptyState(context);
    }

    return PopScope(
      canPop: _navigationStack.isEmpty,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _navigationStack.isNotEmpty) {
          _navigateBack();
        }
      },
      child: Column(
        children: [
          // Navigation bar
          if (_currentFolderPath != null) _buildNavigationBar(context),
          // Action buttons (only when in a folder)
          if (_currentFolderPath != null) _buildActionButtons(context),
          // Grid content
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(8),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 180,
                childAspectRatio: 0.75,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              itemCount: subfolders.length + albums.length,
              itemBuilder: (context, index) {
                if (index < subfolders.length) {
                  return _FolderCardWidget(
                    folder: subfolders[index],
                    onTap: () => _navigateToFolder(subfolders[index]),
                  );
                } else {
                  final album = albums[index - subfolders.length];
                  return AlbumCardWidget(
                    album: album,
                    onTap: () => widget.onOpenAlbum?.call(album),
                    onFetchArtwork: widget.onFetchArtwork,
                  );
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavigationBar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final i18n = I18nService();
    final folderName = p.basename(_currentFolderPath!);

    // Calculate track count for current folder
    final trackCount = widget.library
        .getTracksInFolder(_currentFolderPath!)
        .length;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      color: colorScheme.surfaceContainerLow,
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _navigateBack,
            tooltip: i18n.t('back'),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              folderName,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            i18n.t('tracks_count', params: [trackCount.toString()]),
            style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons(BuildContext context) {
    final i18n = I18nService();
    return StreamBuilder<MusicPlaybackState>(
      stream: widget.playback.stateStream,
      initialData: widget.playback.state,
      builder: (context, snapshot) {
        final isPlaying =
            snapshot.data == MusicPlaybackState.playing ||
            snapshot.data == MusicPlaybackState.paused ||
            snapshot.data == MusicPlaybackState.loading;

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: isPlaying ? _stopPlayback : _playAll,
                  icon: Icon(isPlaying ? Icons.stop : Icons.play_arrow),
                  label: Text(isPlaying ? i18n.t('stop') : i18n.t('play_all')),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _shuffleAll,
                  icon: const Icon(Icons.shuffle),
                  label: Text(i18n.t('shuffle')),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _stopPlayback() {
    widget.playback.stop();
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
              Icons.folder_open,
              size: 80,
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 24),
            Text(
              i18n.t('no_music_folders'),
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              i18n.t('add_folder_to_browse'),
              textAlign: TextAlign.center,
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
            if (widget.onAddFolder != null) ...[
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: widget.onAddFolder,
                icon: const Icon(Icons.folder_open),
                label: Text(i18n.t('add_music_folder')),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A card for displaying a folder
class _FolderCardWidget extends StatelessWidget {
  final MusicFolderNode folder;
  final VoidCallback? onTap;

  const _FolderCardWidget({required this.folder, this.onTap});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final i18n = I18nService();

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Folder artwork or icon
            Expanded(child: _buildArtwork(colorScheme)),
            // Folder info
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    folder.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    i18n.t(
                      'tracks_count',
                      params: [folder.totalTrackCount.toString()],
                    ),
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
          ],
        ),
      ),
    );
  }

  Widget _buildArtwork(ColorScheme colorScheme) {
    if (folder.artwork != null) {
      final file = File(folder.artwork!);
      return Stack(
        fit: StackFit.expand,
        children: [
          Image.file(
            file,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) {
              return _buildPlaceholder(colorScheme);
            },
          ),
          // Folder overlay icon
          Positioned(
            right: 8,
            top: 8,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: colorScheme.surface.withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Icon(Icons.folder, size: 16, color: colorScheme.primary),
            ),
          ),
        ],
      );
    }
    return _buildPlaceholder(colorScheme);
  }

  Widget _buildPlaceholder(ColorScheme colorScheme) {
    return Container(
      color: colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(Icons.folder, size: 48, color: colorScheme.primary),
      ),
    );
  }
}
