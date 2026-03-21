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
];

/// How often to re-announce on DHT topics (minutes).
const int kReannounceMinutes = 25;

/// How often to refresh stale routing table entries (minutes).
const int kRefreshMinutes = 15;

/// Max peers to store per info_hash topic.
const int kMaxPeersPerTopic = 100;

/// Transaction ID counter for DHT queries.
int _txIdCounter = 0;

/// Generate a 2-byte transaction ID.
Uint8List _nextTxId() {
  _txIdCounter = (_txIdCounter + 1) & 0xFFFF;
  return Uint8List.fromList([
    (_txIdCounter >> 8) & 0xFF,
    _txIdCounter & 0xFF,
  ]);
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

  _PendingQuery({
    required this.txId,
    required this.method,
    required this.completer,
  }) : sentAt = DateTime.now();

  bool get isExpired =>
      DateTime.now().difference(sentAt) > const Duration(seconds: 10);
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

  /// Tokens we received from remote nodes (for our announces).
  /// Maps "ip:port" → token.
  final Map<String, Uint8List> _receivedTokens = {};

  /// Peer store: info_hash → set of compact peers (6 bytes each).
  final Map<String, Set<PeerInfo>> _peerStore = {};

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
  final _peerFoundController = StreamController<(Uint8List infoHash, PeerInfo peer)>.broadcast();

  /// Stream of newly discovered peers.
  Stream<(Uint8List infoHash, PeerInfo peer)> get onPeerFound => _peerFoundController.stream;

  /// Node count in routing table.
  int get routingTableSize => _routingTable.nodeCount;

  /// Number of peers stored.
  int get storedPeerCount {
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
    });

    // Rotate token secret every 5 minutes
    _tokenRotationTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      _tokenSecretPrev = _tokenSecret;
      _tokenSecret = _generateTokenSecret();
    });

    LogService().log('DHT node started on port $_localPort '
        '(id: ${_hexPrefix(nodeId)})');
  }

  /// Bootstrap the DHT by contacting well-known nodes.
  ///
  /// Also accepts [cachedNodes] from a previous session.
  /// Non-blocking: yields to the event loop between phases.
  Future<void> bootstrap({List<DhtContact>? cachedNodes}) async {
    if (!_running) return;

    // Phase 1: Insert cached nodes and ping them (fast, no blocking)
    if (cachedNodes != null) {
      for (final node in cachedNodes) {
        _routingTable.insertNode(node);
        _sendPing(node.ip, node.port);
      }
      // Yield to event loop after batch
      await Future.delayed(Duration.zero);
    }

    // Phase 2: Resolve bootstrap nodes one at a time with short timeouts
    for (final (host, port) in kBootstrapNodes) {
      if (!_running) return;
      try {
        final addresses = await InternetAddress.lookup(host)
            .timeout(const Duration(seconds: 3), onTimeout: () => []);
        final ipv4 = addresses.where(
            (a) => a.type == InternetAddressType.IPv4).toList();
        if (ipv4.isNotEmpty) {
          _sendFindNode(ipv4.first.address, port, nodeId);
        }
      } catch (e) {
        LogService().log('DHT bootstrap: failed to resolve $host: $e');
      }
      // Yield between DNS lookups
      await Future.delayed(Duration.zero);
    }

    // Phase 3: Wait for responses, then populate routing table
    await Future.delayed(const Duration(seconds: 3));
    if (!_running) return;
    await _iterativeFindNode(nodeId);

    LogService().log('DHT bootstrap complete: ${_routingTable.nodeCount} nodes');
  }

  /// Announce this node on a topic (info_hash).
  ///
  /// [infoHash] — 20-byte info_hash.
  /// [port] — port to announce (e.g., local shelf server port).
  Future<void> announce(Uint8List infoHash, int port) async {
    if (!_running) return;

    final hexHash = _toHex(infoHash);
    _announcedTopics[hexHash] = port;

    // First do get_peers to collect tokens
    await _iterativeGetPeers(infoHash);

    // Then announce to nodes that gave us tokens
    final closest = _routingTable.findClosest(infoHash);
    for (final node in closest) {
      final key = '${node.ip}:${node.port}';
      final token = _receivedTokens[key];
      if (token != null) {
        _sendAnnouncePeer(node.ip, node.port, infoHash, port, token);
      }
    }

    LogService().log('DHT announced on ${_hexPrefix(infoHash)} port $port');
  }

  /// Look up peers for an info_hash.
  ///
  /// Returns peers found from both the local peer store and remote DHT nodes.
  /// Also available via [onPeerFound] stream.
  Future<List<PeerInfo>> getPeers(Uint8List infoHash) async {
    if (!_running) return [];
    final remotePeers = await _iterativeGetPeers(infoHash);
    // Merge with locally stored peers (from incoming announces)
    final localPeers = getCachedPeers(infoHash);
    final merged = <PeerInfo>{...remotePeers, ...localPeers};
    return merged.toList();
  }

  /// Start periodic re-announce on all topics.
  void startPeriodicAnnounce() {
    _reannounceTimer?.cancel();
    _reannounceTimer = Timer.periodic(
      const Duration(minutes: kReannounceMinutes),
      (_) {
        for (final entry in _announcedTopics.entries) {
          final infoHash = _fromHex(entry.key);
          announce(infoHash, entry.value);
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
    return _peerStore[key]?.toList() ?? [];
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

  void _handleQuery(
      Map<String, dynamic> msg, String fromIp, int fromPort) {
    final txId = Bencode.asBytes(msg['t']);
    final method = Bencode.asString(msg['q']);
    final args = Bencode.asMap(msg['a']);
    final senderId = Bencode.asBytes(args['id']);

    // Update routing table with querying node
    _routingTable.insertNode(DhtContact(
      nodeId: Uint8List.fromList(senderId),
      ip: fromIp,
      port: fromPort,
    ));

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
    }
  }

  void _handleResponse(
      Map<String, dynamic> msg, String fromIp, int fromPort) {
    final txId = Bencode.asBytes(msg['t']);
    final txKey = _toHex(txId);
    final pending = _pendingQueries.remove(txKey);
    if (pending == null) return; // Unknown transaction

    final body = Bencode.asMap(msg['r']);
    final responderId = Bencode.asBytes(body['id']);

    // Update routing table
    _routingTable.insertNode(DhtContact(
      nodeId: Uint8List.fromList(responderId),
      ip: fromIp,
      port: fromPort,
    ));

    // Store token if present
    if (body.containsKey('token')) {
      final token = Bencode.asBytes(body['token']);
      _receivedTokens['$fromIp:$fromPort'] = Uint8List.fromList(token);
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
    _sendMessage({
      't': txId,
      'y': 'r',
      'r': {'id': nodeId},
    }, toIp, toPort);
  }

  void _respondFindNode(
      Uint8List txId, Uint8List target, String toIp, int toPort) {
    final closest = _routingTable.findClosest(target);
    final nodes = _packNodes(closest);

    _sendMessage({
      't': txId,
      'y': 'r',
      'r': {
        'id': nodeId,
        'nodes': nodes,
      },
    }, toIp, toPort);
  }

  void _respondGetPeers(
      Uint8List txId, Uint8List infoHash, String toIp, int toPort) {
    final token = _generateToken(toIp);
    final hexHash = _toHex(infoHash);

    final response = <String, dynamic>{
      'id': nodeId,
      'token': token,
    };

    // Do we have peers for this info_hash?
    final peers = _peerStore[hexHash];
    if (peers != null && peers.isNotEmpty) {
      // Return compact peer list
      final values = <Uint8List>[];
      for (final peer in peers) {
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
      // Return closest nodes
      final closest = _routingTable.findClosest(infoHash);
      response['nodes'] = _packNodes(closest);
    }

    _sendMessage({
      't': txId,
      'y': 'r',
      'r': response,
    }, toIp, toPort);
  }

  void _handleAnnouncePeer(
      Map<String, dynamic> args, Uint8List txId, String fromIp, int fromPort) {
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
    final hexHash = _toHex(Uint8List.fromList(infoHash));
    _peerStore.putIfAbsent(hexHash, () => <PeerInfo>{});
    final peer = PeerInfo(ip: fromIp, port: announcedPort);
    _peerStore[hexHash]!.add(peer);

    // Trim to max
    if (_peerStore[hexHash]!.length > kMaxPeersPerTopic) {
      final list = _peerStore[hexHash]!.toList();
      _peerStore[hexHash] = list.sublist(list.length - kMaxPeersPerTopic).toSet();
    }

    // Emit event
    _peerFoundController.add((Uint8List.fromList(infoHash), peer));

    // Respond with ack
    _respondPing(txId, fromIp, fromPort);
  }

  // ─── Public Helpers ─────────────────────────────────────────────

  /// Ping a node (adds it to routing table on response).
  void pingNode(String ip, int port) {
    _sendPing(ip, port);
  }

  // ─── Sending Queries ────────────────────────────────────────────

  Future<Map<String, dynamic>?> _sendPing(String ip, int port) {
    return _sendQuery('ping', {'id': nodeId}, ip, port);
  }

  Future<Map<String, dynamic>?> _sendFindNode(
      String ip, int port, Uint8List target) {
    return _sendQuery('find_node', {
      'id': nodeId,
      'target': target,
    }, ip, port);
  }

  Future<Map<String, dynamic>?> _sendGetPeers(
      String ip, int port, Uint8List infoHash) {
    return _sendQuery('get_peers', {
      'id': nodeId,
      'info_hash': infoHash,
    }, ip, port);
  }

  void _sendAnnouncePeer(
      String ip, int port, Uint8List infoHash, int announcePort, Uint8List token) {
    _sendQuery('announce_peer', {
      'id': nodeId,
      'info_hash': infoHash,
      'port': announcePort,
      'token': token,
      'implied_port': 0,
    }, ip, port);
  }

  Future<Map<String, dynamic>?> _sendQuery(
      String method, Map<String, dynamic> args, String ip, int port) {
    final txId = _nextTxId();
    final txKey = _toHex(txId);

    final completer = Completer<Map<String, dynamic>?>();
    _pendingQueries[txKey] = _PendingQuery(
      txId: txId,
      method: method,
      completer: completer,
    );

    _sendMessage({
      't': txId,
      'y': 'q',
      'q': method,
      'a': args,
    }, ip, port);

    // Timeout (short to avoid blocking the event loop)
    return completer.future.timeout(
      const Duration(seconds: 4),
      onTimeout: () {
        _pendingQueries.remove(txKey);
        return null;
      },
    );
  }

  void _sendError(Uint8List txId, int code, String message, String ip, int port) {
    _sendMessage({
      't': txId,
      'y': 'e',
      'e': [code, message],
    }, ip, port);
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

  // ─── Iterative Operations ──────────────────────────────────────

  /// Iterative find_node: find the [kBucketSize] closest nodes to [target].
  Future<List<DhtContact>> _iterativeFindNode(Uint8List target) async {
    final queried = <String>{};
    var closest = _routingTable.findClosest(target);

    for (var round = 0; round < 3 && _running; round++) {
      final toQuery = <DhtContact>[];
      for (final node in closest) {
        final key = '${node.ip}:${node.port}';
        if (!queried.contains(key)) {
          queried.add(key);
          toQuery.add(node);
        }
      }
      if (toQuery.isEmpty) break;

      // Query up to 3 in parallel
      final batch = toQuery.take(3).toList();
      final futures = batch.map((node) =>
          _sendFindNode(node.ip, node.port, target));
      final results = await Future.wait(futures);

      for (final result in results) {
        if (result == null) continue;
        _processNodes(result);
      }

      closest = _routingTable.findClosest(target);
      // Yield to event loop between rounds
      await Future.delayed(Duration.zero);
    }

    return closest;
  }

  /// Iterative get_peers: find peers for [infoHash].
  Future<List<PeerInfo>> _iterativeGetPeers(Uint8List infoHash) async {
    final queried = <String>{};
    final foundPeers = <PeerInfo>{};
    var closest = _routingTable.findClosest(infoHash);

    for (var round = 0; round < 3 && _running; round++) {
      final toQuery = <DhtContact>[];
      for (final node in closest) {
        final key = '${node.ip}:${node.port}';
        if (!queried.contains(key)) {
          queried.add(key);
          toQuery.add(node);
        }
      }
      if (toQuery.isEmpty) break;

      final batch = toQuery.take(3).toList();
      final futures = batch.map((node) =>
          _sendGetPeers(node.ip, node.port, infoHash));
      final results = await Future.wait(futures);

      for (final result in results) {
        if (result == null) continue;

        // Process returned peers
        if (result.containsKey('values')) {
          final values = Bencode.asList(result['values']);
          for (final v in values) {
            final bytes = Bencode.asBytes(v);
            if (bytes.length == 6) {
              final (ip, port) = DhtContact.parseCompactPeer(bytes);
              final peer = PeerInfo(ip: ip, port: port);
              foundPeers.add(peer);
              _peerFoundController.add((infoHash, peer));
            }
          }
        }

        // Process returned nodes (closer to target)
        _processNodes(result);
      }

      closest = _routingTable.findClosest(infoHash);
      // Yield to event loop between rounds
      await Future.delayed(Duration.zero);
    }

    // Store found peers
    final hexHash = _toHex(infoHash);
    _peerStore.putIfAbsent(hexHash, () => <PeerInfo>{});
    _peerStore[hexHash]!.addAll(foundPeers);

    return foundPeers.toList();
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
    // Ping stale nodes
    final stale = _routingTable.getStaleNodes(const Duration(minutes: 15));
    for (final node in stale.take(5)) {
      final result = await _sendPing(node.ip, node.port);
      if (result == null) {
        _routingTable.markFailed(node.nodeId);
      }
    }

    // Find random ID to discover new nodes
    final randomId = _generateNodeId();
    await _iterativeFindNode(randomId);
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

  void dispose() {
    _peerFoundController.close();
  }
}
