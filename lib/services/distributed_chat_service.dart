import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../models/chat_channel.dart';
import '../models/chat_message.dart';
import '../models/dchat_storage.dart';
import '../models/distributed_chat.dart';
import '../util/backup_encryption.dart';
import '../util/chat_format.dart';
import '../util/nostr_crypto.dart';
import '../util/nostr_event.dart';
import '../util/nostr_key_generator.dart';
import 'chat_service.dart' show PermissionDeniedException;
import 'config_service.dart';
import 'dchat_room_store.dart';
import 'profile_storage.dart';

typedef LoadDistributedChatRoomSecret = Future<String?> Function(String roomId);
typedef SaveDistributedChatRoomSecret =
    Future<void> Function(String roomId, String roomNsec);
typedef DeleteDistributedChatRoomSecret = Future<void> Function(String roomId);

const _epochEncryptionScheme = 'epoch-chacha20poly1305-v1';

/// Orchestrates distributed restricted chat rooms on top of the dchat SQLite
/// room store.
///
/// The public API stays aligned with the previous prototype, but room state,
/// control events, and messages are now persisted under `/{callsign}/dchat/`
/// via [DChatRoomStore] instead of legacy chat text files.
class DistributedChatService {
  final String appPath;
  final ProfileStorage storage;
  final String profileCallsign;
  final String profileNpub;
  final String? profileNsec;
  final LoadDistributedChatRoomSecret _loadRoomSecret;
  final SaveDistributedChatRoomSecret _saveRoomSecret;
  final DeleteDistributedChatRoomSecret _deleteRoomSecret;

  DistributedChatService({
    required this.appPath,
    required this.storage,
    required this.profileCallsign,
    required this.profileNpub,
    this.profileNsec,
    LoadDistributedChatRoomSecret? loadRoomSecret,
    SaveDistributedChatRoomSecret? saveRoomSecret,
    DeleteDistributedChatRoomSecret? deleteRoomSecret,
  }) : _loadRoomSecret = loadRoomSecret ?? _defaultLoadRoomSecret(appPath),
       _saveRoomSecret = saveRoomSecret ?? _defaultSaveRoomSecret(appPath),
       _deleteRoomSecret =
           deleteRoomSecret ?? _defaultDeleteRoomSecret(appPath);

  static LoadDistributedChatRoomSecret _defaultLoadRoomSecret(String appPath) {
    return (roomId) async {
      final namespace = _configNamespace(appPath);
      final value = ConfigService().getNestedValue(
        'dchat.$namespace.room_secrets.$roomId',
      );
      return value is String && value.isNotEmpty ? value : null;
    };
  }

  static SaveDistributedChatRoomSecret _defaultSaveRoomSecret(String appPath) {
    return (roomId, roomNsec) async {
      final namespace = _configNamespace(appPath);
      final config = ConfigService();
      config.setNestedValue('dchat.$namespace.room_secrets.$roomId', roomNsec);
      await config.saveNow();
    };
  }

  static DeleteDistributedChatRoomSecret _defaultDeleteRoomSecret(
    String appPath,
  ) {
    return (roomId) async {
      final namespace = _configNamespace(appPath);
      final config = ConfigService();
      final rawSecrets = config.getNestedValue(
        'dchat.$namespace.room_secrets',
        <String, dynamic>{},
      );
      final secrets = Map<String, dynamic>.from(
        rawSecrets is Map ? rawSecrets : const <String, dynamic>{},
      );
      secrets.remove(roomId);
      config.setNestedValue('dchat.$namespace.room_secrets', secrets);
      await config.saveNow();
    };
  }

  static String _configNamespace(String appPath) {
    return sha256.convert(utf8.encode(appPath)).toString().substring(0, 16);
  }

  Future<ChatChannel> _requireRoom(String roomId) async {
    final room = await getRoom(roomId);
    if (room == null) {
      throw Exception('Room not found: $roomId');
    }
    return room;
  }

  Future<ChatChannelConfig> _requireDistributedConfig(String roomId) async {
    final room = await _requireRoom(roomId);
    final config = room.config;
    if (config == null || !config.isDistributed || config.roomNpub == null) {
      throw Exception('Room is not a distributed room: $roomId');
    }
    return config;
  }

  Future<ChatChannel?> getRoom(String roomId) async {
    final snapshot = await _loadSnapshot(roomId);
    if (snapshot == null) {
      return null;
    }
    return _snapshotToChannel(snapshot);
  }

  Future<List<ChatMessage>> loadMessages(
    String roomId, {
    int limit = 1000,
  }) async {
    final records = await _loadMessageRecords(
      roomId,
      limit: limit,
      includeDeleted: false,
    );
    return _decodeReadableMessages(roomId, records);
  }

  Future<List<DistributedChatControlEvent>> loadControlEvents(
    String roomId,
  ) async {
    return _withStore(roomId, (store) async {
      if (!await store.exists()) {
        return const <DistributedChatControlEvent>[];
      }
      return store.listControlEvents(limit: 100000);
    });
  }

  Future<bool> hasRoomSecret(String roomId) async {
    final secret = await _loadRoomSecret(roomId);
    return secret != null && secret.isNotEmpty;
  }

  Future<void> clearRoomSecret(String roomId) async {
    await _deleteRoomSecret(roomId);
  }

  Future<ChatChannel> createDistributedRoom({
    required String roomId,
    required String name,
    String? description,
    List<String> seedPeerHints = const [],
  }) async {
    _requireSigner();
    final existing = await getRoom(roomId);
    if (existing != null) {
      throw Exception('Room already exists: $roomId');
    }

    final roomKeys = NostrKeyGenerator.generateKeyPair();
    await _saveRoomSecret(roomId, roomKeys.nsec);

    final created = DistributedChatControlEvent.create(
      type: DistributedChatControlType.roomCreated,
      roomId: roomId,
      actorNsec: profileNsec!,
      actorCallsign: profileCallsign,
      payload: {
        'name': name,
        if (description != null) 'description': description,
        'owner_npub': profileNpub,
        'room_npub': roomKeys.npub,
        'distribution_mode': 'distributed',
        'join_policy': 'approval_required',
        if (seedPeerHints.isNotEmpty) 'seed_peer_hints': seedPeerHints,
      },
    );
    await _importControlEvent(created);
    await _rotateEpoch(
      roomId,
      summary: 'room_created',
      rotatedAt: created.createdAt.toUtc(),
    );

    return _requireRoom(roomId);
  }

  Future<DistributedChatInvite> createInvite(
    String roomId, {
    List<String> seedPeerHints = const [],
  }) async {
    final room = await _requireRoom(roomId);
    final config = await _requireDistributedConfig(roomId);

    return DistributedChatInvite(
      roomId: roomId,
      roomName: room.name,
      roomDescription: room.description,
      ownerNpub: config.owner ?? profileNpub,
      roomNpub: config.roomNpub!,
      joinPolicy: config.joinPolicy,
      distributionMode: config.distributionMode ?? 'distributed',
      hostCallsign: profileCallsign,
      seedPeerHints: seedPeerHints.isNotEmpty
          ? seedPeerHints
          : config.seedPeerHints,
    );
  }

  Future<ChatChannel> acceptInviteAndRequestJoin(
    DistributedChatInvite invite, {
    String? message,
  }) async {
    _requireSigner();
    await _ensureStubRoomFromInvite(invite);

    final request = DistributedChatControlEvent.create(
      type: DistributedChatControlType.joinRequested,
      roomId: invite.roomId,
      actorNsec: profileNsec!,
      actorCallsign: profileCallsign,
      targetNpub: profileNpub,
      payload: {
        'callsign': profileCallsign,
        if (message != null && message.trim().isNotEmpty)
          'message': message.trim(),
      },
    );
    await _importControlEvent(request);
    return _requireRoom(invite.roomId);
  }

  Future<DistributedChatControlEvent> approveApplicant(
    String roomId,
    String applicantNpub, {
    int? expiresAt,
  }) async {
    _requireSigner();
    final config = await _requireDistributedConfig(roomId);
    if (!config.canManageApplications(profileNpub)) {
      throw PermissionDeniedException(
        'Only moderators and above can approve applicants',
      );
    }

    final roomNsec = await _requireRoomSecret(roomId);
    final admission = DistributedChatAdmission.create(
      roomId: roomId,
      roomNsec: roomNsec,
      memberNpub: applicantNpub,
      approvedByNpub: profileNpub,
      expiresAt: expiresAt,
    );
    final event = DistributedChatControlEvent.create(
      type: DistributedChatControlType.joinApproved,
      roomId: roomId,
      actorNsec: profileNsec!,
      actorCallsign: profileCallsign,
      targetNpub: applicantNpub,
      payload: {'admission': admission.toJson()},
    );
    await _importControlEvent(event);
    await _rotateEpoch(
      roomId,
      summary: 'join_approved:$applicantNpub',
      rotatedAt: event.createdAt.toUtc(),
    );
    return event;
  }

  Future<DistributedChatControlEvent> rejectApplicant(
    String roomId,
    String applicantNpub, {
    String? reason,
  }) async {
    _requireSigner();
    final config = await _requireDistributedConfig(roomId);
    if (!config.canManageApplications(profileNpub)) {
      throw PermissionDeniedException(
        'Only moderators and above can reject applicants',
      );
    }

    final event = DistributedChatControlEvent.create(
      type: DistributedChatControlType.joinRejected,
      roomId: roomId,
      actorNsec: profileNsec!,
      actorCallsign: profileCallsign,
      targetNpub: applicantNpub,
      payload: {
        if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
      },
    );
    await _importControlEvent(event);
    return event;
  }

  Future<DistributedChatControlEvent> promoteToModerator(
    String roomId,
    String targetNpub,
  ) async {
    final event = await _emitRoleChange(
      roomId: roomId,
      targetNpub: targetNpub,
      type: DistributedChatControlType.moderatorGranted,
      role: 'moderator',
    );
    await shareRoomSecret(roomId, targetNpub);
    return event;
  }

  Future<DistributedChatControlEvent> promoteToAdmin(
    String roomId,
    String targetNpub,
  ) async {
    final event = await _emitRoleChange(
      roomId: roomId,
      targetNpub: targetNpub,
      type: DistributedChatControlType.adminGranted,
      role: 'admin',
    );
    await shareRoomSecret(roomId, targetNpub);
    return event;
  }

  Future<DistributedChatControlEvent> demoteModerator(
    String roomId,
    String targetNpub,
  ) async {
    return _emitRoleChange(
      roomId: roomId,
      targetNpub: targetNpub,
      type: DistributedChatControlType.moderatorRevoked,
      role: 'moderator',
    );
  }

  Future<DistributedChatControlEvent> demoteAdmin(
    String roomId,
    String targetNpub,
  ) async {
    return _emitRoleChange(
      roomId: roomId,
      targetNpub: targetNpub,
      type: DistributedChatControlType.adminRevoked,
      role: 'admin',
    );
  }

  Future<DistributedChatControlEvent> shareRoomSecret(
    String roomId,
    String targetNpub,
  ) async {
    _requireSigner();
    final config = await _requireDistributedConfig(roomId);
    if (!config.canManageRoles(profileNpub)) {
      throw PermissionDeniedException(
        'Only admins and above can distribute room signing keys',
      );
    }
    if (!config.isAdmin(targetNpub) && !config.isModerator(targetNpub)) {
      throw PermissionDeniedException(
        'Room signing keys may only be shared with admins or moderators',
      );
    }

    final roomNsec = await _requireRoomSecret(roomId);
    final encryptedSecret = BackupEncryption.encryptFile(
      Uint8List.fromList(utf8.encode(roomNsec)),
      targetNpub,
    );
    final event = DistributedChatControlEvent.create(
      type: DistributedChatControlType.roomKeyShared,
      roomId: roomId,
      actorNsec: profileNsec!,
      actorCallsign: profileCallsign,
      targetNpub: targetNpub,
      payload: {'encrypted_room_nsec': base64Encode(encryptedSecret)},
    );
    await _importControlEvent(event);
    return event;
  }

  Future<DistributedChatControlEvent> removeMember(
    String roomId,
    String targetNpub,
  ) async {
    final event = await _emitMembershipChange(
      roomId: roomId,
      targetNpub: targetNpub,
      type: DistributedChatControlType.memberRemoved,
    );
    await _rotateEpoch(
      roomId,
      summary: 'member_removed:$targetNpub',
      rotatedAt: event.createdAt.toUtc(),
    );
    return event;
  }

  Future<DistributedChatControlEvent> banMember(
    String roomId,
    String targetNpub,
  ) async {
    final event = await _emitMembershipChange(
      roomId: roomId,
      targetNpub: targetNpub,
      type: DistributedChatControlType.memberBanned,
    );
    await _rotateEpoch(
      roomId,
      summary: 'member_banned:$targetNpub',
      rotatedAt: event.createdAt.toUtc(),
    );
    return event;
  }

  Future<DistributedChatControlEvent> unbanMember(
    String roomId,
    String targetNpub,
  ) async {
    return _emitMembershipChange(
      roomId: roomId,
      targetNpub: targetNpub,
      type: DistributedChatControlType.memberUnbanned,
    );
  }

  Future<DistributedChatControlEvent> pauseRoom(
    String roomId, {
    String? reason,
  }) async {
    return _emitStateChange(
      roomId: roomId,
      type: DistributedChatControlType.roomPaused,
      state: 'paused',
      reason: reason,
    );
  }

  Future<DistributedChatControlEvent> resumeRoom(String roomId) async {
    return _emitStateChange(
      roomId: roomId,
      type: DistributedChatControlType.roomResumed,
      state: 'active',
    );
  }

  Future<DistributedChatControlEvent> closeRoom(
    String roomId, {
    String? reason,
  }) async {
    return _emitStateChange(
      roomId: roomId,
      type: DistributedChatControlType.roomClosed,
      state: 'closed',
      reason: reason,
    );
  }

  Future<DistributedChatControlEvent> deleteMessage(
    String roomId, {
    required String timestamp,
    required String authorCallsign,
  }) async {
    _requireSigner();
    final event = DistributedChatControlEvent.create(
      type: DistributedChatControlType.messageDeleted,
      roomId: roomId,
      actorNsec: profileNsec!,
      actorCallsign: profileCallsign,
      messageTimestamp: timestamp,
      messageAuthor: authorCallsign,
    );
    await _importControlEvent(event);
    return event;
  }

  Future<ChatMessage> sendMessage(
    String roomId,
    String content, {
    Map<String, String>? metadata,
  }) async {
    _requireSigner();
    final snapshot = await _requireSnapshot(roomId);
    final config = _snapshotToConfig(snapshot);
    if (!config.canWrite(profileNpub)) {
      throw PermissionDeniedException('You cannot send messages to this room');
    }
    final epoch = snapshot.metadata.currentEpoch;
    if (epoch < 1) {
      throw Exception('Room has no active epoch: $roomId');
    }
    final epochKey = await _loadLocalEpochKey(roomId, epoch);
    if (epochKey == null) {
      throw PermissionDeniedException(
        'Missing local epoch key for room $roomId epoch $epoch',
      );
    }

    final plaintext = Uint8List.fromList(utf8.encode(content));
    final encrypted = BackupEncryption.encryptBytesWithSharedKey(
      plaintext,
      epochKey,
      info: _epochMessageInfo(roomId, epoch),
    );
    final ciphertextSha1 = sha1.convert(encrypted.ciphertext).toString();
    final envelope = <String, dynamic>{
      'epoch': epoch,
      'enc': _epochEncryptionScheme,
      'ciphertext_sha1': ciphertextSha1,
      'nonce': base64Encode(encrypted.nonce),
    };

    final privateKeyHex = NostrCrypto.decodeNsec(profileNsec!);
    final pubkeyHex = NostrCrypto.derivePublicKey(privateKeyHex);
    final messageEvent = NostrEvent.textNote(
      pubkeyHex: pubkeyHex,
      content: jsonEncode(envelope),
      tags: [
        ['t', 'chat'],
        ['room', roomId],
        ['callsign', profileCallsign],
        ['epoch', epoch.toString()],
        ['enc', _epochEncryptionScheme],
        ['ciphertext_sha1', ciphertextSha1],
      ],
    );
    messageEvent.signWithNsec(profileNsec!);

    await _withStore(roomId, (store) async {
      final metadataRecord = await store.loadMetadata();
      if (metadataRecord == null) {
        throw Exception('Room not found: $roomId');
      }
      final record = DChatMessageRecord(
        messageId: messageEvent.id ?? messageEvent.calculateId(),
        epoch: epoch,
        lamport: await store.nextMessageLamport(),
        authorNpub: profileNpub,
        authoredAt: DateTime.fromMillisecondsSinceEpoch(
          messageEvent.createdAt * 1000,
          isUtc: true,
        ),
        ciphertext: encrypted.ciphertext,
        nonce: encrypted.nonce,
        encryptionScheme: _epochEncryptionScheme,
        ciphertextSha1: ciphertextSha1,
        rawEventJson: jsonEncode(messageEvent.toJson()),
      );
      await store.appendMessage(record);
    });

    final eventDateTime = DateTime.fromMillisecondsSinceEpoch(
      messageEvent.createdAt * 1000,
      isUtc: true,
    ).toLocal();
    return ChatMessage(
      author: profileCallsign,
      timestamp: ChatFormat.formatTimestamp(eventDateTime),
      content: content,
      metadata: {
        ...?metadata,
        'npub': profileNpub,
        'created_at': messageEvent.createdAt.toString(),
        if (messageEvent.sig != null) 'signature': messageEvent.sig!,
        if (messageEvent.id != null) 'event_id': messageEvent.id!,
        'enc': _epochEncryptionScheme,
        'epoch': epoch.toString(),
      },
    );
  }

  Future<void> syncRoomFromPeer(
    DistributedChatService peer,
    String roomId,
  ) async {
    final remoteEvents = await peer.loadControlEvents(roomId);
    for (final event in remoteEvents) {
      await _importControlEvent(event);
    }

    final room = await getRoom(roomId);
    if (room == null) {
      return;
    }

    final config = room.config;
    final hasCurrentAccess = config?.canAccess(profileNpub) ?? false;
    final accessEnd = await _accessEnd(roomId, profileNpub);
    if (!hasCurrentAccess && accessEnd == null) {
      return;
    }

    final remoteMessages = await peer._loadMessageRecords(
      roomId,
      limit: 100000,
      includeDeleted: true,
    );
    final localMessages = await _loadMessageRecords(
      roomId,
      limit: 100000,
      includeDeleted: true,
    );
    final localById = {
      for (final message in localMessages) message.messageId: message,
    };

    for (final message in remoteMessages) {
      if (!hasCurrentAccess &&
          accessEnd != null &&
          !message.authoredAt.toLocal().isBefore(accessEnd)) {
        continue;
      }
      final local = localById[message.messageId];
      if (local == null) {
        await _importMessageRecord(roomId, message);
        localById[message.messageId] = message;
        continue;
      }
      if (local.deletedAt == null && message.deletedAt != null) {
        await _withStore(roomId, (store) async {
          await store.markMessageDeleted(
            message.messageId,
            deletedAt: message.deletedAt!,
          );
        });
      }
    }
  }

  Future<String> _requireRoomSecret(String roomId) async {
    final secret = await _loadRoomSecret(roomId);
    if (secret == null || secret.isEmpty) {
      throw Exception('Missing room secret for $roomId');
    }
    return secret;
  }

  void _requireSigner() {
    if (profileNsec == null || profileNsec!.isEmpty) {
      throw Exception('This operation requires a local NOSTR signer');
    }
  }

  Future<void> _ensureStubRoomFromInvite(DistributedChatInvite invite) async {
    final existing = await getRoom(invite.roomId);
    final now = DateTime.now().toUtc();
    if (existing != null) {
      await _withStore(invite.roomId, (store) async {
        final metadata = await store.loadMetadata();
        if (metadata == null) {
          return;
        }
        final mergedHints = {
          ...metadata.seedPeerHints,
          ...invite.seedPeerHints,
        }.toList();
        await store.initializeRoom(
          metadata.copyWith(
            title: invite.roomName,
            description: invite.roomDescription,
            ownerNpub: invite.ownerNpub,
            roomNpub: invite.roomNpub,
            seedPeerHints: mergedHints,
            joinPolicy: invite.joinPolicy,
            updatedAt: now,
          ),
        );
      });
      return;
    }

    await _withStore(invite.roomId, (store) async {
      await store.initializeRoom(
        DChatRoomMetadata(
          roomId: invite.roomId,
          title: invite.roomName,
          description: invite.roomDescription,
          ownerNpub: invite.ownerNpub,
          roomNpub: invite.roomNpub,
          seedPeerHints: invite.seedPeerHints,
          joinPolicy: invite.joinPolicy,
          createdAt: now,
          updatedAt: now,
        ),
      );
      await store.upsertMember(
        DChatMemberRecord(
          memberNpub: invite.ownerNpub,
          role: 'owner',
          status: 'active',
          joinedAt: now,
          addedBy: invite.ownerNpub,
          updatedAt: now,
        ),
      );
    });
  }

  Future<DistributedChatControlEvent> _emitRoleChange({
    required String roomId,
    required String targetNpub,
    required DistributedChatControlType type,
    required String role,
  }) async {
    _requireSigner();
    final event = DistributedChatControlEvent.create(
      type: type,
      roomId: roomId,
      actorNsec: profileNsec!,
      actorCallsign: profileCallsign,
      targetNpub: targetNpub,
      role: role,
    );
    await _importControlEvent(event);
    return event;
  }

  Future<DistributedChatControlEvent> _emitMembershipChange({
    required String roomId,
    required String targetNpub,
    required DistributedChatControlType type,
  }) async {
    _requireSigner();
    final event = DistributedChatControlEvent.create(
      type: type,
      roomId: roomId,
      actorNsec: profileNsec!,
      actorCallsign: profileCallsign,
      targetNpub: targetNpub,
    );
    await _importControlEvent(event);
    return event;
  }

  Future<DistributedChatControlEvent> _emitStateChange({
    required String roomId,
    required DistributedChatControlType type,
    required String state,
    String? reason,
  }) async {
    _requireSigner();
    final event = DistributedChatControlEvent.create(
      type: type,
      roomId: roomId,
      actorNsec: profileNsec!,
      actorCallsign: profileCallsign,
      state: state,
      payload: {
        if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
      },
    );
    await _importControlEvent(event);
    return event;
  }

  Future<void> _rotateEpoch(
    String roomId, {
    required String summary,
    DateTime? rotatedAt,
  }) async {
    _requireSigner();
    final snapshot = await _requireSnapshot(roomId);
    final config = _snapshotToConfig(snapshot);
    if (!config.isModerator(profileNpub)) {
      throw PermissionDeniedException(
        'Only moderators and above can rotate room epochs',
      );
    }

    final recipients = _activeEpochRecipients(config);
    if (recipients.isEmpty) {
      throw Exception('Cannot rotate epoch without active recipients');
    }

    final epoch = snapshot.metadata.currentEpoch + 1;
    final epochKey = BackupEncryption.randomBytes(32);
    final boxes = [
      for (final recipientNpub in recipients)
        {
          'recipient_npub': recipientNpub,
          'envelope': base64Encode(
            BackupEncryption.encryptFile(epochKey, recipientNpub),
          ),
        },
    ];

    final event = DistributedChatControlEvent.create(
      type: DistributedChatControlType.epochRotated,
      roomId: roomId,
      actorNsec: profileNsec!,
      actorCallsign: profileCallsign,
      createdAt: rotatedAt == null
          ? null
          : rotatedAt.millisecondsSinceEpoch ~/ 1000,
      payload: {'epoch': epoch, 'summary': summary, 'boxes': boxes},
    );
    await _importControlEvent(event);
  }

  Future<void> _importControlEvent(DistributedChatControlEvent event) async {
    if (!event.verify()) {
      throw Exception('Invalid distributed control event signature');
    }

    final eventId = event.event.id ?? event.event.calculateId();
    final alreadyExists = await _withStore(event.roomId, (store) async {
      return store.hasControlEvent(eventId);
    });
    if (alreadyExists) {
      return;
    }

    await _applyControlEvent(event);
    await _withStore(event.roomId, (store) async {
      await store.appendControlEvent(
        event,
        lamport: await store.nextControlLamport(),
      );
    });
  }

  Future<void> _applyControlEvent(DistributedChatControlEvent event) async {
    switch (event.type) {
      case DistributedChatControlType.roomCreated:
        await _applyRoomCreated(event);
        break;
      case DistributedChatControlType.joinRequested:
        await _applyJoinRequested(event);
        break;
      case DistributedChatControlType.joinApproved:
        await _applyJoinApproved(event);
        break;
      case DistributedChatControlType.joinRejected:
        await _applyJoinRejected(event);
        break;
      case DistributedChatControlType.roomKeyShared:
        await _applyRoomKeyShared(event);
        break;
      case DistributedChatControlType.epochRotated:
        await _applyEpochRotated(event);
        break;
      case DistributedChatControlType.memberRemoved:
        await _applyMemberRemoved(event);
        break;
      case DistributedChatControlType.memberBanned:
        await _applyMemberBanned(event);
        break;
      case DistributedChatControlType.memberUnbanned:
        await _applyMemberUnbanned(event);
        break;
      case DistributedChatControlType.moderatorGranted:
        await _applyModeratorGranted(event);
        break;
      case DistributedChatControlType.moderatorRevoked:
        await _applyModeratorRevoked(event);
        break;
      case DistributedChatControlType.adminGranted:
        await _applyAdminGranted(event);
        break;
      case DistributedChatControlType.adminRevoked:
        await _applyAdminRevoked(event);
        break;
      case DistributedChatControlType.roomPaused:
      case DistributedChatControlType.roomResumed:
      case DistributedChatControlType.roomClosed:
        await _applyRoomStateChange(event);
        break;
      case DistributedChatControlType.messageDeleted:
        await _applyMessageDeleted(event);
        break;
    }
  }

  Future<void> _applyRoomCreated(DistributedChatControlEvent event) async {
    final ownerNpub = event.payload['owner_npub'] as String? ?? event.actorNpub;
    final createdAt = event.createdAt.toUtc();

    await _withStore(event.roomId, (store) async {
      final existing = await store.loadMetadata();
      final mergedHints = {
        ...?existing?.seedPeerHints,
        ...List<String>.from(
          event.payload['seed_peer_hints'] as List? ?? const [],
        ),
      }.toList();

      await store.initializeRoom(
        DChatRoomMetadata(
          roomId: event.roomId,
          title:
              event.payload['name'] as String? ??
              existing?.title ??
              event.roomId,
          description:
              event.payload['description'] as String? ?? existing?.description,
          ownerNpub: ownerNpub,
          roomNpub: event.payload['room_npub'] as String? ?? existing?.roomNpub,
          seedPeerHints: mergedHints,
          currentEpoch: existing?.currentEpoch ?? 0,
          snapshotStart: existing?.snapshotStart,
          state: existing?.state ?? 'active',
          joinPolicy:
              event.payload['join_policy'] as String? ??
              existing?.joinPolicy ??
              'approval_required',
          createdAt: existing?.createdAt ?? createdAt,
          updatedAt: createdAt,
        ),
      );

      final ownerRecord = await _findMemberRecord(store, ownerNpub);
      await store.upsertMember(
        DChatMemberRecord(
          memberNpub: ownerNpub,
          role: 'owner',
          status: 'active',
          joinedAt: ownerRecord?.joinedAt ?? createdAt,
          removedAt: null,
          addedBy: ownerNpub,
          updatedAt: createdAt,
        ),
      );
    });
  }

  Future<void> _applyJoinRequested(DistributedChatControlEvent event) async {
    final room = await getRoom(event.roomId);
    if (room == null) {
      return;
    }
    final config = room.config;
    final applicantNpub = event.targetNpub ?? event.actorNpub;
    if (config == null ||
        config.hasApplied(applicantNpub) ||
        config.isMember(applicantNpub) ||
        config.isBanned(applicantNpub)) {
      return;
    }

    await _withStore(event.roomId, (store) async {
      await store.upsertMember(
        DChatMemberRecord(
          memberNpub: applicantNpub,
          role: 'member',
          status: 'pending',
          addedBy: event.actorNpub,
          updatedAt: event.createdAt.toUtc(),
        ),
      );
    });
  }

  Future<void> _applyJoinApproved(DistributedChatControlEvent event) async {
    final snapshot = await _requireSnapshot(event.roomId);
    final room = _snapshotToChannel(snapshot);
    final config = room.config;
    final targetNpub = event.targetNpub;
    if (config == null || targetNpub == null) {
      return;
    }
    if (!config.canManageApplications(event.actorNpub)) {
      throw PermissionDeniedException(
        'Only moderators and above can approve applicants',
      );
    }

    final admission = event.admission;
    if (config.roomNpub == null || admission == null) {
      throw Exception('Missing admission capability for join approval');
    }
    if (!admission.verify(
      roomNpub: config.roomNpub!,
      roomId: event.roomId,
      memberNpub: targetNpub,
    )) {
      throw Exception('Invalid admission capability for $targetNpub');
    }
    if (config.isBanned(targetNpub)) {
      throw PermissionDeniedException('User is banned from this room');
    }
    if (config.isMember(targetNpub)) {
      return;
    }

    await _withStore(event.roomId, (store) async {
      final existing = await _findMemberRecord(store, targetNpub);
      await store.upsertMember(
        DChatMemberRecord(
          memberNpub: targetNpub,
          role: existing?.role == 'admin' || existing?.role == 'moderator'
              ? existing!.role
              : 'member',
          status: 'active',
          joinedAt: existing?.joinedAt ?? event.createdAt.toUtc(),
          addedBy: existing?.addedBy ?? event.actorNpub,
          updatedAt: event.createdAt.toUtc(),
        ),
      );
    });
  }

  Future<void> _applyJoinRejected(DistributedChatControlEvent event) async {
    final room = await _requireRoom(event.roomId);
    final config = room.config;
    final applicantNpub = event.targetNpub;
    if (config == null || applicantNpub == null) {
      return;
    }
    if (!config.canManageApplications(event.actorNpub)) {
      throw PermissionDeniedException(
        'Only moderators and above can reject applicants',
      );
    }
    if (!config.hasApplied(applicantNpub)) {
      return;
    }

    await _withStore(event.roomId, (store) async {
      final existing = await _findMemberRecord(store, applicantNpub);
      await store.upsertMember(
        DChatMemberRecord(
          memberNpub: applicantNpub,
          role: existing?.role ?? 'member',
          status: 'rejected',
          joinedAt: existing?.joinedAt,
          removedAt: event.createdAt.toUtc(),
          addedBy: existing?.addedBy ?? event.actorNpub,
          updatedAt: event.createdAt.toUtc(),
        ),
      );
    });
  }

  Future<void> _applyRoomKeyShared(DistributedChatControlEvent event) async {
    final room = await getRoom(event.roomId);
    final config = room?.config;
    if (room == null || config == null) {
      return;
    }
    if (!config.isAdmin(event.actorNpub)) {
      throw PermissionDeniedException(
        'Only admins and above can distribute room signing keys',
      );
    }
    if (event.targetNpub != profileNpub || profileNsec == null) {
      return;
    }

    final encryptedBase64 = event.encryptedRoomSecretBase64;
    if (encryptedBase64 == null || encryptedBase64.isEmpty) {
      throw Exception('Missing encrypted room secret payload');
    }

    final encryptedBytes = base64Decode(encryptedBase64);
    final decryptedBytes = BackupEncryption.decryptFile(
      Uint8List.fromList(encryptedBytes),
      profileNsec!,
    );
    final roomNsec = utf8.decode(decryptedBytes).trim();
    final derivedNpub = NostrKeyGenerator.derivePublicKey(roomNsec);
    if (derivedNpub == null || derivedNpub != config.roomNpub) {
      throw Exception('Room secret does not match room public key');
    }
    await _saveRoomSecret(event.roomId, roomNsec);
  }

  Future<void> _applyEpochRotated(DistributedChatControlEvent event) async {
    final room = await _requireRoom(event.roomId);
    final config = room.config;
    final epoch = event.epoch;
    if (config == null || epoch == null) {
      return;
    }
    if (!config.isModerator(event.actorNpub)) {
      throw PermissionDeniedException(
        'Only moderators and above can rotate room epochs',
      );
    }

    final boxes = event.epochKeyBoxes;
    if (boxes.isEmpty) {
      throw Exception('Epoch rotation is missing key envelopes');
    }

    await _withStore(event.roomId, (store) async {
      final metadata = await store.loadMetadata();
      if (metadata == null) {
        return;
      }
      final controlEventId = event.event.id ?? event.event.calculateId();
      await store.recordEpoch(
        DChatEpochRecord(
          epoch: epoch,
          rotatedByNpub: event.actorNpub,
          createdAt: event.createdAt.toUtc(),
          controlEventId: controlEventId,
          summary: event.epochSummary,
        ),
      );
      for (final box in boxes) {
        await store.putEpochKeyBox(
          DChatEpochKeyBox(
            epoch: epoch,
            recipientNpub: box['recipient_npub']!,
            envelope: box['envelope']!,
            createdAt: event.createdAt.toUtc(),
          ),
        );
      }
      await store.initializeRoom(
        metadata.copyWith(
          currentEpoch: epoch > metadata.currentEpoch
              ? epoch
              : metadata.currentEpoch,
          snapshotStart: event.createdAt.toUtc().millisecondsSinceEpoch,
          updatedAt: event.createdAt.toUtc(),
        ),
      );
      if (profileNsec == null || profileNsec!.isEmpty) {
        return;
      }
      final myBox = boxes.where((box) => box['recipient_npub'] == profileNpub);
      if (myBox.isEmpty) {
        return;
      }
      final decrypted = BackupEncryption.decryptFile(
        Uint8List.fromList(base64Decode(myBox.first['envelope']!)),
        profileNsec!,
      );
      if (decrypted.isEmpty) {
        throw Exception('Received empty epoch key for room ${event.roomId}');
      }
      await store.storeLocalEpochKey(epoch, decrypted);
    });
  }

  Future<void> _applyMemberRemoved(DistributedChatControlEvent event) async {
    final room = await _requireRoom(event.roomId);
    final config = room.config;
    final targetNpub = event.targetNpub;
    if (config == null || targetNpub == null) {
      return;
    }
    if (config.isOwner(targetNpub)) {
      throw PermissionDeniedException('Cannot remove the room owner');
    }
    if (config.isAdmin(targetNpub)) {
      if (!config.isOwner(event.actorNpub)) {
        throw PermissionDeniedException('Only the owner can remove admins');
      }
    } else if (config.isModerator(targetNpub)) {
      if (!config.isAdmin(event.actorNpub)) {
        throw PermissionDeniedException('Only admins can remove moderators');
      }
    } else if (!config.canManageMembers(event.actorNpub)) {
      throw PermissionDeniedException(
        'Only moderators and above can remove members',
      );
    }
    if (!config.isMember(targetNpub)) {
      return;
    }

    await _withStore(event.roomId, (store) async {
      final existing = await _findMemberRecord(store, targetNpub);
      await store.upsertMember(
        DChatMemberRecord(
          memberNpub: targetNpub,
          role: 'member',
          status: 'removed',
          joinedAt: existing?.joinedAt,
          removedAt: event.createdAt.toUtc(),
          addedBy: existing?.addedBy ?? event.actorNpub,
          updatedAt: event.createdAt.toUtc(),
        ),
      );
    });
  }

  Future<void> _applyMemberBanned(DistributedChatControlEvent event) async {
    final room = await _requireRoom(event.roomId);
    final config = room.config;
    final targetNpub = event.targetNpub;
    if (config == null || targetNpub == null) {
      return;
    }
    if (config.isOwner(targetNpub)) {
      throw PermissionDeniedException('Cannot ban the room owner');
    }
    if (!config.canBan(event.actorNpub)) {
      throw PermissionDeniedException(
        'Only moderators and above can ban users',
      );
    }
    if (config.isAdmin(targetNpub) && !config.isOwner(event.actorNpub)) {
      throw PermissionDeniedException('Only the owner can ban admins');
    }
    if (config.isModerator(targetNpub) && !config.isAdmin(event.actorNpub)) {
      throw PermissionDeniedException('Only admins can ban moderators');
    }
    if (config.isBanned(targetNpub)) {
      return;
    }

    await _withStore(event.roomId, (store) async {
      final existing = await _findMemberRecord(store, targetNpub);
      await store.upsertMember(
        DChatMemberRecord(
          memberNpub: targetNpub,
          role: 'member',
          status: 'banned',
          joinedAt: existing?.joinedAt,
          removedAt: event.createdAt.toUtc(),
          addedBy: existing?.addedBy ?? event.actorNpub,
          updatedAt: event.createdAt.toUtc(),
        ),
      );
    });
  }

  Future<void> _applyMemberUnbanned(DistributedChatControlEvent event) async {
    final room = await _requireRoom(event.roomId);
    final config = room.config;
    final targetNpub = event.targetNpub;
    if (config == null || targetNpub == null) {
      return;
    }
    if (!config.canBan(event.actorNpub)) {
      throw PermissionDeniedException(
        'Only moderators and above can unban users',
      );
    }
    if (!config.isBanned(targetNpub)) {
      return;
    }

    await _withStore(event.roomId, (store) async {
      final existing = await _findMemberRecord(store, targetNpub);
      await store.upsertMember(
        DChatMemberRecord(
          memberNpub: targetNpub,
          role: 'member',
          status: 'removed',
          joinedAt: existing?.joinedAt,
          removedAt: event.createdAt.toUtc(),
          addedBy: existing?.addedBy ?? event.actorNpub,
          updatedAt: event.createdAt.toUtc(),
        ),
      );
    });
  }

  Future<void> _applyModeratorGranted(DistributedChatControlEvent event) async {
    final room = await _requireRoom(event.roomId);
    final config = room.config;
    final targetNpub = event.targetNpub;
    if (config == null || targetNpub == null) {
      return;
    }
    if (!config.canManageRoles(event.actorNpub)) {
      throw PermissionDeniedException(
        'Only admins and above can promote to moderator',
      );
    }
    if (!config.isMember(targetNpub)) {
      throw PermissionDeniedException('User must be a member before promotion');
    }
    if (config.isModerator(targetNpub)) {
      return;
    }

    await _withStore(event.roomId, (store) async {
      final existing = await _findMemberRecord(store, targetNpub);
      await store.upsertMember(
        DChatMemberRecord(
          memberNpub: targetNpub,
          role: 'moderator',
          status: 'active',
          joinedAt: existing?.joinedAt ?? event.createdAt.toUtc(),
          addedBy: existing?.addedBy ?? event.actorNpub,
          updatedAt: event.createdAt.toUtc(),
        ),
      );
    });
  }

  Future<void> _applyModeratorRevoked(DistributedChatControlEvent event) async {
    final room = await _requireRoom(event.roomId);
    final config = room.config;
    final targetNpub = event.targetNpub;
    if (config == null || targetNpub == null) {
      return;
    }
    if (config.isOwner(targetNpub)) {
      throw PermissionDeniedException('Cannot demote the room owner');
    }
    if (!config.moderatorNpubs.contains(targetNpub)) {
      return;
    }
    if (!config.isAdmin(event.actorNpub)) {
      throw PermissionDeniedException('Only admins can demote moderators');
    }

    await _withStore(event.roomId, (store) async {
      final existing = await _findMemberRecord(store, targetNpub);
      await store.upsertMember(
        DChatMemberRecord(
          memberNpub: targetNpub,
          role: 'member',
          status: 'active',
          joinedAt: existing?.joinedAt ?? event.createdAt.toUtc(),
          addedBy: existing?.addedBy ?? event.actorNpub,
          updatedAt: event.createdAt.toUtc(),
        ),
      );
    });
  }

  Future<void> _applyAdminGranted(DistributedChatControlEvent event) async {
    final room = await _requireRoom(event.roomId);
    final config = room.config;
    final targetNpub = event.targetNpub;
    if (config == null || targetNpub == null) {
      return;
    }
    if (!config.canManageAdmins(event.actorNpub)) {
      throw PermissionDeniedException('Only the owner can promote to admin');
    }
    if (!config.isMember(targetNpub)) {
      throw PermissionDeniedException('User must be a member before promotion');
    }
    if (config.isAdmin(targetNpub)) {
      return;
    }

    await _withStore(event.roomId, (store) async {
      final existing = await _findMemberRecord(store, targetNpub);
      await store.upsertMember(
        DChatMemberRecord(
          memberNpub: targetNpub,
          role: 'admin',
          status: 'active',
          joinedAt: existing?.joinedAt ?? event.createdAt.toUtc(),
          addedBy: existing?.addedBy ?? event.actorNpub,
          updatedAt: event.createdAt.toUtc(),
        ),
      );
    });
  }

  Future<void> _applyAdminRevoked(DistributedChatControlEvent event) async {
    final room = await _requireRoom(event.roomId);
    final config = room.config;
    final targetNpub = event.targetNpub;
    if (config == null || targetNpub == null) {
      return;
    }
    if (config.isOwner(targetNpub)) {
      throw PermissionDeniedException('Cannot demote the room owner');
    }
    if (!config.admins.contains(targetNpub)) {
      return;
    }
    if (!config.isOwner(event.actorNpub)) {
      throw PermissionDeniedException('Only the owner can demote admins');
    }

    await _withStore(event.roomId, (store) async {
      final existing = await _findMemberRecord(store, targetNpub);
      await store.upsertMember(
        DChatMemberRecord(
          memberNpub: targetNpub,
          role: 'member',
          status: 'active',
          joinedAt: existing?.joinedAt ?? event.createdAt.toUtc(),
          addedBy: existing?.addedBy ?? event.actorNpub,
          updatedAt: event.createdAt.toUtc(),
        ),
      );
    });
  }

  Future<void> _applyRoomStateChange(DistributedChatControlEvent event) async {
    final room = await _requireRoom(event.roomId);
    final config = room.config;
    if (config == null) {
      return;
    }
    if (!config.isAdmin(event.actorNpub)) {
      throw PermissionDeniedException(
        'Only admins and above can change room state',
      );
    }

    await _withStore(event.roomId, (store) async {
      final metadata = await store.loadMetadata();
      if (metadata == null) {
        return;
      }
      await store.initializeRoom(
        metadata.copyWith(
          state: event.state ?? metadata.state,
          updatedAt: event.createdAt.toUtc(),
        ),
      );
    });
  }

  Future<void> _applyMessageDeleted(DistributedChatControlEvent event) async {
    final room = await _requireRoom(event.roomId);
    final config = room.config;
    final timestamp = event.messageTimestamp;
    final authorCallsign = event.messageAuthor;
    if (config == null || timestamp == null || authorCallsign == null) {
      return;
    }

    final matches = <DChatMessageRecord>[];
    final records = await _loadMessageRecords(
      event.roomId,
      limit: 100000,
      includeDeleted: true,
    );
    await _withStore(event.roomId, (store) async {
      final keyCache = <int, Uint8List?>{};
      for (final record in records) {
        final message = await _chatMessageFromRecord(
          event.roomId,
          store,
          record,
          keyCache: keyCache,
        );
        if (message == null) {
          continue;
        }
        if (message.timestamp == timestamp &&
            message.author == authorCallsign) {
          matches.add(record);
        }
      }
    });
    if (matches.isEmpty) {
      return;
    }

    final canModerate = config.isModerator(event.actorNpub);
    for (final record in matches) {
      final rawEvent = jsonDecode(record.rawEventJson) as Map<String, dynamic>;
      final messageEvent = NostrEvent.fromJson(rawEvent);
      final messageNpub = NostrCrypto.encodeNpub(messageEvent.pubkey);
      final isAuthor = messageNpub == event.actorNpub;
      if (!isAuthor && !canModerate) {
        throw PermissionDeniedException(
          'Not authorized to delete this message',
        );
      }
      await _withStore(event.roomId, (store) async {
        await store.markMessageDeleted(
          record.messageId,
          deletedAt: event.createdAt.toUtc(),
        );
      });
    }
  }

  Future<DateTime?> _accessEnd(String roomId, String npub) async {
    final events = await loadControlEvents(roomId);
    DateTime? end;
    for (final event in events) {
      if (event.targetNpub != npub) {
        continue;
      }
      switch (event.type) {
        case DistributedChatControlType.joinApproved:
        case DistributedChatControlType.memberUnbanned:
          end = null;
          break;
        case DistributedChatControlType.memberRemoved:
        case DistributedChatControlType.memberBanned:
          end = event.createdAt;
          break;
        default:
          break;
      }
    }
    return end;
  }

  Future<_DChatRoomSnapshot?> _loadSnapshot(String roomId) async {
    return _withStore(roomId, (store) async {
      if (!await store.exists()) {
        return null;
      }
      final metadata = await store.loadMetadata();
      if (metadata == null) {
        return null;
      }
      return _DChatRoomSnapshot(
        metadata: metadata,
        members: await store.listMembers(),
        controlEvents: await store.listControlEvents(limit: 100000),
      );
    });
  }

  Future<_DChatRoomSnapshot> _requireSnapshot(String roomId) async {
    final snapshot = await _loadSnapshot(roomId);
    if (snapshot == null) {
      throw Exception('Room not found: $roomId');
    }
    return snapshot;
  }

  ChatChannel _snapshotToChannel(_DChatRoomSnapshot snapshot) {
    final config = _snapshotToConfig(snapshot);
    final participants = <String>{
      if (snapshot.metadata.ownerNpub.isNotEmpty) snapshot.metadata.ownerNpub,
      ...config.admins,
      ...config.moderatorNpubs,
      ...config.members,
    }.toList();

    return ChatChannel(
      id: snapshot.metadata.roomId,
      type: ChatChannelType.group,
      name: snapshot.metadata.title,
      folder: 'dchat/${snapshot.metadata.roomId}',
      participants: participants,
      description: snapshot.metadata.description,
      created: snapshot.metadata.createdAt,
      config: config,
    );
  }

  ChatChannelConfig _snapshotToConfig(_DChatRoomSnapshot snapshot) {
    final admins = <String>[];
    final moderators = <String>[];
    final members = <String>[];
    final banned = <String>[];

    for (final member in snapshot.members) {
      switch (member.status) {
        case 'active':
          switch (member.role) {
            case 'admin':
              admins.add(member.memberNpub);
              break;
            case 'moderator':
              moderators.add(member.memberNpub);
              break;
            case 'member':
              members.add(member.memberNpub);
              break;
            case 'owner':
              break;
            default:
              members.add(member.memberNpub);
              break;
          }
          break;
        case 'banned':
          banned.add(member.memberNpub);
          break;
      }
    }

    final pendingByNpub = _pendingApplicationsFromEvents(
      snapshot.controlEvents,
    );
    final pendingApplicants = snapshot.members
        .where((member) => member.status == 'pending')
        .map(
          (member) =>
              pendingByNpub[member.memberNpub] ??
              MembershipApplication(
                npub: member.memberNpub,
                appliedAt: member.updatedAt,
              ),
        )
        .toList();

    return ChatChannelConfig(
      id: snapshot.metadata.roomId,
      name: snapshot.metadata.title,
      description: snapshot.metadata.description,
      visibility: 'RESTRICTED',
      owner: snapshot.metadata.ownerNpub,
      admins: admins,
      moderatorNpubs: moderators,
      members: members,
      banned: banned,
      pendingApplicants: pendingApplicants,
      dailyFiles: true,
      distributionMode: 'distributed',
      roomNpub: snapshot.metadata.roomNpub,
      roomState: snapshot.metadata.state,
      joinPolicy: snapshot.metadata.joinPolicy,
      seedPeerHints: snapshot.metadata.seedPeerHints,
    );
  }

  Map<String, MembershipApplication> _pendingApplicationsFromEvents(
    List<DistributedChatControlEvent> events,
  ) {
    final pending = <String, MembershipApplication>{};
    for (final event in events) {
      final targetNpub = event.targetNpub ?? event.actorNpub;
      switch (event.type) {
        case DistributedChatControlType.joinRequested:
          pending[targetNpub] = MembershipApplication(
            npub: targetNpub,
            callsign:
                (event.payload['callsign'] as String?) ?? event.actorCallsign,
            appliedAt: event.createdAt,
            message: event.payload['message'] as String?,
          );
          break;
        case DistributedChatControlType.joinApproved:
        case DistributedChatControlType.joinRejected:
        case DistributedChatControlType.memberRemoved:
        case DistributedChatControlType.memberBanned:
          pending.remove(targetNpub);
          break;
        default:
          break;
      }
    }
    return pending;
  }

  Future<List<DChatMessageRecord>> _loadMessageRecords(
    String roomId, {
    int limit = 1000,
    bool includeDeleted = false,
  }) async {
    return _withStore(roomId, (store) async {
      if (!await store.exists()) {
        return const <DChatMessageRecord>[];
      }
      return store.listMessageRecords(
        limit: limit,
        includeDeleted: includeDeleted,
      );
    });
  }

  Future<List<ChatMessage>> _decodeReadableMessages(
    String roomId,
    List<DChatMessageRecord> records,
  ) async {
    return _withStore(roomId, (store) async {
      final keyCache = <int, Uint8List?>{};
      final messages = <ChatMessage>[];
      for (final record in records) {
        final message = await _chatMessageFromRecord(
          roomId,
          store,
          record,
          keyCache: keyCache,
        );
        if (message != null) {
          messages.add(message);
        }
      }
      return messages;
    });
  }

  Future<void> _importMessageRecord(
    String roomId,
    DChatMessageRecord record,
  ) async {
    final rawEvent = jsonDecode(record.rawEventJson) as Map<String, dynamic>;
    final event = NostrEvent.fromJson(rawEvent);
    if (!event.verify()) {
      throw Exception('Invalid distributed message signature');
    }
    final eventRoomId = _eventTagValue(event.tags, 'room');
    if (eventRoomId != roomId) {
      throw Exception('Message room mismatch for ${record.messageId}');
    }
    final eventId = event.id ?? event.calculateId();
    if (eventId != record.messageId) {
      throw Exception('Message id mismatch for ${record.messageId}');
    }
    final eventAuthorNpub = NostrCrypto.encodeNpub(event.pubkey);
    if (eventAuthorNpub != record.authorNpub) {
      throw Exception('Message author mismatch for ${record.messageId}');
    }

    final envelope = _decodeMessageEnvelope(event);
    final eventEpoch =
        int.tryParse(_eventTagValue(event.tags, 'epoch') ?? '') ??
        _intValue(envelope?['epoch']);
    if (eventEpoch != null && eventEpoch != record.epoch) {
      throw Exception('Message epoch mismatch for ${record.messageId}');
    }

    final eventScheme =
        _eventTagValue(event.tags, 'enc') ?? envelope?['enc']?.toString();
    if (record.encryptionScheme != null &&
        eventScheme != null &&
        record.encryptionScheme != eventScheme) {
      throw Exception(
        'Message encryption scheme mismatch for ${record.messageId}',
      );
    }

    final eventCiphertextSha1 =
        _eventTagValue(event.tags, 'ciphertext_sha1') ??
        envelope?['ciphertext_sha1']?.toString();
    final actualCiphertextSha1 = sha1.convert(record.ciphertext).toString();
    if (actualCiphertextSha1 != record.ciphertextSha1) {
      throw Exception(
        'Message ciphertext digest mismatch for ${record.messageId}',
      );
    }
    if (eventCiphertextSha1 != null &&
        eventCiphertextSha1 != record.ciphertextSha1) {
      throw Exception(
        'Signed ciphertext digest mismatch for ${record.messageId}',
      );
    }
    if (record.encryptionScheme == _epochEncryptionScheme) {
      final nonceBase64 = envelope?['nonce']?.toString();
      final recordNonce = record.nonce;
      if (recordNonce == null || nonceBase64 == null || nonceBase64.isEmpty) {
        throw Exception('Encrypted message is missing nonce metadata');
      }
      if (base64Encode(recordNonce) != nonceBase64) {
        throw Exception('Message nonce mismatch for ${record.messageId}');
      }
    }

    await _withStore(roomId, (store) async {
      if (await store.hasMessage(record.messageId)) {
        return;
      }
      final metadata = await store.loadMetadata();
      if (metadata == null) {
        throw Exception('Room not found: $roomId');
      }
      final normalized = DChatMessageRecord(
        messageId: record.messageId,
        epoch: record.epoch,
        lamport: await store.nextMessageLamport(),
        authorNpub: record.authorNpub,
        authoredAt: record.authoredAt,
        ciphertext: record.ciphertext,
        nonce: record.nonce,
        encryptionScheme: record.encryptionScheme,
        ciphertextSha1: record.ciphertextSha1,
        rawEventJson: record.rawEventJson,
        deletedAt: record.deletedAt,
      );
      await store.appendMessage(normalized);
    });
  }

  Future<ChatMessage?> _chatMessageFromRecord(
    String roomId,
    DChatRoomStore store,
    DChatMessageRecord record, {
    required Map<int, Uint8List?> keyCache,
  }) async {
    final rawEvent = jsonDecode(record.rawEventJson) as Map<String, dynamic>;
    final event = NostrEvent.fromJson(rawEvent);
    final content = await _decodeMessageContent(
      roomId,
      store,
      record,
      keyCache: keyCache,
    );
    if (content == null) {
      return null;
    }
    return ChatMessage(
      author:
          _eventTagValue(event.tags, 'callsign') ??
          NostrCrypto.encodeNpub(event.pubkey),
      timestamp: ChatFormat.epochToTimestamp(event.createdAt),
      content: content,
      metadata: {
        'npub': NostrCrypto.encodeNpub(event.pubkey),
        'created_at': event.createdAt.toString(),
        if (event.sig != null) 'signature': event.sig!,
        if (event.id != null) 'event_id': event.id!,
        if (record.encryptionScheme != null) 'enc': record.encryptionScheme!,
        'epoch': record.epoch.toString(),
      },
    );
  }

  Future<String?> _decodeMessageContent(
    String roomId,
    DChatRoomStore store,
    DChatMessageRecord record, {
    required Map<int, Uint8List?> keyCache,
  }) async {
    if (record.encryptionScheme == null || record.encryptionScheme == 'plain') {
      return _decodeUtf8(record.ciphertext);
    }

    if (record.encryptionScheme != _epochEncryptionScheme) {
      return null;
    }

    final nonce = record.nonce;
    if (nonce == null) {
      return null;
    }
    if (!keyCache.containsKey(record.epoch)) {
      keyCache[record.epoch] = await store.loadLocalEpochKey(record.epoch);
    }
    final epochKey = keyCache[record.epoch];
    if (epochKey == null) {
      return null;
    }
    try {
      final plaintext = BackupEncryption.decryptBytesWithSharedKey(
        ciphertext: record.ciphertext,
        nonce: nonce,
        sharedSecret: epochKey,
        info: _epochMessageInfo(roomId, record.epoch),
      );
      return _decodeUtf8(plaintext);
    } catch (_) {
      return null;
    }
  }

  String _decodeUtf8(Uint8List bytes) {
    try {
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return base64Encode(bytes);
    }
  }

  Map<String, dynamic>? _decodeMessageEnvelope(NostrEvent event) {
    if (event.content.trim().isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(event.content);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {
      // Legacy/plain fallback.
    }
    return null;
  }

  int? _intValue(Object? raw) {
    if (raw is int) {
      return raw;
    }
    if (raw is num) {
      return raw.toInt();
    }
    if (raw is String) {
      return int.tryParse(raw);
    }
    return null;
  }

  List<String> _activeEpochRecipients(ChatChannelConfig config) {
    final recipients = <String>{
      if (config.owner != null && config.owner!.isNotEmpty) config.owner!,
      ...config.admins,
      ...config.moderatorNpubs,
      ...config.members,
    }.where(config.canAccess).toList();
    recipients.sort();
    return recipients;
  }

  Future<Uint8List?> _loadLocalEpochKey(String roomId, int epoch) async {
    return _withStore(roomId, (store) async {
      if (!await store.exists()) {
        return null;
      }
      return store.loadLocalEpochKey(epoch);
    });
  }

  Future<DChatMemberRecord?> _findMemberRecord(
    DChatRoomStore store,
    String npub,
  ) async {
    final members = await store.listMembers();
    for (final member in members) {
      if (member.memberNpub == npub) {
        return member;
      }
    }
    return null;
  }

  Future<T> _withStore<T>(
    String roomId,
    Future<T> Function(DChatRoomStore store) action,
  ) async {
    final store = DChatRoomStore(profileStorage: storage, roomId: roomId);
    try {
      return await action(store);
    } finally {
      await store.close();
    }
  }
}

class _DChatRoomSnapshot {
  final DChatRoomMetadata metadata;
  final List<DChatMemberRecord> members;
  final List<DistributedChatControlEvent> controlEvents;

  const _DChatRoomSnapshot({
    required this.metadata,
    required this.members,
    required this.controlEvents,
  });
}

String? _eventTagValue(List<List<String>> tags, String key) {
  for (final tag in tags) {
    if (tag.isNotEmpty && tag.first == key && tag.length > 1) {
      return tag[1];
    }
  }
  return null;
}

String _epochMessageInfo(String roomId, int epoch) {
  return 'geogram-dchat-message:$roomId:$epoch';
}
