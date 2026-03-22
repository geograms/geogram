/// Standalone DHT discovery test — two nodes find each other via BT mainline DHT.
///
/// Run with: dart run tests/dht/dht_discovery_test.dart
///
/// No Flutter dependency. Uses the geogram DHT library directly.
import 'dart:io';
import 'dart:typed_data';

import '../../lib/p2p/dht_node.dart';
import '../../lib/p2p/k_bucket.dart';

void main() async {
  final testHash = sha1Hash('geogram-test-${DateTime.now().millisecondsSinceEpoch}');
  print('=== DHT Discovery Test ===');
  print('Test hash: ${_hex(testHash).substring(0, 16)}...');
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
  print('Memory after create: ${_memoryMB()} MB');
  print('');

  // ─── Phase 2: Bootstrap both ───────────────────────────────────
  print('--- Phase 2: Bootstrap ---');
  final bsStart = DateTime.now();

  await nodeA.bootstrap();
  final aNodes = nodeA.routingTableSize;
  print('Node A: ${aNodes} nodes (${_elapsed(bsStart)}ms)');

  await nodeB.bootstrap();
  final bNodes = nodeB.routingTableSize;
  print('Node B: ${bNodes} nodes (${_elapsed(bsStart)}ms)');
  print('Memory after bootstrap: ${_memoryMB()} MB');
  print('');

  // ─── Phase 3: Announce ─────────────────────────────────────────
  print('--- Phase 3: Announce ---');
  final annStart = DateTime.now();

  await nodeA.announce(testHash, nodeA.localPort);
  print('Node A announced (${_elapsed(annStart)}ms)');

  await nodeB.announce(testHash, nodeB.localPort);
  print('Node B announced (${_elapsed(annStart)}ms)');
  print('Memory after announce: ${_memoryMB()} MB');
  print('');

  // ─── Phase 4: Wait for propagation ─────────────────────────────
  print('--- Phase 4: Wait 5s for propagation ---');
  await Future.delayed(const Duration(seconds: 5));
  print('');

  // ─── Phase 5: Get peers ────────────────────────────────────────
  print('--- Phase 5: Get peers ---');

  final gpStartA = DateTime.now();
  final peersA = await nodeA.getPeers(testHash);
  final gpTimeA = _elapsed(gpStartA);
  print('Node A found ${peersA.length} peers (${gpTimeA}ms):');
  for (final p in peersA) {
    print('  ${p.ip}:${p.port}');
  }

  final gpStartB = DateTime.now();
  final peersB = await nodeB.getPeers(testHash);
  final gpTimeB = _elapsed(gpStartB);
  print('Node B found ${peersB.length} peers (${gpTimeB}ms):');
  for (final p in peersB) {
    print('  ${p.ip}:${p.port}');
  }

  print('');
  print('Memory after getPeers: ${_memoryMB()} MB');
  print('Node A routing table: ${nodeA.routingTableSize} nodes');
  print('Node B routing table: ${nodeB.routingTableSize} nodes');
  print('');

  // ─── Phase 6: Verify ──────────────────────────────────────────
  print('--- Phase 6: Verify ---');
  final aFoundB = peersA.any((p) => p.port == nodeB.localPort);
  final bFoundA = peersB.any((p) => p.port == nodeA.localPort);

  // Also check if they found each other via public IP
  final aFoundAny = peersA.isNotEmpty;
  final bFoundAny = peersB.isNotEmpty;

  print('Node A found Node B by port: $aFoundB');
  print('Node B found Node A by port: $bFoundA');
  print('Node A found any peers: $aFoundAny');
  print('Node B found any peers: $bFoundAny');
  print('');

  if (aFoundB && bFoundA) {
    print('*** PASS: Both nodes found each other ***');
  } else if (aFoundAny || bFoundAny) {
    print('*** PARTIAL: Found peers but not each other by port ***');
    print('   (Expected on same-IP: both announce same public IP,');
    print('    differs by port. Announces go to same K-closest nodes.)');
  } else {
    print('*** FAIL: No peers found ***');
  }

  // ─── Cleanup ──────────────────────────────────────────────────
  print('');
  print('--- Cleanup ---');
  await nodeA.stop();
  await nodeB.stop();
  nodeA.dispose();
  nodeB.dispose();
  print('Memory final: ${_memoryMB()} MB');
  print('=== Done ===');

  exit(0);
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
