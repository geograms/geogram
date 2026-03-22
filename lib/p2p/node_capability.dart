/// Node capability detection for P2P connectivity.
///
/// Learns public IP from BEP 42 `ip` field in DHT responses.
/// No separate STUN infrastructure needed — DHT peers report our IP.
library;

import 'dart:io';

import '../services/log_service.dart';
import 'dht_node.dart';

/// Node connectivity type.
enum NodeType {
  typeA,
  typeB,
  typeC,
  unknown,
}

/// Detects this node's NAT type and public address.
class NodeCapability {
  NodeType _type = NodeType.unknown;
  NodeType get type => _type;

  String? _publicIp;
  String? get publicIp => _publicIp;

  int? _publicPort;
  int? get publicPort => _publicPort;

  bool get isTypeA => _type == NodeType.typeA;
  bool get canHolePunch => _type == NodeType.typeA || _type == NodeType.typeB;

  /// Detect NAT type from the DHT node's BEP 42 external IP field.
  ///
  /// After bootstrap, many DHT peers include our external IP:port in their
  /// responses. The DhtNode collects this automatically.
  Future<void> detectFromDht(DhtNode dht) async {
    if (!dht.isRunning) return;

    final ip = dht.externalIp;
    if (ip == null) {
      // BEP 42 not supported by any peer we talked to yet — try pinging more
      final nodes = dht.getExternalNodes(count: 6);
      for (final node in nodes) {
        dht.pingNode(node.ip, node.port);
        await Future.delayed(Duration.zero);
      }
      // Wait for responses
      await Future.delayed(const Duration(seconds: 3));

      if (dht.externalIp == null) {
        _type = NodeType.unknown;
        LogService().log('NodeCapability: no BEP 42 IP from DHT peers');
        return;
      }
    }

    _publicIp = dht.externalIp;
    _publicPort = dht.externalPort;

    if (await _isLocalIp(_publicIp!)) {
      _type = NodeType.typeA;
    } else {
      _type = NodeType.typeB;
    }

    LogService().log('NodeCapability: detected as ${_type.name} '
        '(public: $_publicIp:$_publicPort)');
  }

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

  Map<String, dynamic> getStatus() {
    return {
      'node_type': _type.name,
      'public_ip': _publicIp,
      'public_port': _publicPort,
      'can_hole_punch': canHolePunch,
    };
  }
}
