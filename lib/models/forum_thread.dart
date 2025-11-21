/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Represents a forum thread
class ForumThread implements Comparable<ForumThread> {
  /// Unique thread identifier (filename without extension)
  final String id;

  /// Thread title
  final String title;

  /// Section this thread belongs to
  final String sectionId;

  /// Original poster's callsign
  final String author;

  /// Thread creation timestamp
  final DateTime created;

  /// Last reply timestamp (for sorting)
  DateTime lastReply;

  /// Number of replies (excluding original post)
  int replyCount;

  /// File path to thread file
  final String? filePath;

  /// Whether thread is pinned
  bool isPinned;

  /// Whether thread is locked (no new replies)
  bool isLocked;

  ForumThread({
    required this.id,
    required this.title,
    required this.sectionId,
    required this.author,
    required this.created,
    DateTime? lastReply,
    this.replyCount = 0,
    this.filePath,
    this.isPinned = false,
    this.isLocked = false,
  }) : lastReply = lastReply ?? created;

  /// Create from thread file header
  factory ForumThread.fromHeader({
    required String id,
    required String title,
    required String sectionId,
    required String author,
    required DateTime created,
    String? filePath,
  }) {
    return ForumThread(
      id: id,
      title: title,
      sectionId: sectionId,
      author: author,
      created: created,
      lastReply: created,
      replyCount: 0,
      filePath: filePath,
    );
  }

  /// Create from JSON
  factory ForumThread.fromJson(Map<String, dynamic> json) {
    return ForumThread(
      id: json['id'] as String,
      title: json['title'] as String,
      sectionId: json['section_id'] as String,
      author: json['author'] as String,
      created: DateTime.parse(json['created'] as String),
      lastReply: json['last_reply'] != null
          ? DateTime.parse(json['last_reply'] as String)
          : null,
      replyCount: json['reply_count'] as int? ?? 0,
      filePath: json['file_path'] as String?,
      isPinned: json['is_pinned'] as bool? ?? false,
      isLocked: json['is_locked'] as bool? ?? false,
    );
  }

  /// Convert to JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'section_id': sectionId,
      'author': author,
      'created': created.toIso8601String(),
      'last_reply': lastReply.toIso8601String(),
      'reply_count': replyCount,
      if (filePath != null) 'file_path': filePath,
      'is_pinned': isPinned,
      'is_locked': isLocked,
    };
  }

  /// Compare by last reply for sorting (most recent first)
  @override
  int compareTo(ForumThread other) {
    // Pinned threads always come first
    if (isPinned && !other.isPinned) return -1;
    if (!isPinned && other.isPinned) return 1;

    // Then sort by last reply (newest first)
    return other.lastReply.compareTo(lastReply);
  }

  /// Update last reply timestamp and count
  void addReply(DateTime timestamp) {
    lastReply = timestamp;
    replyCount++;
  }

  /// Get formatted last reply time for display
  String get formattedLastReply {
    final now = DateTime.now();
    final difference = now.difference(lastReply);

    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes}m ago';
    } else if (difference.inHours < 24) {
      return '${difference.inHours}h ago';
    } else if (difference.inDays < 7) {
      return '${difference.inDays}d ago';
    } else {
      final month = lastReply.month.toString().padLeft(2, '0');
      final day = lastReply.day.toString().padLeft(2, '0');
      return '${lastReply.year}-$month-$day';
    }
  }

  /// Get subtitle text for thread list
  String get subtitle {
    return '$author • ${formattedLastReply} • $replyCount ${replyCount == 1 ? "reply" : "replies"}';
  }

  /// Copy with modifications
  ForumThread copyWith({
    String? id,
    String? title,
    String? sectionId,
    String? author,
    DateTime? created,
    DateTime? lastReply,
    int? replyCount,
    String? filePath,
    bool? isPinned,
    bool? isLocked,
  }) {
    return ForumThread(
      id: id ?? this.id,
      title: title ?? this.title,
      sectionId: sectionId ?? this.sectionId,
      author: author ?? this.author,
      created: created ?? this.created,
      lastReply: lastReply ?? this.lastReply,
      replyCount: replyCount ?? this.replyCount,
      filePath: filePath ?? this.filePath,
      isPinned: isPinned ?? this.isPinned,
      isLocked: isLocked ?? this.isLocked,
    );
  }
}
