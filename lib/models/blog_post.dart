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
  final String? edited; // Format: YYYY-MM-DD HH:MM (when post was last edited)
  final String title;
  final String? description;
  final String? location; // Format: "lat, lon" (e.g., "38.736946, -9.142685")
  final BlogStatus status;
  final List<String> tags;
  final String content;
  final List<BlogComment> comments;
  final Map<String, String> metadata;

  // Feedback counts
  final int likesCount;
  final int pointsCount;
  final int dislikesCount;
  final int subscribeCount;
  final int verificationsCount;

  // Emoji reaction counts
  final int heartCount;
  final int thumbsUpCount;
  final int thumbsDownCount;
  final int fireCount;
  final int hundredCount;
  final int curiousCount;
  final int celebrateCount;
  final int laughCount;
  final int sadCount;
  final int beerCheersCount;
  final int surpriseCount;

  // User-specific feedback state (optional, only populated for current user)
  final bool hasLiked;
  final bool hasPointed;
  final bool hasDisliked;
  final bool hasSubscribed;
  final bool hasVerified;
  final bool hasHearted;
  final bool hasThumbsUp;
  final bool hasThumbsDown;
  final bool hasFired;
  final bool hasHundred;
  final bool hasCurious;
  final bool hasCelebrated;
  final bool hasLaughed;
  final bool hasSad;
  final bool hasBeerCheers;
  final bool hasSurprised;

  BlogPost({
    required this.id,
    required this.author,
    required this.timestamp,
    this.edited,
    required this.title,
    this.description,
    this.location,
    this.status = BlogStatus.draft,
    this.tags = const [],
    required this.content,
    this.comments = const [],
    this.metadata = const {},
    // Feedback counts with defaults
    this.likesCount = 0,
    this.pointsCount = 0,
    this.dislikesCount = 0,
    this.subscribeCount = 0,
    this.verificationsCount = 0,
    this.heartCount = 0,
    this.thumbsUpCount = 0,
    this.thumbsDownCount = 0,
    this.fireCount = 0,
    this.hundredCount = 0,
    this.curiousCount = 0,
    this.celebrateCount = 0,
    this.laughCount = 0,
    this.sadCount = 0,
    this.beerCheersCount = 0,
    this.surpriseCount = 0,
    // User feedback state with defaults
    this.hasLiked = false,
    this.hasPointed = false,
    this.hasDisliked = false,
    this.hasSubscribed = false,
    this.hasVerified = false,
    this.hasHearted = false,
    this.hasThumbsUp = false,
    this.hasThumbsDown = false,
    this.hasFired = false,
    this.hasHundred = false,
    this.hasCurious = false,
    this.hasCelebrated = false,
    this.hasLaughed = false,
    this.hasSad = false,
    this.hasBeerCheers = false,
    this.hasSurprised = false,
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

  /// Check if post has a location
  bool get hasLocation => location != null && location!.isNotEmpty;

  /// Get latitude from location string
  double? get latitude {
    if (!hasLocation) return null;
    final parts = location!.split(',');
    if (parts.length != 2) return null;
    return double.tryParse(parts[0].trim());
  }

  /// Get longitude from location string
  double? get longitude {
    if (!hasLocation) return null;
    final parts = location!.split(',');
    if (parts.length != 2) return null;
    return double.tryParse(parts[1].trim());
  }

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

    // Header
    buffer.writeln('# BLOG: $title');
    buffer.writeln();
    buffer.writeln('AUTHOR: $author');
    buffer.writeln('CREATED: $timestamp');
    if (edited != null && edited!.isNotEmpty) {
      buffer.writeln('EDITED: $edited');
    }
    if (description != null && description!.isNotEmpty) {
      buffer.writeln('DESCRIPTION: $description');
    }
    if (location != null && location!.isNotEmpty) {
      buffer.writeln('LOCATION: $location');
    }
    buffer.writeln('STATUS: ${status.name}');

    // Tags as metadata (before blank line)
    if (tags.isNotEmpty) {
      buffer.writeln('--> tags: ${tags.join(',')}');
    }

    buffer.writeln();

    // Content
    buffer.writeln(content);

    // Metadata (excluding signature, tags, and npub which goes before signature)
    final regularMetadata = Map<String, String>.from(metadata);
    regularMetadata.remove('tags');
    final sig = regularMetadata.remove('signature');
    final npubValue = regularMetadata.remove('npub');

    for (var entry in regularMetadata.entries) {
      buffer.writeln('--> ${entry.key}: ${entry.value}');
    }

    // npub must be before signature
    if (npubValue != null) {
      buffer.writeln('--> npub: $npubValue');
    }

    // Signature must be last if present
    if (sig != null) {
      buffer.writeln('--> signature: $sig');
    }

    // Note: Comments are stored in separate files in the comments/ directory,
    // not inline in the post file

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

    // Line 5: EDITED: timestamp (optional) or DESCRIPTION: or LOCATION: or STATUS:
    String? edited;
    String? description;
    String? location;
    BlogStatus status = BlogStatus.draft;
    int currentLine = 4;

    // Check for EDITED field
    if (currentLine < lines.length && lines[currentLine].startsWith('EDITED: ')) {
      edited = lines[currentLine].substring(8).trim();
      currentLine++;
    }

    if (currentLine < lines.length && lines[currentLine].startsWith('DESCRIPTION: ')) {
      description = lines[currentLine].substring(13).trim();
      currentLine++;
    }

    // Check for LOCATION field
    if (currentLine < lines.length && lines[currentLine].startsWith('LOCATION: ')) {
      location = lines[currentLine].substring(10).trim();
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

    // Parse content (comments are stored in separate files, not inline)
    final contentLines = <String>[];

    while (currentLine < lines.length) {
      final line = lines[currentLine];

      if (line.startsWith('-->')) {
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
      edited: edited,
      title: title,
      description: description,
      location: location,
      status: status,
      tags: tags,
      content: content,
      comments: const [], // Comments are loaded separately from comments/ directory
      metadata: metadata,
    );
  }

  /// Create a copy with updated fields
  BlogPost copyWith({
    String? id,
    String? author,
    String? timestamp,
    String? edited,
    String? title,
    String? description,
    String? location,
    BlogStatus? status,
    List<String>? tags,
    String? content,
    List<BlogComment>? comments,
    Map<String, String>? metadata,
    int? likesCount,
    int? pointsCount,
    int? dislikesCount,
    int? subscribeCount,
    int? verificationsCount,
    int? heartCount,
    int? thumbsUpCount,
    int? thumbsDownCount,
    int? fireCount,
    int? hundredCount,
    int? curiousCount,
    int? celebrateCount,
    int? laughCount,
    int? sadCount,
    int? beerCheersCount,
    int? surpriseCount,
    bool? hasLiked,
    bool? hasPointed,
    bool? hasDisliked,
    bool? hasSubscribed,
    bool? hasVerified,
    bool? hasHearted,
    bool? hasThumbsUp,
    bool? hasThumbsDown,
    bool? hasFired,
    bool? hasHundred,
    bool? hasCurious,
    bool? hasCelebrated,
    bool? hasLaughed,
    bool? hasSad,
    bool? hasBeerCheers,
    bool? hasSurprised,
  }) {
    return BlogPost(
      id: id ?? this.id,
      author: author ?? this.author,
      timestamp: timestamp ?? this.timestamp,
      edited: edited ?? this.edited,
      title: title ?? this.title,
      description: description ?? this.description,
      location: location ?? this.location,
      status: status ?? this.status,
      tags: tags ?? this.tags,
      content: content ?? this.content,
      comments: comments ?? this.comments,
      metadata: metadata ?? this.metadata,
      likesCount: likesCount ?? this.likesCount,
      pointsCount: pointsCount ?? this.pointsCount,
      dislikesCount: dislikesCount ?? this.dislikesCount,
      subscribeCount: subscribeCount ?? this.subscribeCount,
      verificationsCount: verificationsCount ?? this.verificationsCount,
      heartCount: heartCount ?? this.heartCount,
      thumbsUpCount: thumbsUpCount ?? this.thumbsUpCount,
      thumbsDownCount: thumbsDownCount ?? this.thumbsDownCount,
      fireCount: fireCount ?? this.fireCount,
      hundredCount: hundredCount ?? this.hundredCount,
      curiousCount: curiousCount ?? this.curiousCount,
      celebrateCount: celebrateCount ?? this.celebrateCount,
      laughCount: laughCount ?? this.laughCount,
      sadCount: sadCount ?? this.sadCount,
      beerCheersCount: beerCheersCount ?? this.beerCheersCount,
      surpriseCount: surpriseCount ?? this.surpriseCount,
      hasLiked: hasLiked ?? this.hasLiked,
      hasPointed: hasPointed ?? this.hasPointed,
      hasDisliked: hasDisliked ?? this.hasDisliked,
      hasSubscribed: hasSubscribed ?? this.hasSubscribed,
      hasVerified: hasVerified ?? this.hasVerified,
      hasHearted: hasHearted ?? this.hasHearted,
      hasThumbsUp: hasThumbsUp ?? this.hasThumbsUp,
      hasThumbsDown: hasThumbsDown ?? this.hasThumbsDown,
      hasFired: hasFired ?? this.hasFired,
      hasHundred: hasHundred ?? this.hasHundred,
      hasCurious: hasCurious ?? this.hasCurious,
      hasCelebrated: hasCelebrated ?? this.hasCelebrated,
      hasLaughed: hasLaughed ?? this.hasLaughed,
      hasSad: hasSad ?? this.hasSad,
      hasBeerCheers: hasBeerCheers ?? this.hasBeerCheers,
      hasSurprised: hasSurprised ?? this.hasSurprised,
    );
  }

  @override
  String toString() {
    return 'BlogPost(id: $id, title: $title, author: $author, status: ${status.name}, comments: ${comments.length})';
  }
}
