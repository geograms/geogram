/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io';

import 'package:flutter/material.dart';

import '../../services/i18n_service.dart';
import '../models/music_album.dart';

/// Callback for fetching album artwork
typedef FetchArtworkCallback = Future<String?> Function(MusicAlbum album);

/// A card for displaying an album
class AlbumCardWidget extends StatefulWidget {
  final MusicAlbum album;
  final bool isSelected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final FetchArtworkCallback? onFetchArtwork;

  const AlbumCardWidget({
    super.key,
    required this.album,
    this.isSelected = false,
    this.onTap,
    this.onLongPress,
    this.onFetchArtwork,
  });

  @override
  State<AlbumCardWidget> createState() => _AlbumCardWidgetState();
}

class _AlbumCardWidgetState extends State<AlbumCardWidget> {
  String? _artworkPath;
  bool _isFetching = false;
  bool _fetchAttempted = false;

  @override
  void initState() {
    super.initState();
    _artworkPath = widget.album.artwork;
    _tryFetchArtwork();
  }

  @override
  void didUpdateWidget(AlbumCardWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.album.id != widget.album.id) {
      _artworkPath = widget.album.artwork;
      _fetchAttempted = false;
      _tryFetchArtwork();
    } else if (widget.album.artwork != null && _artworkPath == null) {
      // Album was updated with artwork
      _artworkPath = widget.album.artwork;
    }
  }

  void _tryFetchArtwork() {
    if (_artworkPath == null &&
        !_isFetching &&
        !_fetchAttempted &&
        widget.onFetchArtwork != null) {
      _fetchAttempted = true;
      _isFetching = true;

      widget.onFetchArtwork!(widget.album).then((path) {
        if (mounted && path != null) {
          setState(() {
            _artworkPath = path;
            _isFetching = false;
          });
        } else if (mounted) {
          setState(() {
            _isFetching = false;
          });
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      clipBehavior: Clip.antiAlias,
      color: widget.isSelected ? colorScheme.primaryContainer : null,
      child: InkWell(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Album artwork - Expanded to fill available space
            Expanded(child: _buildArtwork(colorScheme)),
            // Album info
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.album.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    widget.album.artist +
                        (widget.album.year != null
                            ? ' (${widget.album.year})'
                            : ''),
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
    if (_artworkPath != null) {
      final file = File(_artworkPath!);
      return Image.file(
        file,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) {
          return _buildPlaceholder(colorScheme);
        },
      );
    }
    if (_isFetching) {
      return _buildLoadingPlaceholder(colorScheme);
    }
    return _buildPlaceholder(colorScheme);
  }

  Widget _buildPlaceholder(ColorScheme colorScheme) {
    return Container(
      color: colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(Icons.album, size: 48, color: colorScheme.onSurfaceVariant),
      ),
    );
  }

  Widget _buildLoadingPlaceholder(ColorScheme colorScheme) {
    return Container(
      color: colorScheme.surfaceContainerHighest,
      child: Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// A list tile variant for album display
class AlbumListTile extends StatefulWidget {
  final MusicAlbum album;
  final bool isSelected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget? trailing;
  final FetchArtworkCallback? onFetchArtwork;

  const AlbumListTile({
    super.key,
    required this.album,
    this.isSelected = false,
    this.onTap,
    this.onLongPress,
    this.trailing,
    this.onFetchArtwork,
  });

  @override
  State<AlbumListTile> createState() => _AlbumListTileState();
}

class _AlbumListTileState extends State<AlbumListTile> {
  String? _artworkPath;
  bool _isFetching = false;
  bool _fetchAttempted = false;

  @override
  void initState() {
    super.initState();
    _artworkPath = widget.album.artwork;
    _tryFetchArtwork();
  }

  @override
  void didUpdateWidget(AlbumListTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.album.id != widget.album.id) {
      _artworkPath = widget.album.artwork;
      _fetchAttempted = false;
      _tryFetchArtwork();
    } else if (widget.album.artwork != null && _artworkPath == null) {
      _artworkPath = widget.album.artwork;
    }
  }

  void _tryFetchArtwork() {
    if (_artworkPath == null &&
        !_isFetching &&
        !_fetchAttempted &&
        widget.onFetchArtwork != null) {
      _fetchAttempted = true;
      _isFetching = true;

      widget.onFetchArtwork!(widget.album).then((path) {
        if (mounted && path != null) {
          setState(() {
            _artworkPath = path;
            _isFetching = false;
          });
        } else if (mounted) {
          setState(() {
            _isFetching = false;
          });
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final i18n = I18nService();

    return ListTile(
      selected: widget.isSelected,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: 48,
          height: 48,
          child: _buildArtwork(colorScheme),
        ),
      ),
      title: Text(
        widget.album.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${widget.album.artist}${widget.album.year != null ? ' (${widget.album.year})' : ''}'
        ' - ${i18n.t('tracks_count', params: [widget.album.trackCount.toString()])}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
      ),
      trailing: widget.trailing,
    );
  }

  Widget _buildArtwork(ColorScheme colorScheme) {
    if (_artworkPath != null) {
      final file = File(_artworkPath!);
      return Image.file(
        file,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) {
          return _buildPlaceholder(colorScheme);
        },
      );
    }
    if (_isFetching) {
      return Container(
        color: colorScheme.surfaceContainerHighest,
        child: const Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return _buildPlaceholder(colorScheme);
  }

  Widget _buildPlaceholder(ColorScheme colorScheme) {
    return Container(
      color: colorScheme.surfaceContainerHighest,
      child: Icon(Icons.album, size: 24, color: colorScheme.onSurfaceVariant),
    );
  }
}
