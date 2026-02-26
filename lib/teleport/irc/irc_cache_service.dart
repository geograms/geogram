/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * SQLite cache for IRC — one database per server.
 *
 * Storage layout:
 *   teleport/irc/config.json              # server configs (global)
 *   teleport/irc/cache/{serverId}.db      # per-server: channels + messages
 *
 * Each per-server DB has two tables:
 *   channels — joined channel metadata (name, topic, last_activity)
 *   messages — chat messages (channel, sender, text, timestamp, type, is_outgoing)
 */

import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../../services/log_service.dart';
import '../../services/profile_storage.dart';
import '../../services/sqlite_loader.dart';
import 'models/irc_channel.dart';
import 'models/irc_message.dart';
import 'models/irc_server_config.dart';

class IrcCacheService {
  final ProfileStorage _storage;

  /// Open databases keyed by server ID.
  final Map<String, Database> _dbs = {};

  static const int _maxMessages = 10000;

  IrcCacheService(this._storage);

  String _baseDirPath() => 'teleport/irc';
  String _cacheDirPath() => '${_baseDirPath()}/cache';
  String _dbPath(String serverId) => '${_cacheDirPath()}/$serverId.db';
  String _configPath() => '${_baseDirPath()}/config.json';

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
      LogService().log('IrcCacheService: saveConfig error: $e');
    }
  }

  Future<Map<String, dynamic>?> loadConfig() async {
    try {
      final str = await _storage.readString(_configPath());
      if (str == null) return null;
      return jsonDecode(str) as Map<String, dynamic>;
    } catch (e) {
      LogService().log('IrcCacheService: loadConfig error: $e');
      return null;
    }
  }

  Future<void> saveServers(List<IrcServerConfig> servers) async {
    final config = await loadConfig() ?? {};
    config['servers'] = servers.map((s) => s.toJson()).toList();
    await saveConfig(config);
  }

  Future<List<IrcServerConfig>> loadServers() async {
    final config = await loadConfig();
    if (config == null) return [];
    final list = config['servers'] as List<dynamic>? ?? [];
    return list
        .map((e) => IrcServerConfig.fromJson(e as Map<String, dynamic>))
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
      CREATE TABLE IF NOT EXISTS channels (
        name TEXT PRIMARY KEY,
        topic TEXT NOT NULL DEFAULT '',
        last_activity INTEGER NOT NULL DEFAULT 0,
        last_read_ts INTEGER NOT NULL DEFAULT 0
      );
    ''');

    // Migration: add last_read_ts if missing (existing DBs)
    try {
      db.execute('ALTER TABLE channels ADD COLUMN last_read_ts INTEGER NOT NULL DEFAULT 0');
    } catch (_) {
      // Column already exists
    }

    db.execute('''
      CREATE TABLE IF NOT EXISTS messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        channel TEXT NOT NULL,
        sender TEXT NOT NULL,
        text TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        type TEXT NOT NULL,
        is_outgoing INTEGER NOT NULL DEFAULT 0
      );
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_irc_msg_channel_ts
      ON messages(channel, timestamp DESC);
    ''');

    _prune(db);
    _dbs[serverId] = db;
    return db;
  }

  // ---------------------------------------------------------------------------
  // Channel cache
  // ---------------------------------------------------------------------------

  /// Save or update a joined channel's metadata.
  Future<void> saveChannel(String serverId, IrcChannel channel) async {
    try {
      final db = await _openDb(serverId);
      db.execute(
        '''INSERT OR REPLACE INTO channels (name, topic, last_activity, last_read_ts)
           VALUES (?, ?, ?, COALESCE(
             (SELECT last_read_ts FROM channels WHERE name = ?), 0
           ))''',
        [
          channel.name,
          channel.topic,
          channel.lastMessage?.timestamp.millisecondsSinceEpoch ??
              DateTime.now().toUtc().millisecondsSinceEpoch,
          channel.name,
        ],
      );
    } catch (e) {
      LogService().log('IrcCacheService: saveChannel error: $e');
    }
  }

  /// Save multiple channels in a transaction.
  Future<void> saveChannels(String serverId, List<IrcChannel> channels) async {
    if (channels.isEmpty) return;
    try {
      final db = await _openDb(serverId);
      db.execute('BEGIN');
      try {
        for (final ch in channels) {
          db.execute(
            '''INSERT OR REPLACE INTO channels (name, topic, last_activity, last_read_ts)
               VALUES (?, ?, ?, COALESCE(
                 (SELECT last_read_ts FROM channels WHERE name = ?), 0
               ))''',
            [
              ch.name,
              ch.topic,
              ch.lastMessage?.timestamp.millisecondsSinceEpoch ??
                  DateTime.now().toUtc().millisecondsSinceEpoch,
              ch.name,
            ],
          );
        }
        db.execute('COMMIT');
      } catch (e) {
        db.execute('ROLLBACK');
        rethrow;
      }
    } catch (e) {
      LogService().log('IrcCacheService: saveChannels error: $e');
    }
  }

  /// Remove a channel from cache (on part/leave).
  Future<void> removeChannel(String serverId, String channelName) async {
    try {
      final db = await _openDb(serverId);
      db.execute('DELETE FROM channels WHERE name = ?', [channelName]);
    } catch (e) {
      LogService().log('IrcCacheService: removeChannel error: $e');
    }
  }

  /// Load all cached channels for a server, with unread counts computed
  /// from messages newer than the last_read_ts.
  Future<List<IrcChannel>> loadChannels(String serverId) async {
    try {
      final db = await _openDb(serverId);
      final result = db.select('''
        SELECT c.name, c.topic, c.last_activity, c.last_read_ts,
               (SELECT COUNT(*) FROM messages m
                WHERE m.channel = c.name
                  AND m.timestamp > c.last_read_ts
                  AND m.is_outgoing = 0) AS unread
        FROM channels c
        ORDER BY c.last_activity DESC
      ''');
      final channels = <IrcChannel>[];
      for (final row in result) {
        channels.add(IrcChannel(
          serverConfigId: serverId,
          name: row['name'] as String,
          topic: row['topic'] as String? ?? '',
          unreadCount: row['unread'] as int? ?? 0,
        ));
      }
      return channels;
    } catch (e) {
      LogService().log('IrcCacheService: loadChannels error: $e');
      return [];
    }
  }

  /// Mark a channel as read — sets last_read_ts to now.
  Future<void> markChannelRead(String serverId, String channelName) async {
    try {
      final db = await _openDb(serverId);
      db.execute(
        'UPDATE channels SET last_read_ts = ? WHERE name = ?',
        [DateTime.now().toUtc().millisecondsSinceEpoch, channelName],
      );
    } catch (e) {
      LogService().log('IrcCacheService: markChannelRead error: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Message cache
  // ---------------------------------------------------------------------------

  /// Cache a batch of messages for a specific server.
  Future<void> cacheMessages(String serverId, List<IrcMessage> messages) async {
    if (messages.isEmpty) return;
    try {
      final db = await _openDb(serverId);
      db.execute('BEGIN');
      try {
        final stmt = db.prepare(
          '''INSERT INTO messages (channel, sender, text, timestamp, type, is_outgoing)
             VALUES (?, ?, ?, ?, ?, ?)''',
        );
        for (final msg in messages) {
          stmt.execute([
            msg.channel,
            msg.sender,
            msg.text,
            msg.timestamp.millisecondsSinceEpoch,
            msg.type.name,
            msg.isOutgoing ? 1 : 0,
          ]);
        }
        stmt.dispose();
        db.execute('COMMIT');
      } catch (e) {
        db.execute('ROLLBACK');
        rethrow;
      }
    } catch (e) {
      LogService().log('IrcCacheService: cacheMessages error: $e');
    }
  }

  /// Load messages for a channel from a server's DB.
  Future<List<IrcMessage>> loadMessages(
    String serverId,
    String channel, {
    int limit = 500,
  }) async {
    try {
      final db = await _openDb(serverId);
      final result = db.select(
        '''SELECT channel, sender, text, timestamp, type, is_outgoing
           FROM messages
           WHERE channel = ?
           ORDER BY timestamp DESC LIMIT ?''',
        [channel, limit],
      );

      final messages = <IrcMessage>[];
      for (final row in result) {
        messages.add(_rowToMessage(serverId, row));
      }
      return messages.reversed.toList(); // oldest-first
    } catch (e) {
      LogService().log('IrcCacheService: loadMessages error: $e');
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
      // Check which .db files exist
      final cacheDirAbs = _storage.getAbsolutePath(_cacheDirPath());
      final cacheDir = Directory(cacheDirAbs);
      if (cacheDir.existsSync()) {
        for (final entry in cacheDir.listSync()) {
          if (entry is File && entry.path.endsWith('.db')) {
            final fileName = entry.uri.pathSegments.last;
            final serverId = fileName.replaceAll('.db', '');
            final db = await _openDb(serverId);
            final msgCount = db.select('SELECT COUNT(*) as cnt FROM messages');
            final chCount = db.select('SELECT COUNT(*) as cnt FROM channels');
            serverInfos.add({
              'serverId': serverId,
              'messages': msgCount.first['cnt'] as int,
              'channels': chCount.first['cnt'] as int,
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
      db.execute('DELETE FROM channels');
      db.execute('VACUUM');
    } catch (e) {
      LogService().log('IrcCacheService: clearServer error: $e');
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
      LogService().log('IrcCacheService: clear error: $e');
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
      LogService().log('IrcCacheService: prune error: $e');
    }
  }

  IrcMessage _rowToMessage(String serverId, Row row) {
    final typeName = row['type'] as String;
    final type = IrcMessageType.values.firstWhere(
      (t) => t.name == typeName,
      orElse: () => IrcMessageType.privmsg,
    );
    return IrcMessage(
      serverConfigId: serverId,
      channel: row['channel'] as String,
      sender: row['sender'] as String,
      text: row['text'] as String,
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        row['timestamp'] as int,
        isUtc: true,
      ),
      type: type,
      isOutgoing: (row['is_outgoing'] as int) == 1,
    );
  }

  void dispose() {
    for (final db in _dbs.values) {
      db.dispose();
    }
    _dbs.clear();
  }
}
