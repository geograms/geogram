/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Shared mixin for registering chat participants in NIP-05 registry.
 * Used by both CLI (PureStationServer) and Desktop (StationServer) stations.
 */

import '../../services/nip05_registry_service.dart';

/// Mixin providing NIP-05 registration for chat message senders.
/// Binds callsign→npub in the NIP-05 registry so web chat participants
/// are discoverable via .well-known/nostr.json.
mixin ChatNip05Mixin {
  /// Register a chat sender's callsign→npub binding in NIP-05.
  /// Called after a message is successfully created in a room.
  /// Silently skips if npub is null/empty (anonymous senders).
  void registerChatSender(String callsign, String? npub) {
    if (npub == null || npub.isEmpty) return;
    Nip05RegistryService().registerIdentity(callsign, npub);
  }
}
