/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

import '../../services/i18n_service.dart';
import '../../services/log_service.dart';
import '../models/music_models.dart';
import '../utils/music_path_utils.dart';
import 'music_storage_service.dart';
import 'music_metadata_service.dart';

/// Scan progress callback
typedef ScanProgressCallback =
    void Function(int scanned, int total, String? currentFile);

/// Service for scanning and managing the music library
class MusicLibraryService {
  final MusicStorageService storage;
  final MusicMetadataService metadata;
  final LogService _log = LogService();

  MusicLibrary _library = MusicLibrary();
  bool _isScanning = false;

  MusicLibraryService({required this.storage, MusicMetadataService? metadata})
    : metadata = metadata ?? MusicMetadataService();

  /// Get current library
  MusicLibrary get library => _library;

  /// Whether currently scanning
  bool get isScanning => _isScanning;

  /// Load library from storage
  Future<MusicLibrary> loadLibrary() async {
    _library = await storage.loadLibrary();
    return _library;
  }

  /// Save library to storage
  Future<void> saveLibrary() async {
    await storage.saveLibrary(_library);
  }

  /// Scan source folders for music
  Future<MusicLibrary> scanFolders(
    List<String> sourceFolders, {
    ScanProgressCallback? onProgress,
    MusicSettings? settings,
  }) async {
    if (_isScanning) {
      _log.log('MusicLibraryService: Already scanning');
      return _library;
    }

    _isScanning = true;
    final stopwatch = Stopwatch()..start();

    try {
      _log.log(
        'MusicLibraryService: Starting scan of ${sourceFolders.length} folders',
      );
      final i18n = I18nService();
      final unknownArtistLabel = i18n.tOrDefault(
        'unknown_artist',
        'Unknown Artist',
      );
      final variousArtistsLabel = i18n.tOrDefault(
        'various_artists',
        'Various Artists',
      );

      // First pass: collect all audio files
      final audioFiles = <String>[];
      for (final folder in sourceFolders) {
        final dir = Directory(folder);
        if (!await dir.exists()) {
          _log.log('MusicLibraryService: Folder not found: $folder');
          continue;
        }

        await for (final entity in dir.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is File && MusicPathUtils.isAudioFile(entity.path)) {
            audioFiles.add(entity.path);
          }
        }
      }

      _log.log('MusicLibraryService: Found ${audioFiles.length} audio files');

      // Group files by folder (album)
      final albumFolders = <String, List<String>>{};
      for (final file in audioFiles) {
        final folder = path.dirname(file);
        albumFolders.putIfAbsent(folder, () => []).add(file);
      }

      _log.log(
        'MusicLibraryService: Found ${albumFolders.length} album folders',
      );

      // Process each album folder
      final tracks = <MusicTrack>[];
      final albums = <String, MusicAlbum>{};
      final artists = <String, MusicArtist>{};

      int scanned = 0;
      final total = audioFiles.length;

      for (final entry in albumFolders.entries) {
        final folderPath = entry.key;
        final files = entry.value;

        // Process tracks in this album folder
        final albumTracks = <MusicTrack>[];
        String? albumTitle;
        String? albumArtist;
        int? albumYear;
        String? albumGenre;
        Set<String> trackArtists = {};

        for (final filePath in files) {
          scanned++;
          onProgress?.call(scanned, total, filePath);

          try {
            final trackMetadata = await metadata.extractMetadata(filePath);
            if (trackMetadata == null) continue;

            // Generate IDs
            final trackId = MusicPathUtils.generateTrackId(filePath);
            final artistId = MusicArtist.generateId(trackMetadata.artist);
            final albumId = MusicPathUtils.generateAlbumId(folderPath);

            // Create track
            final track = MusicTrack(
              id: trackId,
              filePath: filePath,
              title: trackMetadata.title,
              artist: trackMetadata.artist,
              artistId: artistId,
              album: trackMetadata.album,
              albumId: albumId,
              albumArtist: trackMetadata.albumArtist,
              trackNumber: trackMetadata.trackNumber,
              discNumber: trackMetadata.discNumber,
              year: trackMetadata.year,
              genre: trackMetadata.genre,
              durationSeconds: trackMetadata.durationSeconds,
              bitrateKbps: trackMetadata.bitrateKbps,
              sampleRateHz: trackMetadata.sampleRateHz,
              channels: trackMetadata.channels,
              format: MusicTrack.formatFromExtension(filePath),
              fileSizeBytes: trackMetadata.fileSizeBytes,
              hasEmbeddedArtwork: trackMetadata.hasEmbeddedArtwork,
              modifiedAt: trackMetadata.modifiedAt,
              addedAt: DateTime.now(),
            );

            tracks.add(track);
            albumTracks.add(track);

            // Collect album metadata from first track with data
            albumTitle ??= trackMetadata.album;
            albumArtist ??= trackMetadata.albumArtist ?? trackMetadata.artist;
            albumYear ??= trackMetadata.year;
            albumGenre ??= trackMetadata.genre;
            trackArtists.add(trackMetadata.artist);

            // Build artist entry
            if (!artists.containsKey(artistId)) {
              artists[artistId] = MusicArtist(
                id: artistId,
                name: trackMetadata.artist,
                albumCount: 0,
                trackCount: 0,
              );
            }
            artists[artistId] = artists[artistId]!.copyWith(
              trackCount: artists[artistId]!.trackCount + 1,
            );
          } catch (e) {
            _log.log('MusicLibraryService: Error processing $filePath: $e');
          }
        }

        if (albumTracks.isEmpty) continue;

        // Create album
        final albumId = MusicPathUtils.generateAlbumId(folderPath);
        final artistId = albumArtist != null
            ? MusicArtist.generateId(albumArtist)
            : null;

        // Determine if compilation (multiple artists)
        final isCompilation = trackArtists.length >= 3;

        // Find cover art (local first, then online if enabled)
        String? artwork = await _findCoverArt(folderPath);
        ArtworkSource artworkSource = artwork != null
            ? ArtworkSource.folder
            : ArtworkSource.none;

        // If no local cover and auto-fetch enabled, try online
        if (artwork == null &&
            settings != null &&
            settings.online.autoFetchCovers) {
          final artist = isCompilation
              ? variousArtistsLabel
              : (albumArtist ?? unknownArtistLabel);
          final title = albumTitle ?? path.basename(folderPath);
          artwork = await _fetchCoverArt(artist, title, albumId);
          if (artwork != null) {
            artworkSource = ArtworkSource.downloaded;
          }
        }

        // Calculate total duration
        final totalDuration = albumTracks.fold(
          0,
          (sum, t) => sum + t.durationSeconds,
        );

        // Determine disc count
        final discNumbers = albumTracks.map((t) => t.discNumber ?? 1).toSet();
        final discCount = discNumbers.isEmpty ? 1 : discNumbers.length;

        final album = MusicAlbum(
          id: albumId,
          title: albumTitle ?? path.basename(folderPath),
          artist: isCompilation
              ? variousArtistsLabel
              : (albumArtist ?? unknownArtistLabel),
          artistId: artistId,
          year: albumYear,
          genre: albumGenre,
          trackCount: albumTracks.length,
          totalDurationSeconds: totalDuration,
          folderPath: folderPath,
          artwork: artwork,
          artworkSource: artworkSource,
          discCount: discCount,
          isCompilation: isCompilation,
          addedAt: DateTime.now(),
        );

        albums[albumId] = album;

        // Update artist album count
        if (artistId != null && artists.containsKey(artistId)) {
          artists[artistId] = artists[artistId]!.copyWith(
            albumCount: artists[artistId]!.albumCount + 1,
          );
        }
      }

      stopwatch.stop();

      // Calculate stats
      final stats = LibraryStats(
        totalTracks: tracks.length,
        totalAlbums: albums.length,
        totalArtists: artists.length,
        totalDurationSeconds: tracks.fold(
          0,
          (sum, t) => sum + t.durationSeconds,
        ),
        totalSizeBytes: tracks.fold(0, (sum, t) => sum + t.fileSizeBytes),
      );

      _library = MusicLibrary(
        version: '1.0',
        lastScan: DateTime.now(),
        scanDurationSeconds: stopwatch.elapsed.inSeconds,
        stats: stats,
        artists: artists.values.toList()
          ..sort((a, b) => a.sortKey.compareTo(b.sortKey)),
        albums: albums.values.toList()
          ..sort((a, b) => a.title.compareTo(b.title)),
        tracks: tracks,
      );

      await saveLibrary();

      _log.log(
        'MusicLibraryService: Scan complete - ${tracks.length} tracks, '
        '${albums.length} albums, ${artists.length} artists '
        'in ${stopwatch.elapsed.inSeconds}s',
      );

      return _library;
    } finally {
      _isScanning = false;
    }
  }

  /// Find cover art in album folder
  Future<String?> _findCoverArt(String folderPath) async {
    // Check standard cover art filenames
    for (final name in MusicPathUtils.coverArtNames) {
      final coverPath = path.join(folderPath, name);
      if (await File(coverPath).exists()) {
        return coverPath;
      }
    }

    // Fallback: find any image file
    try {
      final dir = Directory(folderPath);
      await for (final entity in dir.list()) {
        if (entity is File && MusicPathUtils.isImageFile(entity.path)) {
          return entity.path;
        }
      }
    } catch (e) {
      // Ignore errors
    }

    return null;
  }

  /// Fetch cover art from Cover Art Archive (MusicBrainz)
  Future<String?> _fetchCoverArt(
    String artist,
    String album,
    String albumId,
  ) async {
    try {
      // Search MusicBrainz for release
      final query = Uri.encodeComponent('$artist $album');
      final searchUrl =
          'https://musicbrainz.org/ws/2/release?query=$query&limit=1&fmt=json';

      _log.log('MusicLibraryService: Fetching cover for $artist - $album');

      final searchResponse = await http
          .get(
            Uri.parse(searchUrl),
            headers: {
              'User-Agent': 'Geogram/1.0 (https://github.com/geograms/geogram)',
            },
          )
          .timeout(const Duration(seconds: 10));

      if (searchResponse.statusCode != 200) {
        _log.log(
          'MusicLibraryService: MusicBrainz search failed: ${searchResponse.statusCode}',
        );
        return null;
      }

      final data = jsonDecode(searchResponse.body);
      final releases = data['releases'] as List?;
      if (releases == null || releases.isEmpty) {
        _log.log('MusicLibraryService: No releases found for $artist - $album');
        return null;
      }

      final mbid = releases[0]['id'] as String?;
      if (mbid == null) return null;

      // Fetch cover from Cover Art Archive
      final coverUrl = 'https://coverartarchive.org/release/$mbid/front-500';
      final coverResponse = await http
          .get(Uri.parse(coverUrl))
          .timeout(const Duration(seconds: 15));

      if (coverResponse.statusCode != 200) {
        _log.log(
          'MusicLibraryService: Cover Art Archive returned ${coverResponse.statusCode}',
        );
        return null;
      }

      // Cache the artwork
      final cachedPath = await storage.cacheArtwork(
        albumId,
        coverResponse.bodyBytes,
      );
      if (cachedPath != null) {
        _log.log('MusicLibraryService: Cached cover art for $artist - $album');
      }
      return cachedPath;
    } catch (e) {
      _log.log(
        'MusicLibraryService: Failed to fetch cover for $artist - $album: $e',
      );
      return null;
    }
  }

  /// Fetch artwork for a specific album (on-demand)
  /// Returns the artwork path if successful, null otherwise
  Future<String?> fetchAlbumArtwork(MusicAlbum album) async {
    // Skip if already has artwork
    if (album.artwork != null) return album.artwork;

    final artworkPath = await _fetchCoverArt(
      album.artist,
      album.title,
      album.id,
    );
    if (artworkPath != null) {
      // Update the album in the library
      final updatedAlbum = album.copyWith(
        artwork: artworkPath,
        artworkSource: ArtworkSource.downloaded,
      );

      // Update library
      final albumIndex = _library.albums.indexWhere((a) => a.id == album.id);
      if (albumIndex >= 0) {
        _library.albums[albumIndex] = updatedAlbum;
        // Save library in background (don't await)
        saveLibrary();
      }
    }
    return artworkPath;
  }

  /// Get tracks for an album
  List<MusicTrack> getAlbumTracks(String albumId) {
    return _library.getAlbumTracks(albumId);
  }

  /// Get albums for an artist
  List<MusicAlbum> getArtistAlbums(String artistId) {
    return _library.getArtistAlbums(artistId);
  }

  /// Search tracks by query
  List<MusicTrack> searchTracks(String query) {
    if (query.isEmpty) return [];

    final lowerQuery = query.toLowerCase();
    return _library.tracks.where((t) {
      return t.title.toLowerCase().contains(lowerQuery) ||
          t.artist.toLowerCase().contains(lowerQuery) ||
          (t.album?.toLowerCase().contains(lowerQuery) ?? false);
    }).toList();
  }

  /// Search albums by query
  List<MusicAlbum> searchAlbums(String query) {
    if (query.isEmpty) return [];

    final lowerQuery = query.toLowerCase();
    return _library.albums.where((a) {
      return a.title.toLowerCase().contains(lowerQuery) ||
          a.artist.toLowerCase().contains(lowerQuery);
    }).toList();
  }

  /// Search artists by query
  List<MusicArtist> searchArtists(String query) {
    if (query.isEmpty) return [];

    final lowerQuery = query.toLowerCase();
    return _library.artists.where((a) {
      return a.name.toLowerCase().contains(lowerQuery);
    }).toList();
  }
}
