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
}
