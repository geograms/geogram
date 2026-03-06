/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * SQLite cache for BitChat — single database for messages, peers, channels.
 *
 * Storage layout:
 *   teleport/bitchat/config.json           # identity + settings
 *   teleport/bitchat/cache/bitchat.db      # messages, peers, channels
 */

import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../../services/log_service.dart';
import '../../services/profile_storage.dart';
import '../../services/sqlite_loader.dart';
import 'models/bitchat_channel.dart';
import 'models/bitchat_config.dart';
import 'models/bitchat_message.dart';
import 'models/bitchat_peer.dart';

class BitchatCacheService {
  final ProfileStorage _storage;
  Database? _db;

  static const int _maxMessages = 10000;

  BitchatCacheService(this._storage);

  String _baseDirPath() => 'teleport/bitchat';
  String _cacheDirPath() => '${_baseDirPath()}/cache';
  String _dbPath() => '${_cacheDirPath()}/bitchat.db';
  String _configPath() => '${_baseDirPath()}/config.json';

  // ---------------------------------------------------------------------------
  // Config persistence
  // ---------------------------------------------------------------------------

  Future<void> saveConfig(BitchatConfig config) async {
    try {
      await _storage.createDirectory(_baseDirPath());
      await _storage.writeString(
        _configPath(),
        const JsonEncoder.withIndent('  ').convert(config.toJson()),
      );
    } catch (e) {
      LogService().log('BitchatCache: saveConfig error: $e');
    }
  }

  Future<BitchatConfig?> loadConfig() async {
    try {
      final str = await _storage.readString(_configPath());
      if (str == null) return null;
      return BitchatConfig.fromJson(
        jsonDecode(str) as Map<String, dynamic>,
      );
    } catch (e) {
      LogService().log('BitchatCache: loadConfig error: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Database
  // ---------------------------------------------------------------------------

  Future<Database> _openDb() async {
    if (_db != null) return _db!;

    await _storage.createDirectory(_cacheDirPath());
    final absPath = _storage.getAbsolutePath(_dbPath());
    _db = SQLiteLoader.openDatabase(absPath);

    _db!.execute('''
      CREATE TABLE IF NOT EXISTS messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        uuid TEXT NOT NULL UNIQUE,
        channel_geohash TEXT NOT NULL DEFAULT '',
        sender_id TEXT NOT NULL,
        recipient_id TEXT NOT NULL DEFAULT '',
        sender_nickname TEXT NOT NULL DEFAULT '',
        content TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        direction TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        ttl INTEGER NOT NULL DEFAULT 7,
        hop_count INTEGER NOT NULL DEFAULT 0
      )
    ''');

    _db!.execute('''
      CREATE TABLE IF NOT EXISTS peers (
        public_key_hex TEXT PRIMARY KEY,
        signing_public_key_hex TEXT NOT NULL DEFAULT '',
        nickname TEXT NOT NULL DEFAULT '',
        last_seen INTEGER,
        geohash TEXT NOT NULL DEFAULT '',
        verified INTEGER NOT NULL DEFAULT 0
      )
    ''');

    _db!.execute('''
      CREATE TABLE IF NOT EXISTS channels (
        geohash TEXT PRIMARY KEY,
        precision_ INTEGER NOT NULL DEFAULT 4,
        display_name TEXT NOT NULL DEFAULT '',
        peer_count INTEGER NOT NULL DEFAULT 0,
        last_activity INTEGER,
        unread_count INTEGER NOT NULL DEFAULT 0
      )
    ''');

    _db!.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_conversation
      ON messages(sender_id, timestamp DESC)
    ''');

    _db!.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_channel
      ON messages(channel_geohash, timestamp DESC)
    ''');

    _db!.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_uuid
      ON messages(uuid)
    ''');

    _prune();
    return _db!;
  }

  // ---------------------------------------------------------------------------
  // Messages
  // ---------------------------------------------------------------------------

  Future<int> saveMessage(BitchatMessage msg) async {
    try {
      final db = await _openDb();
      db.execute(
        '''INSERT OR IGNORE INTO messages
           (uuid, channel_geohash, sender_id, recipient_id, sender_nickname,
            content, timestamp, direction, status, ttl, hop_count)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
        [
          msg.uuid,
          msg.channelGeohash,
          msg.senderId,
          msg.recipientId,
          msg.senderNickname,
          msg.content,
          msg.timestamp.millisecondsSinceEpoch,
          msg.direction.name,
          msg.status.name,
          msg.ttl,
          msg.hopCount,
        ],
      );
      return db.lastInsertRowId;
    } catch (e) {
      LogService().log('BitchatCache: saveMessage error: $e');
      return -1;
    }
  }

  Future<void> saveMessages(List<BitchatMessage> messages) async {
    if (messages.isEmpty) return;
    try {
      final db = await _openDb();
      db.execute('BEGIN');
      try {
        final stmt = db.prepare(
          '''INSERT OR IGNORE INTO messages
             (uuid, channel_geohash, sender_id, recipient_id, sender_nickname,
              content, timestamp, direction, status, ttl, hop_count)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
        );
        for (final msg in messages) {
          stmt.execute([
            msg.uuid,
            msg.channelGeohash,
            msg.senderId,
            msg.recipientId,
            msg.senderNickname,
            msg.content,
            msg.timestamp.millisecondsSinceEpoch,
            msg.direction.name,
            msg.status.name,
            msg.ttl,
            msg.hopCount,
          ]);
        }
        stmt.dispose();
        db.execute('COMMIT');
      } catch (e) {
        db.execute('ROLLBACK');
        rethrow;
      }
    } catch (e) {
      LogService().log('BitchatCache: saveMessages error: $e');
    }
  }

  Future<List<BitchatMessage>> loadMessages({
    String? conversationId,
    String? channelGeohash,
    int limit = 200,
  }) async {
    try {
      final db = await _openDb();
      final ResultSet rows;
      if (channelGeohash != null) {
        rows = db.select(
          '''SELECT * FROM messages
             WHERE channel_geohash = ?
             ORDER BY timestamp DESC LIMIT ?''',
          [channelGeohash, limit],
        );
      } else if (conversationId != null) {
        rows = db.select(
          '''SELECT * FROM messages
             WHERE (sender_id = ? OR recipient_id = ?)
               AND channel_geohash = ''
             ORDER BY timestamp DESC LIMIT ?''',
          [conversationId, conversationId, limit],
        );
      } else {
        rows = db.select(
          'SELECT * FROM messages ORDER BY timestamp DESC LIMIT ?',
          [limit],
        );
      }
      return rows.map(_rowToMessage).toList().reversed.toList();
    } catch (e) {
      LogService().log('BitchatCache: loadMessages error: $e');
      return [];
    }
  }

  Future<bool> hasMessage(String uuid) async {
    try {
      final db = await _openDb();
      final rows = db.select(
        'SELECT 1 FROM messages WHERE uuid = ? LIMIT 1',
        [uuid],
      );
      return rows.isNotEmpty;
    } catch (e) {
      return false;
    }
  }

  Future<void> updateMessageStatus(
      String uuid, BitchatMessageStatus status) async {
    try {
      final db = await _openDb();
      db.execute(
        'UPDATE messages SET status = ? WHERE uuid = ?',
        [status.name, uuid],
      );
    } catch (e) {
      LogService().log('BitchatCache: updateMessageStatus error: $e');
    }
  }

  Future<Map<String, BitchatMessage>> getLastMessages() async {
    try {
      final db = await _openDb();
      final rows = db.select('''
        SELECT m.* FROM messages m
        INNER JOIN (
          SELECT
            CASE WHEN channel_geohash != '' THEN 'geo:' || channel_geohash
                 WHEN direction = 'outgoing' THEN recipient_id
                 ELSE sender_id
            END as conv_id,
            MAX(timestamp) as max_ts
          FROM messages
          GROUP BY conv_id
        ) g ON (
          CASE WHEN m.channel_geohash != '' THEN 'geo:' || m.channel_geohash
               WHEN m.direction = 'outgoing' THEN m.recipient_id
               ELSE m.sender_id
          END = g.conv_id
          AND m.timestamp = g.max_ts
        )
        ORDER BY m.timestamp DESC
      ''');
      final result = <String, BitchatMessage>{};
      for (final row in rows) {
        final msg = _rowToMessage(row);
        result[msg.conversationId] = msg;
      }
      return result;
    } catch (e) {
      LogService().log('BitchatCache: getLastMessages error: $e');
      return {};
    }
  }

  // ---------------------------------------------------------------------------
  // Peers
  // ---------------------------------------------------------------------------

  Future<void> savePeer(BitchatPeer peer) async {
    try {
      final db = await _openDb();
      db.execute(
        '''INSERT OR REPLACE INTO peers
           (public_key_hex, signing_public_key_hex, nickname, last_seen,
            geohash, verified)
           VALUES (?, ?, ?, ?, ?, ?)''',
        [
          peer.publicKeyHex,
          peer.signingPublicKeyHex,
          peer.nickname,
          peer.lastSeen?.millisecondsSinceEpoch,
          peer.geohash,
          peer.verified ? 1 : 0,
        ],
      );
    } catch (e) {
      LogService().log('BitchatCache: savePeer error: $e');
    }
  }

  Future<List<BitchatPeer>> loadPeers() async {
    try {
      final db = await _openDb();
      final rows =
          db.select('SELECT * FROM peers ORDER BY last_seen DESC');
      return rows.map(_rowToPeer).toList();
    } catch (e) {
      LogService().log('BitchatCache: loadPeers error: $e');
      return [];
    }
  }

  Future<BitchatPeer?> findPeerById(String senderId) async {
    try {
      final db = await _openDb();
      final rows = db.select(
        'SELECT * FROM peers WHERE public_key_hex LIKE ?',
        ['$senderId%'],
      );
      if (rows.isEmpty) return null;
      return _rowToPeer(rows.first);
    } catch (e) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Channels
  // ---------------------------------------------------------------------------

  Future<void> saveChannel(BitchatChannel channel) async {
    try {
      final db = await _openDb();
      db.execute(
        '''INSERT OR REPLACE INTO channels
           (geohash, precision_, display_name, peer_count, last_activity,
            unread_count)
           VALUES (?, ?, ?, ?, ?, ?)''',
        [
          channel.geohash,
          channel.precision,
          channel.displayName,
          channel.peerCount,
          channel.lastActivity?.millisecondsSinceEpoch,
          channel.unreadCount,
        ],
      );
    } catch (e) {
      LogService().log('BitchatCache: saveChannel error: $e');
    }
  }

  Future<List<BitchatChannel>> loadChannels() async {
    try {
      final db = await _openDb();
      final rows = db.select(
          'SELECT * FROM channels ORDER BY last_activity DESC');
      return rows.map(_rowToChannel).toList();
    } catch (e) {
      LogService().log('BitchatCache: loadChannels error: $e');
      return [];
    }
  }

  // ---------------------------------------------------------------------------
  // Debug
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> inspect() async {
    try {
      final db = await _openDb();
      final msgCount = db.select('SELECT COUNT(*) as cnt FROM messages');
      final peerCount = db.select('SELECT COUNT(*) as cnt FROM peers');
      final channelCount = db.select('SELECT COUNT(*) as cnt FROM channels');
      final absPath = _storage.getAbsolutePath(_dbPath());
      final file = File(absPath);
      final size = file.existsSync() ? file.lengthSync() : 0;
      return {
        'messages': msgCount.first['cnt'] as int,
        'peers': peerCount.first['cnt'] as int,
        'channels': channelCount.first['cnt'] as int,
        'sizeBytes': size,
        'path': absPath,
      };
    } catch (e) {
      return {'error': '$e'};
    }
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  BitchatMessage _rowToMessage(Row row) => BitchatMessage(
        id: row['id'] as int?,
        uuid: row['uuid'] as String,
        channelGeohash: row['channel_geohash'] as String? ?? '',
        senderId: row['sender_id'] as String,
        recipientId: row['recipient_id'] as String? ?? '',
        senderNickname: row['sender_nickname'] as String? ?? '',
        content: row['content'] as String,
        timestamp: DateTime.fromMillisecondsSinceEpoch(
          row['timestamp'] as int,
          isUtc: true,
        ),
        direction: BitchatMessageDirection.values.firstWhere(
          (d) => d.name == row['direction'],
          orElse: () => BitchatMessageDirection.incoming,
        ),
        status: BitchatMessageStatus.values.firstWhere(
          (s) => s.name == (row['status'] as String?),
          orElse: () => BitchatMessageStatus.pending,
        ),
        ttl: row['ttl'] as int? ?? 7,
        hopCount: row['hop_count'] as int? ?? 0,
      );

  BitchatPeer _rowToPeer(Row row) => BitchatPeer(
        publicKeyHex: row['public_key_hex'] as String,
        signingPublicKeyHex:
            row['signing_public_key_hex'] as String? ?? '',
        nickname: row['nickname'] as String? ?? '',
        lastSeen: row['last_seen'] != null
            ? DateTime.fromMillisecondsSinceEpoch(
                row['last_seen'] as int,
                isUtc: true,
              )
            : null,
        geohash: row['geohash'] as String? ?? '',
        verified: (row['verified'] as int?) == 1,
      );

  BitchatChannel _rowToChannel(Row row) => BitchatChannel(
        geohash: row['geohash'] as String,
        precision: row['precision_'] as int? ?? 4,
        displayName: row['display_name'] as String? ?? '',
        peerCount: row['peer_count'] as int? ?? 0,
        lastActivity: row['last_activity'] != null
            ? DateTime.fromMillisecondsSinceEpoch(
                row['last_activity'] as int,
                isUtc: true,
              )
            : null,
        unreadCount: row['unread_count'] as int? ?? 0,
      );

  void _prune() {
    try {
      final db = _db;
      if (db == null) return;
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
      LogService().log('BitchatCache: prune error: $e');
    }
  }

  void dispose() {
    _db?.dispose();
    _db = null;
  }
}
