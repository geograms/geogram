/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Engagement actions for events hosted on another device. Signs
 * NOSTR events locally with the active profile's keys and POSTs
 * through the generic `/api/feedback/event/{id}/{action}` surface
 * — the same surface any other app could use because
 * FeedbackHandler already dispatches by contentType.
 *
 * Mirrors the shape of `remote_blog_actions.dart` so the UI for
 * blog and events can share helper semantics.
 */

import 'dart:convert';

import '../services/devices_service.dart';
import '../services/log_service.dart';
import '../services/profile_service.dart';
import '../util/feedback_folder_utils.dart';
import '../util/nostr_crypto.dart';
import '../util/nostr_event.dart';

class RemoteEventActionResult {
  final bool success;
  final int? statusCode;
  final String? error;
  final Map<String, dynamic>? body;

  const RemoteEventActionResult({
    required this.success,
    this.statusCode,
    this.error,
    this.body,
  });

  Map<String, dynamic> toJson() => {
        'success': success,
        if (statusCode != null) 'status_code': statusCode,
        if (error != null) 'error': error,
        if (body != null) 'body': body,
      };
}

class RemoteEventActions {
  RemoteEventActions._();

  /// Sign a kind-7 reaction and POST to
  /// `/api/feedback/event/{eventId}/{actionName}` (or `/react/{emoji}`
  /// when [actionName] is `'reaction'`). [feedbackType] is stored
  /// inside the event `type` tag and becomes the URL segment for
  /// reactions (`heart`, `fire`, …).
  static Future<RemoteEventActionResult> sendFeedback({
    required String remoteCallsign,
    required String eventId,
    required String feedbackType,
    required String actionName,
    String? authorNpub,
  }) async {
    try {
      final profile = ProfileService().getProfile();
      if (profile.npub.isEmpty || profile.nsec.isEmpty) {
        return const RemoteEventActionResult(
            success: false, error: 'NOSTR key required');
      }
      final pubkeyHex = NostrCrypto.decodeNpub(profile.npub);
      final event = NostrEvent(
        pubkey: pubkeyHex,
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        kind: NostrEventKind.reaction,
        tags: [
          ['p', authorNpub ?? ''],
          ['e', eventId],
          ['type', feedbackType],
        ],
        content: actionName,
      );
      event.calculateId();
      event.signWithNsec(profile.nsec);

      final subPath = actionName == 'reaction'
          ? 'react/$feedbackType'
          : actionName;
      final resp = await DevicesService().makeDeviceApiRequest(
        callsign: remoteCallsign,
        method: 'POST',
        path: '/api/feedback/event/$eventId/$subPath',
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(event.toJson()),
      );
      return _wrap(resp);
    } catch (e) {
      LogService().log('RemoteEventActions.sendFeedback: $e');
      return RemoteEventActionResult(success: false, error: e.toString());
    }
  }

  /// Sign a kind-1 comment and POST to
  /// `/api/feedback/event/{eventId}/comment` with
  /// `{author, content, npub, signature, created_at}`. `created_at`
  /// travels with the payload so the server reconstructs the
  /// canonical NOSTR event for signature verification using the
  /// same timestamp the client used.
  static Future<RemoteEventActionResult> sendComment({
    required String remoteCallsign,
    required String eventId,
    required String content,
  }) async {
    try {
      if (content.trim().isEmpty) {
        return const RemoteEventActionResult(
            success: false, error: 'Empty comment');
      }
      final profile = ProfileService().getProfile();
      if (profile.npub.isEmpty || profile.nsec.isEmpty) {
        return const RemoteEventActionResult(
            success: false, error: 'NOSTR key required');
      }
      final pubkeyHex = NostrCrypto.decodeNpub(profile.npub);
      final createdAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final event = NostrEvent(
        pubkey: pubkeyHex,
        createdAt: createdAt,
        kind: 1,
        tags: [
          ['e', eventId],
          ['t', 'event-comment'],
          ['callsign', profile.callsign],
        ],
        content: content,
      );
      event.calculateId();
      event.signWithNsec(profile.nsec);

      final resp = await DevicesService().makeDeviceApiRequest(
        callsign: remoteCallsign,
        method: 'POST',
        path: '/api/feedback/event/$eventId/comment',
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'author': profile.callsign,
          'content': content,
          'npub': profile.npub,
          'signature': event.sig,
          'created_at': createdAt,
        }),
      );
      return _wrap(resp);
    } catch (e) {
      LogService().log('RemoteEventActions.sendComment: $e');
      return RemoteEventActionResult(success: false, error: e.toString());
    }
  }

  /// Sign a kind-1 view event and POST to
  /// `/api/feedback/event/{eventId}/view`. Best-effort; fails
  /// silently if the profile has no NOSTR keys.
  static Future<RemoteEventActionResult> recordView({
    required String remoteCallsign,
    required String eventId,
  }) async {
    try {
      final profile = ProfileService().getProfile();
      if (profile.npub.isEmpty || profile.nsec.isEmpty) {
        return const RemoteEventActionResult(
            success: false, error: 'NOSTR key required');
      }
      final pubkeyHex = NostrCrypto.decodeNpub(profile.npub);
      final event = NostrEvent(
        pubkey: pubkeyHex,
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        kind: 1,
        tags: [
          ['t', 'event-view'],
          ['e', eventId],
          ['callsign', profile.callsign],
        ],
        content: '',
      );
      event.calculateId();
      event.signWithNsec(profile.nsec);
      final resp = await DevicesService().makeDeviceApiRequest(
        callsign: remoteCallsign,
        method: 'POST',
        path: '/api/feedback/event/$eventId/view',
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(event.toJson()),
      );
      return _wrap(resp);
    } catch (e) {
      LogService().log('RemoteEventActions.recordView: $e');
      return RemoteEventActionResult(success: false, error: e.toString());
    }
  }

  /// Convenience wrappers keyed on FeedbackFolderUtils constants so
  /// UI code reads `RemoteEventActions.like(...)` instead of the
  /// raw sendFeedback pair.
  static Future<RemoteEventActionResult> like({
    required String remoteCallsign,
    required String eventId,
    String? authorNpub,
  }) =>
      sendFeedback(
        remoteCallsign: remoteCallsign,
        eventId: eventId,
        feedbackType: FeedbackFolderUtils.feedbackTypeLikes,
        actionName: 'like',
        authorNpub: authorNpub,
      );

  static Future<RemoteEventActionResult> dislike({
    required String remoteCallsign,
    required String eventId,
    String? authorNpub,
  }) =>
      sendFeedback(
        remoteCallsign: remoteCallsign,
        eventId: eventId,
        feedbackType: FeedbackFolderUtils.feedbackTypeDislikes,
        actionName: 'dislike',
        authorNpub: authorNpub,
      );

  static RemoteEventActionResult _wrap(dynamic resp) {
    if (resp == null) {
      return const RemoteEventActionResult(
          success: false, error: 'No response');
    }
    Map<String, dynamic>? body;
    try {
      if (resp.body is String && (resp.body as String).isNotEmpty) {
        final decoded = jsonDecode(resp.body);
        if (decoded is Map<String, dynamic>) body = decoded;
      }
    } catch (_) {}
    final success = resp.statusCode >= 200 && resp.statusCode < 300;
    return RemoteEventActionResult(
      success: success,
      statusCode: resp.statusCode,
      body: body,
      error: success
          ? null
          : (body?['error'] as String?) ??
              (resp.body is String
                  ? (resp.body as String).isEmpty
                      ? 'HTTP ${resp.statusCode}'
                      : resp.body as String
                  : 'HTTP ${resp.statusCode}'),
    );
  }
}
