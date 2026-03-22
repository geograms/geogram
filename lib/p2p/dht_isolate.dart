/// DHT Isolate — runs all DHT work in a background isolate.
///
/// The main isolate communicates via SendPort/ReceivePort:
/// - Main → DHT: commands (start, stop, announce, getPeers, addNode)
/// - DHT → Main: events (started, peers_found, status, ip_detected)
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'dht_node.dart';
import 'k_bucket.dart';
import 'node_capability.dart';

/// Parameters passed to the DHT isolate on spawn.
class DhtIsolateParams {
  final SendPort sendPort;
  final int announcePort;
  final String npub;
  final Uint8List? persistedNodeId;
  final List<Map<String, dynamic>>? cachedNodes;
  final List<Map<String, dynamic>>? cachedPeers;

  DhtIsolateParams({
    required this.sendPort,
    required this.announcePort,
    required this.npub,
    this.persistedNodeId,
    this.cachedNodes,
    this.cachedPeers,
  });
}

/// Entry point for the DHT isolate.
///
/// Runs the full DHT lifecycle: bootstrap, announce, detect, scan.
/// Sends events back to main isolate via SendPort.
void dhtIsolateEntry(DhtIsolateParams params) async {
  final sendPort = params.sendPort;
  final dht = DhtNode();
  final capability = NodeCapability();

  // Compute info hashes
  final geogramHash = sha1Hash('geogram');
  final npubHash = sha1Hash(params.npub);

  try {
    // Start DHT node
    await dht.start(persistedNodeId: params.persistedNodeId);
    sendPort.send(jsonEncode({
      'type': 'log',
      'message': 'DHT isolate: socket open on port ${dht.localPort}',
    }));
    sendPort.send(jsonEncode({
      'type': 'node_id',
      'id': _toHex(dht.nodeId),
    }));

    // Load cached nodes
    if (params.cachedNodes != null) {
      final nodes = <DhtContact>[];
      for (final entry in params.cachedNodes!) {
        final idHex = entry['id'] as String?;
        final ip = entry['ip'] as String?;
        final port = entry['port'] as int?;
        if (idHex != null && ip != null && port != null) {
          nodes.add(DhtContact(
            nodeId: _fromHex(idHex),
            ip: ip,
            port: port,
          ));
        }
      }
      await dht.bootstrap(cachedNodes: nodes);
    } else {
      await dht.bootstrap();
    }

    sendPort.send(jsonEncode({
      'type': 'log',
      'message': 'DHT isolate: bootstrap complete (${dht.routingTableSize} nodes)',
    }));

    // Announce on both topics
    await dht.announce(geogramHash, params.announcePort);
    await Future.delayed(const Duration(seconds: 1));
    await dht.announce(npubHash, params.announcePort);
    dht.startPeriodicAnnounce();

    sendPort.send(jsonEncode({
      'type': 'log',
      'message': 'DHT isolate: announced on DHT',
    }));

    // Detect public IP
    await capability.detectFromDht(dht);

    sendPort.send(jsonEncode({
      'type': 'started',
      'dht_port': dht.localPort,
      'node_type': capability.type.name,
      'public_ip': capability.publicIp,
      'public_port': capability.publicPort,
      'dht_nodes': dht.routingTableSize,
    }));

    // Listen for discovered peers
    dht.onPeerFound.listen((event) {
      final (infoHash, peer) = event;
      sendPort.send(jsonEncode({
        'type': 'peer_found',
        'info_hash': _toHex(infoHash),
        'ip': peer.ip,
        'port': peer.port,
      }));
    });

    // Initial scan for geogram peers
    final geogramPeers = await dht.getPeers(geogramHash);
    for (final peer in geogramPeers) {
      sendPort.send(jsonEncode({
        'type': 'peer_found',
        'info_hash': _toHex(geogramHash),
        'ip': peer.ip,
        'port': peer.port,
      }));
    }

    // Scan own npub
    final npubPeers = await dht.getPeers(npubHash);
    for (final peer in npubPeers) {
      sendPort.send(jsonEncode({
        'type': 'peer_found',
        'info_hash': _toHex(npubHash),
        'ip': peer.ip,
        'port': peer.port,
      }));
    }

    // Periodic refresh every 5 min
    Timer.periodic(const Duration(minutes: 5), (_) async {
      if (!dht.isRunning) return;

      await capability.detectFromDht(dht);

      // Check for new peers
      final peers = await dht.getPeers(geogramHash);
      for (final peer in peers) {
        sendPort.send(jsonEncode({
          'type': 'peer_found',
          'info_hash': _toHex(geogramHash),
          'ip': peer.ip,
          'port': peer.port,
        }));
      }

      sendPort.send(jsonEncode({
        'type': 'status',
        'dht_nodes': dht.routingTableSize,
        'stored_peers': dht.storedPeerCount,
        'node_type': capability.type.name,
        'public_ip': capability.publicIp,
        'public_port': capability.publicPort,
      }));
    });

    // Set up command receiver from main isolate
    final commandPort = ReceivePort();
    sendPort.send(jsonEncode({
      'type': 'command_port',
      'port_token': commandPort.sendPort.hashCode.toString(),
    }));
    // Send the actual port object (not JSON-serializable)
    sendPort.send(commandPort.sendPort);

    commandPort.listen((message) async {
      if (message is! String) return;
      final cmd = jsonDecode(message) as Map<String, dynamic>;
      final action = cmd['action'] as String?;

      switch (action) {
        case 'stop':
          // Save cache before stopping
          final cacheNodes = dht.getNodesForCache();
          sendPort.send(jsonEncode({
            'type': 'cache',
            'nodes': cacheNodes.map((n) => {
              'id': _toHex(n.nodeId),
              'ip': n.ip,
              'port': n.port,
            }).toList(),
          }));
          await dht.stop();
          dht.dispose();
          sendPort.send(jsonEncode({'type': 'stopped'}));
          Isolate.exit();
          break;

        case 'get_status':
          sendPort.send(jsonEncode({
            'type': 'status',
            'dht_port': dht.localPort,
            'dht_nodes': dht.routingTableSize,
            'stored_peers': dht.storedPeerCount,
            'node_type': capability.type.name,
            'public_ip': capability.publicIp,
            'public_port': capability.publicPort,
          }));
          break;

        case 'find_user':
          final npubQuery = cmd['npub'] as String?;
          if (npubQuery != null) {
            final hash = sha1Hash(npubQuery);
            final peers = await dht.getPeers(hash);
            sendPort.send(jsonEncode({
              'type': 'find_result',
              'npub': npubQuery,
              'devices': peers.map((p) => {'ip': p.ip, 'port': p.port}).toList(),
            }));
          }
          break;

        case 'add_node':
          final ip = cmd['ip'] as String?;
          final port = cmd['port'] as int?;
          if (ip != null && port != null) {
            dht.pingNode(ip, port);
          }
          break;
      }
    });

  } catch (e) {
    sendPort.send(jsonEncode({
      'type': 'error',
      'message': e.toString(),
    }));
  }
}

String _toHex(Uint8List bytes) {
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

Uint8List _fromHex(String hex) {
  final bytes = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return bytes;
}
