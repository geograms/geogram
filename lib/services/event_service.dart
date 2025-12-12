/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'dart:convert';
import '../models/event.dart';
import '../models/event_comment.dart';
import '../models/event_reaction.dart';
import '../models/event_item.dart';
import '../models/event_update.dart';
import '../models/event_registration.dart';
import '../models/event_link.dart';

/// Service for managing events, files, and reactions
class EventService {
  static final EventService _instance = EventService._internal();
  factory EventService() => _instance;
  EventService._internal();

  String? _collectionPath;

  /// Initialize event service for a collection
  Future<void> initializeCollection(String collectionPath) async {
    print('EventService: Initializing with collection path: $collectionPath');
    _collectionPath = collectionPath;

    // Ensure events directory exists
    final eventsDir = Directory('$collectionPath/events');
    if (!await eventsDir.exists()) {
      await eventsDir.create(recursive: true);
      print('EventService: Created events directory');
    }
  }

  /// Get available years (folders in events directory)
  Future<List<int>> getYears() async {
    if (_collectionPath == null) return [];

    final eventsDir = Directory('$_collectionPath/events');
    if (!await eventsDir.exists()) return [];

    final years = <int>[];
    final entities = await eventsDir.list().toList();

    for (var entity in entities) {
      if (entity is Directory) {
        final name = entity.path.split('/').last;
        final year = int.tryParse(name);
        if (year != null) {
          years.add(year);
        }
      }
    }

    years.sort((a, b) => b.compareTo(a)); // Most recent first
    return years;
  }

  /// Load events for a specific year or all years
  Future<List<Event>> loadEvents({
    int? year,
    String? currentCallsign,
    String? currentUserNpub,
  }) async {
    if (_collectionPath == null) return [];

    final events = <Event>[];
    final years = year != null ? [year] : await getYears();

    for (var y in years) {
      final yearDir = Directory('$_collectionPath/events/$y');
      if (!await yearDir.exists()) continue;

      final entities = await yearDir.list().toList();


      for (var entity in entities) {
        if (entity is Directory) {
          try {
            final folderName = entity.path.split('/').last;
            // Event folders are like: 2025-07-15_summer-festival
            if (RegExp(r'^\d{4}-\d{2}-\d{2}_').hasMatch(folderName)) {
              final event = await loadEvent(folderName);
              if (event != null) {
                events.add(event);
              }
            }
          } catch (e) {
            print('EventService: Error loading event ${entity.path}: $e');
          }
        }
      }
    }

    // Sort by date (most recent first)
    events.sort((a, b) => b.dateTime.compareTo(a.dateTime));

    return events;
  }

  /// Load full event with reactions and v1.2 features
  Future<Event?> loadEvent(String eventId) async {
    if (_collectionPath == null) return null;

    // Extract year from eventId (format: YYYY-MM-DD_title)
    final year = eventId.substring(0, 4);
    final eventDir = Directory('$_collectionPath/events/$year/$eventId');

    if (!await eventDir.exists()) {
      print('EventService: Event directory not found: ${eventDir.path}');
      return null;
    }

    // Load event.txt
    final eventFile = File('${eventDir.path}/event.txt');
    if (!await eventFile.exists()) {
      print('EventService: event.txt not found in ${eventDir.path}');
      return null;
    }

    try {
      final content = await eventFile.readAsString();
      final event = Event.fromText(content, eventId);

      // Load event-level reactions
      final eventReaction = await _loadReaction(eventDir.path, 'event.txt');

      // Load v1.2 features
      final flyers = await _loadFlyers(eventDir.path);
      final trailer = await _loadTrailer(eventDir.path);
      final updates = await _loadUpdates(eventDir.path);
      final registration = await _loadRegistration(eventDir.path);
      final links = await _loadLinks(eventDir.path);

      return event.copyWith(
        likes: eventReaction?.likes ?? event.likes,
        comments: eventReaction?.comments ?? event.comments,
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

  /// Load reaction file for a specific item
  Future<EventReaction?> _loadReaction(String eventPath, String targetItem) async {
    // Remove .txt extension from targetItem if present for the reaction filename
    final reactionTarget = targetItem.endsWith('.txt')
        ? targetItem
        : '$targetItem.txt';

    final reactionFile = File('$eventPath/.reactions/$reactionTarget');

    if (!await reactionFile.exists()) {
      return null;
    }

    try {
      final content = await reactionFile.readAsString();
      return EventReaction.fromText(content, targetItem);
    } catch (e) {
      print('EventService: Error loading reaction: $e');
      return null;
    }
  }

  /// Sanitize title to create valid folder name
  String sanitizeFolderName(String title, DateTime? date) {
    date ??= DateTime.now();

    // Convert to lowercase, replace spaces with hyphens
    String sanitized = title.toLowerCase().trim();

    // Replace spaces and underscores with hyphens
    sanitized = sanitized.replaceAll(RegExp(r'[\s_]+'), '-');

    // Remove non-alphanumeric characters except hyphens
    sanitized = sanitized.replaceAll(RegExp(r'[^a-z0-9-]'), '');

    // Remove multiple consecutive hyphens
    sanitized = sanitized.replaceAll(RegExp(r'-+'), '-');

    // Remove leading/trailing hyphens
    sanitized = sanitized.replaceAll(RegExp(r'^-+|-+$'), '');

    // Truncate to 50 characters
    if (sanitized.length > 50) {
      sanitized = sanitized.substring(0, 50);
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

    while (await Directory('$_collectionPath/events/$year/$folderName').exists()) {
      folderName = '$baseFolderName-$suffix';
      suffix++;
    }

    return folderName;
  }

  /// Create new event
  Future<Event?> createEvent({
    required String author,
    required String title,
    DateTime? eventDate,
    String? startDate,
    String? endDate,
    required String location,
    String? locationName,
    required String content,
    String? npub,
    Map<String, String>? metadata,
  }) async {
    if (_collectionPath == null) return null;

    try {
      // Use provided event date or current time
      final dateToUse = eventDate ?? DateTime.now();
      final year = dateToUse.year;

      // Sanitize folder name
      final baseFolderName = sanitizeFolderName(title, dateToUse);
      final folderName = await _ensureUniqueFolderName(baseFolderName, year);

      // Ensure year directory exists
      final yearDir = Directory('$_collectionPath/events/$year');
      if (!await yearDir.exists()) {
        await yearDir.create(recursive: true);
      }

      // Create event directory
      final eventDir = Directory('$_collectionPath/events/$year/$folderName');
      await eventDir.create(recursive: true);

      // Create .reactions directory
      final reactionsDir = Directory('${eventDir.path}/.reactions');
      await reactionsDir.create(recursive: true);

      // Create day folders if multi-day event
      if (startDate != null && endDate != null && startDate != endDate) {
        final start = DateTime.parse(startDate);
        final end = DateTime.parse(endDate);
        final days = end.difference(start).inDays + 1;

        for (int i = 1; i <= days; i++) {
          final dayDir = Directory('${eventDir.path}/day$i');
          await dayDir.create();
          final dayReactionsDir = Directory('${dayDir.path}/.reactions');
          await dayReactionsDir.create();
        }
      }

      // Create event object
      final event = Event(
        id: folderName,
        author: author,
        timestamp: _formatTimestamp(dateToUse),
        title: title,
        startDate: startDate,
        endDate: endDate,
        admins: [],
        moderators: [],
        location: location,
        locationName: locationName,
        content: content,
        metadata: {
          ...?metadata,
          if (npub != null) 'npub': npub,
        },
      );

      // Write event.txt
      final eventFile = File('${eventDir.path}/event.txt');
      await eventFile.writeAsString(event.exportAsText(), flush: true);

      print('EventService: Created event: $folderName');
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
    if (_collectionPath == null) return false;

    try {
      final year = eventId.substring(0, 4);
      final eventDir = Directory('$_collectionPath/events/$year/$eventId');

      if (!await eventDir.exists()) return false;

      // Determine reaction file path
      final target = targetItem ?? 'event.txt';
      final reactionFile = File('${eventDir.path}/.reactions/$target');

      // Load or create reaction
      EventReaction reaction;
      if (await reactionFile.exists()) {
        final content = await reactionFile.readAsString();
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
      final reactionsDir = Directory('${eventDir.path}/.reactions');
      if (!await reactionsDir.exists()) {
        await reactionsDir.create(recursive: true);
      }

      // Write updated reaction
      await reactionFile.writeAsString(updatedReaction.exportAsText(), flush: true);

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
    if (_collectionPath == null) return false;

    try {
      final year = eventId.substring(0, 4);
      final eventDir = Directory('$_collectionPath/events/$year/$eventId');

      if (!await eventDir.exists()) return false;

      final target = targetItem ?? 'event.txt';
      final reactionFile = File('${eventDir.path}/.reactions/$target');

      if (!await reactionFile.exists()) return false;

      // Load reaction
      final content = await reactionFile.readAsString();
      final reaction = EventReaction.fromText(content, target);

      // Remove like
      final updatedLikes = reaction.likes.where((c) => c != callsign).toList();
      final updatedReaction = reaction.copyWith(likes: updatedLikes);

      // If no likes and no comments, delete the file
      if (updatedReaction.likes.isEmpty && updatedReaction.comments.isEmpty) {
        await reactionFile.delete();
      } else {
        await reactionFile.writeAsString(updatedReaction.exportAsText(), flush: true);
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
    if (_collectionPath == null) return false;

    try {
      final year = eventId.substring(0, 4);
      final eventDir = Directory('$_collectionPath/events/$year/$eventId');

      if (!await eventDir.exists()) return false;

      final target = targetItem ?? 'event.txt';
      final reactionFile = File('${eventDir.path}/.reactions/$target');

      // Load or create reaction
      EventReaction reaction;
      if (await reactionFile.exists()) {
        final fileContent = await reactionFile.readAsString();
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
      final reactionsDir = Directory('${eventDir.path}/.reactions');
      if (!await reactionsDir.exists()) {
        await reactionsDir.create(recursive: true);
      }

      // Write updated reaction
      await reactionFile.writeAsString(updatedReaction.exportAsText(), flush: true);

      print('EventService: Added comment from $author to $target');
      return true;
    } catch (e) {
      print('EventService: Error adding comment: $e');
      return false;
    }
  }

  /// Load event items (files, folders, etc.)
  Future<List<EventItem>> loadEventItems(String eventId) async {
    if (_collectionPath == null) return [];

    try {
      final year = eventId.substring(0, 4);
      final eventDir = Directory('$_collectionPath/events/$year/$eventId');

      if (!await eventDir.exists()) return [];

      final items = <EventItem>[];

      final entities = await eventDir.list().toList();


      for (var entity in entities) {
        final name = entity.path.split('/').last;

        // Skip special files and directories
        if (name == 'event.txt' ||
            name.startsWith('.') ||
            name == 'contributors') {
          continue;
        }

        if (entity is Directory) {
          // Check if it's a day folder
          if (RegExp(r'^day\d+$').hasMatch(name)) {
            final reaction = await _loadReaction(eventDir.path, name);
            items.add(EventItem(
              name: name,
              path: entity.path,
              type: EventItemType.dayFolder,
              reaction: reaction,
            ));
          } else {
            // Regular subfolder
            final reaction = await _loadReaction(eventDir.path, name);
            items.add(EventItem(
              name: name,
              path: entity.path,
              type: EventItemType.folder,
              reaction: reaction,
            ));
          }
        } else if (entity is File) {
          // Regular file
          final type = EventItem.getTypeFromExtension(name);
          final reaction = await _loadReaction(eventDir.path, name);
          items.add(EventItem(
            name: name,
            path: entity.path,
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

  // ==================== v1.2 Feature Methods ====================

  /// Load flyers from event directory
  Future<List<String>> _loadFlyers(String eventPath) async {
    try {
      final eventDir = Directory(eventPath);
      if (!await eventDir.exists()) return [];

      final flyers = <String>[];
      final flyerPattern = RegExp(r'^flyer.*\.(jpg|jpeg|png|gif|webp)$', caseSensitive: false);

      final entities = await eventDir.list().toList();


      for (var entity in entities) {
        if (entity is File) {
          final name = entity.path.split('/').last;
          if (flyerPattern.hasMatch(name)) {
            flyers.add(name);
          }
        }
      }

      // Sort alphabetically (flyer.jpg comes before flyer-alt.png)
      flyers.sort();
      return flyers;
    } catch (e) {
      print('EventService: Error loading flyers: $e');
      return [];
    }
  }

  /// Load trailer filename if it exists
  Future<String?> _loadTrailer(String eventPath) async {
    try {
      final eventDir = Directory(eventPath);
      if (!await eventDir.exists()) return null;

      // Look for any file named trailer.* (mp4, mov, avi, etc.)
      final trailerPattern = RegExp(r'^trailer\.(mp4|mov|avi|mkv|webm|flv|wmv)$', caseSensitive: false);

      final entities = await eventDir.list().toList();


      for (var entity in entities) {
        if (entity is File) {
          final name = entity.path.split('/').last;
          if (trailerPattern.hasMatch(name)) {
            return name;
          }
        }
      }

      return null;
    } catch (e) {
      print('EventService: Error loading trailer: $e');
      return null;
    }
  }

  /// Load updates from updates directory
  Future<List<EventUpdate>> _loadUpdates(String eventPath) async {
    try {
      final updatesDir = Directory('$eventPath/updates');
      if (!await updatesDir.exists()) return [];

      final updates = <EventUpdate>[];

      final entities = await updatesDir.list().toList();


      for (var entity in entities) {
        if (entity is File && entity.path.endsWith('.md')) {
          try {
            final content = await entity.readAsString();
            final filename = entity.path.split('/').last;
            final updateId = filename.substring(0, filename.length - 3); // Remove .md

            final update = EventUpdate.fromText(content, updateId);

            // Load update reactions
            final updateReaction = await _loadReaction(updatesDir.path, filename);
            if (updateReaction != null) {
              updates.add(update.copyWith(
                likes: updateReaction.likes,
                comments: updateReaction.comments,
              ));
            } else {
              updates.add(update);
            }
          } catch (e) {
            print('EventService: Error loading update ${entity.path}: $e');
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

  /// Load registration from registration.txt
  Future<EventRegistration?> _loadRegistration(String eventPath) async {
    try {
      final registrationFile = File('$eventPath/registration.txt');
      if (!await registrationFile.exists()) return null;

      final content = await registrationFile.readAsString();
      return EventRegistration.fromText(content);
    } catch (e) {
      print('EventService: Error loading registration: $e');
      return null;
    }
  }

  /// Load links from links.txt
  Future<List<EventLink>> _loadLinks(String eventPath) async {
    try {
      final linksFile = File('$eventPath/links.txt');
      if (!await linksFile.exists()) return [];

      final content = await linksFile.readAsString();
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
    if (_collectionPath == null) return null;

    try {
      final year = eventId.substring(0, 4);
      final eventDir = Directory('$_collectionPath/events/$year/$eventId');

      if (!await eventDir.exists()) return null;

      // Create updates directory if it doesn't exist
      final updatesDir = Directory('${eventDir.path}/updates');
      if (!await updatesDir.exists()) {
        await updatesDir.create(recursive: true);
      }

      // Create .reactions directory inside updates
      final reactionsDir = Directory('${updatesDir.path}/.reactions');
      if (!await reactionsDir.exists()) {
        await reactionsDir.create(recursive: true);
      }

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

      // Write update file
      final updateFile = File('${updatesDir.path}/$filename');
      await updateFile.writeAsString(update.exportAsText(), flush: true);

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
    if (_collectionPath == null) return false;

    try {
      final year = eventId.substring(0, 4);
      final eventDir = Directory('$_collectionPath/events/$year/$eventId');

      if (!await eventDir.exists()) return false;

      final registrationFile = File('${eventDir.path}/registration.txt');

      // Load or create registration
      EventRegistration registration;
      if (await registrationFile.exists()) {
        final content = await registrationFile.readAsString();
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

      // Write updated registration
      await registrationFile.writeAsString(
        updatedRegistration.exportAsText(),
        flush: true,
      );

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
    if (_collectionPath == null) return false;

    try {
      final year = eventId.substring(0, 4);
      final eventDir = Directory('$_collectionPath/events/$year/$eventId');

      if (!await eventDir.exists()) return false;

      final registrationFile = File('${eventDir.path}/registration.txt');
      if (!await registrationFile.exists()) return false;

      final content = await registrationFile.readAsString();
      final registration = EventRegistration.fromText(content);

      // Remove from both lists
      final going = registration.going.where((e) => e.callsign != callsign).toList();
      final interested = registration.interested.where((e) => e.callsign != callsign).toList();

      // If no registrations left, delete file
      if (going.isEmpty && interested.isEmpty) {
        await registrationFile.delete();
      } else {
        final updatedRegistration = EventRegistration(
          going: going,
          interested: interested,
        );
        await registrationFile.writeAsString(
          updatedRegistration.exportAsText(),
          flush: true,
        );
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
    if (_collectionPath == null) return false;

    try {
      final year = eventId.substring(0, 4);
      final eventDir = Directory('$_collectionPath/events/$year/$eventId');

      if (!await eventDir.exists()) return false;

      final linksFile = File('${eventDir.path}/links.txt');

      // Load existing links or create empty list
      List<EventLink> links;
      if (await linksFile.exists()) {
        final content = await linksFile.readAsString();
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

      // Write updated links
      await linksFile.writeAsString(
        EventLinksParser.toText(links),
        flush: true,
      );

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
    if (_collectionPath == null) return false;

    try {
      final year = eventId.substring(0, 4);
      final eventDir = Directory('$_collectionPath/events/$year/$eventId');

      if (!await eventDir.exists()) return false;

      final linksFile = File('${eventDir.path}/links.txt');
      if (!await linksFile.exists()) return false;

      final content = await linksFile.readAsString();
      final links = EventLinksParser.fromText(content);

      // Remove link with matching URL
      final updatedLinks = links.where((link) => link.url != url).toList();

      // If no links left, delete file
      if (updatedLinks.isEmpty) {
        await linksFile.delete();
      } else {
        await linksFile.writeAsString(
          EventLinksParser.toText(updatedLinks),
          flush: true,
        );
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
    DateTime? eventDateTime,
    String? startDate,
    String? endDate,
    String? trailerFileName,
    List<EventLink>? links,
    bool? registrationEnabled,
  }) async {
    if (_collectionPath == null) return null;

    try {
      final year = eventId.substring(0, 4);
      final eventDir = Directory('$_collectionPath/events/$year/$eventId');

      if (!await eventDir.exists()) return null;

      // Load existing event
      final eventFile = File('${eventDir.path}/event.txt');
      if (!await eventFile.exists()) return null;

      final existingContent = await eventFile.readAsString();
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
      final updatedEvent = existingEvent.copyWith(
        title: title,
        location: location,
        locationName: locationName,
        content: content,
        agenda: agenda,
        visibility: visibility,
        admins: admins,
        moderators: moderators,
        timestamp: newTimestamp,
        startDate: startDate,
        endDate: endDate,
      );

      // Determine the working directory (might be renamed)
      Directory workingDir = eventDir;
      String workingYear = year;
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
          workingYear = newYear;

          // Create new year directory if needed
          final newYearDir = Directory('$_collectionPath/events/$newYear');
          if (!await newYearDir.exists()) {
            await newYearDir.create(recursive: true);
          }

          // New event directory path
          final newEventDir = Directory('${newYearDir.path}/$newFolderName');

          // Rename/move the directory
          await eventDir.rename(newEventDir.path);
          workingDir = newEventDir;

          print('EventService: Renamed event folder from $eventId to $newFolderName');
        }
      }

      // Write updated event file
      final finalEventFile = File('${workingDir.path}/event.txt');
      await finalEventFile.writeAsString(updatedEvent.exportAsText(), flush: true);

      // Handle trailer
      // Empty string means "remove trailer", null means "don't change", non-empty means "use this file"
      if (trailerFileName == '') {
        // User explicitly removed trailer - delete any existing trailer file
        final existingTrailer = await _loadTrailer(workingDir.path);
        if (existingTrailer != null) {
          final trailerFile = File('${workingDir.path}/$existingTrailer');
          if (await trailerFile.exists()) {
            await trailerFile.delete();
            print('EventService: Deleted trailer file: $existingTrailer');
          }
        }
      }
      // Note: If trailerFileName is a non-empty string, the file should already be copied by settings page
      // If trailerFileName is null, we don't touch the trailer

      // Handle links
      if (links != null) {
        final linksFile = File('${workingDir.path}/links.txt');
        if (links.isEmpty) {
          // Delete links file if empty
          if (await linksFile.exists()) {
            await linksFile.delete();
            print('EventService: Deleted empty links.txt');
          }
        } else {
          // Write links
          await linksFile.writeAsString(
            EventLinksParser.toText(links),
            flush: true,
          );
          print('EventService: Saved ${links.length} links');
        }
      }

      // Handle registration
      if (registrationEnabled != null) {
        final registrationFile = File('${workingDir.path}/registration.txt');
        if (!registrationEnabled) {
          // Delete registration file if disabled
          if (await registrationFile.exists()) {
            await registrationFile.delete();
            print('EventService: Deleted registration.txt (disabled)');
          }
        } else {
          // Create empty registration file if enabled but doesn't exist
          if (!await registrationFile.exists()) {
            final emptyRegistration = EventRegistration();
            await registrationFile.writeAsString(
              emptyRegistration.exportAsText(),
              flush: true,
            );
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

  // ==================== API Helper Methods ====================

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
      final collectionsDir = Directory('$dataDir/collections');
      if (!await collectionsDir.exists()) {
        print('EventService: Collections directory not found');
        return null;
      }

      final entities = await collectionsDir.list().toList();
      for (var entity in entities) {
        if (entity is Directory) {
          // Check if this is an events-type app by looking for events subdirectory
          final eventsSubdir = Directory('${entity.path}/events');
          if (await eventsSubdir.exists()) {
            // Look for the event in this app
            final eventDir = Directory('${entity.path}/events/$year/$eventId');
            if (await eventDir.exists()) {
              // Found! Load the event using this collection
              final savedPath = _collectionPath;
              _collectionPath = entity.path;
              final event = await loadEvent(eventId);
              _collectionPath = savedPath; // Restore original path
              if (event != null) {
                return event;
              }
            }
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

    try {
      // Search in collections directory
      final collectionsDir = Directory('$dataDir/collections');
      if (await collectionsDir.exists()) {
        final entities = await collectionsDir.list().toList();
        for (var entity in entities) {
          if (entity is Directory) {
            // Check if this is an events-type app
            final eventsSubdir = Directory('${entity.path}/events');
            if (await eventsSubdir.exists()) {
              // Load events from this app
              final savedPath = _collectionPath;
              _collectionPath = entity.path;
              final events = await loadEvents(year: year);
              _collectionPath = savedPath; // Restore original path
              allEvents.addAll(events);
            }
          }
        }
      }

      // Also search in devices directory for local events
      final devicesDir = Directory('$dataDir/devices');
      if (await devicesDir.exists()) {
        final deviceEntities = await devicesDir.list().toList();
        for (var deviceEntity in deviceEntities) {
          if (deviceEntity is Directory) {
            // Look for events apps in each device folder
            final deviceApps = await deviceEntity.list().toList();
            for (var appEntity in deviceApps) {
              if (appEntity is Directory) {
                final eventsSubdir = Directory('${appEntity.path}/events');
                if (await eventsSubdir.exists()) {
                  // Load events from this app
                  final savedPath = _collectionPath;
                  _collectionPath = appEntity.path;
                  final events = await loadEvents(year: year);
                  _collectionPath = savedPath; // Restore original path
                  allEvents.addAll(events);
                }
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

    try {
      // Search in collections directory
      final collectionsDir = Directory('$dataDir/collections');
      if (await collectionsDir.exists()) {
        final entities = await collectionsDir.list().toList();
        for (var entity in entities) {
          if (entity is Directory) {
            final eventsSubdir = Directory('${entity.path}/events');
            if (await eventsSubdir.exists()) {
              // Get years from this app
              final savedPath = _collectionPath;
              _collectionPath = entity.path;
              final appYears = await getYears();
              _collectionPath = savedPath;
              years.addAll(appYears);
            }
          }
        }
      }

      // Also search in devices directory for local events
      final devicesDir = Directory('$dataDir/devices');
      if (await devicesDir.exists()) {
        final deviceEntities = await devicesDir.list().toList();
        for (var deviceEntity in deviceEntities) {
          if (deviceEntity is Directory) {
            // Look for events apps in each device folder
            final deviceApps = await deviceEntity.list().toList();
            for (var appEntity in deviceApps) {
              if (appEntity is Directory) {
                final eventsSubdir = Directory('${appEntity.path}/events');
                if (await eventsSubdir.exists()) {
                  final savedPath = _collectionPath;
                  _collectionPath = appEntity.path;
                  final appYears = await getYears();
                  _collectionPath = savedPath;
                  years.addAll(appYears);
                }
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

      // Search in collections directory
      final collectionsDir = Directory('$dataDir/collections');
      if (await collectionsDir.exists()) {
        final entities = await collectionsDir.list().toList();
        for (var entity in entities) {
          if (entity is Directory) {
            final eventDir = Directory('${entity.path}/events/$year/$eventId');
            if (await eventDir.exists()) {
              return eventDir.path;
            }
          }
        }
      }

      // Also search in devices directory for local events
      final devicesDir = Directory('$dataDir/devices');
      if (await devicesDir.exists()) {
        final deviceEntities = await devicesDir.list().toList();
        for (var deviceEntity in deviceEntities) {
          if (deviceEntity is Directory) {
            // Look for events apps in each device folder
            final deviceApps = await deviceEntity.list().toList();
            for (var appEntity in deviceApps) {
              if (appEntity is Directory) {
                final eventDir = Directory('${appEntity.path}/events/$year/$eventId');
                if (await eventDir.exists()) {
                  return eventDir.path;
                }
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
