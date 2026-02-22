/*
 * Merkle Search Tree (MST) for AT Protocol repositories.
 *
 * The MST is the core data structure of AT Proto repos. It maps
 * "collection/rkey" keys to record CIDs, forming a content-addressed
 * tree whose shape is deterministic for any given set of keys.
 *
 * Key properties:
 * - Fanout determined by leading zeros of SHA-256(key), 2 bits at a time
 * - Keys sorted lexicographically within each node
 * - Prefix compression: each entry stores only the suffix after the
 *   previous key's shared prefix
 * - Same keys always produce the same tree shape (no balancing needed)
 *
 * Node structure (DAG-CBOR encoded):
 * {
 *   "l": <CID of left subtree or null>,
 *   "e": [
 *     { "p": <prefix-len>, "k": <key-suffix bytes>, "v": <record CID>, "t": <right subtree CID or null> },
 *     ...
 *   ]
 * }
 *
 * Reference: https://atproto.com/specs/repository#mst-structure
 *            picopds mst.py
 */

import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'cid.dart';
import 'dag_cbor.dart';

/// A single entry in the MST (key → value mapping with subtree pointer).
class MstEntry {
  final String key;
  final Cid valueCid;

  MstEntry(this.key, this.valueCid);
}

/// Block store interface for the MST.
///
/// The MST needs to read/write DAG-CBOR blocks by CID.
abstract class MstBlockStore {
  /// Get a block by CID. Returns null if not found.
  Uint8List? getBlock(Cid cid);

  /// Store a block and return its CID.
  Cid putBlock(Uint8List dagCborBytes);
}

/// In-memory block store for MST operations.
class MemoryBlockStore implements MstBlockStore {
  final Map<String, Uint8List> _blocks = {};

  @override
  Uint8List? getBlock(Cid cid) => _blocks[cid.toBase32()];

  @override
  Cid putBlock(Uint8List dagCborBytes) {
    final cid = Cid.fromContent(dagCborBytes);
    _blocks[cid.toBase32()] = dagCborBytes;
    return cid;
  }

  /// Get all stored blocks.
  Map<Cid, Uint8List> get allBlocks {
    final result = <Cid, Uint8List>{};
    for (final entry in _blocks.entries) {
      result[Cid.fromString(entry.key)] = entry.value;
    }
    return result;
  }
}

/// Merkle Search Tree for AT Protocol.
class MerkleSearchTree {
  final MstBlockStore store;
  Cid? _rootCid;

  MerkleSearchTree(this.store, [this._rootCid]);

  /// The root CID of the current tree state. Null if empty.
  Cid? get rootCid => _rootCid;

  /// Calculate the tree layer (depth) for a key.
  ///
  /// Counts leading zero pairs in SHA-256(key), 2 bits at a time.
  /// This determines which level of the tree the key belongs at.
  static int layerForKey(String key) {
    final hash = sha256.convert(Uint8List.fromList(key.codeUnits));
    final bytes = hash.bytes;
    var layer = 0;
    for (final byte in bytes) {
      // Check each 2-bit pair from MSB
      if (byte & 0xc0 == 0) {
        layer++;
      } else {
        return layer;
      }
      if (byte & 0x30 == 0) {
        layer++;
      } else {
        return layer;
      }
      if (byte & 0x0c == 0) {
        layer++;
      } else {
        return layer;
      }
      if (byte & 0x03 == 0) {
        layer++;
      } else {
        return layer;
      }
    }
    return layer;
  }

  /// Insert or update a key-value pair.
  void insert(String key, Cid valueCid) {
    final entries = _collectAll();
    // Insert or update
    var found = false;
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].key == key) {
        entries[i] = MstEntry(key, valueCid);
        found = true;
        break;
      }
    }
    if (!found) {
      entries.add(MstEntry(key, valueCid));
    }
    entries.sort((a, b) => a.key.compareTo(b.key));
    _rootCid = _buildFromEntries(entries);
  }

  /// Delete a key from the tree.
  ///
  /// Returns true if the key was found and removed.
  bool delete(String key) {
    final entries = _collectAll();
    final before = entries.length;
    entries.removeWhere((e) => e.key == key);
    if (entries.length == before) return false;
    _rootCid = entries.isEmpty ? null : _buildFromEntries(entries);
    return true;
  }

  /// Get the value CID for a key, or null if not found.
  Cid? get(String key) {
    if (_rootCid == null) return null;
    return _getFromNode(_rootCid!, key);
  }

  /// List entries matching a key prefix.
  List<MstEntry> list({String? prefix, int? limit, String? cursor}) {
    final all = _collectAll();
    var results = all;

    if (prefix != null) {
      results = results.where((e) => e.key.startsWith(prefix)).toList();
    }
    if (cursor != null) {
      results = results.where((e) => e.key.compareTo(cursor) > 0).toList();
    }
    if (limit != null && results.length > limit) {
      results = results.sublist(0, limit);
    }
    return results;
  }

  /// Get the total number of entries in the tree.
  int get length => _collectAll().length;

  /// Collect all entries in sorted order (for iteration/export).
  List<MstEntry> get entries => _collectAll();

  // -- Internal: tree construction --

  /// Build a tree from sorted entries.
  ///
  /// Uses the picopds algorithm: find the max layer among entries,
  /// place those at the current node, and recursively build subtrees
  /// from the entries between them.
  Cid? _buildFromEntries(List<MstEntry> entries) {
    if (entries.isEmpty) return null;

    // Find the highest layer among these entries
    var maxLayer = 0;
    for (final entry in entries) {
      final layer = layerForKey(entry.key);
      if (layer > maxLayer) maxLayer = layer;
    }

    // Entries at maxLayer go in this node; others go into subtrees
    final nodeEntries = <_NodeEntry>[];
    var leftEntries = <MstEntry>[];

    for (final entry in entries) {
      if (layerForKey(entry.key) == maxLayer) {
        final leftSubtree = _buildFromEntries(leftEntries);
        nodeEntries.add(_NodeEntry(
          key: entry.key,
          valueCid: entry.valueCid,
          leftSubtree: leftSubtree,
        ));
        leftEntries = [];
      } else {
        leftEntries.add(entry);
      }
    }

    // Remaining entries go into the rightmost subtree
    final rightSubtree = _buildFromEntries(leftEntries);

    return _encodeNode(nodeEntries, rightSubtree);
  }

  /// Encode a node as DAG-CBOR and store it.
  Cid _encodeNode(List<_NodeEntry> entries, Cid? rightSubtree) {
    // The first entry's left subtree is the node's "l" field.
    // Subsequent entries' left subtrees are the previous entry's "t" field.
    Cid? leftmost;
    if (entries.isNotEmpty) {
      leftmost = entries[0].leftSubtree;
    }

    final encodedEntries = <Map<String, dynamic>>[];
    var prevKey = '';

    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      // Prefix compression: find shared prefix length with previous key
      final prefixLen = _sharedPrefixLen(prevKey, entry.key);
      final keySuffix = entry.key.substring(prefixLen);

      final e = <String, dynamic>{
        'p': prefixLen,
        'k': Uint8List.fromList(keySuffix.codeUnits),
        'v': CidLink(entry.valueCid),
      };

      // "t" is the right subtree (which is the next entry's left subtree)
      Cid? rightTree;
      if (i + 1 < entries.length) {
        rightTree = entries[i + 1].leftSubtree;
      } else {
        rightTree = rightSubtree;
      }
      if (rightTree != null) {
        e['t'] = CidLink(rightTree);
      }

      encodedEntries.add(e);
      prevKey = entry.key;
    }

    final node = <String, dynamic>{
      'e': encodedEntries,
    };
    if (leftmost != null) {
      node['l'] = CidLink(leftmost);
    }

    final bytes = DagCbor.encode(node);
    return store.putBlock(bytes);
  }

  // -- Internal: tree traversal --

  Cid? _getFromNode(Cid nodeCid, String key) {
    final node = _decodeNode(nodeCid);
    if (node == null) return null;

    // Check left subtree for keys before the first entry
    if (node.entries.isNotEmpty && key.compareTo(node.entries.first.key) < 0) {
      if (node.leftSubtree != null) {
        return _getFromNode(node.leftSubtree!, key);
      }
      return null;
    }

    for (var i = 0; i < node.entries.length; i++) {
      final entry = node.entries[i];
      if (entry.key == key) return entry.valueCid;

      // If key is between this entry and the next (or after the last),
      // search the right subtree of this entry
      final isLast = i == node.entries.length - 1;
      final isBeforeNext = !isLast && key.compareTo(node.entries[i + 1].key) < 0;
      if (isLast || isBeforeNext) {
        if (entry.rightSubtree != null) {
          return _getFromNode(entry.rightSubtree!, key);
        }
        return null;
      }
    }

    return null;
  }

  /// Collect all entries from the tree in sorted order.
  List<MstEntry> _collectAll() {
    if (_rootCid == null) return [];
    return _collectFromNode(_rootCid!);
  }

  List<MstEntry> _collectFromNode(Cid nodeCid) {
    final node = _decodeNode(nodeCid);
    if (node == null) return [];

    final results = <MstEntry>[];

    // Left subtree
    if (node.leftSubtree != null) {
      results.addAll(_collectFromNode(node.leftSubtree!));
    }

    for (var i = 0; i < node.entries.length; i++) {
      final entry = node.entries[i];
      results.add(MstEntry(entry.key, entry.valueCid));

      // Right subtree of this entry
      if (entry.rightSubtree != null) {
        results.addAll(_collectFromNode(entry.rightSubtree!));
      }
    }

    return results;
  }

  /// Decode a node from the block store.
  _DecodedNode? _decodeNode(Cid nodeCid) {
    final bytes = store.getBlock(nodeCid);
    if (bytes == null) return null;

    final data = DagCbor.decode(bytes);
    if (data is! Map) return null;

    Cid? leftSubtree;
    final l = data['l'];
    if (l is CidLink) leftSubtree = l.cid;

    final entriesList = data['e'] as List? ?? [];
    final entries = <_DecodedEntry>[];
    var prevKey = '';

    for (final e in entriesList) {
      if (e is! Map) continue;

      final prefixLen = (e['p'] as int?) ?? 0;
      final keySuffixBytes = e['k'];
      String keySuffix;
      if (keySuffixBytes is Uint8List) {
        keySuffix = String.fromCharCodes(keySuffixBytes);
      } else if (keySuffixBytes is List) {
        keySuffix = String.fromCharCodes(keySuffixBytes.cast<int>());
      } else {
        keySuffix = keySuffixBytes?.toString() ?? '';
      }

      final fullKey = prevKey.substring(0, prefixLen) + keySuffix;

      Cid? valueCid;
      final v = e['v'];
      if (v is CidLink) valueCid = v.cid;

      Cid? rightSubtree;
      final t = e['t'];
      if (t is CidLink) rightSubtree = t.cid;

      entries.add(_DecodedEntry(
        key: fullKey,
        valueCid: valueCid!,
        rightSubtree: rightSubtree,
      ));
      prevKey = fullKey;
    }

    return _DecodedNode(
      leftSubtree: leftSubtree,
      entries: entries,
    );
  }

  static int _sharedPrefixLen(String a, String b) {
    final len = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < len; i++) {
      if (a.codeUnitAt(i) != b.codeUnitAt(i)) return i;
    }
    return len;
  }
}

// -- Internal node types --

class _NodeEntry {
  final String key;
  final Cid valueCid;
  final Cid? leftSubtree;

  _NodeEntry({
    required this.key,
    required this.valueCid,
    this.leftSubtree,
  });
}

class _DecodedNode {
  final Cid? leftSubtree;
  final List<_DecodedEntry> entries;

  _DecodedNode({this.leftSubtree, required this.entries});
}

class _DecodedEntry {
  final String key;
  final Cid valueCid;
  final Cid? rightSubtree;

  _DecodedEntry({
    required this.key,
    required this.valueCid,
    this.rightSubtree,
  });
}
