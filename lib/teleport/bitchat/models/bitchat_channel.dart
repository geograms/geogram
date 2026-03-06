/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * BitChat geohash channel — a location-based chat channel.
 */

class BitchatChannel {
  /// Geohash string identifying this channel.
  final String geohash;

  /// Geohash precision level (1-12).
  final int precision;

  /// Human-readable display name (e.g., "Lisbon" or geohash).
  final String displayName;

  /// Number of known peers in this channel.
  final int peerCount;

  /// Last activity timestamp.
  final DateTime? lastActivity;

  /// Unread message count.
  final int unreadCount;

  const BitchatChannel({
    required this.geohash,
    required this.precision,
    this.displayName = '',
    this.peerCount = 0,
    this.lastActivity,
    this.unreadCount = 0,
  });

  /// Display name: custom name if set, otherwise the geohash itself.
  String get label => displayName.isNotEmpty ? displayName : '#$geohash';

  Map<String, dynamic> toJson() => {
        'geohash': geohash,
        'precision': precision,
        'displayName': displayName,
        'peerCount': peerCount,
        'lastActivity': lastActivity?.millisecondsSinceEpoch,
        'unreadCount': unreadCount,
      };

  factory BitchatChannel.fromJson(Map<String, dynamic> json) => BitchatChannel(
        geohash: json['geohash'] as String,
        precision: json['precision'] as int? ?? 4,
        displayName: json['displayName'] as String? ?? '',
        peerCount: json['peerCount'] as int? ?? 0,
        lastActivity: json['lastActivity'] != null
            ? DateTime.fromMillisecondsSinceEpoch(
                json['lastActivity'] as int,
                isUtc: true,
              )
            : null,
        unreadCount: json['unreadCount'] as int? ?? 0,
      );

  BitchatChannel copyWith({
    String? displayName,
    int? peerCount,
    DateTime? lastActivity,
    int? unreadCount,
  }) => BitchatChannel(
        geohash: geohash,
        precision: precision,
        displayName: displayName ?? this.displayName,
        peerCount: peerCount ?? this.peerCount,
        lastActivity: lastActivity ?? this.lastActivity,
        unreadCount: unreadCount ?? this.unreadCount,
      );
}
