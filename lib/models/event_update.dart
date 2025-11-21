/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'event_comment.dart';

/// Model representing an event update (blog-like post)
class EventUpdate {
  final String id; // Filename without extension
  final String title;
  final String author;
  final String posted; // Format: YYYY-MM-DD HH:MM_ss
  final String content; // Markdown content
  final List<String> likes;
  final List<EventComment> comments;
  final Map<String, String> metadata;

  EventUpdate({
    required this.id,
    required this.title,
    required this.author,
    required this.posted,
    required this.content,
    this.likes = const [],
    this.comments = const [],
    this.metadata = const {},
  });

  /// Parse timestamp to DateTime
  DateTime get dateTime {
    try {
      final normalized = posted.replaceAll('_', ':');
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

  /// Check if update is signed with NOSTR
  bool get isSigned => metadata.containsKey('signature');

  /// Get NOSTR public key
  String? get npub => metadata['npub'];

  /// Get signature
  String? get signature => metadata['signature'];

  /// Check if user has liked
  bool hasUserLiked(String callsign) => likes.contains(callsign);

  /// Get like count
  int get likeCount => likes.length;

  /// Get comment count
  int get commentCount => comments.length;

  /// Export update as text format for file storage
  String exportAsText() {
    final buffer = StringBuffer();

    buffer.writeln('# UPDATE: $title');
    buffer.writeln();
    buffer.writeln('POSTED: $posted');
    buffer.writeln('AUTHOR: $author');
    buffer.writeln();

    // Content (markdown)
    buffer.writeln(content);

    // Metadata (excluding npub and signature)
    final regularMetadata = Map<String, String>.from(metadata);
    final npubVal = regularMetadata.remove('npub');
    final sig = regularMetadata.remove('signature');

    for (var entry in regularMetadata.entries) {
      buffer.writeln('--> ${entry.key}: ${entry.value}');
    }

    // npub before signature
    if (npubVal != null) {
      buffer.writeln('--> npub: $npubVal');
    }

    // Signature must be last if present
    if (sig != null) {
      buffer.writeln('--> signature: $sig');
    }

    return buffer.toString();
  }

  /// Parse update from file text
  static EventUpdate fromText(String text, String updateId) {
    final lines = text.split('\n');
    if (lines.isEmpty || lines.length < 4) {
      throw Exception('Invalid update file');
    }

    // Line 1: # UPDATE: Title
    final titleLine = lines[0];
    if (!titleLine.startsWith('# UPDATE: ')) {
      throw Exception('Invalid update title line');
    }
    final title = titleLine.substring(10).trim();

    // Line 2: Blank
    // Line 3: POSTED: timestamp
    final postedLine = lines[2];
    if (!postedLine.startsWith('POSTED: ')) {
      throw Exception('Invalid posted line');
    }
    final posted = postedLine.substring(8).trim();

    // Line 4: AUTHOR: callsign
    final authorLine = lines[3];
    if (!authorLine.startsWith('AUTHOR: ')) {
      throw Exception('Invalid author line');
    }
    final author = authorLine.substring(8).trim();

    // Skip blank line
    int currentLine = 5;

    // Parse content and metadata
    final contentLines = <String>[];
    final Map<String, String> metadata = {};

    while (currentLine < lines.length) {
      final line = lines[currentLine];

      if (line.startsWith('-->')) {
        // Metadata
        final metaLine = line.substring(3).trim();
        final colonIndex = metaLine.indexOf(':');
        if (colonIndex > 0) {
          final key = metaLine.substring(0, colonIndex).trim();
          final value = metaLine.substring(colonIndex + 1).trim();
          metadata[key] = value;
        }
      } else {
        // Content line
        contentLines.add(line);
      }
      currentLine++;
    }

    // Remove trailing empty lines from content
    while (contentLines.isNotEmpty && contentLines.last.trim().isEmpty) {
      contentLines.removeLast();
    }

    final content = contentLines.join('\n');

    return EventUpdate(
      id: updateId,
      title: title,
      author: author,
      posted: posted,
      content: content,
      metadata: metadata,
    );
  }

  /// Create a copy with updated fields
  EventUpdate copyWith({
    String? id,
    String? title,
    String? author,
    String? posted,
    String? content,
    List<String>? likes,
    List<EventComment>? comments,
    Map<String, String>? metadata,
  }) {
    return EventUpdate(
      id: id ?? this.id,
      title: title ?? this.title,
      author: author ?? this.author,
      posted: posted ?? this.posted,
      content: content ?? this.content,
      likes: likes ?? this.likes,
      comments: comments ?? this.comments,
      metadata: metadata ?? this.metadata,
    );
  }

  @override
  String toString() {
    return 'EventUpdate(id: $id, title: $title, author: $author, posted: $posted)';
  }
}
