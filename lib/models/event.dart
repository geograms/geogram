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
  final List<String> groupAccess; // Group names with access (when visibility == group)
  final String location; // "online" or "lat,lon"
  final String? locationName;
  final String content;
  final String? agenda; // Event schedule/agenda (optional)
  /// Visibility / access state. Recognised values:
  ///   public          — anyone can list and open
  ///   unlisted        — hidden from listings; openable with `?key=<unlistedKey>`
  ///   request_access  — listed publicly, but content gated like `private`
  ///                     unless the viewer is on `accessCallsigns` /
  ///                     `groupAccess`; web page shows a "Request access"
  ///                     button for blocked viewers.
  ///   group           — listed only to viewers in `groupAccess`
  ///   private         — listed only to author / admins / `accessCallsigns` /
  ///                     `groupAccess`
  final String visibility;
  /// 32-char hex token required as `?key=` to view an `unlisted` event.
  /// Generated automatically the first time visibility flips to `unlisted`.
  final String? unlistedKey;
  /// Explicit per-callsign grants. Augments `groupAccess` for the
  /// `private`, `group` and `request_access` states.
  final List<String> accessCallsigns;
  /// Optional prompt the author writes for `request_access` events,
  /// shown to blocked viewers above the request form so they know what
  /// to put in the note. Empty / null → no prompt rendered.
  final String? accessRequestPrompt;
  /// Whether visitors can post NOSTR-signed comments on the public event
  /// page. Defaults to true — the event.txt only persists the field when
  /// the author has *disabled* it, so older event files keep working.
  final bool commentsEnabled;
  final List<String> likes; // List of npubs (feedback)
  final List<EventComment> comments;
  final Map<String, String> metadata;

  // New v1.2 features
  /// All photo filenames inside the event folder. A photo only becomes
  /// the "flyer" when the author explicitly designates it via [flyer].
  final List<String> photos;
  /// Optional cover image — the one photo the author picked to
  /// represent the event. Null means no cover was chosen; the UI
  /// should fall back to [photos.first] (or show nothing) rather
  /// than treating every photo as a flyer.
  final String? flyer;
  final String? trailer; // Trailer filename (usually "trailer.mp4")
  final List<EventUpdate> updates; // Event updates
  final EventRegistration? registration; // Going/Interested lists
  final List<EventLink> links; // Relevant links
  final List<String> contacts; // List of contact callsigns associated with event
  final String? slug; // URL-friendly short name (optional)

  Event({
    required this.id,
    required this.author,
    required this.timestamp,
    required this.title,
    this.startDate,
    this.endDate,
    this.admins = const [],
    this.moderators = const [],
    this.groupAccess = const [],
    required this.location,
    this.locationName,
    required this.content,
    this.agenda,
    this.visibility = 'public',
    this.unlistedKey,
    this.accessCallsigns = const [],
    this.accessRequestPrompt,
    this.commentsEnabled = true,
    this.likes = const [],
    this.comments = const [],
    this.metadata = const {},
    // New v1.2 features
    this.photos = const [],
    this.flyer,
    this.trailer,
    this.updates = const [],
    this.registration,
    this.links = const [],
    this.contacts = const [],
    this.slug,
  });

  /// Create Event from API JSON (from toApiJson output)
  factory Event.fromApiJson(Map<String, dynamic> json) {
    final metadata = <String, String>{};
    final npub = json['npub'] as String?;
    if (npub != null && npub.isNotEmpty) {
      metadata['npub'] = npub;
    }
    final signature = json['signature'] as String?;
    if (signature != null && signature.isNotEmpty) {
      metadata['signature'] = signature;
    }
    final placePath = json['place_path'] as String? ?? json['placePath'] as String?;
    if (placePath != null && placePath.isNotEmpty) {
      metadata['place_path'] = placePath;
    }

    // Parse comments if present
    final commentsJson = json['comments'] as List<dynamic>? ?? [];
    final comments = commentsJson.map((c) {
      final commentMap = c as Map<String, dynamic>;
      return EventComment(
        author: commentMap['author'] as String? ?? '',
        timestamp: commentMap['timestamp'] as String? ?? '',
        content: commentMap['content'] as String? ?? '',
        metadata: commentMap['npub'] != null
            ? {'npub': commentMap['npub'] as String}
            : {},
      );
    }).toList();

    // Parse updates if present
    final updatesJson = json['updates'] as List<dynamic>? ?? [];
    final updates = updatesJson.map((u) {
      final updateMap = u as Map<String, dynamic>;
      return EventUpdate(
        id: updateMap['id'] as String? ?? '',
        title: updateMap['title'] as String? ?? '',
        author: updateMap['author'] as String? ?? '',
        posted: updateMap['posted'] as String? ?? '',
        content: updateMap['content'] as String? ?? '',
      );
    }).toList();

    // Parse registration if present
    EventRegistration? registration;
    final regJson = json['registration'] as Map<String, dynamic>?;
    if (regJson != null) {
      final goingJson = regJson['going'] as List<dynamic>? ?? [];
      final interestedJson = regJson['interested'] as List<dynamic>? ?? [];

      final going = goingJson.map((e) {
        final entryMap = e as Map<String, dynamic>;
        return RegistrationEntry(
          callsign: entryMap['callsign'] as String? ?? '',
          npub: entryMap['npub'] as String? ?? '',
        );
      }).toList();

      final interested = interestedJson.map((e) {
        final entryMap = e as Map<String, dynamic>;
        return RegistrationEntry(
          callsign: entryMap['callsign'] as String? ?? '',
          npub: entryMap['npub'] as String? ?? '',
        );
      }).toList();

      registration = EventRegistration(going: going, interested: interested);
    }

    // Parse links if present
    final linksJson = json['links'] as List<dynamic>? ?? [];
    final links = linksJson.map((l) {
      final linkMap = l as Map<String, dynamic>;
      return EventLink(
        url: linkMap['url'] as String? ?? '',
        description: linkMap['description'] as String? ?? '',
        password: linkMap['password'] as String?,
      );
    }).toList();

    return Event(
      id: json['id'] as String? ?? '',
      author: json['author'] as String? ?? '',
      timestamp: json['timestamp'] as String? ?? '',
      title: json['title'] as String? ?? '',
      startDate: json['start_date'] as String?,
      endDate: json['end_date'] as String?,
      admins: (json['admins'] as List<dynamic>?)?.cast<String>() ?? [],
      moderators: (json['moderators'] as List<dynamic>?)?.cast<String>() ?? [],
      groupAccess: (json['groups'] as List<dynamic>?)?.cast<String>() ??
          (json['group_access'] as List<dynamic>?)?.cast<String>() ??
          [],
      location: json['location'] as String? ?? 'online',
      locationName: json['location_name'] as String?,
      content: json['content'] as String? ?? '',
      agenda: json['agenda'] as String?,
      visibility: json['visibility'] as String? ?? 'public',
      unlistedKey: json['unlisted_key'] as String? ?? json['unlistedKey'] as String?,
      accessCallsigns:
          (json['access_callsigns'] as List<dynamic>?)?.cast<String>() ??
              (json['accessCallsigns'] as List<dynamic>?)?.cast<String>() ??
              [],
      accessRequestPrompt: json['access_request_prompt'] as String? ??
          json['accessRequestPrompt'] as String?,
      commentsEnabled: (json['comments_enabled'] as bool?) ??
          (json['commentsEnabled'] as bool?) ??
          true,
      likes: (json['likes'] as List<dynamic>?)?.cast<String>() ?? [],
      comments: comments,
      photos: (json['photos'] as List<dynamic>?)?.cast<String>() ??
          (json['flyers'] as List<dynamic>?)?.cast<String>() ??
          [],
      flyer: json['flyer'] as String?,
      trailer: json['trailer'] as String?,
      updates: updates,
      registration: registration,
      links: links,
      contacts: (json['contacts'] as List<dynamic>?)?.cast<String>() ?? [],
      slug: json['slug'] as String?,
      metadata: metadata,
    );
  }

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

  /// Whether a meaningful time is available (00:00 treated as "not set")
  bool get hasDisplayTime => displayTime != '00:00';

  /// Get display date (YYYY-MM-DD)
  String get displayDate {
    final dt = dateTime;
    final year = dt.year.toString();
    final month = dt.month.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }

  /// Get display date + time (omit time if unset)
  String get displayDateTime {
    if (!hasDisplayTime) {
      return displayDate;
    }
    return '$displayDate $displayTime';
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

  /// Linked place path (relative or absolute)
  String? get placePath {
    final path = metadata['place_path'] ?? metadata['placePath'];
    if (path == null || path.trim().isEmpty) return null;
    return path.trim();
  }

  /// Whether this event links to a place
  bool get hasPlaceReference => placePath != null;

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
  bool hasUserLiked(String? npub) {
    if (npub == null || npub.isEmpty) return false;
    return likes.contains(npub);
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

    // Unlisted access key (only for unlisted events)
    if (unlistedKey != null && unlistedKey!.isNotEmpty) {
      buffer.writeln('UNLISTED_KEY: $unlistedKey');
    }

    // Per-callsign access grants (private / group / request_access)
    if (accessCallsigns.isNotEmpty) {
      buffer.writeln('ACCESS_CALLSIGNS: ${accessCallsigns.join(', ')}');
    }

    // Optional access-request prompt (shown to visitors of request_access
    // events so they know what to put in their request note).
    if (accessRequestPrompt != null && accessRequestPrompt!.trim().isNotEmpty) {
      buffer.writeln('ACCESS_REQUEST_PROMPT: ${accessRequestPrompt!.trim()}');
    }

    // Persist comments-enabled only when the author has explicitly turned
    // it off — keeps older event.txt files compatible (default is true).
    if (!commentsEnabled) {
      buffer.writeln('COMMENTS_ENABLED: false');
    }

    // Contacts (optional)
    if (contacts.isNotEmpty) {
      buffer.writeln('CONTACTS: ${contacts.join(', ')}');
    }

    // URL slug (optional)
    if (slug != null && slug!.isNotEmpty) {
      buffer.writeln('SLUG: $slug');
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

    // Parse optional fields (AUTHOR is now optional, discovered from folder path)
    String author = '';
    String? startDate;
    String? endDate;
    String? slug;
    List<String> admins = [];
    List<String> moderators = [];
    List<String> groupAccess = [];
    List<String> contacts = [];
    String? location;
    String? locationName;
    String? agenda;
    String visibility = 'public'; // Default to public
    String? unlistedKey;
    List<String> accessCallsigns = [];
    String? accessRequestPrompt;
    bool commentsEnabled = true;

    int currentLine = 3;

    // Parse header fields until we hit blank line
    while (currentLine < lines.length && lines[currentLine].trim().isNotEmpty) {
      final line = lines[currentLine];

      if (line.startsWith('AUTHOR: ')) {
        // Legacy field - still parse for backwards compatibility
        author = line.substring(8).trim();
      } else if (line.startsWith('START_DATE: ')) {
        startDate = line.substring(12).trim();
      } else if (line.startsWith('END_DATE: ')) {
        endDate = line.substring(10).trim();
      } else if (line.startsWith('ADMINS: ')) {
        final adminsStr = line.substring(8).trim();
        admins = adminsStr.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      } else if (line.startsWith('MODERATORS: ')) {
        final modsStr = line.substring(12).trim();
        moderators = modsStr.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      } else if (line.startsWith('GROUPS: ')) {
        // Legacy field - still parse for backwards compatibility
        final groupsStr = line.substring(8).trim();
        groupAccess = groupsStr.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      } else if (line.startsWith('LOCATION: ')) {
        location = line.substring(10).trim();
      } else if (line.startsWith('LOCATION_NAME: ')) {
        locationName = line.substring(15).trim();
      } else if (line.startsWith('AGENDA: ')) {
        agenda = line.substring(8).trim();
      } else if (line.startsWith('VISIBILITY: ')) {
        visibility = line.substring(12).trim();
      } else if (line.startsWith('UNLISTED_KEY: ')) {
        unlistedKey = line.substring(14).trim();
      } else if (line.startsWith('ACCESS_CALLSIGNS: ')) {
        final csStr = line.substring(18).trim();
        accessCallsigns = csStr
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
      } else if (line.startsWith('ACCESS_REQUEST_PROMPT: ')) {
        accessRequestPrompt = line.substring(23).trim();
      } else if (line.startsWith('COMMENTS_ENABLED: ')) {
        final v = line.substring(18).trim().toLowerCase();
        commentsEnabled = !(v == 'false' || v == '0' || v == 'no');
      } else if (line.startsWith('CONTACTS: ')) {
        final contactsStr = line.substring(10).trim();
        contacts = contactsStr.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      } else if (line.startsWith('SLUG: ')) {
        slug = line.substring(6).trim();
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
      groupAccess: groupAccess,
      location: location,
      locationName: locationName,
      content: content,
      agenda: agenda,
      visibility: visibility,
      unlistedKey: unlistedKey,
      accessCallsigns: accessCallsigns,
      accessRequestPrompt: accessRequestPrompt,
      commentsEnabled: commentsEnabled,
      contacts: contacts,
      slug: slug,
      metadata: metadata,
    );
  }

  /// Whether this event has contacts associated
  bool get hasContacts => contacts.isNotEmpty;

  /// Get contact count
  int get contactCount => contacts.length;

  /// The cover photo the UI should display prominently. Uses the
  /// explicit [flyer] if set; otherwise falls back to the first photo
  /// so existing events (pre-flyer-field) still get a cover image.
  String? get primaryFlyer {
    if (flyer != null && flyer!.isNotEmpty) return flyer;
    if (photos.isEmpty) return null;
    return photos.first;
  }

  /// True when the event has at least one photo (with or without an
  /// explicit flyer designation).
  bool get hasPhotos => photos.isNotEmpty;

  /// True when the author has designated one of the photos as the
  /// event flyer (the cover image). Prefer this over [hasPhotos]
  /// when you want to know whether the author made an intentional
  /// choice rather than just uploaded any photos.
  bool get hasFlyer =>
      (flyer != null && flyer!.isNotEmpty) || photos.isNotEmpty;

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
    List<String>? groupAccess,
    String? location,
    String? locationName,
    String? content,
    String? agenda,
    String? visibility,
    String? unlistedKey,
    List<String>? accessCallsigns,
    String? accessRequestPrompt,
    bool? commentsEnabled,
    List<String>? likes,
    List<EventComment>? comments,
    Map<String, String>? metadata,
    List<String>? photos,
    String? flyer,
    String? trailer,
    List<EventUpdate>? updates,
    EventRegistration? registration,
    List<EventLink>? links,
    List<String>? contacts,
    String? slug,
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
      groupAccess: groupAccess ?? this.groupAccess,
      location: location ?? this.location,
      locationName: locationName ?? this.locationName,
      content: content ?? this.content,
      agenda: agenda ?? this.agenda,
      visibility: visibility ?? this.visibility,
      unlistedKey: unlistedKey ?? this.unlistedKey,
      accessCallsigns: accessCallsigns ?? this.accessCallsigns,
      accessRequestPrompt: accessRequestPrompt ?? this.accessRequestPrompt,
      commentsEnabled: commentsEnabled ?? this.commentsEnabled,
      likes: likes ?? this.likes,
      comments: comments ?? this.comments,
      metadata: metadata ?? this.metadata,
      photos: photos ?? this.photos,
      flyer: flyer ?? this.flyer,
      trailer: trailer ?? this.trailer,
      updates: updates ?? this.updates,
      registration: registration ?? this.registration,
      links: links ?? this.links,
      contacts: contacts ?? this.contacts,
      slug: slug ?? this.slug,
    );
  }

  /// Convert to API JSON
  ///
  /// When [summary] is true, returns minimal data for list views.
  /// When [summary] is false, returns full event detail.
  Map<String, dynamic> toApiJson({bool summary = false}) {
    if (summary) {
      return {
        'id': id,
        'title': title,
        'author': author,
        'timestamp': timestamp,
        'location': location,
        'location_name': locationName,
        'start_date': startDate,
        'end_date': endDate,
        'visibility': visibility,
        'groups': groupAccess,
        'like_count': likes.length,
        'comment_count': comments.length,
        'has_flyer': flyer != null && flyer!.isNotEmpty,
        'has_photos': photos.isNotEmpty,
        'has_trailer': trailer != null,
        'update_count': updates.length,
        'going_count': registration?.goingCount ?? 0,
        'interested_count': registration?.interestedCount ?? 0,
        if (slug != null) 'slug': slug,
        if (placePath != null) 'place_path': placePath,
      };
    }

    // Full event detail
    return {
      'id': id,
      'title': title,
      'author': author,
      'timestamp': timestamp,
      'content': content,
      'location': location,
      'location_name': locationName,
      'start_date': startDate,
      'end_date': endDate,
      'agenda': agenda,
      'visibility': visibility,
      // unlisted_key intentionally NOT included in the default detail
      // payload — the server is responsible for adding it back when the
      // viewer is the event owner (so they can see the share link), and
      // for stripping it when the viewer is anyone else (so the key
      // doesn't leak through the public detail endpoint).
        'admins': admins,
        'moderators': moderators,
        'groups': groupAccess,
        'access_callsigns': accessCallsigns,
        if (accessRequestPrompt != null && accessRequestPrompt!.isNotEmpty)
          'access_request_prompt': accessRequestPrompt,
        'comments_enabled': commentsEnabled,
        'likes': likes,
        'comments': comments.map((c) => {
          'author': c.author,
        'timestamp': c.timestamp,
        'content': c.content,
        'npub': c.npub,
      }).toList(),
      'photos': photos,
      if (flyer != null && flyer!.isNotEmpty) 'flyer': flyer,
      'trailer': trailer,
      'updates': updates.map((u) => {
        'id': u.id,
        'title': u.title,
        'author': u.author,
        'posted': u.posted,
        'content': u.content,
        'like_count': u.likeCount,
        'comment_count': u.commentCount,
      }).toList(),
      'registration': registration != null ? {
        'going': registration!.going.map((e) => {
          'callsign': e.callsign,
          'npub': e.npub,
        }).toList(),
        'interested': registration!.interested.map((e) => {
          'callsign': e.callsign,
          'npub': e.npub,
        }).toList(),
      } : null,
      'links': links.map((l) => {
        'url': l.url,
        'description': l.description,
        'password': l.password,
      }).toList(),
      'contacts': contacts,
      'npub': npub,
      'signature': signature,
      if (slug != null) 'slug': slug,
      if (placePath != null) 'place_path': placePath,
    };
  }

  @override
  String toString() {
    return 'Event(id: $id, title: $title, author: $author, location: $location, likes: ${likes.length}, comments: ${comments.length})';
  }
}
