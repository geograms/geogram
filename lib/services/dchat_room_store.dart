import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;

import '../models/dchat_storage.dart';
import '../models/distributed_chat.dart';
import 'profile_sqlite_database.dart';
import 'profile_storage.dart';

class DChatRoomStore {
  final String roomId;
  final ScopedProfileStorage _roomStorage;
  final ProfileSQLiteDatabase _roomDatabase;
  final ProfileSQLiteDatabase _deviceDatabase;

  bool _opened = false;

  DChatRoomStore({required ProfileStorage profileStorage, required this.roomId})
    : _roomStorage = ScopedProfileStorage(
        profileStorage,
        p.join('dchat', roomId),
      ),
      _roomDatabase = ProfileSQLiteDatabase(
        storage: ScopedProfileStorage(profileStorage, p.join('dchat', roomId)),
        relativePath: 'room.sqlite3',
        tempLabel: 'dchat-room-$roomId',
      ),
      _deviceDatabase = ProfileSQLiteDatabase(
        storage: ScopedProfileStorage(profileStorage, p.join('dchat', roomId)),
        relativePath: 'device.sqlite3',
        tempLabel: 'dchat-device-$roomId',
      );

  String get relativeRoomPath => p.join('dchat', roomId);

  String get absoluteRoomPath => _roomStorage.basePath;

  Future<bool> exists() async {
    return _roomStorage.exists('room.sqlite3');
  }

  Future<void> open() async {
    if (_opened) {
      return;
    }

    await _ensureRoomDirectories();
    await _roomDatabase.write(_initRoomSchema);
    await _deviceDatabase.write(_initDeviceSchema);
    _opened = true;
  }

  Future<void> initializeRoom(DChatRoomMetadata metadata) async {
    await open();
    final now = metadata.updatedAt.toUtc();
    await _roomDatabase.write((db) {
      db.execute(
        '''
        INSERT INTO room_meta (
          room_id,
          title,
          description,
          icon,
          owner_npub,
          room_npub,
          seed_peer_hints_json,
          current_epoch,
          snapshot_start,
          state,
          join_policy,
          created_at,
          updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(room_id) DO UPDATE SET
          title = excluded.title,
          description = excluded.description,
          icon = excluded.icon,
          owner_npub = excluded.owner_npub,
          room_npub = excluded.room_npub,
          seed_peer_hints_json = excluded.seed_peer_hints_json,
          current_epoch = excluded.current_epoch,
          snapshot_start = excluded.snapshot_start,
          state = excluded.state,
          join_policy = excluded.join_policy,
          updated_at = excluded.updated_at;
        ''',
        [
          metadata.roomId,
          metadata.title,
          metadata.description,
          metadata.icon,
          metadata.ownerNpub,
          metadata.roomNpub,
          jsonEncode(metadata.seedPeerHints),
          metadata.currentEpoch,
          metadata.snapshotStart,
          metadata.state,
          metadata.joinPolicy,
          _millis(metadata.createdAt),
          _millis(now),
        ],
      );
    });
  }

  Future<DChatRoomMetadata?> loadMetadata() async {
    if (!await exists()) {
      return null;
    }
    await open();
    return _roomDatabase.read((db) {
      final rows = db.select('''
        SELECT
          room_id,
          title,
          description,
          icon,
          owner_npub,
          room_npub,
          seed_peer_hints_json,
          current_epoch,
          snapshot_start,
          state,
          join_policy,
          created_at,
          updated_at
        FROM room_meta
        LIMIT 1;
        ''');
      if (rows.isEmpty) {
        return null;
      }
      return _roomMetadataFromRow(rows.first);
    });
  }

  Future<void> upsertMember(DChatMemberRecord record) async {
    await open();
    await _roomDatabase.write((db) {
      db.execute(
        '''
        INSERT INTO members (
          member_npub,
          role,
          status,
          joined_at,
          removed_at,
          added_by,
          updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(member_npub) DO UPDATE SET
          role = excluded.role,
          status = excluded.status,
          joined_at = excluded.joined_at,
          removed_at = excluded.removed_at,
          added_by = excluded.added_by,
          updated_at = excluded.updated_at;
        ''',
        [
          record.memberNpub,
          record.role,
          record.status,
          _millisOrNull(record.joinedAt),
          _millisOrNull(record.removedAt),
          record.addedBy,
          _millis(record.updatedAt),
        ],
      );
    });
  }

  Future<List<DChatMemberRecord>> listMembers() async {
    if (!await exists()) {
      return const [];
    }
    await open();
    return _roomDatabase.read((db) {
      final rows = db.select('''
        SELECT
          member_npub,
          role,
          status,
          joined_at,
          removed_at,
          added_by,
          updated_at
        FROM members
        ORDER BY joined_at ASC, member_npub ASC;
        ''');
      return rows.map(_memberFromRow).toList();
    });
  }

  Future<void> upsertTopic(DChatTopicRecord topic) async {
    await open();
    await _roomDatabase.write((db) {
      db.execute(
        '''
        INSERT INTO topics (
          topic_id,
          title,
          description,
          icon,
          created_by_npub,
          created_at,
          updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(topic_id) DO UPDATE SET
          title = excluded.title,
          description = excluded.description,
          icon = excluded.icon,
          updated_at = excluded.updated_at;
        ''',
        [
          topic.topicId,
          topic.title,
          topic.description,
          topic.icon,
          topic.createdByNpub,
          _millis(topic.createdAt),
          _millis(topic.updatedAt),
        ],
      );
    });
  }

  Future<List<DChatTopicRecord>> listTopics() async {
    if (!await exists()) {
      return const [];
    }
    await open();
    return _roomDatabase.read((db) {
      final rows = db.select('''
        SELECT
          topic_id,
          title,
          description,
          icon,
          created_by_npub,
          created_at,
          updated_at
        FROM topics
        ORDER BY created_at ASC, topic_id ASC;
        ''');
      return rows.map(_topicFromRow).toList();
    });
  }

  Future<void> appendControlEvent(
    DistributedChatControlEvent event, {
    int lamport = 0,
  }) async {
    await open();
    final eventId = event.event.id ?? event.event.calculateId();
    await _roomDatabase.write((db) {
      db.execute(
        '''
        INSERT OR REPLACE INTO control_events (
          event_id,
          event_type,
          actor_npub,
          created_at,
          lamport,
          target_npub,
          raw_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?);
        ''',
        [
          eventId,
          event.type.wireName,
          event.actorNpub,
          event.event.createdAt * 1000,
          lamport,
          event.targetNpub,
          jsonEncode(event.toJson()),
        ],
      );
    });
  }

  Future<bool> hasControlEvent(String eventId) async {
    if (!await exists()) {
      return false;
    }
    await open();
    return _roomDatabase.read((db) {
      final rows = db.select(
        'SELECT 1 FROM control_events WHERE event_id = ? LIMIT 1;',
        [eventId],
      );
      return rows.isNotEmpty;
    });
  }

  Future<int> nextControlLamport() async {
    if (!await exists()) {
      return 1;
    }
    await open();
    return _roomDatabase.read((db) {
      final rows = db.select(
        'SELECT COALESCE(MAX(lamport), 0) AS max_lamport FROM control_events;',
      );
      final current = rows.first['max_lamport'] as int? ?? 0;
      return current + 1;
    });
  }

  Future<List<DistributedChatControlEvent>> listControlEvents({
    int limit = 500,
  }) async {
    if (!await exists()) {
      return const [];
    }
    await open();
    return _roomDatabase.read((db) {
      final rows = db.select(
        '''
        SELECT raw_json
        FROM control_events
        ORDER BY lamport DESC, created_at DESC, event_id DESC
        LIMIT ?;
        ''',
        [limit.clamp(1, 5000)],
      );
      return rows.reversed
          .map(
            (row) => DistributedChatControlEvent.fromJson(
              jsonDecode(row['raw_json'] as String) as Map<String, dynamic>,
            ),
          )
          .toList();
    });
  }

  Future<void> recordEpoch(DChatEpochRecord record) async {
    await open();
    await _roomDatabase.write((db) {
      db.execute(
        '''
        INSERT OR REPLACE INTO epochs (
          epoch,
          created_at,
          rotated_by_npub,
          control_event_id,
          summary
        ) VALUES (?, ?, ?, ?, ?);
        ''',
        [
          record.epoch,
          _millis(record.createdAt),
          record.rotatedByNpub,
          record.controlEventId,
          record.summary,
        ],
      );
    });
  }

  Future<List<DChatEpochRecord>> listEpochs() async {
    if (!await exists()) {
      return const [];
    }
    await open();
    return _roomDatabase.read((db) {
      final rows = db.select('''
        SELECT epoch, created_at, rotated_by_npub, control_event_id, summary
        FROM epochs
        ORDER BY epoch ASC;
        ''');
      return rows.map(_epochFromRow).toList();
    });
  }

  Future<void> putEpochKeyBox(DChatEpochKeyBox box) async {
    await open();
    await _roomDatabase.write((db) {
      db.execute(
        '''
        INSERT OR REPLACE INTO epoch_key_boxes (
          epoch,
          recipient_npub,
          envelope,
          created_at
        ) VALUES (?, ?, ?, ?);
        ''',
        [box.epoch, box.recipientNpub, box.envelope, _millis(box.createdAt)],
      );
    });
  }

  Future<List<DChatEpochKeyBox>> listEpochKeyBoxes(int epoch) async {
    if (!await exists()) {
      return const [];
    }
    await open();
    return _roomDatabase.read((db) {
      final rows = db.select(
        '''
        SELECT epoch, recipient_npub, envelope, created_at
        FROM epoch_key_boxes
        WHERE epoch = ?
        ORDER BY recipient_npub ASC;
        ''',
        [epoch],
      );
      return rows.map(_epochKeyBoxFromRow).toList();
    });
  }

  Future<void> appendMessage(DChatMessageRecord message) async {
    await open();
    await _roomDatabase.write((db) {
      db.execute(
        '''
        INSERT OR REPLACE INTO messages (
          message_id,
          topic_id,
          epoch,
          lamport,
          author_npub,
          authored_at,
          ciphertext,
          nonce,
          enc,
          ciphertext_sha1,
          raw_event_json,
          deleted_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        ''',
        [
          message.messageId,
          message.topicId,
          message.epoch,
          message.lamport,
          message.authorNpub,
          _millis(message.authoredAt),
          message.ciphertext,
          message.nonce,
          message.encryptionScheme,
          message.ciphertextSha1,
          message.rawEventJson,
          _millisOrNull(message.deletedAt),
        ],
      );
    });
  }

  Future<bool> hasMessage(String messageId) async {
    if (!await exists()) {
      return false;
    }
    await open();
    return _roomDatabase.read((db) {
      final rows = db.select(
        'SELECT 1 FROM messages WHERE message_id = ? LIMIT 1;',
        [messageId],
      );
      return rows.isNotEmpty;
    });
  }

  Future<int> nextMessageLamport() async {
    if (!await exists()) {
      return 1;
    }
    await open();
    return _roomDatabase.read((db) {
      final rows = db.select(
        'SELECT COALESCE(MAX(lamport), 0) AS max_lamport FROM messages;',
      );
      final current = rows.first['max_lamport'] as int? ?? 0;
      return current + 1;
    });
  }

  Future<List<DChatMessageRecord>> listMessageRecords({
    int limit = 200,
    bool includeDeleted = false,
    String? topicId,
  }) async {
    if (!await exists()) {
      return const [];
    }
    await open();
    return _roomDatabase.read((db) {
      final whereParts = <String>[];
      final args = <Object?>[];
      if (!includeDeleted) {
        whereParts.add('deleted_at IS NULL');
      }
      if (topicId != null && topicId.isNotEmpty) {
        whereParts.add('topic_id = ?');
        args.add(topicId);
      }
      final whereClause = whereParts.isEmpty
          ? ''
          : 'WHERE ${whereParts.join(' AND ')}';
      final rows = db.select(
        '''
        SELECT
          message_id,
          topic_id,
          epoch,
          lamport,
          author_npub,
          authored_at,
          ciphertext,
          nonce,
          enc,
          ciphertext_sha1,
          raw_event_json,
          deleted_at
        FROM messages
        $whereClause
        ORDER BY epoch DESC, lamport DESC, authored_at DESC, message_id DESC
        LIMIT ?;
        ''',
        [...args, limit.clamp(1, 5000)],
      );
      return rows.reversed.map(_messageFromRow).toList();
    });
  }

  Future<List<DChatMessageRecord>> listMessages({int limit = 200}) {
    return listMessageRecords(limit: limit, includeDeleted: false);
  }

  Future<void> markMessageDeleted(
    String messageId, {
    required DateTime deletedAt,
  }) async {
    await open();
    await _roomDatabase.write((db) {
      db.execute(
        '''
        UPDATE messages
        SET deleted_at = ?
        WHERE message_id = ?;
        ''',
        [_millis(deletedAt), messageId],
      );
    });
  }

  Future<DChatMediaRecord> storeMediaBytes({
    required Uint8List bytes,
    String? originalName,
    String? mimeType,
    DChatMediaKind? mediaKind,
    String? extension,
  }) async {
    await open();

    final digest = sha1.convert(bytes).toString();
    final existing = await getMediaBySha1(digest);
    if (existing != null) {
      if (!await _roomStorage.exists(existing.relativePath)) {
        await _roomStorage.writeBytes(existing.relativePath, bytes);
      }
      return existing;
    }

    final normalizedMimeType = mimeType ?? _detectMimeType(bytes, originalName);
    final normalizedExtension = _normalizedExtension(
      extension: extension,
      originalName: originalName,
      mimeType: normalizedMimeType,
      mediaKind: mediaKind,
    );
    final resolvedKind =
        mediaKind ??
        _inferMediaKind(
          mimeType: normalizedMimeType,
          extension: normalizedExtension,
        );
    final relativePath = p.join(
      'media',
      resolvedKind.folderName,
      '$digest.$normalizedExtension',
    );

    await _roomStorage.writeBytes(relativePath, bytes);

    final record = DChatMediaRecord(
      sha1: digest,
      kind: resolvedKind,
      extension: normalizedExtension,
      relativePath: relativePath,
      mimeType: normalizedMimeType,
      originalName: originalName,
      sizeBytes: bytes.length,
      createdAt: DateTime.now().toUtc(),
    );
    await _putMediaRecord(record);
    return record;
  }

  Future<DChatMediaRecord?> getMediaBySha1(String sha1Digest) async {
    if (!await exists()) {
      return null;
    }
    await open();
    return _roomDatabase.read((db) {
      final rows = db.select(
        '''
        SELECT
          sha1,
          media_kind,
          extension,
          relative_path,
          mime_type,
          original_name,
          size_bytes,
          created_at
        FROM media_refs
        WHERE sha1 = ?
        LIMIT 1;
        ''',
        [sha1Digest],
      );
      if (rows.isEmpty) {
        return null;
      }
      return _mediaFromRow(rows.first);
    });
  }

  Future<void> linkMediaToMessage(
    String messageId,
    String mediaSha1, {
    int sortOrder = 0,
  }) async {
    await open();
    await _roomDatabase.write((db) {
      db.execute(
        '''
        INSERT OR REPLACE INTO message_media (
          message_id,
          media_sha1,
          sort_order
        ) VALUES (?, ?, ?);
        ''',
        [messageId, mediaSha1, sortOrder],
      );
    });
  }

  Future<List<DChatMediaRecord>> listMediaForMessage(String messageId) async {
    if (!await exists()) {
      return const [];
    }
    await open();
    return _roomDatabase.read((db) {
      final rows = db.select(
        '''
        SELECT
          media.sha1,
          media.media_kind,
          media.extension,
          media.relative_path,
          media.mime_type,
          media.original_name,
          media.size_bytes,
          media.created_at
        FROM media_refs media
        INNER JOIN message_media link
          ON link.media_sha1 = media.sha1
        WHERE link.message_id = ?
        ORDER BY link.sort_order ASC, media.sha1 ASC;
        ''',
        [messageId],
      );
      return rows.map(_mediaFromRow).toList();
    });
  }

  Future<void> upsertSyncCursor(DChatSyncCursor cursor) async {
    await open();
    await _roomDatabase.write((db) {
      db.execute(
        '''
        INSERT INTO sync_cursors (
          peer_npub,
          last_control_lamport,
          last_message_lamport,
          last_synced_at
        ) VALUES (?, ?, ?, ?)
        ON CONFLICT(peer_npub) DO UPDATE SET
          last_control_lamport = excluded.last_control_lamport,
          last_message_lamport = excluded.last_message_lamport,
          last_synced_at = excluded.last_synced_at;
        ''',
        [
          cursor.peerNpub,
          cursor.lastControlLamport,
          cursor.lastMessageLamport,
          _millisOrNull(cursor.lastSyncedAt),
        ],
      );
    });
  }

  Future<DChatSyncCursor?> loadSyncCursor(String peerNpub) async {
    if (!await exists()) {
      return null;
    }
    await open();
    return _roomDatabase.read((db) {
      final rows = db.select(
        '''
        SELECT
          peer_npub,
          last_control_lamport,
          last_message_lamport,
          last_synced_at
        FROM sync_cursors
        WHERE peer_npub = ?
        LIMIT 1;
        ''',
        [peerNpub],
      );
      if (rows.isEmpty) {
        return null;
      }
      return _syncCursorFromRow(rows.first);
    });
  }

  Future<void> setDeviceValue(String key, String value) async {
    await open();
    await _deviceDatabase.write((db) {
      db.execute(
        '''
        INSERT INTO device_values (key_name, value_text, updated_at)
        VALUES (?, ?, ?)
        ON CONFLICT(key_name) DO UPDATE SET
          value_text = excluded.value_text,
          updated_at = excluded.updated_at;
        ''',
        [key, value, DateTime.now().toUtc().millisecondsSinceEpoch],
      );
    });
  }

  Future<void> storeLocalEpochKey(int epoch, Uint8List keyBytes) async {
    await setDeviceValue(_epochKeyName(epoch), base64Encode(keyBytes));
  }

  Future<Uint8List?> loadLocalEpochKey(int epoch) async {
    final encoded = await getDeviceValue(_epochKeyName(epoch));
    if (encoded == null || encoded.isEmpty) {
      return null;
    }
    try {
      return Uint8List.fromList(base64Decode(encoded));
    } catch (_) {
      return null;
    }
  }

  Future<String?> getDeviceValue(String key) async {
    await open();
    return _deviceDatabase.read((db) {
      final rows = db.select(
        '''
        SELECT value_text
        FROM device_values
        WHERE key_name = ?
        LIMIT 1;
        ''',
        [key],
      );
      if (rows.isEmpty) {
        return null;
      }
      return rows.first['value_text'] as String;
    });
  }

  Future<void> upsertLocalSyncState(DChatLocalSyncState state) async {
    await open();
    await _deviceDatabase.write((db) {
      db.execute(
        '''
        INSERT INTO local_sync_state (
          peer_npub,
          last_attempt_at,
          last_success_at,
          last_error
        ) VALUES (?, ?, ?, ?)
        ON CONFLICT(peer_npub) DO UPDATE SET
          last_attempt_at = excluded.last_attempt_at,
          last_success_at = excluded.last_success_at,
          last_error = excluded.last_error;
        ''',
        [
          state.peerNpub,
          _millisOrNull(state.lastAttemptAt),
          _millisOrNull(state.lastSuccessAt),
          state.lastError,
        ],
      );
    });
  }

  Future<DChatLocalSyncState?> loadLocalSyncState(String peerNpub) async {
    await open();
    return _deviceDatabase.read((db) {
      final rows = db.select(
        '''
        SELECT peer_npub, last_attempt_at, last_success_at, last_error
        FROM local_sync_state
        WHERE peer_npub = ?
        LIMIT 1;
        ''',
        [peerNpub],
      );
      if (rows.isEmpty) {
        return null;
      }
      final row = rows.first;
      return DChatLocalSyncState(
        peerNpub: row['peer_npub'] as String,
        lastAttemptAt: _fromMillisOrNull(row['last_attempt_at'] as int?),
        lastSuccessAt: _fromMillisOrNull(row['last_success_at'] as int?),
        lastError: row['last_error'] as String?,
      );
    });
  }

  Future<void> flush() async {
    await open();
    await _roomDatabase.flush();
    await _deviceDatabase.flush();
  }

  Future<void> close() async {
    await _roomDatabase.close();
    await _deviceDatabase.close();
    _opened = false;
  }

  Future<void> deleteRoom() async {
    await close();
    await _roomStorage.deleteDirectory('', recursive: true);
  }

  Future<void> _ensureRoomDirectories() async {
    await _roomStorage.createDirectory('');
    for (final folder in const [
      'media',
      'media/images',
      'media/video',
      'media/audio',
      'media/files',
      'media/thumbs',
    ]) {
      await _roomStorage.createDirectory(folder);
    }
  }

  void _initRoomSchema(dynamic db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS room_meta (
        room_id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        description TEXT,
        icon TEXT,
        owner_npub TEXT NOT NULL,
        room_npub TEXT,
        seed_peer_hints_json TEXT NOT NULL DEFAULT '[]',
        current_epoch INTEGER NOT NULL DEFAULT 0,
        snapshot_start INTEGER,
        state TEXT NOT NULL DEFAULT 'active',
        join_policy TEXT NOT NULL DEFAULT 'approval_required',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS members (
        member_npub TEXT PRIMARY KEY,
        role TEXT NOT NULL,
        status TEXT NOT NULL,
        joined_at INTEGER,
        removed_at INTEGER,
        added_by TEXT,
        updated_at INTEGER NOT NULL
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS control_events (
        event_id TEXT PRIMARY KEY,
        event_type TEXT NOT NULL,
        actor_npub TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        lamport INTEGER NOT NULL DEFAULT 0,
        target_npub TEXT,
        raw_json TEXT NOT NULL
      );
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS control_events_order_idx
      ON control_events(lamport DESC, created_at DESC, event_id DESC);
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS epochs (
        epoch INTEGER PRIMARY KEY,
        created_at INTEGER NOT NULL,
        rotated_by_npub TEXT NOT NULL,
        control_event_id TEXT,
        summary TEXT
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS epoch_key_boxes (
        epoch INTEGER NOT NULL,
        recipient_npub TEXT NOT NULL,
        envelope TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        PRIMARY KEY (epoch, recipient_npub)
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS topics (
        topic_id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        description TEXT,
        icon TEXT,
        created_by_npub TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS messages (
        message_id TEXT PRIMARY KEY,
        topic_id TEXT NOT NULL DEFAULT 'general',
        epoch INTEGER NOT NULL,
        lamport INTEGER NOT NULL,
        author_npub TEXT NOT NULL,
        authored_at INTEGER NOT NULL,
        ciphertext BLOB NOT NULL,
        nonce BLOB,
        enc TEXT,
        ciphertext_sha1 TEXT NOT NULL,
        raw_event_json TEXT NOT NULL,
        deleted_at INTEGER
      );
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS messages_order_idx
      ON messages(epoch DESC, lamport DESC, authored_at DESC, message_id DESC);
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS media_refs (
        sha1 TEXT PRIMARY KEY,
        media_kind TEXT NOT NULL,
        extension TEXT NOT NULL,
        relative_path TEXT NOT NULL,
        mime_type TEXT,
        original_name TEXT,
        size_bytes INTEGER NOT NULL,
        created_at INTEGER NOT NULL
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS message_media (
        message_id TEXT NOT NULL,
        media_sha1 TEXT NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (message_id, media_sha1),
        FOREIGN KEY (message_id) REFERENCES messages(message_id) ON DELETE CASCADE,
        FOREIGN KEY (media_sha1) REFERENCES media_refs(sha1) ON DELETE CASCADE
      );
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS message_media_order_idx
      ON message_media(message_id, sort_order ASC, media_sha1 ASC);
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS sync_cursors (
        peer_npub TEXT PRIMARY KEY,
        last_control_lamport INTEGER NOT NULL DEFAULT 0,
        last_message_lamport INTEGER NOT NULL DEFAULT 0,
        last_synced_at INTEGER
      );
    ''');
    if (!_hasColumn(db, 'room_meta', 'icon')) {
      db.execute('ALTER TABLE room_meta ADD COLUMN icon TEXT;');
    }
    if (!_hasColumn(db, 'messages', 'topic_id')) {
      db.execute(
        "ALTER TABLE messages ADD COLUMN topic_id TEXT NOT NULL DEFAULT 'general';",
      );
    }
    db.execute('PRAGMA user_version = 2;');
  }

  void _initDeviceSchema(dynamic db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS device_values (
        key_name TEXT PRIMARY KEY,
        value_text TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS pending_outbox (
        event_id TEXT PRIMARY KEY,
        queue_type TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        created_at INTEGER NOT NULL
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS local_sync_state (
        peer_npub TEXT PRIMARY KEY,
        last_attempt_at INTEGER,
        last_success_at INTEGER,
        last_error TEXT
      );
    ''');
    db.execute('PRAGMA user_version = 1;');
  }

  Future<void> _putMediaRecord(DChatMediaRecord record) async {
    await _roomDatabase.write((db) {
      db.execute(
        '''
        INSERT OR REPLACE INTO media_refs (
          sha1,
          media_kind,
          extension,
          relative_path,
          mime_type,
          original_name,
          size_bytes,
          created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        ''',
        [
          record.sha1,
          record.kind.name,
          record.extension,
          record.relativePath,
          record.mimeType,
          record.originalName,
          record.sizeBytes,
          _millis(record.createdAt),
        ],
      );
    });
  }

  DChatRoomMetadata _roomMetadataFromRow(Map<String, Object?> row) {
    return DChatRoomMetadata(
      roomId: row['room_id'] as String,
      title: row['title'] as String,
      description: row['description'] as String?,
      icon: row['icon'] as String?,
      ownerNpub: row['owner_npub'] as String,
      roomNpub: row['room_npub'] as String?,
      seedPeerHints: _decodeStringList(
        row['seed_peer_hints_json'] as String? ?? '[]',
      ),
      currentEpoch: row['current_epoch'] as int? ?? 0,
      snapshotStart: row['snapshot_start'] as int?,
      state: row['state'] as String? ?? 'active',
      joinPolicy: row['join_policy'] as String? ?? 'approval_required',
      createdAt: _fromMillis(row['created_at'] as int),
      updatedAt: _fromMillis(row['updated_at'] as int),
    );
  }

  DChatMemberRecord _memberFromRow(Map<String, Object?> row) {
    return DChatMemberRecord(
      memberNpub: row['member_npub'] as String,
      role: row['role'] as String,
      status: row['status'] as String? ?? 'active',
      joinedAt: _fromMillisOrNull(row['joined_at'] as int?),
      removedAt: _fromMillisOrNull(row['removed_at'] as int?),
      addedBy: row['added_by'] as String?,
      updatedAt: _fromMillis(row['updated_at'] as int),
    );
  }

  DChatEpochRecord _epochFromRow(Map<String, Object?> row) {
    return DChatEpochRecord(
      epoch: row['epoch'] as int,
      rotatedByNpub: row['rotated_by_npub'] as String,
      createdAt: _fromMillis(row['created_at'] as int),
      controlEventId: row['control_event_id'] as String?,
      summary: row['summary'] as String?,
    );
  }

  DChatTopicRecord _topicFromRow(Map<String, Object?> row) {
    return DChatTopicRecord(
      topicId: row['topic_id'] as String,
      title: row['title'] as String,
      description: row['description'] as String?,
      icon: row['icon'] as String?,
      createdByNpub: row['created_by_npub'] as String,
      createdAt: _fromMillis(row['created_at'] as int),
      updatedAt: _fromMillis(row['updated_at'] as int),
    );
  }

  DChatEpochKeyBox _epochKeyBoxFromRow(Map<String, Object?> row) {
    return DChatEpochKeyBox(
      epoch: row['epoch'] as int,
      recipientNpub: row['recipient_npub'] as String,
      envelope: row['envelope'] as String,
      createdAt: _fromMillis(row['created_at'] as int),
    );
  }

  DChatMessageRecord _messageFromRow(Map<String, Object?> row) {
    return DChatMessageRecord(
      messageId: row['message_id'] as String,
      topicId: row['topic_id'] as String? ?? 'general',
      epoch: row['epoch'] as int,
      lamport: row['lamport'] as int,
      authorNpub: row['author_npub'] as String,
      authoredAt: _fromMillis(row['authored_at'] as int),
      ciphertext: row['ciphertext'] as Uint8List,
      nonce: row['nonce'] as Uint8List?,
      encryptionScheme: row['enc'] as String?,
      ciphertextSha1: row['ciphertext_sha1'] as String,
      rawEventJson: row['raw_event_json'] as String,
      deletedAt: _fromMillisOrNull(row['deleted_at'] as int?),
    );
  }

  DChatMediaRecord _mediaFromRow(Map<String, Object?> row) {
    return DChatMediaRecord(
      sha1: row['sha1'] as String,
      kind: DChatMediaKind.fromStorageValue(row['media_kind'] as String),
      extension: row['extension'] as String,
      relativePath: row['relative_path'] as String,
      mimeType: row['mime_type'] as String?,
      originalName: row['original_name'] as String?,
      sizeBytes: row['size_bytes'] as int,
      createdAt: _fromMillis(row['created_at'] as int),
    );
  }

  DChatSyncCursor _syncCursorFromRow(Map<String, Object?> row) {
    return DChatSyncCursor(
      peerNpub: row['peer_npub'] as String,
      lastControlLamport: row['last_control_lamport'] as int? ?? 0,
      lastMessageLamport: row['last_message_lamport'] as int? ?? 0,
      lastSyncedAt: _fromMillisOrNull(row['last_synced_at'] as int?),
    );
  }

  String? _detectMimeType(Uint8List bytes, String? originalName) {
    if (originalName != null && originalName.isNotEmpty) {
      return lookupMimeType(originalName, headerBytes: bytes.take(16).toList());
    }
    return lookupMimeType('file', headerBytes: bytes.take(16).toList());
  }

  DChatMediaKind _inferMediaKind({
    required String? mimeType,
    required String extension,
  }) {
    if (mimeType != null) {
      if (mimeType.startsWith('image/')) return DChatMediaKind.image;
      if (mimeType.startsWith('video/')) return DChatMediaKind.video;
      if (mimeType.startsWith('audio/')) return DChatMediaKind.audio;
    }

    if (const {
      'jpg',
      'jpeg',
      'png',
      'gif',
      'webp',
      'bmp',
      'heic',
      'svg',
    }.contains(extension)) {
      return DChatMediaKind.image;
    }
    if (const {'mp4', 'mov', 'webm', 'mkv', 'avi', 'm4v'}.contains(extension)) {
      return DChatMediaKind.video;
    }
    if (const {
      'mp3',
      'wav',
      'm4a',
      'ogg',
      'opus',
      'aac',
      'flac',
    }.contains(extension)) {
      return DChatMediaKind.audio;
    }
    return DChatMediaKind.file;
  }

  String _normalizedExtension({
    String? extension,
    String? originalName,
    String? mimeType,
    DChatMediaKind? mediaKind,
  }) {
    final candidates = <String?>[
      extension,
      originalName != null ? p.extension(originalName) : null,
      _defaultExtensionForMime(mimeType),
      _defaultExtensionForKind(mediaKind),
    ];

    for (final candidate in candidates) {
      final normalized = _sanitizeExtension(candidate);
      if (normalized != null) {
        return normalized;
      }
    }
    return 'bin';
  }

  String? _defaultExtensionForMime(String? mimeType) {
    switch (mimeType) {
      case 'image/jpeg':
        return 'jpg';
      case 'image/png':
        return 'png';
      case 'image/webp':
        return 'webp';
      case 'video/mp4':
        return 'mp4';
      case 'audio/mpeg':
        return 'mp3';
      case 'audio/mp4':
        return 'm4a';
      case 'application/pdf':
        return 'pdf';
      default:
        return null;
    }
  }

  String? _defaultExtensionForKind(DChatMediaKind? kind) {
    switch (kind) {
      case DChatMediaKind.image:
      case DChatMediaKind.thumb:
        return 'jpg';
      case DChatMediaKind.video:
        return 'mp4';
      case DChatMediaKind.audio:
        return 'm4a';
      case DChatMediaKind.file:
        return 'bin';
      case null:
        return null;
    }
  }

  String? _sanitizeExtension(String? extension) {
    if (extension == null || extension.trim().isEmpty) {
      return null;
    }
    final stripped = extension.trim().toLowerCase().replaceFirst(
      RegExp(r'^\.+'),
      '',
    );
    final normalized = stripped.replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (normalized.isEmpty) {
      return null;
    }
    return normalized;
  }

  int _millis(DateTime value) => value.toUtc().millisecondsSinceEpoch;

  int? _millisOrNull(DateTime? value) => value == null ? null : _millis(value);

  DateTime _fromMillis(int value) {
    return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true).toLocal();
  }

  DateTime? _fromMillisOrNull(int? value) {
    if (value == null) {
      return null;
    }
    return _fromMillis(value);
  }

  List<String> _decodeStringList(String rawJson) {
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is List) {
        return decoded.map((value) => value.toString()).toList();
      }
    } catch (_) {
      // Best-effort fallback.
    }
    return const [];
  }

  String _epochKeyName(int epoch) => 'epoch_key.$epoch';

  bool _hasColumn(dynamic db, String tableName, String columnName) {
    final rows = db.select('PRAGMA table_info($tableName);');
    for (final row in rows) {
      if (row['name'] == columnName) {
        return true;
      }
    }
    return false;
  }
}
