/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';

import '../models/group.dart';
import '../models/group_member.dart';
import 'profile_storage.dart';

/// Resolves access to shared groups from the active station profile.
class StationGroupAccessService {
  final ProfileStorage rootStorage;
  final void Function(String level, String message)? log;

  DateTime? _lastGroupAppScanAt;
  List<String> _groupAppRoots = const [];

  StationGroupAccessService({required this.rootStorage, this.log});

  Future<bool> hasAnyMatchingGroup(
    String npub,
    Iterable<String> groupIds,
  ) async {
    final normalizedNpub = npub.trim();
    if (normalizedNpub.isEmpty) {
      return false;
    }

    final groupNames = groupIds
        .map((groupId) => groupId.trim())
        .where((groupId) => groupId.isNotEmpty)
        .toSet();
    if (groupNames.isEmpty) {
      return false;
    }

    final appRoots = await _findGroupsAppRoots();
    for (final appRoot in appRoots) {
      final scopedStorage = ScopedProfileStorage(rootStorage, appRoot);
      for (final groupId in groupNames) {
        final group = await _loadGroup(scopedStorage, groupId);
        if (group?.isMember(normalizedNpub) == true) {
          return true;
        }
      }
    }

    return false;
  }

  Future<List<String>> _findGroupsAppRoots() async {
    final now = DateTime.now();
    if (_lastGroupAppScanAt != null &&
        now.difference(_lastGroupAppScanAt!) < const Duration(seconds: 30)) {
      return _groupAppRoots;
    }

    final roots = <String>[];
    final entries = await rootStorage.listDirectory('');
    for (final entry in entries) {
      if (!entry.isDirectory) {
        continue;
      }

      final appJs = await rootStorage.readString('${entry.path}/app.js');
      if (appJs == null) {
        continue;
      }

      final appType = _readAppType(appJs);
      if (appType == 'groups') {
        roots.add(entry.path);
      }
    }

    _groupAppRoots = roots;
    _lastGroupAppScanAt = now;
    return roots;
  }

  Future<Group?> _loadGroup(ProfileStorage storage, String groupId) async {
    final groupContent = await storage.readString('$groupId/group.json');
    if (groupContent == null) {
      return null;
    }

    try {
      final groupJson = jsonDecode(groupContent) as Map<String, dynamic>;
      final members = await _loadMembers(storage, groupId);
      return Group.fromJson(groupJson, groupId).copyWith(members: members);
    } catch (e) {
      _log('WARN', 'Failed to load group $groupId: $e');
      return null;
    }
  }

  Future<List<GroupMember>> _loadMembers(
    ProfileStorage storage,
    String groupId,
  ) async {
    final membersContent = await storage.readString('$groupId/members.txt');
    if (membersContent == null) {
      return const [];
    }

    final lines = membersContent.split('\n');
    final members = <GroupMember>[];
    var index = 0;

    while (index < lines.length) {
      final line = lines[index].trim();
      if (line.isEmpty || line.startsWith('#')) {
        index++;
        continue;
      }

      if (line.startsWith('ADMIN:') ||
          line.startsWith('MODERATOR:') ||
          line.startsWith('CONTRIBUTOR:') ||
          line.startsWith('GUEST:')) {
        final member = GroupMember.fromMembersTxt(lines, index);
        if (member != null) {
          members.add(member);
        }
        index++;
        while (index < lines.length &&
            (lines[index].startsWith('-->') || lines[index].trim().isEmpty)) {
          index++;
        }
        continue;
      }

      index++;
    }

    return members;
  }

  String? _readAppType(String appJs) {
    try {
      if (appJs.trimLeft().startsWith('{')) {
        final raw = jsonDecode(appJs) as Map<String, dynamic>;
        final directType = raw['type']?.toString().toLowerCase();
        if (directType != null && directType.isNotEmpty) {
          return directType;
        }
      }

      final jsonStart = appJs.indexOf('{');
      final jsonEnd = appJs.lastIndexOf('};');
      if (jsonStart == -1 || jsonEnd == -1 || jsonEnd <= jsonStart) {
        return null;
      }

      final decoded =
          jsonDecode(appJs.substring(jsonStart, jsonEnd + 1))
              as Map<String, dynamic>;
      final app = decoded['app'] as Map<String, dynamic>?;
      return app?['type']?.toString().toLowerCase();
    } catch (_) {
      return null;
    }
  }

  void _log(String level, String message) {
    log?.call(level, message);
  }
}
