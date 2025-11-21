/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'event_comment.dart';

/// Model representing reactions (likes and comments) on an event item
/// Can be for the event itself, a file, subfolder, day folder, or contributor folder
class EventReaction {
  final String target; // Filename or folder name (e.g., "event.txt", "photo.jpg", "day1", "contributors/CR7BBQ")
  final List<String> likes; // List of callsigns
  final List<EventComment> comments;

  EventReaction({
    required this.target,
    this.likes = const [],
    this.comments = const [],
  });

  /// Check if user has liked
  bool hasUserLiked(String callsign) {
    return likes.contains(callsign);
  }

  /// Get like count
  int get likeCount => likes.length;

  /// Get comment count
  int get commentCount => comments.length;

  /// Export reaction as text format for file storage
  String exportAsText() {
    final buffer = StringBuffer();

    // LIKES line
    if (likes.isNotEmpty) {
      buffer.writeln('LIKES: ${likes.join(', ')}');
    } else {
      buffer.writeln('LIKES:');
    }

    // Comments
    if (comments.isNotEmpty) {
      buffer.writeln();
      for (var comment in comments) {
        buffer.write(comment.exportAsText());
        if (comment != comments.last) {
          buffer.writeln();
        }
      }
    }

    return buffer.toString();
  }

  /// Parse reaction from reaction file text
  static EventReaction fromText(String text, String target) {
    final lines = text.split('\n');
    if (lines.isEmpty) {
      return EventReaction(target: target);
    }

    // Parse LIKES line
    final List<String> likes = [];
    int currentLine = 0;

    if (lines[currentLine].startsWith('LIKES:')) {
      final likesStr = lines[currentLine].substring(6).trim();
      if (likesStr.isNotEmpty) {
        likes.addAll(
          likesStr.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty),
        );
      }
      currentLine++;
    }

    // Skip blank line
    if (currentLine < lines.length && lines[currentLine].trim().isEmpty) {
      currentLine++;
    }

    // Parse comments
    final comments = <EventComment>[];

    while (currentLine < lines.length) {
      final line = lines[currentLine];

      // Check if this is a comment (starts with "> 2" for year 2xxx)
      if (line.startsWith('> 2')) {
        final comment = _parseComment(lines, currentLine);
        comments.add(comment);

        // Skip to next comment or end
        currentLine++;
        while (currentLine < lines.length && !lines[currentLine].startsWith('> 2')) {
          currentLine++;
        }
      } else {
        currentLine++;
      }
    }

    return EventReaction(
      target: target,
      likes: likes,
      comments: comments,
    );
  }

  /// Parse a single comment from lines starting at index
  static EventComment _parseComment(List<String> lines, int startIndex) {
    // Line format: > YYYY-MM-DD HH:MM_ss -- AUTHOR
    final headerLine = lines[startIndex];
    final parts = headerLine.substring(2).split(' -- ');
    if (parts.length < 2) {
      throw Exception('Invalid comment header');
    }

    final timestamp = parts[0].trim();
    final author = parts[1].trim();

    // Parse comment content and metadata
    final contentLines = <String>[];
    final Map<String, String> metadata = {};
    int i = startIndex + 1;

    while (i < lines.length && !lines[i].startsWith('> 2')) {
      final line = lines[i];

      if (line.startsWith('-->')) {
        // Metadata
        final metaLine = line.substring(3).trim();
        final colonIndex = metaLine.indexOf(':');
        if (colonIndex > 0) {
          final key = metaLine.substring(0, colonIndex).trim();
          final value = metaLine.substring(colonIndex + 1).trim();
          metadata[key] = value;
        }
      } else if (line.trim().isEmpty && contentLines.isEmpty) {
        // Skip leading blank lines
      } else {
        contentLines.add(line);
      }
      i++;
    }

    // Remove trailing empty lines and metadata lines from content
    while (contentLines.isNotEmpty &&
           (contentLines.last.trim().isEmpty || contentLines.last.startsWith('-->'))) {
      contentLines.removeLast();
    }

    final content = contentLines.join('\n').trim();

    return EventComment(
      author: author,
      timestamp: timestamp,
      content: content,
      metadata: metadata,
    );
  }

  /// Create a copy with updated fields
  EventReaction copyWith({
    String? target,
    List<String>? likes,
    List<EventComment>? comments,
  }) {
    return EventReaction(
      target: target ?? this.target,
      likes: likes ?? this.likes,
      comments: comments ?? this.comments,
    );
  }

  @override
  String toString() {
    return 'EventReaction(target: $target, likes: ${likes.length}, comments: ${comments.length})';
  }
}
