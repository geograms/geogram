import 'dart:convert';

/// User profile model
class Profile {
  String callsign;
  String nickname;
  String description;
  String? profileImagePath;
  String npub; // NOSTR public key
  String nsec; // NOSTR private key (secret)
  String preferredColor;

  Profile({
    this.callsign = '',
    this.nickname = '',
    this.description = '',
    this.profileImagePath,
    this.npub = '',
    this.nsec = '',
    this.preferredColor = 'blue',
  });

  /// Create a Profile from JSON map
  factory Profile.fromJson(Map<String, dynamic> json) {
    return Profile(
      callsign: json['callsign'] as String? ?? '',
      nickname: json['nickname'] as String? ?? '',
      description: json['description'] as String? ?? '',
      profileImagePath: json['profileImagePath'] as String?,
      npub: json['npub'] as String? ?? '',
      nsec: json['nsec'] as String? ?? '',
      preferredColor: json['preferredColor'] as String? ?? 'blue',
    );
  }

  /// Convert Profile to JSON map
  Map<String, dynamic> toJson() {
    return {
      'callsign': callsign,
      'nickname': nickname,
      'description': description,
      if (profileImagePath != null) 'profileImagePath': profileImagePath,
      'npub': npub,
      'nsec': nsec,
      'preferredColor': preferredColor,
    };
  }

  /// Create a copy of this profile
  Profile copyWith({
    String? callsign,
    String? nickname,
    String? description,
    String? profileImagePath,
    String? npub,
    String? nsec,
    String? preferredColor,
  }) {
    return Profile(
      callsign: callsign ?? this.callsign,
      nickname: nickname ?? this.nickname,
      description: description ?? this.description,
      profileImagePath: profileImagePath ?? this.profileImagePath,
      npub: npub ?? this.npub,
      nsec: nsec ?? this.nsec,
      preferredColor: preferredColor ?? this.preferredColor,
    );
  }
}
