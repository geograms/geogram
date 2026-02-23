/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Signal user/contact model.
 * Identified by UUID (not integer user IDs like Telegram).
 */

class SignalUser {
  final String uuid;
  final String name;
  final String? phoneNumber;
  final String? avatarPath;

  const SignalUser({
    required this.uuid,
    required this.name,
    this.phoneNumber,
    this.avatarPath,
  });

  factory SignalUser.fromJson(Map<String, dynamic> json) {
    return SignalUser(
      uuid: json['uuid'] as String? ?? '',
      name: json['name'] as String? ?? '',
      phoneNumber: json['phone_number'] as String?,
      avatarPath: json['avatar_path'] as String?,
    );
  }

  @override
  String toString() => 'SignalUser($uuid, $name)';
}
