/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Represents a single forum post (original post or reply)
class ForumPost implements Comparable<ForumPost> {
  /// Author's callsign
  final String author;

  /// Timestamp in format: YYYY-MM-DD HH:MM_ss
  final String timestamp;

  /// Post content (can be multi-line)
  final String content;

  /// Whether this is the original post (thread starter)
  final bool isOriginalPost;

  /// Metadata key-value pairs
  final Map<String, String> metadata;

  ForumPost({
    required this.author,
    required this.timestamp,
    required this.content,
    this.isOriginalPost = false,
    Map<String, String>? metadata,
  }) : metadata = metadata ?? {};

  /// Create original post (thread starter)
  factory ForumPost.original({
    required String author,
    required String timestamp,
    required String content,
    Map<String, String>? metadata,
  }) {
    return ForumPost(
      author: author,
      timestamp: timestamp,
      content: content,
      isOriginalPost: true,
      metadata: metadata,
    );
  }

  /// Create reply post
  factory ForumPost.reply({
    required String author,
    required String timestamp,
    required String content,
    Map<String, String>? metadata,
  }) {
    return ForumPost(
      author: author,
      timestamp: timestamp,
      content: content,
      isOriginalPost: false,
      metadata: metadata,
    );
  }

  /// Create from current time
  factory ForumPost.now({
    required String author,
    required String content,
    bool isOriginalPost = false,
    Map<String, String>? metadata,
  }) {
    final now = DateTime.now();
    final timestamp = _formatTimestamp(now);

    return ForumPost(
      author: author,
      timestamp: timestamp,
      content: content,
      isOriginalPost: isOriginalPost,
      metadata: metadata,
    );
  }

  /// Format DateTime to forum timestamp format: YYYY-MM-DD HH:MM_ss
  static String _formatTimestamp(DateTime dt) {
    String year = dt.year.toString().padLeft(4, '0');
    String month = dt.month.toString().padLeft(2, '0');
    String day = dt.day.toString().padLeft(2, '0');
    String hour = dt.hour.toString().padLeft(2, '0');
    String minute = dt.minute.toString().padLeft(2, '0');
    String second = dt.second.toString().padLeft(2, '0');

    return '$year-$month-$day $hour:$minute\_$second';
  }

  /// Parse timestamp string to DateTime
  DateTime get dateTime {
    try {
      String datePart = timestamp.substring(0, 10); // YYYY-MM-DD
      String timePart = timestamp.substring(11); // HH:MM_ss

      // Replace underscore with colon
      timePart = timePart.replaceAll('_', ':');

      return DateTime.parse('${datePart}T$timePart');
    } catch (e) {
      return DateTime.now();
    }
  }

  /// Get display time (HH:MM format)
  String get displayTime {
    if (timestamp.length < 16) return '';
    return timestamp.substring(11, 16); // HH:MM
  }

  /// Get display date (YYYY-MM-DD)
  String get displayDate {
    if (timestamp.length < 10) return '';
    return timestamp.substring(0, 10); // YYYY-MM-DD
  }

  /// Check if post has file attachment
  bool get hasFile => metadata.containsKey('file');

  /// Get attached filename (full name with SHA1 prefix)
  String? get attachedFile => metadata['file'];

  /// Get display filename (without SHA1 prefix)
  /// Format: {sha1}_{original_filename} -> original_filename
  String? get displayFileName {
    if (!hasFile) return null;
    final fullName = metadata['file']!;

    // Check if file follows SHA1 naming convention
    final underscoreIndex = fullName.indexOf('_');
    if (underscoreIndex > 0 && underscoreIndex == 40) {
      // SHA1 is 40 characters, followed by underscore
      return fullName.substring(41);
    }

    // Fallback to full name if not in expected format
    return fullName;
  }

  /// Check if post has location
  bool get hasLocation =>
      metadata.containsKey('lat') && metadata.containsKey('lon');

  /// Get latitude
  double? get latitude {
    if (!metadata.containsKey('lat')) return null;
    return double.tryParse(metadata['lat']!);
  }

  /// Get longitude
  double? get longitude {
    if (!metadata.containsKey('lon')) return null;
    return double.tryParse(metadata['lon']!);
  }

  /// Check if post quotes another post
  bool get hasQuote => metadata.containsKey('quote');

  /// Get quoted post timestamp
  String? get quotedTimestamp => metadata['quote'];

  /// Check if post has poll
  bool get hasPoll => metadata.containsKey('Poll');

  /// Get poll question
  String? get pollQuestion => metadata['Poll'];

  /// Check if post has NOSTR signature
  bool get isSigned =>
      metadata.containsKey('signature') && metadata.containsKey('npub');

  /// Get NOSTR public key
  String? get npub => metadata['npub'];

  /// Get signature
  String? get signature => metadata['signature'];

  /// Export post as text format for file storage
  String exportAsText() {
    StringBuffer buffer = StringBuffer();

    // For original posts, content comes first (no post marker)
    // For replies, add post marker
    if (!isOriginalPost) {
      buffer.writeln('> $timestamp -- $author');
    }

    // Content
    if (content.isNotEmpty) {
      buffer.writeln(content);
    }

    // Metadata (signature must be last)
    final metadataKeys = metadata.keys.toList();

    // Separate signature from other metadata
    final signature = metadata['signature'];
    final npub = metadata['npub'];
    final otherKeys =
        metadataKeys.where((k) => k != 'signature' && k != 'npub').toList();

    // Write other metadata first
    for (var key in otherKeys) {
      buffer.writeln('--> $key: ${metadata[key]}');
    }

    // Write npub before signature
    if (npub != null) {
      buffer.writeln('--> npub: $npub');
    }

    // Write signature last
    if (signature != null) {
      buffer.writeln('--> signature: $signature');
    }

    return buffer.toString();
  }

  /// Create from JSON
  factory ForumPost.fromJson(Map<String, dynamic> json) {
    return ForumPost(
      author: json['author'] as String,
      timestamp: json['timestamp'] as String,
      content: json['content'] as String,
      isOriginalPost: json['is_original_post'] as bool? ?? false,
      metadata: (json['metadata'] as Map<String, dynamic>?)?.map(
            (k, v) => MapEntry(k, v.toString()),
          ) ??
          {},
    );
  }

  /// Convert to JSON
  Map<String, dynamic> toJson() {
    return {
      'author': author,
      'timestamp': timestamp,
      'content': content,
      'is_original_post': isOriginalPost,
      'metadata': metadata,
    };
  }

  /// Compare by timestamp for sorting
  @override
  int compareTo(ForumPost other) {
    return dateTime.compareTo(other.dateTime);
  }

  /// Copy with modifications
  ForumPost copyWith({
    String? author,
    String? timestamp,
    String? content,
    bool? isOriginalPost,
    Map<String, String>? metadata,
  }) {
    return ForumPost(
      author: author ?? this.author,
      timestamp: timestamp ?? this.timestamp,
      content: content ?? this.content,
      isOriginalPost: isOriginalPost ?? this.isOriginalPost,
      metadata: metadata ?? Map.from(this.metadata),
    );
  }
}
