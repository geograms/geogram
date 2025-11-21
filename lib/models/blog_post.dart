/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'blog_comment.dart';

/// Blog post status
enum BlogStatus {
  draft,
  published;

  static BlogStatus fromString(String value) {
    return BlogStatus.values.firstWhere(
      (e) => e.name == value.toLowerCase(),
      orElse: () => BlogStatus.draft,
    );
  }
}

/// Model representing a blog post with comments
class BlogPost {
  final String id; // Filename without extension
  final String author;
  final String timestamp; // Format: YYYY-MM-DD HH:MM_ss
  final String title;
  final String? description;
  final BlogStatus status;
  final List<String> tags;
  final String content;
  final List<BlogComment> comments;
  final Map<String, String> metadata;

  BlogPost({
    required this.id,
    required this.author,
    required this.timestamp,
    required this.title,
    this.description,
    this.status = BlogStatus.draft,
    this.tags = const [],
    required this.content,
    this.comments = const [],
    this.metadata = const {},
  });

  /// Parse timestamp to DateTime
  DateTime get dateTime {
    try {
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

  /// Get year from timestamp
  int get year => dateTime.year;

  /// Check if post is published
  bool get isPublished => status == BlogStatus.published;

  /// Check if post is draft
  bool get isDraft => status == BlogStatus.draft;

  /// Check if post has attached files
  bool get hasFile => metadata.containsKey('file');

  /// Check if post has attached images
  bool get hasImage => metadata.containsKey('image');

  /// Check if post has URLs
  bool get hasUrl => metadata.containsKey('url');

  /// Check if post is signed with NOSTR
  bool get isSigned => metadata.containsKey('signature');

  /// Get NOSTR public key
  String? get npub => metadata['npub'];

  /// Get signature
  String? get signature => metadata['signature'];

  /// Get attached file name
  String? get attachedFile => metadata['file'];

  /// Get image file name
  String? get imageFile => metadata['image'];

  /// Get URL
  String? get url => metadata['url'];

  /// Get display filename (without SHA1 prefix)
  String? get displayFileName {
    if (attachedFile == null) return null;
    final parts = attachedFile!.split('_');
    if (parts.length > 1) {
      return parts.sublist(1).join('_');
    }
    return attachedFile;
  }

  /// Get display image name (without SHA1 prefix)
  String? get displayImageName {
    if (imageFile == null) return null;
    final parts = imageFile!.split('_');
    if (parts.length > 1) {
      return parts.sublist(1).join('_');
    }
    return imageFile;
  }

  /// Check if current user is the author (compare npub)
  bool isOwnPost(String? currentUserNpub) {
    if (currentUserNpub == null || npub == null) return false;
    return npub == currentUserNpub;
  }

  /// Get comment count
  int get commentCount => comments.length;

  /// Export blog post as text format for file storage
  String exportAsText() {
    final buffer = StringBuffer();

    // Header (7 lines)
    buffer.writeln('# BLOG: $title');
    buffer.writeln();
    buffer.writeln('AUTHOR: $author');
    buffer.writeln('CREATED: $timestamp');
    if (description != null && description!.isNotEmpty) {
      buffer.writeln('DESCRIPTION: $description');
    }
    buffer.writeln('STATUS: ${status.name}');

    // Tags as metadata (before blank line)
    if (tags.isNotEmpty) {
      buffer.writeln('--> tags: ${tags.join(',')}');
    }

    // npub if present
    if (npub != null) {
      buffer.writeln('--> npub: $npub');
    }

    buffer.writeln();

    // Content
    buffer.writeln(content);

    // Metadata (excluding signature and tags, which go last or were already written)
    final regularMetadata = Map<String, String>.from(metadata);
    regularMetadata.remove('tags');
    final sig = regularMetadata.remove('signature');

    for (var entry in regularMetadata.entries) {
      buffer.writeln('--> ${entry.key}: ${entry.value}');
    }

    // Signature must be last if present
    if (sig != null) {
      buffer.writeln('--> signature: $sig');
    }

    // Comments
    if (comments.isNotEmpty) {
      buffer.writeln();
      for (var comment in comments) {
        buffer.writeln(comment.exportAsText());
      }
    }

    return buffer.toString();
  }

  /// Parse blog post from file text
  static BlogPost fromText(String text, String postId) {
    final lines = text.split('\n');
    if (lines.isEmpty) {
      throw Exception('Empty blog post file');
    }

    // Parse header (at least 6 lines)
    if (lines.length < 6) {
      throw Exception('Invalid blog post header');
    }

    // Line 1: # BLOG: Title
    final titleLine = lines[0];
    if (!titleLine.startsWith('# BLOG: ')) {
      throw Exception('Invalid blog post title line');
    }
    final title = titleLine.substring(8).trim();

    // Line 2: Blank
    // Line 3: AUTHOR: callsign
    final authorLine = lines[2];
    if (!authorLine.startsWith('AUTHOR: ')) {
      throw Exception('Invalid author line');
    }
    final author = authorLine.substring(8).trim();

    // Line 4: CREATED: timestamp
    final createdLine = lines[3];
    if (!createdLine.startsWith('CREATED: ')) {
      throw Exception('Invalid created line');
    }
    final timestamp = createdLine.substring(9).trim();

    // Line 5: DESCRIPTION: text (optional) or STATUS:
    String? description;
    BlogStatus status = BlogStatus.draft;
    int currentLine = 4;

    if (lines[currentLine].startsWith('DESCRIPTION: ')) {
      description = lines[currentLine].substring(13).trim();
      currentLine++;
    }

    // STATUS line
    if (currentLine < lines.length && lines[currentLine].startsWith('STATUS: ')) {
      final statusStr = lines[currentLine].substring(8).trim();
      status = BlogStatus.fromString(statusStr);
      currentLine++;
    }

    // Parse metadata before blank line (tags, npub)
    final Map<String, String> metadata = {};
    final List<String> tags = [];

    while (currentLine < lines.length &&
        lines[currentLine].trim().isNotEmpty &&
        lines[currentLine].startsWith('-->')) {
      final metaLine = lines[currentLine].substring(3).trim();
      final colonIndex = metaLine.indexOf(':');
      if (colonIndex > 0) {
        final key = metaLine.substring(0, colonIndex).trim();
        final value = metaLine.substring(colonIndex + 1).trim();

        if (key == 'tags') {
          tags.addAll(value.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty));
        } else {
          metadata[key] = value;
        }
      }
      currentLine++;
    }

    // Skip blank line
    if (currentLine < lines.length && lines[currentLine].trim().isEmpty) {
      currentLine++;
    }

    // Parse content and comments
    final contentLines = <String>[];
    final comments = <BlogComment>[];

    while (currentLine < lines.length) {
      final line = lines[currentLine];

      // Check if this is a comment (starts with "> 2" for year 2xxx)
      if (line.startsWith('> 2')) {
        // Parse comment
        final comment = _parseComment(lines, currentLine);
        comments.add(comment);

        // Skip to next comment or end
        currentLine++;
        while (currentLine < lines.length && !lines[currentLine].startsWith('> 2')) {
          currentLine++;
        }
      } else if (line.startsWith('-->')) {
        // Metadata for post content
        final metaLine = line.substring(3).trim();
        final colonIndex = metaLine.indexOf(':');
        if (colonIndex > 0) {
          final key = metaLine.substring(0, colonIndex).trim();
          final value = metaLine.substring(colonIndex + 1).trim();
          metadata[key] = value;
        }
        currentLine++;
      } else {
        // Content line
        contentLines.add(line);
        currentLine++;
      }
    }

    // Remove trailing empty lines from content
    while (contentLines.isNotEmpty && contentLines.last.trim().isEmpty) {
      contentLines.removeLast();
    }

    final content = contentLines.join('\n');

    return BlogPost(
      id: postId,
      author: author,
      timestamp: timestamp,
      title: title,
      description: description,
      status: status,
      tags: tags,
      content: content,
      comments: comments,
      metadata: metadata,
    );
  }

  /// Parse a single comment from lines starting at index
  static BlogComment _parseComment(List<String> lines, int startIndex) {
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

    return BlogComment(
      author: author,
      timestamp: timestamp,
      content: content,
      metadata: metadata,
    );
  }

  /// Create a copy with updated fields
  BlogPost copyWith({
    String? id,
    String? author,
    String? timestamp,
    String? title,
    String? description,
    BlogStatus? status,
    List<String>? tags,
    String? content,
    List<BlogComment>? comments,
    Map<String, String>? metadata,
  }) {
    return BlogPost(
      id: id ?? this.id,
      author: author ?? this.author,
      timestamp: timestamp ?? this.timestamp,
      title: title ?? this.title,
      description: description ?? this.description,
      status: status ?? this.status,
      tags: tags ?? this.tags,
      content: content ?? this.content,
      comments: comments ?? this.comments,
      metadata: metadata ?? this.metadata,
    );
  }

  @override
  String toString() {
    return 'BlogPost(id: $id, title: $title, author: $author, status: ${status.name}, comments: ${comments.length})';
  }
}
