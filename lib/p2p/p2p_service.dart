/// P2P Discovery Service — orchestrates DHT in a background isolate.
///
/// All DHT work (bootstrap, announce, get_peers, detect) runs in a
/// separate Dart isolate so it never blocks the main thread's HTTP
/// server or UI. Communication via SendPort/ReceivePort.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
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
import 'dht_isolate.dart';
import 'dht_node.dart' show PeerInfo, sha1Hash;
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

  // Isolate state
  Isolate? _isolate;
  ReceivePort? _receivePort;
  SendPort? _commandPort;
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

  /// Pending find_user completers
  final Map<String, Completer<List<Map<String, dynamic>>>> _findCompleters = {};

  /// Start the P2P service in a background isolate.
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

    // Load persisted state
    final persistedId = await _loadNodeId();
    final cachedNodes = await _loadCachedNodesRaw();
    final cachedPeers = await _loadCachedPeersRaw();

    // Load cached peers immediately (before isolate starts)
    if (cachedPeers != null) {
      for (final entry in cachedPeers) {
        final ip = entry['ip'] as String?;
        final port = entry['port'] as int?;
        if (ip != null && port != null) {
          _addDiscoveredPeer(PeerInfo(ip: ip, port: port));
        }
      }
    }

    // Spawn the DHT isolate
    _receivePort = ReceivePort();
    final params = DhtIsolateParams(
      sendPort: _receivePort!.sendPort,
      announcePort: localPort,
      npub: npub,
      persistedNodeId: persistedId,
      cachedNodes: cachedNodes,
      cachedPeers: cachedPeers,
    );

    _receivePort!.listen(_handleIsolateMessage);
    _isolate = await Isolate.spawn(dhtIsolateEntry, params);
    _running = true;
    _taskHandle?.markRunning();
    LogService().log('P2P: isolate spawned');
  }

  /// Stop the P2P service.
  Future<void> stop() async {
    if (_commandPort != null) {
      _commandPort!.send(jsonEncode({'action': 'stop'}));
      // Wait briefly for cache to be sent back
      await Future.delayed(const Duration(seconds: 1));
    }
    _cleanup();
    LogService().log('P2P service stopped');
  }

  void _cleanup() {
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _isolate = null;
    _receivePort?.close();
    _receivePort = null;
    _commandPort = null;
    _running = false;
    _taskHandle?.dispose();
    _taskHandle = null;
  }

  /// Find devices for a specific npub via DHT.
  Future<List<PeerInfo>> findDevicesForUser(String npub) async {
    if (!_running || _commandPort == null) return [];
    final completer = Completer<List<Map<String, dynamic>>>();
    _findCompleters[npub] = completer;
    _commandPort!.send(jsonEncode({'action': 'find_user', 'npub': npub}));
    final results = await completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => [],
    );
    _findCompleters.remove(npub);
    return results.map((r) => PeerInfo(
      ip: r['ip'] as String,
      port: r['port'] as int,
    )).toList();
  }

  /// Add a DHT node manually.
  Future<void> addNode(String ip, int port) async {
    _commandPort?.send(jsonEncode({'action': 'add_node', 'ip': ip, 'port': port}));
  }

  /// Get full status.
  Map<String, dynamic> getStatus() {
    return {
      'enabled': _enabled,
      'running': _running,
      'dht_port': _dhtPort,
      'node_type': _nodeType.name,
      'public_ip': _publicIp,
      'public_port': _publicPort,
      'dht_nodes': _dhtNodes,
      'stored_peers': _storedPeers,
      'direct_connections': 0,
      'connections': {'connections': 0, 'peers': []},
      'capability': {
        'node_type': _nodeType.name,
        'public_ip': _publicIp,
        'public_port': _publicPort,
        'can_hole_punch': _nodeType == NodeType.typeA || _nodeType == NodeType.typeB,
      },
    };
  }

  // ─── Isolate Message Handling ──────────────────────────────────

  void _handleIsolateMessage(dynamic message) {
    // The isolate sends both JSON strings and SendPort objects
    if (message is SendPort) {
      _commandPort = message;
      return;
    }
    if (message is! String) return;

    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(message) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    final type = msg['type'] as String?;
    switch (type) {
      case 'log':
        LogService().log(msg['message'] as String? ?? '');
        break;

      case 'node_id':
        final idHex = msg['id'] as String?;
        if (idHex != null) {
          _saveNodeId(_fromHex(idHex));
        }
        break;

      case 'started':
        _dhtPort = msg['dht_port'] as int? ?? 0;
        _dhtNodes = msg['dht_nodes'] as int? ?? 0;
        _updateCapability(msg);
        _taskHandle?.markIdle();
        LogService().log('P2P service started '
            '(type: ${_nodeType.name}, dht: $_dhtNodes nodes)');
        break;

      case 'status':
        _dhtNodes = msg['dht_nodes'] as int? ?? _dhtNodes;
        _storedPeers = msg['stored_peers'] as int? ?? _storedPeers;
        _updateCapability(msg);
        break;

      case 'peer_found':
        final ip = msg['ip'] as String?;
        final port = msg['port'] as int?;
        if (ip != null && port != null) {
          _addDiscoveredPeer(PeerInfo(ip: ip, port: port));
        }
        break;

      case 'find_result':
        final npub = msg['npub'] as String?;
        final devices = msg['devices'] as List<dynamic>?;
        if (npub != null && _findCompleters.containsKey(npub)) {
          _findCompleters[npub]!.complete(
            devices?.cast<Map<String, dynamic>>() ?? [],
          );
        }
        break;

      case 'cache':
        final nodes = msg['nodes'] as List<dynamic>?;
        if (nodes != null) {
          _saveCachedNodes(nodes.cast<Map<String, dynamic>>());
        }
        break;

      case 'stopped':
        _cleanup();
        break;

      case 'error':
        final error = msg['message'] as String? ?? 'unknown';
        _taskHandle?.markError(error);
        LogService().log('P2P isolate error: $error');
        break;
    }
  }

  void _updateCapability(Map<String, dynamic> msg) {
    final nodeType = msg['node_type'] as String?;
    if (nodeType != null) {
      _nodeType = NodeType.values.firstWhere(
        (t) => t.name == nodeType,
        orElse: () => NodeType.unknown,
      );
    }
    _publicIp = msg['public_ip'] as String?;
    _publicPort = msg['public_port'] as int?;
    if (msg.containsKey('dht_port')) {
      _dhtPort = msg['dht_port'] as int? ?? _dhtPort;
    }
  }

  // ─── Peer Management ──────────────────────────────────────────

  void _addDiscoveredPeer(PeerInfo peer) {
    final myPort = AppArgs().port;
    if (peer.ip == _publicIp && peer.port == myPort) return;
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
          .timeout(const Duration(seconds: 5));
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
      // HTTP probe failed — peer behind NAT
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

  static Uint8List _fromHex(String hex) {
    final bytes = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }
}
