/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * MeshCore contact — represents a node in the mesh network.
 * Identified by a 32-byte Ed25519 public key managed by the device.
 */

class MeshCoreContact {
  /// Hex-encoded 32-byte Ed25519 public key (64 hex chars).
  final String pubKeyHex;

  /// Human-readable name advertised by the node.
  final String name;

  /// Unix epoch timestamp of last seen advertisement.
  final DateTime? lastSeen;

  /// Signal-to-noise ratio of last received packet (dB).
  final double? lastSnr;

  /// Whether this contact is a repeater node.
  final bool isRepeater;

  const MeshCoreContact({
    required this.pubKeyHex,
    required this.name,
    this.lastSeen,
    this.lastSnr,
    this.isRepeater = false,
  });

  /// Short display key — first 8 hex chars.
  String get shortKey => pubKeyHex.length >= 8
      ? pubKeyHex.substring(0, 8)
      : pubKeyHex;

  /// Display name: name if available, otherwise short key.
  String get displayName => name.isNotEmpty ? name : shortKey;

  Map<String, dynamic> toJson() => {
    'pubKeyHex': pubKeyHex,
    'name': name,
    'lastSeen': lastSeen?.millisecondsSinceEpoch,
    'lastSnr': lastSnr,
    'isRepeater': isRepeater,
  };

  factory MeshCoreContact.fromJson(Map<String, dynamic> json) => MeshCoreContact(
    pubKeyHex: json['pubKeyHex'] as String,
    name: json['name'] as String? ?? '',
    lastSeen: json['lastSeen'] != null
        ? DateTime.fromMillisecondsSinceEpoch(json['lastSeen'] as int, isUtc: true)
        : null,
    lastSnr: (json['lastSnr'] as num?)?.toDouble(),
    isRepeater: json['isRepeater'] as bool? ?? false,
  );

  MeshCoreContact copyWith({
    String? pubKeyHex,
    String? name,
    DateTime? lastSeen,
    double? lastSnr,
    bool? isRepeater,
  }) => MeshCoreContact(
    pubKeyHex: pubKeyHex ?? this.pubKeyHex,
    name: name ?? this.name,
    lastSeen: lastSeen ?? this.lastSeen,
    lastSnr: lastSnr ?? this.lastSnr,
    isRepeater: isRepeater ?? this.isRepeater,
  );
}
