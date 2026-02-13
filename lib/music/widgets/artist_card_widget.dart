/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io';

import 'package:flutter/material.dart';

import '../../services/i18n_service.dart';
import '../models/music_artist.dart';

/// A card for displaying an artist
class ArtistCardWidget extends StatelessWidget {
  final MusicArtist artist;
  final bool isSelected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const ArtistCardWidget({
    super.key,
    required this.artist,
    this.isSelected = false,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final i18n = I18nService();

    return Card(
      clipBehavior: Clip.antiAlias,
      color: isSelected ? colorScheme.primaryContainer : null,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Artist artwork (circular) - Expanded to fill available space
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: ClipOval(child: _buildArtwork(colorScheme)),
              ),
            ),
            // Artist info
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                artist.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 8, top: 4),
              child: Text(
                i18n.t('albums_count', params: [artist.albumCount.toString()]),
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildArtwork(ColorScheme colorScheme) {
    if (artist.artwork != null) {
      final file = File(artist.artwork!);
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
          Icons.person,
          size: 48,
          color: colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// A list tile variant for artist display
class ArtistListTile extends StatelessWidget {
  final MusicArtist artist;
  final bool isSelected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget? trailing;

  const ArtistListTile({
    super.key,
    required this.artist,
    this.isSelected = false,
    this.onTap,
    this.onLongPress,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final i18n = I18nService();

    return ListTile(
      selected: isSelected,
      onTap: onTap,
      onLongPress: onLongPress,
      leading: CircleAvatar(
        radius: 24,
        backgroundColor: colorScheme.surfaceContainerHighest,
        backgroundImage: artist.artwork != null
            ? FileImage(File(artist.artwork!))
            : null,
        child: artist.artwork == null
            ? Icon(Icons.person, color: colorScheme.onSurfaceVariant)
            : null,
      ),
      title: Text(artist.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        i18n.t(
          'albums_tracks_count',
          params: [artist.albumCount.toString(), artist.trackCount.toString()],
        ),
        style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
      ),
      trailing: trailing,
    );
  }
}
