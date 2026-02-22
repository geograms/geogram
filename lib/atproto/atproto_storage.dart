/*
 * SQLite-backed block store for AT Protocol repositories.
 *
 * Tables:
 * - blocks: content-addressed DAG-CBOR blobs (CID → bytes)
 * - repos: repository metadata (DID → head commit CID + signing key)
 * - records: index for fast record lookups without MST traversal
 * - sequence: monotonic event counter for firehose
 *
 * Follows the same patterns as NostrRelayStorage.
 */

import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import '../services/sqlite_loader.dart';
import 'cid.dart';
import 'mst.dart';

/// SQLite-backed storage for AT Protocol repos.
class AtprotoStorage implements MstBlockStore {
  final Database _db;

  AtprotoStorage._(this._db);

  /// Open (or create) an AT Proto storage database at the given path.
  static AtprotoStorage open(String dbPath) {
    final dir = Directory(dbPath).parent;
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    final db = SQLiteLoader.openDatabase(dbPath);
    final storage = AtprotoStorage._(db);
    storage._init();
    return storage;
  }

  /// Open an in-memory database (for testing).
  static AtprotoStorage openInMemory() {
    final db = SQLiteLoader.openInMemory();
    final storage = AtprotoStorage._(db);
    storage._init();
    return storage;
  }

  void _init() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS blocks (
        cid TEXT PRIMARY KEY,
        content BLOB NOT NULL
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS repos (
        did TEXT PRIMARY KEY,
        head TEXT NOT NULL,
        signing_key BLOB NOT NULL
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS records (
        uri TEXT PRIMARY KEY,
        cid TEXT NOT NULL,
        collection TEXT NOT NULL,
        rkey TEXT NOT NULL,
        created_at INTEGER NOT NULL
      );
    ''');
    _db.execute('''
      CREATE INDEX IF NOT EXISTS idx_records_collection
      ON records(collection, rkey);
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS sequence (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        event BLOB NOT NULL,
        created_at INTEGER NOT NULL
      );
    ''');
  }

  void close() {
    _db.dispose();
  }

  // -- MstBlockStore interface --

  @override
  Uint8List? getBlock(Cid cid) {
    final rows = _db.select(
      'SELECT content FROM blocks WHERE cid = ?',
      [cid.toBase32()],
    );
    if (rows.isEmpty) return null;
    return rows.first['content'] as Uint8List;
  }

  @override
  Cid putBlock(Uint8List dagCborBytes) {
    final cid = Cid.fromContent(dagCborBytes);
    _db.execute(
      'INSERT OR IGNORE INTO blocks (cid, content) VALUES (?, ?)',
      [cid.toBase32(), dagCborBytes],
    );
    return cid;
  }

  /// Check if a block exists.
  bool hasBlock(Cid cid) {
    final rows = _db.select(
      'SELECT 1 FROM blocks WHERE cid = ?',
      [cid.toBase32()],
    );
    return rows.isNotEmpty;
  }

  // -- Repo metadata --

  /// Get the head commit CID for a DID.
  Cid? getHead(String did) {
    final rows = _db.select(
      'SELECT head FROM repos WHERE did = ?',
      [did],
    );
    if (rows.isEmpty) return null;
    return Cid.fromString(rows.first['head'] as String);
  }

  /// Update the head commit CID for a DID.
  void setHead(String did, Cid head, Uint8List signingKey) {
    _db.execute(
      'INSERT OR REPLACE INTO repos (did, head, signing_key) VALUES (?, ?, ?)',
      [did, head.toBase32(), signingKey],
    );
  }

  /// Get the signing key for a DID.
  Uint8List? getSigningKey(String did) {
    final rows = _db.select(
      'SELECT signing_key FROM repos WHERE did = ?',
      [did],
    );
    if (rows.isEmpty) return null;
    return rows.first['signing_key'] as Uint8List;
  }

  // -- Record index --

  /// Index a record for fast lookup.
  void indexRecord(String uri, Cid cid, String collection, String rkey) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _db.execute(
      'INSERT OR REPLACE INTO records (uri, cid, collection, rkey, created_at) VALUES (?, ?, ?, ?, ?)',
      [uri, cid.toBase32(), collection, rkey, now],
    );
  }

  /// Remove a record from the index.
  void removeRecord(String uri) {
    _db.execute('DELETE FROM records WHERE uri = ?', [uri]);
  }

  /// Get a record CID by AT-URI.
  Cid? getRecordCid(String uri) {
    final rows = _db.select(
      'SELECT cid FROM records WHERE uri = ?',
      [uri],
    );
    if (rows.isEmpty) return null;
    return Cid.fromString(rows.first['cid'] as String);
  }

  /// List records in a collection with pagination.
  List<({String uri, String cid, String rkey})> listRecords(
    String collection, {
    int? limit,
    String? cursor,
    bool reverse = false,
  }) {
    final args = <Object?>[collection];
    var sql = 'SELECT uri, cid, rkey FROM records WHERE collection = ?';

    if (cursor != null) {
      sql += reverse ? ' AND rkey < ?' : ' AND rkey > ?';
      args.add(cursor);
    }

    sql += ' ORDER BY rkey ${reverse ? 'DESC' : 'ASC'}';

    if (limit != null) {
      sql += ' LIMIT ?';
      args.add(limit);
    }

    final rows = _db.select(sql, args);
    return rows.map((r) => (
      uri: r['uri'] as String,
      cid: r['cid'] as String,
      rkey: r['rkey'] as String,
    )).toList();
  }

  /// Count records in a collection.
  int countRecords(String collection) {
    final rows = _db.select(
      'SELECT COUNT(*) as cnt FROM records WHERE collection = ?',
      [collection],
    );
    return rows.first['cnt'] as int;
  }

  /// List all distinct collections.
  List<String> listCollections() {
    final rows = _db.select(
      'SELECT DISTINCT collection FROM records ORDER BY collection',
    );
    return rows.map((r) => r['collection'] as String).toList();
  }

  // -- Sequence (firehose events) --

  /// Append a firehose event and return its sequence number.
  int appendEvent(Uint8List eventBytes) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _db.execute(
      'INSERT INTO sequence (event, created_at) VALUES (?, ?)',
      [eventBytes, now],
    );
    return _db.lastInsertRowId;
  }

  /// Get events after a given sequence number.
  List<({int seq, Uint8List event})> getEventsSince(int cursor, {int? limit}) {
    final args = <Object?>[cursor];
    var sql = 'SELECT seq, event FROM sequence WHERE seq > ? ORDER BY seq ASC';
    if (limit != null) {
      sql += ' LIMIT ?';
      args.add(limit);
    }
    final rows = _db.select(sql, args);
    return rows.map((r) => (
      seq: r['seq'] as int,
      event: r['event'] as Uint8List,
    )).toList();
  }

  /// Get the latest sequence number.
  int? getLatestSeq() {
    final rows = _db.select('SELECT MAX(seq) as latest FROM sequence');
    final val = rows.first['latest'];
    return val as int?;
  }

  // -- Transactions --

  /// Run a function inside a transaction.
  T transaction<T>(T Function() fn) {
    _db.execute('BEGIN');
    try {
      final result = fn();
      _db.execute('COMMIT');
      return result;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }
}
