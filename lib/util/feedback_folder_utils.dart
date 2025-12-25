import 'dart:io';
import 'dart:convert';
import 'nostr_event.dart';
import 'nostr_crypto.dart';

/// Simple file-based lock for atomic feedback operations.
/// Prevents race conditions when multiple concurrent requests modify the same feedback file.
class _FileLock {
  final String lockFilePath;
  static const int maxWaitMs = 5000;
  static const int retryDelayMs = 50;

  _FileLock(String feedbackFilePath) : lockFilePath = '$feedbackFilePath.lock';

  /// Acquire the lock, waiting up to maxWaitMs if necessary.
  /// Returns true if lock acquired, false if timeout.
  Future<bool> acquire() async {
    final lockFile = File(lockFilePath);
    final startTime = DateTime.now();

    while (true) {
      try {
        // Try to create lock file exclusively (fails if exists)
        await lockFile.create(exclusive: true);
        return true; // Lock acquired
      } catch (e) {
        // Lock file exists, wait and retry
        final elapsed = DateTime.now().difference(startTime).inMilliseconds;
        if (elapsed > maxWaitMs) {
          return false; // Timeout
        }
        await Future.delayed(Duration(milliseconds: retryDelayMs));
      }
    }
  }

  /// Release the lock.
  Future<void> release() async {
    final lockFile = File(lockFilePath);
    try {
      if (await lockFile.exists()) {
        await lockFile.delete();
      }
    } catch (e) {
      // Lock file already deleted, ignore
    }
  }
}

/// Centralized utilities for generic feedback folder structure.
///
/// Feedback folder structure:
/// ```
/// {contentPath}/
/// └── feedback/
///     ├── likes.txt                  # Signed NOSTR events (JSON), one per line (toggle)
///     ├── points.txt                 # Signed NOSTR events (JSON), one per line (toggle)
///     ├── dislikes.txt               # Signed NOSTR events (JSON), one per line (toggle)
///     ├── subscribe.txt              # Signed NOSTR events (JSON), one per line (toggle)
///     ├── verifications.txt          # Signed NOSTR events (JSON), one per line (add-only)
///     ├── views.txt                  # Signed NOSTR events (JSON), multiple entries (metric)
///     ├── heart.txt                  # Emoji reaction: signed events, one per line (toggle)
///     ├── thumbs-up.txt              # Emoji reaction: signed events, one per line (toggle)
///     ├── fire.txt                   # Emoji reaction: signed events, one per line (toggle)
///     ├── celebrate.txt              # Emoji reaction: signed events, one per line (toggle)
///     ├── laugh.txt                  # Emoji reaction: signed events, one per line (toggle)
///     ├── sad.txt                    # Emoji reaction: signed events, one per line (toggle)
///     ├── surprise.txt               # Emoji reaction: signed events, one per line (toggle)
///     └── comments/
///         └── YYYY-MM-DD_HH-MM-SS_XXXXXX.txt
/// ```
///
/// This utility is content-type agnostic and works for:
/// - Blog posts
/// - Alert reports
/// - Forum threads
/// - Events
/// - Any other content type
class FeedbackFolderUtils {
  FeedbackFolderUtils._();

  /// Standard feedback types (toggles - one signed event per user)
  static const String feedbackTypeLikes = 'likes';
  static const String feedbackTypePoints = 'points';
  static const String feedbackTypeDislikes = 'dislikes';
  static const String feedbackTypeSubscribe = 'subscribe';
  static const String feedbackTypeVerifications = 'verifications';

  /// Metric feedback types (multiple entries allowed)
  static const String feedbackTypeViews = 'views';

  /// Emoji reaction types
  static const String reactionHeart = 'heart';
  static const String reactionThumbsUp = 'thumbs-up';
  static const String reactionFire = 'fire';
  static const String reactionCelebrate = 'celebrate';
  static const String reactionLaugh = 'laugh';
  static const String reactionSad = 'sad';
  static const String reactionSurprise = 'surprise';

  /// All supported emoji reactions
  static const List<String> supportedReactions = [
    reactionHeart,
    reactionThumbsUp,
    reactionFire,
    reactionCelebrate,
    reactionLaugh,
    reactionSad,
    reactionSurprise,
  ];

  /// Build path to the feedback folder for a content item.
  static String buildFeedbackPath(String contentPath) {
    return '$contentPath/feedback';
  }

  /// Build path to a feedback file (likes.txt, points.txt, etc.).
  ///
  /// Example:
  /// ```dart
  /// buildFeedbackFilePath(contentPath, FeedbackFolderUtils.feedbackTypeLikes)
  /// // Returns: {contentPath}/feedback/likes.txt
  /// ```
  static String buildFeedbackFilePath(String contentPath, String feedbackType) {
    return '${buildFeedbackPath(contentPath)}/$feedbackType.txt';
  }

  /// Build path to the comments subfolder.
  static String buildCommentsPath(String contentPath) {
    return '${buildFeedbackPath(contentPath)}/comments';
  }

  /// Ensure feedback folder exists.
  static Future<void> ensureFeedbackFolder(String contentPath) async {
    final feedbackDir = Directory(buildFeedbackPath(contentPath));
    if (!await feedbackDir.exists()) {
      await feedbackDir.create(recursive: true);
    }
  }

  /// Read signed feedback events from a feedback file.
  /// Returns list of verified npub strings, empty list if file doesn't exist.
  /// Only includes feedback with valid NOSTR signatures.
  ///
  /// File format: Each line is a JSON signed NOSTR event (verified).
  /// Plain npub lines are not supported and are ignored.
  ///
  /// Example:
  /// ```dart
  /// final likes = await readFeedbackFile(contentPath, FeedbackFolderUtils.feedbackTypeLikes);
  /// ```
  static Future<List<String>> readFeedbackFile(
    String contentPath,
    String feedbackType,
  ) async {
    final feedbackFile = File(buildFeedbackFilePath(contentPath, feedbackType));
    if (!await feedbackFile.exists()) return [];

    final content = await feedbackFile.readAsString();
    final lines = content
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();

    final verifiedNpubs = <String>[];

    for (final line in lines) {
      // Try to parse as JSON event
      if (line.startsWith('{')) {
        try {
          final json = jsonDecode(line) as Map<String, dynamic>;
          final event = NostrEvent.fromJson(json);

          // Verify signature
          if (event.verify()) {
            verifiedNpubs.add(event.npub);
          }
        } catch (e) {
          // Invalid JSON or event, skip
          continue;
        }
      }
      // Legacy format (plain npub) is ignored for security - no signature
    }

    return verifiedNpubs;
  }

  /// Read signed feedback events (full event objects with signatures).
  /// Returns list of verified NostrEvent objects.
  ///
  /// Example:
  /// ```dart
  /// final events = await readFeedbackEvents(contentPath, FeedbackFolderUtils.feedbackTypeLikes);
  /// ```
  static Future<List<NostrEvent>> readFeedbackEvents(
    String contentPath,
    String feedbackType,
  ) async {
    final feedbackFile = File(buildFeedbackFilePath(contentPath, feedbackType));
    if (!await feedbackFile.exists()) return [];

    final content = await feedbackFile.readAsString();
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
  /// Each event is written as a JSON object on a separate line.
  /// If the list is empty, the file is deleted.
  ///
  /// Example:
  /// ```dart
  /// await writeFeedbackEvents(contentPath, FeedbackFolderUtils.feedbackTypeLikes, [event1, event2]);
  /// ```
  static Future<void> writeFeedbackEvents(
    String contentPath,
    String feedbackType,
    List<NostrEvent> events,
  ) async {
    await ensureFeedbackFolder(contentPath);
    final feedbackFile = File(buildFeedbackFilePath(contentPath, feedbackType));

    if (events.isEmpty) {
      // Delete the file if no feedback
      if (await feedbackFile.exists()) {
        await feedbackFile.delete();
      }
      return;
    }

    final lines = events.map((event) => jsonEncode(event.toJson())).join('\n');
    await feedbackFile.writeAsString(lines, flush: true);
  }

  /// Write npubs to a feedback file (DEPRECATED - use writeFeedbackEvents for security).
  /// Each npub is written on a separate line.
  /// If the list is empty, the file is deleted.
  ///
  /// Example:
  /// ```dart
  /// await writeFeedbackFile(contentPath, FeedbackFolderUtils.feedbackTypeLikes, ['npub1...', 'npub2...']);
  /// ```
  @Deprecated('Use writeFeedbackEvents with signed NOSTR events for security')
  static Future<void> writeFeedbackFile(
    String contentPath,
    String feedbackType,
    List<String> npubs,
  ) async {
    await ensureFeedbackFolder(contentPath);
    final feedbackFile = File(buildFeedbackFilePath(contentPath, feedbackType));

    if (npubs.isEmpty) {
      // Delete the file if no feedback
      if (await feedbackFile.exists()) {
        await feedbackFile.delete();
      }
      return;
    }

    await feedbackFile.writeAsString(npubs.join('\n'), flush: true);
  }

  /// Add signed feedback event if not already present.
  /// Returns true if the feedback was added, false if already exists or signature invalid.
  /// Uses file locking to prevent race conditions and duplicate feedback.
  ///
  /// Example:
  /// ```dart
  /// final added = await addFeedbackEvent(contentPath, FeedbackFolderUtils.feedbackTypeLikes, signedEvent);
  /// ```
  static Future<bool> addFeedbackEvent(
    String contentPath,
    String feedbackType,
    NostrEvent event,
  ) async {
    // Verify signature before adding
    if (!event.verify()) {
      return false;
    }

    await ensureFeedbackFolder(contentPath);

    // Acquire lock to prevent race conditions
    final feedbackFilePath = buildFeedbackFilePath(contentPath, feedbackType);
    final lock = _FileLock(feedbackFilePath);

    if (!await lock.acquire()) {
      return false; // Lock timeout, treat as error
    }

    try {
      // CRITICAL SECTION - atomic read-check-write
      final events = await readFeedbackEvents(contentPath, feedbackType);
      final npub = event.npub;

      // Check if this npub already has feedback
      if (events.any((e) => e.npub == npub)) {
        return false;
      }

      events.add(event);
      await writeFeedbackEvents(contentPath, feedbackType, events);
      return true;
    } finally {
      // Always release lock
      await lock.release();
    }
  }

  /// Add feedback (npub) if not already present (DEPRECATED - use addFeedbackEvent for security).
  /// Returns true if the feedback was added, false if already exists.
  ///
  /// Example:
  /// ```dart
  /// final added = await addFeedback(contentPath, FeedbackFolderUtils.feedbackTypeLikes, 'npub1...');
  /// ```
  @Deprecated('Use addFeedbackEvent with signed NOSTR events for security')
  static Future<bool> addFeedback(
    String contentPath,
    String feedbackType,
    String npub,
  ) async {
    final npubs = await readFeedbackFile(contentPath, feedbackType);
    if (npubs.contains(npub)) return false;

    npubs.add(npub);
    await writeFeedbackFile(contentPath, feedbackType, npubs);
    return true;
  }

  /// Remove feedback event from a feedback file by npub.
  /// Returns true if the feedback was removed, false if not found.
  /// Uses file locking to prevent race conditions.
  ///
  /// Example:
  /// ```dart
  /// final removed = await removeFeedbackEvent(contentPath, FeedbackFolderUtils.feedbackTypeLikes, 'npub1...');
  /// ```
  static Future<bool> removeFeedbackEvent(
    String contentPath,
    String feedbackType,
    String npub,
  ) async {
    await ensureFeedbackFolder(contentPath);

    // Acquire lock to prevent race conditions
    final feedbackFilePath = buildFeedbackFilePath(contentPath, feedbackType);
    final lock = _FileLock(feedbackFilePath);

    if (!await lock.acquire()) {
      return false; // Lock timeout, treat as error
    }

    try {
      // CRITICAL SECTION - atomic read-modify-write
      final events = await readFeedbackEvents(contentPath, feedbackType);
      final initialLength = events.length;

      events.removeWhere((e) => e.npub == npub);

      if (events.length == initialLength) {
        return false; // Not found
      }

      await writeFeedbackEvents(contentPath, feedbackType, events);
      return true;
    } finally {
      // Always release lock
      await lock.release();
    }
  }

  /// Toggle feedback with signed event (add if not present, remove if present).
  /// Returns true if added, false if removed, null if signature invalid.
  /// Uses file locking to prevent race conditions and duplicate feedback.
  ///
  /// Example:
  /// ```dart
  /// final isNowActive = await toggleFeedbackEvent(contentPath, FeedbackFolderUtils.feedbackTypeLikes, signedEvent);
  /// ```
  static Future<bool?> toggleFeedbackEvent(
    String contentPath,
    String feedbackType,
    NostrEvent event,
  ) async {
    // Verify signature before processing
    if (!event.verify()) {
      return null; // Invalid signature
    }

    await ensureFeedbackFolder(contentPath);

    // Acquire lock to prevent race conditions
    final feedbackFilePath = buildFeedbackFilePath(contentPath, feedbackType);
    final lock = _FileLock(feedbackFilePath);

    if (!await lock.acquire()) {
      return null; // Lock timeout, treat as error
    }

    try {
      // CRITICAL SECTION - atomic read-modify-write
      final events = await readFeedbackEvents(contentPath, feedbackType);
      final npub = event.npub;

      // Check if this npub already has feedback
      final existingIndex = events.indexWhere((e) => e.npub == npub);

      if (existingIndex >= 0) {
        // Remove existing feedback
        events.removeAt(existingIndex);
        await writeFeedbackEvents(contentPath, feedbackType, events);
        return false; // Removed
      } else {
        // Add new feedback
        events.add(event);
        await writeFeedbackEvents(contentPath, feedbackType, events);
        return true; // Added
      }
    } finally {
      // Always release lock
      await lock.release();
    }
  }

  /// Remove feedback (npub) from a feedback file (DEPRECATED - use removeFeedbackEvent).
  /// Returns true if the feedback was removed, false if not found.
  ///
  /// Example:
  /// ```dart
  /// final removed = await removeFeedback(contentPath, FeedbackFolderUtils.feedbackTypeLikes, 'npub1...');
  /// ```
  @Deprecated('Use removeFeedbackEvent for consistency with signed events')
  static Future<bool> removeFeedback(
    String contentPath,
    String feedbackType,
    String npub,
  ) async {
    final npubs = await readFeedbackFile(contentPath, feedbackType);
    if (!npubs.contains(npub)) return false;

    npubs.remove(npub);
    await writeFeedbackFile(contentPath, feedbackType, npubs);
    return true;
  }

  /// Toggle feedback (add if not present, remove if present) (DEPRECATED - use toggleFeedbackEvent for security).
  /// Returns true if added, false if removed.
  ///
  /// Example:
  /// ```dart
  /// final isNowActive = await toggleFeedback(contentPath, FeedbackFolderUtils.feedbackTypeLikes, 'npub1...');
  /// ```
  @Deprecated('Use toggleFeedbackEvent with signed NOSTR events for security')
  static Future<bool> toggleFeedback(
    String contentPath,
    String feedbackType,
    String npub,
  ) async {
    final npubs = await readFeedbackFile(contentPath, feedbackType);
    if (npubs.contains(npub)) {
      npubs.remove(npub);
      await writeFeedbackFile(contentPath, feedbackType, npubs);
      return false; // Removed
    } else {
      npubs.add(npub);
      await writeFeedbackFile(contentPath, feedbackType, npubs);
      return true; // Added
    }
  }

  /// Get feedback count by counting lines in feedback file.
  ///
  /// Example:
  /// ```dart
  /// final likeCount = await getFeedbackCount(contentPath, FeedbackFolderUtils.feedbackTypeLikes);
  /// ```
  static Future<int> getFeedbackCount(
    String contentPath,
    String feedbackType,
  ) async {
    final npubs = await readFeedbackFile(contentPath, feedbackType);
    return npubs.length;
  }

  /// Check if a user has provided specific feedback.
  ///
  /// Example:
  /// ```dart
  /// final hasLiked = await hasFeedback(contentPath, FeedbackFolderUtils.feedbackTypeLikes, 'npub1...');
  /// ```
  static Future<bool> hasFeedback(
    String contentPath,
    String feedbackType,
    String npub,
  ) async {
    final npubs = await readFeedbackFile(contentPath, feedbackType);
    return npubs.contains(npub);
  }

  /// Get all feedback counts for a content item.
  /// Returns a map with feedbackType as key and count as value.
  ///
  /// Example:
  /// ```dart
  /// final counts = await getAllFeedbackCounts(contentPath);
  /// // Returns: {'likes': 5, 'points': 3, 'dislikes': 1, 'views': 120, 'heart': 8, ...}
  /// ```
  static Future<Map<String, int>> getAllFeedbackCounts(
    String contentPath,
  ) async {
    final counts = <String, int>{};

    // Standard feedback types (toggles)
    counts[feedbackTypeLikes] = await getFeedbackCount(contentPath, feedbackTypeLikes);
    counts[feedbackTypePoints] = await getFeedbackCount(contentPath, feedbackTypePoints);
    counts[feedbackTypeDislikes] = await getFeedbackCount(contentPath, feedbackTypeDislikes);
    counts[feedbackTypeSubscribe] = await getFeedbackCount(contentPath, feedbackTypeSubscribe);
    counts[feedbackTypeVerifications] = await getFeedbackCount(contentPath, feedbackTypeVerifications);

    // Metric feedback types (counters)
    counts[feedbackTypeViews] = await getViewCount(contentPath);

    // Emoji reactions
    for (final reaction in supportedReactions) {
      counts[reaction] = await getFeedbackCount(contentPath, reaction);
    }

    return counts;
  }

  /// Get user's feedback state for a content item.
  /// Returns a map indicating which feedback types the user has provided.
  ///
  /// Example:
  /// ```dart
  /// final userState = await getUserFeedbackState(contentPath, 'npub1...');
  /// // Returns: {'likes': true, 'points': false, 'heart': true, ...}
  /// ```
  static Future<Map<String, bool>> getUserFeedbackState(
    String contentPath,
    String npub,
  ) async {
    final state = <String, bool>{};

    // Standard feedback types
    state[feedbackTypeLikes] = await hasFeedback(contentPath, feedbackTypeLikes, npub);
    state[feedbackTypePoints] = await hasFeedback(contentPath, feedbackTypePoints, npub);
    state[feedbackTypeDislikes] = await hasFeedback(contentPath, feedbackTypeDislikes, npub);
    state[feedbackTypeSubscribe] = await hasFeedback(contentPath, feedbackTypeSubscribe, npub);
    state[feedbackTypeVerifications] = await hasFeedback(contentPath, feedbackTypeVerifications, npub);

    // Emoji reactions
    for (final reaction in supportedReactions) {
      state[reaction] = await hasFeedback(contentPath, reaction, npub);
    }

    return state;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Page View Tracking (Metric Feedback - Multiple Entries Allowed)
  // ═══════════════════════════════════════════════════════════════════════════

  /// Record a page view event with NOSTR signature.
  /// Unlike toggle feedback (likes, dislikes), page views allow multiple entries.
  /// Each view is recorded as a signed NOSTR event with timestamp.
  ///
  /// Use this for tracking:
  /// - Blog post views
  /// - Forum thread views
  /// - Event page views
  /// - Alert report views
  ///
  /// Parameters:
  /// - contentPath: Path to the content (blog post, forum thread, etc.)
  /// - viewEvent: Signed NOSTR event representing the view
  ///
  /// Returns: true if view recorded successfully, false if signature invalid
  ///
  /// Example:
  /// ```dart
  /// final viewEvent = NostrEvent(
  ///   pubkey: pubkeyHex,
  ///   createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
  ///   kind: 1,
  ///   tags: [['e', postId], ['type', 'view']],
  ///   content: 'view',
  /// );
  /// viewEvent.calculateId();
  /// viewEvent.signWithNsec(nsec);
  ///
  /// final success = await FeedbackFolderUtils.recordViewEvent(contentPath, viewEvent);
  /// ```
  static Future<bool> recordViewEvent(
    String contentPath,
    NostrEvent viewEvent,
  ) async {
    // Verify signature before recording
    if (!viewEvent.verify()) {
      return false;
    }

    // Views don't need locking since multiple entries are allowed
    // Even concurrent views from same user are valid
    await ensureFeedbackFolder(contentPath);

    final viewsFile = File(buildFeedbackFilePath(contentPath, feedbackTypeViews));

    try {
      // Append view event to file
      final eventJson = jsonEncode(viewEvent.toJson());
      final sink = viewsFile.openWrite(mode: FileMode.append);
      sink.writeln(eventJson);
      await sink.flush();
      await sink.close();

      return true;
    } catch (e) {
      return false;
    }
  }

  /// Get all view events for a content item.
  /// Returns list of verified NostrEvent objects, ordered chronologically.
  ///
  /// Example:
  /// ```dart
  /// final viewEvents = await FeedbackFolderUtils.getViewEvents(contentPath);
  /// for (final event in viewEvents) {
  ///   print('View at ${DateTime.fromMillisecondsSinceEpoch(event.createdAt * 1000)}');
  ///   print('  by ${event.npub}');
  /// }
  /// ```
  static Future<List<NostrEvent>> getViewEvents(String contentPath) async {
    final viewsFile = File(buildFeedbackFilePath(contentPath, feedbackTypeViews));
    if (!await viewsFile.exists()) return [];

    try {
      final content = await viewsFile.readAsString();
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
  /// Counts all verified view events, including multiple views from same user.
  ///
  /// Example:
  /// ```dart
  /// final totalViews = await FeedbackFolderUtils.getViewCount(contentPath);
  /// print('Total views: $totalViews');
  /// ```
  static Future<int> getViewCount(String contentPath) async {
    final events = await getViewEvents(contentPath);
    return events.length;
  }

  /// Get unique viewer count for a content item.
  /// Counts distinct npubs who have viewed the content.
  ///
  /// Example:
  /// ```dart
  /// final uniqueViewers = await FeedbackFolderUtils.getUniqueViewerCount(contentPath);
  /// print('Unique viewers: $uniqueViewers');
  /// ```
  static Future<int> getUniqueViewerCount(String contentPath) async {
    final events = await getViewEvents(contentPath);
    final uniqueNpubs = events.map((e) => e.npub).toSet();
    return uniqueNpubs.length;
  }

  /// Get view statistics for a content item.
  /// Returns map with total views, unique viewers, and recent view timestamps.
  ///
  /// Example:
  /// ```dart
  /// final stats = await FeedbackFolderUtils.getViewStats(contentPath);
  /// print('Total views: ${stats['total_views']}');
  /// print('Unique viewers: ${stats['unique_viewers']}');
  /// print('First view: ${stats['first_view']}');
  /// print('Latest view: ${stats['latest_view']}');
  /// ```
  static Future<Map<String, dynamic>> getViewStats(String contentPath) async {
    final events = await getViewEvents(contentPath);

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
  ///
  /// Example:
  /// ```dart
  /// final hasViewed = await FeedbackFolderUtils.hasUserViewed(contentPath, 'npub1...');
  /// ```
  static Future<bool> hasUserViewed(String contentPath, String npub) async {
    final events = await getViewEvents(contentPath);
    return events.any((e) => e.npub == npub);
  }

  /// Get view count for a specific user.
  /// Returns how many times a specific user has viewed the content.
  ///
  /// Example:
  /// ```dart
  /// final userViewCount = await FeedbackFolderUtils.getUserViewCount(contentPath, 'npub1...');
  /// print('User viewed this content $userViewCount times');
  /// ```
  static Future<int> getUserViewCount(String contentPath, String npub) async {
    final events = await getViewEvents(contentPath);
    return events.where((e) => e.npub == npub).length;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Migration Utilities
  // ═══════════════════════════════════════════════════════════════════════════

  /// Migrate existing comments folder to feedback/comments.
  /// Moves files from {contentPath}/comments/ to {contentPath}/feedback/comments/
  /// if the old structure exists.
  ///
  /// This supports backwards compatibility during migration.
  static Future<void> migrateCommentsFolder(String contentPath) async {
    final oldCommentsDir = Directory('$contentPath/comments');
    if (!await oldCommentsDir.exists()) return; // Nothing to migrate

    final newCommentsDir = Directory(buildCommentsPath(contentPath));
    await newCommentsDir.create(recursive: true);

    // Move all files
    await for (final entity in oldCommentsDir.list()) {
      if (entity is File) {
        final filename = entity.path.split('/').last;
        final newPath = '${newCommentsDir.path}/$filename';
        await entity.rename(newPath);
      }
    }

    // Remove old directory if empty
    final remaining = await oldCommentsDir.list().length;
    if (remaining == 0) {
      await oldCommentsDir.delete();
    }
  }

  /// Migrate existing points.txt from root to feedback/points.txt.
  /// Moves {contentPath}/points.txt to {contentPath}/feedback/points.txt
  /// if the old file exists.
  ///
  /// This supports backwards compatibility for alerts during migration.
  static Future<void> migratePointsFile(String contentPath) async {
    final oldPointsFile = File('$contentPath/points.txt');
    if (!await oldPointsFile.exists()) return; // Nothing to migrate

    await ensureFeedbackFolder(contentPath);
    final newPointsFile = File(buildFeedbackFilePath(contentPath, feedbackTypePoints));
    await oldPointsFile.rename(newPointsFile.path);
  }
}
