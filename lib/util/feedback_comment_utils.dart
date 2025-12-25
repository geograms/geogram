import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';

import 'feedback_folder_utils.dart';

class FeedbackComment {
  final String id;
  final String author;
  final String created;
  final String content;
  final String? npub;
  final String? signature;

  FeedbackComment({
    required this.id,
    required this.author,
    required this.created,
    required this.content,
    this.npub,
    this.signature,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'author': author,
        'created': created,
        'content': content,
        if (npub != null && npub!.isNotEmpty) 'npub': npub,
        'has_signature': signature != null && signature!.isNotEmpty,
      };
}

/// Utilities for feedback comment files stored under {contentPath}/feedback/comments.
class FeedbackCommentUtils {
  FeedbackCommentUtils._();

  /// Generate a comment filename in the format: `YYYY-MM-DD_HH-MM-SS_AUTHOR.txt`
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
  static bool isValidCommentFilename(String filename) {
    return RegExp(r'^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}_[A-Za-z0-9]+\.txt$').hasMatch(filename);
  }

  /// Format comment file content for writing.
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
  static FeedbackComment parseCommentFile(String content, String commentId) {
    final lines = content.split('\n');
    if (lines.isEmpty) {
      throw Exception('Empty comment file');
    }

    String? author;
    String? timestamp;
    final contentLines = <String>[];
    String? npub;
    String? signature;
    bool inContent = false;

    for (final line in lines) {
      if (line.startsWith('AUTHOR: ')) {
        author = line.substring(8).trim();
      } else if (line.startsWith('CREATED: ')) {
        timestamp = line.substring(9).trim();
      } else if (line.startsWith('--> ')) {
        final metaLine = line.substring(4).trim();
        final colonIndex = metaLine.indexOf(':');
        if (colonIndex > 0) {
          final key = metaLine.substring(0, colonIndex).trim();
          final value = metaLine.substring(colonIndex + 1).trim();
          if (key == 'npub') {
            npub = value;
          } else if (key == 'signature') {
            signature = value;
          }
        }
      } else if (line.trim().isEmpty && author != null && timestamp != null && !inContent) {
        inContent = true;
      } else if (inContent && !line.startsWith('--> ')) {
        contentLines.add(line);
      }
    }

    if (author == null || timestamp == null) {
      throw Exception('Invalid comment file: missing AUTHOR or CREATED');
    }

    while (contentLines.isNotEmpty && contentLines.last.trim().isEmpty) {
      contentLines.removeLast();
    }

    return FeedbackComment(
      id: commentId,
      author: author,
      created: timestamp,
      content: contentLines.join('\n').trim(),
      npub: npub,
      signature: signature,
    );
  }

  /// List comment filenames (sorted) for a content item.
  static Future<List<String>> listCommentFiles(String contentPath) async {
    final commentsDir = Directory(FeedbackFolderUtils.buildCommentsPath(contentPath));
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

    files.sort();
    return files;
  }

  /// Load comments and return them sorted by timestamp (oldest first).
  static Future<List<FeedbackComment>> loadComments(String contentPath) async {
    final commentFiles = await listCommentFiles(contentPath);
    final comments = <FeedbackComment>[];
    final commentsDir = FeedbackFolderUtils.buildCommentsPath(contentPath);

    for (final filename in commentFiles) {
      final commentId = filename.replaceAll('.txt', '');
      final filePath = '$commentsDir/$filename';
      try {
        final content = await File(filePath).readAsString();
        final comment = parseCommentFile(content, commentId);
        comments.add(comment);
      } catch (_) {
        // Skip invalid comment files
      }
    }

    return comments;
  }

  /// Write a comment and return the comment ID.
  static Future<String> writeComment({
    required String contentPath,
    required String author,
    required String content,
    String? npub,
    String? signature,
  }) async {
    final now = DateTime.now();
    final filename = generateCommentFilename(now, author);
    final commentId = generateCommentId(now, author);

    final timestamp = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}_${now.second.toString().padLeft(2, '0')}';

    final commentContent = formatCommentFile(
      author: author,
      timestamp: timestamp,
      content: content,
      npub: npub,
      signature: signature,
    );

    final commentsDir = Directory(FeedbackFolderUtils.buildCommentsPath(contentPath));
    if (!await commentsDir.exists()) {
      await commentsDir.create(recursive: true);
    }

    final commentFile = File('${commentsDir.path}/$filename');
    await commentFile.writeAsString(commentContent, flush: true);

    return commentId;
  }

  /// Count comment files for a content item.
  static Future<int> getCommentCount(String contentPath) async {
    final commentFiles = await listCommentFiles(contentPath);
    return commentFiles.length;
  }
}
