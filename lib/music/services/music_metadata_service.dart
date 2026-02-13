/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io';

import 'package:path/path.dart' as path;

import '../../services/i18n_service.dart';
import '../../services/log_service.dart';
import '../utils/music_path_utils.dart';

/// Extracted metadata from an audio file
class TrackMetadata {
  final String title;
  final String artist;
  final String? album;
  final String? albumArtist;
  final int? trackNumber;
  final int? discNumber;
  final int? year;
  final String? genre;
  final int durationSeconds;
  final int? bitrateKbps;
  final int? sampleRateHz;
  final int? channels;
  final int fileSizeBytes;
  final bool hasEmbeddedArtwork;
  final DateTime? modifiedAt;

  TrackMetadata({
    required this.title,
    required this.artist,
    this.album,
    this.albumArtist,
    this.trackNumber,
    this.discNumber,
    this.year,
    this.genre,
    required this.durationSeconds,
    this.bitrateKbps,
    this.sampleRateHz,
    this.channels,
    required this.fileSizeBytes,
    this.hasEmbeddedArtwork = false,
    this.modifiedAt,
  });
}

/// Service for extracting metadata from audio files
class MusicMetadataService {
  final LogService _log = LogService();

  /// Extract metadata from an audio file
  /// Currently uses filename-based extraction as a baseline.
  /// TODO: Integrate with a proper audio metadata library (like flutter_media_metadata)
  Future<TrackMetadata?> extractMetadata(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;

      final stat = await file.stat();
      final fileName = path.basename(filePath);
      final folderName = path.basename(path.dirname(filePath));
      final parentFolderName = path.basename(
        path.dirname(path.dirname(filePath)),
      );

      // Extract title from filename
      String title = MusicPathUtils.extractTitleFromFilename(fileName);
      if (title.isEmpty) {
        title = path.basenameWithoutExtension(fileName);
      }

      // Try to extract artist from folder structure
      // Common patterns: "Artist/Album/Track.mp3" or "Artist - Album/Track.mp3"
      final unknownArtistLabel = I18nService().tOrDefault(
        'unknown_artist',
        'Unknown Artist',
      );
      String artist = unknownArtistLabel;
      String? album;

      // Check if folder name contains " - " (Artist - Album pattern)
      if (folderName.contains(' - ')) {
        final parts = folderName.split(' - ');
        if (parts.length >= 2) {
          artist = parts[0].trim();
          album = parts.sublist(1).join(' - ').trim();
        }
      } else {
        // Assume Artist/Album structure
        album = folderName;
        artist = parentFolderName;

        // Clean up generic folder names
        if (_isGenericFolderName(artist)) {
          artist = unknownArtistLabel;
        }
        if (_isGenericFolderName(album)) {
          album = null;
        }
      }

      // Extract track number from filename
      final trackNumber = MusicPathUtils.extractTrackNumber(fileName);

      // Extract year from album folder name (e.g., "Album (1973)" or "Album [1973]")
      int? year;
      if (album != null) {
        final yearMatch = RegExp(r'[\(\[](19|20)\d{2}[\)\]]').firstMatch(album);
        if (yearMatch != null) {
          year = int.tryParse(
            yearMatch.group(0)!.replaceAll(RegExp(r'[\(\)\[\]]'), ''),
          );
          // Clean year from album name
          album = album.replaceAll(yearMatch.group(0)!, '').trim();
        }
      }

      // Estimate duration based on file size (rough approximation)
      // Average: MP3 ~128kbps = 16KB/s, FLAC ~1000kbps = 125KB/s
      int estimatedDuration;
      final ext = path.extension(filePath).toLowerCase();
      if (ext == '.flac' || ext == '.wav' || ext == '.aiff') {
        // Lossless: assume ~1000kbps
        estimatedDuration = (stat.size / (125 * 1024)).round();
      } else {
        // Lossy: assume ~256kbps average
        estimatedDuration = (stat.size / (32 * 1024)).round();
      }

      // Ensure reasonable duration (1 second to 1 hour)
      estimatedDuration = estimatedDuration.clamp(1, 3600);

      return TrackMetadata(
        title: title,
        artist: artist,
        album: album,
        albumArtist: artist,
        trackNumber: trackNumber,
        discNumber: null,
        year: year,
        genre: null,
        durationSeconds: estimatedDuration,
        bitrateKbps: null,
        sampleRateHz: null,
        channels: null,
        fileSizeBytes: stat.size,
        hasEmbeddedArtwork: false,
        modifiedAt: stat.modified,
      );
    } catch (e) {
      _log.log(
        'MusicMetadataService: Error extracting metadata from $filePath: $e',
      );
      return null;
    }
  }

  /// Check if a folder name is generic and shouldn't be used as artist/album
  bool _isGenericFolderName(String name) {
    final lower = name.toLowerCase();
    final genericNames = [
      'music',
      'songs',
      'audio',
      'downloads',
      'download',
      'my music',
      'desktop',
      'documents',
      'home',
      'user',
      'users',
      'media',
      'storage',
      'external',
      'internal',
      'sdcard',
      'emulated',
      '0',
    ];
    return genericNames.contains(lower) || lower.isEmpty;
  }

  /// Extract embedded artwork from audio file
  /// Returns bytes of the artwork image, or null if none found
  Future<List<int>?> extractArtwork(String filePath) async {
    // TODO: Implement using flutter_media_metadata or similar
    // For now, return null (no embedded artwork extraction)
    return null;
  }
}
