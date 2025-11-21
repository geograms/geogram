# Geogram Events Format Implementation Guide

**Version**: 1.2
**Last Updated**: 2025-11-21

## Overview

Events in Geogram combine year-based organization with folder structure, location data, and granular engagement features. Each event is a folder containing media files, optional subfolders, and a reactions system for likes and comments.

**New in v1.2**:
- Flyers (event artwork/posters)
- Trailer (promotional video)
- Event Updates (blog-like update system)
- Registration (going/interested tracking)
- Links (relevant URLs with descriptions)

**New in v1.1**:
- Multi-day event support with day folders
- Contributor organization system
- Multiple admins and moderators (identified by npub)
- Moderation system (hide vs delete)

## Event Structure

**Single-Day Event**:
```
events/
└── 2025/
    └── 2025-07-15_summer-festival/
        ├── event.txt
        ├── poster.jpg
        ├── contributors/
        │   ├── CR7BBQ/
        │   │   ├── contributor.txt
        │   │   └── photo1.jpg
        │   └── X135AS/
        │       └── photo2.jpg
        └── .reactions/
            ├── event.txt
            └── contributors/CR7BBQ.txt
```

**Multi-Day Event**:
```
events/
└── 2025/
    └── 2025-09-15_tech-conference/
        ├── event.txt
        ├── schedule.pdf
        ├── day1/
        │   ├── keynote.jpg
        │   └── contributors/
        │       └── CR7BBQ/
        │           └── photos/
        ├── day2/
        │   └── workshop.jpg
        ├── day3/
        │   └── closing.jpg
        ├── contributors/
        │   └── X135AS/
        │       └── drone-video.mp4
        ├── .reactions/
        │   ├── event.txt
        │   ├── day1.txt
        │   └── contributors/X135AS.txt
        └── .hidden/
            ├── comments/
            ├── files/
            └── moderation-log.txt
```

## Event File Format

### Main Event File (event.txt)

**Single-Day Event**:
```
# EVENT: Summer Music Festival

CREATED: 2025-07-15 09:00_00
AUTHOR: CR7BBQ
LOCATION: 40.7128,-74.0060
LOCATION_NAME: Central Park, New York

Annual summer music festival with live performances.

Great weather and amazing turnout!

--> npub: npub1abc123...
--> signature: hex_signature
```

**Multi-Day Event with Admins and Moderators**:
```
# EVENT: Tech Conference 2025

CREATED: 2025-09-15 08:00_00
AUTHOR: CR7BBQ
START_DATE: 2025-09-15
END_DATE: 2025-09-17
ADMINS: npub1xyz789..., npub1bravo...
MODERATORS: npub1delta..., npub1echo...
LOCATION: 40.7128,-74.0060
LOCATION_NAME: Convention Center, NYC

Three-day technology conference with keynotes and workshops.

--> npub: npub1abc123...
--> signature: hex_signature
```

**Header Requirements**:
1. Title line: `# EVENT: <title>`
2. Blank line
3. CREATED: `YYYY-MM-DD HH:MM_ss`
4. AUTHOR: callsign
5. START_DATE: `YYYY-MM-DD` (optional, for multi-day)
6. END_DATE: `YYYY-MM-DD` (optional, for multi-day)
7. ADMINS: comma-separated npub list (optional)
8. MODERATORS: comma-separated npub list (optional)
9. LOCATION: `online` or `lat,lon`
10. LOCATION_NAME: optional description
11. Blank line before content

**Location Formats**:
- Physical: `LOCATION: 38.7223,-9.1393`
- Virtual: `LOCATION: online`

**Content**:
- Plain text (no markdown)
- Multiple paragraphs allowed
- Simple description of event

### Subfolder Metadata (subfolder.txt)

```
# SUBFOLDER: Team Photos

CREATED: 2025-07-15 12:00_00
AUTHOR: BRAVO2

Photos of our amazing team members.

--> npub: npub1bravo...
--> signature: hex_sig
```

Same format as event file but with `# SUBFOLDER:` header.

## Reactions System

### Reactions Directory

All likes and comments stored in `.reactions/` hidden directory.

**Reaction File Naming**:
- Event: `.reactions/event.txt`
- Photo: `.reactions/photo.jpg.txt`
- Subfolder: `.reactions/subfolder-name.txt`

### Reaction File Format

```
LIKES: CR7BBQ, X135AS, BRAVO2

> 2025-07-15 14:30_00 -- CR7BBQ
Great photo!
--> npub: npub1abc123...
--> signature: hex_sig

> 2025-07-15 15:00_00 -- X135AS
Amazing shot!
```

**Components**:
1. LIKES line (comma-separated callsigns)
2. Comments (same format as blog/chat)

### Granular Engagement

Users can like/comment on:
- **Event itself** (`.reactions/event.txt`)
- **Individual files** (`.reactions/filename.ext.txt`)
- **Subfolders** (`.reactions/subfolder-name.txt`)

## Folder Organization

### Event Folder Naming

**Pattern**: `YYYY-MM-DD_sanitized-title/`

**Sanitization**:
- Lowercase
- Replace spaces with hyphens
- Remove special characters
- Max 50 characters
- Examples:
  - "Summer Festival" → `2025-07-15_summer-festival/`
  - "Team Meeting @ HQ" → `2025-01-10_team-meeting-hq/`

### Year Organization

Events organized by year:
```
events/
├── 2024/
│   ├── 2024-01-15_event1/
│   └── 2024-12-31_event2/
└── 2025/
    └── 2025-07-15_event3/
```

### File Organization

**Flat Structure**:
```
event/
├── event.txt
├── photo1.jpg
├── photo2.jpg
└── document.pdf
```

**With Subfolders**:
```
event/
├── event.txt
├── poster.jpg
├── keynote-photos/
│   ├── subfolder.txt
│   ├── speaker1.jpg
│   └── speaker2.jpg
└── workshop-materials/
    ├── subfolder.txt
    └── slides.pdf
```

## File Operations

### Creating Event

```dart
1. Sanitize title to folder name
2. Determine year from date
3. Create directory: events/YYYY/YYYY-MM-DD_title/
4. Create event.txt with header and content
5. Create .reactions/ directory
6. Set permissions
```

### Adding Files

```dart
1. Copy files to event folder or subfolder
2. Preserve original filenames
3. Support any file type (images, videos, documents)
```

### Adding Subfolder

```dart
1. Create subfolder in event directory
2. Optionally create subfolder.txt
3. Can nest subfolders (reasonable depth)
```

### Adding Like

```dart
1. Determine target (event/file/subfolder)
2. Read or create .reactions/<target>.txt
3. Parse LIKES line
4. Add callsign if not present
5. Write updated file
```

### Adding Comment

```dart
1. Determine target
2. Read or create reaction file
3. Append comment with timestamp and author
4. Include npub/signature if available
5. Write updated file
```

## Location Handling

### Coordinate Format

```
LOCATION: lat,lon
LOCATION_NAME: Human-readable name
```

**Examples**:
```
LOCATION: 38.7223,-9.1393
LOCATION_NAME: Lisbon, Portugal

LOCATION: 51.5074,-0.1278
LOCATION_NAME: Tower Bridge, London

LOCATION: online
LOCATION_NAME: Zoom Meeting
```

### UI Display

- Show map for physical locations
- Display "Online" badge for virtual events
- Link to map services (Google Maps, OpenStreetMap)
- Show location name as primary label

## Parsing Implementation

### Event Parsing

```dart
class EventParser {
  static Event parse(String eventPath) {
    // Read event.txt
    final file = File('$eventPath/event.txt');
    final lines = file.readAsLinesSync();

    // Parse header
    final title = lines[0].substring(9); // After "# EVENT: "
    final created = parseTimestamp(lines[2]);
    final author = lines[3].substring(8); // After "AUTHOR: "
    final location = parseLocation(lines[4]);
    final locationName = lines[5].startsWith('LOCATION_NAME:')
        ? lines[5].substring(15)
        : null;

    // Find content start
    int contentStart = findContentStart(lines);
    int contentEnd = findMetadataStart(lines, contentStart);

    // Extract content
    final content = lines
        .sublist(contentStart, contentEnd)
        .join('\n');

    // Parse metadata
    final metadata = parseMetadata(lines, contentEnd);

    return Event(
      title: title,
      created: created,
      author: author,
      location: location,
      locationName: locationName,
      content: content,
      npub: metadata['npub'],
      signature: metadata['signature'],
    );
  }
}
```

### Reaction Parsing

```dart
class ReactionParser {
  static Reactions parse(File reactionFile) {
    final lines = reactionFile.readAsLinesSync();

    // Parse LIKES line
    final likes = <String>[];
    if (lines.isNotEmpty && lines[0].startsWith('LIKES:')) {
      final likesStr = lines[0].substring(6).trim();
      if (likesStr.isNotEmpty) {
        likes.addAll(likesStr.split(',').map((s) => s.trim()));
      }
    }

    // Parse comments
    final comments = <Comment>[];
    int i = 1; // Skip LIKES line
    while (i < lines.length) {
      if (lines[i].startsWith('> ')) {
        final comment = parseComment(lines, i);
        comments.add(comment);
        i = comment.endLine;
      } else {
        i++;
      }
    }

    return Reactions(likes: likes, comments: comments);
  }
}
```

### File Enumeration

```dart
class EventFiles {
  static List<FileItem> enumerate(String eventPath) {
    final files = <FileItem>[];
    final dir = Directory(eventPath);

    for (var entity in dir.listSync()) {
      // Skip hidden files and event.txt
      if (entity.path.contains('/.') ||
          entity.path.endsWith('event.txt')) {
        continue;
      }

      if (entity is File) {
        files.add(FileItem(
          path: entity.path,
          name: basename(entity.path),
          type: determineFileType(entity.path),
          reactions: loadReactions(eventPath, entity.path),
        ));
      } else if (entity is Directory) {
        files.add(FolderItem(
          path: entity.path,
          name: basename(entity.path),
          metadata: loadSubfolderMetadata(entity.path),
          files: enumerate(entity.path), // Recursive
          reactions: loadReactions(eventPath, entity.path),
        ));
      }
    }

    return files;
  }
}
```

## UI Features

### Event List View

**Year-Grouped List**:
- Collapsible year headers
- Events sorted by date (newest first)
- Show event title, date, location badge
- Thumbnail preview from first image
- Like count and comment count

### Event Detail View

**Header**:
- Event title
- Date and author
- Location (map or "Online" badge)
- Like button + count
- Comment count

**Content**:
- Event description
- Location name (if provided)

**Files Grid**:
- Photo/video thumbnails
- Document icons
- Each with like count
- Click to view full size

**Subfolders**:
- Expandable subfolder list
- Show subfolder metadata
- Nested file grids
- Like/comment on subfolder

**Comments Section**:
- Comments on event
- Comments on files (when viewing file)
- Comments on subfolders (when viewing subfolder)
- Flat chronological order

### Interaction Patterns

**Like Flow**:
```
1. User clicks like on event/file/subfolder
2. Check if already liked
3. Add/remove from LIKES list
4. Update .reactions/<target>.txt
5. Refresh UI count
```

**Comment Flow**:
```
1. User selects comment target (event/file/subfolder)
2. Writes comment in input field
3. Submit with current timestamp and callsign
4. Optionally sign with NOSTR key
5. Append to .reactions/<target>.txt
6. Refresh UI
```

## Timestamp Format

Uses standard Geogram format: `YYYY-MM-DD HH:MM_ss`

Example: `2025-07-15 14:30_45`

Note the underscore before seconds (consistent with chat/forum/blog).

## Permissions

### Role Hierarchy

```
Author (event creator)
  ↓
Admins (ADMINS field - identified by npub)
  ↓
Moderators (MODERATORS field - identified by npub)
  ↓
Participants (all other users)
```

### Event Author (Creator)

**Permissions**:
- All admin permissions
- Cannot be removed from admin list
- Edit event.txt (all fields)
- Delete entire event
- Manage admins and moderators

### Admins

Listed in ADMINS field, identified by npub.

**Permissions**:
- Edit event.txt
- Add/remove admins and moderators
- Create/delete subfolders and day folders
- Add/delete any files
- Delete entire event
- Permanently delete comments and content
- Manage contributor folders
- Override moderation decisions

### Moderators

Listed in MODERATORS field, identified by npub.

**Permissions**:
- Hide comments (move to .hidden/)
- Hide files (move to .hidden/)
- View hidden content
- Can restore hidden content
- **Cannot** delete permanently
- **Cannot** edit event.txt
- **Cannot** manage roles

### Participants

All other users.

**Permissions**:
- View event and content
- Create contributor folder for themselves
- Add files to their contributor folder
- Like event, files, and subfolders
- Comment on event, files, and subfolders
- Delete their own comments
- Edit/delete files in their contributor folder

## Multi-Day Events

### Overview

Events spanning multiple days use START_DATE and END_DATE fields and create day folders for organization.

### Creating Multi-Day Event

```dart
1. Parse START_DATE and END_DATE from event.txt
2. Calculate days = END_DATE - START_DATE + 1
3. If days > 1:
   - Create day1/, day2/, ..., dayN/ folders
   - Create .reactions/ in each day folder
4. If days == 1:
   - No day folders (flat structure)
```

### Day Folder Structure

```
2025-09-15_tech-conference/
├── event.txt              (START_DATE: 2025-09-15, END_DATE: 2025-09-17)
├── day1/                  (2025-09-15)
│   └── content...
├── day2/                  (2025-09-16)
│   └── content...
├── day3/                  (2025-09-17)
│   └── content...
└── .reactions/
    ├── event.txt
    ├── day1.txt
    ├── day2.txt
    └── day3.txt
```

### Day Reactions

Users can like and comment on day folders:

```
.reactions/day1.txt:
LIKES: CR7BBQ, X135AS

> 2025-09-15 18:00_00 -- CR7BBQ
Great first day! Keynote was amazing.
```

## Contributor Organization

### Overview

Contributors create subfolders with their callsign to organize their contributions.

### Contributor Folder Structure

```
contributors/
├── CR7BBQ/
│   ├── contributor.txt
│   ├── photo1.jpg
│   └── photo2.jpg
└── X135AS/
    ├── contributor.txt
    └── drone-video.mp4
```

### Contributor Metadata

**File**: `contributors/CALLSIGN/contributor.txt`

**Format**:
```
# CONTRIBUTOR: CR7BBQ

CREATED: 2025-07-15 14:00_00

My photos from the festival.

Shot with Sony A7IV.

--> npub: npub1abc123...
--> signature: hex_sig
```

### Contributor Reactions

```
.reactions/contributors/CR7BBQ.txt:
LIKES: X135AS, BRAVO2

> 2025-07-15 18:00_00 -- X135AS
Amazing photos! Great composition.
```

### Contributor Permissions

- Contributors can only edit files in their own folder
- Admins can access all contributor folders
- Moderators can hide files in contributor folders

## Moderation System

### Overview

Moderators can hide content without permanently deleting it. Admins can restore or permanently delete hidden content.

### Hidden Directory

```
.hidden/
├── comments/
│   ├── event_comment_20250715_143000_SPAMMER.txt
│   └── photo1_comment_20250715_150000_TROLL.txt
├── files/
│   ├── inappropriate.jpg
│   └── spam.pdf
└── moderation-log.txt
```

### Hide vs Delete

**Hide** (Moderators and Admins):
- Moves content to .hidden/
- Not visible in UI
- Can be restored by admins
- Logged in moderation-log.txt

**Delete** (Admins only):
- Permanently removes content
- Cannot be restored
- Used for illegal/harmful content

### Hidden Comment Format

```
HIDDEN_BY: npub1delta...
HIDDEN_DATE: 2025-07-15 16:00_00
REASON: Spam
TARGET: event.txt

> 2025-07-15 14:30_00 -- SPAMMER
Buy my product! Visit spam-site.com
--> npub: npub1spam...
--> signature: hex_sig
```

### Moderation Log

```
.hidden/moderation-log.txt:

> 2025-07-15 16:00_00 -- npub1delta... (moderator)
ACTION: hide_comment
TARGET: event.txt
AUTHOR: SPAMMER
REASON: Spam advertising
CONTENT_PREVIEW: Buy my product...

> 2025-07-16 09:00_00 -- npub1abc... (admin)
ACTION: restore_comment
TARGET: event.txt
AUTHOR: LEGITIMATE_USER
REASON: False positive
```

## Flyers

### File Placement

```
2025-07-15_summer-festival/
├── event.txt
├── flyer.jpg                 # Primary flyer
├── flyer-alt.png            # Alternative design (optional)
└── flyer-sponsor.jpg        # Sponsor version (optional)
```

### Loading Flyers

```dart
List<File> loadFlyers(String eventPath) {
  final flyers = <File>[];
  final eventDir = Directory(eventPath);

  for (var entity in eventDir.listSync()) {
    if (entity is File) {
      final name = basename(entity.path).toLowerCase();
      if (name.startsWith('flyer') &&
          (name.endsWith('.jpg') || name.endsWith('.png') || name.endsWith('.webp'))) {
        flyers.add(entity);
      }
    }
  }

  // Sort so primary flyer (flyer.jpg) is first
  flyers.sort((a, b) => basename(a.path).compareTo(basename(b.path)));
  return flyers;
}
```

### Display Priority

1. `flyer.jpg` or `flyer.png` or `flyer.webp` (primary)
2. `flyer-*.{jpg,png,webp}` (alternatives)
3. First image file in event (fallback)

## Trailer

### File Placement

```
2025-07-15_summer-festival/
├── event.txt
├── trailer.mp4              # Event trailer
└── trailer-info.txt         # Optional metadata
```

### Loading Trailer

```dart
File? loadTrailer(String eventPath) {
  final trailerFile = File('$eventPath/trailer.mp4');
  return trailerFile.existsSync() ? trailerFile : null;
}
```

### Video Player Integration

- Use Flutter video_player package
- Generate thumbnail for preview
- Controls: play/pause, fullscreen, volume
- Auto-play muted option

## Event Updates

### Directory Structure

```
2025-07-15_summer-festival/
├── event.txt
├── updates/
│   ├── 2025-06-15_lineup-announced.md
│   ├── 2025-07-01_tickets-on-sale.md
│   └── 2025-07-14_final-details.md
└── .reactions/
    └── updates/
        └── 2025-06-15_lineup-announced.md.txt
```

### Loading Updates

```dart
class EventUpdate {
  final String id;
  final String title;
  final String author;
  final String posted;
  final String content;
  final Map<String, String> metadata;

  EventUpdate({...});

  static EventUpdate fromFile(File file) {
    final lines = file.readAsLinesSync();
    // Parse "# UPDATE: title"
    final title = lines[0].substring(10).trim();
    // Parse POSTED, AUTHOR, content, metadata
    ...
    return EventUpdate(...);
  }
}

Future<List<EventUpdate>> loadUpdates(String eventPath) async {
  final updates = <EventUpdate>[];
  final updatesDir = Directory('$eventPath/updates');

  if (!await updatesDir.exists()) return updates;

  await for (var entity in updatesDir.list()) {
    if (entity is File && entity.path.endsWith('.md')) {
      updates.add(EventUpdate.fromFile(entity));
    }
  }

  // Sort by date (newest first)
  updates.sort((a, b) => b.posted.compareTo(a.posted));
  return updates;
}
```

### Creating Update

```dart
Future<bool> createUpdate({
  required String eventPath,
  required String author,
  required String title,
  required String content,
  String? npub,
}) async {
  // Check permissions (must be author or admin)

  final now = DateTime.now();
  final filename = '${_formatDate(now)}_${_sanitize(title)}.md';

  final updateFile = File('$eventPath/updates/$filename');
  final updateContent = '''
# UPDATE: $title

POSTED: ${_formatTimestamp(now)}
AUTHOR: $author

$content

${npub != null ? '--> npub: $npub\n' : ''}''';

  await updateFile.writeAsString(updateContent, flush: true);

  // Notify registered users (INTERESTED and GOING)
  await _notifyRegisteredUsers(eventPath, 'New update: $title');

  return true;
}
```

## Registration

### File Format

```
# REGISTRATION

GOING:
CR7BBQ, npub1abc123...
X135AS, npub1xyz789...

INTERESTED:
ALPHA1, npub1alpha...
DELTA4, npub1delta...
```

### Loading Registration

```dart
class EventRegistration {
  final List<RegistrationEntry> going;
  final List<RegistrationEntry> interested;

  EventRegistration({this.going = const [], this.interested = const []});

  int get goingCount => going.length;
  int get interestedCount => interested.length;

  bool isGoing(String callsign) => going.any((e) => e.callsign == callsign);
  bool isInterested(String callsign) => interested.any((e) => e.callsign == callsign);
}

class RegistrationEntry {
  final String callsign;
  final String npub;

  RegistrationEntry(this.callsign, this.npub);
}

EventRegistration loadRegistration(String eventPath) {
  final regFile = File('$eventPath/registration.txt');
  if (!regFile.existsSync()) return EventRegistration();

  final lines = regFile.readAsLinesSync();
  final going = <RegistrationEntry>[];
  final interested = <RegistrationEntry>[];

  String? currentSection;
  for (var line in lines) {
    if (line.trim() == 'GOING:') {
      currentSection = 'going';
    } else if (line.trim() == 'INTERESTED:') {
      currentSection = 'interested';
    } else if (line.trim().isNotEmpty && line.contains(',')) {
      final parts = line.split(',').map((s) => s.trim()).toList();
      if (parts.length == 2) {
        final entry = RegistrationEntry(parts[0], parts[1]);
        if (currentSection == 'going') {
          going.add(entry);
        } else if (currentSection == 'interested') {
          interested.add(entry);
        }
      }
    }
  }

  return EventRegistration(going: going, interested: interested);
}
```

### Adding Registration

```dart
Future<bool> register({
  required String eventPath,
  required String callsign,
  required String npub,
  required RegistrationType type, // going or interested
}) async {
  final registration = loadRegistration(eventPath);

  // Remove from both lists first
  final going = registration.going.where((e) => e.callsign != callsign).toList();
  final interested = registration.interested.where((e) => e.callsign != callsign).toList();

  // Add to appropriate list
  final entry = RegistrationEntry(callsign, npub);
  if (type == RegistrationType.going) {
    going.add(entry);
  } else {
    interested.add(entry);
  }

  // Write updated file
  final buffer = StringBuffer();
  buffer.writeln('# REGISTRATION');
  buffer.writeln();
  buffer.writeln('GOING:');
  for (var e in going) {
    buffer.writeln('${e.callsign}, ${e.npub}');
  }
  buffer.writeln();
  buffer.writeln('INTERESTED:');
  for (var e in interested) {
    buffer.writeln('${e.callsign}, ${e.npub}');
  }

  await File('$eventPath/registration.txt').writeAsString(buffer.toString(), flush: true);
  return true;
}
```

## Links

### File Format

```
# LINKS

LINK: https://zoom.us/j/123456789
DESCRIPTION: Main event Zoom room
PASSWORD: festival2025

LINK: https://festival.example.com
DESCRIPTION: Official website
NOTE: Full schedule available
```

### Loading Links

```dart
class EventLink {
  final String url;
  final String description;
  final String? password;
  final String? note;

  EventLink({
    required this.url,
    required this.description,
    this.password,
    this.note,
  });
}

List<EventLink> loadLinks(String eventPath) {
  final linksFile = File('$eventPath/links.txt');
  if (!linksFile.existsSync()) return [];

  final lines = linksFile.readAsLinesSync();
  final links = <EventLink>[];

  String? currentUrl;
  String? currentDescription;
  String? currentPassword;
  String? currentNote;

  for (var line in lines) {
    if (line.startsWith('LINK:')) {
      // Save previous link if exists
      if (currentUrl != null && currentDescription != null) {
        links.add(EventLink(
          url: currentUrl,
          description: currentDescription,
          password: currentPassword,
          note: currentNote,
        ));
      }
      currentUrl = line.substring(5).trim();
      currentDescription = null;
      currentPassword = null;
      currentNote = null;
    } else if (line.startsWith('DESCRIPTION:')) {
      currentDescription = line.substring(12).trim();
    } else if (line.startsWith('PASSWORD:')) {
      currentPassword = line.substring(9).trim();
    } else if (line.startsWith('NOTE:')) {
      currentNote = line.substring(5).trim();
    }
  }

  // Add last link
  if (currentUrl != null && currentDescription != null) {
    links.add(EventLink(
      url: currentUrl,
      description: currentDescription,
      password: currentPassword,
      note: currentNote,
    ));
  }

  return links;
}
```

### Link Display

- Launch URL in browser
- Copy to clipboard
- Generate QR code for mobile access
- Show password with reveal/hide toggle
- Icon based on domain (Zoom, Google Meet, etc.)

## Best Practices

1. **Descriptive Titles**: Use clear event names
2. **Organize Files**: Use subfolders for large events
3. **Good Filenames**: Name files descriptively (not IMG_001.jpg)
4. **Add Location**: Always include location (online or coordinates)
5. **Sign Content**: Use NOSTR signatures for authenticity
6. **Engage**: Use likes and comments to build community

## Implementation Notes

- Event folders created on demand
- .reactions/ directory created when first like/comment added
- Reaction files removed if no likes and no comments remain
- Original filenames always preserved (no SHA1 renaming)
- Subfolders can be nested (reasonable depth recommended)
- File types unrestricted (images, videos, documents, archives)
- Location coordinates validated (-90 to +90 lat, -180 to +180 lon)
- All text files UTF-8 encoded, Unix line endings

## Security Considerations

- Validate file paths (prevent directory traversal)
- Check file sizes before upload
- Verify NOSTR signatures if present
- Enforce permission checks on all operations
- Sanitize folder names strictly
- Consider privacy when adding exact coordinates

## Summary

The events feature provides:

1. ✅ Year-based organization
2. ✅ Folder-per-event structure
3. ✅ Location support (coordinates or online)
4. ✅ Unlimited files and photos
5. ✅ Optional subfolder organization
6. ✅ Granular likes (event, files, subfolders)
7. ✅ Granular comments (event, files, subfolders)
8. ✅ Simple text format
9. ✅ NOSTR signature support
10. ✅ Permission system

Events are designed for collaborative documentation of gatherings, conferences, parties, and any other organized occasions with shared media and engagement.
