/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Per-chat SQLite message cache for the Telegram bridge.
 * One database per chat keeps things isolated and avoids a single large DB.
 */

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:sqlite3/sqlite3.dart';

import '../../services/log_service.dart';
import '../../services/profile_storage.dart';
import '../../services/sqlite_loader.dart';
import '../../services/static_map_service.dart';
import '../../util/tlsh.dart';
import '../../util/video_metadata_extractor.dart';
import 'models/telegram_message.dart';

/// Manages per-chat SQLite databases for caching Telegram messages.
///
/// Storage layout:
///   {prefix}/telegram/cache/chat_{chatId}.db
class TelegramCacheService {
  final ProfileStorage _storage;
  final String _prefix;
  final Map<int, Database> _openDbs = {};

  Database? _visitsDb;
  Database? _photosDb;
  bool _visitsPruned = false;

  /// Maximum file size (in bytes) to store as a BLOB. Files above this
  /// threshold keep their on-disk path reference instead.
  static const int maxBlobSizeBytes = 20 * 1024 * 1024; // 20 MB

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
    // Migrate: add reply, edit, forward columns
    _migrateReplyAndEditColumns(db);
    // Migrate: add reactions column
    _migrateReactionsColumn(db);
    // Migrate: purge old 'other' messages so TDLib re-fetches with proper types
    _purgeOtherMessages(db);
    // Migrate: add media blob columns for inline BLOB storage
    _migrateMediaBlobColumns(db);
    // Migrate: add is_read column for local unread tracking
    _migrateIsReadColumn(db);
    // Migrate: add topic_photos table for forum topic icon caching
    _migrateTopicPhotosTable(db);

    _openDbs[chatId] = db;

    // Auto-migrate existing file-based media into BLOBs
    _autoMigrateMedia(db, chatId);

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
      'media_minithumbnail TEXT',
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

  /// Add reply/edit/forward columns via safe ALTER TABLE.
  void _migrateReplyAndEditColumns(Database db) {
    const columns = [
      'reply_to_message_id INTEGER',
      'reply_to_sender_name TEXT',
      'reply_to_text TEXT',
      'edit_date INTEGER',
      'forward_sender_name TEXT',
    ];
    for (final col in columns) {
      try {
        db.execute('ALTER TABLE messages ADD COLUMN $col');
      } on SqliteException catch (e) {
        if (!e.message.contains('duplicate column name')) {
          stderr.writeln('TelegramCache: migration warning for "$col": $e');
        }
      } catch (e) {
        stderr.writeln('TelegramCache: unexpected migration error for "$col": $e');
      }
    }
  }

  /// Add reactions_json column via safe ALTER TABLE.
  void _migrateReactionsColumn(Database db) {
    try {
      db.execute('ALTER TABLE messages ADD COLUMN reactions_json TEXT');
    } on SqliteException catch (e) {
      if (!e.message.contains('duplicate column name')) {
        stderr.writeln('TelegramCache: migration warning for "reactions_json": $e');
      }
    } catch (e) {
      stderr.writeln('TelegramCache: unexpected migration error for "reactions_json": $e');
    }
  }

  /// Add media BLOB columns via safe ALTER TABLE.
  void _migrateMediaBlobColumns(Database db) {
    const columns = [
      'media_data BLOB',
      'media_data_size INTEGER',
      'media_sha1 TEXT',
      'media_tlsh TEXT',
      'media_transcript TEXT',
      'media_extension TEXT',
      'media_thumbnail BLOB',
    ];
    for (final col in columns) {
      try {
        db.execute('ALTER TABLE messages ADD COLUMN $col');
      } on SqliteException catch (e) {
        if (!e.message.contains('duplicate column name')) {
          stderr.writeln('TelegramCache: blob migration warning for "$col": $e');
        }
      } catch (e) {
        stderr.writeln('TelegramCache: blob migration error for "$col": $e');
      }
    }
  }

  /// Add is_read column for local unread tracking.
  void _migrateIsReadColumn(Database db) {
    try {
      db.execute('ALTER TABLE messages ADD COLUMN is_read INTEGER DEFAULT 0');
    } on SqliteException catch (e) {
      if (!e.message.contains('duplicate column name')) {
        stderr.writeln('TelegramCache: migration warning for "is_read": $e');
      }
    } catch (e) {
      stderr.writeln('TelegramCache: unexpected migration error for "is_read": $e');
    }
  }

  /// Create topic_photos table for caching forum topic custom emoji icons.
  void _migrateTopicPhotosTable(Database db) {
    try {
      db.execute('''
        CREATE TABLE IF NOT EXISTS topic_photos (
          message_thread_id INTEGER PRIMARY KEY,
          photo_data BLOB NOT NULL,
          photo_size INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        )
      ''');
    } catch (e) {
      stderr.writeln('TelegramCache: topic_photos migration error: $e');
    }
  }

  /// One-time migration: delete cached messages with content_type='other'
  /// so TDLib re-fetches them with the correct type after new content types
  /// were added (location, venue, videoNote, contact, audio, poll, call, pinMessage).
  void _purgeOtherMessages(Database db) {
    try {
      final result = db.select(
          "SELECT COUNT(*) as cnt FROM messages WHERE content_type = 'other'");
      final count = result.first['cnt'] as int;
      if (count > 0) {
        db.execute("DELETE FROM messages WHERE content_type = 'other'");
        stderr.writeln(
            'TelegramCache: purged $count stale "other" messages for re-fetch');
      }
    } catch (e) {
      stderr.writeln('TelegramCache: _purgeOtherMessages error: $e');
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
      return rows.map((row) => _rowToMessage(chatId, row)).toList();
    } catch (e) {
      stderr.writeln('TelegramCache: getCachedMessages error: $e');
      LogService().error('TelegramCache: getCachedMessages error: $e');
      return [];
    }
  }

  /// Get a single cached message by primary key.
  TelegramMessage? getCachedMessage(int chatId, int messageId) {
    try {
      final db = _openDb(chatId);
      final rows = db.select('SELECT * FROM messages WHERE id = ? LIMIT 1', [messageId]);
      if (rows.isEmpty) return null;
      return _rowToMessage(chatId, rows.first);
    } catch (e) {
      stderr.writeln('TelegramCache: getCachedMessage error: $e');
      LogService().error('TelegramCache: getCachedMessage error: $e');
      return null;
    }
  }

  /// Get cached messages older than [beforeDateMs], ordered by date descending.
  List<TelegramMessage> getOlderCachedMessages(
    int chatId, {
    required int beforeDateMs,
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
          WHERE date < ? AND message_thread_id = ?
          ORDER BY date DESC
          LIMIT ?
        ''';
        args = [beforeDateMs, messageThreadId, limit];
      } else {
        sql = '''
          SELECT * FROM messages
          WHERE date < ?
          ORDER BY date DESC
          LIMIT ?
        ''';
        args = [beforeDateMs, limit];
      }

      final rows = db.select(sql, args);
      return rows.map((row) => _rowToMessage(chatId, row)).toList();
    } catch (e) {
      stderr.writeln('TelegramCache: getOlderCachedMessages error: $e');
      LogService().error('TelegramCache: getOlderCachedMessages error: $e');
      return [];
    }
  }

  /// Cache a list of messages in a transaction.
  void cacheMessages(int chatId, List<TelegramMessage> messages) {
    if (messages.isEmpty) return;
    try {
      final db = _openDb(chatId);
      db.execute('BEGIN');
      try {
        for (final msg in messages) {
          _insertMessage(db, msg);
        }
        db.execute('COMMIT');
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
    // Serialize reactions to JSON
    String? reactionsJson;
    if (msg.reactions.isNotEmpty) {
      reactionsJson = jsonEncode(msg.reactions.map((r) => r.toJson()).toList());
    }

    // Preserve existing blob data and read state across INSERT OR REPLACE
    Uint8List? existingBlob;
    int? existingBlobSize;
    String? existingSha1;
    String? existingTlsh;
    String? existingTranscript;
    String? existingExtension;
    Uint8List? existingThumbnail;
    int existingIsRead = 0;
    try {
      final prev = db.select(
        'SELECT media_data, media_data_size, media_sha1, media_tlsh, '
        'media_transcript, media_extension, media_thumbnail, is_read '
        'FROM messages WHERE id = ?',
        [msg.id],
      );
      if (prev.isNotEmpty) {
        final row = prev.first;
        existingBlob = row['media_data'] as Uint8List?;
        existingBlobSize = row['media_data_size'] as int?;
        existingSha1 = row['media_sha1'] as String?;
        existingTlsh = row['media_tlsh'] as String?;
        existingTranscript = row['media_transcript'] as String?;
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
        id, sender_user_id, sender_name, content_type,
        text, date, is_outgoing, message_thread_id,
        media_file_id, media_local_path, media_width,
        media_height, media_duration, media_file_name, media_mime_type,
        media_minithumbnail,
        reply_to_message_id, reply_to_sender_name, reply_to_text,
        edit_date, forward_sender_name, reactions_json,
        media_data, media_data_size, media_sha1, media_tlsh,
        media_transcript, media_extension, media_thumbnail,
        is_read
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
        msg.media?.minithumbnailData,
        msg.replyToMessageId,
        msg.replyToSenderName,
        msg.replyToText,
        msg.editDate,
        msg.forwardSenderName,
        reactionsJson,
        existingBlob,
        existingBlobSize,
        existingSha1,
        existingTlsh,
        existingTranscript,
        existingExtension,
        existingThumbnail,
        existingIsRead,
      ],
    );
  }

  /// Content types that can render directly from memory bytes (Image.memory).
  static const _inMemoryTypes = {
    'photo',
    'sticker',
    'animation',
  };

  TelegramMessage _rowToMessage(int chatId, Row row) {
    // Reconstruct media info if file ID is present
    final mediaFileId = row['media_file_id'] as int?;
    TelegramMediaInfo? media;
    if (mediaFileId != null) {
      final contentType = row['content_type'] as String;
      final blobData = row['media_data'] as Uint8List?;
      final msgId = row['id'] as int;
      final mime = row['media_mime_type'] as String?;
      final fileName = row['media_file_name'] as String?;

      String? localPath;
      Uint8List? mediaBytes;

      if (blobData != null && blobData.isNotEmpty) {
        if (_inMemoryTypes.contains(contentType)) {
          // Image types: pass bytes for in-memory rendering, no disk extraction
          mediaBytes = blobData;
        } else {
          // File-path types: extract to app-local extracted/ directory
          localPath = _extractBlobToFile(
              chatId, msgId, blobData, mime, fileName);
        }
      } else {
        localPath = row['media_local_path'] as String?;
        // Validate that the file still exists on disk
        if (localPath != null && !File(localPath).existsSync()) {
          localPath = null;
        }
      }

      // Read thumbnail blob if available
      Uint8List? thumbnail;
      try {
        thumbnail = row['media_thumbnail'] as Uint8List?;
      } catch (_) {}

      media = TelegramMediaInfo(
        fileId: mediaFileId,
        localPath: localPath,
        width: row['media_width'] as int?,
        height: row['media_height'] as int?,
        duration: row['media_duration'] as int?,
        fileName: row['media_file_name'] as String?,
        mimeType: row['media_mime_type'] as String?,
        minithumbnailData: row['media_minithumbnail'] as String?,
        mediaBytes: mediaBytes,
        extension: row['media_extension'] as String?,
        thumbnail: thumbnail,
      );
    } else {
      // Location/venue: surface thumbnail even without a media file ID
      final ct = row['content_type'] as String;
      if (ct == 'location' || ct == 'venue') {
        Uint8List? thumbnail;
        try {
          thumbnail = row['media_thumbnail'] as Uint8List?;
        } catch (_) {}
        if (thumbnail != null && thumbnail.isNotEmpty) {
          media = TelegramMediaInfo(
            fileId: 0,
            thumbnail: thumbnail,
          );
        }
      }
    }

    // Deserialize reactions from JSON
    List<TelegramReaction> reactions = const [];
    final reactionsJson = row['reactions_json'] as String?;
    if (reactionsJson != null && reactionsJson.isNotEmpty) {
      try {
        final list = jsonDecode(reactionsJson) as List<dynamic>;
        reactions = list
            .whereType<Map<String, dynamic>>()
            .map(TelegramReaction.fromJson)
            .toList();
      } catch (_) {
        // Ignore corrupt JSON
      }
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
      replyToMessageId: row['reply_to_message_id'] as int?,
      replyToSenderName: row['reply_to_sender_name'] as String?,
      replyToText: row['reply_to_text'] as String?,
      editDate: row['edit_date'] as int?,
      forwardSenderName: row['forward_sender_name'] as String?,
      reactions: reactions,
    );
  }

  // ---------- Extraction helpers ----------

  /// Lazily-created extracted media directory inside the app's cache.
  String? _extractedDirPath;

  /// Get (and lazily create) the extracted media directory.
  String _getExtractedDir() {
    if (_extractedDirPath != null) return _extractedDirPath!;
    final path = '$cacheDirAbsolutePath/extracted';
    final dir = Directory(path);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    _extractedDirPath = path;
    return path;
  }

  /// Extract a blob to a deterministic file path inside the extracted/ dir.
  /// Returns the file path, or null on failure.
  String? _extractBlobToFile(
    int chatId,
    int msgId,
    Uint8List bytes,
    String? mimeType,
    String? fileName,
  ) {
    try {
      final dir = _getExtractedDir();
      final ext = _resolveExtension(mimeType, fileName);
      final filePath = '$dir/chat_${chatId}_msg_$msgId$ext';
      final file = File(filePath);

      // Skip write if already extracted with correct size
      if (file.existsSync() && file.lengthSync() == bytes.length) {
        return filePath;
      }

      file.writeAsBytesSync(bytes);
      return filePath;
    } catch (e) {
      stderr.writeln('TelegramCache: _extractBlobToFile error: $e');
      return null;
    }
  }

  /// Extract a media blob to disk on demand (e.g. for gallery viewer).
  /// Returns the extracted file path, or null if no blob exists.
  String? extractBlobToFile(int chatId, int messageId) {
    try {
      final db = _openDb(chatId);
      final rows = db.select(
        'SELECT media_data, media_mime_type, media_file_name '
        'FROM messages WHERE id = ?',
        [messageId],
      );
      if (rows.isEmpty) return null;
      final row = rows.first;
      final blobData = row['media_data'] as Uint8List?;
      if (blobData == null || blobData.isEmpty) return null;

      final mime = row['media_mime_type'] as String?;
      final fileName = row['media_file_name'] as String?;
      return _extractBlobToFile(chatId, messageId, blobData, mime, fileName);
    } catch (e) {
      stderr.writeln('TelegramCache: extractBlobToFile error: $e');
      return null;
    }
  }

  /// Store a thumbnail BLOB for a message.
  void storeThumbnail(int chatId, int messageId, Uint8List thumbnailBytes) {
    try {
      final db = _openDb(chatId);
      db.execute(
        'UPDATE messages SET media_thumbnail = ? WHERE id = ?',
        [thumbnailBytes, messageId],
      );
    } catch (e) {
      stderr.writeln('TelegramCache: storeThumbnail error: $e');
    }
  }

  /// Maximum thumbnail dimension (width or height) in pixels.
  static const _thumbnailMaxDim = 200;

  /// Generate and store a thumbnail for a media message if one is missing.
  ///
  /// For images (photo, sticker, animation): downsizes using the `image`
  /// package to a ≤200px JPEG.
  /// For videos (video, videoNote): extracts a frame via
  /// VideoMetadataExtractor, reads it back as PNG bytes.
  ///
  /// Returns the generated thumbnail bytes, or null on failure / not applicable.
  Future<Uint8List?> generateThumbnailIfMissing(
      int chatId, int messageId) async {
    try {
      final db = _openDb(chatId);

      // Check if thumbnail already exists
      final check = db.select(
        'SELECT media_thumbnail, content_type, media_data, media_extension, '
        'media_mime_type, media_file_name, text FROM messages WHERE id = ?',
        [messageId],
      );
      if (check.isEmpty) return null;
      final row = check.first;

      final existing = row['media_thumbnail'] as Uint8List?;
      if (existing != null && existing.isNotEmpty) return existing;

      final contentType = row['content_type'] as String;
      final blobData = row['media_data'] as Uint8List?;

      // Image types: downsize from blob bytes
      if (_inMemoryTypes.contains(contentType) &&
          blobData != null &&
          blobData.isNotEmpty) {
        return _generateImageThumbnail(db, messageId, blobData);
      }

      // Video types: extract a frame via media_kit
      if (contentType == 'video' || contentType == 'videoNote') {
        return _generateVideoThumbnail(
            db, chatId, messageId, blobData,
            row['media_mime_type'] as String?,
            row['media_file_name'] as String?);
      }

      // Location/venue types: generate static map thumbnail
      if (contentType == 'location' || contentType == 'venue') {
        final text = row['text'] as String?;
        return _generateLocationThumbnail(db, messageId, contentType, text);
      }

      return null;
    } catch (e) {
      stderr.writeln('TelegramCache: generateThumbnailIfMissing error: $e');
      return null;
    }
  }

  /// Downsize image bytes to a JPEG thumbnail (≤200px on longest side).
  Uint8List? _generateImageThumbnail(
      Database db, int messageId, Uint8List imageBytes) {
    try {
      final decoded = img.decodeImage(imageBytes);
      if (decoded == null) return null;

      final resized = img.copyResize(
        decoded,
        width: decoded.width >= decoded.height ? _thumbnailMaxDim : null,
        height: decoded.height > decoded.width ? _thumbnailMaxDim : null,
        interpolation: img.Interpolation.linear,
      );

      final jpegBytes = Uint8List.fromList(img.encodeJpg(resized, quality: 75));

      db.execute(
        'UPDATE messages SET media_thumbnail = ? WHERE id = ?',
        [jpegBytes, messageId],
      );
      return jpegBytes;
    } catch (e) {
      stderr.writeln('TelegramCache: _generateImageThumbnail error: $e');
      return null;
    }
  }

  /// Extract a video frame and store it as a PNG thumbnail.
  Future<Uint8List?> _generateVideoThumbnail(
    Database db,
    int chatId,
    int messageId,
    Uint8List? blobData,
    String? mimeType,
    String? fileName,
  ) async {
    try {
      // We need the video on disk — either already extracted or extract now
      String? videoPath;
      if (blobData != null && blobData.isNotEmpty) {
        videoPath = _extractBlobToFile(
            chatId, messageId, blobData, mimeType, fileName);
      }
      if (videoPath == null) return null;

      final dir = _getExtractedDir();
      final thumbPath = '$dir/thumb_${chatId}_$messageId.png';

      final result = await VideoMetadataExtractor.generateThumbnail(
        videoPath,
        thumbPath,
        atSeconds: 1,
      );
      if (result == null) return null;

      final thumbFile = File(thumbPath);
      if (!thumbFile.existsSync()) return null;
      final thumbBytes = thumbFile.readAsBytesSync();

      // Clean up the temp thumbnail file
      try {
        thumbFile.deleteSync();
      } catch (_) {}

      if (thumbBytes.isEmpty) return null;

      db.execute(
        'UPDATE messages SET media_thumbnail = ? WHERE id = ?',
        [thumbBytes, messageId],
      );
      return thumbBytes;
    } catch (e) {
      stderr.writeln('TelegramCache: _generateVideoThumbnail error: $e');
      return null;
    }
  }

  /// Generate a static map thumbnail for a location or venue message.
  Future<Uint8List?> _generateLocationThumbnail(
    Database db,
    int messageId,
    String contentType,
    String? text,
  ) async {
    if (text == null || text.isEmpty) {
      stderr.writeln('TelegramCache: _generateLocationThumbnail: no text for msg $messageId');
      return null;
    }
    try {
      // Parse coordinates from text
      double? lat, lon;
      if (contentType == 'venue') {
        // Venue format: "Title\nAddress\nlat, lng"
        final lines = text.split('\n');
        if (lines.length >= 3) {
          final coords = _parseCoordsString(lines[2]);
          lat = coords?.$1;
          lon = coords?.$2;
        }
      } else {
        // Location format: "lat, lng" or "lat, lng|live"
        final clean = text.replaceAll('|live', '');
        final coords = _parseCoordsString(clean);
        lat = coords?.$1;
        lon = coords?.$2;
      }

      if (lat == null || lon == null) {
        stderr.writeln('TelegramCache: _generateLocationThumbnail: could not parse coords from "$text"');
        return null;
      }

      stderr.writeln('TelegramCache: generating map thumbnail for msg $messageId at $lat, $lon');
      final pngBytes = await StaticMapService.generateStaticMap(
        lat: lat,
        lon: lon,
        width: 300,
        height: 200,
        zoom: 15,
      );
      if (pngBytes == null) {
        stderr.writeln('TelegramCache: StaticMapService returned null for msg $messageId');
        return null;
      }
      stderr.writeln('TelegramCache: map thumbnail generated for msg $messageId (${pngBytes.length} bytes)');

      db.execute(
        'UPDATE messages SET media_thumbnail = ? WHERE id = ?',
        [pngBytes, messageId],
      );
      return pngBytes;
    } catch (e) {
      stderr.writeln('TelegramCache: _generateLocationThumbnail error: $e');
      return null;
    }
  }

  /// Parse "lat, lng" string into a (lat, lon) tuple.
  static (double, double)? _parseCoordsString(String text) {
    final parts = text.split(',');
    if (parts.length != 2) return null;
    final lat = double.tryParse(parts[0].trim());
    final lon = double.tryParse(parts[1].trim());
    if (lat == null || lon == null) return null;
    return (lat, lon);
  }

  /// Resolve a file extension from MIME type or original file name.
  static String _resolveExtension(String? mimeType, String? fileName) {
    // Try to get extension from original file name
    if (fileName != null && fileName.contains('.')) {
      final dot = fileName.lastIndexOf('.');
      return fileName.substring(dot); // e.g. ".pdf"
    }
    // Fall back to MIME type mapping
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
        return '.m4a';
      case 'application/pdf':
        return '.pdf';
      case 'image/tgs':
      case 'application/x-tgsticker':
        return '.tgs';
      default:
        if (mime.startsWith('image/')) return '.jpg';
        if (mime.startsWith('video/')) return '.mp4';
        if (mime.startsWith('audio/')) return '.ogg';
        return '.bin';
    }
  }

  // ---------- Blob ingestion ----------

  /// Ingest a downloaded media file as a BLOB into the per-chat DB.
  ///
  /// Returns `true` if the file was stored (or dedup-matched) and the
  /// original file deleted; `false` if skipped (too large, missing, etc.).
  bool ingestMediaBlob(int chatId, int messageId, String filePath) {
    try {
      final file = File(filePath);
      if (!file.existsSync()) return false;

      final size = file.lengthSync();
      if (size > maxBlobSizeBytes || size == 0) return false;

      final bytes = file.readAsBytesSync();
      final sha1Hex = sha1.convert(bytes).toString();
      final tlshHex = TLSH.hash(Uint8List.fromList(bytes));

      final db = _openDb(chatId);

      // Resolve file extension from existing mime/fileName columns
      String? ext;
      try {
        final meta = db.select(
          'SELECT media_mime_type, media_file_name FROM messages WHERE id = ?',
          [messageId],
        );
        if (meta.isNotEmpty) {
          ext = _resolveExtension(
            meta.first['media_mime_type'] as String?,
            meta.first['media_file_name'] as String?,
          );
        }
      } catch (_) {}

      // Dedup: check if identical content already exists in this chat DB
      final existing = db.select(
        'SELECT id FROM messages '
        'WHERE media_sha1 = ? AND media_data IS NOT NULL AND id != ? LIMIT 1',
        [sha1Hex, messageId],
      );

      if (existing.isNotEmpty) {
        // Same content already stored — store blob + set hash columns
        db.execute(
          'UPDATE messages SET media_data = ?, media_sha1 = ?, media_tlsh = ?, '
          'media_data_size = ?, media_extension = ? WHERE id = ?',
          [bytes, sha1Hex, tlshHex, size, ext, messageId],
        );
        stderr.writeln('TelegramCache: dedup hit for msg $messageId '
            '(sha1=$sha1Hex), skipping blob storage');
      } else {
        db.execute(
          'UPDATE messages SET media_data = ?, media_data_size = ?, '
          'media_sha1 = ?, media_tlsh = ?, media_extension = ? WHERE id = ?',
          [bytes, size, sha1Hex, tlshHex, ext, messageId],
        );
      }

      // Delete the original file now that it's stored in the DB
      try {
        file.deleteSync();
      } catch (e) {
        stderr.writeln('TelegramCache: could not delete original file '
            '$filePath: $e');
      }

      stderr.writeln('TelegramCache: ingested ${size ~/ 1024}KB blob for '
          'msg $messageId (sha1=$sha1Hex)');
      return true;
    } catch (e) {
      stderr.writeln('TelegramCache: ingestMediaBlob error: $e');
      LogService().error('TelegramCache: ingestMediaBlob error: $e');
      return false;
    }
  }

  /// Delete messages from the cache by their IDs.
  void deleteMessages(int chatId, List<int> messageIds) {
    if (messageIds.isEmpty) return;
    try {
      final db = _openDb(chatId);
      final placeholders = List.filled(messageIds.length, '?').join(', ');
      db.execute(
        'DELETE FROM messages WHERE id IN ($placeholders)',
        messageIds,
      );
      stderr.writeln('TelegramCache: deleted ${messageIds.length} messages from chat $chatId');
    } catch (e) {
      stderr.writeln('TelegramCache: deleteMessages error: $e');
      LogService().error('TelegramCache: deleteMessages error: $e');
    }
  }

  /// Mark all messages in a chat as read in the local cache.
  void markAllAsRead(int chatId) {
    try {
      final db = _openDb(chatId);
      db.execute('UPDATE messages SET is_read = 1 WHERE is_read = 0');
    } catch (e) {
      stderr.writeln('TelegramCache: markAllAsRead error: $e');
    }
  }

  /// Get the count of unread messages in a chat.
  int getUnreadCount(int chatId) {
    try {
      final db = _openDb(chatId);
      final result = db.select(
        'SELECT COUNT(*) as cnt FROM messages WHERE is_read = 0',
      );
      return result.first['cnt'] as int;
    } catch (e) {
      stderr.writeln('TelegramCache: getUnreadCount error: $e');
      return 0;
    }
  }

  /// Store (or update) a forum topic's icon bytes in the per-chat DB.
  void storeTopicPhoto(int chatId, int messageThreadId, Uint8List photoBytes) {
    try {
      final db = _openDb(chatId);
      db.execute(
        'INSERT OR REPLACE INTO topic_photos '
        '(message_thread_id, photo_data, photo_size, updated_at) '
        'VALUES (?, ?, ?, ?)',
        [messageThreadId, photoBytes, photoBytes.length,
         DateTime.now().toUtc().millisecondsSinceEpoch],
      );
    } catch (e) {
      stderr.writeln('TelegramCache: storeTopicPhoto error: $e');
    }
  }

  /// Load all cached topic photos for a chat, keyed by messageThreadId.
  Map<int, Uint8List> getAllTopicPhotos(int chatId) {
    try {
      final db = _openDb(chatId);
      final rows = db.select(
        'SELECT message_thread_id, photo_data FROM topic_photos',
      );
      final result = <int, Uint8List>{};
      for (final row in rows) {
        final data = row['photo_data'] as Uint8List?;
        if (data != null && data.isNotEmpty) {
          result[row['message_thread_id'] as int] = data;
        }
      }
      return result;
    } catch (e) {
      stderr.writeln('TelegramCache: getAllTopicPhotos error: $e');
      return {};
    }
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
          'SELECT id, content_type, date, media_file_id, media_local_path, '
          'media_minithumbnail '
          'FROM messages ORDER BY date DESC LIMIT 5',
        );
        final rows = sample
            .map((r) => {
                  'id': r['id'],
                  'content_type': r['content_type'],
                  'date': r['date'],
                  'media_file_id': r['media_file_id'],
                  'media_local_path': r['media_local_path'],
                  'media_minithumbnail': r['media_minithumbnail'] != null
                      ? '${(r['media_minithumbnail'] as String).length} chars'
                      : null,
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

    // Close all open DBs (including visits) and delete all .db files
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

  // ---------- Migration of existing file-based media ----------

  /// Auto-migrate existing file-based media into BLOBs when a DB is opened.
  /// Runs in a transaction for atomicity. Silent on empty results.
  void _autoMigrateMedia(Database db, int chatId) {
    try {
      final rows = db.select(
        'SELECT id, media_local_path, media_mime_type, media_file_name '
        'FROM messages '
        'WHERE media_local_path IS NOT NULL AND media_data IS NULL '
        'AND media_file_id IS NOT NULL',
      );
      if (rows.isEmpty) return;

      int migrated = 0, skipped = 0;
      db.execute('BEGIN');
      try {
        for (final row in rows) {
          final msgId = row['id'] as int;
          final path = row['media_local_path'] as String?;
          if (path == null) continue;

          final file = File(path);
          if (!file.existsSync()) {
            skipped++;
            continue;
          }

          final size = file.lengthSync();
          if (size > maxBlobSizeBytes || size == 0) {
            skipped++;
            continue;
          }

          final bytes = file.readAsBytesSync();
          final sha1Hex = sha1.convert(bytes).toString();
          final tlshHex = TLSH.hash(Uint8List.fromList(bytes));
          final ext = _resolveExtension(
            row['media_mime_type'] as String?,
            row['media_file_name'] as String?,
          );

          db.execute(
            'UPDATE messages SET media_data = ?, media_data_size = ?, '
            'media_sha1 = ?, media_tlsh = ?, media_extension = ? WHERE id = ?',
            [bytes, size, sha1Hex, tlshHex, ext, msgId],
          );

          try {
            file.deleteSync();
          } catch (_) {}
          migrated++;
        }
        db.execute('COMMIT');
        if (migrated > 0) {
          stderr.writeln('TelegramCache: auto-migrated $migrated media files '
              'to BLOBs for chat $chatId (skipped $skipped)');
        }
      } catch (e) {
        db.execute('ROLLBACK');
        stderr.writeln('TelegramCache: _autoMigrateMedia rollback: $e');
      }
    } catch (e) {
      stderr.writeln('TelegramCache: _autoMigrateMedia error: $e');
    }
  }

  /// Migrate all existing media files to BLOBs across all chat databases.
  /// Returns aggregate stats.
  Map<String, int> migrateAllExistingMedia() {
    int totalMigrated = 0, totalSkipped = 0, totalErrors = 0;
    final cacheDir = Directory(cacheDirAbsolutePath);
    if (!cacheDir.existsSync()) {
      return {'migrated': 0, 'skipped': 0, 'errors': 0};
    }

    for (final f in cacheDir.listSync().whereType<File>()) {
      if (!f.path.endsWith('.db')) continue;
      final name = f.uri.pathSegments.last;
      final match = RegExp(r'chat_(-?\d+)\.db').firstMatch(name);
      if (match == null) continue;
      final chatId = int.parse(match.group(1)!);

      try {
        final db = _openDb(chatId);
        // _openDb already calls _autoMigrateMedia, but count results here
        final remaining = db.select(
          'SELECT COUNT(*) as cnt FROM messages '
          'WHERE media_local_path IS NOT NULL AND media_data IS NULL '
          'AND media_file_id IS NOT NULL',
        );
        totalSkipped += remaining.first['cnt'] as int;
      } catch (e) {
        totalErrors++;
        stderr.writeln('TelegramCache: migrateAll error for chat $chatId: $e');
      }
    }
    return {
      'migrated': totalMigrated,
      'skipped': totalSkipped,
      'errors': totalErrors,
    };
  }

  // ---------- Stats ----------

  /// Get media blob storage statistics.
  Map<String, dynamic> mediaBlobStats({int? chatId}) {
    try {
      if (chatId != null) {
        final db = _openDb(chatId);
        return _blobStatsForDb(db, chatId);
      }

      // Aggregate across all open chat DBs
      int totalBlobs = 0, totalFileOnly = 0, totalBlobBytes = 0;
      final cacheDir = Directory(cacheDirAbsolutePath);
      if (cacheDir.existsSync()) {
        for (final f in cacheDir.listSync().whereType<File>()) {
          if (!f.path.endsWith('.db')) continue;
          final match = RegExp(r'chat_(-?\d+)\.db')
              .firstMatch(f.uri.pathSegments.last);
          if (match == null) continue;
          final cid = int.parse(match.group(1)!);
          try {
            final db = _openDb(cid);
            final stats = _blobStatsForDb(db, cid);
            totalBlobs += stats['blob_stored'] as int;
            totalFileOnly += stats['file_only'] as int;
            totalBlobBytes += stats['total_blob_bytes'] as int;
          } catch (_) {}
        }
      }
      return {
        'blob_stored': totalBlobs,
        'file_only': totalFileOnly,
        'total_blob_bytes': totalBlobBytes,
        'total_blob_mb':
            (totalBlobBytes / (1024 * 1024)).toStringAsFixed(1),
      };
    } catch (e) {
      return {'error': 'mediaBlobStats failed: $e'};
    }
  }

  Map<String, dynamic> _blobStatsForDb(Database db, int chatId) {
    final blobResult = db.select(
      'SELECT COUNT(*) as cnt, COALESCE(SUM(media_data_size), 0) as total '
      'FROM messages WHERE media_data IS NOT NULL',
    );
    final blobCount = blobResult.first['cnt'] as int;
    final blobBytes = blobResult.first['total'] as int;

    final fileResult = db.select(
      'SELECT COUNT(*) as cnt FROM messages '
      'WHERE media_local_path IS NOT NULL AND media_data IS NULL '
      'AND media_file_id IS NOT NULL',
    );
    final fileOnly = fileResult.first['cnt'] as int;

    return {
      'chat_id': chatId,
      'blob_stored': blobCount,
      'file_only': fileOnly,
      'total_blob_bytes': blobBytes,
      'total_blob_mb': (blobBytes / (1024 * 1024)).toStringAsFixed(1),
    };
  }

  // ---------- Visit tracking ----------

  /// Lazy-open the shared visits database.
  Database _openVisitsDb() {
    if (_visitsDb != null) return _visitsDb!;

    final dbPath = _storage.getAbsolutePath('${_cacheDirPath()}/visits.db');
    _visitsDb = SQLiteLoader.openDatabase(dbPath);

    _visitsDb!.execute('''
      CREATE TABLE IF NOT EXISTS chat_visits (
        chat_id INTEGER NOT NULL,
        visited_at INTEGER NOT NULL
      );
    ''');
    _visitsDb!.execute('''
      CREATE INDEX IF NOT EXISTS idx_visits_chat
      ON chat_visits(chat_id);
    ''');
    _visitsDb!.execute('''
      CREATE INDEX IF NOT EXISTS idx_visits_date
      ON chat_visits(visited_at);
    ''');

    // Auto-prune entries older than 30 days (once per session)
    if (!_visitsPruned) {
      final cutoff = DateTime.now().toUtc()
          .subtract(const Duration(days: 30))
          .millisecondsSinceEpoch ~/ 1000;
      _visitsDb!.execute(
        'DELETE FROM chat_visits WHERE visited_at < ?',
        [cutoff],
      );
      _visitsPruned = true;
    }

    return _visitsDb!;
  }

  // ---------- Chat photo caching ----------

  /// Lazy-open the shared photos database.
  Database _openPhotosDb() {
    if (_photosDb != null) return _photosDb!;

    final dbPath = _storage.getAbsolutePath('${_cacheDirPath()}/photos.db');
    _photosDb = SQLiteLoader.openDatabase(dbPath);

    _photosDb!.execute('''
      CREATE TABLE IF NOT EXISTS chat_photos (
        chat_id INTEGER PRIMARY KEY,
        photo_data BLOB NOT NULL,
        photo_size INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');

    return _photosDb!;
  }

  /// Store (or update) a chat's profile photo bytes.
  void storeChatPhoto(int chatId, Uint8List photoBytes) {
    try {
      final db = _openPhotosDb();
      db.execute(
        'INSERT OR REPLACE INTO chat_photos (chat_id, photo_data, photo_size, updated_at) VALUES (?, ?, ?, ?)',
        [chatId, photoBytes, photoBytes.length, DateTime.now().toUtc().millisecondsSinceEpoch],
      );
    } catch (e) {
      stderr.writeln('TelegramCache: storeChatPhoto error: $e');
    }
  }

  /// Get a single chat's cached photo bytes, or null.
  Uint8List? getChatPhoto(int chatId) {
    try {
      final db = _openPhotosDb();
      final rows = db.select('SELECT photo_data FROM chat_photos WHERE chat_id = ?', [chatId]);
      if (rows.isEmpty) return null;
      return rows.first['photo_data'] as Uint8List?;
    } catch (e) {
      stderr.writeln('TelegramCache: getChatPhoto error: $e');
      return null;
    }
  }

  /// Load all cached chat photos in a single query (for chat list page).
  Map<int, Uint8List> getAllCachedChatPhotos() {
    try {
      final db = _openPhotosDb();
      final rows = db.select('SELECT chat_id, photo_data FROM chat_photos');
      final result = <int, Uint8List>{};
      for (final row in rows) {
        final data = row['photo_data'] as Uint8List?;
        if (data != null && data.isNotEmpty) {
          result[row['chat_id'] as int] = data;
        }
      }
      return result;
    } catch (e) {
      stderr.writeln('TelegramCache: getAllCachedChatPhotos error: $e');
      return {};
    }
  }

  /// Record a visit to a chat (called when the user opens a chat).
  void recordVisit(int chatId) {
    try {
      final db = _openVisitsDb();
      final nowSec = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      db.execute(
        'INSERT INTO chat_visits (chat_id, visited_at) VALUES (?, ?)',
        [chatId, nowSec],
      );
    } catch (e) {
      stderr.writeln('TelegramCache: recordVisit error: $e');
    }
  }

  /// Get the top-30 most-visited chats within the last 30 days.
  /// Returns a map of chatId → visitCount, ordered by count descending.
  Map<int, int> getTopVisitedChats() {
    try {
      final db = _openVisitsDb();
      final cutoff = DateTime.now().toUtc()
          .subtract(const Duration(days: 30))
          .millisecondsSinceEpoch ~/ 1000;
      final rows = db.select('''
        SELECT chat_id, COUNT(*) as visit_count
        FROM chat_visits
        WHERE visited_at >= ?
        GROUP BY chat_id
        ORDER BY visit_count DESC
        LIMIT 30
      ''', [cutoff]);

      final result = <int, int>{};
      for (final row in rows) {
        result[row['chat_id'] as int] = row['visit_count'] as int;
      }
      return result;
    } catch (e) {
      stderr.writeln('TelegramCache: getTopVisitedChats error: $e');
      return {};
    }
  }

  /// Inspect visit records for debugging.
  Map<String, dynamic> inspectVisits() {
    try {
      final db = _openVisitsDb();
      final countResult = db.select(
        'SELECT COUNT(*) as cnt FROM chat_visits',
      );
      final totalVisits = countResult.first['cnt'] as int;

      final topChats = db.select('''
        SELECT chat_id, COUNT(*) as visit_count,
               MAX(visited_at) as last_visit
        FROM chat_visits
        GROUP BY chat_id
        ORDER BY visit_count DESC
        LIMIT 10
      ''');
      final top = topChats
          .map((r) => {
                'chat_id': r['chat_id'],
                'visit_count': r['visit_count'],
                'last_visit': r['last_visit'],
              })
          .toList();

      return {
        'total_visits': totalVisits,
        'top_chats': top,
      };
    } catch (e) {
      return {'error': 'inspectVisits failed: $e'};
    }
  }

  /// Clear all visit records.
  Map<String, dynamic> clearVisits() {
    try {
      final db = _openVisitsDb();
      db.execute('DELETE FROM chat_visits');
      return {'cleared': true};
    } catch (e) {
      return {'error': 'clearVisits failed: $e'};
    }
  }

  /// Close all open databases, release resources, and clean up extracted files.
  void dispose() {
    // Clean up the extracted media directory
    try {
      final dir = Directory('$cacheDirAbsolutePath/extracted');
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    } catch (e) {
      stderr.writeln('TelegramCache: dispose extracted cleanup error: $e');
    }
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
