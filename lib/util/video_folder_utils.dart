/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io';

/// Centralized utilities for video folder structure and naming conventions.
///
/// Video folder structure:
/// ```
/// videos/
/// ├── {callsign}/                           # User's videos root
/// │   ├── video.txt                         # Optional: channel metadata
/// │   ├── my-first-video/
/// │   │   ├── video.txt                     # Video metadata
/// │   │   ├── thumbnail.jpg                 # Preview image
/// │   │   └── video.mp4                     # Video file (local only)
/// │   ├── travel/                           # Level 1 folder
/// │   │   ├── folder.txt                    # Optional: folder metadata
/// │   │   └── portugal/                     # Level 2 folder
/// │   │       └── lisbon-tour/
/// │   │           ├── video.txt
/// │   │           ├── thumbnail.jpg
/// │   │           └── video.mp4
/// ```
///
/// Maximum folder depth: 5 levels
class VideoFolderUtils {
  VideoFolderUtils._();

  /// Maximum allowed folder depth
  static const int maxFolderDepth = 5;

  /// Video metadata filename
  static const String videoMetadataFile = 'video.txt';

  /// Folder metadata filename
  static const String folderMetadataFile = 'folder.txt';

  /// Supported thumbnail extensions
  static const List<String> thumbnailExtensions = ['jpg', 'jpeg', 'png'];

  /// Supported video extensions
  static const List<String> videoExtensions = [
    'mp4',
    'webm',
    'mov',
    'avi',
    'mkv',
  ];

  /// Build path to videos root for a data directory
  static String buildVideosRootPath(String dataDir) {
    return '$dataDir/videos';
  }

  /// Build path to videos folder for a specific callsign
  static String buildVideosPath(String dataDir, String callsign) {
    return '${buildVideosRootPath(dataDir)}/$callsign';
  }

  /// Build path to a video folder
  ///
  /// [videosPath] - Base path (e.g., videos/CR7BBQ)
  /// [pathSegments] - Folder path segments (e.g., ['travel', 'portugal'])
  /// [videoId] - Video folder name (sanitized title)
  static String buildVideoFolderPath(
    String videosPath,
    List<String> pathSegments,
    String videoId,
  ) {
    if (pathSegments.isEmpty) {
      return '$videosPath/$videoId';
    }
    return '$videosPath/${pathSegments.join('/')}/$videoId';
  }

  /// Build path to video.txt file
  static String buildVideoFilePath(String videoFolderPath) {
    return '$videoFolderPath/$videoMetadataFile';
  }

  /// Build path to thumbnail file
  ///
  /// [ext] - File extension (default: 'png' - media_kit outputs PNG format)
  static String buildThumbnailPath(String videoFolderPath, {String ext = 'png'}) {
    return '$videoFolderPath/thumbnail.$ext';
  }

  /// Build path to folder.txt file
  static String buildFolderFilePath(String folderPath) {
    return '$folderPath/$folderMetadataFile';
  }

  /// Build path to feedback folder for a video
  static String buildFeedbackPath(String videoFolderPath) {
    return '$videoFolderPath/feedback';
  }

  /// Sanitize title for folder name
  ///
  /// Rules from specification:
  /// 1. Convert to lowercase
  /// 2. Replace spaces and underscores with hyphens
  /// 3. Remove non-alphanumeric characters (except hyphens)
  /// 4. Collapse multiple consecutive hyphens
  /// 5. Remove leading/trailing hyphens
  /// 6. Truncate to 50 characters
  static String sanitizeFolderName(String title) {
    String result = title.toLowerCase();

    // Replace spaces and underscores with hyphens
    result = result.replaceAll(RegExp(r'[\s_]+'), '-');

    // Remove non-alphanumeric characters except hyphens
    result = result.replaceAll(RegExp(r'[^a-z0-9-]'), '');

    // Collapse multiple consecutive hyphens
    result = result.replaceAll(RegExp(r'-+'), '-');

    // Remove leading/trailing hyphens
    result = result.replaceAll(RegExp(r'^-+|-+$'), '');

    // Truncate to 50 characters
    if (result.length > 50) {
      result = result.substring(0, 50);
      // Don't end with a hyphen after truncation
      result = result.replaceAll(RegExp(r'-+$'), '');
    }

    // Ensure non-empty result
    if (result.isEmpty) {
      result = 'video';
    }

    return result;
  }

  /// Check if folder depth is valid (max 5 levels)
  static bool isValidFolderDepth(List<String> pathSegments) {
    return pathSegments.length <= maxFolderDepth;
  }

  /// Get folder depth from full path relative to videos root
  static int getFolderDepth(String videosPath, String videoFolderPath) {
    if (!videoFolderPath.startsWith(videosPath)) return -1;

    final relativePath = videoFolderPath.substring(videosPath.length);
    final segments = relativePath
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList();

    // Subtract 1 for the video folder itself
    return segments.length > 0 ? segments.length - 1 : 0;
  }

  /// Extract path segments from full video folder path
  static List<String> extractPathSegments(String videosPath, String videoFolderPath) {
    if (!videoFolderPath.startsWith(videosPath)) return [];

    final relativePath = videoFolderPath.substring(videosPath.length);
    final segments = relativePath
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList();

    // Remove the last segment (video folder itself)
    if (segments.isNotEmpty) {
      segments.removeLast();
    }

    return segments;
  }

  /// Find all video paths recursively in a videos folder
  ///
  /// Returns list of paths to video folders (folders containing video.txt)
  static Future<List<String>> findAllVideoPaths(String videosPath) async {
    final paths = <String>[];
    final dir = Directory(videosPath);

    if (!await dir.exists()) return paths;

    await for (final entity in dir.list(recursive: true)) {
      if (entity is File && entity.path.endsWith('/$videoMetadataFile')) {
        // Extract the video folder path (parent of video.txt)
        final videoFolderPath = entity.path.substring(
          0,
          entity.path.length - videoMetadataFile.length - 1,
        );
        paths.add(videoFolderPath);
      }
    }

    // Sort by path for consistent ordering
    paths.sort();

    return paths;
  }

  /// Find video folder by ID (folder name)
  ///
  /// Searches recursively through all folders
  static Future<String?> findVideoPath(String videosPath, String videoId) async {
    final dir = Directory(videosPath);
    if (!await dir.exists()) return null;

    await for (final entity in dir.list(recursive: true)) {
      if (entity is Directory) {
        final folderName = entity.path.split('/').last;
        if (folderName == videoId) {
          // Check if it contains video.txt
          final videoFile = File('${entity.path}/$videoMetadataFile');
          if (await videoFile.exists()) {
            return entity.path;
          }
        }
      }
    }

    return null;
  }

  /// Find thumbnail file in video folder
  ///
  /// Checks for thumbnail.jpg, thumbnail.jpeg, thumbnail.png
  static Future<String?> findThumbnailPath(String videoFolderPath) async {
    for (final ext in thumbnailExtensions) {
      final path = '$videoFolderPath/thumbnail.$ext';
      if (await File(path).exists()) {
        return path;
      }
    }
    return null;
  }

  /// Find video file in video folder
  ///
  /// Looks for any supported video file extension
  static Future<String?> findVideoMediaPath(String videoFolderPath) async {
    final dir = Directory(videoFolderPath);
    if (!await dir.exists()) return null;

    await for (final entity in dir.list()) {
      if (entity is File) {
        final fileName = entity.path.split('/').last.toLowerCase();
        for (final ext in videoExtensions) {
          if (fileName.endsWith('.$ext') && !fileName.startsWith('thumbnail')) {
            return entity.path;
          }
        }
      }
    }

    return null;
  }

  /// Create video folder structure
  ///
  /// Creates the folder and any necessary parent folders
  static Future<void> createVideoFolder(String videoFolderPath) async {
    final dir = Directory(videoFolderPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  }

  /// List subfolders at a path (non-recursive)
  ///
  /// Returns list of folder names that are not video folders (no video.txt)
  static Future<List<String>> listSubfolders(String folderPath) async {
    final folders = <String>[];
    final dir = Directory(folderPath);

    if (!await dir.exists()) return folders;

    await for (final entity in dir.list()) {
      if (entity is Directory) {
        final folderName = entity.path.split('/').last;
        // Check if it's NOT a video folder (no video.txt)
        final videoFile = File('${entity.path}/$videoMetadataFile');
        if (!await videoFile.exists()) {
          folders.add(folderName);
        }
      }
    }

    folders.sort();
    return folders;
  }

  /// List videos at a path (non-recursive)
  ///
  /// Returns list of video folder names (folders containing video.txt)
  static Future<List<String>> listVideosInFolder(String folderPath) async {
    final videos = <String>[];
    final dir = Directory(folderPath);

    if (!await dir.exists()) return videos;

    await for (final entity in dir.list()) {
      if (entity is Directory) {
        final folderName = entity.path.split('/').last;
        // Check if it IS a video folder (has video.txt)
        final videoFile = File('${entity.path}/$videoMetadataFile');
        if (await videoFile.exists()) {
          videos.add(folderName);
        }
      }
    }

    videos.sort();
    return videos;
  }

  /// Check if a path is a valid video folder
  static Future<bool> isVideoFolder(String path) async {
    final videoFile = File('$path/$videoMetadataFile');
    return await videoFile.exists();
  }

  /// Get MIME type from file extension
  static String getMimeType(String filePath) {
    final ext = filePath.split('.').last.toLowerCase();
    switch (ext) {
      case 'mp4':
        return 'video/mp4';
      case 'webm':
        return 'video/webm';
      case 'mov':
        return 'video/quicktime';
      case 'avi':
        return 'video/x-msvideo';
      case 'mkv':
        return 'video/x-matroska';
      default:
        return 'video/mp4';
    }
  }

  /// Generate unique video folder name
  ///
  /// If folder already exists, appends -2, -3, etc.
  static Future<String> generateUniqueFolderName(
    String parentPath,
    String baseName,
  ) async {
    final sanitized = sanitizeFolderName(baseName);
    var folderName = sanitized;
    var counter = 2;

    while (await Directory('$parentPath/$folderName').exists()) {
      folderName = '$sanitized-$counter';
      counter++;
    }

    return folderName;
  }
}
