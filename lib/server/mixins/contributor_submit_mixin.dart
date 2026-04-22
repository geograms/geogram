/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Shared write-side for event contributor submissions.
 *
 * Both HTTP surfaces (lib/station.dart raw HttpServer and
 * lib/services/log_api_service.dart shelf) mix this in. The route
 * handled is:
 *
 *   POST /api/events/{eventId}/contributors/{callsign}/submit/{filename}
 *
 * Body:   raw file bytes (no multipart — one file per POST).
 * Headers (required):
 *   X-Nostr-Npub        visitor's NOSTR public key (npub1…)
 *   X-Nostr-Signature   Schnorr signature in hex
 *   X-Nostr-Timestamp   unix seconds used at signing time
 *
 * The signature covers a synthetic kind-1 NOSTR event whose content
 * is the SHA-256 hex digest of the file bytes, with tags locking
 * submission to this eventId + filename + callsign. Server
 * reconstructs the same event, verifies, and rejects any mismatch.
 *
 * Landing folder:
 *   events/{year}/{eventId}/contributors/_pending/{CALLSIGN}/{filename}
 * unless the callsign is already approved (folder exists under
 *   events/{year}/{eventId}/contributors/{CALLSIGN}/
 * ) in which case files land directly there.
 *
 * Read-side (display + thumbnails) already works through
 * EventContentProvider + the station's _handleEventFileServe — the
 * relative path `contributors/CALLSIGN/filename.jpg` resolves inside
 * the event folder the same way flyer/photo files do.
 */

import 'dart:convert';
import 'dart:io' if (dart.library.html) '../../platform/io_stub.dart';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart' as shelf;

import '../../services/profile_storage.dart';
import '../../util/contributor_folder_utils.dart';
import '../../util/nostr_crypto.dart';
import '../../util/nostr_event.dart';

/// Per-file size limit. 50 MB is generous enough for any modern
/// phone photo and short video clips, and bounds the blast radius
/// of a malicious caller.
const int _maxSubmissionBytes = 50 * 1024 * 1024;

/// Supported submission extensions — union of the gallery image
/// and short-video types the rest of the event surface already
/// handles. Kept conservative; anything else gets a 415.
const Set<String> _allowedExtensions = {
  '.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp',
  '.mp4', '.mov', '.webm', '.mkv', '.avi', '.wmv', '.flv',
};

class ContributorSubmitResult {
  final int statusCode;
  final Map<String, dynamic> body;
  ContributorSubmitResult(this.statusCode, this.body);
}

mixin ContributorSubmitMixin {
  /// Storage rooted at the per-callsign device folder (same shape
  /// as [ContentBrowseMixin.contentBrowseStorage]).
  ProfileStorage get contributorStorage;

  /// Fired after a new submission lands in `_pending/` so the
  /// implementing class can raise a Now-panel notification / poke
  /// the activity notifier. Called with the event path (relative
  /// to storage) and the contributor's callsign.
  void onContributionSubmitted(String eventPath, String callsign) {}

  void contributorLog(String level, String message) {
    // ignore: avoid_print
    print('[$level] Contributor: $message');
  }

  // ── HttpRequest (station.dart) ────────────────────────────────────

  /// Returns true when the request matched and was handled (caller
  /// must return from its dispatcher afterwards); false otherwise.
  Future<bool> handleContributorRequest(HttpRequest request) async {
    final mineParsed = _parseMinePath(request.uri.path);
    if (mineParsed != null) {
      final headers = <String, String>{};
      request.headers.forEach((name, values) {
        headers[name.toLowerCase()] = values.isEmpty ? '' : values.first;
      });
      final result = await _processMineQuery(
        eventId: mineParsed,
        method: request.method,
        headers: headers,
      );
      _writeHttpJson(request, result.statusCode, result.body);
      return true;
    }

    final parsed = _parsePath(request.uri.path);
    if (parsed == null) return false;

    if (request.method != 'POST') {
      _writeHttpJson(request, 405, {'error': 'Method not allowed'});
      return true;
    }

    try {
      final bytes = await _readBodyBytes(request);
      final headers = <String, String>{};
      request.headers.forEach((name, values) {
        headers[name.toLowerCase()] = values.isEmpty ? '' : values.first;
      });
      final result = await _process(
        eventId: parsed.eventId,
        callsign: parsed.callsign,
        filename: parsed.filename,
        bytes: bytes,
        headers: headers,
      );
      _writeHttpJson(request, result.statusCode, result.body);
    } on _BodyTooLarge {
      _writeHttpJson(request, 413, {
        'error': 'Payload too large',
        'max_bytes': _maxSubmissionBytes,
      });
    } catch (e) {
      contributorLog('ERROR', 'Submission failed: $e');
      _writeHttpJson(request, 500, {'error': 'Internal server error'});
    }
    return true;
  }

  // ── shelf.Request (log_api_service.dart) ──────────────────────────

  /// Returns a shelf.Response when the URL matched; null so the
  /// caller keeps its own dispatch chain alive otherwise.
  Future<shelf.Response?> handleContributorShelf(
    shelf.Request request,
    String urlPath,
  ) async {
    if (!urlPath.startsWith('api/events/')) return null;

    // GET /api/events/{id}/contributors/mine — visitor inspects their
    // own submissions (pending + approved). NOSTR-signed query via
    // headers; server returns only folders whose contributor.txt npub
    // matches the signing npub.
    final mineEvent = _parseMinePath('/$urlPath');
    if (mineEvent != null) {
      final headers = <String, String>{};
      request.headers.forEach((name, value) {
        headers[name.toLowerCase()] = value;
      });
      final result = await _processMineQuery(
        eventId: mineEvent,
        method: request.method,
        headers: headers,
      );
      return shelf.Response(
        result.statusCode,
        body: jsonEncode(result.body),
        headers: const {'Content-Type': 'application/json'},
      );
    }

    final parsed = _parsePath('/$urlPath');
    if (parsed == null) return null;

    if (request.method != 'POST') {
      return shelf.Response(
        405,
        body: jsonEncode({'error': 'Method not allowed'}),
        headers: const {'Content-Type': 'application/json'},
      );
    }

    try {
      final bytesList = await request.read().fold<List<int>>([], (acc, chunk) {
        if (acc.length + chunk.length > _maxSubmissionBytes) {
          throw _BodyTooLarge();
        }
        acc.addAll(chunk);
        return acc;
      });
      final bytes = Uint8List.fromList(bytesList);
      final headers = <String, String>{};
      request.headers.forEach((name, value) {
        headers[name.toLowerCase()] = value;
      });
      final result = await _process(
        eventId: parsed.eventId,
        callsign: parsed.callsign,
        filename: parsed.filename,
        bytes: bytes,
        headers: headers,
      );
      return shelf.Response(
        result.statusCode,
        body: jsonEncode(result.body),
        headers: const {'Content-Type': 'application/json'},
      );
    } on _BodyTooLarge {
      return shelf.Response(
        413,
        body: jsonEncode({'error': 'Payload too large', 'max_bytes': _maxSubmissionBytes}),
        headers: const {'Content-Type': 'application/json'},
      );
    } catch (e) {
      contributorLog('ERROR', 'Submission failed: $e');
      return shelf.Response(
        500,
        body: jsonEncode({'error': 'Internal server error'}),
        headers: const {'Content-Type': 'application/json'},
      );
    }
  }

  // ── shared ────────────────────────────────────────────────────────

  Future<ContributorSubmitResult> _process({
    required String eventId,
    required String callsign,
    required String filename,
    required Uint8List bytes,
    required Map<String, String> headers,
  }) async {
    if (!_validCallsign(callsign)) {
      return ContributorSubmitResult(400, {'error': 'Invalid callsign'});
    }
    if (!_validFilename(filename)) {
      return ContributorSubmitResult(400, {'error': 'Invalid filename'});
    }
    final ext = _extensionOf(filename);
    if (!_allowedExtensions.contains(ext)) {
      return ContributorSubmitResult(415, {
        'error': 'Unsupported file type',
        'extension': ext,
      });
    }
    if (bytes.isEmpty) {
      return ContributorSubmitResult(400, {'error': 'Empty body'});
    }
    if (bytes.length > _maxSubmissionBytes) {
      return ContributorSubmitResult(413, {
        'error': 'Payload too large',
        'max_bytes': _maxSubmissionBytes,
      });
    }

    final npub = headers['x-nostr-npub'] ?? '';
    final signature = headers['x-nostr-signature'] ?? '';
    final tsStr = headers['x-nostr-timestamp'] ?? '';
    if (npub.isEmpty || signature.isEmpty || tsStr.isEmpty) {
      return ContributorSubmitResult(401, {
        'error': 'Missing NOSTR signature headers',
      });
    }
    final createdAt = int.tryParse(tsStr);
    if (createdAt == null) {
      return ContributorSubmitResult(400, {'error': 'Invalid timestamp'});
    }

    final storage = contributorStorage;
    final eventPath = await _resolveEventPath(storage, eventId);
    if (eventPath == null) {
      return ContributorSubmitResult(404, {'error': 'Event not found'});
    }

    final ok = ContributorFolderUtils.verifySubmissionSignature(
      npub: npub,
      signatureHex: signature,
      createdAt: createdAt,
      eventId: eventId,
      callsign: callsign,
      filename: filename,
      fileBytes: bytes,
    );
    if (!ok) {
      return ContributorSubmitResult(403, {'error': 'Signature verification failed'});
    }

    final targetFolder = await ContributorFolderUtils.submissionTarget(
      eventPath: eventPath,
      callsign: callsign,
      storage: storage,
    );
    final approved = targetFolder ==
        ContributorFolderUtils.approvedFolder(eventPath, callsign);

    // Write a contributor.txt on first upload if one doesn't exist
    // yet, so the author has something to look at in the approval UI
    // even before the contributor fills in a description.
    if (!await storage.exists(
      '$targetFolder/${ContributorFolderUtils.contributorMetaFile}',
    )) {
      await ContributorFolderUtils.writeMeta(
        folderPath: targetFolder,
        storage: storage,
        meta: ContributorMeta(
          callsign: callsign,
          created: DateTime.now().toUtc().toIso8601String(),
          npub: npub,
        ),
      );
    }

    final fileHash = _sha256Hex(bytes);
    await ContributorFolderUtils.writeSubmission(
      folderPath: targetFolder,
      filename: filename,
      bytes: bytes,
      storage: storage,
      signing: SubmissionRecord(
        npub: npub,
        signature: signature,
        createdAt: createdAt,
        fileHash: fileHash,
        fileSize: bytes.length,
      ),
    );

    if (!approved) {
      onContributionSubmitted(eventPath, callsign);
    }

    return ContributorSubmitResult(200, {
      'success': true,
      'status': approved ? 'approved' : 'pending',
      'filename': filename,
      'bytes': bytes.length,
      'sha256': fileHash,
    });
  }

  /// Parse `/api/events/{id}/contributors/{callsign}/submit/{filename}`
  /// Returns null for anything that doesn't fit. All components are
  /// URL-decoded.
  _SubmitPath? _parsePath(String path) {
    if (!path.startsWith('/api/events/')) return null;
    final trimmed = path.substring('/api/events/'.length);
    final parts = trimmed.split('/');
    if (parts.length < 5) return null;
    if (parts[1] != 'contributors') return null;
    if (parts[3] != 'submit') return null;
    final eventId = Uri.decodeComponent(parts[0]);
    final callsign = Uri.decodeComponent(parts[2]).toUpperCase();
    final filename = Uri.decodeComponent(parts.sublist(4).join('/'));
    if (eventId.isEmpty || callsign.isEmpty || filename.isEmpty) {
      return null;
    }
    return _SubmitPath(
        eventId: eventId, callsign: callsign, filename: filename);
  }

  /// Parse `/api/events/{id}/contributors/mine` → eventId, or null.
  String? _parseMinePath(String path) {
    if (!path.startsWith('/api/events/')) return null;
    final trimmed = path.substring('/api/events/'.length);
    final parts = trimmed.split('/');
    if (parts.length != 3) return null;
    if (parts[1] != 'contributors') return null;
    if (parts[2] != 'mine') return null;
    final eventId = Uri.decodeComponent(parts[0]);
    if (eventId.isEmpty) return null;
    return eventId;
  }

  /// Visitor-side "what did I submit?" query. Verifies a NOSTR-
  /// signed kind-1 event passed in headers (X-Nostr-Npub /
  /// -Signature / -Timestamp), then enumerates every contributor
  /// folder for this event whose contributor.txt npub matches.
  ///
  /// Used by the public event page so a visitor reloading the
  /// browser still sees what they previously submitted, even when
  /// IndexedDB has been cleared or they're on a different machine.
  /// Approved entries are also returned so the page can stop
  /// showing "awaiting approval" rows that have since been approved.
  Future<ContributorSubmitResult> _processMineQuery({
    required String eventId,
    required String method,
    required Map<String, String> headers,
  }) async {
    if (method != 'GET') {
      return ContributorSubmitResult(405, {'error': 'Method not allowed'});
    }
    final npub = headers['x-nostr-npub'] ?? '';
    final signature = headers['x-nostr-signature'] ?? '';
    final tsStr = headers['x-nostr-timestamp'] ?? '';
    if (npub.isEmpty || signature.isEmpty || tsStr.isEmpty) {
      return ContributorSubmitResult(401, {
        'error': 'Missing NOSTR signature headers',
      });
    }
    final createdAt = int.tryParse(tsStr);
    if (createdAt == null) {
      return ContributorSubmitResult(400, {'error': 'Invalid timestamp'});
    }

    // Verify a kind-1 event whose tags lock it to this event id +
    // this query intent. Fixed `content` so the signing payload is
    // deterministic.
    try {
      final pubkeyHex = NostrCrypto.decodeNpub(npub);
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
      ev.sig = signature;
      if (!ev.verify()) {
        return ContributorSubmitResult(403, {
          'error': 'Signature verification failed',
        });
      }
    } catch (_) {
      return ContributorSubmitResult(403, {
        'error': 'Signature verification failed',
      });
    }

    final storage = contributorStorage;
    final eventPath = await _resolveEventPath(storage, eventId);
    if (eventPath == null) {
      return ContributorSubmitResult(404, {'error': 'Event not found'});
    }

    Future<List<Map<String, dynamic>>> scan({
      required Future<List<String>> Function() listCallsigns,
      required String Function(String callsign) folderFor,
      required String status,
    }) async {
      final callsigns = await listCallsigns();
      final out = <Map<String, dynamic>>[];
      for (final callsign in callsigns) {
        final folder = folderFor(callsign);
        final meta = await ContributorFolderUtils.readMeta(
          folderPath: folder,
          storage: storage,
        );
        if (meta?.npub != npub) continue; // not this visitor
        final files = await ContributorFolderUtils.listMediaFiles(
          folderPath: folder,
          storage: storage,
        );
        if (files.isEmpty) continue;
        out.add({
          'callsign': callsign,
          'status': status,
          'files': files,
          if (meta?.created.isNotEmpty == true) 'created': meta!.created,
        });
      }
      return out;
    }

    final pending = await scan(
      listCallsigns: () => ContributorFolderUtils.listPendingCallsigns(
        eventPath: eventPath, storage: storage,
      ),
      folderFor: (c) =>
          ContributorFolderUtils.pendingFolder(eventPath, c),
      status: 'pending',
    );
    final approved = await scan(
      listCallsigns: () => ContributorFolderUtils.listApprovedCallsigns(
        eventPath: eventPath, storage: storage,
      ),
      folderFor: (c) =>
          ContributorFolderUtils.approvedFolder(eventPath, c),
      status: 'approved',
    );

    return ContributorSubmitResult(200, {
      'success': true,
      'event_id': eventId,
      'npub': npub,
      'submissions': [...pending, ...approved],
    });
  }

  /// Locate the event folder relative to the storage root (e.g.
  /// `events/2026/2026-04-21_Tree house`). Mirrors the scan used by
  /// EventContentProvider so new features stay consistent.
  Future<String?> _resolveEventPath(
      ProfileStorage storage, String eventId) async {
    try {
      final entries = await storage.listDirectory('events', recursive: true);
      for (final entry in entries) {
        if (entry.isDirectory) continue;
        if (!entry.name.endsWith('event.txt')) continue;
        final parts = entry.path.split('/');
        final idIdx = parts.lastIndexOf('event.txt') - 1;
        if (idIdx < 0) continue;
        if (parts[idIdx] != eventId) continue;
        return entry.path.replaceAll(RegExp(r'/event\.txt$'), '');
      }
    } catch (_) {}
    return null;
  }

  Future<Uint8List> _readBodyBytes(HttpRequest request) async {
    final contentLength = request.contentLength;
    if (contentLength > _maxSubmissionBytes) {
      throw _BodyTooLarge();
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request) {
      if (builder.length + chunk.length > _maxSubmissionBytes) {
        throw _BodyTooLarge();
      }
      builder.add(chunk);
    }
    return builder.toBytes();
  }

  void _writeHttpJson(
      HttpRequest request, int statusCode, Map<String, dynamic> body) {
    request.response.statusCode = statusCode;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
  }

  bool _validCallsign(String callsign) {
    if (callsign.isEmpty || callsign.length > 64) return false;
    return RegExp(r'^[A-Z0-9_-]+$').hasMatch(callsign);
  }

  bool _validFilename(String filename) {
    if (filename.isEmpty || filename.length > 255) return false;
    if (filename.contains('..') ||
        filename.contains('/') ||
        filename.contains('\\')) {
      return false;
    }
    if (filename.startsWith('.')) return false;
    return true;
  }

  String _extensionOf(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return '';
    return name.substring(dot).toLowerCase();
  }

  String _sha256Hex(Uint8List bytes) => sha256.convert(bytes).toString();
}

class _SubmitPath {
  final String eventId;
  final String callsign;
  final String filename;
  _SubmitPath({
    required this.eventId,
    required this.callsign,
    required this.filename,
  });
}

class _BodyTooLarge implements Exception {}
