/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Represents a chat channel (main group, direct message, or custom group)
class ChatChannel {
  /// Unique channel identifier (e.g., "main", "X135AS", "team-alpha")
  final String id;

  /// Channel type
  final ChatChannelType type;

  /// Display name
  final String name;

  /// Folder name (relative to collection root)
  final String folder;

  /// List of participant callsigns ("*" for public main channel)
  final List<String> participants;

  /// Channel description
  final String? description;

  /// When channel was created
  final DateTime created;

  /// Last message timestamp (for sorting)
  DateTime? lastMessageTime;

  /// Unread message count
  int unreadCount;

  /// Is channel favorited/pinned
  bool isFavorite;

  /// Channel configuration (from config.json)
  final ChatChannelConfig? config;

  ChatChannel({
    required this.id,
    required this.type,
    required this.name,
    required this.folder,
    required this.participants,
    this.description,
    required this.created,
    this.lastMessageTime,
    this.unreadCount = 0,
    this.isFavorite = false,
    this.config,
  });

  /// Create main group channel
  factory ChatChannel.main({
    String name = 'Main Chat',
    String? description,
    ChatChannelConfig? config,
  }) {
    return ChatChannel(
      id: 'main',
      type: ChatChannelType.group,
      name: name,
      folder: 'main',
      participants: ['*'], // Public for everyone
      description: description ?? 'Public group chat for everyone',
      created: DateTime.now(),
      config: config,
    );
  }

  /// Create direct message channel
  factory ChatChannel.direct({
    required String callsign,
    ChatChannelConfig? config,
  }) {
    return ChatChannel(
      id: callsign,
      type: ChatChannelType.direct,
      name: callsign,
      folder: callsign,
      participants: [callsign], // Will add owner when created
      description: 'Direct message with $callsign',
      created: DateTime.now(),
      config: config,
    );
  }

  /// Create custom group channel
  factory ChatChannel.group({
    required String id,
    required String name,
    required List<String> participants,
    String? description,
    ChatChannelConfig? config,
  }) {
    return ChatChannel(
      id: id,
      type: ChatChannelType.group,
      name: name,
      folder: id,
      participants: participants,
      description: description,
      created: DateTime.now(),
      config: config,
    );
  }

  /// Check if channel is the main group
  bool get isMain => id == 'main';

  /// Check if channel is a direct message
  bool get isDirect => type == ChatChannelType.direct;

  /// Check if channel is a custom group
  bool get isGroup => type == ChatChannelType.group;

  /// Check if channel is public (main channel with "*")
  bool get isPublic => participants.contains('*');

  /// Get icon name for channel type
  String get iconName {
    switch (type) {
      case ChatChannelType.group:
        return isMain ? 'forum' : 'group';
      case ChatChannelType.direct:
        return 'person';
    }
  }

  /// Get display subtitle (participant count or last message preview)
  String get subtitle {
    if (isDirect) {
      return 'Direct message';
    } else if (isMain) {
      return 'Public group chat';
    } else {
      int count = participants.length;
      return '$count participant${count != 1 ? 's' : ''}';
    }
  }

  /// Create from JSON
  factory ChatChannel.fromJson(Map<String, dynamic> json) {
    return ChatChannel(
      id: json['id'] as String,
      type: ChatChannelType.values.firstWhere(
        (t) => t.name == (json['type'] as String),
        orElse: () => ChatChannelType.group,
      ),
      name: json['name'] as String,
      folder: json['folder'] as String,
      participants: List<String>.from(json['participants'] as List? ?? []),
      description: json['description'] as String?,
      created: DateTime.parse(json['created'] as String),
      lastMessageTime: json['lastMessageTime'] != null
          ? DateTime.parse(json['lastMessageTime'] as String)
          : null,
      unreadCount: json['unreadCount'] as int? ?? 0,
      isFavorite: json['isFavorite'] as bool? ?? false,
      config: json['config'] != null
          ? ChatChannelConfig.fromJson(json['config'] as Map<String, dynamic>)
          : null,
    );
  }

  /// Convert to JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type.name,
      'name': name,
      'folder': folder,
      'participants': participants,
      if (description != null) 'description': description,
      'created': created.toIso8601String(),
      if (lastMessageTime != null)
        'lastMessageTime': lastMessageTime!.toIso8601String(),
      'unreadCount': unreadCount,
      'isFavorite': isFavorite,
      if (config != null) 'config': config!.toJson(),
    };
  }

  /// Create a copy with modified fields
  ChatChannel copyWith({
    String? id,
    ChatChannelType? type,
    String? name,
    String? folder,
    List<String>? participants,
    String? description,
    DateTime? created,
    DateTime? lastMessageTime,
    int? unreadCount,
    bool? isFavorite,
    ChatChannelConfig? config,
  }) {
    return ChatChannel(
      id: id ?? this.id,
      type: type ?? this.type,
      name: name ?? this.name,
      folder: folder ?? this.folder,
      participants: participants ?? List<String>.from(this.participants),
      description: description ?? this.description,
      created: created ?? this.created,
      lastMessageTime: lastMessageTime ?? this.lastMessageTime,
      unreadCount: unreadCount ?? this.unreadCount,
      isFavorite: isFavorite ?? this.isFavorite,
      config: config ?? this.config,
    );
  }

  @override
  String toString() {
    return 'ChatChannel(id: $id, type: ${type.name}, name: $name, '
        'participants: ${participants.length})';
  }
}

/// Channel type enumeration
enum ChatChannelType {
  group, // Group chat (main or custom)
  direct, // Direct 1:1 message
}

/// Channel configuration (from config.json)
class ChatChannelConfig {
  /// Channel ID
  final String id;

  /// Channel name
  final String name;

  /// Description
  final String? description;

  /// Visibility (PUBLIC, PRIVATE, RESTRICTED)
  final String visibility;

  /// Is read-only
  final bool readonly;

  /// Allow file uploads
  final bool fileUpload;

  /// Max files per message
  final int filesPerPost;

  /// Max file size in MB
  final int maxFileSize;

  /// Max message text size in characters
  final int maxSizeText;

  /// List of moderator callsigns (legacy, kept for backward compatibility)
  final List<String> moderators;

  // === Role-Based Access Control (npub-based) ===

  /// Room owner npub (creator with full control)
  final String? owner;

  /// List of admin npubs (full room management)
  final List<String> admins;

  /// List of moderator npubs (member management, message moderation)
  final List<String> moderatorNpubs;

  /// List of member npubs (read/write access)
  final List<String> members;

  /// List of banned npubs (no access, cannot reapply)
  final List<String> banned;

  /// Pending membership applications
  final List<MembershipApplication> pendingApplicants;

  /// Group ID for dynamic membership lookup
  /// When set, membership is resolved dynamically from GroupsService
  final String? groupId;

  ChatChannelConfig({
    required this.id,
    required this.name,
    this.description,
    this.visibility = 'PUBLIC',
    this.readonly = false,
    this.fileUpload = true,
    this.filesPerPost = 3,
    this.maxFileSize = 10,
    this.maxSizeText = 500,
    this.moderators = const [],
    this.owner,
    this.admins = const [],
    this.moderatorNpubs = const [],
    this.members = const [],
    this.banned = const [],
    this.pendingApplicants = const [],
    this.groupId,
  });

  /// Check if this config uses dynamic group membership
  bool get usesDynamicMembership => groupId != null && groupId!.isNotEmpty;

  // === Role Check Methods ===

  /// Check if npub is the room owner
  bool isOwner(String? npub) => npub != null && owner == npub;

  /// Check if npub is an admin (includes owner)
  bool isAdmin(String? npub) =>
      npub != null && (admins.contains(npub) || isOwner(npub));

  /// Check if npub is a moderator (includes admins)
  bool isModerator(String? npub) =>
      npub != null && (moderatorNpubs.contains(npub) || isAdmin(npub));

  /// Check if npub is a member (includes moderators)
  bool isMember(String? npub) =>
      npub != null && (members.contains(npub) || isModerator(npub));

  /// Check if npub is banned
  bool isBanned(String? npub) => npub != null && banned.contains(npub);

  /// Check if npub has a pending application
  bool hasApplied(String? npub) =>
      npub != null && pendingApplicants.any((a) => a.npub == npub);

  // === Permission Check Methods ===

  /// Check if npub can access the room (member and not banned)
  bool canAccess(String? npub) => isMember(npub) && !isBanned(npub);

  /// Check if npub can manage members (add/remove)
  bool canManageMembers(String? npub) => isModerator(npub);

  /// Check if npub can manage roles (promote/demote moderators)
  bool canManageRoles(String? npub) => isAdmin(npub);

  /// Check if npub can manage admins (only owner)
  bool canManageAdmins(String? npub) => isOwner(npub);

  /// Check if npub can ban users
  bool canBan(String? npub) => isModerator(npub);

  /// Check if npub can approve/reject applications
  bool canManageApplications(String? npub) => isModerator(npub);

  /// Create default config for a channel
  factory ChatChannelConfig.defaults({
    required String id,
    required String name,
    String? description,
  }) {
    return ChatChannelConfig(
      id: id,
      name: name,
      description: description,
      visibility: 'PUBLIC',
      readonly: false,
      fileUpload: true,
      filesPerPost: 3,
      maxFileSize: 10,
      maxSizeText: 500,
      moderators: [],
    );
  }

  /// Create from JSON
  factory ChatChannelConfig.fromJson(Map<String, dynamic> json) {
    return ChatChannelConfig(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String?,
      visibility: json['visibility'] as String? ?? 'PUBLIC',
      readonly: json['readonly'] as bool? ?? false,
      fileUpload: json['file_upload'] as bool? ?? true,
      filesPerPost: json['files_per_post'] as int? ?? 3,
      maxFileSize: json['max_file_size'] as int? ?? 10,
      maxSizeText: json['max_size_text'] as int? ?? 500,
      moderators: List<String>.from(json['moderators'] as List? ?? []),
      // Role-based access control fields
      owner: json['owner'] as String?,
      admins: List<String>.from(json['admins'] as List? ?? []),
      moderatorNpubs:
          List<String>.from(json['moderator_npubs'] as List? ?? []),
      members: List<String>.from(json['members'] as List? ?? []),
      banned: List<String>.from(json['banned'] as List? ?? []),
      pendingApplicants: (json['pending_applicants'] as List? ?? [])
          .map((a) => MembershipApplication.fromJson(a as Map<String, dynamic>))
          .toList(),
      groupId: json['group_id'] as String?,
    );
  }

  /// Convert to JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      if (description != null) 'description': description,
      'visibility': visibility,
      'readonly': readonly,
      'file_upload': fileUpload,
      'files_per_post': filesPerPost,
      'max_file_size': maxFileSize,
      'max_size_text': maxSizeText,
      'moderators': moderators,
      // Role-based access control fields
      if (owner != null) 'owner': owner,
      if (admins.isNotEmpty) 'admins': admins,
      if (moderatorNpubs.isNotEmpty) 'moderator_npubs': moderatorNpubs,
      if (members.isNotEmpty) 'members': members,
      if (banned.isNotEmpty) 'banned': banned,
      if (pendingApplicants.isNotEmpty)
        'pending_applicants': pendingApplicants.map((a) => a.toJson()).toList(),
      if (groupId != null) 'group_id': groupId,
    };
  }

  /// Create a copy with modified fields
  ChatChannelConfig copyWith({
    String? id,
    String? name,
    String? description,
    String? visibility,
    bool? readonly,
    bool? fileUpload,
    int? filesPerPost,
    int? maxFileSize,
    int? maxSizeText,
    List<String>? moderators,
    String? owner,
    List<String>? admins,
    List<String>? moderatorNpubs,
    List<String>? members,
    List<String>? banned,
    List<MembershipApplication>? pendingApplicants,
    String? groupId,
  }) {
    return ChatChannelConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      visibility: visibility ?? this.visibility,
      readonly: readonly ?? this.readonly,
      fileUpload: fileUpload ?? this.fileUpload,
      filesPerPost: filesPerPost ?? this.filesPerPost,
      maxFileSize: maxFileSize ?? this.maxFileSize,
      maxSizeText: maxSizeText ?? this.maxSizeText,
      moderators: moderators ?? List<String>.from(this.moderators),
      owner: owner ?? this.owner,
      admins: admins ?? List<String>.from(this.admins),
      moderatorNpubs: moderatorNpubs ?? List<String>.from(this.moderatorNpubs),
      members: members ?? List<String>.from(this.members),
      banned: banned ?? List<String>.from(this.banned),
      pendingApplicants: pendingApplicants ??
          this.pendingApplicants.map((a) => a.copy()).toList(),
      groupId: groupId ?? this.groupId,
    );
  }

  @override
  String toString() {
    return 'ChatChannelConfig(id: $id, name: $name, visibility: $visibility)';
  }
}

/// Represents a membership application to join a restricted room
class MembershipApplication {
  /// Applicant's npub (NOSTR public key)
  final String npub;

  /// Applicant's callsign (for display)
  final String? callsign;

  /// When the application was submitted
  final DateTime appliedAt;

  /// Optional message from the applicant
  final String? message;

  MembershipApplication({
    required this.npub,
    this.callsign,
    required this.appliedAt,
    this.message,
  });

  /// Create from JSON
  factory MembershipApplication.fromJson(Map<String, dynamic> json) {
    return MembershipApplication(
      npub: json['npub'] as String,
      callsign: json['callsign'] as String?,
      appliedAt: DateTime.parse(json['applied_at'] as String),
      message: json['message'] as String?,
    );
  }

  /// Convert to JSON
  Map<String, dynamic> toJson() {
    return {
      'npub': npub,
      if (callsign != null) 'callsign': callsign,
      'applied_at': appliedAt.toIso8601String(),
      if (message != null) 'message': message,
    };
  }

  /// Create a copy
  MembershipApplication copy() {
    return MembershipApplication(
      npub: npub,
      callsign: callsign,
      appliedAt: appliedAt,
      message: message,
    );
  }

  @override
  String toString() {
    return 'MembershipApplication(npub: $npub, callsign: $callsign, '
        'appliedAt: $appliedAt)';
  }
}
