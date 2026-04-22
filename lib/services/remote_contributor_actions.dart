/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Visitor-side helper for submitting media to a remote event's
 * contributor folder. Mirrors `remote_event_actions.dart` but for
 * the upload (write+bytes) flow:
 *
 *   1. Client computes SHA-256 of the file bytes.
 *   2. Builds a kind-1 NOSTR event whose content is that hex digest,
 *      with tags locking the submission to (eventId, filename,
 *      callsign). Signs with the active profile's nsec.
 *   3. POSTs through DevicesService.makeDeviceApiRequest with the
 *      raw file bytes in the body and the signature in headers
 *      (X-Nostr-Npub / -Signature / -Timestamp). Server reconstructs
 *      the same event and verifies — a mismatched filename or
 *      tampered byte stream invalidates.
 *
 * Single-file POST per call. The UI batches multiple files by
 * calling [submitFile] sequentially so progress can be shown
 * per-file and one bad upload doesn't fail the whole batch.
 */

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../services/devices_service.dart';
import '../services/log_service.dart';
import '../services/profile_service.dart';
import '../util/nostr_crypto.dart';
import '../util/nostr_event.dart';

class RemoteContributorSubmitResult {
  final bool success;
  final String filename;
  final int? statusCode;
  final String? status; // 'pending' or 'approved' (server reply)
  final String? error;

  const RemoteContributorSubmitResult({
    required this.success,
    required this.filename,
    this.statusCode,
    this.status,
    this.error,
  });
}

/// One file the visitor has submitted to the event, as reported by
/// the device's signed `/api/events/{id}/contributors/mine` endpoint.
class RemoteMineSubmission {
  final String callsign;
  final String filename;
  final String status; // 'pending' or 'approved'
  const RemoteMineSubmission({
    required this.callsign,
    required this.filename,
    required this.status,
  });
}

class RemoteContributorActions {
  RemoteContributorActions._();

  /// Sign + POST one file. The remote server lands it in
  /// `contributors/_pending/{callsign}/` (or directly in
  /// `contributors/{callsign}/` if the visitor has already been
  /// approved on this event).
  ///
  /// Returns a result with `success=false` and a friendly `error`
  /// when transport, signing, or server validation fails — the
  /// caller surfaces this in a SnackBar / progress UI.
  static Future<RemoteContributorSubmitResult> submitFile({
    required String remoteCallsign,
    required String eventId,
    required String filename,
    required Uint8List bytes,
  }) async {
    if (bytes.isEmpty) {
      return RemoteContributorSubmitResult(
        success: false,
        filename: filename,
        error: 'empty body',
      );
    }
    final profile = ProfileService().getProfile();
    final nsec = profile.nsec;
    final npub = profile.npub;
    final callsign = profile.callsign;
    if (nsec.isEmpty || npub.isEmpty || callsign.isEmpty) {
      return RemoteContributorSubmitResult(
        success: false,
        filename: filename,
        error: 'No local NOSTR identity',
      );
    }

    final createdAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final pubkeyHex = NostrCrypto.decodeNpub(npub);
    final fileHash = sha256.convert(bytes).toString();

    final ev = NostrEvent(
      pubkey: pubkeyHex,
      createdAt: createdAt,
      kind: NostrEventKind.textNote,
      tags: [
        ['e', eventId],
        ['f', filename],
        ['callsign', callsign],
        ['kind', 'event_contribution'],
      ],
      content: fileHash,
    );
    ev.calculateId();
    final signature = ev.signWithNsec(nsec);

    try {
      final resp = await DevicesService().makeDeviceApiRequest(
        callsign: remoteCallsign,
        method: 'POST',
        path: '/api/events/${Uri.encodeComponent(eventId)}'
            '/contributors/${Uri.encodeComponent(callsign)}'
            '/submit/${Uri.encodeComponent(filename)}',
        headers: {
          'Content-Type': 'application/octet-stream',
          'X-Nostr-Npub': npub,
          'X-Nostr-Signature': signature,
          'X-Nostr-Timestamp': createdAt.toString(),
        },
        bodyBytes: bytes,
      );
      if (resp == null) {
        return RemoteContributorSubmitResult(
          success: false,
          filename: filename,
          error: 'Transport unavailable',
        );
      }
      Map<String, dynamic>? body;
      try {
        body = jsonDecode(resp.body) as Map<String, dynamic>;
      } catch (_) {}
      final ok = resp.statusCode == 200 && (body?['success'] == true);
      return RemoteContributorSubmitResult(
        success: ok,
        filename: filename,
        statusCode: resp.statusCode,
        status: body?['status'] as String?,
        error:
            ok ? null : (body?['error'] as String? ?? 'HTTP ${resp.statusCode}'),
      );
    } catch (e) {
      LogService().log('RemoteContributorActions: $filename failed: $e');
      return RemoteContributorSubmitResult(
        success: false,
        filename: filename,
        error: e.toString(),
      );
    }
  }

  /// Sign a contributor_mine_query event and ask the remote device
  /// which submissions belong to the local profile's npub on this
  /// event. Used by the remote event detail page so the visitor sees
  /// their pending uploads even after closing/reopening the app.
  /// Returns an empty list on any failure (no NOSTR identity, server
  /// rejection, transport unavailable).
  static Future<List<RemoteMineSubmission>> fetchMine({
    required String remoteCallsign,
    required String eventId,
  }) async {
    final token = _signMineQuery(eventId);
    if (token == null) return const [];
    try {
      final resp = await DevicesService().makeDeviceApiRequest(
        callsign: remoteCallsign,
        method: 'GET',
        path: '/api/events/${Uri.encodeComponent(eventId)}/contributors/mine',
        headers: {
          'X-Nostr-Npub': token.npub,
          'X-Nostr-Signature': token.signature,
          'X-Nostr-Timestamp': token.createdAt.toString(),
        },
      );
      if (resp == null || resp.statusCode != 200) return const [];
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      final list = body['submissions'] as List<dynamic>? ?? const [];
      final out = <RemoteMineSubmission>[];
      for (final entry in list.whereType<Map<String, dynamic>>()) {
        final callsign = entry['callsign'] as String? ?? '';
        final status = entry['status'] as String? ?? '';
        final files = (entry['files'] as List<dynamic>?) ?? const [];
        for (final f in files) {
          if (f is String && f.isNotEmpty) {
            out.add(RemoteMineSubmission(
              callsign: callsign,
              filename: f,
              status: status,
            ));
          }
        }
      }
      return out;
    } catch (e) {
      LogService().log('RemoteContributorActions.fetchMine: $e');
      return const [];
    }
  }

  /// Signed thumbnail fetch (~480 px JPEG) for a submission belonging
  /// to the local profile's npub. The browser side caches results in
  /// IndexedDB; on Flutter the caller is expected to keep the bytes
  /// in widget state for the session.
  static Future<Uint8List?> fetchMineThumbnail({
    required String remoteCallsign,
    required String eventId,
    required String filename,
  }) async {
    final token = _signMineQuery(eventId);
    if (token == null) return null;
    try {
      final resp = await DevicesService().makeDeviceApiRequestBytes(
        callsign: remoteCallsign,
        method: 'GET',
        path: '/api/events/${Uri.encodeComponent(eventId)}'
            '/contributors/mine/files/${Uri.encodeComponent(filename)}'
            '?thumb=1',
        headers: {
          'X-Nostr-Npub': token.npub,
          'X-Nostr-Signature': token.signature,
          'X-Nostr-Timestamp': token.createdAt.toString(),
        },
      );
      if (resp == null || resp.statusCode != 200) return null;
      return resp.bytes;
    } catch (e) {
      LogService().log('RemoteContributorActions.fetchMineThumbnail: $e');
      return null;
    }
  }

  /// Build + sign the contributor_mine_query event used by both
  /// `fetchMine` and `fetchMineThumbnail`. Same shape the public web
  /// page uses so server verification is identical.
  static _MineToken? _signMineQuery(String eventId) {
    final profile = ProfileService().getProfile();
    final nsec = profile.nsec;
    final npub = profile.npub;
    if (nsec.isEmpty || npub.isEmpty) return null;
    try {
      final pubkeyHex = NostrCrypto.decodeNpub(npub);
      final createdAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final ev = NostrEvent(
        pubkey: pubkeyHex,
        createdAt: createdAt,
        kind: NostrEventKind.textNote,
        tags: [
          ['e', eventId],
          ['kind', 'contributor_mine_query'],
        ],
        content: 'contributor_mine_query',
      );
      ev.calculateId();
      final sig = ev.signWithNsec(nsec);
      return _MineToken(
          npub: npub, signature: sig, createdAt: createdAt);
    } catch (_) {
      return null;
    }
  }
}

class _MineToken {
  final String npub;
  final String signature;
  final int createdAt;
  _MineToken({
    required this.npub,
    required this.signature,
    required this.createdAt,
  });
}
