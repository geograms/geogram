/// P2P Discovery Service — orchestrates DHT, STUN, and hole punching.
///
/// Ties together:
/// - DhtNode: BEP 5 Mainline DHT for peer discovery
/// - NodeCapability: NAT type detection via STUN
/// - IcePunch: UDP hole punching for direct connections
///
/// Each device announces under two DHT topics:
/// 1. SHA1("geogram") — global topic (find all Geogram nodes)
/// 2. SHA1(npub) — per-user topic (find all devices for a specific identity)
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../services/config_service.dart';
import '../services/log_service.dart';
import '../services/profile_service.dart';
import '../services/app_service.dart';
import 'dht_node.dart';
import 'ice_punch.dart';
import 'k_bucket.dart';
import 'node_capability.dart';

/// File path for persisted DHT node cache (relative to profile storage).
const String _kNodeCachePath = 'p2p/dht_cache.json';

/// File path for persisted node ID.
const String _kNodeIdPath = 'p2p/node_id.bin';

/// P2P Discovery Service.
///
/// Singleton orchestrator that manages DHT announcement, peer discovery,
/// NAT detection, and direct connection establishment.
class P2PService {
  static final P2PService _instance = P2PService._internal();
  factory P2PService() => _instance;
  P2PService._internal();

  /// Core components.
  final DhtNode _dht = DhtNode();
  final NodeCapability _capability = NodeCapability();
  final IcePunch _icePunch = IcePunch();

  /// Whether P2P is enabled (user preference).
  bool _enabled = true;
  bool get enabled => _enabled;
  set enabled(bool value) {
    _enabled = value;
    if (!value && _dht.isRunning) {
      stop();
    }
  }

  /// Whether the service is currently running.
  bool get isRunning => _dht.isRunning;

  /// Stream of newly discovered peers (forwarded from DhtNode).
  Stream<(Uint8List infoHash, PeerInfo peer)> get onPeerFound =>
      _dht.onPeerFound;

  /// DHT routing table size.
  int get dhtPeerCount => _dht.routingTableSize;

  /// Active direct connections count.
  int get directConnectionCount => _icePunch.connectionCount;

  /// Detected node type.
  NodeType get nodeType => _capability.type;

  /// Our public address.
  String? get publicIp => _capability.publicIp;
  int? get publicPort => _capability.publicPort;

  /// The global Geogram info_hash.
  late final Uint8List _geogramHash = sha1Hash('geogram');

  /// Our npub info_hash (set after profile is loaded).
  Uint8List? _npubHash;

  /// Re-STUN timer (every 5 minutes to track IP changes).
  Timer? _stunRefreshTimer;

  /// Stream subscriptions.
  StreamSubscription? _peerFoundSub;

  /// Start the P2P service.
  ///
  /// [localPort] — the port our local server listens on (e.g., 3456).
  Future<void> start({int localPort = 3456}) async {
    if (!_enabled) return;
    if (_dht.isRunning) return;

    final profile = ProfileService().getProfile();
    final npub = profile.npub;
    if (npub.isEmpty) {
      LogService().log('P2P: No npub set, cannot start');
      return;
    }

    _npubHash = sha1Hash(npub);

    // Load persisted node ID
    final persistedId = await _loadNodeId();

    // Start DHT node
    await _dht.start(persistedNodeId: persistedId);

    // Save node ID for next session
    await _saveNodeId(_dht.nodeId);

    // Load cached nodes and bootstrap
    final cachedNodes = await _loadCachedNodes();
    await _dht.bootstrap(cachedNodes: cachedNodes);

    // Announce on both topics
    await _dht.announce(_geogramHash, localPort);
    if (_npubHash != null) {
      await _dht.announce(_npubHash!, localPort);
    }

    // Start periodic re-announce
    _dht.startPeriodicAnnounce();

    // Detect node type
    final typeAPeers = await _dht.getPeers(_geogramHash);
    await _capability.detect(_dht, typeAPeers);

    // Listen for newly discovered peers
    _peerFoundSub = _dht.onPeerFound.listen(_onPeerFound);

    // Periodically re-check STUN (IP may change)
    _stunRefreshTimer = Timer.periodic(const Duration(minutes: 5), (_) async {
      final peers = _dht.getCachedPeers(_geogramHash);
      await _capability.detect(_dht, peers);
    });

    LogService().log('P2P service started '
        '(type: ${_capability.type.name}, '
        'dht: ${_dht.routingTableSize} nodes)');
  }

  /// Stop the P2P service and persist state.
  Future<void> stop() async {
    _stunRefreshTimer?.cancel();
    _peerFoundSub?.cancel();

    // Save routing table for next session
    await _saveCachedNodes(_dht.getNodesForCache());

    _icePunch.closeAll();
    await _dht.stop();

    LogService().log('P2P service stopped');
  }

  /// Find all online devices for a specific npub.
  ///
  /// Returns list of IP:port entries — one per device.
  Future<List<PeerInfo>> findDevicesForUser(String npub) async {
    if (!_dht.isRunning) return [];
    final hash = sha1Hash(npub);
    return _dht.getPeers(hash);
  }

  /// Attempt to connect directly to a peer via hole punching.
  Future<DirectConnection?> connectTo(PeerInfo peer) async {
    if (!_dht.isRunning) return null;

    if (_capability.publicIp == null) {
      LogService().log('P2P: Cannot connect — own public address unknown');
      return null;
    }

    final ourCandidate = IceCandidate(
      ip: _capability.publicIp!,
      port: _capability.publicPort!,
    );

    final theirCandidate = IceCandidate(
      ip: peer.ip,
      port: peer.port,
    );

    // Create a socket for this connection attempt
    final connection = await _icePunch.punch(
      localSocket: await _createSocket(),
      ourCandidate: ourCandidate,
      theirCandidate: theirCandidate,
      capability: _capability,
    );

    if (connection != null) {
      // Send identity handshake
      final profile = ProfileService().getProfile();
      await _icePunch.sendHandshake(
        connection,
        deviceId: ConfigService().deviceId,
        deviceName: ConfigService().get('device_name') as String? ?? '',
        callsign: profile.callsign,
        npub: profile.npub,
      );
    }

    return connection;
  }

  /// Get a direct connection to a device by callsign (if one exists).
  DirectConnection? getConnectionByCallsign(String callsign) {
    return _icePunch.getConnectionByCallsign(callsign);
  }

  /// Get all active direct connections.
  List<DirectConnection> get activeConnections => _icePunch.activeConnections;

  /// Get comprehensive status for API/UI.
  Map<String, dynamic> getStatus() {
    return {
      'enabled': _enabled,
      'running': _dht.isRunning,
      'node_type': _capability.type.name,
      'public_ip': _capability.publicIp,
      'public_port': _capability.publicPort,
      'dht_nodes': _dht.routingTableSize,
      'stored_peers': _dht.storedPeerCount,
      'direct_connections': _icePunch.connectionCount,
      'connections': _icePunch.getStatus(),
      'capability': _capability.getStatus(),
    };
  }

  // ─── Internal ──────────────────────────────────────────────────

  void _onPeerFound((Uint8List infoHash, PeerInfo peer) event) {
    // Log discovery but don't auto-connect (let transport layer decide)
    LogService().log('P2P: peer found ${event.$2} for ${_hexPrefix(event.$1)}');
  }

  Future<RawDatagramSocket> _createSocket() async {
    return RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
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

  Future<List<DhtContact>?> _loadCachedNodes() async {
    try {
      final storage = AppService().profileStorage;
      if (storage == null) return null;
      final json = await storage.readJson(_kNodeCachePath);
      if (json == null) return null;

      final nodes = <DhtContact>[];
      final list = json['nodes'] as List<dynamic>? ?? [];
      for (final entry in list) {
        if (entry is! Map<String, dynamic>) continue;
        final idHex = entry['id'] as String?;
        final ip = entry['ip'] as String?;
        final port = entry['port'] as int?;
        if (idHex == null || ip == null || port == null) continue;
        nodes.add(DhtContact(
          nodeId: _fromHex(idHex),
          ip: ip,
          port: port,
        ));
      }
      return nodes.isEmpty ? null : nodes;
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveCachedNodes(List<DhtContact> nodes) async {
    try {
      final storage = AppService().profileStorage;
      if (storage == null) return;
      await storage.createDirectory('p2p');
      final list = nodes
          .map((n) => {
                'id': _toHex(n.nodeId),
                'ip': n.ip,
                'port': n.port,
              })
          .toList();
      await storage.writeJson(_kNodeCachePath, {'nodes': list});
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

  static String _hexPrefix(Uint8List bytes) {
    if (bytes.length < 4) return _toHex(bytes);
    return _toHex(bytes).substring(0, 8);
  }
}
