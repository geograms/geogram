/*
 * WappSigningService — signs a wapp package with the active profile's
 * NOSTR identity and writes a `signature.json` sidecar.
 *
 * The signature is a NIP-78 (kind 30078) NostrEvent whose `content`
 * is the hex-encoded SHA256 of a canonical hash manifest — a JSON
 * map of every file in the wapp folder (sorted by path) to its own
 * SHA256. Signing uses the active profile's nsec; verification is a
 * future phase (see docs/plan/wapp-signing.md).
 *
 * This is phase 1 of the signing plan: sign on install and on
 * launcher scan (for built-ins missing a signature), then surface
 * the signer's npub on store cards and launcher tiles. Tamper
 * verification, trust anchors, and relay republish are all later.
 */

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../util/nostr_crypto.dart';
import '../util/nostr_event.dart';
import 'profile_service.dart';
import 'profile_storage.dart';

class WappSigningService {
  WappSigningService._();
  static final WappSigningService instance = WappSigningService._();

  /// Read the `signature.json` sidecar (if present) and return the
  /// publisher's npub. Returns empty string when the file is missing
  /// or the JSON is malformed — absent ≠ broken, callers decide how
  /// to surface the difference.
  Future<String> readPublisherNpub(ProfileStorage pkg) async {
    try {
      final json = await pkg.readJson('signature.json');
      if (json == null) return '';
      final npub = json['publisher_npub'];
      if (npub is String) return npub;
    } catch (_) {}
    return '';
  }

  /// Sync variant of [readPublisherNpub] — used from launcher scan
  /// where the UI thread wants a quick check without awaiting.
  String readPublisherNpubSync(ProfileStorage pkg) {
    try {
      final bytes = pkg.readBytesSync('signature.json');
      if (bytes == null) return '';
      final json =
          jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final npub = json['publisher_npub'];
      if (npub is String) return npub;
    } catch (_) {}
    return '';
  }

  /// Build a canonical hash manifest for [pkg] — a sorted map of
  /// relative-path → SHA256 hex for every regular file inside the
  /// package, excluding `signature.json` itself (which would create
  /// a chicken-and-egg problem) and any transient build artefacts.
  Future<Map<String, String>> computeHashes(ProfileStorage pkg) async {
    final hashes = <String, String>{};
    if (!await pkg.directoryExists('')) return hashes;
    final entries = await pkg.listDirectory('', recursive: true);
    for (final entry in entries) {
      if (entry.isDirectory) continue;
      final path = entry.path;
      if (path == 'signature.json') continue;
      if (path.endsWith('/signature.json')) continue;
      // Skip build-time noise — we only care about shipped content.
      if (path.endsWith('.o') || path.endsWith('.wasm.tmp')) continue;
      final bytes = await pkg.readBytes(path);
      if (bytes == null) continue;
      hashes[path] = sha256.convert(bytes).toString();
    }
    return hashes;
  }

  /// Encode [hashes] as a deterministic JSON byte string. Sorted
  /// keys, no whitespace, no trailing newline — so two hosts hashing
  /// the same file set produce byte-identical output.
  Uint8List canonicalManifestBytes(Map<String, String> hashes) {
    final sorted = <String, String>{};
    final keys = hashes.keys.toList()..sort();
    for (final k in keys) {
      sorted[k] = hashes[k]!;
    }
    final text = jsonEncode(sorted);
    return Uint8List.fromList(utf8.encode(text));
  }

  /// Sign [pkg] with the currently-active profile's nsec and write a
  /// `signature.json` sidecar. Returns true on success, false when no
  /// profile is active or something in the hashing / signing step
  /// fails (e.g. the package dir is unwriteable). Errors are
  /// swallowed intentionally — signing is best-effort in phase 1.
  Future<bool> signPackage(
    ProfileStorage pkg, {
    required String wappId,
    String wappVersion = '1.0.0',
  }) async {
    final profile = ProfileService.instance.activeProfile;
    if (profile == null) return false;
    final nsec = profile.nsec;
    if (nsec.isEmpty) return false;

    try {
      final pubkeyHex = NostrCrypto.decodeNsec(nsec);
      final pubkey = NostrCrypto.derivePublicKey(pubkeyHex);
      final hashes = await computeHashes(pkg);
      if (hashes.isEmpty) return false;

      final canonical = canonicalManifestBytes(hashes);
      final digestHex = sha256.convert(canonical).toString();
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      final event = NostrEvent(
        pubkey: pubkey,
        createdAt: now,
        kind: NostrEventKind.applicationSpecificData,
        tags: [
          ['d', 'geogram.wapp:$wappId'],
          ['t', 'geogram-wapp-signature'],
          ['wapp_id', wappId],
          ['wapp_version', wappVersion],
          ['manifest_digest', digestHex],
        ],
        content: digestHex,
      );
      event.sign(pubkeyHex);

      final sig = <String, dynamic>{
        'schema': 'geogram.wapp.signature/1',
        'wapp_id': wappId,
        'wapp_version': wappVersion,
        'signed_at': now,
        'publisher_npub': profile.npub,
        'publisher_hex': pubkey,
        'hash_algo': 'sha256',
        'manifest_digest_hex': digestHex,
        'hashes': hashes,
        'event': event.toJson(),
      };
      await pkg.writeJson('signature.json', sig);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// True when the package already has a valid-shape signature.json
  /// on disk. Does NOT run cryptographic verification — that's phase
  /// 2. Used by the launcher scan to decide whether to backfill.
  Future<bool> isSigned(ProfileStorage pkg) async {
    return (await readPublisherNpub(pkg)).isNotEmpty;
  }
}
