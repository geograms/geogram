/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * NOSTR Event Implementation (NIP-01)
 * https://github.com/nostr-protocol/nips/blob/master/01.md
 */

import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:hex/hex.dart';
import 'nostr_crypto.dart';
import '../models/report.dart';

/// NOSTR Event kinds
class NostrEventKind {
  static const int setMetadata = 0;
  static const int textNote = 1;
  static const int recommendServer = 2;
  static const int contacts = 3;
  static const int encryptedDirectMessage = 4;
  static const int deletion = 5;
  static const int repost = 6;
  static const int reaction = 7;
  static const int channelCreation = 40;
  static const int channelMetadata = 41;
  static const int channelMessage = 42;
  static const int channelHideMessage = 43;
  static const int channelMuteUser = 44;
  /// NIP-78: Application-specific data (parameterized replaceable)
  /// Used for Geogram alerts
  static const int applicationSpecificData = 30078;
}

/// NOSTR Event structure (NIP-01)
class NostrEvent {
  /// 32-byte lowercase hex event id
  String? id;

  /// 32-byte lowercase hex public key of the event creator
  final String pubkey;

  /// Unix timestamp in seconds
  final int createdAt;

  /// Event kind (1 = text note for chat messages)
  final int kind;

  /// Array of arrays of strings (tags)
  final List<List<String>> tags;

  /// Arbitrary string content
  final String content;

  /// 64-byte lowercase hex Schnorr signature
  String? sig;

  NostrEvent({
    this.id,
    required this.pubkey,
    required this.createdAt,
    required this.kind,
    required this.tags,
    required this.content,
    this.sig,
  });

  /// Create a text note event (kind 1) for chat messages
  factory NostrEvent.textNote({
    required String pubkeyHex,
    required String content,
    List<List<String>>? tags,
    int? createdAt,
  }) {
    return NostrEvent(
      pubkey: pubkeyHex,
      createdAt: createdAt ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000),
      kind: NostrEventKind.textNote,
      tags: tags ?? [],
      content: content,
    );
  }

  /// Create a channel message event (kind 42) for public chat rooms
  factory NostrEvent.channelMessage({
    required String pubkeyHex,
    required String content,
    required String channelId,
    String? replyToEventId,
    List<List<String>>? additionalTags,
    int? createdAt,
  }) {
    final tags = <List<String>>[
      ['e', channelId, '', 'root'],
    ];

    if (replyToEventId != null) {
      tags.add(['e', replyToEventId, '', 'reply']);
    }

    if (additionalTags != null) {
      tags.addAll(additionalTags);
    }

    return NostrEvent(
      pubkey: pubkeyHex,
      createdAt: createdAt ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000),
      kind: NostrEventKind.channelMessage,
      tags: tags,
      content: content,
    );
  }

  /// Create hello event for WebSocket connection
  /// Optionally includes location coordinates for distance calculation
  factory NostrEvent.createHello({
    required String npub,
    required String callsign,
    String? nickname,
    String? color,
    double? latitude,
    double? longitude,
    String? platform,
  }) {
    // Convert npub to pubkey hex
    final pubkeyHex = NostrCrypto.decodeNpub(npub);
    final tags = <List<String>>[
      ['t', 'hello'],
      ['callsign', callsign],
    ];
    // Include nickname if provided and not empty (for friendly URL support)
    if (nickname != null && nickname.isNotEmpty) {
      tags.add(['nickname', nickname]);
    }
    // Include preferred color if set
    if (color != null && color.isNotEmpty) {
      tags.add(['color', color]);
    }
    // Include location if both coordinates are provided
    if (latitude != null && longitude != null) {
      tags.add(['latitude', latitude.toString()]);
      tags.add(['longitude', longitude.toString()]);
    }
    // Include platform if provided
    if (platform != null && platform.isNotEmpty) {
      tags.add(['platform', platform]);
    }
    // Build content with platform name
    final platformName = platform ?? 'Desktop';
    return NostrEvent(
      pubkey: pubkeyHex,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      kind: NostrEventKind.textNote,
      tags: tags,
      content: 'Hello from Geogram $platformName',
    );
  }

  /// Create alert event (kind 30078) for sharing reports to relays
  ///
  /// This creates a NIP-78 application-specific event with:
  /// - d tag: folderName (makes it a parameterized replaceable event)
  /// - g tag: coordinates
  /// - t tag: "alert"
  /// - severity, status, type tags: for filtering
  /// - expires tag: expiration timestamp (if set)
  /// - content: full report.txt text
  factory NostrEvent.alert({
    required String pubkeyHex,
    required Report report,
    int? createdAt,
  }) {
    final tags = <List<String>>[
      // d tag makes this a parameterized replaceable event (same d = replacement)
      ['d', report.folderName],
      // Geolocation tag
      ['g', '${report.latitude},${report.longitude}'],
      // Type tags for filtering
      ['t', 'alert'],
      ['severity', report.severity.name],
      ['status', report.status.toFileString()],
      ['type', report.type],
    ];

    // Add expiration if set
    if (report.expires != null) {
      final expDateTime = report.expirationDateTime;
      if (expDateTime != null) {
        tags.add(['expires', (expDateTime.millisecondsSinceEpoch ~/ 1000).toString()]);
      }
    }

    return NostrEvent(
      pubkey: pubkeyHex,
      createdAt: createdAt ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000),
      kind: NostrEventKind.applicationSpecificData,
      tags: tags,
      content: report.exportAsText(),
    );
  }

  /// Serialize event for hashing (NIP-01 format)
  /// [0, pubkey, created_at, kind, tags, content]
  String _serialize() {
    return jsonEncode([
      0,
      pubkey,
      createdAt,
      kind,
      tags,
      content,
    ]);
  }

  /// Calculate event ID (SHA256 of serialized event)
  String calculateId() {
    final serialized = _serialize();
    final bytes = utf8.encode(serialized);
    final hash = sha256.convert(bytes);
    id = hash.toString();
    return id!;
  }

  /// Sign event with private key using BIP-340 Schnorr signature
  String sign(String privateKeyHex) {
    if (id == null) {
      calculateId();
    }

    // Sign the event ID with Schnorr signature
    sig = NostrCrypto.schnorrSign(id!, privateKeyHex);
    return sig!;
  }

  /// Sign event with nsec (bech32 encoded private key)
  String signWithNsec(String nsec) {
    final privateKeyHex = NostrCrypto.decodeNsec(nsec);
    return sign(privateKeyHex);
  }

  /// Verify event signature
  bool verify() {
    if (id == null || sig == null) {
      return false;
    }

    // Recalculate ID to ensure it matches
    final calculatedId = sha256.convert(utf8.encode(_serialize())).toString();
    if (calculatedId != id) {
      return false;
    }

    // Verify Schnorr signature
    return NostrCrypto.schnorrVerify(id!, sig!, pubkey);
  }

  /// Convert to JSON for transmission
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'pubkey': pubkey,
      'created_at': createdAt,
      'kind': kind,
      'tags': tags,
      'content': content,
      'sig': sig,
    };
  }

  /// Create from JSON
  factory NostrEvent.fromJson(Map<String, dynamic> json) {
    return NostrEvent(
      id: json['id'] as String?,
      pubkey: json['pubkey'] as String,
      createdAt: json['created_at'] as int,
      kind: json['kind'] as int,
      tags: (json['tags'] as List)
          .map((t) => (t as List).map((e) => e.toString()).toList())
          .toList(),
      content: json['content'] as String,
      sig: json['sig'] as String?,
    );
  }

  /// Get npub from pubkey
  String get npub => NostrCrypto.encodeNpub(pubkey);

  /// Get callsign derived from pubkey (X1 + first 4 chars of npub after 'npub1')
  String get callsign => 'X1${NostrCrypto.deriveCallsign(pubkey)}';

  /// Get tag value by tag name
  String? getTagValue(String tagName) {
    for (final tag in tags) {
      if (tag.isNotEmpty && tag[0] == tagName && tag.length > 1) {
        return tag[1];
      }
    }
    return null;
  }

  /// Get all tag values by tag name
  List<String> getTagValues(String tagName) {
    final values = <String>[];
    for (final tag in tags) {
      if (tag.isNotEmpty && tag[0] == tagName && tag.length > 1) {
        values.add(tag[1]);
      }
    }
    return values;
  }

  /// Check if this is a signed event
  bool get isSigned => sig != null && sig!.isNotEmpty;

  /// Get created_at as DateTime
  DateTime get createdAtDateTime =>
      DateTime.fromMillisecondsSinceEpoch(createdAt * 1000);

  /// Format timestamp as HH:MM
  String get formattedTime {
    final dt = createdAtDateTime;
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  /// Format timestamp as YYYY-MM-DD HH:MM_ss (geogram format)
  String get geogramTimestamp {
    final dt = createdAtDateTime;
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}_${dt.second.toString().padLeft(2, '0')}';
  }

  @override
  String toString() =>
      'NostrEvent(id: ${id?.substring(0, 8)}..., kind: $kind, pubkey: ${pubkey.substring(0, 8)}...)';
}

/// NOSTR station message types
class NostrRelayMessage {
  /// Create EVENT message for publishing
  static List<dynamic> event(NostrEvent event) {
    return ['EVENT', event.toJson()];
  }

  /// Create REQ message for subscribing
  static List<dynamic> req(String subscriptionId, Map<String, dynamic> filter) {
    return ['REQ', subscriptionId, filter];
  }

  /// Create CLOSE message for unsubscribing
  static List<dynamic> close(String subscriptionId) {
    return ['CLOSE', subscriptionId];
  }

  /// Parse incoming station message
  static NostrRelayResponse? parse(String message) {
    try {
      final json = jsonDecode(message) as List;
      if (json.isEmpty) return null;

      final type = json[0] as String;

      switch (type) {
        case 'EVENT':
          if (json.length >= 3) {
            return NostrRelayResponse(
              type: NostrRelayResponseType.event,
              subscriptionId: json[1] as String,
              event: NostrEvent.fromJson(json[2] as Map<String, dynamic>),
            );
          }
          break;
        case 'OK':
          if (json.length >= 3) {
            return NostrRelayResponse(
              type: NostrRelayResponseType.ok,
              eventId: json[1] as String,
              success: json[2] as bool,
              message: json.length > 3 ? json[3] as String? : null,
            );
          }
          break;
        case 'EOSE':
          if (json.length >= 2) {
            return NostrRelayResponse(
              type: NostrRelayResponseType.eose,
              subscriptionId: json[1] as String,
            );
          }
          break;
        case 'NOTICE':
          if (json.length >= 2) {
            return NostrRelayResponse(
              type: NostrRelayResponseType.notice,
              message: json[1] as String,
            );
          }
          break;
      }
      return null;
    } catch (e) {
      return null;
    }
  }
}

/// Response types from NOSTR station
enum NostrRelayResponseType {
  event,
  ok,
  eose,
  notice,
}

/// Parsed response from NOSTR station
class NostrRelayResponse {
  final NostrRelayResponseType type;
  final String? subscriptionId;
  final NostrEvent? event;
  final String? eventId;
  final bool? success;
  final String? message;

  NostrRelayResponse({
    required this.type,
    this.subscriptionId,
    this.event,
    this.eventId,
    this.success,
    this.message,
  });
}
