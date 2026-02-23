/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Signal conversation model.
 * Key difference from Telegram: conversations are identified by UUID strings
 * (not int64), and groups use base64-encoded master key bytes.
 */

import 'signal_message.dart';

enum SignalChatType { direct, group }

class SignalChat {
  /// UUID string for direct chats, base64 group master key for groups.
  final String id;

  final String title;
  final SignalChatType type;
  final String? phoneNumber;
  final int memberCount;
  final int unreadCount;
  final SignalMessage? lastMessage;

  const SignalChat({
    required this.id,
    required this.title,
    required this.type,
    this.phoneNumber,
    this.memberCount = 0,
    this.unreadCount = 0,
    this.lastMessage,
  });

  factory SignalChat.fromJson(Map<String, dynamic> json) {
    return SignalChat(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      type: (json['type'] as String?) == 'group'
          ? SignalChatType.group
          : SignalChatType.direct,
      phoneNumber: json['phone_number'] as String?,
      memberCount: json['member_count'] as int? ?? 0,
      unreadCount: json['unread_count'] as int? ?? 0,
    );
  }

  SignalChat copyWith({
    String? title,
    int? unreadCount,
    SignalMessage? lastMessage,
  }) {
    return SignalChat(
      id: id,
      title: title ?? this.title,
      type: type,
      phoneNumber: phoneNumber,
      memberCount: memberCount,
      unreadCount: unreadCount ?? this.unreadCount,
      lastMessage: lastMessage ?? this.lastMessage,
    );
  }

  @override
  String toString() => 'SignalChat($id, $title, $type)';
}
