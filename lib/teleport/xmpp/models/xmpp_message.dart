/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * XMPP message model — represents a single message in an XMPP MUC room or PM.
 */

/// Classification of XMPP messages for display purposes.
enum XmppMessageType {
  groupchat,
  chat,
  subject,
  join,
  leave,
  system,
}

class XmppMessage {
  final String serverConfigId;
  final String roomJid;
  final String sender;
  final String? senderJid;
  final String text;
  final DateTime timestamp;
  final bool isOutgoing;
  final XmppMessageType type;
  final String? stanzaId;

  const XmppMessage({
    required this.serverConfigId,
    required this.roomJid,
    required this.sender,
    this.senderJid,
    required this.text,
    required this.timestamp,
    this.isOutgoing = false,
    this.type = XmppMessageType.groupchat,
    this.stanzaId,
  });

  /// Whether this is a system/event message (join, leave, subject) rather than chat.
  bool get isSystemMessage =>
      type == XmppMessageType.join ||
      type == XmppMessageType.leave ||
      type == XmppMessageType.subject ||
      type == XmppMessageType.system;

  Map<String, dynamic> toJson() => {
        'serverConfigId': serverConfigId,
        'roomJid': roomJid,
        'sender': sender,
        'senderJid': senderJid,
        'text': text,
        'timestamp': timestamp.millisecondsSinceEpoch,
        'isOutgoing': isOutgoing,
        'type': type.name,
        'stanzaId': stanzaId,
      };

  factory XmppMessage.fromJson(Map<String, dynamic> json) {
    final typeName = json['type'] as String? ?? 'groupchat';
    final type = XmppMessageType.values.firstWhere(
      (t) => t.name == typeName,
      orElse: () => XmppMessageType.groupchat,
    );
    return XmppMessage(
      serverConfigId: json['serverConfigId'] as String,
      roomJid: json['roomJid'] as String,
      sender: json['sender'] as String,
      senderJid: json['senderJid'] as String?,
      text: json['text'] as String,
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        json['timestamp'] as int,
        isUtc: true,
      ),
      isOutgoing: json['isOutgoing'] as bool? ?? false,
      type: type,
      stanzaId: json['stanzaId'] as String?,
    );
  }
}
