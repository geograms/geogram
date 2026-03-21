/// DHT Transport — Direct P2P communication via Mainline DHT discovery.
///
/// Priority 25: between WebRTC (15) and Station (30).
/// Uses UDP hole punching for direct connections discovered via BEP 5 DHT.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import '../../services/log_service.dart';
import '../../services/app_args.dart';
import '../../services/security_service.dart';
import '../../p2p/p2p_service.dart';
import '../../p2p/ice_punch.dart';
import '../../p2p/dht_node.dart';
import '../transport.dart';
import '../transport_message.dart';

/// DHT Transport for direct P2P communication discovered via Mainline DHT.
///
/// Discovers peers via BitTorrent DHT and establishes direct UDP connections
/// using hole punching. Falls back to relay via Type A nodes when needed.
class DhtTransport extends Transport with TransportMixin {
  @override
  String get id => 'dht';

  @override
  String get name => 'P2P Direct';

  @override
  int get priority => 25; // Between WebRTC (15) and Station (30)

  @override
  bool get isAvailable {
    if (kIsWeb) return false; // No raw UDP sockets on web
    if (AppArgs().internetOnly) return false;
    if (SecurityService().bleOnlyMode) return false;
    return true;
  }

  final P2PService _p2p = P2PService();

  /// Pending connection attempts to avoid duplicates.
  final Set<String> _connectingTo = {};

  @override
  Future<void> initialize() async {
    LogService().log('DhtTransport: Initializing...');

    // Subscribe to P2P peer discovery events (when running)
    if (_p2p.isRunning) {
      _p2p.onPeerFound.listen(_onPeerDiscovered);
    }

    markInitialized();
    LogService().log('DhtTransport: Initialized');
  }

  @override
  Future<void> dispose() async {
    LogService().log('DhtTransport: Disposing...');
    await disposeMixin();
    LogService().log('DhtTransport: Disposed');
  }

  @override
  Future<bool> canReach(String callsign) async {
    // Check if we have an active direct connection to this callsign
    final conn = _p2p.getConnectionByCallsign(callsign);
    return conn != null && conn.isAlive;
  }

  @override
  Future<int> getQuality(String callsign) async {
    final conn = _p2p.getConnectionByCallsign(callsign);
    if (conn == null || !conn.isAlive) return 0;

    // Score based on connection age (fresher = better) and activity
    final age = DateTime.now().difference(conn.lastActivity);
    if (age.inSeconds < 10) return 90;
    if (age.inSeconds < 30) return 70;
    if (age.inSeconds < 60) return 50;
    return 30;
  }

  @override
  Future<TransportResult> send(
    TransportMessage message, {
    Duration? timeout,
  }) async {
    final stopwatch = Stopwatch()..start();

    try {
      final conn = _p2p.getConnectionByCallsign(message.targetCallsign);
      if (conn == null || !conn.isAlive) {
        return TransportResult.failure(
          error: 'No direct connection to ${message.targetCallsign}',
          transportUsed: id,
        );
      }

      switch (message.type) {
        case TransportMessageType.apiRequest:
          return await _handleApiRequest(message, conn, stopwatch);

        case TransportMessageType.directMessage:
        case TransportMessageType.chatMessage:
          return await _handleMessageSend(message, conn, stopwatch);

        case TransportMessageType.ping:
          conn.sendJson({'type': 'ping'});
          stopwatch.stop();
          final result = TransportResult.success(
            statusCode: 200,
            transportUsed: id,
            latency: stopwatch.elapsed,
          );
          recordMetrics(result);
          return result;

        default:
          return TransportResult.failure(
            error: 'Unsupported message type for DHT: ${message.type}',
            transportUsed: id,
          );
      }
    } catch (e) {
      stopwatch.stop();
      final result = TransportResult.failure(
        error: e.toString(),
        transportUsed: id,
      );
      recordMetrics(result);
      return result;
    }
  }

  @override
  Future<void> sendAsync(TransportMessage message) async {
    send(message);
  }

  /// Handle API request by wrapping in JSON and sending over UDP.
  Future<TransportResult> _handleApiRequest(
    TransportMessage message,
    DirectConnection conn,
    Stopwatch stopwatch,
  ) async {
    // Wrap HTTP request as JSON message over UDP
    final requestId = message.id;
    final request = {
      'type': 'http_request',
      'id': requestId,
      'method': message.method ?? 'GET',
      'path': message.path,
      'headers': message.headers,
      'body': message.payload,
    };

    // Send request
    conn.sendJson(request);

    // Wait for response
    final completer = Completer<Map<String, dynamic>?>();
    late StreamSubscription sub;
    sub = conn.onData.listen((data) {
      try {
        final json = jsonDecode(utf8.decode(data));
        if (json is Map<String, dynamic> &&
            json['type'] == 'http_response' &&
            json['id'] == requestId) {
          if (!completer.isCompleted) {
            completer.complete(json);
          }
        }
      } catch (_) {}
    });

    final effectiveTimeout = const Duration(seconds: 15);
    final response = await completer.future
        .timeout(effectiveTimeout, onTimeout: () => null);

    sub.cancel();
    stopwatch.stop();

    if (response == null) {
      final result = TransportResult.failure(
        error: 'Timeout waiting for response from ${message.targetCallsign}',
        transportUsed: id,
      );
      recordMetrics(result);
      return result;
    }

    final result = TransportResult.success(
      statusCode: response['status'] as int? ?? 200,
      responseData: response['body'],
      transportUsed: id,
      latency: stopwatch.elapsed,
    );
    recordMetrics(result);
    return result;
  }

  /// Handle DM/chat message send.
  Future<TransportResult> _handleMessageSend(
    TransportMessage message,
    DirectConnection conn,
    Stopwatch stopwatch,
  ) async {
    final msg = {
      'type': message.type == TransportMessageType.directMessage
          ? 'dm'
          : 'chat',
      'id': message.id,
      'event': message.signedEvent,
      'path': message.path,
    };

    conn.sendJson(msg);
    stopwatch.stop();

    final result = TransportResult.success(
      statusCode: 200,
      transportUsed: id,
      latency: stopwatch.elapsed,
    );
    recordMetrics(result);
    return result;
  }

  /// Handle a newly discovered peer from DHT.
  void _onPeerDiscovered((Uint8List, PeerInfo) event) {
    // Peer discovery is logged by P2PService.
    // Auto-connection is handled when the transport layer needs to reach
    // a specific callsign — not on every discovery event.
  }

  /// Attempt to establish a direct connection to a peer discovered via DHT.
  ///
  /// Called by ConnectionManager when this transport is selected for a callsign.
  Future<bool> connectToPeer(PeerInfo peer) async {
    final key = '${peer.ip}:${peer.port}';
    if (_connectingTo.contains(key)) return false;

    _connectingTo.add(key);
    try {
      final conn = await _p2p.connectTo(peer);
      if (conn != null) {
        // Register the device once we know its callsign
        if (conn.callsign != null) {
          registerDevice(conn.callsign!, metadata: {
            'source': 'dht_direct',
            'ip': conn.remoteIp,
            'port': conn.remotePort,
            'device_id': conn.deviceId,
            'device_name': conn.deviceName,
          });
        }
        return true;
      }
      return false;
    } finally {
      _connectingTo.remove(key);
    }
  }

  /// Register a DHT-discovered device.
  void registerDhtDevice(String callsign, {
    String? ip,
    int? port,
    String? deviceId,
    String? deviceName,
  }) {
    registerDevice(callsign, metadata: {
      'source': 'dht',
      'ip': ip,
      'port': port,
      'device_id': deviceId,
      'device_name': deviceName,
      'registered_at': DateTime.now().toIso8601String(),
    });
    LogService().log('DhtTransport: Registered $callsign via DHT');
  }
}
