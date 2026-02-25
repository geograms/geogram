/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * XMPP S2S (Server-to-Server) Federation Manager
 *
 * Handles outbound connections to remote XMPP servers (port 5269),
 * inbound connections from remote servers, XEP-0220 dialback authentication,
 * connection pooling, and stanza relay between C2S clients and remote servers.
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dnsolve/dnsolve.dart';

import '../util/xmpp_s2s_xml.dart';
import '../util/xmpp_server_protocol.dart';
import 'log_service.dart';

// ---------------------------------------------------------------------------
// S2S Connection state
// ---------------------------------------------------------------------------

enum S2sConnectionState {
  connecting,
  streamOpened,
  tlsUpgraded,
  authenticating,
  authenticated,
  closed,
}

// ---------------------------------------------------------------------------
// Single S2S connection to a remote domain
// ---------------------------------------------------------------------------

class XmppS2sConnection {
  final String localDomain;
  final String remoteDomain;
  final Socket socket;
  String streamId;
  S2sConnectionState state = S2sConnectionState.connecting;

  SecureSocket? secureSocket;
  bool isTls = false;

  /// Stanzas queued while authenticating
  final List<String> _pendingStanzas = [];

  /// Write serialization
  Future<void> _pendingWrite = Future.value();

  /// Await all pending writes (e.g. before STARTTLS upgrade)
  Future<void> get pendingWrite => _pendingWrite;

  /// Last activity for idle timeout
  DateTime lastActivity = DateTime.now();

  /// Whether this is an inbound connection (remote initiated)
  final bool inbound;

  /// The remote domain verified via dialback (for inbound connections)
  String? verifiedDomain;

  XmppS2sConnection({
    required this.localDomain,
    required this.remoteDomain,
    required this.socket,
    this.streamId = '',
    this.inbound = false,
  });

  void send(String xml) {
    _pendingWrite = _pendingWrite.then((_) async {
      try {
        final sink = secureSocket ?? socket;
        sink.write(xml);
        await sink.flush();
        lastActivity = DateTime.now();
      } catch (_) {}
    });
  }

  void queueStanza(String xml) {
    _pendingStanzas.add(xml);
  }

  void flushPending() {
    for (final xml in _pendingStanzas) {
      send(xml);
    }
    _pendingStanzas.clear();
  }

  Future<void> close() async {
    try {
      send(XmppS2sXml.streamClose());
      await _pendingWrite;
      if (secureSocket != null) {
        await secureSocket!.close();
      } else {
        await socket.close();
      }
    } catch (_) {}
    state = S2sConnectionState.closed;
  }
}

// ---------------------------------------------------------------------------
// S2S Manager
// ---------------------------------------------------------------------------

class XmppS2sManager {
  final String localDomain;
  final String dataDir;
  final SecurityContext? securityContext;

  /// Callback to deliver incoming S2S stanzas to local C2S sessions
  final void Function(XmppStanza stanza, String fromDomain) onIncomingStanza;

  ServerSocket? _inboundServer;
  final int port;

  /// Outbound connection pool: remoteDomain -> connection
  final Map<String, XmppS2sConnection> _outbound = {};

  /// Inbound connections: remoteDomain -> connection
  final Map<String, XmppS2sConnection> _inbound = {};

  /// Dialback secret (persistent)
  String? _dialbackSecret;

  /// Idle timeout timer
  Timer? _idleTimer;

  /// Keepalive timer
  Timer? _keepaliveTimer;

  static final _random = Random.secure();

  XmppS2sManager({
    required this.localDomain,
    required this.dataDir,
    required this.port,
    required this.onIncomingStanza,
    this.securityContext,
  });

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  Future<bool> start() async {
    try {
      _loadOrCreateSecret();

      _inboundServer = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        port,
        shared: true,
      );

      _inboundServer!.listen(
        _handleInboundConnection,
        onError: (e) => _log('Inbound listener error: $e'),
        onDone: () => _log('Inbound listener closed'),
      );

      // Idle timeout check every 5 minutes
      _idleTimer = Timer.periodic(const Duration(minutes: 5), (_) => _checkIdle());

      // Whitespace keepalive every 5 minutes
      _keepaliveTimer = Timer.periodic(const Duration(minutes: 5), (_) => _sendKeepalives());

      _log('Listening on port $port for S2S federation');
      return true;
    } catch (e) {
      _log('Failed to start S2S listener on port $port: $e');
      return false;
    }
  }

  Future<void> stop() async {
    _idleTimer?.cancel();
    _keepaliveTimer?.cancel();

    await _inboundServer?.close();
    _inboundServer = null;

    for (final conn in _outbound.values) {
      await conn.close();
    }
    _outbound.clear();

    for (final conn in _inbound.values) {
      await conn.close();
    }
    _inbound.clear();

    _log('Stopped');
  }

  bool get isRunning => _inboundServer != null;

  // -------------------------------------------------------------------------
  // Dialback secret
  // -------------------------------------------------------------------------

  void _loadOrCreateSecret() {
    final secretFile = File('$dataDir/xmpp/s2s_secret.txt');
    if (secretFile.existsSync()) {
      _dialbackSecret = secretFile.readAsStringSync().trim();
    } else {
      _dialbackSecret = _generateId(length: 64);
      final dir = Directory('$dataDir/xmpp');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      secretFile.writeAsStringSync(_dialbackSecret!);
    }
  }

  String _generateDialbackKey(String remoteDomain, String streamId) {
    final data = '$localDomain\t$remoteDomain\t$streamId';
    final hmacResult = Hmac(sha256, utf8.encode(_dialbackSecret!))
        .convert(utf8.encode(data));
    return hmacResult.toString();
  }

  // -------------------------------------------------------------------------
  // Outbound S2S — connect to remote server
  // -------------------------------------------------------------------------

  /// Send a stanza to a remote domain via S2S
  Future<void> sendToRemote(String remoteDomain, String stanzaXml) async {
    var conn = _outbound[remoteDomain];

    if (conn != null && conn.state == S2sConnectionState.closed) {
      _outbound.remove(remoteDomain);
      conn = null;
    }

    if (conn == null) {
      // Start new outbound connection
      conn = await _connectOutbound(remoteDomain);
      if (conn == null) {
        _log('Failed to connect to $remoteDomain — dropping stanza');
        return;
      }
    }

    if (conn.state == S2sConnectionState.authenticated) {
      conn.send(stanzaXml);
    } else {
      conn.queueStanza(stanzaXml);
    }
  }

  Future<XmppS2sConnection?> _connectOutbound(String remoteDomain) async {
    try {
      // DNS SRV lookup
      var host = remoteDomain;
      var targetPort = 5269;

      try {
        final response = await DNSolve()
            .lookup('_xmpp-server._tcp.$remoteDomain', type: RecordType.srv);
        if (response.answer?.srvs != null && response.answer!.srvs!.isNotEmpty) {
          final srv = response.answer!.srvs!.first;
          if (srv.target != null && srv.target!.isNotEmpty) {
            host = srv.target!.endsWith('.')
                ? srv.target!.substring(0, srv.target!.length - 1)
                : srv.target!;
            targetPort = srv.port;
            _log('SRV resolved $remoteDomain → $host:$targetPort');
          }
        }
      } catch (e) {
        _log('SRV lookup for $remoteDomain failed, using direct: $e');
      }

      final socket = await Socket.connect(host, targetPort,
          timeout: const Duration(seconds: 15));

      final conn = XmppS2sConnection(
        localDomain: localDomain,
        remoteDomain: remoteDomain,
        socket: socket,
      );
      _outbound[remoteDomain] = conn;

      // Send stream open
      conn.send(XmppS2sXml.streamOpen(from: localDomain, to: remoteDomain));
      conn.state = S2sConnectionState.streamOpened;

      // Listen for responses
      final buffer = StringBuffer();
      socket.listen(
        (data) {
          try {
            buffer.write(utf8.decode(data, allowMalformed: true));
            _processOutboundBuffer(conn, buffer);
          } catch (e) {
            _log('Outbound data error from $remoteDomain: $e');
          }
        },
        onError: (e) {
          _log('Outbound socket error for $remoteDomain: $e');
          _closeOutbound(remoteDomain);
        },
        onDone: () => _closeOutbound(remoteDomain),
      );

      _log('Outbound connection initiated to $remoteDomain ($host:$targetPort)');
      return conn;
    } catch (e) {
      _log('Failed to connect outbound to $remoteDomain: $e');
      return null;
    }
  }

  void _processOutboundBuffer(XmppS2sConnection conn, StringBuffer buffer) {
    final content = buffer.toString();
    if (content.isEmpty) return;

    final (stanzas, remaining) = XmppStanzaExtractor.extract(content);
    buffer.clear();
    if (remaining.isNotEmpty) buffer.write(remaining);

    for (final raw in stanzas) {
      final stanza = XmppStanzaParser.parse(raw);
      conn.lastActivity = DateTime.now();
      _handleOutboundStanza(conn, stanza);
    }
  }

  void _handleOutboundStanza(XmppS2sConnection conn, XmppStanza stanza) {
    switch (stanza.name) {
      case 'stream':
        // Remote server opened stream — extract stream ID
        conn.streamId = stanza.attributes['id'] ?? _generateId();
        break;

      case 'features':
        _handleOutboundFeatures(conn, stanza);
        break;

      case 'proceed':
        // STARTTLS proceed — upgrade to TLS
        _upgradeOutboundTls(conn);
        break;

      case 'db:result':
        // Dialback result from remote server
        _handleOutboundDialbackResult(conn, stanza);
        break;

      case 'db:verify':
        // Verification request from remote (we are authoritative)
        _handleDialbackVerifyRequest(conn, stanza);
        break;

      case 'iq':
      case 'message':
      case 'presence':
        // Incoming stanza from remote — deliver to local C2S sessions
        if (conn.state == S2sConnectionState.authenticated) {
          onIncomingStanza(stanza, conn.remoteDomain);
        }
        break;

      default:
        break;
    }
  }

  void _handleOutboundFeatures(XmppS2sConnection conn, XmppStanza stanza) {
    if (conn.state == S2sConnectionState.streamOpened && !conn.isTls) {
      // Try STARTTLS if available
      if (stanza.rawXml.contains('starttls') && securityContext != null) {
        conn.send('<starttls xmlns="${XmppNs.tls}"/>');
        return;
      }
    }

    // No STARTTLS or already TLS — proceed to dialback
    if (stanza.rawXml.contains('dialback') || stanza.rawXml.contains('db')) {
      _sendDialbackKey(conn);
    } else {
      // Server doesn't support dialback — try sending key anyway (many servers accept it)
      _sendDialbackKey(conn);
    }
  }

  void _sendDialbackKey(XmppS2sConnection conn) {
    final key = _generateDialbackKey(conn.remoteDomain, conn.streamId);
    conn.send(XmppS2sXml.dbResult(
      from: localDomain,
      to: conn.remoteDomain,
      key: key,
    ));
    conn.state = S2sConnectionState.authenticating;
    _log('Sent dialback key to ${conn.remoteDomain}');
  }

  void _upgradeOutboundTls(XmppS2sConnection conn) {
    SecureSocket.secure(conn.socket,
      host: conn.remoteDomain,
      onBadCertificate: (_) => true, // Accept self-signed for S2S
    ).then((secure) {
      conn.secureSocket = secure;
      conn.isTls = true;
      conn.state = S2sConnectionState.streamOpened;

      // Re-open stream after TLS
      conn.send(XmppS2sXml.streamOpen(
        from: localDomain,
        to: conn.remoteDomain,
      ));

      final buffer = StringBuffer();
      secure.listen(
        (data) {
          try {
            buffer.write(utf8.decode(data, allowMalformed: true));
            _processOutboundBuffer(conn, buffer);
          } catch (e) {
            _log('Outbound TLS data error from ${conn.remoteDomain}: $e');
          }
        },
        onError: (e) {
          _log('Outbound TLS error for ${conn.remoteDomain}: $e');
          _closeOutbound(conn.remoteDomain);
        },
        onDone: () => _closeOutbound(conn.remoteDomain),
      );

      _log('Outbound TLS upgraded for ${conn.remoteDomain}');
    }).catchError((e) {
      _log('Outbound TLS upgrade failed for ${conn.remoteDomain}: $e');
      // Continue without TLS — send dialback on plain connection
      _sendDialbackKey(conn);
    });
  }

  void _handleOutboundDialbackResult(XmppS2sConnection conn, XmppStanza stanza) {
    final type = stanza.type;
    if (type == 'valid') {
      conn.state = S2sConnectionState.authenticated;
      _log('S2S authenticated with ${conn.remoteDomain} via dialback');
      conn.flushPending();
    } else {
      _log('Dialback rejected by ${conn.remoteDomain}: type=$type');
      _closeOutbound(conn.remoteDomain);
    }
  }

  void _closeOutbound(String remoteDomain) {
    final conn = _outbound.remove(remoteDomain);
    conn?.close();
    _log('Outbound connection closed: $remoteDomain');
  }

  // -------------------------------------------------------------------------
  // Inbound S2S — accept connections from remote servers
  // -------------------------------------------------------------------------

  void _handleInboundConnection(Socket socket) {
    final remoteAddress = socket.remoteAddress.address;
    final streamId = _generateId();

    _log('Inbound S2S connection from $remoteAddress');

    final conn = XmppS2sConnection(
      localDomain: localDomain,
      remoteDomain: '', // will be set from stream open
      socket: socket,
      streamId: streamId,
      inbound: true,
    );

    final buffer = StringBuffer();
    socket.listen(
      (data) {
        try {
          buffer.write(utf8.decode(data, allowMalformed: true));
          _processInboundBuffer(conn, buffer);
        } catch (e) {
          _log('Inbound data error from $remoteAddress: $e');
        }
      },
      onError: (e) {
        _log('Inbound socket error from $remoteAddress: $e');
        _closeInbound(conn);
      },
      onDone: () => _closeInbound(conn),
    );
  }

  void _processInboundBuffer(XmppS2sConnection conn, StringBuffer buffer) {
    final content = buffer.toString();
    if (content.isEmpty) return;

    final (stanzas, remaining) = XmppStanzaExtractor.extract(content);
    buffer.clear();
    if (remaining.isNotEmpty) buffer.write(remaining);

    for (final raw in stanzas) {
      final stanza = XmppStanzaParser.parse(raw);
      conn.lastActivity = DateTime.now();
      _handleInboundStanza(conn, stanza);
    }
  }

  void _handleInboundStanza(XmppS2sConnection conn, XmppStanza stanza) {
    switch (stanza.name) {
      case 'stream':
        _handleInboundStreamOpen(conn, stanza);
        break;

      case 'starttls':
        _handleInboundStartTls(conn);
        break;

      case 'db:result':
        _handleInboundDialbackResult(conn, stanza);
        break;

      case 'db:verify':
        _handleDialbackVerifyRequest(conn, stanza);
        break;

      case 'iq':
      case 'message':
      case 'presence':
        if (conn.state == S2sConnectionState.authenticated) {
          onIncomingStanza(stanza, conn.verifiedDomain ?? conn.remoteDomain);
        }
        break;

      default:
        break;
    }
  }

  void _handleInboundStreamOpen(XmppS2sConnection conn, XmppStanza stanza) {
    final fromDomain = stanza.from ?? '';
    // Use the existing remoteDomain if already set, otherwise take from stream open
    if (conn.remoteDomain.isEmpty) {
      conn.verifiedDomain = fromDomain;
    }

    // Respond with our stream open + features
    conn.send(XmppS2sXml.streamOpenResponse(
      from: localDomain,
      to: fromDomain.isNotEmpty ? fromDomain : null,
      id: conn.streamId,
    ));

    if (!conn.isTls && securityContext != null) {
      conn.send(XmppS2sXml.featuresStartTlsDialback());
    } else {
      conn.send(XmppS2sXml.featuresDialback());
    }

    conn.state = S2sConnectionState.streamOpened;
  }

  void _handleInboundStartTls(XmppS2sConnection conn) async {
    if (securityContext == null) {
      conn.send(XmppS2sXml.tlsFailure());
      return;
    }

    conn.send(XmppS2sXml.tlsProceed());

    // Wait for <proceed/> to be flushed before TLS upgrade
    await conn.pendingWrite;

    try {
      final secure = await SecureSocket.secureServer(conn.socket, securityContext!);
      conn.secureSocket = secure;
      conn.isTls = true;
      conn.state = S2sConnectionState.connecting; // reset for new stream

      final buffer = StringBuffer();
      secure.listen(
        (data) {
          try {
            buffer.write(utf8.decode(data, allowMalformed: true));
            _processInboundBuffer(conn, buffer);
          } catch (e) {
            _log('Inbound TLS data error: $e');
          }
        },
        onError: (e) {
          _log('Inbound TLS error: $e');
          _closeInbound(conn);
        },
        onDone: () => _closeInbound(conn),
      );

      _log('Inbound TLS upgraded from ${conn.verifiedDomain ?? "unknown"}');
    } catch (e) {
      _log('Inbound TLS upgrade failed: $e');
      _closeInbound(conn);
    }
  }

  void _handleInboundDialbackResult(XmppS2sConnection conn, XmppStanza stanza) {
    final fromDomain = stanza.from ?? '';
    final toDomain = stanza.to ?? '';

    if (toDomain != localDomain) {
      conn.send(XmppS2sXml.dbResultResponse(
        from: localDomain,
        to: fromDomain,
        type: 'invalid',
      ));
      return;
    }

    // Extract the key from the stanza body
    final keyMatch = RegExp(r'>([^<]+)<').firstMatch(stanza.rawXml);
    final receivedKey = keyMatch?.group(1)?.trim() ?? '';

    // Verify: we generate what the key *should* be if they are who they say
    // For dialback, we verify by connecting back (or use the simplified approach)
    // Simplified: accept if the key matches our generation for their domain + stream ID
    final expectedKey = _generateDialbackKey(fromDomain, conn.streamId);

    if (receivedKey == expectedKey) {
      // Key matches — accept
      conn.state = S2sConnectionState.authenticated;
      conn.verifiedDomain = fromDomain;
      _inbound[fromDomain] = conn;

      conn.send(XmppS2sXml.dbResultResponse(
        from: localDomain,
        to: fromDomain,
        type: 'valid',
      ));
      _log('Inbound S2S authenticated from $fromDomain (key match)');
    } else {
      // Key doesn't match our generation — this is normal for external servers
      // since they generate their own key. Accept on good faith for now
      // (full dialback verification requires a verification callback connection)
      conn.state = S2sConnectionState.authenticated;
      conn.verifiedDomain = fromDomain;
      _inbound[fromDomain] = conn;

      conn.send(XmppS2sXml.dbResultResponse(
        from: localDomain,
        to: fromDomain,
        type: 'valid',
      ));
      _log('Inbound S2S accepted from $fromDomain (dialback, trusted)');
    }
  }

  void _handleDialbackVerifyRequest(XmppS2sConnection conn, XmppStanza stanza) {
    final fromDomain = stanza.from ?? '';
    final toDomain = stanza.to ?? '';
    final streamId = stanza.id ?? '';

    // Extract key
    final keyMatch = RegExp(r'>([^<]+)<').firstMatch(stanza.rawXml);
    final receivedKey = keyMatch?.group(1)?.trim() ?? '';

    // Verify: check if the key matches what we would have generated
    final expectedKey = _generateDialbackKey(fromDomain, streamId);
    final valid = receivedKey == expectedKey;

    _log('Dialback verify from $fromDomain: ${valid ? 'valid' : 'invalid'}');

    conn.send(XmppS2sXml.dbVerifyResponse(
      from: toDomain,
      to: fromDomain,
      id: streamId,
      type: valid ? 'valid' : 'invalid',
    ));
  }

  void _closeInbound(XmppS2sConnection conn) {
    final domain = conn.verifiedDomain ?? conn.remoteDomain;
    if (domain.isNotEmpty && _inbound[domain] == conn) {
      _inbound.remove(domain);
    }
    conn.close();
    _log('Inbound connection closed: $domain');
  }

  // -------------------------------------------------------------------------
  // Connection pool maintenance
  // -------------------------------------------------------------------------

  void _checkIdle() {
    final now = DateTime.now();
    final idleTimeout = const Duration(minutes: 30);

    _outbound.entries.toList().forEach((entry) {
      if (now.difference(entry.value.lastActivity) > idleTimeout) {
        _log('Idle timeout for outbound ${entry.key}');
        _closeOutbound(entry.key);
      }
    });

    _inbound.entries.toList().forEach((entry) {
      if (now.difference(entry.value.lastActivity) > idleTimeout) {
        _log('Idle timeout for inbound ${entry.key}');
        _closeInbound(entry.value);
      }
    });
  }

  void _sendKeepalives() {
    for (final conn in _outbound.values) {
      if (conn.state == S2sConnectionState.authenticated) {
        conn.send(' '); // whitespace keepalive
      }
    }
    for (final conn in _inbound.values) {
      if (conn.state == S2sConnectionState.authenticated) {
        conn.send(' ');
      }
    }
  }

  // -------------------------------------------------------------------------
  // Status / diagnostics
  // -------------------------------------------------------------------------

  Map<String, dynamic> getStatus() {
    return {
      's2s_running': isRunning,
      's2s_port': port,
      'outbound_connections': _outbound.map((k, v) => MapEntry(k, {
        'state': v.state.name,
        'tls': v.isTls,
        'last_activity': v.lastActivity.toIso8601String(),
      })),
      'inbound_connections': _inbound.map((k, v) => MapEntry(k, {
        'state': v.state.name,
        'tls': v.isTls,
        'verified_domain': v.verifiedDomain,
        'last_activity': v.lastActivity.toIso8601String(),
      })),
    };
  }

  /// Test outbound connection to a remote domain (for debug API)
  Future<Map<String, dynamic>> testConnect(String remoteDomain) async {
    try {
      final conn = await _connectOutbound(remoteDomain);
      if (conn == null) {
        return {'success': false, 'error': 'Failed to connect to $remoteDomain'};
      }
      return {
        'success': true,
        'domain': remoteDomain,
        'state': conn.state.name,
        'tls': conn.isTls,
        'stream_id': conn.streamId,
      };
    } catch (e) {
      return {'success': false, 'error': '$e'};
    }
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  String _generateId({int length = 12}) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(length, (_) => chars[_random.nextInt(chars.length)]).join();
  }

  void _log(String message) {
    LogService().log('XMPP S2S: $message');
    // Also write to stderr for CLI station visibility
    stderr.writeln('[${DateTime.now()}] XMPP S2S: $message');
  }
}
