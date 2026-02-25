/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * XMPP client — wraps whixp library for XMPP connection, MUC operations,
 * and event handling.
 *
 * No isolate needed — whixp manages async I/O internally.
 * Parsed XMPP events are emitted via onEvent callback as maps
 * (same pattern as IrcClient).
 */

import 'dart:async';

import 'package:whixp/whixp.dart';

import '../../services/log_service.dart';
import 'models/xmpp_server_config.dart';

class XmppClient {
  final XmppServerConfig config;
  final String nickname;

  Whixp? _whixp;
  bool _running = false;
  bool _connected = false;

  /// Callback for XMPP events — set by XmppService.
  void Function(Map<String, dynamic> event)? onEvent;

  XmppClient({required this.config, required this.nickname});

  bool get isConnected => _connected;

  /// Start the connection. Idempotent.
  void connect() {
    if (_running) return;
    _running = true;

    final jid = config.jid;
    final password = config.password;
    if (jid == null || jid.isEmpty || password == null || password.isEmpty) {
      _emitEvent({'type': 'error', 'message': 'JID and password required'});
      _running = false;
      return;
    }

    try {
      _whixp = Whixp(
        jabberID: jid,
        password: password,
        host: config.host,
        port: config.port,
        logger: Log(enableWarning: false, enableError: true),
        reconnectionPolicy: RandomBackoffReconnectionPolicy(3, 10),
      );

      _whixp!.addEventHandler('streamNegotiated', (_) {
        LogService().log('XmppClient[${config.id}]: stream negotiated');
        _connected = true;
        // Send initial presence to indicate we're online
        _whixp!.sendPresence();
        _emitEvent({'type': 'connected'});

        // Auto-join rooms after a short delay
        Future.delayed(const Duration(milliseconds: 500), () {
          for (final room in config.autoJoinRooms) {
            if (room.isNotEmpty) joinRoom(room, nickname);
          }
        });
      });

      _whixp!.addEventHandler<TransportState>('state', (state) {
        if (state == TransportState.disconnected) {
          final wasConnected = _connected;
          _connected = false;
          if (wasConnected) {
            _emitEvent({'type': 'disconnected'});
          }
          // whixp reconnection policy handles auto-reconnect
        }
      });

      _whixp!.addEventHandler<Message>('message', (message) {
        if (message == null) return;
        _handleMessage(message);
      });

      _whixp!.addEventHandler<Presence>('presence', (presence) {
        if (presence == null) return;
        _handlePresence(presence);
      });

      _whixp!.connect();
    } catch (e) {
      _emitEvent({'type': 'error', 'message': 'Connect failed: $e'});
      _running = false;
    }
  }

  /// Disconnect and stop.
  Future<void> disconnect() async {
    _running = false;
    _connected = false;
    try {
      await _whixp?.disconnect();
    } catch (e) {
      LogService().log('XmppClient[${config.id}]: disconnect error: $e');
    }
    _whixp = null;
  }

  /// Join a MUC room.
  void joinRoom(String roomJid, String nick) {
    if (_whixp == null || !_connected) return;
    // Send presence to room/nick with MUC xmlns
    _whixp!.sendPresence(
      to: JabberID('$roomJid/$nick'),
    );
    LogService().log('XmppClient[${config.id}]: joining $roomJid as $nick');
  }

  /// Leave a MUC room.
  void leaveRoom(String roomJid) {
    if (_whixp == null) return;
    _whixp!.sendPresence(
      to: JabberID('$roomJid/$nickname'),
      type: 'unavailable',
    );
    _emitEvent({
      'type': 'room_left',
      'roomJid': roomJid,
    });
  }

  /// Send a groupchat message to a MUC room.
  void sendGroupMessage(String roomJid, String text) {
    if (_whixp == null || !_connected) return;
    _whixp!.sendMessage(
      JabberID(roomJid),
      body: text,
      type: MessageType.groupchat,
    );
  }

  /// Send a 1:1 chat message.
  void sendChatMessage(String jid, String text) {
    if (_whixp == null || !_connected) return;
    _whixp!.sendMessage(
      JabberID(jid),
      body: text,
      type: MessageType.chat,
    );
  }

  /// Discover MUC rooms on a conference service via disco#items.
  void discoverRooms(String conferenceService) {
    if (_whixp == null || !_connected) return;
    // Use service discovery - build disco#items IQ query
    // For now, emit a placeholder - whixp doesn't expose raw IQ building easily
    // We'll use sendPresence to probe the conference service
    LogService().log('XmppClient[${config.id}]: discovering rooms on $conferenceService');
    _emitEvent({
      'type': 'discover_started',
      'conferenceService': conferenceService,
    });
    // TODO: Use whixp's disco support if available, or implement via raw IQ
    // For now, rooms are joined manually or via auto-join
    _emitEvent({
      'type': 'room_list',
      'conferenceService': conferenceService,
      'rooms': <Map<String, dynamic>>[],
    });
  }

  /// Set the subject/topic of a MUC room.
  void setRoomSubject(String roomJid, String subject) {
    if (_whixp == null || !_connected) return;
    _whixp!.sendMessage(
      JabberID(roomJid),
      subject: subject,
      type: MessageType.groupchat,
    );
  }

  // ---------------------------------------------------------------------------
  // Event handling
  // ---------------------------------------------------------------------------

  void _handleMessage(Message message) {
    final from = message.from;
    final body = message.body;
    final subject = message.subject;

    if (from == null) return;

    final fromStr = from.toString();
    // MUC messages come from room@conference/nick
    // The bare JID is the room, the resource is the sender nick
    final bareJid = from.bare;
    final resource = _extractResource(fromStr);

    // Check for type
    final isGroupchat = fromStr.contains('@') && resource.isNotEmpty;

    if (subject != null && subject.isNotEmpty) {
      // Subject change
      _emitEvent({
        'type': 'subject',
        'roomJid': bareJid,
        'sender': resource,
        'subject': subject,
      });
      return;
    }

    if (body == null || body.isEmpty) return;

    _emitEvent({
      'type': 'message',
      'roomJid': bareJid,
      'sender': resource.isNotEmpty ? resource : bareJid,
      'senderJid': fromStr,
      'text': body,
      'isGroupchat': isGroupchat,
    });
  }

  void _handlePresence(Presence presence) {
    final from = presence.from;
    if (from == null) return;

    final fromStr = from.toString();
    final bareJid = from.bare;
    final resource = _extractResource(fromStr);

    final type = presence.type;

    if (resource.isEmpty) return; // Not a MUC presence

    if (type == 'unavailable') {
      _emitEvent({
        'type': 'occupant_left',
        'roomJid': bareJid,
        'nick': resource,
      });
    } else {
      _emitEvent({
        'type': 'occupant_joined',
        'roomJid': bareJid,
        'nick': resource,
      });
    }
  }

  String _extractResource(String fullJid) {
    final slashIdx = fullJid.indexOf('/');
    return slashIdx >= 0 ? fullJid.substring(slashIdx + 1) : '';
  }

  void _emitEvent(Map<String, dynamic> event) {
    event['serverId'] = config.id;
    onEvent?.call(event);
  }
}
