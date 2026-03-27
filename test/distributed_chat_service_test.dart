import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:geogram/models/distributed_chat.dart';
import 'package:geogram/platform/file_system_service.dart';
import 'package:geogram/services/chat_service.dart'
    show PermissionDeniedException;
import 'package:geogram/services/dchat_room_store.dart';
import 'package:geogram/services/distributed_chat_service.dart';
import 'package:geogram/services/profile_storage.dart';
import 'package:geogram/util/nostr_key_generator.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/open.dart' as sqlite_open;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _configureSqliteForTests();

  setUpAll(() async {
    await FileSystemService.instance.init();
  });

  group('DistributedChatService', () {
    late _TestInstance admin;
    late _TestInstance moderator;
    late _TestInstance member;

    setUp(() async {
      admin = await _TestInstance.create('admin');
      moderator = await _TestInstance.create('moderator');
      member = await _TestInstance.create('member');
    });

    tearDown(() async {
      await admin.dispose();
      await moderator.dispose();
      await member.dispose();
    });

    test(
      'rotates epochs for joins and kicks while keeping old readable history',
      () async {
        const roomId = 'mesh-camp';

        final created = await admin.service.createDistributedRoom(
          roomId: roomId,
          name: 'Mesh Camp',
          description: 'Distributed field room',
          seedPeerHints: ['bt-dht://seed-admin'],
        );
        expect(created.config?.isDistributed, isTrue);
        expect(created.config?.dailyFiles, isTrue);
        expect(await admin.service.hasRoomSecret(roomId), isTrue);
        expect(
          await admin.storage.exists('dchat/$roomId/room.sqlite3'),
          isTrue,
        );
        expect(
          await admin.storage.exists('dchat/$roomId/device.sqlite3'),
          isTrue,
        );
        final adminStore = DChatRoomStore(
          profileStorage: admin.storage,
          roomId: roomId,
        );
        final initialEpochs = await adminStore.listEpochs();
        expect(initialEpochs.map((epoch) => epoch.epoch).toList(), [1]);
        expect(await adminStore.loadLocalEpochKey(1), isNotNull);
        await adminStore.close();

        final invite = await admin.service.createInvite(roomId);
        final preApprovalMessage = await admin.service.sendMessage(
          roomId,
          'Before approval',
        );
        expect(preApprovalMessage.content, 'Before approval');
        expect(
          await admin.storage.exists('dchat/$roomId/room.sqlite3'),
          isTrue,
        );
        expect(await admin.storage.exists('$roomId/messages.txt'), isFalse);
        expect(
          await admin.storage.exists('$roomId/extra/dchat/control.jsonl'),
          isFalse,
        );

        await moderator.service.acceptInviteAndRequestJoin(
          invite,
          message: 'Moderator candidate',
        );
        await admin.service.syncRoomFromPeer(moderator.service, roomId);

        final roomWithApplicant = await admin.service.getRoom(roomId);
        expect(
          roomWithApplicant!.config!.pendingApplicants.any(
            (applicant) => applicant.npub == moderator.keys.npub,
          ),
          isTrue,
        );

        await moderator.service.syncRoomFromPeer(admin.service, roomId);
        expect(
          await moderator.service.loadMessages(roomId, limit: 100),
          isEmpty,
        );

        await admin.service.approveApplicant(roomId, moderator.keys.npub);
        await moderator.service.syncRoomFromPeer(admin.service, roomId);

        final approvedModeratorRoom = await moderator.service.getRoom(roomId);
        expect(
          approvedModeratorRoom!.config!.isMember(moderator.keys.npub),
          isTrue,
        );
        expect(await moderator.service.hasRoomSecret(roomId), isFalse);

        final moderatorBootstrapMessages = await moderator.service.loadMessages(
          roomId,
          limit: 100,
        );
        expect(moderatorBootstrapMessages, isEmpty);

        await admin.service.promoteToModerator(roomId, moderator.keys.npub);
        await moderator.service.syncRoomFromPeer(admin.service, roomId);

        final promotedModeratorRoom = await moderator.service.getRoom(roomId);
        expect(
          promotedModeratorRoom!.config!.isModerator(moderator.keys.npub),
          isTrue,
        );
        expect(await moderator.service.hasRoomSecret(roomId), isTrue);

        await moderator.service.sendMessage(roomId, 'Moderator online');
        await admin.service.syncRoomFromPeer(moderator.service, roomId);

        await member.service.acceptInviteAndRequestJoin(
          invite,
          message: 'Please let me join',
        );
        await admin.service.syncRoomFromPeer(member.service, roomId);
        await moderator.service.syncRoomFromPeer(admin.service, roomId);
        await moderator.service.approveApplicant(roomId, member.keys.npub);
        await member.service.syncRoomFromPeer(moderator.service, roomId);

        final approvedMemberRoom = await member.service.getRoom(roomId);
        expect(approvedMemberRoom!.config!.isMember(member.keys.npub), isTrue);
        final memberBootstrapMessages = await member.service.loadMessages(
          roomId,
          limit: 100,
        );
        expect(memberBootstrapMessages, isEmpty);

        await moderator.service.sendMessage(roomId, 'Welcome member');
        await admin.service.syncRoomFromPeer(moderator.service, roomId);
        await member.service.syncRoomFromPeer(admin.service, roomId);

        final memberMessagesBeforeKick = await member.service.loadMessages(
          roomId,
          limit: 100,
        );
        final memberMessagesBeforeKickContents = memberMessagesBeforeKick
            .map((message) => message.content)
            .toList();
        expect(memberMessagesBeforeKickContents, contains('Welcome member'));
        expect(
          memberMessagesBeforeKickContents,
          isNot(contains('Before approval')),
        );
        expect(
          memberMessagesBeforeKickContents,
          isNot(contains('Moderator online')),
        );

        await moderator.service.removeMember(roomId, member.keys.npub);
        await admin.service.syncRoomFromPeer(moderator.service, roomId);
        await admin.service.sendMessage(roomId, 'After kick');
        await member.service.syncRoomFromPeer(admin.service, roomId);

        final kickedMemberRoom = await member.service.getRoom(roomId);
        expect(kickedMemberRoom!.config!.canAccess(member.keys.npub), isFalse);
        await expectLater(
          member.service.sendMessage(roomId, 'Should fail'),
          throwsA(isA<PermissionDeniedException>()),
        );

        final memberMessagesAfterKick = await member.service.loadMessages(
          roomId,
          limit: 100,
        );
        final memberContents = memberMessagesAfterKick
            .map((message) => message.content)
            .toList();
        expect(memberContents, contains('Welcome member'));
        expect(memberContents, isNot(contains('Before approval')));
        expect(memberContents, isNot(contains('Moderator online')));
        expect(memberContents, isNot(contains('After kick')));

        final controlEvents = await admin.service.loadControlEvents(roomId);
        final controlTypes = controlEvents.map((event) => event.type).toList();
        expect(controlTypes, contains(DistributedChatControlType.epochRotated));
        expect(
          controlTypes,
          contains(DistributedChatControlType.roomKeyShared),
        );
        expect(
          controlTypes,
          contains(DistributedChatControlType.memberRemoved),
        );

        expect(
          await admin.storage.exists('dchat/$roomId/room.sqlite3'),
          isTrue,
        );
        expect(
          await member.storage.exists('dchat/$roomId/room.sqlite3'),
          isTrue,
        );

        final finalAdminStore = DChatRoomStore(
          profileStorage: admin.storage,
          roomId: roomId,
        );
        final finalMemberStore = DChatRoomStore(
          profileStorage: member.storage,
          roomId: roomId,
        );
        expect(
          (await finalAdminStore.listEpochs()).map((epoch) => epoch.epoch),
          [1, 2, 3, 4],
        );
        expect(await finalMemberStore.loadLocalEpochKey(3), isNotNull);
        expect(await finalMemberStore.loadLocalEpochKey(4), isNull);
        await finalAdminStore.close();
        await finalMemberStore.close();
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });
}

class _TestInstance {
  final Directory rootDir;
  final String appPath;
  final FilesystemProfileStorage storage;
  final NostrKeys keys;
  final Map<String, String> roomSecrets;
  late final DistributedChatService service;

  _TestInstance._({
    required this.rootDir,
    required this.appPath,
    required this.storage,
    required this.keys,
    required this.roomSecrets,
  }) {
    service = DistributedChatService(
      appPath: appPath,
      storage: storage,
      profileCallsign: keys.callsign,
      profileNpub: keys.npub,
      profileNsec: keys.nsec,
      loadRoomSecret: (roomId) async => roomSecrets[roomId],
      saveRoomSecret: (roomId, roomNsec) async {
        roomSecrets[roomId] = roomNsec;
      },
      deleteRoomSecret: (roomId) async {
        roomSecrets.remove(roomId);
      },
    );
  }

  static Future<_TestInstance> create(String label) async {
    final rootDir = await Directory.systemTemp.createTemp('dchat-$label-');
    final keys = NostrKeyGenerator.generateKeyPair();
    final profilePath = p.join(rootDir.path, keys.callsign);
    await Directory(profilePath).create(recursive: true);
    final appPath = p.join(profilePath, 'chat');
    await Directory(appPath).create(recursive: true);
    return _TestInstance._(
      rootDir: rootDir,
      appPath: appPath,
      storage: FilesystemProfileStorage(profilePath),
      keys: keys,
      roomSecrets: <String, String>{},
    );
  }

  Future<void> dispose() async {
    if (await rootDir.exists()) {
      await rootDir.delete(recursive: true);
    }
  }
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
