/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'event_comment.dart';
import 'event_update.dart';
import 'event_registration.dart';
import 'event_link.dart';

/// Model representing an event with location, files, and engagement
class Event {
  final String id; // Folder name
  final String author;
  final String timestamp; // Format: YYYY-MM-DD HH:MM_ss
  final String title;
  final String? startDate; // YYYY-MM-DD (for multi-day events)
  final String? endDate; // YYYY-MM-DD (for multi-day events)
  final List<String> admins; // List of npub strings
  final List<String> moderators; // List of npub strings
  final String location; // "online" or "lat,lon"
  final String? locationName;
  final String content;
  final String? agenda; // Event schedule/agenda (optional)
  final String visibility; // "public", "private", or "group"
  final List<String> likes; // List of callsigns
  final List<EventComment> comments;
  final Map<String, String> metadata;

  // New v1.2 features
  final List<String> flyers; // List of flyer filenames
  final String? trailer; // Trailer filename (usually "trailer.mp4")
  final List<EventUpdate> updates; // Event updates
  final EventRegistration? registration; // Going/Interested lists
  final List<EventLink> links; // Relevant links

  Event({
    required this.id,
    required this.author,
    required this.timestamp,
    required this.title,
    this.startDate,
    this.endDate,
    this.admins = const [],
    this.moderators = const [],
    required this.location,
    this.locationName,
    required this.content,
    this.agenda,
    this.visibility = 'public',
    this.likes = const [],
    this.comments = const [],
    this.metadata = const {},
    // New v1.2 features
    this.flyers = const [],
    this.trailer,
    this.updates = const [],
    this.registration,
    this.links = const [],
  });

  /// Parse timestamp to DateTime
  DateTime get dateTime {
    try {
      final normalized = timestamp.replaceAll('_', ':');
      return DateTime.parse(normalized);
    } catch (e) {
      return DateTime.now();
    }
  }

  /// Get display time (HH:MM)
  String get displayTime {
    final dt = dateTime;
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  /// Get display date (YYYY-MM-DD)
  String get displayDate {
    final dt = dateTime;
    final year = dt.year.toString();
    final month = dt.month.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }

  /// Get year from timestamp
  int get year => dateTime.year;

  /// Check if event is multi-day
  bool get isMultiDay => startDate != null && endDate != null && startDate != endDate;

  /// Get number of days for multi-day event
  int get numberOfDays {
    if (!isMultiDay || startDate == null || endDate == null) return 1;
    try {
      final start = DateTime.parse(startDate!);
      final end = DateTime.parse(endDate!);
      return end.difference(start).inDays + 1;
    } catch (e) {
      return 1;
    }
  }

  /// Check if location is online
  bool get isOnline => location.toLowerCase() == 'online';

  /// Check if location has coordinates
  bool get hasCoordinates => !isOnline && location.contains(',');

  /// Get latitude (if coordinates)
  double? get latitude {
    if (!hasCoordinates) return null;
    try {
      final parts = location.split(',');
      return double.parse(parts[0].trim());
    } catch (e) {
      return null;
    }
  }

  /// Get longitude (if coordinates)
  double? get longitude {
    if (!hasCoordinates) return null;
    try {
      final parts = location.split(',');
      return double.parse(parts[1].trim());
    } catch (e) {
      return null;
    }
  }

  /// Check if event is signed with NOSTR
  bool get isSigned => metadata.containsKey('signature');

  /// Get NOSTR public key
  String? get npub => metadata['npub'];

  /// Get signature
  String? get signature => metadata['signature'];

  /// Check if user is author
  bool isAuthor(String callsign) => author == callsign;

  /// Check if user is admin (by npub)
  bool isAdmin(String? userNpub) {
    if (userNpub == null) return false;
    return admins.contains(userNpub);
  }

  /// Check if user is moderator (by npub)
  bool isModerator(String? userNpub) {
    if (userNpub == null) return false;
    return moderators.contains(userNpub);
  }

  /// Check if user can edit event (author or admin)
  bool canEdit(String callsign, String? userNpub) {
    return isAuthor(callsign) || isAdmin(userNpub);
  }

  /// Check if user can delete content (author or admin)
  bool canDelete(String callsign, String? userNpub) {
    return isAuthor(callsign) || isAdmin(userNpub);
  }

  /// Check if user can moderate content (author, admin, or moderator)
  bool canModerate(String callsign, String? userNpub) {
    return isAuthor(callsign) || isAdmin(userNpub) || isModerator(userNpub);
  }

  /// Check if user has liked the event
  bool hasUserLiked(String callsign) {
    return likes.contains(callsign);
  }

  /// Get like count
  int get likeCount => likes.length;

  /// Get comment count
  int get commentCount => comments.length;

  /// Export event as text format for file storage
  String exportAsText() {
    final buffer = StringBuffer();

    // Header
    buffer.writeln('# EVENT: $title');
    buffer.writeln();
    buffer.writeln('CREATED: $timestamp');
    buffer.writeln('AUTHOR: $author');

    // Multi-day fields (optional)
    if (startDate != null) {
      buffer.writeln('START_DATE: $startDate');
    }
    if (endDate != null) {
      buffer.writeln('END_DATE: $endDate');
    }

    // Admins (optional)
    if (admins.isNotEmpty) {
      buffer.writeln('ADMINS: ${admins.join(', ')}');
    }

    // Moderators (optional)
    if (moderators.isNotEmpty) {
      buffer.writeln('MODERATORS: ${moderators.join(', ')}');
    }

    // Location
    buffer.writeln('LOCATION: $location');
    if (locationName != null && locationName!.isNotEmpty) {
      buffer.writeln('LOCATION_NAME: $locationName');
    }

    // Agenda (optional)
    if (agenda != null && agenda!.isNotEmpty) {
      buffer.writeln('AGENDA: $agenda');
    }

    // Visibility (defaults to public if not specified)
    if (visibility != 'public') {
      buffer.writeln('VISIBILITY: $visibility');
    }

    buffer.writeln();

    // Content
    buffer.writeln(content);

    // Metadata (excluding npub and signature)
    final regularMetadata = Map<String, String>.from(metadata);
    final npubVal = regularMetadata.remove('npub');
    final sig = regularMetadata.remove('signature');

    for (var entry in regularMetadata.entries) {
      buffer.writeln('--> ${entry.key}: ${entry.value}');
    }

    // npub before signature
    if (npubVal != null) {
      buffer.writeln('--> npub: $npubVal');
    }

    // Signature must be last if present
    if (sig != null) {
      buffer.writeln('--> signature: $sig');
    }

    return buffer.toString();
  }

  /// Parse event from event.txt file text
  static Event fromText(String text, String eventId) {
    final lines = text.split('\n');
    if (lines.isEmpty) {
      throw Exception('Empty event file');
    }

    if (lines.length < 6) {
      throw Exception('Invalid event header');
    }

    // Line 1: # EVENT: Title
    final titleLine = lines[0];
    if (!titleLine.startsWith('# EVENT: ')) {
      throw Exception('Invalid event title line');
    }
    final title = titleLine.substring(9).trim();

    // Line 2: Blank
    // Line 3: CREATED: timestamp
    final createdLine = lines[2];
    if (!createdLine.startsWith('CREATED: ')) {
      throw Exception('Invalid created line');
    }
    final timestamp = createdLine.substring(9).trim();

    // Line 4: AUTHOR: callsign
    final authorLine = lines[3];
    if (!authorLine.startsWith('AUTHOR: ')) {
      throw Exception('Invalid author line');
    }
    final author = authorLine.substring(8).trim();

    // Parse optional fields
    String? startDate;
    String? endDate;
    List<String> admins = [];
    List<String> moderators = [];
    String? location;
    String? locationName;
    String? agenda;
    String visibility = 'public'; // Default to public

    int currentLine = 4;

    // Parse header fields until we hit blank line
    while (currentLine < lines.length && lines[currentLine].trim().isNotEmpty) {
      final line = lines[currentLine];

      if (line.startsWith('START_DATE: ')) {
        startDate = line.substring(12).trim();
      } else if (line.startsWith('END_DATE: ')) {
        endDate = line.substring(10).trim();
      } else if (line.startsWith('ADMINS: ')) {
        final adminsStr = line.substring(8).trim();
        admins = adminsStr.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      } else if (line.startsWith('MODERATORS: ')) {
        final modsStr = line.substring(12).trim();
        moderators = modsStr.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      } else if (line.startsWith('LOCATION: ')) {
        location = line.substring(10).trim();
      } else if (line.startsWith('LOCATION_NAME: ')) {
        locationName = line.substring(15).trim();
      } else if (line.startsWith('AGENDA: ')) {
        agenda = line.substring(8).trim();
      } else if (line.startsWith('VISIBILITY: ')) {
        visibility = line.substring(12).trim();
      }

      currentLine++;
    }

    if (location == null) {
      throw Exception('Missing LOCATION field');
    }

    // Skip blank line
    if (currentLine < lines.length && lines[currentLine].trim().isEmpty) {
      currentLine++;
    }

    // Parse content and metadata
    final contentLines = <String>[];
    final Map<String, String> metadata = {};

    while (currentLine < lines.length) {
      final line = lines[currentLine];

      if (line.startsWith('-->')) {
        // Metadata for event
        final metaLine = line.substring(3).trim();
        final colonIndex = metaLine.indexOf(':');
        if (colonIndex > 0) {
          final key = metaLine.substring(0, colonIndex).trim();
          final value = metaLine.substring(colonIndex + 1).trim();
          metadata[key] = value;
        }
      } else {
        // Content line
        contentLines.add(line);
      }
      currentLine++;
    }

    // Remove trailing empty lines from content
    while (contentLines.isNotEmpty && contentLines.last.trim().isEmpty) {
      contentLines.removeLast();
    }

    final content = contentLines.join('\n');

    return Event(
      id: eventId,
      author: author,
      timestamp: timestamp,
      title: title,
      startDate: startDate,
      endDate: endDate,
      admins: admins,
      moderators: moderators,
      location: location,
      locationName: locationName,
      content: content,
      agenda: agenda,
      visibility: visibility,
      metadata: metadata,
    );
  }

  /// Get primary flyer filename
  String? get primaryFlyer {
    if (flyers.isEmpty) return null;
    // Primary flyer is first one (sorted alphabetically, so "flyer.jpg" comes first)
    return flyers.first;
  }

  /// Check if event has flyer
  bool get hasFlyer => flyers.isNotEmpty;

  /// Check if event has trailer
  bool get hasTrailer => trailer != null;

  /// Check if event has updates
  bool get hasUpdates => updates.isNotEmpty;

  /// Check if event has registration
  bool get hasRegistration => registration != null;

  /// Check if event has links
  bool get hasLinks => links.isNotEmpty;

  /// Get count of people going
  int get goingCount => registration?.goingCount ?? 0;

  /// Get count of people interested
  int get interestedCount => registration?.interestedCount ?? 0;

  /// Create a copy with updated fields
  Event copyWith({
    String? id,
    String? author,
    String? timestamp,
    String? title,
    String? startDate,
    String? endDate,
    List<String>? admins,
    List<String>? moderators,
    String? location,
    String? locationName,
    String? content,
    String? agenda,
    String? visibility,
    List<String>? likes,
    List<EventComment>? comments,
    Map<String, String>? metadata,
    List<String>? flyers,
    String? trailer,
    List<EventUpdate>? updates,
    EventRegistration? registration,
    List<EventLink>? links,
  }) {
    return Event(
      id: id ?? this.id,
      author: author ?? this.author,
      timestamp: timestamp ?? this.timestamp,
      title: title ?? this.title,
      startDate: startDate ?? this.startDate,
      endDate: endDate ?? this.endDate,
      admins: admins ?? this.admins,
      moderators: moderators ?? this.moderators,
      location: location ?? this.location,
      locationName: locationName ?? this.locationName,
      content: content ?? this.content,
      agenda: agenda ?? this.agenda,
      visibility: visibility ?? this.visibility,
      likes: likes ?? this.likes,
      comments: comments ?? this.comments,
      metadata: metadata ?? this.metadata,
      flyers: flyers ?? this.flyers,
      trailer: trailer ?? this.trailer,
      updates: updates ?? this.updates,
      registration: registration ?? this.registration,
      links: links ?? this.links,
    );
  }

  @override
  String toString() {
    return 'Event(id: $id, title: $title, author: $author, location: $location, likes: ${likes.length}, comments: ${comments.length})';
  }
}
