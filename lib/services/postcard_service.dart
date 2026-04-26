/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:math' as math;

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

  // ── Sample / debug seeding ────────────────────────────────────────

  /// Inject [count] synthetic postcards spread across Portuguese cities,
  /// each with a randomized journey (1–3 carrier stamps and a random
  /// status). Bypasses NOSTR signing — signatures are random hex —
  /// because the goal is to populate the map for visual testing, not
  /// to ship verifiable mail. Returns the number of files written.
  Future<int> seedSamplePostcards({int count = 2000}) async {
    if (_appPath == null) return 0;
    await _storage.createDirectory('postcards');

    final rng = math.Random(0xCAFE);
    final senderProfile = ProfileService().getProfile();
    final senderCs = senderProfile.callsign.isEmpty
        ? 'CR0BOT0'
        : senderProfile.callsign;
    final senderNpub = senderProfile.npub;

    int written = 0;
    DateTime? lastDate;
    String currentShard = '';

    for (var i = 0; i < count; i++) {
      // Spread creation timestamps across the past 180 days.
      final daysAgo = rng.nextInt(180);
      final created = DateTime.now().subtract(Duration(
        days: daysAgo,
        hours: rng.nextInt(24),
        minutes: rng.nextInt(60),
        seconds: rng.nextInt(60),
      ));

      // Pick or refresh the shard whenever the year changes.
      if (lastDate == null || created.year != lastDate.year) {
        currentShard = await _currentShardForYear(created.year);
        lastDate = created;
      }

      // Random sender (sometimes me, sometimes a fictional bot).
      final isMine = rng.nextDouble() < 0.5;
      final sCs = isMine ? senderCs : 'BOT${(rng.nextInt(99) + 1).toString().padLeft(2, '0')}';
      final sNpub = isMine ? senderNpub : 'npub1bot${i.toRadixString(16).padLeft(4, '0')}xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx';

      // Recipient: random bot.
      final rCs = 'BOT${(rng.nextInt(99) + 1).toString().padLeft(2, '0')}';
      final rNpub = 'npub1rcp${i.toRadixString(16).padLeft(4, '0')}xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx';

      // 1–3 recipient locations from the Portuguese city pool.
      final recipientLocs = <RecipientLocation>[];
      final nDest = 1 + rng.nextInt(3);
      final destPicks = _pickN(_ptCities, nDest, rng);
      for (final c in destPicks) {
        recipientLocs.add(RecipientLocation(
          latitude: _jitter(c.lat, rng),
          longitude: _jitter(c.lng, rng),
          locationName: c.name,
        ));
      }

      // 0–4 stamps. Older postcards skew toward more hops.
      final maxHops = (daysAgo / 60).clamp(1, 4).toInt();
      final nStamps = rng.nextInt(maxHops + 1);
      final stamps = <PostcardStamp>[];
      String prevFrom = 'sender';
      DateTime hopWhen = created;
      for (var h = 0; h < nStamps; h++) {
        final city = _ptCities[rng.nextInt(_ptCities.length)];
        hopWhen = hopWhen.add(Duration(hours: 6 + rng.nextInt(48)));
        if (hopWhen.isAfter(DateTime.now())) hopWhen = DateTime.now();
        final via = _viaPool[rng.nextInt(_viaPool.length)];
        stamps.add(PostcardStamp(
          number: h + 1,
          stamperCallsign: 'CARRY${(rng.nextInt(50) + 1).toString().padLeft(2, '0')}',
          stamperNpub: 'npub1car${h.toRadixString(16)}${i.toRadixString(16).padLeft(4, '0')}xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
          timestamp: _formatTimestamp(hopWhen),
          latitude: _jitter(city.lat, rng),
          longitude: _jitter(city.lng, rng),
          locationName: city.name,
          receivedFrom: prevFrom,
          receivedVia: via,
          hopNumber: h + 1,
          signature: _randomHex(rng, 64),
        ));
        prevFrom = 'npub1car${h.toRadixString(16)}…';
      }

      // Status distribution.
      final roll = rng.nextDouble();
      String status;
      PostcardDeliveryReceipt? receipt;
      if (roll < 0.6 || stamps.isEmpty) {
        status = 'in-transit';
      } else if (roll < 0.85) {
        status = 'delivered';
        final dest = destPicks.first;
        receipt = PostcardDeliveryReceipt(
          recipientNpub: rNpub,
          timestamp: _formatTimestamp(
            hopWhen.add(Duration(hours: 1 + rng.nextInt(48))),
          ),
          carrierCallsign: stamps.last.stamperCallsign,
          carrierNpub: stamps.last.stamperNpub,
          deliveryLatitude: _jitter(dest.lat, rng),
          deliveryLongitude: _jitter(dest.lng, rng),
          deliveryLocationName: dest.name,
          signature: _randomHex(rng, 64),
        );
      } else if (roll < 0.95) {
        status = 'expired';
      } else {
        status = 'acknowledged';
        final dest = destPicks.first;
        receipt = PostcardDeliveryReceipt(
          recipientNpub: rNpub,
          timestamp: _formatTimestamp(hopWhen),
          carrierCallsign: stamps.last.stamperCallsign,
          carrierNpub: stamps.last.stamperNpub,
          deliveryLatitude: _jitter(dest.lat, rng),
          deliveryLongitude: _jitter(dest.lng, rng),
          deliveryLocationName: dest.name,
          signature: _randomHex(rng, 64),
        );
      }

      final title = _titlePool[rng.nextInt(_titlePool.length)]
          .replaceAll('{city}', destPicks.first.name);
      final body = _bodyPool[rng.nextInt(_bodyPool.length)]
          .replaceAll('{city}', destPicks.first.name);

      final sigHex = _randomHex(rng, 64);
      final dateStr = '${created.year.toString().padLeft(4, '0')}-'
          '${created.month.toString().padLeft(2, '0')}-'
          '${created.day.toString().padLeft(2, '0')}';
      final stem = 'postcard-${_sanitizeCallsign(sCs)}_'
          '${dateStr}_${sigHex.substring(0, 4)}';

      // Skip if a same-stem file already exists in this shard.
      final filePath = 'postcards/$currentShard/$stem.txt';
      if (await _storage.exists(filePath)) continue;

      final p = Postcard(
        id: stem,
        title: title,
        createdTimestamp: _formatTimestamp(created),
        senderCallsign: sCs,
        senderNpub: sNpub,
        recipientCallsign: rCs,
        recipientNpub: rNpub,
        recipientLocations: recipientLocs,
        type: 'open',
        status: status,
        ttl: 30,
        priority: 'normal',
        content: body,
        metadata: {'npub': sNpub, 'signature': sigHex},
        stamps: stamps,
        deliveryReceipt: receipt,
      );

      try {
        await _storage.writeString(filePath, p.exportAsText());
        written++;
      } catch (_) {
        // Continue on write errors so a partial seed still produces
        // useful map content.
      }

      // Roll over to a new shard if we hit the cap mid-burst.
      if (written % _shardCap == 0) {
        currentShard = await _currentShardForYear(created.year);
      }
    }

    return written;
  }

  String _randomHex(math.Random rng, int len) {
    const chars = '0123456789abcdef';
    final buf = StringBuffer();
    for (var i = 0; i < len; i++) {
      buf.write(chars[rng.nextInt(16)]);
    }
    return buf.toString();
  }

  double _jitter(double v, math.Random rng) =>
      v + (rng.nextDouble() - 0.5) * 0.04;

  List<_City> _pickN(List<_City> src, int n, math.Random rng) {
    final pool = [...src]..shuffle(rng);
    return pool.take(n).toList();
  }

  static const List<_City> _ptCities = [
    _City('Lisbon', 38.7223, -9.1393),
    _City('Porto', 41.1579, -8.6291),
    _City('Coimbra', 40.2110, -8.4292),
    _City('Braga', 41.5454, -8.4265),
    _City('Faro', 37.0194, -7.9304),
    _City('Funchal', 32.6669, -16.9241),
    _City('Aveiro', 40.6443, -8.6455),
    _City('Évora', 38.5713, -7.9135),
    _City('Viseu', 40.6566, -7.9128),
    _City('Leiria', 39.7437, -8.8071),
    _City('Setúbal', 38.5244, -8.8882),
    _City('Guimarães', 41.4413, -8.2911),
    _City('Viana do Castelo', 41.6932, -8.8327),
    _City('Vila Real', 41.3006, -7.7441),
    _City('Bragança', 41.8071, -6.7567),
    _City('Castelo Branco', 39.8217, -7.4912),
    _City('Beja', 38.0150, -7.8633),
    _City('Santarém', 39.2362, -8.6859),
    _City('Portalegre', 39.2916, -7.4307),
    _City('Tomar', 39.6033, -8.4108),
    _City('Caldas da Rainha', 39.4039, -9.1346),
    _City('Sines', 37.9542, -8.8693),
    _City('Lagos', 37.1028, -8.6736),
    _City('Albufeira', 37.0894, -8.2474),
    _City('Cascais', 38.6968, -9.4214),
    _City('Sintra', 38.8029, -9.3817),
    _City('Almada', 38.6790, -9.1569),
    _City('Loures', 38.8307, -9.1683),
    _City('Ponta Delgada', 37.7412, -25.6756),
    _City('Angra do Heroísmo', 38.6566, -27.2210),
  ];

  static const List<String> _viaPool = [
    'BLE', 'LoRa', 'WiFi-LAN', 'Radio', 'Satellite',
    'In-Person', 'Meshtastic', 'Cellular',
  ];

  static const List<String> _titlePool = [
    'Greetings from {city}',
    'Quick note from {city}',
    'Sunset over {city}',
    'Wish you were here',
    'Test postcard',
    'Hello from the road',
    'Update from {city}',
    'Postcards from the edge',
    'Just a hello',
    'Coffee in {city}',
  ];

  static const List<String> _bodyPool = [
    'Spent the day walking around {city}. Beautiful weather, great food.',
    'Quick note before the next leg of the trip — heading out tomorrow.',
    'Arrived in {city} this morning. Will write more when I have time.',
    'Test message generated for the map. Ignore.',
    'The light in {city} is something else this time of year.',
    'Catching the train soon. Wanted to say hi.',
    'Met a couple of carriers along the way — they took excellent care of this card.',
    'Coffee, books, more coffee. The {city} routine.',
  ];
}

/// Tiny helper class for seed-data city table.
class _City {
  final String name;
  final double lat;
  final double lng;
  const _City(this.name, this.lat, this.lng);
}
