import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:geogram/platform/file_system_service.dart';
import 'package:geogram/services/chat_service.dart';
import 'package:geogram/services/distributed_chat_service.dart';
import 'package:geogram/services/profile_storage.dart';
import 'package:geogram/util/nostr_key_generator.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await FileSystemService.instance.init();
  });

  group('DistributedChatService', () {
    late _TestInstance admin;
    late _TestInstance moderator;
    late _TestInstance member;

    setUp(() async {
      ChatService().reset();
      admin = await _TestInstance.create('admin');
      moderator = await _TestInstance.create('moderator');
      member = await _TestInstance.create('member');
    });

    tearDown(() async {
      ChatService().reset();
      await admin.dispose();
      await moderator.dispose();
      await member.dispose();
    });

    test(
      'supports approval, moderator room-key sharing, and kick boundaries',
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

        final invite = await admin.service.createInvite(roomId);
        final preApprovalMessage = await admin.service.sendMessage(
          roomId,
          'Before approval',
        );
        final dailyPath =
            '$roomId/${preApprovalMessage.dateTime.year}/${preApprovalMessage.datePortion}_chat.txt';
        expect(await admin.storage.exists(dailyPath), isTrue);
        expect(await admin.storage.exists('$roomId/messages.txt'), isFalse);

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
        expect(
          moderatorBootstrapMessages.map((message) => message.content),
          contains('Before approval'),
        );

        await admin.service.promoteToModerator(roomId, moderator.keys.npub);
        await moderator.service.syncRoomFromPeer(admin.service, roomId);

        final promotedModeratorRoom = await moderator.service.getRoom(roomId);
        expect(
          promotedModeratorRoom!.config!.isModerator(moderator.keys.npub),
          isTrue,
        );
        expect(await moderator.service.hasRoomSecret(roomId), isTrue);

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
        expect(
          memberBootstrapMessages.map((message) => message.content),
          contains('Before approval'),
        );

        await moderator.service.sendMessage(roomId, 'Moderator online');
        await admin.service.syncRoomFromPeer(moderator.service, roomId);
        await member.service.syncRoomFromPeer(admin.service, roomId);

        final memberMessagesBeforeKick = await member.service.loadMessages(
          roomId,
          limit: 100,
        );
        expect(
          memberMessagesBeforeKick.map((message) => message.content),
          contains('Moderator online'),
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
        expect(memberContents, contains('Before approval'));
        expect(memberContents, contains('Moderator online'));
        expect(memberContents, isNot(contains('After kick')));

        final controlLog = await admin.storage.readString(
          '$roomId/extra/dchat/control.jsonl',
        );
        expect(controlLog, isNotNull);
        expect(controlLog, contains('room_key_shared'));
        expect(controlLog, contains('member_removed'));
      },
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
    final appPath = p.join(rootDir.path, 'chat');
    await Directory(appPath).create(recursive: true);
    return _TestInstance._(
      rootDir: rootDir,
      appPath: appPath,
      storage: FilesystemProfileStorage(appPath),
      keys: NostrKeyGenerator.generateKeyPair(),
      roomSecrets: <String, String>{},
    );
  }

  Future<void> dispose() async {
    if (await rootDir.exists()) {
      await rootDir.delete(recursive: true);
    }
  }
}
