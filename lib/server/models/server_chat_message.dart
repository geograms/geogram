/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Server-side chat message model for station servers.
 * Used for in-memory message storage with NOSTR signature support.
 */

import '../../cli/commands/service_interfaces.dart';
import '../../util/reaction_utils.dart';

/// Server-side chat message for station servers.
///
/// This model is used by station servers (CLI and GUI) for storing
/// chat messages with NOSTR signature verification support.
///
/// Storage format only requires: timestamp, callsign, content, npub, signature
/// Event ID and verification status are recalculated from these fields.
///
/// For client-side chat message parsing, see `lib/models/chat_message.dart`.
/// For API response DTOs, see `lib/api/endpoints/chat_api.dart`.
class ServerChatMessage implements ChatMessageReadable {
  /// NOSTR event ID (calculated from content)
  final String id;

  /// Room ID this message belongs to
  final String roomId;

  /// Sender's callsign
  final String senderCallsign;

  /// NOSTR public key (bech32) - human readable
  final String? senderNpub;

  /// BIP-340 Schnorr signature
  final String? signature;

  /// Message content
  final String content;

  /// Message timestamp (UTC)
  final DateTime timestamp;

  /// Signature verified (runtime, not stored)
  final bool verified;

  /// Has valid signature
  final bool hasSignature;

  /// Emoji reactions: emoji -> list of callsigns
  final Map<String, List<String>> reactions;

  /// File attachments, voice messages, etc.
  final Map<String, String> metadata;

  ServerChatMessage({
    required this.id,
    required this.roomId,
    required this.senderCallsign,
    this.senderNpub,
    this.signature,
    required this.content,
    DateTime? timestamp,
    this.verified = false,
    bool? hasSignature,
    Map<String, List<String>>? reactions,
    Map<String, String>? metadata,
  })  : timestamp = timestamp ?? DateTime.now().toUtc(),
        hasSignature =
            hasSignature ?? (signature != null && signature.isNotEmpty),
        reactions = reactions ?? {},
        metadata = metadata ?? {};

  factory ServerChatMessage.fromJson(Map<String, dynamic> json, String roomId) {
    final sig = json['signature'] as String?;
    // Parse timestamp as UTC for consistent handling
    DateTime? parsedTime;
    if (json['timestamp'] != null) {
      parsedTime = DateTime.tryParse(json['timestamp'] as String);
      // Ensure it's treated as UTC if not already
      if (parsedTime != null && !parsedTime.isUtc) {
        parsedTime = parsedTime.toUtc();
      }
    }
    final rawReactions = json['reactions'] as Map?;
    final reactions = <String, List<String>>{};
    if (rawReactions != null) {
      rawReactions.forEach((key, value) {
        if (value is List) {
          reactions[key.toString()] =
              value.map((entry) => entry.toString()).toList();
        }
      });
    }

    // Parse metadata
    final rawMetadata = json['metadata'] as Map?;
    final metadata = <String, String>{};
    if (rawMetadata != null) {
      rawMetadata.forEach((key, value) {
        metadata[key.toString()] = value.toString();
      });
    }

    return ServerChatMessage(
      id: json['id'] as String? ??
          DateTime.now().millisecondsSinceEpoch.toString(),
      roomId: json['room_id'] as String? ?? roomId,
      senderCallsign: json['sender'] as String? ??
          json['callsign'] as String? ??
          'Unknown',
      senderNpub: json['npub'] as String?,
      signature: sig,
      content: json['content'] as String? ?? '',
      timestamp: parsedTime ?? DateTime.now().toUtc(),
      verified: json['verified'] as bool? ?? false,
      hasSignature:
          json['has_signature'] as bool? ?? (sig != null && sig.isNotEmpty),
      reactions: ReactionUtils.normalizeReactionMap(reactions),
      metadata: metadata,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'room_id': roomId,
        'callsign': senderCallsign,
        if (senderNpub != null) 'npub': senderNpub,
        if (signature != null) 'signature': signature,
        'content': content,
        'timestamp': timestamp.toIso8601String(),
        'created_at': timestamp.millisecondsSinceEpoch ~/
            1000, // Unix timestamp for signature verification
        'verified': verified,
        'has_signature': hasSignature,
        if (reactions.isNotEmpty) 'reactions': reactions,
        if (metadata.isNotEmpty) 'metadata': metadata,
      };
}
