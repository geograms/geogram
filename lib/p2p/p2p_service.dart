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
import 'ice_punch.dart';
import 'k_bucket.dart';
import 'node_capability.dart';

/// Task monitor ID for DHT discovery.
const String _kTaskId = 'p2p_discovery.dht';

/// File path for persisted DHT node cache (relative to profile storage).
const String _kNodeCachePath = 'p2p/dht_cache.json';

/// File path for persisted node ID.
const String _kNodeIdPath = 'p2p/node_id.bin';

/// File path for cached discovered peers.
const String _kPeerCachePath = 'p2p/peer_cache.json';

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

  /// DHT node's UDP port.
  int get dhtPort => _dht.localPort;

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

  /// Task monitor handle.
  MonitoredIsolateHandle? _taskHandle;

  /// Peers discovered via DHT for our own npub (our other devices).
  final Set<PeerInfo> discoveredPeers = {};

  /// Stream of discovered peer updates.
  final _peersController = StreamController<List<PeerInfo>>.broadcast();

  /// Stream that emits when discovered peers change.
  Stream<List<PeerInfo>> get onDiscoveredPeersChanged => _peersController.stream;

  /// Start the P2P service.
  ///
  /// [localPort] — the port our local server listens on (default from AppArgs).
  /// Runs DHT bootstrap and announce in the background to avoid blocking the UI.
  Future<void> start({int? localPort}) async {
    localPort ??= AppArgs().port;
    if (!_enabled) return;
    if (_dht.isRunning) return;

    final profile = ProfileService().getProfile();
    final npub = profile.npub;
    if (npub.isEmpty) {
      LogService().log('P2P: No npub set, cannot start');
      return;
    }

    _npubHash = sha1Hash(npub);

    // Register as a monitored task
    _taskHandle = MonitoredIsolateHandle(
      id: _kTaskId,
      name: 'P2P Discovery',
      description: 'BitTorrent DHT peer discovery',
      serviceName: 'P2PService',
    );
    _taskHandle!.markRunning();

    try {
      // Load persisted node ID
      final persistedId = await _loadNodeId();

      // Start DHT node (binds UDP socket — fast, non-blocking)
      await _dht.start(persistedNodeId: persistedId);
      await _saveNodeId(_dht.nodeId);

      // Listen for newly discovered peers immediately
      _peerFoundSub = _dht.onPeerFound.listen(_onPeerFound);

      LogService().log('P2P: DHT socket open on port ${_dht.localPort}');

      // Schedule ALL heavy work (bootstrap, announce, detect) on a timer
      // so start() returns immediately and the HTTP server + UI stay responsive
      final announcePort = localPort!;
      Timer(const Duration(seconds: 2), () => _bootstrapAndAnnounce(announcePort));
    } catch (e) {
      _taskHandle?.markError(e);
      LogService().log('P2P service failed: $e');
    }
  }

  /// Stop the P2P service and persist state.
  Future<void> stop() async {
    _stunRefreshTimer?.cancel();
    _peerFoundSub?.cancel();

    // Save state for next session
    if (_dht.isRunning) {
      await _saveCachedNodes(_dht.getNodesForCache());
    }
    await _saveDiscoveredPeers();

    _icePunch.closeAll();
    await _dht.stop();
    discoveredPeers.clear();
    _taskHandle?.dispose();
    _taskHandle = null;

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

  /// Manually add a DHT node (for testing / direct peering).
  Future<void> addNode(String ip, int port) async {
    if (!_dht.isRunning) return;
    // Send a find_node to the peer — this will add them to our routing table
    // and trigger them to add us to theirs.
    _dht.pingNode(ip, port);
  }

  /// Get comprehensive status for API/UI.
  Map<String, dynamic> getStatus() {
    return {
      'enabled': _enabled,
      'running': _dht.isRunning,
      'dht_port': _dht.isRunning ? _dht.localPort : null,
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

  /// Heavy work scheduled after start() returns.
  /// Each phase is separated by Timer to give the HTTP server time to breathe.
  Future<void> _bootstrapAndAnnounce(int announcePort) async {
    if (!_dht.isRunning) return;

    try {
      // Load cached peers from previous session
      await _loadAndProbeCachedPeers();

      // Bootstrap DHT
      final cachedNodes = await _loadCachedNodes();
      await _dht.bootstrap(cachedNodes: cachedNodes);
      LogService().log('P2P: bootstrap complete (${_dht.routingTableSize} nodes)');

      // Schedule announce after a pause
      Timer(const Duration(seconds: 3), () => _announcePhase(announcePort));
    } catch (e) {
      _taskHandle?.markError(e);
      LogService().log('P2P bootstrap failed: $e');
    }
  }

  Future<void> _announcePhase(int port) async {
    if (!_dht.isRunning) return;
    try {
      await _dht.announce(_geogramHash, port);
      await Future.delayed(const Duration(seconds: 1));
      if (_npubHash != null && _dht.isRunning) {
        await _dht.announce(_npubHash!, port);
      }
      _dht.startPeriodicAnnounce();
      LogService().log('P2P: announced on DHT');

      // Schedule detection after another pause
      Timer(const Duration(seconds: 5), () => _detectAndScan());
    } catch (e) {
      LogService().log('P2P announce failed: $e');
    }
  }

  Future<void> _detectAndScan() async {
    if (!_dht.isRunning) return;
    try {
      await _capability.detectFromDht(_dht);

      // Check cached peers first (no network)
      final cachedGlobal = _dht.getCachedPeers(_geogramHash);
      for (final peer in cachedGlobal) {
        _addDiscoveredPeer(peer);
      }

      _stunRefreshTimer = Timer.periodic(const Duration(minutes: 5), (_) async {
        if (!_dht.isRunning) return;
        _taskHandle?.markRunning();
        await _capability.detectFromDht(_dht);
        // Light scan: check cached peers only (populated by fire-and-forget responses)
        final peers = _dht.getCachedPeers(_geogramHash);
        for (final peer in peers) {
          _addDiscoveredPeer(peer);
        }
        if (_npubHash != null) {
          final npubPeers = _dht.getCachedPeers(_npubHash!);
          for (final peer in npubPeers) {
            _addDiscoveredPeer(peer);
          }
        }
        _taskHandle?.markIdle();
      });

      _peersController.add(discoveredPeers.toList());
      _taskHandle?.markIdle();
      LogService().log('P2P service started '
          '(type: ${_capability.type.name}, '
          'dht: ${_dht.routingTableSize} nodes)');
    } catch (e) {
      _taskHandle?.markError(e);
      LogService().log('P2P detect/scan failed: $e');
    }
  }

  void _onPeerFound((Uint8List infoHash, PeerInfo peer) event) {
    final (infoHash, peer) = event;
    _addDiscoveredPeer(peer);
  }

  /// Scan the DHT for devices on the geogram global topic and our npub topic.
  Future<void> _scanForOwnDevices() async {
    if (!_dht.isRunning) return;

    // Check locally cached peers first (fast, no network)
    final cachedGlobal = _dht.getCachedPeers(_geogramHash);
    for (final peer in cachedGlobal) {
      _addDiscoveredPeer(peer);
    }
    if (_npubHash != null) {
      final cachedNpub = _dht.getCachedPeers(_npubHash!);
      for (final peer in cachedNpub) {
        _addDiscoveredPeer(peer);
      }
    }

    // Then do a network lookup (heavy but deferred)
    final globalPeers = await _dht.getPeers(_geogramHash);
    for (final peer in globalPeers) {
      _addDiscoveredPeer(peer);
    }
    await Future.delayed(const Duration(milliseconds: 200));

    if (_npubHash != null && _dht.isRunning) {
      final npubPeers = await _dht.getPeers(_npubHash!);
      for (final peer in npubPeers) {
        _addDiscoveredPeer(peer);
      }
    }
  }

  /// Set of peers we already tried to probe (avoid repeated HTTP calls).
  final Set<String> _probedPeers = {};

  /// Add a DHT-discovered peer to Devices UI.
  void _addDiscoveredPeer(PeerInfo peer) {
    final myPort = AppArgs().port;
    // Skip self
    if (peer.ip == _capability.publicIp && peer.port == myPort) return;
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

  /// Probe a DHT peer via HTTP to get its identity, then register in Devices UI.
  /// Only registers peers whose identity can be confirmed.
  Future<void> _registerDhtPeer(PeerInfo peer) async {
    final peerUrl = 'http://${peer.ip}:${peer.port}';
    final myCallsign = ProfileService().getProfile().callsign;

    try {
      final response = await http.get(Uri.parse('$peerUrl/api/status'))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) return;

      final data = json.decode(response.body) as Map<String, dynamic>;
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
      // HTTP probe failed (peer behind NAT) — don't show unidentified peers
      LogService().log('P2P: peer ${peer.ip}:${peer.port} not reachable via HTTP');
    }
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

  /// Save discovered peers to disk for fast restart.
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

  /// Load cached discovered peers from disk and re-probe them.
  Future<void> _loadAndProbeCachedPeers() async {
    try {
      final storage = AppService().profileStorage;
      if (storage == null) return;
      final data = await storage.readJson(_kPeerCachePath);
      if (data == null) return;

      final peers = data['peers'] as List<dynamic>? ?? [];
      for (final entry in peers) {
        if (entry is! Map<String, dynamic>) continue;
        final ip = entry['ip'] as String?;
        final port = entry['port'] as int?;
        if (ip == null || port == null) continue;
        _addDiscoveredPeer(PeerInfo(ip: ip, port: port));
      }
      if (peers.isNotEmpty) {
        LogService().log('P2P: loaded ${peers.length} cached peer(s)');
      }
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
