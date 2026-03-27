import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../models/chat_channel.dart';
import '../models/chat_message.dart';
import '../models/distributed_chat.dart';
import '../util/backup_encryption.dart';
import '../util/chat_format.dart';
import '../util/nostr_crypto.dart';
import '../util/nostr_event.dart';
import '../util/nostr_key_generator.dart';
import 'chat_service.dart';
import 'config_service.dart';
import 'profile_storage.dart';

typedef LoadDistributedChatRoomSecret = Future<String?> Function(String roomId);
typedef SaveDistributedChatRoomSecret =
    Future<void> Function(String roomId, String roomNsec);
typedef DeleteDistributedChatRoomSecret = Future<void> Function(String roomId);

/// Orchestrates distributed restricted chat rooms on top of [ChatService].
///
/// The room folder remains the durable source of truth. This service adds:
/// - room invite/admission capability handling
/// - signed control-log entries
/// - room-key distribution for moderators/admins
/// - peer-to-peer room synchronization for bootstrap and repair flows
///
/// It intentionally reuses [ChatService] for room configs, membership rules,
/// moderation, and per-day message storage instead of duplicating chat logic.
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

  String _controlLogPath(String roomId) => '$roomId/extra/dchat/control.jsonl';

  Future<T> _withChat<T>(Future<T> Function(ChatService chat) action) async {
    final chat = ChatService();
    chat.reset();
    chat.setStorage(storage);
    await chat.initializeApp(appPath, creatorNpub: profileNpub);
    return action(chat);
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
    return _withChat((chat) async => chat.getChannel(roomId));
  }

  Future<List<ChatMessage>> loadMessages(
    String roomId, {
    int limit = 1000,
  }) async {
    return _withChat((chat) async => chat.loadMessages(roomId, limit: limit));
  }

  Future<List<DistributedChatControlEvent>> loadControlEvents(
    String roomId,
  ) async {
    final content = await storage.readString(_controlLogPath(roomId));
    if (content == null || content.trim().isEmpty) {
      return const [];
    }

    final events = <DistributedChatControlEvent>[];
    for (final line in content.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      try {
        final json = jsonDecode(trimmed) as Map<String, dynamic>;
        events.add(DistributedChatControlEvent.fromJson(json));
      } catch (_) {
        // Skip malformed lines in a best-effort way.
      }
    }
    return events;
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

    final config = ChatChannelConfig(
      id: roomId,
      name: name,
      description: description,
      visibility: 'RESTRICTED',
      owner: profileNpub,
      admins: const [],
      moderatorNpubs: const [],
      members: [profileNpub],
      banned: const [],
      pendingApplicants: const [],
      dailyFiles: true,
      distributionMode: 'distributed',
      roomNpub: roomKeys.npub,
      roomState: 'active',
      joinPolicy: 'approval_required',
      seedPeerHints: seedPeerHints,
    );
    final channel = ChatChannel.group(
      id: roomId,
      name: name,
      participants: const [],
      description: description,
      config: config,
    );
    await _withChat((chat) async => chat.createChannel(channel));

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
        'daily_files': true,
        'join_policy': 'approval_required',
        if (seedPeerHints.isNotEmpty) 'seed_peer_hints': seedPeerHints,
      },
    );
    await _importControlEvent(created);

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
    return _emitMembershipChange(
      roomId: roomId,
      targetNpub: targetNpub,
      type: DistributedChatControlType.memberRemoved,
    );
  }

  Future<DistributedChatControlEvent> banMember(
    String roomId,
    String targetNpub,
  ) async {
    return _emitMembershipChange(
      roomId: roomId,
      targetNpub: targetNpub,
      type: DistributedChatControlType.memberBanned,
    );
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
    final config = await _requireDistributedConfig(roomId);
    if (!config.canWrite(profileNpub)) {
      throw PermissionDeniedException('You cannot send messages to this room');
    }

    final privateKeyHex = NostrCrypto.decodeNsec(profileNsec!);
    final pubkeyHex = NostrCrypto.derivePublicKey(privateKeyHex);
    final messageEvent = NostrEvent.textNote(
      pubkeyHex: pubkeyHex,
      content: content,
      tags: [
        ['t', 'chat'],
        ['room', roomId],
        ['callsign', profileCallsign],
      ],
    );
    messageEvent.signWithNsec(profileNsec!);

    final eventDateTime = DateTime.fromMillisecondsSinceEpoch(
      messageEvent.createdAt * 1000,
      isUtc: true,
    ).toLocal();
    final message = ChatMessage(
      author: profileCallsign,
      timestamp: ChatFormat.formatTimestamp(eventDateTime),
      content: content,
      metadata: {
        ...?metadata,
        'npub': profileNpub,
        'created_at': messageEvent.createdAt.toString(),
        if (messageEvent.sig != null) 'signature': messageEvent.sig!,
        if (messageEvent.id != null) 'event_id': messageEvent.id!,
      },
    );
    await _withChat((chat) async => chat.saveMessage(roomId, message));
    return message;
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

    final remoteMessages = await peer.loadMessages(roomId, limit: 100000);
    final localMessages = await loadMessages(roomId, limit: 100000);
    final existingIds = localMessages.map(_messageIdentity).toSet();

    for (final message in remoteMessages) {
      if (!hasCurrentAccess &&
          accessEnd != null &&
          !message.dateTime.isBefore(accessEnd)) {
        continue;
      }
      final id = _messageIdentity(message);
      if (!existingIds.add(id)) {
        continue;
      }
      await _withChat((chat) async => chat.saveMessage(roomId, message));
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
    if (existing != null) {
      return;
    }

    final config = ChatChannelConfig(
      id: invite.roomId,
      name: invite.roomName,
      description: invite.roomDescription,
      visibility: 'RESTRICTED',
      owner: invite.ownerNpub,
      admins: const [],
      moderatorNpubs: const [],
      members: [invite.ownerNpub],
      banned: const [],
      pendingApplicants: const [],
      dailyFiles: true,
      distributionMode: invite.distributionMode,
      roomNpub: invite.roomNpub,
      roomState: 'active',
      joinPolicy: invite.joinPolicy,
      seedPeerHints: invite.seedPeerHints,
    );
    final room = ChatChannel.group(
      id: invite.roomId,
      name: invite.roomName,
      participants: const [],
      description: invite.roomDescription,
      config: config,
    );
    await _withChat((chat) async => chat.createChannel(room));
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

  Future<void> _importControlEvent(DistributedChatControlEvent event) async {
    if (!event.verify()) {
      throw Exception('Invalid distributed control event signature');
    }

    final eventId = event.event.id;
    final existingIds = await _loadControlEventIds(event.roomId);
    if (eventId != null && existingIds.contains(eventId)) {
      return;
    }

    await _applyControlEvent(event);
    await _appendControlEvent(event.roomId, event);
  }

  Future<void> _appendControlEvent(
    String roomId,
    DistributedChatControlEvent event,
  ) async {
    final path = _controlLogPath(roomId);
    final existing = await storage.readString(path);
    final line = jsonEncode(event.toJson());
    final newContent = existing == null || existing.trim().isEmpty
        ? line
        : '$existing\n$line';
    await storage.writeString(path, newContent);
  }

  Future<Set<String>> _loadControlEventIds(String roomId) async {
    final events = await loadControlEvents(roomId);
    return {
      for (final event in events)
        if (event.event.id != null) event.event.id!,
    };
  }

  Future<void> _applyControlEvent(DistributedChatControlEvent event) async {
    switch (event.type) {
      case DistributedChatControlType.roomCreated:
        await _applyRoomCreated(event);
        break;
      case DistributedChatControlType.joinRequested:
        await _withChat((chat) async {
          final room = chat.getChannel(event.roomId);
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
          await chat.applyForMembership(
            event.roomId,
            applicantNpub,
            (event.payload['callsign'] as String?) ?? event.actorCallsign,
            event.payload['message'] as String?,
          );
        });
        break;
      case DistributedChatControlType.joinApproved:
        await _applyJoinApproved(event);
        break;
      case DistributedChatControlType.joinRejected:
        await _withChat((chat) async {
          final room = chat.getChannel(event.roomId);
          final config = room?.config;
          final applicantNpub = event.targetNpub;
          if (room == null || config == null || applicantNpub == null) {
            return;
          }
          if (!config.hasApplied(applicantNpub)) {
            return;
          }
          await chat.rejectApplication(
            event.roomId,
            event.actorNpub,
            applicantNpub,
          );
        });
        break;
      case DistributedChatControlType.roomKeyShared:
        await _applyRoomKeyShared(event);
        break;
      case DistributedChatControlType.memberRemoved:
        await _withChat((chat) async {
          final room = chat.getChannel(event.roomId);
          final config = room?.config;
          final targetNpub = event.targetNpub;
          if (room == null || config == null || targetNpub == null) {
            return;
          }
          if (!config.isMember(targetNpub)) {
            return;
          }
          await chat.removeMember(event.roomId, event.actorNpub, targetNpub);
        });
        break;
      case DistributedChatControlType.memberBanned:
        await _withChat((chat) async {
          final room = chat.getChannel(event.roomId);
          final config = room?.config;
          final targetNpub = event.targetNpub;
          if (room == null || config == null || targetNpub == null) {
            return;
          }
          if (config.isBanned(targetNpub)) {
            return;
          }
          await chat.banMember(event.roomId, event.actorNpub, targetNpub);
        });
        break;
      case DistributedChatControlType.memberUnbanned:
        await _withChat((chat) async {
          final room = chat.getChannel(event.roomId);
          final config = room?.config;
          final targetNpub = event.targetNpub;
          if (room == null || config == null || targetNpub == null) {
            return;
          }
          if (!config.isBanned(targetNpub)) {
            return;
          }
          await chat.unbanMember(event.roomId, event.actorNpub, targetNpub);
        });
        break;
      case DistributedChatControlType.moderatorGranted:
        await _withChat((chat) async {
          final room = chat.getChannel(event.roomId);
          final config = room?.config;
          final targetNpub = event.targetNpub;
          if (room == null || config == null || targetNpub == null) {
            return;
          }
          if (config.isModerator(targetNpub)) {
            return;
          }
          await chat.promoteToModerator(
            event.roomId,
            event.actorNpub,
            targetNpub,
          );
        });
        break;
      case DistributedChatControlType.moderatorRevoked:
        await _withChat((chat) async {
          final room = chat.getChannel(event.roomId);
          final config = room?.config;
          final targetNpub = event.targetNpub;
          if (room == null || config == null || targetNpub == null) {
            return;
          }
          if (!config.moderatorNpubs.contains(targetNpub)) {
            return;
          }
          await chat.demote(event.roomId, event.actorNpub, targetNpub);
        });
        break;
      case DistributedChatControlType.adminGranted:
        await _withChat((chat) async {
          final room = chat.getChannel(event.roomId);
          final config = room?.config;
          final targetNpub = event.targetNpub;
          if (room == null || config == null || targetNpub == null) {
            return;
          }
          if (config.isAdmin(targetNpub)) {
            return;
          }
          await chat.promoteToAdmin(event.roomId, event.actorNpub, targetNpub);
        });
        break;
      case DistributedChatControlType.adminRevoked:
        await _withChat((chat) async {
          final room = chat.getChannel(event.roomId);
          final config = room?.config;
          final targetNpub = event.targetNpub;
          if (room == null || config == null || targetNpub == null) {
            return;
          }
          if (!config.admins.contains(targetNpub)) {
            return;
          }
          await chat.demote(event.roomId, event.actorNpub, targetNpub);
        });
        break;
      case DistributedChatControlType.roomPaused:
      case DistributedChatControlType.roomResumed:
      case DistributedChatControlType.roomClosed:
        await _withChat((chat) async {
          final room = chat.getChannel(event.roomId);
          final config = room?.config;
          if (room == null || config == null) {
            return;
          }
          if (!config.isAdmin(event.actorNpub)) {
            throw PermissionDeniedException(
              'Only admins and above can change room state',
            );
          }
          final updatedConfig = config.copyWith(
            roomState: event.state ?? config.roomState,
          );
          await chat.updateChannel(room.copyWith(config: updatedConfig));
        });
        break;
      case DistributedChatControlType.messageDeleted:
        await _withChat((chat) async {
          final timestamp = event.messageTimestamp;
          final authorCallsign = event.messageAuthor;
          if (timestamp == null || authorCallsign == null) {
            return;
          }
          try {
            await chat.deleteMessageByTimestamp(
              channelId: event.roomId,
              timestamp: timestamp,
              authorCallsign: authorCallsign,
              actorNpub: event.actorNpub,
            );
          } catch (_) {
            // Deletion is best-effort during replay.
          }
        });
        break;
    }
  }

  Future<void> _applyRoomCreated(DistributedChatControlEvent event) async {
    final existing = await getRoom(event.roomId);
    final ownerNpub = event.payload['owner_npub'] as String? ?? event.actorNpub;
    final config = ChatChannelConfig(
      id: event.roomId,
      name: event.payload['name'] as String? ?? event.roomId,
      description: event.payload['description'] as String?,
      visibility: 'RESTRICTED',
      owner: ownerNpub,
      admins: const [],
      moderatorNpubs: const [],
      members: [ownerNpub],
      banned: const [],
      pendingApplicants: const [],
      dailyFiles: (event.payload['daily_files'] as bool?) ?? true,
      distributionMode:
          event.payload['distribution_mode'] as String? ?? 'distributed',
      roomNpub: event.payload['room_npub'] as String?,
      roomState: 'active',
      joinPolicy:
          event.payload['join_policy'] as String? ?? 'approval_required',
      seedPeerHints: List<String>.from(
        event.payload['seed_peer_hints'] as List? ?? const [],
      ),
    );

    if (existing == null) {
      final room = ChatChannel.group(
        id: event.roomId,
        name: config.name,
        participants: const [],
        description: config.description,
        config: config,
      );
      await _withChat((chat) async => chat.createChannel(room));
      return;
    }

    final existingConfig = existing.config;
    final mergedConfig =
        existingConfig?.copyWith(
          name: config.name,
          description: config.description,
          visibility: 'RESTRICTED',
          owner: config.owner,
          members: existingConfig.members.contains(ownerNpub)
              ? existingConfig.members
              : [...existingConfig.members, ownerNpub],
          dailyFiles: config.dailyFiles,
          distributionMode: config.distributionMode,
          roomNpub: config.roomNpub,
          roomState: config.roomState,
          joinPolicy: config.joinPolicy,
          seedPeerHints: {
            ...existingConfig.seedPeerHints,
            ...config.seedPeerHints,
          }.toList(),
        ) ??
        config;

    await _withChat((chat) async {
      await chat.updateChannel(
        existing.copyWith(
          name: config.name,
          description: config.description,
          config: mergedConfig,
        ),
      );
    });
  }

  Future<void> _applyJoinApproved(DistributedChatControlEvent event) async {
    final room = await _requireRoom(event.roomId);
    final config = room.config;
    final targetNpub = event.targetNpub;
    if (config == null || targetNpub == null) {
      return;
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

    await _withChat((chat) async {
      final current = chat.getChannel(event.roomId);
      final currentConfig = current?.config;
      if (current == null || currentConfig == null) {
        return;
      }

      if (currentConfig.hasApplied(targetNpub)) {
        await chat.approveApplication(
          event.roomId,
          event.actorNpub,
          targetNpub,
        );
      } else if (!currentConfig.isMember(targetNpub) &&
          !currentConfig.isBanned(targetNpub)) {
        await chat.addMember(event.roomId, event.actorNpub, targetNpub);
      }
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

  String _messageIdentity(ChatMessage message) {
    final eventId = message.getMeta('event_id');
    if (eventId != null && eventId.isNotEmpty) {
      return 'event:$eventId';
    }
    final signature = message.signature;
    if (signature != null && signature.isNotEmpty) {
      return 'sig:$signature';
    }
    return '${message.timestamp}|${message.author}|${message.content}';
  }
}
