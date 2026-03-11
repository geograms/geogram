/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../models/station_activity_event.dart';
import 'sqlite_loader.dart';

class StationActivityInsertResult {
  final StationActivityEvent event;
  final bool inserted;

  const StationActivityInsertResult({
    required this.event,
    required this.inserted,
  });
}

/// SQLite-backed feed storage for station activity.
class StationActivityStore {
  final String baseDir;
  final int maxEvents;
  final void Function(String level, String message)? log;

  Database? _db;

  StationActivityStore({
    required this.baseDir,
    this.maxEvents = 100000,
    this.log,
  });

  String get activityDir => p.join(baseDir, 'activity');
  String get dbPath => p.join(activityDir, 'activity.sqlite3');

  Future<void> initialize() async {
    if (_db != null) {
      return;
    }
    final dir = Directory(activityDir);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }

    final db = SQLiteLoader.openDatabase(dbPath);
    _db = db;
    _initSchema(db);
  }

  void close() {
    _db?.dispose();
    _db = null;
  }

  Future<int> latestIndex() async {
    final db = await _readyDb();
    final rows = db.select(
      'SELECT COALESCE(MAX(idx), 0) AS latest_index FROM activity_events;',
    );
    return (rows.first['latest_index'] as int?) ?? 0;
  }

  Future<StationActivityInsertResult> insertEvent(
    StationActivityEvent event,
  ) async {
    final db = await _readyDb();
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    db.execute(
      '''
      INSERT OR IGNORE INTO activity_events (
        event_id,
        app_type,
        action,
        source_id,
        source_name,
        author_callsign,
        author_npub,
        summary,
        date_text,
        visibility,
        allowed_groups_json,
        allowed_npubs_json,
        metadata_json,
        received_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      ''',
      [
        event.id,
        event.appType,
        event.action,
        event.sourceId,
        event.sourceName,
        event.authorCallsign,
        event.authorNpub,
        event.summary,
        event.date,
        event.visibility,
        jsonEncode(event.allowedGroups),
        jsonEncode(event.allowedNpubs),
        jsonEncode(event.metadata),
        now,
      ],
    );

    final inserted = db.updatedRows > 0;
    final stored = _lookupByEventId(db, event.id);
    if (stored == null) {
      throw StateError('Activity row missing after insert: ${event.id}');
    }

    if (inserted) {
      await _prune(db);
    }

    return StationActivityInsertResult(event: stored, inserted: inserted);
  }

  Future<List<StationActivityEvent>> listEvents({
    int? sinceIndex,
    int limit = 50,
    List<String>? appTypes,
    bool publicOnly = false,
  }) async {
    final db = await _readyDb();
    final where = <String>[];
    final args = <Object?>[];

    if (sinceIndex != null && sinceIndex > 0) {
      where.add('idx > ?');
      args.add(sinceIndex);
    }
    if (publicOnly) {
      where.add('visibility = ?');
      args.add('public');
    }
    if (appTypes != null && appTypes.isNotEmpty) {
      where.add(
        'app_type IN (${List.filled(appTypes.length, '?').join(', ')})',
      );
      args.addAll(appTypes);
    }

    final sql = StringBuffer('''
      SELECT
        idx,
        event_id,
        app_type,
        action,
        source_id,
        source_name,
        author_callsign,
        author_npub,
        summary,
        date_text,
        visibility,
        allowed_groups_json,
        allowed_npubs_json,
        metadata_json,
        received_at
      FROM activity_events
      ''');
    if (where.isNotEmpty) {
      sql.write(' WHERE ${where.join(' AND ')}');
    }
    sql.write(' ORDER BY idx DESC LIMIT ?;');
    args.add(limit.clamp(1, 1000));

    final rows = db.select(sql.toString(), args);
    return rows.map(_rowToEvent).toList();
  }

  void _initSchema(Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS activity_events (
        idx INTEGER PRIMARY KEY AUTOINCREMENT,
        event_id TEXT NOT NULL UNIQUE,
        app_type TEXT NOT NULL,
        action TEXT NOT NULL,
        source_id TEXT NOT NULL,
        source_name TEXT NOT NULL,
        author_callsign TEXT NOT NULL,
        author_npub TEXT,
        summary TEXT NOT NULL,
        date_text TEXT NOT NULL,
        visibility TEXT NOT NULL,
        allowed_groups_json TEXT NOT NULL DEFAULT '[]',
        allowed_npubs_json TEXT NOT NULL DEFAULT '[]',
        metadata_json TEXT NOT NULL DEFAULT '{}',
        received_at INTEGER NOT NULL
      );
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS activity_events_visibility_idx
      ON activity_events(visibility, idx DESC);
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS activity_events_app_idx
      ON activity_events(app_type, idx DESC);
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS activity_events_author_idx
      ON activity_events(author_npub, idx DESC);
    ''');
  }

  Future<Database> _readyDb() async {
    await initialize();
    return _db!;
  }

  StationActivityEvent? _lookupByEventId(Database db, String eventId) {
    final rows = db.select(
      '''
      SELECT
        idx,
        event_id,
        app_type,
        action,
        source_id,
        source_name,
        author_callsign,
        author_npub,
        summary,
        date_text,
        visibility,
        allowed_groups_json,
        allowed_npubs_json,
        metadata_json,
        received_at
      FROM activity_events
      WHERE event_id = ?
      LIMIT 1;
      ''',
      [eventId],
    );
    if (rows.isEmpty) {
      return null;
    }
    return _rowToEvent(rows.first);
  }

  Future<void> _prune(Database db) async {
    final countRows = db.select(
      'SELECT COUNT(*) AS total_count FROM activity_events;',
    );
    final totalCount = (countRows.first['total_count'] as int?) ?? 0;
    final toDelete = totalCount - maxEvents;
    if (toDelete <= 0) {
      return;
    }

    db.execute(
      '''
      DELETE FROM activity_events
      WHERE idx IN (
        SELECT idx
        FROM activity_events
        ORDER BY idx ASC
        LIMIT ?
      );
      ''',
      [toDelete],
    );
    _log('INFO', 'Pruned $toDelete activity rows');
  }

  StationActivityEvent _rowToEvent(Row row) {
    return StationActivityEvent(
      id: row['event_id'] as String? ?? '',
      appType: row['app_type'] as String? ?? '',
      action: row['action'] as String? ?? '',
      sourceId: row['source_id'] as String? ?? '',
      sourceName: row['source_name'] as String? ?? '',
      authorCallsign: row['author_callsign'] as String? ?? '',
      authorNpub: row['author_npub'] as String?,
      summary: row['summary'] as String? ?? '',
      date: row['date_text'] as String? ?? '',
      visibility: row['visibility'] as String? ?? 'public',
      allowedGroups: _decodeStringList(row['allowed_groups_json'] as String?),
      allowedNpubs: _decodeStringList(row['allowed_npubs_json'] as String?),
      metadata: _decodeMap(row['metadata_json'] as String?),
      index: row['idx'] as int?,
      receivedAt: row['received_at'] as int?,
    );
  }

  List<String> _decodeStringList(String? raw) {
    if (raw == null || raw.isEmpty) {
      return const [];
    }
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded.map((value) => value.toString()).toList();
    } catch (_) {
      return const [];
    }
  }

  Map<String, dynamic> _decodeMap(String? raw) {
    if (raw == null || raw.isEmpty) {
      return const {};
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return decoded.cast<String, dynamic>();
      }
    } catch (_) {}
    return const {};
  }

  void _log(String level, String message) {
    log?.call(level, message);
  }
}
