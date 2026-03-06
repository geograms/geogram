/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * SQLite cache for Meshtastic — messages, nodes, channels.
 *
 * Storage layout:
 *   teleport/meshtastic/config.json              # connection config
 *   teleport/meshtastic/cache/meshtastic.db      # messages, nodes, channels
 */

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import '../../services/log_service.dart';
import '../../services/profile_storage.dart';
import '../../services/sqlite_loader.dart';
import 'models/meshtastic_channel.dart';
import 'models/meshtastic_config.dart';
import 'models/meshtastic_message.dart';
import 'models/meshtastic_node.dart';

class MeshtasticCacheService {
  final ProfileStorage _storage;
  Database? _db;

  static const int _maxMessages = 10000;

  MeshtasticCacheService(this._storage);

  String _baseDirPath() => 'teleport/meshtastic';
  String _cacheDirPath() => '${_baseDirPath()}/cache';
  String _dbPath() => '${_cacheDirPath()}/meshtastic.db';
  String _configPath() => '${_baseDirPath()}/config.json';

  // ---------------------------------------------------------------------------
  // Config persistence
  // ---------------------------------------------------------------------------

  Future<void> saveConfig(MeshtasticConfig config) async {
    try {
      await _storage.createDirectory(_baseDirPath());
      await _storage.writeString(
        _configPath(),
        const JsonEncoder.withIndent('  ').convert(config.toJson()),
      );
    } catch (e) {
      LogService().log('MeshtasticCache: saveConfig error: $e');
    }
  }

  Future<MeshtasticConfig?> loadConfig() async {
    try {
      final str = await _storage.readString(_configPath());
      if (str == null) return null;
      return MeshtasticConfig.fromJson(
        jsonDecode(str) as Map<String, dynamic>,
      );
    } catch (e) {
      LogService().log('MeshtasticCache: loadConfig error: $e');
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
      CREATE TABLE IF NOT EXISTS nodes (
        node_num INTEGER PRIMARY KEY,
        user_id TEXT NOT NULL DEFAULT '',
        long_name TEXT NOT NULL DEFAULT '',
        short_name TEXT NOT NULL DEFAULT '',
        hw_model INTEGER NOT NULL DEFAULT 0,
        latitude REAL,
        longitude REAL,
        altitude INTEGER NOT NULL DEFAULT 0,
        snr REAL NOT NULL DEFAULT 0,
        last_heard INTEGER NOT NULL DEFAULT 0,
        battery_level INTEGER NOT NULL DEFAULT 0,
        voltage REAL NOT NULL DEFAULT 0
      )
    ''');

    _db!.execute('''
      CREATE TABLE IF NOT EXISTS channels (
        idx INTEGER PRIMARY KEY,
        name TEXT NOT NULL DEFAULT '',
        psk TEXT NOT NULL DEFAULT '',
        role TEXT NOT NULL DEFAULT 'disabled'
      )
    ''');

    _db!.execute('''
      CREATE TABLE IF NOT EXISTS messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        channel_index INTEGER NOT NULL DEFAULT 0,
        from_node INTEGER NOT NULL,
        to_node INTEGER NOT NULL,
        text TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        direction TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        rx_snr REAL,
        rx_rssi INTEGER,
        hop_start INTEGER NOT NULL DEFAULT 0,
        hop_limit INTEGER NOT NULL DEFAULT 3,
        sender_long_name TEXT NOT NULL DEFAULT '',
        sender_short_name TEXT NOT NULL DEFAULT '',
        packet_id INTEGER NOT NULL DEFAULT 0
      )
    ''');

    _db!.execute('''
      CREATE INDEX IF NOT EXISTS idx_meshtastic_messages_channel
      ON messages(channel_index, timestamp DESC)
    ''');

    _db!.execute('''
      CREATE INDEX IF NOT EXISTS idx_meshtastic_messages_timestamp
      ON messages(timestamp DESC)
    ''');

    _db!.execute('''
      CREATE INDEX IF NOT EXISTS idx_meshtastic_messages_packet
      ON messages(packet_id)
    ''');

    _prune();
    return _db!;
  }

  // ---------------------------------------------------------------------------
  // Nodes
  // ---------------------------------------------------------------------------

  Future<void> saveNode(MeshtasticNode node) async {
    try {
      final db = await _openDb();
      db.execute(
        '''INSERT OR REPLACE INTO nodes
           (node_num, user_id, long_name, short_name, hw_model,
            latitude, longitude, altitude, snr, last_heard,
            battery_level, voltage)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
        [
          node.nodeNum,
          node.userId,
          node.longName,
          node.shortName,
          node.hwModel,
          node.latitude,
          node.longitude,
          node.altitude,
          node.snr,
          node.lastHeard,
          node.batteryLevel,
          node.voltage,
        ],
      );
    } catch (e) {
      LogService().log('MeshtasticCache: saveNode error: $e');
    }
  }

  Future<void> saveNodes(List<MeshtasticNode> nodes) async {
    if (nodes.isEmpty) return;
    try {
      final db = await _openDb();
      db.execute('BEGIN');
      try {
        final stmt = db.prepare(
          '''INSERT OR REPLACE INTO nodes
             (node_num, user_id, long_name, short_name, hw_model,
              latitude, longitude, altitude, snr, last_heard,
              battery_level, voltage)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
        );
        for (final n in nodes) {
          stmt.execute([
            n.nodeNum,
            n.userId,
            n.longName,
            n.shortName,
            n.hwModel,
            n.latitude,
            n.longitude,
            n.altitude,
            n.snr,
            n.lastHeard,
            n.batteryLevel,
            n.voltage,
          ]);
        }
        stmt.dispose();
        db.execute('COMMIT');
      } catch (e) {
        db.execute('ROLLBACK');
        rethrow;
      }
    } catch (e) {
      LogService().log('MeshtasticCache: saveNodes error: $e');
    }
  }

  Future<List<MeshtasticNode>> loadNodes() async {
    try {
      final db = await _openDb();
      final rows =
          db.select('SELECT * FROM nodes ORDER BY last_heard DESC');
      return rows.map(_rowToNode).toList();
    } catch (e) {
      LogService().log('MeshtasticCache: loadNodes error: $e');
      return [];
    }
  }

  // ---------------------------------------------------------------------------
  // Channels
  // ---------------------------------------------------------------------------

  Future<void> saveChannel(MeshtasticChannelConfig channel) async {
    try {
      final db = await _openDb();
      db.execute(
        'INSERT OR REPLACE INTO channels (idx, name, psk, role) VALUES (?, ?, ?, ?)',
        [
          channel.index,
          channel.name,
          base64Encode(channel.psk),
          channel.role.name,
        ],
      );
    } catch (e) {
      LogService().log('MeshtasticCache: saveChannel error: $e');
    }
  }

  Future<List<MeshtasticChannelConfig>> loadChannels() async {
    try {
      final db = await _openDb();
      final rows = db.select('SELECT * FROM channels ORDER BY idx');
      return rows.map((row) {
        Uint8List psk;
        try {
          psk = base64Decode(row['psk'] as String? ?? '');
        } catch (_) {
          psk = Uint8List(0);
        }
        return MeshtasticChannelConfig(
          index: row['idx'] as int,
          name: row['name'] as String? ?? '',
          psk: psk,
          role: MeshtasticChannelRole.values.firstWhere(
            (r) => r.name == row['role'],
            orElse: () => MeshtasticChannelRole.disabled,
          ),
        );
      }).toList();
    } catch (e) {
      LogService().log('MeshtasticCache: loadChannels error: $e');
      return [];
    }
  }

  // ---------------------------------------------------------------------------
  // Messages
  // ---------------------------------------------------------------------------

  Future<int> saveMessage(MeshtasticMessage msg) async {
    try {
      final db = await _openDb();
      db.execute(
        '''INSERT INTO messages
           (channel_index, from_node, to_node, text, timestamp, direction,
            status, rx_snr, rx_rssi, hop_start, hop_limit,
            sender_long_name, sender_short_name, packet_id)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
        [
          msg.channelIndex,
          msg.fromNode,
          msg.toNode,
          msg.text,
          msg.timestamp.millisecondsSinceEpoch,
          msg.direction.name,
          msg.status.name,
          msg.rxSnr,
          msg.rxRssi,
          msg.hopStart,
          msg.hopLimit,
          msg.senderLongName,
          msg.senderShortName,
          msg.packetId,
        ],
      );
      return db.lastInsertRowId;
    } catch (e) {
      LogService().log('MeshtasticCache: saveMessage error: $e');
      return -1;
    }
  }

  Future<void> saveMessages(List<MeshtasticMessage> messages) async {
    if (messages.isEmpty) return;
    try {
      final db = await _openDb();
      db.execute('BEGIN');
      try {
        final stmt = db.prepare(
          '''INSERT INTO messages
             (channel_index, from_node, to_node, text, timestamp, direction,
              status, rx_snr, rx_rssi, hop_start, hop_limit,
              sender_long_name, sender_short_name, packet_id)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
        );
        for (final msg in messages) {
          stmt.execute([
            msg.channelIndex,
            msg.fromNode,
            msg.toNode,
            msg.text,
            msg.timestamp.millisecondsSinceEpoch,
            msg.direction.name,
            msg.status.name,
            msg.rxSnr,
            msg.rxRssi,
            msg.hopStart,
            msg.hopLimit,
            msg.senderLongName,
            msg.senderShortName,
            msg.packetId,
          ]);
        }
        stmt.dispose();
        db.execute('COMMIT');
      } catch (e) {
        db.execute('ROLLBACK');
        rethrow;
      }
    } catch (e) {
      LogService().log('MeshtasticCache: saveMessages error: $e');
    }
  }

  Future<List<MeshtasticMessage>> loadMessages({
    String? conversationId,
    int limit = 200,
  }) async {
    try {
      final db = await _openDb();
      final ResultSet rows;
      if (conversationId != null) {
        if (conversationId.startsWith('ch:')) {
          final chIdx = int.tryParse(conversationId.substring(3)) ?? 0;
          rows = db.select(
            '''SELECT * FROM messages
               WHERE channel_index = ? AND to_node = ?
               ORDER BY timestamp DESC LIMIT ?''',
            [chIdx, 0xFFFFFFFF, limit],
          );
        } else if (conversationId.startsWith('dm:')) {
          final nodeHex = conversationId.substring(3);
          final nodeNum = int.tryParse(nodeHex, radix: 16) ?? 0;
          rows = db.select(
            '''SELECT * FROM messages
               WHERE (from_node = ? OR to_node = ?) AND to_node != ?
               ORDER BY timestamp DESC LIMIT ?''',
            [nodeNum, nodeNum, 0xFFFFFFFF, limit],
          );
        } else {
          rows = db.select(
            'SELECT * FROM messages ORDER BY timestamp DESC LIMIT ?',
            [limit],
          );
        }
      } else {
        rows = db.select(
          'SELECT * FROM messages ORDER BY timestamp DESC LIMIT ?',
          [limit],
        );
      }
      return rows.map(_rowToMessage).toList().reversed.toList();
    } catch (e) {
      LogService().log('MeshtasticCache: loadMessages error: $e');
      return [];
    }
  }

  Future<bool> hasPacket(int packetId) async {
    if (packetId == 0) return false;
    try {
      final db = await _openDb();
      final rows = db.select(
        'SELECT 1 FROM messages WHERE packet_id = ? LIMIT 1',
        [packetId],
      );
      return rows.isNotEmpty;
    } catch (e) {
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Debug
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> inspect() async {
    try {
      final db = await _openDb();
      final msgCount = db.select('SELECT COUNT(*) as cnt FROM messages');
      final nodeCount = db.select('SELECT COUNT(*) as cnt FROM nodes');
      final channelCount = db.select('SELECT COUNT(*) as cnt FROM channels');
      final absPath = _storage.getAbsolutePath(_dbPath());
      final file = File(absPath);
      final size = file.existsSync() ? file.lengthSync() : 0;
      return {
        'messages': msgCount.first['cnt'] as int,
        'nodes': nodeCount.first['cnt'] as int,
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

  MeshtasticMessage _rowToMessage(Row row) => MeshtasticMessage(
        id: row['id'] as int?,
        channelIndex: row['channel_index'] as int? ?? 0,
        fromNode: row['from_node'] as int,
        toNode: row['to_node'] as int,
        text: row['text'] as String,
        timestamp: DateTime.fromMillisecondsSinceEpoch(
          row['timestamp'] as int,
          isUtc: true,
        ),
        direction: MeshtasticMessageDirection.values.firstWhere(
          (d) => d.name == row['direction'],
          orElse: () => MeshtasticMessageDirection.incoming,
        ),
        status: MeshtasticMessageStatus.values.firstWhere(
          (s) => s.name == (row['status'] as String?),
          orElse: () => MeshtasticMessageStatus.pending,
        ),
        rxSnr: row['rx_snr'] as double?,
        rxRssi: row['rx_rssi'] as int?,
        hopStart: row['hop_start'] as int? ?? 0,
        hopLimit: row['hop_limit'] as int? ?? 3,
        senderLongName: row['sender_long_name'] as String? ?? '',
        senderShortName: row['sender_short_name'] as String? ?? '',
        packetId: row['packet_id'] as int? ?? 0,
      );

  MeshtasticNode _rowToNode(Row row) => MeshtasticNode(
        nodeNum: row['node_num'] as int,
        userId: row['user_id'] as String? ?? '',
        longName: row['long_name'] as String? ?? '',
        shortName: row['short_name'] as String? ?? '',
        hwModel: row['hw_model'] as int? ?? 0,
        latitude: row['latitude'] as double?,
        longitude: row['longitude'] as double?,
        altitude: row['altitude'] as int? ?? 0,
        snr: (row['snr'] as num?)?.toDouble() ?? 0.0,
        lastHeard: row['last_heard'] as int? ?? 0,
        batteryLevel: row['battery_level'] as int? ?? 0,
        voltage: (row['voltage'] as num?)?.toDouble() ?? 0.0,
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
      LogService().log('MeshtasticCache: prune error: $e');
    }
  }

  void dispose() {
    _db?.dispose();
    _db = null;
  }
}
