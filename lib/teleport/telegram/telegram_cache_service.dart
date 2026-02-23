/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Per-chat SQLite message cache for the Telegram bridge.
 * One database per chat keeps things isolated and avoids a single large DB.
 */

import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../../services/log_service.dart';
import '../../services/profile_storage.dart';
import '../../services/sqlite_loader.dart';
import 'models/telegram_message.dart';

/// Manages per-chat SQLite databases for caching Telegram messages.
///
/// Storage layout:
///   {prefix}/telegram/cache/chat_{chatId}.db
class TelegramCacheService {
  final ProfileStorage _storage;
  final String _prefix;
  final Map<int, Database> _openDbs = {};

  TelegramCacheService(this._storage, this._prefix);

  String _cacheDirPath() {
    final pfx = _prefix.isEmpty ? '' : '$_prefix/';
    return '${pfx}telegram/cache';
  }

  /// Ensure the cache directory exists.
  Future<void> ensureCacheDir() async {
    await _storage.createDirectory(_cacheDirPath());
  }

  /// Lazy-open the SQLite database for a given chat ID.
  Database _openDb(int chatId) {
    final existing = _openDbs[chatId];
    if (existing != null) return existing;

    final dbPath = _storage.getAbsolutePath(
        '${_cacheDirPath()}/chat_$chatId.db');
    stderr.writeln('TelegramCache: opening DB at $dbPath');
    final db = SQLiteLoader.openDatabase(dbPath);

    db.execute('''
      CREATE TABLE IF NOT EXISTS messages (
        id INTEGER PRIMARY KEY,
        sender_user_id INTEGER NOT NULL,
        sender_name TEXT,
        content_type TEXT NOT NULL,
        text TEXT,
        date INTEGER NOT NULL,
        is_outgoing INTEGER NOT NULL,
        message_thread_id INTEGER
      );
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_date
      ON messages(date DESC);
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_thread
      ON messages(message_thread_id, date DESC);
    ''');

    // Migrate: add media columns (safe — ignore if already exist)
    _migrateMediaColumns(db);

    _openDbs[chatId] = db;
    return db;
  }

  /// Add media columns via safe ALTER TABLE (ignore duplicate column errors).
  void _migrateMediaColumns(Database db) {
    const columns = [
      'media_file_id INTEGER',
      'media_local_path TEXT',
      'media_width INTEGER',
      'media_height INTEGER',
      'media_duration INTEGER',
      'media_file_name TEXT',
      'media_mime_type TEXT',
    ];
    for (final col in columns) {
      try {
        db.execute('ALTER TABLE messages ADD COLUMN $col');
      } on SqliteException catch (e) {
        // Error code 1 = "duplicate column name" — safe to ignore
        if (!e.message.contains('duplicate column name')) {
          stderr.writeln('TelegramCache: migration warning for "$col": $e');
        }
      } catch (e) {
        stderr.writeln('TelegramCache: unexpected migration error for "$col": $e');
      }
    }
  }

  /// Get cached messages for a chat, ordered by date descending.
  List<TelegramMessage> getCachedMessages(
    int chatId, {
    int? messageThreadId,
    int limit = 50,
  }) {
    try {
      final db = _openDb(chatId);

      final String sql;
      final List<Object?> args;

      if (messageThreadId != null) {
        sql = '''
          SELECT * FROM messages
          WHERE message_thread_id = ?
          ORDER BY date DESC
          LIMIT ?
        ''';
        args = [messageThreadId, limit];
      } else {
        sql = '''
          SELECT * FROM messages
          ORDER BY date DESC
          LIMIT ?
        ''';
        args = [limit];
      }

      final rows = db.select(sql, args);
      stderr.writeln('TelegramCache: getCachedMessages($chatId) returned ${rows.length} rows');
      return rows.map((row) => _rowToMessage(chatId, row)).toList();
    } catch (e) {
      stderr.writeln('TelegramCache: getCachedMessages error: $e');
      LogService().error('TelegramCache: getCachedMessages error: $e');
      return [];
    }
  }

  /// Cache a list of messages in a transaction.
  void cacheMessages(int chatId, List<TelegramMessage> messages) {
    if (messages.isEmpty) return;
    stderr.writeln('TelegramCache: cacheMessages($chatId) — ${messages.length} messages');
    try {
      final db = _openDb(chatId);
      db.execute('BEGIN');
      try {
        for (final msg in messages) {
          _insertMessage(db, msg);
        }
        db.execute('COMMIT');
        stderr.writeln('TelegramCache: cacheMessages($chatId) — committed ${messages.length}');
      } catch (e) {
        stderr.writeln('TelegramCache: cacheMessages INSERT error, rolling back: $e');
        db.execute('ROLLBACK');
        rethrow;
      }
    } catch (e) {
      stderr.writeln('TelegramCache: cacheMessages error: $e');
      LogService().error('TelegramCache: cacheMessages error: $e');
    }
  }

  /// Cache a single message (e.g. from real-time updateNewMessage).
  void cacheMessage(int chatId, TelegramMessage message) {
    try {
      final db = _openDb(chatId);
      _insertMessage(db, message);
    } catch (e) {
      LogService().error('TelegramCache: cacheMessage error: $e');
    }
  }

  void _insertMessage(Database db, TelegramMessage msg) {
    db.execute(
      '''
      INSERT OR REPLACE INTO messages (
        id, sender_user_id, sender_name, content_type,
        text, date, is_outgoing, message_thread_id,
        media_file_id, media_local_path, media_width,
        media_height, media_duration, media_file_name, media_mime_type
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        msg.id,
        msg.senderUserId,
        msg.senderName,
        msg.contentType.name,
        msg.text,
        msg.date.millisecondsSinceEpoch,
        msg.isOutgoing ? 1 : 0,
        msg.messageThreadId,
        msg.media?.fileId,
        msg.media?.localPath,
        msg.media?.width,
        msg.media?.height,
        msg.media?.duration,
        msg.media?.fileName,
        msg.media?.mimeType,
      ],
    );
  }

  TelegramMessage _rowToMessage(int chatId, Row row) {
    // Reconstruct media info if file ID is present
    final mediaFileId = row['media_file_id'] as int?;
    TelegramMediaInfo? media;
    if (mediaFileId != null) {
      media = TelegramMediaInfo(
        fileId: mediaFileId,
        localPath: row['media_local_path'] as String?,
        width: row['media_width'] as int?,
        height: row['media_height'] as int?,
        duration: row['media_duration'] as int?,
        fileName: row['media_file_name'] as String?,
        mimeType: row['media_mime_type'] as String?,
      );
    }

    return TelegramMessage(
      id: row['id'] as int,
      chatId: chatId,
      senderUserId: row['sender_user_id'] as int,
      senderName: row['sender_name'] as String?,
      contentType: TelegramMessageContentType.values.firstWhere(
        (e) => e.name == (row['content_type'] as String),
        orElse: () => TelegramMessageContentType.other,
      ),
      text: row['text'] as String?,
      date: DateTime.fromMillisecondsSinceEpoch(
        row['date'] as int,
        isUtc: true,
      ),
      isOutgoing: (row['is_outgoing'] as int) == 1,
      messageThreadId: row['message_thread_id'] as int?,
      media: media,
    );
  }

  /// Get the absolute path of the cache directory.
  String get cacheDirAbsolutePath =>
      _storage.getAbsolutePath(_cacheDirPath());

  /// Inspect cache: if chatId given, return message stats; otherwise list DB files.
  Map<String, dynamic> inspectCache({int? chatId}) {
    final cacheDir = Directory(cacheDirAbsolutePath);
    if (!cacheDir.existsSync()) {
      return {'error': 'Cache directory does not exist', 'path': cacheDir.path};
    }

    if (chatId != null) {
      try {
        final db = _openDb(chatId);
        final countResult = db.select('SELECT count(*) as cnt FROM messages');
        final count = countResult.first['cnt'] as int;

        final sample = db.select(
          'SELECT id, content_type, date, media_file_id, media_local_path '
          'FROM messages ORDER BY date DESC LIMIT 5',
        );
        final rows = sample
            .map((r) => {
                  'id': r['id'],
                  'content_type': r['content_type'],
                  'date': r['date'],
                  'media_file_id': r['media_file_id'],
                  'media_local_path': r['media_local_path'],
                })
            .toList();

        return {
          'chat_id': chatId,
          'message_count': count,
          'sample': rows,
        };
      } catch (e) {
        return {'error': 'Failed to inspect chat $chatId: $e'};
      }
    }

    // List all DB files in cache dir
    final files = cacheDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.db'))
        .map((f) => {
              'name': f.uri.pathSegments.last,
              'size_bytes': f.lengthSync(),
            })
        .toList();
    return {'cache_dir': cacheDir.path, 'databases': files};
  }

  /// Clear cache: delete DB file for a specific chat, or all cache DBs.
  Map<String, dynamic> clearCache({int? chatId}) {
    final cacheDir = Directory(cacheDirAbsolutePath);
    if (!cacheDir.existsSync()) {
      return {'error': 'Cache directory does not exist'};
    }

    if (chatId != null) {
      // Close the DB if open
      final db = _openDbs.remove(chatId);
      db?.dispose();

      final dbFile = File('${cacheDir.path}/chat_$chatId.db');
      if (dbFile.existsSync()) {
        dbFile.deleteSync();
        return {'deleted': 'chat_$chatId.db'};
      }
      return {'error': 'No cache DB for chat $chatId'};
    }

    // Close all open DBs and delete all .db files
    for (final db in _openDbs.values) {
      db.dispose();
    }
    _openDbs.clear();

    final deleted = <String>[];
    for (final f in cacheDir.listSync().whereType<File>()) {
      if (f.path.endsWith('.db')) {
        deleted.add(f.uri.pathSegments.last);
        f.deleteSync();
      }
    }
    return {'deleted': deleted};
  }

  /// Close all open databases and release resources.
  void dispose() {
    for (final db in _openDbs.values) {
      db.dispose();
    }
    _openDbs.clear();
  }
}
