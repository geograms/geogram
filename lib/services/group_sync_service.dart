/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import '../models/group.dart';
import '../models/group_member.dart';
import '../models/chat_channel.dart';
import '../models/profile.dart';
import '../services/groups_service.dart';
import '../services/devices_service.dart';
import '../services/chat_service.dart';
import '../services/collection_service.dart';
import '../services/profile_service.dart';
import '../util/group_utils.dart';
import '../util/nostr_key_generator.dart';
import 'log_service.dart';

/// Sync group data with device folders and chat channels.
class GroupSyncService {
  static final GroupSyncService _instance = GroupSyncService._internal();
  factory GroupSyncService() => _instance;
  GroupSyncService._internal();

  Future<String?> findCollectionPathByType(String type) async {
    try {
      final collections = await CollectionService().loadCollections();
      for (final collection in collections) {
        if (collection.type == type && collection.storagePath != null) {
          return collection.storagePath;
        }
      }
    } catch (e) {
      LogService().log('GroupSyncService: Failed to find $type collection: $e');
    }
    return null;
  }

  Future<void> syncGroupsCollection({
    required String groupsCollectionPath,
    String? chatCollectionPath,
    bool includeDeviceFolders = true,
    bool includeChatChannels = true,
  }) async {
    final groupsService = GroupsService();
    await groupsService.initializeCollection(groupsCollectionPath);

    if (includeDeviceFolders) {
      await _syncDeviceFolders(groupsService);
      await _syncGroupsToDeviceFolders(groupsService);
    }

    if (includeChatChannels) {
      final resolvedChatPath =
          chatCollectionPath ?? await findCollectionPathByType('chat');
      if (resolvedChatPath != null) {
        await _syncChatChannels(groupsService, resolvedChatPath);
      }
    }
  }

  Future<void> _syncDeviceFolders(GroupsService groupsService) async {
    final devicesService = DevicesService();
    final profile = ProfileService().getProfile();
    final folders = devicesService.getFolders();

    for (final folder in folders) {

      final groupName = folder.id;
      var group = await groupsService.loadGroup(groupName);

      if (group == null) {
        await groupsService.createGroup(
          groupName: groupName,
          title: folder.name,
          description: '',
          type: GroupType.association,
          creatorNpub: profile.npub,
          creatorCallsign: profile.callsign,
        );
        group = await groupsService.loadGroup(groupName);
      }

      if (group == null) {
        continue;
      }

      if (group.title != folder.name) {
        final updated = group.copyWith(
          title: folder.name,
          updated: GroupUtils.formatTimestamp(DateTime.now()),
        );
        await groupsService.saveGroup(updated);
        group = updated;
      }

      final devices = devicesService.getDevicesInFolder(folder.id);
      final membersToMerge = <GroupMember>[];

      for (final device in devices) {
        final npub = device.npub;
        if (npub == null || npub.isEmpty) {
          continue;
        }

        membersToMerge.add(
          GroupMember(
            callsign: device.callsign,
            npub: npub,
            role: GroupRole.guest,
            joined: GroupUtils.formatTimestamp(DateTime.now()),
          ),
        );
      }

      await _mergeMembers(groupsService, group, membersToMerge);
    }
  }

  Future<void> _syncGroupsToDeviceFolders(GroupsService groupsService) async {
    final devicesService = DevicesService();
    final profile = ProfileService().getProfile();
    final groups = await groupsService.loadGroups();

    for (final group in groups) {
      if (!group.isActive) {
        continue;
      }

      if (!group.isMember(profile.npub)) {
        continue;
      }

      if (group.name == DevicesService.defaultFolderId) {
        continue;
      }

      final folderName =
          group.title.isNotEmpty ? group.title : group.name;
      devicesService.ensureFolder(group.name, folderName);
    }
  }

  Future<void> _syncChatChannels(
    GroupsService groupsService,
    String chatCollectionPath,
  ) async {
    final chatService = ChatService();
    if (chatService.collectionPath != chatCollectionPath) {
      await chatService.initializeCollection(chatCollectionPath);
    } else {
      await chatService.refreshChannels();
    }

    final profile = ProfileService().getProfile();
    final participants = chatService.participants;
    final devices = DevicesService().getAllDevices();

    for (final channel in chatService.channels) {
      if (!channel.isGroup || channel.isMain) {
        continue;
      }

      final groupName = channel.id;
      var group = await groupsService.loadGroup(groupName);

      if (group == null) {
        await groupsService.createGroup(
          groupName: groupName,
          title: channel.name,
          description: channel.description ?? '',
          type: GroupType.association,
          creatorNpub: profile.npub,
          creatorCallsign: profile.callsign,
        );
        group = await groupsService.loadGroup(groupName);
      }

      if (group == null) {
        continue;
      }

      if (group.title.isEmpty || group.title == group.name) {
        final updated = group.copyWith(
          title: channel.name,
          description: group.description.isEmpty
              ? (channel.description ?? '')
              : group.description,
          updated: GroupUtils.formatTimestamp(DateTime.now()),
        );
        await groupsService.saveGroup(updated);
        group = updated;
      }

      if (channel.config != null) {
        final membersToMerge = _membersFromChatConfig(
          channel.config!,
          participants,
          devices,
          profile,
        );
        await _mergeMembers(groupsService, group, membersToMerge);
      }
    }

    await _syncGroupsToChatChannels(groupsService, chatService);
  }

  Future<void> _syncGroupsToChatChannels(
    GroupsService groupsService,
    ChatService chatService,
  ) async {
    final groups = await groupsService.loadGroups();

    for (final group in groups) {
      if (!group.isActive || !group.isFeatureEnabled('chat')) {
        continue;
      }

      if (group.name == DevicesService.defaultFolderId) {
        continue;
      }

      final existing = chatService.getChannel(group.name);
      if (existing != null && (!existing.isGroup || existing.isMain)) {
        continue;
      }
      final config = _buildChatConfigFromGroup(group, existing?.config);
      final updatedName = group.title.isNotEmpty ? group.title : group.name;
      final updatedDescription =
          group.description.isNotEmpty ? group.description : existing?.description;

      if (existing == null) {
        final channel = ChatChannel(
          id: group.name,
          type: ChatChannelType.group,
          name: updatedName,
          folder: group.name,
          participants: const [],
          description: updatedDescription,
          created: DateTime.now(),
          config: config,
        );
        await chatService.createChannel(channel);
      } else {
        final updatedChannel = existing.copyWith(
          name: updatedName,
          description: updatedDescription,
          config: config,
        );
        await chatService.updateChannel(updatedChannel);
      }
    }
  }

  Future<void> _mergeMembers(
    GroupsService groupsService,
    Group group,
    List<GroupMember> incomingMembers,
  ) async {
    if (incomingMembers.isEmpty) {
      return;
    }

    final updatedMembers = List<GroupMember>.from(group.members);
    var changed = false;

    for (final incoming in incomingMembers) {
      final index = updatedMembers.indexWhere((m) => m.npub == incoming.npub);
      if (index == -1) {
        updatedMembers.add(incoming);
        changed = true;
        continue;
      }

      final existing = updatedMembers[index];
      final mergedRole = _higherRole(existing.role, incoming.role);
      final mergedCallsign = existing.callsign.isNotEmpty
          ? existing.callsign
          : incoming.callsign;

      if (mergedRole != existing.role ||
          mergedCallsign != existing.callsign) {
        updatedMembers[index] = existing.copyWith(
          role: mergedRole,
          callsign: mergedCallsign,
        );
        changed = true;
      }
    }

    if (changed) {
      await groupsService.saveMembers(group.name, updatedMembers);
    }
  }

  List<GroupMember> _membersFromChatConfig(
    ChatChannelConfig config,
    Map<String, String> participants,
    List<RemoteDevice> devices,
    Profile profile,
  ) {
    final members = <GroupMember>[];
    final roleMap = <String, GroupRole>{};

    void assignRole(String npub, GroupRole role) {
      final existingRole = roleMap[npub];
      if (existingRole == null || _higherRole(role, existingRole) == role) {
        roleMap[npub] = role;
      }
    }

    if (config.owner != null && config.owner!.isNotEmpty) {
      assignRole(config.owner!, GroupRole.admin);
    }

    for (final npub in config.admins) {
      assignRole(npub, GroupRole.admin);
    }
    for (final npub in config.moderatorNpubs) {
      assignRole(npub, GroupRole.moderator);
    }
    for (final npub in config.members) {
      assignRole(npub, GroupRole.contributor);
    }

    for (final entry in roleMap.entries) {
      final callsign = _resolveCallsign(entry.key, participants, devices, profile);
      members.add(
        GroupMember(
          callsign: callsign,
          npub: entry.key,
          role: entry.value,
          joined: GroupUtils.formatTimestamp(DateTime.now()),
        ),
      );
    }

    return members;
  }

  String _resolveCallsign(
    String npub,
    Map<String, String> participants,
    List<RemoteDevice> devices,
    Profile profile,
  ) {
    if (profile.npub == npub && profile.callsign.isNotEmpty) {
      return profile.callsign;
    }

    for (final entry in participants.entries) {
      if (entry.value == npub && entry.key.isNotEmpty) {
        return entry.key;
      }
    }

    for (final device in devices) {
      if (device.npub == npub && device.callsign.isNotEmpty) {
        return device.callsign;
      }
    }

    try {
      return NostrKeyGenerator.deriveCallsign(npub);
    } catch (_) {
      return npub;
    }
  }

  ChatChannelConfig _buildChatConfigFromGroup(
    Group group,
    ChatChannelConfig? baseConfig,
  ) {
    final adminSet = <String>{};
    final moderatorSet = <String>{};
    final memberSet = <String>{};

    for (final member in group.members) {
      switch (member.role) {
        case GroupRole.admin:
          adminSet.add(member.npub);
          break;
        case GroupRole.moderator:
          moderatorSet.add(member.npub);
          break;
        case GroupRole.contributor:
        case GroupRole.guest:
          memberSet.add(member.npub);
          break;
      }
    }

    final owner = baseConfig?.owner ??
        (adminSet.isNotEmpty ? adminSet.first : null);

    return ChatChannelConfig(
      id: group.name,
      name: group.title.isNotEmpty ? group.title : group.name,
      description: group.description.isNotEmpty ? group.description : baseConfig?.description,
      visibility: baseConfig?.visibility ?? 'RESTRICTED',
      readonly: baseConfig?.readonly ?? false,
      fileUpload: baseConfig?.fileUpload ?? true,
      filesPerPost: baseConfig?.filesPerPost ?? 3,
      maxFileSize: baseConfig?.maxFileSize ?? 10,
      maxSizeText: baseConfig?.maxSizeText ?? 500,
      moderators: baseConfig?.moderators ?? const [],
      owner: owner,
      admins: adminSet.toList(),
      moderatorNpubs: moderatorSet.toList(),
      members: memberSet.toList(),
      banned: baseConfig?.banned ?? const [],
      pendingApplicants: baseConfig?.pendingApplicants ?? const [],
    );
  }

  GroupRole _higherRole(GroupRole a, GroupRole b) {
    return _roleRank(a) >= _roleRank(b) ? a : b;
  }

  int _roleRank(GroupRole role) {
    switch (role) {
      case GroupRole.admin:
        return 3;
      case GroupRole.moderator:
        return 2;
      case GroupRole.contributor:
        return 1;
      case GroupRole.guest:
        return 0;
    }
  }

  /// Verify and create missing chat rooms for all device folders with chat enabled.
  /// Call this at app startup and when chat is enabled for a folder.
  Future<void> ensureFolderChatRooms() async {
    final chatCollectionPath = await findCollectionPathByType('chat');
    final groupsCollectionPath = await findCollectionPathByType('groups');

    if (chatCollectionPath == null) {
      LogService().log('GroupSyncService: Cannot ensure chat rooms - chat collection not configured');
      return;
    }

    final chatService = ChatService();
    if (chatService.collectionPath != chatCollectionPath) {
      await chatService.initializeCollection(chatCollectionPath);
    }

    GroupsService? groupsService;
    if (groupsCollectionPath != null) {
      groupsService = GroupsService();
      await groupsService.initializeCollection(groupsCollectionPath);
    }

    final devicesService = DevicesService();
    final profile = ProfileService().getProfile();
    final folders = devicesService.getFolders();

    for (final folder in folders) {
      // Skip default folder and folders with chat disabled
      if (folder.isDefault || !folder.chatEnabled) continue;

      final existingChannel = chatService.getChannel(folder.id);
      if (existingChannel == null) {
        LogService().log('GroupSyncService: Creating missing chat room for folder ${folder.name}');

        try {
          await chatService.createGroupLinkedRoom(
            groupId: folder.id,
            name: folder.name,
            ownerNpub: profile.npub,
            description: 'Group chat for ${folder.name}',
          );
        } catch (e) {
          LogService().log('GroupSyncService: Failed to create chat room for ${folder.id}: $e');
        }
      } else if (existingChannel.config?.groupId == null) {
        // Update existing channel to use groupId for dynamic membership
        final updatedConfig = existingChannel.config?.copyWith(groupId: folder.id) ??
            ChatChannelConfig(
              id: folder.id,
              name: folder.name,
              groupId: folder.id,
            );
        final updatedChannel = existingChannel.copyWith(config: updatedConfig);
        await chatService.updateChannel(updatedChannel);
        LogService().log('GroupSyncService: Updated chat room ${folder.id} with groupId');
      }
    }
  }
}
