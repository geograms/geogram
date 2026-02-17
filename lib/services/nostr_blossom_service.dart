/*
 * Blossom storage service (SQLite metadata + blob files).
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import 'nostr_storage_paths.dart';
import 'sqlite_loader.dart';

class NostrBlossomService {
  final Database _db;
  final Directory _blobDir;

  int maxBytes;
  int maxFileBytes;

  NostrBlossomService._(
    this._db,
    this._blobDir, {
    required int maxBytes,
    required int maxFileBytes,
  })  : maxBytes = maxBytes,
        maxFileBytes = maxFileBytes;

  static NostrBlossomService open({
    String? baseDir,
    int maxBytes = 1024 * 1024 * 1024, // 1 GB default
    int maxFileBytes = 10 * 1024 * 1024, // 10 MB default
  }) {
    final base = NostrStoragePaths.baseDir(overrideBase: baseDir);
    final blobDir = Directory(NostrStoragePaths.blossomDir(overrideBase: baseDir));
    if (!blobDir.existsSync()) {
      blobDir.createSync(recursive: true);
    }

    final dbPath = NostrStoragePaths.blossomDbPath(overrideBase: baseDir);
    final db = SQLiteLoader.openDatabase(dbPath);
    final service = NostrBlossomService._(
      db,
      blobDir,
      maxBytes: maxBytes,
      maxFileBytes: maxFileBytes,
    );
    service._init();
    return service;
  }

  void _init() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS blobs (
        hash TEXT PRIMARY KEY,
        size INTEGER NOT NULL,
        mime TEXT,
        created_at INTEGER NOT NULL,
        path TEXT NOT NULL,
        owner_pubkey TEXT
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS blob_refs (
        hash TEXT NOT NULL,
        event_id TEXT,
        pubkey TEXT,
        created_at INTEGER NOT NULL
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
    ''');
    _db.execute(
      'CREATE INDEX IF NOT EXISTS blobs_created_at_idx ON blobs(created_at DESC);',
    );
    _db.execute(
      'CREATE INDEX IF NOT EXISTS blobs_owner_idx ON blobs(owner_pubkey);',
    );
    _db.execute(
      'CREATE INDEX IF NOT EXISTS blob_refs_event_idx ON blob_refs(event_id);',
    );
  }

  void close() {
    _db.dispose();
  }

  Future<BlossomUploadResult> ingestBytes({
    required Uint8List bytes,
    String? mime,
    String? ownerPubkey,
  }) async {
    if (bytes.length > maxFileBytes) {
      throw BlossomStorageError('File exceeds maxFileBytes (${maxFileBytes} bytes)');
    }

    final hash = sha256.convert(bytes).toString();
    final filePath = pathForHash(hash);
    final file = File(filePath);
    if (!await file.exists()) {
      await file.writeAsBytes(bytes, flush: true);
    }

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _db.execute('''
      INSERT OR IGNORE INTO blobs (hash, size, mime, created_at, path, owner_pubkey)
      VALUES (?, ?, ?, ?, ?, ?);
    ''', [hash, bytes.length, mime, now, file.path, ownerPubkey]);

    await enforceCap();

    return BlossomUploadResult(
      hash: hash,
      size: bytes.length,
      mime: mime,
      path: file.path,
    );
  }

  String pathForHash(String hash) {
    return '${_blobDir.path}${Platform.pathSeparator}$hash';
  }

  File? getBlobFile(String hash) {
    final file = File(pathForHash(hash));
    if (file.existsSync()) return file;
    return null;
  }

  void addReference({
    required String hash,
    String? eventId,
    String? pubkey,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _db.execute(
      'INSERT INTO blob_refs (hash, event_id, pubkey, created_at) VALUES (?, ?, ?, ?)',
      [hash, eventId, pubkey, now],
    );
  }

  Future<void> enforceCap() async {
    final cap = maxBytes;
    if (cap <= 0) return;

    int total = _currentSizeBytes();
    if (total <= cap) return;

    final unrefRows = _db.select('''
      SELECT hash, size, path FROM blobs
      WHERE hash NOT IN (SELECT DISTINCT hash FROM blob_refs)
      ORDER BY created_at ASC
    ''');
    total = await _pruneRows(unrefRows, total, cap);

    if (total <= cap) return;

    final refRows = _db.select('''
      SELECT hash, size, path FROM blobs
      ORDER BY created_at ASC
    ''');
    await _pruneRows(refRows, total, cap);
  }

  Future<int> _pruneRows(ResultSet rows, int total, int cap) async {
    var current = total;
    for (final row in rows) {
      if (current <= cap) break;
      final hash = row['hash'] as String;
      final size = row['size'] as int;
      final path = row['path'] as String;
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
      _db.execute('DELETE FROM blobs WHERE hash = ?', [hash]);
      _db.execute('DELETE FROM blob_refs WHERE hash = ?', [hash]);
      current -= knownSize(size);
    }
    return current;
  }

  Future<void> replicateUrl(String url, {String? ownerPubkey}) async {
    final uri = Uri.parse(url);
    if (uri.scheme != 'http' && uri.scheme != 'https') return;

    final client = HttpClient();
    try {
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode != 200) return;

      final contentLength = response.contentLength;
      if (contentLength > 0 && contentLength > maxFileBytes) return;

      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        builder.add(chunk);
      }
      final bytes = builder.takeBytes();
      await ingestBytes(bytes: bytes, mime: response.headers.contentType?.mimeType, ownerPubkey: ownerPubkey);
    } catch (_) {
      // Ignore replication failures.
    } finally {
      client.close();
    }
  }

  int _currentSizeBytes() {
    final rows = _db.select('SELECT SUM(size) AS total FROM blobs');
    final row = rows.isNotEmpty ? rows.first : null;
    final total = row?['total'];
    if (total is int) return total;
    if (total is num) return total.toInt();
    return 0;
  }

  int knownSize(int size) => size;
}

class BlossomUploadResult {
  final String hash;
  final int size;
  final String? mime;
  final String path;

  BlossomUploadResult({
    required this.hash,
    required this.size,
    required this.mime,
    required this.path,
  });

  Map<String, dynamic> toJson({String? baseUrl}) {
    final url = baseUrl != null ? '$baseUrl/$hash' : hash;
    return {
      'hash': hash,
      'size': size,
      if (mime != null) 'mime': mime,
      'url': url,
    };
  }
}

class BlossomStorageError implements Exception {
  final String message;
  BlossomStorageError(this.message);
  @override
  String toString() => message;
}
