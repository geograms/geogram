import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypted_archive/encrypted_archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geogram/models/dchat_storage.dart';
import 'package:geogram/models/distributed_chat.dart';
import 'package:geogram/platform/file_system_service.dart';
import 'package:geogram/services/dchat_room_store.dart';
import 'package:geogram/services/encrypted_storage_service.dart';
import 'package:geogram/services/profile_sqlite_database.dart';
import 'package:geogram/services/profile_storage.dart';
import 'package:geogram/services/storage_config.dart';
import 'package:geogram/util/nostr_key_generator.dart';
import 'package:sqlite3/open.dart' as sqlite_open;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _configureSqliteForTests();

  setUpAll(() async {
    await FileSystemService.instance.init();
  });

  group('ProfileSQLiteDatabase', () {
    test('persists database content through FilesystemProfileStorage', () async {
      final rootDir = await Directory.systemTemp.createTemp(
        'profile-sqlite-fs-',
      );
      try {
        final storage = FilesystemProfileStorage(rootDir.path);
        final sqlite = ProfileSQLiteDatabase(
          storage: storage,
          relativePath: 'dchat/mesh-camp/room.sqlite3',
        );

        await sqlite.write((db) {
          db.execute(
            'CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT NOT NULL);',
          );
          db.execute('INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?);', [
            'hello',
            'world',
          ]);
        });
        await sqlite.close();

        expect(await storage.exists('dchat/mesh-camp/room.sqlite3'), isTrue);

        final reopened = ProfileSQLiteDatabase(
          storage: storage,
          relativePath: 'dchat/mesh-camp/room.sqlite3',
        );
        final value = await reopened.read((db) {
          final rows = db.select(
            'SELECT value FROM kv WHERE key = ? LIMIT 1;',
            ['hello'],
          );
          return rows.single['value'] as String;
        });
        expect(value, 'world');
        await reopened.close();
      } finally {
        if (await rootDir.exists()) {
          await rootDir.delete(recursive: true);
        }
      }
    });

    test('persists database content through EncryptedProfileStorage', () async {
      final rootDir = await Directory.systemTemp.createTemp(
        'profile-sqlite-enc-',
      );
      try {
        await StorageConfig().init(customBaseDir: rootDir.path);
        final keys = NostrKeyGenerator.generateKeyPair();
        final callsign = keys.callsign;
        final archivePath = StorageConfig().getEncryptedArchivePath(callsign);
        final archive = await EncryptedArchive.create(
          archivePath,
          _archivePassword(keys.nsec),
        );
        await archive.close();

        final storage = EncryptedProfileStorage(
          callsign: callsign,
          nsec: keys.nsec,
          basePath: StorageConfig().getCallsignDir(callsign),
        );
        final sqlite = ProfileSQLiteDatabase(
          storage: storage,
          relativePath: 'dchat/mesh-camp/room.sqlite3',
        );

        await sqlite.write((db) {
          db.execute(
            'CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT NOT NULL);',
          );
          db.execute('INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?);', [
            'cipher',
            'archive',
          ]);
        });
        await sqlite.close();

        expect(await storage.exists('dchat/mesh-camp/room.sqlite3'), isTrue);

        final reopened = ProfileSQLiteDatabase(
          storage: storage,
          relativePath: 'dchat/mesh-camp/room.sqlite3',
        );
        final value = await reopened.read((db) {
          final rows = db.select(
            'SELECT value FROM kv WHERE key = ? LIMIT 1;',
            ['cipher'],
          );
          return rows.single['value'] as String;
        });
        expect(value, 'archive');
        await reopened.close();
        await EncryptedStorageService().closeArchive(callsign);
      } finally {
        if (await rootDir.exists()) {
          await rootDir.delete(recursive: true);
        }
      }
    });
  });

  group('DChatRoomStore', () {
    test('creates room-local SQLite state and media layout', () async {
      final rootDir = await Directory.systemTemp.createTemp('dchat-store-');
      try {
        final storage = FilesystemProfileStorage(rootDir.path);
        final roomOwner = NostrKeyGenerator.generateKeyPair();
        final peer = NostrKeyGenerator.generateKeyPair();
        final store = DChatRoomStore(
          profileStorage: storage,
          roomId: 'mesh-camp',
        );

        final createdAt = DateTime.utc(2026, 3, 27, 10, 0, 0);
        await store.initializeRoom(
          DChatRoomMetadata(
            roomId: 'mesh-camp',
            title: 'Mesh Camp',
            description: 'Distributed room',
            ownerNpub: roomOwner.npub,
            roomNpub: peer.npub,
            currentEpoch: 3,
            snapshotStart: createdAt.millisecondsSinceEpoch,
            createdAt: createdAt,
            updatedAt: createdAt,
          ),
        );

        expect(await storage.exists('dchat/mesh-camp/room.sqlite3'), isTrue);
        expect(await storage.exists('dchat/mesh-camp/device.sqlite3'), isTrue);
        expect(
          await storage.directoryExists('dchat/mesh-camp/media/images'),
          isTrue,
        );
        expect(
          await storage.directoryExists('dchat/mesh-camp/media/files'),
          isTrue,
        );

        await store.upsertMember(
          DChatMemberRecord(
            memberNpub: roomOwner.npub,
            role: 'admin',
            joinedAt: createdAt,
            addedBy: roomOwner.npub,
            updatedAt: createdAt,
          ),
        );
        await store.upsertMember(
          DChatMemberRecord(
            memberNpub: peer.npub,
            role: 'member',
            status: 'active',
            joinedAt: createdAt,
            addedBy: roomOwner.npub,
            updatedAt: createdAt,
          ),
        );

        final control = DistributedChatControlEvent.create(
          type: DistributedChatControlType.roomCreated,
          roomId: 'mesh-camp',
          actorNsec: roomOwner.nsec,
          actorCallsign: roomOwner.callsign,
          payload: {'title': 'Mesh Camp'},
          createdAt: createdAt.millisecondsSinceEpoch ~/ 1000,
        );
        await store.appendControlEvent(control, lamport: 1);
        await store.recordEpoch(
          DChatEpochRecord(
            epoch: 3,
            rotatedByNpub: roomOwner.npub,
            createdAt: createdAt,
            controlEventId: control.event.id,
            summary: 'Current epoch',
          ),
        );
        await store.putEpochKeyBox(
          DChatEpochKeyBox(
            epoch: 3,
            recipientNpub: peer.npub,
            envelope: 'sealed-box',
            createdAt: createdAt,
          ),
        );

        final mediaBytes = Uint8List.fromList(utf8.encode('hello image'));
        final media = await store.storeMediaBytes(
          bytes: mediaBytes,
          originalName: 'photo.png',
        );
        final duplicateMedia = await store.storeMediaBytes(
          bytes: mediaBytes,
          originalName: 'renamed.png',
        );
        expect(duplicateMedia.sha1, media.sha1);
        expect(duplicateMedia.relativePath, media.relativePath);
        expect(
          await storage.exists('dchat/mesh-camp/${media.relativePath}'),
          isTrue,
        );

        final secondRoom = DChatRoomStore(
          profileStorage: storage,
          roomId: 'field-team',
        );
        await secondRoom.initializeRoom(
          DChatRoomMetadata(
            roomId: 'field-team',
            title: 'Field Team',
            ownerNpub: roomOwner.npub,
            createdAt: createdAt,
            updatedAt: createdAt,
          ),
        );
        final secondRoomMedia = await secondRoom.storeMediaBytes(
          bytes: mediaBytes,
          originalName: 'photo.png',
        );
        expect(secondRoomMedia.sha1, media.sha1);
        expect(secondRoomMedia.relativePath, media.relativePath);
        expect(
          await storage.exists(
            'dchat/field-team/${secondRoomMedia.relativePath}',
          ),
          isTrue,
        );
        await secondRoom.close();

        final ciphertext = Uint8List.fromList(
          utf8.encode('ciphertext payload'),
        );
        final message = DChatMessageRecord(
          messageId: 'msg-1',
          epoch: 3,
          lamport: 7,
          authorNpub: roomOwner.npub,
          authoredAt: createdAt.add(const Duration(minutes: 5)),
          ciphertext: ciphertext,
          nonce: Uint8List.fromList(const [1, 2, 3, 4]),
          encryptionScheme: 'aes-gcm',
          ciphertextSha1: sha1.convert(ciphertext).toString(),
          rawEventJson: jsonEncode({'id': 'msg-1', 'kind': 'group_message'}),
        );
        await store.appendMessage(message);
        await store.linkMediaToMessage(message.messageId, media.sha1);
        await store.upsertSyncCursor(
          DChatSyncCursor(
            peerNpub: peer.npub,
            lastControlLamport: 1,
            lastMessageLamport: 7,
            lastSyncedAt: createdAt.add(const Duration(minutes: 6)),
          ),
        );
        await store.setDeviceValue('room_nsec', roomOwner.nsec);
        await store.upsertLocalSyncState(
          DChatLocalSyncState(
            peerNpub: peer.npub,
            lastAttemptAt: createdAt.add(const Duration(minutes: 7)),
            lastSuccessAt: createdAt.add(const Duration(minutes: 8)),
          ),
        );
        await store.close();

        final reopened = DChatRoomStore(
          profileStorage: storage,
          roomId: 'mesh-camp',
        );
        final metadata = await reopened.loadMetadata();
        expect(metadata, isNotNull);
        expect(metadata!.title, 'Mesh Camp');
        expect(metadata.currentEpoch, 3);

        final members = await reopened.listMembers();
        expect(members.map((member) => member.memberNpub), contains(peer.npub));

        final controlEvents = await reopened.listControlEvents();
        expect(
          controlEvents.single.type,
          DistributedChatControlType.roomCreated,
        );

        final epochs = await reopened.listEpochs();
        expect(epochs.single.epoch, 3);

        final keyBoxes = await reopened.listEpochKeyBoxes(3);
        expect(keyBoxes.single.recipientNpub, peer.npub);

        final messages = await reopened.listMessages();
        expect(messages.single.messageId, 'msg-1');
        expect(
          messages.single.ciphertextSha1,
          sha1.convert(ciphertext).toString(),
        );

        final attachments = await reopened.listMediaForMessage('msg-1');
        expect(attachments.single.sha1, media.sha1);
        expect(await reopened.getDeviceValue('room_nsec'), roomOwner.nsec);

        final cursor = await reopened.loadSyncCursor(peer.npub);
        expect(cursor, isNotNull);
        expect(cursor!.lastMessageLamport, 7);

        final localSyncState = await reopened.loadLocalSyncState(peer.npub);
        expect(localSyncState, isNotNull);
        expect(localSyncState!.lastSuccessAt, isNotNull);

        final roomEntries = await storage.listDirectory(
          'dchat/mesh-camp',
          recursive: true,
        );
        final imageFiles = roomEntries
            .where((entry) => entry.path.endsWith('.png'))
            .toList();
        expect(imageFiles.length, 1);

        await reopened.deleteRoom();
        expect(await storage.directoryExists('dchat/mesh-camp'), isFalse);
      } finally {
        if (await rootDir.exists()) {
          await rootDir.delete(recursive: true);
        }
      }
    });
  });
}

String _archivePassword(String nsec) {
  final key = utf8.encode(nsec);
  final info = utf8.encode('geogram-encrypted-storage-v1');
  final hmac = Hmac(sha256, key);
  return hmac.convert(info).toString();
}

void _configureSqliteForTests() {
  final cwd = Directory.current.path;

  if (Platform.isLinux) {
    final libPath = '$cwd/third_party/sqlite/linux-x64/libsqlite3.so.0';
    if (File(libPath).existsSync()) {
      sqlite_open.open.overrideFor(
        sqlite_open.OperatingSystem.linux,
        () => DynamicLibrary.open(libPath),
      );
    }
    return;
  }

  if (Platform.isMacOS) {
    final libPath = '$cwd/third_party/sqlite/macos-x64/libsqlite3.dylib';
    if (File(libPath).existsSync()) {
      sqlite_open.open.overrideFor(
        sqlite_open.OperatingSystem.macOS,
        () => DynamicLibrary.open(libPath),
      );
    }
    return;
  }

  if (Platform.isWindows) {
    final libPath = '$cwd/third_party/sqlite/windows-x64/sqlite3.dll';
    if (File(libPath).existsSync()) {
      sqlite_open.open.overrideFor(
        sqlite_open.OperatingSystem.windows,
        () => DynamicLibrary.open(libPath),
      );
    }
  }
}
