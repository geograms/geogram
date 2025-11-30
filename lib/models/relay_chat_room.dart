/// Model for a chat room from a remote relay
class RelayChatRoom {
  final String id;
  final String name;
  final String description;
  final int messageCount;
  final String relayUrl;
  final String relayName;

  RelayChatRoom({
    required this.id,
    required this.name,
    this.description = '',
    this.messageCount = 0,
    required this.relayUrl,
    this.relayName = '',
  });

  factory RelayChatRoom.fromJson(Map<String, dynamic> json, String relayUrl, String relayName) {
    return RelayChatRoom(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      messageCount: json['message_count'] as int? ?? 0,
      relayUrl: relayUrl,
      relayName: relayName,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'message_count': messageCount,
      'relay_url': relayUrl,
      'relay_name': relayName,
    };
  }

  /// Get the HTTP base URL for API calls
  String get httpBaseUrl {
    return relayUrl
        .replaceFirst('ws://', 'http://')
        .replaceFirst('wss://', 'https://');
  }

  @override
  String toString() => 'RelayChatRoom(id: $id, name: $name, relay: $relayName)';
}

/// Model for a message from a relay chat room
class RelayChatMessage {
  final String timestamp;
  final String callsign;
  final String content;
  final String roomId;
  final String? npub;      // Author's NOSTR public key (bech32)
  final String? pubkey;    // Author's public key (hex)
  final String? signature; // Message signature (BIP-340 Schnorr)
  final String? eventId;   // NOSTR event ID
  final int? createdAt;    // Unix timestamp in seconds
  final bool verified;     // Server-side signature verification result
  final bool hasSignature; // Whether message has a signature

  RelayChatMessage({
    required this.timestamp,
    required this.callsign,
    required this.content,
    required this.roomId,
    this.npub,
    this.pubkey,
    this.signature,
    this.eventId,
    this.createdAt,
    this.verified = false,
    this.hasSignature = false,
  });

  factory RelayChatMessage.fromJson(Map<String, dynamic> json, String roomId) {
    return RelayChatMessage(
      timestamp: json['timestamp'] as String? ?? '',
      callsign: json['callsign'] as String? ?? '',
      content: json['content'] as String? ?? '',
      roomId: roomId,
      npub: json['npub'] as String?,
      pubkey: json['pubkey'] as String?,
      signature: json['signature'] as String?,
      eventId: json['event_id'] as String?,
      createdAt: json['created_at'] as int?,
      verified: json['verified'] as bool? ?? false,
      hasSignature: json['has_signature'] as bool? ?? false,
    );
  }

  /// Create from a NOSTR event
  factory RelayChatMessage.fromNostrEvent(
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
    final timestamp = '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}_${dt.second.toString().padLeft(2, '0')}';

    return RelayChatMessage(
      timestamp: timestamp,
      callsign: callsign,
      content: content,
      roomId: roomId,
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
