/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Shared mixin for chat message modification (edit/delete) verification.
 * Used by both CLI (PureStationServer) and Desktop (LogApiService) stations.
 */

import 'dart:convert';

import '../../util/nostr_event.dart';

/// Mixin providing shared NOSTR event verification for chat message
/// modification requests (DELETE and PUT).
mixin ChatModificationMixin {
  /// Verify a NOSTR event from an Authorization header for message modification.
  ///
  /// Accepts:
  /// - Kind 5 (NIP-09 deletion) for delete actions
  /// - Kind 1 (text note) for both delete (legacy) and edit actions
  ///
  /// Returns the verified event, or null if verification fails.
  NostrEvent? verifyModificationEvent(
    String? authHeader,
    String expectedAction,
    String expectedRoomId,
  ) {
    if (authHeader == null || !authHeader.startsWith('Nostr ')) {
      return null;
    }

    try {
      final base64Event = authHeader.substring(6);
      final eventJson = utf8.decode(base64Decode(base64Event));
      final eventData = jsonDecode(eventJson) as Map<String, dynamic>;
      final event = NostrEvent.fromJson(eventData);

      // Verify signature
      if (!event.verify()) {
        return null;
      }

      // Check event is recent (within 5 minutes)
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if ((now - event.createdAt).abs() > 300) {
        return null;
      }

      // Accept kind 5 for delete, kind 1 for both delete (legacy) and edit
      if (expectedAction == 'delete') {
        if (event.kind != NostrEventKind.deletion &&
            event.kind != NostrEventKind.textNote) {
          return null;
        }
      } else {
        // edit and other actions: kind 1 only
        if (event.kind != NostrEventKind.textNote) {
          return null;
        }
      }

      // Verify action tag
      final actionTag = event.getTagValue('action');
      if (actionTag != expectedAction) {
        return null;
      }

      // Verify room tag
      final roomTag = event.getTagValue('room');
      if (roomTag != expectedRoomId) {
        return null;
      }

      return event;
    } catch (_) {
      return null;
    }
  }

  /// For kind 5 (NIP-09) deletion events, validate that the ["e"] tag
  /// references the correct stored event ID.
  ///
  /// Returns true if:
  /// - The event is not kind 5 (skip validation for legacy kind 1)
  /// - The event is kind 5 and has a matching ["e"] tag
  /// - The storedEventId is null (message has no event ID to check)
  bool validateDeletionTarget(NostrEvent event, String? storedEventId) {
    if (event.kind != NostrEventKind.deletion) {
      return true; // Not a kind 5, skip validation
    }

    if (storedEventId == null || storedEventId.isEmpty) {
      return true; // No stored event ID to check against
    }

    final eventIds = event.getTagValues('e');
    return eventIds.contains(storedEventId);
  }
}
