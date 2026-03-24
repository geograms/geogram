/// BEP 5 Mainline DHT Node.
///
/// Implements the BitTorrent DHT protocol for peer discovery:
/// - UDP transport with bencoded messages
/// - Kademlia routing with 160-bit XOR distance
/// - RPCs: ping, find_node, get_peers, announce_peer
/// - Token-based announce validation
/// - Topic-scoped peer storage (geogram global + per-npub)
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../services/log_service.dart';
import 'bencode.dart';
import 'k_bucket.dart';

/// Bootstrap DHT nodes (well-known public routers).
const List<(String host, int port)> kBootstrapNodes = [
  ('router.bittorrent.com', 6881),
  ('dht.transmissionbt.com', 6881),
  ('router.utorrent.com', 6881),
  ('dht.libtorrent.org', 25401),
  ('dht.aelitis.com', 6881),
];

/// How often to re-announce on DHT topics (minutes).
const int kReannounceMinutes = 25;

/// How often to refresh stale routing table entries (minutes).
const int kRefreshMinutes = 2;

/// Max peers to store per info_hash topic.
const int kMaxPeersPerTopic = 100;
const Duration kPeerRetention = Duration(hours: 1);

/// Transaction ID counter for DHT queries.
int _txIdCounter = 0;

/// Generate a 2-byte transaction ID.
Uint8List _nextTxId() {
  _txIdCounter = (_txIdCounter + 1) & 0xFFFF;
  return Uint8List.fromList([(_txIdCounter >> 8) & 0xFF, _txIdCounter & 0xFF]);
}

/// Compute SHA1 hash of a string, returning 20 bytes.
Uint8List sha1Hash(String input) {
  return Uint8List.fromList(sha1.convert(utf8.encode(input)).bytes);
}

/// Pending DHT query waiting for a response.
class _PendingQuery {
  final Uint8List txId;
  final String method;
  final Completer<Map<String, dynamic>?> completer;
  final DateTime sentAt;
  final Uint8List? infoHash; // For get_peers: the info_hash being queried

  _PendingQuery({
    required this.txId,
    required this.method,
    required this.completer,
    this.infoHash,
  }) : sentAt = DateTime.now();

  bool get isExpired =>
      DateTime.now().difference(sentAt) > const Duration(seconds: 10);
}

class _IncomingSignalBuffer {
  final int totalChunks;
  final Map<int, String> chunks = {};
  DateTime updatedAt = DateTime.now();

  _IncomingSignalBuffer({required this.totalChunks});

  bool get isComplete => chunks.length == totalChunks;

  String? assemble() {
    if (!isComplete) return null;
    final buffer = StringBuffer();
    for (var i = 0; i < totalChunks; i++) {
      final chunk = chunks[i];
      if (chunk == null) return null;
      buffer.write(chunk);
    }
    return buffer.toString();
  }
}

class _StoredPeer {
  final PeerInfo peer;
  DateTime lastSeen;
  int observations;
  bool announced;

  _StoredPeer({
    required this.peer,
    DateTime? lastSeen,
    this.observations = 1,
    this.announced = false,
  }) : lastSeen = lastSeen ?? DateTime.now();

  void touch({int additionalObservations = 1, bool fromAnnounce = false}) {
    lastSeen = DateTime.now();
    observations += additionalObservations;
    if (fromAnnounce) {
      announced = true;
    }
  }
}

/// Peer info returned by get_peers.
class PeerInfo {
  final String ip;
  final int port;

  const PeerInfo({required this.ip, required this.port});

  @override
  bool operator ==(Object other) =>
      other is PeerInfo && ip == other.ip && port == other.port;

  @override
  int get hashCode => ip.hashCode ^ port.hashCode;

  @override
  String toString() => 'PeerInfo($ip:$port)';
}

/// BEP 5 DHT Node.
class DhtNode {
  /// Our 20-byte node ID.
  late Uint8List nodeId;

  /// Kademlia routing table.
  late RoutingTable _routingTable;

  /// UDP socket.
  RawDatagramSocket? _socket;

  /// Local UDP port.
  int _localPort = 0;
  int get localPort => _localPort;

  /// Whether the node is running.
  bool _running = false;
  bool get isRunning => _running;

  /// Pending queries awaiting responses.
  final Map<String, _PendingQuery> _pendingQueries = {};

  /// In-progress chunked signaling payloads keyed by "ip:port:messageId".
  final Map<String, _IncomingSignalBuffer> _incomingSignalBuffers = {};

  /// Tokens we received from remote nodes (for our announces).
  /// Maps "ip:port" → token.
  final Map<String, Uint8List> _receivedTokens = {};

  /// Peer store: info_hash → "ip:port" → observed peer.
  final Map<String, Map<String, _StoredPeer>> _peerStore = {};

  /// Timers for periodic tasks.
  Timer? _reannounceTimer;
  Timer? _refreshTimer;
  Timer? _cleanupTimer;

  /// Topics we are announced on: info_hash (hex) → local port.
  final Map<String, int> _announcedTopics = {};

  /// Token secret for generating announce tokens (rotated periodically).
  late Uint8List _tokenSecret;
  late Uint8List _tokenSecretPrev;
  Timer? _tokenRotationTimer;

  /// Stream controller for DHT events.
  final _peerFoundController =
      StreamController<(Uint8List infoHash, PeerInfo peer)>.broadcast();

  /// Stream of newly discovered peers.
  Stream<(Uint8List infoHash, PeerInfo peer)> get onPeerFound =>
      _peerFoundController.stream;

  /// Node count in routing table.
  int get routingTableSize => _routingTable.nodeCount;

  /// Number of peers stored.
  int get storedPeerCount {
    _cleanupExpiredPeers();
    var count = 0;
    for (final peers in _peerStore.values) {
      count += peers.length;
    }
    return count;
  }

  /// Initialize the DHT node.
  ///
  /// [persistedNodeId] — 20-byte node ID from previous session (null = generate new).
  /// [port] — UDP port to bind (0 = OS-assigned).
  Future<void> start({Uint8List? persistedNodeId, int port = 0}) async {
    if (_running) return;

    // Initialize node ID
    if (persistedNodeId != null && persistedNodeId.length == 20) {
      nodeId = persistedNodeId;
    } else {
      nodeId = _generateNodeId();
    }

    _routingTable = RoutingTable(localId: nodeId);

    // Initialize token secrets
    _tokenSecret = _generateTokenSecret();
    _tokenSecretPrev = _generateTokenSecret();

    // Bind UDP socket
    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
    _localPort = _socket!.port;

    _socket!.listen(
      _handleDatagram,
      onError: (e) {
        // Non-fatal: send errors (e.g., IPv6 target on IPv4 socket) arrive here
        // but the socket stays open.
        LogService().log('DHT socket error: $e');
      },
      onDone: () {
        LogService().log('DHT socket closed');
        _running = false;
      },
    );

    _running = true;

    // Start periodic cleanup of expired queries
    _cleanupTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _cleanupExpiredQueries();
      _cleanupExpiredPeers();
    });

    // Rotate token secret every 5 minutes
    _tokenRotationTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      _tokenSecretPrev = _tokenSecret;
      _tokenSecret = _generateTokenSecret();
    });

    LogService().log(
      'DHT node started on port $_localPort '
      '(id: ${_hexPrefix(nodeId)})',
    );
  }

  /// Bootstrap the DHT by contacting well-known nodes.
  ///
  /// Also accepts [cachedNodes] from a previous session.
  /// Non-blocking: yields to the event loop between phases.
  Future<void> bootstrap({List<DhtContact>? cachedNodes}) async {
    if (!_running) return;

    // Phase 1: Insert cached nodes and ping a few (not all — avoid flood)
    if (cachedNodes != null) {
      for (final node in cachedNodes) {
        _routingTable.insertNode(node);
      }
      // Ping only first 8 to verify they're alive
      for (final node in cachedNodes.take(8)) {
        _sendPing(node.ip, node.port);
      }
      await Future.delayed(const Duration(milliseconds: 50));
    }

    // Phase 2: Resolve bootstrap nodes one at a time with short timeouts
    for (final (host, port) in kBootstrapNodes) {
      if (!_running) return;
      try {
        final addresses = await InternetAddress.lookup(
          host,
        ).timeout(const Duration(seconds: 3), onTimeout: () => []);
        final ipv4 = addresses
            .where((a) => a.type == InternetAddressType.IPv4)
            .toList();
        if (ipv4.isNotEmpty) {
          _sendFindNode(ipv4.first.address, port, nodeId);
        }
      } catch (e) {
        LogService().log('DHT bootstrap: failed to resolve $host: $e');
      }
      await Future.delayed(const Duration(milliseconds: 50));
    }

    // Phase 3: Wait for responses
    await Future.delayed(const Duration(seconds: 3));
    if (!_running) return;

    if (_routingTable.nodeCount == 0) {
      // No responses — retry with longer wait
      LogService().log('DHT bootstrap: no responses, retrying...');
      for (final (host, port) in kBootstrapNodes) {
        if (!_running) return;
        try {
          final addresses = await InternetAddress.lookup(
            host,
          ).timeout(const Duration(seconds: 3), onTimeout: () => []);
          final ipv4 = addresses
              .where((a) => a.type == InternetAddressType.IPv4)
              .toList();
          if (ipv4.isNotEmpty) {
            _sendFindNode(ipv4.first.address, port, nodeId);
          }
        } catch (_) {}
      }
      await Future.delayed(const Duration(seconds: 5));
    }

    // Do ONE lightweight round to expand table without blocking for long
    if (_routingTable.nodeCount > 0) {
      final closest = _routingTable.findClosest(nodeId);
      final batch = closest.take(3).toList();
      if (batch.isNotEmpty) {
        final futures = batch.map((n) => _sendFindNode(n.ip, n.port, nodeId));
        await Future.wait(futures);
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }

    LogService().log(
      'DHT bootstrap complete: ${_routingTable.nodeCount} nodes',
    );
  }

  /// Announce this node on a topic (info_hash).
  ///
  /// Does a proper iterative get_peers first to find the K-closest nodes
  /// and collect their tokens, then announces to those specific nodes.
  Future<void> announce(Uint8List infoHash, int port) async {
    if (!_running) return;

    final hexHash = _toHex(infoHash);
    _announcedTopics[hexHash] = port;

    // Clear stale tokens before lookup to prevent unbounded growth
    _receivedTokens.clear();

    // Iterative get_peers finds K-closest nodes and collects tokens
    await _iterativeGetPeers(infoHash);

    // Announce to nodes that gave us tokens during the lookup
    var announced = 0;
    for (final entry in _receivedTokens.entries) {
      final parts = entry.key.split(':');
      if (parts.length == 2) {
        final ip = parts[0];
        final nodePort = int.tryParse(parts[1]);
        if (nodePort != null) {
          _sendAnnouncePeer(ip, nodePort, infoHash, port, entry.value);
          announced++;
        }
      }
    }

    LogService().log(
      'DHT announced on ${_hexPrefix(infoHash)} port $port '
      'to $announced nodes',
    );
  }

  /// Lightweight announce: send get_peers to closest routing table nodes ONE
  /// AT A TIME, then announce to those that respond with tokens. No iterative
  /// lookup — avoids the heap spike from processing hundreds of candidates.
  Future<void> announceLight(Uint8List infoHash, int port) async {
    if (!_running) return;

    final hexHash = _toHex(infoHash);
    _announcedTopics[hexHash] = port;
    _receivedTokens.clear();

    // Query closest routing table nodes sequentially (one at a time)
    final closest = _routingTable.findClosest(infoHash, count: 8);
    for (final node in closest) {
      if (!_running) return;
      final result = await _sendGetPeers(node.ip, node.port, infoHash);
      if (result != null) {
        // Process any peers found
        if (result.containsKey('values')) {
          try {
            final values = Bencode.asList(result['values']);
            for (final v in values) {
              final bytes = Bencode.asBytes(v);
              if (bytes.length == 6) {
                final (ip, peerPort) = DhtContact.parseCompactPeer(bytes);
                _recordPeer(infoHash, PeerInfo(ip: ip, port: peerPort));
              }
            }
          } catch (_) {}
        }
      }
    }

    // Announce to nodes that gave us tokens
    var announced = 0;
    for (final entry in _receivedTokens.entries) {
      final parts = entry.key.split(':');
      if (parts.length == 2) {
        final ip = parts[0];
        final nodePort = int.tryParse(parts[1]);
        if (nodePort != null) {
          _sendAnnouncePeer(ip, nodePort, infoHash, port, entry.value);
          announced++;
        }
      }
    }

    LogService().log(
      'DHT announced (light) on ${_hexPrefix(infoHash)} port $port '
      'to $announced nodes',
    );
  }

  /// Look up peers for an info_hash.
  ///
  /// By default returns peers found from both the local peer store and remote
  /// DHT nodes. Callers can set [includeCached] to false to force a fresh
  /// iterative lookup result without merging previously cached peers.
  /// Also available via [onPeerFound] stream.
  Future<List<PeerInfo>> getPeers(
    Uint8List infoHash, {
    bool includeCached = true,
  }) async {
    if (!_running) return [];
    final remotePeers = await _iterativeGetPeers(infoHash);
    if (!includeCached) {
      return remotePeers;
    }
    final merged = <PeerInfo>[];
    final seen = <String>{};

    void append(List<PeerInfo> peers) {
      for (final peer in peers) {
        final key = '${peer.ip}:${peer.port}';
        if (seen.add(key)) {
          merged.add(peer);
        }
      }
    }

    append(remotePeers);
    append(getCachedPeers(infoHash));
    return merged;
  }

  /// Start periodic re-announce on all topics.
  /// [light] uses announceLight (routing table only) to avoid heap spikes.
  void startPeriodicAnnounce({bool light = false}) {
    _reannounceTimer?.cancel();
    _reannounceTimer = Timer.periodic(
      const Duration(minutes: kReannounceMinutes),
      (_) {
        for (final entry in _announcedTopics.entries) {
          final infoHash = _fromHex(entry.key);
          if (light) {
            announceLight(infoHash, entry.value);
          } else {
            announce(infoHash, entry.value);
          }
        }
      },
    );

    // Also start routing table refresh
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(
      const Duration(minutes: kRefreshMinutes),
      (_) => _refreshRoutingTable(),
    );
  }

  /// Stop the DHT node.
  Future<void> stop() async {
    if (!_running) return;
    _running = false;

    _reannounceTimer?.cancel();
    _refreshTimer?.cancel();
    _cleanupTimer?.cancel();
    _tokenRotationTimer?.cancel();

    // Complete all pending queries
    for (final q in _pendingQueries.values) {
      if (!q.completer.isCompleted) {
        q.completer.complete(null);
      }
    }
    _pendingQueries.clear();

    _socket?.close();
    _socket = null;

    LogService().log('DHT node stopped');
  }

  /// Get nodes to cache for next session (best 30 from routing table).
  List<DhtContact> getNodesForCache() {
    final all = _routingTable.getAllNodes();
    // Sort by last seen (most recent first)
    all.sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    return all.take(30).toList();
  }

  /// Get the cached peers for a given info_hash.
  List<PeerInfo> getCachedPeers(Uint8List infoHash) {
    final key = _toHex(infoHash);
    final stored = _peerStore[key];
    if (stored == null || stored.isEmpty) return [];

    final now = DateTime.now();
    final peers =
        stored.values
            .where((entry) => now.difference(entry.lastSeen) < kPeerRetention)
            .toList()
          ..sort(_compareStoredPeers);
    return peers.map((entry) => entry.peer).toList();
  }

  // ─── UDP Message Handling ───────────────────────────────────────

  void _handleDatagram(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;

    final datagram = _socket?.receive();
    if (datagram == null) return;

    try {
      final msg = Bencode.decode(datagram.data);
      if (msg is! Map) return;
      final dict = Bencode.asMap(msg);
      final type = Bencode.asString(dict['y']);

      switch (type) {
        case 'q':
          _handleQuery(dict, datagram.address.address, datagram.port);
          break;
        case 'r':
          _handleResponse(dict, datagram.address.address, datagram.port);
          break;
        case 'e':
          _handleError(dict);
          break;
      }
    } catch (e) {
      // Silently ignore malformed messages
    }
  }

  void _handleQuery(Map<String, dynamic> msg, String fromIp, int fromPort) {
    final txId = Bencode.asBytes(msg['t']);
    final method = Bencode.asString(msg['q']);
    final args = Bencode.asMap(msg['a']);
    final senderId = Bencode.asBytes(args['id']);

    // Update routing table with querying node
    _routingTable.insertNode(
      DhtContact(
        nodeId: Uint8List.fromList(senderId),
        ip: fromIp,
        port: fromPort,
      ),
    );

    switch (method) {
      case 'ping':
        _respondPing(txId, fromIp, fromPort);
        break;
      case 'find_node':
        final target = Bencode.asBytes(args['target']);
        _respondFindNode(txId, Uint8List.fromList(target), fromIp, fromPort);
        break;
      case 'get_peers':
        final infoHash = Bencode.asBytes(args['info_hash']);
        _respondGetPeers(txId, Uint8List.fromList(infoHash), fromIp, fromPort);
        break;
      case 'announce_peer':
        _handleAnnouncePeer(args, txId, fromIp, fromPort);
        break;
      case 'geogram':
        _handleGeogramQuery(args, txId, fromIp, fromPort);
        break;
      case 'geogram_signal':
        _handleGeogramSignalQuery(args, txId, fromIp, fromPort);
        break;
      case 'geogram_signal_chunk':
        _handleGeogramSignalChunkQuery(args, txId, fromIp, fromPort);
        break;
    }
  }

  // ─── Geogram Custom DHT Messaging ──────────────────────────────

  /// Our identity fields for geogram queries (set by P2PService).
  String? geogramCallsign;
  String? geogramNpub;
  String? geogramDeviceId;
  String? geogramPlatform;
  int geogramHttpPort = 3456;

  /// Callback when a geogram query or response is received from a peer.
  void Function(
    String callsign,
    String? npub,
    String? deviceId,
    String? platform,
    int httpPort,
    String ip,
    int udpPort,
  )?
  onGeogramPeer;

  /// Callback when a geogram signaling message is received from a peer.
  void Function(Map<String, dynamic> signal, String ip, int udpPort)?
  onGeogramSignal;

  void _handleGeogramQuery(
    Map<String, dynamic> args,
    Uint8List txId,
    String fromIp,
    int fromPort,
  ) {
    // Extract peer identity from the query
    final peerCallsign = Bencode.asString(args['callsign']);
    final peerNpub = args.containsKey('npub')
        ? Bencode.asString(args['npub'])
        : null;
    final peerDeviceId = args.containsKey('device_id')
        ? Bencode.asString(args['device_id'])
        : null;
    final peerPlatform = args.containsKey('platform')
        ? Bencode.asString(args['platform'])
        : null;
    final peerHttpPort = args.containsKey('http_port')
        ? (args['http_port'] as int? ?? 3456)
        : 3456;

    LogService().log(
      'DHT: geogram query from $peerCallsign at $fromIp:$fromPort',
    );

    // Respond with our identity
    _sendMessage(
      {
        't': txId,
        'y': 'r',
        'r': {
          'id': nodeId,
          'callsign': geogramCallsign ?? '',
          'npub': geogramNpub ?? '',
          'device_id': geogramDeviceId ?? '',
          'platform': geogramPlatform ?? '',
          'http_port': geogramHttpPort,
        },
      },
      fromIp,
      fromPort,
    );

    // Notify P2PService about this peer
    if (peerCallsign.isNotEmpty) {
      onGeogramPeer?.call(
        peerCallsign,
        peerNpub,
        peerDeviceId,
        peerPlatform,
        peerHttpPort,
        fromIp,
        fromPort,
      );
    }
  }

  void _handleGeogramSignalQuery(
    Map<String, dynamic> args,
    Uint8List txId,
    String fromIp,
    int fromPort,
  ) {
    final signal = <String, dynamic>{};
    for (final entry in args.entries) {
      if (entry.key == 'id') continue;
      final normalized = _normalizeSignalValue(entry.value);
      if (normalized != null) {
        signal[entry.key] = normalized;
      }
    }

    _sendMessage(
      {
        't': txId,
        'y': 'r',
        'r': {'id': nodeId, 'ok': 1},
      },
      fromIp,
      fromPort,
    );

    final targetCallsign = signal['to_callsign'] as String?;
    final myCallsign = geogramCallsign;
    if (targetCallsign != null &&
        myCallsign != null &&
        targetCallsign.toUpperCase() != myCallsign.toUpperCase()) {
      LogService().log(
        'DHT: ignoring geogram signal for $targetCallsign from $fromIp:$fromPort',
      );
      return;
    }

    LogService().log(
      'DHT: geogram signal ${signal['type'] ?? 'unknown'} from $fromIp:$fromPort',
    );
    onGeogramSignal?.call(signal, fromIp, fromPort);
  }

  void _handleGeogramSignalChunkQuery(
    Map<String, dynamic> args,
    Uint8List txId,
    String fromIp,
    int fromPort,
  ) {
    final messageId = Bencode.asString(args['message_id']);
    final chunkIndex = Bencode.asInt(args['chunk_index']);
    final chunkTotal = Bencode.asInt(args['chunk_total']);
    final payload = Bencode.asString(args['payload']);

    _sendMessage(
      {
        't': txId,
        'y': 'r',
        'r': {'id': nodeId, 'ok': 1},
      },
      fromIp,
      fromPort,
    );

    final targetCallsign = args.containsKey('to_callsign')
        ? Bencode.asString(args['to_callsign'])
        : null;
    final myCallsign = geogramCallsign;
    if (targetCallsign != null &&
        myCallsign != null &&
        targetCallsign.toUpperCase() != myCallsign.toUpperCase()) {
      LogService().log(
        'DHT: ignoring geogram signal chunk for $targetCallsign from $fromIp:$fromPort',
      );
      return;
    }

    _discardExpiredSignalBuffers();

    final bufferKey = '$fromIp:$fromPort:$messageId';
    final existingBuffer = _incomingSignalBuffers[bufferKey];
    final buffer =
        existingBuffer != null && existingBuffer.totalChunks == chunkTotal
        ? existingBuffer
        : _incomingSignalBuffers[bufferKey] = _IncomingSignalBuffer(
            totalChunks: chunkTotal,
          );

    buffer.updatedAt = DateTime.now();
    buffer.chunks[chunkIndex] = payload;

    if (!buffer.isComplete) return;

    final assembled = buffer.assemble();
    _incomingSignalBuffers.remove(bufferKey);
    if (assembled == null) return;

    try {
      final decoded = jsonDecode(assembled);
      if (decoded is! Map) {
        LogService().log(
          'DHT: ignoring chunked geogram signal with invalid payload from $fromIp:$fromPort',
        );
        return;
      }

      final signal = _normalizeJsonSignalValue(decoded);
      if (signal is! Map<String, dynamic>) {
        LogService().log(
          'DHT: ignoring chunked geogram signal with invalid map from $fromIp:$fromPort',
        );
        return;
      }

      LogService().log(
        'DHT: reassembled geogram signal ${signal['type'] ?? 'unknown'} from $fromIp:$fromPort',
      );
      onGeogramSignal?.call(signal, fromIp, fromPort);
    } catch (e) {
      LogService().log(
        'DHT: failed to decode chunked geogram signal from $fromIp:$fromPort: $e',
      );
    }
  }

  /// Send a geogram identity query to a peer's DHT socket.
  Future<Map<String, dynamic>?> sendGeogramQuery(String ip, int port) async {
    final txId = _nextTxId();
    final completer = Completer<Map<String, dynamic>?>();

    _pendingQueries[_toHex(txId)] = _PendingQuery(
      txId: txId,
      method: 'geogram',
      completer: completer,
    );

    _sendMessage(
      {
        't': txId,
        'y': 'q',
        'q': 'geogram',
        'a': {
          'id': nodeId,
          'callsign': geogramCallsign ?? '',
          'npub': geogramNpub ?? '',
          'device_id': geogramDeviceId ?? '',
          'platform': geogramPlatform ?? '',
          'http_port': geogramHttpPort,
        },
      },
      ip,
      port,
    );

    LogService().log('DHT: sent geogram query to $ip:$port');

    return completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _pendingQueries.remove(_toHex(txId));
        return null;
      },
    );
  }

  /// Send a geogram signaling message to a peer's DHT socket.
  Future<bool> sendGeogramSignal(
    String ip,
    int port,
    Map<String, dynamic> signal,
  ) async {
    final preparedSignal = <String, dynamic>{};
    for (final entry in signal.entries) {
      final prepared = _prepareSignalValue(entry.value);
      if (prepared != null) {
        preparedSignal[entry.key] = prepared;
      }
    }

    final payload = jsonEncode(preparedSignal);
    if (payload.length > 900) {
      return _sendChunkedGeogramSignal(ip, port, preparedSignal, payload);
    }

    final response = await _sendQuery(
      'geogram_signal',
      {'id': nodeId, ...preparedSignal},
      ip,
      port,
    );
    if (response == null) {
      LogService().log('DHT: geogram signal to $ip:$port timed out');
      return false;
    }

    final ok = response['ok'];
    return ok is int && ok == 1;
  }

  Future<bool> _sendChunkedGeogramSignal(
    String ip,
    int port,
    Map<String, dynamic> signal,
    String payload,
  ) async {
    const chunkSize = 700;
    final messageId =
        '${DateTime.now().microsecondsSinceEpoch}-${_toHex(_nextTxId())}';
    final totalChunks = (payload.length / chunkSize).ceil();
    final targetCallsign = signal['to_callsign'] as String?;

    for (var i = 0; i < totalChunks; i++) {
      final start = i * chunkSize;
      final end = min(start + chunkSize, payload.length);
      final response = await _sendQuery(
        'geogram_signal_chunk',
        {
          'id': nodeId,
          'message_id': messageId,
          'chunk_index': i,
          'chunk_total': totalChunks,
          'payload': payload.substring(start, end),
          if (targetCallsign != null) 'to_callsign': targetCallsign,
        },
        ip,
        port,
      );

      final ok = response?['ok'];
      if (ok is! int || ok != 1) {
        LogService().log(
          'DHT: geogram signal chunk ${i + 1}/$totalChunks to $ip:$port failed',
        );
        return false;
      }
    }

    LogService().log(
      'DHT: sent chunked geogram signal (${payload.length} bytes, $totalChunks chunk(s)) to $ip:$port',
    );
    return true;
  }

  /// Our external IP:port as reported by BEP 42 `ip` field in DHT responses.
  String? _externalIp;
  int? _externalPort;

  /// Our external IP as reported by DHT peers (BEP 42).
  String? get externalIp => _externalIp;
  int? get externalPort => _externalPort;

  void _handleResponse(Map<String, dynamic> msg, String fromIp, int fromPort) {
    final txId = Bencode.asBytes(msg['t']);
    final txKey = _toHex(txId);
    final pending = _pendingQueries.remove(txKey);
    if (pending == null) return; // Unknown transaction

    // BEP 42: extract 'ip' field (6-byte compact: 4 IP + 2 port)
    if (msg.containsKey('ip')) {
      try {
        final ipBytes = Bencode.asBytes(msg['ip']);
        if (ipBytes.length == 6) {
          final (ip, port) = DhtContact.parseCompactPeer(ipBytes);
          if (ip != '0.0.0.0' && !ip.startsWith('127.')) {
            _externalIp = ip;
            _externalPort = port;
          }
        }
      } catch (_) {}
    }

    final body = Bencode.asMap(msg['r']);
    final responderId = Bencode.asBytes(body['id']);

    // Update routing table
    _routingTable.insertNode(
      DhtContact(
        nodeId: Uint8List.fromList(responderId),
        ip: fromIp,
        port: fromPort,
      ),
    );

    // Store token if present
    if (body.containsKey('token')) {
      final token = Bencode.asBytes(body['token']);
      _receivedTokens['$fromIp:$fromPort'] = Uint8List.fromList(token);
    }

    // Process nodes from ANY response type (find_node, get_peers)
    // This is how the routing table grows
    if (body.containsKey('nodes')) {
      _processNodes(body);
    }

    // Extract peers from get_peers responses
    if (pending.method == 'get_peers' &&
        body.containsKey('values') &&
        pending.infoHash != null) {
      try {
        final values = Bencode.asList(body['values']);
        for (final v in values) {
          final bytes = Bencode.asBytes(v);
          if (bytes.length == 6) {
            final (ip, port) = DhtContact.parseCompactPeer(bytes);
            _recordPeer(pending.infoHash!, PeerInfo(ip: ip, port: port));
          }
        }
      } catch (_) {}
    }

    // Handle geogram responses — extract peer identity
    if (body.containsKey('callsign')) {
      try {
        final peerCallsign = Bencode.asString(body['callsign']);
        if (peerCallsign.isNotEmpty) {
          final peerNpub = body.containsKey('npub')
              ? Bencode.asString(body['npub'])
              : null;
          final peerDeviceId = body.containsKey('device_id')
              ? Bencode.asString(body['device_id'])
              : null;
          final peerPlatform = body.containsKey('platform')
              ? Bencode.asString(body['platform'])
              : null;
          final peerHttpPort = body.containsKey('http_port')
              ? (body['http_port'] as int? ?? 3456)
              : 3456;
          LogService().log(
            'DHT: geogram response from $peerCallsign at $fromIp:$fromPort (http:$peerHttpPort)',
          );
          onGeogramPeer?.call(
            peerCallsign,
            peerNpub,
            peerDeviceId,
            peerPlatform,
            peerHttpPort,
            fromIp,
            fromPort,
          );
        }
      } catch (_) {}
    }

    // Complete the query
    if (!pending.completer.isCompleted) {
      pending.completer.complete(body);
    }
  }

  void _handleError(Map<String, dynamic> msg) {
    try {
      final errorInfo = Bencode.asList(msg['e']);
      final code = Bencode.asInt(errorInfo[0]);
      final message = Bencode.asString(errorInfo[1]);
      LogService().log('DHT error $code: $message');
    } catch (_) {}
  }

  // ─── Query Responses ────────────────────────────────────────────

  void _respondPing(Uint8List txId, String toIp, int toPort) {
    _sendMessage(
      {
        't': txId,
        'y': 'r',
        'r': {'id': nodeId},
      },
      toIp,
      toPort,
    );
  }

  void _respondFindNode(
    Uint8List txId,
    Uint8List target,
    String toIp,
    int toPort,
  ) {
    final closest = _routingTable.findClosest(target);
    final nodes = _packNodes(closest);

    _sendMessage(
      {
        't': txId,
        'y': 'r',
        'r': {'id': nodeId, 'nodes': nodes},
      },
      toIp,
      toPort,
    );
  }

  void _respondGetPeers(
    Uint8List txId,
    Uint8List infoHash,
    String toIp,
    int toPort,
  ) {
    final token = _generateToken(toIp);
    final hexHash = _toHex(infoHash);

    final response = <String, dynamic>{'id': nodeId, 'token': token};

    // Do we have peers for this info_hash?
    final peers = _peerStore[hexHash];
    if (peers != null && peers.isNotEmpty) {
      final freshPeers = getCachedPeers(infoHash);
      if (freshPeers.isNotEmpty) {
        // Return compact peer list
        final values = <Uint8List>[];
        for (final peer in freshPeers) {
          final parts = peer.ip.split('.');
          if (parts.length != 4) continue;
          final buf = Uint8List(6);
          for (var i = 0; i < 4; i++) {
            buf[i] = int.parse(parts[i]);
          }
          buf[4] = (peer.port >> 8) & 0xFF;
          buf[5] = peer.port & 0xFF;
          values.add(buf);
        }
        response['values'] = values;
      } else {
        final closest = _routingTable.findClosest(infoHash);
        response['nodes'] = _packNodes(closest);
      }
    } else {
      // Return closest nodes
      final closest = _routingTable.findClosest(infoHash);
      response['nodes'] = _packNodes(closest);
    }

    _sendMessage({'t': txId, 'y': 'r', 'r': response}, toIp, toPort);
  }

  void _handleAnnouncePeer(
    Map<String, dynamic> args,
    Uint8List txId,
    String fromIp,
    int fromPort,
  ) {
    final infoHash = Bencode.asBytes(args['info_hash']);
    final token = Bencode.asBytes(args['token']);

    // Validate token
    if (!_validateToken(fromIp, Uint8List.fromList(token))) {
      _sendError(txId, 203, 'Bad token', fromIp, fromPort);
      return;
    }

    // Determine announced port
    int announcedPort;
    final impliedPort = args['implied_port'];
    if (impliedPort is int && impliedPort == 1) {
      announcedPort = fromPort; // Use UDP source port
    } else {
      announcedPort = Bencode.asInt(args['port']);
    }

    // Store peer
    _recordPeer(
      Uint8List.fromList(infoHash),
      PeerInfo(ip: fromIp, port: announcedPort),
      observations: 2,
      fromAnnounce: true,
    );

    // Respond with ack
    _respondPing(txId, fromIp, fromPort);
  }

  // ─── Public Helpers ─────────────────────────────────────────────

  /// Ping a node (adds it to routing table on response).
  void pingNode(String ip, int port) {
    _sendPing(ip, port);
  }

  /// Fire get_peers queries to closest nodes for an info_hash.
  /// Non-blocking: just sends UDP queries, responses arrive via _handleResponse
  /// and populate _peerStore + _routingTable automatically.
  void fireGetPeers(Uint8List infoHash) {
    final closest = _routingTable.findClosest(infoHash, count: 3);
    for (final node in closest) {
      _sendGetPeers(node.ip, node.port, infoHash);
    }
  }

  /// Get external (non-localhost, non-LAN) nodes from routing table.
  List<DhtContact> getExternalNodes({int count = 6}) {
    final all = _routingTable.getAllNodes();
    final external = all
        .where(
          (n) =>
              !n.ip.startsWith('127.') &&
              !n.ip.startsWith('192.168.') &&
              !n.ip.startsWith('10.') &&
              !n.ip.startsWith('172.') &&
              n.ip != '0.0.0.0',
        )
        .toList();
    external.sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    return external.take(count).toList();
  }

  // ─── Sending Queries ────────────────────────────────────────────

  Future<Map<String, dynamic>?> _sendPing(String ip, int port) {
    return _sendQuery('ping', {'id': nodeId}, ip, port);
  }

  Future<Map<String, dynamic>?> _sendFindNode(
    String ip,
    int port,
    Uint8List target,
  ) {
    return _sendQuery('find_node', {'id': nodeId, 'target': target}, ip, port);
  }

  Future<Map<String, dynamic>?> _sendGetPeers(
    String ip,
    int port,
    Uint8List infoHash,
  ) {
    return _sendQuery(
      'get_peers',
      {'id': nodeId, 'info_hash': infoHash},
      ip,
      port,
      infoHash: infoHash,
    );
  }

  void _sendAnnouncePeer(
    String ip,
    int port,
    Uint8List infoHash,
    int announcePort,
    Uint8List token,
  ) {
    _sendQuery(
      'announce_peer',
      {
        'id': nodeId,
        'info_hash': infoHash,
        'port': announcePort,
        'token': token,
        'implied_port': 1,
      },
      ip,
      port,
    );
  }

  Future<Map<String, dynamic>?> _sendQuery(
    String method,
    Map<String, dynamic> args,
    String ip,
    int port, {
    Uint8List? infoHash,
  }) {
    final txId = _nextTxId();
    final txKey = _toHex(txId);

    final completer = Completer<Map<String, dynamic>?>();
    _pendingQueries[txKey] = _PendingQuery(
      txId: txId,
      method: method,
      completer: completer,
      infoHash: infoHash,
    );

    _sendMessage({'t': txId, 'y': 'q', 'q': method, 'a': args}, ip, port);

    return completer.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () {
        _pendingQueries.remove(txKey);
        return null;
      },
    );
  }

  void _sendError(
    Uint8List txId,
    int code,
    String message,
    String ip,
    int port,
  ) {
    _sendMessage(
      {
        't': txId,
        'y': 'e',
        'e': [code, message],
      },
      ip,
      port,
    );
  }

  void _sendMessage(Map<String, dynamic> msg, String ip, int port) {
    if (_socket == null || !_running) return;
    // Skip bogus addresses
    if (ip.isEmpty || ip == '0.0.0.0' || ip.contains(':')) return;
    try {
      final encoded = Bencode.encode(msg);
      _socket!.send(encoded, InternetAddress(ip), port);
    } catch (e) {
      // SocketException on send is non-fatal — skip this peer
    }
  }

  dynamic _prepareSignalValue(dynamic value) {
    if (value == null) return null;
    if (value is bool) return value ? 1 : 0;
    if (value is int || value is String || value is Uint8List) return value;
    if (value is List<int>) return Uint8List.fromList(value);
    if (value is List) {
      final result = <dynamic>[];
      for (final item in value) {
        final prepared = _prepareSignalValue(item);
        if (prepared != null) {
          result.add(prepared);
        }
      }
      return result;
    }
    if (value is Map) {
      final result = <String, dynamic>{};
      for (final entry in value.entries) {
        final prepared = _prepareSignalValue(entry.value);
        if (prepared != null) {
          result[entry.key.toString()] = prepared;
        }
      }
      return result;
    }
    return value.toString();
  }

  dynamic _normalizeSignalValue(dynamic value) {
    if (value is Uint8List) return String.fromCharCodes(value);
    if (value is List) {
      return value.map(_normalizeSignalValue).toList();
    }
    if (value is Map) {
      final result = <String, dynamic>{};
      for (final entry in value.entries) {
        result[entry.key.toString()] = _normalizeSignalValue(entry.value);
      }
      return result;
    }
    return value;
  }

  dynamic _normalizeJsonSignalValue(dynamic value) {
    if (value is Map) {
      final result = <String, dynamic>{};
      for (final entry in value.entries) {
        result[entry.key.toString()] = _normalizeJsonSignalValue(entry.value);
      }
      return result;
    }
    if (value is List) {
      return value.map(_normalizeJsonSignalValue).toList();
    }
    return value;
  }

  void _discardExpiredSignalBuffers() {
    final now = DateTime.now();
    _incomingSignalBuffers.removeWhere(
      (_, buffer) =>
          now.difference(buffer.updatedAt) > const Duration(seconds: 30),
    );
  }

  // ─── Iterative Operations ──────────────────────────────────────

  /// Proper BEP 5 iterative find_node.
  ///
  /// Maintains its own candidate set sorted by XOR distance to target.
  /// Iterates until no closer nodes are found (converged).
  Future<List<DhtContact>> _iterativeFindNode(Uint8List target) async {
    // Candidate set: all nodes discovered during this lookup, sorted by distance
    final candidates = <String, DhtContact>{}; // key → contact
    final distances = <String, Uint8List>{}; // key → xor distance
    final queried = <String>{};

    // Seed with closest nodes from routing table
    for (final node in _routingTable.findClosest(target, count: 8)) {
      final key = '${node.ip}:${node.port}';
      candidates[key] = node;
      distances[key] = xorDistance(node.nodeId, target);
    }

    for (var round = 0; round < 10 && _running; round++) {
      // Pick alpha=3 unqueried candidates closest to target
      final unqueried =
          candidates.keys.where((k) => !queried.contains(k)).toList()
            ..sort((a, b) => compareDistance(distances[a]!, distances[b]!));
      final toQuery = unqueried.take(3).toList();
      if (toQuery.isEmpty) break; // converged

      // Parallel queries (alpha=3) — lets the event loop process UI frames
      final futures = toQuery.map((key) {
        queried.add(key);
        final node = candidates[key]!;
        return _sendFindNode(node.ip, node.port, target);
      }).toList();
      final results = await Future.wait(futures);

      for (final result in results) {
        if (result == null) continue;
        if (result.containsKey('nodes')) {
          final nodesBytes = Bencode.asBytes(result['nodes']);
          for (var i = 0; i + 26 <= nodesBytes.length; i += 26) {
            final contact = DhtContact.fromCompactNodeInfo(nodesBytes, i);
            if (contact.ip == '0.0.0.0' || contact.port == 0) continue;
            final nkey = '${contact.ip}:${contact.port}';
            if (!candidates.containsKey(nkey)) {
              candidates[nkey] = contact;
              distances[nkey] = xorDistance(contact.nodeId, target);
              _routingTable.insertNode(contact);
            }
          }
        }
      }

      await Future.delayed(const Duration(milliseconds: 50));
    }

    // Return K-closest from candidates
    final sorted = candidates.keys.toList()
      ..sort((a, b) => compareDistance(distances[a]!, distances[b]!));
    return sorted.take(kBucketSize).map((k) => candidates[k]!).toList();
  }

  /// Proper BEP 5 iterative get_peers.
  ///
  /// Iterates through the DHT hop by hop until it reaches the K-closest
  /// nodes to the info_hash. Returns peers if found, and stores tokens
  /// for later announce_peer.
  Future<List<PeerInfo>> _iterativeGetPeers(Uint8List infoHash) async {
    final candidates = <String, DhtContact>{};
    final distances = <String, Uint8List>{};
    final queried = <String>{};
    final foundPeers = <String, PeerInfo>{};
    final peerSightings = <String, int>{};

    // Seed with closest nodes from routing table
    for (final node in _routingTable.findClosest(infoHash, count: 8)) {
      final key = '${node.ip}:${node.port}';
      candidates[key] = node;
      distances[key] = xorDistance(node.nodeId, infoHash);
    }

    for (var round = 0; round < 10 && _running; round++) {
      final unqueried =
          candidates.keys.where((k) => !queried.contains(k)).toList()
            ..sort((a, b) => compareDistance(distances[a]!, distances[b]!));
      final toQuery = unqueried.take(3).toList();
      if (toQuery.isEmpty) break;

      // Parallel queries (alpha=3) — lets the event loop process UI frames
      final futures = toQuery.map((key) {
        queried.add(key);
        final node = candidates[key]!;
        return _sendGetPeers(node.ip, node.port, infoHash);
      }).toList();
      final results = await Future.wait(futures);

      for (final result in results) {
        if (result == null) continue;

        if (result.containsKey('values')) {
          try {
            final values = Bencode.asList(result['values']);
            for (final v in values) {
              final bytes = Bencode.asBytes(v);
              if (bytes.length == 6) {
                final (ip, port) = DhtContact.parseCompactPeer(bytes);
                final peer = PeerInfo(ip: ip, port: port);
                if (!_isUsableDhtPeer(peer)) continue;
                final key = '${peer.ip}:${peer.port}';
                foundPeers[key] = peer;
                peerSightings[key] = (peerSightings[key] ?? 0) + 1;
              }
            }
          } catch (_) {}
        }

        if (result.containsKey('nodes')) {
          final nodesBytes = Bencode.asBytes(result['nodes']);
          for (var i = 0; i + 26 <= nodesBytes.length; i += 26) {
            final contact = DhtContact.fromCompactNodeInfo(nodesBytes, i);
            if (contact.ip == '0.0.0.0' || contact.port == 0) continue;
            final nkey = '${contact.ip}:${contact.port}';
            if (!candidates.containsKey(nkey)) {
              candidates[nkey] = contact;
              distances[nkey] = xorDistance(contact.nodeId, infoHash);
              _routingTable.insertNode(contact);
            }
          }
        }
      }

      await Future.delayed(const Duration(milliseconds: 50));
    }

    LogService().log(
      'DHT get_peers: ${queried.length} nodes queried, '
      '${foundPeers.length} peers found, '
      '${candidates.length} total candidates',
    );

    final rankedKeys = foundPeers.keys.toList()
      ..sort((a, b) {
        final bySightings = (peerSightings[b] ?? 0).compareTo(
          peerSightings[a] ?? 0,
        );
        if (bySightings != 0) return bySightings;
        return a.compareTo(b);
      });
    return rankedKeys.map((key) => foundPeers[key]!).toList();
  }

  /// Extract and insert nodes from a response's "nodes" field.
  void _processNodes(Map<String, dynamic> response) {
    if (!response.containsKey('nodes')) return;
    final nodesBytes = Bencode.asBytes(response['nodes']);
    // Compact node info: 26 bytes per node
    for (var i = 0; i + 26 <= nodesBytes.length; i += 26) {
      final contact = DhtContact.fromCompactNodeInfo(nodesBytes, i);
      // Skip bogus addresses
      if (contact.ip == '0.0.0.0' || contact.port == 0) continue;
      _routingTable.insertNode(contact);
    }
  }

  // ─── Token Management ──────────────────────────────────────────

  Uint8List _generateToken(String ip) {
    final input = utf8.encode('$ip:${_toHex(_tokenSecret)}');
    final hash = sha1.convert(input);
    return Uint8List.fromList(hash.bytes.sublist(0, 8));
  }

  bool _validateToken(String ip, Uint8List token) {
    // Check against current and previous secret
    final current = _generateToken(ip);
    if (_bytesEqual(token, current)) return true;

    final prevInput = utf8.encode('$ip:${_toHex(_tokenSecretPrev)}');
    final prevHash = sha1.convert(prevInput);
    final prev = Uint8List.fromList(prevHash.bytes.sublist(0, 8));
    return _bytesEqual(token, prev);
  }

  void _cleanupExpiredPeers() {
    final now = DateTime.now();
    final emptyTopics = <String>[];

    for (final entry in _peerStore.entries) {
      entry.value.removeWhere(
        (_, storedPeer) =>
            now.difference(storedPeer.lastSeen) >= kPeerRetention,
      );
      if (entry.value.isEmpty) {
        emptyTopics.add(entry.key);
      }
    }

    for (final topic in emptyTopics) {
      _peerStore.remove(topic);
    }
  }

  // ─── Maintenance ───────────────────────────────────────────────

  void _cleanupExpiredQueries() {
    final expired = <String>[];
    for (final entry in _pendingQueries.entries) {
      if (entry.value.isExpired) {
        expired.add(entry.key);
        if (!entry.value.completer.isCompleted) {
          entry.value.completer.complete(null);
        }
      }
    }
    for (final key in expired) {
      _pendingQueries.remove(key);
    }
  }

  Future<void> _refreshRoutingTable() async {
    // Ping a few stale nodes (fire-and-forget)
    final stale = _routingTable.getStaleNodes(const Duration(minutes: 5));
    for (final node in stale.take(3)) {
      _sendPing(node.ip, node.port);
    }

    // Search for nodes near our announced topics (not random IDs)
    // This grows the routing table in the keyspace that matters
    final closest = _routingTable.findClosest(_generateNodeId());
    for (final node in closest.take(3)) {
      _sendFindNode(node.ip, node.port, _generateNodeId());
    }
    await Future.delayed(const Duration(seconds: 1));

    // Also search near the geogram hash specifically
    final geogramHash = sha1Hash('geogram');
    final nearGeogram = _routingTable.findClosest(geogramHash);
    for (final node in nearGeogram.take(3)) {
      _sendFindNode(node.ip, node.port, geogramHash);
    }
  }

  // ─── Utilities ─────────────────────────────────────────────────

  Uint8List _generateNodeId() {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(20, (_) => rng.nextInt(256)));
  }

  Uint8List _generateTokenSecret() {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(16, (_) => rng.nextInt(256)));
  }

  /// Pack a list of contacts into compact "nodes" format (26 bytes each).
  Uint8List _packNodes(List<DhtContact> contacts) {
    final buf = Uint8List(contacts.length * 26);
    for (var i = 0; i < contacts.length; i++) {
      buf.setRange(i * 26, (i + 1) * 26, contacts[i].compactNodeInfo);
    }
    return buf;
  }

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
    return _toHex(bytes).substring(0, 8);
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _recordPeer(
    Uint8List infoHash,
    PeerInfo peer, {
    int observations = 1,
    bool fromAnnounce = false,
  }) {
    if (!_isUsableDhtPeer(peer)) return;

    final hexHash = _toHex(infoHash);
    final topicPeers = _peerStore.putIfAbsent(
      hexHash,
      () => <String, _StoredPeer>{},
    );
    final key = '${peer.ip}:${peer.port}';
    final existing = topicPeers[key];
    if (existing != null) {
      existing.touch(
        additionalObservations: observations,
        fromAnnounce: fromAnnounce,
      );
      _peerFoundController.add((infoHash, existing.peer));
    } else {
      topicPeers[key] = _StoredPeer(
        peer: peer,
        observations: observations,
        announced: fromAnnounce,
      );
      _peerFoundController.add((infoHash, peer));
    }

    if (topicPeers.length > kMaxPeersPerTopic) {
      final sorted = topicPeers.values.toList()..sort(_compareStoredPeers);
      final keepKeys = sorted
          .take(kMaxPeersPerTopic)
          .map((entry) => '${entry.peer.ip}:${entry.peer.port}')
          .toSet();
      topicPeers.removeWhere((peerKey, _) => !keepKeys.contains(peerKey));
    }
  }

  int _compareStoredPeers(_StoredPeer a, _StoredPeer b) {
    if (a.announced != b.announced) {
      return a.announced ? -1 : 1;
    }

    final byObservations = b.observations.compareTo(a.observations);
    if (byObservations != 0) return byObservations;

    return b.lastSeen.compareTo(a.lastSeen);
  }

  bool _isUsableDhtPeer(PeerInfo peer) {
    if (peer.port <= 1 || peer.port > 65535) {
      return false;
    }

    if (peer.ip.isEmpty ||
        peer.ip == '0.0.0.0' ||
        peer.ip.startsWith('127.') ||
        peer.ip.startsWith('10.') ||
        peer.ip.startsWith('192.168.') ||
        peer.ip.startsWith('169.254.')) {
      return false;
    }

    if (peer.ip.startsWith('172.')) {
      final parts = peer.ip.split('.');
      if (parts.length == 4) {
        final secondOctet = int.tryParse(parts[1]);
        if (secondOctet != null && secondOctet >= 16 && secondOctet <= 31) {
          return false;
        }
      }
    }

    return true;
  }

  void dispose() {
    _peerFoundController.close();
  }
}
