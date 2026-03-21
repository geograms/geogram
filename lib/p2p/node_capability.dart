/// Node capability detection for P2P connectivity.
///
/// Determines whether this device is:
/// - Type A: Public IP, port reachable (can be STUN reflector + relay)
/// - Type B: Behind NAT with predictable port mapping (hole punching works)
/// - Type C: Behind CGNAT/symmetric NAT (needs relay via Type A)
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../services/log_service.dart';
import '../services/stun_server_service.dart';
import 'dht_node.dart';

/// Node connectivity type.
enum NodeType {
  /// Public IP, port reachable. Can serve as STUN reflector and signaling relay.
  typeA,

  /// Behind NAT with predictable port mapping. UDP hole punching works.
  typeB,

  /// Behind CGNAT or symmetric NAT. Needs relay via Type A node.
  typeC,

  /// Not yet determined.
  unknown,
}

/// Result of a STUN binding query.
class StunResult {
  final String publicIp;
  final int publicPort;

  const StunResult({required this.publicIp, required this.publicPort});

  @override
  String toString() => 'StunResult($publicIp:$publicPort)';
}

/// Detects this node's NAT type and public address.
class NodeCapability {
  /// Detected node type.
  NodeType _type = NodeType.unknown;
  NodeType get type => _type;

  /// Our public IP as seen by STUN reflectors.
  String? _publicIp;
  String? get publicIp => _publicIp;

  /// Our public port as seen by STUN reflectors.
  int? _publicPort;
  int? get publicPort => _publicPort;

  /// Whether we are Type A.
  bool get isTypeA => _type == NodeType.typeA;

  /// Whether hole punching is expected to work.
  bool get canHolePunch => _type == NodeType.typeA || _type == NodeType.typeB;

  /// Detect NAT type by querying STUN reflectors.
  ///
  /// [dht] — the running DHT node (provides the UDP socket port).
  /// [stunPeers] — Type A Geogram nodes discovered via DHT that run STUN.
  ///   Only uses Geogram nodes as STUN reflectors — no external infrastructure.
  ///   If fewer than 2 peers are available, detection is deferred until more
  ///   Type A nodes are discovered via DHT.
  Future<void> detect(DhtNode dht, List<PeerInfo> stunPeers) async {
    if (stunPeers.length < 2) {
      if (stunPeers.length == 1) {
        // Single reflector — can learn public IP but not NAT type
        final result = await _queryStun(
            stunPeers.first.ip, 3478, dht.localPort);
        if (result != null) {
          _publicIp = result.publicIp;
          _publicPort = result.publicPort;
          if (await _isLocalIp(_publicIp!)) {
            _type = NodeType.typeA;
          } else {
            // Assume B (most common) until we find a second reflector
            _type = NodeType.typeB;
          }
        } else {
          _type = NodeType.unknown;
        }
      } else {
        // No STUN reflectors available yet — defer detection
        _type = NodeType.unknown;
        LogService().log('NodeCapability: no Geogram STUN reflectors found yet, deferring');
      }
    } else {
      // Query two Geogram STUN reflectors
      final results = <StunResult>[];
      for (final peer in stunPeers.take(2)) {
        final result = await _queryStun(peer.ip, 3478, dht.localPort);
        if (result != null) results.add(result);
      }

      if (results.isEmpty) {
        _type = NodeType.unknown;
        return;
      }

      _publicIp = results.first.publicIp;
      _publicPort = results.first.publicPort;

      if (await _isLocalIp(_publicIp!)) {
        _type = NodeType.typeA;
      } else if (results.length >= 2 &&
          results[0].publicPort == results[1].publicPort) {
        _type = NodeType.typeB;
      } else if (results.length >= 2) {
        _type = NodeType.typeC;
      } else {
        // Only one result — assume B (common case)
        _type = NodeType.typeB;
      }
    }

    LogService().log('NodeCapability: detected as ${_type.name} '
        '(public: $_publicIp:$_publicPort)');

    // If Type A, start STUN reflector for other nodes
    if (_type == NodeType.typeA && !StunServerService().isRunning) {
      await StunServerService().start();
      LogService().log('NodeCapability: Started STUN reflector (Type A node)');
    }
  }

  /// Query a STUN server and return our mapped address.
  Future<StunResult?> _queryStun(
      String serverIp, int serverPort, int localPort) async {
    RawDatagramSocket? sock;
    try {
      sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);

      // Build STUN Binding Request
      final request = _buildStunRequest();
      final sent = sock.send(request, InternetAddress(serverIp), serverPort);
      if (sent <= 0) {
        LogService().log('STUN: send returned $sent to $serverIp:$serverPort');
        return null;
      }

      // Wait for response
      final completer = Completer<StunResult?>();
      late StreamSubscription sub;
      sub = sock.listen((event) {
        if (event == RawSocketEvent.read) {
          final dg = sock?.receive();
          if (dg != null) {
            final result = _parseStunResponse(dg.data);
            if (result != null && !completer.isCompleted) {
              completer.complete(result);
            }
          }
        }
      });

      final result = await completer.future
          .timeout(const Duration(seconds: 5), onTimeout: () => null);

      sub.cancel();
      if (result != null) {
        LogService().log('STUN: $serverIp:$serverPort -> ${result.publicIp}:${result.publicPort}');
      }
      return result;
    } catch (e) {
      LogService().log('STUN query to $serverIp:$serverPort failed: $e');
      return null;
    } finally {
      sock?.close();
    }
  }

  /// Check if an IP matches one of our local network interfaces.
  Future<bool> _isLocalIp(String ip) async {
    try {
      final interfaces = await NetworkInterface.list();
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (addr.address == ip) return true;
        }
      }
    } catch (_) {}
    return false;
  }

  /// Build a minimal STUN Binding Request (RFC 5389).
  Uint8List _buildStunRequest() {
    final rng = Random.secure();
    final request = Uint8List(20);
    final view = ByteData.view(request.buffer);

    // Message Type: Binding Request (0x0001)
    view.setUint16(0, 0x0001, Endian.big);
    // Message Length: 0 (no attributes)
    view.setUint16(2, 0, Endian.big);
    // Magic Cookie
    view.setUint32(4, 0x2112A442, Endian.big);
    // Transaction ID: 12 random bytes
    for (var i = 8; i < 20; i++) {
      request[i] = rng.nextInt(256);
    }

    return request;
  }

  /// Parse a STUN Binding Response to extract XOR-MAPPED-ADDRESS.
  StunResult? _parseStunResponse(Uint8List data) {
    if (data.length < 20) return null;

    final view = ByteData.view(data.buffer, data.offsetInBytes, data.length);
    final msgType = view.getUint16(0, Endian.big);
    if (msgType != 0x0101) return null; // Not a Binding Response

    final msgLen = view.getUint16(2, Endian.big);
    final magicCookie = view.getUint32(4, Endian.big);
    if (magicCookie != 0x2112A442) return null;

    // Parse attributes
    var offset = 20;
    while (offset + 4 <= data.length && offset < 20 + msgLen) {
      final attrType = view.getUint16(offset, Endian.big);
      final attrLen = view.getUint16(offset + 2, Endian.big);
      final attrStart = offset + 4;

      if (attrType == 0x0020 && attrLen >= 8) {
        // XOR-MAPPED-ADDRESS
        final family = data[attrStart + 1];
        if (family == 0x01) {
          // IPv4
          final xPort =
              view.getUint16(attrStart + 2, Endian.big) ^ (0x2112A442 >> 16);
          final xAddr = view.getUint32(attrStart + 4, Endian.big) ^ 0x2112A442;
          final ip =
              '${(xAddr >> 24) & 0xFF}.${(xAddr >> 16) & 0xFF}.${(xAddr >> 8) & 0xFF}.${xAddr & 0xFF}';
          return StunResult(publicIp: ip, publicPort: xPort);
        }
      }

      // Advance to next attribute (padded to 4 bytes)
      offset = attrStart + ((attrLen + 3) & ~3);
    }

    return null;
  }

  /// Get human-readable status.
  Map<String, dynamic> getStatus() {
    return {
      'node_type': _type.name,
      'public_ip': _publicIp,
      'public_port': _publicPort,
      'can_hole_punch': canHolePunch,
      'is_stun_reflector': isTypeA && StunServerService().isRunning,
    };
  }
}
