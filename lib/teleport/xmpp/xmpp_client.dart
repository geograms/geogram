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
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dnsolve/dnsolve.dart';
import 'package:whixp/whixp.dart';

import '../../services/log_service.dart';
import 'models/xmpp_server_config.dart';

class XmppClient {
  final XmppServerConfig config;
  final String nickname;
  final String? databasePath;

  Whixp? _whixp;
  bool _running = false;
  bool _connected = false;

  /// Callback for XMPP events — set by XmppService.
  void Function(Map<String, dynamic> event)? onEvent;

  XmppClient({required this.config, required this.nickname, this.databasePath});

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

    // For DirectTLS, resolve SRV records ourselves to get the correct
    // host/port. Whixp 3.0.0 has two bugs: STARTTLS race condition
    // (WRONG_VERSION_NUMBER) and trailing-dot FQDN in SRV results
    // (CERTIFICATE_VERIFY_FAILED hostname mismatch).
    if (config.directTls) {
      _resolveAndConnect(jid, password);
    } else {
      _createWhixp(jid, password, config.host, config.port);
    }
  }

  /// Resolve XMPP SRV records for DirectTLS and connect.
  Future<void> _resolveAndConnect(String jid, String password) async {
    final domain = jid.contains('@') ? jid.split('@').last : config.host;
    var host = config.host;
    var port = config.port;

    try {
      final response = await DNSolve()
          .lookup('_xmpps-client._tcp.$domain', type: RecordType.srv);
      if (response.answer?.srvs != null && response.answer!.srvs!.isNotEmpty) {
        final srv = response.answer!.srvs!.first;
        if (srv.target != null && srv.target!.isNotEmpty) {
          // Strip trailing dot from FQDN
          host = srv.target!.endsWith('.')
              ? srv.target!.substring(0, srv.target!.length - 1)
              : srv.target!;
          port = srv.port;
          LogService().log(
              'XmppClient: SRV resolved DirectTLS → $host:$port');
        }
      }
    } catch (e) {
      LogService().log('XmppClient: SRV lookup failed, using $host:$port: $e');
    }

    _createWhixp(jid, password, host, port);
  }

  /// Create the Whixp instance and connect.
  void _createWhixp(String jid, String password, String host, int port) {
    try {
      _whixp = Whixp(
        jabberID: jid,
        password: password,
        host: host,
        port: port,
        useTLS: config.directTls,
        disableStartTLS: config.directTls,
        internalDatabasePath: databasePath ?? '',
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

  // ---------------------------------------------------------------------------
  // XEP-0077 In-Band Registration (raw TCP/TLS via RawSocket)
  // ---------------------------------------------------------------------------

  /// Generate a random alphanumeric password of given length.
  static String generatePassword({int length = 20}) {
    const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rng = Random.secure();
    return List.generate(length, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  /// Attempt XEP-0077 in-band registration on a server.
  ///
  /// Returns a result map:
  ///   { 'success': true, 'jid': 'user@host', 'password': '...' }
  ///   { 'success': false, 'error': '...' }
  ///
  /// Uses RawSocket + RawSecureSocket for STARTTLS upgrade.
  /// SecureSocket.secure() fails on single-subscription streams after
  /// listen/cancel — RawSocket polling avoids that entirely.
  static Future<Map<String, dynamic>> registerAccount({
    required String host,
    int port = 5222,
    required String username,
    String? password,
    bool directTls = false,
  }) async {
    password ??= generatePassword();
    final log = LogService();

    final buf = StringBuffer();

    // Poll-based read — RawSocket.read() returns null when no data available.
    Future<String> waitFor(
      RawSocket sock,
      String pattern, {
      int seconds = 15,
    }) async {
      final deadline = DateTime.now().add(Duration(seconds: seconds));
      while (!buf.toString().contains(pattern)) {
        if (DateTime.now().isAfter(deadline)) {
          final snippet = buf.toString();
          throw TimeoutException(
              'Timeout waiting for: $pattern\n'
              'Buffer: ${snippet.substring(0, snippet.length.clamp(0, 300))}');
        }
        final data = sock.read();
        if (data != null && data.isNotEmpty) {
          buf.write(utf8.decode(data, allowMalformed: true));
        } else {
          await Future.delayed(const Duration(milliseconds: 50));
        }
      }
      return buf.toString();
    }

    RawSocket? rawSock;
    RawSecureSocket? secureSock;

    try {
      log.log('XmppRegister: connecting to $host:$port (directTls=$directTls)');

      // 1. Connect TCP
      rawSock = await RawSocket.connect(host, port,
          timeout: const Duration(seconds: 10));
      rawSock.readEventsEnabled = true;

      // Wrap in Direct TLS if requested (port 5223)
      if (directTls) {
        secureSock = await RawSecureSocket.secure(rawSock!, host: host);
        secureSock.readEventsEnabled = true;
        rawSock = null;
      }

      // Helper: send bytes through whichever socket is active
      void send(String xml) {
        final bytes = utf8.encode(xml);
        if (secureSock != null) {
          secureSock!.write(bytes);
        } else {
          rawSock!.write(bytes);
        }
      }

      Future<String> wait(String pattern, {int seconds = 15}) =>
          waitFor(secureSock ?? rawSock!, pattern, seconds: seconds);

      // 2. Open stream
      send("<?xml version='1.0'?>"
          "<stream:stream to='$host' xmlns='jabber:client' "
          "xmlns:stream='http://etherx.jabber.org/streams' version='1.0'>");

      var response = await wait('</stream:features>');
      log.log('XmppRegister: features received (${response.length} bytes)');

      // 3. STARTTLS upgrade (skip if already on direct TLS)
      if (!directTls && response.contains('<starttls')) {
        buf.clear();
        send("<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>");
        await wait('<proceed');
        log.log('XmppRegister: TLS proceed received');

        buf.clear();
        // Upgrade the existing RawSocket to TLS in-place
        secureSock = await RawSecureSocket.secure(rawSock!, host: host);
        secureSock.readEventsEnabled = true;
        rawSock = null; // ownership transferred to secureSock

        // Re-open stream over TLS
        secureSock.write(utf8.encode("<?xml version='1.0'?>"
            "<stream:stream to='$host' xmlns='jabber:client' "
            "xmlns:stream='http://etherx.jabber.org/streams' version='1.0'>"));

        response = await wait('</stream:features>');
        log.log('XmppRegister: TLS features (${response.length} bytes)');
      }

      // 4. Check if registration is supported (informational only)
      if (!response.contains('register') &&
          !response.contains('jabber:iq:register')) {
        log.log('XmppRegister: register not in features, trying anyway');
      }

      // 5. Query registration fields
      buf.clear();
      send("<iq type='get' id='reg1'><query xmlns='jabber:iq:register'/></iq>");
      response = await wait('</iq>');
      log.log(
          'XmppRegister: query: ${response.substring(0, response.length.clamp(0, 300))}');

      if (response.contains('type="error"') ||
          response.contains("type='error'")) {
        final errorMsg = _extractErrorText(response);
        secureSock?.shutdown(SocketDirection.both);
        rawSock?.shutdown(SocketDirection.both);
        return {
          'success': false,
          'error': 'Registration query failed: $errorMsg'
        };
      }

      // Detect web-only redirect (jabber:x:oob)
      if (response.contains('jabber:x:oob') || response.contains('<url>')) {
        secureSock?.shutdown(SocketDirection.both);
        rawSock?.shutdown(SocketDirection.both);
        return {
          'success': false,
          'error': 'Server requires web registration — no in-band registration supported'
        };
      }

      // 6. Submit registration
      buf.clear();
      send("<iq type='set' id='reg2'>"
          "<query xmlns='jabber:iq:register'>"
          "<username>${_xmlEscape(username)}</username>"
          "<password>${_xmlEscape(password!)}</password>"
          "</query></iq>");

      response = await wait('</iq>');
      log.log(
          'XmppRegister: result: ${response.substring(0, response.length.clamp(0, 300))}');

      secureSock?.shutdown(SocketDirection.both);
      rawSock?.shutdown(SocketDirection.both);

      if (response.contains("type='result'") ||
          response.contains('type="result"')) {
        return {
          'success': true,
          'jid': '$username@$host',
          'password': password,
        };
      } else {
        final errorMsg = _extractErrorText(response);
        return {'success': false, 'error': 'Registration failed: $errorMsg'};
      }
    } catch (e) {
      log.log('XmppRegister: error: $e');
      try {
        secureSock?.shutdown(SocketDirection.both);
        rawSock?.shutdown(SocketDirection.both);
      } catch (_) {}
      return {'success': false, 'error': '$e'};
    }
  }

  /// Extract error text from an XMPP IQ error response.
  static String _extractErrorText(String xml) {
    // Try to find <text>...</text>
    final textMatch =
        RegExp(r'<text[^>]*>(.*?)</text>', dotAll: true).firstMatch(xml);
    if (textMatch != null) return textMatch.group(1) ?? 'Unknown error';
    // Try common error conditions
    if (xml.contains('conflict')) return 'Username already taken';
    if (xml.contains('not-acceptable')) return 'Registration not acceptable';
    if (xml.contains('not-allowed')) return 'Registration not allowed on this server';
    if (xml.contains('forbidden')) return 'Registration forbidden';
    if (xml.contains('resource-constraint')) return 'Server resource limit reached';
    return 'Unknown error';
  }

  /// Escape XML special characters.
  static String _xmlEscape(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll("'", '&apos;')
        .replaceAll('"', '&quot;');
  }
}
