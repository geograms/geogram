/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Event contributor storage layout + helpers.
 *
 * Layout (matches docs/apps/events-format-specification.md §Contributors
 * plus an approval gate):
 *
 *   events/{year}/{eventId}/
 *   ├── contributors/
 *   │   ├── {CALLSIGN}/          ← approved
 *   │   │   ├── contributor.txt  (NOSTR-signed metadata)
 *   │   │   ├── <media files…>
 *   │   │   └── .meta/
 *   │   │       └── {filename}.json  (per-file signing record)
 *   │   └── _pending/            ← awaiting author approval
 *   │       └── {CALLSIGN}/ …    (same shape as approved)
 *
 * Approval is per contributor, not per file: once the author approves
 * CR7BBQ, any subsequent upload from CR7BBQ lands directly under
 * `contributors/CR7BBQ/` and skips `_pending/`.
 */

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../services/profile_storage.dart';
import 'nostr_crypto.dart';
import 'nostr_event.dart';

class ContributorFolderUtils {
  ContributorFolderUtils._();

  static const String contributorsRoot = 'contributors';
  static const String pendingSegment = '_pending';
  static const String metaFolder = '.meta';
  static const String contributorMetaFile = 'contributor.txt';

  // ── Paths ─────────────────────────────────────────────────────────

  /// Folder that collects approved contributor folders.
  static String approvedRoot(String eventPath) =>
      '$eventPath/$contributorsRoot';

  /// Folder that collects pending contributor folders.
  static String pendingRoot(String eventPath) =>
      '$eventPath/$contributorsRoot/$pendingSegment';

  static String approvedFolder(String eventPath, String callsign) =>
      '${approvedRoot(eventPath)}/$callsign';

  static String pendingFolder(String eventPath, String callsign) =>
      '${pendingRoot(eventPath)}/$callsign';

  /// Folder a future submission from [callsign] should land in. If the
  /// author has already approved them, use the top-level folder;
  /// otherwise stage into `_pending/`.
  static Future<String> submissionTarget({
    required String eventPath,
    required String callsign,
    required ProfileStorage storage,
  }) async {
    if (await isApproved(eventPath: eventPath, callsign: callsign, storage: storage)) {
      return approvedFolder(eventPath, callsign);
    }
    return pendingFolder(eventPath, callsign);
  }

  // ── Reads ─────────────────────────────────────────────────────────

  /// True when `contributors/{callsign}/` exists on disk (approved).
  static Future<bool> isApproved({
    required String eventPath,
    required String callsign,
    required ProfileStorage storage,
  }) async {
    return storage.directoryExists(approvedFolder(eventPath, callsign));
  }

  /// Callsigns with approved contributor folders. Excludes the
  /// `_pending` sentinel segment.
  static Future<List<String>> listApprovedCallsigns({
    required String eventPath,
    required ProfileStorage storage,
  }) async {
    final out = <String>[];
    try {
      final entries = await storage.listDirectory(approvedRoot(eventPath));
      for (final entry in entries) {
        if (!entry.isDirectory) continue;
        if (entry.name == pendingSegment) continue;
        out.add(entry.name);
      }
    } catch (_) {}
    out.sort();
    return out;
  }

  /// Callsigns with submissions still awaiting approval.
  static Future<List<String>> listPendingCallsigns({
    required String eventPath,
    required ProfileStorage storage,
  }) async {
    final out = <String>[];
    try {
      final entries = await storage.listDirectory(pendingRoot(eventPath));
      for (final entry in entries) {
        if (!entry.isDirectory) continue;
        out.add(entry.name);
      }
    } catch (_) {}
    out.sort();
    return out;
  }

  /// Media filenames inside a contributor folder. Excludes
  /// `contributor.txt` and the hidden `.meta` folder.
  static Future<List<String>> listMediaFiles({
    required String folderPath,
    required ProfileStorage storage,
  }) async {
    final out = <String>[];
    try {
      final entries = await storage.listDirectory(folderPath);
      for (final entry in entries) {
        if (entry.isDirectory) continue;
        if (entry.name == contributorMetaFile) continue;
        if (entry.name.startsWith('.')) continue;
        out.add(entry.name);
      }
    } catch (_) {}
    out.sort();
    return out;
  }

  /// Parse contributor.txt. Returns null when missing or unreadable.
  static Future<ContributorMeta?> readMeta({
    required String folderPath,
    required ProfileStorage storage,
  }) async {
    final content =
        await storage.readString('$folderPath/$contributorMetaFile');
    if (content == null || content.trim().isEmpty) return null;
    return ContributorMeta.parse(content);
  }

  // ── Writes ────────────────────────────────────────────────────────

  /// Write / overwrite `contributor.txt` for a contributor folder.
  static Future<void> writeMeta({
    required String folderPath,
    required ContributorMeta meta,
    required ProfileStorage storage,
  }) async {
    await storage.writeString(
        '$folderPath/$contributorMetaFile', meta.serialize());
  }

  /// Store a submitted file + its signing record. Safe to call for
  /// both pending and already-approved submissions — the caller picks
  /// the target folder via [submissionTarget].
  static Future<void> writeSubmission({
    required String folderPath,
    required String filename,
    required Uint8List bytes,
    required SubmissionRecord signing,
    required ProfileStorage storage,
  }) async {
    await storage.writeBytes('$folderPath/$filename', bytes);
    await storage.writeString(
      '$folderPath/$metaFolder/$filename.json',
      const JsonEncoder.withIndent('  ').convert(signing.toJson()),
    );
  }

  /// Move `_pending/{callsign}` into `contributors/{callsign}`. Files
  /// already present in the target are overwritten so a re-approval
  /// after correction stays consistent. Returns true when something
  /// was moved.
  static Future<bool> approve({
    required String eventPath,
    required String callsign,
    required ProfileStorage storage,
  }) async {
    final from = pendingFolder(eventPath, callsign);
    if (!await storage.directoryExists(from)) return false;
    final to = approvedFolder(eventPath, callsign);
    await _copyTree(from: from, to: to, storage: storage);
    await storage.deleteDirectory(from, recursive: true);
    return true;
  }

  /// Discard a pending contributor's submission.
  static Future<bool> reject({
    required String eventPath,
    required String callsign,
    required ProfileStorage storage,
  }) async {
    final from = pendingFolder(eventPath, callsign);
    if (!await storage.directoryExists(from)) return false;
    await storage.deleteDirectory(from, recursive: true);
    return true;
  }

  /// Revoke an already-approved contributor. Their folder moves back
  /// under `_pending/` so the author can inspect it again or reject
  /// it cleanly via [reject].
  static Future<bool> revoke({
    required String eventPath,
    required String callsign,
    required ProfileStorage storage,
  }) async {
    final from = approvedFolder(eventPath, callsign);
    if (!await storage.directoryExists(from)) return false;
    final to = pendingFolder(eventPath, callsign);
    await _copyTree(from: from, to: to, storage: storage);
    await storage.deleteDirectory(from, recursive: true);
    return true;
  }

  /// Recursively copy every file under [from] into [to]. The
  /// ProfileStorage interface has no native move/rename so we read
  /// and rewrite — fine for contributor folders, which are small
  /// (handful of photos / short clips).
  static Future<void> _copyTree({
    required String from,
    required String to,
    required ProfileStorage storage,
  }) async {
    final entries = await storage.listDirectory(from, recursive: true);
    for (final entry in entries) {
      if (entry.isDirectory) continue;
      final relative = entry.path.substring(from.length).replaceFirst(
            RegExp(r'^/+'),
            '',
          );
      final bytes = await storage.readBytes(entry.path);
      if (bytes == null) continue;
      await storage.writeBytes('$to/$relative', bytes);
    }
  }

  // ── Signature verification ────────────────────────────────────────

  /// Reconstruct the NOSTR kind-1 event the client signed for this
  /// upload and verify it. The client computes SHA-256 of the file
  /// bytes and signs an event whose content is that hex digest, with
  /// tags locking the submission to a specific event + filename +
  /// callsign. Any tampering (wrong file, wrong filename, replay onto
  /// a different event) invalidates the signature.
  static bool verifySubmissionSignature({
    required String npub,
    required String signatureHex,
    required int createdAt,
    required String eventId,
    required String callsign,
    required String filename,
    required Uint8List fileBytes,
  }) {
    try {
      final pubkeyHex = NostrCrypto.decodeNpub(npub);
      final hash = sha256.convert(fileBytes).toString();
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
        content: hash,
      );
      ev.calculateId();
      ev.sig = signatureHex;
      return ev.verify();
    } catch (_) {
      return false;
    }
  }
}

/// Parsed view of `contributor.txt`.
class ContributorMeta {
  final String callsign;
  final String created;
  final String description;
  final String? npub;
  final String? signature;

  ContributorMeta({
    required this.callsign,
    required this.created,
    this.description = '',
    this.npub,
    this.signature,
  });

  String serialize() {
    final buf = StringBuffer();
    buf.writeln('# CONTRIBUTOR: $callsign');
    buf.writeln();
    buf.writeln('CREATED: $created');
    if (description.trim().isNotEmpty) {
      buf.writeln();
      buf.writeln(description.trim());
    }
    if (npub != null || signature != null) {
      buf.writeln();
      if (npub != null) buf.writeln('--> npub: $npub');
      if (signature != null) buf.writeln('--> signature: $signature');
    }
    return buf.toString();
  }

  /// Loose parser — accepts any ordering of `--> key: value` footers.
  /// Anything between the CREATED line and the `-->` footer becomes
  /// the description.
  static ContributorMeta parse(String text) {
    String callsign = '';
    String created = '';
    String? npub;
    String? signature;
    final descLines = <String>[];
    var sawCreated = false;

    for (final raw in text.split('\n')) {
      final line = raw.trimRight();
      if (line.startsWith('# CONTRIBUTOR:')) {
        callsign = line.substring('# CONTRIBUTOR:'.length).trim();
        continue;
      }
      if (line.startsWith('CREATED:')) {
        created = line.substring('CREATED:'.length).trim();
        sawCreated = true;
        continue;
      }
      if (line.startsWith('--> npub:')) {
        npub = line.substring('--> npub:'.length).trim();
        continue;
      }
      if (line.startsWith('--> signature:')) {
        signature = line.substring('--> signature:'.length).trim();
        continue;
      }
      if (sawCreated) descLines.add(line);
    }
    return ContributorMeta(
      callsign: callsign,
      created: created,
      description: descLines.join('\n').trim(),
      npub: npub,
      signature: signature,
    );
  }
}

/// Per-file signing record stored alongside each uploaded file in
/// `.meta/{filename}.json`. Lets the server replay the verification
/// later and lets the author see who signed what.
class SubmissionRecord {
  final String npub;
  final String signature;
  final int createdAt;
  final String fileHash; // sha-256 hex of the raw bytes
  final int fileSize;

  SubmissionRecord({
    required this.npub,
    required this.signature,
    required this.createdAt,
    required this.fileHash,
    required this.fileSize,
  });

  Map<String, dynamic> toJson() => {
        'npub': npub,
        'signature': signature,
        'created_at': createdAt,
        'file_hash': fileHash,
        'file_size': fileSize,
      };
}
