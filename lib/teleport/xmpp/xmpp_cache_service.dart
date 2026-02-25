/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * SQLite cache for XMPP — one database per server.
 *
 * Storage layout:
 *   teleport/xmpp/config.json              # server configs (global)
 *   teleport/xmpp/cache/{serverId}.db      # per-server: rooms + messages
 *
 * Each per-server DB has two tables:
 *   rooms — joined room metadata (jid, name, subject, last_activity)
 *   messages — chat messages (room_jid, sender, text, timestamp, type, is_outgoing)
 */

import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../../services/log_service.dart';
import '../../services/profile_storage.dart';
import '../../services/sqlite_loader.dart';
import 'models/xmpp_room.dart';
import 'models/xmpp_message.dart';
import 'models/xmpp_server_config.dart';

class XmppCacheService {
  final ProfileStorage _storage;

  /// Open databases keyed by server ID.
  final Map<String, Database> _dbs = {};

  static const int _maxMessages = 10000;

  XmppCacheService(this._storage);

  String _baseDirPath() => 'teleport/xmpp';
  String _cacheDirPath() => '${_baseDirPath()}/cache';
  String _dbPath(String serverId) => '${_cacheDirPath()}/$serverId.db';
  String _configPath() => '${_baseDirPath()}/config.json';

  /// Absolute directory path for Whixp's internal database for a server.
  /// Whixp appends its own filename to this path.
  String getWhixpDbPath(String serverId) {
    final absDir = _storage.getAbsolutePath('${_cacheDirPath()}/whixp_$serverId');
    final dir = Directory(absDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return absDir;
  }

  // ---------------------------------------------------------------------------
  // Config persistence (server list + settings) — global, not per-server
  // ---------------------------------------------------------------------------

  Future<void> saveConfig(Map<String, dynamic> config) async {
    try {
      await _storage.createDirectory(_baseDirPath());
      await _storage.writeString(
        _configPath(),
        const JsonEncoder.withIndent('  ').convert(config),
      );
    } catch (e) {
      LogService().log('XmppCacheService: saveConfig error: $e');
    }
  }

  Future<Map<String, dynamic>?> loadConfig() async {
    try {
      final str = await _storage.readString(_configPath());
      if (str == null) return null;
      return jsonDecode(str) as Map<String, dynamic>;
    } catch (e) {
      LogService().log('XmppCacheService: loadConfig error: $e');
      return null;
    }
  }

  Future<void> saveServers(List<XmppServerConfig> servers) async {
    final config = await loadConfig() ?? {};
    config['servers'] = servers.map((s) => s.toJson()).toList();
    await saveConfig(config);
  }

  Future<List<XmppServerConfig>> loadServers() async {
    final config = await loadConfig();
    if (config == null) return [];
    final list = config['servers'] as List<dynamic>? ?? [];
    return list
        .map((e) => XmppServerConfig.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ---------------------------------------------------------------------------
  // Per-server SQLite database
  // ---------------------------------------------------------------------------

  Future<Database> _openDb(String serverId) async {
    final existing = _dbs[serverId];
    if (existing != null) return existing;

    await _storage.createDirectory(_cacheDirPath());
    final absPath = _storage.getAbsolutePath(_dbPath(serverId));
    final db = SQLiteLoader.openDatabase(absPath);

    db.execute('''
      CREATE TABLE IF NOT EXISTS rooms (
        jid TEXT PRIMARY KEY,
        name TEXT NOT NULL DEFAULT '',
        subject TEXT NOT NULL DEFAULT '',
        last_activity INTEGER NOT NULL DEFAULT 0,
        last_read_ts INTEGER NOT NULL DEFAULT 0,
        conference_service TEXT
      );
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        room_jid TEXT NOT NULL,
        sender TEXT NOT NULL,
        sender_jid TEXT,
        text TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        type TEXT NOT NULL,
        is_outgoing INTEGER NOT NULL DEFAULT 0,
        stanza_id TEXT
      );
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_xmpp_msg_room_ts
      ON messages(room_jid, timestamp DESC);
    ''');

    _prune(db);
    _dbs[serverId] = db;
    return db;
  }

  // ---------------------------------------------------------------------------
  // Room cache
  // ---------------------------------------------------------------------------

  /// Save or update a joined room's metadata.
  Future<void> saveRoom(String serverId, XmppRoom room) async {
    try {
      final db = await _openDb(serverId);
      db.execute(
        '''INSERT OR REPLACE INTO rooms (jid, name, subject, last_activity, last_read_ts, conference_service)
           VALUES (?, ?, ?, ?, COALESCE(
             (SELECT last_read_ts FROM rooms WHERE jid = ?), 0
           ), ?)''',
        [
          room.jid,
          room.name,
          room.subject,
          room.lastMessage?.timestamp.millisecondsSinceEpoch ??
              DateTime.now().toUtc().millisecondsSinceEpoch,
          room.jid,
          room.conferenceService,
        ],
      );
    } catch (e) {
      LogService().log('XmppCacheService: saveRoom error: $e');
    }
  }

  /// Save multiple rooms in a transaction.
  Future<void> saveRooms(String serverId, List<XmppRoom> rooms) async {
    if (rooms.isEmpty) return;
    try {
      final db = await _openDb(serverId);
      db.execute('BEGIN');
      try {
        for (final room in rooms) {
          db.execute(
            '''INSERT OR REPLACE INTO rooms (jid, name, subject, last_activity, last_read_ts, conference_service)
               VALUES (?, ?, ?, ?, COALESCE(
                 (SELECT last_read_ts FROM rooms WHERE jid = ?), 0
               ), ?)''',
            [
              room.jid,
              room.name,
              room.subject,
              room.lastMessage?.timestamp.millisecondsSinceEpoch ??
                  DateTime.now().toUtc().millisecondsSinceEpoch,
              room.jid,
              room.conferenceService,
            ],
          );
        }
        db.execute('COMMIT');
      } catch (e) {
        db.execute('ROLLBACK');
        rethrow;
      }
    } catch (e) {
      LogService().log('XmppCacheService: saveRooms error: $e');
    }
  }

  /// Remove a room from cache (on leave).
  Future<void> removeRoom(String serverId, String roomJid) async {
    try {
      final db = await _openDb(serverId);
      db.execute('DELETE FROM rooms WHERE jid = ?', [roomJid]);
    } catch (e) {
      LogService().log('XmppCacheService: removeRoom error: $e');
    }
  }

  /// Load all cached rooms for a server, with unread counts computed
  /// from messages newer than the last_read_ts.
  Future<List<XmppRoom>> loadRooms(String serverId) async {
    try {
      final db = await _openDb(serverId);
      final result = db.select('''
        SELECT r.jid, r.name, r.subject, r.last_activity, r.last_read_ts,
               r.conference_service,
               (SELECT COUNT(*) FROM messages m
                WHERE m.room_jid = r.jid
                  AND m.timestamp > r.last_read_ts
                  AND m.is_outgoing = 0) AS unread
        FROM rooms r
        ORDER BY r.last_activity DESC
      ''');
      final rooms = <XmppRoom>[];
      for (final row in result) {
        rooms.add(XmppRoom(
          serverConfigId: serverId,
          jid: row['jid'] as String,
          name: row['name'] as String? ?? '',
          subject: row['subject'] as String? ?? '',
          conferenceService: row['conference_service'] as String?,
          unreadCount: row['unread'] as int? ?? 0,
        ));
      }
      return rooms;
    } catch (e) {
      LogService().log('XmppCacheService: loadRooms error: $e');
      return [];
    }
  }

  /// Mark a room as read — sets last_read_ts to now.
  Future<void> markRoomRead(String serverId, String roomJid) async {
    try {
      final db = await _openDb(serverId);
      db.execute(
        'UPDATE rooms SET last_read_ts = ? WHERE jid = ?',
        [DateTime.now().toUtc().millisecondsSinceEpoch, roomJid],
      );
    } catch (e) {
      LogService().log('XmppCacheService: markRoomRead error: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Message cache
  // ---------------------------------------------------------------------------

  /// Cache a batch of messages for a specific server.
  Future<void> cacheMessages(String serverId, List<XmppMessage> messages) async {
    if (messages.isEmpty) return;
    try {
      final db = await _openDb(serverId);
      db.execute('BEGIN');
      try {
        final stmt = db.prepare(
          '''INSERT INTO messages (room_jid, sender, sender_jid, text, timestamp, type, is_outgoing, stanza_id)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?)''',
        );
        for (final msg in messages) {
          stmt.execute([
            msg.roomJid,
            msg.sender,
            msg.senderJid,
            msg.text,
            msg.timestamp.millisecondsSinceEpoch,
            msg.type.name,
            msg.isOutgoing ? 1 : 0,
            msg.stanzaId,
          ]);
        }
        stmt.dispose();
        db.execute('COMMIT');
      } catch (e) {
        db.execute('ROLLBACK');
        rethrow;
      }
    } catch (e) {
      LogService().log('XmppCacheService: cacheMessages error: $e');
    }
  }

  /// Load messages for a room from a server's DB.
  Future<List<XmppMessage>> loadMessages(
    String serverId,
    String roomJid, {
    int limit = 500,
  }) async {
    try {
      final db = await _openDb(serverId);
      final result = db.select(
        '''SELECT room_jid, sender, sender_jid, text, timestamp, type, is_outgoing, stanza_id
           FROM messages
           WHERE room_jid = ?
           ORDER BY timestamp DESC LIMIT ?''',
        [roomJid, limit],
      );

      final messages = <XmppMessage>[];
      for (final row in result) {
        messages.add(_rowToMessage(serverId, row));
      }
      return messages.reversed.toList(); // oldest-first
    } catch (e) {
      LogService().log('XmppCacheService: loadMessages error: $e');
      return [];
    }
  }

  // ---------------------------------------------------------------------------
  // Debug / inspection
  // ---------------------------------------------------------------------------

  /// Inspect all per-server databases. Returns a list of server DB summaries.
  Future<Map<String, dynamic>> inspect() async {
    final serverInfos = <Map<String, dynamic>>[];
    try {
      final cacheDirAbs = _storage.getAbsolutePath(_cacheDirPath());
      final cacheDir = Directory(cacheDirAbs);
      if (cacheDir.existsSync()) {
        for (final entry in cacheDir.listSync()) {
          if (entry is File && entry.path.endsWith('.db')) {
            final fileName = entry.uri.pathSegments.last;
            final serverId = fileName.replaceAll('.db', '');
            final db = await _openDb(serverId);
            final msgCount = db.select('SELECT COUNT(*) as cnt FROM messages');
            final roomCount = db.select('SELECT COUNT(*) as cnt FROM rooms');
            serverInfos.add({
              'serverId': serverId,
              'messages': msgCount.first['cnt'] as int,
              'rooms': roomCount.first['cnt'] as int,
              'sizeBytes': entry.lengthSync(),
              'path': entry.path,
            });
          }
        }
      }
    } catch (e) {
      return {'error': '$e'};
    }
    return {'servers': serverInfos};
  }

  /// Clear all cached data for a specific server.
  Future<void> clearServer(String serverId) async {
    try {
      final db = await _openDb(serverId);
      db.execute('DELETE FROM messages');
      db.execute('DELETE FROM rooms');
      db.execute('VACUUM');
    } catch (e) {
      LogService().log('XmppCacheService: clearServer error: $e');
    }
  }

  /// Clear all cached data across all servers.
  Future<void> clear() async {
    try {
      final cacheDirAbs = _storage.getAbsolutePath(_cacheDirPath());
      final cacheDir = Directory(cacheDirAbs);
      if (cacheDir.existsSync()) {
        for (final entry in cacheDir.listSync()) {
          if (entry is File && entry.path.endsWith('.db')) {
            final fileName = entry.uri.pathSegments.last;
            final serverId = fileName.replaceAll('.db', '');
            await clearServer(serverId);
          }
        }
      }
    } catch (e) {
      LogService().log('XmppCacheService: clear error: $e');
    }
  }

  void _prune(Database db) {
    try {
      final countResult = db.select('SELECT COUNT(*) as cnt FROM messages');
      final count = countResult.first['cnt'] as int;
      if (count > _maxMessages) {
        final excess = count - _maxMessages;
        db.execute(
          'DELETE FROM messages WHERE id IN '
          '(SELECT id FROM messages ORDER BY timestamp ASC LIMIT ?)',
          [excess],
        );
      }
    } catch (e) {
      LogService().log('XmppCacheService: prune error: $e');
    }
  }

  XmppMessage _rowToMessage(String serverId, Row row) {
    final typeName = row['type'] as String;
    final type = XmppMessageType.values.firstWhere(
      (t) => t.name == typeName,
      orElse: () => XmppMessageType.groupchat,
    );
    return XmppMessage(
      serverConfigId: serverId,
      roomJid: row['room_jid'] as String,
      sender: row['sender'] as String,
      senderJid: row['sender_jid'] as String?,
      text: row['text'] as String,
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        row['timestamp'] as int,
        isUtc: true,
      ),
      type: type,
      isOutgoing: (row['is_outgoing'] as int) == 1,
      stanzaId: row['stanza_id'] as String?,
    );
  }

  void dispose() {
    for (final db in _dbs.values) {
      db.dispose();
    }
    _dbs.clear();
  }
}
