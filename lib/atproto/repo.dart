/*
 * AT Protocol Repository Manager.
 *
 * Orchestrates MST, signing, and storage into a complete AT Proto repository.
 * Each repo is identified by a DID and contains collections of records.
 *
 * Commit structure (DAG-CBOR):
 * {
 *   "did": "did:web:...",
 *   "version": 3,
 *   "data": <CID of MST root>,
 *   "rev": "<TID of this commit>",
 *   "prev": <CID of previous commit or null>,
 *   "sig": <ECDSA signature bytes>
 * }
 *
 * Reference: https://atproto.com/specs/repository
 */

import 'dart:typed_data';

import 'atproto_storage.dart';
import 'car.dart';
import 'cid.dart';
import 'dag_cbor.dart';
import 'mst.dart';
import 'signing.dart';
import 'tid.dart';

/// A record stored in the repository.
class RepoRecord {
  final String uri;
  final String collection;
  final String rkey;
  final Cid cid;
  final Map<String, dynamic> value;

  RepoRecord({
    required this.uri,
    required this.collection,
    required this.rkey,
    required this.cid,
    required this.value,
  });
}

/// AT Protocol repository manager.
class AtprotoRepo {
  final String did;
  final AtprotoStorage storage;
  final Uint8List _signingKey;
  late final MerkleSearchTree _mst;
  Cid? _headCid;

  AtprotoRepo._({
    required this.did,
    required this.storage,
    required Uint8List signingKey,
    Cid? mstRoot,
    Cid? headCid,
  }) : _signingKey = signingKey,
       _headCid = headCid {
    _mst = MerkleSearchTree(storage, mstRoot);
  }

  /// Create a new repository for a DID.
  factory AtprotoRepo.create({
    required String did,
    required AtprotoStorage storage,
    required Uint8List signingKey,
  }) {
    return AtprotoRepo._(
      did: did,
      storage: storage,
      signingKey: signingKey,
    );
  }

  /// Open an existing repository from storage.
  ///
  /// Returns null if no repo exists for the given DID.
  static AtprotoRepo? open({
    required String did,
    required AtprotoStorage storage,
  }) {
    final headCid = storage.getHead(did);
    if (headCid == null) return null;

    final signingKey = storage.getSigningKey(did);
    if (signingKey == null) return null;

    // Load the commit to get MST root
    final commitBytes = storage.getBlock(headCid);
    if (commitBytes == null) return null;

    final commit = DagCbor.decode(commitBytes);
    if (commit is! Map) return null;

    Cid? mstRoot;
    final data = commit['data'];
    if (data is CidLink) {
      mstRoot = data.cid;
    }

    return AtprotoRepo._(
      did: did,
      storage: storage,
      signingKey: signingKey,
      mstRoot: mstRoot,
      headCid: headCid,
    );
  }

  /// The current head commit CID.
  Cid? get headCid => _headCid;

  /// The public key for this repo's signing key.
  Uint8List get publicKey => AtprotoSigning.derivePublicKey(_signingKey);

  /// Create a new record in a collection.
  ///
  /// Returns the AT-URI and CID of the created record.
  ({String uri, Cid cid}) createRecord(
    String collection,
    Map<String, dynamic> record, {
    String? rkey,
  }) {
    rkey ??= Tid.next();
    final mstKey = '$collection/$rkey';

    // Encode the record as DAG-CBOR and store as a block
    final recordBytes = DagCbor.encode(record);
    final recordCid = storage.putBlock(recordBytes);

    // Insert into MST
    _mst.insert(mstKey, recordCid);

    // Index the record
    final uri = 'at://$did/$collection/$rkey';
    storage.indexRecord(uri, recordCid, collection, rkey);

    return (uri: uri, cid: recordCid);
  }

  /// Get a record by collection and rkey.
  RepoRecord? getRecord(String collection, String rkey) {
    final mstKey = '$collection/$rkey';
    final recordCid = _mst.get(mstKey);
    if (recordCid == null) return null;

    final bytes = storage.getBlock(recordCid);
    if (bytes == null) return null;

    final value = DagCbor.decode(bytes);
    if (value is! Map<String, dynamic>) return null;

    return RepoRecord(
      uri: 'at://$did/$collection/$rkey',
      collection: collection,
      rkey: rkey,
      cid: recordCid,
      value: value,
    );
  }

  /// Update an existing record (put with explicit rkey).
  ({String uri, Cid cid}) putRecord(
    String collection,
    String rkey,
    Map<String, dynamic> record,
  ) {
    // Remove old record index if it exists
    final uri = 'at://$did/$collection/$rkey';
    storage.removeRecord(uri);

    return createRecord(collection, record, rkey: rkey);
  }

  /// Delete a record by collection and rkey.
  ///
  /// Returns true if the record existed and was deleted.
  bool deleteRecord(String collection, String rkey) {
    final mstKey = '$collection/$rkey';
    final deleted = _mst.delete(mstKey);
    if (deleted) {
      storage.removeRecord('at://$did/$collection/$rkey');
    }
    return deleted;
  }

  /// List records in a collection with pagination.
  List<RepoRecord> listRecords(
    String collection, {
    int? limit,
    String? cursor,
    bool reverse = false,
  }) {
    final indexed = storage.listRecords(
      collection,
      limit: limit,
      cursor: cursor,
      reverse: reverse,
    );

    final results = <RepoRecord>[];
    for (final entry in indexed) {
      final cid = Cid.fromString(entry.cid);
      final bytes = storage.getBlock(cid);
      if (bytes == null) continue;

      final value = DagCbor.decode(bytes);
      if (value is! Map<String, dynamic>) continue;

      results.add(RepoRecord(
        uri: entry.uri,
        collection: collection,
        rkey: entry.rkey,
        cid: cid,
        value: value,
      ));
    }
    return results;
  }

  /// List all collections in this repo.
  List<String> listCollections() => storage.listCollections();

  /// Create a signed commit for the current repo state.
  ///
  /// This persists the commit to storage and updates the head.
  Cid commit() {
    final rev = Tid.next();
    final mstRoot = _mst.rootCid;

    // Build unsigned commit
    final commitData = <String, dynamic>{
      'did': did,
      'version': 3,
      'rev': rev,
    };
    if (mstRoot != null) {
      commitData['data'] = CidLink(mstRoot);
    }
    if (_headCid != null) {
      commitData['prev'] = CidLink(_headCid!);
    }

    // Sign the commit: encode without sig, sign, then encode with sig
    final unsignedBytes = DagCbor.encode(commitData);
    final sig = AtprotoSigning.sign(unsignedBytes, _signingKey);
    commitData['sig'] = sig;

    final signedBytes = DagCbor.encode(commitData);
    final commitCid = storage.putBlock(signedBytes);

    // Update head
    _headCid = commitCid;
    storage.setHead(did, commitCid, _signingKey);

    return commitCid;
  }

  /// Export the entire repo as a CAR v1 file.
  ///
  /// Includes the latest commit, MST nodes, and all record blocks.
  Uint8List exportCar() {
    if (_headCid == null) {
      throw StateError('No commits yet — cannot export');
    }

    // Collect all reachable blocks
    final blocks = <Cid, Uint8List>{};

    void collectBlock(Cid cid) {
      if (blocks.containsKey(cid)) return;
      final data = storage.getBlock(cid);
      if (data == null) return;
      blocks[cid] = data;

      // Recursively collect CID references
      try {
        final decoded = DagCbor.decode(data);
        _collectCidLinks(decoded, collectBlock);
      } catch (_) {
        // Not DAG-CBOR or no links — that's fine
      }
    }

    collectBlock(_headCid!);

    return CarWriter.write(_headCid!, blocks);
  }

  /// Recursively find CID links in decoded DAG-CBOR data.
  static void _collectCidLinks(dynamic value, void Function(Cid) visit) {
    if (value is CidLink) {
      visit(value.cid);
    } else if (value is Map) {
      for (final v in value.values) {
        _collectCidLinks(v, visit);
      }
    } else if (value is List) {
      for (final v in value) {
        _collectCidLinks(v, visit);
      }
    }
  }
}
