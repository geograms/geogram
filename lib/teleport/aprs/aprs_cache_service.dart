/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * SQLite packet cache for APRS-IS.
 * Single database stores all received packets for offline browsing.
 *
 * Storage layout:
 *   {prefix}/teleport/aprs/cache/packets.db
 *
 * Follows the SignalCacheService pattern.
 */

import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../../services/log_service.dart';
import '../../services/profile_storage.dart';
import '../../services/sqlite_loader.dart';
import 'models/aprs_packet.dart';

class AprsCacheService {
  final ProfileStorage _storage;
  final String _prefix;
  Database? _db;

  static const int _maxPackets = 10000;

  AprsCacheService(this._storage, this._prefix);

  String _baseDirPath() {
    final pfx = _prefix.isEmpty ? '' : '$_prefix/';
    return '${pfx}teleport/aprs';
  }

  String _cacheDirPath() => '${_baseDirPath()}/cache';

  String _dbPath() => '${_cacheDirPath()}/packets.db';

  String _configPath() => '${_baseDirPath()}/config.json';

  /// Save APRS config (enabled state, callsign, radius) for auto-start.
  Future<void> saveConfig(Map<String, dynamic> config) async {
    try {
      await _storage.createDirectory(_baseDirPath());
      await _storage.writeString(
        _configPath(),
        const JsonEncoder.withIndent('  ').convert(config),
      );
    } catch (e) {
      LogService().log('AprsCacheService: saveConfig error: $e');
    }
  }

  /// Load saved APRS config. Returns null if not found.
  Future<Map<String, dynamic>?> loadConfig() async {
    try {
      final str = await _storage.readString(_configPath());
      if (str == null) return null;
      return jsonDecode(str) as Map<String, dynamic>;
    } catch (e) {
      LogService().log('AprsCacheService: loadConfig error: $e');
      return null;
    }
  }

  /// Ensure the cache directory exists and open the database.
  Future<Database> _openDb() async {
    if (_db != null) return _db!;

    await _storage.createDirectory(_cacheDirPath());
    final absPath = _storage.getAbsolutePath(_dbPath());
    _db = SQLiteLoader.openDatabase(absPath);

    _db!.execute('''
      CREATE TABLE IF NOT EXISTS packets (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        from_callsign TEXT NOT NULL,
        to_callsign TEXT NOT NULL,
        path TEXT,
        info_field TEXT NOT NULL,
        raw_tnc2 TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        type TEXT NOT NULL,
        latitude REAL,
        longitude REAL,
        message_text TEXT,
        message_id TEXT,
        is_acked INTEGER NOT NULL DEFAULT 0
      );
    ''');
    // Migration: add columns to existing DBs
    _addColumnIfMissing('latitude', 'REAL');
    _addColumnIfMissing('longitude', 'REAL');
    _addColumnIfMissing('message_addressee', 'TEXT');
    _addColumnIfMissing('is_outgoing', 'INTEGER');
    _addColumnIfMissing('comment', 'TEXT');
    _db!.execute('''
      CREATE INDEX IF NOT EXISTS idx_packets_timestamp
      ON packets(timestamp DESC);
    ''');
    _db!.execute('''
      CREATE INDEX IF NOT EXISTS idx_packets_type
      ON packets(type);
    ''');
    _db!.execute('''
      CREATE INDEX IF NOT EXISTS idx_packets_addressee
      ON packets(message_addressee);
    ''');

    // Auto-prune to max size
    _prune();

    return _db!;
  }

  /// Insert a single packet into the cache.
  Future<void> cachePacket(AprsPacket packet) async {
    try {
      final db = await _openDb();
      db.execute(
        '''INSERT INTO packets
           (from_callsign, to_callsign, path, info_field, raw_tnc2,
            timestamp, type, latitude, longitude, message_addressee,
            message_text, message_id, is_acked, is_outgoing, comment)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
        [
          packet.fromCallsign,
          packet.toCallsign,
          packet.path,
          packet.infoField,
          packet.rawTnc2,
          packet.timestamp.millisecondsSinceEpoch,
          packet.type.name,
          packet.latitude,
          packet.longitude,
          packet.messageAddressee,
          packet.messageText,
          packet.messageId,
          packet.isAcked ? 1 : 0,
          packet.isOutgoing ? 1 : 0,
          packet.comment,
        ],
      );
    } catch (e) {
      LogService().log('AprsCacheService: cachePacket error: $e');
    }
  }

  /// Insert a batch of packets in a single transaction.
  Future<void> cachePackets(List<AprsPacket> packets) async {
    if (packets.isEmpty) return;
    try {
      final db = await _openDb();
      db.execute('BEGIN');
      try {
        final stmt = db.prepare(
          '''INSERT INTO packets
             (from_callsign, to_callsign, path, info_field, raw_tnc2,
              timestamp, type, latitude, longitude, message_addressee,
              message_text, message_id, is_acked, is_outgoing, comment)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
        );
        for (final packet in packets) {
          stmt.execute([
            packet.fromCallsign,
            packet.toCallsign,
            packet.path,
            packet.infoField,
            packet.rawTnc2,
            packet.timestamp.millisecondsSinceEpoch,
            packet.type.name,
            packet.latitude,
            packet.longitude,
            packet.messageAddressee,
            packet.messageText,
            packet.messageId,
            packet.isAcked ? 1 : 0,
            packet.isOutgoing ? 1 : 0,
            packet.comment,
          ]);
        }
        stmt.dispose();
        db.execute('COMMIT');
      } catch (e) {
        db.execute('ROLLBACK');
        rethrow;
      }
    } catch (e) {
      LogService().log('AprsCacheService: cachePackets error: $e');
    }
  }

  /// Load the newest [limit] packets, returned oldest-first.
  Future<List<AprsPacket>> loadPackets({int limit = 2000}) async {
    try {
      final db = await _openDb();
      final result = db.select(
        '''SELECT from_callsign, to_callsign, path, info_field, raw_tnc2,
                  timestamp, type, latitude, longitude, message_addressee,
                  message_text, message_id, is_acked, is_outgoing, comment
           FROM packets ORDER BY timestamp DESC LIMIT ?''',
        [limit],
      );

      final packets = <AprsPacket>[];
      for (final row in result) {
        packets.add(_rowToPacket(row));
      }
      return packets.reversed.toList(); // oldest-first
    } catch (e) {
      LogService().log('AprsCacheService: loadPackets error: $e');
      return [];
    }
  }

  /// Debug: return row count and DB file size.
  Future<Map<String, dynamic>> inspect() async {
    try {
      final db = await _openDb();
      final countResult = db.select('SELECT COUNT(*) as cnt FROM packets');
      final count = countResult.first['cnt'] as int;
      final absPath = _storage.getAbsolutePath(_dbPath());
      final file = File(absPath);
      final size = file.existsSync() ? file.lengthSync() : 0;
      return {'count': count, 'sizeBytes': size, 'path': absPath};
    } catch (e) {
      return {'error': '$e'};
    }
  }

  /// Delete all cached packets.
  Future<void> clear() async {
    try {
      final db = await _openDb();
      db.execute('DELETE FROM packets');
      db.execute('VACUUM');
    } catch (e) {
      LogService().log('AprsCacheService: clear error: $e');
    }
  }

  /// Delete cached message packets involving [callsign] (as sender or addressee).
  Future<void> deleteByCallsign(String callsign) async {
    try {
      final db = await _openDb();
      final upper = callsign.toUpperCase();
      db.execute(
        '''DELETE FROM packets WHERE type = 'message'
           AND (UPPER(from_callsign) = ? OR UPPER(message_addressee) = ?)''',
        [upper, upper],
      );
    } catch (e) {
      LogService().log('AprsCacheService: deleteByCallsign error: $e');
    }
  }

  /// Delete all cached message-type packets (preserves stream/position packets).
  Future<void> deleteAllMessages() async {
    try {
      final db = await _openDb();
      db.execute("DELETE FROM packets WHERE type = 'message'");
    } catch (e) {
      LogService().log('AprsCacheService: deleteAllMessages error: $e');
    }
  }

  /// Add a column to the packets table if it doesn't already exist.
  void _addColumnIfMissing(String column, String type) {
    try {
      final result = _db!.select("PRAGMA table_info('packets')");
      final hasColumn = result.any((r) => r['name'] == column);
      if (!hasColumn) {
        _db!.execute('ALTER TABLE packets ADD COLUMN $column $type');
      }
    } catch (_) {}
  }

  /// Prune to [_maxPackets] by deleting oldest rows.
  void _prune() {
    try {
      final db = _db;
      if (db == null) return;
      final countResult = db.select('SELECT COUNT(*) as cnt FROM packets');
      final count = countResult.first['cnt'] as int;
      if (count > _maxPackets) {
        final excess = count - _maxPackets;
        db.execute(
          'DELETE FROM packets WHERE id IN '
          '(SELECT id FROM packets ORDER BY timestamp ASC LIMIT ?)',
          [excess],
        );
      }
    } catch (e) {
      LogService().log('AprsCacheService: prune error: $e');
    }
  }

  AprsPacket _rowToPacket(Row row) {
    final typeName = row['type'] as String;
    final type = AprsPacketType.values.firstWhere(
      (t) => t.name == typeName,
      orElse: () => AprsPacketType.other,
    );
    return AprsPacket(
      fromCallsign: row['from_callsign'] as String,
      toCallsign: row['to_callsign'] as String,
      path: row['path'] as String?,
      infoField: row['info_field'] as String,
      rawTnc2: row['raw_tnc2'] as String,
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        row['timestamp'] as int,
        isUtc: true,
      ),
      type: type,
      latitude: row['latitude'] as double?,
      longitude: row['longitude'] as double?,
      messageAddressee: row['message_addressee'] as String?,
      messageText: row['message_text'] as String?,
      messageId: row['message_id'] as String?,
      isAcked: (row['is_acked'] as int) == 1,
      isOutgoing: (row['is_outgoing'] as int?) == 1,
      comment: row['comment'] as String?,
    );
  }

  /// Close the database.
  void dispose() {
    _db?.dispose();
    _db = null;
  }
}
