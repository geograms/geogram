import 'dart:async';
import 'dart:convert';
import 'nostr_event.dart';
import 'nostr_crypto.dart';
import '../services/profile_storage.dart';

/// In-memory async mutex for atomic feedback operations.
/// Prevents race conditions when multiple concurrent requests modify the same feedback file.
class _AsyncMutex {
  Future<void> _last = Future.value();

  Future<T> protect<T>(Future<T> Function() action) {
    final prev = _last;
    final completer = Completer<void>();
    _last = completer.future;
    return prev.then((_) => action()).whenComplete(completer.complete);
  }
}

/// Centralized utilities for generic feedback folder structure.
///
/// Feedback folder structure:
/// ```
/// {contentPath}/
/// └── feedback/
///     ├── likes.txt                  # NOSTR npub, one per line (toggle)
///     ├── points.txt                 # NOSTR npub, one per line (toggle)
///     ├── dislikes.txt               # NOSTR npub, one per line (toggle)
///     ├── subscribe.txt              # NOSTR npub, one per line (toggle)
///     ├── verifications.txt          # NOSTR npub, one per line (add-only)
///     ├── views.txt                  # Signed NOSTR events (JSON), multiple entries (metric)
///     ├── thumbs-up.txt              # Emoji reaction: npub per line (toggle)
///     ├── thumbs-down.txt            # Emoji reaction: npub per line (toggle)
///     ├── heart.txt                  # Emoji reaction: npub per line (toggle)
///     ├── fire.txt                   # Emoji reaction: npub per line (toggle)
///     ├── hundred.txt                # Emoji reaction: npub per line (toggle)
///     ├── curious.txt                # Emoji reaction: npub per line (toggle)
///     ├── celebrate.txt              # Emoji reaction: npub per line (toggle)
///     ├── laugh.txt                  # Emoji reaction: npub per line (toggle)
///     ├── sad.txt                    # Emoji reaction: npub per line (toggle)
///     ├── beer-cheers.txt            # Emoji reaction: npub per line (toggle)
///     ├── surprise.txt               # Emoji reaction: npub per line (toggle)
///     └── comments/
///         └── YYYY-MM-DD_HH-MM-SS_XXXXXX.txt
/// ```
///
/// All I/O methods require a `ProfileStorage` parameter. Content paths are
/// relative to the storage root (the callsign directory).
class FeedbackFolderUtils {
  FeedbackFolderUtils._();

  /// Per-path async locks for atomic read-modify-write operations
  static final _locks = <String, _AsyncMutex>{};

  /// Standard feedback types (toggles - one signed event per user)
  static const String feedbackTypeLikes = 'likes';
  static const String feedbackTypePoints = 'points';
  static const String feedbackTypeDislikes = 'dislikes';
  static const String feedbackTypeSubscribe = 'subscribe';
  static const String feedbackTypeVerifications = 'verifications';

  /// Metric feedback types (multiple entries allowed)
  static const String feedbackTypeViews = 'views';

  /// Emoji reaction types
  static const String reactionThumbsUp = 'thumbs-up';
  static const String reactionThumbsDown = 'thumbs-down';
  static const String reactionHeart = 'heart';
  static const String reactionFire = 'fire';
  static const String reactionHundred = 'hundred';
  static const String reactionCurious = 'curious';
  static const String reactionCelebrate = 'celebrate';
  static const String reactionLaugh = 'laugh';
  static const String reactionSad = 'sad';
  static const String reactionBeerCheers = 'beer-cheers';
  static const String reactionSurprise = 'surprise';

  /// All supported emoji reactions
  static const List<String> supportedReactions = [
    reactionThumbsUp,
    reactionThumbsDown,
    reactionHeart,
    reactionFire,
    reactionHundred,
    reactionCurious,
    reactionCelebrate,
    reactionLaugh,
    reactionSad,
    reactionBeerCheers,
    reactionSurprise,
  ];

  /// Build path to the feedback folder for a content item.
  static String buildFeedbackPath(String contentPath) {
    return '$contentPath/feedback';
  }

  /// Build path to a feedback file (likes.txt, points.txt, etc.).
  static String buildFeedbackFilePath(String contentPath, String feedbackType) {
    return '${buildFeedbackPath(contentPath)}/$feedbackType.txt';
  }

  /// Build path to the comments subfolder.
  static String buildCommentsPath(String contentPath) {
    return '${buildFeedbackPath(contentPath)}/comments';
  }

  /// Ensure feedback folder exists.
  static Future<void> ensureFeedbackFolder(
    String contentPath, {
    required ProfileStorage storage,
  }) async {
    await storage.createDirectory(buildFeedbackPath(contentPath));
  }

  static bool _isValidNpubLine(String line) {
    if (!line.startsWith('npub1')) {
      return false;
    }

    try {
      NostrCrypto.decodeNpub(line);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Read feedback npubs from a feedback file.
  /// Returns list of npub strings, empty list if file doesn't exist.
  static Future<List<String>> readFeedbackFile(
    String contentPath,
    String feedbackType, {
    required ProfileStorage storage,
  }) async {
    final filePath = buildFeedbackFilePath(contentPath, feedbackType);
    final content = await storage.readString(filePath);
    if (content == null) return [];

    final lines = content
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();

    final npubs = <String>{};

    for (final line in lines) {
      // Try to parse as JSON event
      if (line.startsWith('{')) {
        try {
          final json = jsonDecode(line) as Map<String, dynamic>;
          final event = NostrEvent.fromJson(json);

          // Verify signature
          if (event.verify()) {
            npubs.add(event.npub);
          }
        } catch (e) {
          // Invalid JSON or event, skip
          continue;
        }
      } else if (_isValidNpubLine(line)) {
        npubs.add(line);
      }
    }

    return npubs.toList();
  }

  /// Read signed feedback events (full event objects with signatures).
  /// Returns list of verified NostrEvent objects.
  static Future<List<NostrEvent>> readFeedbackEvents(
    String contentPath,
    String feedbackType, {
    required ProfileStorage storage,
  }) async {
    final filePath = buildFeedbackFilePath(contentPath, feedbackType);
    final content = await storage.readString(filePath);
    if (content == null) return [];

    final lines = content
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();

    final verifiedEvents = <NostrEvent>[];

    for (final line in lines) {
      if (line.startsWith('{')) {
        try {
          final json = jsonDecode(line) as Map<String, dynamic>;
          final event = NostrEvent.fromJson(json);

          // Verify signature
          if (event.verify()) {
            verifiedEvents.add(event);
          }
        } catch (e) {
          // Invalid JSON or event, skip
          continue;
        }
      }
    }

    return verifiedEvents;
  }

  /// Write signed feedback events to a feedback file.
  /// If the list is empty, the file is deleted.
  static Future<void> writeFeedbackEvents(
    String contentPath,
    String feedbackType,
    List<NostrEvent> events, {
    required ProfileStorage storage,
  }) async {
    await ensureFeedbackFolder(contentPath, storage: storage);
    final filePath = buildFeedbackFilePath(contentPath, feedbackType);

    if (events.isEmpty) {
      if (await storage.exists(filePath)) {
        await storage.delete(filePath);
      }
      return;
    }

    final lines = events.map((event) => jsonEncode(event.toJson())).join('\n');
    await storage.writeString(filePath, lines);
  }

  /// Write npubs to a feedback file.
  /// If the list is empty, the file is deleted.
  static Future<void> writeFeedbackFile(
    String contentPath,
    String feedbackType,
    List<String> npubs, {
    required ProfileStorage storage,
  }) async {
    await ensureFeedbackFolder(contentPath, storage: storage);
    final filePath = buildFeedbackFilePath(contentPath, feedbackType);

    if (npubs.isEmpty) {
      if (await storage.exists(filePath)) {
        await storage.delete(filePath);
      }
      return;
    }

    await storage.writeString(filePath, npubs.join('\n'));
  }

  /// Add signed feedback event if not already present.
  /// Returns true if the feedback was added, false if already exists or signature invalid.
  /// Uses in-memory locking to prevent race conditions.
  static Future<bool> addFeedbackEvent(
    String contentPath,
    String feedbackType,
    NostrEvent event, {
    required ProfileStorage storage,
  }) async {
    // Verify signature before adding
    if (!event.verify()) {
      return false;
    }

    await ensureFeedbackFolder(contentPath, storage: storage);

    final feedbackFilePath = buildFeedbackFilePath(contentPath, feedbackType);
    return _locks.putIfAbsent(feedbackFilePath, () => _AsyncMutex()).protect(() async {
      // CRITICAL SECTION - atomic read-check-write
      final npubs = await readFeedbackFile(contentPath, feedbackType, storage: storage);
      final npub = event.npub;

      // Check if this npub already has feedback
      if (npubs.contains(npub)) {
        return false;
      }

      npubs.add(npub);
      await writeFeedbackFile(contentPath, feedbackType, npubs, storage: storage);
      return true;
    });
  }

  /// Remove feedback event from a feedback file by npub.
  /// Returns true if the feedback was removed, false if not found.
  /// Uses in-memory locking to prevent race conditions.
  static Future<bool> removeFeedbackEvent(
    String contentPath,
    String feedbackType,
    String npub, {
    required ProfileStorage storage,
  }) async {
    await ensureFeedbackFolder(contentPath, storage: storage);

    final feedbackFilePath = buildFeedbackFilePath(contentPath, feedbackType);
    return _locks.putIfAbsent(feedbackFilePath, () => _AsyncMutex()).protect(() async {
      // CRITICAL SECTION - atomic read-modify-write
      final npubs = await readFeedbackFile(contentPath, feedbackType, storage: storage);
      final initialLength = npubs.length;

      npubs.removeWhere((entry) => entry == npub);

      if (npubs.length == initialLength) {
        return false; // Not found
      }

      await writeFeedbackFile(contentPath, feedbackType, npubs, storage: storage);
      return true;
    });
  }

  /// Toggle feedback with signed event (add if not present, remove if present).
  /// Returns true if added, false if removed, null if signature invalid.
  /// Uses in-memory locking to prevent race conditions.
  static Future<bool?> toggleFeedbackEvent(
    String contentPath,
    String feedbackType,
    NostrEvent event, {
    required ProfileStorage storage,
  }) async {
    // Verify signature before processing
    if (!event.verify()) {
      return null; // Invalid signature
    }

    await ensureFeedbackFolder(contentPath, storage: storage);

    final feedbackFilePath = buildFeedbackFilePath(contentPath, feedbackType);
    return _locks.putIfAbsent(feedbackFilePath, () => _AsyncMutex()).protect(() async {
      // CRITICAL SECTION - atomic read-modify-write
      final npubs = await readFeedbackFile(contentPath, feedbackType, storage: storage);
      final npub = event.npub;

      if (npubs.contains(npub)) {
        // Remove existing feedback
        npubs.removeWhere((entry) => entry == npub);
        await writeFeedbackFile(contentPath, feedbackType, npubs, storage: storage);
        return false; // Removed
      } else {
        // Add new feedback
        npubs.add(npub);
        await writeFeedbackFile(contentPath, feedbackType, npubs, storage: storage);
        return true; // Added
      }
    });
  }

  /// Get feedback count by counting lines in feedback file.
  static Future<int> getFeedbackCount(
    String contentPath,
    String feedbackType, {
    required ProfileStorage storage,
  }) async {
    final npubs = await readFeedbackFile(contentPath, feedbackType, storage: storage);
    return npubs.length;
  }

  /// Check if a user has provided specific feedback.
  static Future<bool> hasFeedback(
    String contentPath,
    String feedbackType,
    String npub, {
    required ProfileStorage storage,
  }) async {
    final npubs = await readFeedbackFile(contentPath, feedbackType, storage: storage);
    return npubs.contains(npub);
  }

  /// Get all feedback counts for a content item.
  static Future<Map<String, int>> getAllFeedbackCounts(
    String contentPath, {
    required ProfileStorage storage,
  }) async {
    final counts = <String, int>{};

    // Standard feedback types (toggles)
    counts[feedbackTypeLikes] = await getFeedbackCount(contentPath, feedbackTypeLikes, storage: storage);
    counts[feedbackTypePoints] = await getFeedbackCount(contentPath, feedbackTypePoints, storage: storage);
    counts[feedbackTypeDislikes] = await getFeedbackCount(contentPath, feedbackTypeDislikes, storage: storage);
    counts[feedbackTypeSubscribe] = await getFeedbackCount(contentPath, feedbackTypeSubscribe, storage: storage);
    counts[feedbackTypeVerifications] = await getFeedbackCount(contentPath, feedbackTypeVerifications, storage: storage);

    // Metric feedback types (counters)
    counts[feedbackTypeViews] = await getViewCount(contentPath, storage: storage);

    // Emoji reactions
    for (final reaction in supportedReactions) {
      counts[reaction] = await getFeedbackCount(contentPath, reaction, storage: storage);
    }

    return counts;
  }

  /// Get user's feedback state for a content item.
  static Future<Map<String, bool>> getUserFeedbackState(
    String contentPath,
    String npub, {
    required ProfileStorage storage,
  }) async {
    final state = <String, bool>{};

    // Standard feedback types
    state[feedbackTypeLikes] = await hasFeedback(contentPath, feedbackTypeLikes, npub, storage: storage);
    state[feedbackTypePoints] = await hasFeedback(contentPath, feedbackTypePoints, npub, storage: storage);
    state[feedbackTypeDislikes] = await hasFeedback(contentPath, feedbackTypeDislikes, npub, storage: storage);
    state[feedbackTypeSubscribe] = await hasFeedback(contentPath, feedbackTypeSubscribe, npub, storage: storage);
    state[feedbackTypeVerifications] = await hasFeedback(contentPath, feedbackTypeVerifications, npub, storage: storage);

    // Emoji reactions
    for (final reaction in supportedReactions) {
      state[reaction] = await hasFeedback(contentPath, reaction, npub, storage: storage);
    }

    return state;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Page View Tracking (Metric Feedback - Multiple Entries Allowed)
  // ═══════════════════════════════════════════════════════════════════════════

  /// Record a page view event with NOSTR signature.
  /// Unlike toggle feedback (likes, dislikes), page views allow multiple entries.
  ///
  /// Returns: true if view recorded successfully, false if signature invalid
  static Future<bool> recordViewEvent(
    String contentPath,
    NostrEvent viewEvent, {
    required ProfileStorage storage,
  }) async {
    // Verify signature before recording
    if (!viewEvent.verify()) {
      return false;
    }

    // Views don't need locking since multiple entries are allowed
    await ensureFeedbackFolder(contentPath, storage: storage);

    final filePath = buildFeedbackFilePath(contentPath, feedbackTypeViews);

    try {
      final eventJson = jsonEncode(viewEvent.toJson());
      await storage.appendString(filePath, '$eventJson\n');
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Get all view events for a content item.
  /// Returns list of verified NostrEvent objects, ordered chronologically.
  static Future<List<NostrEvent>> getViewEvents(
    String contentPath, {
    required ProfileStorage storage,
  }) async {
    final filePath = buildFeedbackFilePath(contentPath, feedbackTypeViews);
    final content = await storage.readString(filePath);
    if (content == null) return [];

    try {
      final lines = content
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList();

      final verifiedEvents = <NostrEvent>[];

      for (final line in lines) {
        if (line.startsWith('{')) {
          try {
            final json = jsonDecode(line) as Map<String, dynamic>;
            final event = NostrEvent.fromJson(json);

            // Verify signature
            if (event.verify()) {
              verifiedEvents.add(event);
            }
          } catch (e) {
            // Invalid JSON or event, skip
            continue;
          }
        }
      }

      // Sort by timestamp (oldest first)
      verifiedEvents.sort((a, b) => a.createdAt.compareTo(b.createdAt));

      return verifiedEvents;
    } catch (e) {
      return [];
    }
  }

  /// Get total view count for a content item.
  static Future<int> getViewCount(
    String contentPath, {
    required ProfileStorage storage,
  }) async {
    final events = await getViewEvents(contentPath, storage: storage);
    return events.length;
  }

  /// Get unique viewer count for a content item.
  static Future<int> getUniqueViewerCount(
    String contentPath, {
    required ProfileStorage storage,
  }) async {
    final events = await getViewEvents(contentPath, storage: storage);
    final uniqueNpubs = events.map((e) => e.npub).toSet();
    return uniqueNpubs.length;
  }

  /// Get view statistics for a content item.
  static Future<Map<String, dynamic>> getViewStats(
    String contentPath, {
    required ProfileStorage storage,
  }) async {
    final events = await getViewEvents(contentPath, storage: storage);

    if (events.isEmpty) {
      return {
        'total_views': 0,
        'unique_viewers': 0,
        'first_view': null,
        'latest_view': null,
      };
    }

    final uniqueNpubs = events.map((e) => e.npub).toSet();

    return {
      'total_views': events.length,
      'unique_viewers': uniqueNpubs.length,
      'first_view': events.first.createdAt,
      'latest_view': events.last.createdAt,
    };
  }

  /// Check if a specific user has viewed the content.
  static Future<bool> hasUserViewed(
    String contentPath,
    String npub, {
    required ProfileStorage storage,
  }) async {
    final events = await getViewEvents(contentPath, storage: storage);
    return events.any((e) => e.npub == npub);
  }

  /// Get view count for a specific user.
  static Future<int> getUserViewCount(
    String contentPath,
    String npub, {
    required ProfileStorage storage,
  }) async {
    final events = await getViewEvents(contentPath, storage: storage);
    return events.where((e) => e.npub == npub).length;
  }
}
