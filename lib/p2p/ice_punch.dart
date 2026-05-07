/// Simplified ICE-style UDP hole punching for P2P connections.
///
/// No WebRTC overhead — raw UDP datagrams with out-of-band signaling.
/// (Currently unused; kept as scaffolding for a future direct-UDP path.)
///
/// Flow:
/// 1. Both peers learn own public IP:port from STUN
/// 2. Exchange candidates via the regular geogram signaling channel
/// 3. Simultaneous UDP send to each other's public address
/// 4. NAT creates mapping → return traffic allowed → direct link
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../services/log_service.dart';
import 'node_capability.dart';

/// Connection state for a direct P2P link.
enum DirectConnectionState {
  /// Exchanging ICE candidates.
  signaling,

  /// Attempting hole punch.
  punching,

  /// Direct UDP link established.
  connected,

  /// Connection failed or closed.
  disconnected,
}

/// An ICE candidate (our public address as seen by STUN).
class IceCandidate {
  final String ip;
  final int port;
  final bool isRelay; // true if this is a relay address (Type C fallback)

  const IceCandidate({
    required this.ip,
    required this.port,
    this.isRelay = false,
  });

  Map<String, dynamic> toJson() => {
        'ip': ip,
        'port': port,
        'relay': isRelay,
      };

  factory IceCandidate.fromJson(Map<String, dynamic> json) => IceCandidate(
        ip: json['ip'] as String,
        port: json['port'] as int,
        isRelay: json['relay'] as bool? ?? false,
      );

  @override
  String toString() => 'IceCandidate($ip:$port${isRelay ? " relay" : ""})';
}

/// A direct UDP connection to a peer.
class DirectConnection {
  /// Remote peer's IP.
  final String remoteIp;

  /// Remote peer's port (the one initially advertised).
  final int remotePort;

  /// Actual port responses came from — set when port prediction lands
  /// on a NAT-remapped port instead of the advertised one.
  int? _actualRemotePort;
  int get effectivePort => _actualRemotePort ?? remotePort;

  /// Our UDP socket for this connection.
  final RawDatagramSocket socket;

  /// Remote peer's identity info (after handshake).
  String? deviceId;
  String? deviceName;
  String? callsign;
  String? npub;

  /// Connection state.
  DirectConnectionState _state = DirectConnectionState.signaling;
  DirectConnectionState get state => _state;

  /// Last time we received data from the peer.
  DateTime lastActivity = DateTime.now();

  /// Stream of incoming data from the peer.
  final _dataController = StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get onData => _dataController.stream;

  /// Keepalive timer.
  Timer? _keepaliveTimer;

  DirectConnection({
    required this.remoteIp,
    required this.remotePort,
    required this.socket,
  });

  /// Send raw bytes to the peer.
  void send(Uint8List data) {
    if (_state != DirectConnectionState.connected) return;
    try {
      socket.send(data, InternetAddress(remoteIp), effectivePort);
    } catch (e) {
      LogService().log('DirectConnection send error: $e');
    }
  }

  /// Send a JSON message to the peer.
  void sendJson(Map<String, dynamic> json) {
    send(Uint8List.fromList(utf8.encode(jsonEncode(json))));
  }

  /// Start keepalive pings (every 30s).
  void startKeepalive() {
    _keepaliveTimer?.cancel();
    _keepaliveTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_state == DirectConnectionState.connected) {
        // Send a minimal ping
        try {
          socket.send(
            Uint8List.fromList(utf8.encode('{"type":"ping"}')),
            InternetAddress(remoteIp),
            effectivePort,
          );
        } catch (_) {
          _state = DirectConnectionState.disconnected;
          _keepaliveTimer?.cancel();
        }
      }
    });
  }

  /// Check if connection is still alive (received data in last 90s).
  bool get isAlive =>
      _state == DirectConnectionState.connected &&
      DateTime.now().difference(lastActivity) < const Duration(seconds: 90);

  /// Close the connection.
  void close() {
    _state = DirectConnectionState.disconnected;
    _keepaliveTimer?.cancel();
    _dataController.close();
  }

  void _handleIncoming(Uint8List data) {
    lastActivity = DateTime.now();
    if (!_dataController.isClosed) {
      _dataController.add(data);
    }
  }
}

/// Manages UDP hole punching to establish direct connections.
class IcePunch {
  /// Active direct connections, keyed by "ip:port".
  final Map<String, DirectConnection> _connections = {};

  /// Get all active connections.
  List<DirectConnection> get activeConnections =>
      _connections.values.where((c) => c.isAlive).toList();

  /// Get connection count.
  int get connectionCount => activeConnections.length;

  /// Callback for incoming UDP data routed from DhtNode's socket.
  /// Called when DhtNode receives a non-bencode packet.
  void handleIncomingPacket(Datagram datagram) {
    final key = '${datagram.address.address}:${datagram.port}';
    final conn = _connections[key];
    if (conn != null) {
      if (conn._state == DirectConnectionState.punching) {
        conn._state = DirectConnectionState.connected;
        LogService().log('IcePunch: hole punch SUCCESS from $key');
      }
      conn._handleIncoming(datagram.data);
      return;
    }

    // No exact-port match. Try connections whose remoteIp matches and
    // are still in the punching state — port prediction may have landed
    // on a different external port than the advertised one.
    for (final c in _connections.values) {
      if (c.remoteIp == datagram.address.address &&
          c._state == DirectConnectionState.punching) {
        c._actualRemotePort = datagram.port;
        c._state = DirectConnectionState.connected;
        LogService().log(
            'IcePunch: hole punch SUCCESS from $key (remapped from advertised ${c.remotePort})');
        c._handleIncoming(datagram.data);
        return;
      }
    }

    // Hole-punch transport's GP01 framing — surface it even before any
    // local punch was issued (the peer may have punched first via a
    // tracker-coordinated handshake).
    if (datagram.data.length >= 4 &&
        datagram.data[0] == 0x47 && // 'G'
        datagram.data[1] == 0x50 && // 'P'
        datagram.data[2] == 0x30 && // '0'
        datagram.data[3] == 0x31) { // '1'
      _pendingIncoming[key] = datagram;
      onUnsolicitedFrame?.call(datagram);
      return;
    }

    // Check if this is a punch packet from an unknown peer (they punched first)
    try {
      final json = jsonDecode(utf8.decode(datagram.data));
      if (json is Map && (json['type'] == 'punch' || json['type'] == 'hello')) {
        LogService().log('IcePunch: incoming ${json['type']} from $key');
        _pendingIncoming[key] = datagram;
      }
    } catch (_) {}
  }

  /// Optional hook for the hole-punch transport: called when a GP01
  /// frame arrives from a peer we haven't yet associated with a
  /// DirectConnection (e.g. they punched first after exchanging
  /// endpoints over the WebTorrent signaling channel).
  void Function(Datagram datagram)? onUnsolicitedFrame;

  /// Pending incoming packets from unknown peers (they initiated punch).
  final Map<String, Datagram> _pendingIncoming = {};

  /// Check if we have a pending incoming punch from a peer.
  bool hasPendingFrom(String ip, int port) =>
      _pendingIncoming.containsKey('$ip:$port');

  /// Attempt to establish a direct connection to a peer.
  ///
  /// [sharedSocket] — the DHT node's UDP socket (shared, not owned by us).
  /// [ourCandidate] — our public address (from BEP 42).
  /// [theirCandidate] — peer's public address (from DHT discovery).
  /// [capability] — our node capability info.
  /// [predictedPorts] — extra ports near theirCandidate.port to also fire
  /// punch packets at, to defeat one-side cellular symmetric NAT (where
  /// the NAT picks consecutive external ports per outbound destination).
  Future<DirectConnection?> punch({
    required RawDatagramSocket sharedSocket,
    required IceCandidate ourCandidate,
    required IceCandidate theirCandidate,
    NodeCapability? capability,
    List<int> predictedPorts = const <int>[],
  }) async {
    final key = '${theirCandidate.ip}:${theirCandidate.port}';

    // Already connected?
    if (_connections.containsKey(key) && _connections[key]!.isAlive) {
      LogService().log('IcePunch: already connected to $key');
      return _connections[key];
    }

    LogService().log('IcePunch: punching to $key '
        '(our public: ${ourCandidate.ip}:${ourCandidate.port}'
        '${predictedPorts.isNotEmpty ? ", predicted=$predictedPorts" : ""})');

    // Use the shared DHT socket — incoming responses are routed via
    // handleIncomingPacket() from DhtNode.onNonDhtPacket callback.
    final connection = DirectConnection(
      remoteIp: theirCandidate.ip,
      remotePort: theirCandidate.port,
      socket: sharedSocket,
    );
    connection._state = DirectConnectionState.punching;
    _connections[key] = connection;

    // Check if peer already punched us (they may have discovered us first).
    // Also check predicted ports in case the cellular NAT remapped.
    Datagram? pending = _pendingIncoming.remove(key);
    if (pending == null) {
      for (final p in predictedPorts) {
        final pk = '${theirCandidate.ip}:$p';
        pending = _pendingIncoming.remove(pk);
        if (pending != null) {
          // Switch the connection to the actual port we received from.
          connection._actualRemotePort = p;
          break;
        }
      }
    }
    if (pending != null) {
      connection._state = DirectConnectionState.connected;
      connection._handleIncoming(pending.data);
      connection.startKeepalive();
      LogService().log('IcePunch: connected to ${connection.remoteIp}:'
          '${connection.effectivePort} (peer punched first)');
      return connection;
    }

    // Send punch packets (simultaneous open) on the primary port and
    // any predicted ports, in parallel.
    final remoteAddr = InternetAddress(theirCandidate.ip);
    final punchPayload = Uint8List.fromList(utf8.encode(
        '{"type":"punch","ts":${DateTime.now().millisecondsSinceEpoch}}'));
    final allPorts = <int>[theirCandidate.port, ...predictedPorts];

    for (var i = 0; i < 5; i++) {
      for (final p in allPorts) {
        try {
          sharedSocket.send(punchPayload, remoteAddr, p);
        } catch (e) {
          LogService().log('IcePunch: send error to $remoteAddr:$p: $e');
        }
      }
      await Future.delayed(const Duration(milliseconds: 200));
    }

    // Wait for response (up to 5 seconds).
    for (var i = 0; i < 25; i++) {
      if (connection._state == DirectConnectionState.connected) break;
      // Did one of our predicted ports land?
      for (final p in predictedPorts) {
        final pk = '${theirCandidate.ip}:$p';
        final dg = _pendingIncoming.remove(pk);
        if (dg != null) {
          connection._actualRemotePort = p;
          connection._state = DirectConnectionState.connected;
          connection._handleIncoming(dg.data);
          break;
        }
      }
      await Future.delayed(const Duration(milliseconds: 200));
    }

    if (connection._state == DirectConnectionState.connected) {
      connection.startKeepalive();
      LogService().log('IcePunch: connected to ${connection.remoteIp}:'
          '${connection.effectivePort}');
      return connection;
    } else {
      _connections.remove(key);
      connection._state = DirectConnectionState.disconnected;
      LogService().log('IcePunch: FAILED to connect to $key (no response after 5s)');
      return null;
    }
  }

  /// Send identity handshake after connection is established.
  ///
  /// Exchanges deviceId, deviceName, callsign, npub with the peer.
  Future<void> sendHandshake(
    DirectConnection connection, {
    required String deviceId,
    required String deviceName,
    required String callsign,
    required String npub,
  }) async {
    connection.sendJson({
      'type': 'hello',
      'device_id': deviceId,
      'device_name': deviceName,
      'callsign': callsign,
      'npub': npub,
    });
  }

  /// Process a received handshake message.
  void handleHandshake(
      DirectConnection connection, Map<String, dynamic> data) {
    connection.deviceId = data['device_id'] as String?;
    connection.deviceName = data['device_name'] as String?;
    connection.callsign = data['callsign'] as String?;
    connection.npub = data['npub'] as String?;
  }

  /// Close a specific connection.
  void closeConnection(String key) {
    _connections[key]?.close();
    _connections.remove(key);
  }

  /// Close all connections.
  void closeAll() {
    for (final conn in _connections.values) {
      conn.close();
    }
    _connections.clear();
  }

  /// Get connection by callsign.
  DirectConnection? getConnectionByCallsign(String callsign) {
    final upper = callsign.toUpperCase();
    for (final conn in _connections.values) {
      if (conn.callsign?.toUpperCase() == upper && conn.isAlive) {
        return conn;
      }
    }
    return null;
  }

  /// Get status for API/UI.
  Map<String, dynamic> getStatus() {
    final active = activeConnections;
    return {
      'connections': active.length,
      'peers': active
          .map((c) => {
                'ip': c.remoteIp,
                'port': c.remotePort,
                'device_id': c.deviceId,
                'device_name': c.deviceName,
                'callsign': c.callsign,
                'state': c.state.name,
                'alive': c.isAlive,
              })
          .toList(),
    };
  }
}
