/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * SQLite persistence for MeshCore messages, contacts, channels, and config.
 * Follows the AprsCacheService pattern with ProfileStorage abstraction.
 *
 * Storage layout:
 *   {prefix}/teleport/meshcore/cache/meshcore.db
 */

import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../../services/log_service.dart';
import '../../services/profile_storage.dart';
import '../../services/sqlite_loader.dart';
import 'models/meshcore_channel.dart';
import 'models/meshcore_contact.dart';
import 'models/meshcore_message.dart';

class MeshCoreCacheService {
  final ProfileStorage _storage;
  final String _prefix;
  Database? _db;

  static const int _maxMessages = 10000;

  MeshCoreCacheService(this._storage, this._prefix);

  String _baseDirPath() {
    final pfx = _prefix.isEmpty ? '' : '$_prefix/';
    return '${pfx}teleport/meshcore';
  }

  String _cacheDirPath() => '${_baseDirPath()}/cache';
  String _dbPath() => '${_cacheDirPath()}/meshcore.db';
  String _configPath() => '${_baseDirPath()}/config.json';

  // ---------------------------------------------------------------------------
  // Config
  // ---------------------------------------------------------------------------

  Future<void> saveConfig(Map<String, dynamic> config) async {
    try {
      await _storage.createDirectory(_baseDirPath());
      await _storage.writeString(
        _configPath(),
        const JsonEncoder.withIndent('  ').convert(config),
      );
    } catch (e) {
      LogService().log('MeshCoreCache: saveConfig error: $e');
    }
  }

  Future<Map<String, dynamic>?> loadConfig() async {
    try {
      final str = await _storage.readString(_configPath());
      if (str == null) return null;
      return jsonDecode(str) as Map<String, dynamic>;
    } catch (e) {
      LogService().log('MeshCoreCache: loadConfig error: $e');
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
      CREATE TABLE IF NOT EXISTS contacts (
        pub_key_hex TEXT PRIMARY KEY,
        name TEXT NOT NULL DEFAULT '',
        last_seen INTEGER,
        last_snr REAL,
        is_repeater INTEGER NOT NULL DEFAULT 0
      )
    ''');

    _db!.execute('''
      CREATE TABLE IF NOT EXISTS channels (
        idx INTEGER PRIMARY KEY,
        name TEXT NOT NULL DEFAULT ''
      )
    ''');

    _db!.execute('''
      CREATE TABLE IF NOT EXISTS messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        conversation_id TEXT NOT NULL,
        conversation_type TEXT NOT NULL,
        text TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        direction TEXT NOT NULL,
        snr REAL,
        status TEXT NOT NULL DEFAULT 'pending',
        sender_name TEXT,
        sender_key_prefix TEXT
      )
    ''');

    _db!.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_conversation
      ON messages(conversation_id, timestamp DESC)
    ''');

    _db!.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_timestamp
      ON messages(timestamp DESC)
    ''');

    _prune();
    return _db!;
  }

  // ---------------------------------------------------------------------------
  // Contacts
  // ---------------------------------------------------------------------------

  Future<void> saveContact(MeshCoreContact contact) async {
    try {
      final db = await _openDb();
      db.execute(
        '''INSERT OR REPLACE INTO contacts
           (pub_key_hex, name, last_seen, last_snr, is_repeater)
           VALUES (?, ?, ?, ?, ?)''',
        [
          contact.pubKeyHex,
          contact.name,
          contact.lastSeen?.millisecondsSinceEpoch,
          contact.lastSnr,
          contact.isRepeater ? 1 : 0,
        ],
      );
    } catch (e) {
      LogService().log('MeshCoreCache: saveContact error: $e');
    }
  }

  Future<void> saveContacts(List<MeshCoreContact> contacts) async {
    if (contacts.isEmpty) return;
    try {
      final db = await _openDb();
      db.execute('BEGIN');
      try {
        final stmt = db.prepare(
          '''INSERT OR REPLACE INTO contacts
             (pub_key_hex, name, last_seen, last_snr, is_repeater)
             VALUES (?, ?, ?, ?, ?)''',
        );
        for (final c in contacts) {
          stmt.execute([
            c.pubKeyHex,
            c.name,
            c.lastSeen?.millisecondsSinceEpoch,
            c.lastSnr,
            c.isRepeater ? 1 : 0,
          ]);
        }
        stmt.dispose();
        db.execute('COMMIT');
      } catch (e) {
        db.execute('ROLLBACK');
        rethrow;
      }
    } catch (e) {
      LogService().log('MeshCoreCache: saveContacts error: $e');
    }
  }

  Future<List<MeshCoreContact>> loadContacts() async {
    try {
      final db = await _openDb();
      final rows = db.select('SELECT * FROM contacts ORDER BY name');
      return rows.map((row) => MeshCoreContact(
        pubKeyHex: row['pub_key_hex'] as String,
        name: row['name'] as String? ?? '',
        lastSeen: row['last_seen'] != null
            ? DateTime.fromMillisecondsSinceEpoch(
                row['last_seen'] as int,
                isUtc: true,
              )
            : null,
        lastSnr: row['last_snr'] as double?,
        isRepeater: (row['is_repeater'] as int?) == 1,
      )).toList();
    } catch (e) {
      LogService().log('MeshCoreCache: loadContacts error: $e');
      return [];
    }
  }

  /// Find a contact whose pubKeyHex starts with the given prefix.
  Future<MeshCoreContact?> findContactByPrefix(String prefix) async {
    try {
      final db = await _openDb();
      final rows = db.select(
        'SELECT * FROM contacts WHERE pub_key_hex LIKE ?',
        ['$prefix%'],
      );
      if (rows.isEmpty) return null;
      final row = rows.first;
      return MeshCoreContact(
        pubKeyHex: row['pub_key_hex'] as String,
        name: row['name'] as String? ?? '',
        lastSeen: row['last_seen'] != null
            ? DateTime.fromMillisecondsSinceEpoch(
                row['last_seen'] as int,
                isUtc: true,
              )
            : null,
        lastSnr: row['last_snr'] as double?,
        isRepeater: (row['is_repeater'] as int?) == 1,
      );
    } catch (e) {
      LogService().log('MeshCoreCache: findContactByPrefix error: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Channels
  // ---------------------------------------------------------------------------

  Future<void> saveChannel(MeshCoreChannel channel) async {
    try {
      final db = await _openDb();
      db.execute(
        'INSERT OR REPLACE INTO channels (idx, name) VALUES (?, ?)',
        [channel.index, channel.name],
      );
    } catch (e) {
      LogService().log('MeshCoreCache: saveChannel error: $e');
    }
  }

  Future<List<MeshCoreChannel>> loadChannels() async {
    try {
      final db = await _openDb();
      final rows = db.select('SELECT * FROM channels ORDER BY idx');
      return rows.map((row) => MeshCoreChannel(
        index: row['idx'] as int,
        name: row['name'] as String? ?? '',
      )).toList();
    } catch (e) {
      LogService().log('MeshCoreCache: loadChannels error: $e');
      return [];
    }
  }

  // ---------------------------------------------------------------------------
  // Messages
  // ---------------------------------------------------------------------------

  Future<int> saveMessage(MeshCoreMessage msg) async {
    try {
      final db = await _openDb();
      db.execute(
        '''INSERT INTO messages
           (conversation_id, conversation_type, text, timestamp, direction,
            snr, status, sender_name, sender_key_prefix)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)''',
        [
          msg.conversationId,
          msg.conversationType.name,
          msg.text,
          msg.timestamp.millisecondsSinceEpoch,
          msg.direction.name,
          msg.snr,
          msg.status.name,
          msg.senderName,
          msg.senderKeyPrefix,
        ],
      );
      return db.lastInsertRowId;
    } catch (e) {
      LogService().log('MeshCoreCache: saveMessage error: $e');
      return -1;
    }
  }

  Future<List<MeshCoreMessage>> loadMessages({
    String? conversationId,
    int limit = 200,
  }) async {
    try {
      final db = await _openDb();
      final ResultSet rows;
      if (conversationId != null) {
        rows = db.select(
          '''SELECT * FROM messages
             WHERE conversation_id = ?
             ORDER BY timestamp DESC LIMIT ?''',
          [conversationId, limit],
        );
      } else {
        rows = db.select(
          'SELECT * FROM messages ORDER BY timestamp DESC LIMIT ?',
          [limit],
        );
      }
      return rows.map(_rowToMessage).toList().reversed.toList();
    } catch (e) {
      LogService().log('MeshCoreCache: loadMessages error: $e');
      return [];
    }
  }

  Future<void> updateMessageStatus(int messageId, MeshCoreMessageStatus status) async {
    try {
      final db = await _openDb();
      db.execute(
        'UPDATE messages SET status = ? WHERE id = ?',
        [status.name, messageId],
      );
    } catch (e) {
      LogService().log('MeshCoreCache: updateMessageStatus error: $e');
    }
  }

  Future<void> deleteConversation(String conversationId) async {
    try {
      final db = await _openDb();
      db.execute(
        'DELETE FROM messages WHERE conversation_id = ?',
        [conversationId],
      );
    } catch (e) {
      LogService().log('MeshCoreCache: deleteConversation error: $e');
    }
  }

  /// Get the last message for each conversation (for conversation list).
  Future<Map<String, MeshCoreMessage>> getLastMessages() async {
    try {
      final db = await _openDb();
      final rows = db.select('''
        SELECT m.* FROM messages m
        INNER JOIN (
          SELECT conversation_id, MAX(timestamp) as max_ts
          FROM messages
          GROUP BY conversation_id
        ) g ON m.conversation_id = g.conversation_id
           AND m.timestamp = g.max_ts
        ORDER BY m.timestamp DESC
      ''');
      final result = <String, MeshCoreMessage>{};
      for (final row in rows) {
        final msg = _rowToMessage(row);
        result[msg.conversationId] = msg;
      }
      return result;
    } catch (e) {
      LogService().log('MeshCoreCache: getLastMessages error: $e');
      return {};
    }
  }

  // ---------------------------------------------------------------------------
  // Debug
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> inspect() async {
    try {
      final db = await _openDb();
      final msgCount = db.select('SELECT COUNT(*) as cnt FROM messages');
      final contactCount = db.select('SELECT COUNT(*) as cnt FROM contacts');
      final channelCount = db.select('SELECT COUNT(*) as cnt FROM channels');
      final absPath = _storage.getAbsolutePath(_dbPath());
      final file = File(absPath);
      final size = file.existsSync() ? file.lengthSync() : 0;
      return {
        'messages': msgCount.first['cnt'] as int,
        'contacts': contactCount.first['cnt'] as int,
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

  MeshCoreMessage _rowToMessage(Row row) => MeshCoreMessage(
    id: row['id'] as int?,
    conversationId: row['conversation_id'] as String,
    conversationType: MeshCoreConversationType.values.firstWhere(
      (t) => t.name == row['conversation_type'],
      orElse: () => MeshCoreConversationType.contact,
    ),
    text: row['text'] as String,
    timestamp: DateTime.fromMillisecondsSinceEpoch(
      row['timestamp'] as int,
      isUtc: true,
    ),
    direction: MeshCoreMessageDirection.values.firstWhere(
      (d) => d.name == row['direction'],
      orElse: () => MeshCoreMessageDirection.incoming,
    ),
    snr: row['snr'] as double?,
    status: MeshCoreMessageStatus.values.firstWhere(
      (s) => s.name == (row['status'] as String?),
      orElse: () => MeshCoreMessageStatus.pending,
    ),
    senderName: row['sender_name'] as String?,
    senderKeyPrefix: row['sender_key_prefix'] as String?,
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
      LogService().log('MeshCoreCache: prune error: $e');
    }
  }

  void dispose() {
    _db?.dispose();
    _db = null;
  }
}
