/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Reusable engagement actions for a blog post hosted on another
 * device. Signs NOSTR events with the local profile's keys and
 * relays them through DevicesService.makeDeviceApiRequest, so every
 * caller (the remote-blog detail page UI, the debug API, any future
 * bot / test harness) uses the same wire format the server expects.
 */

import 'dart:convert';

import '../services/devices_service.dart';
import '../services/log_service.dart';
import '../services/profile_service.dart';
import '../util/feedback_folder_utils.dart';
import '../util/nostr_crypto.dart';
import '../util/nostr_event.dart';

/// Result of a remote blog action. [body] is the parsed JSON when the
/// remote returned JSON; [statusCode] is the HTTP status; [error]
/// carries a human-readable reason when [success] is false.
class RemoteBlogActionResult {
  final bool success;
  final int? statusCode;
  final String? error;
  final Map<String, dynamic>? body;

  const RemoteBlogActionResult({
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

class RemoteBlogActions {
  RemoteBlogActions._();

  // ─────────────────────────── reads ───────────────────────────

  /// Fetch a post's full detail (content + counts + comments) from a
  /// remote device through ConnectionManager.
  static Future<RemoteBlogActionResult> fetchDetail({
    required String remoteCallsign,
    required String postId,
  }) async {
    try {
      final resp = await DevicesService().makeDeviceApiRequest(
        callsign: remoteCallsign,
        method: 'GET',
        path: '/api/blog/$postId',
      );
      if (resp == null) {
        return const RemoteBlogActionResult(
          success: false, error: 'No response from device');
      }
      if (resp.statusCode != 200) {
        return RemoteBlogActionResult(
          success: false,
          statusCode: resp.statusCode,
          error: 'Remote returned ${resp.statusCode}',
        );
      }
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      return RemoteBlogActionResult(
          success: data['success'] == true,
          statusCode: resp.statusCode,
          body: data,
          error: data['success'] == true
              ? null
              : (data['error'] as String?));
    } catch (e) {
      return RemoteBlogActionResult(success: false, error: e.toString());
    }
  }

  // ─────────────────────────── writes ──────────────────────────

  /// Sign a kind-7 reaction event with the active profile's keys and
  /// POST it to the remote device.
  ///
  /// [feedbackType] is the value stored in the `type` tag — one of
  /// the [FeedbackFolderUtils] constants (likes / dislikes / points /
  /// subscribe) or a supported emoji reaction name.
  /// [actionName] is the URL sub-path and the event content. Use
  /// `'reaction'` for emoji reactions; the URL becomes
  /// `/api/blog/{postId}/react/{emoji}` in that case.
  static Future<RemoteBlogActionResult> sendFeedback({
    required String remoteCallsign,
    required String postId,
    required String feedbackType,
    required String actionName,
    String? authorNpub,
  }) async {
    try {
      final profile = ProfileService().getProfile();
      if (profile.npub.isEmpty || profile.nsec.isEmpty) {
        return const RemoteBlogActionResult(
          success: false, error: 'NOSTR key required');
      }

      final pubkeyHex = NostrCrypto.decodeNpub(profile.npub);
      final event = NostrEvent(
        pubkey: pubkeyHex,
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        kind: NostrEventKind.reaction,
        tags: [
          ['p', authorNpub ?? ''],
          ['e', postId],
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
        path: '/api/blog/$postId/$subPath',
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(event.toJson()),
      );
      return _wrap(resp);
    } catch (e) {
      LogService().log('RemoteBlogActions.sendFeedback: $e');
      return RemoteBlogActionResult(success: false, error: e.toString());
    }
  }

  /// Sign a kind-1 comment event and POST it with the
  /// `{author, content, npub, signature}` shape the server expects.
  static Future<RemoteBlogActionResult> sendComment({
    required String remoteCallsign,
    required String postId,
    required String content,
  }) async {
    try {
      if (content.trim().isEmpty) {
        return const RemoteBlogActionResult(
          success: false, error: 'Empty comment');
      }
      final profile = ProfileService().getProfile();
      if (profile.npub.isEmpty || profile.nsec.isEmpty) {
        return const RemoteBlogActionResult(
          success: false, error: 'NOSTR key required');
      }

      final pubkeyHex = NostrCrypto.decodeNpub(profile.npub);
      final createdAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final event = NostrEvent(
        pubkey: pubkeyHex,
        createdAt: createdAt,
        kind: 1,
        tags: [
          ['e', postId],
          ['t', 'blog-comment'],
          ['callsign', profile.callsign],
        ],
        content: content,
      );
      event.calculateId();
      event.signWithNsec(profile.nsec);

      final resp = await DevicesService().makeDeviceApiRequest(
        callsign: remoteCallsign,
        method: 'POST',
        path: '/api/blog/$postId/comment',
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'author': profile.callsign,
          'content': content,
          'npub': profile.npub,
          'signature': event.sig,
          // `created_at` must travel with the comment — the server
          // reconstructs the canonical NOSTR event to verify the sig
          // and the timestamp is part of the event ID. Without it, a
          // server-side `DateTime.now()` produces a different ID and
          // verification always fails.
          'created_at': createdAt,
        }),
      );
      return _wrap(resp);
    } catch (e) {
      LogService().log('RemoteBlogActions.sendComment: $e');
      return RemoteBlogActionResult(success: false, error: e.toString());
    }
  }

  /// Sign a kind-1 view event and record it on the remote device via
  /// the shared feedback endpoint.
  static Future<RemoteBlogActionResult> recordView({
    required String remoteCallsign,
    required String postId,
  }) async {
    try {
      final profile = ProfileService().getProfile();
      if (profile.npub.isEmpty || profile.nsec.isEmpty) {
        return const RemoteBlogActionResult(
            success: false, error: 'NOSTR key required');
      }
      final pubkeyHex = NostrCrypto.decodeNpub(profile.npub);
      final event = NostrEvent(
        pubkey: pubkeyHex,
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        kind: 1,
        tags: [
          ['t', 'blog-view'],
          ['e', postId],
          ['callsign', profile.callsign],
        ],
        content: '',
      );
      event.calculateId();
      event.signWithNsec(profile.nsec);
      final resp = await DevicesService().makeDeviceApiRequest(
        callsign: remoteCallsign,
        method: 'POST',
        path: '/api/feedback/blog/$postId/view',
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(event.toJson()),
      );
      return _wrap(resp);
    } catch (e) {
      LogService().log('RemoteBlogActions.recordView: $e');
      return RemoteBlogActionResult(success: false, error: e.toString());
    }
  }

  static RemoteBlogActionResult _wrap(dynamic resp) {
    if (resp == null) {
      return const RemoteBlogActionResult(
          success: false, error: 'No response');
    }
    Map<String, dynamic>? body;
    try {
      if (resp.body is String && resp.body.isNotEmpty) {
        final decoded = jsonDecode(resp.body);
        if (decoded is Map<String, dynamic>) body = decoded;
      }
    } catch (_) {}
    final success = resp.statusCode >= 200 && resp.statusCode < 300;
    return RemoteBlogActionResult(
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
