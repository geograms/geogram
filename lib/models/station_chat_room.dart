import '../util/reaction_utils.dart';

/// Model for a chat room from a remote station
class StationChatRoom {
  final String id;
  final String name;
  final String description;
  final int messageCount;
  final String stationUrl;
  final String stationName;
  final bool isModerator;

  StationChatRoom({
    required this.id,
    required this.name,
    this.description = '',
    this.messageCount = 0,
    required this.stationUrl,
    this.stationName = '',
    this.isModerator = false,
  });

  factory StationChatRoom.fromJson(
    Map<String, dynamic> json,
    String stationUrl,
    String stationName,
  ) {
    final rawMessageCount =
        json['message_count'] ?? json['messageCount'] ?? json['count'];
    final messageCount = rawMessageCount is int
        ? rawMessageCount
        : int.tryParse(rawMessageCount?.toString() ?? '') ?? 0;

    return StationChatRoom(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      messageCount: messageCount,
      stationUrl: stationUrl,
      stationName: stationName,
      isModerator: json['isModerator'] == true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'message_count': messageCount,
      'station_url': stationUrl,
      'station_name': stationName,
    };
  }

  /// Get the HTTP base URL for API calls
  String get httpBaseUrl {
    return stationUrl
        .replaceFirst('ws://', 'http://')
        .replaceFirst('wss://', 'https://');
  }

  StationChatRoom copyWith({String? name, String? description}) {
    return StationChatRoom(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      messageCount: messageCount,
      stationUrl: stationUrl,
      stationName: stationName,
      isModerator: isModerator,
    );
  }

  @override
  String toString() =>
      'StationChatRoom(id: $id, name: $name, station: $stationName)';
}

/// Model for a message from a station chat room
class StationChatMessage {
  final String timestamp;
  final String callsign;
  final String content;
  final String roomId;
  final Map<String, String> metadata;
  final Map<String, List<String>> reactions;
  final String? npub; // Author's NOSTR public key (bech32)
  final String? pubkey; // Author's public key (hex)
  final String? signature; // Message signature (BIP-340 Schnorr)
  final String? eventId; // NOSTR event ID
  final int? createdAt; // Unix timestamp in seconds
  final bool verified; // Server-side signature verification result
  final bool hasSignature; // Whether message has a signature

  StationChatMessage({
    required this.timestamp,
    required this.callsign,
    required this.content,
    required this.roomId,
    Map<String, String>? metadata,
    Map<String, List<String>>? reactions,
    this.npub,
    this.pubkey,
    this.signature,
    this.eventId,
    this.createdAt,
    this.verified = false,
    this.hasSignature = false,
  }) : metadata = metadata ?? {},
       reactions = reactions ?? {};

  factory StationChatMessage.fromJson(
    Map<String, dynamic> json,
    String roomId,
  ) {
    final rawMetadata = json['metadata'] as Map?;
    final metadata = rawMetadata != null
        ? rawMetadata.map(
            (key, value) => MapEntry(key.toString(), value.toString()),
          )
        : <String, String>{};
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
    final npub = json['npub']?.toString() ?? metadata['npub'];
    final signature = json['signature']?.toString() ?? metadata['signature'];
    final eventId = json['event_id']?.toString() ?? metadata['event_id'];
    final createdAt =
        _normalizeEpoch(json['created_at']) ??
        (metadata['created_at'] != null
            ? int.tryParse(metadata['created_at']!)
            : null);
    final verified =
        (json['verified'] as bool?) ?? (metadata['verified'] == 'true');
    final hasSignature =
        (json['has_signature'] as bool?) ??
        (signature != null && signature.isNotEmpty);

    if (npub != null && npub.isNotEmpty) {
      metadata['npub'] = npub;
    }
    if (signature != null && signature.isNotEmpty) {
      metadata['signature'] = signature;
    }
    if (eventId != null && eventId.isNotEmpty) {
      metadata['event_id'] = eventId;
    }
    if (createdAt != null) {
      metadata['created_at'] = createdAt.toString();
    }
    if (verified) {
      metadata['verified'] = 'true';
    }

    return StationChatMessage(
      timestamp: _normalizeTimestamp(json['timestamp']),
      callsign: (json['callsign'] ?? json['author'] ?? '').toString(),
      content: (json['content'] ?? json['text'] ?? '').toString(),
      roomId: roomId,
      metadata: metadata,
      reactions: ReactionUtils.normalizeReactionMap(reactions),
      npub: npub,
      pubkey: json['pubkey']?.toString(),
      signature: signature,
      eventId: eventId,
      createdAt: createdAt,
      verified: verified,
      hasSignature: hasSignature,
    );
  }

  static int? _normalizeEpoch(dynamic raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw);
    return null;
  }

  static String _normalizeTimestamp(dynamic rawTimestamp) {
    if (rawTimestamp is String && rawTimestamp.isNotEmpty) {
      if (rawTimestamp.contains('-') && rawTimestamp.contains('_')) {
        return rawTimestamp;
      }

      final parsed = int.tryParse(rawTimestamp);
      if (parsed != null) {
        return _epochToChatTimestamp(parsed);
      }

      return rawTimestamp;
    }

    if (rawTimestamp is num) {
      return _epochToChatTimestamp(rawTimestamp.toInt());
    }

    return _epochToChatTimestamp(DateTime.now().millisecondsSinceEpoch ~/ 1000);
  }

  static String _epochToChatTimestamp(int epochRaw) {
    var epoch = epochRaw;
    if (epoch > 1000000000000) {
      epoch = (epoch / 1000).round();
    }

    if (epoch <= 0) {
      epoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    }

    final dt = DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
    final year = dt.year.toString().padLeft(4, '0');
    final month = dt.month.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    final second = dt.second.toString().padLeft(2, '0');
    return '$year-$month-$day $hour:$minute\_$second';
  }

  /// Create from a NOSTR event
  factory StationChatMessage.fromNostrEvent(
    Map<String, dynamic> eventJson,
    String roomId,
  ) {
    final pubkey = eventJson['pubkey'] as String? ?? '';
    final createdAt = eventJson['created_at'] as int? ?? 0;
    final content = eventJson['content'] as String? ?? '';
    final tags = (eventJson['tags'] as List?)?.cast<List>() ?? [];

    // Extract callsign from tags or derive from pubkey
    String callsign = '';
    for (final tag in tags) {
      if (tag.isNotEmpty && tag[0] == 'callsign' && tag.length > 1) {
        callsign = tag[1] as String;
        break;
      }
    }
    if (callsign.isEmpty && pubkey.isNotEmpty) {
      // Derive callsign from pubkey (first 6 chars formatted)
      callsign = 'X1${pubkey.substring(0, 4).toUpperCase()}';
    }

    // Format timestamp in geogram format
    final dt = DateTime.fromMillisecondsSinceEpoch(createdAt * 1000);
    final timestamp =
        '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}_${dt.second.toString().padLeft(2, '0')}';

    return StationChatMessage(
      timestamp: timestamp,
      callsign: callsign,
      content: content,
      roomId: roomId,
      metadata: const <String, String>{},
      reactions: const <String, List<String>>{},
      pubkey: pubkey,
      signature: eventJson['sig'] as String?,
      eventId: eventJson['id'] as String?,
      createdAt: createdAt,
    );
  }

  /// Check if message is signed
  bool get isSigned => signature != null && signature!.isNotEmpty;

  /// Parse the timestamp to DateTime
  DateTime? get dateTime {
    try {
      // Format: YYYY-MM-DD HH:MM_ss
      final parts = timestamp.split(' ');
      if (parts.length != 2) return null;

      final dateParts = parts[0].split('-');
      final timeParts = parts[1].replaceAll('_', ':').split(':');

      if (dateParts.length != 3 || timeParts.length != 3) return null;

      return DateTime(
        int.parse(dateParts[0]),
        int.parse(dateParts[1]),
        int.parse(dateParts[2]),
        int.parse(timeParts[0]),
        int.parse(timeParts[1]),
        int.parse(timeParts[2]),
      );
    } catch (e) {
      return null;
    }
  }

  /// Get formatted time (HH:MM)
  String get formattedTime {
    final dt = dateTime;
    if (dt == null) return timestamp;
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  /// Get formatted date (YYYY-MM-DD)
  String get formattedDate {
    if (timestamp.length >= 10) {
      return timestamp.substring(0, 10);
    }
    return '';
  }
}
