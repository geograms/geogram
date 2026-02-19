/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Represents security settings for a chat collection
class ChatSecurity {
  /// Admin npub (owner of the chat collection)
  final String? adminNpub;

  /// Moderators by channel ID
  final Map<String, List<String>> moderators;

  ChatSecurity({
    this.adminNpub,
    Map<String, List<String>>? moderators,
  }) : moderators = moderators ?? {};

  /// Create from JSON
  factory ChatSecurity.fromJson(Map<String, dynamic> json) {
    Map<String, List<String>> mods = {};
    if (json['moderators'] != null) {
      final modsJson = json['moderators'] as Map<String, dynamic>;
      modsJson.forEach((key, value) {
        mods[key] = (value as List).cast<String>();
      });
    }

    return ChatSecurity(
      adminNpub: json['admin'] as String?,
      moderators: mods,
    );
  }

  /// Convert to JSON
  Map<String, dynamic> toJson() {
    return {
      'admin': adminNpub,
      'moderators': moderators,
    };
  }

  /// Check if npub is admin
  bool isAdmin(String? npub) {
    if (npub == null || adminNpub == null) return false;
    return npub == adminNpub;
  }

  /// Check if npub is moderator for a channel
  bool isModerator(String? npub, String channelId) {
    if (npub == null) return false;
    final channelMods = moderators[channelId] ?? [];
    return channelMods.contains(npub);
  }

  /// Check if npub is a global moderator (across all channels)
  bool isGlobalModerator(String? npub) {
    if (npub == null) return false;
    return (moderators['*'] ?? []).contains(npub);
  }

  /// Check if npub has moderation permissions (admin, global mod, or channel mod)
  bool canModerate(String? npub, String channelId) {
    return isAdmin(npub) || isGlobalModerator(npub) || isModerator(npub, channelId);
  }

  /// Get moderators for a specific channel
  List<String> getModerators(String channelId) {
    return List.unmodifiable(moderators[channelId] ?? []);
  }

  /// Add moderator to a channel
  void addModerator(String channelId, String npub) {
    if (!moderators.containsKey(channelId)) {
      moderators[channelId] = [];
    }
    if (!moderators[channelId]!.contains(npub)) {
      moderators[channelId]!.add(npub);
    }
  }

  /// Remove moderator from a channel
  void removeModerator(String channelId, String npub) {
    if (moderators.containsKey(channelId)) {
      moderators[channelId]!.remove(npub);
    }
  }

  /// Add a global moderator (moderates all channels)
  void addGlobalModerator(String npub) {
    addModerator('*', npub);
  }

  /// Remove a global moderator
  void removeGlobalModerator(String npub) {
    removeModerator('*', npub);
  }

  /// Get all global moderators
  List<String> getGlobalModerators() {
    return List.unmodifiable(moderators['*'] ?? []);
  }

  /// Copy with modifications
  ChatSecurity copyWith({
    String? adminNpub,
    Map<String, List<String>>? moderators,
  }) {
    return ChatSecurity(
      adminNpub: adminNpub ?? this.adminNpub,
      moderators: moderators ?? Map.from(this.moderators),
    );
  }
}
