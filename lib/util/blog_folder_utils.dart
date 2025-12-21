/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io';

import '../models/blog_comment.dart';

/// Centralized utilities for blog folder structure and naming conventions.
///
/// Blog folder structure:
/// ```
/// blog/                     # Blog collection root
/// ├── {year}/
/// │   └── {postId}/
/// │       ├── post.md       # Blog post content
/// │       ├── files/        # Attached files (optional)
/// │       │   ├── {sha1}_file.pdf
/// │       │   └── ...
/// │       └── comments/
/// │           ├── 2025-01-15_10-30-45_CALLSIGN.txt
/// │           └── ...
/// ```
///
/// - postId: `YYYY-MM-DD_sanitized-title`
/// - Comment files: `YYYY-MM-DD_HH-MM-SS_AUTHOR.txt`
class BlogFolderUtils {
  BlogFolderUtils._();

  /// Build the full path to a blog post folder.
  ///
  /// Returns: `{blogPath}/{year}/{postId}`
  static String buildPostFolderPath(String blogPath, int year, String postId) {
    return '$blogPath/$year/$postId';
  }

  /// Build path to the post.md file for a blog post.
  static String buildPostFilePath(String postFolderPath) {
    return '$postFolderPath/post.md';
  }

  /// Build path to the comments subfolder for a blog post.
  static String buildCommentsPath(String postFolderPath) {
    return '$postFolderPath/comments';
  }

  /// Build path to the files subfolder for a blog post.
  static String buildFilesPath(String postFolderPath) {
    return '$postFolderPath/files';
  }

  /// Generate a comment filename in the format: `YYYY-MM-DD_HH-MM-SS_AUTHOR.txt`
  ///
  /// Example: `generateCommentFilename(DateTime.now(), 'X1ABC2')` returns
  /// `2025-01-15_10-30-45_X1ABC2.txt`
  static String generateCommentFilename(DateTime timestamp, String author) {
    return '${timestamp.year}-${timestamp.month.toString().padLeft(2, '0')}-${timestamp.day.toString().padLeft(2, '0')}_'
        '${timestamp.hour.toString().padLeft(2, '0')}-${timestamp.minute.toString().padLeft(2, '0')}-${timestamp.second.toString().padLeft(2, '0')}_$author.txt';
  }

  /// Generate comment ID (filename without .txt extension).
  static String generateCommentId(DateTime timestamp, String author) {
    return '${timestamp.year}-${timestamp.month.toString().padLeft(2, '0')}-${timestamp.day.toString().padLeft(2, '0')}_'
        '${timestamp.hour.toString().padLeft(2, '0')}-${timestamp.minute.toString().padLeft(2, '0')}-${timestamp.second.toString().padLeft(2, '0')}_$author';
  }

  /// Validate that a filename follows the comment format.
  ///
  /// Expected format: `YYYY-MM-DD_HH-MM-SS_AUTHOR.txt`
  static bool isValidCommentFilename(String filename) {
    return RegExp(r'^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}_[A-Za-z0-9]+\.txt$').hasMatch(filename);
  }

  /// Format comment file content for writing.
  ///
  /// Format:
  /// ```
  /// AUTHOR: CALLSIGN
  /// CREATED: YYYY-MM-DD HH:MM_ss
  ///
  /// Comment content here.
  ///
  /// --> npub: npub1...
  /// --> signature: hex_signature
  /// ```
  static String formatCommentFile({
    required String author,
    required String timestamp,
    required String content,
    String? npub,
    String? signature,
  }) {
    final buffer = StringBuffer();

    buffer.writeln('AUTHOR: $author');
    buffer.writeln('CREATED: $timestamp');
    buffer.writeln();
    buffer.writeln(content);

    if (npub != null && npub.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('--> npub: $npub');
    }

    if (signature != null && signature.isNotEmpty) {
      buffer.writeln('--> signature: $signature');
    }

    return buffer.toString();
  }

  /// Parse comment file content.
  ///
  /// Returns a BlogComment object parsed from the file content.
  static BlogComment parseCommentFile(String content, String commentId) {
    final lines = content.split('\n');
    if (lines.isEmpty) {
      throw Exception('Empty comment file');
    }

    String? author;
    String? timestamp;
    final contentLines = <String>[];
    final metadata = <String, String>{};
    bool inContent = false;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];

      if (line.startsWith('AUTHOR: ')) {
        author = line.substring(8).trim();
      } else if (line.startsWith('CREATED: ')) {
        timestamp = line.substring(9).trim();
      } else if (line.startsWith('--> ')) {
        // Metadata line
        final metaLine = line.substring(4).trim();
        final colonIndex = metaLine.indexOf(':');
        if (colonIndex > 0) {
          final key = metaLine.substring(0, colonIndex).trim();
          final value = metaLine.substring(colonIndex + 1).trim();
          metadata[key] = value;
        }
      } else if (line.trim().isEmpty && author != null && timestamp != null && !inContent) {
        // Start of content after header
        inContent = true;
      } else if (inContent && !line.startsWith('--> ')) {
        contentLines.add(line);
      }
    }

    if (author == null || timestamp == null) {
      throw Exception('Invalid comment file: missing AUTHOR or CREATED');
    }

    // Remove trailing empty lines from content
    while (contentLines.isNotEmpty && contentLines.last.trim().isEmpty) {
      contentLines.removeLast();
    }

    return BlogComment(
      id: commentId,
      author: author,
      timestamp: timestamp,
      content: contentLines.join('\n').trim(),
      metadata: metadata,
    );
  }

  /// Find a blog post folder by searching in year directories.
  ///
  /// Returns the full path to the post folder if found, null otherwise.
  static Future<String?> findPostPath(String blogPath, String postId) async {
    // Extract year from postId (format: YYYY-MM-DD_title)
    if (postId.length < 4) return null;
    final year = postId.substring(0, 4);

    final postFolderPath = '$blogPath/$year/$postId';
    final postFolder = Directory(postFolderPath);

    if (await postFolder.exists()) {
      final postFile = File('$postFolderPath/post.md');
      if (await postFile.exists()) {
        return postFolderPath;
      }
    }

    return null;
  }

  /// Find all blog post folders recursively and return their paths.
  ///
  /// Returns a list of paths to post folders (directories containing post.md).
  static Future<List<String>> findAllPostPaths(String blogPath) async {
    final paths = <String>[];
    final dir = Directory(blogPath);
    if (!await dir.exists()) return paths;

    await for (final entity in dir.list(recursive: true)) {
      if (entity is File && entity.path.endsWith('/post.md')) {
        // Extract the post directory path
        final postPath = entity.path.replaceFirst('/post.md', '');
        paths.add(postPath);
      }
    }

    return paths;
  }

  /// List all comment files in a post's comments folder.
  ///
  /// Returns list of comment filenames (not full paths).
  static Future<List<String>> listCommentFiles(String postFolderPath) async {
    final commentsDir = Directory(buildCommentsPath(postFolderPath));
    if (!await commentsDir.exists()) return [];

    final files = <String>[];
    await for (final entity in commentsDir.list()) {
      if (entity is File) {
        final filename = entity.path.split('/').last;
        if (isValidCommentFilename(filename)) {
          files.add(filename);
        }
      }
    }

    // Sort by filename (which includes timestamp) - oldest first
    files.sort();
    return files;
  }

  /// Load all comments for a blog post.
  ///
  /// Returns list of BlogComment objects sorted by timestamp (oldest first).
  static Future<List<BlogComment>> loadComments(String postFolderPath) async {
    final commentFiles = await listCommentFiles(postFolderPath);
    final comments = <BlogComment>[];

    for (final filename in commentFiles) {
      try {
        final filePath = '${buildCommentsPath(postFolderPath)}/$filename';
        final content = await File(filePath).readAsString();
        final commentId = filename.substring(0, filename.length - 4); // Remove .txt
        final comment = parseCommentFile(content, commentId);
        comments.add(comment);
      } catch (e) {
        // Skip invalid comment files
        continue;
      }
    }

    return comments;
  }

  /// Write a comment to a file.
  ///
  /// Creates the comments directory if it doesn't exist.
  /// Returns the comment ID (filename without .txt).
  static Future<String> writeComment({
    required String postFolderPath,
    required String author,
    required String content,
    String? npub,
    String? signature,
  }) async {
    final now = DateTime.now();
    final filename = generateCommentFilename(now, author);
    final commentId = generateCommentId(now, author);

    // Format timestamp
    final timestamp = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}_${now.second.toString().padLeft(2, '0')}';

    final commentContent = formatCommentFile(
      author: author,
      timestamp: timestamp,
      content: content,
      npub: npub,
      signature: signature,
    );

    // Ensure comments directory exists
    final commentsDir = Directory(buildCommentsPath(postFolderPath));
    if (!await commentsDir.exists()) {
      await commentsDir.create(recursive: true);
    }

    // Write comment file
    final commentFile = File('${commentsDir.path}/$filename');
    await commentFile.writeAsString(commentContent, flush: true);

    return commentId;
  }

  /// Delete a comment file by ID.
  ///
  /// Returns true if deleted, false if not found.
  static Future<bool> deleteComment(String postFolderPath, String commentId) async {
    final filename = '$commentId.txt';
    final filePath = '${buildCommentsPath(postFolderPath)}/$filename';
    final file = File(filePath);

    if (await file.exists()) {
      await file.delete();
      return true;
    }

    return false;
  }

  /// Get a single comment by ID.
  ///
  /// Returns the BlogComment if found, null otherwise.
  static Future<BlogComment?> getComment(String postFolderPath, String commentId) async {
    final filename = '$commentId.txt';
    final filePath = '${buildCommentsPath(postFolderPath)}/$filename';
    final file = File(filePath);

    if (!await file.exists()) return null;

    try {
      final content = await file.readAsString();
      return parseCommentFile(content, commentId);
    } catch (e) {
      return null;
    }
  }

  /// Format DateTime to timestamp string (for CREATED field).
  static String formatTimestamp(DateTime dt) {
    final year = dt.year.toString().padLeft(4, '0');
    final month = dt.month.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    final second = dt.second.toString().padLeft(2, '0');
    return '$year-$month-$day $hour:$minute\_$second';
  }
}
