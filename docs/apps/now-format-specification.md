# Now Activity Feed Specification

**Version**: 1.0
**Last Updated**: 2026-03-04
**Status**: Active

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Event System](#event-system)
- [Data Model](#data-model)
- [Priority System](#priority-system)
- [Group Settings](#group-settings)
- [UI Layout](#ui-layout)
- [Read State & Visibility](#read-state--visibility)
- [Muting](#muting)
- [Expiry & Pruning](#expiry--pruning)
- [Source Navigation](#source-navigation)
- [Debug API](#debug-api)
- [Internationalization](#internationalization)
- [Integration Guide](#integration-guide)

## Overview

The Now feed is a unified real-time activity aggregator that surfaces events from all apps (IRC, chat, email, alerts, DMs, etc.) into a single panel. Any service can push items into the feed by firing a `NowItemEvent` on the EventBus. Items are grouped by source, displayed as cards in a responsive masonry layout, and sorted by most recent activity.

## Architecture

```
┌──────────────┐  NowItemEvent    ┌─────────────┐   itemsStream   ┌──────────┐
│  IRC Service │─────────────────►│             │─────────────────►│          │
├──────────────┤                  │             │                  │          │
│ Chat Service │─────────────────►│  NowService │   unreadCount    │  NowPage │
├──────────────┤                  │  (singleton) │─────────────────►│  (cards) │
│  DM Service  │─────────────────►│             │                  │          │
├──────────────┤                  │             │◄─────────────────│          │
│ Alert/Email  │─────────────────►│             │  feedVisible,    └──────────┘
└──────────────┘                  │             │  markAsRead,
                                  │             │  groupSettings
  NowGroupRemoveEvent            │             │
  (e.g. leaving IRC channel) ───►│             │
                                  └─────────────┘
```

### Key Files

| File | Purpose |
|------|---------|
| `lib/models/now_item.dart` | NowItem model and NowGroupSettings |
| `lib/services/now_service.dart` | Core singleton service |
| `lib/pages/now_page.dart` | Card-based UI with masonry layout |
| `lib/util/event_bus.dart` | NowItemEvent, NowGroupRemoveEvent, NowPriority |
| `lib/services/log_api_service.dart` | Debug API endpoints |

## Event System

### NowItemEvent

Fired by any service to add an item to the feed:

```dart
EventBus().fire(NowItemEvent(
  id: 'irc:libera:#geogram:1709561234567',
  appType: 'irc',
  sourceId: 'libera:#geogram',
  sourceName: '#geogram (Libera)',
  callsign: 'hackerman',
  summary: 'Anyone on the mesh?',
  priority: NowPriority.chat,
));
```

| Field | Type | Description |
|-------|------|-------------|
| `id` | String | Unique identifier (duplicates are silently dropped) |
| `appType` | String | App category: `chat`, `dm`, `alert`, `email`, `irc`, `forum`, `blog`, `event` |
| `sourceId` | String | Source identifier (room ID, `serverId:channel`, thread ID, etc.) |
| `sourceName` | String | Human-readable display name |
| `callsign` | String | Who caused the activity |
| `summary` | String | Preview text |
| `priority` | int | Priority level (1 = highest, 10 = lowest) |

### NowGroupRemoveEvent

Fired when a source should be completely removed from the feed (e.g. leaving an IRC channel):

```dart
EventBus().fire(NowGroupRemoveEvent(
  appType: 'irc',
  sourceId: 'libera:#geogram',
));
```

This removes all items matching the given `appType:sourceId`.

### Auto-Converted Events

NowService internally converts these events into NowItemEvents:

| Source Event | Converted appType | Priority |
|-------------|-------------------|----------|
| `AlertReceivedEvent` (emergency/urgent) | `alert` | `alertUrgent` (1) |
| `AlertReceivedEvent` (other) | `alert` | `alertAttention` (2) |
| `EmailNotificationEvent` | `email` | `email` (4) |

## Data Model

### NowItem

Stored feed item, created from a NowItemEvent:

```dart
class NowItem {
  final String id;
  final String appType;
  final String sourceId;
  final String sourceName;
  final String callsign;
  final String summary;
  final int priority;
  final DateTime timestamp;
  bool isRead;
}
```

### NowGroupSettings

Per-source configuration for feed behavior:

```dart
class NowGroupSettings {
  final int maxItems;       // Max items retained per group (default: 5)
  final int expiryMinutes;  // Auto-expire after N minutes (0 = never, default: 1440 = 24h)
}
```

## Priority System

Items are sorted by priority (ascending), then by timestamp (newest first).

| Constant | Value | Use Case | Dot Color |
|----------|-------|----------|-----------|
| `NowPriority.alertUrgent` | 1 | Emergency/urgent alerts | Red |
| `NowPriority.alertAttention` | 2 | Attention-level alerts | Red |
| `NowPriority.directMessage` | 3 | 1:1 direct messages | Orange |
| `NowPriority.email` | 4 | Email notifications | Blue |
| `NowPriority.chat` | 5 | Chat rooms, IRC channels | Blue |
| `NowPriority.forum` | 6 | Forum posts | Green |
| `NowPriority.blog` | 7 | Blog posts | Green |
| `NowPriority.event` | 8 | Calendar events | Grey |
| `NowPriority.sharedFile` | 9 | Shared files | Grey |
| `NowPriority.routine` | 10 | Everything else | Grey |

## Group Settings

Settings resolve with a cascading fallback chain:

```
"appType:sourceId" → "appType" → "_default" → hardcoded defaults
```

Examples:
- `"irc:libera:#geogram"` — settings for a specific IRC channel
- `"irc"` — settings for all IRC channels
- `"_default"` — global default for all sources

Settings are persisted in ConfigService under `now.groupSettings`.

## UI Layout

### Card-Based Design

Each source (`appType:sourceId`) renders as a Card widget:

```
┌─────────────────────────────────────┐
│ # #geogram (Libera)        3   ⋮   │
│─────────────────────────────────────│
│ ● hackerman: Anyone on the mesh? 2m│
│ ● radioguy: Yes testing now     1m │
│ ● devops: Build passed          30s│
└─────────────────────────────────────┘
```

- **Header**: app type icon + source name + unread badge (pill) + three-dot menu
- **Body**: messages in chronological order (oldest top, newest bottom)
- **Message row**: priority dot + `callsign: summary` + time-ago
- Cards sorted by newest message timestamp (most recent card first)
- Tapping header navigates to the source
- Tapping a message row marks it as read and navigates to the source
- Three-dot menu opens group settings bottom sheet

### Responsive Masonry Layout

Cards flow into multiple columns based on available width:

| Screen Width | Columns | Use Case |
|-------------|---------|----------|
| < 340px | 1 | Small phone |
| 340–510px | 2 | Phone portrait |
| 510–680px | 3 | Tablet portrait |
| 680px+ | 4 (max) | Desktop / landscape |

Minimum card width: 170px. Cards distribute using shortest-column-first for balanced heights.

### Group Settings Sheet

Opened via the three-dot menu on each card header:

- **Mute/Unmute toggle** — suppress all future items from this source
- **Max items slider** — 1 to 50 items retained per group
- **Expiry slider** — 0 to 168 hours (0 = never expire, max 7 days)
- **Save button** — persists settings

## Read State & Visibility

### Read Tracking

- Each item has an `isRead` flag
- Read item IDs are persisted in ConfigService (capped at 500 IDs)
- `markAsRead(itemId)` — mark single item
- `markAllAsRead()` — mark all items

### Feed Visibility

When the Now tab is active (`feedVisible = true`):
- New arriving items are immediately marked as read
- `unreadCount` reports 0 (badge hidden)
- Switching away from the tab restores normal unread tracking

## Muting

- `toggleSourceMute(appType, sourceId)` — toggle mute for a source
- Muted sources: new events are silently dropped, existing items removed
- Muted state persisted in ConfigService under `now.mutedSources`
- Mute/unmute available in the group settings sheet

## Expiry & Pruning

- **Per-group expiry**: controlled by `NowGroupSettings.expiryMinutes` (default 24h)
- **Automatic pruning**: expired items removed every 60 seconds
- **Visual indicator**: items within 10% of expiry time are rendered with reduced opacity
- **Global cap**: maximum 200 items across all groups
- **Per-group cap**: controlled by `NowGroupSettings.maxItems` (default 5)

When a group exceeds maxItems, the newest N are kept and displayed chronologically.

## Source Navigation

Tapping a card header or message row navigates to the source:

| appType | Navigation |
|---------|-----------|
| `chat` | Push `/chat` route with `sourceId` as room ID |
| `irc` | Push `IrcChatPage` with `serverId` and `channel` (parsed from `sourceId`) |
| `dm` | Push `/dm` route with `sourceId` as callsign |
| `email` | Push `/email` route with `sourceId` as thread ID |
| `alert` | Push `/alerts` route with `sourceId` as folder name |

## Debug API

All endpoints require debug API to be enabled (`SecurityService().debugApiEnabled`).

### GET /api/debug/now

List current feed items.

**Response:**
```json
{
  "items": [{ "id": "...", "appType": "irc", "sourceId": "...", ... }],
  "total": 12,
  "unread": 3
}
```

### POST /api/debug/now/inject

Inject a test NowItemEvent.

**Body:**
```json
{
  "appType": "irc",
  "sourceId": "libera:#geogram",
  "sourceName": "#geogram (Libera)",
  "callsign": "testuser",
  "summary": "Hello from debug API",
  "priority": 5,
  "id": "optional-custom-id"
}
```

### POST /api/debug/now/clear

Clear all feed items.

### POST /api/debug/now/mark-read

Mark all items as read.

### GET /api/debug/now/settings

Get all group settings.

**Response:**
```json
{
  "settings": {
    "_default": { "maxItems": 5, "expiryMinutes": 1440 },
    "irc": { "maxItems": 10, "expiryMinutes": 720 }
  }
}
```

### POST /api/debug/now/settings

Set group settings.

**Body:**
```json
{
  "group": "irc:libera:#geogram",
  "maxItems": 10,
  "expiryMinutes": 1440
}
```

### POST /api/debug/now/remove-group

Remove all items for a source group.

**Body:**
```json
{
  "appType": "irc",
  "sourceId": "libera:#geogram"
}
```

## Internationalization

| Key | Default (en_US) |
|-----|----------------|
| `now_empty` | No recent activity |
| `now_group_settings` | Group settings |
| `now_mute_source` | Mute this source |
| `now_unmute_source` | Unmute this source |
| `now_max_items` | Max items |
| `now_expiry` | Expires after |
| `now_expiry_hours` | {0}h |
| `save` | Save |
| `just_now` | Just now |
| `minutes_ago` | {0}m ago |
| `hours_ago` | {0}h ago |
| `days_ago` | {0}d ago |

## Integration Guide

### Adding a New Source to the Now Feed

1. Fire `NowItemEvent` from your service when activity occurs:

```dart
import '../../util/event_bus.dart';

EventBus().fire(NowItemEvent(
  id: 'myapp:${sourceId}:${DateTime.now().millisecondsSinceEpoch}',
  appType: 'myapp',
  sourceId: sourceId,
  sourceName: 'My Source Name',
  callsign: actorName,
  summary: previewText,
  priority: NowPriority.chat,
));
```

2. Fire `NowGroupRemoveEvent` when the user leaves/unsubscribes:

```dart
EventBus().fire(NowGroupRemoveEvent(
  appType: 'myapp',
  sourceId: sourceId,
));
```

3. Add navigation handling in `NowPage._navigateToSource()`:

```dart
case 'myapp':
  Navigator.pushNamed(context, '/myapp', arguments: item.sourceId);
  break;
```

4. Optionally add an icon mapping in `NowPage._getAppTypeIcon()`.

### ID Format Convention

Use the pattern `appType:sourceId:uniquePart` for item IDs to ensure uniqueness. The unique part is typically a timestamp or message ID. Duplicate IDs are silently dropped.

### Priority Guidelines

- Use `alertUrgent` (1) or `alertAttention` (2) only for time-sensitive alerts
- Use `directMessage` (3) for 1:1 conversations requiring immediate attention
- Use `chat` (5) for group conversations
- Use `routine` (10) for background activity that doesn't need attention
