/// P2P Discovery Service — runs DHT on main isolate with Timer-based scheduling.
///
/// Each DHT operation (bootstrap, announce, get_peers) is a single async
/// call that yields to the event loop between query rounds via
/// Future.delayed. No Isolate.spawn (causes OOM on Android from double heap).
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../models/device_source.dart';
import '../services/app_args.dart';
import '../services/config_service.dart';
import '../services/devices_service.dart';
import '../services/log_service.dart';
import '../services/profile_service.dart';
import '../services/app_service.dart';
import '../tracker/models/tracker_proximity_track.dart';
import '../util/task_monitor_helpers.dart';
import '../connection/connection_manager.dart';
import '../connection/transports/dht_transport.dart';
import 'dht_node.dart';
import 'k_bucket.dart';
import 'node_capability.dart';

const String _kNodeCachePath = 'p2p/dht_cache.json';
const String _kNodeIdPath = 'p2p/node_id.bin';
const String _kPeerCachePath = 'p2p/peer_cache.json';
const String _kTaskId = 'p2p_discovery.dht';
const Duration _kKnownPeerProbeInterval = Duration(seconds: 45);
const int _kKnownPeerProbeBatchSize = 3;
const Duration _kFailedDhtCandidateTtl = Duration(minutes: 10);

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

        // Set geogram identity on the DHT node for custom queries
        final profile = ProfileService().getProfile();
        _dht!.geogramCallsign = profile.callsign;
        _dht!.geogramNpub = profile.npub;
        _dht!.geogramDeviceId = ConfigService().deviceId;
        _dht!.geogramPlatform = Platform.operatingSystem;
        _dht!.geogramHttpPort = AppArgs().port;

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
        final geogramHash = sha1Hash('geogram');
        final npubHash = sha1Hash(npub);

        // Announce with implied_port=1 (set in dht_node.dart). The DHT
        // node stores the UDP source port (NAT-mapped external port),
        // not the declared port. This means get_peers returns the actual
        // reachable address through NAT. The declared port value doesn't
        // matter but we pass the local DHT port for consistency.
        final dhtPort = _dht!.localPort;
        await _dht!.announce(geogramHash, dhtPort);
        await _dht!.announce(npubHash, dhtPort);
        _dht!.startPeriodicAnnounce();
        LogService().log(
          'P2P: announced on DHT (implied_port=1, local: $dhtPort, http: $port)',
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
        await _probeExistingDiscoveredPeers();

        final peers = await _dht!.getPeers(
          sha1Hash('geogram'),
          includeCached: false,
        );
        for (final p in peers) {
          _addDiscoveredPeer(p);
        }

        _taskHandle?.markIdle();
        LogService().log(
          'P2P service started '
          '(type: ${_capability!.type.name}, dht: ${_dht!.routingTableSize} nodes)',
        );
        _startKnownPeerProbeLoop();

        // After 30s: fresh peer scan + probe known devices
        // (gives the other device time to announce)
        Timer(const Duration(seconds: 30), () async {
          if (_dht == null || !_dht!.isRunning) return;
          final p = await _dht!.getPeers(
            sha1Hash('geogram'),
            includeCached: false,
          );
          for (final peer in p) {
            _addDiscoveredPeer(peer);
          }
          await _runKnownPeerProbe();
        });

        // Periodic refresh — fresh getPeers to discover new peers
        _refreshTimer = Timer.periodic(const Duration(minutes: 5), (_) async {
          if (_dht == null || !_dht!.isRunning) return;
          await _capability!.detectFromDht(_dht!);
          final p = await _dht!.getPeers(
            sha1Hash('geogram'),
            includeCached: false,
          );
          for (final peer in p) {
            _addDiscoveredPeer(peer);
          }
          await _runKnownPeerProbe();
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
    final hash = sha1Hash(npub);
    // Check cache first (instant, no blocking)
    final cached = _dht!.getCachedPeers(hash);
    if (cached.isNotEmpty) return cached;
    // Full iterative lookup (blocks — only used by debug API)
    return _dht!.getPeers(hash);
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

    final myPort = AppArgs().port;
    if ((peer.ip == '127.0.0.1' || peer.ip == '0.0.0.0') &&
        peer.port == myPort) {
      return;
    }

    final myDhtPort = _dht?.localPort ?? _dhtPort;
    final myPublicIp = _capability?.publicIp;
    final myPublicPort = _capability?.publicPort;
    if (myPublicIp != null &&
        peer.ip == myPublicIp &&
        (peer.port == myDhtPort || peer.port == myPublicPort)) {
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
    // The geogram topic announces the peer's DHT rendezvous socket, not an HTTP
    // API port. Resolve the real HTTP endpoint through the geogram identity
    // exchange before trying direct API traffic.
    LogService().log(
      'P2P: discovered DHT peer ${peer.ip}:${peer.port}, sending geogram query',
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
    String ip,
    int udpPort,
  ) {
    final myCallsign = ProfileService().getProfile().callsign;
    if (callsign.toUpperCase() == myCallsign.toUpperCase()) {
      final selfKey = '$ip:$udpPort';
      _selfRendezvousPeers.add(selfKey);
      _probedPeers.remove(selfKey);
      discoveredPeers.remove(PeerInfo(ip: ip, port: udpPort));
      LogService().log('P2P: ignoring self geogram peer at $selfKey');
      return;
    }

    LogService().log(
      'P2P: geogram peer $callsign at $ip (http:$httpPort, udp:$udpPort)',
    );

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

    // Rotate through devices — one per call
    _npubProbeIndex = _npubProbeIndex % targets.length;
    final target = targets[_npubProbeIndex];
    _npubProbeIndex++;

    LogService().log(
      'P2P: probing known peer ${target.callsign} via DHT npub lookup',
    );

    var peers = await _dht!.getPeers(
      sha1Hash(target.npub),
      includeCached: false,
    );
    if (peers.isEmpty) {
      peers = _dht!.getCachedPeers(sha1Hash(target.npub));
    }
    final candidates = _selectRendezvousCandidates(target, peers, devService);
    if (candidates.isEmpty) {
      LogService().log(
        'P2P: npub lookup for ${target.callsign} returned no usable rendezvous candidates',
      );
      return;
    }

    LogService().log(
      'P2P: npub lookup for ${target.callsign} returned ${peers.length} peer(s), trying ${candidates.length} candidate(s)',
    );

    for (var i = 0; i < candidates.length; i += _kKnownPeerProbeBatchSize) {
      final batch = candidates.skip(i).take(_kKnownPeerProbeBatchSize).toList();
      final verified = await Future.wait(
        batch.map((peer) => _tryVerifyKnownPeerCandidate(target, peer)),
      );
      if (verified.any((ok) => ok)) {
        return;
      }
    }

    LogService().log(
      'P2P: no verified DHT rendezvous responded for ${target.callsign}',
    );
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
      final myPublicIp = _capability?.publicIp;
      final myPublicPort = _capability?.publicPort;
      final myDhtPort = _dht?.localPort ?? _dhtPort;
      if (peer.ip.isEmpty ||
          peer.ip == '0.0.0.0' ||
          peer.ip.startsWith('127.') ||
          (myPublicIp != null &&
              peer.ip == myPublicIp &&
              (peer.port == myPublicPort || peer.port == myDhtPort)) ||
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

    final response = await _dht!.sendGeogramQuery(peer.ip, peer.port);
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
    _knownPeerProbeTimer = Timer.periodic(_kKnownPeerProbeInterval, (_) {
      unawaited(_runKnownPeerProbe());
    });
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
  }

  Future<List<_KnownPeerTarget>> _loadKnownPeerTargets(
    DevicesService devService,
  ) async {
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
      }
    } catch (e) {
      LogService().log(
        'P2P: failed to load tracker DHT targets from profile storage: $e',
      );
    }

    return targets.values.toList()..sort((a, b) {
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
