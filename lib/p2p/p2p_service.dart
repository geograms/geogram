/// P2P Discovery Service — orchestrates DHT in a background isolate.
///
/// All DHT work (bootstrap, announce, get_peers, detect) runs in a
/// separate Dart isolate so it never blocks the main thread's HTTP
/// server or UI. Communication via SendPort/ReceivePort.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import '../models/device_source.dart';
import '../services/app_args.dart';
import '../services/config_service.dart';
import '../services/devices_service.dart';
import '../services/log_service.dart';
import '../services/profile_service.dart';
import '../services/app_service.dart';
import '../util/task_monitor_helpers.dart';
import 'dht_node.dart';
import 'k_bucket.dart';
import 'node_capability.dart';

/// File paths for persisted state.
const String _kNodeCachePath = 'p2p/dht_cache.json';
const String _kNodeIdPath = 'p2p/node_id.bin';
const String _kPeerCachePath = 'p2p/peer_cache.json';
const String _kTaskId = 'p2p_discovery.dht';

/// P2P Discovery Service — singleton.
class P2PService {
  static final P2PService _instance = P2PService._internal();
  factory P2PService() => _instance;
  P2PService._internal();

  bool _enabled = true;
  bool get enabled => _enabled;
  set enabled(bool value) {
    _enabled = value;
    if (!value) stop();
  }

  MonitoredIsolateHandle? _taskHandle;

  // Status from isolate
  bool _running = false;
  bool get isRunning => _running;
  int _dhtPort = 0;
  int get dhtPort => _dhtPort;
  int _dhtNodes = 0;
  int get dhtPeerCount => _dhtNodes;
  int _storedPeers = 0;
  NodeType _nodeType = NodeType.unknown;
  NodeType get nodeType => _nodeType;
  String? _publicIp;
  String? get publicIp => _publicIp;
  int? _publicPort;
  int? get publicPort => _publicPort;
  int get directConnectionCount => 0; // TODO: hole punching

  // Discovered peers
  final Set<PeerInfo> discoveredPeers = {};
  final _peersController = StreamController<List<PeerInfo>>.broadcast();
  Stream<List<PeerInfo>> get onDiscoveredPeersChanged => _peersController.stream;
  final Set<String> _probedPeers = {};

  /// Start the P2P service.
  Future<void> start({int? localPort}) async {
    localPort ??= AppArgs().port;
    if (!_enabled) return;
    if (_running) return;

    final profile = ProfileService().getProfile();
    final npub = profile.npub;
    if (npub.isEmpty) {
      LogService().log('P2P: No npub set, cannot start');
      return;
    }

    _taskHandle = MonitoredIsolateHandle(
      id: _kTaskId,
      name: 'P2P Discovery',
      description: 'BitTorrent DHT peer discovery (isolate)',
      serviceName: 'P2PService',
    );

    // Load cached peers immediately
    final cachedPeers = await _loadCachedPeersRaw();
    if (cachedPeers != null) {
      for (final entry in cachedPeers) {
        final ip = entry['ip'] as String?;
        final port = entry['port'] as int?;
        if (ip != null && port != null) {
          _addDiscoveredPeer(PeerInfo(ip: ip, port: port));
        }
      }
    }

    _running = true;
    _taskHandle?.markRunning();

    // Run DHT directly on the main isolate (no Isolate.spawn —
    // a second isolate doubles memory and causes OOM on Android).
    // The iterative lookups use await Future.wait which yields to the
    // event loop between rounds, keeping the HTTP server responsive.
    Timer(const Duration(seconds: 2), () =>
        _runDht(localPort!, npub));

    LogService().log('P2P: scheduled DHT start');
  }

  /// The DhtNode instance (runs on main isolate).
  DhtNode? _dht;
  NodeCapability? _capability;
  Timer? _refreshTimer;

  Future<void> _runDht(int announcePort, String npub) async {
    try {
      final persistedId = await _loadNodeId();
      final cachedNodesRaw = await _loadCachedNodesRaw();

      _dht = DhtNode();
      _capability = NodeCapability();
      await _dht!.start(persistedNodeId: persistedId);
      await _saveNodeId(_dht!.nodeId);

      LogService().log('P2P: DHT socket on port ${_dht!.localPort}');

      // Bootstrap
      List<DhtContact>? cachedNodes;
      if (cachedNodesRaw != null) {
        cachedNodes = <DhtContact>[];
        for (final e in cachedNodesRaw) {
          final id = e['id'] as String?;
          final ip = e['ip'] as String?;
          final port = e['port'] as int?;
          if (id != null && ip != null && port != null) {
            cachedNodes.add(DhtContact(nodeId: _fromHex(id), ip: ip, port: port));
          }
        }
      }
      await _dht!.bootstrap(cachedNodes: cachedNodes);
      LogService().log('P2P: bootstrap done (${_dht!.routingTableSize} nodes)');

      // Announce
      final geogramHash = sha1Hash('geogram');
      final npubHash = sha1Hash(npub);
      await _dht!.announce(geogramHash, announcePort);
      await _dht!.announce(npubHash, announcePort);
      _dht!.startPeriodicAnnounce();
      LogService().log('P2P: announced on DHT');

      // Detect public IP
      await _capability!.detectFromDht(_dht!);

      // Listen for peers
      _dht!.onPeerFound.listen((event) {
        _addDiscoveredPeer(event.$2);
      });

      // Initial scan
      final peers = await _dht!.getPeers(geogramHash);
      for (final p in peers) {
        _addDiscoveredPeer(p);
      }

      // Probe known devices via their npub on DHT
      await _probeKnownDevicesViaDht();

      // Periodic refresh
      _refreshTimer = Timer.periodic(const Duration(minutes: 5), (_) async {
        if (_dht == null || !_dht!.isRunning) return;
        await _capability!.detectFromDht(_dht!);
        final p = _dht!.getCachedPeers(geogramHash);
        for (final peer in p) {
          _addDiscoveredPeer(peer);
        }
        await _probeKnownDevicesViaDht();
      });

      _dhtPort = _dht!.localPort;
      _dhtNodes = _dht!.routingTableSize;
      _nodeType = _capability!.type;
      _publicIp = _capability!.publicIp;
      _publicPort = _capability!.publicPort;
      _taskHandle?.markIdle();

      LogService().log('P2P service started '
          '(type: ${_nodeType.name}, dht: $_dhtNodes nodes)');
    } catch (e) {
      _taskHandle?.markError(e);
      LogService().log('P2P: DHT failed: $e');
    }
  }

  /// Stop the P2P service.
  Future<void> stop() async {
    _refreshTimer?.cancel();
    if (_dht != null && _dht!.isRunning) {
      final nodes = _dht!.getNodesForCache();
      await _saveCachedNodes(nodes.map((n) => {
        'id': _toHex(n.nodeId),
        'ip': n.ip,
        'port': n.port,
      }).toList());
      await _dht!.stop();
      _dht!.dispose();
    }
    await _saveDiscoveredPeers();
    _cleanup();
    LogService().log('P2P service stopped');
  }

  void _cleanup() {
    _dht = null;
    _capability = null;
    _refreshTimer?.cancel();
    _running = false;
    _taskHandle?.dispose();
    _taskHandle = null;
  }

  /// Look up each known device's npub on the DHT.
  /// If found, mark it online with 'internet' connection method.
  Future<void> _probeKnownDevicesViaDht() async {
    if (_dht == null || !_dht!.isRunning) return;

    final myCallsign = ProfileService().getProfile().callsign.toUpperCase();
    final devService = DevicesService();
    final allDevices = devService.getAllDevices();

    for (final device in allDevices) {
      if (device.callsign.toUpperCase() == myCallsign) continue;
      final npub = device.npub;
      if (npub == null || npub.isEmpty) continue;

      // Search DHT for this device's npub
      final hash = sha1Hash(npub);
      final peers = await _dht!.getPeers(hash);

      if (peers.isNotEmpty) {
        // Device is online via DHT — update with internet tag
        if (!device.connectionMethods.contains('internet')) {
          device.connectionMethods = [...device.connectionMethods, 'internet'];
        }
        device.isOnline = true;
        device.lastSeen = DateTime.now();

        // Store the DHT peer address for potential direct connection
        final peer = peers.first;
        final dhtUrl = 'http://${peer.ip}:${peer.port}';
        // Only update URL if the current one is unreachable (LAN IP from old network)
        if (device.url != null && !device.isOnline) {
          device.url = dhtUrl;
        }

        devService.addOrUpdateDevice(device);
        LogService().log('P2P: ${device.callsign} found via DHT at ${peer.ip}:${peer.port}');
      }

      // Yield between lookups
      await Future.delayed(const Duration(milliseconds: 200));
    }
  }

  /// Find devices for a specific npub via DHT.
  Future<List<PeerInfo>> findDevicesForUser(String npub) async {
    if (_dht == null || !_dht!.isRunning) return [];
    return _dht!.getPeers(sha1Hash(npub));
  }

  /// Add a DHT node manually.
  Future<void> addNode(String ip, int port) async {
    _dht?.pingNode(ip, port);
  }

  /// Get full status.
  Map<String, dynamic> getStatus() {
    final nt = _capability?.type ?? _nodeType;
    final ip = _capability?.publicIp ?? _publicIp;
    final pp = _capability?.publicPort ?? _publicPort;
    final nodes = _dht?.routingTableSize ?? _dhtNodes;
    final stored = _dht?.storedPeerCount ?? _storedPeers;
    final port = _dht?.localPort ?? _dhtPort;

    return {
      'enabled': _enabled,
      'running': _running,
      'dht_port': port,
      'node_type': nt.name,
      'public_ip': ip,
      'public_port': pp,
      'dht_nodes': nodes,
      'stored_peers': stored,
      'direct_connections': 0,
      'connections': {'connections': 0, 'peers': []},
      'capability': {
        'node_type': nt.name,
        'public_ip': ip,
        'public_port': pp,
        'can_hole_punch': nt == NodeType.typeA || nt == NodeType.typeB,
      },
    };
  }

  // ─── Peer Management ──────────────────────────────────────────

  void _addDiscoveredPeer(PeerInfo peer) {
    // Only skip localhost self — never skip by public IP because
    // same-household devices share the same public IP and port
    final myPort = AppArgs().port;
    if ((peer.ip == '127.0.0.1' || peer.ip == '0.0.0.0') && peer.port == myPort) return;

    if (discoveredPeers.add(peer)) {
      _peersController.add(discoveredPeers.toList());
      final key = '${peer.ip}:${peer.port}';
      if (!_probedPeers.contains(key)) {
        _probedPeers.add(key);
        _registerDhtPeer(peer);
      }
    }
  }

  /// Try to identify a DHT peer via direct HTTP (works on LAN/same-network).
  /// For NAT'd peers, _probeKnownDevicesViaDht handles identification via npub.
  Future<void> _registerDhtPeer(PeerInfo peer) async {
    final peerUrl = 'http://${peer.ip}:${peer.port}';
    final myCallsign = ProfileService().getProfile().callsign;

    try {
      final response = await http.get(Uri.parse('$peerUrl/api/status'))
          .timeout(const Duration(seconds: 3));
      if (response.statusCode != 200) return;

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final callsign = data['callsign'] as String?;
      if (callsign == null || callsign.isEmpty) return;
      if (callsign.toUpperCase() == myCallsign.toUpperCase()) return;

      final nickname = data['nickname'] as String?;
      final displayName = (nickname != null && nickname.isNotEmpty)
          ? '$nickname ($callsign)'
          : callsign;

      DevicesService().addOrUpdateDevice(RemoteDevice(
        callsign: callsign.toUpperCase(),
        name: displayName,
        nickname: nickname,
        npub: data['npub'] as String?,
        url: peerUrl,
        isOnline: true,
        hasCachedData: false,
        apps: [],
        connectionMethods: ['internet'],
        source: DeviceSourceType.direct,
        lastSeen: DateTime.now(),
        platform: data['platform'] as String?,
      ));
      LogService().log('P2P: found $displayName at ${peer.ip}:${peer.port} via DHT');
    } catch (_) {
      // HTTP probe failed (NAT) — _probeKnownDevicesViaDht will handle via npub
    }
  }

  // ─── Persistence ───────────────────────────────────────────────

  Future<Uint8List?> _loadNodeId() async {
    try {
      final storage = AppService().profileStorage;
      if (storage == null) return null;
      final bytes = await storage.readBytes(_kNodeIdPath);
      if (bytes != null && bytes.length == 20) return bytes;
    } catch (_) {}
    return null;
  }

  Future<void> _saveNodeId(Uint8List id) async {
    try {
      final storage = AppService().profileStorage;
      if (storage == null) return;
      await storage.createDirectory('p2p');
      await storage.writeBytes(_kNodeIdPath, id);
    } catch (_) {}
  }

  Future<List<Map<String, dynamic>>?> _loadCachedNodesRaw() async {
    try {
      final storage = AppService().profileStorage;
      if (storage == null) return null;
      final json = await storage.readJson(_kNodeCachePath);
      if (json == null) return null;
      return (json['nodes'] as List<dynamic>?)?.cast<Map<String, dynamic>>();
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveCachedNodes(List<Map<String, dynamic>> nodes) async {
    try {
      final storage = AppService().profileStorage;
      if (storage == null) return;
      await storage.createDirectory('p2p');
      await storage.writeJson(_kNodeCachePath, {'nodes': nodes});
    } catch (_) {}
  }

  Future<List<Map<String, dynamic>>?> _loadCachedPeersRaw() async {
    try {
      final storage = AppService().profileStorage;
      if (storage == null) return null;
      final json = await storage.readJson(_kPeerCachePath);
      if (json == null) return null;
      return (json['peers'] as List<dynamic>?)?.cast<Map<String, dynamic>>();
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveDiscoveredPeers() async {
    try {
      final storage = AppService().profileStorage;
      if (storage == null) return;
      await storage.createDirectory('p2p');
      final list = discoveredPeers.map((p) => {
        'ip': p.ip,
        'port': p.port,
      }).toList();
      await storage.writeJson(_kPeerCachePath, {'peers': list});
    } catch (_) {}
  }

  // ─── Utilities ─────────────────────────────────────────────────

  static String _toHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static Uint8List _fromHex(String hex) {
    final bytes = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }
}
