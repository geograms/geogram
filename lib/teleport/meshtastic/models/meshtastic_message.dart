/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Meshtastic message — a text message sent or received via the mesh network.
 */

enum MeshtasticMessageDirection { incoming, outgoing }

enum MeshtasticMessageStatus { pending, sent, delivered, failed }

class MeshtasticMessage {
  final int? id;
  final int channelIndex;
  final int fromNode;
  final int toNode;
  final String text;
  final DateTime timestamp;
  final MeshtasticMessageDirection direction;
  final MeshtasticMessageStatus status;
  final double? rxSnr;
  final int? rxRssi;
  final int hopStart;
  final int hopLimit;
  final String senderLongName;
  final String senderShortName;
  final int packetId;

  const MeshtasticMessage({
    this.id,
    required this.channelIndex,
    required this.fromNode,
    required this.toNode,
    required this.text,
    required this.timestamp,
    required this.direction,
    this.status = MeshtasticMessageStatus.pending,
    this.rxSnr,
    this.rxRssi,
    this.hopStart = 0,
    this.hopLimit = 3,
    this.senderLongName = '',
    this.senderShortName = '',
    this.packetId = 0,
  });

  /// Conversation ID: "ch:N" for channel messages, node number hex for DMs.
  String get conversationId {
    if (toNode == 0xFFFFFFFF) return 'ch:$channelIndex';
    // DM: use the other party's node number
    if (direction == MeshtasticMessageDirection.outgoing) {
      return 'dm:${toNode.toRadixString(16)}';
    }
    return 'dm:${fromNode.toRadixString(16)}';
  }

  bool get isOutgoing => direction == MeshtasticMessageDirection.outgoing;
  bool get isBroadcast => toNode == 0xFFFFFFFF;

  MeshtasticMessage copyWith({
    int? id,
    MeshtasticMessageStatus? status,
    String? senderLongName,
    String? senderShortName,
  }) =>
      MeshtasticMessage(
        id: id ?? this.id,
        channelIndex: channelIndex,
        fromNode: fromNode,
        toNode: toNode,
        text: text,
        timestamp: timestamp,
        direction: direction,
        status: status ?? this.status,
        rxSnr: rxSnr,
        rxRssi: rxRssi,
        hopStart: hopStart,
        hopLimit: hopLimit,
        senderLongName: senderLongName ?? this.senderLongName,
        senderShortName: senderShortName ?? this.senderShortName,
        packetId: packetId,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'channelIndex': channelIndex,
        'fromNode': fromNode,
        'toNode': toNode,
        'text': text,
        'timestamp': timestamp.millisecondsSinceEpoch,
        'direction': direction.name,
        'status': status.name,
        'rxSnr': rxSnr,
        'rxRssi': rxRssi,
        'hopStart': hopStart,
        'hopLimit': hopLimit,
        'senderLongName': senderLongName,
        'senderShortName': senderShortName,
        'packetId': packetId,
      };

  factory MeshtasticMessage.fromJson(Map<String, dynamic> json) =>
      MeshtasticMessage(
        id: json['id'] as int?,
        channelIndex: json['channelIndex'] as int? ?? 0,
        fromNode: json['fromNode'] as int? ?? 0,
        toNode: json['toNode'] as int? ?? 0,
        text: json['text'] as String? ?? '',
        timestamp: DateTime.fromMillisecondsSinceEpoch(
          json['timestamp'] as int,
          isUtc: true,
        ),
        direction: MeshtasticMessageDirection.values.firstWhere(
          (d) => d.name == json['direction'],
          orElse: () => MeshtasticMessageDirection.incoming,
        ),
        status: MeshtasticMessageStatus.values.firstWhere(
          (s) => s.name == json['status'],
          orElse: () => MeshtasticMessageStatus.pending,
        ),
        rxSnr: (json['rxSnr'] as num?)?.toDouble(),
        rxRssi: json['rxRssi'] as int?,
        hopStart: json['hopStart'] as int? ?? 0,
        hopLimit: json['hopLimit'] as int? ?? 3,
        senderLongName: json['senderLongName'] as String? ?? '',
        senderShortName: json['senderShortName'] as String? ?? '',
        packetId: json['packetId'] as int? ?? 0,
      );
}
