/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * BitChat message — a text message sent or received via the BitChat mesh.
 */

enum BitchatMessageDirection { incoming, outgoing }

enum BitchatMessageStatus { pending, sent, delivered, failed }

class BitchatMessage {
  /// Unique local ID for database storage.
  final int? id;

  /// Message UUID for deduplication across mesh hops.
  final String uuid;

  /// Channel geohash (for broadcast messages) or empty for DMs.
  final String channelGeohash;

  /// Sender ID (first 8 bytes of static public key, hex).
  final String senderId;

  /// Recipient ID (for DMs) or empty for broadcasts.
  final String recipientId;

  /// Sender display name.
  final String senderNickname;

  /// Message text content.
  final String content;

  /// Timestamp (UTC).
  final DateTime timestamp;

  /// Direction: incoming or outgoing.
  final BitchatMessageDirection direction;

  /// Delivery status for outgoing messages.
  final BitchatMessageStatus status;

  /// Time-to-live (remaining hops).
  final int ttl;

  /// Number of hops this message has taken.
  final int hopCount;

  const BitchatMessage({
    this.id,
    required this.uuid,
    this.channelGeohash = '',
    required this.senderId,
    this.recipientId = '',
    this.senderNickname = '',
    required this.content,
    required this.timestamp,
    required this.direction,
    this.status = BitchatMessageStatus.pending,
    this.ttl = 7,
    this.hopCount = 0,
  });

  bool get isOutgoing => direction == BitchatMessageDirection.outgoing;
  bool get isBroadcast => recipientId.isEmpty;
  bool get isDelivered => status == BitchatMessageStatus.delivered;

  /// Conversation ID for grouping: geohash for broadcasts, sender/recipient for DMs.
  String get conversationId {
    if (isBroadcast) return 'geo:$channelGeohash';
    return isOutgoing ? recipientId : senderId;
  }

  BitchatMessage copyWith({
    int? id,
    BitchatMessageStatus? status,
    int? hopCount,
  }) => BitchatMessage(
    id: id ?? this.id,
    uuid: uuid,
    channelGeohash: channelGeohash,
    senderId: senderId,
    recipientId: recipientId,
    senderNickname: senderNickname,
    content: content,
    timestamp: timestamp,
    direction: direction,
    status: status ?? this.status,
    ttl: ttl,
    hopCount: hopCount ?? this.hopCount,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'uuid': uuid,
    'channelGeohash': channelGeohash,
    'senderId': senderId,
    'recipientId': recipientId,
    'senderNickname': senderNickname,
    'content': content,
    'timestamp': timestamp.millisecondsSinceEpoch,
    'direction': direction.name,
    'status': status.name,
    'ttl': ttl,
    'hopCount': hopCount,
  };

  factory BitchatMessage.fromJson(Map<String, dynamic> json) => BitchatMessage(
    id: json['id'] as int?,
    uuid: json['uuid'] as String,
    channelGeohash: json['channelGeohash'] as String? ?? '',
    senderId: json['senderId'] as String,
    recipientId: json['recipientId'] as String? ?? '',
    senderNickname: json['senderNickname'] as String? ?? '',
    content: json['content'] as String,
    timestamp: DateTime.fromMillisecondsSinceEpoch(
      json['timestamp'] as int,
      isUtc: true,
    ),
    direction: BitchatMessageDirection.values.firstWhere(
      (d) => d.name == json['direction'],
      orElse: () => BitchatMessageDirection.incoming,
    ),
    status: BitchatMessageStatus.values.firstWhere(
      (s) => s.name == json['status'],
      orElse: () => BitchatMessageStatus.pending,
    ),
    ttl: json['ttl'] as int? ?? 7,
    hopCount: json['hopCount'] as int? ?? 0,
  );
}
