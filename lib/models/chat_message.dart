/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import '../util/chat_format.dart';
import '../util/reaction_utils.dart';

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

  /// Unsigned reactions stored outside the signed block
  final Map<String, List<String>> reactions;

  ChatMessage({
    required this.author,
    required this.timestamp,
    required this.content,
    this.messageType = ChatMessageType.simple,
    Map<String, String>? metadata,
    Map<String, List<String>>? reactions,
  }) : metadata = metadata ?? {},
       reactions = reactions ?? {};

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
    Map<String, List<String>>? reactions,
  }) {
    final now = DateTime.now();
    final timestamp = ChatFormat.formatTimestamp(now);

    return ChatMessage(
      author: author,
      timestamp: timestamp,
      content: content,
      metadata: metadata,
      reactions: reactions,
    );
  }

  DateTime? get _createdAtDateTime {
    final createdAt = getMeta('created_at');
    if (createdAt == null) return null;

    final parsed = int.tryParse(createdAt);
    if (parsed == null || parsed <= 0) return null;

    final epochMs = parsed > 1000000000000 ? parsed : parsed * 1000;
    return DateTime.fromMillisecondsSinceEpoch(epochMs, isUtc: true).toLocal();
  }

  String _formatDatePart(DateTime dt) {
    final year = dt.year.toString().padLeft(4, '0');
    final month = dt.month.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }

  String _formatTimePart(DateTime dt) {
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    final second = dt.second.toString().padLeft(2, '0');
    return '$hour:$minute'
        '_$second';
  }

  /// Parse timestamp string to DateTime
  DateTime get dateTime {
    final createdAt = _createdAtDateTime;
    if (createdAt != null) {
      return createdAt;
    }

    try {
      // Legacy fallback: older locally generated messages stored local wall-clock
      // timestamps directly in the raw chat timestamp field.
      final normalized = timestamp.replaceAll('_', ':');
      final parsed = DateTime.tryParse(normalized);
      if (parsed != null) {
        return parsed;
      }

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
      try {
        return ChatFormat.parseTimestamp(timestamp).toLocal();
      } catch (_) {
        // Fallback to current time if parsing fails
        return DateTime.now();
      }
    }
  }

  /// Get date portion (YYYY-MM-DD) from timestamp
  String get datePortion => _formatDatePart(dateTime);

  /// Get time portion (HH:MM_ss) from timestamp
  String get timePortion => _formatTimePart(dateTime);

  /// Get formatted time for display (HH:MM)
  String get displayTime {
    final dt = dateTime;
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
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

  /// Check if message is a voice message
  bool get hasVoice => hasMeta('voice');

  /// Get voice filename
  String? get voiceFile => getMeta('voice');

  /// Get voice duration in seconds (from 'duration' metadata)
  int? get voiceDuration {
    final dur = getMeta('duration');
    return dur != null ? int.tryParse(dur) : null;
  }

  /// Get voice file SHA1 hash (for integrity verification)
  String? get voiceSha1 => getMeta('sha1');

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
  bool get hasSignature =>
      getMeta('has_signature') == 'true' || hasMeta('signature');

  /// Get NOSTR signature
  String? get signature => getMeta('signature');

  /// Check if signature was verified by server
  bool get isVerified => getMeta('verified') == 'true';

  /// Get author's npub
  String? get npub => getMeta('npub');

  /// Get edited_at timestamp (if message was edited)
  String? get editedAt => getMeta('edited_at');

  /// Check if message has been edited
  bool get isEdited => hasMeta('edited_at');

  /// Get message delivery status (for DMs)
  MessageStatus? get deliveryStatus {
    final status = getMeta('status');
    if (status == null) return null;
    return MessageStatus.values.firstWhere(
      (s) => s.name == status,
      orElse: () =>
          MessageStatus.delivered, // Legacy messages assumed delivered
    );
  }

  /// Check if message is pending delivery
  bool get isPending => deliveryStatus == MessageStatus.pending;

  /// Check if message was delivered
  bool get isDelivered =>
      deliveryStatus == MessageStatus.delivered || deliveryStatus == null;

  /// Check if message delivery failed
  bool get isFailed => deliveryStatus == MessageStatus.failed;

  /// Set message delivery status
  void setDeliveryStatus(MessageStatus status) {
    setMeta('status', status.name);
  }

  /// Check if message quotes another message
  bool get isQuote =>
      hasMeta('quote') || hasMeta('quote_author') || hasMeta('quote_excerpt');

  /// Get quoted message timestamp
  String? get quotedMessage => getMeta('quote');

  /// Get quoted message author (optional)
  String? get quotedAuthor => getMeta('quote_author');

  /// Get quoted message excerpt (optional)
  String? get quotedExcerpt => getMeta('quote_excerpt');

  /// Check if message is a system message (e.g. retention change notice)
  bool get isSystemMessage => getMeta('system') == 'true';

  /// Check if message is a poll
  bool get isPoll => hasMeta('Poll');

  /// Get poll question
  String? get pollQuestion => getMeta('Poll');

  /// Export message as text following the chat format specification
  /// Format:
  /// > YYYY-MM-DD HH:MM_ss -- CALLSIGN
  /// Content goes here
  /// --> metadata_key: metadata_value
  /// --> edited_at: timestamp (if edited, before npub/signature)
  /// --> npub: bech32_key (before signature)
  /// --> signature: hex_signature (if signed, must be last)
  String exportAsText() {
    StringBuffer buffer = StringBuffer();
    const postSignatureKeys = {
      'status',
      'delivery_state',
      'retry_count',
      'queued_at',
    };

    // Header: > YYYY-MM-DD HH:MM_ss -- CALLSIGN
    buffer.writeln('> $timestamp -- $author');

    // Special case for polls (put Poll metadata first for readability)
    if (isPoll) {
      buffer.writeln('--> Poll: $pollQuestion');
    }

    // Content
    if (content.isNotEmpty) {
      buffer.writeln(content);
    }

    // Reserved keys that have special ordering or should be excluded
    // - verified/has_signature: useless in export - verification happens at load time
    //   (anyone could edit the file and set verified=true, defeating the purpose)
    // - created_at: written in specific order (needed for signature verification)
    const reservedKeys = {
      'Poll',
      'edited_at',
      'created_at',
      'npub',
      'signature',
      'verified',
      'has_signature',
    };

    // Metadata (excluding reserved keys which have special ordering or are excluded)
    for (var entry in metadata.entries) {
      if (reservedKeys.contains(entry.key)) {
        continue; // Skip reserved keys - they're written in specific order or excluded
      }
      if (postSignatureKeys.contains(entry.key)) {
        continue; // Unsigned metadata goes after signature
      }
      buffer.writeln('--> ${entry.key}: ${entry.value}');
    }

    // edited_at comes before npub/signature (if present)
    if (isEdited) {
      buffer.writeln('--> edited_at: $editedAt');
    }

    // created_at (needed for signature verification)
    if (hasMeta('created_at')) {
      buffer.writeln('--> created_at: ${getMeta('created_at')}');
    }

    // npub comes before signature (if present)
    if (hasMeta('npub')) {
      buffer.writeln('--> npub: $npub');
    }

    // Signature must be last if present
    if (isSigned) {
      buffer.writeln('--> signature: $signature');
    }

    // Unsigned metadata (post-signature allowlist)
    for (final key in const [
      'status',
      'delivery_state',
      'retry_count',
      'queued_at',
    ]) {
      if (metadata.containsKey(key)) {
        buffer.writeln('--> $key: ${metadata[key]}');
      }
    }

    if (reactions.isNotEmpty) {
      final normalized = ReactionUtils.normalizeReactionMap(reactions);
      final keys = normalized.keys.toList()..sort();
      for (final key in keys) {
        final users = normalized[key] ?? [];
        if (users.isEmpty) continue;
        buffer.writeln('~~> reaction: $key=${users.join(',')}');
      }
    }

    return buffer.toString().trim();
  }

  /// Create ChatMessage from JSON
  /// Handles both the chat file format (metadata-based) and API format (direct properties)
  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final rawReactions = json['reactions'] as Map?;
    final reactions = <String, List<String>>{};
    if (rawReactions != null) {
      rawReactions.forEach((key, value) {
        if (value is List) {
          reactions[key.toString()] = value
              .map((entry) => entry.toString())
              .toList();
        }
      });
    }

    // Start with metadata from JSON
    final rawMetadata = json['metadata'] as Map?;
    final metadata = rawMetadata != null
        ? rawMetadata.map(
            (key, value) => MapEntry(key.toString(), value.toString()),
          )
        : <String, String>{};

    // Merge direct API fields into metadata (API format compatibility)
    if (json['latitude'] != null) {
      metadata['lat'] = json['latitude'].toString();
    }
    if (json['longitude'] != null) {
      metadata['lon'] = json['longitude'].toString();
    }
    if (json['npub'] != null && !metadata.containsKey('npub')) {
      metadata['npub'] = json['npub'].toString();
    }
    if (json['signature'] != null && !metadata.containsKey('signature')) {
      metadata['signature'] = json['signature'].toString();
    }
    if (json['verified'] == true) {
      metadata['verified'] = 'true';
    }

    return ChatMessage(
      author: (json['author'] ?? json['callsign'] ?? 'Unknown').toString(),
      timestamp: ChatFormat.normalizeTimestamp(json['timestamp']),
      content: (json['content'] ?? json['text'] ?? '').toString(),
      messageType: ChatMessageType.values.firstWhere(
        (type) => type.name == (json['messageType'] as String? ?? 'simple'),
        orElse: () => ChatMessageType.simple,
      ),
      metadata: metadata,
      reactions: ReactionUtils.normalizeReactionMap(reactions),
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
      'reactions': reactions,
    };
  }

  /// Sort messages by timestamp, then author, then content
  @override
  int compareTo(ChatMessage other) {
    // Primary sort: resolved display time. This keeps locally-authored legacy
    // timestamps and signed created_at-based timestamps in the same order.
    int cmp = dateTime.compareTo(other.dateTime);
    if (cmp != 0) return cmp;

    // Secondary sort: raw timestamp for stability
    cmp = timestamp.compareTo(other.timestamp);
    if (cmp != 0) return cmp;

    // Tertiary sort: author
    cmp = author.compareTo(other.author);
    if (cmp != 0) return cmp;

    // Final sort: content
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
    final preview = content.length > 50
        ? '${content.substring(0, 50)}...'
        : content;
    return 'ChatMessage(author: $author, timestamp: $timestamp, '
        'content: $preview, '
        'metadata: $metadata)';
  }

  /// Create a copy with modified fields
  ChatMessage copyWith({
    String? author,
    String? timestamp,
    String? content,
    ChatMessageType? messageType,
    Map<String, String>? metadata,
    Map<String, List<String>>? reactions,
  }) {
    return ChatMessage(
      author: author ?? this.author,
      timestamp: timestamp ?? this.timestamp,
      content: content ?? this.content,
      messageType: messageType ?? this.messageType,
      metadata: metadata ?? Map<String, String>.from(this.metadata),
      reactions: reactions ?? Map<String, List<String>>.from(this.reactions),
    );
  }
}

/// Message type enumeration
enum ChatMessageType {
  simple, // Regular text message
  poll, // Poll message
  announcement, // System announcement
}

/// Message delivery status for DMs
enum MessageStatus {
  pending, // Saved locally, awaiting remote confirmation
  delivered, // HTTP 200 received from remote device
  failed, // HTTP error or timeout
}
