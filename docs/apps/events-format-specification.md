# Events Format Specification

**Version**: 1.2
**Last Updated**: 2025-11-21
**Status**: Active

## Table of Contents

- [Overview](#overview)
- [File Organization](#file-organization)
- [Multi-Day Events](#multi-day-events)
- [Contributor Organization](#contributor-organization)
- [Event Format](#event-format)
- [Flyers](#flyers)
- [Trailer](#trailer)
- [Event Updates](#event-updates)
- [Registration](#registration)
- [Links](#links)
- [Subfolder Organization](#subfolder-organization)
- [Reactions System](#reactions-system)
- [Comments](#comments)
- [Location Support](#location-support)
- [File Management](#file-management)
- [Permissions and Roles](#permissions-and-roles)
- [Moderation System](#moderation-system)
- [NOSTR Integration](#nostr-integration)
- [Complete Examples](#complete-examples)
- [Parsing Implementation](#parsing-implementation)
- [File Operations](#file-operations)
- [Validation Rules](#validation-rules)
- [Best Practices](#best-practices)
- [Security Considerations](#security-considerations)
- [Related Documentation](#related-documentation)
- [Change Log](#change-log)

## Overview

This document specifies the text-based format used for storing events in the Geogram system. The events app provides a platform for organizing and sharing events with photos, files, location information, and community engagement through likes and comments.

Events combine features from other app types with unique characteristics designed for event documentation and collaboration.

### Key Features

- **Year-based Organization**: Events organized in year subdirectories (YYYY/)
- **Event Folders**: Each event is a folder containing all related content
- **Date-based Naming**: Events named YYYY-MM-DD_title for chronological ordering
- **Location Support**: Geographic coordinates or "online" indicator
- **Unlimited Media**: Any number of photos, videos, and files
- **Subfolder Structure**: Optional subfolders for organizing content
- **Granular Reactions**: Likes on event, individual files, and subfolders
- **Granular Comments**: Comments on event, individual files, and subfolders
- **Simple Text Format**: Plain text descriptions (no markdown)
- **NOSTR Integration**: Cryptographic signatures for authenticity

## File Organization

### Directory Structure

```
{app_name}/
├── 2024/
│   ├── 2024-12-25_christmas-party/
│   │   ├── event.txt
│   │   ├── photo1.jpg
│   │   ├── photo2.jpg
│   │   ├── group-photo.jpg
│   │   ├── document.pdf
│   │   ├── team-photos/
│   │   │   ├── subfolder.txt
│   │   │   ├── team1.jpg
│   │   │   ├── team2.jpg
│   │   │   └── team3.jpg
│   │   └── .reactions/
│   │       ├── event.txt
│   │       ├── photo1.jpg.txt
│   │       ├── group-photo.jpg.txt
│   │       └── team-photos.txt
│   └── 2024-12-31_new-year-celebration/
│       ├── event.txt
│       ├── fireworks.mp4
│       └── .reactions/
│           └── event.txt
└── 2025/
    ├── 2025-01-15_tech-conference/
    │   ├── event.txt
    │   ├── keynote.pdf
    │   ├── photos/
    │   │   ├── subfolder.txt
    │   │   └── speaker1.jpg
    │   └── .reactions/
    │       ├── event.txt
    │       └── photos.txt
    └── 2025-02-10_workshop/
        └── event.txt
```

Events are organized by year folders (`YYYY/`) within the app. The event folder name includes the full date (`YYYY-MM-DD_title`).

### Event Folder Naming

**Pattern**: `YYYY-MM-DD_sanitized-title/`

**Sanitization Rules**:
1. Convert title to lowercase
2. Replace spaces and underscores with single hyphens
3. Remove all non-alphanumeric characters (except hyphens)
4. Collapse multiple consecutive hyphens
5. Remove leading/trailing hyphens
6. Truncate to 50 characters
7. Prepend event date in YYYY-MM-DD format

**Examples**:
```
Title: "Summer Music Festival"
Date: 2025-07-15
→ 2025-07-15_summer-music-festival/

Title: "Team Building @ Mountain Resort!"
Date: 2024-03-20
→ 2024-03-20_team-building-mountain-resort/

Title: "Online Webinar: Tech Trends 2025"
Date: 2025-01-10
→ 2025-01-10_online-webinar-tech-trends-2025/
```

### Year Organization

- **Format**: `{app_name}/YYYY/` (e.g., `my-events/2024/`, `my-events/2025/`)
- **Purpose**: Organize events by year for long-term archival
- **Creation**: Automatically created when first event for that year is added
- **Benefits**: Easy year-based browsing, archival, and cleanup

### Special Directories

**`.reactions/` Directory**:
- Hidden directory (starts with dot)
- Contains reaction files for event and items
- One file per item that has likes/comments
- Filename matches target item with `.txt` suffix

**`.hidden/` Directory** (see Moderation System):
- Hidden directory for moderated content
- Contains files/comments hidden by moderators
- Not visible in standard UI

## Multi-Day Events

### Overview

Events can span multiple days. For multi-day events, the system creates separate day folders to organize content chronologically. Single-day events remain as simple folders without day subdivisions.

### Date Range Format

Multi-day events specify start and end dates in the event.txt header:

```
# EVENT: Tech Conference 2025

CREATED: 2025-09-15 08:00_00
AUTHOR: CR7BBQ
START_DATE: 2025-09-15
END_DATE: 2025-09-17
LOCATION: 40.7128,-74.0060
LOCATION_NAME: Convention Center, New York

Three-day technology conference...
```

**New Fields**:
- `START_DATE`: First day of event (YYYY-MM-DD format)
- `END_DATE`: Last day of event (YYYY-MM-DD format)

**Single-Day Events**:
- Omit START_DATE and END_DATE fields
- Or use same date for both
- No day folders created

### Multi-Day Folder Structure

For events spanning multiple days, create day folders:

```
events/
└── 2025/
    └── 2025-09-15_tech-conference/
        ├── event.txt
        ├── poster.jpg                    # Event-level files
        ├── schedule.pdf
        ├── day1/
        │   ├── keynote-photo.jpg
        │   ├── morning-session.mp4
        │   └── .reactions/
        │       └── keynote-photo.jpg.txt
        ├── day2/
        │   ├── workshop-photos/
        │   │   ├── subfolder.txt
        │   │   └── photo1.jpg
        │   └── .reactions/
        │       └── workshop-photos.txt
        ├── day3/
        │   └── closing-ceremony.jpg
        └── .reactions/
            └── event.txt
```

### Day Folder Naming

**Pattern**: `day1/`, `day2/`, `day3/`, etc.

**Characteristics**:
- Sequential numbering starting from 1
- Lowercase "day" prefix
- No date in folder name (date implied from event start date)
- One folder per day of event

**Date Mapping**:
```
Event: 2025-09-15 to 2025-09-17
- day1/ = 2025-09-15
- day2/ = 2025-09-16
- day3/ = 2025-09-17
```

### Day Folder Contents

Each day folder can contain:
- Photos and videos from that day
- Documents specific to that day
- Subfolders for organizing day's content
- `.reactions/` subdirectory for day-specific items

**Event-level vs Day-level Files**:
- **Event-level**: Files in root event folder (poster, schedule, etc.)
- **Day-level**: Files in day folders (photos from specific days)

### Creating Multi-Day Events

```
1. Parse START_DATE and END_DATE from event.txt
2. Calculate number of days (END_DATE - START_DATE + 1)
3. If days > 1:
   - Create day1/, day2/, ..., dayN/ folders
   - Create .reactions/ in each day folder
4. If days == 1:
   - No day folders (flat structure)
```

### Multi-Day Reactions

Reactions on day folders work like subfolder reactions:

```
.reactions/day1.txt          # Likes/comments on day1 folder
.reactions/day2.txt          # Likes/comments on day2 folder
```

**Reaction File Format**:
```
LIKES: CR7BBQ, X135AS

> 2025-09-15 18:00_00 -- CR7BBQ
Great first day! Keynote was amazing.
--> npub: npub1abc...
--> signature: hex_sig
```

### Multi-Day Example

```
=== event.txt ===
# EVENT: Annual Tech Summit

CREATED: 2025-09-15 08:00_00
AUTHOR: CR7BBQ
START_DATE: 2025-09-15
END_DATE: 2025-09-17
LOCATION: 40.7128,-74.0060
LOCATION_NAME: Tech Convention Center, NYC

Three-day technology summit featuring keynotes,
workshops, and networking events.

Day 1: Keynotes and product announcements
Day 2: Technical workshops
Day 3: Community sessions and closing ceremony

--> npub: npub1abc123...
--> signature: hex_sig...

=== Folder Structure ===
2025-09-15_annual-tech-summit/
├── event.txt
├── summit-guide.pdf
├── day1/
│   ├── opening-keynote.jpg
│   └── product-launch.mp4
├── day2/
│   ├── workshops/
│   │   ├── subfolder.txt
│   │   └── ai-workshop.jpg
│   └── lunch-networking.jpg
├── day3/
│   └── closing-ceremony.jpg
└── .reactions/
    ├── event.txt
    ├── day1.txt
    └── day2.txt
```

## Contributor Organization

### Overview

Events can have multiple contributors who share files and photos. Each contributor gets their own subfolder identified by their callsign, allowing clear attribution and organization of contributed content.

### Contributor Folder Structure

```
events/
└── 2025/
    └── 2025-07-15_summer-festival/
        ├── event.txt
        ├── contributors/
        │   ├── CR7BBQ/
        │   │   ├── contributor.txt
        │   │   ├── photo1.jpg
        │   │   ├── photo2.jpg
        │   │   └── video1.mp4
        │   ├── X135AS/
        │   │   ├── contributor.txt
        │   │   ├── drone-footage.mp4
        │   │   └── aerial-photos/
        │   │       └── shot1.jpg
        │   └── BRAVO2/
        │       └── team-photos.jpg
        └── .reactions/
            ├── event.txt
            ├── contributors/CR7BBQ.txt
            └── contributors/X135AS.txt
```

### Contributor Folder Location

**Base Path**: `contributors/CALLSIGN/`

**Characteristics**:
- All contributor folders under `contributors/` subdirectory
- Folder name matches contributor's callsign exactly
- Case-sensitive (CALLSIGN must match)
- One folder per contributor

**For Multi-Day Events**:
```
2025-09-15_tech-conference/
├── event.txt
├── day1/
│   └── contributors/
│       ├── CR7BBQ/
│       └── X135AS/
├── day2/
│   └── contributors/
│       └── BRAVO2/
└── contributors/              # Event-level contributors
    └── DELTA4/
```

Contributors can organize at event-level or within specific day folders.

### Contributor Metadata File

**Filename**: `contributor.txt` (inside contributor folder)

**Format**:
```
# CONTRIBUTOR: CR7BBQ

CREATED: 2025-07-15 14:00_00

My photos and videos from the summer festival.

Captured with Canon EOS R5.

--> npub: npub1abc123...
--> signature: hex_sig...
```

**Header**:
1. `# CONTRIBUTOR: <callsign>`
2. Blank line
3. `CREATED: YYYY-MM-DD HH:MM_ss`
4. Blank line
5. Description (optional, plain text)
6. Metadata (npub, signature)

**Purpose**:
- Describe contributor's submissions
- Add context (equipment, technique, etc.)
- Optional - contributor folder can exist without it

### Contributor Reactions

Reactions on contributor folders use the pattern:

**Reaction File**: `.reactions/contributors/CALLSIGN.txt`

**Example**:
```
LIKES: X135AS, BRAVO2, ALPHA1

> 2025-07-15 20:00_00 -- X135AS
Amazing photos! Love the composition.
--> npub: npub1xyz...
--> signature: hex_sig

> 2025-07-16 09:00_00 -- BRAVO2
Great work capturing the atmosphere!
```

### Contributor Permissions

**Contributor Folder Owner**:
- Add/edit/delete files in their own folder
- Edit contributor.txt
- Cannot modify other contributors' folders

**Event Admins**:
- Full access to all contributor folders
- Can reorganize content if needed

**Moderators**:
- Can hide files in contributor folders
- Cannot delete files

### Creating Contributor Folder

```
1. User selects "Add my contributions" for event
2. System creates contributors/ folder if needed
3. Create contributors/CALLSIGN/ folder
4. Optionally create contributor.txt
5. User uploads files to their folder
6. Set permissions (755 for folder, 644 for files)
```

### Contributor Example

```
=== contributors/CR7BBQ/contributor.txt ===
# CONTRIBUTOR: CR7BBQ

CREATED: 2025-07-15 14:30_00

My photography from the festival main stage area.

Shot with Sony A7IV, edited in Lightroom.

--> npub: npub1abc123...
--> signature: hex_sig...

=== File Structure ===
contributors/
├── CR7BBQ/
│   ├── contributor.txt
│   ├── main-stage-1.jpg
│   ├── main-stage-2.jpg
│   ├── crowd-shot.jpg
│   └── band-closeup.jpg
├── X135AS/
│   ├── contributor.txt
│   ├── aerial-view.jpg
│   └── drone-video.mp4
└── BRAVO2/
    └── backstage-photos/
        ├── artist1.jpg
        └── artist2.jpg

=== .reactions/contributors/CR7BBQ.txt ===
LIKES: X135AS, BRAVO2, ALPHA1, DELTA4

> 2025-07-15 18:00_00 -- X135AS
Incredible shots! The lighting is perfect.
--> npub: npub1xyz...
--> signature: hex_sig

> 2025-07-15 19:30_00 -- BRAVO2
Professional quality photos! 📸
```

## Event Format

### Main Event File

Every event must have an `event.txt` file in the event folder root.

**Complete Structure (Single-Day)**:
```
# EVENT: Event Title

CREATED: YYYY-MM-DD HH:MM_ss
AUTHOR: CALLSIGN
LOCATION: online|lat,lon
LOCATION_NAME: Optional Location Name

Event description goes here.
Simple plain text format.
No markdown formatting.

Can include multiple paragraphs.
Each paragraph separated by blank line.

--> npub: npub1...
--> signature: hex_signature
```

**Complete Structure (Multi-Day)**:
```
# EVENT: Event Title

CREATED: YYYY-MM-DD HH:MM_ss
AUTHOR: CALLSIGN
START_DATE: YYYY-MM-DD
END_DATE: YYYY-MM-DD
ADMINS: npub1abc123..., npub1xyz789...
MODERATORS: npub1delta..., npub1echo...
LOCATION: online|lat,lon
LOCATION_NAME: Optional Location Name

Event description goes here.
Simple plain text format.
No markdown formatting.

Can include multiple paragraphs.
Each paragraph separated by blank line.

--> npub: npub1...
--> signature: hex_signature
```

### Header Section

1. **Title Line** (required)
   - **Format**: `# EVENT: <title>`
   - **Example**: `# EVENT: Summer Music Festival`
   - **Constraints**: Any length, but will be truncated in folder name

2. **Blank Line** (required)
   - Separates title from metadata

3. **Created Timestamp** (required)
   - **Format**: `CREATED: YYYY-MM-DD HH:MM_ss`
   - **Example**: `CREATED: 2025-07-15 10:00_00`
   - **Note**: Underscore before seconds

4. **Author Line** (required)
   - **Format**: `AUTHOR: <callsign>`
   - **Example**: `AUTHOR: CR7BBQ`
   - **Constraints**: Alphanumeric callsign
   - **Note**: Author is automatically an admin

5. **Start Date** (optional, required for multi-day)
   - **Format**: `START_DATE: YYYY-MM-DD`
   - **Example**: `START_DATE: 2025-09-15`
   - **Purpose**: First day of multi-day event

6. **End Date** (optional, required for multi-day)
   - **Format**: `END_DATE: YYYY-MM-DD`
   - **Example**: `END_DATE: 2025-09-17`
   - **Purpose**: Last day of multi-day event
   - **Constraints**: Must be >= START_DATE

7. **Admins** (optional)
   - **Format**: `ADMINS: <npub1>, <npub2>, ...`
   - **Example**: `ADMINS: npub1abc123..., npub1xyz789...`
   - **Purpose**: Additional administrators for event
   - **Note**: Author is always admin, even if not listed
   - **Security**: Using npub ensures cryptographic verification

8. **Moderators** (optional)
   - **Format**: `MODERATORS: <npub1>, <npub2>, ...`
   - **Example**: `MODERATORS: npub1delta..., npub1echo...`
   - **Purpose**: Users who can moderate content
   - **Security**: Using npub ensures cryptographic verification

9. **Location Line** (required)
   - **Format**: `LOCATION: <online|lat,lon>`
   - **Examples**:
     - `LOCATION: online` (for virtual events)
     - `LOCATION: 38.7223,-9.1393` (for physical events)
   - **Constraints**: Either "online" or valid lat,lon coordinates

10. **Location Name** (optional)
    - **Format**: `LOCATION_NAME: <name>`
    - **Example**: `LOCATION_NAME: Central Park, New York`
    - **Purpose**: Human-readable location description

11. **Blank Line** (required)
    - Separates header from content

### Content Section

The content section contains the event description.

**Characteristics**:
- **Plain text only** (no markdown)
- Multiple paragraphs allowed
- Blank lines separate paragraphs
- Whitespace preserved
- No length limit (reasonable sizes recommended)

**Example**:
```
Join us for the annual summer festival!

This year's lineup includes:
- Live music performances
- Food trucks
- Kids activities
- Fireworks show at sunset

Bring your friends and family!
```

### Event Metadata

Metadata appears after content:

```
--> npub: npub1abc123...
--> signature: hex_signature_string...
```

- **npub**: NOSTR public key (optional)
- **signature**: NOSTR signature, must be last if present

## Flyers

### Overview

Flyers are artwork images that promote and represent the event visually. They appear prominently in event listings and detail views, providing an attractive visual identity for the event.

### Flyer File Format

**Filename**: `flyer.jpg`, `flyer.png`, or `flyer.webp` (in event root directory)

**Characteristics**:
- Image files placed directly in event root directory
- Multiple flyers supported: `flyer.jpg`, `flyer-alt.png`, `flyer-2.jpg`, etc.
- Recommended resolution: 1920x1080 or 1080x1920 (landscape or portrait)
- Maximum file size: 5MB recommended
- Formats: JPG, PNG, WebP

### Flyer Organization

**Single Flyer**:
```
2025-07-15_summer-festival/
├── event.txt
├── flyer.jpg                  # Main flyer
└── ...
```

**Multiple Flyers**:
```
2025-07-15_summer-festival/
├── event.txt
├── flyer.jpg                  # Primary flyer (displayed first)
├── flyer-alt.png             # Alternative design
├── flyer-sponsor.jpg         # Sponsor version
└── ...
```

### Flyer Display

**UI Behavior**:
- Primary flyer (`flyer.jpg`, `flyer.png`, `flyer.webp`) displayed in event listings
- Multiple flyers shown in gallery/carousel in event detail view
- Fallback to first image in event if no flyer present
- Click to view full size

### Flyer Reactions

Flyers can have likes and comments:

```
.reactions/flyer.jpg.txt:
LIKES: CR7BBQ, X135AS, BRAVO2

> 2025-07-10 14:00_00 -- CR7BBQ
Great design! Very eye-catching.
--> npub: npub1abc...
--> signature: hex_sig
```

### Flyer Metadata (Optional)

**File**: `flyer-info.txt`

```
# FLYER: Summer Festival Poster

CREATED: 2025-07-10 12:00_00
AUTHOR: DESIGNER_CALLSIGN
DESIGNER: Jane Doe
SOFTWARE: Adobe Illustrator

Official poster for the Summer Music Festival 2025.

Design features vibrant colors representing the energy of the festival.

--> npub: npub1designer...
--> signature: hex_sig
```

## Trailer

### Overview

The trailer is a short video that introduces the event, showcases highlights, or provides a preview. It helps attract participants and communicate the event's atmosphere.

### Trailer File Format

**Filename**: `trailer.mp4` (in event root directory)

**Characteristics**:
- Video file placed directly in event root directory
- Recommended duration: 30 seconds to 2 minutes
- Recommended format: MP4 (H.264 codec)
- Recommended resolution: 1920x1080 (Full HD)
- Maximum file size: 50MB recommended

### Trailer Organization

```
2025-07-15_summer-festival/
├── event.txt
├── flyer.jpg
├── trailer.mp4               # Event trailer video
└── ...
```

### Trailer Display

**UI Behavior**:
- Displayed prominently in event detail view
- Auto-play muted option
- Full-screen playback available
- Download option for offline viewing
- Thumbnail preview generated automatically

### Trailer Reactions

Trailers can have likes and comments:

```
.reactions/trailer.mp4.txt:
LIKES: CR7BBQ, X135AS, BRAVO2, ALPHA1

> 2025-07-12 16:00_00 -- X135AS
Amazing trailer! Can't wait for the event!
--> npub: npub1xyz...
--> signature: hex_sig

> 2025-07-13 09:00_00 -- BRAVO2
The editing is top-notch!
```

### Trailer Metadata (Optional)

**File**: `trailer-info.txt`

```
# TRAILER: Summer Festival 2025 Promo

CREATED: 2025-07-12 10:00_00
AUTHOR: VIDEO_CALLSIGN
EDITOR: John Smith
DURATION: 01:45
SOFTWARE: DaVinci Resolve

Promotional trailer featuring last year's highlights and this year's lineup.

Music: "Summer Vibes" by Artist Name (licensed)

--> npub: npub1video...
--> signature: hex_sig
```

## Event Updates

### Overview

Event updates provide a blog-like feature for sharing information before, during, and after the event. Organizers and admins can post updates to keep interested participants informed.

### Updates Directory

**Location**: `<event-folder>/updates/`

**Purpose**: Store chronological updates about the event

**Structure**:
```
2025-07-15_summer-festival/
├── event.txt
├── updates/
│   ├── 2025-06-15_lineup-announced.md
│   ├── 2025-07-01_early-bird-tickets.md
│   ├── 2025-07-14_final-details.md
│   └── 2025-07-16_thank-you.md
└── .reactions/
    └── updates/
        ├── 2025-06-15_lineup-announced.md.txt
        └── 2025-07-01_early-bird-tickets.md.txt
```

### Update File Format

**Filename Pattern**: `YYYY-MM-DD_title.md`

**Format**:
```
# UPDATE: Lineup Announced!

POSTED: 2025-06-15 14:00_00
AUTHOR: CR7BBQ

We're excited to announce the full lineup for Summer Festival 2025!

## Headliners

- Band A (8:00 PM)
- Band B (9:30 PM)
- DJ C (11:00 PM)

## Supporting Acts

- Artist D (6:00 PM)
- Artist E (7:00 PM)

Tickets go on sale next week. Early bird pricing available!

--> npub: npub1abc123...
--> signature: hex_sig
```

**Header Requirements**:
1. Title line: `# UPDATE: <title>`
2. Blank line
3. POSTED: `YYYY-MM-DD HH:MM_ss`
4. AUTHOR: callsign (must be event author or admin)
5. Blank line before content
6. Content in markdown format
7. Optional metadata (npub, signature)

### Update Types

**Pre-Event Updates**:
- Lineup announcements
- Ticket information
- Venue details
- Schedule changes

**During-Event Updates**:
- Real-time highlights
- Schedule adjustments
- Important announcements
- Photo/video shares

**Post-Event Updates**:
- Thank you messages
- Photo galleries
- Event recap
- Next edition announcement

### Update Reactions

Updates have their own reaction files:

```
.reactions/updates/2025-06-15_lineup-announced.md.txt:
LIKES: X135AS, BRAVO2, ALPHA1, DELTA4, ECHO5

> 2025-06-15 15:00_00 -- X135AS
Can't wait! Band A is amazing!
--> npub: npub1xyz...
--> signature: hex_sig

> 2025-06-15 16:30_00 -- BRAVO2
Already got my tickets!
```

### Update Permissions

**Who Can Post Updates**:
- Event author
- Event admins (listed in ADMINS field)

**Update Management**:
- Authors can edit/delete their own updates
- Event author can edit/delete any update
- Admins can edit/delete any update

## Registration

### Overview

The registration system allows people to indicate their interest level and receive updates. Users can register as "GOING" (committed to attend) or "INTERESTED" (following updates).

### Registration File

**Location**: `<event-folder>/registration.txt`

**Format**:
```
# REGISTRATION

GOING:
CR7BBQ, npub1abc123...
X135AS, npub1xyz789...
BRAVO2, npub1bravo...

INTERESTED:
ALPHA1, npub1alpha...
DELTA4, npub1delta...
ECHO5, npub1echo...
FOXTROT6, npub1foxtrot...
```

### Registration Sections

**GOING Section**:
- Users committed to attending the event
- Format: `CALLSIGN, npub`
- One entry per line
- Displayed prominently ("X people going")

**INTERESTED Section**:
- Users following event updates
- Format: `CALLSIGN, npub`
- One entry per line
- Receive notifications for event updates

### Registration Operations

**Add Registration**:
```
1. User clicks "Going" or "Interested"
2. System checks if already registered
3. Add entry: "CALLSIGN, npub" to appropriate section
4. Update registration.txt
5. Subscribe user to event updates (if interested)
```

**Change Registration**:
```
1. User changes from "Interested" to "Going" (or vice versa)
2. Remove from current section
3. Add to new section
4. Update registration.txt
```

**Remove Registration**:
```
1. User clicks "Not Going" or "Not Interested"
2. Remove entry from registration.txt
3. Unsubscribe from updates
```

### Registration Display

**UI Elements**:
- "Going" button (primary action)
- "Interested" button (secondary action)
- Count display: "42 going, 87 interested"
- List view: Show who's going/interested (with privacy option)
- Profile integration: "Your friends going: CR7BBQ, X135AS"

### Registration Notifications

**Auto-Notify Registered Users**:
- When new update is posted
- When event details change (location, date, time)
- When event is cancelled
- Reminder before event (24 hours, 1 hour)

### Registration Privacy

**Privacy Options** (in event.txt or registration-settings.txt):
```
REGISTRATION_VISIBILITY: public|contacts_only|count_only

- public: Show full list of registered users
- contacts_only: Only show contacts/friends
- count_only: Only show count, not names
```

## Links

### Overview

The links feature allows event organizers to share relevant URLs with descriptions, such as video call links, registration pages, related websites, or social media pages.

### Links File

**Location**: `<event-folder>/links.txt`

**Format**:
```
# LINKS

LINK: https://zoom.us/j/123456789
DESCRIPTION: Main event Zoom meeting room
PASSWORD: festival2025

LINK: https://tickets.example.com/summer-festival
DESCRIPTION: Official ticket sales page
NOTE: Early bird pricing ends July 1st

LINK: https://festival.example.com
DESCRIPTION: Festival official website
--> Full schedule, artist bios, and more information

LINK: https://instagram.com/summerfestival
DESCRIPTION: Follow us on Instagram for updates

LINK: https://maps.google.com/?q=Central+Park+NYC
DESCRIPTION: Event venue location on Google Maps
```

### Link Entry Format

**Required Fields**:
- `LINK:` The URL (must be valid http:// or https://)
- `DESCRIPTION:` Brief description of what the link is for

**Optional Fields**:
- `PASSWORD:` Password or access code (for protected links)
- `NOTE:` Additional information about the link
- `--> ` Free-form text lines starting with `-->` for extra details

### Link Categories

Links can be organized by type:

```
# LINKS

## Meeting Links
LINK: https://zoom.us/j/123456789
DESCRIPTION: Main stage Zoom room
PASSWORD: stage2025

LINK: https://meet.google.com/abc-defg-hij
DESCRIPTION: Workshop room

## Information
LINK: https://festival.example.com
DESCRIPTION: Official website

LINK: https://docs.google.com/document/festival-guide
DESCRIPTION: Comprehensive festival guide (PDF)

## Social Media
LINK: https://instagram.com/summerfestival
DESCRIPTION: Instagram

LINK: https://twitter.com/summerfest
DESCRIPTION: Twitter/X updates

## Tickets & Registration
LINK: https://tickets.example.com
DESCRIPTION: Ticket sales
NOTE: Eventbrite platform

## Resources
LINK: https://drive.google.com/folder/abc123
DESCRIPTION: Shared photo folder
NOTE: Upload your photos here!
```

### Link Validation

**URL Validation**:
- Must start with `http://` or `https://`
- Basic URL format validation
- Optional: Check if URL is accessible (ping test)

**Security**:
- Warn users when clicking external links
- Display full URL before navigation
- Optional: URL shortener detection and expansion

### Link Display

**UI Components**:
- Clickable link cards with description
- Icon based on link type (Zoom, Google Meet, website, etc.)
- Copy link to clipboard button
- QR code generation for easy mobile access
- Password visibility toggle for protected links

**Link Organization**:
- Display in order of appearance
- Category headers if using markdown headings
- Highlight primary/important links

### Link Management

**Permissions**:
- Event author and admins can add/edit/delete links
- Links file can be edited directly (text format)
- Version control through file history

**Link Reactions**:

Links can have comments (to report broken links, suggest alternatives):

```
.reactions/links.txt:
LIKES:

> 2025-07-10 12:00_00 -- X135AS
The Zoom link isn't working for me
--> npub: npub1xyz...
--> signature: hex_sig

> 2025-07-10 12:30_00 -- CR7BBQ (admin)
Thanks for reporting! Updated the link.
```

## Subfolder Organization

### Subfolder Purpose

Subfolders organize related content within an event:
- Group photos by category (e.g., "team-photos", "keynote-photos")
- Separate different media types (e.g., "videos", "documents")
- Organize chronologically (e.g., "morning-sessions", "afternoon-sessions")

### Subfolder Structure

Each subfolder can contain:
- Media files (photos, videos)
- Documents (PDFs, text files)
- A `subfolder.txt` file describing the subfolder
- Nested subfolders (one level recommended, unlimited supported)

### Subfolder Metadata File

**Filename**: `subfolder.txt`

**Format**:
```
# SUBFOLDER: Subfolder Title

CREATED: YYYY-MM-DD HH:MM_ss
AUTHOR: CALLSIGN

Description of this subfolder's contents.

Can include multiple paragraphs explaining
what's organized here.

--> npub: npub1...
--> signature: hex_sig...
```

**Characteristics**:
- Optional (subfolder can exist without metadata file)
- Allows description and attribution
- Can have reactions (likes/comments) via `.reactions/`
- Follows same format as event file but with `# SUBFOLDER:` header

## Reactions System

### Overview

The reactions system enables granular engagement with events and their content. Users can:
- Like the event itself
- Like individual photos/videos/files
- Like subfolders
- Comment on any of the above

### Reactions Directory

**Location**: `<event-folder>/.reactions/`

**Purpose**: Stores all likes and comments for event and items

**Filename Pattern**: `<target-item>.txt`

**Examples**:
- Event reactions: `.reactions/event.txt`
- Photo reactions: `.reactions/photo1.jpg.txt`
- Subfolder reactions: `.reactions/team-photos.txt`

### Reaction File Format

```
LIKES: CALLSIGN1, CALLSIGN2, CALLSIGN3

> YYYY-MM-DD HH:MM_ss -- COMMENTER
Comment text here.
--> npub: npub1...
--> signature: hex_sig

> YYYY-MM-DD HH:MM_ss -- ANOTHER_USER
Another comment.
```

### Likes Section

**Format**: `LIKES: <callsign1>, <callsign2>, <callsign3>`

**Characteristics**:
- Comma-separated list of callsigns
- Each callsign can appear only once
- Order can be chronological or alphabetical
- Empty if no likes: `LIKES:` (with no callsigns)
- Optional: line can be omitted if no likes

**Example**:
```
LIKES: CR7BBQ, X135AS, BRAVO2, ALPHA1
```

### Comments Section

Comments follow the likes line and use the same format as other collection types:

```
> YYYY-MM-DD HH:MM_ss -- CALLSIGN
Comment content.
--> npub: npub1...
--> signature: hex_sig
```

### Reaction Targets

**Event Reactions** (`.reactions/event.txt`):
- Likes and comments on the event itself
- Most common reaction target

**File Reactions** (`.reactions/<filename>.txt`):
- Reactions specific to a photo, video, or document
- Filename must match exactly (case-sensitive)
- Examples:
  - Photo: `.reactions/sunset.jpg.txt`
  - Video: `.reactions/highlights.mp4.txt`
  - Document: `.reactions/agenda.pdf.txt`

**Subfolder Reactions** (`.reactions/<subfolder-name>.txt`):
- Reactions on a subfolder as a whole
- Filename matches subfolder name
- Example: `.reactions/team-photos.txt` for `team-photos/` subfolder

### Adding/Removing Likes

**Adding a Like**:
1. Read existing reaction file (or create if doesn't exist)
2. Check if user callsign already in LIKES list
3. If not present, append to LIKES list
4. Write updated reaction file

**Removing a Like**:
1. Read reaction file
2. Find and remove callsign from LIKES list
3. If no likes and no comments remain, delete reaction file
4. Otherwise, write updated reaction file

### Comment Characteristics

- **Threading**: Flat (not threaded)
- **Ordering**: Chronological by timestamp
- **Format**: Same as blog/chat comments
- **Target**: Specific to item (event, file, or subfolder)

## Comments

### Comment Format

```
> YYYY-MM-DD HH:MM_ss -- CALLSIGN
Comment content here.
Can span multiple lines.
--> npub: npub1...
--> signature: hex_signature
```

### Comment Structure

1. **Header Line** (required)
   - **Format**: `> YYYY-MM-DD HH:MM_ss -- CALLSIGN`
   - **Example**: `> 2025-07-15 14:30_45 -- X135AS`
   - Starts with `>` followed by space

2. **Content** (required)
   - Plain text, multiple lines allowed
   - No formatting

3. **Metadata** (optional)
   - npub and signature only
   - Signature must be last if present

### Comment Locations

Comments are stored in reaction files:
- **Event comments**: `.reactions/event.txt`
- **Photo comments**: `.reactions/photo.jpg.txt`
- **Subfolder comments**: `.reactions/subfolder-name.txt`

### Comment Characteristics

- **Flat structure**: No nested replies
- **Chronological order**: Sorted by timestamp
- **Multiple targets**: Can comment on different items
- **Persistent**: Comments remain with item

## Location Support

### Location Types

**Physical Location**:
```
LOCATION: 38.7223,-9.1393
LOCATION_NAME: Lisbon, Portugal
```

**Virtual/Online Event**:
```
LOCATION: online
LOCATION_NAME: Zoom Meeting (optional)
```

### Coordinate Format

**Pattern**: `lat,lon`

**Constraints**:
- **Latitude**: -90.0 to +90.0 (decimal degrees)
- **Longitude**: -180.0 to +180.0 (decimal degrees)
- **Precision**: Up to 6 decimal places recommended
- **Separator**: Comma (no spaces)

**Examples**:
```
LOCATION: 40.7128,-74.0060    # New York City
LOCATION: 51.5074,-0.1278     # London
LOCATION: 35.6762,139.6503    # Tokyo
LOCATION: -33.8688,151.2093   # Sydney
```

### Online Events

For virtual events:
```
LOCATION: online
LOCATION_NAME: Virtual Conference (optional)
```

The `LOCATION_NAME` can provide additional context like platform or URL.

### Location Display

**UI Considerations**:
- Display map for physical locations
- Show "Online" badge for virtual events
- Show location name if provided
- Link to map applications (Google Maps, OpenStreetMap)

## File Management

### Supported File Types

**Images**:
- JPG, JPEG, PNG, GIF, WebP, BMP, SVG
- Any size (reasonable limits recommended)

**Videos**:
- MP4, AVI, MOV, MKV, WebM
- Recommended: MP4 for compatibility

**Documents**:
- PDF, TXT, MD, DOC, DOCX, XLS, XLSX

**Archives**:
- ZIP, TAR, GZ, 7Z

**Other**:
- Any file type can be stored in event folder

### File Organization

Files are stored directly in the event folder or subfolders:

```
2025-07-15_summer-festival/
├── event.txt
├── poster.jpg
├── schedule.pdf
├── photos/
│   ├── subfolder.txt
│   ├── img001.jpg
│   ├── img002.jpg
│   └── img003.jpg
└── videos/
    ├── subfolder.txt
    └── highlights.mp4
```

### File Naming

**Convention**: Original filenames preserved

**Best Practices**:
- Use descriptive names (e.g., `keynote-speaker.jpg` not `IMG_1234.jpg`)
- Avoid special characters in filenames
- Use lowercase for consistency
- Include date/sequence in filename if relevant

**Example Names**:
```
Good:
- team-photo-2025.jpg
- morning-session-keynote.pdf
- highlight-reel.mp4

Avoid:
- IMG_0001.jpg
- Document (1).pdf
- VID_20250715_143045.mp4
```

### File Operations

**Adding Files**:
1. Copy file to event folder or subfolder
2. Preserve original filename
3. Set appropriate permissions (644)

**Deleting Files**:
1. Delete file from filesystem
2. Remove associated reaction file if exists

**Moving Files**:
1. Move file within event folder/subfolders
2. Update reaction file location if it exists

## Permissions and Roles

### Overview

Events support three distinct roles with different permission levels: Admins, Moderators, and Participants. This system enables collaborative event management while maintaining content integrity.

### Roles

#### Event Author

The user who created the event (AUTHOR field).

**Permissions**:
- All admin permissions (author is implicit admin)
- Cannot be removed from admin list
- Can transfer ownership to another admin

#### Admins

Additional administrators listed in ADMINS field.

**Permissions**:
- Edit event.txt (title, description, metadata)
- Add/remove admins and moderators
- Create/delete subfolders and day folders
- Add/delete any files
- Delete entire event
- Permanently delete comments and content
- Manage contributor folders
- Override moderation decisions

**Adding Admins**:
```
ADMINS: npub1abc123..., npub1xyz789..., npub1bravo...
```

**Admin Management**:
- Author can add/remove admins
- Existing admins can add new admins
- Admins cannot remove the author
- Requires majority agreement to remove admin (optional policy)
- Admins identified by npub for security

#### Moderators

Users with moderation privileges listed in MODERATORS field.

**Permissions**:
- Hide comments (move to .hidden/)
- Hide files (move to .hidden/)
- Cannot delete content permanently
- Cannot edit event.txt
- Cannot manage roles
- Can view hidden content
- Can restore hidden content

**Adding Moderators**:
```
MODERATORS: npub1delta..., npub1echo..., npub1foxtrot...
```

**Moderator Identification**:
- Moderators identified by npub
- Ensures cryptographic verification
- Prevents impersonation

**Moderator Scope**:
- Can moderate all content in event
- Can moderate content in all day folders
- Can moderate content in all contributor folders
- Cannot moderate admin actions

#### Participants

All other users who can access the event.

**Permissions**:
- View event and all content
- Add files to event (if allowed by settings)
- Create contributor folder for themselves
- Add files to their contributor folder
- Like event, files, and subfolders
- Comment on event, files, and subfolders
- Delete their own comments
- Edit/delete files in their contributor folder

### Permission Checks

Before any operation, verify user permissions:

```
1. Identify user's role (author, admin, moderator, participant)
2. Check if action is allowed for that role
3. For destructive actions, require confirmation
4. Log action for audit trail
5. Execute operation
```

### Role Hierarchy

```
Author (highest authority)
  ↓
Admins (full control)
  ↓
Moderators (hide only, no delete)
  ↓
Participants (view, contribute, react)
```

### Permission Examples

**Editing Event Description**:
- ✅ Author: Yes
- ✅ Admin: Yes
- ❌ Moderator: No
- ❌ Participant: No

**Deleting Spam Comment**:
- ✅ Author: Yes (permanent delete)
- ✅ Admin: Yes (permanent delete)
- ✅ Moderator: Yes (hide only, not delete)
- ✅ Participant: Only their own comments

**Adding Files to Event**:
- ✅ Author: Yes, anywhere
- ✅ Admin: Yes, anywhere
- ❌ Moderator: Only to their contributor folder
- ⚠️ Participant: Only to their contributor folder

**Removing Admin**:
- ✅ Author: Yes
- ✅ Admin: Yes (except author)
- ❌ Moderator: No
- ❌ Participant: No

### Permission Validation

```dart
enum EventRole {
  author,
  admin,
  moderator,
  participant,
}

class PermissionChecker {
  static bool canEditEvent(String userCallsign, String userNpub, Event event) {
    // Check if user is author by callsign
    if (event.author == userCallsign) return true;
    // Check if user is admin by npub
    if (event.admins.contains(userNpub)) return true;
    return false;
  }

  static bool canDeleteContent(String userCallsign, String userNpub, Event event) {
    // Only admins and author can permanently delete
    if (event.author == userCallsign) return true;
    if (event.admins.contains(userNpub)) return true;
    return false;
  }

  static bool canModerateContent(String userCallsign, String userNpub, Event event) {
    // Admins and moderators can moderate (hide) content
    if (event.author == userCallsign) return true;
    if (event.admins.contains(userNpub)) return true;
    if (event.moderators.contains(userNpub)) return true;
    return false;
  }

  static bool canManageRoles(String userCallsign, String userNpub, Event event) {
    // Only author and admins can manage roles
    if (event.author == userCallsign) return true;
    if (event.admins.contains(userNpub)) return true;
    return false;
  }

  static EventRole getUserRole(String userCallsign, String userNpub, Event event) {
    if (event.author == userCallsign) return EventRole.author;
    if (event.admins.contains(userNpub)) return EventRole.admin;
    if (event.moderators.contains(userNpub)) return EventRole.moderator;
    return EventRole.participant;
  }
}
```

## Moderation System

### Overview

The moderation system allows moderators and admins to hide inappropriate content without permanently deleting it. Hidden content is moved to a `.hidden/` directory and can be restored by admins if needed.

### Hidden Content Directory

**Location**: `<event-folder>/.hidden/`

**Purpose**: Store content hidden by moderators

**Structure**:
```
.hidden/
├── comments/
│   ├── event_comment_20250715_143000_SPAMMER.txt
│   └── photo1_comment_20250715_150000_TROLL.txt
├── files/
│   ├── inappropriate-image.jpg
│   └── spam-document.pdf
└── moderation-log.txt
```

### Hiding vs Deleting

**Hiding (Moderators and Admins)**:
- Moves content to `.hidden/`
- Content not visible in UI
- Can be restored by admins
- Logged in moderation-log.txt
- Original metadata preserved

**Deleting (Admins Only)**:
- Permanently removes content
- Cannot be restored
- More severe action
- Used for illegal or harmful content

### Hide Comment

**Process**:
```
1. Moderator selects "Hide Comment"
2. System checks moderator permissions
3. Extract comment from reaction file
4. Create hidden comment file:
   .hidden/comments/<target>_comment_<timestamp>_<author>.txt
5. Remove comment from reaction file
6. Log moderation action
7. Optionally notify comment author
```

**Hidden Comment File**:
```
HIDDEN_BY: DELTA4
HIDDEN_DATE: 2025-07-15 16:00_00
REASON: Spam
TARGET: event.txt

> 2025-07-15 14:30_00 -- SPAMMER
Buy my product! Visit example.com!!!
--> npub: npub1spam...
--> signature: hex_sig
```

### Hide File

**Process**:
```
1. Moderator selects "Hide File"
2. System checks moderator permissions
3. Move file to .hidden/files/
4. Move reaction file if exists
5. Create metadata file for hidden file
6. Log moderation action
```

**Hidden File Metadata** (`.hidden/files/<filename>.meta`):
```
ORIGINAL_PATH: photo.jpg
HIDDEN_BY: ECHO5
HIDDEN_DATE: 2025-07-15 17:30_00
REASON: Inappropriate content
SHA1: abc123def456...
```

### Restore Hidden Content

**Process** (Admins only):
```
1. Admin views .hidden/ directory
2. Selects content to restore
3. System moves content back to original location
4. Updates reaction files if needed
5. Logs restoration action
```

### Moderation Log

**File**: `.hidden/moderation-log.txt`

**Format**:
```
> 2025-07-15 16:00_00 -- DELTA4 (moderator)
ACTION: hide_comment
TARGET: event.txt
AUTHOR: SPAMMER
REASON: Spam advertising
CONTENT_PREVIEW: Buy my product! Visit...

> 2025-07-15 17:30_00 -- ECHO5 (moderator)
ACTION: hide_file
TARGET: inappropriate-image.jpg
REASON: Inappropriate content

> 2025-07-16 09:00_00 -- CR7BBQ (admin)
ACTION: restore_comment
TARGET: event.txt
AUTHOR: LEGITIMATE_USER
REASON: False positive, comment was fine

> 2025-07-16 10:00_00 -- CR7BBQ (admin)
ACTION: delete_file
TARGET: illegal-content.jpg
REASON: Illegal content, permanent removal
```

### Moderation UI Features

**For Moderators**:
- "Hide Comment" button on comments
- "Hide File" button on files
- View hidden content (read-only)
- Add reason when hiding content
- Cannot restore or permanently delete

**For Admins**:
- All moderator features
- "Restore" button on hidden content
- "Permanently Delete" button
- View full moderation log
- Manage moderator list

**For Participants**:
- Cannot see hidden content
- Cannot see .hidden/ directory
- Can report content for moderation

### Moderation Best Practices

1. **Always Add Reason**: Explain why content was hidden
2. **Consistent Standards**: Apply rules fairly to all users
3. **Review Regularly**: Check hidden content periodically
4. **Restore Mistakes**: Fix false positives quickly
5. **Escalate Severe Cases**: Report illegal content to admins
6. **Document Patterns**: Note repeat offenders in log
7. **Communicate**: Notify users when their content is hidden

### Moderation Example

```
=== Original: .reactions/event.txt ===
LIKES: CR7BBQ, X135AS

> 2025-07-15 12:00_00 -- CR7BBQ
Great event! Thanks for organizing.

> 2025-07-15 14:30_00 -- SPAMMER
BUY NOW! Amazing deals at spam-site.com!!!

> 2025-07-15 15:00_00 -- X135AS
Looking forward to next year!

=== After Hiding Spam Comment ===

.reactions/event.txt:
LIKES: CR7BBQ, X135AS

> 2025-07-15 12:00_00 -- CR7BBQ
Great event! Thanks for organizing.

> 2025-07-15 15:00_00 -- X135AS
Looking forward to next year!

.hidden/comments/event_comment_20250715_143000_SPAMMER.txt:
HIDDEN_BY: DELTA4
HIDDEN_DATE: 2025-07-15 16:00_00
REASON: Spam advertising
TARGET: event.txt

> 2025-07-15 14:30_00 -- SPAMMER
BUY NOW! Amazing deals at spam-site.com!!!
--> npub: npub1spam...
--> signature: hex_sig

.hidden/moderation-log.txt:
> 2025-07-15 16:00_00 -- DELTA4 (moderator)
ACTION: hide_comment
TARGET: event.txt
AUTHOR: SPAMMER
REASON: Spam advertising
CONTENT_PREVIEW: BUY NOW! Amazing deals...
```

## NOSTR Integration

### NOSTR Keys

**npub (Public Key)**:
- Bech32-encoded public key
- Format: `npub1` followed by encoded data
- Purpose: Author identification, verification

**nsec (Private Key)**:
- Never stored in files
- Used for signing
- Kept secure in user's keystore

### Signature Format

**Event Signature**:
```
--> npub: npub1qqqqqqqq...
--> signature: 0123456789abcdef...
```

**Comment Signature**:
```
> 2025-07-15 14:30_45 -- CR7BBQ
Great event!
--> npub: npub1abc123...
--> signature: fedcba987654...
```

**Subfolder Signature**:
```
# SUBFOLDER: Team Photos

CREATED: 2025-07-15 12:00_00
AUTHOR: CR7BBQ

Photos of our amazing team members.

--> npub: npub1abc123...
--> signature: 789abcdef012...
```

### Signature Verification

1. Extract npub and signature from metadata
2. Reconstruct signable message content
3. Verify Schnorr signature
4. Display verification badge in UI if valid

## Complete Examples

### Example 1: Simple Event

```
# EVENT: Team Lunch

CREATED: 2025-06-15 12:00_00
AUTHOR: CR7BBQ
LOCATION: 38.7223,-9.1393
LOCATION_NAME: Local Restaurant

Monthly team lunch gathering.

Everyone enjoyed the meal and had great conversations!

--> npub: npub1abc123...
--> signature: 0123456789abcdef...
```

### Example 2: Event with Photos

```
Event folder: 2025-07-15_summer-festival/

Files:
- event.txt
- poster.jpg
- photo1.jpg
- photo2.jpg
- photo3.jpg
- .reactions/
  - event.txt
  - photo1.jpg.txt
  - photo2.jpg.txt

=== event.txt ===
# EVENT: Summer Music Festival

CREATED: 2025-07-15 09:00_00
AUTHOR: X135AS
LOCATION: 40.7128,-74.0060
LOCATION_NAME: Central Park, New York

Annual summer music festival with live performances!

Featured artists:
- Band A
- Band B
- DJ C

Great weather and amazing turnout!

--> npub: npub1xyz789...
--> signature: abcd1234efgh5678...

=== .reactions/event.txt ===
LIKES: CR7BBQ, BRAVO2, ALPHA1, DELTA4

> 2025-07-15 18:30_00 -- CR7BBQ
Amazing event! Can't wait for next year.
--> npub: npub1abc123...
--> signature: 111222333...

> 2025-07-16 09:00_00 -- BRAVO2
The lineup was incredible!

=== .reactions/photo1.jpg.txt ===
LIKES: CR7BBQ, X135AS

> 2025-07-15 19:00_00 -- CR7BBQ
Great shot of the main stage!
```

### Example 3: Event with Subfolders

```
Event folder: 2025-01-10_tech-conference/

Structure:
- event.txt
- keynote-photos/
  - subfolder.txt
  - speaker1.jpg
  - speaker2.jpg
  - speaker3.jpg
- workshop-materials/
  - subfolder.txt
  - slides.pdf
  - handout.pdf
- .reactions/
  - event.txt
  - keynote-photos.txt
  - keynote-photos/speaker1.jpg.txt

=== event.txt ===
# EVENT: Tech Conference 2025

CREATED: 2025-01-10 08:00_00
AUTHOR: CR7BBQ
LOCATION: online
LOCATION_NAME: Zoom Virtual Conference

Annual technology conference featuring industry leaders.

Topics covered:
- AI and Machine Learning
- Web3 and Blockchain
- Cybersecurity Trends
- Cloud Architecture

Over 500 participants attended remotely!

--> npub: npub1abc123...
--> signature: aaa111bbb222...

=== keynote-photos/subfolder.txt ===
# SUBFOLDER: Keynote Speaker Photos

CREATED: 2025-01-10 14:00_00
AUTHOR: BRAVO2

Screenshots from the keynote presentations.

All speakers gave excellent talks!

--> npub: npub1bravo...
--> signature: ccc333ddd444...

=== .reactions/event.txt ===
LIKES: X135AS, BRAVO2, ALPHA1

> 2025-01-10 17:00_00 -- X135AS
Excellent conference! Learned so much.
--> npub: npub1xyz789...
--> signature: eee555fff666...

=== .reactions/keynote-photos.txt ===
LIKES: CR7BBQ, X135AS

> 2025-01-10 16:00_00 -- CR7BBQ
Great captures of the presentations!

=== .reactions/keynote-photos/speaker1.jpg.txt ===
LIKES: ALPHA1, BRAVO2

> 2025-01-10 18:00_00 -- ALPHA1
Inspiring talk from this speaker!
```

### Example 4: In-Person Event

```
Event folder: 2024-12-25_holiday-party/

Files:
- event.txt
- group-photo.jpg
- decorations.jpg
- dinner-table.jpg
- santa.jpg
- .reactions/
  - event.txt
  - group-photo.jpg.txt

=== event.txt ===
# EVENT: Annual Holiday Party

CREATED: 2024-12-25 18:00_00
AUTHOR: BRAVO2
LOCATION: 51.5074,-0.1278
LOCATION_NAME: Community Center, London

Wonderful holiday celebration with the team!

Highlights:
- Secret Santa gift exchange
- Festive dinner
- Karaoke session
- Photo booth

Thank you all for making it special!

--> npub: npub1bravo...
--> signature: 999aaabbb000...

=== .reactions/event.txt ===
LIKES: CR7BBQ, X135AS, ALPHA1, DELTA4, ECHO5, FOXTROT6

> 2024-12-25 22:00_00 -- CR7BBQ
Best party ever! Happy holidays everyone!
--> npub: npub1abc123...
--> signature: 111ccc222ddd...

> 2024-12-26 09:00_00 -- X135AS
Thanks for organizing! Great memories made.
--> npub: npub1xyz789...
--> signature: 333eee444fff...

> 2024-12-26 10:30_00 -- ALPHA1
The karaoke was hilarious! 😄

=== .reactions/group-photo.jpg.txt ===
LIKES: CR7BBQ, X135AS, BRAVO2, ALPHA1, DELTA4

> 2024-12-25 23:00_00 -- DELTA4
Perfect group shot! Everyone looks great.
```

## Parsing Implementation

### Event File Parsing

```
1. Read event.txt as UTF-8 text
2. Verify first line starts with "# EVENT: "
3. Extract title from first line
4. Parse header lines:
   - CREATED: timestamp
   - AUTHOR: callsign
   - LOCATION: online|lat,lon
   - LOCATION_NAME: (optional)
5. Find content start (after header blank line)
6. Parse content until metadata or EOF
7. Extract metadata (npub, signature)
8. Validate signature placement (must be last)
```

### Subfolder Parsing

```
1. Check for subfolder.txt in subdirectory
2. If exists, parse same as event file but with "# SUBFOLDER:"
3. Extract title, created, author, content, metadata
4. Associate with parent event
```

### Reaction File Parsing

```
1. Read .reactions/<item>.txt
2. Parse LIKES line (comma-separated callsigns)
3. Parse comments:
   - Extract timestamp and author from header
   - Read content lines
   - Parse metadata (npub, signature)
4. Associate with target item
```

### File Enumeration

```
1. List all files in event folder (exclude . files)
2. Identify subfolders
3. For each subfolder:
   - Check for subfolder.txt
   - List files in subfolder
   - Recursively enumerate nested subfolders
4. Build file tree structure
5. Cross-reference with .reactions/ for engagement data
```

## File Operations

### Creating an Event

```
1. Sanitize event title
2. Generate folder name: YYYY-MM-DD_title/
3. Determine year from date
4. Create year directory if needed: events/YYYY/
5. Create event folder: events/YYYY/YYYY-MM-DD_title/
6. Create event.txt with header and content
7. Create .reactions/ directory
8. Set folder permissions (755)
```

### Adding Files to Event

```
1. Verify event exists
2. Copy file(s) to event folder or subfolder
3. Preserve original filenames
4. Set file permissions (644)
5. Update UI/index with new files
```

### Creating Subfolder

```
1. Verify event exists
2. Create subfolder in event directory
3. Optionally create subfolder.txt
4. Set folder permissions (755)
5. Update event index
```

### Adding a Like

```
1. Determine target (event, file, or subfolder)
2. Generate reaction filename: .reactions/<target>.txt
3. Read existing reaction file or create new
4. Parse LIKES line
5. Check if user already liked
6. If not, add callsign to LIKES list
7. Write updated reaction file
```

### Removing a Like

```
1. Read reaction file
2. Parse LIKES line
3. Remove user's callsign
4. If no likes and no comments remain:
   - Delete reaction file
5. Otherwise:
   - Write updated file without that callsign
```

### Adding a Comment

```
1. Determine target item
2. Generate reaction filename
3. Read existing or create new
4. Append comment:
   - Header line with timestamp and author
   - Content lines
   - Metadata (npub, signature)
5. Write updated reaction file
```

### Deleting a Comment

```
1. Read reaction file
2. Locate comment by timestamp and author
3. Remove comment block
4. If no likes and no comments remain:
   - Delete reaction file
5. Otherwise:
   - Write updated file without that comment
```

### Deleting an Event

```
1. Verify user has permission (creator or admin)
2. Recursively delete event folder and all contents:
   - All files
   - All subfolders
   - .reactions/ directory
3. Update event index
```

## Validation Rules

### Event Validation

- [x] First line must start with `# EVENT: `
- [x] Title must not be empty
- [x] CREATED line must have valid timestamp
- [x] AUTHOR line must have non-empty callsign
- [x] LOCATION must be "online" or valid lat,lon
- [x] Header must end with blank line
- [x] Signature must be last metadata if present
- [x] Folder name must match YYYY-MM-DD_* pattern

### Location Validation

**Coordinates**:
- Latitude: -90.0 to +90.0
- Longitude: -180.0 to +180.0
- Format: `lat,lon` (no spaces)

**Online**:
- Exact string: `online` (lowercase)

### Reaction File Validation

- Filename must match existing file/folder/event
- LIKES line format: `LIKES: callsign1, callsign2`
- No duplicate callsigns in LIKES list
- Comments must have valid timestamp
- Signature must be last if present

### Subfolder Validation

- Subfolder.txt header starts with `# SUBFOLDER: `
- Same validation as event file
- Can be nested (reasonable depth recommended)

## Best Practices

### For Event Organizers

1. **Clear titles**: Use descriptive event names
2. **Accurate locations**: Provide correct coordinates or "online"
3. **Organize files**: Use subfolders for large events
4. **Name files well**: Descriptive filenames help browsing
5. **Add context**: Write detailed event descriptions
6. **Sign events**: Use npub/signature for authenticity

### For Participants

1. **Respect structure**: Keep files in appropriate subfolders
2. **Use likes**: Engage with event and content
3. **Add comments**: Share thoughts and memories
4. **Quality photos**: Upload clear, relevant images
5. **Sign comments**: Add npub/signature to comments

### For Developers

1. **Validate input**: Check all user input thoroughly
2. **Atomic operations**: Use temp files for updates
3. **Permission checks**: Verify user rights before operations
4. **Handle errors**: Gracefully handle missing/invalid files
5. **Optimize reads**: Cache event metadata, lazy-load files
6. **Index reactions**: Build indexes for performance

### For System Administrators

1. **Size limits**: Set reasonable file size limits
2. **Monitor storage**: Track disk usage per event
3. **Backup strategy**: Regular backups of events/
4. **Archive old events**: Move old years to separate storage
5. **Cleanup orphans**: Remove .reactions/ for deleted files

## Security Considerations

### Access Control

**Event Creator**:
- Edit event.txt
- Delete event and all contents
- Create/delete subfolders
- Moderate all comments

**Participants**:
- Add files to event
- Create subfolders
- Like event and items
- Comment on event and items
- Delete own comments

### File Security

**Permissions**:
- Event folders: 755 (rwxr-xr-x)
- Files: 644 (rw-r--r--)
- No execute permissions on uploaded files

**Path Validation**:
- Prevent directory traversal (../)
- Validate filenames (no special chars)
- Check file types before storage
- Scan for malicious content (if applicable)

### Privacy Considerations

**Location Data**:
- Coordinates reveal physical location
- Consider privacy before using exact coordinates
- Use approximate location or "online" if sensitive

**NOSTR Signatures**:
- npub links to public identity
- Comments are permanent and signed
- Consider privacy before signing

### Threat Mitigation

**File Upload Abuse**:
- Set maximum file sizes
- Limit total event size
- Validate file types
- Scan for malware

**Spam Prevention**:
- Rate limit likes and comments
- Require NOSTR signatures for actions
- Moderate content if needed

**Data Integrity**:
- Use NOSTR signatures
- Hash files for integrity checks
- Regular backups
- Validate on read

## Related Documentation

- [Blog Format Specification](../blog/blog-format-specification.md)
- [Chat Format Specification](../chat/chat-format-specification.md)
- [Forum Format Specification](../forum/forum-format-specification.md)
- [Collection File Formats](../others/file-formats.md)
- [NOSTR Protocol](https://github.com/nostr-protocol/nostr)

## Change Log

### Version 1.2 (2025-11-21)

**Major Features**:
- **Flyers**: Event artwork/poster support
  - Multiple flyer files (flyer.jpg, flyer-alt.png, etc.)
  - Flyer metadata file (flyer-info.txt)
  - Reactions on flyers
  - Prominent display in listings

- **Trailer**: Event promotional video
  - trailer.mp4 in event root
  - Optional trailer-info.txt metadata
  - Reactions on trailer
  - Auto-play and full-screen support

- **Event Updates**: Blog-like update system
  - updates/ directory with markdown files
  - Pre-event, during-event, and post-event updates
  - Only admins can post updates
  - Reactions on individual updates
  - Notifications for registered users

- **Registration**: Interest tracking system
  - registration.txt with GOING and INTERESTED sections
  - Callsign/npub pairs for verification
  - Privacy options (public, contacts_only, count_only)
  - Auto-notifications for registered users
  - Friend/contact integration

- **Links**: Relevant URL management
  - links.txt with structured link entries
  - Password and note fields for links
  - Category organization support
  - QR code generation
  - Link reactions for reporting issues

**File Structure Additions**:
- `flyer.jpg`, `flyer.png`, `flyer-*.{jpg,png,webp}`
- `flyer-info.txt` (optional metadata)
- `trailer.mp4`
- `trailer-info.txt` (optional metadata)
- `updates/` directory with `YYYY-MM-DD_title.md` files
- `registration.txt`
- `links.txt`

**UI Enhancements**:
- Flyer carousel/gallery display
- Video player for trailer
- Updates timeline/feed
- Going/Interested buttons
- Link cards with icons
- Notification system for registered users

### Version 1.1 (2025-11-21)

**Major Features**:
- **Multi-Day Events**: Support for events spanning multiple days
  - START_DATE and END_DATE fields
  - Automatic day folder creation (day1/, day2/, etc.)
  - Day-specific content organization
  - Reactions on day folders

- **Contributor Organization**: Individual contributor folders
  - contributors/CALLSIGN/ structure
  - contributor.txt metadata file
  - Reactions on contributor folders
  - Contributor-specific permissions

- **Enhanced Permissions System**: Multi-admin and moderator support
  - ADMINS field with multiple npub entries
  - MODERATORS field with multiple npub entries
  - Role-based permission hierarchy
  - Admin/moderator identified by npub for security

- **Moderation System**: Hide vs delete distinction
  - .hidden/ directory for hidden content
  - Hide comments and files without deletion
  - Moderation log tracking
  - Admin-only restore capability
  - Moderators can hide, only admins can delete

**Breaking Changes**:
- ADMINS and MODERATORS now use npub instead of callsigns
- Author remains identified by callsign for backwards compatibility

**Security Improvements**:
- Admins verified by npub
- Moderators verified by npub
- Cryptographic verification of roles
- Prevention of role impersonation

### Version 1.0 (2025-11-21)

- Initial specification
- Year-based organization
- Event folder structure
- Location support (coordinates and online)
- Unlimited files and photos
- Subfolder organization
- Granular reactions system (likes on events, files, subfolders)
- Granular comments system (comments on events, files, subfolders)
- Simple text format (no markdown)
- NOSTR signature integration
- Basic permission system (author-only)
