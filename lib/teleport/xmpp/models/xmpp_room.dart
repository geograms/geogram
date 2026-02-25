/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * XMPP room model — tracks JID, subject, occupant list, and unread state.
 */

import 'xmpp_message.dart';

class XmppRoom {
  final String serverConfigId;
  final String jid;
  String name;
  String subject;
  final String? conferenceService;
  final List<String> occupants;
  XmppMessage? lastMessage;
  int unreadCount;

  XmppRoom({
    required this.serverConfigId,
    required this.jid,
    String? name,
    this.subject = '',
    this.conferenceService,
    List<String>? occupants,
    this.lastMessage,
    this.unreadCount = 0,
  })  : name = name ?? jid.split('@').first,
        occupants = occupants ?? [];
}
