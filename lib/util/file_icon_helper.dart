import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

/// Helper class for file type icons
class FileIconHelper {
  /// Get icon for a file based on its extension
  static IconData getIconForFile(String fileName) {
    final extension = path.extension(fileName).toLowerCase();

    switch (extension) {
      // Images
      case '.jpg':
      case '.jpeg':
      case '.png':
      case '.gif':
      case '.bmp':
      case '.webp':
      case '.svg':
        return Icons.image;

      // Videos
      case '.mp4':
      case '.avi':
      case '.mkv':
      case '.mov':
      case '.wmv':
      case '.flv':
      case '.webm':
        return Icons.video_file;

      // Audio
      case '.mp3':
      case '.wav':
      case '.flac':
      case '.aac':
      case '.ogg':
      case '.m4a':
        return Icons.audio_file;

      // Documents
      case '.pdf':
        return Icons.picture_as_pdf;
      case '.doc':
      case '.docx':
        return Icons.description;
      case '.txt':
      case '.md':
      case '.log':
        return Icons.text_snippet;
      case '.html':
      case '.htm':
        return Icons.language;

      // Spreadsheets
      case '.xls':
      case '.xlsx':
      case '.csv':
        return Icons.table_chart;

      // Presentations
      case '.ppt':
      case '.pptx':
        return Icons.slideshow;

      // Archives
      case '.zip':
      case '.rar':
      case '.7z':
      case '.tar':
      case '.gz':
        return Icons.folder_zip;

      // Code files
      case '.dart':
      case '.java':
      case '.js':
      case '.ts':
      case '.py':
      case '.cpp':
      case '.c':
      case '.h':
      case '.go':
      case '.rs':
      case '.swift':
      case '.kt':
        return Icons.code;
      case '.json':
      case '.xml':
      case '.yaml':
      case '.yml':
        return Icons.data_object;

      // Executables
      case '.exe':
      case '.app':
      case '.apk':
      case '.dmg':
        return Icons.android;

      // Default
      default:
        return Icons.insert_drive_file;
    }
  }

  /// Get color for file icon based on file type
  static Color getColorForFile(String fileName, BuildContext context) {
    final extension = path.extension(fileName).toLowerCase();

    switch (extension) {
      // Images - purple
      case '.jpg':
      case '.jpeg':
      case '.png':
      case '.gif':
      case '.bmp':
      case '.webp':
      case '.svg':
        return Colors.purple;

      // Videos - red
      case '.mp4':
      case '.avi':
      case '.mkv':
      case '.mov':
      case '.wmv':
      case '.flv':
      case '.webm':
        return Colors.red;

      // Audio - orange
      case '.mp3':
      case '.wav':
      case '.flac':
      case '.aac':
      case '.ogg':
      case '.m4a':
        return Colors.orange;

      // PDF - red
      case '.pdf':
        return Colors.red.shade700;

      // Word - blue
      case '.doc':
      case '.docx':
        return Colors.blue.shade700;

      // Excel - green
      case '.xls':
      case '.xlsx':
      case '.csv':
        return Colors.green.shade700;

      // PowerPoint - orange
      case '.ppt':
      case '.pptx':
        return Colors.orange.shade700;

      // Archives - amber
      case '.zip':
      case '.rar':
      case '.7z':
      case '.tar':
      case '.gz':
        return Colors.amber.shade700;

      // Code - cyan
      case '.dart':
      case '.java':
      case '.js':
      case '.ts':
      case '.py':
      case '.cpp':
      case '.c':
      case '.h':
      case '.go':
      case '.rs':
      case '.swift':
      case '.kt':
      case '.json':
      case '.xml':
      case '.yaml':
      case '.yml':
        return Colors.cyan.shade700;

      // Text - gray
      case '.txt':
      case '.md':
      case '.log':
        return Colors.grey.shade600;

      // HTML - blue
      case '.html':
      case '.htm':
        return Colors.blue.shade600;

      // Default
      default:
        return Theme.of(context).colorScheme.secondary;
    }
  }

  /// Check if file is an image that can have thumbnail
  static bool canGenerateThumbnail(String fileName) {
    final extension = path.extension(fileName).toLowerCase();
    return const [
      '.jpg',
      '.jpeg',
      '.png',
      '.gif',
      '.bmp',
      '.webp',
    ].contains(extension);
  }

  /// Check if file is a video
  static bool isVideo(String fileName) {
    final extension = path.extension(fileName).toLowerCase();
    return const [
      '.mp4',
      '.avi',
      '.mkv',
      '.mov',
      '.wmv',
      '.flv',
      '.webm',
    ].contains(extension);
  }

  /// Check if file is an image
  static bool isImage(String fileName) {
    final extension = path.extension(fileName).toLowerCase();
    return const [
      '.jpg',
      '.jpeg',
      '.png',
      '.gif',
      '.bmp',
      '.webp',
      '.svg',
    ].contains(extension);
  }
}
