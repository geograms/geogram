/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * IRC channel model — tracks name, topic, user list, and unread state.
 */

import 'irc_message.dart';

class IrcChannel {
  final String serverConfigId;
  final String name;
  String topic;
  final List<String> users;
  IrcMessage? lastMessage;
  int unreadCount;

  IrcChannel({
    required this.serverConfigId,
    required this.name,
    this.topic = '',
    List<String>? users,
    this.lastMessage,
    this.unreadCount = 0,
  }) : users = users ?? [];
}
