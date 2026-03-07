/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Utility functions for building reader file paths
class ReaderPathUtils {
  ReaderPathUtils._();

  // ============ Root Paths ============

  /// Get the settings file path
  static String settingsFile(String basePath) => '$basePath/settings.json';

  /// Get the progress file path
  static String progressFile(String basePath) => '$basePath/progress.json';

  // ============ RSS Paths ============

  /// Get the RSS category directory
  static String rssDir(String basePath) => '$basePath/rss';

  /// Get a source directory
  static String sourceDir(String basePath, String category, String sourceId) =>
      '$basePath/$category/$sourceId';

  /// Get source.js file
  static String sourceJsFile(
          String basePath, String category, String sourceId) =>
      '${sourceDir(basePath, category, sourceId)}/source.js';

  /// Get source data.json file
  static String sourceDataFile(
          String basePath, String category, String sourceId) =>
      '${sourceDir(basePath, category, sourceId)}/data.json';

  /// Get posts directory for an RSS source
  static String postsDir(String basePath, String sourceId) =>
      '${sourceDir(basePath, 'rss', sourceId)}/posts';

  /// Get a specific post directory
  static String postDir(String basePath, String sourceId, String postSlug) =>
      '${postsDir(basePath, sourceId)}/$postSlug';

  /// Get post data.json file
  static String postDataFile(
          String basePath, String sourceId, String postSlug) =>
      '${postDir(basePath, sourceId, postSlug)}/data.json';

  /// Get post content.md file
  static String postContentFile(
          String basePath, String sourceId, String postSlug) =>
      '${postDir(basePath, sourceId, postSlug)}/content.md';

  /// Get post images directory
  static String postImagesDir(
          String basePath, String sourceId, String postSlug) =>
      '${postDir(basePath, sourceId, postSlug)}/images';

  // ============ Manga Paths ============

  /// Get the manga category directory
  static String mangaDir(String basePath) => '$basePath/manga';

  /// Get series directory for a manga source
  static String seriesDir(String basePath, String sourceId) =>
      '${sourceDir(basePath, 'manga', sourceId)}/series';

  /// Get a specific manga series directory
  static String mangaSeriesDir(
          String basePath, String sourceId, String mangaSlug) =>
      '${seriesDir(basePath, sourceId)}/$mangaSlug';

  /// Get manga data.json file
  static String mangaDataFile(
          String basePath, String sourceId, String mangaSlug) =>
      '${mangaSeriesDir(basePath, sourceId, mangaSlug)}/data.json';

  /// Get manga thumbnail file
  static String mangaThumbnailFile(
          String basePath, String sourceId, String mangaSlug) =>
      '${mangaSeriesDir(basePath, sourceId, mangaSlug)}/thumbnail.jpg';

  // ============ Extensions Paths ============

  /// Get the manga extensions directory (global, not per-series)
  static String extensionsDir(String basePath) =>
      '$basePath/manga/extensions';

  /// Get a specific extension directory
  static String extensionDir(String basePath, String extensionId) =>
      '${extensionsDir(basePath)}/$extensionId';

  // ============ Books Paths ============

  /// Get the books category directory
  static String booksDir(String basePath) => '$basePath/books';

  /// Get folder.json for a books directory
  static String booksFolderFile(String basePath, List<String> folderPath) {
    if (folderPath.isEmpty) {
      return '${booksDir(basePath)}/folder.json';
    }
    return '${booksDir(basePath)}/${folderPath.join('/')}/folder.json';
  }

  // ============ Slug Generation ============

  /// Generate a slug from a title
  static String slugify(String title) {
    return title
        .toLowerCase()
        .replaceAll(RegExp(r'[_\s]+'), '-') // Replace spaces/underscores
        .replaceAll(RegExp(r'[^a-z0-9-]'), '') // Remove special chars
        .replaceAll(RegExp(r'-+'), '-') // Collapse multiple hyphens
        .replaceAll(RegExp(r'^-|-$'), ''); // Remove leading/trailing hyphens
  }

  /// Generate a post slug with date prefix
  static String postSlug(DateTime date, String title) {
    final dateStr = formatDateISO(date);
    final slug = slugify(title);
    // Truncate to 50 chars max
    final truncatedSlug = slug.length > 40 ? slug.substring(0, 40) : slug;
    return '${dateStr}_$truncatedSlug';
  }

  // ============ Date Helpers ============

  /// Format date as YYYY-MM-DD string
  static String formatDateISO(DateTime date) {
    final year = date.year.toString();
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }

  /// Parse YYYY-MM-DD string to DateTime
  static DateTime? parseDateISO(String dateStr) {
    final parts = dateStr.split('-');
    if (parts.length != 3) return null;
    try {
      final year = int.parse(parts[0]);
      final month = int.parse(parts[1]);
      final day = int.parse(parts[2]);
      return DateTime(year, month, day);
    } catch (e) {
      return null;
    }
  }

  // ============ File Helpers ============

  /// Extract date from post folder name (YYYY-MM-DD_slug)
  static DateTime? extractDateFromPostFolder(String folderName) {
    if (folderName.length < 10) return null;
    final dateStr = folderName.substring(0, 10);
    return parseDateISO(dateStr);
  }

  /// Check if a file is a supported book format
  static bool isSupportedBookFormat(String filename) {
    final ext = filename.split('.').last.toLowerCase();
    return ['epub', 'pdf', 'txt', 'md'].contains(ext);
  }

  /// Check if a file is a CBZ manga chapter
  static bool isCbzFile(String filename) {
    return filename.toLowerCase().endsWith('.cbz');
  }

  /// Generate a unique ID
  static String generateId() {
    final now = DateTime.now();
    final random = now.microsecondsSinceEpoch % 1000000;
    return '${now.millisecondsSinceEpoch}_$random';
  }
}
