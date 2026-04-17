/*
 * WappSocialStore — per-wapp SQLite database for reactions and comments.
 *
 * Each wapp carries its own `social.sqlite3` inside its package
 * directory. When the wapp is shared or exported, the social data
 * travels with it. The permissions.json at the wapp root controls
 * who can write reactions/comments.
 *
 * Storage path: <wapp_dir>/social.sqlite3
 *
 * Reactions are NOSTR kind-7 events (like/emoji). Comments are
 * kind-1111 events. Both are Schnorr-signed.
 */

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:sqlite3/sqlite3.dart';

class WappSocialStore {
  WappSocialStore._();
  static final WappSocialStore instance = WappSocialStore._();

  /// Cache of open databases keyed by wapp directory path.
  final Map<String, Database> _dbs = {};

  /// Open (or reuse) the social database for a specific wapp.
  /// [wappDirPath] is the absolute path to the wapp's package
  /// directory (e.g. `~/.local/share/geogram/profiles/X1/apps/maps/`
  /// or `<repo>/wapps/archive/maps/`).
  Database? open(String wappDirPath) {
    if (kIsWeb) return null;
    if (_dbs.containsKey(wappDirPath)) return _dbs[wappDirPath]!;

    try {
      final dbPath = '$wappDirPath/social.sqlite3';
      final db = sqlite3.open(dbPath);
      _migrate(db);
      _dbs[wappDirPath] = db;
      return db;
    } catch (_) {
      return null;
    }
  }

  void _migrate(Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS reactions (
        id         TEXT PRIMARY KEY,
        reaction   TEXT NOT NULL DEFAULT '+',
        npub       TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        sig        TEXT
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS comments (
        id         TEXT PRIMARY KEY,
        parent_id  TEXT,
        content    TEXT NOT NULL,
        npub       TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        sig        TEXT
      );
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_comments_ts
      ON comments(created_at DESC);
    ''');
  }

  /// Close a specific wapp's database.
  void close(String wappDirPath) {
    _dbs.remove(wappDirPath)?.dispose();
  }

  /// Close all open databases.
  void closeAll() {
    for (final db in _dbs.values) {
      db.dispose();
    }
    _dbs.clear();
  }

  // ── Reactions ─────────────────────────────────────────────────────

  void addReaction(String wappDir, {
    required String id,
    required String npub,
    String reaction = '+',
    int? createdAt,
    String? sig,
  }) {
    final db = open(wappDir);
    if (db == null) return;
    final ts = createdAt ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    db.execute(
      'INSERT OR IGNORE INTO reactions (id, reaction, npub, created_at, sig) VALUES (?, ?, ?, ?, ?)',
      [id, reaction, npub, ts, sig],
    );
  }

  void removeReaction(String wappDir, String id) {
    open(wappDir)?.execute('DELETE FROM reactions WHERE id = ?', [id]);
  }

  int reactionCount(String wappDir) {
    final db = open(wappDir);
    if (db == null) return 0;
    final r = db.select('SELECT COUNT(*) as cnt FROM reactions');
    return r.isNotEmpty ? r.first['cnt'] as int : 0;
  }

  bool hasReacted(String wappDir, String npub) {
    final db = open(wappDir);
    if (db == null) return false;
    final r = db.select(
      'SELECT 1 FROM reactions WHERE npub = ? LIMIT 1', [npub]);
    return r.isNotEmpty;
  }

  List<Map<String, dynamic>> reactions(String wappDir) {
    final db = open(wappDir);
    if (db == null) return [];
    final r = db.select('SELECT * FROM reactions ORDER BY created_at DESC');
    return [for (final row in r) _rowToMap(row)];
  }

  // ── Comments ──────────────────────────────────────────────────────

  void addComment(String wappDir, {
    required String id,
    required String content,
    required String npub,
    String? parentId,
    int? createdAt,
    String? sig,
  }) {
    final db = open(wappDir);
    if (db == null) return;
    final ts = createdAt ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    db.execute(
      'INSERT OR IGNORE INTO comments (id, parent_id, content, npub, created_at, sig) VALUES (?, ?, ?, ?, ?, ?)',
      [id, parentId, content, npub, ts, sig],
    );
  }

  void removeComment(String wappDir, String id) {
    open(wappDir)?.execute('DELETE FROM comments WHERE id = ?', [id]);
  }

  int commentCount(String wappDir) {
    final db = open(wappDir);
    if (db == null) return 0;
    final r = db.select('SELECT COUNT(*) as cnt FROM comments');
    return r.isNotEmpty ? r.first['cnt'] as int : 0;
  }

  List<Map<String, dynamic>> topLevelComments(String wappDir) {
    final db = open(wappDir);
    if (db == null) return [];
    final r = db.select(
      'SELECT * FROM comments WHERE parent_id IS NULL ORDER BY created_at DESC');
    return [for (final row in r) _rowToMap(row)];
  }

  List<Map<String, dynamic>> replies(String wappDir, String parentId) {
    final db = open(wappDir);
    if (db == null) return [];
    final r = db.select(
      'SELECT * FROM comments WHERE parent_id = ? ORDER BY created_at ASC',
      [parentId]);
    return [for (final row in r) _rowToMap(row)];
  }

  Map<String, dynamic> _rowToMap(Row row) {
    final map = <String, dynamic>{};
    for (final col in row.keys) {
      map[col] = row[col];
    }
    return map;
  }
}
