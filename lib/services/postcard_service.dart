/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import '../models/postcard.dart';
import '../services/profile_service.dart';
import '../util/nostr_event.dart';
import '../util/nostr_crypto.dart';
import 'profile_storage.dart';

/// Service for managing postcards (sneakernet message delivery).
///
/// Storage layout (spec v2.0):
///
///   postcards/
///   └── postcard-{CALLSIGN}_YYYY-MM-DD_{ABCD}.txt
///
/// One postcard = one file. No per-message folder, no year folder, no
/// postcard.json sidecar. `{ABCD}` is the first four hex characters of
/// the sender's NOSTR signature over the postcard header+content.
class PostcardService {
  static final PostcardService _instance = PostcardService._internal();
  factory PostcardService() => _instance;
  PostcardService._internal();

  /// Profile storage for file operations (encrypted or filesystem)
  /// IMPORTANT: This MUST be set before using the service.
  late ProfileStorage _storage;

  String? _appPath;

  /// Whether using encrypted storage
  bool get useEncryptedStorage => _storage.isEncrypted;

  /// Set the profile storage for file operations
  /// MUST be called before initializeApp
  void setStorage(ProfileStorage storage) {
    _storage = storage;
  }

  /// Initialize postcard service for a collection
  Future<void> initializeApp(String appPath) async {
    print('PostcardService: Initializing with collection path: $appPath');
    _appPath = appPath;
    await _storage.createDirectory('postcards');
    print('PostcardService: Created postcards directory');
  }

  // ── Listing ───────────────────────────────────────────────────────

  /// Get available years, derived from the date embedded in each
  /// postcard filename (YYYY-MM-DD).
  Future<List<int>> getYears() async {
    if (_appPath == null) return [];
    if (!await _storage.exists('postcards')) return [];

    final years = <int>{};
    final entries = await _storage.listDirectory('postcards');
    for (final entry in entries) {
      if (entry.isDirectory) continue;
      final year = _yearFromFilename(entry.name);
      if (year != null) years.add(year);
    }
    final sorted = years.toList()..sort((a, b) => b.compareTo(a));
    return sorted;
  }

  /// Load postcards (optionally filtered by year and/or status).
  Future<List<Postcard>> loadPostcards({
    int? year,
    String? filterByStatus,
  }) async {
    if (_appPath == null) return [];
    if (!await _storage.exists('postcards')) return [];

    final postcards = <Postcard>[];
    final entries = await _storage.listDirectory('postcards');
    for (final entry in entries) {
      if (entry.isDirectory) continue;
      if (!_isPostcardFilename(entry.name)) continue;
      if (year != null && _yearFromFilename(entry.name) != year) continue;

      try {
        final stem = entry.name.substring(0, entry.name.length - 4); // .txt
        final postcard = await loadPostcard(stem);
        if (postcard == null) continue;
        if (filterByStatus != null && postcard.status != filterByStatus) {
          continue;
        }
        postcards.add(postcard);
      } catch (e) {
        print('PostcardService: Error loading postcard ${entry.name}: $e');
      }
    }

    postcards.sort((a, b) => b.createdDateTime.compareTo(a.createdDateTime));
    return postcards;
  }

  /// Load a single postcard by its id (== filename stem, no .txt).
  Future<Postcard?> loadPostcard(String postcardId) async {
    if (_appPath == null) return null;
    final path = 'postcards/$postcardId.txt';
    final text = await _storage.readString(path);
    if (text == null) {
      print('PostcardService: postcard not found: $path');
      return null;
    }
    try {
      return Postcard.fromText(text, postcardId);
    } catch (e) {
      print('PostcardService: Error parsing $path: $e');
      return null;
    }
  }

  // ── Persistence ───────────────────────────────────────────────────

  /// Write a postcard to disk at postcards/{id}.txt. The id is the
  /// filename stem without the .txt extension.
  Future<void> _persistPostcard(String postcardId, Postcard postcard) async {
    await _storage.writeString(
      'postcards/$postcardId.txt',
      postcard.exportAsText(),
    );
  }

  // ── Filename helpers ──────────────────────────────────────────────

  static final RegExp _postcardFilenameRe = RegExp(
    r'^postcard-[A-Z0-9]+_\d{4}-\d{2}-\d{2}_[0-9a-f]{4}(?:-\d+)?\.txt$',
  );

  bool _isPostcardFilename(String name) => _postcardFilenameRe.hasMatch(name);

  int? _yearFromFilename(String name) {
    final m = RegExp(r'_(\d{4})-\d{2}-\d{2}_').firstMatch(name);
    if (m == null) return null;
    return int.tryParse(m.group(1)!);
  }

  /// Sanitize callsign for use in a filename.
  String _sanitizeCallsign(String callsign) {
    final upper = callsign.toUpperCase();
    final cleaned = upper.replaceAll(RegExp(r'[^A-Z0-9]'), '');
    return cleaned.isEmpty ? 'UNKNOWN' : cleaned;
  }

  /// Build the filename stem (no .txt). Appends `-N` if needed to avoid
  /// collisions when the same sender happens to produce two files in a
  /// day with the same signature prefix.
  Future<String> _uniqueFilenameStem({
    required String senderCallsign,
    required DateTime now,
    required String signatureHex,
  }) async {
    final dateStr = '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    final prefix = (signatureHex.length >= 4
            ? signatureHex.substring(0, 4)
            : signatureHex.padLeft(4, '0'))
        .toLowerCase();
    final base = 'postcard-${_sanitizeCallsign(senderCallsign)}_'
        '${dateStr}_$prefix';

    String stem = base;
    int suffix = 1;
    while (await _storage.exists('postcards/$stem.txt')) {
      stem = '$base-$suffix';
      suffix++;
    }
    return stem;
  }

  // ── Signing ───────────────────────────────────────────────────────

  /// Sign the postcard's header+content with the active profile's nsec.
  /// Returns the 64-char hex Schnorr signature, or null if no nsec is
  /// available (edge case — caller decides whether to proceed).
  String? _signHeaderAndContent(Postcard postcard) {
    final profile = ProfileService().getProfile();
    if (profile.nsec.isEmpty) return null;

    final signable = postcard.signableHeaderAndContent();
    final pubkeyHex = NostrCrypto.decodeNpub(profile.npub);
    final event = NostrEvent.textNote(
      pubkeyHex: pubkeyHex,
      content: signable,
    );
    try {
      return event.signWithNsec(profile.nsec);
    } catch (e) {
      print('PostcardService: signing failed: $e');
      return null;
    }
  }

  // ── Timestamp formatting ──────────────────────────────────────────

  String _formatTimestamp(DateTime dt) {
    final year = dt.year.toString().padLeft(4, '0');
    final month = dt.month.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    final second = dt.second.toString().padLeft(2, '0');
    return '$year-$month-$day $hour:$minute\_$second';
  }

  // ── Create ────────────────────────────────────────────────────────

  /// Create and persist a new postcard. Sender signature over
  /// header+content is produced with the active profile's nsec and the
  /// first four hex characters of that signature are folded into the
  /// filename.
  Future<Postcard?> createPostcard({
    required String title,
    required String senderCallsign,
    required String senderNpub,
    String? recipientCallsign,
    required String recipientNpub,
    required List<RecipientLocation> recipientLocations,
    required String type, // "open" or "encrypted"
    required String content,
    int? ttl,
    String priority = 'normal',
  }) async {
    if (_appPath == null) return null;

    try {
      final now = DateTime.now();
      await _storage.createDirectory('postcards');

      // Build the postcard draft so we can compute the signable text.
      final draft = Postcard(
        id: '', // filled in once we have the signature prefix
        title: title,
        createdTimestamp: _formatTimestamp(now),
        senderCallsign: senderCallsign,
        senderNpub: senderNpub,
        recipientCallsign: recipientCallsign,
        recipientNpub: recipientNpub,
        recipientLocations: recipientLocations,
        type: type,
        status: 'in-transit',
        ttl: ttl,
        priority: priority,
        content: content,
        stamps: const [],
        returnStamps: const [],
      );

      final signature = _signHeaderAndContent(draft);
      if (signature == null) {
        print('PostcardService: cannot create postcard without an nsec');
        return null;
      }

      final stem = await _uniqueFilenameStem(
        senderCallsign: senderCallsign,
        now: now,
        signatureHex: signature,
      );

      final postcard = draft.copyWith(
        id: stem,
        metadata: {
          'npub': senderNpub,
          'signature': signature,
        },
      );

      await _persistPostcard(stem, postcard);
      print('PostcardService: created postcard $stem.txt');
      return postcard;
    } catch (e) {
      print('PostcardService: Error creating postcard: $e');
      return null;
    }
  }

  // ── Mutate an existing postcard ───────────────────────────────────
  //
  // Every mutator loads the existing postcard, produces the new
  // Postcard, and writes it back to the same file. The filename never
  // changes after creation — its id = stem is stable.

  Future<bool> addStamp({
    required String postcardId,
    required String stamperCallsign,
    required String stamperNpub,
    required double latitude,
    required double longitude,
    String? locationName,
    required String receivedFrom,
    required String receivedVia,
    required String signature,
  }) async {
    if (_appPath == null) return false;
    try {
      final postcard = await loadPostcard(postcardId);
      if (postcard == null) return false;

      final now = DateTime.now();
      final stamp = PostcardStamp(
        number: postcard.stamps.length + 1,
        stamperCallsign: stamperCallsign,
        stamperNpub: stamperNpub,
        timestamp: _formatTimestamp(now),
        latitude: latitude,
        longitude: longitude,
        locationName: locationName,
        receivedFrom: receivedFrom,
        receivedVia: receivedVia,
        hopNumber: postcard.stamps.length + 1,
        signature: signature,
      );

      final updated = postcard.copyWith(stamps: [...postcard.stamps, stamp]);
      await _persistPostcard(postcardId, updated);
      print('PostcardService: added stamp #${stamp.number} to $postcardId');
      return true;
    } catch (e) {
      print('PostcardService: Error adding stamp: $e');
      return false;
    }
  }

  Future<bool> deliverPostcard({
    required String postcardId,
    required String carrierCallsign,
    required String carrierNpub,
    required double latitude,
    required double longitude,
    String? locationName,
    String? deliveryNote,
    required String signature,
  }) async {
    if (_appPath == null) return false;
    try {
      final postcard = await loadPostcard(postcardId);
      if (postcard == null) return false;

      final now = DateTime.now();
      final deliveryReceipt = PostcardDeliveryReceipt(
        recipientNpub: postcard.recipientNpub,
        timestamp: _formatTimestamp(now),
        carrierCallsign: carrierCallsign,
        carrierNpub: carrierNpub,
        deliveryLatitude: latitude,
        deliveryLongitude: longitude,
        deliveryLocationName: locationName,
        deliveryNote: deliveryNote,
        signature: signature,
      );

      final updated = postcard.copyWith(
        status: 'delivered',
        deliveryReceipt: deliveryReceipt,
      );
      await _persistPostcard(postcardId, updated);
      print('PostcardService: delivered $postcardId');
      return true;
    } catch (e) {
      print('PostcardService: Error delivering: $e');
      return false;
    }
  }

  Future<bool> addReturnStamp({
    required String postcardId,
    required String stamperCallsign,
    required String stamperNpub,
    required double latitude,
    required double longitude,
    String? locationName,
    required String receivedFrom,
    required String receivedVia,
    required String signature,
  }) async {
    if (_appPath == null) return false;
    try {
      final postcard = await loadPostcard(postcardId);
      if (postcard == null) return false;

      final now = DateTime.now();
      final stamp = PostcardStamp(
        number: postcard.returnStamps.length + 1,
        stamperCallsign: stamperCallsign,
        stamperNpub: stamperNpub,
        timestamp: _formatTimestamp(now),
        latitude: latitude,
        longitude: longitude,
        locationName: locationName,
        receivedFrom: receivedFrom,
        receivedVia: receivedVia,
        hopNumber: postcard.returnStamps.length + 1,
        signature: signature,
      );

      final updated = postcard.copyWith(
        returnStamps: [...postcard.returnStamps, stamp],
      );
      await _persistPostcard(postcardId, updated);
      print('PostcardService: added return stamp #${stamp.number} to $postcardId');
      return true;
    } catch (e) {
      print('PostcardService: Error adding return stamp: $e');
      return false;
    }
  }

  Future<bool> acknowledgePostcard({
    required String postcardId,
    required String receivedTimestamp,
    String? acknowledgmentNote,
    required String signature,
  }) async {
    if (_appPath == null) return false;
    try {
      final postcard = await loadPostcard(postcardId);
      if (postcard == null) return false;

      final acknowledgment = PostcardAcknowledgment(
        senderNpub: postcard.senderNpub,
        timestamp: receivedTimestamp,
        acknowledgmentNote: acknowledgmentNote,
        signature: signature,
      );

      final updated = postcard.copyWith(
        status: 'acknowledged',
        acknowledgment: acknowledgment,
      );
      await _persistPostcard(postcardId, updated);
      print('PostcardService: acknowledged $postcardId');
      return true;
    } catch (e) {
      print('PostcardService: Error acknowledging: $e');
      return false;
    }
  }

  // ── Convenience status queries ────────────────────────────────────

  Future<List<Postcard>> getPostcardsByStatus(String status) =>
      loadPostcards(filterByStatus: status);
  Future<List<Postcard>> getInTransitPostcards() =>
      getPostcardsByStatus('in-transit');
  Future<List<Postcard>> getDeliveredPostcards() =>
      getPostcardsByStatus('delivered');
  Future<List<Postcard>> getAcknowledgedPostcards() =>
      getPostcardsByStatus('acknowledged');
  Future<List<Postcard>> getExpiredPostcards() =>
      getPostcardsByStatus('expired');

  /// Contributor files no longer exist in the flat single-file layout —
  /// kept as a no-op for callers that still invoke it. Remove when the
  /// UI stops asking.
  Future<List<String>> loadContributorFiles(String postcardId) async => const [];

  bool isExpired(Postcard postcard) {
    if (postcard.ttl == null) return false;
    final expiry = postcard.createdDateTime.add(Duration(days: postcard.ttl!));
    return DateTime.now().isAfter(expiry);
  }

  Future<bool> markAsExpired(String postcardId) async {
    if (_appPath == null) return false;
    try {
      final postcard = await loadPostcard(postcardId);
      if (postcard == null) return false;
      await _persistPostcard(postcardId, postcard.copyWith(status: 'expired'));
      return true;
    } catch (e) {
      print('PostcardService: Error marking expired: $e');
      return false;
    }
  }
}
