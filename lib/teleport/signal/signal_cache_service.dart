/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Per-conversation SQLite message cache for the Signal bridge.
 * One database per conversation keeps things isolated and avoids a single large DB.
 *
 * Key differences from TelegramCacheService:
 *   - Conversations identified by UUID strings → DB filename uses SHA-256 hash
 *   - Message PK is composite (timestamp INTEGER, sender TEXT)
 *   - No integer message IDs, no TDLib file IDs
 *   - Media stored by local path (no file ID download workflow)
 */

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../services/log_service.dart';
import '../../services/profile_storage.dart';
import '../../services/sqlite_loader.dart';
import 'models/signal_message.dart';

/// Manages per-conversation SQLite databases for caching Signal messages.
///
/// Storage layout:
///   {prefix}/signal/cache/chat_{sha256(conversationId)}.db
class SignalCacheService {
  final ProfileStorage _storage;
  final String _prefix;
  final Map<String, Database> _openDbs = {};

  Database? _visitsDb;
  Database? _photosDb;
  bool _visitsPruned = false;

  /// Maximum file size (in bytes) to store as a BLOB. Files above this
  /// threshold keep their on-disk path reference instead.
  static const int maxBlobSizeBytes = 20 * 1024 * 1024; // 20 MB

  SignalCacheService(this._storage, this._prefix);

  String _cacheDirPath() {
    final pfx = _prefix.isEmpty ? '' : '$_prefix/';
    return '${pfx}signal/cache';
  }

  /// Compute a stable DB filename from a conversation UUID or group key.
  /// Uses SHA-256 hash (first 16 hex chars) to avoid filesystem issues
  /// with raw UUIDs.
  static String dbFilename(String conversationId) {
    final hash =
        sha256.convert(utf8.encode(conversationId)).toString().substring(0, 16);
    return 'chat_$hash.db';
  }

  /// Ensure the cache directory exists.
  Future<void> ensureCacheDir() async {
    await _storage.createDirectory(_cacheDirPath());
  }

  /// Lazy-open the SQLite database for a given conversation ID.
  Database _openDb(String conversationId) {
    final existing = _openDbs[conversationId];
    if (existing != null) return existing;

    final dbPath = _storage.getAbsolutePath(
        '${_cacheDirPath()}/${dbFilename(conversationId)}');
    final db = SQLiteLoader.openDatabase(dbPath);

    // Create messages table with composite primary key (timestamp, sender)
    db.execute('''
      CREATE TABLE IF NOT EXISTS messages (
        timestamp INTEGER NOT NULL,
        sender TEXT NOT NULL,
        sender_name TEXT,
        content_type TEXT NOT NULL DEFAULT 'text',
        text TEXT,
        is_outgoing INTEGER NOT NULL DEFAULT 0,
        attachment_count INTEGER NOT NULL DEFAULT 0,
        group_key TEXT,
        PRIMARY KEY (timestamp, sender)
      );
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_date
      ON messages(timestamp DESC);
    ''');

    // Apply migrations
    _migrateMediaColumns(db);
    _migrateQuoteColumns(db);
    _migrateReactionColumns(db);
    _migrateMediaBlobColumns(db);
    _migrateIsReadColumn(db);

    _openDbs[conversationId] = db;
    return db;
  }

  /// Add media columns via safe ALTER TABLE (ignore duplicate column errors).
  void _migrateMediaColumns(Database db) {
    const columns = [
      'media_local_path TEXT',
      'media_content_type TEXT',
      'media_file_name TEXT',
      'media_width INTEGER',
      'media_height INTEGER',
      'media_duration INTEGER',
      'media_size INTEGER',
    ];
    for (final col in columns) {
      try {
        db.execute('ALTER TABLE messages ADD COLUMN $col');
      } on SqliteException catch (e) {
        if (!e.message.contains('duplicate column name')) {
          stderr.writeln('SignalCache: migration warning for "$col": $e');
        }
      } catch (e) {
        stderr.writeln('SignalCache: unexpected migration error for "$col": $e');
      }
    }
  }

  /// Add quote/reply columns via safe ALTER TABLE.
  void _migrateQuoteColumns(Database db) {
    const columns = [
      'quote_timestamp INTEGER',
      'quote_text TEXT',
      'forward_sender_name TEXT',
      'edit_timestamp INTEGER',
    ];
    for (final col in columns) {
      try {
        db.execute('ALTER TABLE messages ADD COLUMN $col');
      } on SqliteException catch (e) {
        if (!e.message.contains('duplicate column name')) {
          stderr.writeln('SignalCache: migration warning for "$col": $e');
        }
      } catch (e) {
        stderr.writeln(
            'SignalCache: unexpected migration error for "$col": $e');
      }
    }
  }

  /// Add reaction columns via safe ALTER TABLE.
  void _migrateReactionColumns(Database db) {
    const columns = [
      'reaction_emoji TEXT',
      'reaction_target_timestamp INTEGER',
      'reactions_json TEXT',
    ];
    for (final col in columns) {
      try {
        db.execute('ALTER TABLE messages ADD COLUMN $col');
      } on SqliteException catch (e) {
        if (!e.message.contains('duplicate column name')) {
          stderr.writeln('SignalCache: migration warning for "$col": $e');
        }
      } catch (e) {
        stderr.writeln(
            'SignalCache: unexpected migration error for "$col": $e');
      }
    }
  }

  /// Add media BLOB columns via safe ALTER TABLE.
  void _migrateMediaBlobColumns(Database db) {
    const columns = [
      'media_data BLOB',
      'media_data_size INTEGER',
      'media_sha256 TEXT',
      'media_extension TEXT',
      'media_thumbnail BLOB',
    ];
    for (final col in columns) {
      try {
        db.execute('ALTER TABLE messages ADD COLUMN $col');
      } on SqliteException catch (e) {
        if (!e.message.contains('duplicate column name')) {
          stderr.writeln('SignalCache: blob migration warning for "$col": $e');
        }
      } catch (e) {
        stderr.writeln('SignalCache: blob migration error for "$col": $e');
      }
    }
  }

  /// Add is_read column for local unread tracking.
  void _migrateIsReadColumn(Database db) {
    try {
      db.execute('ALTER TABLE messages ADD COLUMN is_read INTEGER DEFAULT 0');
    } on SqliteException catch (e) {
      if (!e.message.contains('duplicate column name')) {
        stderr.writeln('SignalCache: migration warning for "is_read": $e');
      }
    } catch (e) {
      stderr.writeln(
          'SignalCache: unexpected migration error for "is_read": $e');
    }
  }

  /// Get cached messages for a conversation, ordered by timestamp descending.
  List<SignalMessage> getCachedMessages(
    String conversationId, {
    int limit = 50,
  }) {
    try {
      final db = _openDb(conversationId);
      final rows = db.select('''
        SELECT * FROM messages
        ORDER BY timestamp DESC
        LIMIT ?
      ''', [limit]);
      return rows
          .map((row) => _rowToMessage(row))
          .toList();
    } catch (e) {
      stderr.writeln('SignalCache: getCachedMessages error: $e');
      LogService().error('SignalCache: getCachedMessages error: $e');
      return [];
    }
  }

  /// Get a single cached message by composite primary key.
  SignalMessage? getCachedMessage(
      String conversationId, int timestamp, String senderUuid) {
    try {
      final db = _openDb(conversationId);
      final rows = db.select(
        'SELECT * FROM messages WHERE timestamp = ? AND sender = ? LIMIT 1',
        [timestamp, senderUuid],
      );
      if (rows.isEmpty) return null;
      return _rowToMessage(rows.first);
    } catch (e) {
      stderr.writeln('SignalCache: getCachedMessage error: $e');
      LogService().error('SignalCache: getCachedMessage error: $e');
      return null;
    }
  }

  /// Get cached messages older than [beforeTimestamp], ordered by timestamp descending.
  List<SignalMessage> getOlderCachedMessages(
    String conversationId, {
    required int beforeTimestamp,
    int limit = 50,
  }) {
    try {
      final db = _openDb(conversationId);
      final rows = db.select('''
        SELECT * FROM messages
        WHERE timestamp < ?
        ORDER BY timestamp DESC
        LIMIT ?
      ''', [beforeTimestamp, limit]);
      return rows
          .map((row) => _rowToMessage(row))
          .toList();
    } catch (e) {
      stderr.writeln('SignalCache: getOlderCachedMessages error: $e');
      LogService().error('SignalCache: getOlderCachedMessages error: $e');
      return [];
    }
  }

  /// Cache a list of messages in a transaction.
  void cacheMessages(String conversationId, List<SignalMessage> messages) {
    if (messages.isEmpty) return;
    try {
      final db = _openDb(conversationId);
      db.execute('BEGIN');
      try {
        for (final msg in messages) {
          _insertMessage(db, msg);
        }
        db.execute('COMMIT');
      } catch (e) {
        stderr.writeln(
            'SignalCache: cacheMessages INSERT error, rolling back: $e');
        db.execute('ROLLBACK');
        rethrow;
      }
    } catch (e) {
      stderr.writeln('SignalCache: cacheMessages error: $e');
      LogService().error('SignalCache: cacheMessages error: $e');
    }
  }

  /// Cache a single message (e.g. from real-time updateNewMessage).
  void cacheMessage(String conversationId, SignalMessage message) {
    try {
      final db = _openDb(conversationId);
      _insertMessage(db, message);
    } catch (e) {
      LogService().error('SignalCache: cacheMessage error: $e');
    }
  }

  void _insertMessage(Database db, SignalMessage msg) {
    // Serialize reactions to JSON
    String? reactionsJson;
    if (msg.reactions.isNotEmpty) {
      reactionsJson = jsonEncode(msg.reactions
          .map((r) => {
                'emoji': r.emoji,
                'sender_uuid': r.senderUuid,
                'timestamp': r.timestamp,
              })
          .toList());
    }

    // Preserve existing blob data and read state across INSERT OR REPLACE
    Uint8List? existingBlob;
    int? existingBlobSize;
    String? existingSha256;
    String? existingExtension;
    Uint8List? existingThumbnail;
    int existingIsRead = 0;
    try {
      final prev = db.select(
        'SELECT media_data, media_data_size, media_sha256, '
        'media_extension, media_thumbnail, is_read '
        'FROM messages WHERE timestamp = ? AND sender = ?',
        [msg.timestamp, msg.senderUuid],
      );
      if (prev.isNotEmpty) {
        final row = prev.first;
        existingBlob = row['media_data'] as Uint8List?;
        existingBlobSize = row['media_data_size'] as int?;
        existingSha256 = row['media_sha256'] as String?;
        existingExtension = row['media_extension'] as String?;
        existingThumbnail = row['media_thumbnail'] as Uint8List?;
        existingIsRead = row['is_read'] as int? ?? 0;
      }
    } catch (_) {
      // Column may not exist yet during first migration — ignore
    }

    db.execute(
      '''
      INSERT OR REPLACE INTO messages (
        timestamp, sender, sender_name, content_type,
        text, is_outgoing, attachment_count, group_key,
        media_local_path, media_content_type, media_file_name,
        media_width, media_height, media_duration, media_size,
        quote_timestamp, quote_text,
        forward_sender_name, edit_timestamp,
        reaction_emoji, reaction_target_timestamp, reactions_json,
        media_data, media_data_size, media_sha256,
        media_extension, media_thumbnail,
        is_read
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        msg.timestamp,
        msg.senderUuid,
        msg.senderName,
        msg.contentType,
        msg.text,
        msg.isOutgoing ? 1 : 0,
        msg.attachmentCount,
        msg.groupKey,
        msg.media?.localPath,
        msg.media?.contentType,
        msg.media?.fileName,
        msg.media?.width,
        msg.media?.height,
        msg.media?.duration,
        msg.media?.size,
        msg.quoteTimestamp,
        msg.quoteText,
        msg.forwardSenderName,
        msg.editTimestamp,
        msg.reactionEmoji,
        msg.reactionTargetTimestamp,
        reactionsJson,
        existingBlob,
        existingBlobSize,
        existingSha256,
        existingExtension,
        existingThumbnail,
        existingIsRead,
      ],
    );
  }

  SignalMessage _rowToMessage(Row row) {
    // Reconstruct media info if local path is present
    final mediaPath = row['media_local_path'] as String?;
    SignalMediaInfo? media;
    if (mediaPath != null) {
      media = SignalMediaInfo(
        localPath: mediaPath,
        contentType: row['media_content_type'] as String?,
        fileName: row['media_file_name'] as String?,
        width: row['media_width'] as int?,
        height: row['media_height'] as int?,
        duration: row['media_duration'] as int?,
        size: row['media_size'] as int?,
      );
    }

    // Deserialize reactions from JSON
    List<SignalReaction> reactions = const [];
    final reactionsJson = row['reactions_json'] as String?;
    if (reactionsJson != null && reactionsJson.isNotEmpty) {
      try {
        final list = jsonDecode(reactionsJson) as List<dynamic>;
        reactions = list.whereType<Map<String, dynamic>>().map((j) {
          return SignalReaction(
            emoji: j['emoji'] as String? ?? '',
            senderUuid: j['sender_uuid'] as String? ?? '',
            timestamp: j['timestamp'] as int? ?? 0,
          );
        }).toList();
      } catch (_) {
        // Ignore corrupt JSON
      }
    }

    return SignalMessage(
      timestamp: row['timestamp'] as int,
      senderUuid: row['sender'] as String,
      senderName: row['sender_name'] as String?,
      contentType: row['content_type'] as String? ?? 'text',
      text: row['text'] as String?,
      isOutgoing: (row['is_outgoing'] as int) == 1,
      attachmentCount: row['attachment_count'] as int? ?? 0,
      media: media,
      quoteTimestamp: row['quote_timestamp'] as int?,
      quoteText: row['quote_text'] as String?,
      reactionEmoji: row['reaction_emoji'] as String?,
      reactionTargetTimestamp: row['reaction_target_timestamp'] as int?,
      reactions: reactions,
      groupKey: row['group_key'] as String?,
      forwardSenderName: row['forward_sender_name'] as String?,
      editTimestamp: row['edit_timestamp'] as int?,
    );
  }

  /// Delete messages from the cache by their composite keys.
  void deleteMessages(
      String conversationId, List<(int, String)> compositeKeys) {
    if (compositeKeys.isEmpty) return;
    try {
      final db = _openDb(conversationId);
      db.execute('BEGIN');
      try {
        for (final (timestamp, sender) in compositeKeys) {
          db.execute(
            'DELETE FROM messages WHERE timestamp = ? AND sender = ?',
            [timestamp, sender],
          );
        }
        db.execute('COMMIT');
      } catch (e) {
        db.execute('ROLLBACK');
        rethrow;
      }
      stderr.writeln(
          'SignalCache: deleted ${compositeKeys.length} messages from conv $conversationId');
    } catch (e) {
      stderr.writeln('SignalCache: deleteMessages error: $e');
      LogService().error('SignalCache: deleteMessages error: $e');
    }
  }

  /// Mark all messages in a conversation as read in the local cache.
  void markAllAsRead(String conversationId) {
    try {
      final db = _openDb(conversationId);
      db.execute('UPDATE messages SET is_read = 1 WHERE is_read = 0');
    } catch (e) {
      stderr.writeln('SignalCache: markAllAsRead error: $e');
    }
  }

  /// Get the count of unread messages in a conversation.
  int getUnreadCount(String conversationId) {
    try {
      final db = _openDb(conversationId);
      final result = db.select(
        'SELECT COUNT(*) as cnt FROM messages WHERE is_read = 0',
      );
      return result.first['cnt'] as int;
    } catch (e) {
      stderr.writeln('SignalCache: getUnreadCount error: $e');
      return 0;
    }
  }

  /// Ingest a downloaded media file as a BLOB into the per-conversation DB.
  ///
  /// Returns `true` if the file was stored and the original file deleted;
  /// `false` if skipped (too large, missing, etc.).
  bool ingestMediaBlob(
    String conversationId,
    int timestamp,
    String senderUuid,
    String filePath,
  ) {
    try {
      final file = File(filePath);
      if (!file.existsSync()) return false;

      final size = file.lengthSync();
      if (size > maxBlobSizeBytes || size == 0) return false;

      final bytes = file.readAsBytesSync();
      final sha256Hex = sha256.convert(bytes).toString();

      final db = _openDb(conversationId);

      // Resolve file extension from existing mime/fileName columns
      String? ext;
      try {
        final meta = db.select(
          'SELECT media_content_type, media_file_name '
          'FROM messages WHERE timestamp = ? AND sender = ?',
          [timestamp, senderUuid],
        );
        if (meta.isNotEmpty) {
          ext = _resolveExtension(
            meta.first['media_content_type'] as String?,
            meta.first['media_file_name'] as String?,
          );
        }
      } catch (_) {}

      db.execute(
        'UPDATE messages SET media_data = ?, media_data_size = ?, '
        'media_sha256 = ?, media_extension = ? '
        'WHERE timestamp = ? AND sender = ?',
        [bytes, size, sha256Hex, ext, timestamp, senderUuid],
      );

      // Delete the original file now that it's stored in the DB
      try {
        file.deleteSync();
      } catch (e) {
        stderr.writeln(
            'SignalCache: could not delete original file $filePath: $e');
      }

      stderr.writeln('SignalCache: ingested ${size ~/ 1024}KB blob for '
          'msg $timestamp|$senderUuid (sha256=${sha256Hex.substring(0, 12)})');
      return true;
    } catch (e) {
      stderr.writeln('SignalCache: ingestMediaBlob error: $e');
      LogService().error('SignalCache: ingestMediaBlob error: $e');
      return false;
    }
  }

  /// Resolve a file extension from MIME type or original file name.
  static String _resolveExtension(String? mimeType, String? fileName) {
    if (fileName != null && fileName.contains('.')) {
      final dot = fileName.lastIndexOf('.');
      return fileName.substring(dot);
    }
    return _mimeToExtension(mimeType);
  }

  /// Map common MIME types to file extensions.
  static String _mimeToExtension(String? mime) {
    if (mime == null) return '.bin';
    switch (mime) {
      case 'image/jpeg':
        return '.jpg';
      case 'image/png':
        return '.png';
      case 'image/gif':
        return '.gif';
      case 'image/webp':
        return '.webp';
      case 'video/mp4':
        return '.mp4';
      case 'video/webm':
        return '.webm';
      case 'audio/ogg':
      case 'audio/opus':
        return '.ogg';
      case 'audio/mpeg':
        return '.mp3';
      case 'audio/mp4':
      case 'audio/aac':
        return '.m4a';
      case 'application/pdf':
        return '.pdf';
      default:
        if (mime.startsWith('image/')) return '.jpg';
        if (mime.startsWith('video/')) return '.mp4';
        if (mime.startsWith('audio/')) return '.ogg';
        return '.bin';
    }
  }

  // ---------- Visit tracking ----------

  /// Lazy-open the shared visits database.
  Database _openVisitsDb() {
    if (_visitsDb != null) return _visitsDb!;

    final dbPath = _storage.getAbsolutePath('${_cacheDirPath()}/visits.db');
    _visitsDb = SQLiteLoader.openDatabase(dbPath);

    _visitsDb!.execute('''
      CREATE TABLE IF NOT EXISTS conversation_visits (
        conversation_id TEXT NOT NULL,
        visited_at INTEGER NOT NULL
      );
    ''');
    _visitsDb!.execute('''
      CREATE INDEX IF NOT EXISTS idx_visits_conv
      ON conversation_visits(conversation_id);
    ''');
    _visitsDb!.execute('''
      CREATE INDEX IF NOT EXISTS idx_visits_date
      ON conversation_visits(visited_at);
    ''');

    // Auto-prune entries older than 30 days (once per session)
    if (!_visitsPruned) {
      final cutoff = DateTime.now()
              .toUtc()
              .subtract(const Duration(days: 30))
              .millisecondsSinceEpoch ~/
          1000;
      _visitsDb!.execute(
        'DELETE FROM conversation_visits WHERE visited_at < ?',
        [cutoff],
      );
      _visitsPruned = true;
    }

    return _visitsDb!;
  }

  // ---------- Conversation photo caching ----------

  /// Lazy-open the shared photos database.
  Database _openPhotosDb() {
    if (_photosDb != null) return _photosDb!;

    final dbPath = _storage.getAbsolutePath('${_cacheDirPath()}/photos.db');
    _photosDb = SQLiteLoader.openDatabase(dbPath);

    _photosDb!.execute('''
      CREATE TABLE IF NOT EXISTS conversation_photos (
        conversation_id TEXT PRIMARY KEY,
        photo_data BLOB NOT NULL,
        photo_size INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');

    return _photosDb!;
  }

  /// Store (or update) a conversation's avatar photo bytes.
  void storeConversationPhoto(
      String conversationId, Uint8List photoBytes) {
    try {
      final db = _openPhotosDb();
      db.execute(
        'INSERT OR REPLACE INTO conversation_photos '
        '(conversation_id, photo_data, photo_size, updated_at) '
        'VALUES (?, ?, ?, ?)',
        [
          conversationId,
          photoBytes,
          photoBytes.length,
          DateTime.now().toUtc().millisecondsSinceEpoch,
        ],
      );
    } catch (e) {
      stderr.writeln('SignalCache: storeConversationPhoto error: $e');
    }
  }

  /// Get a single conversation's cached photo bytes, or null.
  Uint8List? getConversationPhoto(String conversationId) {
    try {
      final db = _openPhotosDb();
      final rows = db.select(
        'SELECT photo_data FROM conversation_photos WHERE conversation_id = ?',
        [conversationId],
      );
      if (rows.isEmpty) return null;
      return rows.first['photo_data'] as Uint8List?;
    } catch (e) {
      stderr.writeln('SignalCache: getConversationPhoto error: $e');
      return null;
    }
  }

  /// Load all cached conversation photos in a single query (for chat list).
  Map<String, Uint8List> getAllCachedConversationPhotos() {
    try {
      final db = _openPhotosDb();
      final rows = db.select(
          'SELECT conversation_id, photo_data FROM conversation_photos');
      final result = <String, Uint8List>{};
      for (final row in rows) {
        final data = row['photo_data'] as Uint8List?;
        if (data != null && data.isNotEmpty) {
          result[row['conversation_id'] as String] = data;
        }
      }
      return result;
    } catch (e) {
      stderr.writeln('SignalCache: getAllCachedConversationPhotos error: $e');
      return {};
    }
  }

  /// Record a visit to a conversation (called when the user opens it).
  void recordVisit(String conversationId) {
    try {
      final db = _openVisitsDb();
      final nowSec = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      db.execute(
        'INSERT INTO conversation_visits (conversation_id, visited_at) '
        'VALUES (?, ?)',
        [conversationId, nowSec],
      );
    } catch (e) {
      stderr.writeln('SignalCache: recordVisit error: $e');
    }
  }

  /// Get the top-30 most-visited conversations within the last 30 days.
  /// Returns a map of conversationId -> visitCount, ordered by count descending.
  Map<String, int> getTopVisitedConversations() {
    try {
      final db = _openVisitsDb();
      final cutoff = DateTime.now()
              .toUtc()
              .subtract(const Duration(days: 30))
              .millisecondsSinceEpoch ~/
          1000;
      final rows = db.select('''
        SELECT conversation_id, COUNT(*) as visit_count
        FROM conversation_visits
        WHERE visited_at >= ?
        GROUP BY conversation_id
        ORDER BY visit_count DESC
        LIMIT 30
      ''', [cutoff]);

      final result = <String, int>{};
      for (final row in rows) {
        result[row['conversation_id'] as String] = row['visit_count'] as int;
      }
      return result;
    } catch (e) {
      stderr.writeln('SignalCache: getTopVisitedConversations error: $e');
      return {};
    }
  }

  /// Get the absolute path of the cache directory.
  String get cacheDirAbsolutePath =>
      _storage.getAbsolutePath(_cacheDirPath());

  /// Inspect cache: if conversationId given, return message stats; otherwise list DB files.
  Map<String, dynamic> inspectCache({String? conversationId}) {
    final cacheDir = Directory(cacheDirAbsolutePath);
    if (!cacheDir.existsSync()) {
      return {
        'error': 'Cache directory does not exist',
        'path': cacheDir.path,
      };
    }

    if (conversationId != null) {
      try {
        final db = _openDb(conversationId);
        final countResult = db.select('SELECT count(*) as cnt FROM messages');
        final count = countResult.first['cnt'] as int;

        final sample = db.select(
          'SELECT timestamp, sender, content_type, text, is_outgoing '
          'FROM messages ORDER BY timestamp DESC LIMIT 5',
        );
        final rows = sample
            .map((r) => {
                  'timestamp': r['timestamp'],
                  'sender': r['sender'],
                  'content_type': r['content_type'],
                  'text_preview': (r['text'] as String?)
                          ?.substring(
                              0,
                              ((r['text'] as String?)?.length ?? 0)
                                  .clamp(0, 50)) ??
                      null,
                  'is_outgoing': r['is_outgoing'],
                })
            .toList();

        return {
          'conversation_id': conversationId,
          'db_filename': dbFilename(conversationId),
          'message_count': count,
          'sample': rows,
        };
      } catch (e) {
        return {'error': 'Failed to inspect conversation $conversationId: $e'};
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

  /// Clear cache: delete DB file for a specific conversation, or all cache DBs.
  Map<String, dynamic> clearCache({String? conversationId}) {
    final cacheDir = Directory(cacheDirAbsolutePath);
    if (!cacheDir.existsSync()) {
      return {'error': 'Cache directory does not exist'};
    }

    if (conversationId != null) {
      // Close the DB if open
      final db = _openDbs.remove(conversationId);
      db?.dispose();

      final filename = dbFilename(conversationId);
      final dbFile = File('${cacheDir.path}/$filename');
      if (dbFile.existsSync()) {
        dbFile.deleteSync();
        return {'deleted': filename};
      }
      return {'error': 'No cache DB for conversation $conversationId'};
    }

    // Close all open DBs and delete all .db files
    for (final db in _openDbs.values) {
      db.dispose();
    }
    _openDbs.clear();
    _visitsDb?.dispose();
    _visitsDb = null;
    _photosDb?.dispose();
    _photosDb = null;

    final deleted = <String>[];
    for (final f in cacheDir.listSync().whereType<File>()) {
      if (f.path.endsWith('.db')) {
        deleted.add(f.uri.pathSegments.last);
        f.deleteSync();
      }
    }
    return {'deleted': deleted};
  }

  /// Inspect visit records for debugging.
  Map<String, dynamic> inspectVisits() {
    try {
      final db = _openVisitsDb();
      final countResult = db.select(
        'SELECT COUNT(*) as cnt FROM conversation_visits',
      );
      final totalVisits = countResult.first['cnt'] as int;

      final topConvs = db.select('''
        SELECT conversation_id, COUNT(*) as visit_count,
               MAX(visited_at) as last_visit
        FROM conversation_visits
        GROUP BY conversation_id
        ORDER BY visit_count DESC
        LIMIT 10
      ''');
      final top = topConvs
          .map((r) => {
                'conversation_id': r['conversation_id'],
                'visit_count': r['visit_count'],
                'last_visit': r['last_visit'],
              })
          .toList();

      return {
        'total_visits': totalVisits,
        'top_conversations': top,
      };
    } catch (e) {
      return {'error': 'inspectVisits failed: $e'};
    }
  }

  /// Clear all visit records.
  Map<String, dynamic> clearVisits() {
    try {
      final db = _openVisitsDb();
      db.execute('DELETE FROM conversation_visits');
      return {'cleared': true};
    } catch (e) {
      return {'error': 'clearVisits failed: $e'};
    }
  }

  /// Close all open databases, release resources.
  void dispose() {
    for (final db in _openDbs.values) {
      db.dispose();
    }
    _openDbs.clear();

    _visitsDb?.dispose();
    _visitsDb = null;

    _photosDb?.dispose();
    _photosDb = null;
  }
}
