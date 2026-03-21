/// Simplified ICE-style UDP hole punching for P2P connections.
///
/// No WebRTC overhead — raw UDP with NIP-44 encrypted signaling.
///
/// Flow:
/// 1. Both peers learn own public IP:port from STUN
/// 2. Exchange candidates via NIP-44 encrypted message through a Type A relay
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

  /// Remote peer's port.
  final int remotePort;

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
      socket.send(data, InternetAddress(remoteIp), remotePort);
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
            remotePort,
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

  /// Attempt to establish a direct connection to a peer.
  ///
  /// [localSocket] — our UDP socket (from DhtNode).
  /// [ourCandidate] — our public address (from STUN).
  /// [theirCandidate] — peer's public address (received via signaling).
  /// [capability] — our node capability info.
  Future<DirectConnection?> punch({
    required RawDatagramSocket localSocket,
    required IceCandidate ourCandidate,
    required IceCandidate theirCandidate,
    required NodeCapability capability,
  }) async {
    final key = '${theirCandidate.ip}:${theirCandidate.port}';

    // Already connected?
    if (_connections.containsKey(key) && _connections[key]!.isAlive) {
      return _connections[key];
    }

    LogService().log('IcePunch: punching to $key');

    // Create a dedicated socket for this connection
    RawDatagramSocket punchSocket;
    try {
      punchSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    } catch (e) {
      LogService().log('IcePunch: failed to bind socket: $e');
      return null;
    }

    final connection = DirectConnection(
      remoteIp: theirCandidate.ip,
      remotePort: theirCandidate.port,
      socket: punchSocket,
    );
    connection._state = DirectConnectionState.punching;

    // Listen for incoming data on the punch socket
    final completer = Completer<bool>();
    late StreamSubscription sub;
    sub = punchSocket.listen((event) {
      if (event == RawSocketEvent.read) {
        final dg = punchSocket.receive();
        if (dg != null) {
          if (connection._state == DirectConnectionState.punching) {
            // Hole punch succeeded!
            connection._state = DirectConnectionState.connected;
            if (!completer.isCompleted) completer.complete(true);
          }
          connection._handleIncoming(dg.data);
        }
      }
    });

    // Send punch packets (simultaneous open)
    // Send several packets quickly to increase chances
    final remoteAddr = InternetAddress(theirCandidate.ip);
    final punchPayload = Uint8List.fromList(
        utf8.encode('{"type":"punch","ts":${DateTime.now().millisecondsSinceEpoch}}'));

    for (var i = 0; i < 5; i++) {
      try {
        punchSocket.send(punchPayload, remoteAddr, theirCandidate.port);
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 200));
    }

    // Wait for response (up to 5 seconds)
    final success = await completer.future
        .timeout(const Duration(seconds: 5), onTimeout: () => false);

    if (success) {
      connection.startKeepalive();
      _connections[key] = connection;
      LogService().log('IcePunch: connected to $key');
      return connection;
    } else {
      sub.cancel();
      punchSocket.close();
      connection._state = DirectConnectionState.disconnected;
      LogService().log('IcePunch: failed to connect to $key');
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
