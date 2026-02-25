/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * SQLite cache for NOSTR events.
 * Follows the IrcCacheService pattern.
 *
 * Storage layout:
 *   teleport/nostr/cache/{relay_id}.db  (one DB per relay)
 *   teleport/nostr/config.json
 */

import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../../services/log_service.dart';
import '../../services/profile_storage.dart';
import '../../services/sqlite_loader.dart';
import '../../util/nostr_event.dart';
import 'models/nostr_relay_config.dart';

class NostrCacheService {
  final ProfileStorage _storage;

  /// Open SQLite databases keyed by relay ID.
  final Map<String, Database> _dbs = {};

  static const int _maxEvents = 50000;

  NostrCacheService(this._storage);

  String _baseDirPath() => 'teleport/nostr';
  String _cacheDirPath() => '${_baseDirPath()}/cache';
  String _dbPath(String relayId) => '${_cacheDirPath()}/$relayId.db';
  String _configPath() => '${_baseDirPath()}/config.json';

  // ---------------------------------------------------------------------------
  // Config persistence (relay list + settings)
  // ---------------------------------------------------------------------------

  Future<void> saveConfig(Map<String, dynamic> config) async {
    try {
      await _storage.createDirectory(_baseDirPath());
      await _storage.writeString(
        _configPath(),
        const JsonEncoder.withIndent('  ').convert(config),
      );
    } catch (e) {
      LogService().log('NostrCacheService: saveConfig error: $e');
    }
  }

  Future<Map<String, dynamic>?> loadConfig() async {
    try {
      final str = await _storage.readString(_configPath());
      if (str == null) return null;
      return jsonDecode(str) as Map<String, dynamic>;
    } catch (e) {
      LogService().log('NostrCacheService: loadConfig error: $e');
      return null;
    }
  }

  Future<void> saveRelays(List<NostrRelayConfig> relays) async {
    final config = await loadConfig() ?? {};
    config['relays'] = relays.map((r) => r.toJson()).toList();
    await saveConfig(config);
  }

  Future<List<NostrRelayConfig>> loadRelays() async {
    final config = await loadConfig();
    if (config == null) return [];
    final list = config['relays'] as List<dynamic>? ?? [];
    return list
        .map((e) => NostrRelayConfig.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ---------------------------------------------------------------------------
  // SQLite event cache (per relay)
  // ---------------------------------------------------------------------------

  Future<Database> _openDb(String relayId) async {
    if (_dbs.containsKey(relayId)) return _dbs[relayId]!;

    await _storage.createDirectory(_cacheDirPath());
    final absPath = _storage.getAbsolutePath(_dbPath(relayId));
    final db = SQLiteLoader.openDatabase(absPath);

    db.execute('''
      CREATE TABLE IF NOT EXISTS events (
        id TEXT PRIMARY KEY,
        pubkey TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        kind INTEGER NOT NULL,
        content TEXT NOT NULL,
        sig TEXT,
        raw TEXT NOT NULL,
        relay_url TEXT NOT NULL
      );
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_nostr_events_kind_ts
      ON events(kind, created_at DESC);
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_nostr_events_pubkey
      ON events(pubkey, created_at DESC);
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS profiles (
        pubkey TEXT PRIMARY KEY,
        name TEXT,
        about TEXT,
        picture TEXT,
        nip05 TEXT,
        updated_at INTEGER NOT NULL
      );
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS contacts (
        pubkey TEXT PRIMARY KEY
      );
    ''');

    _dbs[relayId] = db;
    _prune(relayId);
    return db;
  }

  /// Cache a list of events in a single transaction.
  Future<void> cacheEvents(String relayId, List<NostrEvent> events) async {
    if (events.isEmpty) return;
    try {
      final db = await _openDb(relayId);
      db.execute('BEGIN');
      try {
        final stmt = db.prepare(
          '''INSERT OR IGNORE INTO events
             (id, pubkey, created_at, kind, content, sig, raw, relay_url)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?)''',
        );
        for (final ev in events) {
          if (ev.id == null) continue;
          stmt.execute([
            ev.id,
            ev.pubkey,
            ev.createdAt,
            ev.kind,
            ev.content,
            ev.sig,
            jsonEncode(ev.toJson()),
            relayId,
          ]);
        }
        stmt.dispose();
        db.execute('COMMIT');
      } catch (e) {
        db.execute('ROLLBACK');
        rethrow;
      }
    } catch (e) {
      LogService().log('NostrCacheService: cacheEvents error: $e');
    }
  }

  /// Load feed events (kind:1 text notes), newest first.
  Future<List<NostrEvent>> loadFeed(
    String relayId, {
    List<int> kinds = const [1],
    int? since,
    int limit = 500,
  }) async {
    try {
      final db = await _openDb(relayId);
      final kindPlaceholders = kinds.map((_) => '?').join(', ');
      final args = <dynamic>[...kinds];
      String whereExtra = '';
      if (since != null) {
        whereExtra = ' AND created_at > ?';
        args.add(since);
      }
      args.add(limit);
      final result = db.select(
        '''SELECT raw FROM events
           WHERE kind IN ($kindPlaceholders)$whereExtra
           ORDER BY created_at DESC LIMIT ?''',
        args,
      );

      final events = <NostrEvent>[];
      for (final row in result) {
        try {
          events.add(
            NostrEvent.fromJson(jsonDecode(row['raw'] as String)),
          );
        } catch (_) {}
      }
      return events.reversed.toList(); // oldest-first for UI
    } catch (e) {
      LogService().log('NostrCacheService: loadFeed error: $e');
      return [];
    }
  }

  /// Save follows (contact list) from kind:3 event.
  Future<void> saveFollows(String relayId, List<String> pubkeys) async {
    try {
      final db = await _openDb(relayId);
      db.execute('DELETE FROM contacts');
      if (pubkeys.isEmpty) return;
      db.execute('BEGIN');
      try {
        final stmt = db.prepare('INSERT OR IGNORE INTO contacts (pubkey) VALUES (?)');
        for (final pk in pubkeys) {
          stmt.execute([pk]);
        }
        stmt.dispose();
        db.execute('COMMIT');
      } catch (e) {
        db.execute('ROLLBACK');
        rethrow;
      }
    } catch (e) {
      LogService().log('NostrCacheService: saveFollows error: $e');
    }
  }

  /// Load follows (contact list).
  Future<Set<String>> loadFollows(String relayId) async {
    try {
      final db = await _openDb(relayId);
      final result = db.select('SELECT pubkey FROM contacts');
      return result.map((r) => r['pubkey'] as String).toSet();
    } catch (e) {
      LogService().log('NostrCacheService: loadFollows error: $e');
      return {};
    }
  }

  /// Save profile metadata from kind:0 event.
  Future<void> saveProfile(
    String relayId, {
    required String pubkey,
    String? name,
    String? about,
    String? picture,
    String? nip05,
  }) async {
    try {
      final db = await _openDb(relayId);
      db.execute(
        '''INSERT OR REPLACE INTO profiles
           (pubkey, name, about, picture, nip05, updated_at)
           VALUES (?, ?, ?, ?, ?, ?)''',
        [
          pubkey,
          name,
          about,
          picture,
          nip05,
          DateTime.now().millisecondsSinceEpoch ~/ 1000,
        ],
      );
    } catch (e) {
      LogService().log('NostrCacheService: saveProfile error: $e');
    }
  }

  /// Load all cached profiles for a relay (bulk load for startup).
  Future<Map<String, Map<String, String?>>> loadAllProfiles(String relayId) async {
    try {
      final db = await _openDb(relayId);
      final result = db.select(
        'SELECT pubkey, name, about, picture, nip05 FROM profiles',
      );
      final profiles = <String, Map<String, String?>>{};
      for (final row in result) {
        profiles[row['pubkey'] as String] = {
          'name': row['name'] as String?,
          'about': row['about'] as String?,
          'picture': row['picture'] as String?,
          'nip05': row['nip05'] as String?,
        };
      }
      return profiles;
    } catch (e) {
      LogService().log('NostrCacheService: loadAllProfiles error: $e');
      return {};
    }
  }

  /// Load profile metadata.
  Future<Map<String, String?>?> loadProfile(String relayId, String pubkey) async {
    try {
      final db = await _openDb(relayId);
      final result = db.select(
        'SELECT name, about, picture, nip05 FROM profiles WHERE pubkey = ?',
        [pubkey],
      );
      if (result.isEmpty) return null;
      final row = result.first;
      return {
        'name': row['name'] as String?,
        'about': row['about'] as String?,
        'picture': row['picture'] as String?,
        'nip05': row['nip05'] as String?,
      };
    } catch (e) {
      LogService().log('NostrCacheService: loadProfile error: $e');
      return null;
    }
  }

  /// Debug: return row count and DB file size for a relay.
  Future<Map<String, dynamic>> inspect(String relayId) async {
    try {
      final db = await _openDb(relayId);
      final countResult = db.select('SELECT COUNT(*) as cnt FROM events');
      final count = countResult.first['cnt'] as int;
      final absPath = _storage.getAbsolutePath(_dbPath(relayId));
      final file = File(absPath);
      final size = file.existsSync() ? file.lengthSync() : 0;
      return {'count': count, 'sizeBytes': size, 'path': absPath};
    } catch (e) {
      return {'error': '$e'};
    }
  }

  /// Clear all cached events for a relay.
  Future<void> clear(String relayId) async {
    try {
      final db = await _openDb(relayId);
      db.execute('DELETE FROM events');
      db.execute('DELETE FROM profiles');
      db.execute('DELETE FROM contacts');
      db.execute('VACUUM');
    } catch (e) {
      LogService().log('NostrCacheService: clear error: $e');
    }
  }

  void _prune(String relayId) {
    try {
      final db = _dbs[relayId];
      if (db == null) return;
      final countResult = db.select('SELECT COUNT(*) as cnt FROM events');
      final count = countResult.first['cnt'] as int;
      if (count > _maxEvents) {
        final excess = count - _maxEvents;
        db.execute(
          'DELETE FROM events WHERE id IN '
          '(SELECT id FROM events ORDER BY created_at ASC LIMIT ?)',
          [excess],
        );
      }
    } catch (e) {
      LogService().log('NostrCacheService: prune error: $e');
    }
  }

  void dispose() {
    for (final db in _dbs.values) {
      db.dispose();
    }
    _dbs.clear();
  }
}
