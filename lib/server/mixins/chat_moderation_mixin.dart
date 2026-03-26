/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Shared mixin for global chat moderator management.
 * Used by both CLI (PureStationServer) and Desktop (StationServer) stations.
 */

import '../../models/chat_security.dart';
import '../../services/nip05_registry_service.dart';

/// Mixin providing global moderator add/remove/list, identity resolution,
/// and shared helpers for injecting mod status into API responses.
///
/// Implementors must provide [chatSecurity] and [saveChatSecurity] to connect
/// the mixin to the station's security storage (avoids pulling ChatService
/// which has Flutter deps that break the CLI build).
mixin ChatModerationMixin {
  /// Override in each station to provide the active ChatSecurity instance.
  ChatSecurity get chatSecurity;

  /// Override in each station to persist security changes.
  Future<void> saveChatSecurity(ChatSecurity security);

  bool addGlobalModerator(String npub) {
    final security = chatSecurity;
    if (security.isGlobalModerator(npub)) return false;
    security.addGlobalModerator(npub);
    saveChatSecurity(security);
    return true;
  }

  bool removeGlobalModerator(String npub) {
    final security = chatSecurity;
    if (!security.isGlobalModerator(npub)) return false;
    security.removeGlobalModerator(npub);
    saveChatSecurity(security);
    return true;
  }

  List<String> getGlobalModerators() {
    return chatSecurity.getGlobalModerators();
  }

  /// Resolve a callsign or nickname to an npub via NIP-05 registry.
  String? resolveIdentityToNpub(String nameOrCallsign) {
    final reg = Nip05RegistryService().getRegistration(nameOrCallsign.toLowerCase());
    return reg?.npub;
  }

  // ---------------------------------------------------------------------------
  // API response helpers — shared by both station implementations
  // ---------------------------------------------------------------------------

  /// Inject `isModerator: true` into a room JSON map if the authenticated user
  /// has moderation permissions for that room.
  void injectModeratorFlag(Map<String, dynamic> roomJson, String roomId, String? authNpub) {
    if (authNpub != null && chatSecurity.canModerate(authNpub, roomId)) {
      roomJson['isModerator'] = true;
    }
  }

  /// Inject `is_mod: 'true'` into a message metadata map if the message author
  /// is a moderator for the given room.
  void injectModBadge(Map<String, dynamic> msgJson, String? msgNpub, String roomId) {
    if (msgNpub != null && chatSecurity.canModerate(msgNpub, roomId)) {
      final meta = Map<String, dynamic>.from(msgJson['metadata'] as Map? ?? {});
      meta['is_mod'] = 'true';
      msgJson['metadata'] = meta;
    }
  }

  /// Ensure the station owner is set as chat admin if not already configured.
  /// [additionalModerators] are extra npubs (e.g. operator, profile) that
  /// should also have moderator access.
  /// Call after loading chat security. Returns true if security was updated.
  Future<bool> ensureChatAdmin(String ownerNpub, {List<String> additionalModerators = const []}) async {
    bool changed = false;

    // Set admin if missing
    if (chatSecurity.adminNpub == null && ownerNpub.isNotEmpty) {
      final updated = ChatSecurity(
        adminNpub: ownerNpub,
        moderators: Map<String, List<String>>.from(chatSecurity.toJson()['moderators'] as Map? ?? {}),
      );
      for (final m in chatSecurity.getGlobalModerators()) {
        updated.addGlobalModerator(m);
      }
      await saveChatSecurity(updated);
      changed = true;
    }

    // Ensure additional npubs are global moderators
    for (final npub in additionalModerators) {
      if (npub.isNotEmpty && !chatSecurity.isGlobalModerator(npub) && !chatSecurity.isAdmin(npub)) {
        chatSecurity.addGlobalModerator(npub);
        changed = true;
      }
    }

    if (changed) {
      await saveChatSecurity(chatSecurity);
    }
    return changed;
  }

  /// Check whether [actorNpub] is authorized to modify a message authored by
  /// [messageNpub] in [roomId]. Returns `true` if the actor is the author or
  /// a moderator.
  bool canModifyMessage(String actorNpub, String? messageNpub, String roomId) {
    if (actorNpub == messageNpub) return true;
    return chatSecurity.canModerate(actorNpub, roomId);
  }

  /// Build mod-attribution metadata for a moderator editing someone else's
  /// message. Returns an empty map if the actor is the author.
  Map<String, String> buildModEditAttribution(String actorNpub, String? messageNpub) {
    if (actorNpub == messageNpub) return {};
    final attrs = <String, String>{'edited_by_mod': actorNpub};
    final reg = Nip05RegistryService().getRegistrationByNpub(actorNpub);
    if (reg != null) {
      attrs['mod_callsign'] = reg.callsign;
      if (reg.nickname != null) {
        attrs['mod_nickname'] = reg.nickname!;
      }
    }
    return attrs;
  }
}
