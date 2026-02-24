/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'reaction_utils.dart';

/// Unified chat message text format parser and exporter.
///
/// Format specification:
/// ```
/// # ROOM_ID: Chat from YYYY-MM-DD
///
///
/// > YYYY-MM-DD HH:MM_ss -- CALLSIGN
/// Message content here
/// --> file: filename.jpg
/// --> lat: 38.123
/// --> lon: -9.456
/// --> created_at: 1732109412
/// --> npub: npub1...
/// --> signature: hex...
/// ~~> reaction: 👍=USER1,USER2
///
///
/// > YYYY-MM-DD HH:MM_ss -- CALLSIGN2
/// Another message
/// ```
///
/// Key rules:
/// - Two empty lines between messages for readability
/// - Header: `> YYYY-MM-DD HH:MM_ss -- CALLSIGN`
/// - Content: all non-metadata lines after header (empty lines skipped)
/// - Metadata: `--> key: value` lines
/// - Unsigned reactions: `~~> reaction: emoji=USER1,USER2`
/// - Field order: content metadata, created_at, npub, signature (signature ALWAYS last)
class ChatFormat {
  /// Parse messages from chat file content
  ///
  /// Returns list of parsed messages with all metadata preserved.
  /// Handles both client and server format variations gracefully.
  static List<ParsedChatMessage> parse(String content) {
    // Split by message header pattern: "> 2" (year 2xxx)
    final sections = content.split(RegExp(r'\n> 2'));
    final messages = <ParsedChatMessage>[];

    // First section is the header, skip it
    for (int i = 1; i < sections.length; i++) {
      try {
        // Restore the "2" prefix that was removed by split
        final section = '2${sections[i]}';
        final message = _parseSection(section);
        if (message != null) {
          messages.add(message);
        }
      } catch (e) {
        // Skip malformed messages, continue parsing
        continue;
      }
    }

    return messages;
  }

  /// Parse a single message section
  static ParsedChatMessage? _parseSection(String section) {
    final lines = section.split('\n');
    if (lines.isEmpty) return null;

    // Parse header: "YYYY-MM-DD HH:MM_ss -- CALLSIGN"
    final header = lines[0].trim();
    if (header.length < 23) return null;

    // Find the " -- " separator
    final separatorIdx = header.indexOf(' -- ');
    if (separatorIdx < 19) return null;

    final timestamp = header.substring(0, 19).trim();
    final author = header.substring(separatorIdx + 4).trim();

    if (timestamp.isEmpty || author.isEmpty) return null;

    // Parse content and metadata
    final contentBuffer = StringBuffer();
    final metadata = <String, String>{};
    final reactions = <String, List<String>>{};
    bool inContent = true;

    for (int i = 1; i < lines.length; i++) {
      final line = lines[i];
      final trimmed = line.trim();

      // Unsigned reaction line: ~~> reaction: emoji=USER1,USER2
      if (trimmed.startsWith('~~> ')) {
        final unsignedLine = trimmed.substring(4);
        if (unsignedLine.startsWith('reaction:')) {
          _parseReaction(unsignedLine.substring(9).trim(), reactions);
        }
        continue;
      }

      // Metadata line: --> key: value
      if (trimmed.startsWith('--> ')) {
        inContent = false;
        final metaLine = trimmed.substring(4);
        final colonIdx = metaLine.indexOf(': ');
        if (colonIdx > 0) {
          final key = metaLine.substring(0, colonIdx).trim();
          final value = metaLine.substring(colonIdx + 2).trim();

          // Handle reaction in metadata (legacy format)
          if (key == 'reaction') {
            _parseReaction(value, reactions);
          } else {
            metadata[key] = value;
          }
        }
        continue;
      }

      // Content line - only add non-empty lines
      // This is the key fix: empty lines are message separators, not content
      if (inContent && trimmed.isNotEmpty) {
        if (contentBuffer.isNotEmpty) {
          contentBuffer.write('\n');
        }
        // Preserve original line (not trimmed) for proper indentation
        contentBuffer.write(line);
      }
    }

    return ParsedChatMessage(
      author: author,
      timestamp: timestamp,
      content: contentBuffer.toString().trim(),
      metadata: metadata,
      reactions: ReactionUtils.normalizeReactionMap(reactions),
    );
  }

  /// Parse reaction string "emoji=USER1,USER2" into reactions map
  static void _parseReaction(String value, Map<String, List<String>> reactions) {
    final eqIdx = value.indexOf('=');
    if (eqIdx <= 0) return;

    final emoji = ReactionUtils.normalizeReactionKey(value.substring(0, eqIdx).trim());
    final usersPart = value.substring(eqIdx + 1).trim();

    if (emoji.isEmpty) return;

    final users = usersPart.isEmpty
        ? <String>[]
        : usersPart
            .split(',')
            .map((u) => u.trim().toUpperCase())
            .where((u) => u.isNotEmpty)
            .toSet()
            .toList();

    if (users.isNotEmpty) {
      final existing = reactions[emoji] ?? [];
      reactions[emoji] = {...existing, ...users}.toList();
    }
  }

  /// Export a single message to text format
  ///
  /// Field order:
  /// 1. Header: > timestamp -- author
  /// 2. Content
  /// 3. File/location metadata (file, file_size, lat, lon, voice, duration, sha1, etc.)
  /// 4. created_at (for signature verification)
  /// 5. npub (public key)
  /// 6. signature (MUST be last for verification)
  /// 7. Reactions (unsigned, ~~> prefix)
  static String export(ParsedChatMessage message) {
    final buffer = StringBuffer();

    // Header
    buffer.writeln('> ${message.timestamp} -- ${message.author}');

    // Content
    if (message.content.isNotEmpty) {
      buffer.writeln(message.content);
    }

    // Reserved keys with special ordering or that should be excluded
    const reservedKeys = {
      'Poll',
      'edited_at',
      'created_at',
      'npub',
      'signature',
      'verified',
      'has_signature',
    };

    // Regular metadata (file, lat, lon, voice, duration, sha1, quote, etc.)
    for (final entry in message.metadata.entries) {
      if (reservedKeys.contains(entry.key)) continue;
      buffer.writeln('--> ${entry.key}: ${entry.value}');
    }

    // edited_at before npub/signature
    if (message.metadata.containsKey('edited_at')) {
      buffer.writeln('--> edited_at: ${message.metadata['edited_at']}');
    }

    // created_at (needed for signature verification)
    if (message.metadata.containsKey('created_at')) {
      buffer.writeln('--> created_at: ${message.metadata['created_at']}');
    }

    // npub before signature
    if (message.metadata.containsKey('npub')) {
      buffer.writeln('--> npub: ${message.metadata['npub']}');
    }

    // signature MUST be last (for verification)
    if (message.metadata.containsKey('signature')) {
      buffer.writeln('--> signature: ${message.metadata['signature']}');
    }

    // Unsigned reactions (~~> prefix)
    if (message.reactions.isNotEmpty) {
      final normalized = ReactionUtils.normalizeReactionMap(message.reactions);
      final keys = normalized.keys.toList()..sort();
      for (final key in keys) {
        final users = normalized[key] ?? [];
        if (users.isEmpty) continue;
        buffer.writeln('~~> reaction: $key=${users.join(',')}');
      }
    }

    return buffer.toString().trimRight();
  }

  /// Export multiple messages with proper separators
  ///
  /// [header] - Optional file header (e.g., "# ROOM: Chat from 2025-01-15")
  /// Returns formatted text with two empty lines between messages
  static String exportAll(
    List<ParsedChatMessage> messages, {
    String? header,
  }) {
    final buffer = StringBuffer();

    // File header
    if (header != null) {
      buffer.writeln(header);
    }

    // Messages with two empty lines between each
    for (final msg in messages) {
      buffer.writeln();
      buffer.writeln();
      buffer.write(export(msg));
    }

    return buffer.toString();
  }

  /// Format DateTime to chat timestamp format: YYYY-MM-DD HH:MM_ss
  static String formatTimestamp(DateTime dt) {
    final year = dt.year.toString().padLeft(4, '0');
    final month = dt.month.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    final second = dt.second.toString().padLeft(2, '0');

    return '$year-$month-$day $hour:$minute'
        '_$second';
  }

  /// Convert Unix epoch (seconds) to chat timestamp string (UTC).
  static String epochToTimestamp(int epochRaw) {
    var epoch = epochRaw;
    if (epoch > 1000000000000) {
      epoch = (epoch / 1000).round();
    }
    if (epoch <= 0) {
      return formatTimestamp(DateTime.now().toUtc());
    }
    final dt = DateTime.fromMillisecondsSinceEpoch(epoch * 1000, isUtc: true);
    return formatTimestamp(dt);
  }

  /// Normalize a raw timestamp value (string, num, or epoch) to chat format.
  static String normalizeTimestamp(dynamic rawTimestamp) {
    if (rawTimestamp is String && rawTimestamp.isNotEmpty) {
      if (rawTimestamp.contains('-') && rawTimestamp.contains('_')) {
        return rawTimestamp;
      }
      // Try ISO 8601 parse
      final dtParsed = DateTime.tryParse(rawTimestamp);
      if (dtParsed != null) {
        // If no timezone indicator ('Z' or '+'/'-' offset), assume UTC.
        // DateTime.tryParse treats bare strings as local time, which
        // produces different results on machines in different timezones.
        final dtUtc = dtParsed.isUtc
            ? dtParsed
            : DateTime.utc(
                dtParsed.year, dtParsed.month, dtParsed.day,
                dtParsed.hour, dtParsed.minute, dtParsed.second,
              );
        return formatTimestamp(dtUtc);
      }
      // Numeric string
      final parsed = int.tryParse(rawTimestamp);
      if (parsed != null) {
        return epochToTimestamp(parsed);
      }
      return rawTimestamp;
    }
    if (rawTimestamp is num) {
      return epochToTimestamp(rawTimestamp.toInt());
    }
    return formatTimestamp(DateTime.now().toUtc());
  }

  /// Parse timestamp string to DateTime (UTC)
  static DateTime parseTimestamp(String timestamp) {
    try {
      // Format: YYYY-MM-DD HH:MM_ss
      final datePart = timestamp.substring(0, 10);
      final timePart = timestamp.substring(11);

      final dateParts = datePart.split('-');
      final timeParts = timePart.split(RegExp(r'[_:]'));

      return DateTime.utc(
        int.parse(dateParts[0]),
        int.parse(dateParts[1]),
        int.parse(dateParts[2]),
        int.parse(timeParts[0]),
        int.parse(timeParts[1]),
        int.parse(timeParts[2]),
      );
    } catch (e) {
      return DateTime.now().toUtc();
    }
  }

  /// Generate file header for a chat file
  static String generateHeader(String roomId, String dateStr) {
    return '# ${roomId.toUpperCase()}: $roomId from $dateStr';
  }
}

/// Parsed chat message data class
///
/// This is a simple data container used for parsing/exporting.
/// Different from ChatMessage model classes in client/server which have
/// additional business logic.
class ParsedChatMessage {
  final String author;
  final String timestamp;
  final String content;
  final Map<String, String> metadata;
  final Map<String, List<String>> reactions;

  ParsedChatMessage({
    required this.author,
    required this.timestamp,
    required this.content,
    Map<String, String>? metadata,
    Map<String, List<String>>? reactions,
  })  : metadata = metadata ?? {},
        reactions = reactions ?? {};

  /// Get metadata value
  String? getMeta(String key) => metadata[key];

  /// Check if has metadata key
  bool hasMeta(String key) => metadata.containsKey(key);

  /// Check if message has file attachment
  bool get hasFile => hasMeta('file');

  /// Check if message is signed
  bool get isSigned =>
      hasMeta('signature') && metadata['signature']!.isNotEmpty;

  /// Check if message has signature (from API response)
  bool get hasSignature =>
      getMeta('has_signature') == 'true' || hasMeta('signature');

  /// Get npub
  String? get npub => getMeta('npub');

  /// Get signature
  String? get signature => getMeta('signature');

  /// Get created_at Unix timestamp
  int? get createdAt => int.tryParse(getMeta('created_at') ?? '');

  /// Convert to DateTime
  DateTime get dateTime {
    // Prefer created_at Unix timestamp if available
    final unix = createdAt;
    if (unix != null) {
      return DateTime.fromMillisecondsSinceEpoch(unix * 1000, isUtc: true);
    }
    // Fall back to parsing timestamp string
    return ChatFormat.parseTimestamp(timestamp);
  }

  /// Get date portion (YYYY-MM-DD)
  String get datePortion => timestamp.substring(0, 10);

  /// Get time portion (HH:MM_ss)
  String get timePortion =>
      timestamp.length > 11 ? timestamp.substring(11) : '';

  /// Create copy with modified fields
  ParsedChatMessage copyWith({
    String? author,
    String? timestamp,
    String? content,
    Map<String, String>? metadata,
    Map<String, List<String>>? reactions,
  }) {
    return ParsedChatMessage(
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
    return other is ParsedChatMessage &&
        other.author == author &&
        other.timestamp == timestamp &&
        other.content == content;
  }

  @override
  int get hashCode => Object.hash(author, timestamp, content);

  @override
  String toString() {
    return 'ParsedChatMessage(author: $author, timestamp: $timestamp, '
        'content: ${content.length > 30 ? '${content.substring(0, 30)}...' : content})';
  }
}
