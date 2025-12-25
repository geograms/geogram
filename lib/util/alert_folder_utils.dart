import 'dart:io';

import '../util/feedback_folder_utils.dart';

/// Centralized utilities for alert folder structure and naming conventions.
///
/// Alert folder structure:
/// ```
/// devices/{callsign}/alerts/active/{regionFolder}/{folderName}/
///   ├── report.txt
///   ├── feedback/
///   │   ├── points.txt    # Signed NOSTR events (one JSON event per line)
///   │   ├── verifications.txt
///   │   └── comments/
///   │       ├── 2025-12-14_22-15-23_CALLSIGN.txt
///   │       └── ...
///   ├── images/
///   │   ├── photo1.png
///   │   ├── photo2.png
///   │   └── ...
///   └── updates/
/// ```
///
/// - regionFolder: `{lat}_{lon}` rounded to 1 decimal place (e.g., `38.7_-9.1`)
/// - folderName: `YYYY-MM-DD_HH-MM_sanitized-title`
/// - Comment files: `YYYY-MM-DD_HH-MM-SS_AUTHOR.txt`
/// - Photos: `images/photo{N}.{ext}` with sequential numbering
/// - Points: Signed NOSTR events in `feedback/points.txt`
class AlertFolderUtils {
  AlertFolderUtils._();

  /// Calculate region folder from coordinates.
  /// Rounds to 1 decimal place: `{roundedLat}_{roundedLon}`
  ///
  /// Example: `getRegionFolder(38.72, -9.14)` returns `38.7_-9.1`
  static String getRegionFolder(double lat, double lon) {
    final roundedLat = (lat * 10).round() / 10;
    final roundedLon = (lon * 10).round() / 10;
    return '${roundedLat}_$roundedLon';
  }

  /// Build the full path to an alert folder.
  ///
  /// Returns: `{baseDir}/{callsign}/alerts/{status}/{regionFolder}/{folderName}`
  /// where status is 'active' or 'expired'.
  static String buildAlertPath({
    required String baseDir,
    required String callsign,
    required String regionFolder,
    required String folderName,
    bool isExpired = false,
  }) {
    final status = isExpired ? 'expired' : 'active';
    return '$baseDir/$callsign/alerts/$status/$regionFolder/$folderName';
  }

  /// Build alert path from coordinates.
  ///
  /// Convenience method that calculates regionFolder from lat/lon.
  static String buildAlertPathFromCoords({
    required String baseDir,
    required String callsign,
    required double latitude,
    required double longitude,
    required String folderName,
    bool isExpired = false,
  }) {
    final regionFolder = getRegionFolder(latitude, longitude);
    return buildAlertPath(
      baseDir: baseDir,
      callsign: callsign,
      regionFolder: regionFolder,
      folderName: folderName,
      isExpired: isExpired,
    );
  }

  /// Build path to the images subfolder for an alert.
  static String buildImagesPath(String alertPath) {
    return '$alertPath/images';
  }

  /// Build path to the comments subfolder for an alert (feedback/comments).
  static String buildCommentsPath(String alertPath) {
    return FeedbackFolderUtils.buildCommentsPath(alertPath);
  }

  /// Build path to the report.txt file for an alert.
  static String buildReportPath(String alertPath) {
    return '$alertPath/report.txt';
  }

  /// Build path to the feedback points file for an alert.
  static String buildPointsPath(String alertPath) {
    return FeedbackFolderUtils.buildFeedbackFilePath(
      alertPath,
      FeedbackFolderUtils.feedbackTypePoints,
    );
  }

  /// Build path to feedback verifications file for an alert.
  static String buildVerificationsPath(String alertPath) {
    return FeedbackFolderUtils.buildFeedbackFilePath(
      alertPath,
      FeedbackFolderUtils.feedbackTypeVerifications,
    );
  }

  /// Read points from feedback/points.txt.
  /// Returns list of verified npub strings, empty list if file doesn't exist.
  static Future<List<String>> readPointsFile(String alertPath) async {
    return FeedbackFolderUtils.readFeedbackFile(
      alertPath,
      FeedbackFolderUtils.feedbackTypePoints,
    );
  }

  /// Read verifications from feedback/verifications.txt.
  static Future<List<String>> readVerificationsFile(String alertPath) async {
    return FeedbackFolderUtils.readFeedbackFile(
      alertPath,
      FeedbackFolderUtils.feedbackTypeVerifications,
    );
  }

  /// Get the point count for an alert from feedback/points.txt.
  static Future<int> getPointCount(String alertPath) async {
    final points = await readPointsFile(alertPath);
    return points.length;
  }

  /// Check if a user has pointed an alert.
  static Future<bool> hasPointedAlert(String alertPath, String npub) async {
    final points = await readPointsFile(alertPath);
    return points.contains(npub);
  }

  /// Generate a comment filename in the format: `YYYY-MM-DD_HH-MM-SS_AUTHOR.txt`
  ///
  /// Example: `generateCommentFilename(DateTime.now(), 'X1ABC2')` returns
  /// `2025-12-14_22-15-23_X1ABC2.txt`
  static String generateCommentFilename(DateTime timestamp, String author) {
    return '${timestamp.year}-${timestamp.month.toString().padLeft(2, '0')}-${timestamp.day.toString().padLeft(2, '0')}_'
        '${timestamp.hour.toString().padLeft(2, '0')}-${timestamp.minute.toString().padLeft(2, '0')}-${timestamp.second.toString().padLeft(2, '0')}_$author.txt';
  }

  /// Generate comment ID (filename without .txt extension).
  static String generateCommentId(DateTime timestamp, String author) {
    return '${timestamp.year}-${timestamp.month.toString().padLeft(2, '0')}-${timestamp.day.toString().padLeft(2, '0')}_'
        '${timestamp.hour.toString().padLeft(2, '0')}-${timestamp.minute.toString().padLeft(2, '0')}-${timestamp.second.toString().padLeft(2, '0')}_$author';
  }

  /// Generate the next sequential photo filename.
  ///
  /// Scans the images folder and returns `photo{N}.{ext}` where N is the next number.
  static Future<String> getNextPhotoFilename(String alertPath, String extension) async {
    final imagesDir = Directory(buildImagesPath(alertPath));
    int maxNum = 0;

    if (await imagesDir.exists()) {
      await for (final entity in imagesDir.list()) {
        if (entity is File) {
          final filename = entity.path.split('/').last;
          final match = RegExp(r'^photo(\d+)\.').firstMatch(filename);
          if (match != null) {
            final num = int.tryParse(match.group(1)!) ?? 0;
            if (num > maxNum) maxNum = num;
          }
        }
      }
    }

    final cleanExt = extension.startsWith('.') ? extension : '.$extension';
    return 'photo${maxNum + 1}$cleanExt';
  }

  /// Find an alert folder by searching recursively.
  ///
  /// Searches under `alertsDir` for a folder matching `folderName` that contains
  /// a report.txt file. Returns the full path if found, null otherwise.
  ///
  /// This handles the `active/{region}/` folder structure and provides
  /// backwards compatibility with older flat structures.
  static Future<String?> findAlertPath(String alertsDir, String folderName) async {
    final dir = Directory(alertsDir);
    if (!await dir.exists()) return null;

    // Search recursively for the alert folder
    await for (final entity in dir.list(recursive: true)) {
      if (entity is Directory && entity.path.endsWith('/$folderName')) {
        final reportFile = File('${entity.path}/report.txt');
        if (await reportFile.exists()) {
          return entity.path;
        }
      }
    }

    // Also check direct path for backwards compatibility
    final directPath = '$alertsDir/$folderName';
    final directDir = Directory(directPath);
    if (await directDir.exists()) {
      final reportFile = File('$directPath/report.txt');
      if (await reportFile.exists()) {
        return directPath;
      }
    }

    return null;
  }

  /// Find all alert folders recursively and return their paths.
  ///
  /// Returns a list of paths to alert folders (directories containing report.txt).
  static Future<List<String>> findAllAlertPaths(String alertsDir) async {
    final paths = <String>[];
    final dir = Directory(alertsDir);
    if (!await dir.exists()) return paths;

    await for (final entity in dir.list(recursive: true)) {
      if (entity is File && entity.path.endsWith('/report.txt')) {
        // Extract the alert directory path
        final alertPath = entity.path.replaceFirst('/report.txt', '');
        paths.add(alertPath);
      }
    }

    return paths;
  }

  /// Extract region folder from an alert's content by parsing COORDINATES field.
  ///
  /// Returns the region folder string like `38.7_-9.1`, or `0.0_0.0` if not found.
  static String extractRegionFromContent(String content) {
    final coordsRegex = RegExp(r'^COORDINATES:\s*(-?\d+\.?\d*)\s*,\s*(-?\d+\.?\d*)', multiLine: true);
    final match = coordsRegex.firstMatch(content);
    if (match != null) {
      final lat = double.tryParse(match.group(1) ?? '') ?? 0.0;
      final lon = double.tryParse(match.group(2) ?? '') ?? 0.0;
      return getRegionFolder(lat, lon);
    }
    return '0.0_0.0';
  }

  /// Validate that a filename follows the comment format.
  ///
  /// Expected format: `YYYY-MM-DD_HH-MM-SS_XXXXXX.txt`
  static bool isValidCommentFilename(String filename) {
    return RegExp(r'^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}_[A-Za-z0-9]+\.txt$').hasMatch(filename);
  }

  /// Generate a random alphanumeric ID of specified length.
  static String generateRandomId(int length) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final random = DateTime.now().microsecondsSinceEpoch;
    final buffer = StringBuffer();
    for (var i = 0; i < length; i++) {
      buffer.write(chars[(random + i * 7) % chars.length]);
    }
    return buffer.toString();
  }

  /// Generate folder name from title and timestamp.
  ///
  /// Format: `YYYY-MM-DD_HH-MM_sanitized-title`
  static String generateFolderName(DateTime timestamp, String title, {int maxTitleLength = 100}) {
    final sanitized = sanitizeForFolderName(title, maxLength: maxTitleLength);
    return '${timestamp.year}-${timestamp.month.toString().padLeft(2, '0')}-${timestamp.day.toString().padLeft(2, '0')}_'
        '${timestamp.hour.toString().padLeft(2, '0')}-${timestamp.minute.toString().padLeft(2, '0')}_$sanitized';
  }

  /// Sanitize a string for use in folder names.
  ///
  /// Removes special characters and limits length.
  static String sanitizeForFolderName(String input, {int maxLength = 100}) {
    // Truncate first, then sanitize
    var truncated = input.length > maxLength ? input.substring(0, maxLength) : input;

    return truncated
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
  }
}
