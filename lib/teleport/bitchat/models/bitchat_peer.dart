/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * BitChat peer identity — a discovered peer in the mesh.
 */

class BitchatPeer {
  /// Static public key hex (X25519, 32 bytes = 64 hex chars).
  final String publicKeyHex;

  /// Signing public key hex (Ed25519).
  final String signingPublicKeyHex;

  /// Display nickname.
  final String nickname;

  /// Last time this peer was seen.
  final DateTime? lastSeen;

  /// Geohash where this peer was last seen.
  final String geohash;

  /// Whether this peer's identity has been verified.
  final bool verified;

  const BitchatPeer({
    required this.publicKeyHex,
    this.signingPublicKeyHex = '',
    this.nickname = '',
    this.lastSeen,
    this.geohash = '',
    this.verified = false,
  });

  /// Short sender ID (first 8 bytes = 16 hex chars).
  String get senderId => publicKeyHex.length >= 16
      ? publicKeyHex.substring(0, 16)
      : publicKeyHex;

  /// Human-readable fingerprint (first 4 bytes, colon-separated).
  String get fingerprint {
    if (publicKeyHex.length < 8) return publicKeyHex;
    final bytes = publicKeyHex.substring(0, 8);
    return '${bytes.substring(0, 2)}:${bytes.substring(2, 4)}'
        ':${bytes.substring(4, 6)}:${bytes.substring(6, 8)}';
  }

  /// Display name: nickname if available, otherwise truncated key.
  String get displayName =>
      nickname.isNotEmpty ? nickname : '${senderId.substring(0, 8)}...';

  Map<String, dynamic> toJson() => {
        'publicKeyHex': publicKeyHex,
        'signingPublicKeyHex': signingPublicKeyHex,
        'nickname': nickname,
        'lastSeen': lastSeen?.millisecondsSinceEpoch,
        'geohash': geohash,
        'verified': verified,
      };

  factory BitchatPeer.fromJson(Map<String, dynamic> json) => BitchatPeer(
        publicKeyHex: json['publicKeyHex'] as String,
        signingPublicKeyHex: json['signingPublicKeyHex'] as String? ?? '',
        nickname: json['nickname'] as String? ?? '',
        lastSeen: json['lastSeen'] != null
            ? DateTime.fromMillisecondsSinceEpoch(
                json['lastSeen'] as int,
                isUtc: true,
              )
            : null,
        geohash: json['geohash'] as String? ?? '',
        verified: json['verified'] as bool? ?? false,
      );

  BitchatPeer copyWith({
    String? nickname,
    DateTime? lastSeen,
    String? geohash,
    bool? verified,
  }) => BitchatPeer(
        publicKeyHex: publicKeyHex,
        signingPublicKeyHex: signingPublicKeyHex,
        nickname: nickname ?? this.nickname,
        lastSeen: lastSeen ?? this.lastSeen,
        geohash: geohash ?? this.geohash,
        verified: verified ?? this.verified,
      );
}
