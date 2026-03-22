/// P2P Discovery Service — runs DHT on main isolate with Timer-based scheduling.
///
/// Each DHT operation (bootstrap, announce, get_peers) is a single async
/// call that yields to the event loop between query rounds via
/// Future.delayed. No Isolate.spawn (causes OOM on Android from double heap).
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

const String _kNodeCachePath = 'p2p/dht_cache.json';
const String _kNodeIdPath = 'p2p/node_id.bin';
const String _kPeerCachePath = 'p2p/peer_cache.json';
const String _kTaskId = 'p2p_discovery.dht';

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
  DhtNode? _dht;
  NodeCapability? _capability;
  Timer? _refreshTimer;

  bool _running = false;
  bool get isRunning => _running;
  int _dhtPort = 0;
  int get dhtPort => _dhtPort;
  int get dhtPeerCount => _dht?.routingTableSize ?? 0;
  NodeType get nodeType => _capability?.type ?? NodeType.unknown;
  String? get publicIp => _capability?.publicIp;
  int? get publicPort => _capability?.publicPort;
  int get directConnectionCount => 0;

  final Set<PeerInfo> discoveredPeers = {};
  final _peersController = StreamController<List<PeerInfo>>.broadcast();
  Stream<List<PeerInfo>> get onDiscoveredPeersChanged => _peersController.stream;
  final Set<String> _probedPeers = {};
  final Map<String, Completer<List<PeerInfo>>> _findCompleters = {};

  Future<void> start({int? localPort}) async {
    localPort ??= AppArgs().port;
    if (!_enabled || _running) return;

    final profile = ProfileService().getProfile();
    if (profile.npub.isEmpty) {
      LogService().log('P2P: No npub set, cannot start');
      return;
    }

    _taskHandle = MonitoredIsolateHandle(
      id: _kTaskId,
      name: 'P2P Discovery',
      description: 'BitTorrent DHT peer discovery',
      serviceName: 'P2PService',
    );
    _taskHandle?.markRunning();
    _running = true;

    // Load cached peers immediately
    final cachedPeers = await _loadCachedPeersRaw();
    if (cachedPeers != null) {
      for (final e in cachedPeers) {
        final ip = e['ip'] as String?;
        final port = e['port'] as int?;
        if (ip != null && port != null) {
          _addDiscoveredPeer(PeerInfo(ip: ip, port: port));
        }
      }
    }

    LogService().log('P2P: scheduled DHT start');

    // Schedule each phase with Timer gaps so the event loop stays free
    _phase1_startNode(localPort!, profile.npub);
  }

  // ─── Phased Startup (each phase scheduled via Timer) ──────────

  void _phase1_startNode(int port, String npub) {
    Timer(const Duration(seconds: 2), () async {
      if (!_running) return;
      try {
        final persistedId = await _loadNodeId();
        _dht = DhtNode();
        _capability = NodeCapability();
        await _dht!.start(persistedNodeId: persistedId);
        await _saveNodeId(_dht!.nodeId);
        _dhtPort = _dht!.localPort;

        _dht!.onPeerFound.listen((e) => _addDiscoveredPeer(e.$2));

        LogService().log('P2P: DHT socket on port $_dhtPort');
        _phase2_bootstrap(port, npub);
      } catch (e) {
        _taskHandle?.markError(e);
        LogService().log('P2P: start failed: $e');
      }
    });
  }

  void _phase2_bootstrap(int port, String npub) {
    Timer(const Duration(seconds: 1), () async {
      if (!_running || _dht == null) return;
      try {
        final raw = await _loadCachedNodesRaw();
        List<DhtContact>? cached;
        if (raw != null) {
          cached = <DhtContact>[];
          for (final e in raw) {
            final id = e['id'] as String?;
            final ip = e['ip'] as String?;
            final p = e['port'] as int?;
            if (id != null && ip != null && p != null) {
              cached.add(DhtContact(nodeId: _fromHex(id), ip: ip, port: p));
            }
          }
        }
        await _dht!.bootstrap(cachedNodes: cached);
        LogService().log('P2P: bootstrap done (${_dht!.routingTableSize} nodes)');
        _phase3_announce(port, npub);
      } catch (e) {
        LogService().log('P2P: bootstrap failed: $e');
      }
    });
  }

  void _phase3_announce(int port, String npub) {
    Timer(const Duration(seconds: 2), () async {
      if (!_running || _dht == null) return;
      try {
        final geogramHash = sha1Hash('geogram');
        final npubHash = sha1Hash(npub);
        await _dht!.announce(geogramHash, port);
        await _dht!.announce(npubHash, port);
        _dht!.startPeriodicAnnounce();
        LogService().log('P2P: announced on DHT');
        _phase4_detect();
      } catch (e) {
        LogService().log('P2P: announce failed: $e');
      }
    });
  }

  void _phase4_detect() {
    Timer(const Duration(seconds: 2), () async {
      if (!_running || _dht == null) return;
      try {
        await _capability!.detectFromDht(_dht!);

        // Initial scan
        final peers = await _dht!.getPeers(sha1Hash('geogram'));
        for (final p in peers) {
          _addDiscoveredPeer(p);
        }

        _taskHandle?.markIdle();
        LogService().log('P2P service started '
            '(type: ${_capability!.type.name}, dht: ${_dht!.routingTableSize} nodes)');

        // Start periodic refresh
        _refreshTimer = Timer.periodic(const Duration(minutes: 5), (_) async {
          if (_dht == null || !_dht!.isRunning) return;
          await _capability!.detectFromDht(_dht!);
          final p = _dht!.getCachedPeers(sha1Hash('geogram'));
          for (final peer in p) {
            _addDiscoveredPeer(peer);
          }
          _probeKnownDevicesViaDht();
        });

        // Probe known devices
        _probeKnownDevicesViaDht();

        // Schedule npub probes
        Timer(const Duration(seconds: 15), () => _populateNpubCache());
      } catch (e) {
        _taskHandle?.markError(e);
        LogService().log('P2P: detect failed: $e');
      }
    });
  }

  // ─── Stop ─────────────────────────────────────────────────────

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
    _dht = null;
    _capability = null;
    _running = false;
    _taskHandle?.dispose();
    _taskHandle = null;
    LogService().log('P2P service stopped');
  }

  // ─── Public API ───────────────────────────────────────────────

  Future<List<PeerInfo>> findDevicesForUser(String npub) async {
    if (_dht == null || !_dht!.isRunning) return [];
    return _dht!.getPeers(sha1Hash(npub));
  }

  Future<void> addNode(String ip, int port) async {
    _dht?.pingNode(ip, port);
  }

  Map<String, dynamic> getStatus() {
    final nt = _capability?.type ?? NodeType.unknown;
    final ip = _capability?.publicIp;
    final pp = _capability?.publicPort;
    return {
      'enabled': _enabled,
      'running': _running,
      'dht_port': _dht?.localPort ?? _dhtPort,
      'node_type': nt.name,
      'public_ip': ip,
      'public_port': pp,
      'dht_nodes': _dht?.routingTableSize ?? 0,
      'stored_peers': _dht?.storedPeerCount ?? 0,
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

      final devService = DevicesService();
      devService.addOrUpdateDevice(RemoteDevice(
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
      devService.syncDeviceToConnectionManager(callsign.toUpperCase());
      LogService().log('P2P: found $displayName at ${peer.ip}:${peer.port} via DHT');
    } catch (_) {}
  }

  void _probeKnownDevicesViaDht() {
    if (_dht == null || !_dht!.isRunning) return;

    final myCallsign = ProfileService().getProfile().callsign.toUpperCase();
    final devService = DevicesService();
    final devices = devService.getAllDevices()
        .where((d) =>
            d.callsign.toUpperCase() != myCallsign &&
            d.npub != null &&
            d.npub!.isNotEmpty)
        .take(5)
        .toList();

    for (var i = 0; i < devices.length; i++) {
      final device = devices[i];
      Timer(Duration(seconds: i * 5), () async {
        if (_dht == null || !_dht!.isRunning) return;
        try {
          final peers = await findDevicesForUser(device.npub!);
          if (peers.isNotEmpty) {
            if (!device.connectionMethods.contains('internet')) {
              device.connectionMethods = [...device.connectionMethods, 'internet'];
            }
            device.url = 'http://${peers.first.ip}:${peers.first.port}';
            device.isOnline = true;
            device.lastSeen = DateTime.now();
            devService.addOrUpdateDevice(device);
            devService.syncDeviceToConnectionManager(device.callsign);
            LogService().log('P2P: ${device.callsign} found via DHT at ${peers.first.ip}:${peers.first.port}');
          }
        } catch (_) {}
      });
    }
  }

  void _populateNpubCache() {
    if (_dht == null || !_dht!.isRunning) return;
    _probeKnownDevicesViaDht();
    Timer.periodic(const Duration(minutes: 5), (_) {
      if (!_running) return;
      _probeKnownDevicesViaDht();
    });
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

  static String _toHex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _fromHex(String hex) {
    final bytes = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }
}
