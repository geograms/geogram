/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * MeshCore message — a text message sent or received via the mesh network.
 */

enum MeshCoreMessageDirection { incoming, outgoing }

enum MeshCoreMessageStatus { pending, sent, acknowledged, failed }

/// Conversation type: direct (1:1 with a contact) or channel (group).
enum MeshCoreConversationType { contact, channel }

class MeshCoreMessage {
  /// Unique local ID for database storage.
  final int? id;

  /// Conversation identifier: pubKeyHex for contacts, "ch:N" for channels.
  final String conversationId;

  /// Conversation type.
  final MeshCoreConversationType conversationType;

  /// Message text (max 133 chars for MeshCore).
  final String text;

  /// Timestamp (UTC).
  final DateTime timestamp;

  /// Direction: incoming or outgoing.
  final MeshCoreMessageDirection direction;

  /// Signal-to-noise ratio (dB) for incoming messages.
  final double? snr;

  /// Delivery status for outgoing messages.
  final MeshCoreMessageStatus status;

  /// Sender name (for display in channel messages).
  final String? senderName;

  /// Sender pub key hex prefix (6 bytes = 12 hex chars) for incoming messages.
  final String? senderKeyPrefix;

  const MeshCoreMessage({
    this.id,
    required this.conversationId,
    required this.conversationType,
    required this.text,
    required this.timestamp,
    required this.direction,
    this.snr,
    this.status = MeshCoreMessageStatus.pending,
    this.senderName,
    this.senderKeyPrefix,
  });

  bool get isOutgoing => direction == MeshCoreMessageDirection.outgoing;
  bool get isAcknowledged => status == MeshCoreMessageStatus.acknowledged;

  MeshCoreMessage copyWith({
    int? id,
    MeshCoreMessageStatus? status,
    double? snr,
  }) => MeshCoreMessage(
    id: id ?? this.id,
    conversationId: conversationId,
    conversationType: conversationType,
    text: text,
    timestamp: timestamp,
    direction: direction,
    snr: snr ?? this.snr,
    status: status ?? this.status,
    senderName: senderName,
    senderKeyPrefix: senderKeyPrefix,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'conversationId': conversationId,
    'conversationType': conversationType.name,
    'text': text,
    'timestamp': timestamp.millisecondsSinceEpoch,
    'direction': direction.name,
    'snr': snr,
    'status': status.name,
    'senderName': senderName,
    'senderKeyPrefix': senderKeyPrefix,
  };

  factory MeshCoreMessage.fromJson(Map<String, dynamic> json) => MeshCoreMessage(
    id: json['id'] as int?,
    conversationId: json['conversationId'] as String,
    conversationType: MeshCoreConversationType.values.firstWhere(
      (t) => t.name == json['conversationType'],
      orElse: () => MeshCoreConversationType.contact,
    ),
    text: json['text'] as String,
    timestamp: DateTime.fromMillisecondsSinceEpoch(
      json['timestamp'] as int,
      isUtc: true,
    ),
    direction: MeshCoreMessageDirection.values.firstWhere(
      (d) => d.name == json['direction'],
      orElse: () => MeshCoreMessageDirection.incoming,
    ),
    snr: (json['snr'] as num?)?.toDouble(),
    status: MeshCoreMessageStatus.values.firstWhere(
      (s) => s.name == json['status'],
      orElse: () => MeshCoreMessageStatus.pending,
    ),
    senderName: json['senderName'] as String?,
    senderKeyPrefix: json['senderKeyPrefix'] as String?,
  );
}
