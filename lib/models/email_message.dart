/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Email Message Model - Represents a single message within an email thread
 */

import '../util/chat_format.dart';
import '../util/reaction_utils.dart';

/// Represents a single message within an email thread.
///
/// Follows the same format as chat messages:
/// ```
/// > YYYY-MM-DD HH:MM_ss -- CALLSIGN
/// Message content here
/// --> file: attachment.pdf
/// --> npub: npub1...
/// --> signature: hex...
/// ```
class EmailMessage implements Comparable<EmailMessage> {
  /// Author's callsign (e.g., X1ALICE)
  final String author;

  /// Timestamp in format: YYYY-MM-DD HH:MM_ss
  final String timestamp;

  /// Message content (can be multi-line, markdown supported)
  final String content;

  /// Metadata key-value pairs (file, lat, lon, npub, signature, etc.)
  final Map<String, String> metadata;

  /// Reactions (unsigned, stored outside signature block)
  final Map<String, List<String>> reactions;

  EmailMessage({
    required this.author,
    required this.timestamp,
    required this.content,
    Map<String, String>? metadata,
    Map<String, List<String>>? reactions,
  })  : metadata = metadata ?? {},
        reactions = reactions ?? {};

  /// Create message with current timestamp
  factory EmailMessage.now({
    required String author,
    required String content,
    Map<String, String>? metadata,
  }) {
    return EmailMessage(
      author: author,
      timestamp: ChatFormat.formatTimestamp(DateTime.now()),
      content: content,
      metadata: metadata,
    );
  }

  /// Parse timestamp string to DateTime
  DateTime get dateTime {
    try {
      final datePart = timestamp.substring(0, 10);
      final timePart = timestamp.substring(11);
      final dateParts = datePart.split('-');
      final timeParts = timePart.split(RegExp(r'[_:]'));
      return DateTime(
        int.parse(dateParts[0]),
        int.parse(dateParts[1]),
        int.parse(dateParts[2]),
        int.parse(timeParts[0]),
        int.parse(timeParts[1]),
        int.parse(timeParts[2]),
      );
    } catch (e) {
      return DateTime.now();
    }
  }

  /// Get date portion (YYYY-MM-DD)
  String get datePortion => timestamp.substring(0, 10);

  /// Get time portion (HH:MM_ss)
  String get timePortion => timestamp.substring(11);

  /// Get display time (HH:MM)
  String get displayTime {
    try {
      final parts = timePortion.split(RegExp(r'[_:]'));
      return '${parts[0]}:${parts[1]}';
    } catch (e) {
      return timePortion;
    }
  }

  // Metadata helpers
  String? getMeta(String key) => metadata[key];
  bool hasMeta(String key) => metadata.containsKey(key);
  void setMeta(String key, String value) => metadata[key] = value;

  // File attachment
  bool get hasFile => hasMeta('file');
  String? get attachedFile => getMeta('file');

  /// Display filename without SHA1 prefix
  String? get displayFileName {
    if (!hasFile) return null;
    final fullName = getMeta('file')!;
    final underscoreIndex = fullName.indexOf('_');
    if (underscoreIndex == 40) {
      return fullName.substring(41);
    }
    return fullName;
  }

  // Image attachment
  bool get hasImage => hasMeta('image');
  String? get attachedImage => getMeta('image');

  // Voice message
  bool get hasVoice => hasMeta('voice');
  String? get voiceFile => getMeta('voice');
  int? get voiceDuration {
    final dur = getMeta('duration');
    return dur != null ? int.tryParse(dur) : null;
  }

  // Location
  bool get hasLocation => hasMeta('lat') && hasMeta('lon');
  double? get latitude => double.tryParse(getMeta('lat') ?? '');
  double? get longitude => double.tryParse(getMeta('lon') ?? '');

  // NOSTR signature
  bool get isSigned => hasMeta('signature') && metadata['signature']!.isNotEmpty;
  bool get hasSignature => getMeta('has_signature') == 'true' || hasMeta('signature');
  String? get signature => getMeta('signature');
  String? get npub => getMeta('npub');
  bool get isVerified => getMeta('verified') == 'true';
  int? get createdAt => int.tryParse(getMeta('created_at') ?? '');

  // Edited
  bool get isEdited => hasMeta('edited_at');
  String? get editedAt => getMeta('edited_at');

  /// Verification state for display
  EmailVerificationState get verificationState {
    if (!hasSignature && npub == null) {
      return EmailVerificationState.unverified;
    }
    if (isVerified) {
      return EmailVerificationState.verified;
    }
    if (isSigned && !isVerified) {
      return EmailVerificationState.pending;
    }
    return EmailVerificationState.unverified;
  }

  /// Export message as text
  String exportAsText() {
    final buffer = StringBuffer();

    // Header
    buffer.writeln('> $timestamp -- $author');

    // Content
    if (content.isNotEmpty) {
      buffer.writeln(content);
    }

    // Reserved keys with special ordering
    const reservedKeys = {
      'edited_at',
      'created_at',
      'npub',
      'signature',
      'verified',
      'has_signature',
    };

    // Regular metadata
    for (final entry in metadata.entries) {
      if (reservedKeys.contains(entry.key)) continue;
      buffer.writeln('--> ${entry.key}: ${entry.value}');
    }

    // edited_at before npub/signature
    if (isEdited) {
      buffer.writeln('--> edited_at: $editedAt');
    }

    // created_at (for signature verification)
    if (hasMeta('created_at')) {
      buffer.writeln('--> created_at: ${getMeta('created_at')}');
    }

    // npub before signature
    if (hasMeta('npub')) {
      buffer.writeln('--> npub: $npub');
    }

    // signature MUST be last
    if (isSigned) {
      buffer.writeln('--> signature: $signature');
    }

    // Reactions (unsigned)
    if (reactions.isNotEmpty) {
      final normalized = ReactionUtils.normalizeReactionMap(reactions);
      final keys = normalized.keys.toList()..sort();
      for (final key in keys) {
        final users = normalized[key] ?? [];
        if (users.isEmpty) continue;
        buffer.writeln('~~> reaction: $key=${users.join(',')}');
      }
    }

    return buffer.toString().trimRight();
  }

  /// Create from JSON
  factory EmailMessage.fromJson(Map<String, dynamic> json) {
    final rawReactions = json['reactions'] as Map?;
    final reactions = <String, List<String>>{};
    if (rawReactions != null) {
      rawReactions.forEach((key, value) {
        if (value is List) {
          reactions[key.toString()] = value.map((e) => e.toString()).toList();
        }
      });
    }

    final rawMetadata = json['metadata'] as Map?;
    final metadata = rawMetadata != null
        ? rawMetadata.map((k, v) => MapEntry(k.toString(), v.toString()))
        : <String, String>{};

    return EmailMessage(
      author: json['author'] as String? ?? 'Unknown',
      timestamp: json['timestamp'] as String? ?? '',
      content: json['content'] as String? ?? '',
      metadata: metadata,
      reactions: ReactionUtils.normalizeReactionMap(reactions),
    );
  }

  /// Convert to JSON
  Map<String, dynamic> toJson() => {
        'author': author,
        'timestamp': timestamp,
        'content': content,
        'metadata': metadata,
        'reactions': reactions,
      };

  /// Sort by timestamp
  @override
  int compareTo(EmailMessage other) {
    int cmp = timestamp.compareTo(other.timestamp);
    if (cmp != 0) return cmp;
    cmp = author.compareTo(other.author);
    if (cmp != 0) return cmp;
    return content.compareTo(other.content);
  }

  /// Create a copy with modified fields
  EmailMessage copyWith({
    String? author,
    String? timestamp,
    String? content,
    Map<String, String>? metadata,
    Map<String, List<String>>? reactions,
  }) {
    return EmailMessage(
      author: author ?? this.author,
      timestamp: timestamp ?? this.timestamp,
      content: content ?? this.content,
      metadata: metadata ?? Map<String, String>.from(this.metadata),
      reactions: reactions ?? Map<String, List<String>>.from(this.reactions),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is EmailMessage &&
        other.author == author &&
        other.timestamp == timestamp &&
        other.content == content;
  }

  @override
  int get hashCode => Object.hash(author, timestamp, content);

  @override
  String toString() =>
      'EmailMessage(author: $author, timestamp: $timestamp, '
      'content: ${content.length > 50 ? '${content.substring(0, 50)}...' : content})';
}

/// Email signature verification state
enum EmailVerificationState {
  /// No signature present (external email)
  unverified,

  /// Signature present but not yet verified
  pending,

  /// Signature verified successfully
  verified,

  /// Signature verification failed
  invalid,

  /// Signature valid but npub doesn't match sender
  mismatch,
}
