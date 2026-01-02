/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import '../models/chat_channel.dart';
import '../models/group_member.dart';
import 'groups_service.dart';

/// Service for resolving group membership dynamically for chat rooms
class GroupMembershipResolver {
  static final GroupMembershipResolver _instance =
      GroupMembershipResolver._internal();
  factory GroupMembershipResolver() => _instance;
  GroupMembershipResolver._internal();

  /// Check if npub has access to a chat room with dynamic group membership
  Future<bool> canAccess(
    ChatChannelConfig config,
    String? npub,
    GroupsService groupsService,
  ) async {
    if (npub == null) return false;

    // If banned, never allow access
    if (config.isBanned(npub)) return false;

    // If not using dynamic membership, use static check
    if (!config.usesDynamicMembership) {
      return config.canAccess(npub);
    }

    // Dynamic membership: check group
    final group = await groupsService.loadGroup(config.groupId!);
    if (group == null) return false;

    return group.isMember(npub);
  }

  /// Check if npub is admin in a chat room with dynamic group membership
  Future<bool> isAdmin(
    ChatChannelConfig config,
    String? npub,
    GroupsService groupsService,
  ) async {
    if (npub == null) return false;

    // Static check first
    if (config.isOwner(npub) || config.isAdmin(npub)) return true;

    // If not using dynamic membership, return false
    if (!config.usesDynamicMembership) return false;

    // Dynamic membership: check group
    final group = await groupsService.loadGroup(config.groupId!);
    if (group == null) return false;

    return group.isAdmin(npub);
  }

  /// Check if npub is moderator in a chat room with dynamic group membership
  Future<bool> isModerator(
    ChatChannelConfig config,
    String? npub,
    GroupsService groupsService,
  ) async {
    if (npub == null) return false;

    // Static check first
    if (config.isModerator(npub)) return true;

    // If not using dynamic membership, return false
    if (!config.usesDynamicMembership) return false;

    // Dynamic membership: check group
    final group = await groupsService.loadGroup(config.groupId!);
    if (group == null) return false;

    return group.isModerator(npub);
  }

  /// Resolve current members for a chat channel with dynamic group membership
  /// Returns the effective ChatChannelConfig with resolved members
  Future<ChatChannelConfig?> resolveMembers(
    ChatChannelConfig config,
    GroupsService groupsService,
  ) async {
    if (!config.usesDynamicMembership) {
      return config; // No dynamic membership, return as-is
    }

    final group = await groupsService.loadGroup(config.groupId!);
    if (group == null) {
      return null; // Group no longer exists
    }

    // Build membership lists from group
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

    // Return config with resolved members (but keep groupId for future lookups)
    return config.copyWith(
      admins: adminSet.toList(),
      moderatorNpubs: moderatorSet.toList(),
      members: [...adminSet, ...moderatorSet, ...memberSet],
    );
  }
}
