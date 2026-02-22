/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import '../models/group.dart';
import '../models/group_member.dart';
import '../models/group_area.dart';
import '../models/group_application.dart';
import '../models/reputation_entry.dart';
import '../models/station_node.dart';
import '../util/chat_format.dart';
import '../util/nostr_key_generator.dart';
import '../util/group_utils.dart';
import 'log_service.dart';
import 'profile_storage.dart';

/// Service for managing groups
///
/// IMPORTANT: All file operations go through the ProfileStorage abstraction.
/// Never use File() or Directory() directly in this service.
class GroupsService {
  static final GroupsService _instance = GroupsService._internal();
  factory GroupsService() => _instance;
  GroupsService._internal();

  /// Profile storage for file operations (encrypted or filesystem)
  /// MUST be set before using the service.
  late ProfileStorage _storage;

  final List<String> _admins = [];

  /// Whether using encrypted storage
  bool get useEncryptedStorage => _storage.isEncrypted;

  /// Set the profile storage for file operations
  /// MUST be called before initializeApp
  void setStorage(ProfileStorage storage) {
    _storage = storage;
  }

  /// Initialize groups service for a collection
  Future<void> initializeApp(String appPath, {String? creatorNpub}) async {
    LogService().log('GroupsService: Initializing with collection path: $appPath');

    // Load admins
    await _loadAdmins();

    LogService().log('GroupsService: Initialization complete');
  }

  /// Load collection admins from individual files
  Future<void> _loadAdmins() async {
    _admins.clear();

    if (!await _storage.exists('admins')) {
      await _loadAdminsLegacy();
      return;
    }

    try {
      final entries = await _storage.listDirectory('admins');
      for (var entry in entries) {
        if (!entry.isDirectory && entry.name.endsWith('.txt')) {
          final content = await _storage.readString(entry.path);
          if (content != null) {
            final lines = content.split('\n');
            for (var line in lines) {
              final trimmed = line.trim();
              if (trimmed.startsWith('npub: ')) {
                final npub = trimmed.substring(6).trim();
                if (npub.isNotEmpty) {
                  _admins.add(npub);
                }
                break;
              }
            }
          }
        }
      }
      LogService().log('GroupsService: Loaded ${_admins.length} admins from individual files');
    } catch (e) {
      LogService().log('GroupsService: Error loading admins: $e');
    }
  }

  /// Load admins from legacy admins.txt file
  Future<void> _loadAdminsLegacy() async {
    final content = await _storage.readString('admins.txt');
    if (content == null) return;

    try {
      final lines = content.split('\n');

      String? currentCallsign;
      for (int i = 0; i < lines.length; i++) {
        final line = lines[i].trim();

        // Skip comments and empty lines
        if (line.isEmpty || line.startsWith('#')) continue;

        // Check if line is a callsign (not metadata)
        if (!line.startsWith('-->')) {
          currentCallsign = line;
        } else if (line.startsWith('--> npub:') && currentCallsign != null) {
          final npub = line.substring(9).trim();
          if (npub.isNotEmpty) {
            _admins.add(npub);
          }
        }
      }

      LogService().log('GroupsService: Loaded ${_admins.length} admins from legacy file');
    } catch (e) {
      LogService().log('GroupsService: Error loading legacy admins: $e');
    }
  }

  /// Get collection admins
  List<String> getAdmins() => List.unmodifiable(_admins);

  /// Check if user is collection admin
  bool isAppAdmin(String npub) {
    return _admins.contains(npub);
  }

  /// Save admin to individual file
  Future<void> saveAdmin(String callsign, String npub, {String? signature}) async {
    final buffer = StringBuffer();
    buffer.writeln('# ADMIN: $callsign');
    buffer.writeln('npub: $npub');
    buffer.writeln('added: ${_formatTimestamp(DateTime.now())}');
    if (signature != null && signature.isNotEmpty) {
      buffer.writeln('signature: $signature');
    }
    final content = buffer.toString();

    if (!await _storage.exists('admins')) {
      await _storage.createDirectory('admins');
    }
    await _storage.writeString('admins/$callsign.txt', content);

    // Add to in-memory list
    if (!_admins.contains(npub)) {
      _admins.add(npub);
    }

    LogService().log('GroupsService: Saved admin $callsign');
  }

  /// Remove admin file
  Future<void> removeAdmin(String callsign, String npub) async {
    final relativePath = 'admins/$callsign.txt';
    if (await _storage.exists(relativePath)) {
      await _storage.delete(relativePath);
    }

    _admins.remove(npub);
    LogService().log('GroupsService: Removed admin $callsign');
  }

  /// Save moderator to individual file (group-specific)
  Future<void> saveModerator(String groupName, String callsign, String npub, {String? signature}) async {
    final buffer = StringBuffer();
    buffer.writeln('# MODERATOR: $callsign');
    buffer.writeln('npub: $npub');
    buffer.writeln('added: ${_formatTimestamp(DateTime.now())}');
    if (signature != null && signature.isNotEmpty) {
      buffer.writeln('signature: $signature');
    }
    final content = buffer.toString();

    final relativePath = '$groupName/moderators';
    if (!await _storage.exists(relativePath)) {
      await _storage.createDirectory(relativePath);
    }
    await _storage.writeString('$relativePath/$callsign.txt', content);

    LogService().log('GroupsService: Saved moderator $callsign for group $groupName');
  }

  /// Remove moderator file
  Future<void> removeModerator(String groupName, String callsign) async {
    final relativePath = '$groupName/moderators/$callsign.txt';
    if (await _storage.exists(relativePath)) {
      await _storage.delete(relativePath);
    }

    LogService().log('GroupsService: Removed moderator $callsign from group $groupName');
  }

  /// Load all groups
  Future<List<Group>> loadGroups() async {
    final groups = <Group>[];

    final entries = await _storage.listDirectory('');

    for (var entry in entries) {
      if (entry.isDirectory) {
        final groupName = entry.name;

        // Skip special directories
        if (groupName == 'extra' || groupName == 'admins' ||
            groupName == 'reputation' || groupName == 'sync' ||
            groupName == 'approvals' || groupName.startsWith('.')) continue;

        try {
          final group = await loadGroup(groupName);
          if (group != null) {
            groups.add(group);
          }
        } catch (e) {
          LogService().log('GroupsService: Error loading group $groupName: $e');
        }
      }
    }

    // Sort by title
    groups.sort((a, b) => a.title.compareTo(b.title));

    LogService().log('GroupsService: Loaded ${groups.length} groups');
    return groups;
  }

  /// Load single group by name
  Future<Group?> loadGroup(String groupName) async {
    if (!await _storage.exists(groupName)) return null;

    final content = await _storage.readString('$groupName/group.json');
    if (content == null) {
      LogService().log('GroupsService: group.json not found for $groupName');
      return null;
    }

    try {
      final json = jsonDecode(content) as Map<String, dynamic>;
      var group = Group.fromJson(json, groupName);

      // Load members
      final members = await loadMembers(groupName);
      group = group.copyWith(members: members);

      // Load areas
      final areas = await loadAreas(groupName);
      group = group.copyWith(areas: areas);

      // Load config
      final config = await loadConfig(groupName);
      if (config != null) {
        group = group.copyWith(config: config);
      }

      return group;
    } catch (e) {
      LogService().log('GroupsService: Error loading group $groupName: $e');
      return null;
    }
  }

  /// Load members for a group
  Future<List<GroupMember>> loadMembers(String groupName) async {
    final content = await _storage.readString('$groupName/members.txt');
    if (content == null) return [];

    try {
      final lines = content.split('\n');
      final members = <GroupMember>[];

      int i = 0;
      while (i < lines.length) {
        final line = lines[i].trim();

        // Skip empty lines and comments
        if (line.isEmpty || line.startsWith('#')) {
          i++;
          continue;
        }

        // Check if line starts a member entry
        if (line.startsWith('ADMIN:') ||
            line.startsWith('MODERATOR:') ||
            line.startsWith('CONTRIBUTOR:') ||
            line.startsWith('GUEST:')) {
          final member = GroupMember.fromMembersTxt(lines, i);
          if (member != null) {
            members.add(member);
          }

          // Skip past this member's metadata lines
          i++;
          while (i < lines.length && (lines[i].startsWith('-->') || lines[i].trim().isEmpty)) {
            i++;
          }
        } else {
          i++;
        }
      }

      LogService().log('GroupsService: Loaded ${members.length} members for $groupName');
      return members;
    } catch (e) {
      LogService().log('GroupsService: Error loading members for $groupName: $e');
      return [];
    }
  }

  /// Load areas for a group
  Future<List<GroupArea>> loadAreas(String groupName) async {
    final content = await _storage.readString('$groupName/areas.json');
    if (content == null) return [];

    try {
      final json = jsonDecode(content) as Map<String, dynamic>;
      final areasData = json['areas'] as List<dynamic>;

      final areas = areasData
          .map((data) => GroupArea.fromJson(data as Map<String, dynamic>))
          .toList();

      LogService().log('GroupsService: Loaded ${areas.length} areas for $groupName');
      return areas;
    } catch (e) {
      LogService().log('GroupsService: Error loading areas for $groupName: $e');
      return [];
    }
  }

  /// Load config for a group
  Future<Map<String, dynamic>?> loadConfig(String groupName) async {
    final content = await _storage.readString('$groupName/config.json');
    if (content == null) return null;

    try {
      return jsonDecode(content) as Map<String, dynamic>;
    } catch (e) {
      LogService().log('GroupsService: Error loading config for $groupName: $e');
      return null;
    }
  }

  /// Load applications for a group
  Future<List<GroupApplication>> loadApplications(
    String groupName, {
    ApplicationStatus? filterStatus,
  }) async {
    final applications = <GroupApplication>[];

    // Determine which subdirectories to scan
    final subdirs = <String>[];
    if (filterStatus == null) {
      subdirs.addAll(['pending', 'approved', 'rejected']);
    } else {
      subdirs.add(filterStatus.name);
    }

    for (var subdir in subdirs) {
      final dirPath = '$groupName/candidates/$subdir';
      if (!await _storage.exists(dirPath)) continue;

      final entries = await _storage.listDirectory(dirPath);
      for (var entry in entries) {
        if (!entry.isDirectory && entry.name.endsWith('_application.txt')) {
          try {
            final content = await _storage.readString(entry.path);
            if (content != null) {
              final application = GroupApplication.fromText(content, entry.name);
              applications.add(application);
            }
          } catch (e) {
            LogService().log('GroupsService: Error loading application ${entry.path}: $e');
          }
        }
      }
    }

    // Sort by application date (most recent first)
    applications.sort((a, b) => b.appliedDateTime.compareTo(a.appliedDateTime));

    LogService().log('GroupsService: Loaded ${applications.length} applications for $groupName');
    return applications;
  }

  /// Save group
  Future<void> saveGroup(Group group) async {
    final groupJson = const JsonEncoder.withIndent('  ').convert(group.toJson());

    if (!await _storage.exists(group.name)) {
      await _storage.createDirectory(group.name);
    }

    await _storage.writeString('${group.name}/group.json', groupJson);

    // Save members.txt
    await saveMembers(group.name, group.members);

    // Save areas.json
    await saveAreas(group.name, group.areas);

    // Save config.json
    if (group.config.isNotEmpty) {
      final configJson = const JsonEncoder.withIndent('  ').convert(group.config);
      await _storage.writeString('${group.name}/config.json', configJson);
    }

    LogService().log('GroupsService: Saved group ${group.name}');
  }

  /// Save members
  Future<void> saveMembers(String groupName, List<GroupMember> members) async {
    final buffer = StringBuffer();

    // Header (get from group data if available)
    final group = await loadGroup(groupName);
    if (group != null) {
      buffer.writeln('# GROUP: ${group.title}');
      buffer.writeln('# TYPE: ${group.type.toFileString()}');
      if (group.appType != null) {
        buffer.writeln('# COLLECTION: ${group.appType}');
      }
      buffer.writeln('# Created: ${group.created}');
      buffer.writeln();
    }

    // Write members by role
    final admins = members.where((m) => m.role == GroupRole.admin).toList();
    final moderators = members.where((m) => m.role == GroupRole.moderator).toList();
    final contributors = members.where((m) => m.role == GroupRole.contributor).toList();
    final guests = members.where((m) => m.role == GroupRole.guest).toList();

    for (var member in [...admins, ...moderators, ...contributors, ...guests]) {
      buffer.write(member.exportAsText());
      buffer.writeln();
    }

    await _storage.writeString('$groupName/members.txt', buffer.toString());
    LogService().log('GroupsService: Saved ${members.length} members for $groupName');
  }

  /// Save areas
  Future<void> saveAreas(String groupName, List<GroupArea> areas) async {
    final json = {
      'areas': areas.map((a) => a.toJson()).toList(),
      'updated': _formatTimestamp(DateTime.now()),
    };
    final content = const JsonEncoder.withIndent('  ').convert(json);

    await _storage.writeString('$groupName/areas.json', content);

    LogService().log('GroupsService: Saved ${areas.length} areas for $groupName');
  }

  /// Save application
  Future<void> saveApplication(String groupName, GroupApplication application) async {
    final subdir = application.status.name;
    final content = application.exportAsText();

    final relativeDirPath = '$groupName/candidates/$subdir';
    if (!await _storage.exists(relativeDirPath)) {
      await _storage.createDirectory(relativeDirPath);
    }
    await _storage.writeString('$relativeDirPath/${application.filename}', content);

    LogService().log('GroupsService: Saved application ${application.filename} to $subdir');
  }

  /// Move application to different status folder
  Future<void> moveApplication(
    String groupName,
    GroupApplication application,
    ApplicationStatus newStatus,
  ) async {
    // Delete from old location
    final oldSubdir = application.status.name;
    final oldPath = '$groupName/candidates/$oldSubdir/${application.filename}';
    if (await _storage.exists(oldPath)) {
      await _storage.delete(oldPath);
    }

    // Save to new location
    final updatedApplication = application.copyWith(status: newStatus);
    await saveApplication(groupName, updatedApplication);

    LogService().log('GroupsService: Moved application ${application.filename} from $oldSubdir to ${newStatus.name}');
  }

  /// Create new group
  Future<void> createGroup({
    String? groupName,
    required String title,
    required String description,
    required GroupType type,
    String? appType,
    required String creatorNpub,
    required String creatorCallsign,
  }) async {
    final timestamp = _formatTimestamp(DateTime.now());
    final resolvedName = await _resolveGroupName(groupName ?? title);

    // Generate npub/nsec key pair for the group
    final keys = NostrKeyGenerator.generateKeyPair();
    final groupNpub = keys.npub;
    final groupNsec = keys.nsec;

    final group = Group(
      name: resolvedName,
      title: title,
      description: description,
      type: type,
      appType: appType,
      created: timestamp,
      updated: timestamp,
      status: 'active',
      members: [
        GroupMember(
          callsign: creatorCallsign,
          npub: creatorNpub,
          role: GroupRole.admin,
          joined: timestamp,
        ),
      ],
      areas: [],
      config: _getDefaultConfig(),
    );

    await saveGroup(group);

    // Save the nsec to security.json
    final securityJson = const JsonEncoder.withIndent('  ').convert({
      'nsec': groupNsec,
      'npub': groupNpub,
      'created': timestamp,
    });
    await _storage.writeString('$resolvedName/security.json', securityJson);

    // Create candidate subdirectories
    for (var subdir in ['pending', 'approved', 'rejected']) {
      await _storage.createDirectory('$resolvedName/candidates/$subdir');
    }

    // Create feature directories if enabled
    final year = DateTime.now().year;

    if (group.isFeatureEnabled('photos')) {
      await _storage.createDirectory('$resolvedName/photos/.reactions');
    }

    if (group.isFeatureEnabled('news')) {
      await _storage.createDirectory('$resolvedName/news/$year/files');
    }

    if (group.isFeatureEnabled('alerts')) {
      await _storage.createDirectory('$resolvedName/alerts/active');
      await _storage.createDirectory('$resolvedName/alerts/archived');
    }

    if (group.isFeatureEnabled('chat')) {
      await _storage.createDirectory('$resolvedName/chat/$year/files');
    }

    LogService().log('GroupsService: Created group $resolvedName');
  }

  /// Get default config for new groups
  Map<String, dynamic> _getDefaultConfig() {
    return {
      'features': {
        'photos': true,
        'news': true,
        'alerts': true,
        'chat': true,
        'comments': true,
      },
      'permissions': {
        'photos_upload': ['admin', 'moderator', 'contributor'],
        'photos_delete': ['admin', 'moderator'],
        'news_publish': ['admin', 'moderator'],
        'news_edit': ['admin', 'moderator'],
        'alerts_issue': ['admin', 'moderator'],
        'alerts_archive': ['admin', 'moderator'],
        'chat_post': ['admin', 'moderator', 'contributor', 'guest'],
        'chat_delete': ['admin', 'moderator'],
        'cross_group_post': ['admin', 'moderator', 'contributor'],
      },
      'chat_settings': {
        'allow_cross_group_posts': true,
        'allow_file_attachments': true,
        'message_retention_days': 365,
      },
      'updated': _formatTimestamp(DateTime.now()),
    };
  }

  /// Format timestamp in geogram format
  String _formatTimestamp(DateTime dt) {
    return ChatFormat.formatTimestamp(dt);
  }

  Future<String> _resolveGroupName(String name) async {
    final baseName = GroupUtils.sanitizeGroupName(name);
    var candidate = baseName;
    var suffix = 2;

    while (await _storage.exists(candidate)) {
      candidate = '$baseName-$suffix';
      suffix++;
    }

    return candidate;
  }

  /// Delete group (mark as inactive)
  Future<void> deleteGroup(String groupName) async {
    final group = await loadGroup(groupName);
    if (group == null) return;

    // Mark as inactive instead of deleting (for audit trail)
    final updatedGroup = group.copyWith(
      status: 'inactive',
      updated: _formatTimestamp(DateTime.now()),
    );

    await saveGroup(updatedGroup);
    LogService().log('GroupsService: Marked group $groupName as inactive');
  }

  /// Add member to group
  Future<void> addMember(String groupName, GroupMember member) async {
    final group = await loadGroup(groupName);
    if (group == null) return;

    // Check if member already exists
    final existingIndex = group.members.indexWhere((m) => m.npub == member.npub);
    if (existingIndex >= 0) {
      // Update existing member
      final updatedMembers = List<GroupMember>.from(group.members);
      updatedMembers[existingIndex] = member;
      await saveMembers(groupName, updatedMembers);
    } else {
      // Add new member
      final updatedMembers = [...group.members, member];
      await saveMembers(groupName, updatedMembers);
    }

    LogService().log('GroupsService: Added/updated member ${member.callsign} in $groupName');
  }

  /// Remove member from group
  Future<void> removeMember(String groupName, String npub) async {
    final group = await loadGroup(groupName);
    if (group == null) return;

    final updatedMembers = group.members.where((m) => m.npub != npub).toList();
    await saveMembers(groupName, updatedMembers);

    LogService().log('GroupsService: Removed member with npub $npub from $groupName');
  }

  /// Update member role
  Future<void> updateMemberRole(String groupName, String npub, GroupRole newRole) async {
    final group = await loadGroup(groupName);
    if (group == null) return;

    final updatedMembers = group.members.map((m) {
      if (m.npub == npub) {
        return m.copyWith(role: newRole);
      }
      return m;
    }).toList();

    await saveMembers(groupName, updatedMembers);
    LogService().log('GroupsService: Updated member role in $groupName');
  }

  /// Save reputation entry for a callsign
  Future<void> saveReputationEntry(
    String callsign,
    String npub,
    int value,
    String givenBy,
    String givenByNpub,
    String reason,
    String signature,
  ) async {
    // Create unique filename with timestamp
    final timestamp = _formatTimestamp(DateTime.now());
    final timestampFile = timestamp.replaceAll(' ', '_').replaceAll(':', '-');

    final entry = ReputationEntry(
      callsign: callsign,
      npub: npub,
      value: value,
      givenBy: givenBy,
      givenByNpub: givenByNpub,
      timestamp: timestamp,
      reason: reason,
      signature: signature,
    );
    final content = entry.exportAsText();

    final relativeDirPath = 'reputation/$callsign';
    if (!await _storage.exists(relativeDirPath)) {
      await _storage.createDirectory(relativeDirPath);
    }
    await _storage.writeString('$relativeDirPath/${timestampFile}_$givenBy.txt', content);

    LogService().log('GroupsService: Saved reputation entry for $callsign');
  }

  /// Load all reputation entries for a callsign
  Future<List<ReputationEntry>> loadReputationEntries(String callsign) async {
    final entries = <ReputationEntry>[];

    try {
      final relativeDirPath = 'reputation/$callsign';
      if (!await _storage.exists(relativeDirPath)) return [];

      final storageEntries = await _storage.listDirectory(relativeDirPath);
      for (var storageEntry in storageEntries) {
        if (!storageEntry.isDirectory && storageEntry.name.endsWith('.txt')) {
          final content = await _storage.readString(storageEntry.path);
          if (content != null) {
            final entry = ReputationEntry.fromText(content, storageEntry.name);
            if (entry != null) {
              entries.add(entry);
            }
          }
        }
      }

      // Sort by timestamp (most recent first)
      entries.sort((a, b) => b.timestampDateTime.compareTo(a.timestampDateTime));

      LogService().log('GroupsService: Loaded ${entries.length} reputation entries for $callsign');
    } catch (e) {
      LogService().log('GroupsService: Error loading reputation for $callsign: $e');
    }

    return entries;
  }

  /// Get total reputation score for a callsign
  Future<int> getReputationScore(String callsign) async {
    final entries = await loadReputationEntries(callsign);
    return entries.fold<int>(0, (sum, entry) => sum + entry.value);
  }

  /// Save station network topology to sync folder
  Future<void> saveNetworkTopology(List<StationNode> nodes) async {
    final json = {
      'updated': DateTime.now().toIso8601String(),
      'nodes': nodes.map((n) => n.toJson()).toList(),
    };
    final content = const JsonEncoder.withIndent('  ').convert(json);

    if (!await _storage.exists('sync')) {
      await _storage.createDirectory('sync');
    }
    await _storage.writeString('sync/network_topology.json', content);

    LogService().log('GroupsService: Saved network topology with ${nodes.length} nodes');
  }

  /// Load station network topology from sync folder
  Future<List<StationNode>> loadNetworkTopology() async {
    final content = await _storage.readString('sync/network_topology.json');
    if (content == null) return [];

    try {
      final json = jsonDecode(content) as Map<String, dynamic>;
      final nodesData = json['nodes'] as List<dynamic>;

      final nodes = nodesData
          .map((data) => StationNode.fromJson(data as Map<String, dynamic>))
          .toList();

      LogService().log('GroupsService: Loaded network topology with ${nodes.length} nodes');
      return nodes;
    } catch (e) {
      LogService().log('GroupsService: Error loading network topology: $e');
      return [];
    }
  }

  /// Save collection approval status for a user collection
  Future<void> saveAppApproval(
    String userNpub,
    String appType,
    String status, // 'approved', 'rejected', 'pending'
    {String? reason}
  ) async {
    final json = {
      'npub': userNpub,
      'app_type': appType,
      'status': status,
      if (reason != null) 'reason': reason,
      'updated': DateTime.now().toIso8601String(),
    };
    final content = const JsonEncoder.withIndent('  ').convert(json);

    final relativeDirPath = 'approvals/$appType';
    if (!await _storage.exists(relativeDirPath)) {
      await _storage.createDirectory(relativeDirPath);
    }
    await _storage.writeString('$relativeDirPath/$userNpub.json', content);

    LogService().log('GroupsService: Saved collection approval: $userNpub/$appType = $status');
  }

  /// Load collection approval status
  Future<Map<String, dynamic>?> loadAppApproval(
    String userNpub,
    String appType,
  ) async {
    final content = await _storage.readString('approvals/$appType/$userNpub.json');
    if (content == null) return null;

    try {
      return jsonDecode(content) as Map<String, dynamic>;
    } catch (e) {
      LogService().log('GroupsService: Error loading collection approval: $e');
      return null;
    }
  }

  /// Check if collection is approved for user
  Future<bool> isAppApproved(String userNpub, String appType) async {
    final approval = await loadAppApproval(userNpub, appType);
    return approval?['status'] == 'approved';
  }

  /// Get all pending approvals for a collection type
  Future<List<Map<String, dynamic>>> getPendingApprovals(String appType) async {
    final approvals = <Map<String, dynamic>>[];

    try {
      final relativeDirPath = 'approvals/$appType';
      if (!await _storage.exists(relativeDirPath)) return [];

      final entries = await _storage.listDirectory(relativeDirPath);
      for (var entry in entries) {
        if (!entry.isDirectory && entry.name.endsWith('.json')) {
          final content = await _storage.readString(entry.path);
          if (content != null) {
            final data = jsonDecode(content) as Map<String, dynamic>;
            if (data['status'] == 'pending') {
              approvals.add(data);
            }
          }
        }
      }
    } catch (e) {
      LogService().log('GroupsService: Error loading pending approvals: $e');
    }

    return approvals;
  }
}
