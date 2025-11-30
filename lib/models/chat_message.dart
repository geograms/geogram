/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Represents a single chat message following the Geogram chat format specification
class ChatMessage implements Comparable<ChatMessage> {
  /// Author's callsign (e.g., CR7BBQ, X135AS)
  final String author;

  /// Timestamp in format: YYYY-MM-DD HH:MM_ss (e.g., 2025-11-20 19:10_12)
  final String timestamp;

  /// Message content (can be multi-line)
  final String content;

  /// Message type (currently only SIMPLE supported)
  final ChatMessageType messageType;

  /// Metadata key-value pairs (file, lat, lon, quote, npub, signature, etc.)
  final Map<String, String> metadata;

  ChatMessage({
    required this.author,
    required this.timestamp,
    required this.content,
    this.messageType = ChatMessageType.simple,
    Map<String, String>? metadata,
  }) : metadata = metadata ?? {};

  /// Create a simple message without metadata
  factory ChatMessage.simple({
    required String author,
    required String timestamp,
    required String content,
  }) {
    return ChatMessage(
      author: author,
      timestamp: timestamp,
      content: content,
      messageType: ChatMessageType.simple,
    );
  }

  /// Create message from current time
  factory ChatMessage.now({
    required String author,
    required String content,
    Map<String, String>? metadata,
  }) {
    final now = DateTime.now();
    final timestamp = _formatTimestamp(now);

    return ChatMessage(
      author: author,
      timestamp: timestamp,
      content: content,
      metadata: metadata,
    );
  }

  /// Format DateTime to chat timestamp format: YYYY-MM-DD HH:MM_ss
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
      // Format: YYYY-MM-DD HH:MM_ss
      String datePart = timestamp.substring(0, 10); // YYYY-MM-DD
      String timePart = timestamp.substring(11); // HH:MM_ss

      List<String> dateParts = datePart.split('-');
      List<String> timeParts = timePart.split(RegExp(r'[_:]'));

      return DateTime(
        int.parse(dateParts[0]), // year
        int.parse(dateParts[1]), // month
        int.parse(dateParts[2]), // day
        int.parse(timeParts[0]), // hour
        int.parse(timeParts[1]), // minute
        int.parse(timeParts[2]), // second
      );
    } catch (e) {
      // Fallback to current time if parsing fails
      return DateTime.now();
    }
  }

  /// Get date portion (YYYY-MM-DD) from timestamp
  String get datePortion => timestamp.substring(0, 10);

  /// Get time portion (HH:MM_ss) from timestamp
  String get timePortion => timestamp.substring(11);

  /// Get formatted time for display (HH:MM)
  String get displayTime {
    try {
      List<String> parts = timePortion.split(RegExp(r'[_:]'));
      return '${parts[0]}:${parts[1]}';
    } catch (e) {
      return timePortion;
    }
  }

  /// Get metadata value by key
  String? getMeta(String key) => metadata[key];

  /// Check if message has specific metadata
  bool hasMeta(String key) => metadata.containsKey(key);

  /// Add or update metadata
  void setMeta(String key, String value) {
    metadata[key] = value;
  }

  /// Check if message has file attachment
  bool get hasFile => hasMeta('file');

  /// Get attached filename (full name with SHA1 prefix)
  String? get attachedFile => getMeta('file');

  /// Get display filename (without SHA1 prefix)
  /// Format: {sha1}_{original_filename} -> original_filename
  String? get displayFileName {
    if (!hasFile) return null;
    final fullName = getMeta('file')!;

    // Check if file follows SHA1 naming convention
    final underscoreIndex = fullName.indexOf('_');
    if (underscoreIndex > 0 && underscoreIndex == 40) {
      // SHA1 is 40 characters, followed by underscore
      return fullName.substring(41);
    }

    // Fallback to full name if not in expected format
    return fullName;
  }

  /// Check if message has location
  bool get hasLocation => hasMeta('lat') && hasMeta('lon');

  /// Get latitude
  double? get latitude {
    try {
      return double.parse(getMeta('lat') ?? '');
    } catch (e) {
      return null;
    }
  }

  /// Get longitude
  double? get longitude {
    try {
      return double.parse(getMeta('lon') ?? '');
    } catch (e) {
      return null;
    }
  }

  /// Check if message is signed (has signature metadata)
  bool get isSigned => hasMeta('signature') || hasMeta('has_signature');

  /// Check if message has signature (from API response)
  bool get hasSignature => getMeta('has_signature') == 'true' || hasMeta('signature');

  /// Get NOSTR signature
  String? get signature => getMeta('signature');

  /// Check if signature was verified by server
  bool get isVerified => getMeta('verified') == 'true';

  /// Get author's npub
  String? get npub => getMeta('npub');

  /// Check if message quotes another message
  bool get isQuote => hasMeta('quote');

  /// Get quoted message timestamp
  String? get quotedMessage => getMeta('quote');

  /// Check if message is a poll
  bool get isPoll => hasMeta('Poll');

  /// Get poll question
  String? get pollQuestion => getMeta('Poll');

  /// Export message as text following the chat format specification
  /// Format:
  /// > YYYY-MM-DD HH:MM_ss -- CALLSIGN
  /// Content goes here
  /// --> metadata_key: metadata_value
  /// --> signature: hex_signature (if signed, must be last)
  String exportAsText() {
    StringBuffer buffer = StringBuffer();

    // Header: > YYYY-MM-DD HH:MM_ss -- CALLSIGN
    buffer.writeln('> $timestamp -- $author');

    // Special case for polls (put Poll metadata first for readability)
    if (isPoll) {
      buffer.writeln('--> Poll: ${pollQuestion}');
    }

    // Content
    if (content.isNotEmpty) {
      buffer.writeln(content);
    }

    // Metadata (excluding Poll if already written, and signature which goes last)
    for (var entry in metadata.entries) {
      if (entry.key == 'Poll' || entry.key == 'signature') {
        continue; // Skip Poll (already written) and signature (goes last)
      }
      buffer.writeln('--> ${entry.key}: ${entry.value}');
    }

    // Signature must be last if present
    if (isSigned) {
      buffer.writeln('--> signature: $signature');
    }

    return buffer.toString().trim();
  }

  /// Create ChatMessage from JSON
  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      author: json['author'] as String,
      timestamp: json['timestamp'] as String,
      content: json['content'] as String? ?? '',
      messageType: ChatMessageType.values.firstWhere(
        (type) => type.name == (json['messageType'] as String? ?? 'simple'),
        orElse: () => ChatMessageType.simple,
      ),
      metadata: Map<String, String>.from(json['metadata'] as Map? ?? {}),
    );
  }

  /// Convert ChatMessage to JSON
  Map<String, dynamic> toJson() {
    return {
      'author': author,
      'timestamp': timestamp,
      'content': content,
      'messageType': messageType.name,
      'metadata': metadata,
    };
  }

  /// Sort messages by timestamp, then author, then content
  @override
  int compareTo(ChatMessage other) {
    // Primary sort: timestamp
    int cmp = timestamp.compareTo(other.timestamp);
    if (cmp != 0) return cmp;

    // Secondary sort: author
    cmp = author.compareTo(other.author);
    if (cmp != 0) return cmp;

    // Tertiary sort: content
    return content.compareTo(other.content);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ChatMessage &&
        other.author == author &&
        other.timestamp == timestamp &&
        other.content == content;
  }

  @override
  int get hashCode => Object.hash(author, timestamp, content);

  @override
  String toString() {
    return 'ChatMessage(author: $author, timestamp: $timestamp, '
        'content: ${content.length > 50 ? content.substring(0, 50) + '...' : content}, '
        'metadata: $metadata)';
  }

  /// Create a copy with modified fields
  ChatMessage copyWith({
    String? author,
    String? timestamp,
    String? content,
    ChatMessageType? messageType,
    Map<String, String>? metadata,
  }) {
    return ChatMessage(
      author: author ?? this.author,
      timestamp: timestamp ?? this.timestamp,
      content: content ?? this.content,
      messageType: messageType ?? this.messageType,
      metadata: metadata ?? Map<String, String>.from(this.metadata),
    );
  }
}

/// Message type enumeration
enum ChatMessageType {
  simple, // Regular text message
  poll, // Poll message
  announcement, // System announcement
}
