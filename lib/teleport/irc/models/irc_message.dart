/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * IRC message model — represents a single message in an IRC channel or PM.
 */

/// Classification of IRC messages for display purposes.
enum IrcMessageType {
  privmsg,
  notice,
  action,
  join,
  part,
  quit,
  system,
}

class IrcMessage {
  final String serverConfigId;
  final String channel;
  final String sender;
  final String text;
  final DateTime timestamp;
  final bool isOutgoing;
  final IrcMessageType type;

  const IrcMessage({
    required this.serverConfigId,
    required this.channel,
    required this.sender,
    required this.text,
    required this.timestamp,
    this.isOutgoing = false,
    this.type = IrcMessageType.privmsg,
  });

  /// Whether this is a system/event message (join, part, quit) rather than chat.
  bool get isSystemMessage =>
      type == IrcMessageType.join ||
      type == IrcMessageType.part ||
      type == IrcMessageType.quit ||
      type == IrcMessageType.system;

  Map<String, dynamic> toJson() => {
        'serverConfigId': serverConfigId,
        'channel': channel,
        'sender': sender,
        'text': text,
        'timestamp': timestamp.millisecondsSinceEpoch,
        'isOutgoing': isOutgoing,
        'type': type.name,
      };

  factory IrcMessage.fromJson(Map<String, dynamic> json) {
    final typeName = json['type'] as String? ?? 'privmsg';
    final type = IrcMessageType.values.firstWhere(
      (t) => t.name == typeName,
      orElse: () => IrcMessageType.privmsg,
    );
    return IrcMessage(
      serverConfigId: json['serverConfigId'] as String,
      channel: json['channel'] as String,
      sender: json['sender'] as String,
      text: json['text'] as String,
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        json['timestamp'] as int,
        isUtc: true,
      ),
      isOutgoing: json['isOutgoing'] as bool? ?? false,
      type: type,
    );
  }
}
