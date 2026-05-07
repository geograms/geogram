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

import '../models/device_source.dart';
import '../services/app_args.dart';
import '../services/config_service.dart';
import '../services/devices_service.dart';
import '../services/log_service.dart';
import '../services/profile_service.dart';
import '../services/app_service.dart';
import '../services/profile_storage.dart';
import '../services/storage_config.dart';
import '../tracker/models/tracker_proximity_track.dart';
import '../util/task_monitor_helpers.dart';
import '../connection/connection_manager.dart';
import '../connection/transports/dht_transport.dart';
import 'dht_node.dart';
import 'dht_topics.dart';
import 'k_bucket.dart';
import 'node_capability.dart';

const String _kNodeCachePath = 'p2p/dht_cache.json';
const String _kNodeIdPath = 'p2p/node_id.bin';
const String _kPeerCachePath = 'p2p/peer_cache.json';
const String _kTaskId = 'p2p_discovery.dht';
const Duration _kKnownPeerProbeInterval = Duration(seconds: 30);
const Duration _kDesktopKnownPeerProbeInterval = Duration(minutes: 3);
const Duration _kDiscoveryRefreshInterval = Duration(minutes: 5);
const Duration _kDesktopDiscoveryRefreshInterval = Duration(minutes: 10);
const Duration _kInitialDiscoverySweepDelay = Duration(seconds: 5);
const Duration _kDesktopInitialDiscoverySweepDelay = Duration(seconds: 20);
const Duration _kKnownPeerPostStartupDelay = Duration(seconds: 30);
const Duration _kDesktopKnownPeerPostStartupDelay = Duration(minutes: 2);
const int _kKnownPeerProbeBatchSize = 3;
const Duration _kFailedDhtCandidateTtl = Duration(seconds: 20);
const Duration _kKnownPeerCandidateCacheTtl = Duration(minutes: 5);
const Duration _kKnownPeerTargetCacheTtl = Duration(minutes: 2);
const int _kKnownPeerTargetLimit = 12;
const int _kKnownPeerRecentContactFallbackLimit = 8;
const int _kKnownPeerPunchAttempts = 5;
const Duration _kKnownPeerPunchTimeout = Duration(milliseconds: 1200);
const Duration _kKnownPeerPunchSpacing = Duration(milliseconds: 200);
const Duration _kPreferredKnownPeerTtl = Duration(minutes: 3);
const List<Duration> _kKnownPeerWarmupProbeDelays = <Duration>[
  Duration.zero,
  Duration(seconds: 10),
  Duration(seconds: 20),
];
const List<Duration> _kDesktopKnownPeerWarmupProbeDelays = <Duration>[
  Duration(seconds: 45),
];
const String _kPairRendezvousTopicPrefix = 'geogram:rendezvous:v1:';

class _KnownPeerTarget {
  final String callsign;
  final String npub;
  final DateTime? lastSeen;
  final bool needsBootstrap;
  final bool hasReachableEndpoint;

  const _KnownPeerTarget({
    required this.callsign,
    required this.npub,
    this.lastSeen,
    this.needsBootstrap = false,
    this.hasReachableEndpoint = false,
  });
}

class _CachedKnownPeerCandidates {
  final List<PeerInfo> peers;
  final DateTime updatedAt;

  const _CachedKnownPeerCandidates({
    required this.peers,
    required this.updatedAt,
  });
}

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
  Timer? _knownPeerProbeTimer;

  bool _running = false;
  bool _knownPeerProbeInFlight = false;
  bool _publicHttpReachable = false;
  String? _publicHttpUrl;
  bool get isRunning => _running;
  bool get publicHttpReachable => _publicHttpReachable;
  String? get publicHttpUrl => _publicHttpUrl;
  int _dhtPort = 0;
  int get dhtPort => _dhtPort;
  int get dhtPeerCount => _dht?.routingTableSize ?? 0;

  /// True when the BT-DHT-v2 §6.7 blocked-detector reports no responses
  /// after bootstrap. Cleared once the DHT receives any datagram.
  bool _dhtBlocked = false;
  bool get isDhtBlocked => _dhtBlocked;
  NodeType get nodeType => _capability?.type ?? NodeType.unknown;
  String? get publicIp => _capability?.publicIp;
  int? get publicPort => _capability?.publicPort;
  int get directConnectionCount => 0;

  final Set<PeerInfo> discoveredPeers = {};
  final _peersController = StreamController<List<PeerInfo>>.broadcast();
  Stream<List<PeerInfo>> get onDiscoveredPeersChanged =>
      _peersController.stream;
  final _signalingController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onSignalingMessage =>
      _signalingController.stream;
  final Set<String> _probedPeers = {};
  final Set<String> _selfRendezvousPeers = {};
  final Map<String, DateTime> _failedDhtCandidates = {};
  final Map<String, Completer<List<PeerInfo>>> _findCompleters = {};
  final Map<String, _CachedKnownPeerCandidates> _knownPeerCandidateCache = {};
  List<_KnownPeerTarget>? _knownPeerTargetsCache;
  DateTime? _knownPeerTargetsCacheTime;
  String? _preferredKnownPeerCallsign;
  DateTime? _preferredKnownPeerExpiresAt;

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
    _phase1_startNode(localPort, profile.npub);
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

        // BT-DHT-v2 §6.7: surface blocked-DHT networks. The spec proposed
        // a NOSTR-presence fallback here, but per user direction we use no
        // NOSTR servers — just record the state for status reporting.
        _dht!.onDhtBlocked.listen((blocked) {
          _dhtBlocked = blocked;
        });

        // Set geogram identity on the DHT node for custom queries
        final profile = ProfileService().getProfile();
        _dht!.geogramCallsign = profile.callsign;
        _dht!.geogramNpub = profile.npub;
        _dht!.geogramDeviceId = ConfigService().deviceId;
        _dht!.geogramPlatform = Platform.operatingSystem;
        _dht!.geogramHttpPort = AppArgs().port;
        _dht!.geogramCanRelay = AppArgs().port > 0;
        _dht!.geogramRelayHttpPort = AppArgs().port;

        // Handle geogram peer discoveries (from queries AND responses)
        _dht!.onGeogramPeer = _handleGeogramPeer;
        _dht!.onGeogramSignal = _handleGeogramSignal;

        // Give DhtTransport a reference to the DHT node for rendezvous refreshes.
        try {
          final cm = ConnectionManager();
          if (cm.isInitialized) {
            final dt = cm.getTransport('dht') as DhtTransport?;
            if (dt != null) dt.dhtNode = _dht;
          }
        } catch (_) {}

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
        // Arm the §6.7 detector before bootstrap so any UDP response
        // arriving during bootstrap clears the flag immediately.
        _dht!.scheduleBlockedDetector();
        await _dht!.bootstrap(cachedNodes: cached);
        LogService().log(
          'P2P: bootstrap done (${_dht!.routingTableSize} nodes)',
        );
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
        final relayHashes = _relayTopics();
        final peerHashes = _peerTopics(npub);

        // Announce with implied_port=1 (set in dht_node.dart). The DHT
        // node stores the UDP source port (NAT-mapped external port),
        // not the declared port. This means get_peers returns the actual
        // reachable address through NAT. The declared port value doesn't
        // matter but we pass the local DHT port for consistency.
        final dhtPort = _dht!.localPort;
        for (final h in relayHashes) {
          await _announceTopic(h, dhtPort);
        }
        for (final h in peerHashes) {
          await _announceTopic(h, dhtPort);
        }
        _dht!.startPeriodicAnnounce(light: _useLightDhtLookups);
        LogService().log(
          'P2P: announced on DHT '
          '(${_useLightDhtLookups ? "light, " : ""}'
          'topics=${relayHashes.length + peerHashes.length}, '
          'local: $dhtPort, http: $port)',
        );
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
        await _refreshPublicHttpAnnounce();

        _taskHandle?.markIdle();
        LogService().log(
          'P2P service started '
          '(type: ${_capability!.type.name}, dht: ${_dht!.routingTableSize} nodes)',
        );
        _startKnownPeerProbeLoop();
        _scheduleKnownPeerWarmupProbes();
        Timer(_initialDiscoverySweepDelay, () {
          if (_dht == null || !_dht!.isRunning) return;
          unawaited(_runDiscoveryPeerSweep());
        });

        // After 30s: fresh peer scan + probe known devices
        // (gives the other device time to announce)
        Timer(_postStartupKnownPeerRefreshDelay, () async {
          if (_dht == null || !_dht!.isRunning) return;
          await _runDiscoveryPeerSweep(includeKnownPeerProbe: true);
        });

        // Periodic refresh — fresh getPeers to discover new peers
        _refreshTimer = Timer.periodic(_backgroundDiscoveryRefreshInterval, (
          _,
        ) async {
          if (_dht == null || !_dht!.isRunning) return;
          await _runDiscoveryPeerSweep(
            refreshCapability: true,
            includeKnownPeerProbe: true,
          );
        });
      } catch (e) {
        _taskHandle?.markError(e);
        LogService().log('P2P: detect failed: $e');
      }
    });
  }

  // ─── Stop ─────────────────────────────────────────────────────

  Future<void> stop() async {
    _refreshTimer?.cancel();
    _knownPeerProbeTimer?.cancel();
    if (_dht != null && _dht!.isRunning) {
      final nodes = _dht!.getNodesForCache();
      await _saveCachedNodes(
        nodes
            .map((n) => {'id': _toHex(n.nodeId), 'ip': n.ip, 'port': n.port})
            .toList(),
      );
      await _dht!.stop();
      _dht!.dispose();
    }
    try {
      final cm = ConnectionManager();
      if (cm.isInitialized) {
        final dt = cm.getTransport('dht') as DhtTransport?;
        if (dt != null) dt.dhtNode = null;
      }
    } catch (_) {}
    await _saveDiscoveredPeers();
    _dht = null;
    _capability = null;
    _running = false;
    _knownPeerProbeInFlight = false;
    _publicHttpReachable = false;
    _publicHttpUrl = null;
    _knownPeerTargetsCache = null;
    _knownPeerTargetsCacheTime = null;
    _preferredKnownPeerCallsign = null;
    _preferredKnownPeerExpiresAt = null;
    _taskHandle?.dispose();
    _taskHandle = null;
    LogService().log('P2P service stopped');
  }

  // ─── Public API ───────────────────────────────────────────────

  /// Find devices for a user. Checks cache first (instant).
  /// Only does a full iterative lookup if cache is empty and caller awaits.
  /// The iterative lookup WILL block the main thread for 10-30s.
  Future<List<PeerInfo>> findDevicesForUser(String npub) async {
    if (_dht == null || !_dht!.isRunning) return [];
    final hashes = _peerTopics(npub);
    // Check cache first (instant, no blocking) across all topic variants.
    final cached = <PeerInfo>[];
    for (final h in hashes) {
      cached.addAll(_dht!.getCachedPeers(h));
    }
    if (cached.isNotEmpty) return _dedupePeers(cached);
    // Full iterative lookup (blocks — only used by debug API).
    final fresh = <PeerInfo>[];
    for (final h in hashes) {
      fresh.addAll(await _dht!.getPeers(h));
    }
    return _dedupePeers(fresh);
  }

  Future<List<PeerInfo>> findDevicesForUserLight(String npub) async {
    if (_dht == null || !_dht!.isRunning) return [];
    final hashes = _peerTopics(npub);
    final fresh = <PeerInfo>[];
    for (final h in hashes) {
      fresh.addAll(await _dht!.getPeersLight(h, includeCached: false));
    }
    if (fresh.isNotEmpty) return _dedupePeers(fresh);
    final cached = <PeerInfo>[];
    for (final h in hashes) {
      cached.addAll(_dht!.getCachedPeers(h));
    }
    return _dedupePeers(cached);
  }

  List<PeerInfo> _dedupePeers(List<PeerInfo> peers) {
    final seen = <String>{};
    final out = <PeerInfo>[];
    for (final p in peers) {
      final key = '${p.ip}:${p.port}';
      if (seen.add(key)) out.add(p);
    }
    return out;
  }

  Future<Map<String, dynamic>?> sendGeogramQuery(String ip, int port) async {
    if (_dht == null || !_dht!.isRunning) return null;
    return _dht!.sendGeogramQuery(ip, port);
  }

  Future<Map<String, dynamic>?> sendGeogramPunch(String ip, int port) async {
    if (_dht == null || !_dht!.isRunning) return null;
    return _sendGeogramPunchBurst(PeerInfo(ip: ip, port: port));
  }

  Future<void> runKnownPeerProbeNow() async {
    await _runKnownPeerProbe();
  }

  Future<List<Map<String, dynamic>>> getKnownPeerTargetsDebug() async {
    final targets = await _loadKnownPeerTargets(DevicesService());
    return targets
        .map(
          (target) => {
            'callsign': target.callsign,
            'npub': target.npub,
            'needs_bootstrap': target.needsBootstrap,
            'has_reachable_endpoint': target.hasReachableEndpoint,
            'last_seen': target.lastSeen?.toIso8601String(),
            'cached_candidates': _getCachedKnownPeerCandidates(
              target,
            ).map((peer) => {'ip': peer.ip, 'port': peer.port}).toList(),
          },
        )
        .toList();
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
      'public_http_reachable': _publicHttpReachable,
      'public_http_url': _publicHttpUrl,
      'recent_external_ports': _dht?.recentExternalPorts ?? const <int>[],
      'dht_nodes': _dht?.routingTableSize ?? 0,
      'stored_peers': _dht?.storedPeerCount ?? 0,
      'direct_connections': 0,
      'connections': {'connections': 0, 'peers': []},
      'capability': {
        'node_type': nt.name,
        'public_ip': ip,
        'public_port': pp,
        'public_http_reachable': _publicHttpReachable,
        'public_http_url': _publicHttpUrl,
        'recent_external_ports': _dht?.recentExternalPorts ?? const <int>[],
        'can_hole_punch': nt == NodeType.typeA || nt == NodeType.typeB,
      },
    };
  }

  Future<void> _announceTopic(
    Uint8List infoHash,
    int port, {
    bool persist = true,
    bool impliedPort = true,
  }) async {
    if (_dht == null || !_dht!.isRunning) return;

    if (_useLightDhtLookups) {
      await _dht!.announceLight(
        infoHash,
        port,
        persist: persist,
        impliedPort: impliedPort,
      );
      return;
    }

    await _dht!.announce(
      infoHash,
      port,
      persist: persist,
      impliedPort: impliedPort,
    );
  }

  /// BT-DHT-v2 §6.4 RELAY_TOPIC, dual with the legacy `SHA1("geogram")`
  /// hash during the migration window (see `kEnableLegacyTopics`).
  List<Uint8List> _relayTopics() => [
        DhtTopics.relayTopic(),
        if (kEnableLegacyTopics) DhtTopics.legacyGeogramHash(),
      ];

  /// BT-DHT-v2 §6.4 PEER_TOPIC, dual with the legacy `SHA1(npub_string)`
  /// hash during the migration window. Decodes bech32 npub to bytes; if the
  /// input isn't valid bech32, falls back to legacy-only.
  List<Uint8List> _peerTopics(String npub) {
    final out = <Uint8List>[];
    try {
      out.add(DhtTopics.peerTopicFromNpub(npub));
    } catch (_) {
      // Malformed npub — only legacy hash is computable.
    }
    if (kEnableLegacyTopics) out.add(DhtTopics.legacyNpubHash(npub));
    return out;
  }

  Future<void> _refreshPublicHttpAnnounce() async {
    _publicHttpReachable = false;
    _publicHttpUrl = null;

    final ip = _capability?.publicIp?.trim();
    final httpPort = AppArgs().port;
    if (ip == null || ip.isEmpty || httpPort <= 0 || _dht == null) {
      return;
    }

    final profile = ProfileService().getProfile();
    final status = await _fetchDirectHttpStatus(
      PeerInfo(ip: ip, port: httpPort),
    );
    if (status == null) {
      LogService().log(
        'P2P: public HTTP self-check failed for http://$ip:$httpPort',
      );
      return;
    }

    final callsign = (status['callsign'] as String?)?.trim().toUpperCase();
    final npub = (status['npub'] as String?)?.trim();
    if (callsign != profile.callsign.toUpperCase() || npub != profile.npub) {
      LogService().log(
        'P2P: public HTTP self-check mismatch at http://$ip:$httpPort '
        '(callsign=${callsign ?? "unknown"}, npub=${npub ?? "missing"})',
      );
      return;
    }

    _publicHttpReachable = true;
    _publicHttpUrl = 'http://$ip:$httpPort';
    LogService().log('P2P: public HTTP endpoint verified at $_publicHttpUrl');

    for (final h in _relayTopics()) {
      await _announceTopic(h, httpPort, impliedPort: false);
    }
    for (final h in _peerTopics(profile.npub)) {
      await _announceTopic(h, httpPort, impliedPort: false);
    }
  }

  Future<Map<String, dynamic>?> _fetchDirectHttpStatus(PeerInfo peer) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final request = await client.getUrl(
        Uri.parse('http://${peer.ip}:${peer.port}/api/status'),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 4),
      );
      if (response.statusCode != HttpStatus.ok) {
        return null;
      }

      final body = await response.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> _probeDirectHttpPeer(
    PeerInfo peer, {
    String? expectedCallsign,
    String? expectedNpub,
  }) async {
    final status = await _fetchDirectHttpStatus(peer);
    if (status == null) return false;

    final callsign = (status['callsign'] as String?)?.trim().toUpperCase();
    final npub = (status['npub'] as String?)?.trim();
    final platform = (status['platform'] as String?)?.trim();
    final httpPort = (status['port'] as int?) ?? peer.port;

    if (callsign == null || callsign.isEmpty || npub == null || npub.isEmpty) {
      return false;
    }
    if (expectedCallsign != null &&
        expectedCallsign.isNotEmpty &&
        callsign != expectedCallsign.toUpperCase()) {
      return false;
    }
    if (expectedNpub != null &&
        expectedNpub.isNotEmpty &&
        npub != expectedNpub) {
      return false;
    }

    _handleGeogramPeer(
      callsign,
      npub,
      status['device_id'] as String?,
      platform,
      httpPort,
      status['can_relay'] as bool? ?? false,
      status['relay_http_port'] as int?,
      peer.ip,
      0,
    );
    return true;
  }

  Set<int> _knownSelfEndpointPorts() {
    final ports = <int>{};

    final httpPort = AppArgs().port;
    if (_publicHttpReachable && httpPort > 0) {
      ports.add(httpPort);
    }

    final dhtPort = _dht?.localPort ?? _dhtPort;
    if (dhtPort != null && dhtPort > 0) {
      ports.add(dhtPort);
    }

    final capabilityPort = _capability?.publicPort;
    if (capabilityPort != null && capabilityPort > 0) {
      ports.add(capabilityPort);
    }

    final externalPort = _dht?.externalPort;
    if (externalPort != null && externalPort > 0) {
      ports.add(externalPort);
    }

    final recentExternalPorts = _dht?.recentExternalPorts ?? const <int>[];
    for (final port in recentExternalPorts) {
      if (port > 0) {
        ports.add(port);
      }
    }

    return ports;
  }

  bool _isSelfEndpoint(String ip, int port) {
    if (ip.isEmpty || port <= 0) {
      return false;
    }

    if ((ip == '127.0.0.1' || ip == '0.0.0.0') && port == AppArgs().port) {
      return true;
    }

    final myPublicIp = _capability?.publicIp?.trim();
    if (myPublicIp == null || myPublicIp.isEmpty || ip != myPublicIp) {
      return false;
    }

    return _knownSelfEndpointPorts().contains(port);
  }

  // ─── Peer Management ──────────────────────────────────────────

  Future<void> _probeExistingDiscoveredPeers() async {
    if (_dht == null || !_dht!.isRunning) return;
    for (final peer in discoveredPeers.toList()) {
      _addDiscoveredPeer(peer);
    }
  }

  void _addDiscoveredPeer(PeerInfo peer) {
    final key = '${peer.ip}:${peer.port}';
    if (_selfRendezvousPeers.contains(key)) {
      return;
    }

    if (_isSelfEndpoint(peer.ip, peer.port)) {
      return;
    }

    final added = discoveredPeers.add(peer);
    if (added) {
      _peersController.add(discoveredPeers.toList());
    }

    if (_dht != null && _dht!.isRunning && !_probedPeers.contains(key)) {
      _probedPeers.add(key);
      _registerDhtPeer(peer);
    }
  }

  Future<void> _registerDhtPeer(PeerInfo peer) async {
    LogService().log('P2P: discovered DHT peer ${peer.ip}:${peer.port}');

    if (await _probeDirectHttpPeer(peer)) {
      LogService().log(
        'P2P: ${peer.ip}:${peer.port} accepted direct HTTP probe from DHT discovery',
      );
      return;
    }

    // Otherwise treat it as a DHT rendezvous socket and resolve the peer's
    // real HTTP endpoint through the geogram identity exchange.
    LogService().log(
      'P2P: ${peer.ip}:${peer.port} did not answer HTTP, sending geogram query',
    );
    if (_dht != null && _dht!.isRunning) {
      await _dht!.sendGeogramQuery(peer.ip, peer.port);
    }
  }

  /// Called when a geogram peer is discovered (via query or response).
  /// Registers the peer in DevicesService with full identity info.
  void _handleGeogramPeer(
    String callsign,
    String? npub,
    String? deviceId,
    String? platform,
    int httpPort,
    bool canRelay,
    int? relayHttpPort,
    String ip,
    int udpPort,
  ) {
    final myCallsign = ProfileService().getProfile().callsign;
    final resolvedRelayPort = relayHttpPort ?? httpPort;
    if (callsign.toUpperCase() == myCallsign.toUpperCase()) {
      final selfKey = '$ip:$udpPort';
      _selfRendezvousPeers.add(selfKey);
      _probedPeers.remove(selfKey);
      discoveredPeers.remove(PeerInfo(ip: ip, port: udpPort));
      LogService().log('P2P: ignoring self geogram peer at $selfKey');
      return;
    }

    if (_isSelfEndpoint(ip, udpPort) ||
        _isSelfEndpoint(ip, httpPort) ||
        (resolvedRelayPort > 0 && _isSelfEndpoint(ip, resolvedRelayPort))) {
      LogService().log(
        'P2P: ignoring conflicting geogram peer $callsign at '
        '$ip (http:$httpPort, udp:$udpPort, relay:$resolvedRelayPort) '
        'because it resolves to this node\'s public endpoint',
      );
      return;
    }

    LogService().log(
      'P2P: geogram peer $callsign at $ip '
      '(http:$httpPort, udp:$udpPort${canRelay ? ", relay:${relayHttpPort ?? httpPort}" : ""})',
    );

    final relayUrl = canRelay && resolvedRelayPort > 0
        ? 'http://$ip:$resolvedRelayPort'
        : null;

    final devService = DevicesService();
    devService.addOrUpdateDevice(
      RemoteDevice(
        callsign: callsign.toUpperCase(),
        name: callsign,
        npub: npub,
        url: 'http://$ip:$httpPort',
        isOnline: true,
        hasCachedData: false,
        apps: [],
        connectionMethods: ['internet'],
        source: DeviceSourceType.direct,
        lastSeen: DateTime.now(),
        platform: platform,
        deviceId: deviceId,
        udpIp: ip,
        udpPort: udpPort,
        canRelay: canRelay,
        relayHttpPort: canRelay ? resolvedRelayPort : null,
        relayUrl: relayUrl,
      ),
    );
    devService.syncDeviceToConnectionManager(callsign.toUpperCase());
    LogService().log(
      'P2P: registered geogram peer $callsign (http:$httpPort, udp:$udpPort)',
    );
  }

  void _handleGeogramSignal(
    Map<String, dynamic> signal,
    String ip,
    int udpPort,
  ) {
    final fromCallsign = signal['from_callsign'] as String?;
    if (fromCallsign == null || fromCallsign.isEmpty) return;

    final normalizedCallsign = fromCallsign.toUpperCase();
    final myCallsign = ProfileService().getProfile().callsign.toUpperCase();
    if (normalizedCallsign == myCallsign) return;

    final devService = DevicesService();
    final existing = devService.getDevice(normalizedCallsign);
    if (existing != null) {
      if (!existing.connectionMethods.contains('internet')) {
        existing.connectionMethods = [
          ...existing.connectionMethods,
          'internet',
        ];
      }
      existing.udpIp = ip;
      existing.udpPort = udpPort;
      existing.isOnline = true;
      existing.lastSeen = DateTime.now();
      devService.addOrUpdateDevice(existing);
      devService.syncDeviceToConnectionManager(normalizedCallsign);
    } else {
      devService.addOrUpdateDevice(
        RemoteDevice(
          callsign: normalizedCallsign,
          name: normalizedCallsign,
          isOnline: true,
          hasCachedData: false,
          apps: [],
          connectionMethods: const ['internet'],
          source: DeviceSourceType.direct,
          lastSeen: DateTime.now(),
          udpIp: ip,
          udpPort: udpPort,
        ),
      );
    }

    if (!_signalingController.isClosed) {
      _signalingController.add(signal);
    }
    LogService().log(
      'P2P: received geogram signal ${signal['type'] ?? 'unknown'} from $normalizedCallsign at $ip:$udpPort',
    );
  }

  bool canSignalPeer(String callsign) {
    if (_dht == null || !_dht!.isRunning) return false;
    final device = DevicesService().getDevice(callsign.toUpperCase());
    return device?.udpIp != null &&
        device?.udpPort != null &&
        device!.udpPort! > 0;
  }

  Future<bool> sendSignalingMessage(
    String callsign,
    Map<String, dynamic> signal,
  ) async {
    if (_dht == null || !_dht!.isRunning) return false;

    final normalizedCallsign = callsign.toUpperCase();
    final device = DevicesService().getDevice(normalizedCallsign);
    final udpIp = device?.udpIp;
    final udpPort = device?.udpPort;
    if (udpIp == null || udpPort == null || udpPort <= 0) {
      LogService().log(
        'P2P: no DHT signaling endpoint for $normalizedCallsign',
      );
      return false;
    }

    final payload = <String, dynamic>{
      ...signal,
      'to_callsign': normalizedCallsign,
    };
    final sent = await _dht!.sendGeogramSignal(udpIp, udpPort, payload);
    LogService().log(
      'P2P: ${sent ? "sent" : "failed"} geogram signal ${signal['type'] ?? 'unknown'} to $normalizedCallsign at $udpIp:$udpPort',
    );
    return sent;
  }

  int _npubProbeIndex = 0;

  /// Probe ONE known device per call by doing a full iterative DHT lookup
  /// on its npub hash. Rotates through known devices across calls.
  /// Each iterative lookup grows the Dart VM heap (~50MB), and the VM
  /// never shrinks it, so we limit to one lookup per cycle.
  Future<void> _probeKnownDevicesByNpub() async {
    if (_dht == null || !_dht!.isRunning) return;

    final devService = DevicesService();
    final targets = await _loadKnownPeerTargets(devService);
    if (targets.isEmpty) return;

    final target = _selectKnownPeerTarget(targets, devService);

    LogService().log(
      'P2P: probing known peer ${target.callsign} via DHT npub lookup',
    );

    await _announcePairRendezvous(target);

    final cachedCandidates = _selectRendezvousCandidates(
      target,
      _getCachedKnownPeerCandidates(target),
      devService,
    );
    if (cachedCandidates.isNotEmpty) {
      LogService().log(
        'P2P: trying ${cachedCandidates.length} cached DHT candidate(s) for ${target.callsign} before refresh lookup',
      );
      if (await _verifyKnownPeerCandidates(target, cachedCandidates)) {
        return;
      }
    }

    final pairPeers = await _lookupPairRendezvousPeers(target);
    final pairCandidates = _selectRendezvousCandidates(
      target,
      pairPeers,
      devService,
    );
    if (pairCandidates.isNotEmpty) {
      LogService().log(
        'P2P: pair rendezvous lookup for ${target.callsign} returned ${pairPeers.length} peer(s), trying ${pairCandidates.length} candidate(s)',
      );
      if (await _verifyKnownPeerCandidates(target, pairCandidates)) {
        return;
      }
    }

    // BT-DHT-v2 §6.4: lookup against PEER_TOPIC(npub) and the legacy
    // SHA1(npub_string) hash for the dual-announce window.
    final peerHashes = _peerTopics(target.npub);
    final freshPeers = <PeerInfo>[];
    for (final h in peerHashes) {
      freshPeers.addAll(
          await _lookupDiscoveryPeers(h, includeCached: false));
    }
    var peers = _dedupePeers(freshPeers);
    if (peers.isEmpty) {
      final cached = <PeerInfo>[];
      for (final h in peerHashes) {
        cached.addAll(_dht!.getCachedPeers(h));
      }
      peers = _dedupePeers(cached);
    }

    final combinedPeers = _mergeUniquePeers(pairPeers, peers);
    final candidates = _selectRendezvousCandidates(
      target,
      combinedPeers,
      devService,
    );
    _updateKnownPeerCandidateCache(target, candidates);
    if (candidates.isEmpty) {
      _rememberPreferredKnownPeer(target);
      LogService().log(
        'P2P: npub lookup for ${target.callsign} returned no usable rendezvous candidates',
      );
      return;
    }

    LogService().log(
      'P2P: npub lookup for ${target.callsign} returned ${peers.length} peer(s), trying ${candidates.length} candidate(s)',
    );

    final shouldTryLookupCandidates =
        cachedCandidates.isEmpty ||
        !_samePeerSets(cachedCandidates, candidates);
    if (shouldTryLookupCandidates &&
        await _verifyKnownPeerCandidates(target, candidates)) {
      return;
    }

    _rememberPreferredKnownPeer(target);
    LogService().log(
      'P2P: no verified DHT rendezvous responded for ${target.callsign}',
    );
  }

  Future<bool> _verifyKnownPeerCandidates(
    _KnownPeerTarget target,
    List<PeerInfo> candidates,
  ) async {
    for (var i = 0; i < candidates.length; i += _kKnownPeerProbeBatchSize) {
      final batch = candidates.skip(i).take(_kKnownPeerProbeBatchSize).toList();
      final verified = await Future.wait(
        batch.map((peer) => _tryVerifyKnownPeerCandidate(target, peer)),
      );
      if (verified.any((ok) => ok)) {
        return true;
      }
    }

    return false;
  }

  List<PeerInfo> _selectRendezvousCandidates(
    _KnownPeerTarget target,
    List<PeerInfo> peers,
    DevicesService devService,
  ) {
    _purgeExpiredFailedDhtCandidates();

    final preferred = <PeerInfo>[];
    final sameIp = <PeerInfo>[];
    final unprobed = <PeerInfo>[];
    final remaining = <PeerInfo>[];
    final seen = <String>{};

    void addCandidate(
      PeerInfo? peer, {
      required bool isPreferred,
      required String? preferredIp,
      required int? preferredPort,
    }) {
      if (peer == null) return;
      if (peer.port <= 1) return;

      final key = '${peer.ip}:${peer.port}';
      if (peer.ip.isEmpty ||
          peer.ip == '0.0.0.0' ||
          peer.ip.startsWith('127.') ||
          _isSelfEndpoint(peer.ip, peer.port) ||
          _selfRendezvousPeers.contains(key) ||
          _isKnownPeerCandidateCoolingDown(target, peer) ||
          !seen.add(key)) {
        return;
      }

      if (isPreferred) {
        preferred.add(peer);
      } else if (preferredIp != null && peer.ip == preferredIp) {
        sameIp.add(peer);
      } else if (!_probedPeers.contains(key)) {
        unprobed.add(peer);
      } else {
        remaining.add(peer);
      }
    }

    final existingDevice = devService.getDevice(target.callsign);
    final preferredIp = existingDevice?.udpIp;
    final preferredPort = existingDevice?.udpPort;
    if (existingDevice?.udpIp != null && existingDevice?.udpPort != null) {
      addCandidate(
        PeerInfo(ip: existingDevice!.udpIp!, port: existingDevice.udpPort!),
        isPreferred: true,
        preferredIp: preferredIp,
        preferredPort: preferredPort,
      );
    }

    for (final peer in peers) {
      addCandidate(
        peer,
        isPreferred:
            preferredIp != null &&
            preferredPort != null &&
            peer.ip == preferredIp &&
            peer.port == preferredPort,
        preferredIp: preferredIp,
        preferredPort: preferredPort,
      );
    }

    return [...preferred, ...sameIp, ...unprobed, ...remaining];
  }

  Future<bool> _tryVerifyKnownPeerCandidate(
    _KnownPeerTarget target,
    PeerInfo peer,
  ) async {
    if (_dht == null || !_dht!.isRunning) return false;

    LogService().log(
      'P2P: npub probe trying ${target.callsign} at ${peer.ip}:${peer.port}',
    );

    if (await _probeDirectHttpPeer(
      peer,
      expectedCallsign: target.callsign,
      expectedNpub: target.npub,
    )) {
      _failedDhtCandidates.remove(_failedDhtCandidateKey(target, peer));
      _clearPreferredKnownPeer(target.callsign);
      LogService().log(
        'P2P: verified direct HTTP endpoint for ${target.callsign} at ${peer.ip}:${peer.port}',
      );
      return true;
    }

    final response = await _sendGeogramPunchBurst(peer);

    if (response == null) {
      _rememberFailedDhtCandidate(target, peer);
      return false;
    }

    final responseNpub = (response['npub'] as String?)?.trim();
    final responseCallsign = (response['callsign'] as String?)
        ?.trim()
        .toUpperCase();
    final matchesNpub =
        responseNpub != null &&
        responseNpub.isNotEmpty &&
        responseNpub == target.npub;
    final matchesCallsign =
        responseCallsign != null && responseCallsign == target.callsign;

    if (!matchesNpub && !matchesCallsign) {
      _rememberFailedDhtCandidate(target, peer);
      LogService().log(
        'P2P: DHT candidate ${peer.ip}:${peer.port} answered with ${responseCallsign ?? "unknown"} for ${target.callsign}, ignoring',
      );
      return false;
    }

    _failedDhtCandidates.remove(_failedDhtCandidateKey(target, peer));
    _clearPreferredKnownPeer(target.callsign);
    final devService = DevicesService();
    final device = devService.getDevice(target.callsign);
    if (device != null) {
      _updateDhtRendezvous(devService, device, peer);
    }
    LogService().log(
      'P2P: verified DHT rendezvous for ${target.callsign} at ${peer.ip}:${peer.port}',
    );
    return true;
  }

  void _startKnownPeerProbeLoop() {
    _knownPeerProbeTimer?.cancel();
    void scheduleNext() {
      final now = DateTime.now();
      final intervalMs = _knownPeerProbeInterval.inMilliseconds;
      final nextMs =
          ((now.millisecondsSinceEpoch ~/ intervalMs) + 1) * intervalMs;
      final delay = Duration(milliseconds: nextMs - now.millisecondsSinceEpoch);
      _knownPeerProbeTimer = Timer(delay, () {
        unawaited(_runKnownPeerProbe());
        scheduleNext();
      });
    }

    scheduleNext();
  }

  void _scheduleKnownPeerWarmupProbes() {
    for (final delay in _knownPeerWarmupProbeDelays) {
      Timer(delay, () {
        if (!_running || _dht == null || !_dht!.isRunning) return;
        unawaited(_runKnownPeerProbe());
      });
    }
  }

  bool get _isDesktopPlatform =>
      Platform.isLinux || Platform.isMacOS || Platform.isWindows;

  Duration get _knownPeerProbeInterval => _isDesktopPlatform
      ? _kDesktopKnownPeerProbeInterval
      : _kKnownPeerProbeInterval;

  Duration get _backgroundDiscoveryRefreshInterval => _isDesktopPlatform
      ? _kDesktopDiscoveryRefreshInterval
      : _kDiscoveryRefreshInterval;

  Duration get _initialDiscoverySweepDelay => _isDesktopPlatform
      ? _kDesktopInitialDiscoverySweepDelay
      : _kInitialDiscoverySweepDelay;

  Duration get _postStartupKnownPeerRefreshDelay => _isDesktopPlatform
      ? _kDesktopKnownPeerPostStartupDelay
      : _kKnownPeerPostStartupDelay;

  List<Duration> get _knownPeerWarmupProbeDelays => _isDesktopPlatform
      ? _kDesktopKnownPeerWarmupProbeDelays
      : _kKnownPeerWarmupProbeDelays;

  bool get _useLightDhtLookups => Platform.isAndroid || _isDesktopPlatform;

  Future<List<PeerInfo>> _lookupDiscoveryPeers(
    Uint8List infoHash, {
    required bool includeCached,
  }) async {
    if (_dht == null || !_dht!.isRunning) return const [];
    if (_useLightDhtLookups) {
      return _dht!.getPeersLight(infoHash, includeCached: includeCached);
    }
    return _dht!.getPeers(infoHash, includeCached: includeCached);
  }

  Future<void> _runDiscoveryPeerSweep({
    bool refreshCapability = false,
    bool includeKnownPeerProbe = false,
  }) async {
    if (_dht == null || !_dht!.isRunning) {
      return;
    }

    try {
      if (refreshCapability && _capability != null) {
        await _capability!.detectFromDht(_dht!);
      }
      await _probeExistingDiscoveredPeers();
      // BT-DHT-v2 §6.4 RELAY_TOPIC + legacy fallback during dual-announce.
      for (final h in _relayTopics()) {
        final peers =
            await _lookupDiscoveryPeers(h, includeCached: false);
        for (final peer in peers) {
          _addDiscoveredPeer(peer);
        }
      }
      if (includeKnownPeerProbe) {
        await _runKnownPeerProbe();
      }
    } catch (e) {
      LogService().log('P2P: discovery sweep failed: $e');
    }
  }

  Future<void> _runKnownPeerProbe() async {
    if (_knownPeerProbeInFlight) return;
    _knownPeerProbeInFlight = true;
    try {
      await _probeKnownDevicesByNpub();
    } catch (e) {
      LogService().log('P2P: known-peer DHT probe failed: $e');
    } finally {
      _knownPeerProbeInFlight = false;
    }
  }

  String _failedDhtCandidateKey(_KnownPeerTarget target, PeerInfo peer) =>
      '${target.callsign}|${peer.ip}:${peer.port}';

  bool _isKnownPeerCandidateCoolingDown(
    _KnownPeerTarget target,
    PeerInfo peer,
  ) {
    final failedAt = _failedDhtCandidates[_failedDhtCandidateKey(target, peer)];
    if (failedAt == null) return false;
    return DateTime.now().difference(failedAt) < _kFailedDhtCandidateTtl;
  }

  void _rememberFailedDhtCandidate(_KnownPeerTarget target, PeerInfo peer) {
    _failedDhtCandidates[_failedDhtCandidateKey(target, peer)] = DateTime.now();
  }

  void _purgeExpiredFailedDhtCandidates() {
    final now = DateTime.now();
    _failedDhtCandidates.removeWhere(
      (_, failedAt) => now.difference(failedAt) >= _kFailedDhtCandidateTtl,
    );
    _knownPeerCandidateCache.removeWhere(
      (_, cached) =>
          now.difference(cached.updatedAt) >= _kKnownPeerCandidateCacheTtl,
    );
  }

  Future<List<_KnownPeerTarget>> _loadKnownPeerTargets(
    DevicesService devService,
  ) async {
    final now = DateTime.now();
    if (_knownPeerTargetsCache != null &&
        _knownPeerTargetsCacheTime != null &&
        now.difference(_knownPeerTargetsCacheTime!) <
            _kKnownPeerTargetCacheTtl) {
      return List<_KnownPeerTarget>.from(_knownPeerTargetsCache!);
    }

    final profile = ProfileService().getProfile();
    final myCallsign = profile.callsign.toUpperCase();
    final myNpub = profile.npub;
    final targets = <String, _KnownPeerTarget>{};

    void addTarget(String callsign, String npub, {DateTime? lastSeen}) {
      final normalizedCallsign = callsign.trim().toUpperCase();
      final trimmedNpub = npub.trim();
      if (normalizedCallsign.isEmpty || trimmedNpub.isEmpty) return;
      if (normalizedCallsign == myCallsign) return;
      if (myNpub.isNotEmpty && trimmedNpub == myNpub) return;

      final existingDevice = devService.getDevice(normalizedCallsign);
      final hasReachableEndpoint =
          existingDevice != null &&
          (existingDevice.hasLocalConnection ||
              (existingDevice.connectionMethods.contains('internet') &&
                  existingDevice.url != null &&
                  existingDevice.url!.isNotEmpty));
      final needsBootstrap =
          existingDevice == null ||
          (!hasReachableEndpoint &&
              (existingDevice.udpIp == null ||
                  existingDevice.udpIp!.isEmpty ||
                  existingDevice.udpPort == null ||
                  existingDevice.udpPort! <= 0));

      final previous = targets[normalizedCallsign];
      final candidate = _KnownPeerTarget(
        callsign: normalizedCallsign,
        npub: trimmedNpub,
        lastSeen: lastSeen ?? existingDevice?.lastSeen,
        needsBootstrap: needsBootstrap,
        hasReachableEndpoint: hasReachableEndpoint,
      );

      if (previous == null) {
        targets[normalizedCallsign] = candidate;
        return;
      }

      final mergedLastSeen = _latestTime(previous.lastSeen, candidate.lastSeen);
      targets[normalizedCallsign] = _KnownPeerTarget(
        callsign: normalizedCallsign,
        npub: previous.npub.isNotEmpty ? previous.npub : candidate.npub,
        lastSeen: mergedLastSeen,
        needsBootstrap: previous.needsBootstrap || candidate.needsBootstrap,
        hasReachableEndpoint:
            previous.hasReachableEndpoint || candidate.hasReachableEndpoint,
      );
    }

    for (final device in devService.getAllDevices()) {
      final npub = device.npub;
      if (npub != null && npub.isNotEmpty) {
        addTarget(device.callsign, npub, lastSeen: device.lastSeen);
      }
    }

    try {
      final storage = AppService().profileStorage;
      if (storage != null) {
        final contactIndex = await _indexContactFiles(storage);

        final datesToCheck = <DateTime>[
          DateTime.now(),
          DateTime.now().subtract(const Duration(days: 7)),
        ];
        for (final date in datesToCheck) {
          final weekDir =
              'tracker/proximity/${date.year}/W${getWeekNumber(date).toString().padLeft(2, '0')}';
          if (!await storage.exists(weekDir)) continue;

          final entries = await storage.listDirectory(weekDir);
          for (final entry in entries) {
            if (entry.isDirectory || !entry.name.endsWith('-track.json')) {
              continue;
            }

            final json = await storage.readJson('$weekDir/${entry.name}');
            if (json == null) continue;

            try {
              final track = ProximityTrack.fromJson(json);
              if (track.type != ProximityTargetType.device) continue;
              final callsign = track.callsign;
              final npub = track.npub;
              if (callsign == null || npub == null) continue;
              final trackerLastSeen = track.weekSummary.lastDetection != null
                  ? DateTime.tryParse(track.weekSummary.lastDetection!)
                  : null;
              addTarget(callsign, npub, lastSeen: trackerLastSeen);
            } catch (_) {
              // Skip malformed tracker files and keep probing with the rest.
            }
          }
        }

        await _loadDirectMessageDhtTargets(
          addTarget,
          profileStorage: storage,
          contactIndex: contactIndex,
        );

        if (targets.isEmpty) {
          await _loadRecentContactDhtTargets(
            storage,
            addTarget,
            contactIndex: contactIndex,
          );
        }
      }
    } catch (e) {
      LogService().log(
        'P2P: failed to load tracker DHT targets from profile storage: $e',
      );
    }

    final sortedTargets = targets.values.toList()
      ..sort((a, b) {
        if (a.needsBootstrap != b.needsBootstrap) {
          return a.needsBootstrap ? -1 : 1;
        }
        if (a.hasReachableEndpoint != b.hasReachableEndpoint) {
          return a.hasReachableEndpoint ? 1 : -1;
        }
        final byLastSeen = _compareDescendingTime(a.lastSeen, b.lastSeen);
        if (byLastSeen != 0) return byLastSeen;
        return a.callsign.compareTo(b.callsign);
      });

    final limitedTargets = sortedTargets.take(_kKnownPeerTargetLimit).toList();
    _knownPeerTargetsCache = limitedTargets;
    _knownPeerTargetsCacheTime = now;
    return List<_KnownPeerTarget>.from(limitedTargets);
  }

  _KnownPeerTarget _selectKnownPeerTarget(
    List<_KnownPeerTarget> targets,
    DevicesService devService,
  ) {
    final now = DateTime.now();
    final preferredCallsign = _preferredKnownPeerCallsign;
    if (preferredCallsign != null &&
        _preferredKnownPeerExpiresAt != null &&
        now.isBefore(_preferredKnownPeerExpiresAt!)) {
      for (final target in targets) {
        if (target.callsign == preferredCallsign) {
          return target;
        }
      }
    }

    _preferredKnownPeerCallsign = null;
    _preferredKnownPeerExpiresAt = null;

    for (final target in targets) {
      final device = devService.getDevice(target.callsign);
      final hasDhtEndpoint =
          device != null &&
          device.udpIp != null &&
          device.udpIp!.isNotEmpty &&
          device.udpPort != null &&
          device.udpPort! > 0;
      if (target.needsBootstrap ||
          !target.hasReachableEndpoint ||
          !hasDhtEndpoint) {
        return target;
      }
    }

    _npubProbeIndex = _npubProbeIndex % targets.length;
    final target = targets[_npubProbeIndex];
    _npubProbeIndex++;
    return target;
  }

  Future<Map<String, StorageEntry>> _indexContactFiles(
    ProfileStorage storage,
  ) async {
    final indexed = <String, StorageEntry>{};
    if (!await storage.directoryExists('contacts')) {
      return indexed;
    }

    final contactsStorage = ScopedProfileStorage(storage, 'contacts');
    final entries = await contactsStorage.listDirectory('', recursive: true);
    for (final entry in entries) {
      if (entry.isDirectory ||
          entry.name == 'group.txt' ||
          entry.name == 'fast.json' ||
          entry.name.startsWith('.') ||
          !entry.name.endsWith('.txt')) {
        continue;
      }
      final callsign = entry.name
          .substring(0, entry.name.length - 4)
          .toUpperCase();
      final existing = indexed[callsign];
      if (existing == null ||
          _compareDescendingTime(entry.modified, existing.modified) < 0) {
        indexed[callsign] = entry;
      }
    }

    return indexed;
  }

  Future<void> _loadDirectMessageDhtTargets(
    void Function(String callsign, String npub, {DateTime? lastSeen})
    addTarget, {
    ProfileStorage? profileStorage,
    Map<String, StorageEntry>? contactIndex,
  }) async {
    final config = StorageConfig();
    if (!config.isInitialized) {
      return;
    }

    final chatDir = Directory(config.chatDir);
    if (!await chatDir.exists()) {
      return;
    }

    final contactsStorage =
        profileStorage != null &&
            await profileStorage.directoryExists('contacts')
        ? ScopedProfileStorage(profileStorage, 'contacts')
        : null;

    await for (final entity in chatDir.list(followLinks: false)) {
      if (entity is! Directory) continue;

      final segments = entity.uri.pathSegments
          .where((segment) => segment.isNotEmpty)
          .toList();
      final callsign = segments.isEmpty ? null : segments.last.toUpperCase();
      if (callsign == null ||
          callsign.isEmpty ||
          callsign == 'MAIN' ||
          callsign == 'EXTRA') {
        continue;
      }

      final configFile = File('${entity.path}/config.json');
      if (!await configFile.exists()) {
        continue;
      }

      try {
        final decoded = jsonDecode(await configFile.readAsString());
        if (decoded is! Map<String, dynamic>) {
          continue;
        }

        final type = decoded['type'] as String?;
        final otherNpub = decoded['otherNpub'] as String?;
        if (type != 'direct') {
          continue;
        }

        final configModified = await configFile.lastModified();
        if (otherNpub != null &&
            otherNpub.isNotEmpty &&
            otherNpub.startsWith('npub1')) {
          addTarget(callsign, otherNpub, lastSeen: configModified);
          continue;
        }

        if (contactsStorage == null || contactIndex == null) {
          continue;
        }

        final contactEntry = contactIndex[callsign];
        if (contactEntry == null) continue;
        final contactIdentity = await _readContactDhtIdentity(
          contactsStorage,
          contactEntry.path,
        );
        final contactNpub = contactIdentity.$2;
        if (contactNpub == null ||
            contactNpub.isEmpty ||
            !contactNpub.startsWith('npub1')) {
          continue;
        }

        addTarget(
          callsign,
          contactNpub,
          lastSeen: _latestTime(configModified, contactEntry.modified),
        );
      } catch (_) {
        // Ignore malformed DM config files.
      }
    }
  }

  void _rememberPreferredKnownPeer(_KnownPeerTarget target) {
    _preferredKnownPeerCallsign = target.callsign;
    _preferredKnownPeerExpiresAt = DateTime.now().add(_kPreferredKnownPeerTtl);
  }

  void _clearPreferredKnownPeer(String callsign) {
    if (_preferredKnownPeerCallsign == callsign) {
      _preferredKnownPeerCallsign = null;
      _preferredKnownPeerExpiresAt = null;
    }
  }

  Uint8List? _pairRendezvousHash(_KnownPeerTarget target) {
    final myNpub = ProfileService().getProfile().npub.trim();
    final targetNpub = target.npub.trim();
    if (myNpub.isEmpty || targetNpub.isEmpty) {
      return null;
    }

    final sorted = [myNpub, targetNpub]..sort();
    final topic = '$_kPairRendezvousTopicPrefix${sorted[0]}:${sorted[1]}';
    return sha1Hash(topic);
  }

  Future<void> _announcePairRendezvous(_KnownPeerTarget target) async {
    final infoHash = _pairRendezvousHash(target);
    if (infoHash == null || _dht == null || !_dht!.isRunning) return;

    final dhtPort = _dht!.localPort;
    if (_useLightDhtLookups) {
      await _dht!.announceLight(infoHash, dhtPort, persist: false);
    } else {
      await _dht!.announce(infoHash, dhtPort, persist: false);
    }

    final explicitPorts = <int>{};
    if (_publicHttpReachable &&
        AppArgs().port > 0 &&
        AppArgs().port != dhtPort) {
      explicitPorts.add(AppArgs().port);
    }
    final capabilityPort = _capability?.publicPort;
    if (capabilityPort != null &&
        capabilityPort > 1 &&
        capabilityPort != dhtPort) {
      explicitPorts.add(capabilityPort);
    }
    for (final observedPort in _dht!.recentExternalPorts) {
      if (observedPort > 1 && observedPort != dhtPort) {
        explicitPorts.add(observedPort);
      }
    }

    for (final explicitPort in explicitPorts.take(4)) {
      if (_useLightDhtLookups) {
        await _dht!.announceLight(
          infoHash,
          explicitPort,
          persist: false,
          impliedPort: false,
        );
      } else {
        await _dht!.announce(
          infoHash,
          explicitPort,
          persist: false,
          impliedPort: false,
        );
      }
    }
  }

  Future<List<PeerInfo>> _lookupPairRendezvousPeers(
    _KnownPeerTarget target,
  ) async {
    final infoHash = _pairRendezvousHash(target);
    if (infoHash == null || _dht == null || !_dht!.isRunning) {
      return const [];
    }

    var peers = await _lookupDiscoveryPeers(infoHash, includeCached: false);
    if (peers.isEmpty) {
      peers = _dht!.getCachedPeers(infoHash);
    }
    return peers;
  }

  Future<void> _loadRecentContactDhtTargets(
    ProfileStorage storage,
    void Function(String callsign, String npub, {DateTime? lastSeen})
    addTarget, {
    Map<String, StorageEntry>? contactIndex,
  }) async {
    if (contactIndex == null || contactIndex.isEmpty) return;

    final contactsStorage = ScopedProfileStorage(storage, 'contacts');
    final recentEntries = contactIndex.values.toList()
      ..sort((a, b) => _compareDescendingTime(a.modified, b.modified));

    for (final entry in recentEntries.take(
      _kKnownPeerRecentContactFallbackLimit,
    )) {
      final identity = await _readContactDhtIdentity(
        contactsStorage,
        entry.path,
      );
      final callsign = identity.$1;
      final npub = identity.$2;
      if (callsign == null ||
          callsign.isEmpty ||
          npub == null ||
          npub.isEmpty ||
          !npub.startsWith('npub1')) {
        continue;
      }

      addTarget(callsign, npub, lastSeen: entry.modified);
    }
  }

  Future<(String?, String?)> _readContactDhtIdentity(
    ScopedProfileStorage contactsStorage,
    String relativePath,
  ) async {
    final content = await contactsStorage.readString(relativePath);
    if (content == null || content.isEmpty) {
      return (null, null);
    }

    String? callsign;
    String? npub;
    for (final rawLine in content.split('\n')) {
      final line = rawLine.trim();
      if (line.startsWith('CALLSIGN:')) {
        callsign = line.substring('CALLSIGN:'.length).trim();
      } else if (line.startsWith('NPUB:')) {
        npub = line.substring('NPUB:'.length).trim();
      }

      if (callsign != null && npub != null) {
        break;
      }
    }

    return (callsign, npub);
  }

  DateTime? _latestTime(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }

  int _compareDescendingTime(DateTime? a, DateTime? b) {
    if (a != null && b != null) {
      return b.compareTo(a);
    }
    if (a != null) return -1;
    if (b != null) return 1;
    return 0;
  }

  void _updateDhtRendezvous(
    DevicesService devService,
    RemoteDevice device,
    PeerInfo peer,
  ) {
    devService.updateDhtRendezvous(
      device.callsign,
      udpIp: peer.ip,
      udpPort: peer.port,
    );
    LogService().log(
      'P2P: updated DHT rendezvous for ${device.callsign} at ${peer.ip}:${peer.port}; awaiting geogram identity',
    );
  }

  List<PeerInfo> _getCachedKnownPeerCandidates(_KnownPeerTarget target) {
    _purgeExpiredFailedDhtCandidates();
    final cached = _knownPeerCandidateCache[target.callsign];
    if (cached == null) return const [];
    return cached.peers;
  }

  void _updateKnownPeerCandidateCache(
    _KnownPeerTarget target,
    List<PeerInfo> candidates,
  ) {
    if (candidates.isEmpty) return;
    _knownPeerCandidateCache[target.callsign] = _CachedKnownPeerCandidates(
      peers: candidates.take(8).toList(),
      updatedAt: DateTime.now(),
    );
  }

  bool _samePeerSets(List<PeerInfo> a, List<PeerInfo> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    final aKeys = a.map((peer) => '${peer.ip}:${peer.port}').toSet();
    final bKeys = b.map((peer) => '${peer.ip}:${peer.port}').toSet();
    return aKeys.length == bKeys.length && aKeys.containsAll(bKeys);
  }

  List<PeerInfo> _mergeUniquePeers(List<PeerInfo> a, List<PeerInfo> b) {
    final merged = <PeerInfo>[];
    final seen = <String>{};

    void addAll(List<PeerInfo> peers) {
      for (final peer in peers) {
        final key = '${peer.ip}:${peer.port}';
        if (seen.add(key)) {
          merged.add(peer);
        }
      }
    }

    addAll(a);
    addAll(b);
    return merged;
  }

  Future<Map<String, dynamic>?> _sendGeogramPunchBurst(PeerInfo peer) async {
    if (_dht == null || !_dht!.isRunning) return null;

    final responseCompleter = Completer<Map<String, dynamic>?>();
    var pending = _kKnownPeerPunchAttempts;

    for (var attempt = 0; attempt < _kKnownPeerPunchAttempts; attempt++) {
      unawaited(() async {
        if (attempt > 0) {
          await Future.delayed(
            Duration(
              milliseconds: _kKnownPeerPunchSpacing.inMilliseconds * attempt,
            ),
          );
        }

        final response = await _dht!.sendGeogramQuery(
          peer.ip,
          peer.port,
          timeout: _kKnownPeerPunchTimeout,
        );
        if (response != null && !responseCompleter.isCompleted) {
          responseCompleter.complete(response);
          return;
        }

        pending--;
        if (pending == 0 && !responseCompleter.isCompleted) {
          responseCompleter.complete(null);
        }
      }());
    }

    return responseCompleter.future;
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
      final list = discoveredPeers
          .map((p) => {'ip': p.ip, 'port': p.port})
          .toList();
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
