/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// A Telegram user.
class TelegramUser {
  final int id;
  final String firstName;
  final String? lastName;
  final String? username;
  final String? phoneNumber;
  final String? profilePhotoPath;

  const TelegramUser({
    required this.id,
    required this.firstName,
    this.lastName,
    this.username,
    this.phoneNumber,
    this.profilePhotoPath,
  });

  String get displayName {
    if (lastName != null && lastName!.isNotEmpty) {
      return '$firstName $lastName';
    }
    return firstName;
  }

  factory TelegramUser.fromTdlib(Map<String, dynamic> json) {
    return TelegramUser(
      id: json['id'] as int,
      firstName: json['first_name'] as String? ?? '',
      lastName: json['last_name'] as String?,
      username: (json['usernames'] as Map<String, dynamic>?)?['editable_username'] as String?,
      phoneNumber: json['phone_number'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'firstName': firstName,
        'lastName': lastName,
        'username': username,
        'phoneNumber': phoneNumber,
      };

  @override
  String toString() => 'TelegramUser($id, $displayName)';
}
