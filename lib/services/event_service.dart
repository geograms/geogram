/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import '../models/event.dart';
import '../models/event_comment.dart';
import '../models/event_reaction.dart';
import '../models/event_item.dart';
import '../models/event_update.dart';
import '../models/event_registration.dart';
import '../models/event_link.dart';
import '../util/event_bus.dart';
import '../util/feedback_comment_utils.dart';
import '../util/feedback_folder_utils.dart';
import 'contact_service.dart';
import 'profile_storage.dart';

/// Service for managing events, files, and reactions
///
/// IMPORTANT: All file operations go through the ProfileStorage abstraction.
/// Never use File() or Directory() directly in this service.
class EventService {
  static final EventService _instance = EventService._internal();
  factory EventService() => _instance;
  EventService._internal();

  /// Optional callback to publish activity when an event is created.
  /// Set by Flutter app; not available in CLI mode.
  static Future<void> Function(Event)? onEventCreated;

  /// Profile storage for file operations (encrypted or filesystem)
  /// IMPORTANT: This MUST be set before using the service.
  /// All file operations go through this abstraction.
  late ProfileStorage _storage;
  bool _storageInitialized = false;

  String? _appPath;

  /// Safely get storage or null if not yet initialized
  ProfileStorage? get _storageOrNull => _storageInitialized ? _storage : null;

  /// Whether using encrypted storage
  bool get useEncryptedStorage => _storage.isEncrypted;

  /// Set the profile storage for file operations
  /// MUST be called before initializeApp
  void setStorage(ProfileStorage storage) {
    _storage = storage;
    _storageInitialized = true;
  }

  /// Initialize event service for a collection
  Future<void> initializeApp(String appPath) async {
    print('EventService: Initializing with collection path: $appPath');
    _appPath = appPath;

    // Ensure collection directory exists via storage abstraction
    await _storage.createDirectory('');
    print('EventService: Initialized with ProfileStorage');
  }

  /// Get available years (folders in collection directory)
  Future<List<int>> getYears() async {
    if (_appPath == null) return [];

    final years = <int>[];

    final entries = await _storage.listDirectory('');
    for (var entry in entries) {
      if (entry.isDirectory) {
        final year = int.tryParse(entry.name);
        if (year != null) {
          years.add(year);
        }
      }
    }

    years.sort((a, b) => b.compareTo(a)); // Most recent first
    return years;
  }

  /// Load events for a specific year or all years
  /// Uses lightweight summaries (only event.txt + flyer list) and parallel batches.
  Future<List<Event>> loadEvents({
    int? year,
    String? currentCallsign,
    String? currentUserNpub,
  }) async {
    if (_appPath == null) return [];

    // Collect all event folder names across years
    final years = year != null ? [year] : await getYears();
    final eventNames = <String>[];

    for (var y in years) {
      final entries = await _storage.listDirectory('$y');
      for (var entry in entries) {
        if (entry.isDirectory &&
            RegExp(r'^\d{4}-\d{2}-\d{2}_').hasMatch(entry.name)) {
          eventNames.add(entry.name);
        }
      }
    }

    // Load summaries in parallel batches of 10
    final events = <Event>[];
    const batchSize = 10;
    for (var i = 0; i < eventNames.length; i += batchSize) {
      final batch = eventNames.sublist(
        i,
        i + batchSize > eventNames.length ? eventNames.length : i + batchSize,
      );
      final results = await Future.wait(
        batch.map((name) => loadEventSummary(name)),
      );
      for (final event in results) {
        if (event != null) events.add(event);
      }
    }

    // Sort by date (most recent first)
    events.sort((a, b) => b.dateTime.compareTo(a.dateTime));

    return events;
  }

  /// Load only the fields needed for the list tile: event.txt + primary flyer.
  /// Skips reactions, feedback, updates, registration, links, trailer.
  Future<Event?> loadEventSummary(String eventId) async {
    if (_appPath == null) return null;

    final year = eventId.substring(0, 4);
    final eventRelativePath = '$year/$eventId';

    if (!await _storage.directoryExists(eventRelativePath)) return null;

    final content = await _storage.readString('$eventRelativePath/event.txt');
    if (content == null) return null;

    try {
      final event = Event.fromText(content, eventId);

      // Only scan for flyers (needed for thumbnail in list tile)
      final flyers = await _loadFlyersStorage(eventRelativePath);

      return event.copyWith(flyers: flyers);
    } catch (e) {
      print('EventService: Error loading event summary $eventId: $e');
      return null;
    }
  }

  /// Stream event summaries as they load — yields batches progressively.
  /// UI can start rendering before all events are loaded.
  Stream<List<Event>> loadEventSummariesStream({
    String? currentCallsign,
    String? currentUserNpub,
  }) async* {
    if (_appPath == null) return;

    final years = await getYears();
    final eventNames = <String>[];

    for (var y in years) {
      final entries = await _storage.listDirectory('$y');
      for (var entry in entries) {
        if (entry.isDirectory &&
            RegExp(r'^\d{4}-\d{2}-\d{2}_').hasMatch(entry.name)) {
          eventNames.add(entry.name);
        }
      }
    }

    const batchSize = 10;
    for (var i = 0; i < eventNames.length; i += batchSize) {
      final batch = eventNames.sublist(
        i,
        i + batchSize > eventNames.length ? eventNames.length : i + batchSize,
      );
      final results = await Future.wait(
        batch.map((name) => loadEventSummary(name)),
      );
      final loaded = results.whereType<Event>().toList();
      if (loaded.isNotEmpty) yield loaded;
    }
  }

  /// Load full event with reactions and v1.2 features
  Future<Event?> loadEvent(String eventId) async {
    if (_appPath == null) return null;

    // Extract year from eventId (format: YYYY-MM-DD_title)
    final year = eventId.substring(0, 4);
    final eventRelativePath = '$year/$eventId';
    final eventDirPath = '$_appPath/$year/$eventId';

    if (!await _storage.directoryExists(eventRelativePath)) {
      print('EventService: Event directory not found: $eventRelativePath');
      return null;
    }

    final content = await _storage.readString('$eventRelativePath/event.txt');
    if (content == null) {
      print('EventService: event.txt not found in $eventRelativePath');
      return null;
    }

    try {
      final event = Event.fromText(content, eventId);

      // Load event-level reactions (legacy) or centralized feedback (preferred)
      // Note: Helper methods still use filesystem paths - full migration pending
      final eventReaction = await _loadReactionStorage(eventRelativePath, 'event.txt');
      final hasFeedbackDir = await _storage.directoryExists('$eventRelativePath/.feedback');
      List<String> eventLikes = [];
      List<EventComment> eventComments = [];

      if (hasFeedbackDir) {
        // Note: FeedbackFolderUtils/FeedbackCommentUtils still use filesystem paths
        // Full migration pending - for now use filesystem path for these utils
        final feedbackLikes = await FeedbackFolderUtils.readFeedbackFile(
          eventDirPath,
          FeedbackFolderUtils.feedbackTypeLikes,
          storage: _storage,
        );
        final feedbackComments = await FeedbackCommentUtils.loadComments(eventDirPath, storage: _storage);

        eventLikes = feedbackLikes;
        eventComments = feedbackComments.map((comment) {
          final metadata = <String, String>{};
          final npub = comment.npub;
          if (npub != null && npub.isNotEmpty) {
            metadata['npub'] = npub;
          }
          final signature = comment.signature;
          if (signature != null && signature.isNotEmpty) {
            metadata['signature'] = signature;
          }
          return EventComment(
            author: comment.author,
            timestamp: comment.created,
            content: comment.content,
            metadata: metadata,
          );
        }).toList();
      } else {
        eventLikes = eventReaction?.likes ?? event.likes;
        eventComments = eventReaction?.comments ?? event.comments;
      }

      // Load v1.2 features via storage abstraction
      final flyers = await _loadFlyersStorage(eventRelativePath);
      final trailer = await _loadTrailerStorage(eventRelativePath);
      final updates = await _loadUpdatesStorage(eventRelativePath);
      final registration = await _loadRegistrationStorage(eventRelativePath);
      final links = await _loadLinksStorage(eventRelativePath);

      return event.copyWith(
        likes: eventLikes,
        comments: eventComments,
        flyers: flyers,
        trailer: trailer,
        updates: updates,
        registration: registration,
        links: links,
      );
    } catch (e) {
      print('EventService: Error loading event: $e');
      return null;
    }
  }

  /// Load reaction file for a specific item (storage-based)
  Future<EventReaction?> _loadReactionStorage(String eventRelativePath, String targetItem) async {
    // Remove .txt extension from targetItem if present for the reaction filename
    final reactionTarget = targetItem.endsWith('.txt')
        ? targetItem
        : '$targetItem.txt';

    final content = await _storage.readString('$eventRelativePath/.reactions/$reactionTarget');
    if (content == null) return null;

    try {
      return EventReaction.fromText(content, targetItem);
    } catch (e) {
      print('EventService: Error loading reaction: $e');
      return null;
    }
  }

  /// Sanitize title to create valid folder name
  String sanitizeFolderName(String title, DateTime? date) {
    date ??= DateTime.now();

    // Preserve title casing/letters; only remove characters invalid on common filesystems.
    String sanitized = title;
    sanitized = sanitized.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '');
    sanitized = sanitized.replaceAll(RegExp(r'[<>:"/\\\\|?*]'), '-');
    sanitized = sanitized.trim();
    sanitized = sanitized.replaceAll(RegExp(r'[. ]+$'), '');
    if (sanitized.isEmpty) {
      sanitized = 'event';
    }

    // Format date as YYYY-MM-DD
    final year = date.year.toString().padLeft(4, '0');
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');

    return '$year-$month-$day\_$sanitized';
  }

  /// Check if folder name already exists, add suffix if needed
  Future<String> _ensureUniqueFolderName(String baseFolderName, int year) async {
    String folderName = baseFolderName;
    int suffix = 1;

    while (await _storage.directoryExists('$year/$folderName')) {
      folderName = '$baseFolderName-$suffix';
      suffix++;
    }

    return folderName;
  }

  /// Create new event
  ///
  /// When [customSlug] is provided it replaces the auto-generated title
  /// portion of the folder name, producing `YYYY-MM-DD_<customSlug>`.
  Future<Event?> createEvent({
    required String author,
    required String title,
    DateTime? eventDate,
    String? startDate,
    String? endDate,
    required String location,
    String? locationName,
    required String content,
    String? agenda,
    String? visibility,
    List<String>? admins,
    List<String>? moderators,
    List<String>? groupAccess,
    String? unlistedKey,
    List<String>? accessCallsigns,
    String? accessRequestPrompt,
    List<String>? contacts,
    String? npub,
    Map<String, String>? metadata,
    String? customSlug,
  }) async {
    if (_appPath == null) return null;

    try {
      // Use provided event date or current time
      final dateToUse = eventDate ?? DateTime.now();
      final year = dateToUse.year;

      // Sanitize folder name (always from title — slug is stored inside event.txt)
      final baseFolderName = sanitizeFolderName(title, dateToUse);
      final folderName = await _ensureUniqueFolderName(baseFolderName, year);

      // Event paths
      final eventRelativePath = '$year/$folderName';

      // Create year and event directories via storage abstraction
      await _storage.createDirectory('$year');
      await _storage.createDirectory(eventRelativePath);
      await _storage.createDirectory('$eventRelativePath/.reactions');
      // Note: FeedbackFolderUtils still uses filesystem - needs future migration

      // Create day folders if multi-day event
      if (startDate != null && endDate != null && startDate != endDate) {
        final start = DateTime.parse(startDate);
        final end = DateTime.parse(endDate);
        final days = end.difference(start).inDays + 1;

        for (int i = 1; i <= days; i++) {
          await _storage.createDirectory('$eventRelativePath/day$i');
          await _storage.createDirectory('$eventRelativePath/day$i/.reactions');
        }
      }

      // Create event object
      final slugValue = (customSlug != null && customSlug.trim().isNotEmpty)
          ? customSlug.trim()
          : null;
      final event = Event(
        id: folderName,
        author: author,
        timestamp: _formatTimestamp(dateToUse),
        title: title,
        startDate: startDate,
        endDate: endDate,
        admins: admins ?? [],
        moderators: moderators ?? [],
        groupAccess: groupAccess ?? [],
        unlistedKey: unlistedKey,
        accessCallsigns: accessCallsigns ?? [],
        accessRequestPrompt: accessRequestPrompt,
        contacts: contacts ?? [],
        location: location,
        locationName: locationName,
        content: content,
        agenda: agenda,
        visibility: visibility ?? 'private',
        slug: slugValue,
        metadata: {
          ...?metadata,
          if (npub != null) 'npub': npub,
        },
      );

      // Write event.txt via storage abstraction
      await _storage.writeString('$eventRelativePath/event.txt', event.exportAsText());

      // Record event associations in contact metrics
      if (contacts != null && contacts.isNotEmpty) {
        await ContactService().recordEventAssociations(contacts);
      }

      print('EventService: Created event: $folderName');

      // Notify Now feed
      EventBus().fire(EventCreatedEvent(
        eventId: folderName,
        author: author,
        title: title,
        eventRecord: event,
      ));

      return event;
    } catch (e) {
      print('EventService: Error creating event: $e');
      return null;
    }
  }

  /// Format DateTime to timestamp string
  String _formatTimestamp(DateTime dt) {
    final year = dt.year.toString().padLeft(4, '0');
    final month = dt.month.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    final second = dt.second.toString().padLeft(2, '0');
    return '$year-$month-$day $hour:$minute\_$second';
  }

  /// Add like to event or event item
  Future<bool> addLike({
    required String eventId,
    required String callsign,
    String? targetItem, // null for event itself, or filename/folder name
  }) async {
    if (_appPath == null) return false;

    try {
      final year = eventId.substring(0, 4);
      final eventRelativePath = '$year/$eventId';

      if (!await _storage.directoryExists(eventRelativePath)) return false;

      // Determine reaction file path
      final target = targetItem ?? 'event.txt';
      final reactionPath = '$eventRelativePath/.reactions/$target';

      // Load or create reaction
      EventReaction reaction;
      final content = await _storage.readString(reactionPath);
      if (content != null) {
        reaction = EventReaction.fromText(content, target);
      } else {
        reaction = EventReaction(target: target);
      }

      // Check if already liked
      if (reaction.hasUserLiked(callsign)) {
        return true; // Already liked
      }

      // Add like
      final updatedLikes = [...reaction.likes, callsign];
      final updatedReaction = reaction.copyWith(likes: updatedLikes);

      // Ensure .reactions directory exists
      await _storage.createDirectory('$eventRelativePath/.reactions');

      // Write updated reaction
      await _storage.writeString(reactionPath, updatedReaction.exportAsText());

      print('EventService: Added like from $callsign to $target');
      return true;
    } catch (e) {
      print('EventService: Error adding like: $e');
      return false;
    }
  }

  /// Remove like from event or event item
  Future<bool> removeLike({
    required String eventId,
    required String callsign,
    String? targetItem,
  }) async {
    if (_appPath == null) return false;

    try {
      final year = eventId.substring(0, 4);
      final eventRelativePath = '$year/$eventId';

      if (!await _storage.directoryExists(eventRelativePath)) return false;

      final target = targetItem ?? 'event.txt';
      final reactionPath = '$eventRelativePath/.reactions/$target';

      final content = await _storage.readString(reactionPath);
      if (content == null) return false;

      // Load reaction
      final reaction = EventReaction.fromText(content, target);

      // Remove like
      final updatedLikes = reaction.likes.where((c) => c != callsign).toList();
      final updatedReaction = reaction.copyWith(likes: updatedLikes);

      // If no likes and no comments, delete the file
      if (updatedReaction.likes.isEmpty && updatedReaction.comments.isEmpty) {
        await _storage.delete(reactionPath);
      } else {
        await _storage.writeString(reactionPath, updatedReaction.exportAsText());
      }

      print('EventService: Removed like from $callsign on $target');
      return true;
    } catch (e) {
      print('EventService: Error removing like: $e');
      return false;
    }
  }

  /// Add comment to event or event item
  Future<bool> addComment({
    required String eventId,
    required String author,
    required String content,
    String? targetItem,
    String? npub,
  }) async {
    if (_appPath == null) return false;

    try {
      final year = eventId.substring(0, 4);
      final eventRelativePath = '$year/$eventId';

      if (!await _storage.directoryExists(eventRelativePath)) return false;

      final target = targetItem ?? 'event.txt';
      final reactionPath = '$eventRelativePath/.reactions/$target';

      // Load or create reaction
      EventReaction reaction;
      final fileContent = await _storage.readString(reactionPath);
      if (fileContent != null) {
        reaction = EventReaction.fromText(fileContent, target);
      } else {
        reaction = EventReaction(target: target);
      }

      // Create new comment
      final comment = EventComment.now(
        author: author,
        content: content,
        metadata: npub != null ? {'npub': npub} : {},
      );

      // Add comment
      final updatedComments = [...reaction.comments, comment];
      final updatedReaction = reaction.copyWith(comments: updatedComments);

      // Ensure .reactions directory exists
      await _storage.createDirectory('$eventRelativePath/.reactions');

      // Write updated reaction
      await _storage.writeString(reactionPath, updatedReaction.exportAsText());

      print('EventService: Added comment from $author to $target');
      return true;
    } catch (e) {
      print('EventService: Error adding comment: $e');
      return false;
    }
  }

  /// Load event items (files, folders, etc.)
  Future<List<EventItem>> loadEventItems(String eventId) async {
    if (_appPath == null) return [];

    try {
      final year = eventId.substring(0, 4);
      final eventRelativePath = '$year/$eventId';
      final eventDirPath = '$_appPath/$year/$eventId';

      if (!await _storage.directoryExists(eventRelativePath)) return [];

      final items = <EventItem>[];
      final entries = await _storage.listDirectory(eventRelativePath);

      for (var entry in entries) {
        // Skip special files and directories
        if (entry.name == 'event.txt' ||
            entry.name.startsWith('.') ||
            entry.name == 'contributors') {
          continue;
        }

        if (entry.isDirectory) {
          // Check if it's a day folder
          if (RegExp(r'^day\d+$').hasMatch(entry.name)) {
            final reaction = await _loadReactionStorage(eventRelativePath, entry.name);
            items.add(EventItem(
              name: entry.name,
              path: '$eventDirPath/${entry.name}',
              type: EventItemType.dayFolder,
              reaction: reaction,
            ));
          } else {
            // Regular subfolder
            final reaction = await _loadReactionStorage(eventRelativePath, entry.name);
            items.add(EventItem(
              name: entry.name,
              path: '$eventDirPath/${entry.name}',
              type: EventItemType.folder,
              reaction: reaction,
            ));
          }
        } else {
          // Regular file
          final type = EventItem.getTypeFromExtension(entry.name);
          final reaction = await _loadReactionStorage(eventRelativePath, entry.name);
          items.add(EventItem(
            name: entry.name,
            path: '$eventDirPath/${entry.name}',
            type: type,
            reaction: reaction,
          ));
        }
      }

      return items;
    } catch (e) {
      print('EventService: Error loading event items: $e');
      return [];
    }
  }

  // ==================== v1.2 Feature Methods (Storage-based) ====================

  /// Load flyers from event directory (storage-based)
  /// Matches ALL image files at the event root, not just flyer-named ones.
  /// Files named flyer.* sort first (primary), then others alphabetically.
  Future<List<String>> _loadFlyersStorage(String eventRelativePath) async {
    try {
      final entries = await _storage.listDirectory(eventRelativePath);
      final flyers = <String>[];
      // Photos AND short video clips both belong to the event's media gallery.
      // The trailer keeps its own slot (matched by the literal filename
      // "trailer.*"); a "photo-N.mp4" or "flyer.mp4" is just another item in
      // the gallery the user added through the same picker.
      final mediaPattern = RegExp(
        r'\.(jpg|jpeg|png|gif|webp|mp4|mov|webm|mkv|avi|wmv|flv)$',
        caseSensitive: false,
      );
      final trailerPattern =
          RegExp(r'^trailer\.', caseSensitive: false);

      for (var entry in entries) {
        if (entry.isDirectory) continue;
        if (trailerPattern.hasMatch(entry.name)) continue;
        if (mediaPattern.hasMatch(entry.name)) {
          flyers.add(entry.name);
        }
      }

      // Sort: flyer.* first (cover), then photo-N.* in numeric order, then rest alphabetically
      flyers.sort((a, b) {
        final aLower = a.toLowerCase();
        final bLower = b.toLowerCase();
        final aIsFlyer = aLower.startsWith('flyer.');
        final bIsFlyer = bLower.startsWith('flyer.');
        if (aIsFlyer && !bIsFlyer) return -1;
        if (!aIsFlyer && bIsFlyer) return 1;

        final photoNum = RegExp(r'^photo-(\d+)\.');
        final aMatch = photoNum.firstMatch(aLower);
        final bMatch = photoNum.firstMatch(bLower);
        final aIsPhoto = aMatch != null;
        final bIsPhoto = bMatch != null;
        if (aIsPhoto && bIsPhoto) {
          return int.parse(aMatch!.group(1)!).compareTo(int.parse(bMatch!.group(1)!));
        }
        if (aIsPhoto && !bIsPhoto) return aIsFlyer ? -1 : -1;
        if (!aIsPhoto && bIsPhoto) return bIsFlyer ? 1 : 1;

        // Legacy flyer-N names sort before other files
        final aIsLegacyFlyer = aLower.startsWith('flyer');
        final bIsLegacyFlyer = bLower.startsWith('flyer');
        if (aIsLegacyFlyer && !bIsLegacyFlyer) return -1;
        if (!aIsLegacyFlyer && bIsLegacyFlyer) return 1;
        return a.compareTo(b);
      });
      return flyers;
    } catch (e) {
      print('EventService: Error loading flyers: $e');
      return [];
    }
  }

  /// Generate the next image filename for an uploaded image.
  /// [existingFlyers] is the list of current image filenames in the event dir.
  /// [extension] is the file extension without dot (e.g. 'jpg', 'png').
  /// First image becomes 'flyer.ext' (cover), subsequent become 'photo-N.ext'.
  static String nextFlyerName(List<String> existingFlyers, String extension) {
    final ext = extension.isNotEmpty ? extension : 'jpg';
    if (existingFlyers.isEmpty) {
      return 'flyer.$ext';
    }
    int num = existingFlyers.length;
    String candidate = 'photo-$num.$ext';
    while (existingFlyers.contains(candidate)) {
      num++;
      candidate = 'photo-$num.$ext';
    }
    return candidate;
  }

  /// Load trailer filename if it exists (storage-based)
  Future<String?> _loadTrailerStorage(String eventRelativePath) async {
    try {
      final entries = await _storage.listDirectory(eventRelativePath);

      // Look for any file named trailer.* (mp4, mov, avi, etc.)
      final trailerPattern = RegExp(r'^trailer\.(mp4|mov|avi|mkv|webm|flv|wmv)$', caseSensitive: false);

      for (var entry in entries) {
        if (!entry.isDirectory && trailerPattern.hasMatch(entry.name)) {
          return entry.name;
        }
      }

      return null;
    } catch (e) {
      print('EventService: Error loading trailer: $e');
      return null;
    }
  }

  /// Load updates from updates directory (storage-based)
  Future<List<EventUpdate>> _loadUpdatesStorage(String eventRelativePath) async {
    try {
      final updatesRelativePath = '$eventRelativePath/updates';
      if (!await _storage.directoryExists(updatesRelativePath)) return [];

      final updates = <EventUpdate>[];
      final entries = await _storage.listDirectory(updatesRelativePath);

      for (var entry in entries) {
        if (!entry.isDirectory && entry.name.endsWith('.md')) {
          try {
            final content = await _storage.readString('$updatesRelativePath/${entry.name}');
            if (content == null) continue;

            final updateId = entry.name.substring(0, entry.name.length - 3); // Remove .md
            final update = EventUpdate.fromText(content, updateId);

            // Load update reactions
            final updateReaction = await _loadReactionStorage(updatesRelativePath, entry.name);
            if (updateReaction != null) {
              updates.add(update.copyWith(
                likes: updateReaction.likes,
                comments: updateReaction.comments,
              ));
            } else {
              updates.add(update);
            }
          } catch (e) {
            print('EventService: Error loading update ${entry.name}: $e');
          }
        }
      }

      // Sort by posted date (most recent first)
      updates.sort((a, b) => b.dateTime.compareTo(a.dateTime));
      return updates;
    } catch (e) {
      print('EventService: Error loading updates: $e');
      return [];
    }
  }

  /// Load registration from registration.txt (storage-based)
  Future<EventRegistration?> _loadRegistrationStorage(String eventRelativePath) async {
    try {
      final content = await _storage.readString('$eventRelativePath/registration.txt');
      if (content == null) return null;

      return EventRegistration.fromText(content);
    } catch (e) {
      print('EventService: Error loading registration: $e');
      return null;
    }
  }

  /// Load links from links.txt (storage-based)
  Future<List<EventLink>> _loadLinksStorage(String eventRelativePath) async {
    try {
      final content = await _storage.readString('$eventRelativePath/links.txt');
      if (content == null) return [];

      return EventLinksParser.fromText(content);
    } catch (e) {
      print('EventService: Error loading links: $e');
      return [];
    }
  }

  /// Create new update for an event
  Future<EventUpdate?> createUpdate({
    required String eventId,
    required String title,
    required String author,
    required String content,
    String? npub,
  }) async {
    if (_appPath == null) return null;

    try {
      final year = eventId.substring(0, 4);
      final eventRelativePath = '$year/$eventId';

      if (!await _storage.directoryExists(eventRelativePath)) return null;

      // Create updates directory if it doesn't exist
      final updatesRelativePath = '$eventRelativePath/updates';
      await _storage.createDirectory(updatesRelativePath);

      // Create .reactions directory inside updates
      await _storage.createDirectory('$updatesRelativePath/.reactions');

      // Generate update filename (timestamp-based)
      final now = DateTime.now();
      final timestamp = _formatTimestamp(now);
      final sanitizedTitle = title
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
          .replaceAll(RegExp(r'^-+|-+$'), '');
      final filename = '${timestamp.replaceAll(RegExp(r'[:\s]'), '-')}_$sanitizedTitle.md';

      // Create update object
      final update = EventUpdate(
        id: filename.substring(0, filename.length - 3),
        title: title,
        author: author,
        posted: timestamp,
        content: content,
        metadata: npub != null ? {'npub': npub} : {},
      );

      // Write update file via storage abstraction
      await _storage.writeString('$updatesRelativePath/$filename', update.exportAsText());

      print('EventService: Created update: $filename');
      return update;
    } catch (e) {
      print('EventService: Error creating update: $e');
      return null;
    }
  }

  /// Register user for event (going or interested)
  Future<bool> register({
    required String eventId,
    required String callsign,
    required String npub,
    required RegistrationType type,
  }) async {
    if (_appPath == null) return false;

    try {
      final year = eventId.substring(0, 4);
      final eventRelativePath = '$year/$eventId';

      if (!await _storage.directoryExists(eventRelativePath)) return false;

      final registrationPath = '$eventRelativePath/registration.txt';

      // Load or create registration
      EventRegistration registration;
      final content = await _storage.readString(registrationPath);
      if (content != null) {
        registration = EventRegistration.fromText(content);
      } else {
        registration = EventRegistration();
      }

      final entry = RegistrationEntry(callsign: callsign, npub: npub);

      // Remove from both lists first (in case changing type)
      var going = registration.going.where((e) => e.callsign != callsign).toList();
      var interested = registration.interested.where((e) => e.callsign != callsign).toList();

      // Add to appropriate list
      if (type == RegistrationType.going) {
        going.add(entry);
      } else {
        interested.add(entry);
      }

      final updatedRegistration = EventRegistration(
        going: going,
        interested: interested,
      );

      // Write updated registration via storage abstraction
      await _storage.writeString(registrationPath, updatedRegistration.exportAsText());

      print('EventService: Registered $callsign as ${type.name}');
      return true;
    } catch (e) {
      print('EventService: Error registering: $e');
      return false;
    }
  }

  /// Unregister user from event
  Future<bool> unregister({
    required String eventId,
    required String callsign,
  }) async {
    if (_appPath == null) return false;

    try {
      final year = eventId.substring(0, 4);
      final eventRelativePath = '$year/$eventId';

      if (!await _storage.directoryExists(eventRelativePath)) return false;

      final registrationPath = '$eventRelativePath/registration.txt';
      final content = await _storage.readString(registrationPath);
      if (content == null) return false;

      final registration = EventRegistration.fromText(content);

      // Remove from both lists
      final going = registration.going.where((e) => e.callsign != callsign).toList();
      final interested = registration.interested.where((e) => e.callsign != callsign).toList();

      // If no registrations left, delete file
      if (going.isEmpty && interested.isEmpty) {
        await _storage.delete(registrationPath);
      } else {
        final updatedRegistration = EventRegistration(
          going: going,
          interested: interested,
        );
        await _storage.writeString(registrationPath, updatedRegistration.exportAsText());
      }

      print('EventService: Unregistered $callsign');
      return true;
    } catch (e) {
      print('EventService: Error unregistering: $e');
      return false;
    }
  }

  /// Add link to event (admins only)
  Future<bool> addLink({
    required String eventId,
    required String url,
    required String description,
    String? password,
    String? note,
  }) async {
    if (_appPath == null) return false;

    try {
      final year = eventId.substring(0, 4);
      final eventRelativePath = '$year/$eventId';

      if (!await _storage.directoryExists(eventRelativePath)) return false;

      final linksPath = '$eventRelativePath/links.txt';

      // Load existing links or create empty list
      List<EventLink> links;
      final content = await _storage.readString(linksPath);
      if (content != null) {
        links = EventLinksParser.fromText(content);
      } else {
        links = [];
      }

      // Add new link
      final newLink = EventLink(
        url: url,
        description: description,
        password: password,
        note: note,
      );
      links.add(newLink);

      // Write updated links via storage abstraction
      await _storage.writeString(linksPath, EventLinksParser.toText(links));

      print('EventService: Added link: $url');
      return true;
    } catch (e) {
      print('EventService: Error adding link: $e');
      return false;
    }
  }

  /// Remove link from event (admins only)
  Future<bool> removeLink({
    required String eventId,
    required String url,
  }) async {
    if (_appPath == null) return false;

    try {
      final year = eventId.substring(0, 4);
      final eventRelativePath = '$year/$eventId';

      if (!await _storage.directoryExists(eventRelativePath)) return false;

      final linksPath = '$eventRelativePath/links.txt';
      final content = await _storage.readString(linksPath);
      if (content == null) return false;

      final links = EventLinksParser.fromText(content);

      // Remove link with matching URL
      final updatedLinks = links.where((link) => link.url != url).toList();

      // If no links left, delete file
      if (updatedLinks.isEmpty) {
        await _storage.delete(linksPath);
      } else {
        await _storage.writeString(linksPath, EventLinksParser.toText(updatedLinks));
      }

      print('EventService: Removed link: $url');
      return true;
    } catch (e) {
      print('EventService: Error removing link: $e');
      return false;
    }
  }

  /// Update event
  /// Returns the new event ID if the folder was renamed, otherwise returns the original ID
  /// Returns null if the update failed
  ///
  /// NOTE: This method still uses some direct filesystem operations for:
  /// - Directory renaming (ProfileStorage doesn't support rename/move)
  /// These are marked with TODO comments for future migration when ProfileStorage
  /// gains rename support.
  Future<String?> updateEvent({
    required String eventId,
    required String title,
    required String location,
    String? locationName,
    required String content,
    String? agenda,
    String? visibility,
    List<String>? admins,
    List<String>? moderators,
    List<String>? groupAccess,
    String? unlistedKey,
    List<String>? accessCallsigns,
    String? accessRequestPrompt,
    DateTime? eventDateTime,
    String? startDate,
    String? endDate,
    String? trailerFileName,
    List<EventLink>? links,
    bool? registrationEnabled,
    Map<String, String>? metadata,
    List<String>? contacts,
    String? customSlug,
  }) async {
    if (_appPath == null) return null;

    try {
      final year = eventId.substring(0, 4);
      final eventRelativePath = '$year/$eventId';

      if (!await _storage.directoryExists(eventRelativePath)) return null;

      // Load existing event
      final existingContent = await _storage.readString('$eventRelativePath/event.txt');
      if (existingContent == null) return null;

      final existingEvent = Event.fromText(existingContent, eventId);

      // Prepare date update
      String? newTimestamp;
      DateTime? folderDate;

      if (eventDateTime != null && !existingEvent.isMultiDay) {
        // Update timestamp for single-day event
        newTimestamp = _formatTimestamp(eventDateTime);
        folderDate = eventDateTime;
        print('EventService: Single-day event date change: ${existingEvent.dateTime} -> $eventDateTime');
      } else if (startDate != null && existingEvent.isMultiDay) {
        // For multi-day events, use start date for folder
        folderDate = DateTime.parse(startDate);
        print('EventService: Multi-day event date change: ${existingEvent.startDate} -> $startDate');
      }

      // Create updated event
      final mergedMetadata = Map<String, String>.from(existingEvent.metadata);
      if (metadata != null) {
        for (final entry in metadata.entries) {
          if (entry.value.isEmpty) {
            mergedMetadata.remove(entry.key);
          } else {
            mergedMetadata[entry.key] = entry.value;
          }
        }
      }

      // Resolve slug: explicit value, empty string to clear, null to keep existing
      final resolvedSlug = customSlug != null
          ? (customSlug.trim().isEmpty ? null : customSlug.trim())
          : existingEvent.slug;

      final updatedEvent = existingEvent.copyWith(
        title: title,
        location: location,
        locationName: locationName,
        content: content,
        agenda: agenda,
        visibility: visibility,
        admins: admins,
        moderators: moderators,
        groupAccess: groupAccess,
        unlistedKey: unlistedKey,
        accessCallsigns: accessCallsigns,
        accessRequestPrompt: accessRequestPrompt,
        timestamp: newTimestamp,
        startDate: startDate,
        endDate: endDate,
        contacts: contacts,
        slug: resolvedSlug,
        metadata: mergedMetadata,
      );

      // Track working path (might change if renamed)
      String workingRelativePath = eventRelativePath;
      String finalEventId = eventId;

      // Check if folder needs to be renamed (date or title changed)
      if (folderDate != null || title != existingEvent.title) {
        final dateToUse = folderDate ?? existingEvent.dateTime;
        final newFolderName = sanitizeFolderName(title, dateToUse);
        final newYear = dateToUse.year.toString();

        print('EventService: Checking rename: oldId=$eventId, newId=$newFolderName, oldYear=$year, newYear=$newYear');

        // Only rename if the ID actually changed
        if (newFolderName != eventId || newYear != year) {
          finalEventId = newFolderName;
          final newRelativePath = '$newYear/$newFolderName';

          // TODO: ProfileStorage doesn't support rename/move - using direct filesystem
          // This needs to be addressed when ProfileStorage gains rename support
          final eventDir = Directory('$_appPath/$year/$eventId');
          final newYearDir = Directory('$_appPath/$newYear');
          if (!await newYearDir.exists()) {
            await newYearDir.create(recursive: true);
          }
          final newEventDir = Directory('${newYearDir.path}/$newFolderName');
          await eventDir.rename(newEventDir.path);

          workingRelativePath = newRelativePath;
          print('EventService: Renamed event folder from $eventId to $newFolderName');
        }
      }

      // Write updated event file via storage abstraction
      await _storage.writeString('$workingRelativePath/event.txt', updatedEvent.exportAsText());

      // Record event associations for any new contacts
      if (contacts != null && contacts.isNotEmpty) {
        // Only record metrics for contacts that weren't already in the event
        final newContacts = contacts
            .where((c) => !existingEvent.contacts.contains(c))
            .toList();
        if (newContacts.isNotEmpty) {
          await ContactService().recordEventAssociations(newContacts);
        }
      }

      // Handle trailer
      // Empty string means "remove trailer", null means "don't change", non-empty means "use this file"
      if (trailerFileName == '') {
        // User explicitly removed trailer - delete any existing trailer file
        final existingTrailer = await _loadTrailerStorage(workingRelativePath);
        if (existingTrailer != null) {
          await _storage.delete('$workingRelativePath/$existingTrailer');
          print('EventService: Deleted trailer file: $existingTrailer');
        }
      }
      // Note: If trailerFileName is a non-empty string, the file should already be copied by settings page
      // If trailerFileName is null, we don't touch the trailer

      // Handle links via storage abstraction
      if (links != null) {
        final linksPath = '$workingRelativePath/links.txt';
        if (links.isEmpty) {
          // Delete links file if empty
          if (await _storage.exists(linksPath)) {
            await _storage.delete(linksPath);
            print('EventService: Deleted empty links.txt');
          }
        } else {
          // Write links
          await _storage.writeString(linksPath, EventLinksParser.toText(links));
          print('EventService: Saved ${links.length} links');
        }
      }

      // Handle registration via storage abstraction
      if (registrationEnabled != null) {
        final registrationPath = '$workingRelativePath/registration.txt';
        if (!registrationEnabled) {
          // Delete registration file if disabled
          if (await _storage.exists(registrationPath)) {
            await _storage.delete(registrationPath);
            print('EventService: Deleted registration.txt (disabled)');
          }
        } else {
          // Create empty registration file if enabled but doesn't exist
          if (!await _storage.exists(registrationPath)) {
            final emptyRegistration = EventRegistration();
            await _storage.writeString(registrationPath, emptyRegistration.exportAsText());
            print('EventService: Created empty registration.txt');
          }
        }
      }

      print('EventService: Updated event: $finalEventId');
      return finalEventId;
    } catch (e) {
      print('EventService: Error updating event: $e');
      return null;
    }
  }

  /// Delete an event by ID
  ///
  /// Returns true if successfully deleted, false otherwise.
  Future<bool> deleteEvent(String eventId) async {
    if (_appPath == null) return false;

    try {
      final year = eventId.substring(0, 4);
      final eventRelativePath = '$year/$eventId';

      if (!await _storage.directoryExists(eventRelativePath)) {
        print('EventService: Event directory not found: $eventRelativePath');
        return false;
      }
      await _storage.deleteDirectory(eventRelativePath, recursive: true);

      print('EventService: Deleted event: $eventId');
      return true;
    } catch (e) {
      print('EventService: Error deleting event: $e');
      return false;
    }
  }

  // ==================== API Helper Methods ====================
  //
  // NOTE: The methods below intentionally use direct filesystem operations because
  // they scan across multiple profiles/collections (outside the current profile's
  // storage). These are cross-profile discovery operations that cannot use the
  // per-profile ProfileStorage abstraction.

  /// Find event by ID across all events apps
  ///
  /// This method searches all collections/apps of type 'events' for an event
  /// with the given ID. Returns null if not found.
  Future<Event?> findEventByIdGlobal(String eventId, String dataDir) async {
    try {
      // Extract year from eventId (format: YYYY-MM-DD_title)
      if (eventId.length < 10 || !eventId.contains('_')) {
        print('EventService: Invalid eventId format: $eventId');
        return null;
      }
      final year = eventId.substring(0, 4);

      // Scan collections directory for event-type apps
      final appsDir = Directory('$dataDir/collections');

      Future<Event?> searchInDir(Directory parentDir) async {
        if (!await parentDir.exists()) return null;
        final entities = await parentDir.list().toList();
        for (var entity in entities) {
          if (entity is Directory) {
            // Check if this is an events-type app by looking for events subdirectory
            final eventsSubdir = Directory('${entity.path}/events');
            if (await eventsSubdir.exists()) {
              // Look for the event in this app
              final eventDir = Directory('${entity.path}/events/$year/$eventId');
              if (await eventDir.exists()) {
                // Found! Load the event using this collection
                final savedPath = _appPath;
                _appPath = entity.path;
                final event = await loadEvent(eventId);
                _appPath = savedPath; // Restore original path
                if (event != null) {
                  return event;
                }
              }
            }
            // Also check direct layout: {entity}/{year}/{eventId}/
            final directDir = Directory('${entity.path}/$year/$eventId');
            if (await directDir.exists()) {
              final savedPath = _appPath;
              final savedStorage = _storageOrNull;
              _appPath = entity.path;
              _storage = FilesystemProfileStorage(entity.path);
              final event = await loadEvent(eventId);
              _appPath = savedPath;
              if (savedStorage != null) _storage = savedStorage;
              if (event != null) {
                return event;
              }
            }
          }
        }
        return null;
      }

      // Search collections directory
      final result = await searchInDir(appsDir);
      if (result != null) return result;

      // Search devices directory
      final devicesDir = Directory('$dataDir/devices');
      if (await devicesDir.exists()) {
        final deviceEntities = await devicesDir.list().toList();
        for (var deviceEntity in deviceEntities) {
          if (deviceEntity is Directory) {
            final deviceResult = await searchInDir(deviceEntity);
            if (deviceResult != null) return deviceResult;
          }
        }
      }

      print('EventService: Event not found: $eventId');
      return null;
    } catch (e) {
      print('EventService: Error finding event: $e');
      return null;
    }
  }

  /// Get all events across all events apps
  ///
  /// Optionally filter by year. Returns events sorted by date (most recent first).
  /// Searches both $dataDir/collections/ and $dataDir/devices/{callsign}/ for events.
  Future<List<Event>> getAllEventsGlobal(String dataDir, {int? year}) async {
    final allEvents = <Event>[];

    Future<void> scanAppDir(Directory appDir) async {
      // Events can be stored in two layouts:
      //   1) {appDir}/{year}/{eventFolder}/ — local client layout (storage base = appDir)
      //   2) {appDir}/events/{year}/{eventFolder}/ — station/upload layout (storage base = appDir/events)
      // Scan both layouts.
      final savedPath = _appPath;
      final savedStorage = _storageOrNull;
      try {
        // Layout 1: year folders directly under appDir
        _appPath = appDir.path;
        _storage = FilesystemProfileStorage(appDir.path);
        final directEvents = await loadEvents(year: year);
        allEvents.addAll(directEvents);

        // Layout 2: year folders under appDir/events/
        final eventsSubdir = Directory('${appDir.path}/events');
        if (await eventsSubdir.exists()) {
          _appPath = eventsSubdir.path;
          _storage = FilesystemProfileStorage(eventsSubdir.path);
          final subEvents = await loadEvents(year: year);
          allEvents.addAll(subEvents);
        }
      } finally {
        _appPath = savedPath;
        if (savedStorage != null) _storage = savedStorage;
      }
    }

    try {
      // Search in collections directory
      final appsDir = Directory('$dataDir/collections');
      if (await appsDir.exists()) {
        final entities = await appsDir.list().toList();
        for (var entity in entities) {
          if (entity is Directory) {
            await scanAppDir(entity);
          }
        }
      }

      // Also search in devices directory for local events
      final devicesDir = Directory('$dataDir/devices');
      if (await devicesDir.exists()) {
        final deviceEntities = await devicesDir.list().toList();
        for (var deviceEntity in deviceEntities) {
          if (deviceEntity is Directory) {
            final deviceApps = await deviceEntity.list().toList();
            for (var appEntity in deviceApps) {
              if (appEntity is Directory) {
                await scanAppDir(appEntity);
              }
            }
          }
        }
      }

      // Sort by date (most recent first)
      allEvents.sort((a, b) => b.dateTime.compareTo(a.dateTime));
      return allEvents;
    } catch (e) {
      print('EventService: Error loading all events: $e');
      return [];
    }
  }

  /// Get all available years across all events apps
  /// Searches both $dataDir/collections/ and $dataDir/devices/{callsign}/ for events.
  Future<List<int>> getAvailableYearsGlobal(String dataDir) async {
    final years = <int>{};

    Future<void> scanAppDir(Directory appDir) async {
      final savedPath = _appPath;
      final savedStorage = _storageOrNull;
      try {
        // Layout 1: year folders directly under appDir
        _appPath = appDir.path;
        _storage = FilesystemProfileStorage(appDir.path);
        years.addAll(await getYears());

        // Layout 2: year folders under appDir/events/
        final eventsSubdir = Directory('${appDir.path}/events');
        if (await eventsSubdir.exists()) {
          _appPath = eventsSubdir.path;
          _storage = FilesystemProfileStorage(eventsSubdir.path);
          years.addAll(await getYears());
        }
      } finally {
        _appPath = savedPath;
        if (savedStorage != null) _storage = savedStorage;
      }
    }

    try {
      // Search in collections directory
      final appsDir = Directory('$dataDir/collections');
      if (await appsDir.exists()) {
        final entities = await appsDir.list().toList();
        for (var entity in entities) {
          if (entity is Directory) {
            await scanAppDir(entity);
          }
        }
      }

      // Also search in devices directory for local events
      final devicesDir = Directory('$dataDir/devices');
      if (await devicesDir.exists()) {
        final deviceEntities = await devicesDir.list().toList();
        for (var deviceEntity in deviceEntities) {
          if (deviceEntity is Directory) {
            final deviceApps = await deviceEntity.list().toList();
            for (var appEntity in deviceApps) {
              if (appEntity is Directory) {
                await scanAppDir(appEntity);
              }
            }
          }
        }
      }

      final sortedYears = years.toList()..sort((a, b) => b.compareTo(a));
      return sortedYears;
    } catch (e) {
      print('EventService: Error getting years: $e');
      return [];
    }
  }

  /// Get path to an event's directory
  ///
  /// Returns the full path if found, null otherwise
  /// Searches both $dataDir/collections/ and $dataDir/devices/{callsign}/ for events.
  Future<String?> getEventPath(String eventId, String dataDir) async {
    try {
      if (eventId.length < 10 || !eventId.contains('_')) {
        return null;
      }
      final year = eventId.substring(0, 4);

      // Check both event storage layouts for a given app directory
      Future<String?> checkAppDir(Directory appDir) async {
        // Layout 1: {appDir}/{year}/{eventId}/ (local client)
        final direct = Directory('${appDir.path}/$year/$eventId');
        if (await direct.exists()) return direct.path;
        // Layout 2: {appDir}/events/{year}/{eventId}/ (station/upload)
        final nested = Directory('${appDir.path}/events/$year/$eventId');
        if (await nested.exists()) return nested.path;
        return null;
      }

      // Search in collections directory
      final appsDir = Directory('$dataDir/collections');
      if (await appsDir.exists()) {
        final entities = await appsDir.list().toList();
        for (var entity in entities) {
          if (entity is Directory) {
            final found = await checkAppDir(entity);
            if (found != null) return found;
          }
        }
      }

      // Also search in devices directory for local events
      final devicesDir = Directory('$dataDir/devices');
      if (await devicesDir.exists()) {
        final deviceEntities = await devicesDir.list().toList();
        for (var deviceEntity in deviceEntities) {
          if (deviceEntity is Directory) {
            final deviceApps = await deviceEntity.list().toList();
            for (var appEntity in deviceApps) {
              if (appEntity is Directory) {
                final found = await checkAppDir(appEntity);
                if (found != null) return found;
              }
            }
          }
        }
      }

      return null;
    } catch (e) {
      print('EventService: Error getting event path: $e');
      return null;
    }
  }
}
