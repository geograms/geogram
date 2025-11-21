/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Model representing a comment on a blog post
class BlogComment {
  final String author;
  final String timestamp; // Format: YYYY-MM-DD HH:MM_ss
  final String content;
  final Map<String, String> metadata;

  BlogComment({
    required this.author,
    required this.timestamp,
    required this.content,
    this.metadata = const {},
  });

  /// Parse timestamp to DateTime
  DateTime get dateTime {
    try {
      // Replace underscore with colon for parsing: "2025-11-20 14:30_45" -> "2025-11-20 14:30:45"
      final normalized = timestamp.replaceAll('_', ':');
      return DateTime.parse(normalized);
    } catch (e) {
      return DateTime.now();
    }
  }

  /// Get display time (HH:MM)
  String get displayTime {
    final dt = dateTime;
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  /// Get display date (YYYY-MM-DD)
  String get displayDate {
    final dt = dateTime;
    final year = dt.year.toString();
    final month = dt.month.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }

  /// Check if comment has NOSTR signature
  bool get isSigned => metadata.containsKey('signature');

  /// Get NOSTR public key
  String? get npub => metadata['npub'];

  /// Get signature
  String? get signature => metadata['signature'];

  /// Export comment as text format for file storage
  String exportAsText() {
    final buffer = StringBuffer();

    // Comment header: > YYYY-MM-DD HH:MM_ss -- AUTHOR
    buffer.writeln('> $timestamp -- $author');

    // Content
    buffer.writeln(content);

    // Metadata (excluding signature, which goes last)
    final regularMetadata = Map<String, String>.from(metadata);
    final sig = regularMetadata.remove('signature');

    for (var entry in regularMetadata.entries) {
      buffer.writeln('--> ${entry.key}: ${entry.value}');
    }

    // Signature must be last if present
    if (sig != null) {
      buffer.writeln('--> signature: $sig');
    }

    return buffer.toString();
  }

  /// Create a new comment with current timestamp
  factory BlogComment.now({
    required String author,
    required String content,
    Map<String, String>? metadata,
  }) {
    return BlogComment(
      author: author,
      timestamp: _formatTimestamp(DateTime.now()),
      content: content,
      metadata: metadata ?? {},
    );
  }

  /// Format DateTime to timestamp string
  static String _formatTimestamp(DateTime dt) {
    final year = dt.year.toString().padLeft(4, '0');
    final month = dt.month.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    final second = dt.second.toString().padLeft(2, '0');
    return '$year-$month-$day $hour:$minute\_$second';
  }

  @override
  String toString() {
    return 'BlogComment(author: $author, timestamp: $timestamp, content: ${content.substring(0, content.length > 50 ? 50 : content.length)}...)';
  }
}
