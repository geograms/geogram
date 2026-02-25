/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * XMPP Server - Station-hosted XMPP service
 * Standalone implementation using dart:io sockets (no whixp dependency)
 *
 * Mirrors the SMTPServer pattern: raw ServerSocket, per-IP rate limiting,
 * STARTTLS via SecureSocket.secureServer(), regex-based stanza parsing.
 *
 * S2S federation via XmppS2sManager for connecting to remote XMPP servers.
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../util/xmpp_server_protocol.dart';
import 'log_service.dart';
import 'xmpp_s2s.dart';

// ---------------------------------------------------------------------------
// User account model
// ---------------------------------------------------------------------------

class XmppUserAccount {
  final String username;
  String password;
  final DateTime created;
  DateTime lastLogin;
  bool isAdmin;

  XmppUserAccount({
    required this.username,
    required this.password,
    required this.created,
    required this.lastLogin,
    this.isAdmin = false,
  });

  factory XmppUserAccount.fromJson(Map<String, dynamic> json) {
    return XmppUserAccount(
      username: json['username'] as String,
      password: json['password'] as String,
      created: DateTime.tryParse(json['created'] as String? ?? '') ?? DateTime.now(),
      lastLogin: DateTime.tryParse(json['lastLogin'] as String? ?? '') ?? DateTime.now(),
      isAdmin: json['isAdmin'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'username': username,
    'password': password,
    'created': created.toIso8601String(),
    'lastLogin': lastLogin.toIso8601String(),
    'isAdmin': isAdmin,
  };
}

// ---------------------------------------------------------------------------
// MUC room model
// ---------------------------------------------------------------------------

class XmppRoom {
  final String name; // local part (e.g. "general")
  final String jid; // full JID (e.g. "general@conference.domain")
  final DateTime created;

  /// occupant bare JID -> nickname
  final Map<String, String> occupants = {};

  XmppRoom({required this.name, required this.jid, required this.created});

  Map<String, dynamic> toJson() => {
    'name': name,
    'jid': jid,
    'created': created.toIso8601String(),
    'occupants': occupants,
  };
}

// ---------------------------------------------------------------------------
// XMPP Server
// ---------------------------------------------------------------------------

class XmppServer {
  /// Static instance reference — set when a server starts, cleared when it stops.
  /// Used by debug API to access the running server.
  static XmppServer? instance;

  final int port;
  final String domain;
  final String dataDir;
  final int maxConnectionsPerIp;
  final Duration connectionTimeout;

  /// S2S federation settings
  final bool s2sEnabled;
  final int s2sPort;

  /// S2S federation manager
  XmppS2sManager? _s2sManager;

  ServerSocket? _server;
  final Map<String, List<XmppServerSession>> _sessionsByIp = {};
  final Map<String, int> _connectionCounts = {};

  /// All bound sessions indexed by bare JID
  final Map<String, List<XmppServerSession>> _sessionsByJid = {};

  /// Registered user accounts
  final Map<String, XmppUserAccount> _users = {};

  /// MUC rooms
  final Map<String, XmppRoom> _rooms = {};

  /// TLS security context (loaded from station SSL certs)
  SecurityContext? _securityContext;

  /// Conference subdomain
  String get conferenceDomain => 'conference.$domain';

  XmppServer({
    required this.port,
    required this.domain,
    required this.dataDir,
    this.maxConnectionsPerIp = 20,
    this.connectionTimeout = const Duration(minutes: 10),
    this.s2sEnabled = false,
    this.s2sPort = 5269,
  });

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  Future<bool> start() async {
    if (_server != null) {
      _log('Already running on port $port');
      return true;
    }

    try {
      // Load user accounts
      await _loadUsers();

      // Load TLS certificates
      _loadSecurityContext();

      // Create default room
      _ensureDefaultRoom();

      _server = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        port,
        shared: true,
      );

      _server!.listen(
        _handleConnection,
        onError: (error) => _log('Server error: $error'),
        onDone: () => _log('Listener closed'),
      );

      instance = this;
      _log('Listening on port $port for domain $domain');

      // Start S2S federation if enabled
      if (s2sEnabled) {
        _s2sManager = XmppS2sManager(
          localDomain: domain,
          dataDir: dataDir,
          port: s2sPort,
          securityContext: _securityContext,
          onIncomingStanza: _handleIncomingS2sStanza,
        );
        final s2sStarted = await _s2sManager!.start();
        if (s2sStarted) {
          _log('S2S federation started on port $s2sPort');
        } else {
          _log('Failed to start S2S federation on port $s2sPort');
          _s2sManager = null;
        }
      }

      return true;
    } catch (e) {
      _log('Failed to start on port $port: $e');
      return false;
    }
  }

  Future<void> stop() async {
    await _s2sManager?.stop();
    _s2sManager = null;

    await _server?.close();
    _server = null;

    // Close all sessions
    for (final sessions in _sessionsByIp.values) {
      for (final session in sessions) {
        await session.close();
      }
    }
    _sessionsByIp.clear();
    _connectionCounts.clear();
    _sessionsByJid.clear();

    if (instance == this) instance = null;
    _log('Stopped');
  }

  bool get isRunning => _server != null;

  int get activeSessionCount =>
      _sessionsByIp.values.fold(0, (sum, list) => sum + list.length);

  int get boundSessionCount =>
      _sessionsByJid.values.fold(0, (sum, list) => sum + list.length);

  // -------------------------------------------------------------------------
  // TLS
  // -------------------------------------------------------------------------

  void _loadSecurityContext() {
    try {
      final certPath = '$dataDir/ssl/fullchain.pem';
      final keyPath = '$dataDir/ssl/privkey.pem';
      final altKeyPath = '$dataDir/ssl/domain.key';

      if (!File(certPath).existsSync()) {
        _log('No SSL cert found at $certPath — STARTTLS will be unavailable');
        return;
      }

      String? actualKeyPath;
      if (File(keyPath).existsSync()) {
        actualKeyPath = keyPath;
      } else if (File(altKeyPath).existsSync()) {
        actualKeyPath = altKeyPath;
      }

      if (actualKeyPath == null) {
        _log('No SSL private key found — STARTTLS will be unavailable');
        return;
      }

      _securityContext = SecurityContext()
        ..useCertificateChain(certPath)
        ..usePrivateKey(actualKeyPath);

      _log('TLS loaded from $certPath + $actualKeyPath');
    } catch (e) {
      _log('Failed to load TLS certs: $e');
      _securityContext = null;
    }
  }

  bool get hasTls => _securityContext != null;

  // -------------------------------------------------------------------------
  // User accounts
  // -------------------------------------------------------------------------

  String get _usersFilePath => '$dataDir/xmpp/users.json';

  Future<void> _loadUsers() async {
    try {
      final file = File(_usersFilePath);
      if (!await file.exists()) return;
      final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      _users.clear();
      for (final entry in data.entries) {
        _users[entry.key] = XmppUserAccount.fromJson(
          entry.value as Map<String, dynamic>,
        );
      }
      _log('Loaded ${_users.length} user accounts');
    } catch (e) {
      _log('Failed to load users: $e');
    }
  }

  Future<void> _saveUsers() async {
    try {
      final dir = Directory('$dataDir/xmpp');
      if (!await dir.exists()) await dir.create(recursive: true);
      final data = _users.map((k, v) => MapEntry(k, v.toJson()));
      await File(_usersFilePath).writeAsString(
        const JsonEncoder.withIndent('  ').convert(data),
      );
    } catch (e) {
      _log('Failed to save users: $e');
    }
  }

  /// Register a new user. Returns true on success.
  Future<bool> registerUser(String username, String password, {bool isAdmin = false}) async {
    final normalized = username.toLowerCase().trim();
    if (normalized.isEmpty || password.isEmpty) return false;
    if (_users.containsKey(normalized)) return false;

    _users[normalized] = XmppUserAccount(
      username: normalized,
      password: password,
      created: DateTime.now(),
      lastLogin: DateTime.now(),
      isAdmin: isAdmin,
    );
    await _saveUsers();
    _log('Registered user: $normalized (admin=$isAdmin)');
    return true;
  }

  bool validateCredentials(String username, String password) {
    final account = _users[username.toLowerCase().trim()];
    return account != null && account.password == password;
  }

  /// Auto-provision the station callsign as admin
  Future<void> autoProvisionAdmin(String callsign, String password) async {
    final normalized = callsign.toLowerCase().trim();
    if (_users.containsKey(normalized)) return;
    await registerUser(normalized, password, isAdmin: true);
    _log('Auto-provisioned admin: $normalized');
  }

  List<Map<String, dynamic>> listUsers() {
    return _users.values.map((u) => {
      'username': u.username,
      'created': u.created.toIso8601String(),
      'lastLogin': u.lastLogin.toIso8601String(),
      'isAdmin': u.isAdmin,
      'jid': '${u.username}@$domain',
    }).toList();
  }

  // -------------------------------------------------------------------------
  // MUC rooms
  // -------------------------------------------------------------------------

  void _ensureDefaultRoom() {
    final roomJid = 'general@$conferenceDomain';
    if (!_rooms.containsKey(roomJid)) {
      _rooms[roomJid] = XmppRoom(
        name: 'general',
        jid: roomJid,
        created: DateTime.now(),
      );
      _log('Created default room: $roomJid');
    }
  }

  XmppRoom? getRoom(String roomJid) => _rooms[roomJid];

  XmppRoom createRoom(String name) {
    final jid = '$name@$conferenceDomain';
    return _rooms.putIfAbsent(jid, () => XmppRoom(
      name: name,
      jid: jid,
      created: DateTime.now(),
    ));
  }

  List<Map<String, dynamic>> listRooms() {
    return _rooms.values.map((r) => r.toJson()).toList();
  }

  /// Kick a user from a room (admin action)
  bool kickFromRoom(String roomJid, String bareJid) {
    final room = _rooms[roomJid];
    if (room == null) return false;
    if (!room.occupants.containsKey(bareJid)) return false;

    final nick = room.occupants.remove(bareJid)!;
    // Send unavailable presence to all remaining occupants
    for (final occupantJid in room.occupants.keys) {
      final sessions = _sessionsByJid[occupantJid] ?? [];
      for (final s in sessions) {
        s.send(XmppXml.mucPresence(
          from: '$roomJid/$nick',
          to: s.fullJid!,
          type: 'unavailable',
          affiliation: 'none',
          role: 'none',
          statusCodes: [307], // kicked
        ));
      }
    }

    // Notify the kicked user
    final kickedSessions = _sessionsByJid[bareJid] ?? [];
    for (final s in kickedSessions) {
      s.send(XmppXml.mucPresence(
        from: '$roomJid/$nick',
        to: s.fullJid!,
        type: 'unavailable',
        affiliation: 'none',
        role: 'none',
        statusCodes: [307, 110],
      ));
      s.joinedRooms.remove(roomJid);
    }

    return true;
  }

  // -------------------------------------------------------------------------
  // Connection handling
  // -------------------------------------------------------------------------

  void _handleConnection(Socket socket) {
    final remoteAddress = socket.remoteAddress.address;

    // Rate limit
    final count = _connectionCounts[remoteAddress] ?? 0;
    if (count >= maxConnectionsPerIp) {
      _log('Connection limit exceeded for $remoteAddress');
      socket.write(XmppXml.streamError('policy-violation'));
      socket.write(XmppXml.streamClose());
      socket.close();
      return;
    }

    final streamId = _generateId();
    final session = XmppServerSession(
      socket: socket,
      remoteAddress: remoteAddress,
      serverDomain: domain,
      streamId: streamId,
    );

    _sessionsByIp.putIfAbsent(remoteAddress, () => []).add(session);
    _connectionCounts[remoteAddress] = count + 1;

    _log('New connection from $remoteAddress (stream=$streamId)');

    // Listen for data
    final buffer = StringBuffer();

    socket.listen(
      (data) {
        try {
          buffer.write(utf8.decode(data, allowMalformed: true));
          _processBuffer(session, buffer);
        } catch (e) {
          _log('Error processing data from $remoteAddress: $e');
        }
      },
      onError: (error) {
        _log('Socket error from $remoteAddress: $error');
        _closeSession(session);
      },
      onDone: () {
        _closeSession(session);
      },
    );

    // Connection timeout
    Timer(connectionTimeout, () {
      if (session.state != XmppServerState.closed) {
        _log('Connection timeout for $remoteAddress');
        _closeSession(session);
      }
    });
  }

  // -------------------------------------------------------------------------
  // Buffer processing
  // -------------------------------------------------------------------------

  void _processBuffer(XmppServerSession session, StringBuffer buffer) {
    final content = buffer.toString();
    if (content.isEmpty) return;

    final (stanzas, remaining) = XmppStanzaExtractor.extract(content);
    buffer.clear();
    if (remaining.isNotEmpty) buffer.write(remaining);

    for (final raw in stanzas) {
      final stanza = XmppStanzaParser.parse(raw);
      session.lastActivity = DateTime.now();
      _handleStanza(session, stanza);
    }
  }

  // -------------------------------------------------------------------------
  // Stanza dispatch
  // -------------------------------------------------------------------------

  void _handleStanza(XmppServerSession session, XmppStanza stanza) {
    switch (stanza.name) {
      case 'stream':
        _handleStreamOpen(session, stanza);
      case 'starttls':
        _handleStartTls(session);
      case 'auth':
        _handleAuth(session, stanza);
      case 'iq':
        _handleIq(session, stanza);
      case 'message':
        _handleMessage(session, stanza);
      case 'presence':
        _handlePresence(session, stanza);
      default:
        // Ignore unknown stanzas (XML declarations, etc.)
        break;
    }
  }

  // -------------------------------------------------------------------------
  // Stream negotiation
  // -------------------------------------------------------------------------

  void _handleStreamOpen(XmppServerSession session, XmppStanza stanza) {
    switch (session.state) {
      case XmppServerState.connected:
        // Initial stream — offer STARTTLS if available
        session.send(XmppXml.streamOpen(
          from: domain,
          id: session.streamId,
        ));
        if (hasTls) {
          session.send(XmppXml.featuresStartTls());
          session.state = XmppServerState.streamOpened;
        } else {
          // No TLS available, skip to SASL
          session.send(XmppXml.featuresSaslAndRegister());
          session.state = XmppServerState.awaitingAuth;
        }

      case XmppServerState.tlsEstablished:
        // Re-opened after TLS — offer SASL + register
        session.send(XmppXml.streamOpen(
          from: domain,
          id: session.streamId,
        ));
        session.send(XmppXml.featuresSaslAndRegister());
        session.state = XmppServerState.awaitingAuth;

      case XmppServerState.authenticated:
        // Re-opened after SASL — offer bind/session
        session.send(XmppXml.streamOpen(
          from: domain,
          id: session.streamId,
        ));
        session.send(XmppXml.featuresBindSession());
        session.state = XmppServerState.awaitingBind;

      default:
        // Unexpected stream restart
        session.send(XmppXml.streamError('policy-violation'));
        _closeSession(session);
    }
  }

  // -------------------------------------------------------------------------
  // STARTTLS
  // -------------------------------------------------------------------------

  void _handleStartTls(XmppServerSession session) async {
    if (session.state != XmppServerState.streamOpened || !hasTls) {
      session.send(XmppXml.tlsFailure());
      return;
    }

    session.send(XmppXml.tlsProceed());

    // Wait for <proceed/> to be flushed before upgrading the socket
    await session.pendingWrite;

    // Upgrade to TLS
    SecureSocket.secureServer(session.socket, _securityContext!).then((secure) {
      session.secureSocket = secure;
      session.isTls = true;
      session.state = XmppServerState.tlsEstablished;

      // Re-listen on the secure socket
      final buffer = StringBuffer();
      secure.listen(
        (data) {
          try {
            buffer.write(utf8.decode(data, allowMalformed: true));
            _processBuffer(session, buffer);
          } catch (e) {
            _log('TLS data error from ${session.remoteAddress}: $e');
          }
        },
        onError: (error) {
          _log('TLS socket error: $error');
          _closeSession(session);
        },
        onDone: () => _closeSession(session),
      );
    }).catchError((e) {
      _log('TLS upgrade failed for ${session.remoteAddress}: $e');
      _closeSession(session);
    });
  }

  // -------------------------------------------------------------------------
  // SASL authentication
  // -------------------------------------------------------------------------

  void _handleAuth(XmppServerSession session, XmppStanza stanza) {
    if (session.state != XmppServerState.awaitingAuth) {
      session.send(XmppXml.saslFailure('not-authorized'));
      return;
    }

    final mechanism = stanza.attributes['mechanism'];
    if (mechanism != 'PLAIN') {
      session.send(XmppXml.saslFailure('invalid-mechanism'));
      return;
    }

    // Extract base64 payload from the <auth> body
    final payloadMatch = RegExp(r'>([^<]+)<').firstMatch(stanza.rawXml);
    final payload = payloadMatch?.group(1)?.trim() ?? '';

    final creds = SaslPlain.decode(payload);
    if (creds == null) {
      session.send(XmppXml.saslFailure('malformed-request'));
      return;
    }

    if (!validateCredentials(creds.username, creds.password)) {
      _log('Auth failed for ${creds.username} from ${session.remoteAddress}');
      session.send(XmppXml.saslFailure('not-authorized'));
      return;
    }

    // Update last login
    final account = _users[creds.username.toLowerCase()];
    if (account != null) {
      account.lastLogin = DateTime.now();
      _saveUsers(); // fire-and-forget
    }

    session.username = creds.username.toLowerCase();
    session.state = XmppServerState.authenticated;
    session.send(XmppXml.saslSuccess());
    _log('Authenticated: ${session.username} from ${session.remoteAddress}');
  }

  // -------------------------------------------------------------------------
  // IQ handling
  // -------------------------------------------------------------------------

  void _handleIq(XmppServerSession session, XmppStanza stanza) {
    final id = stanza.id ?? '';
    final type = stanza.type ?? '';

    // Registration (XEP-0077) — allowed before auth
    final queryNs = stanza.childXmlns('query');
    if (queryNs == XmppNs.register) {
      _handleRegistration(session, stanza);
      return;
    }

    // Everything else requires at least authentication
    if (session.state.index < XmppServerState.awaitingBind.index) {
      session.send(XmppXml.iqError(
        id: id,
        errorType: 'auth',
        condition: 'not-authorized',
      ));
      return;
    }

    // Bind
    if (stanza.hasChild('bind')) {
      _handleBind(session, stanza);
      return;
    }

    // Session
    if (stanza.hasChild('session')) {
      session.send(XmppXml.sessionResult(id: id, to: session.fullJid));
      return;
    }

    // Forward IQ to remote domain via S2S if the 'to' is not local
    final iqTo = stanza.to ?? '';
    if (iqTo.isNotEmpty && _s2sManager != null) {
      final toJid = Jid.parse(iqTo);
      final toDomain = toJid?.domain ?? iqTo;
      if (toDomain != domain && toDomain != conferenceDomain) {
        _forwardViaS2s(session, stanza);
        return;
      }
    }

    // Disco#info
    if (queryNs == XmppNs.discoInfo) {
      _handleDiscoInfo(session, stanza);
      return;
    }

    // Disco#items
    if (queryNs == XmppNs.discoItems) {
      _handleDiscoItems(session, stanza);
      return;
    }

    // Roster
    if (queryNs == XmppNs.roster) {
      session.send(XmppXml.rosterResult(id: id, to: session.fullJid));
      return;
    }

    // Ping (XEP-0199)
    if (stanza.hasChild('ping')) {
      session.send(XmppXml.pong(
        id: id,
        from: domain,
        to: session.fullJid ?? session.bareJid ?? '',
      ));
      return;
    }

    // vCard
    if (queryNs == XmppNs.vcard) {
      session.send(XmppXml.iqResult(id: id, to: session.fullJid));
      return;
    }

    // Unknown IQ — return service-unavailable
    if (type == 'get' || type == 'set') {
      session.send(XmppXml.iqError(
        id: id,
        to: session.fullJid,
        errorType: 'cancel',
        condition: 'service-unavailable',
      ));
    }
  }

  // -------------------------------------------------------------------------
  // Resource binding
  // -------------------------------------------------------------------------

  void _handleBind(XmppServerSession session, XmppStanza stanza) {
    if (session.state != XmppServerState.awaitingBind || session.username == null) {
      session.send(XmppXml.iqError(
        id: stanza.id ?? '',
        errorType: 'auth',
        condition: 'not-authorized',
      ));
      return;
    }

    // Client may request a resource, or we generate one
    var resource = stanza.childText('resource');
    if (resource == null || resource.isEmpty) {
      resource = 'geogram-${_generateId(length: 6)}';
    }

    session.resource = resource;
    session.jid = Jid(
      local: session.username!,
      domain: domain,
      resource: resource,
    );
    session.state = XmppServerState.bound;

    // Track by JID
    _sessionsByJid.putIfAbsent(session.bareJid!, () => []).add(session);

    session.send(XmppXml.bindResult(
      id: stanza.id ?? '',
      jid: session.fullJid!,
    ));

    _log('Bound: ${session.fullJid}');
  }

  // -------------------------------------------------------------------------
  // Registration (XEP-0077)
  // -------------------------------------------------------------------------

  void _handleRegistration(XmppServerSession session, XmppStanza stanza) {
    final id = stanza.id ?? '';
    final type = stanza.type ?? '';

    if (type == 'get') {
      // Return registration form
      session.send(XmppXml.registerForm(id: id));
      return;
    }

    if (type == 'set') {
      final username = stanza.childText('username');
      final password = stanza.childText('password');

      if (username == null || username.isEmpty || password == null || password.isEmpty) {
        session.send(XmppXml.iqError(
          id: id,
          errorType: 'modify',
          condition: 'not-acceptable',
        ));
        return;
      }

      // Check if username is taken
      if (_users.containsKey(username.toLowerCase())) {
        session.send(XmppXml.registerConflict(id: id));
        return;
      }

      // Register
      registerUser(username, password).then((success) {
        if (success) {
          session.send(XmppXml.registerSuccess(id: id));
          _log('XEP-0077 registration: $username from ${session.remoteAddress}');
        } else {
          session.send(XmppXml.iqError(
            id: id,
            errorType: 'cancel',
            condition: 'internal-server-error',
          ));
        }
      });
      return;
    }
  }

  // -------------------------------------------------------------------------
  // Message routing
  // -------------------------------------------------------------------------

  void _handleMessage(XmppServerSession session, XmppStanza stanza) {
    if (session.state != XmppServerState.bound) return;

    final to = stanza.to;
    final type = stanza.type ?? 'chat';

    if (to == null) return;

    if (type == 'groupchat') {
      _routeGroupMessage(session, stanza);
    } else {
      _routeDirectMessage(session, stanza);
    }
  }

  void _routeDirectMessage(XmppServerSession session, XmppStanza stanza) {
    final toJid = Jid.parse(stanza.to!);
    if (toJid == null) return;

    // Forward to remote domain via S2S if not local
    if (toJid.domain != domain && _s2sManager != null) {
      _forwardViaS2s(session, stanza);
      return;
    }

    final targetSessions = _sessionsByJid[toJid.bare] ?? [];
    if (targetSessions.isEmpty) {
      // User offline — silently drop for now (no offline storage in v1)
      return;
    }

    // Rewrite 'from' to include server-assigned JID
    final body = stanza.body;
    if (body == null) return;

    for (final target in targetSessions) {
      target.send(XmppXml.message(
        from: session.fullJid!,
        to: target.fullJid!,
        type: stanza.type ?? 'chat',
        id: stanza.id,
        body: body,
      ));
    }
  }

  void _routeGroupMessage(XmppServerSession session, XmppStanza stanza) {
    final roomJid = Jid.parse(stanza.to!)?.bare ?? stanza.to!;
    // Strip resource from room JID if present
    final actualRoomJid = roomJid.contains('/') ? roomJid.split('/').first : roomJid;

    // Check if this is a remote MUC room — forward via S2S
    final roomDomain = actualRoomJid.contains('@')
        ? actualRoomJid.split('@').last
        : '';
    if (roomDomain.isNotEmpty &&
        roomDomain != conferenceDomain &&
        roomDomain != domain &&
        _s2sManager != null) {
      _forwardViaS2s(session, stanza);
      return;
    }

    final room = _rooms[actualRoomJid];
    if (room == null) return;

    // Must be an occupant
    final nick = room.occupants[session.bareJid!];
    if (nick == null) return;

    final body = stanza.body;
    if (body == null) return;

    // Broadcast to all occupants
    for (final occupantJid in room.occupants.keys) {
      final sessions = _sessionsByJid[occupantJid] ?? [];
      for (final target in sessions) {
        target.send(XmppXml.message(
          from: '$actualRoomJid/$nick',
          to: target.fullJid!,
          type: 'groupchat',
          id: stanza.id,
          body: body,
        ));
      }
    }
  }

  // -------------------------------------------------------------------------
  // Presence handling
  // -------------------------------------------------------------------------

  void _handlePresence(XmppServerSession session, XmppStanza stanza) {
    if (session.state != XmppServerState.bound) return;

    final to = stanza.to;
    final type = stanza.type;

    // Check for remote MUC join/leave — forward via S2S
    if (to != null && _s2sManager != null) {
      final toJid = Jid.parse(to);
      if (toJid != null) {
        final targetDomain = toJid.domain;
        if (targetDomain != conferenceDomain &&
            targetDomain != domain &&
            targetDomain.isNotEmpty) {
          _forwardViaS2s(session, stanza);
          return;
        }
      }
    }

    // MUC join — presence to room@conference.domain/nickname
    if (to != null && to.contains(conferenceDomain)) {
      if (type == 'unavailable') {
        _handleMucLeave(session, stanza);
      } else {
        _handleMucJoin(session, stanza);
      }
      return;
    }

    // Regular presence broadcast to contacts who are online
    // In v1 we simply broadcast available/unavailable to all bound sessions
    if (type == 'unavailable') {
      _broadcastPresence(session, type: 'unavailable');
    } else if (type == null) {
      // Available presence
      _broadcastPresence(session);
    }
  }

  void _broadcastPresence(XmppServerSession session, {String? type}) {
    for (final sessions in _sessionsByJid.values) {
      for (final target in sessions) {
        if (target.fullJid == session.fullJid) continue;
        target.send(XmppXml.presence(
          from: session.fullJid,
          to: target.fullJid,
          type: type,
        ));
      }
    }
  }

  // -------------------------------------------------------------------------
  // MUC (XEP-0045)
  // -------------------------------------------------------------------------

  void _handleMucJoin(XmppServerSession session, XmppStanza stanza) {
    final toJid = Jid.parse(stanza.to!);
    if (toJid == null) return;

    final roomJid = '${toJid.local}@${toJid.domain}';
    final nick = toJid.resource ?? session.username ?? 'anonymous';

    // Auto-create room if it doesn't exist
    if (!_rooms.containsKey(roomJid)) {
      final roomName = toJid.local;
      if (!roomJid.contains(conferenceDomain)) return; // wrong domain
      _rooms[roomJid] = XmppRoom(
        name: roomName,
        jid: roomJid,
        created: DateTime.now(),
      );
      _log('Auto-created room: $roomJid');
    }

    final room = _rooms[roomJid]!;

    // Send existing occupants' presence to the new joiner
    for (final entry in room.occupants.entries) {
      session.send(XmppXml.mucPresence(
        from: '$roomJid/${entry.value}',
        to: session.fullJid!,
        affiliation: 'member',
        role: 'participant',
      ));
    }

    // Add new occupant
    room.occupants[session.bareJid!] = nick;
    session.joinedRooms[roomJid] = nick;

    // Announce new occupant to all (including self with status 110)
    for (final occupantJid in room.occupants.keys) {
      final sessions = _sessionsByJid[occupantJid] ?? [];
      final isSelf = occupantJid == session.bareJid;
      for (final target in sessions) {
        target.send(XmppXml.mucPresence(
          from: '$roomJid/$nick',
          to: target.fullJid!,
          affiliation: 'member',
          role: 'participant',
          statusCodes: isSelf ? [110] : [],
        ));
      }
    }

    _log('MUC join: ${session.bareJid} -> $roomJid as $nick');
  }

  void _handleMucLeave(XmppServerSession session, XmppStanza stanza) {
    final toJid = Jid.parse(stanza.to!);
    if (toJid == null) return;

    final roomJid = '${toJid.local}@${toJid.domain}';
    final room = _rooms[roomJid];
    if (room == null) return;

    final nick = room.occupants.remove(session.bareJid!);
    session.joinedRooms.remove(roomJid);
    if (nick == null) return;

    // Announce departure to remaining occupants
    for (final occupantJid in room.occupants.keys) {
      final sessions = _sessionsByJid[occupantJid] ?? [];
      for (final target in sessions) {
        target.send(XmppXml.mucPresence(
          from: '$roomJid/$nick',
          to: target.fullJid!,
          type: 'unavailable',
          affiliation: 'none',
          role: 'none',
        ));
      }
    }

    // Confirm to the leaving user
    session.send(XmppXml.mucPresence(
      from: '$roomJid/$nick',
      to: session.fullJid!,
      type: 'unavailable',
      affiliation: 'none',
      role: 'none',
      statusCodes: [110],
    ));

    _log('MUC leave: ${session.bareJid} from $roomJid');
  }

  // -------------------------------------------------------------------------
  // Service Discovery (XEP-0030)
  // -------------------------------------------------------------------------

  void _handleDiscoInfo(XmppServerSession session, XmppStanza stanza) {
    final id = stanza.id ?? '';
    final to = stanza.to ?? domain;

    // Is this a query to a room?
    if (to.contains(conferenceDomain)) {
      final room = _rooms[to];
      if (room != null) {
        session.send(XmppXml.discoInfoRoom(
          id: id,
          to: session.fullJid!,
          roomJid: room.jid,
          roomName: room.name,
        ));
      } else {
        session.send(XmppXml.iqError(
          id: id,
          to: session.fullJid,
          errorType: 'cancel',
          condition: 'item-not-found',
        ));
      }
      return;
    }

    // Server disco#info
    session.send(XmppXml.discoInfoServer(
      id: id,
      to: session.fullJid!,
      domain: domain,
    ));
  }

  void _handleDiscoItems(XmppServerSession session, XmppStanza stanza) {
    final id = stanza.id ?? '';
    final to = stanza.to ?? domain;

    // Items query to server → list rooms via conference subdomain
    if (!to.contains(conferenceDomain)) {
      // Return conference service as an item
      session.send(XmppXml.discoItems(
        id: id,
        to: session.fullJid!,
        from: domain,
        items: [MapEntry(conferenceDomain, 'Chat Rooms')],
      ));
      return;
    }

    // Items query to conference subdomain → list rooms
    final roomItems = _rooms.values
        .map((r) => MapEntry(r.jid, r.name))
        .toList();

    session.send(XmppXml.discoItems(
      id: id,
      to: session.fullJid!,
      from: conferenceDomain,
      items: roomItems,
    ));
  }

  // -------------------------------------------------------------------------
  // S2S forwarding
  // -------------------------------------------------------------------------

  /// Forward a C2S stanza to a remote domain via S2S federation
  void _forwardViaS2s(XmppServerSession session, XmppStanza stanza) {
    if (_s2sManager == null) return;

    final to = stanza.to;
    if (to == null) return;

    // Determine the remote domain from the 'to' JID
    final toJid = Jid.parse(to);
    // For bare domains (no @), use the full 'to' as the domain
    final remoteDomain = toJid?.domain ?? to.split('/').first;
    if (remoteDomain.isEmpty) return;

    // Rewrite the 'from' attribute to use the server-assigned JID
    // and forward the raw XML with corrected from
    final fromJid = session.fullJid ?? session.bareJid ?? '';
    final rewritten = stanza.rawXml
        .replaceFirst(RegExp(r"from='[^']*'"), "from='$fromJid'")
        .replaceFirst(RegExp(r'from="[^"]*"'), 'from="$fromJid"');

    // If there was no from attribute, add one
    final xml = rewritten.contains('from=')
        ? rewritten
        : rewritten.replaceFirst('<${stanza.name}', "<${stanza.name} from='$fromJid'");

    _s2sManager!.sendToRemote(remoteDomain, xml);
    _log('S2S forward: ${stanza.name} from $fromJid to $to via $remoteDomain');
  }

  /// Handle an incoming stanza from a remote server via S2S
  void _handleIncomingS2sStanza(XmppStanza stanza, String fromDomain) {
    final to = stanza.to;
    if (to == null) return;

    // Handle IQ queries directed at our server domain
    if (stanza.name == 'iq' && (to == domain || to == conferenceDomain)) {
      _handleS2sIq(stanza, fromDomain);
      return;
    }

    final toJid = Jid.parse(to);
    if (toJid == null) return;

    // Route to local C2S sessions
    final targetSessions = _sessionsByJid[toJid.bare] ?? [];
    if (targetSessions.isEmpty) {
      // Also check by full JID (for presence directed to specific resource)
      for (final sessions in _sessionsByJid.values) {
        for (final s in sessions) {
          if (s.fullJid == to) {
            s.send(stanza.rawXml);
            return;
          }
        }
      }
      return;
    }

    for (final target in targetSessions) {
      target.send(stanza.rawXml);
    }
  }

  /// Handle IQ queries from remote servers directed at our domain
  void _handleS2sIq(XmppStanza stanza, String fromDomain) {
    final id = stanza.id ?? '';
    final from = stanza.from ?? '';
    final to = stanza.to ?? domain;
    final type = stanza.type;
    final queryNs = stanza.childXmlns('query');

    if (type == 'get' && queryNs == XmppNs.discoInfo) {
      // Respond with server disco#info via S2S
      final response = "<iq type='result' id='$id' to='$from' from='$to'>"
          "<query xmlns='${XmppNs.discoInfo}'>"
          "<identity category='server' type='im' name='Geogram XMPP'/>"
          "<feature var='${XmppNs.discoInfo}'/>"
          "<feature var='${XmppNs.discoItems}'/>"
          "<feature var='${XmppNs.muc}'/>"
          "<feature var='${XmppNs.ping}'/>"
          "</query></iq>";
      _s2sManager?.sendToRemote(fromDomain, response);
    } else if (type == 'get' && queryNs == XmppNs.discoItems) {
      // Empty items response
      final response = "<iq type='result' id='$id' to='$from' from='$to'>"
          "<query xmlns='${XmppNs.discoItems}'/></iq>";
      _s2sManager?.sendToRemote(fromDomain, response);
    }
  }

  /// Get S2S manager status (for debug API)
  Map<String, dynamic>? getS2sStatus() => _s2sManager?.getStatus();

  /// Get S2S manager (for debug API)
  XmppS2sManager? get s2sManager => _s2sManager;

  // -------------------------------------------------------------------------
  // Session cleanup
  // -------------------------------------------------------------------------

  void _closeSession(XmppServerSession session) {
    // Remove from MUC rooms
    for (final roomJid in session.joinedRooms.keys.toList()) {
      final room = _rooms[roomJid];
      if (room != null) {
        final nick = room.occupants.remove(session.bareJid);
        if (nick != null) {
          // Notify remaining occupants
          for (final occupantJid in room.occupants.keys) {
            final sessions = _sessionsByJid[occupantJid] ?? [];
            for (final target in sessions) {
              target.send(XmppXml.mucPresence(
                from: '$roomJid/$nick',
                to: target.fullJid!,
                type: 'unavailable',
                affiliation: 'none',
                role: 'none',
              ));
            }
          }
        }
      }
    }

    // Send unavailable presence to all
    if (session.state == XmppServerState.bound) {
      _broadcastPresence(session, type: 'unavailable');
    }

    // Remove from JID tracking
    if (session.bareJid != null) {
      _sessionsByJid[session.bareJid!]?.remove(session);
      if (_sessionsByJid[session.bareJid!]?.isEmpty ?? false) {
        _sessionsByJid.remove(session.bareJid!);
      }
    }

    // Remove from IP tracking
    _sessionsByIp[session.remoteAddress]?.remove(session);
    if (_sessionsByIp[session.remoteAddress]?.isEmpty ?? false) {
      _sessionsByIp.remove(session.remoteAddress);
    }
    final count = _connectionCounts[session.remoteAddress] ?? 0;
    if (count > 1) {
      _connectionCounts[session.remoteAddress] = count - 1;
    } else {
      _connectionCounts.remove(session.remoteAddress);
    }

    session.close();
    _log('Session closed: ${session.fullJid ?? session.remoteAddress}');
  }

  // -------------------------------------------------------------------------
  // Status
  // -------------------------------------------------------------------------

  Map<String, dynamic> getStatus() {
    return {
      'running': isRunning,
      'domain': domain,
      'port': port,
      'tls_available': hasTls,
      'active_connections': activeSessionCount,
      'bound_sessions': boundSessionCount,
      'registered_users': _users.length,
      'rooms': _rooms.length,
      'room_list': _rooms.keys.toList(),
      'online_jids': _sessionsByJid.keys.toList(),
      's2s_enabled': s2sEnabled,
      's2s_port': s2sPort,
      's2s_running': _s2sManager?.isRunning ?? false,
    };
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  static final _random = Random.secure();

  String _generateId({int length = 12}) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(length, (_) => chars[_random.nextInt(chars.length)]).join();
  }

  void _log(String message) {
    LogService().log('XMPP Server: $message');
    // Also write to stderr for CLI station visibility
    stderr.writeln('[${DateTime.now()}] XMPP Server: $message');
  }
}
