/// Kademlia routing table for BEP 5 DHT.
///
/// Implements a 160-bucket routing table with XOR distance metric.
/// Each bucket holds up to [K] nodes (default 8), evicted by LRU.
library;

import 'dart:typed_data';

/// Maximum nodes per bucket (BEP 5 standard).
const int kBucketSize = 8;

/// Total bits in node ID space.
const int kIdBits = 160;

/// A DHT node in the routing table.
class DhtContact {
  /// 20-byte (160-bit) node ID.
  final Uint8List nodeId;

  /// IP address.
  final String ip;

  /// UDP port.
  final int port;

  /// Last time we got a valid response from this node.
  DateTime lastSeen;

  /// Number of consecutive failed queries.
  int failCount;

  DhtContact({
    required this.nodeId,
    required this.ip,
    required this.port,
    DateTime? lastSeen,
    this.failCount = 0,
  }) : lastSeen = lastSeen ?? DateTime.now();

  /// Compact peer info: 6 bytes (4 IP + 2 port) for BEP 5.
  Uint8List get compactAddress {
    final parts = ip.split('.');
    if (parts.length != 4) return Uint8List(6);
    final buf = Uint8List(6);
    for (var i = 0; i < 4; i++) {
      buf[i] = int.parse(parts[i]);
    }
    buf[4] = (port >> 8) & 0xFF;
    buf[5] = port & 0xFF;
    return buf;
  }

  /// Compact node info: 26 bytes (20 ID + 4 IP + 2 port) for BEP 5.
  Uint8List get compactNodeInfo {
    final buf = Uint8List(26);
    buf.setRange(0, 20, nodeId);
    final addr = compactAddress;
    buf.setRange(20, 26, addr);
    return buf;
  }

  /// Parse compact node info (26 bytes) → DhtContact.
  static DhtContact fromCompactNodeInfo(Uint8List data, [int offset = 0]) {
    final nodeId = Uint8List.fromList(data.sublist(offset, offset + 20));
    final ip =
        '${data[offset + 20]}.${data[offset + 21]}.${data[offset + 22]}.${data[offset + 23]}';
    final port = (data[offset + 24] << 8) | data[offset + 25];
    return DhtContact(nodeId: nodeId, ip: ip, port: port);
  }

  /// Parse compact peer info (6 bytes) → ip:port.
  static (String ip, int port) parseCompactPeer(Uint8List data,
      [int offset = 0]) {
    final ip =
        '${data[offset]}.${data[offset + 1]}.${data[offset + 2]}.${data[offset + 3]}';
    final port = (data[offset + 4] << 8) | data[offset + 5];
    return (ip, port);
  }

  @override
  bool operator ==(Object other) =>
      other is DhtContact && _bytesEqual(nodeId, other.nodeId);

  @override
  int get hashCode {
    // Use first 4 bytes of nodeId
    if (nodeId.length < 4) return 0;
    return (nodeId[0] << 24) | (nodeId[1] << 16) | (nodeId[2] << 8) | nodeId[3];
  }

  @override
  String toString() => 'DhtContact($ip:$port)';
}

/// XOR distance between two 20-byte node IDs.
Uint8List xorDistance(Uint8List a, Uint8List b) {
  final result = Uint8List(20);
  for (var i = 0; i < 20; i++) {
    result[i] = a[i] ^ b[i];
  }
  return result;
}

/// Index of the highest bit set in a 20-byte distance.
/// Returns 0..159 (0 = farthest), or -1 if distance is zero.
int distanceBucket(Uint8List distance) {
  for (var i = 0; i < 20; i++) {
    if (distance[i] == 0) continue;
    final byte = distance[i];
    // Find highest bit in this byte
    for (var bit = 7; bit >= 0; bit--) {
      if ((byte >> bit) & 1 == 1) {
        return (i * 8) + (7 - bit);
      }
    }
  }
  return -1; // Zero distance (same node)
}

/// Compare two distances: negative if a < b, 0 if equal, positive if a > b.
int compareDistance(Uint8List a, Uint8List b) {
  for (var i = 0; i < 20; i++) {
    if (a[i] != b[i]) return a[i] - b[i];
  }
  return 0;
}

/// Kademlia routing table: 160 k-buckets.
class RoutingTable {
  /// Our own node ID.
  final Uint8List localId;

  /// 160 buckets, indexed 0..159.
  /// Bucket i holds nodes whose distance has highest bit at position i.
  final List<List<DhtContact>> buckets;

  RoutingTable({required this.localId})
      : buckets = List.generate(kIdBits, (_) => <DhtContact>[]);

  /// Total number of nodes in the table.
  int get nodeCount {
    var count = 0;
    for (final b in buckets) {
      count += b.length;
    }
    return count;
  }

  /// Insert or update a node. Returns true if the node was added/updated.
  ///
  /// If the bucket is full and the node is new, it is dropped (unless
  /// the oldest node has failed — in which case it's evicted).
  bool insertNode(DhtContact contact) {
    if (_bytesEqual(contact.nodeId, localId)) return false; // Don't add self

    final dist = xorDistance(localId, contact.nodeId);
    final bucketIdx = distanceBucket(dist);
    if (bucketIdx < 0) return false; // Same ID as us

    final bucket = buckets[bucketIdx];

    // Check if already in bucket
    for (var i = 0; i < bucket.length; i++) {
      if (_bytesEqual(bucket[i].nodeId, contact.nodeId)) {
        // Move to end (most recently seen)
        bucket[i].lastSeen = DateTime.now();
        bucket[i].failCount = 0;
        final node = bucket.removeAt(i);
        bucket.add(node);
        return true;
      }
    }

    // New node — add if space
    if (bucket.length < kBucketSize) {
      bucket.add(contact);
      return true;
    }

    // Bucket full — check if oldest has failed
    if (bucket.first.failCount > 0) {
      bucket.removeAt(0);
      bucket.add(contact);
      return true;
    }

    // Bucket full, oldest is good — discard new node
    return false;
  }

  /// Remove a node by ID.
  bool removeNode(Uint8List nodeId) {
    final dist = xorDistance(localId, nodeId);
    final bucketIdx = distanceBucket(dist);
    if (bucketIdx < 0) return false;

    final bucket = buckets[bucketIdx];
    for (var i = 0; i < bucket.length; i++) {
      if (_bytesEqual(bucket[i].nodeId, nodeId)) {
        bucket.removeAt(i);
        return true;
      }
    }
    return false;
  }

  /// Mark a node as failed (increment fail count).
  void markFailed(Uint8List nodeId) {
    final dist = xorDistance(localId, nodeId);
    final bucketIdx = distanceBucket(dist);
    if (bucketIdx < 0) return;

    for (final node in buckets[bucketIdx]) {
      if (_bytesEqual(node.nodeId, nodeId)) {
        node.failCount++;
        return;
      }
    }
  }

  /// Find the [count] closest nodes to [target].
  List<DhtContact> findClosest(Uint8List target, {int count = 8}) {
    // Collect all nodes with their distance to target
    final candidates = <(DhtContact, Uint8List)>[];
    for (final bucket in buckets) {
      for (final node in bucket) {
        final dist = xorDistance(node.nodeId, target);
        candidates.add((node, dist));
      }
    }

    // Sort by distance
    candidates.sort((a, b) => compareDistance(a.$2, b.$2));

    // Return closest
    final result = <DhtContact>[];
    for (var i = 0; i < candidates.length && i < count; i++) {
      result.add(candidates[i].$1);
    }
    return result;
  }

  /// Get all nodes (for cache persistence).
  List<DhtContact> getAllNodes() {
    final all = <DhtContact>[];
    for (final bucket in buckets) {
      all.addAll(bucket);
    }
    return all;
  }

  /// Get nodes that haven't been seen recently (for refresh pings).
  List<DhtContact> getStaleNodes(Duration threshold) {
    final cutoff = DateTime.now().subtract(threshold);
    final stale = <DhtContact>[];
    for (final bucket in buckets) {
      for (final node in bucket) {
        if (node.lastSeen.isBefore(cutoff)) {
          stale.add(node);
        }
      }
    }
    return stale;
  }
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
