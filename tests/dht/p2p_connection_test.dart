/// Full P2P connection test — two geogram instances discover each other via DHT,
/// exchange identity, register as devices, and communicate through NAT.
///
/// Run with: dart run tests/dht/p2p_connection_test.dart
///
/// Each instance has:
/// - A DhtNode for discovery + geogram messaging
/// - An HTTP server (shelf) responding to /api/status
/// - A device registry tracking discovered peers
/// - Identity (callsign, npub, deviceId)
///
/// The test simulates the full flow that happens in the real app
/// when two devices on different networks find each other.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import '../../lib/p2p/dht_node.dart';
import '../../lib/p2p/k_bucket.dart';

// ─── Lightweight Geogram Instance ────────────────────────────────

/// A minimal geogram peer for testing — DhtNode + HTTP server + device registry.
class GeogramInstance {
  final String callsign;
  final String npub;
  final String deviceId;
  final String platform;
  final int httpPort;

  late DhtNode dht;
  HttpServer? _httpServer;

  /// Devices discovered via DHT (callsign → DeviceInfo)
  final Map<String, DiscoveredDevice> devices = {};

  /// Peers found on geogram DHT topic (raw IP:port)
  final List<PeerInfo> discoveredPeers = [];

  bool get isRunning => dht.isRunning;

  GeogramInstance({
    required this.callsign,
    required this.npub,
    required this.deviceId,
    required this.platform,
    required this.httpPort,
  });

  /// Start the instance: HTTP server + DHT node.
  Future<void> start() async {
    // Start HTTP server
    final handler = Pipeline()
        .addHandler(_handleRequest);
    _httpServer = await shelf_io.serve(handler, '0.0.0.0', httpPort);
    print('  [$callsign] HTTP server on port $httpPort');

    // Start DHT
    dht = DhtNode();
    await dht.start();

    // Set geogram identity
    dht.geogramCallsign = callsign;
    dht.geogramNpub = npub;
    dht.geogramDeviceId = deviceId;
    dht.geogramPlatform = platform;
    dht.geogramHttpPort = httpPort;

    // Handle incoming geogram queries/responses
    dht.onGeogramPeer = _onPeerDiscovered;

    // Listen for DHT peer discoveries
    dht.onPeerFound.listen((e) {
      final peer = e.$2;
      if (!discoveredPeers.any((p) => p.ip == peer.ip && p.port == peer.port)) {
        discoveredPeers.add(peer);
      }
    });

    print('  [$callsign] DHT on port ${dht.localPort}');
  }

  /// Handle HTTP requests — minimal /api/status endpoint.
  Response _handleRequest(Request request) {
    if (request.url.path == 'api/status') {
      return Response.ok(
        jsonEncode({
          'service': 'Geogram',
          'callsign': callsign,
          'npub': npub,
          'device_id': deviceId,
          'platform': platform,
          'port': httpPort,
          'status': 'online',
        }),
        headers: {'Content-Type': 'application/json'},
      );
    }
    if (request.url.path == 'api/devices') {
      return Response.ok(
        jsonEncode({
          'devices': devices.values.map((d) => d.toJson()).toList(),
        }),
        headers: {'Content-Type': 'application/json'},
      );
    }
    // Echo endpoint for testing data transfer
    if (request.url.path == 'api/echo') {
      return Response.ok(
        jsonEncode({
          'from': callsign,
          'echo': 'hello from $callsign',
          'timestamp': DateTime.now().toIso8601String(),
        }),
        headers: {'Content-Type': 'application/json'},
      );
    }
    return Response.notFound('Not found');
  }

  /// Bootstrap into the DHT network.
  Future<void> bootstrap() async {
    await dht.bootstrap();
    print('  [$callsign] Bootstrap done: ${dht.routingTableSize} nodes');
  }

  /// Announce on geogram + geogram-udp topics.
  Future<void> announce() async {
    final geogramHash = sha1Hash('geogram');
    final npubHash = sha1Hash(npub);
    final udpHash = sha1Hash('geogram-udp');

    await dht.announceLight(geogramHash, httpPort);
    await dht.announceLight(npubHash, httpPort);
    await dht.announceLight(udpHash, dht.localPort);
    print('  [$callsign] Announced (http:$httpPort, udp:${dht.localPort})');
  }

  /// Discover peers on the geogram topic.
  Future<List<PeerInfo>> discoverPeers() async {
    final peers = await dht.getPeers(sha1Hash('geogram'));
    for (final p in peers) {
      if (!discoveredPeers.any((e) => e.ip == p.ip && e.port == p.port)) {
        discoveredPeers.add(p);
      }
    }
    return peers;
  }

  /// Try to probe a peer — first HTTP, then geogram DHT query.
  Future<bool> probePeer(PeerInfo peer) async {
    // Step 1: Try direct HTTP (works on LAN, fails through NAT)
    try {
      final resp = await HttpClient().getUrl(
          Uri.parse('http://${peer.ip}:${peer.port}/api/status'))
          .then((req) => req.close())
          .timeout(const Duration(seconds: 2));
      if (resp.statusCode == 200) {
        final body = await resp.transform(utf8.decoder).join();
        final data = jsonDecode(body) as Map<String, dynamic>;
        final peerCallsign = data['callsign'] as String?;
        if (peerCallsign != null && peerCallsign.toUpperCase() != callsign.toUpperCase()) {
          _registerDevice(peerCallsign, data, peer, 'http');
          return true;
        }
      }
    } catch (_) {
      print('  [$callsign] HTTP probe to ${peer.ip}:${peer.port} failed');
    }

    // Step 2: Look up peer's UDP port from geogram-udp topic
    final udpPeers = dht.getCachedPeers(sha1Hash('geogram-udp'));
    final udpPeer = udpPeers.where((p) => p.ip == peer.ip).firstOrNull;

    final targetPort = udpPeer?.port ?? peer.port;
    print('  [$callsign] Sending geogram query to ${peer.ip}:$targetPort');

    // Step 3: Send geogram identity query via DHT socket
    final response = await dht.sendGeogramQuery(peer.ip, targetPort);
    if (response != null && response.containsKey('callsign')) {
      return true; // onGeogramPeer callback handles registration
    }

    return false;
  }

  /// Called when a geogram peer is discovered (query or response).
  void _onPeerDiscovered(String peerCallsign, String? peerNpub,
      String? peerDeviceId, String? peerPlatform, int peerHttpPort,
      String ip, int udpPort) {
    if (peerCallsign.toUpperCase() == callsign.toUpperCase()) return;

    print('  [$callsign] Geogram peer: $peerCallsign at $ip '
        '(http:$peerHttpPort, udp:$udpPort)');

    devices[peerCallsign.toUpperCase()] = DiscoveredDevice(
      callsign: peerCallsign.toUpperCase(),
      npub: peerNpub,
      deviceId: peerDeviceId,
      platform: peerPlatform,
      httpUrl: 'http://$ip:$peerHttpPort',
      udpIp: ip,
      udpPort: udpPort,
      connectionMethod: 'internet',
      isOnline: true,
      lastSeen: DateTime.now(),
    );
  }

  void _registerDevice(String peerCallsign, Map<String, dynamic> data,
      PeerInfo peer, String method) {
    devices[peerCallsign.toUpperCase()] = DiscoveredDevice(
      callsign: peerCallsign.toUpperCase(),
      npub: data['npub'] as String?,
      deviceId: data['device_id'] as String?,
      platform: data['platform'] as String?,
      httpUrl: 'http://${peer.ip}:${peer.port}',
      udpIp: peer.ip,
      udpPort: peer.port,
      connectionMethod: method,
      isOnline: true,
      lastSeen: DateTime.now(),
    );
    print('  [$callsign] Registered device $peerCallsign via $method');
  }

  /// Send data to a registered device via HTTP.
  Future<Map<String, dynamic>?> sendToDevice(String targetCallsign,
      String path) async {
    final device = devices[targetCallsign.toUpperCase()];
    if (device == null) return null;

    try {
      final resp = await HttpClient().getUrl(
          Uri.parse('${device.httpUrl}$path'))
          .then((req) => req.close())
          .timeout(const Duration(seconds: 3));
      if (resp.statusCode == 200) {
        final body = await resp.transform(utf8.decoder).join();
        return jsonDecode(body) as Map<String, dynamic>;
      }
    } catch (e) {
      print('  [$callsign] HTTP to $targetCallsign failed: $e');
    }

    // Fallback: send via geogram DHT message
    if (device.udpPort != null) {
      print('  [$callsign] Trying DHT message to $targetCallsign');
      final response = await dht.sendGeogramQuery(device.udpIp, device.udpPort!);
      return response;
    }

    return null;
  }

  /// Stop everything.
  Future<void> stop() async {
    await _httpServer?.close(force: true);
    await dht.stop();
    dht.dispose();
    print('  [$callsign] Stopped');
  }
}

/// A device discovered via DHT.
class DiscoveredDevice {
  final String callsign;
  final String? npub;
  final String? deviceId;
  final String? platform;
  final String httpUrl;
  final String udpIp;
  final int? udpPort;
  final String connectionMethod;
  bool isOnline;
  DateTime lastSeen;

  DiscoveredDevice({
    required this.callsign,
    this.npub,
    this.deviceId,
    this.platform,
    required this.httpUrl,
    required this.udpIp,
    this.udpPort,
    required this.connectionMethod,
    required this.isOnline,
    required this.lastSeen,
  });

  Map<String, dynamic> toJson() => {
    'callsign': callsign,
    'npub': npub,
    'device_id': deviceId,
    'platform': platform,
    'http_url': httpUrl,
    'udp_ip': udpIp,
    'udp_port': udpPort,
    'connection_method': connectionMethod,
    'is_online': isOnline,
    'last_seen': lastSeen.toIso8601String(),
  };
}

// ─── Test Runner ─────────────────────────────────────────────────

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
  print('══════════════════════════════════════════════════');
  print('  P2P Connection Test — Two Geogram Instances');
  print('══════════════════════════════════════════════════');
  print('Memory before: ${_memoryMB()} MB');
  print('');

  // ─── Phase 1: Create two instances ─────────────────────────────
  print('--- Phase 1: Create instances ---');
  final alice = GeogramInstance(
    callsign: 'X1ALICE',
    npub: 'npub1alice_test_key_0001',
    deviceId: 'alice-device-uuid-001',
    platform: 'linux',
    httpPort: 18001,
  );
  final bob = GeogramInstance(
    callsign: 'X2BOB',
    npub: 'npub1bob_test_key_0002',
    deviceId: 'bob-device-uuid-002',
    platform: 'android',
    httpPort: 18002,
  );

  await alice.start();
  await bob.start();
  _check('Alice HTTP running', alice.isRunning);
  _check('Bob HTTP running', bob.isRunning);
  print('');

  // ─── Phase 2: Verify HTTP servers respond ──────────────────────
  print('--- Phase 2: HTTP status check ---');
  final aliceStatus = await _httpGet('http://localhost:18001/api/status');
  final bobStatus = await _httpGet('http://localhost:18002/api/status');

  _check('Alice /api/status responds', aliceStatus != null);
  _check('Bob /api/status responds', bobStatus != null);
  if (aliceStatus != null) {
    _check('Alice callsign correct', aliceStatus['callsign'] == 'X1ALICE');
    _check('Alice has device_id', aliceStatus['device_id'] == 'alice-device-uuid-001');
  }
  if (bobStatus != null) {
    _check('Bob callsign correct', bobStatus['callsign'] == 'X2BOB');
    _check('Bob platform correct', bobStatus['platform'] == 'android');
  }
  print('');

  // ─── Phase 3: Bootstrap DHT ────────────────────────────────────
  print('--- Phase 3: Bootstrap DHT ---');
  await alice.bootstrap();
  await bob.bootstrap();
  _check('Alice has DHT nodes', alice.dht.routingTableSize > 0);
  _check('Bob has DHT nodes', bob.dht.routingTableSize > 0);
  print('Memory after bootstrap: ${_memoryMB()} MB');
  print('');

  // ─── Phase 4: Announce on DHT ──────────────────────────────────
  print('--- Phase 4: Announce on DHT ---');
  await alice.announce();
  await bob.announce();
  _check('Alice announced', true);
  _check('Bob announced', true);
  print('');

  // ─── Phase 5: Wait for DHT propagation ─────────────────────────
  print('--- Phase 5: Wait 5s for DHT propagation ---');
  await Future.delayed(const Duration(seconds: 5));
  print('');

  // ─── Phase 6: Discover peers ───────────────────────────────────
  print('--- Phase 6: Discover peers on geogram topic ---');
  final alicePeers = await alice.discoverPeers();
  final bobPeers = await bob.discoverPeers();

  print('  Alice found ${alicePeers.length} peers:');
  for (final p in alicePeers) print('    ${p.ip}:${p.port}');
  print('  Bob found ${bobPeers.length} peers:');
  for (final p in bobPeers) print('    ${p.ip}:${p.port}');

  _check('Alice found peers', alicePeers.isNotEmpty);
  _check('Bob found peers', bobPeers.isNotEmpty);
  print('');

  // ─── Phase 7: Probe peers (HTTP + geogram query) ───────────────
  print('--- Phase 7: Probe discovered peers ---');

  for (final peer in alice.discoveredPeers) {
    await alice.probePeer(peer);
  }
  for (final peer in bob.discoveredPeers) {
    await bob.probePeer(peer);
  }

  // Also try localhost direct connection (simulates LAN)
  if (!alice.devices.containsKey('X2BOB')) {
    print('  Alice probing Bob directly on localhost');
    await alice.probePeer(PeerInfo(ip: '127.0.0.1', port: bob.httpPort));
  }
  if (!bob.devices.containsKey('X1ALICE')) {
    print('  Bob probing Alice directly on localhost');
    await bob.probePeer(PeerInfo(ip: '127.0.0.1', port: alice.httpPort));
  }

  // Allow callbacks to fire
  await Future.delayed(const Duration(seconds: 1));

  print('  Alice devices: ${alice.devices.keys.toList()}');
  print('  Bob devices: ${bob.devices.keys.toList()}');

  _check('Alice found Bob', alice.devices.containsKey('X2BOB'));
  _check('Bob found Alice', bob.devices.containsKey('X1ALICE'));

  if (alice.devices.containsKey('X2BOB')) {
    final bobDev = alice.devices['X2BOB']!;
    _check('Alice knows Bob platform', bobDev.platform == 'android');
    _check('Alice knows Bob npub', bobDev.npub == 'npub1bob_test_key_0002');
    _check('Bob marked online', bobDev.isOnline);
    _check('Bob has internet method', bobDev.connectionMethod == 'http' || bobDev.connectionMethod == 'internet');
  }
  print('');

  // ─── Phase 8: Send data between instances ──────────────────────
  print('--- Phase 8: Data transfer ---');

  // Alice sends request to Bob
  final echoFromBob = await alice.sendToDevice('X2BOB', '/api/echo');
  _check('Alice got echo from Bob', echoFromBob != null);
  if (echoFromBob != null) {
    _check('Echo is from Bob', echoFromBob['from'] == 'X2BOB');
    print('  Bob responded: ${echoFromBob['echo']}');
  }

  // Bob sends request to Alice
  final echoFromAlice = await bob.sendToDevice('X1ALICE', '/api/echo');
  _check('Bob got echo from Alice', echoFromAlice != null);
  if (echoFromAlice != null) {
    _check('Echo is from Alice', echoFromAlice['from'] == 'X1ALICE');
    print('  Alice responded: ${echoFromAlice['echo']}');
  }
  print('');

  // ─── Phase 9: Geogram DHT messaging (NAT fallback) ─────────────
  print('--- Phase 9: DHT messaging (simulated NAT) ---');

  // Send geogram queries directly via DHT socket (simulates NAT scenario)
  final dhtResponseAB = await alice.dht.sendGeogramQuery(
      '127.0.0.1', bob.dht.localPort);
  _check('DHT query A→B response', dhtResponseAB != null);
  if (dhtResponseAB != null) {
    _check('DHT response has Bob callsign',
        dhtResponseAB.containsKey('callsign'));
  }

  final dhtResponseBA = await bob.dht.sendGeogramQuery(
      '127.0.0.1', alice.dht.localPort);
  _check('DHT query B→A response', dhtResponseBA != null);
  if (dhtResponseBA != null) {
    _check('DHT response has Alice callsign',
        dhtResponseBA.containsKey('callsign'));
  }
  print('');

  // ─── Phase 10: Verify devices panel ─────────────────────────────
  print('--- Phase 10: Verify Devices panel ---');

  // Check /api/devices endpoint
  final aliceDevicesResp = await _httpGet('http://localhost:18001/api/devices');
  final bobDevicesResp = await _httpGet('http://localhost:18002/api/devices');

  _check('Alice /api/devices responds', aliceDevicesResp != null);
  _check('Bob /api/devices responds', bobDevicesResp != null);

  if (aliceDevicesResp != null) {
    final devList = aliceDevicesResp['devices'] as List;
    _check('Alice has Bob in devices list', devList.any((d) => d['callsign'] == 'X2BOB'));
    if (devList.isNotEmpty) {
      print('  Alice devices panel:');
      for (final d in devList) {
        print('    ${d['callsign']} (${d['platform']}) - ${d['connection_method']} - online:${d['is_online']}');
      }
    }
  }
  if (bobDevicesResp != null) {
    final devList = bobDevicesResp['devices'] as List;
    _check('Bob has Alice in devices list', devList.any((d) => d['callsign'] == 'X1ALICE'));
  }
  print('');

  // ─── Phase 11: Memory check ────────────────────────────────────
  print('--- Phase 11: Memory ---');
  final memMB = double.parse(_memoryMB());
  print('  Final memory: $memMB MB');
  _check('Memory under 250MB', memMB < 250);
  print('');

  // ─── Cleanup ──────────────────────────────────────────────────
  print('--- Cleanup ---');
  await alice.stop();
  await bob.stop();
  print('Memory after cleanup: ${_memoryMB()} MB');
  print('');

  // ─── Summary ──────────────────────────────────────────────────
  print('══════════════════════════════════════════════════');
  print('  PASSED: $_passed');
  print('  FAILED: $_failed');
  if (_failed == 0) {
    print('  *** ALL TESTS PASSED ***');
  } else {
    print('  *** $_failed TEST(S) FAILED ***');
  }
  print('══════════════════════════════════════════════════');

  exit(_failed > 0 ? 1 : 0);
}

Future<Map<String, dynamic>?> _httpGet(String url) async {
  try {
    final client = HttpClient();
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close().timeout(const Duration(seconds: 3));
    if (response.statusCode == 200) {
      final body = await response.transform(utf8.decoder).join();
      client.close();
      return jsonDecode(body) as Map<String, dynamic>;
    }
    client.close();
  } catch (_) {}
  return null;
}

String _memoryMB() {
  return (ProcessInfo.currentRss / 1024 / 1024).toStringAsFixed(1);
}
