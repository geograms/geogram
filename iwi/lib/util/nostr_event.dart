/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * NOSTR Event Implementation (NIP-01)
 * https://github.com/nostr-protocol/nips/blob/master/01.md
 *
 * Vendored from geogram/lib/util/nostr_event.dart — stripped of the
 * `NostrEvent.alert` factory (which depended on the parent project's
 * Report model) and of the NostrRelayMessage/Response helpers (iwi
 * doesn't talk to relays yet). Keep in sync with the parent until a
 * shared package lands.
 */

import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'nostr_crypto.dart';

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

  /// NIP-78: Application-specific data (parameterized replaceable).
  /// Used for geogram wapp signatures.
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

  /// Event kind
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

  /// Sign event with private key (hex) using BIP-340 Schnorr signature
  String sign(String privateKeyHex) {
    if (id == null) {
      calculateId();
    }
    sig = NostrCrypto.schnorrSign(id!, privateKeyHex);
    return sig!;
  }

  /// Sign event with nsec (bech32 encoded private key)
  String signWithNsec(String nsec) {
    final privateKeyHex = NostrCrypto.decodeNsec(nsec);
    return sign(privateKeyHex);
  }

  /// Verify event signature. Recalculates the id from (pubkey, tags,
  /// content, etc) and checks the Schnorr signature against it.
  bool verify() {
    if (id == null || sig == null) return false;
    final calculatedId =
        sha256.convert(utf8.encode(_serialize())).toString();
    if (calculatedId != id) return false;
    return NostrCrypto.schnorrVerify(id!, sig!, pubkey);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'pubkey': pubkey,
        'created_at': createdAt,
        'kind': kind,
        'tags': tags,
        'content': content,
        'sig': sig,
      };

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

  /// Check if this is a signed event
  bool get isSigned => sig != null && sig!.isNotEmpty;
}
