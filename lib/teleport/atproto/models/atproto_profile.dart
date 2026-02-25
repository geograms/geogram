/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

class AtprotoProfile {
  final String did;
  final String handle;
  final String displayName;
  final String description;
  final String? avatarUrl;
  final String? bannerUrl;
  final int followersCount;
  final int followsCount;
  final int postsCount;
  final bool isFollowedByMe;

  const AtprotoProfile({
    required this.did,
    required this.handle,
    required this.displayName,
    required this.description,
    this.avatarUrl,
    this.bannerUrl,
    this.followersCount = 0,
    this.followsCount = 0,
    this.postsCount = 0,
    this.isFollowedByMe = false,
  });

  factory AtprotoProfile.fromJson(Map<String, dynamic> json) {
    final viewer = json['viewer'] as Map<String, dynamic>?;
    return AtprotoProfile(
      did: json['did'] as String? ?? '',
      handle: json['handle'] as String? ?? '',
      displayName: json['displayName'] as String? ?? '',
      description: json['description'] as String? ?? '',
      avatarUrl: json['avatar'] as String?,
      bannerUrl: json['banner'] as String?,
      followersCount: json['followersCount'] as int? ?? 0,
      followsCount: json['followsCount'] as int? ?? 0,
      postsCount: json['postsCount'] as int? ?? 0,
      isFollowedByMe: viewer?['following'] != null,
    );
  }
}
