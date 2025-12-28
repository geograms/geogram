# Centralized Feedback API

**Version**: 1.4
**Status**: Active (implemented)
**Last Updated**: 2025-12-28

## Table of Contents

- [Introduction & Overview](#introduction--overview)
- [Content Type System](#content-type-system)
- [Folder Structure Specification](#folder-structure-specification)
- [Feedback Types](#feedback-types)
- [File Format Specifications](#file-format-specifications)
- [API Endpoints](#api-endpoints)
- [Subscription Notifications](#subscription-notifications)
- [NOSTR Message Format](#nostr-message-format)
- [Authentication & Authorization](#authentication--authorization)
- [Request/Response Examples](#requestresponse-examples)
- [Error Handling](#error-handling)
- [Migration Guide](#migration-guide)
- [Implementation Notes](#implementation-notes)

---

## Introduction & Overview

### Problem Statement

Currently, multiple Geogram apps implement feedback features independently:

- **Alerts**: Points, comments, verifications, and subscriptions under `feedback/`
- **Blog**: Has only comments, no likes or reactions
- **Forum**: Needs comments, likes, and reactions (not yet implemented)
- **Events**: Will need RSVPs, comments, and reactions (future)

This leads to:
- Code duplication across apps
- Inconsistent file structures (alert `points.txt` vs blog comments)
- Maintenance overhead
- Difficulty adding new feedback types

### Solution

A **centralized feedback API** that:
- Works across all content types (alerts, blog posts, forum threads, events, etc.)
- Uses a consistent folder structure: `{contentPath}/feedback/`
- Provides generic utilities and API endpoints
- Supports NOSTR-signed messages for authentication
- Enables incremental adoption by existing apps

### Benefits

1. **Code Reuse**: Write feedback logic once, use everywhere
2. **Consistency**: Same API and folder structure across all apps
3. **NOSTR Native**: Built for cryptographic authentication and future interoperability
4. **Extensibility**: Easy to add new feedback types (e.g., new emoji reactions)
5. **Maintainability**: Single source of truth for feedback operations

---

## Content Type System

### Supported Content Types

The feedback system is content-type agnostic. It works with:

| Content Type | Description | Example ID |
|--------------|-------------|------------|
| `alert` | Emergency reports and incident alerts | `2025-12-14_15-32_broken-sidewalk` |
| `blog` | Personal blog posts | `2025-12-04_hello-everyone` |
| `forum` | Forum threads and discussions | `2025-12-01_thread-title` |
| `event` | Community events and meetups | `2025-01-15_community-meetup` |
| `place` | Points of interest | `38.7223_-9.1393_cafe-central` |
| `service` | Service provider listings | `38.7223_-9.1393_john-repairs` |
| `market` | Marketplace listings | `2025-12-10_laptop-for-sale` |
| `custom:{appName}` | Custom app-specific content | `custom:myapp_{id}` |

### Content Identification

Each piece of content is uniquely identified by three components:

1. **Content Type**: The app/category (e.g., `blog`, `alert`)
2. **Content ID**: Unique identifier within that type (e.g., `2025-12-04_hello-everyone`)
3. **Owner Callsign**: The device/user who created it (e.g., `X1ABCD`)

### Visibility and Sync Behavior

Feedback sync is visibility-aware across apps:

- **Public content**: Feedback is sent to the station via `/api/feedback/...` and stored under `{contentPath}/feedback/`.
- **Group content**: Feedback is stored locally and replicated peer-to-peer within the group. Do not send to the station API.
- **Private content**: Feedback is stored locally only. Do not send to the station API.

If an app does not expose visibility controls, treat the content as public (station-synced).
If content is not present on the station, the feedback API will return `404 Content not found`.

### Path Resolution Examples

Feedback is stored relative to the content's base path:

```
Alert:
devices/X1ABCD/alerts/active/38.7_-9.1/2025-12-14_broken-sidewalk/feedback/

Blog:
devices/X1ABCD/blog/2025/2025-12-04_hello-everyone/feedback/

Forum:
devices/X1ABCD/forum/general/2025-12-01_thread-title/feedback/

Event:
devices/X1ABCD/events/2025/2025-01-15_community-meetup/feedback/

Service:
devices/X1ABCD/services/38.7_-9.1/38.7223_-9.1393_john-repairs/feedback/
```

---

## Folder Structure Specification

### Standard Feedback Folder

All content types use the same feedback folder structure:

```
{contentPath}/
├── {content-file}                 # Main content (report.txt, post.md, etc.)
├── files/                          # Attachments (optional)
└── feedback/                       # NEW: Centralized feedback folder
    ├── likes.txt                   # NOSTR npub, one per line
    ├── points.txt                  # NOSTR npub, one per line
    ├── dislikes.txt                # NOSTR npub, one per line
    ├── subscribe.txt               # NOSTR npub, one per line
    ├── verifications.txt           # NOSTR npub, one per line (add-only)
    ├── views.txt                   # Signed NOSTR events (JSON), multiple entries
    ├── heart.txt                   # Emoji reaction: npub per line
    ├── thumbs-up.txt               # Emoji reaction: npub per line
    ├── fire.txt                    # Emoji reaction: npub per line
    ├── celebrate.txt               # Emoji reaction: npub per line
    ├── laugh.txt                   # Emoji reaction: npub per line
    ├── sad.txt                     # Emoji reaction: npub per line
    ├── surprise.txt                # Emoji reaction: npub per line
    ├── comments/
    │   └── YYYY-MM-DD_HH-MM-SS_CALLSIGN.txt
    └── ratings/
        └── YYYY-MM-DD_HH-MM-SS_CALLSIGN.txt  # Rating with required comment
```

### Key Principles

1. **Flat Structure**: All feedback files stored directly in `feedback/` folder (no nested subfolders except comments)
2. **Npub per line**: Toggle feedback files store one npub per line; views remain signed JSON events
3. **Auto-cleanup**: Empty feedback files are automatically deleted
4. **Signature enforcement**: Signatures are verified on write; stored npub lines represent validated feedback

### Example: Blog Post with Feedback

```
devices/X1ABCD/blog/2025/2025-12-04_hello-everyone/
├── post.md                         # Main blog post content
├── files/                          # Optional attachments
│   └── abc123_document.pdf
└── feedback/
    ├── likes.txt                   # 15 events (15 likes)
    ├── heart.txt                   # 8 events (8 heart reactions)
    ├── thumbs-up.txt               # 12 events (12 thumbs up)
    ├── subscribe.txt               # 5 events (5 subscribers)
    ├── views.txt                   # 342 view events (87 unique viewers)
    └── comments/
        ├── 2025-12-04_15-30-45_X1ABCD.txt
        ├── 2025-12-04_16-20-12_X1EFGH.txt
        └── 2025-12-05_09-15-00_X1JKLM.txt
```

---

## Feedback Types

Toggle feedback files (likes, points, dislikes, subscribe, verifications, reactions) use **one npub per line**.
Views remain signed JSON event lines to preserve timestamps and analytics.

### Standard Feedback Types

#### 1. Likes (likes.txt)
- **Purpose**: Express general approval, support, or agreement
- **Use Case**: "I like this blog post" or "Good information"
- **UI**: Heart icon or "Like" button
- **Toggleable**: Yes (user can like/unlike)

#### 2. Points (points.txt)
- **Purpose**: Call attention to important content, flag for review
- **Use Case**: "This alert needs immediate attention" (primarily for alerts)
- **UI**: Flag icon or "Point" button
- **Toggleable**: Yes (user can point/unpoint)

#### 3. Dislikes (dislikes.txt)
- **Purpose**: Express disapproval or disagreement
- **Use Case**: "I disagree with this" or "Not helpful"
- **UI**: Thumbs down icon or "Dislike" button
- **Toggleable**: Yes (user can dislike/undislike)

#### 4. Subscribe (subscribe.txt)
- **Purpose**: Follow content for notifications about updates
- **Use Case**: "Notify me when someone comments" or "Follow this discussion"
- **UI**: Bell icon or "Subscribe" button
- **Toggleable**: Yes (user can subscribe/unsubscribe)

#### 5. Verifications (verifications.txt)
- **Purpose**: Confirm truth/validity of content (for verifiable content like alerts)
- **Use Case**: "I can verify this report is accurate"
- **UI**: Checkmark icon or "Verify" button
- **Toggleable**: No (once verified, cannot be unverified)
- **Applicable To**: Alerts, reports, factual content

### Metric Feedback Types

#### 6. Page Views (views.txt)
- **Purpose**: Track page views and content engagement metrics
- **Use Case**: "Track how many times this blog post has been viewed"
- **Behavior**: Multiple entries allowed (not a toggle)
- **Format**: One signed NOSTR event per line (JSON)
- **Tracking**:
  - Total view count (all views including repeats)
  - Unique viewer count (distinct npubs)
  - View timestamps for analytics
- **Applicable To**: Blog posts, forum threads, events, alerts, any content
- **Privacy**: Requires user authentication (npub/nsec) to record

**Key Differences from Toggle Feedback:**
- **Not Toggleable**: Each page view is recorded as a new event
- **Multiple Entries**: Same user can have multiple view events
- **Timestamped**: Each view includes Unix timestamp for analytics
- **Append-Only**: Views are never removed, only added
- **Analytics**: Supports metrics like view trends over time

**File Format** (views.txt):
```
{"id":"abc123...","pubkey":"def456...","created_at":1734912345,"kind":1,"tags":[["e","post-id"],["type","view"]],"content":"view","sig":"789xyz..."}
{"id":"ghi789...","pubkey":"jkl012...","created_at":1734912456,"kind":1,"tags":[["e","post-id"],["type","view"]],"content":"view","sig":"345mno..."}
{"id":"pqr345...","pubkey":"def456...","created_at":1734913567,"kind":1,"tags":[["e","post-id"],["type","view"]],"content":"view","sig":"678stu..."}
```

**View Statistics Available:**
- `total_views`: Total number of view events (including repeat views)
- `unique_viewers`: Number of distinct npubs who viewed
- `first_view`: Unix timestamp of first recorded view
- `latest_view`: Unix timestamp of most recent view

**Example Metrics:**
```
Total Views: 342
Unique Viewers: 87
First View: 2025-12-10 14:23:00 UTC
Latest View: 2025-12-23 09:45:12 UTC
Average Views per Viewer: 3.93
```

### Emoji Reactions

All emoji reactions follow the same pattern: one npub per line in `{emoji-name}.txt`

| Emoji | File | Purpose | Icon |
|-------|------|---------|------|
| Heart | `heart.txt` | Love, care, appreciation | ❤️ |
| Thumbs Up | `thumbs-up.txt` | Approval, agreement | 👍 |
| Fire | `fire.txt` | Excitement, impressive | 🔥 |
| Celebrate | `celebrate.txt` | Celebration, achievement | 🎉 |
| Laugh | `laugh.txt` | Humor, amusement | 😂 |
| Sad | `sad.txt` | Sympathy, sadness | 😢 |
| Surprise | `surprise.txt` | Surprise, shock | 😮 |

**Properties:**
- Users can have multiple different emoji reactions on the same content
- Each emoji type is toggleable independently
- Emoji reactions are additive (not mutually exclusive)

### Comments

**Storage**: `feedback/comments/` subdirectory
**Filename Format**: `YYYY-MM-DD_HH-MM-SS_CALLSIGN.txt`
- `YYYY-MM-DD`: Date of comment creation
- `HH-MM-SS`: Time of comment creation (24-hour format)
- `CALLSIGN`: Author callsign (e.g., `X1ABCD`)

**Example Filenames**:
```
comments/2025-12-14_15-30-45_X1ABCD.txt
comments/2025-12-14_16-20-12_X1EFGH.txt
comments/2025-12-15_09-15-00_X1JKLM.txt
```

**Purpose**: Detailed text feedback with NOSTR signatures
**Properties**: Flat structure (no threading), chronologically ordered

### Ratings

**Storage**: `feedback/ratings/` subdirectory
**Filename Format**: `YYYY-MM-DD_HH-MM-SS_CALLSIGN.txt`
- `YYYY-MM-DD`: Date of rating creation
- `HH-MM-SS`: Time of rating creation (24-hour format)
- `CALLSIGN`: Author callsign (e.g., `X1ABCD`)

**Example Filenames**:
```
ratings/2025-12-14_15-30-45_X1ABCD.txt
ratings/2025-12-20_10-15-30_Y2EFGH.txt
```

**Purpose**: Numeric rating (1-5 stars) with **required** comment
**Properties**:
- Rating value: 1 to 5 (integer)
- Comment is mandatory - ratings without comments are rejected
- One rating per user per content (replaces previous rating if exists)
- Content owner can delete any rating on their content
- Flat structure (no threading), chronologically ordered
- Used primarily for service providers, places, and review-based content

**Key Differences from Comments**:
- **Required**: Comment text is mandatory (cannot submit rating without comment)
- **One Per User**: Only one rating per user per content item (updates replace)
- **Numeric Value**: Includes 1-5 star rating value
- **Owner Deletable**: Content owner can delete any rating on their content

---

## File Format Specifications

### Feedback File Format (likes.txt, points.txt, etc.)

**Encoding**: UTF-8
**Line Ending**: Unix (`\n`)
**Format**: One npub per line (bech32)

**Example** (`likes.txt`):
```
npub1abc123def456ghi789jkl012mno345pqr678stu901vwx234yz567890
npub1def456ghi789jkl012mno345pqr678stu901vwx234yz567890abc12
```

**Rules**:
- No blank lines
- Each line is a valid `npub1...` bech32 key
- Signatures are verified on write; invalid events are rejected before storage
- Legacy JSON event lines are accepted for migration; only verified events are counted
- File is deleted automatically if it becomes empty

### Comment File Format

**File**: `feedback/comments/YYYY-MM-DD_HH-MM-SS_CALLSIGN.txt`

**Structure**:
```
AUTHOR: {CALLSIGN}
CREATED: YYYY-MM-DD HH:MM_ss

{Comment content here.
Can span multiple lines.}

--> npub: npub1...
--> signature: {hex_signature}
```

**Fields**:
1. **AUTHOR** (required): Callsign of comment author
2. **CREATED** (required): Timestamp in format `YYYY-MM-DD HH:MM_ss`
3. **Blank line** (required): Separates header from content
4. **Content** (required): Plain text comment (no markdown)
5. **Blank line** (optional): Separates content from signature
6. **npub** (optional): NOSTR public key for verification
7. **signature** (optional): Hex-encoded Schnorr signature

**Example**:
```
AUTHOR: X1ABCD
CREATED: 2025-12-14 15:30_45

This is a great blog post! I really enjoyed reading about your experience.

--> npub: npub1abc123def456ghi789jkl012mno345pqr678stu901vwx234yz567890
--> signature: 1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef
```

### Rating File Format

**File**: `feedback/ratings/YYYY-MM-DD_HH-MM-SS_CALLSIGN.txt`

**Structure**:
```
AUTHOR: {CALLSIGN}
CREATED: YYYY-MM-DD HH:MM_ss
RATING: {1-5}

{Comment content here - REQUIRED.
Can span multiple lines.
Must explain the rating.}

--> npub: npub1...
--> signature: {hex_signature}
```

**Fields**:
1. **AUTHOR** (required): Callsign of rating author
2. **CREATED** (required): Timestamp in format `YYYY-MM-DD HH:MM_ss`
3. **RATING** (required): Numeric value 1-5 (stars)
4. **Blank line** (required): Separates header from content
5. **Content** (required): Plain text comment explaining the rating
6. **Blank line** (optional): Separates content from signature
7. **npub** (optional): NOSTR public key for verification
8. **signature** (optional): Hex-encoded Schnorr signature

**Example**:
```
AUTHOR: X1ABCD
CREATED: 2025-12-14 15:30_45
RATING: 5

Excellent service! John fixed my plumbing issue quickly and professionally.
Very reasonable prices and he cleaned up after the work was done.
Highly recommend for any plumbing needs.

--> npub: npub1abc123def456ghi789jkl012mno345pqr678stu901vwx234yz567890
--> signature: 1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef
```

**Validation Rules**:
- RATING must be integer 1-5
- Content must not be empty (minimum 10 characters recommended)
- If user submits new rating, previous rating file is deleted and replaced
- Content owner can delete rating file directly

### NOSTR Signature Format

**npub Format**: `npub1` + 58 bech32 characters (total 63 characters)
**Signature Format**: 128-character hex string (64-byte Schnorr signature)

**Content to Sign** (for comments):

Comments use a standard NOSTR text note (kind 1). Clients should sign the full event (pubkey, created_at, kind, tags, content) and store the resulting `sig` alongside the comment.

**Recommended Verification**:
```dart
final event = NostrEvent(
  pubkey: pubkeyHex,
  createdAt: createdAt,
  kind: NostrEventKind.textNote,
  tags: [
    ['content_type', contentType],
    ['content_id', contentId],
    ['action', 'comment'],
    ['owner', author],
  ],
  content: content,
  sig: signature,
);
event.calculateId();
final isValid = event.verify();
```

---

## API Endpoints

### Base Pattern

All feedback endpoints follow this pattern:

```
POST /api/feedback/{contentType}/{contentId}/{action}
GET  /api/feedback/{contentType}/{contentId}
```

### Endpoint: Toggle Feedback

**Pattern**: `POST /api/feedback/{contentType}/{contentId}/{feedbackType}`

Supported feedback types: `like`, `point`, `dislike`, `subscribe`, `react/{emoji}` (toggle) and `verify` (add-only)

#### Like Content

**Endpoint**: `POST /api/feedback/{contentType}/{contentId}/like`

**Request Body**:
```json
{
  "id": "e8c4...",
  "pubkey": "3bf0c63f...",
  "created_at": 1734864600,
  "kind": 7,
  "tags": [
    ["content_type", "blog"],
    ["content_id", "2025-12-04_hello-everyone"],
    ["action", "like"],
    ["owner", "X1ABCD"],
    ["type", "likes"]
  ],
  "content": "like",
  "sig": "abc123..."
}
```

**Response** (Success - 200):
```json
{
  "success": true,
  "action": "added",
  "liked": true,
  "like_count": 42,
  "timestamp": "2025-12-22T10:30:00Z"
}
```

**Response** (Removed):
```json
{
  "success": true,
  "action": "removed",
  "liked": false,
  "like_count": 41,
  "timestamp": "2025-12-22T10:30:00Z"
}
```

#### Point Content

**Endpoint**: `POST /api/feedback/{contentType}/{contentId}/point`

Same format as `/like`, returns `pointed` and `point_count`.

#### Dislike Content

**Endpoint**: `POST /api/feedback/{contentType}/{contentId}/dislike`

Same format as `/like`, returns `disliked` and `dislike_count`.

#### Subscribe to Content

**Endpoint**: `POST /api/feedback/{contentType}/{contentId}/subscribe`

**Request Body**:
```json
{
  "id": "a9d1...",
  "pubkey": "7aa1e5d9...",
  "created_at": 1734864800,
  "kind": 30078,
  "tags": [
    ["content_type", "forum"],
    ["content_id", "2025-12-01_discussion-thread"],
    ["action", "subscribe"],
    ["owner", "X1ABCD"]
  ],
  "content": "subscribe",
  "sig": "def456..."
}
```

**Response**:
```json
{
  "success": true,
  "subscribed": true,
  "subscriber_count": 8,
  "timestamp": "2025-12-22T10:30:00Z"
}
```

#### React with Emoji

**Endpoint**: `POST /api/feedback/{contentType}/{contentId}/react/{emoji}`

Supported emojis: `heart`, `thumbs-up`, `fire`, `celebrate`, `laugh`, `sad`, `surprise`

**Request Body**:
```json
{
  "id": "f2b7...",
  "pubkey": "3bf0c63f...",
  "created_at": 1734865000,
  "kind": 7,
  "tags": [
    ["content_type", "alert"],
    ["content_id", "2025-12-14_broken-sidewalk"],
    ["action", "react"],
    ["owner", "X1ABCD"],
    ["type", "heart"]
  ],
  "content": "heart",
  "sig": "789xyz..."
}
```

**Response**:
```json
{
  "success": true,
  "action": "added",
  "reacted": true,
  "reaction": "heart",
  "reaction_count": 15,
  "timestamp": "2025-12-22T10:30:00Z"
}
```

#### Verify Content

**Endpoint**: `POST /api/feedback/{contentType}/{contentId}/verify`

**Request Body**:
```json
{
  "npub": "npub1abc123...",
  "comment": "I can confirm this report is accurate"
}
```

**Response**:
```json
{
  "success": true,
  "verified": true,
  "verification_count": 5,
  "timestamp": "2025-12-22T10:30:00Z"
}
```

**Note**: Verifications are immutable - once verified, cannot be unverified.

### Endpoint: Record Page View

**Endpoint**: `POST /api/feedback/{contentType}/{contentId}/view`

**Purpose**: Track page views for analytics and engagement metrics.

**Request Body**:
```json
{
  "id": "abc123...",
  "pubkey": "def456...",
  "created_at": 1734912345,
  "kind": 1,
  "tags": [
    ["e", "2025-12-04_hello-everyone"],
    ["type", "view"]
  ],
  "content": "view",
  "sig": "789xyz..."
}
```

**Response** (Success - 200):
```json
{
  "success": true,
  "view_recorded": true,
  "total_views": 343,
  "unique_viewers": 87,
  "timestamp": "2025-12-23T10:30:00Z"
}
```

**Response** (Invalid Signature - 401):
```json
{
  "error": "Invalid signature",
  "message": "NOSTR event signature verification failed"
}
```

**Key Differences from Toggle Feedback:**
- Multiple views from same user are allowed (append-only)
- No "toggle" or "remove" action - views are permanent
- Returns both total views and unique viewer count
- Uses NOSTR event format (not just npub) for full auditability

**Example Flow**:
```dart
// Client side: Create and sign view event
final pubkeyHex = NostrCrypto.decodeNpub(npub);
final viewEvent = NostrEvent(
  pubkey: pubkeyHex,
  createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
  kind: 1,
  tags: [
    ['e', postId],
    ['type', 'view'],
  ],
  content: 'view',
);
viewEvent.calculateId();
viewEvent.signWithNsec(nsec);

// Send to API
final response = await http.post(
  Uri.parse('http://localhost:17000/api/feedback/blog/$postId/view'),
  headers: {'Content-Type': 'application/json'},
  body: jsonEncode(viewEvent.toJson()),
);
```

**View Statistics Endpoint**:

**Endpoint**: `GET /api/feedback/{contentType}/{contentId}/stats`

**Response**:
```json
{
  "total_views": 342,
  "unique_viewers": 87,
  "first_view": 1733846580,
  "latest_view": 1734912345,
  "likes": 15,
  "comments": 3,
  "reactions": {
    "heart": 8,
    "thumbs-up": 12,
    "fire": 5
  }
}
```

### Endpoint: Add Comment

**Endpoint**: `POST /api/feedback/{contentType}/{contentId}/comment`

**Request Body**:
```json
{
  "author": "X1ABCD",
  "content": "This is my comment...",
  "npub": "npub1abc123...",
  "signature": "1234567890abcdef..."
}
```

**Response**:
```json
{
  "success": true,
  "comment_id": "2025-12-22_10-30-45_X1ABCD",
  "timestamp": "2025-12-22T10:30:45Z"
}
```

### Endpoint: Add/Update Rating

**Endpoint**: `POST /api/feedback/{contentType}/{contentId}/rating`

**Purpose**: Submit a rating with required comment. Replaces any existing rating from the same user.

**Request Body**:
```json
{
  "author": "X1ABCD",
  "rating": 5,
  "content": "Excellent service! John fixed my plumbing issue quickly and professionally.",
  "npub": "npub1abc123...",
  "signature": "1234567890abcdef..."
}
```

**Required Fields**:
- `author`: Callsign of the rating author
- `rating`: Integer 1-5 (stars)
- `content`: Comment text explaining the rating (minimum 10 characters)

**Optional Fields**:
- `npub`: NOSTR public key for verification
- `signature`: Hex-encoded Schnorr signature

**Response** (Success - 200):
```json
{
  "success": true,
  "rating_id": "2025-12-22_10-30-45_X1ABCD",
  "action": "created",
  "average_rating": 4.5,
  "rating_count": 12,
  "timestamp": "2025-12-22T10:30:45Z"
}
```

**Response** (Updated existing - 200):
```json
{
  "success": true,
  "rating_id": "2025-12-22_10-30-45_X1ABCD",
  "action": "updated",
  "previous_rating": 3,
  "new_rating": 5,
  "average_rating": 4.6,
  "rating_count": 12,
  "timestamp": "2025-12-22T10:30:45Z"
}
```

**Response** (Missing comment - 400):
```json
{
  "success": false,
  "error": "missing_comment",
  "message": "Rating must include a comment explaining the rating",
  "details": {
    "field": "content",
    "suggestion": "Provide a comment with at least 10 characters"
  }
}
```

### Endpoint: Get Ratings

**Endpoint**: `GET /api/feedback/{contentType}/{contentId}/ratings`

**Query Parameters**:
- `limit` (optional): Max ratings to return (default: 20)
- `offset` (optional): Pagination offset (default: 0)
- `sort` (optional): Sort order - `newest`, `oldest`, `highest`, `lowest` (default: `newest`)

**Response**:
```json
{
  "success": true,
  "content_id": "38.7223_-9.1393_john-repairs",
  "content_type": "service",
  "average_rating": 4.5,
  "rating_count": 12,
  "rating_distribution": {
    "5": 7,
    "4": 3,
    "3": 1,
    "2": 0,
    "1": 1
  },
  "ratings": [
    {
      "id": "2025-12-22_10-30-45_X1ABCD",
      "author": "X1ABCD",
      "rating": 5,
      "created": "2025-12-22 10:30_45",
      "content": "Excellent service! John fixed my plumbing issue quickly.",
      "npub": "npub1abc123...",
      "has_signature": true
    },
    {
      "id": "2025-12-20_14-15-30_Y2EFGH",
      "author": "Y2EFGH",
      "rating": 4,
      "created": "2025-12-20 14:15_30",
      "content": "Good work, slightly delayed but quality was great.",
      "npub": "npub1xyz987...",
      "has_signature": true
    }
  ],
  "timestamp": "2025-12-22T10:35:00Z"
}
```

### Endpoint: Delete Rating

**Endpoint**: `DELETE /api/feedback/{contentType}/{contentId}/rating/{ratingId}`

**Purpose**: Delete a rating. Can be done by the rating author OR the content owner.

**Request Body** (for authentication):
```json
{
  "npub": "npub1abc123...",
  "signature": "1234567890abcdef..."
}
```

**Authorization**:
- **Rating author**: Can delete their own rating
- **Content owner**: Can delete ANY rating on their content (for moderation)

**Response** (Success - 200):
```json
{
  "success": true,
  "action": "deleted",
  "rating_id": "2025-12-22_10-30-45_X1ABCD",
  "deleted_by": "owner",
  "average_rating": 4.3,
  "rating_count": 11,
  "timestamp": "2025-12-22T11:00:00Z"
}
```

**Response** (Forbidden - 403):
```json
{
  "success": false,
  "error": "forbidden",
  "message": "Only the rating author or content owner can delete this rating",
  "details": {
    "rating_author": "X1ABCD",
    "content_owner": "Y2EFGH"
  }
}
```

---

### Subscription Notifications

Subscriptions are stored in `feedback/subscribe.txt` and toggled via:

```
POST /api/feedback/{contentType}/{contentId}/subscribe
```

When content changes, the item owner can notify all current subscribers.

#### Endpoint: Notify Subscribers (Owner/Admin)

**Endpoint**: `POST /api/feedback/{contentType}/{contentId}/notify`

**Purpose**: Fan-out a notification to all subscribers of a content item.

**Request Body** (NOSTR-signed event):
```json
{
  "id": "9f1a...",
  "pubkey": "3bf0c63f...",
  "created_at": 1734865200,
  "kind": 1,
  "tags": [
    ["content_type", "event"],
    ["content_id", "2025-01-15_community-meetup"],
    ["action", "notify"],
    ["owner", "X1ABCD"]
  ],
  "content": "update: Agenda updated and photos added",
  "sig": "abc123..."
}
```

**Response**:
```json
{
  "success": true,
  "notification_id": "2025-12-22_10-30-00_X1ABCD",
  "subscriber_count": 24,
  "delivered_online": 7,
  "timestamp": "2025-12-22T10:30:00Z"
}
```

**Realtime Delivery**:
For each connected subscriber, the station sends a lightweight WebSocket update:

```
UPDATE:{ownerCallsign}/{collectionType}/{contentId}
```

Example:
```
UPDATE:X1ABCD/events/2025-01-15_community-meetup
```

`collectionType` is the collection folder name (alerts/events/places/blog/forum/etc).

Clients should increment a per-app unread counter (similar to chat) and clear it
when the user opens the item.

**Visibility Rules**:
- **Public**: notify via station API.
- **Group**: do not use station API; notify within the group channel or P2P sync.
- **Private**: local-only, no station notification.

### Endpoint: Get All Feedback

**Endpoint**: `GET /api/feedback/{contentType}/{contentId}`

**Query Parameters**:
- `npub` (optional): User's npub to get personalized state
- `include_comments` (optional): Set to `true` to include comment list (default: `false`)
- `comment_limit` (optional): Max comments to return (default: 20)
- `comment_offset` (optional): Comment pagination offset (default: 0)

**Response**:
```json
{
  "success": true,
  "content_id": "2025-12-04_hello-everyone",
  "content_type": "blog",
  "counts": {
    "likes": 42,
    "points": 8,
    "dislikes": 2,
    "subscribe": 15,
    "verifications": 0,
    "heart": 23,
    "thumbs_up": 18,
    "fire": 12,
    "celebrate": 5,
    "laugh": 3,
    "sad": 0,
    "surprise": 1,
    "comments": 27,
    "ratings": 12,
    "average_rating": 4.5
  },
  "user_state": {
    "liked": true,
    "pointed": false,
    "disliked": false,
    "subscribed": true,
    "verified": false,
    "heart": true,
    "thumbs_up": false,
    "fire": false,
    "celebrate": false,
    "laugh": false,
    "sad": false,
    "surprise": false,
    "has_rated": true,
    "user_rating": 5
  },
  "comments": [
    {
      "id": "2025-12-22_10-30-45_X1ABCD",
      "author": "X1ABCD",
      "created": "2025-12-22 10:30_45",
      "content": "Great post!",
      "npub": "npub1abc123...",
      "has_signature": true
    }
  ],
  "timestamp": "2025-12-22T10:30:00Z"
}
```

---

## NOSTR Message Format

Feedback actions are signed NOSTR events for cryptographic verification and relay propagation.

### Event Kinds

| Action | NOSTR Kind | Description |
|--------|------------|-------------|
| Like, Point, Dislike, React | 7 | Reaction event (NIP-25) |
| Comment, View, Notify, Rating | 1 | Text note (NIP-01) |
| Subscribe, Verify | 30078 | Application-specific data (NIP-78) |

### Event Structure for Reactions

**Kind 7** (Reaction):

```json
{
  "kind": 7,
  "pubkey": "{hex_pubkey}",
  "created_at": 1734864600,
  "tags": [
    ["content_type", "blog"],
    ["content_id", "2025-12-04_hello-everyone"],
    ["action", "like"],
    ["owner", "X1ABCD"],
    ["type", "likes"]
  ],
  "content": "like",
  "sig": "{hex_signature}"
}
```

### Event Structure for Comments

**Kind 1** (Text Note):

```json
{
  "kind": 1,
  "pubkey": "{hex_pubkey}",
  "created_at": 1734864600,
  "tags": [
    ["content_type", "blog"],
    ["content_id", "2025-12-04_hello-everyone"],
    ["action", "comment"],
    ["owner", "X1ABCD"]
  ],
  "content": "This is my comment...",
  "sig": "{hex_signature}"
}
```

### Event Structure for Ratings

**Kind 1** (Text Note with rating tag):

```json
{
  "kind": 1,
  "pubkey": "{hex_pubkey}",
  "created_at": 1734864600,
  "tags": [
    ["content_type", "service"],
    ["content_id", "38.7223_-9.1393_john-repairs"],
    ["action", "rating"],
    ["owner", "X1ABCD"],
    ["rating", "5"]
  ],
  "content": "Excellent service! John fixed my plumbing issue quickly and professionally.",
  "sig": "{hex_signature}"
}
```

**Note**: The `["rating", "{1-5}"]` tag is required and contains the numeric rating value as a string.

### Event Structure for Subscribe/Verify

**Kind 30078** (Application Data):

```json
{
  "kind": 30078,
  "pubkey": "{hex_pubkey}",
  "created_at": 1734864600,
  "tags": [
    ["content_type", "blog"],
    ["content_id", "2025-12-04_hello-everyone"],
    ["action", "subscribe"],
    ["owner", "X1ABCD"]
  ],
  "content": "subscribe",
  "sig": "{hex_signature}"
}
```

### Required Tags

All feedback events MUST include these tags:

- `["content_type", "{type}"]` - The content type (blog, alert, etc.)
- `["content_id", "{id}"]` - The content identifier
- `["action", "{action}"]` - The feedback action (like, comment, view, verify, etc.)
- `["owner", "{callsign}"]` - The feedback author's callsign

Optional tags:
- `["type", "{feedbackType}"]` - The feedback file target (likes, points, heart, etc.)
- `["e", "{event_id}"]` - Reference to original content event (if available)

---

## Authentication & Authorization

### Permission Levels

| Permission Level | Can Do |
|------------------|--------|
| **Public** (any authenticated user) | Add likes, points, dislikes, emoji reactions, comments, ratings, subscriptions |
| **Author** (comment/rating author) | Delete own comments, delete own ratings |
| **Content Owner** (content creator) | Delete any comment on their content, delete any rating on their content, notify subscribers |
| **Admin** (system admin) | All permissions, bulk operations |

### NOSTR Signature Verification

**All feedback actions except comments MUST include NOSTR signatures** for:
- Audit trail and accountability
- Spam prevention
- Future relay synchronization
- Cryptographic proof of authorship

**Signature Verification Process**:
1. Extract `npub` and `signature` from request
2. Reconstruct the signed content (varies by feedback type)
3. Convert npub to hex public key
4. Verify using BIP-340 Schnorr signature verification
5. Accept if valid, reject with 422 if invalid

Comments SHOULD include signatures as well, but the server stores unsigned comments if provided.

### Rate Limiting

| Action | Limit |
|--------|-------|
| **Comments** | 10 per hour, 100 per day per user |
| **Ratings** | 1 per content per user (updates replace previous) |
| **Likes/Reactions** | Unlimited toggles |
| **Points** | Unlimited toggles |
| **Subscriptions** | Unlimited toggles |
| **Verifications** | 1 per content per user (immutable) |

### Authorization Rules

1. **Anyone** can add feedback to published content
2. **Only the author** can delete their own comments
3. **Only the author** can delete their own ratings
4. **Only the content owner** can delete comments on their content
5. **Only the content owner** can delete ratings on their content (for moderation)
6. **Ratings require comments** - a rating without a comment is rejected
7. **One rating per user** - submitting a new rating replaces the previous one
8. **Verifications are immutable** - cannot be removed once added
9. **Only content owners** can send subscriber notifications
10. **Rate limits apply** to prevent spam

---

## Request/Response Examples

### Example 1: Like a Blog Post

**Request**:
```http
POST /api/feedback/blog/2025-12-04_hello-everyone/like
Content-Type: application/json

{
  "id": "e8c4...",
  "pubkey": "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d",
  "created_at": 1734864600,
  "kind": 7,
  "tags": [
    ["content_type", "blog"],
    ["content_id", "2025-12-04_hello-everyone"],
    ["action", "like"],
    ["owner", "X1ABCD"],
    ["type", "likes"]
  ],
  "content": "like",
  "sig": "abc123..."
}
```

**Response** (200 OK):
```json
{
  "success": true,
  "action": "added",
  "liked": true,
  "like_count": 43,
  "timestamp": "2025-12-22T10:30:00Z"
}
```

### Example 2: Add Heart Reaction

**Request**:
```http
POST /api/feedback/alert/2025-12-14_broken-sidewalk/react/heart
Content-Type: application/json

{
  "id": "f2b7...",
  "pubkey": "7aa1e5d9b9cbfd4a8b2e1d5b0c8f2a3c9b8b0d3a1c2d4e5f6a7b8c9d0e1f2a3b",
  "created_at": 1734864700,
  "kind": 7,
  "tags": [
    ["content_type", "alert"],
    ["content_id", "2025-12-14_broken-sidewalk"],
    ["action", "react"],
    ["owner", "X1EFGH"],
    ["type", "heart"]
  ],
  "content": "heart",
  "sig": "789xyz..."
}
```

**Response** (200 OK):
```json
{
  "success": true,
  "action": "added",
  "reacted": true,
  "reaction": "heart",
  "reaction_count": 16,
  "timestamp": "2025-12-22T10:31:00Z"
}
```

### Example 3: Add Comment with Signature

**Request**:
```http
POST /api/feedback/blog/2025-12-04_hello-everyone/comment
Content-Type: application/json

{
  "author": "X1ABCD",
  "content": "Great insights! I especially liked the part about mesh networking.",
  "npub": "npub1abc123def456ghi789jkl012mno345pqr678stu901vwx234yz567890",
  "signature": "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
}
```

**Response** (200 OK):
```json
{
  "success": true,
  "comment_id": "2025-12-22_10-32-15_X1ABCD",
  "timestamp": "2025-12-22T10:32:15Z"
}
```

### Example 4: Subscribe to Content

**Request**:
```http
POST /api/feedback/forum/2025-12-01_discussion-thread/subscribe
Content-Type: application/json

{
  "id": "a9d1...",
  "pubkey": "9f1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c",
  "created_at": 1734864800,
  "kind": 30078,
  "tags": [
    ["content_type", "forum"],
    ["content_id", "2025-12-01_discussion-thread"],
    ["action", "subscribe"],
    ["owner", "X1JKLM"]
  ],
  "content": "subscribe",
  "sig": "def456..."
}
```

**Response** (200 OK):
```json
{
  "success": true,
  "subscribed": true,
  "subscriber_count": 24,
  "timestamp": "2025-12-22T10:33:00Z"
}
```

### Example 5: Record Page View

**Request**:
```http
POST /api/feedback/blog/2025-12-04_hello-everyone/view
Content-Type: application/json

{
  "id": "a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6q7r8s9t0u1v2w3x4y5z6a7b8c9d0e1f2",
  "pubkey": "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d",
  "created_at": 1734912345,
  "kind": 1,
  "tags": [
    ["e", "2025-12-04_hello-everyone"],
    ["type", "view"]
  ],
  "content": "view",
  "sig": "30440220abc123def456ghi789jkl012mno345pqr678stu901vwx234yz567890abc123def456ghi789jkl012mno345pqr678stu901vwx234yz567890abc123de"
}
```

**Response** (200 OK):
```json
{
  "success": true,
  "view_recorded": true,
  "total_views": 343,
  "unique_viewers": 87,
  "timestamp": "2025-12-23T10:30:00Z"
}
```

**Notes**:
- Page views are append-only (no toggle behavior)
- Same user can record multiple views
- Each view must be a signed NOSTR event
- Returns both total views and unique viewer count
- Useful for analytics and engagement tracking

### Example 6: Get All Feedback

**Request**:
```http
GET /api/feedback/blog/2025-12-04_hello-everyone?npub=npub1abc123...&include_comments=true&comment_limit=5
```

**Response** (200 OK):
```json
{
  "success": true,
  "content_id": "2025-12-04_hello-everyone",
  "content_type": "blog",
  "counts": {
    "likes": 43,
    "points": 8,
    "dislikes": 1,
    "subscribe": 16,
    "verifications": 0,
    "heart": 24,
    "thumbs_up": 19,
    "fire": 13,
    "celebrate": 6,
    "laugh": 4,
    "sad": 0,
    "surprise": 2,
    "comments": 28
  },
  "user_state": {
    "liked": true,
    "pointed": false,
    "disliked": false,
    "subscribed": true,
    "verified": false,
    "heart": true,
    "thumbs_up": false,
    "fire": false,
    "celebrate": false,
    "laugh": false,
    "sad": false,
    "surprise": false
  },
  "comments": [
    {
      "id": "2025-12-22_10-32-15_X1ABCD",
      "author": "X1ABCD",
      "created": "2025-12-22 10:32_15",
      "content": "Great insights! I especially liked the part about mesh networking.",
      "npub": "npub1abc123...",
      "has_signature": true
    },
    {
      "id": "2025-12-21_14-20-30_Y2EFGH",
      "author": "Y2EFGH",
      "created": "2025-12-21 14:20_30",
      "content": "Thanks for sharing!",
      "npub": "npub1xyz987...",
      "has_signature": true
    }
  ],
  "timestamp": "2025-12-22T10:35:00Z"
}
```

---

## Error Handling

### Standard Error Codes

| Code | Error Type | Description |
|------|------------|-------------|
| 400 | Bad Request | Missing required fields or invalid parameters |
| 401 | Unauthorized | Missing authentication (npub required) |
| 403 | Forbidden | Insufficient permissions for this action |
| 404 | Not Found | Content not found |
| 422 | Unprocessable Entity | Invalid NOSTR signature or malformed data |
| 429 | Too Many Requests | Rate limit exceeded |
| 500 | Internal Server Error | Server-side error |

### Error Response Format

All errors return this structure:

```json
{
  "success": false,
  "error": "error_type",
  "message": "Human-readable error message",
  "details": {
    "field": "Additional context",
    "suggestion": "How to fix this error"
  },
  "timestamp": "2025-12-22T10:30:00Z"
}
```

### Example Error Responses

#### 400 Bad Request (Missing Field)

```json
{
  "success": false,
  "error": "missing_field",
  "message": "Required field 'author' is missing",
  "details": {
    "field": "author",
    "suggestion": "Include 'author' field in request body"
  },
  "timestamp": "2025-12-22T10:30:00Z"
}
```

#### 404 Not Found

```json
{
  "success": false,
  "error": "content_not_found",
  "message": "Content 'blog/2025-12-99_nonexistent' not found",
  "details": {
    "content_type": "blog",
    "content_id": "2025-12-99_nonexistent"
  },
  "timestamp": "2025-12-22T10:30:00Z"
}
```

#### 422 Invalid Signature

```json
{
  "success": false,
  "error": "invalid_signature",
  "message": "NOSTR signature verification failed",
  "details": {
    "npub": "npub1abc123...",
    "suggestion": "Ensure signature was created for this exact content"
  },
  "timestamp": "2025-12-22T10:30:00Z"
}
```

#### 429 Rate Limit Exceeded

```json
{
  "success": false,
  "error": "rate_limit_exceeded",
  "message": "Comment rate limit exceeded: 10 per hour",
  "details": {
    "limit": "10 per hour",
    "retry_after": "2025-12-22T11:30:00Z",
    "suggestion": "Wait 25 minutes before posting another comment"
  },
  "timestamp": "2025-12-22T10:30:00Z"
}
```

---

## Migration Guide

The centralized feedback API assumes data lives under `{contentPath}/feedback/` and uses npub-per-line toggle files plus JSON event files for views. Legacy feedback locations are out of scope for this specification; new apps should not implement dual-read logic.

---

## Implementation Notes

### Repository Implementation

The centralized feedback system is implemented in the shared libraries and API handlers:

- **Server endpoints**: `lib/services/station_feedback_api.dart` (wired in `lib/services/station_server_service.dart` and `lib/cli/pure_station.dart`)
- **Storage utilities**: `lib/util/feedback_folder_utils.dart` and `lib/util/feedback_comment_utils.dart`
- **Client usage**: `lib/services/alert_feedback_service.dart` and `lib/services/blog_comment_service.dart` post signed events to `/api/feedback/...`
- **Client persistence rule**: For toggle feedback (like/point/dislike/subscribe/react), only persist the local feedback file after the station returns `success: true`. Use the response fields (`action`, `liked`, `like_count`, etc.) as the source of truth; do not apply optimistic local toggles.

### Concurrency & Race Condition Prevention

**Problem**: Multiple concurrent HTTP requests can create race conditions in feedback operations, allowing duplicate feedback from the same user.

#### The Race Condition Vulnerability

When multiple requests attempt to add feedback from the same user simultaneously:

```
Timeline:
T0: Request A reads file (user not found)
T1: Request B reads file (user not found) ← Same state!
T2: Request A adds npub, writes file
T3: Request B adds npub, writes file ← DUPLICATE!
```

**Result**: User's npub appears twice in the file, inflating counts and violating the design requirement that users cannot send multiple likes/dislikes to the same content.

#### Solution: File-Based Locking

The `FeedbackFolderUtils` class implements file-based locking to make read-modify-write operations atomic:

```dart
/// Simple file-based lock for atomic feedback operations.
class _FileLock {
  final String lockFilePath;
  static const int maxWaitMs = 5000;
  static const int retryDelayMs = 50;

  _FileLock(String feedbackFilePath) : lockFilePath = '$feedbackFilePath.lock';

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
```

#### Protected Operations

All feedback modification methods use locking:

1. **toggleFeedbackEvent()** - Add/remove feedback atomically
2. **addFeedbackEvent()** - Add feedback only if not present
3. **removeFeedbackEvent()** - Remove feedback atomically

Example usage:

```dart
static Future<bool?> toggleFeedbackEvent(
  String contentPath,
  String feedbackType,
  NostrEvent event,
) async {
  // Verify signature before processing
  if (!event.verify()) {
    return null;
  }

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
```

#### Test Verification

The race condition fix is validated by `tests/feedback_race_condition_test.dart`:

**Test 1: Concurrent Duplicate Prevention**
- Launches 10 concurrent requests to add the same user's like
- **Expected**: Only 1 succeeds (9 are blocked by locking)
- **Result**: File contains exactly 1 npub (no duplicates)

**Test 2: Concurrent Toggle**
- Launches 20 concurrent toggle requests from same user
- **Expected**: Final state is 0 or 1 npub (no duplicates)
- **Result**: Toggle count matches file state (integrity maintained)

**Test 3: Multiple Users Concurrent**
- 5 different users add feedback simultaneously
- **Expected**: All 5 succeed (different users don't block each other)
- **Result**: File contains 5 unique npubs

#### Lock File Behavior

- **Lock file location**: `{feedbackFilePath}.lock` (e.g., `feedback/likes.txt.lock`)
- **Acquisition timeout**: 5 seconds (returns null on timeout)
- **Retry interval**: 50ms between lock attempts
- **Cleanup**: Lock file automatically deleted in `finally` block
- **Stale locks**: If process crashes, lock file may persist (manual cleanup needed)

#### Performance Implications

- **Best case**: No contention, lock acquired immediately (~1ms overhead)
- **Average case**: 2-3 concurrent requests, wait ~50-100ms
- **Worst case**: Lock timeout at 5 seconds (very unlikely in normal usage)
- **Throughput**: Sequential processing of feedback for same content item

**Note**: Lock contention only occurs when multiple requests modify the **same** feedback file (e.g., `likes.txt` for post X). Different posts or different feedback types are not affected.

---

### Best Practices

1. **Atomic Writes**: Always write to temporary file first, then rename
   ```dart
   final tempFile = File('$path.tmp');
   await tempFile.writeAsString(content);
   await tempFile.rename(path);
   ```

2. **UTF-8 Encoding**: Always use UTF-8 for all text files
   ```dart
   await file.writeAsString(content, encoding: utf8, flush: true);
   ```

3. **File Locks**: Use file locking for concurrent write operations to prevent race conditions

4. **Validation**: Always validate npub format before writing
   ```dart
   bool isValidNpub(String npub) {
     return npub.startsWith('npub1') && npub.length == 63;
   }
   ```

5. **Auto-Cleanup**: Delete empty feedback files automatically
   ```dart
   if (npubs.isEmpty && await file.exists()) {
     await file.delete();
   }
   ```

### Performance Optimization

1. **Caching Counts**: Cache feedback counts in memory with 5-minute TTL
   ```dart
   final cache = <String, CachedCount>{};

   Future<int> getCachedCount(String path, String type) async {
     final key = '$path/$type';
     final cached = cache[key];
     if (cached != null && DateTime.now().difference(cached.timestamp) < Duration(minutes: 5)) {
       return cached.count;
     }
     final count = await FeedbackFolderUtils.getFeedbackCount(path, type);
     cache[key] = CachedCount(count, DateTime.now());
     return count;
   }
   ```

2. **Pagination**: Always paginate comment listings (20-50 per page)

3. **Lazy Loading**: Don't load comment content until needed, only load metadata for lists

4. **File Size Proxy**: Use file size as count proxy without reading
   ```dart
   final fileSize = await file.length();
   final approxCount = fileSize ~/ 65; // Each npub ≈ 65 bytes (63 + newline + rounding)
   ```

### Storage Efficiency

**Estimated Storage per Content**:
- 1,000 likes: ~65 KB (likes.txt)
- 100 comments: ~50 KB (comment files)
- All reactions: ~500 KB (with 1,000 users)
- 10,000 page views: ~2.5 MB (views.txt with full NOSTR events)
- **Total**: ~3-5 MB per popular content item

**Limits**:
- Max 15,000 npubs per feedback file (~1 MB)
- Max 10,000 comments per content (UX limit, not technical)
- Max 100,000 page views per content (~25 MB)
- Total feedback: <50 MB per content item

**Cleanup**:
- Delete empty feedback files automatically
- Archive old subscriptions after 1 year
- Remove comments from deleted content
- Archive old page views (keep only last 90 days for analytics)

### Page View Tracking Usage

Page views are a special metric feedback type that allows multiple entries per user (append-only). Use the `FeedbackFolderUtils` library to record and analyze page views.

#### Recording Page Views

**Client-Side Implementation:**

```dart
import 'package:geogram_desktop/util/feedback_folder_utils.dart';
import 'package:geogram_desktop/util/nostr_event.dart';
import 'package:geogram_desktop/util/nostr_crypto.dart';

/// Record a page view when user opens a blog post
Future<void> recordPageView(String postId, String npub, String nsec) async {
  // Get content path
  final contentPath = BlogFolderUtils.buildPostPath(postId);

  // Create signed view event
  final pubkeyHex = NostrCrypto.decodeNpub(npub);
  final viewEvent = NostrEvent(
    pubkey: pubkeyHex,
    createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    kind: 1, // Text note (NIP-01)
    tags: [
      ['e', postId],  // Reference to content
      ['type', 'view'],  // Tag as view event
    ],
    content: 'view',
  );

  // Calculate ID and sign
  viewEvent.calculateId();
  viewEvent.signWithNsec(nsec);

  // Record view
  final success = await FeedbackFolderUtils.recordViewEvent(
    contentPath,
    viewEvent,
  );

  if (success) {
    print('Page view recorded for post $postId');
  } else {
    print('Failed to record page view (invalid signature)');
  }
}
```

#### Retrieving View Statistics

```dart
/// Get view statistics for a blog post
Future<void> showViewStats(String postId) async {
  final contentPath = BlogFolderUtils.buildPostPath(postId);

  // Get comprehensive view statistics
  final stats = await FeedbackFolderUtils.getViewStats(contentPath);

  print('Total Views: ${stats['total_views']}');
  print('Unique Viewers: ${stats['unique_viewers']}');

  if (stats['first_view'] != null) {
    final firstView = DateTime.fromMillisecondsSinceEpoch(
      stats['first_view'] * 1000,
    );
    print('First View: $firstView');
  }

  if (stats['latest_view'] != null) {
    final latestView = DateTime.fromMillisecondsSinceEpoch(
      stats['latest_view'] * 1000,
    );
    print('Latest View: $latestView');
  }

  // Calculate engagement rate
  if (stats['unique_viewers'] > 0) {
    final viewsPerUser = stats['total_views'] / stats['unique_viewers'];
    print('Average Views per User: ${viewsPerUser.toStringAsFixed(2)}');
  }
}
```

#### Checking User View History

```dart
/// Check if a user has viewed a post
Future<bool> hasUserViewedPost(String postId, String npub) async {
  final contentPath = BlogFolderUtils.buildPostPath(postId);
  return await FeedbackFolderUtils.hasUserViewed(contentPath, npub);
}

/// Get how many times a user viewed a post
Future<int> getUserViewCount(String postId, String npub) async {
  final contentPath = BlogFolderUtils.buildPostPath(postId);
  return await FeedbackFolderUtils.getUserViewCount(contentPath, npub);
}
```

#### View Analytics Example

```dart
/// Generate view analytics for content dashboard
Future<void> generateViewAnalytics(String postId) async {
  final contentPath = BlogFolderUtils.buildPostPath(postId);

  // Get all view events with timestamps
  final viewEvents = await FeedbackFolderUtils.getViewEvents(contentPath);

  // Group views by day
  final viewsByDay = <String, int>{};
  for (final event in viewEvents) {
    final date = DateTime.fromMillisecondsSinceEpoch(event.createdAt * 1000);
    final dateKey = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    viewsByDay[dateKey] = (viewsByDay[dateKey] ?? 0) + 1;
  }

  // Find peak viewing day
  var peakDay = '';
  var peakViews = 0;
  viewsByDay.forEach((day, count) {
    if (count > peakViews) {
      peakDay = day;
      peakViews = count;
    }
  });

  print('Peak Viewing Day: $peakDay with $peakViews views');

  // Identify most engaged viewers (top 10)
  final viewCountByUser = <String, int>{};
  for (final event in viewEvents) {
    final npub = event.npub;
    viewCountByUser[npub] = (viewCountByUser[npub] ?? 0) + 1;
  }

  final topViewers = viewCountByUser.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));

  print('\nTop 10 Most Engaged Viewers:');
  for (var i = 0; i < 10 && i < topViewers.length; i++) {
    final entry = topViewers[i];
    print('${i + 1}. ${entry.key.substring(0, 20)}... : ${entry.value} views');
  }
}
```

#### Best Practices for Page Views

1. **When to Record**: Record a view when the user:
   - Opens the content detail page
   - Spends more than 5 seconds on the page (debounce rapid navigation)
   - Scrolls past 25% of the content (for long posts)

2. **Privacy Considerations**:
   - Page views require authentication (npub/nsec)
   - Anonymous viewing is not tracked
   - Users can see they are being tracked

3. **Performance**:
   - Record views asynchronously (fire-and-forget)
   - Don't block UI on view recording
   - Cache view statistics with 5-minute TTL

4. **Analytics Retention**:
   - Keep detailed view events for 90 days
   - Archive to summary statistics after 90 days
   - Retain total/unique counts indefinitely

### Security Considerations

1. **Input Validation**: Always validate npub format and content length
2. **Signature Verification**: Verify NOSTR signatures for audit trail
3. **Rate Limiting**: Enforce rate limits to prevent spam
4. **Path Traversal**: Sanitize contentId to prevent directory traversal attacks
   ```dart
   String sanitizeContentId(String id) {
     return id.replaceAll('..', '').replaceAll('/', '_');
   }
   ```

5. **File Permissions**: Set appropriate file permissions (644 for files, 755 for directories)

---

## Comment Handling

### Overview

Comments are stored under `{contentPath}/feedback/comments` and written via `FeedbackCommentUtils` (`lib/util/feedback_comment_utils.dart`). Signatures are optional but recommended; the station stores `npub` and `signature` without enforcing verification.

### Recommended Signing Workflow

1. Build a NOSTR text note (kind 1) with tags:
   - `content_type` (e.g., `blog`, `alert`)
   - `content_id` (content identifier)
   - `action` = `comment`
   - `owner` = author callsign
2. Sign the event with `SigningService.signEvent(...)`.
3. Send `author`, `content`, and optional `npub` + `signature` to `/api/feedback/{contentType}/{contentId}/comment`.

### FeedbackCommentUtils Usage

```dart
import 'package:geogram/util/feedback_comment_utils.dart';

final commentId = await FeedbackCommentUtils.writeComment(
  contentPath: '/path/to/blog/2025/2025-12-04_hello-everyone',
  author: profile.callsign,
  content: 'This is my comment text',
  npub: profile.npub,
  signature: signedSig,
);

final comments = await FeedbackCommentUtils.loadComments(
  '/path/to/blog/2025/2025-12-04_hello-everyone',
);
```

### Comment File Layout

See "Comment File Format" above. Files are named `YYYY-MM-DD_HH-MM-SS_CALLSIGN.txt`.

---

## Related Documentation

- [Alert Format Specification](apps/alert-format-specification.md) - Current alert feedback system
- [Blog Format Specification](apps/blog-format-specification.md) - Current blog comment system
- [Chat Format Specification](apps/chat-format-specification.md) - NOSTR signature patterns
- [API Documentation](API.md) - Main API overview

---

## Changelog

### Version 1.4 (2025-12-28)
- Added Ratings feedback type with required comments
- New `feedback/ratings/` folder structure
- Rating file format with RATING field (1-5)
- API endpoints: POST/GET/DELETE ratings
- Content owner can delete any rating on their content
- One rating per user per content (updates replace)
- Updated permission levels and authorization rules for ratings

### Version 1.3 (2025-12-25)
- Toggle feedback files store one npub per line; views remain JSON events
- Documented migration compatibility for legacy JSON lines

### Version 1.2 (2025-12-24)
- Feedback files store signed NOSTR event JSON per line
- Documented FeedbackCommentUtils usage and comment flow
- Removed legacy migration guidance in favor of clean feedback/ usage

### Version 1.1 (2025-12-23)
- Added feedback endpoint examples and stats

### Version 1.0 (2025-12-22)
- Initial specification
- Designed feedback folder structure
- Defined API endpoints
- NOSTR message format integration
- Migration guide for alerts and blog

---

*This feedback system is part of the Geogram project.*
*License: Apache-2.0*
