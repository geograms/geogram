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

  /// Get available years by scanning `postcards/` for shard directories
  /// matching `YYYY` or `YYYY-N`.
  Future<List<int>> getYears() async {
    if (_appPath == null) return [];
    if (!await _storage.exists('postcards')) return [];

    final years = <int>{};
    final entries = await _storage.listDirectory('postcards');
    for (final entry in entries) {
      if (!entry.isDirectory) continue;
      final m = _shardNameRe.firstMatch(entry.name);
      if (m != null) years.add(int.parse(m.group(1)!));
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

    // Discover the year shards we need to walk.
    final shards = <String>[];
    if (year != null) {
      shards.addAll(await _existingShardsForYear(year));
    } else {
      final entries = await _storage.listDirectory('postcards');
      for (final entry in entries) {
        if (entry.isDirectory && _shardNameRe.hasMatch(entry.name)) {
          shards.add(entry.name);
        }
      }
    }

    final postcards = <Postcard>[];
    for (final shard in shards) {
      final shardPath = 'postcards/$shard';
      final files = await _storage.listDirectory(shardPath);
      for (final file in files) {
        if (file.isDirectory) continue;
        if (!_isPostcardFilename(file.name)) continue;
        final stem = file.name.substring(0, file.name.length - 4);
        try {
          final path = '$shardPath/${file.name}';
          final text = await _storage.readString(path);
          if (text == null) continue;
          final postcard = Postcard.fromText(text, stem);
          if (filterByStatus != null && postcard.status != filterByStatus) {
            continue;
          }
          postcards.add(postcard);
        } catch (e) {
          print('PostcardService: Error loading ${file.name}: $e');
        }
      }
    }

    postcards.sort((a, b) => b.createdDateTime.compareTo(a.createdDateTime));
    return postcards;
  }

  /// Load a single postcard by its id (== filename stem, no .txt).
  /// Walks the year's shards until it finds the file.
  Future<Postcard?> loadPostcard(String postcardId) async {
    if (_appPath == null) return null;
    final path = await _resolvePostcardPath(postcardId);
    if (path == null) {
      print('PostcardService: postcard not found: $postcardId');
      return null;
    }
    final text = await _storage.readString(path);
    if (text == null) return null;
    try {
      return Postcard.fromText(text, postcardId);
    } catch (e) {
      print('PostcardService: Error parsing $path: $e');
      return null;
    }
  }

  // ── Persistence ───────────────────────────────────────────────────

  /// Write an existing postcard back to the shard it already lives in.
  /// Used by mutators (addStamp, deliverPostcard, …) where the file
  /// already exists on disk.
  Future<void> _persistExisting(String postcardId, Postcard postcard) async {
    final path = await _resolvePostcardPath(postcardId);
    if (path == null) {
      throw StateError(
        'PostcardService: cannot persist unknown postcard $postcardId',
      );
    }
    await _storage.writeString(path, postcard.exportAsText());
  }

  /// Write a brand-new postcard to the current shard for its year,
  /// opening a new shard if the current one has reached the cap.
  Future<void> _persistNew(String shard, String postcardId, Postcard postcard) async {
    await _storage.writeString(
      'postcards/$shard/$postcardId.txt',
      postcard.exportAsText(),
    );
  }

  // ── Filename + shard helpers ──────────────────────────────────────

  /// A shard directory is named either `YYYY` (first shard for a year)
  /// or `YYYY-N` (subsequent shards when the previous one filled up).
  static final RegExp _shardNameRe = RegExp(r'^(\d{4})(?:-\d+)?$');

  /// Max files we allow per shard directory. File systems (and some
  /// sync/indexing tools) start misbehaving around 10 000 entries per
  /// directory; 5 000 keeps plenty of headroom.
  static const int _shardCap = 5000;

  static final RegExp _postcardFilenameRe = RegExp(
    r'^postcard-[A-Z0-9]+_\d{4}-\d{2}-\d{2}_[0-9a-f]{4}(?:-\d+)?\.txt$',
  );

  bool _isPostcardFilename(String name) => _postcardFilenameRe.hasMatch(name);

  /// Extract the year prefix from a postcard filename stem
  /// (`postcard-CALLSIGN_YYYY-MM-DD_ABCD` → `YYYY`).
  int? _yearFromStem(String stem) {
    final m = RegExp(r'_(\d{4})-\d{2}-\d{2}_').firstMatch(stem);
    if (m == null) return null;
    return int.tryParse(m.group(1)!);
  }

  /// Return every existing shard directory for `year`, in ascending
  /// order (`YYYY`, `YYYY-1`, `YYYY-2`, …).
  Future<List<String>> _existingShardsForYear(int year) async {
    final shards = <String>[];
    int n = 0;
    while (true) {
      final name = n == 0 ? '$year' : '$year-$n';
      if (!await _storage.exists('postcards/$name')) break;
      shards.add(name);
      n++;
    }
    return shards;
  }

  /// Resolve a postcard id to its on-disk path by walking the year's
  /// shards until a matching file is found. Returns null if the file
  /// is not in any shard.
  Future<String?> _resolvePostcardPath(String postcardId) async {
    final year = _yearFromStem(postcardId);
    if (year == null) return null;
    int n = 0;
    while (true) {
      final shard = n == 0 ? '$year' : '$year-$n';
      final dir = 'postcards/$shard';
      if (!await _storage.exists(dir)) return null;
      final path = '$dir/$postcardId.txt';
      if (await _storage.exists(path)) return path;
      n++;
    }
  }

  /// Return the name of the shard to write a new postcard for `year`
  /// into. Creates the shard directory if needed. Iterates
  /// YYYY → YYYY-1 → YYYY-2 → … until it finds one holding fewer than
  /// [_shardCap] postcard files; if every existing shard is full, a
  /// fresh one is created.
  Future<String> _currentShardForYear(int year) async {
    int n = 0;
    while (true) {
      final name = n == 0 ? '$year' : '$year-$n';
      final dir = 'postcards/$name';
      if (!await _storage.exists(dir)) {
        await _storage.createDirectory(dir);
        return name;
      }
      int count = 0;
      final entries = await _storage.listDirectory(dir);
      for (final entry in entries) {
        if (!entry.isDirectory && _isPostcardFilename(entry.name)) count++;
      }
      if (count < _shardCap) return name;
      n++;
    }
  }

  /// Sanitize callsign for use in a filename.
  String _sanitizeCallsign(String callsign) {
    final upper = callsign.toUpperCase();
    final cleaned = upper.replaceAll(RegExp(r'[^A-Z0-9]'), '');
    return cleaned.isEmpty ? 'UNKNOWN' : cleaned;
  }

  /// Build the filename stem (no .txt). Appends `-N` if a file with
  /// the same stem already exists in any shard for the same year.
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
    while (await _resolvePostcardPath(stem) != null) {
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

      final shard = await _currentShardForYear(now.year);
      await _persistNew(shard, stem, postcard);
      print('PostcardService: created $shard/$stem.txt');
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
      await _persistExisting(postcardId, updated);
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
      await _persistExisting(postcardId, updated);
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
      await _persistExisting(postcardId, updated);
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
      await _persistExisting(postcardId, updated);
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
      await _persistExisting(
        postcardId,
        postcard.copyWith(status: 'expired'),
      );
      return true;
    } catch (e) {
      print('PostcardService: Error marking expired: $e');
      return false;
    }
  }
}
