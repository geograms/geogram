/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Signal group model.
 * Groups are identified by a base64-encoded 32-byte master key.
 */

class SignalGroup {
  /// Base64-encoded group master key (32 bytes).
  final String groupId;

  final String title;
  final List<String> memberUuids;
  final List<String> adminUuids;
  final String? avatarPath;

  const SignalGroup({
    required this.groupId,
    required this.title,
    this.memberUuids = const [],
    this.adminUuids = const [],
    this.avatarPath,
  });

  factory SignalGroup.fromJson(Map<String, dynamic> json) {
    return SignalGroup(
      groupId: json['id'] as String? ?? json['group_id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      memberUuids: (json['member_uuids'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      adminUuids: (json['admin_uuids'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      avatarPath: json['avatar_path'] as String?,
    );
  }

  @override
  String toString() => 'SignalGroup($groupId, $title, ${memberUuids.length} members)';
}
