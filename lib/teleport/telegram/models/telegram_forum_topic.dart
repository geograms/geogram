/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// A forum topic within a Telegram supergroup.
class TelegramForumTopic {
  final int messageThreadId;
  final String name;
  final bool isGeneral;
  final bool isClosed;
  final bool isHidden;
  final int unreadCount;
  final String? lastMessageText;
  final DateTime? lastMessageDate;

  const TelegramForumTopic({
    required this.messageThreadId,
    required this.name,
    this.isGeneral = false,
    this.isClosed = false,
    this.isHidden = false,
    this.unreadCount = 0,
    this.lastMessageText,
    this.lastMessageDate,
  });

  factory TelegramForumTopic.fromTdlib(Map<String, dynamic> json) {
    final info = json['info'] as Map<String, dynamic>? ?? {};
    final lastMsg = json['last_message'] as Map<String, dynamic>?;

    String? lastMsgText;
    DateTime? lastMsgDate;
    if (lastMsg != null) {
      final content = lastMsg['content'] as Map<String, dynamic>?;
      if (content != null) {
        final type = content['@type'] as String? ?? '';
        if (type == 'messageText') {
          lastMsgText =
              (content['text'] as Map<String, dynamic>?)?['text'] as String?;
        } else {
          lastMsgText = '[$type]';
        }
      }
      final date = lastMsg['date'] as int?;
      if (date != null) {
        lastMsgDate =
            DateTime.fromMillisecondsSinceEpoch(date * 1000, isUtc: true);
      }
    }

    return TelegramForumTopic(
      messageThreadId: info['message_thread_id'] as int? ?? 0,
      name: info['name'] as String? ?? 'Unknown',
      isGeneral: info['is_general'] as bool? ?? false,
      isClosed: info['is_closed'] as bool? ?? false,
      isHidden: info['is_hidden'] as bool? ?? false,
      unreadCount: json['unread_count'] as int? ?? 0,
      lastMessageText: lastMsgText,
      lastMessageDate: lastMsgDate,
    );
  }

  @override
  String toString() => 'ForumTopic($messageThreadId, $name)';
}
