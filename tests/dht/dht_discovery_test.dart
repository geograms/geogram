/// Standalone P2P connection test — two nodes discover each other via DHT,
/// exchange identity via custom geogram messages, and establish connectivity.
///
/// Run with: dart run tests/dht/dht_discovery_test.dart
///
/// No Flutter dependency. Uses the geogram P2P libraries directly.
/// Tests the full flow that would happen in the real app.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../lib/p2p/dht_node.dart';
import '../../lib/p2p/k_bucket.dart';

int _passed = 0;
int _failed = 0;

void _check(String name, bool condition) {
  if (condition) {
    _passed++;
    print('  ✓ $name');
  } else {
    _failed++;
    print('  ✗ FAIL: $name');
  }
}

void main() async {
  final testHash = sha1Hash('geogram-test-${DateTime.now().millisecondsSinceEpoch}');
  print('=== P2P Connection Test ===');
  print('Test topic: ${_hex(testHash).substring(0, 16)}...');
  print('Memory before: ${_memoryMB()} MB');
  print('');

  // ─── Phase 1: Create two nodes ─────────────────────────────────
  print('--- Phase 1: Create nodes ---');
  final nodeA = DhtNode();
  final nodeB = DhtNode();

  await nodeA.start();
  await nodeB.start();
  print('Node A: port ${nodeA.localPort}, id ${_hex(nodeA.nodeId).substring(0, 8)}');
  print('Node B: port ${nodeB.localPort}, id ${_hex(nodeB.nodeId).substring(0, 8)}');
  _check('Node A started', nodeA.isRunning);
  _check('Node B started', nodeB.isRunning);
  _check('Different ports', nodeA.localPort != nodeB.localPort);
  print('');

  // ─── Phase 2: Bootstrap both ───────────────────────────────────
  print('--- Phase 2: Bootstrap ---');
  final bsStart = DateTime.now();

  await nodeA.bootstrap();
  print('Node A: ${nodeA.routingTableSize} nodes (${_elapsed(bsStart)}ms)');

  await nodeB.bootstrap();
  print('Node B: ${nodeB.routingTableSize} nodes (${_elapsed(bsStart)}ms)');

  _check('Node A has routing table', nodeA.routingTableSize > 0);
  _check('Node B has routing table', nodeB.routingTableSize > 0);
  print('Memory after bootstrap: ${_memoryMB()} MB');
  print('');

  // ─── Phase 3: Set geogram identity ─────────────────────────────
  print('--- Phase 3: Set geogram identity ---');
  nodeA.geogramCallsign = 'X1TEST';
  nodeA.geogramNpub = 'npub1aaa';
  nodeA.geogramDeviceId = 'device-a-uuid';
  nodeA.geogramPlatform = 'linux';
  nodeA.geogramHttpPort = 3456;

  nodeB.geogramCallsign = 'X2TEST';
  nodeB.geogramNpub = 'npub1bbb';
  nodeB.geogramDeviceId = 'device-b-uuid';
  nodeB.geogramPlatform = 'android';
  nodeB.geogramHttpPort = 3456;

  _check('Node A callsign set', nodeA.geogramCallsign == 'X1TEST');
  _check('Node B callsign set', nodeB.geogramCallsign == 'X2TEST');
  print('');

  // ─── Phase 4: Direct geogram query (localhost) ─────────────────
  print('--- Phase 4: Direct geogram query (localhost) ---');

  // Set up callbacks to capture peer discoveries
  String? aReceivedCallsign;
  String? bReceivedCallsign;
  int? aReceivedHttpPort;
  int? bReceivedHttpPort;

  nodeA.onGeogramPeer = (callsign, npub, deviceId, platform, httpPort, ip, udpPort) {
    print('  Node A received peer: $callsign (npub: $npub, platform: $platform, http: $httpPort)');
    aReceivedCallsign = callsign;
    aReceivedHttpPort = httpPort;
  };

  nodeB.onGeogramPeer = (callsign, npub, deviceId, platform, httpPort, ip, udpPort) {
    print('  Node B received peer: $callsign (npub: $npub, platform: $platform, http: $httpPort)');
    bReceivedCallsign = callsign;
    bReceivedHttpPort = httpPort;
  };

  // Node A sends geogram query to Node B (direct localhost)
  print('  Sending: A → B (127.0.0.1:${nodeB.localPort})');
  final responseAB = await nodeA.sendGeogramQuery('127.0.0.1', nodeB.localPort);

  _check('Node A got response from B', responseAB != null);
  if (responseAB != null) {
    _check('Response has B callsign', responseAB.containsKey('callsign'));
  }
  _check('Node B callback fired (received A)', bReceivedCallsign == 'X1TEST');
  _check('Node A got B identity from response', aReceivedCallsign == 'X2TEST');

  // Node B sends geogram query to Node A
  print('  Sending: B → A (127.0.0.1:${nodeA.localPort})');
  aReceivedCallsign = null;
  bReceivedCallsign = null;
  final responseBA = await nodeB.sendGeogramQuery('127.0.0.1', nodeA.localPort);

  _check('Node B got response from A', responseBA != null);
  _check('Node A callback fired (received B)', aReceivedCallsign == 'X2TEST');
  _check('Node B got A identity from response', bReceivedCallsign == 'X1TEST');
  print('');

  // ─── Phase 5: Announce on geogram topic ─────────────────────────
  print('--- Phase 5: Announce on geogram topic ---');
  final annStart = DateTime.now();

  await nodeA.announce(testHash, nodeA.localPort);
  print('  Node A announced on test topic (${_elapsed(annStart)}ms)');

  await nodeB.announce(testHash, nodeB.localPort);
  print('  Node B announced on test topic (${_elapsed(annStart)}ms)');

  print('Memory after announce: ${_memoryMB()} MB');
  print('');

  // ─── Phase 6: Announce DHT port on geogram-udp topic ────────────
  print('--- Phase 6: Announce DHT UDP port ---');
  final udpHash = sha1Hash('geogram-udp');

  await nodeA.announce(udpHash, nodeA.localPort);
  print('  Node A announced UDP port ${nodeA.localPort}');

  await nodeB.announce(udpHash, nodeB.localPort);
  print('  Node B announced UDP port ${nodeB.localPort}');
  print('');

  // ─── Phase 7: Wait for propagation ──────────────────────────────
  print('--- Phase 7: Wait 5s for DHT propagation ---');
  await Future.delayed(const Duration(seconds: 5));
  print('');

  // ─── Phase 8: Discover peers on geogram topic ───────────────────
  print('--- Phase 8: Discover peers ---');

  final peersA = await nodeA.getPeers(testHash);
  print('  Node A found ${peersA.length} peers on geogram topic');
  for (final p in peersA) {
    print('    ${p.ip}:${p.port}');
  }

  final peersB = await nodeB.getPeers(testHash);
  print('  Node B found ${peersB.length} peers on geogram topic');
  for (final p in peersB) {
    print('    ${p.ip}:${p.port}');
  }

  _check('Node A found peers', peersA.isNotEmpty);
  _check('Node B found peers', peersB.isNotEmpty);
  print('');

  // ─── Phase 9: Discover UDP ports from geogram-udp topic ─────────
  print('--- Phase 9: Discover UDP ports ---');

  final udpPeersA = await nodeA.getPeers(udpHash);
  print('  Node A found ${udpPeersA.length} UDP peers');
  for (final p in udpPeersA) {
    print('    ${p.ip}:${p.port}');
  }

  final udpPeersB = await nodeB.getPeers(udpHash);
  print('  Node B found ${udpPeersB.length} UDP peers');
  for (final p in udpPeersB) {
    print('    ${p.ip}:${p.port}');
  }

  _check('Node A found UDP peers', udpPeersA.isNotEmpty);
  _check('Node B found UDP peers', udpPeersB.isNotEmpty);
  print('');

  // ─── Phase 10: Full flow — discover peer, get UDP port, send geogram query
  print('--- Phase 10: Full connection flow ---');
  aReceivedCallsign = null;
  bReceivedCallsign = null;

  // Simulate what P2PService does:
  // 1. Find peer on geogram topic → get their public IP
  // 2. HTTP probe would fail (NAT) — skip in test
  // 3. Look up their UDP port from geogram-udp topic
  // 4. Send geogram query to their UDP port

  if (peersA.isNotEmpty) {
    final peerIp = peersA.first.ip;
    print('  Node A discovered peer at $peerIp');

    // Find their UDP port
    final matchingUdp = udpPeersA.where((p) => p.ip == peerIp).toList();
    if (matchingUdp.isNotEmpty) {
      final udpPort = matchingUdp.first.port;
      print('  Found UDP port $udpPort for $peerIp');
      print('  Sending geogram query to $peerIp:$udpPort');

      final response = await nodeA.sendGeogramQuery(peerIp, udpPort);
      _check('Full flow: got geogram response', response != null);
      if (response != null) {
        _check('Full flow: response has callsign',
            response.containsKey('callsign'));
      }
      // Allow time for callback
      await Future.delayed(const Duration(milliseconds: 500));
      _check('Full flow: identified peer', aReceivedCallsign != null);
      if (aReceivedCallsign != null) {
        print('  Identified peer: $aReceivedCallsign');
      }
    } else {
      print('  No UDP port found for $peerIp (same-machine: ports differ)');
      // On same machine, the peer's public IP matches ours.
      // Try the discovered port directly.
      final discoveredPort = peersA.first.port;
      print('  Trying discovered port $discoveredPort directly');
      final response = await nodeA.sendGeogramQuery('127.0.0.1', discoveredPort);
      _check('Full flow (localhost): got geogram response', response != null);
      await Future.delayed(const Duration(milliseconds: 500));
      _check('Full flow (localhost): identified peer', aReceivedCallsign != null);
      if (aReceivedCallsign != null) {
        print('  Identified peer: $aReceivedCallsign');
      }
    }
  } else {
    print('  No peers found — cannot test full flow');
    _check('Full flow: peers available', false);
  }
  print('');

  // ─── Phase 11: Bidirectional communication ──────────────────────
  print('--- Phase 11: Bidirectional communication ---');
  aReceivedCallsign = null;
  bReceivedCallsign = null;

  // Both nodes send geogram queries to each other simultaneously
  final futureAB2 = nodeA.sendGeogramQuery('127.0.0.1', nodeB.localPort);
  final futureBA2 = nodeB.sendGeogramQuery('127.0.0.1', nodeA.localPort);

  final results = await Future.wait([futureAB2, futureBA2]);
  await Future.delayed(const Duration(milliseconds: 500));

  _check('Bidirectional: A→B response', results[0] != null);
  _check('Bidirectional: B→A response', results[1] != null);
  _check('Bidirectional: A knows B', aReceivedCallsign == 'X2TEST');
  _check('Bidirectional: B knows A', bReceivedCallsign == 'X1TEST');
  print('');

  // ─── Phase 12: Memory check ────────────────────────────────────
  print('--- Phase 12: Memory ---');
  final memMB = double.parse(_memoryMB());
  print('  Final memory: $memMB MB');
  _check('Memory under 200MB', memMB < 200);
  print('');

  // ─── Cleanup ──────────────────────────────────────────────────
  print('--- Cleanup ---');
  await nodeA.stop();
  await nodeB.stop();
  nodeA.dispose();
  nodeB.dispose();
  print('Memory after cleanup: ${_memoryMB()} MB');
  print('');

  // ─── Summary ──────────────────────────────────────────────────
  print('══════════════════════════════════════');
  print('  PASSED: $_passed');
  print('  FAILED: $_failed');
  if (_failed == 0) {
    print('  *** ALL TESTS PASSED ***');
  } else {
    print('  *** $_failed TEST(S) FAILED ***');
  }
  print('══════════════════════════════════════');

  exit(_failed > 0 ? 1 : 0);
}

String _hex(Uint8List bytes) {
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

int _elapsed(DateTime start) {
  return DateTime.now().difference(start).inMilliseconds;
}

String _memoryMB() {
  final info = ProcessInfo.currentRss;
  return (info / 1024 / 1024).toStringAsFixed(1);
}
