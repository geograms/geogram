# Geogram Station API

This document describes the HTTP API endpoints available on Geogram radio stations.

## Table of Contents

- [Overview](#overview)
- [Connection Manager](#connection-manager)
- [GeogramApi Client](#geogramapi-client)
  - [API Modules](#api-modules)
  - [StatusApi](#statusapi)
  - [ChatApi](#chatapi)
  - [AlertsApi](#alertsapi)
  - [PlacesApi](#placesapi)
  - [EventsApi](#eventsapi)
  - [BlogApi](#blogapi)
  - [VideosApi](#videosapi)
  - [FeedbackApi](#feedbackapi)
  - [BackupApi](#backupapi)
  - [DmApi](#dmapi)
  - [UpdatesApi](#updatesapi)
- [Base URL](#base-url)
- [Endpoints](#endpoints)
  - [Status](#status)
  - [Clients](#clients)
  - [GeoIP](#geoip)
  - [Device Proxy](#device-proxy)
  - [Alert File Upload/Download](#alert-file-uploaddownload-station)
  - [Software Updates](#software-updates)
  - [Map Tiles](#map-tiles)
  - [Chat](#chat)
  - [Direct Messages](#direct-messages)
  - [Blog](#blog)
  - [Events](#events)
  - [Alerts](#alerts)
  - [Feedback](#feedback)
  - [Logs](#logs)
  - [Debug API](#debug-api)
  - [Backup](#backup)
  - [Mirror Sync](#mirror-sync)
  - [P2P File Transfer](#p2p-file-transfer)
- [WebSocket Connection](#websocket-connection)
- [Station Configuration](#station-configuration)

## Overview

Geogram stations provide a local HTTP API that enables:

- **Offgrid Software Updates**: Mirrors GitHub releases for clients without internet
- **Map Tile Caching**: Serves cached OpenStreetMap and satellite tiles
- **Chat & Messaging**: Room-based chat and direct messages
- **Blog Publishing**: Serves user blog posts as HTML
- **Device Status**: Information about connected devices

---

## Connection Manager

The Connection Manager provides transport-agnostic device-to-device communication. It automatically selects the best transport based on availability and priority, allowing apps to send messages without knowing the underlying connection method.

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    ConnectionManager                         │
│                      (Singleton)                             │
├─────────────────────────────────────────────────────────────┤
│  send(message) → tries transports in priority order         │
│  apiRequest(callsign, method, path) → convenience method    │
│  sendDM(callsign, signedEvent) → direct message             │
│  isReachable(callsign) → check if device is reachable       │
└─────────────────────────────────────────────────────────────┘
                              │
         ┌────────────────────┼────────────────────┐
         ▼                    ▼                    ▼
┌─────────────────┐  ┌──────────────────┐  ┌─────────────────┐
│  LAN Transport  │  │ Station Transport │  │  BLE Transport  │
│  (priority: 10) │  │  (priority: 30)   │  │  (priority: 40) │
│                 │  │                   │  │                 │
│ Direct HTTP on  │  │ WebSocket relay   │  │ Bluetooth Low   │
│ local network   │  │ via p2p.radio     │  │ Energy (offline)│
└─────────────────┘  └───────────────────┘  └─────────────────┘
```

### Transport Priority

| Transport | Priority | Description | Use Case |
|-----------|----------|-------------|----------|
| LAN | 10 | Direct HTTP on local network | Fastest, same WiFi/LAN |
| Station | 30 | Internet relay via station | Global reach, requires internet |
| BLE | 40 | Bluetooth Low Energy | Offline fallback, slow but works without internet |

Lower priority values are preferred. The Connection Manager tries transports in order until one succeeds.

### Usage

```dart
// Get the singleton instance
final cm = ConnectionManager();

// Make an API request (transport is selected automatically)
final result = await cm.apiRequest(
  callsign: 'X1ABCD',
  method: 'GET',
  path: '/api/status',
);

if (result.success) {
  print('Response via ${result.transportUsed}: ${result.responseData}');
  print('Latency: ${result.latency?.inMilliseconds}ms');
} else {
  print('Failed: ${result.error}');
}

// Send a direct message with optional queueing
final dmResult = await cm.sendDM(
  callsign: 'X1ABCD',
  signedEvent: nostrSignedEvent,
  queueIfOffline: true,  // Queue if device unreachable
  ttl: Duration(hours: 24),  // Expire after 24 hours
);

// Check if a device is reachable via any transport
final reachable = await cm.isReachable('X1ABCD');

// Get available transports for a device
final transports = await cm.getAvailableTransports('X1ABCD');
// Returns: ['lan', 'station'] or ['ble'] etc.
```

### TransportMessage

All messages are wrapped in a `TransportMessage`:

```dart
class TransportMessage {
  final String id;                    // Unique message ID
  final String targetCallsign;        // Target device callsign
  final TransportMessageType type;    // Message type
  final String? method;               // HTTP method (GET, POST, etc.)
  final String? path;                 // API path (/api/status)
  final Map<String, String>? headers; // HTTP headers
  final dynamic payload;              // Message body
  final Map<String, dynamic>? signedEvent; // NOSTR signed event
  final bool queueIfOffline;          // Queue if unreachable (default: false)
  final Duration? ttl;                // Time-to-live for queued messages
}

enum TransportMessageType {
  apiRequest,     // HTTP-style API request
  directMessage,  // 1-to-1 DM
  chatMessage,    // Room chat message
  sync,           // Sync request
  hello,          // Connection handshake
  ping,           // Heartbeat
}
```

### TransportResult

Send operations return a `TransportResult`:

```dart
class TransportResult {
  final bool success;           // Whether send succeeded
  final String? error;          // Error message if failed
  final int? statusCode;        // HTTP status code
  final dynamic responseData;   // Response body
  final String? transportUsed;  // Which transport delivered ('lan', 'ble', 'station')
  final Duration? latency;      // Round-trip time
  final bool wasQueued;         // True if message was queued for later
}
```

### Transports

#### LAN Transport

Direct HTTP communication with devices on the local network.

**File:** `lib/connection/transports/lan_transport.dart`

**Features:**
- Detects local IP addresses (192.168.x, 10.x, 172.16-31.x)
- Fastest transport when available
- No internet dependency
- Automatic device URL registration

**Configuration:**
```dart
LanTransport(
  timeout: Duration(seconds: 30),
  reachabilityTimeout: Duration(seconds: 3),
)
```

#### BLE Transport

Bluetooth Low Energy communication using GATT protocol.

**File:** `lib/connection/transports/ble_transport.dart`

**Features:**
- Works offline (no internet or LAN required)
- Short range (~10-100 meters)
- Uses BLEMessageService for message exchange
- GATT server on Android/iOS, client-only on desktop

**Platform Support:**
| Platform | GATT Server | GATT Client |
|----------|-------------|-------------|
| Android | Yes | Yes |
| iOS | Yes | Yes |
| Linux | No | Yes |
| macOS | No | Yes |
| Windows | No | Yes |
| Web | No | No |

#### Station Transport

Internet relay via WebSocket connection to a station (e.g., p2p.radio).

**File:** `lib/connection/transports/station_transport.dart`

**Features:**
- Global reach (works across networks)
- HTTP proxy via `/{callsign}/api/*` format
- WebSocket relay for signed events
- Connection status caching

**Proxy Format:**
```
https://p2p.radio/{callsign}/api/status
https://p2p.radio/{callsign}/api/dm/conversations
```

### Routing Strategies

The Connection Manager supports pluggable routing strategies:

#### PriorityRoutingStrategy (Default)

Selects transports by priority (lower = better):

```dart
ConnectionManager().setRoutingStrategy(
  PriorityRoutingStrategy(
    filterUnreachable: true,  // Only try reachable transports
    reachabilityTimeout: Duration(seconds: 2),
  ),
);
```

#### QualityRoutingStrategy

Selects transports based on historical metrics:

```dart
ConnectionManager().setRoutingStrategy(
  QualityRoutingStrategy(
    latencyWeight: 0.3,
    successRateWeight: 0.4,
    qualityWeight: 0.3,
  ),
);
```

#### FailoverRoutingStrategy

Uses explicit transport order:

```dart
ConnectionManager().setRoutingStrategy(
  FailoverRoutingStrategy(
    transportOrder: ['lan', 'ble', 'station'],
  ),
);
```

### Message Queueing

By default, messages fail immediately if no transport can reach the device. Enable queueing for store-and-forward:

```dart
final result = await cm.apiRequest(
  callsign: 'X1ABCD',
  method: 'POST',
  path: '/api/chat/room1/messages',
  body: messageBody,
  queueIfOffline: true,  // Queue if unreachable
);

if (result.wasQueued) {
  print('Message queued for later delivery');
}

// Check pending queue
print('Pending messages: ${cm.pendingCount}');

// Manually retry pending messages
await cm.retryPending();
```

### Adding New Transports

To add a new transport (e.g., LoRa, Meshtastic):

1. Create a new transport class implementing `Transport`:

```dart
class LoRaTransport extends Transport with TransportMixin {
  @override
  String get id => 'lora';

  @override
  String get name => 'LoRa Radio';

  @override
  int get priority => 25;  // Between BLE and Station

  @override
  bool get isAvailable => Platform.isLinux;  // Hardware requirement

  @override
  Future<bool> canReach(String callsign) async {
    // Check if device is in LoRa range
  }

  @override
  Future<TransportResult> send(TransportMessage message, {Duration? timeout}) async {
    // Send via LoRa radio
  }

  // ... implement other methods
}
```

2. Register the transport in `main.dart`:

```dart
final cm = ConnectionManager();
cm.registerTransport(LanTransport());
cm.registerTransport(BleTransport());
cm.registerTransport(LoRaTransport());  // New transport
cm.registerTransport(StationTransport());
await cm.initialize();
```

### Metrics

Each transport tracks performance metrics:

```dart
final metrics = cm.allMetrics;
for (final entry in metrics.entries) {
  print('${entry.key}: '
      'latency=${entry.value.averageLatencyMs.toStringAsFixed(1)}ms, '
      'success=${(entry.value.successRate * 100).toStringAsFixed(1)}%');
}
```

---

## GeogramApi Client

The `GeogramApi` class (`lib/api/api.dart`) provides a unified Dart interface for all API operations. It wraps the ConnectionManager to provide transport-agnostic communication with type-safe responses.

### Quick Start

```dart
import 'package:geogram/api/api.dart';

final api = GeogramApi();

// Get device status
final status = await api.status.get('X3STATION');
if (status.success) {
  print('Station: ${status.data?.callsign}');
  print('Version: ${status.data?.version}');
}

// List alerts near a location
final alerts = await api.alerts.list('X3STATION',
  lat: 38.72,
  lon: -9.14,
  radius: 10, // km
);
for (final alert in alerts.items) {
  print('Alert: ${alert.title} at ${alert.latitude}, ${alert.longitude}');
}
```

### API Modules

The GeogramApi facade exposes the following endpoint modules:

| Module | Class | Description |
|--------|-------|-------------|
| `api.status` | `StatusApi` | Device status, GeoIP, connected clients |
| `api.chat` | `ChatApi` | Chat rooms, messages, files, moderation |
| `api.alerts` | `AlertsApi` | Alert listing, details, photos |
| `api.places` | `PlacesApi` | Place listing, details, photos |
| `api.events` | `EventsApi` | Events, media contributors, files |
| `api.blog` | `BlogApi` | Blog posts, comments, reactions |
| `api.videos` | `VideosApi` | Video listing, categories, comments |
| `api.feedback` | `FeedbackApi` | Points, likes, verifications, comments |
| `api.backup` | `BackupApi` | Backup providers, clients, snapshots |
| `api.dm` | `DmApi` | Direct messages, conversations, sync |
| `api.updates` | `UpdatesApi` | Software update info, version checking |

### StatusApi

```dart
// Get device status
final status = await api.status.get('X3STATION');

// Get GeoIP location for client
final geoip = await api.status.geoip('X3STATION');
print('Location: ${geoip.data?.city}, ${geoip.data?.country}');

// List connected clients
final clients = await api.status.clients('X3STATION');
```

### ChatApi

```dart
// List chat rooms
final rooms = await api.chat.rooms('X3STATION');

// Get messages from a room
final messages = await api.chat.messages('X3STATION', 'general',
  limit: 50,
  since: lastTimestamp,
);

// Send a message (requires signed NOSTR event)
await api.chat.sendMessage('X3STATION', 'general', signedEvent);

// List files in a room
final files = await api.chat.files('X3STATION', 'general');

// Room moderation
await api.chat.banUser('X3STATION', 'roomId', userNpub, signedEvent);
await api.chat.promoteMember('X3STATION', 'roomId', signedEvent);
```

### AlertsApi

```dart
// List alerts with filters
final alerts = await api.alerts.list('X3STATION',
  status: 'active',
  lat: 38.72,
  lon: -9.14,
  radius: 10,
  type: 'infrastructure',
  limit: 20,
);

// Get alert details
final alert = await api.alerts.get('X3STATION', alertId);

// Get alert photo
final photo = await api.alerts.getFile('X3STATION', alertId, 'images/photo1.jpg');

// Upload alert photo
await api.alerts.uploadFile('X3STATION', alertId, 'photo.jpg', imageBytes,
  contentType: 'image/jpeg',
);
```

### PlacesApi

```dart
// List places near location
final places = await api.places.list('X3STATION',
  lat: 38.72,
  lon: -9.14,
  radius: 5,
  type: 'restaurant',
);

// Get place details
final place = await api.places.get('X3STATION', folderName);
print('Address: ${place.data?.address}');
print('Hours: ${place.data?.hours}');
```

### EventsApi

```dart
// List events (optionally filter by year)
final events = await api.events.list('X3STATION', year: 2025);

// Get event files
final items = await api.events.items('X3STATION', eventId, path: 'photos/day1');

// List media contributors
final contributors = await api.events.mediaContributors('X3STATION', eventId);

// Contributor moderation
await api.events.approveContributor('X3STATION', eventId, contributorCallsign);
await api.events.suspendContributor('X3STATION', eventId, contributorCallsign);
```

### BlogApi

```dart
// List blog posts
final posts = await api.blog.list('X3STATION',
  tag: 'tutorial',
  limit: 10,
);

// Get post with comments
final post = await api.blog.get('X3STATION', postId);
for (final comment in post.data?.comments ?? []) {
  print('${comment.author}: ${comment.content}');
}

// Add comment
await api.blog.comment('X3STATION', postId,
  author: 'Alice',
  content: 'Great post!',
  npub: myNpub,
);

// Reactions
await api.blog.like('X3STATION', postId, signedEvent);
await api.blog.point('X3STATION', postId, signedEvent);
await api.blog.react('X3STATION', postId, '👍', signedEvent);
```

### VideosApi

```dart
// List videos with filters
final videos = await api.videos.list('X3STATION',
  category: 'tutorials',
  tag: 'beginner',
  limit: 20,
);

// Get video details
final video = await api.videos.get('X3STATION', videoId);
print('Duration: ${video.data?.durationFormatted}');
print('Views: ${video.data?.viewCount}');

// Record a view
await api.videos.recordView('X3STATION', videoId);

// Get categories and tags
final categories = await api.videos.categories('X3STATION');
final tags = await api.videos.tags('X3STATION');
```

### FeedbackApi

Unified feedback system for all content types (alerts, places, events, blog, videos).

```dart
// Get feedback counts and user state
final feedback = await api.feedback.get('X3STATION', 'alert', alertId, npub: myNpub);
print('Points: ${feedback.data?.counts.points}');
print('Has pointed: ${feedback.data?.userState.hasPointed}');

// Generic feedback actions
await api.feedback.point('X3STATION', 'alert', alertId, signedEvent);
await api.feedback.like('X3STATION', 'blog', postId, signedEvent);
await api.feedback.verify('X3STATION', 'alert', alertId, signedEvent);
await api.feedback.subscribe('X3STATION', 'event', eventId, signedEvent);
await api.feedback.react('X3STATION', 'video', videoId, '🔥', signedEvent);

// Convenience methods
await api.feedback.pointAlert('X3STATION', alertId, signedEvent);
await api.feedback.verifyAlert('X3STATION', alertId, signedEvent);
await api.feedback.likeBlogPost('X3STATION', postId, signedEvent);
await api.feedback.likeVideo('X3STATION', videoId, signedEvent);
```

### BackupApi

```dart
// Provider settings
final settings = await api.backup.getSettings('X3STATION');
await api.backup.updateSettings('X3STATION', BackupSettings(
  enabled: true,
  maxStorageBytes: 1024 * 1024 * 1024, // 1GB
  maxClients: 5,
  autoAccept: false,
));

// Client operations
final providers = await api.backup.providers('X3STATION');
await api.backup.inviteProvider('X3STATION', providerCallsign);
await api.backup.startBackup('X3STATION', providerCallsign);
final status = await api.backup.status('X3STATION');
print('Progress: ${status.data?.progressPercent}%');

// Provider operations
final clients = await api.backup.clients('X3STATION');
await api.backup.acceptClient('X3STATION', clientCallsign);
final snapshots = await api.backup.snapshots('X3STATION', clientCallsign);
```

### DmApi

```dart
// List DM conversations
final conversations = await api.dm.conversations('X3STATION');
for (final conv in conversations.items) {
  print('${conv.callsign}: ${conv.unreadCount} unread');
}

// Get messages
final messages = await api.dm.messages('X3STATION', otherCallsign,
  limit: 50,
  since: lastTimestamp,
);

// Send message (uses ConnectionManager for optimal transport)
await api.dm.sendMessage(targetCallsign, signedEvent,
  queueIfOffline: true,
  ttl: Duration(hours: 24),
);

// Sync messages
final syncResult = await api.dm.sync('X3STATION', otherCallsign, since: lastSync);
```

### UpdatesApi

```dart
// Get latest release info
final release = await api.updates.latest('X3STATION', platform: 'android');
if (release.success) {
  print('Latest: ${release.data?.version}');
  print('Download: ${release.data?.downloadUrl}');
}

// Check if update available
final hasUpdate = await api.updates.checkForUpdate('X3STATION', '1.10.7');
if (hasUpdate.data == true) {
  print('Update available!');
}
```

### Response Types

All API methods return typed responses:

```dart
/// Single item response
class ApiResponse<T> {
  final bool success;
  final String? error;
  final T? data;
  final int? statusCode;
  final String? transportUsed;  // 'lan', 'ble', 'station'
  final Duration? latency;
  final bool wasQueued;
}

/// List response with pagination
class ApiListResponse<T> {
  final bool success;
  final String? error;
  final List<T> items;
  final int? total;
  final int? offset;
  final int? limit;
}
```

### Core Request Methods

For custom endpoints not covered by modules:

```dart
// GET request
final response = await api.get<MyType>(
  'X3STATION',
  '/api/custom/endpoint',
  queryParams: {'key': 'value'},
  fromJson: (json) => MyType.fromJson(json),
);

// POST request
final response = await api.post<MyType>(
  'X3STATION',
  '/api/custom/endpoint',
  body: {'data': 'value'},
  fromJson: (json) => MyType.fromJson(json),
  queueIfOffline: true,
);

// Other methods: put, delete, patch, list
```

### File Structure

```
lib/api/
├── api.dart              # GeogramApi facade
├── api_response.dart     # ApiResponse, ApiListResponse
├── api_error.dart        # ApiError class
├── endpoints/
│   ├── status_api.dart   # StatusApi, DeviceStatus, GeoIpInfo
│   ├── chat_api.dart     # ChatApi, ChatRoom, ChatMessage, ChatFile
│   ├── alerts_api.dart   # AlertsApi, AlertSummary, AlertDetails
│   ├── places_api.dart   # PlacesApi, PlaceSummary, PlaceDetails
│   ├── events_api.dart   # EventsApi, EventSummary, MediaContributor
│   ├── blog_api.dart     # BlogApi, BlogPostSummary, BlogPostDetails
│   ├── videos_api.dart   # VideosApi, VideoSummary, VideoFolder
│   ├── feedback_api.dart # FeedbackApi, FeedbackCounts, FeedbackComment
│   ├── backup_api.dart   # BackupApi, BackupProvider, BackupSnapshot
│   ├── dm_api.dart       # DmApi, DmConversation, DmMessage
│   └── updates_api.dart  # UpdatesApi, ReleaseInfo
├── handlers/             # Server-side request handlers
│   ├── alert_handler.dart
│   ├── place_handler.dart
│   ├── video_handler.dart
│   ├── blog_handler.dart
│   └── feedback_handler.dart
└── common/
    ├── station_info.dart
    ├── file_tree_builder.dart
    └── geometry_utils.dart
```

---

## Base URL

The station API is available at the same host as the WebSocket connection, using HTTP/HTTPS protocol.

**Example:** If your station is at `ws://192.168.1.100:8080`, the API is at `http://192.168.1.100:8080`.

---

## Endpoints

### Status

#### GET /

Returns a simple HTML status page for the station.

**Response (200 OK):** HTML page with station info.

#### GET /api/status

Returns detailed station status and configuration.

**Response (200 OK):**
```json
{
  "name": "Geogram Desktop Station",
  "version": "1.6.17",
  "callsign": "X1ABCD",
  "nickname": "Alice",
  "color": "purple",
  "platform": "linux",
  "description": "My local Geogram station",
  "connected_devices": 5,
  "uptime": 3600,
  "station_mode": true,
  "location": {
    "latitude": 38.72,
    "longitude": -9.14,
    "precision_km": 25
  },
  "latitude": 38.72,
  "longitude": -9.14,
  "tile_server": true,
  "osm_fallback": true,
  "cache_size": 150,
  "cache_size_bytes": 52428800
}
```

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Station/device name |
| `version` | string | Geogram version |
| `callsign` | string | Device callsign (e.g., X1ABCD) |
| `nickname` | string | User's display name (optional) |
| `color` | string | User's preferred color: red, blue, green, yellow, purple, orange, pink, cyan |
| `platform` | string | Operating system: linux, macos, windows, android, ios |
| `description` | string | Station description |
| `connected_devices` | int | Number of connected clients (stations only) |
| `uptime` | int | Uptime in minutes (stations only) |
| `station_mode` | bool | Whether running as station |
| `location` | object | Location with privacy precision |
| `location.latitude` | float | Latitude (rounded to privacy precision) |
| `location.longitude` | float | Longitude (rounded to privacy precision) |
| `location.precision_km` | int | Location privacy precision in km (from Security settings) |
| `latitude` | float | Latitude (top-level, for backwards compatibility) |
| `longitude` | float | Longitude (top-level, for backwards compatibility) |
| `tile_server` | bool | Tile server enabled (stations only) |
| `osm_fallback` | bool | OSM fallback enabled (stations only) |
| `cache_size` | int | Tiles in cache (stations only) |
| `cache_size_bytes` | int | Cache size in bytes (stations only) |

---

### Meeting Discovery

#### GET /api/meet/active

Returns info about the currently active meeting on this device, or 404 if no meeting is hosted.

**Response (200 OK):**
```json
{
  "room_id": "BGNI@X1SU86",
  "room_name": "Test Conference",
  "host_callsign": "X1SU86",
  "signaling_port": 36665,
  "participant_count": 1,
  "max_participants": 6
}
```

**Response (404 Not Found):** No active meeting.

| Field | Type | Description |
|-------|------|-------------|
| `room_id` | string | Room ID in `XXXX@callsign` format |
| `room_name` | string | Meeting name |
| `host_callsign` | string | Host device callsign |
| `signaling_port` | int | WebSocket signaling server port (for LAN join) |
| `participant_count` | int | Current participants |
| `max_participants` | int | Maximum participants |

No authentication required.

**Shareable URLs:**
- **LAN**: `http://ip:port/meet/XXXX` — the 4-letter code, no callsign needed (IP is the direct connection)
- **Station**: `http://p2p.radio/CALLSIGN/meet/XXXX` — includes callsign for routing through the station

---

### Clients

#### GET /api/clients

Returns list of connected clients, grouped by callsign.

**Response (200 OK):**
```json
{
  "station": "X3WFE4",
  "count": 3,
  "clients": [
    {
      "callsign": "X1ABCD",
      "nickname": "Alice",
      "color": "purple",
      "platform": "android",
      "npub": "npub1abc...",
      "latitude": 38.72,
      "longitude": -9.14,
      "connected_at": "2024-12-08T10:00:00Z",
      "last_activity": "2024-12-08T10:30:00Z",
      "is_online": true
    }
  ]
}
```

| Field | Type | Description |
|-------|------|-------------|
| `callsign` | string | Client's callsign |
| `nickname` | string | Display name |
| `color` | string | User's preferred color |
| `platform` | string | Operating system: linux, macos, windows, android, ios |
| `npub` | string | Nostr public key (if available) |
| `connection_types` | array | Connection methods (`local`, `lora`, `meshtastic`) |
| `latitude` | float | Client's latitude (if shared) |
| `longitude` | float | Client's longitude (if shared) |
| `connected_at` | string | ISO 8601 connection timestamp |
| `last_activity` | string | ISO 8601 last activity timestamp |
| `is_online` | bool | Online status |

---

### Console

#### POST /api/cli

Execute a CLI console command. Navigation state (`cd`) is preserved across requests.

Available on two servers:
- **Station server** (port 8080) — uses `ConsoleCommandMixin`, accessible by remote clients
- **Desktop local server** (port 3456) — uses `CliConsoleController`, same endpoint for local automation/testing

**Request body:**
```json
{
  "command": "ls /chat"
}
```

**Response (200 OK):**
```json
{
  "status": "ok",
  "output": "X3WFE4/\n",
  "path": "/"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `status` | string | `"ok"` on success |
| `output` | string | Command output (ANSI stripped) |
| `path` | string | Current navigation path after command |

**Stateful navigation example (Desktop local server):**
```bash
# Navigate to chat directory
curl -X POST http://localhost:3456/api/cli \
  -H 'Content-Type: application/json' \
  -d '{"command": "cd chat"}'
# → {"status":"ok","output":"","path":"/chat"}

# List contents (uses current path from previous cd)
curl -X POST http://localhost:3456/api/cli \
  -H 'Content-Type: application/json' \
  -d '{"command": "ls"}'
# → {"status":"ok","output":"X3WFE4/\ngeneral/  General\n","path":"/chat"}
```

**Same endpoint on station server (port 8080):**
```bash
curl -X POST http://localhost:8080/api/cli \
  -H 'Content-Type: application/json' \
  -d '{"command": "ls /chat"}'
```

**Error (400):**
```json
{"status": "error", "error": "Missing command"}
```

---

### GeoIP

Privacy-preserving IP geolocation using a bundled offline database (DB-IP Lite).

#### GET /api/geoip

Returns the client's public IP address and its geolocation. The station extracts the client IP from the HTTP connection and looks it up in the local MMDB database. **No external IP services are called.**

**Response (200 OK):**
```json
{
  "ip": "203.0.113.42",
  "latitude": 38.7223,
  "longitude": -9.1393,
  "city": "Lisbon",
  "country": "Portugal",
  "countryCode": "PT"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `ip` | string | Client's public IP address |
| `latitude` | float | Latitude (null if not found) |
| `longitude` | float | Longitude (null if not found) |
| `city` | string | City name in English (null if not found) |
| `country` | string | Country name in English (null if not found) |
| `countryCode` | string | ISO 3166-1 alpha-2 country code (null if not found) |

**Response (503 Service Unavailable):**

Returned when the GeoIP database is not loaded.

```json
{
  "error": "GeoIP service not initialized",
  "ip": "203.0.113.42"
}
```

**Privacy Notes:**
- Uses bundled DB-IP Lite database (~127MB)
- No external IP lookup services are contacted
- Client IP is determined from the HTTP connection, not via external APIs
- Database attribution: "IP Geolocation by DB-IP" (CC BY 4.0)

---

### Device Proxy

The station can proxy API requests to connected devices via WebSocket. This allows you to query a remote device's status or API through the station.

**Two URL formats are supported:**
- `/{callsign}/api/{endpoint}` - Recommended format
- `/device/{callsign}/{endpoint}` - Alternative format

#### GET /{callsign}/api/status

Returns the status of a connected device by forwarding the request to the device via WebSocket.

**Parameters:**
| Parameter | Description |
|-----------|-------------|
| `callsign` | The callsign of the connected device (case-insensitive) |

**Response - Device Connected (200 OK):**
```json
{
  "service": "Geogram Desktop",
  "version": "1.6.2",
  "type": "desktop",
  "status": "online",
  "callsign": "X1ABCD",
  "name": "X1ABCD",
  "hostname": "my-laptop",
  "port": 3456,
  "location": {
    "latitude": 38.72,
    "longitude": -9.14
  },
  "nickname": "Alice"
}
```

**Response - Device Not Connected (404 Not Found):**
```json
{
  "error": "Device not connected",
  "callsign": "X1ABCD",
  "message": "The device X1ABCD is not currently connected to this station"
}
```

**Response - Gateway Timeout (504):**
```json
{
  "error": "Gateway Timeout",
  "message": "Device X1ABCD did not respond in time"
}
```

#### GET /device/{callsign}

Returns connection info for a device (without proxying to the device).

**Response - Device Connected (200 OK):**
```json
{
  "callsign": "X1ABCD",
  "connected": true,
  "uptime": 3600,
  "idleTime": 30,
  "deviceType": "Linux",
  "version": "1.6.2",
  "address": "192.168.1.100"
}
```

**Response - Device Not Connected (404 Not Found):**
```json
{
  "callsign": "X1ABCD",
  "connected": false,
  "error": "Device not connected"
}
```

#### GET /{callsign}/api/{endpoint}

Proxies any API request to a connected device. All `/api/*` endpoints available on a device can be accessed through the station proxy.

**Available Proxied Endpoints:**
| Endpoint | Description |
|----------|-------------|
| `/{callsign}/api/status` | Device status |
| `/{callsign}/api/log` | Device logs |
| `/{callsign}/api/dm/conversations` | DM conversations |
| `/{callsign}/api/dm/{target}/messages` | DM messages with a target |
| `/{callsign}/api/chat/{roomId}/messages` | Chat messages |
| `/{callsign}/api/devices` | Discovered devices (if debug API enabled) |

**Example Usage:**
```bash
# Get status of connected device X1ABCD (recommended format)
curl https://p2p.radio/X1ABCD/api/status

# Alternative format using /device/ prefix
curl https://p2p.radio/device/X1ABCD/api/status

# Get logs from a connected device
curl "https://p2p.radio/X1ABCD/api/log?limit=50"

# List DM conversations on a device
curl https://p2p.radio/X1ABCD/api/dm/conversations

# Check if a device is connected (without proxying)
curl https://p2p.radio/device/X1ABCD
```

---

### Alert File Upload/Download (Station)

Stations can store and serve alert photos uploaded from clients. These endpoints allow clients to upload photos when sharing alerts and download photos when syncing alerts.

#### POST /{callsign}/api/alerts/{folderName}/files/{filename}

Uploads a photo to the station's local storage for an alert.

**Parameters:**
| Parameter | Description |
|-----------|-------------|
| `callsign` | Callsign of the alert owner (uppercase) |
| `folderName` | Alert folder name (coordinate-based, e.g., `38_7222_n9_1393_broken-sidewalk`) |
| `filename` | Photo filename (e.g., `photo1.jpg`) |

**Headers:**
| Header | Description |
|--------|-------------|
| `Content-Type` | MIME type (e.g., `image/jpeg`, `image/png`) |
| `X-Callsign` | Sender's callsign (optional) |

**Request Body:** Binary image data.

**Response (201 Created):**
```json
{
  "success": true,
  "path": "/X1ABCD/alerts/38_7222_n9_1393_broken-sidewalk/photo1.jpg",
  "size": 12345
}
```

**Response (400 Bad Request):**
```json
{
  "success": false,
  "error": "Empty file"
}
```

#### GET /{callsign}/api/alerts/{folderName}

Returns detailed information about a specific alert, including list of photos.

**Parameters:**
| Parameter | Description |
|-----------|-------------|
| `callsign` | Callsign of the alert owner (uppercase) |
| `folderName` | Alert folder name (e.g., `38_7223_n9_1393_broken-sidewalk`) |

**Response (200 OK):**
```json
{
  "id": "38_7223_n9_1393_broken-sidewalk",
  "folder_name": "38_7223_n9_1393_broken-sidewalk",
  "title": "Broken Sidewalk",
  "description": "The sidewalk has a large crack near the bus stop.",
  "latitude": 38.7223,
  "longitude": -9.1393,
  "severity": "urgent",
  "status": "open",
  "type": "infrastructure-broken",
  "point_count": 3,
  "verification_count": 5,
  "pointed_by": ["npub1abc...", "npub1def..."],
  "verified_by": ["npub1ghi..."],
  "last_modified": "2025-12-14T10:30:00Z",
  "files": {
    "report.txt": { "size": 597, "mtime": 1734215746 },
    "images/": {
      "photo1.jpg": { "size": 160337, "mtime": 1734212897 },
      "photo2.png": { "size": 40135, "mtime": 1734212897 }
    },
    "feedback/": {
      "points.txt": { "size": 0, "mtime": 0 },
      "comments/": {
        "2025-12-14_10-35-00_X1ABCD.txt": { "size": 155, "mtime": 1734215746 }
      }
    }
  },
  "photos": ["images/photo1.jpg", "images/photo2.png"],
  "comments": [
    {
      "filename": "2025-12-14_10-35-00_X1ABCD.txt",
      "author": "X1ABCD",
      "created": "2025-12-14 10:35_00",
      "content": "I can confirm this issue is still present.",
      "npub": "npub1xyz...",
      "signature": "sig123..."
    }
  ],
  "comment_count": 1,
  "callsign": "X1ABCD",
  "report_content": "# REPORT: Broken Sidewalk\n..."
}
```

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Alert ID (same as folder_name) |
| `folder_name` | string | Alert folder name |
| `title` | string | Alert title (default language) |
| `description` | string | Alert description (default language) |
| `latitude` | float | Location latitude |
| `longitude` | float | Location longitude |
| `severity` | string | Severity: `info`, `attention`, `urgent`, `emergency` |
| `status` | string | Status: `open`, `inProgress`, `resolved`, `closed` |
| `type` | string | Alert type (e.g., `infrastructure-broken`) |
| `point_count` | int | Number of "points" (attention calls) |
| `verification_count` | int | Number of verifications |
| `pointed_by` | array | List of NPUBs who pointed the alert |
| `verified_by` | array | List of NPUBs who verified the alert |
| `last_modified` | string | ISO 8601 timestamp of last modification |
| `files` | object | File tree for synchronization (see below) |
| `photos` | array | List of photo filenames in the alert folder |
| `comments` | array | List of comment objects (see below) |
| `comment_count` | int | Number of comments |
| `callsign` | string | Alert owner's callsign |
| `report_content` | string | Raw report.txt content for sync |

**Files Object:**

The `files` field contains a recursive tree structure of all files in the alert folder, enabling efficient synchronization. Clients compare server `mtime` (Unix timestamp) with local file modification times to download only changed files.

| Key Format | Value | Description |
|------------|-------|-------------|
| `filename` | `{size, mtime}` | File with size in bytes and Unix timestamp |
| `dirname/` | `{nested files}` | Directory (trailing slash) containing nested file objects |

**Sync Algorithm:**
1. For each file in `files`, compare server `mtime` with local file `mtime`
2. If `server_mtime > local_mtime`, download the file via `GET /{callsign}/api/alerts/{alertId}/files/{path}`
3. Files with `mtime: 0` and `size: 0` are placeholders (non-existent files)

**Comment Object:**
| Field | Type | Description |
|-------|------|-------------|
| `filename` | string | Comment filename |
| `author` | string | Author's callsign |
| `created` | string | Creation timestamp (`YYYY-MM-DD HH:MM_ss`) |
| `content` | string | Comment text |
| `npub` | string | Author's NOSTR public key (optional) |
| `signature` | string | NOSTR signature (optional) |

**Response (404 Not Found):**
```json
{
  "error": "Alert not found"
}
```

**Feedback Note:** Feedback (points, verifications, reactions, comments) is centralized under `feedback/` and must be accessed via `/api/feedback/...` (see `docs/API_feedback.md`). Legacy `/api/alerts/{id}/{action}` feedback endpoints are deprecated and return `410 Gone`.

#### POST /{callsign}/api/alerts/{folderName}/comment (Deprecated)

This endpoint is no longer supported. Use `/api/feedback/alert/{alertId}/comment`.

#### GET /{callsign}/api/alerts/{folderName}/files/{filename}

Downloads a photo from the station's local storage.

**Parameters:**
| Parameter | Description |
|-----------|-------------|
| `callsign` | Callsign of the alert owner (uppercase) |
| `folderName` | Alert folder name |
| `filename` | Photo filename |

**Response (200 OK):** Binary image data with appropriate `Content-Type`.

**Response (404 Not Found):**
```json
{
  "error": "File not found",
  "path": "/path/to/expected/file"
}
```

**Example Usage:**
```bash
# Get alert details with photos list
curl http://localhost:3457/X1ABCD/api/alerts/38_7222_n9_1393_broken-sidewalk

# Upload a photo to station
curl -X POST http://localhost:3457/X1ABCD/api/alerts/38_7222_n9_1393_broken-sidewalk/files/photo1.jpg \
  -H "Content-Type: image/jpeg" \
  -H "X-Callsign: X1ABCD" \
  --data-binary @photo1.jpg

# Download a photo from station
curl -o photo1.jpg http://localhost:3457/X1ABCD/api/alerts/38_7222_n9_1393_broken-sidewalk/files/photo1.jpg
```

**Note:** The station port is typically API port + 1 (e.g., if API is on 3456, station is on 3457).

---

### Feedback

Centralized feedback endpoints for alerts, blog posts, and places. Feedback is stored under each content item's `feedback/` folder (see `docs/API_feedback.md`) and uses signed NOSTR events for verification.

#### GET /api/feedback/{contentType}/{contentId}

Returns feedback counts and optional user state/comments.

**Query Parameters:**
| Parameter | Description |
|-----------|-------------|
| `callsign` | Optional owner callsign to disambiguate content |
| `npub` | Optional; include user_state for this npub |
| `include_comments` | `true` to include comments |
| `comment_limit` | Max comments to return (default 20) |
| `comment_offset` | Offset for pagination (default 0) |

**Response (200 OK):**
```json
{
  "success": true,
  "content_type": "alert",
  "content_id": "2025-12-10_broken-sidewalk",
  "owner": "X1ABCD",
  "counts": {
    "likes": 3,
    "points": 2,
    "dislikes": 0,
    "subscribe": 1,
    "verifications": 1,
    "views": 12,
    "heart": 0,
    "thumbs-up": 1,
    "fire": 0,
    "celebrate": 0,
    "laugh": 0,
    "sad": 0,
    "surprise": 0,
    "comments": 4
  },
  "user_state": {
    "liked": true,
    "pointed": false,
    "disliked": false,
    "subscribed": true,
    "verified": false,
    "heart": false,
    "thumbs-up": false,
    "fire": false,
    "celebrate": false,
    "laugh": false,
    "sad": false,
    "surprise": false
  }
}
```

#### GET /api/feedback/{contentType}/{contentId}/stats

Returns aggregated view stats and counts.

#### POST /api/feedback/{contentType}/{contentId}/{action}

Posts feedback actions. Actions and payloads:

- `like|point|dislike|subscribe|react/{emoji}`: signed NOSTR event JSON (toggle)
- `verify`: signed NOSTR event JSON (add-only)
- `view`: signed NOSTR event JSON (append-only)
- `comment`: JSON body with `author`, `content`, optional `npub`, `signature`

**Example (comment):**
```json
{
  "author": "X1ABCD",
  "content": "I can confirm this issue is still present.",
  "npub": "npub1xyz...",
  "signature": "sig123..."
}
```

**Example (toggle with signed event):**
```json
{
  "id": "eventid...",
  "pubkey": "hexpub...",
  "created_at": 1734937020,
  "kind": 7,
  "tags": [["content_type","alert"],["content_id","2025-12-10_broken-sidewalk"],["action","point"]],
  "content": "point",
  "sig": "hexsig..."
}
```

---

### Software Updates

The station can mirror software releases from GitHub, allowing clients to download updates without internet access (offgrid-first).

#### GET /api/updates/latest

Returns information about the latest cached release.

**Response - Update Available (200 OK):**
```json
{
  "status": "available",
  "version": "1.5.36",
  "tagName": "v1.5.36",
  "name": "Release 1.5.36",
  "body": "## Changelog\n- New feature...\n- Bug fix...",
  "publishedAt": "2024-12-08T10:00:00Z",
  "htmlUrl": "https://github.com/geograms/geogram-desktop/releases/tag/v1.5.36",
  "assets": {
    "android-apk": "/updates/1.5.36/geogram.apk",
    "android-aab": "/updates/1.5.36/app-release.aab",
    "linux-desktop": "/updates/1.5.36/geogram-linux-x64.tar.gz",
    "linux-cli": "/updates/1.5.36/geogram-cli-linux-x64.tar.gz",
    "windows-desktop": "/updates/1.5.36/geogram-windows-x64.zip",
    "macos-desktop": "/updates/1.5.36/geogram-macos-x64.zip",
    "ios-unsigned": "/updates/1.5.36/geogram-ios-unsigned.ipa",
    "web": "/updates/1.5.36/geogram-web.tar.gz"
  },
  "assetFilenames": {
    "android-apk": "geogram.apk",
    "android-aab": "app-release.aab",
    "linux-desktop": "geogram-linux-x64.tar.gz",
    "linux-cli": "geogram-cli-linux-x64.tar.gz",
    "windows-desktop": "geogram-windows-x64.zip",
    "macos-desktop": "geogram-macos-x64.zip",
    "ios-unsigned": "geogram-ios-unsigned.ipa",
    "web": "geogram-web.tar.gz"
  }
}
```

**Response - No Updates Cached (200 OK):**
```json
{
  "status": "no_updates_cached",
  "message": "Station has not downloaded any updates yet"
}
```

#### GET /updates/{version}/{filename}

Downloads a specific binary file from the version archive.

**Parameters:**
| Parameter | Description |
|-----------|-------------|
| `version` | Release version number (e.g., `1.5.36`) |
| `filename` | The original filename of the asset |

**Available Files:**
| Filename | Description | Size |
|----------|-------------|------|
| `geogram.apk` | Android APK installer | ~80 MB |
| `app-release.aab` | Android App Bundle (Play Store) | ~55 MB |
| `geogram-linux-x64.tar.gz` | Linux desktop application | ~22 MB |
| `geogram-cli-linux-x64.tar.gz` | Linux CLI tool | ~4 MB |
| `geogram-windows-x64.zip` | Windows desktop application | ~18 MB |
| `geogram-macos-x64.zip` | macOS desktop application | ~83 MB |
| `geogram-ios-unsigned.ipa` | iOS unsigned IPA | ~14 MB |
| `geogram-web.tar.gz` | Web build archive | ~13 MB |

**Response Headers:**
| Header | Value |
|--------|-------|
| `Content-Type` | Appropriate MIME type (e.g., `application/vnd.android.package-archive`) |
| `Content-Length` | File size in bytes |
| `Content-Disposition` | `attachment; filename="<filename>"` |

**Response (200 OK):** Binary file content.

**Response (404 Not Found):** File not found.

**Example Usage:**
```bash
# Check for updates
curl http://192.168.1.100:8080/api/updates/latest

# Download Android APK (version 1.5.36)
curl -O http://192.168.1.100:8080/updates/1.5.36/geogram.apk

# Download Linux desktop
curl -O http://192.168.1.100:8080/updates/1.5.36/geogram-linux-x64.tar.gz

# Download with wget and resume support
wget -c http://192.168.1.100:8080/updates/1.5.36/geogram.apk

# Browse available versions
ls /path/to/station/updates/
# 1.5.34/  1.5.35/  1.5.36/
```

---

### Map Tiles

#### GET /tiles/{callsign}/{z}/{x}/{y}.png

Serves cached map tiles.

**Parameters:**
| Parameter | Description |
|-----------|-------------|
| `callsign` | Station callsign |
| `z` | Zoom level (0-18) |
| `x` | Tile X coordinate |
| `y` | Tile Y coordinate |

**Query Parameters:**
| Parameter | Default | Description |
|-----------|---------|-------------|
| `layer` | `standard` | Tile layer: `standard` (OSM) or `satellite` (Esri) |

**Response (200 OK):** PNG image data.

**Response (404 Not Found):** Tile not found and OSM fallback disabled.

**Example:**
```bash
# Get a standard OSM tile
curl -o tile.png "http://192.168.1.100:8080/tiles/STATION-42/10/512/384.png"

# Get a satellite tile
curl -o tile.png "http://192.168.1.100:8080/tiles/STATION-42/10/512/384.png?layer=satellite"
```

**Tile Sources:**
- Standard: OpenStreetMap (`tile.openstreetmap.org`)
- Satellite: Esri World Imagery (`server.arcgisonline.com`)

---

### Road Data (Offline Navigation)

#### GET /api/roads

Returns cached OSM road network data for offline routing. The station fetches from Overpass API if not cached.

**Query Parameters:**
| Parameter | Description |
|-----------|-------------|
| `south` | Southern latitude of bounding box |
| `west` | Western longitude of bounding box |
| `north` | Northern latitude of bounding box |
| `east` | Eastern longitude of bounding box |

**Response (200 OK):** Overpass API JSON with nodes and ways.

**Response (503):** OSM fallback disabled.

**Example:**
```bash
# Get road data for Lisbon area
curl "http://192.168.1.100:8080/api/roads?south=38.6&west=-9.3&north=38.8&east=-9.0"
```

#### Debug: Map Search

Test the map search bar via the debug API:

```bash
# Search by place name
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "map_search", "query": "Lisbon"}'

# Search by coordinates
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "map_search", "query": "38.72, -9.14"}'

# Calculate route from current map center to coordinates (auto-downloads road data)
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "map_route", "toLat": 38.75, "toLon": -9.15, "mode": "driving"}'

# Walking route
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "map_route", "toLat": 38.75, "toLon": -9.15, "mode": "walking"}'
```

---

### Chat

#### GET /api/chat/rooms

Returns list of available chat rooms.

**Response (200 OK):**
```json
{
  "station": "STATION-42",
  "rooms": [
    {
      "id": "general",
      "name": "General",
      "description": "General discussion",
      "member_count": 5,
      "is_public": true
    }
  ]
}
```

#### GET /api/chat/{roomId}/messages

Returns messages for a specific chat room.

**Parameters:**
| Parameter | Description |
|-----------|-------------|
| `roomId` | Room identifier (e.g., `main`) |

**Response (200 OK):**
```json
{
  "roomId": "main",
  "messages": [],
  "count": 0,
  "hasMore": false,
  "limit": 50
}
```

**Note:** Only PUBLIC rooms are accessible without authentication. PRIVATE and RESTRICTED rooms require NOSTR authentication.

#### POST /api/chat/{roomId}/messages

Posts a message to a chat room.

**Response (201 Created):**
```json
{
  "status": "ok"
}
```

**Note:** Posting to RESTRICTED rooms requires NOSTR authentication with the sender's npub in the authorized participants list.

**Message metadata (stored in chat files):**
- `file`: Attached filename under the room `files/` folder
- `quote`: Timestamp of the quoted message
- `quote_author`: Callsign of the quoted author
- `quote_excerpt`: Short excerpt for display
- Reactions are stored as unsigned lines after the signature:
  - `~~> reaction: thumbs-up=X1AAA,X1BBB`

Images are attached as files; clients may render them inline based on file extension.

#### POST /api/chat/{roomId}/messages/{timestamp}/reactions

Toggle a reaction on a message (requires NOSTR auth).

**Required NOSTR tags:**
- `action=react`
- `room={roomId}`
- `timestamp={message_timestamp}`
- `reaction={reactionName}`
- `callsign={yourCallsign}`

#### GET /api/chat/{roomId}/roles

Returns room roles for moderation (requires NOSTR auth).

#### POST /api/chat/{roomId}/promote

Promotes a member to `moderator` or `admin` (requires NOSTR event with `promote` action).

#### POST /api/chat/{roomId}/demote

Demotes a member (requires NOSTR event with `demote` action).

#### POST /api/chat/{roomId}/ban/{npub}

Bans a member (requires NOSTR event with `ban` action).

#### DELETE /api/chat/{roomId}/ban/{npub}

Unbans a member (requires NOSTR event with `unban` action).

---

### Direct Messages

Direct messages (DMs) enable 1:1 communication between devices. DMs are implemented as **RESTRICTED chat rooms** using the standard chat API.

#### DM Architecture

DMs use a symmetric room ID system:
- **Device A (callsign "ALICE")** has a room named **"BOB"** for chatting with BOB
- **Device B (callsign "BOB")** has a room named **"ALICE"** for chatting with ALICE

Both devices store messages in their own `chat/{OTHER_CALLSIGN}/` directory.

**To send a DM via the Chat API:**
```bash
# ALICE sends a message to BOB
# POST to BOB's device: /api/chat/ALICE/messages
# (The room on BOB's device is named "ALICE")
curl -X POST http://BOB_DEVICE_IP:3456/api/chat/ALICE/messages \
  -H "Content-Type: application/json" \
  -d '{
    "event": {
      "pubkey": "ALICE_HEX_PUBKEY",
      "created_at": 1733745600,
      "kind": 1,
      "tags": [["t", "chat"], ["room", "ALICE"], ["callsign", "ALICE"]],
      "content": "Hello BOB!",
      "sig": "NOSTR_SIGNATURE"
    }
  }'
```

**Response (200 OK):**
```json
{
  "success": true,
  "timestamp": "2024-12-09 10:00_00",
  "author": "ALICE"
}
```

The receiving device auto-creates the DM channel if it doesn't exist.

#### Legacy DM API (Deprecated)

The following endpoints are kept for backward compatibility but the chat API is preferred:

#### GET /api/dm/conversations

Returns list of all DM conversations.

**Response (200 OK):**
```json
{
  "conversations": [
    {
      "callsign": "REMOTE-42",
      "myCallsign": "USER-123",
      "lastMessage": "2024-12-09T10:30:00Z",
      "lastMessagePreview": "Hello!",
      "lastMessageAuthor": "USER-123",
      "unread": 2,
      "isOnline": true,
      "lastSyncTime": "2024-12-09T10:00:00Z"
    }
  ],
  "total": 1
}
```

#### GET /api/dm/{callsign}/messages

Returns direct messages with a specific device.

**Parameters:**
| Parameter | Description |
|-----------|-------------|
| `callsign` | Target device's callsign |

**Query Parameters:**
| Parameter | Default | Description |
|-----------|---------|-------------|
| `limit` | 100 | Maximum messages to return (1-500) |

**Response (200 OK):**
```json
{
  "targetCallsign": "REMOTE-42",
  "messages": [
    {
      "author": "USER-123",
      "timestamp": "2024-12-09 10:30_15",
      "content": "Hello!",
      "npub": "npub1abc...",
      "signature": "3a4f8c92...",
      "verified": true
    }
  ],
  "count": 1
}
```

#### POST /api/dm/{callsign}/messages

Sends a direct message to a device. Messages are signed with the sender's NOSTR key.

**Parameters:**
| Parameter | Description |
|-----------|-------------|
| `callsign` | Target device's callsign |

**Request Body:**
```json
{
  "content": "Hello from the API!"
}
```

**Response (200 OK):**
```json
{
  "success": true,
  "targetCallsign": "REMOTE-42",
  "timestamp": "2024-12-09T10:30:15Z"
}
```

#### GET /api/dm/{callsign}/retention

Gets the current message retention (disappearing messages) setting for a DM conversation.

**Parameters:**
| Parameter | Description |
|-----------|-------------|
| `callsign` | Target device's callsign |

**Response (200 OK):**
```json
{
  "callsign": "CR7BBQ",
  "retention": "1w",
  "label": "1 week"
}
```

Valid retention values: `1d` (1 day), `1w` (1 week), `1m` (1 month), `1y` (1 year), `forever` (keep all).

#### POST /api/dm/{callsign}/retention

Sets the message retention period for a DM conversation. Updates local config, sends a signed control event to the other device, and immediately purges expired messages.

**Request Body:**
```json
{
  "retention": "1w"
}
```

**Response (200 OK):**
```json
{
  "success": true,
  "callsign": "CR7BBQ",
  "retention": "1w",
  "label": "1 week"
}
```

#### GET /api/dm/sync/{callsign}

Gets messages for synchronization with a remote device.

**Parameters:**
| Parameter | Description |
|-----------|-------------|
| `callsign` | Target device's callsign |

**Query Parameters:**
| Parameter | Description |
|-----------|-------------|
| `since` | ISO timestamp to get messages since |

**Response (200 OK):**
```json
{
  "messages": [...],
  "timestamp": "2024-12-09T10:30:00Z"
}
```

#### POST /api/dm/sync/{callsign}

Receives and merges messages from a remote device during sync.

**Request Body:**
```json
{
  "messages": [
    {
      "author": "REMOTE-42",
      "timestamp": "2024-12-09 10:25_00",
      "content": "Hello back!",
      "npub": "npub1xyz...",
      "signature": "5e1a9c6f..."
    }
  ]
}
```

**Response (200 OK):**
```json
{
  "success": true,
  "accepted": 1,
  "timestamp": "2024-12-09T10:30:00Z"
}
```

---

### Apps Discovery

#### GET /api/apps

Returns all available apps on this device with availability and item counts. This is a fast, single-call alternative to querying each app endpoint individually.

**Response (200 OK):**
```json
{
  "success": true,
  "timestamp": 1709500000,
  "apps": {
    "blog": {"available": true, "count": 5},
    "chat": {"available": true, "count": 2},
    "events": {"available": false, "count": 0},
    "alerts": {"available": true, "count": 1},
    "shared": {"available": true, "count": 3}
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `apps` | object | Map of app type to availability info |
| `apps.{type}.available` | bool | Whether the app has any content |
| `apps.{type}.count` | int | Number of items (posts, rooms, events, etc.) |

---

### Blog

The Blog API provides access to blog posts stored on a device. Posts are stored in a folder-based structure with comments in separate files.

For detailed specifications, see [Blog Format Specification](apps/blog-format-specification.md).

#### GET /{identifier}/blog/{filename}.html

Serves a user's blog post as HTML.

**Parameters:**
| Parameter | Description |
|-----------|-------------|
| `identifier` | User's nickname or callsign |
| `filename` | Blog post filename (without `.html` extension) |

**Response (200 OK):** HTML page with the blog post content (rendered from Markdown).

**Response (404 Not Found):** User or blog post not found.

**Example:**
```bash
curl http://192.168.1.100:8080/alice/blog/my-first-post.html
```

#### GET /api/blog

Returns list of all published blog posts.

**Query Parameters:**
| Parameter | Default | Description |
|-----------|---------|-------------|
| `year` | (all) | Filter by year (e.g., `2025`) |
| `tag` | (all) | Filter by tag |
| `limit` | (all) | Max posts to return |
| `offset` | 0 | Pagination offset |

**Response (200 OK):**
```json
{
  "success": true,
  "timestamp": 1734344400,
  "total": 5,
  "count": 5,
  "posts": [
    {
      "id": "2025-12-04_hello-everyone",
      "title": "Hello Everyone",
      "author": "CR7BBQ",
      "timestamp": "2025-12-04 10:00_00",
      "status": "published",
      "tags": ["welcome"],
      "comment_count": 2
    }
  ]
}
```

#### GET /api/blog/{postId}

Returns full details for a specific blog post including comments.

**Parameters:**
| Parameter | Description |
|-----------|-------------|
| `postId` | Post ID in format `YYYY-MM-DD_title-slug` |

**Response (200 OK):**
```json
{
  "success": true,
  "id": "2025-12-04_hello-everyone",
  "title": "Hello Everyone",
  "author": "CR7BBQ",
  "timestamp": "2025-12-04 10:00_00",
  "status": "published",
  "tags": ["welcome"],
  "content": "Welcome to my blog...",
  "comments": [
    {
      "id": "2025-12-04_11-30-45_X13K0G",
      "author": "X13K0G",
      "timestamp": "2025-12-04 11:30_45",
      "content": "Great post!"
    }
  ],
  "comment_count": 1
}
```

#### POST /api/blog/{postId}/comment

Add a comment to a published blog post.

**Request Body:**
```json
{
  "author": "X13K0G",
  "content": "Great post!",
  "npub": "npub1abc...",
  "signature": "hex_signature"
}
```

**Response (200 OK):**
```json
{
  "success": true,
  "comment_id": "2025-12-04_11-30-45_X13K0G",
  "timestamp": "2025-12-04T11:30:45Z"
}
```

**Error Responses:**
- `400` - Missing required field (author or content)
- `403` - Cannot comment on unpublished post
- `404` - Post not found

#### DELETE /api/blog/{postId}/comment/{commentId}

Delete a comment from a blog post. Requires authorization via X-Npub header.

**Headers:**
| Header | Description |
|--------|-------------|
| `X-Npub` | Requester's NOSTR public key |

**Response (200 OK):**
```json
{
  "success": true,
  "deleted": true
}
```

**Error Responses:**
- `401` - Missing X-Npub header
- `403` - Unauthorized (not post author or comment author)
- `404` - Post or comment not found

#### GET /api/blog/{postId}/files/{filename}

Get an attached file from a blog post.

**Response (200 OK):** File content with appropriate Content-Type header.

**Response (404 Not Found):** File not found.

#### POST /api/blog/{postId}/like

Toggle like on a blog post using a NOSTR-signed event. Requires a NIP-07 compatible browser extension (e.g., Alby, nos2x) for signing.

**Request Body:** A NOSTR kind 7 reaction event signed by the user's extension:
```json
{
  "pubkey": "hex_public_key",
  "created_at": 1736784000,
  "kind": 7,
  "tags": [
    ["p", "author_npub"],
    ["e", "post_id"],
    ["type", "likes"]
  ],
  "content": "like",
  "id": "event_id_hash",
  "sig": "schnorr_signature"
}
```

**Response (200 OK):**
```json
{
  "success": true,
  "liked": true,
  "like_count": 5
}
```

The `liked` field indicates the new state after toggling:
- `true` - User's like was added
- `false` - User's like was removed (unliked)

**Error Responses:**
- `400` - Invalid event format or missing signature
- `401` - Signature verification failed
- `404` - Post not found

**Web Browser Integration:**

When viewing a blog post in a web browser with a NOSTR extension installed:
1. The page detects the extension via `window.nostr` (NIP-07)
2. User clicks the Like button
3. Extension prompts for signature approval
4. Signed event is sent to this endpoint
5. UI updates to show liked state (filled heart)

The like state persists across page refreshes - users see a filled heart icon if they've already liked the post.

---

### Events

The Events API provides read-only access to events stored on a device. Events are community gatherings, meetups, or other scheduled activities.

For detailed specifications, see [Event Format Specification](apps/event-format-specification.md).

#### GET /api/events

Returns list of all events.

**Query Parameters:**
| Parameter | Default | Description |
|-----------|---------|-------------|
| `year` | (all) | Filter by year (e.g., `2025`) |

**Response (200 OK):**
```json
{
  "events": [
    {
      "id": "2025-01-15_community-meetup",
      "title": "Community Meetup",
      "author": "X1ABCD",
      "timestamp": "2025-01-15 14:00_00",
      "location": "online",
      "location_name": null,
      "start_date": null,
      "end_date": null,
      "visibility": "public",
      "like_count": 5,
      "comment_count": 2,
      "has_flyer": true,
      "has_trailer": false,
      "update_count": 0,
      "going_count": 12,
      "interested_count": 8
    }
  ],
  "total": 1,
  "filters": {
    "year": 2025
  }
}
```

#### GET /api/events/{eventId}

Returns full details for a specific event.

**Parameters:**
| Parameter | Description |
|-----------|-------------|
| `eventId` | Event ID in format `YYYY-MM-DD_title-slug` |

**Response (200 OK):**
```json
{
  "id": "2025-01-15_community-meetup",
  "title": "Community Meetup",
  "author": "X1ABCD",
  "timestamp": "2025-01-15 14:00_00",
  "content": "Join us for our monthly community meetup!",
  "location": "online",
  "location_name": null,
  "start_date": null,
  "end_date": null,
  "agenda": null,
  "visibility": "public",
  "admins": ["npub1abc..."],
  "moderators": [],
  "likes": ["X2BCDE", "X3CDEF"],
  "comments": [],
  "flyers": ["flyer.jpg"],
  "trailer": null,
  "updates": [],
  "registration": {
    "going": [{"callsign": "X2BCDE", "npub": "npub1xyz..."}],
    "interested": []
  },
  "links": [],
  "npub": "npub1abc...",
  "signature": "hex_signature..."
}
```

**Response (404 Not Found):**
```json
{
  "error": "Event not found",
  "event_id": "2025-01-15_invalid-event"
}
```

#### GET /api/events/{eventId}/files/{path}

Returns a file associated with an event (flyer image, trailer video, etc.).

**Parameters:**
| Parameter | Description |
|-----------|-------------|
| `eventId` | Event ID in format `YYYY-MM-DD_title-slug` |
| `path` | File path relative to event folder |

**Response (200 OK):** Binary file content with appropriate Content-Type.

**Response (404 Not Found):** File not found.

---

### Alerts

The Alerts API provides read-only access to alerts (reports) stored on a device. Alerts are community-reported incidents, hazards, or issues with geographic location.

For detailed specifications, see [Alert Format Specification](apps/alert-format-specification.md).

#### GET /api/alerts

Returns list of all alerts with optional filtering.

**Query Parameters:**
| Parameter | Default | Description |
|-----------|---------|-------------|
| `status` | (all) | Filter by status: `open`, `inProgress`, `resolved`, `closed` |
| `lat` | (none) | Latitude for geographic filtering (requires `lon` and `radius`) |
| `lon` | (none) | Longitude for geographic filtering (requires `lat` and `radius`) |
| `radius` | (none) | Radius in km for geographic filtering (max 500) |

**Response (200 OK):**
```json
{
  "alerts": [
    {
      "id": "2025-12-10_broken-sidewalk",
      "title": "Broken Sidewalk",
      "author": "X1ABCD",
      "created": "2025-12-10 14:30_00",
      "latitude": 38.7222,
      "longitude": -9.1393,
      "severity": "urgent",
      "type": "infrastructure-broken",
      "status": "open",
      "address": "Rua Example 123, Lisbon",
      "verification_count": 5,
      "point_count": 3,
      "has_photos": true
    }
  ],
  "total": 1,
  "filters": {
    "status": "open",
    "lat": 38.72,
    "lon": -9.14,
    "radius_km": 50.0
  }
}
```

**Note:** Coordinates in API responses are truncated to 4 decimal places (~11m precision) for privacy.

#### GET /api/alerts/{alertId}

Returns full details for a specific alert.

**Parameters:**
| Parameter | Description |
|-----------|-------------|
| `alertId` | Alert ID in format `YYYY-MM-DD_title-slug` |

**Response (200 OK):**
```json
{
  "id": "2025-12-10_broken-sidewalk",
  "title": "Broken Sidewalk",
  "title_translations": {
    "EN": "Broken Sidewalk",
    "PT": "Passeio Danificado"
  },
  "description": "The sidewalk has a large crack near the bus stop.",
  "description_translations": {
    "EN": "The sidewalk has a large crack near the bus stop.",
    "PT": "O passeio tem uma grande fissura perto da paragem de autocarro."
  },
  "author": "X1ABCD",
  "created": "2025-12-10 14:30_00",
  "latitude": 38.7222,
  "longitude": -9.1393,
  "severity": "urgent",
  "type": "infrastructure-broken",
  "status": "open",
  "address": "Rua Example 123, Lisbon",
  "contact": "city-services@example.com",
  "verified_by": ["npub1abc...", "npub1def..."],
  "verification_count": 5,
  "pointed_by": ["npub1ghi..."],
  "point_count": 3,
  "admins": ["npub1author..."],
  "moderators": [],
  "ttl": 2592000,
  "expires": "2026-01-10 14:30_00",
  "photos": ["photo1.jpg", "photo2.jpg"],
  "npub": "npub1author...",
  "signature": "hex_signature..."
}
```

**Response (404 Not Found):**
```json
{
  "error": "Alert not found",
  "alert_id": "2025-12-10_invalid-alert"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Alert ID (format: `YYYY-MM-DD_title-slug`) |
| `title` | string | Alert title (default language) |
| `title_translations` | object | Title in multiple languages |
| `description` | string | Alert description (default language) |
| `description_translations` | object | Description in multiple languages |
| `author` | string | Author's callsign |
| `created` | string | Creation timestamp (`YYYY-MM-DD HH:MM_ss`) |
| `latitude` | float | Location latitude (4 decimal places) |
| `longitude` | float | Location longitude (4 decimal places) |
| `severity` | string | Severity: `info`, `attention`, `urgent`, `emergency` |
| `type` | string | Alert type (e.g., `infrastructure-broken`, `safety-hazard`) |
| `status` | string | Status: `open`, `inProgress`, `resolved`, `closed` |
| `address` | string | Human-readable address (optional) |
| `contact` | string | Contact information (optional) |
| `verified_by` | array | List of NPUBs who verified the alert |
| `verification_count` | int | Number of verifications |
| `pointed_by` | array | List of NPUBs who pointed (called attention to) the alert |
| `point_count` | int | Number of points (attention calls) |
| `admins` | array | List of admin NPUBs |
| `moderators` | array | List of moderator NPUBs |
| `ttl` | int | Time-to-live in seconds (optional) |
| `expires` | string | Expiration timestamp (optional) |
| `photos` | array | List of photo filenames |
| `npub` | string | Author's NOSTR public key |
| `signature` | string | NOSTR signature |

#### GET /api/alerts/{alertId}/files/{filename}

Returns a file associated with an alert (photo).

**Parameters:**
| Parameter | Description |
|-----------|-------------|
| `alertId` | Alert ID in format `YYYY-MM-DD_title-slug` |
| `filename` | Photo filename (e.g., `photo1.jpg`) |

**Response (200 OK):** Binary file content with appropriate Content-Type (e.g., `image/jpeg`).

**Response (404 Not Found):** File not found.

**Example Usage:**
```bash
# List all alerts
curl http://localhost:3456/api/alerts

# Filter by status
curl "http://localhost:3456/api/alerts?status=open"

# Filter by location (50km radius around Lisbon)
curl "http://localhost:3456/api/alerts?lat=38.72&lon=-9.14&radius=50"

# Get specific alert details
curl http://localhost:3456/api/alerts/2025-12-10_broken-sidewalk

# Download alert photo
curl -o photo.jpg http://localhost:3456/api/alerts/2025-12-10_broken-sidewalk/files/photo1.jpg
```

---

### Logs

#### GET /log

Returns application logs with optional filtering and pagination.

**Base URL:** `http://localhost:3456/log`

**Query Parameters:**
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `filter` | string | (none) | Filter logs containing this text (case-insensitive) |
| `limit` | int | 100 | Maximum number of log entries to return |

**Response (200 OK):**
```json
{
  "filter": "BLE",
  "limit": 20,
  "count": 15,
  "logs": [
    "[2024-12-08 10:00:00] BLEDiscovery: Started scanning...",
    "[2024-12-08 10:00:01] BLEDiscovery: Found device X164GH",
    "[2024-12-08 10:00:02] BLEDiscovery: Connected to device"
  ]
}
```

**Example Usage:**
```bash
# Get last 100 logs
curl http://localhost:3456/log

# Filter logs containing "BLE"
curl "http://localhost:3456/log?filter=BLE&limit=50"

# Get service-related logs
curl "http://localhost:3456/log?filter=Service&limit=20"
```

---

### Karma API

The Karma API provides gamification features — points, streaks, levels, and leaderboards. Points are awarded automatically for user actions (login, chat, content creation, feedback).

#### Public Endpoints (no auth required)

##### GET /api/karma/stats
Station-wide karma statistics.

##### GET /api/karma/leaderboard/{period}
Leaderboard for a period: `weekly`, `monthly`, `yearly`, `alltime`. Query: `?limit=20`.

#### Authenticated Endpoints (require `Authorization: Nostr <base64_signed_event>`)

##### GET /api/karma/profile/{callsign}
User's karma profile: points, level, streak, today's activity, rank.

##### GET /api/karma/history/{callsign}
Point history (paginated). Query: `?limit=50&offset=0`.

##### GET /api/karma/streak/{callsign}
Streak details: current streak, longest streak, multiplier.

#### Debug Endpoints (localhost only)

##### GET /api/karma/debug
List available debug endpoints.

##### POST /api/karma/debug/award
Manually award karma points.
```json
{"callsign": "X1SU86", "action": "daily_login", "meta": {}}
```
Available actions: `daily_login`, `chat_message`, `chat_reaction`, `blog_published`, `place_created`, `alert_created`, `event_created`, `like_given`, `like_received`, `comment_given`, `comment_received`, `verify_given`, `alert_verified`.

##### GET /api/karma/debug/profile/{callsign}
Get profile without NOSTR auth (debug only).

##### GET /api/karma/debug/history/{callsign}
Get history without NOSTR auth (debug only).

##### POST /api/karma/debug/recompute
Force immediate leaderboard recomputation.

---

### Debug API

The Debug API allows triggering actions in the Geogram desktop client remotely. This is useful for automation, testing, and integration with external tools.

**Base URL:** `http://localhost:3456/api/debug`

#### GET /api/debug

Returns available debug actions and recent action history.

**Response (200 OK):**
```json
{
  "service": "Geogram Debug API",
  "version": "1.5.47",
  "callsign": "USER-123",
  "available_actions": [
    {
      "action": "navigate",
      "description": "Navigate to a panel",
      "params": {
        "panel": "Panel name: collections, maps, devices, settings, logs"
      }
    },
    {
      "action": "ble_scan",
      "description": "Start BLE device discovery scan",
      "params": {}
    },
    {
      "action": "ble_advertise",
      "description": "Start BLE advertising",
      "params": {
        "callsign": "(optional) Callsign to advertise"
      }
    },
    {
      "action": "ble_hello",
      "description": "Send HELLO handshake to a BLE device",
      "params": {
        "device_id": "(optional) BLE device ID to connect to, or first discovered device"
      }
    },
    {
      "action": "refresh_devices",
      "description": "Refresh all devices (BLE, local network, station)",
      "params": {}
    },
    {
      "action": "local_scan",
      "description": "Scan local network for devices",
      "params": {}
    },
    {
      "action": "connect_station",
      "description": "Connect to a station",
      "params": {
        "url": "(optional) Station WebSocket URL"
      }
    },
    {
      "action": "disconnect_station",
      "description": "Disconnect from current station",
      "params": {}
    }
  ],
  "recent_actions": [],
  "panels": {
    "collections": 0,
    "maps": 1,
    "devices": 2,
    "settings": 3,
    "logs": 4
  }
}
```

#### POST /api/debug

Triggers a debug action.

**Request Body:**
```json
{
  "action": "action_name",
  "param1": "value1"
}
```

**Available Actions:**

| Action | Description | Parameters |
|--------|-------------|------------|
| `navigate` | Navigate to a UI panel | `panel`: Panel name (collections, maps, devices, settings, logs) |
| `toast` | Show a toast/snackbar message on the UI | `message`: Text to display, `duration` (optional): Seconds (default: 3) |
| `ble_scan` | Start BLE device discovery | None |
| `ble_advertise` | Start BLE advertising | `callsign` (optional): Callsign to advertise |
| `ble_hello` | Send BLE HELLO handshake to a device | `device_id` (optional): Target device ID, or first discovered device |
| `ble_send` | Send test data to a BLE device | `device_id` (optional), `data` (optional): String, `size` (optional): Bytes |
| `refresh_devices` | Refresh all device sources | None |
| `local_scan` | Scan local network for devices | None |
| `connect_station` | Connect to a station | `url` (optional): Station WebSocket URL |
| `disconnect_station` | Disconnect from current station | None |
| `bot_download_model` | Download a bot model via TransferService | `model_type` (required): vision or music, `model_id` (required), `station_url` (optional), `station_callsign` (optional) |
| `send_dm` | Send a direct message | `callsign`: Target callsign (required), `content`: Message (required) |
| `sync_dm` | Sync DMs with a device | `callsign`: Target callsign (required), `url` (optional): Device URL |
| `open_dm` | Open DM conversation UI with a device | `callsign`: Target device callsign (required) |
| `send_dm_file` | Send a file in a direct message | `callsign`: Target callsign (required), `file_path`: Absolute path to file (required) |
| `voice_record` | Record audio for testing | `duration` (optional): Seconds to record (default: 5) |
| `voice_stop` | Stop recording and get file path | None |
| `voice_status` | Get recording/playback status | None |
| `backup_provider_enable` | Enable backup provider mode | `max_storage_bytes` (optional): Max total storage, `max_client_storage` (optional): Per-client limit, `max_snapshots` (optional): Max snapshots per client |
| `backup_create_test_data` | Create random test files for backup testing | `file_count` (optional): Number of files (default: 10), `max_file_size` (optional): Max bytes per file (default: 10240) |
| `backup_send_invite` | Send backup invite to a provider | `provider_callsign` (required): Target provider callsign, `interval_days` (optional): Backup interval (default: 3) |
| `backup_accept_invite` | Accept a pending backup invite (provider side) | `client_callsign` (required): Client to accept |
| `backup_start` | Start backup to a provider | `provider_callsign` (required): Target provider |
| `backup_get_status` | Get current backup/restore status | None |
| `backup_restore` | Start restore from a provider snapshot | `provider_callsign` (required): Provider callsign, `snapshot_id` (required): Snapshot date (YYYY-MM-DD) |
| `backup_list_snapshots` | List available snapshots for a client | `client_callsign` (required): Client callsign |
| `event_create` | Create an event for testing | `title` (required): Event title, `content` (required): Event content, `location` (required): "online" or "lat,lon", `app_name` (optional): App name (default: "my-events"), `location_name` (optional): Venue name |
| `event_list` | List all events | `year` (optional): Filter by year |
| `event_delete` | Delete an event | `event_id` (required): Event ID (e.g., "2025-01-15_party"), `app_name` (optional): App name (default: "my-events") |
| `alert_create` | Create an alert for testing | `title` (required): Alert title, `description` (required): Alert description, `latitude` (optional): Location lat, `longitude` (optional): Location lon, `severity` (optional): info/attention/urgent/emergency, `type` (optional): Alert type, `photo` (optional): If true, creates a test photo in the alert |
| `alert_share` | Share an alert to stations | `alert_id` (required): Alert ID (e.g., "38_7222_n9_1393_broken-sidewalk"). Shares the alert via NOSTR event and uploads photos to the station |
| `alert_sync` | Sync alerts from station | `lat` (optional): Latitude, `lon` (optional): Longitude, `radius` (optional): Radius in km, `use_since` (optional): Only fetch new alerts. Downloads alerts and photos from the connected station |
| `alert_list` | List all alerts | `status` (optional): Filter by status |
| `alert_delete` | Delete an alert | `alert_id` (required): Alert ID (e.g., "2025-12-10_broken-sidewalk") |
| `alert_point` | Point/unpoint an alert (call attention) | `alert_id` (required): Alert ID, `npub` (optional): User npub (uses profile npub if not provided) |
| `alert_comment` | Add a comment to an alert | `alert_id` (required): Alert ID, `content` (required): Comment text, `author` (optional): Author callsign, `npub` (optional): Author npub |
| `alert_add_photo` | Add a photo to an alert | `alert_id` (required): Alert ID, `url` (optional): URL to download image from, `name` (optional): Photo filename (default: auto-generated) |
| `alert_upload_photos` | Upload photos directly to station via HTTP | `alert_id` (required): Alert ID, `station_url` (optional): Station URL (default: connected station). Uploads all photos from the alert folder to the station |
| `place_like` | Toggle like for a place via station feedback | `place_id` (required): Place folder name, `callsign` (optional): Place owner callsign for local cache update, `place_path` (optional): Absolute path to place folder or `place.txt` |
| `place_comment` | Add a comment to a place via station feedback | `place_id` (required): Place folder name, `content` (required): Comment text, `author` (optional): Author callsign, `npub` (optional): Author npub, `callsign` (optional): Place owner callsign for local cache update, `place_path` (optional): Absolute path to place folder or `place.txt` |
| `station_server_start` | Start the station server | None. Starts StationServerService on port (API port + 1) |
| `station_server_stop` | Stop the station server | None. Stops the running station server |
| `station_server_status` | Get station server status | None. Returns running state, port, and connected client count |
| `open_station_chat` | Open the station chat browser | None. Opens ChatBrowserPage connected to preferred station (or p2p.radio) |
| `select_chat_room` | Select a chat room by ID | `room_id` (required): Room ID to select (e.g., "general") |
| `send_chat_message` | Send a message to the currently selected room (via UI) | `content` (optional): Message text, `image_path` (optional): Path to image file |
| `station_set` | Set the preferred station | `url` (required): Station WebSocket URL, `name` (optional): Station name |
| `station_connect` | Connect to preferred station | `url` (optional): Station WebSocket URL |
| `station_status` | Get station connection status | None |
| `station_send_chat` | Send a message to a station room (bypasses UI) | `room` (optional): Room ID (default: "general"), `content` (optional): Message text, `image_path` (optional): Absolute path to image file |
| `station_delete_chat` | Delete a message from a station room | `room` (optional): Room ID (default: "general"), `timestamp` (required): Message timestamp, `event_id` (optional): NOSTR event ID, `local` (optional): true to delete from local station |
| `station_edit_chat` | Edit a message in a station room | `room` (optional): Room ID (default: "general"), `timestamp` (required): Message timestamp, `content` (required): New message text, `event_id` (optional): NOSTR event ID |
| `karma_award` | Award karma points to a callsign | `callsign` (required): Target callsign, `karma_action` (required): Action type (e.g., `daily_login`, `chat_message`, `blog_published`), `meta` (optional): Additional metadata |
| `karma_profile` | Get karma profile for a callsign | `callsign` (optional): Target callsign (default: current user) |
| `karma_history` | Get karma event history | `callsign` (optional): Target callsign (default: current user), `limit` (optional): Max events (default: 50) |
| `karma_leaderboard` | Get leaderboard for a period | `period` (optional): `weekly`, `monthly`, `yearly`, `alltime` (default: `alltime`) |
| `karma_recompute` | Force leaderboard recomputation | None |
| `open_console` | Open the Console collection and auto-launch the first session | `session_id` (optional): Session ID to focus (default: first session) |
| `console_status` | Report Console VM status (files present, rootfs extraction marker, recent logs) | None |
| `email_compose` | Create a draft email | `to` (required): Recipient email(s) comma-separated, `subject` (required): Subject line, `content` (optional): Message body, `cc` (optional): CC recipients comma-separated, `station` (optional): Station domain (default: preferred station or p2p.radio) |
| `email_send` | Compose and send an email in one action | `to` (required): Recipient email(s), `subject` (required): Subject line, `content` (required): Message body, `cc` (optional): CC recipients, `station` (optional): Station domain |
| `email_send_with_image` | Compose and send an email with an attached local picture | `to` (required): Recipient email(s), `subject` (required): Subject line, `content` (required): Message body, `image_path` (required): Local image file path (`.jpg`, `.jpeg`, `.png`, `.gif`, `.webp`, `.bmp`), `image_name` (optional): Attachment filename override, `cc` (optional): CC recipients, `station` (optional): Station domain |
| `email_list` | List emails in a folder | `folder` (optional): inbox/sent/outbox/drafts/spam/trash (default: inbox), `station` (optional): Station domain (default: p2p.radio) |
| `email_status` | Get email service status | None. Returns WebSocket connection status, preferred station, and registered accounts |
| `p2p_navigate` | Navigate to P2P Transfer panel | None |
| `p2p_send` | Send files to another device via P2P | `callsign`: Target device callsign (required), `folder`: Absolute path to folder containing files to send (required) |
| `p2p_list_incoming` | List pending incoming transfer offers | None |
| `p2p_list_outgoing` | List pending outgoing transfer offers | None |
| `p2p_accept` | Accept an incoming transfer offer | `offer_id`: Offer ID to accept (required), `destination`: Absolute path to destination folder (required) |
| `p2p_reject` | Reject an incoming transfer offer | `offer_id`: Offer ID to reject (required) |
| `p2p_status` | Get status of a transfer offer | `offer_id`: Offer ID to check (required) |
| `list_devices` | List all known devices with online status | None |
| `add_device` | Add a device by callsign and URL | `callsign` (required): Device callsign, `url` (required): Device HTTP API URL. Fetches device nickname from its status API |
| `conference_host` | Host a new SFU audio conference (LAN or station mode) | `room_name` (optional): Conference name (default: "Test Meeting"), `max_speakers` (optional): Max speakers including host (default: 6) |
| `conference_join` | Join an existing conference | `url` (optional): WebSocket URL for LAN mode, `room_id` (optional): Room ID for station mode, `role` (optional): "speaker" or "listener" (default: "listener") |
| `conference_status` | Get current conference status | None |
| `conference_end` | End or leave the current conference | None |
| `conference_mute` | Toggle mute in current conference | None |
| `conference_promote` | Promote a listener to speaker (host only) | `callsign` (required): Callsign of participant to promote |
| `conference_demote` | Demote a speaker to listener (host only) | `callsign` (required): Callsign of participant to demote |
| `atproto_status` | Get Teleport AT Proto bridge status | None |
| `atproto_read_feed` | Read public Bluesky/AT feed for an actor | `actor` (required): Handle or DID, `limit` (optional): 1-100, `appview` (optional): Base URL override |
| `atproto_sync_feed` | Trigger bridge-managed feed sync with fallback actor logic | None |
| `atproto_like_from_feed` | Test like write flow against first post from actor feed | `actor` (optional): Handle or DID (default: `bsky.app`) |
| `atproto_read_replies` | Read replies for a given post URI using AT thread endpoint | `uri` (required): AT URI of root post, `depth` (optional): 1-20 |
| `atproto_follow_actor` | Follow an actor using bridge write flow | `actor` (required): Handle or DID |
| `atproto_following_list` | List locally persisted followed actors | None |
| `atproto_following_activity` | Get merged activity feed from followed actors | None |
| `atproto_search_people` | Search actors/profiles across Bluesky network | `query` (required): Search text, `limit` (optional): 1-100 |
| `atproto_search_posts` | Search posts/content across Bluesky network | `query` (required): Search text, `limit` (optional): 1-100 |
| `shared_list` | List all shared folder entries with metadata | None |
| `shared_test_access` | Test access control for a given pubkey | `pubkey` (optional): Hex pubkey to test. Returns accessibility per folder |
| `shared_test_cookie` | Test cookie parsing from HTTP headers | `headers` (required): Raw HTTP headers string to parse for `geogram_nostr_pubkey` cookie |
| `hotspot_portal_start` | Start the captive portal HTTP server + DNS | `gateway_ip` (optional): Gateway IP (default: 192.168.49.1), `station_name` (optional): Station name for portal title |
| `hotspot_portal_stop` | Stop the captive portal server and DNS | None |
| `hotspot_portal_status` | Get portal server status | None. Returns running state, DNS state, port, gateway IP |
| `bitchat_status` | Get BitChat service status (identity, BLE state, peers, messages, cache) | None |
| `bitchat_enable` | Enable BitChat service (generate identity if needed, start BLE) | None |
| `meshtastic_status` | Get Meshtastic service status (BLE state, nodes, channels, messages, cache) | None |
| `meshtastic_enable` | Enable Meshtastic service (create config if needed) | None |
| `meshtastic_log_level` | Set Meshtastic log level (returns current if no level param) | `level` (off\|error\|warn\|info\|debug) |

Place feedback actions send signed events to the station and only update local cache files if the place folder can be resolved via `place_path` or `callsign`.

**Console automation examples:**

- Launch the console UI (navigates to Collections, opens Console, auto-starts first session):
```bash
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action":"open_console"}'
```

- Poll console status (checks VM files, rootfs marker, and recent console logs):
```bash
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action":"console_status"}'
```

Sample `console_status` response:
```json
{
  "success": true,
  "vm_path": "/home/user/.geogram/console/vm",
  "files": {
    "jslinux.js": true,
    "term.js": true,
    "x86emu-wasm.js": true,
    "x86emu-wasm.wasm": true,
    "kernel-x86.bin": true,
    "alpine-x86.cfg": true,
    "alpine-x86-rootfs.tar.gz": true,
    "alpine-x86-rootfs.cpio.gz": false
  },
  "rootfs_extracted": false,
  "console_collection": {
    "id": "console",
    "title": "Console",
    "path": "/home/user/.geogram/collections/console"
  },
  "log_tail": [
    "Console: Initialized",
    "ConsoleVmManager: Rootfs extracted to /home/user/.geogram/console/vm/rootfs"
  ]
}
```

**Email automation examples:**

- Compose and send an email to an external address:
```bash
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action":"email_send", "to":"test@example.com", "subject":"Hello from Geogram", "content":"This is a test email sent via the debug API."}'
```

- Compose and send an email with an attached local image:
```bash
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action":"email_send_with_image", "to":"test@example.com", "subject":"Photo Test", "content":"Sending a picture from debug API.", "image_path":"tests/images/photo_2025-03-25_10-33-43.jpg"}'
```

- Create a draft email:
```bash
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action":"email_compose", "to":"alice@example.com,bob@example.com", "subject":"Meeting Notes", "cc":"charlie@example.com"}'
```

- List outbox emails:
```bash
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action":"email_list", "folder":"outbox"}'
```

- Check email service status:
```bash
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action":"email_status"}'
```

Sample `email_send` response:
```json
{
  "success": true,
  "message": "Email created and queued for delivery",
  "thread_id": "abc123def456",
  "from": "user@p2p.radio",
  "to": ["test@example.com"],
  "subject": "Hello from Geogram",
  "station": "p2p.radio",
  "delivery_status": "sent_to_station",
  "websocket_connected": true
}
```

**P2P Transfer automation examples:**

- Send files to another device:
```bash
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action":"p2p_send","callsign":"X1BOB","folder":"/home/user/files-to-send"}'
```

Sample `p2p_send` response:
```json
{
  "success": true,
  "offer_id": "tr_abc123",
  "recipient": "X1BOB",
  "files": 3,
  "total_bytes": 15360,
  "status": "pending"
}
```

- List incoming transfer offers:
```bash
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action":"p2p_list_incoming"}'
```

Sample `p2p_list_incoming` response:
```json
{
  "success": true,
  "offers": [
    {
      "offer_id": "tr_abc123",
      "sender_callsign": "X1ALICE",
      "total_files": 3,
      "total_bytes": 15360,
      "expires_at": 1706003600,
      "status": "pending"
    }
  ]
}
```

- Accept an incoming offer:
```bash
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action":"p2p_accept","offer_id":"tr_abc123","destination":"/home/user/received"}'
```

- Check transfer status:
```bash
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action":"p2p_status","offer_id":"tr_abc123"}'
```

Sample `p2p_status` response:
```json
{
  "success": true,
  "offer_id": "tr_abc123",
  "status": "transferring",
  "bytes_transferred": 8192,
  "total_bytes": 15360,
  "files_completed": 1,
  "total_files": 3,
  "current_file": "docs/readme.txt"
}
```

**Device management examples:**

- Add a device by callsign and URL (fetches nickname automatically):
```bash
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action":"add_device","callsign":"X1BOB","url":"http://192.168.1.50:3456"}'
```

Sample `add_device` response:
```json
{
  "success": true,
  "message": "Device added: X1BOB at http://192.168.1.50:3456",
  "callsign": "X1BOB",
  "url": "http://192.168.1.50:3456",
  "nickname": "Bob's Device"
}
```

The `add_device` action fetches the device's `/api/status` endpoint to retrieve its nickname, making the device identifiable in the UI dropdown. If the device is unreachable, `nickname` will be `null`.

- Permanently remove a device (won't reappear from discovery):
```bash
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action":"remove_device","callsign":"X1BOB","permanent":true}'
```

- Restore a previously removed device (allows re-discovery):
```bash
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action":"restore_device","callsign":"X1BOB"}'
```

- List all permanently removed devices:
```bash
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action":"get_removed_devices"}'
```

**Response - Success (200 OK):**
```json
{
  "success": true,
  "message": "BLE scan triggered"
}
```

**Response - Error (400 Bad Request):**
```json
{
  "success": false,
  "error": "Unknown action: invalid_action",
  "available_actions": ["navigate", "ble_scan", "ble_advertise", "refresh_devices", "local_scan", "connect_station", "disconnect_station", "open_station_chat", "select_chat_room"]
}
```

**Example Usage:**
```bash
# Get available actions
curl http://localhost:3456/api/debug

# Navigate to devices panel (BLE/Bluetooth view)
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "navigate", "panel": "devices"}'

# Show a toast message on the UI
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "toast", "message": "Hello from the test script!", "duration": 5}'

# Trigger BLE scan
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "ble_scan"}'

# Get AT Proto bridge status
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action":"atproto_status"}'

# Read public feed posts from Bluesky actor
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action":"atproto_read_feed","actor":"bsky.app","limit":5}'

# Trigger bridge feed sync (uses configured actor with fallback)
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action":"atproto_sync_feed"}'

# Test like flow using first post from actor feed
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action":"atproto_like_from_feed","actor":"bsky.app"}'

# Read replies for a specific post URI
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action":"atproto_read_replies","uri":"at://did:plc:.../app.bsky.feed.post/3abc","depth":6}'

# Follow an actor
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action":"atproto_follow_actor","actor":"bsky.app"}'

# List followed actors
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action":"atproto_following_list"}'

# Fetch activity feed from followed actors
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action":"atproto_following_activity"}'

# Search people
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action":"atproto_search_people","query":"pfrazee","limit":5}'

# Search posts
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action":"atproto_search_posts","query":"geogram","limit":5}'

# Start BLE advertising
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "ble_advertise"}'

# Refresh all devices
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "refresh_devices"}'

# Start a bot model download (vision)
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "bot_download_model", "model_type": "vision", "model_id": "mobilenet-v3"}'

# Start a bot model download (vision) via a specific station
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "bot_download_model", "model_type": "vision", "model_id": "mobilenet-v3", "station_url": "https://p2p.radio", "station_callsign": "X3WFE4"}'

# Send BLE HELLO handshake to first discovered device
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "ble_hello"}'

# Send BLE HELLO to a specific device
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "ble_hello", "device_id": "5B:2F:49:2E:8C:05"}'

# Navigate to devices and trigger BLE scan (chained)
curl -X POST http://localhost:3456/api/debug -d '{"action": "navigate", "panel": "devices"}' && \
curl -X POST http://localhost:3456/api/debug -d '{"action": "ble_scan"}'

# Send a direct message
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "send_dm", "callsign": "REMOTE-42", "content": "Hello from debug API!"}'

# Sync DMs with a device
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "sync_dm", "callsign": "REMOTE-42", "url": "http://192.168.1.100:3456"}'

# Open DM conversation UI with a device
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "open_dm", "callsign": "REMOTE-42"}'

# Send a file (image) in a direct message
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "send_dm_file", "callsign": "REMOTE-42", "file_path": "/tmp/photo.jpg"}'

# Enable backup provider mode
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "backup_provider_enable", "max_storage_bytes": 10737418240}'

# Create test data files for backup testing
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "backup_create_test_data", "file_count": 5, "max_file_size": 4096}'

# Send backup invite to a provider
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "backup_send_invite", "provider_callsign": "X2BCDE", "interval_days": 3}'

# Accept backup invite (on provider side)
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "backup_accept_invite", "client_callsign": "X1ABCD"}'

# Start backup
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "backup_start", "provider_callsign": "X2BCDE"}'

# Get backup/restore status
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "backup_get_status"}'

# List snapshots from a provider
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "backup_list_snapshots", "client_callsign": "X1ABCD"}'

# Restore from a snapshot
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "backup_restore", "provider_callsign": "X2BCDE", "snapshot_id": "2025-12-12"}'

# Point an alert (toggles point on/off - calls attention to it)
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "alert_point", "alert_id": "38_7222_n9_1393_broken-sidewalk"}'

# Point an alert with specific npub
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "alert_point", "alert_id": "38_7222_n9_1393_broken-sidewalk", "npub": "npub1abc..."}'

# Add a comment to an alert
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "alert_comment", "alert_id": "38_7222_n9_1393_broken-sidewalk", "content": "I can confirm this issue!"}'

# Add a comment with specific author
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "alert_comment", "alert_id": "38_7222_n9_1393_broken-sidewalk", "content": "Issue verified", "author": "X1ABCD", "npub": "npub1xyz..."}'

# Like a place (toggle)
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "place_like", "place_id": "40.209643_-8.419623_praa-de-repblica", "callsign": "X1UEFU"}'

# Comment on a place
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "place_comment", "place_id": "40.209643_-8.419623_praa-de-repblica", "content": "Great spot", "author": "X1UEFU"}'

# Add a placeholder photo to an alert
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "alert_add_photo", "alert_id": "2025-12-13_test-fire-hazard", "name": "evidence.png"}'

# Add a photo from URL to an alert
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "alert_add_photo", "alert_id": "2025-12-13_test-fire-hazard", "url": "https://example.com/image.jpg", "name": "downloaded.jpg"}'

# Create an alert with a test photo
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "alert_create", "title": "Test Alert", "description": "Test description", "photo": true}'

# Share an alert to stations (uploads alert and photos via NOSTR)
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "alert_share", "alert_id": "38_7222_n9_1393_test-alert"}'

# Sync alerts from station (downloads alerts and photos)
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "alert_sync"}'

# Start the station server (listens on API port + 1)
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "station_server_start"}'
# Returns: {"success": true, "port": 3457, "running": true}

# Get station server status
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "station_server_status"}'
# Returns: {"running": true, "port": 3457, "connected_devices": 2, ...}

# Stop the station server
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "station_server_stop"}'

# Upload photos for an alert directly to station
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "alert_upload_photos", "alert_id": "38_7222_n9_1393_broken-sidewalk"}'

# Open the station chat browser page
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "open_station_chat"}'
# Opens ChatBrowserPage connected to the preferred station (or p2p.radio if none configured)

# Select a specific chat room in the currently open chat browser
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "select_chat_room", "room_id": "general"}'
# Selects the specified room and displays its messages

# Send a chat message to the selected room
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "send_chat_message", "content": "Hello from debug API!"}'

# Send a chat message with an image attachment
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "send_chat_message", "content": "Check out this photo", "image_path": "tests/images/photo_2025-03-25_10-33-43.jpg"}'
# Relative paths are resolved from the project root; absolute paths are used as-is

# Set preferred station
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "station_set", "url": "wss://p2p.radio", "name": "P2P Radio"}'

# Connect to preferred station
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "station_connect"}'

# Check station connection status
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "station_status"}'
# Returns: {"success": true, "connected": true, "preferred_url": "wss://p2p.radio", "preferred_name": "p2p.radio"}

# Send a chat message directly to station (bypasses UI, more reliable for automation)
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "station_send_chat", "room": "general", "content": "Hello from automation!"}'

# Send a chat message with image to station (returns detailed logs)
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "station_send_chat", "room": "general", "content": "Check this photo", "image_path": "/absolute/path/to/image.jpg"}'
# Returns: {"success": true, "metadata": {"file": "hash_filename.jpg", "file_size": "12345"}, "logs": [...]}

# Delete a chat message from a station room
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "station_delete_chat", "room": "general", "timestamp": "2026-02-18 19:47_53", "event_id": "abc123..."}'
# Optional: "local": true to delete from local station directly (no NOSTR auth needed)

# Edit a chat message in a station room
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "station_edit_chat", "room": "general", "timestamp": "2026-02-18 19:47_53", "content": "Updated message text"}'

# Award karma points
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "karma_award", "callsign": "X1SU86", "karma_action": "daily_login"}'

# Get karma profile
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "karma_profile", "callsign": "X1SU86"}'

# Get karma leaderboard
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "karma_leaderboard", "period": "alltime"}'

# Force leaderboard recomputation
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "karma_recompute"}'
```

---

### Connected Devices (Server-Side)

**GET /api/debug/connected-devices** — Show all connected devices grouped by callsign with protocol version, verification status, and responsiveness stats

```bash
curl -s https://p2p.radio/api/debug/connected-devices | jq
```

Returns:
```json
{
  "total_connections": 3,
  "unique_callsigns": 2,
  "devices_by_callsign": {
    "X1SU86": [
      {
        "id": "1709568000000",
        "callsign": "X1SU86",
        "protocol": 2,
        "verified": true,
        "success_count": 15,
        "fail_count": 1,
        "platform": "Linux",
        "connected_at": "..."
      },
      {
        "id": "1709568001000",
        "callsign": "X1SU86",
        "protocol": 2,
        "verified": true,
        "success_count": 3,
        "fail_count": 0,
        "platform": "Android",
        "connected_at": "..."
      }
    ]
  }
}
```

---

### Now Feed

**GET /api/debug/now** — List current feed items
- Returns: `{ items: [...], total: int, unread: int }`

**POST /api/debug/now/inject** — Inject a test NowItemEvent
- Body: `{ "appType": "chat", "sourceId": "test-room", "sourceName": "Test Room", "callsign": "TEST", "summary": "Test message", "priority": 5 }`
- Optional: `"id"` (auto-generated if omitted)

**POST /api/debug/now/reply** — Simulate sending a reply from a Now card
- Body: `{ "appType": "aprs", "sourceId": "geochat", "text": "hello" }`
- For APRS geochat (`sourceId: "geochat"`): calls `sendGeoChat()` (position report)
- For APRS direct (`sourceId: "CALLSIGN"`): calls `sendMessage()` (directed message)

**POST /api/debug/now/clear** — Clear all items

**POST /api/debug/now/mark-read** — Mark all items as read

**GET /api/debug/now/settings** — Get all group settings
- Returns: `{ settings: { "_default": { "maxItems": 5, "expiryMinutes": 1440 }, ... } }`

**POST /api/debug/now/settings** — Set group settings
- Body: `{ "group": "chat", "maxItems": 10, "expiryMinutes": 1440, "priorityOverride": 1, "pinned": true }`
- `group` can be `"_default"`, `"appType"`, or `"appType:sourceId"` for cascading resolution
- Settings resolution: `appType:sourceId` → `appType` → `_default` → hardcoded (5 items, 1440 min)
- `priorityOverride` (int, optional): Override item priority for this group (1-2 triggers desktop popups). Omit or `null` to use the item's own priority.
- `pinned` (bool, default false): When true, the card sorts to the top of the Now feed

**POST /api/debug/now/remove-group** — Remove all items for a source group
- Body: `{ "appType": "irc", "sourceId": "libera:#geogram" }`
- Removes all items matching the given appType + sourceId from the feed

---

### Devices (Debug)

#### GET /api/devices

Returns list of discovered devices. **Requires Debug API to be enabled.**

**Response (200 OK):**
```json
{
  "myCallsign": "USER-123",
  "devices": [
    {
      "callsign": "REMOTE-42",
      "name": "Remote Station",
      "nickname": "Alice",
      "url": "http://192.168.1.100:3456",
      "npub": "npub1abc...",
      "isOnline": true,
      "latency": 45,
      "lastSeen": "2024-12-09T10:30:00Z",
      "latitude": 38.72,
      "longitude": -9.14,
      "connectionMethods": ["wifi_local", "internet"],
      "source": "station",
      "bleProximity": null,
      "bleRssi": null
    }
  ],
  "total": 1,
  "isBLEAvailable": true,
  "isBLEScanning": false
}
```

| Field | Type | Description |
|-------|------|-------------|
| `callsign` | string | Device callsign |
| `name` | string | Device name |
| `nickname` | string | Display nickname (if set) |
| `url` | string | Device HTTP URL (for direct connection) |
| `npub` | string | NOSTR public key |
| `isOnline` | bool | Current online status |
| `latency` | int | Connection latency in ms |
| `lastSeen` | string | ISO 8601 last activity timestamp |
| `connectionMethods` | array | Available connections: `wifi_local`, `internet`, `bluetooth`, `lora` |
| `source` | string | Discovery source: `local`, `station`, `ble`, `direct` |
| `bleProximity` | string | BLE proximity: "Very close", "Nearby", "In range", "Far" |
| `bleRssi` | int | BLE signal strength in dBm |

**Response (403 Forbidden):** Debug API is disabled.

---

### Backup

The Backup API enables peer-to-peer backup and restore between devices. A device can act as a backup client (sending backups) or a backup provider (storing backups for others). All backup data is end-to-end encrypted using the client's NOSTR keys.

For detailed specifications, see [Backup Format Specification](apps/backup-format-specification.md).

#### Authentication

All backup endpoints require a NOSTR-signed event to prevent impersonation (including reads like availability, snapshots, and file transfers):

- `Authorization: Nostr <base64_encoded_event_json>`

The server verifies signature, freshness (5 minutes), and `callsign` tag before processing. The `t` tag should be `backup`.
Large payloads (manifests/files) use `application/octet-stream` over HTTP (LAN or station proxy). WebRTC transports are used for signaling only.

#### Provider Endpoints

##### GET /api/backup/settings

Returns provider backup settings.

**Response (200 OK):**
```json
{
  "enabled": true,
  "max_total_storage_bytes": 107374182400,
  "used_storage_bytes": 52428800000,
  "available_storage_bytes": 54946382400,
  "client_count": 5,
  "default_max_client_storage_bytes": 10737418240,
  "default_max_snapshots": 10
}
```

##### PUT /api/backup/settings

Update provider backup settings.

**Request:**
```json
{
  "enabled": true,
  "max_total_storage_bytes": 214748364800,
  "default_max_client_storage_bytes": 21474836480,
  "default_max_snapshots": 15
}
```

**Response (200 OK):** Updated settings object.

##### GET /api/backup/availability

Lightweight provider availability response for LAN discovery. Requires NOSTR auth.

**Response (200 OK):**
```json
{
  "enabled": true,
  "callsign": "X2BCDE",
  "npub": "npub1xyz789...",
  "max_total_storage_bytes": 10737418240,
  "default_max_client_storage_bytes": 1073741824,
  "default_max_snapshots": 10,
  "updated_at": "2026-01-04T10:00:00Z"
}
```

##### GET /api/backup/clients

List all backup clients for this provider.

**Response (200 OK):**
```json
{
  "clients": [
    {
      "callsign": "X1ABCD",
      "npub": "npub1abc123...",
      "status": "active",
      "max_storage_bytes": 10737418240,
      "current_storage_bytes": 524288000,
      "snapshot_count": 3,
      "last_backup_at": "2025-12-12T15:30:00Z"
    }
  ]
}
```

##### GET /api/backup/clients/{callsign}

Get specific client info.

**Parameters:**
| Parameter | Description |
|-----------|-------------|
| `callsign` | Client's callsign |

**Response (200 OK):** Client object with full details.

##### DELETE /api/backup/clients/{callsign}

Remove client and optionally delete their backups.

**Query Parameters:**
| Parameter | Default | Description |
|-----------|---------|-------------|
| `delete_data` | `false` | Also delete all backup data |

**Response (200 OK):**
```json
{
  "success": true,
  "callsign": "X1ABCD",
  "data_deleted": true
}
```

##### GET /api/backup/clients/{callsign}/snapshots

List client's snapshots.

**Response (200 OK):**
```json
{
  "snapshots": [
    {
      "snapshot_id": "2025-12-12",
      "status": "complete",
      "note": "Field work day 3",
      "total_files": 1234,
      "total_bytes": 524288000,
      "started_at": "2025-12-12T15:30:00Z",
      "completed_at": "2025-12-12T16:45:00Z"
    }
  ],
  "total_snapshot_bytes": 524288000,
  "max_storage_bytes": 1073741824,
  "current_storage_bytes": 524288000,
  "max_snapshots": 10,
  "remaining_bytes": 548451824
}
```

##### PUT /api/backup/clients/{callsign}/snapshots/{date}/note

Update the human-readable note/label for a snapshot. Requires NOSTR authentication from the snapshot owner.

**Request:**
```json
{
  "note": "Why this snapshot matters"
}
```

**Response (200 OK):**
```json
{
  "success": true,
  "snapshot_id": "2025-12-12",
  "note": "Why this snapshot matters"
}
```

##### GET /api/backup/clients/{callsign}/snapshots/{date}

Get snapshot manifest (encrypted).

**Parameters:**
| Parameter | Description |
|-----------|-------------|
| `callsign` | Client's callsign |
| `date` | Snapshot date `YYYY-MM-DD` |

**Response (200 OK):** Encrypted manifest as binary `application/octet-stream`.

##### PUT /api/backup/clients/{callsign}/snapshots/{date}

Upload encrypted manifest to snapshot. Requires NOSTR authentication.

**Headers:**
| Header | Description |
|--------|-------------|
| `Authorization` | `Nostr <base64_encoded_event>` |
| `Content-Type` | `application/octet-stream` |

**Notes:**
- Raw binary body is preferred; JSON/base64 payloads are also accepted for compatibility.

**Notes:**
- Raw binary body is preferred; JSON/base64 payloads are also accepted for compatibility.

**Response (200 OK):**
```json
{
  "success": true,
  "message": "Manifest saved"
}
```

##### GET /api/backup/clients/{callsign}/snapshots/{date}/files/{name}

Download encrypted file from snapshot.

**Response (200 OK):** Binary encrypted file data (`application/octet-stream`).

##### PUT /api/backup/clients/{callsign}/snapshots/{date}/files/{name}

Upload encrypted file to snapshot. Requires NOSTR authentication.

**Headers:**
| Header | Description |
|--------|-------------|
| `Authorization` | `Nostr <base64_encoded_event>` |
| `Content-Type` | `application/octet-stream` |

**Response (200 OK):**
```json
{
  "success": true,
  "message": "File saved",
  "size": 4128
}
```

#### Client Endpoints

##### GET /api/backup/providers

List configured backup providers.

**Response (200 OK):**
```json
{
  "providers": [
    {
      "callsign": "X2BCDE",
      "npub": "npub1xyz789...",
      "status": "active",
      "max_storage_bytes": 10737418240,
      "backup_interval_days": 3,
      "last_successful_backup": "2025-12-12T15:30:00Z",
      "next_scheduled_backup": "2025-12-15T15:30:00Z"
    }
  ]
}
```

##### POST /api/backup/providers

Send backup invite to a device.

**Request:**
```json
{
  "callsign": "X2BCDE",
  "backup_interval_days": 3
}
```

**Response (200 OK):**
```json
{
  "success": true,
  "status": "pending",
  "provider_callsign": "X2BCDE"
}
```

##### PUT /api/backup/providers/{callsign}

Update provider settings (e.g., backup interval).

**Request:**
```json
{
  "backup_interval_days": 7
}
```

##### DELETE /api/backup/providers/{callsign}

Remove provider relationship.

**Response (200 OK):**
```json
{
  "success": true,
  "callsign": "X2BCDE"
}
```

##### POST /api/backup/start

Start manual backup to a provider.

**Request:**
```json
{
  "provider_callsign": "X2BCDE"
}
```

**Response (200 OK):**
```json
{
  "success": true,
  "status": {
    "provider_callsign": "X2BCDE",
    "snapshot_id": "2025-12-12",
    "status": "in_progress",
    "progress_percent": 0,
    "files_transferred": 0,
    "files_total": 0,
    "bytes_transferred": 0,
    "bytes_total": 0,
    "started_at": "2025-12-12T15:30:00Z"
  }
}
```

##### GET /api/backup/status

Get current backup status.
Note: This endpoint reports backup progress only; restore progress is not currently exposed via the public API.

**Response (200 OK):**
```json
{
  "provider_callsign": "X2BCDE",
  "snapshot_id": "2025-12-12",
  "status": "in_progress",
  "progress_percent": 45,
  "files_transferred": 567,
  "files_total": 1234,
  "bytes_transferred": 234567890,
  "bytes_total": 524288000,
  "started_at": "2025-12-12T15:30:00Z"
}
```

##### POST /api/backup/restore

Start restore from a provider snapshot.
Restore runs asynchronously.

**Request:**
```json
{
  "provider_callsign": "X2BCDE",
  "snapshot_id": "2025-12-12"
}
```

**Response (200 OK):**
```json
{
  "success": true,
  "message": "Restore started"
}
```

#### Provider Directory (Station)

##### GET /api/backup/providers/available

List available backup providers from the connected station directory. Requires NOSTR authorization.
Requester must be connected to the station.
Entries expire after roughly 90 seconds without provider refresh.

**Response (200 OK):**
```json
{
  "providers": [
    {
      "callsign": "X2BCDE",
      "npub": "npub1xyz789...",
      "max_total_storage_bytes": 10737418240,
      "default_max_client_storage_bytes": 1073741824,
      "default_max_snapshots": 10,
      "last_seen": "2026-01-04T10:00:30Z",
      "connection_method": "station"
    }
  ]
}
```

#### Provider Discovery (Account Restoration)

When restoring an account on a new device, the client can automatically discover backup providers using a challenge-response protocol that protects privacy.

##### POST /api/backup/discover

Initiate automatic provider discovery. Queries all connected devices via station to find backup providers for the local NPUB.

**Request:**
```json
{
  "timeout_seconds": 30
}
```

**Response (200 OK):**
```json
{
  "discovery_id": "abc123",
  "status": "in_progress",
  "devices_to_query": 42
}
```

##### GET /api/backup/discover/{discovery_id}

Poll discovery status.

**Parameters:**
| Parameter | Description |
|-----------|-------------|
| `discovery_id` | ID returned from POST /api/backup/discover |

**Response (200 OK) - In Progress:**
```json
{
  "discovery_id": "abc123",
  "status": "in_progress",
  "devices_queried": 20,
  "devices_responded": 15,
  "providers_found": []
}
```

**Response (200 OK) - Complete:**
```json
{
  "discovery_id": "abc123",
  "status": "complete",
  "devices_queried": 42,
  "devices_responded": 38,
  "providers_found": [
    {
      "callsign": "X2BCDE",
      "npub": "npub1xyz789...",
      "max_storage_bytes": 10737418240,
      "snapshot_count": 5,
      "latest_snapshot": "2025-12-10"
    },
    {
      "callsign": "X3CDEF",
      "npub": "npub1abc456...",
      "max_storage_bytes": 5368709120,
      "snapshot_count": 3,
      "latest_snapshot": "2025-12-08"
    }
  ]
}
```

**Discovery Protocol:**

The discovery uses NOSTR-signed challenge-response to ensure only the NPUB owner can identify their providers:

1. Client sends signed `backup_discovery_challenge` to each connected device
2. Each device verifies signature and checks if they're a provider for that NPUB
3. Provider responds with signed `backup_discovery_response` echoing the unique challenge
4. Client verifies response signatures and collects provider list

This protects privacy: without the NSEC (private key), no one can discover who backs up whom.

**Example Usage:**
```bash
# Start discovery
curl -X POST http://localhost:3456/api/backup/discover \
  -H "Content-Type: application/json" \
  -d '{"timeout_seconds": 30}'
# Returns: {"discovery_id": "abc123", "status": "in_progress", ...}

# Poll for results
curl http://localhost:3456/api/backup/discover/abc123
# Returns: {"status": "complete", "providers_found": [...]}
```

---

## Mirror Sync

Mirror sync enables one-way folder synchronization between Geogram instances using NOSTR-signed authentication.

For full documentation of the sync protocol, see [API_synch.md](API_synch.md).

### Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/mirror/challenge` | GET | Get authentication challenge (prevents replay attacks) |
| `/api/mirror/request` | POST | Request sync with signed challenge response |
| `/api/mirror/manifest` | GET | Get folder structure with file hashes |
| `/api/mirror/file` | GET | Download a specific file |

### GET /api/mirror/challenge

Get a challenge nonce that must be signed to prove identity.

**Query Parameters:**
- `folder`: Folder path to sync (required)

**Response:**
```json
{
  "success": true,
  "nonce": "64_hex_chars...",
  "folder": "collections/blog",
  "expires_at": 1706000120
}
```

### POST /api/mirror/request

Request permission to sync a folder (with signed challenge response).

**Request Body:**
```json
{
  "event": {
    "id": "...",
    "kind": 1,
    "pubkey": "...",
    "created_at": 1706000000,
    "content": "mirror_response:<nonce>:collections/blog",
    "tags": [["t", "mirror_response"], ["folder", "collections/blog"], ["nonce", "<nonce>"]],
    "sig": "..."
  },
  "folder": "collections/blog"
}
```

**Response:**
```json
{
  "success": true,
  "allowed": true,
  "token": "access_token_123",
  "expires_at": 1706003600,
  "peer_callsign": "X1ABCD"
}
```

### GET /api/mirror/manifest

Get folder structure with file metadata for comparison.

**Query Parameters:**
- `folder`: Folder path (required)
- `token`: Access token from request step (required)

**Response:**
```json
{
  "success": true,
  "folder": "blog",
  "total_files": 3,
  "total_bytes": 15360,
  "files": [
    {"path": "post1.md", "sha1": "abc123", "mtime": 1706000000, "size": 2048}
  ],
  "generated_at": 1706000500
}
```

### GET /api/mirror/file

Download a specific file.

**Query Parameters:**
- `path`: File path relative to synced folder (required)
- `token`: Access token (required)

**Headers (Optional):**
- `Range`: Byte range for resumable downloads

**Response:**
- Raw file content
- Header `X-SHA1`: File hash for verification

### Debug Actions

Mirror sync can be tested via the debug API:

```bash
# Enable mirror mode
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "mirror_enable", "enabled": true}'

# Add allowed peer
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "mirror_add_allowed_peer", "npub": "npub1...", "callsign": "X1ABCD"}'

# Request sync from peer
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "mirror_request_sync", "peer_url": "http://192.168.1.100:3456", "folder": "collections/blog"}'

# Get sync status
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "mirror_get_status"}'

# Show mirror configuration (peers, apps, addresses)
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "mirror_config"}'

# Full sync with all configured peers
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "mirror_sync_all"}'

# Open Mirror Settings page on device
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "mirror_open_settings"}'

# Open Mirror Wizard page on device
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "mirror_open_wizard"}'

# Check auto-sync timer status
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "mirror_auto_sync_status"}'

# Trigger immediate sync of all peers (with relay fallback)
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "mirror_auto_sync_trigger"}'

# Check station relay URLs per peer
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "mirror_relay_status"}'

# List all profiles
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "profile_list"}'

# Delete a profile by callsign
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "profile_delete", "callsign": "X1FART"}'
```

### BlueAPRS Debug Actions

BlueAPRS provides APRS over Bluetooth Low Energy. These debug actions test the iGate (BLE ↔ APRS-IS) and repeater (BLE ↔ BLE) bridge using simulated BLE clients.

```bash
# Get BlueAPRS bridge status (includes beacon state)
curl -s localhost:3456/api/debug -d '{"action":"blue_aprs_status"}'
# → {active, beaconEnabled, beaconIntervalSec, bleClients: [...], stats: {...}}

# Enable/disable BlueAPRS bridge
curl -s localhost:3456/api/debug -d '{"action":"blue_aprs_enable","enabled":true}'
# → {success, blueAprsEnabled, active}

# Control position beacon
curl -s localhost:3456/api/debug -d '{
  "action": "blue_aprs_beacon",
  "enabled": true,
  "intervalSec": 300
}'
# → {success, beaconEnabled, beaconIntervalSec, ...status}

# Register a simulated BLE client (no real Bluetooth needed)
curl -s localhost:3456/api/debug -d '{
  "action": "blue_aprs_register_client",
  "deviceId": "sim-ble-1",
  "callsign": "BLE1-5"
}'

# Simulate BLE client sending directed APRS message (iGate TX)
curl -s localhost:3456/api/debug -d '{
  "action": "blue_aprs_inject_ble",
  "callsign": "BLE1-5",
  "to": "N0CALL",
  "text": "Hello from BlueAPRS",
  "type": "message"
}'

# Simulate BLE client sending geochat (iGate TX)
curl -s localhost:3456/api/debug -d '{
  "action": "blue_aprs_inject_ble",
  "callsign": "BLE1-5",
  "type": "geochat",
  "text": "Position report via BLE",
  "lat": 38.72,
  "lon": -9.14
}'

# Simulate APRS-IS packet arriving for BLE client (iGate RX)
curl -s localhost:3456/api/debug -d '{
  "action": "blue_aprs_inject_aprs",
  "from": "W5XYZ-9",
  "to": "BLE1-5",
  "text": "Reply from APRS network"
}'

# Check simulated BLE client inbox
curl -s localhost:3456/api/debug -d '{
  "action": "blue_aprs_client_inbox",
  "deviceId": "sim-ble-1"
}'
# → {success, messages: [{from, to, text, type, timestamp}]}
```

**Automated test:** `dart run tests/blue_aprs_test.dart`

---

## AT Protocol PDS

When `atprotoEnabled` is true in station settings, the station runs an AT Protocol Personal Data Server. These endpoints are served on the station's HTTP port.

### XRPC Endpoints

Standard AT Protocol XRPC endpoints at `/xrpc/{nsid}`:

| Endpoint | Method | Auth | Description |
|---|---|---|---|
| `com.atproto.server.describeServer` | GET | No | Server capabilities and DID |
| `com.atproto.server.createSession` | POST | No | Login with identifier + password |
| `com.atproto.server.refreshSession` | POST | Bearer (refresh) | Rotate refresh token |
| `com.atproto.server.deleteSession` | POST | Bearer (refresh) | Revoke session |
| `com.atproto.server.getSession` | GET | Bearer (access) | Get current session info |
| `com.atproto.identity.resolveHandle` | GET | No | Resolve handle to DID |
| `com.atproto.repo.createRecord` | POST | Bearer (access) | Create record in collection |
| `com.atproto.repo.putRecord` | POST | Bearer (access) | Upsert record with explicit rkey |
| `com.atproto.repo.deleteRecord` | POST | Bearer (access) | Remove record from repo |
| `com.atproto.repo.getRecord` | GET | No | Fetch record by repo/collection/rkey |
| `com.atproto.repo.listRecords` | GET | No | Paginated list by collection |
| `com.atproto.repo.describeRepo` | GET | No | Repo metadata and collections |
| `com.atproto.repo.applyWrites` | POST | Bearer (access) | Batch create/update/delete |
| `com.atproto.repo.uploadBlob` | POST | Bearer (access) | Store blob via Blossom |
| `com.atproto.sync.getRepo` | GET | No | Full repo as CAR v1 file |
| `com.atproto.sync.getRecord` | GET | No | Single record as CAR proof |
| `com.atproto.sync.listRepos` | GET | No | List repos (single entry) |
| `com.atproto.sync.listBlobs` | GET | No | Blob CIDs for a DID |
| `com.atproto.sync.getBlob` | GET | No | Fetch blob bytes by CID |
| `com.atproto.sync.getLatestCommit` | GET | No | Head CID + rev |
| `com.atproto.sync.requestCrawl` | POST | No | Notify relay to crawl |
| `com.atproto.sync.subscribeRepos` | GET (WS) | No | Firehose event stream |

### DID Document

#### GET /.well-known/did.json

Returns the DID document for this PDS.

```bash
curl https://station.example.com/.well-known/did.json
```

### AT Proto Debug API

#### GET /api/atproto/status

Returns PDS status including DID, handle, repo head, collections, and record count.

```bash
curl http://localhost:8080/api/atproto/status
```

**Response:**
```json
{
  "enabled": true,
  "running": true,
  "did": "did:web:station.example.com",
  "handle": "user.example.com",
  "headCid": "bafy...",
  "collections": ["app.bsky.feed.post"],
  "recordCount": 42
}
```

#### GET /api/atproto/did

Returns the full DID document (same as `/.well-known/did.json`).

```bash
curl http://localhost:8080/api/atproto/did
```

#### GET /api/atproto/admin-password

Returns the auto-generated admin password for session creation (for testing).

```bash
curl http://localhost:8080/api/atproto/admin-password
```

**Response:**
```json
{
  "password": "random-32-char-password",
  "did": "did:web:station.example.com",
  "handle": "user.example.com"
}
```

#### POST /api/atproto/test-record

Creates a test record and reads it back (for verifying repo CRUD).

```bash
# Create a default test record
curl -X POST http://localhost:8080/api/atproto/test-record

# Create with custom content
curl -X POST http://localhost:8080/api/atproto/test-record \
  -H "Content-Type: application/json" \
  -d '{"collection": "radio.geogram.blog.post", "record": {"$type": "radio.geogram.blog.post", "text": "Hello!"}}'
```

**Response:**
```json
{
  "created": {
    "uri": "at://did:web:station.example.com/radio.geogram.test/3kqfbu2hs4a7o",
    "cid": "bafyrei..."
  },
  "readBack": {
    "uri": "at://did:web:station.example.com/radio.geogram.test/3kqfbu2hs4a7o",
    "cid": "bafyrei...",
    "value": {"$type": "radio.geogram.test", "text": "Test record..."}
  },
  "match": true
}
```

### Testing AT Proto Session + Repo Flow

```bash
# 1. Get admin password
ADMIN=$(curl -s http://localhost:8080/api/atproto/admin-password | jq -r .password)
HANDLE=$(curl -s http://localhost:8080/api/atproto/admin-password | jq -r .handle)
DID=$(curl -s http://localhost:8080/api/atproto/admin-password | jq -r .did)

# 2. Create session
TOKEN=$(curl -s -X POST http://localhost:8080/xrpc/com.atproto.server.createSession \
  -H "Content-Type: application/json" \
  -d "{\"identifier\": \"$HANDLE\", \"password\": \"$ADMIN\"}" | jq -r .accessJwt)

# 3. Create a record
curl -X POST http://localhost:8080/xrpc/com.atproto.repo.createRecord \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"repo\": \"$DID\", \"collection\": \"radio.geogram.blog.post\", \"record\": {\"text\": \"Hello AT Proto!\"}}"

# 4. List records
curl "http://localhost:8080/xrpc/com.atproto.repo.listRecords?repo=$DID&collection=radio.geogram.blog.post"

# 5. Describe repo
curl "http://localhost:8080/xrpc/com.atproto.repo.describeRepo?repo=$DID"

# 6. Resolve handle
curl "http://localhost:8080/xrpc/com.atproto.identity.resolveHandle?handle=$HANDLE"
```

#### GET /api/atproto/collections

List all registered content collections with record counts.

```bash
curl http://localhost:8080/api/atproto/collections
```

Response: `{"collections": [{"nsid": "radio.geogram.blog.post", "displayName": "Blog Posts", "recordCount": 5}, ...]}`

#### POST /api/atproto/sync-collection

Trigger sync for a specific collection (by `nsid` query parameter) or all collections.

```bash
# Sync a specific collection
curl -X POST "http://localhost:8080/api/atproto/sync-collection?nsid=radio.geogram.blog.post"

# Sync all collections
curl -X POST http://localhost:8080/api/atproto/sync-collection
```

Response (specific): `{"nsid": "radio.geogram.blog.post", "created": 3, "error": null}`
Response (all): `{"results": {"radio.geogram.blog.post": 3, "radio.geogram.places.entry": 1, ...}, "totalCreated": 5}`

**Geogram content collection NSIDs:**
| NSID | Geogram Content | Sync Filter |
|------|----------------|-------------|
| `radio.geogram.blog.post` | Blog posts | Published only |
| `radio.geogram.places.entry` | Places | Public/restricted only |
| `radio.geogram.events.entry` | Events | Public/group only |
| `radio.geogram.alerts.report` | Alerts/Reports | Non-closed only |

---

## P2P File Transfer

P2P file transfer enables direct file sharing between Geogram devices. The sender creates an offer, the receiver accepts and downloads files directly from the sender's HTTP API.

For full documentation of the P2P transfer protocol, see [API_p2p.md](API_p2p.md).

### Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/p2p/offer/{offerId}/manifest` | GET | Get offer manifest with serve token |
| `/api/p2p/offer/{offerId}/file` | GET | Download a specific file |

### Message Types

P2P messages are sent as NOSTR DMs via the Connection Manager:

| Type | Direction | Description |
|------|-----------|-------------|
| `transfer_offer` | Sender → Receiver | Initial offer with file manifest |
| `transfer_response` | Receiver → Sender | Accept or reject the offer |
| `transfer_progress` | Receiver → Sender | Download progress updates |
| `transfer_complete` | Receiver → Sender | Transfer completion notification |

### Quick Example

```dart
// Send files to another device
final offer = await P2PTransferService().sendOffer(
  recipientCallsign: 'X1BOB',
  items: [SendItem(path: '/path/to/file.jpg', name: 'file.jpg', isDirectory: false)],
);

// Accept incoming offer
await P2PTransferService().acceptOffer(offerId, '/destination/folder');
```

---

## WebSocket Connection

The station accepts WebSocket connections for real-time messaging.

### Connection Example

```javascript
const ws = new WebSocket('ws://192.168.1.100:8080');

ws.onopen = () => {
  console.log('Connected to station');
};

ws.onmessage = (event) => {
  const message = JSON.parse(event.data);
  console.log('Received:', message);
};
```

### HELLO Protocol

After connecting, clients must send a HELLO message to register with the station. The station responds with a `hello_ack` message.

**Client sends HELLO:**
```json
{
  "type": "hello",
  "event": {
    "pubkey": "abc123...",
    "kind": 0,
    "created_at": 1702000000,
    "tags": [
      ["callsign", "X1ABCD"],
      ["nickname", "Alice"],
      ["platform", "Linux"],
      ["latitude", "38.72"],
      ["longitude", "-9.14"]
    ],
    "content": "Geogram Desktop v1.6.2 on Linux",
    "id": "event_id_here",
    "sig": "signature_here"
  }
}
```

| Tag | Description |
|-----|-------------|
| `callsign` | Device's unique identifier (e.g., X1ABCD) |
| `nickname` | User's display name |
| `platform` | Platform: Android, iOS, Web, Linux, Windows, macOS |
| `latitude` | Device's latitude (optional) |
| `longitude` | Device's longitude (optional) |

**Station responds with hello_ack:**
```json
{
  "type": "hello_ack",
  "success": true,
  "station_id": "X3WFE4",
  "message": "Welcome to p2p.radio",
  "version": "1.6.2"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `type` | string | Always "hello_ack" |
| `success` | boolean | Whether the hello was accepted |
| `station_id` | string | Station's callsign |
| `message` | string | Welcome message or rejection reason |
| `version` | string | Station software version |

### Heartbeat (PING/PONG)

Clients should send periodic PING messages to keep the connection alive:

**Client sends:**
```json
{"type": "PING"}
```

**Station responds:**
```json
{"type": "PONG", "timestamp": 1702000000000}
```

### HTTP Request Proxying

The station can forward HTTP requests to connected devices. This is used by the `/{callsign}/api/*` proxy endpoints.

**Station sends to device:**
```json
{
  "type": "HTTP_REQUEST",
  "requestId": "1702000000000-12345",
  "method": "GET",
  "path": "/api/status",
  "headers": "{}",
  "body": null
}
```

**Device responds:**
```json
{
  "type": "HTTP_RESPONSE",
  "requestId": "1702000000000-12345",
  "statusCode": 200,
  "responseHeaders": "{\"Content-Type\": \"application/json\"}",
  "responseBody": "{\"callsign\": \"X1ABCD\", ...}",
  "isBase64": false
}
```

---

## Station Configuration

### Update Mirroring

When a station has `updateMirrorEnabled: true` in its settings:

1. **Polls GitHub** every 2 minutes (configurable via `updateCheckInterval`)
2. **Downloads ALL binaries** for all platforms to local storage
3. **Serves binaries** to clients via the `/updates/` endpoints

This enables **offgrid-first software updates** - clients check the connected station first for updates, and only fall back to GitHub if the station doesn't have updates cached.

### Client Update Settings

Clients configure their update source in **Settings > Software Updates**:

| Setting | Behavior |
|---------|----------|
| **Download from Station** (default) | Check connected station first, fall back to GitHub |
| **Download from GitHub** | Skip station check, always download from GitHub directly |

### Station Storage Structure

Updates are organized by version number, making it easy to browse and archive:

```
{appSupportDir}/
├── updates/
│   ├── release.json              # Cached release metadata (latest)
│   ├── 1.5.34/                   # Archived version
│   │   ├── geogram.apk
│   │   ├── app-release.aab
│   │   ├── geogram-linux-x64.tar.gz
│   │   ├── geogram-cli-linux-x64.tar.gz
│   │   ├── geogram-windows-x64.zip
│   │   ├── geogram-macos-x64.zip
│   │   ├── geogram-ios-unsigned.ipa
│   │   └── geogram-web.tar.gz
│   ├── 1.5.35/                   # Archived version
│   │   └── ...
│   └── 1.5.36/                   # Latest version
│       ├── geogram.apk
│       ├── app-release.aab
│       ├── geogram-linux-x64.tar.gz
│       ├── geogram-cli-linux-x64.tar.gz
│       ├── geogram-windows-x64.zip
│       ├── geogram-macos-x64.zip
│       ├── geogram-ios-unsigned.ipa
│       └── geogram-web.tar.gz
└── tiles/
    ├── standard/
    │   └── {z}/{x}/{y}.png
    └── satellite/
        └── {z}/{x}/{y}.png
```

**Note:** Previous versions are kept as an archive. The station does not automatically delete old versions, allowing rollback to previous releases if needed.

---

## Error Responses

All endpoints may return the following error responses:

| Status Code | Description |
|-------------|-------------|
| 400 | Bad Request - Invalid parameters |
| 404 | Not Found - Resource doesn't exist |
| 405 | Method Not Allowed - Wrong HTTP method |
| 500 | Internal Server Error |
| 503 | Service Unavailable - Feature disabled |

---

## CORS

All API endpoints include CORS headers for cross-origin access:

```
Access-Control-Allow-Origin: *
Access-Control-Allow-Methods: GET, POST, OPTIONS
Access-Control-Allow-Headers: Content-Type
```

---

## Blossom (BUD-02 Blob Storage)

Hash-addressed file storage following the [Blossom protocol](https://github.com/hzrd149/blossom).

### POST /blossom/upload

Upload a file. Requires Nostr authorization header when `nostrRequireAuthForWrites` is enabled.

**Authorization:** `Authorization: Nostr <base64-encoded kind 24242 event>`

**Request body:** Raw bytes or `multipart/form-data` with a `file` part.

**Response (200 OK):**
```json
{
  "hash": "<sha256>",
  "size": 12345,
  "mime": "image/png",
  "url": "https://example.com/blossom/<sha256>"
}
```

| Status | Meaning |
|--------|---------|
| 200 | Upload successful |
| 400 | Upload too large or invalid |
| 403 | Unauthorized or forbidden |

### GET /blossom/{hash}

Download a blob by its SHA-256 hash.

**Response:** Raw file bytes with `Content-Type: application/octet-stream`.

| Status | Meaning |
|--------|---------|
| 200 | File returned |
| 404 | Blob not found |

### HEAD /blossom/{hash}

Check if a blob exists. Returns `Content-Length` header.

| Status | Meaning |
|--------|---------|
| 200 | Blob exists |
| 404 | Blob not found |

### DELETE /blossom/{hash}

Delete a blob. Requires a Nostr authorization header with a kind 24242 event containing `["t", "delete"]` and `["x", "<sha256>"]` tags.

**Authorization:** `Authorization: Nostr <base64-encoded kind 24242 event>`

The authorization event must include:
- `kind`: 24242
- Tag `["t", "delete"]`
- Tag `["x", "<sha256>"]` matching the requested hash

**Ownership rules:**
- If the blob has a recorded owner, only the owner or station owner can delete it.
- If the blob has no owner, any pubkey in the allowed set (station owner + contacts) can delete it.

| Status | Meaning |
|--------|---------|
| 200 | Blob deleted |
| 401 | Missing or invalid Nostr auth |
| 403 | Not authorized to delete this blob |
| 404 | Blob not found |

---

## Local Backup

Debug API actions for managing local ZIP archive backups of the active profile.

### Set Backup Folder

```bash
curl -X POST http://localhost:8080/api/debug \
  -H 'Content-Type: application/json' \
  -d '{"action": "local_backup_set_folder", "path": "/tmp/geogram-backups"}'
```

### Create Backup

```bash
curl -X POST http://localhost:8080/api/debug \
  -H 'Content-Type: application/json' \
  -d '{"action": "local_backup_create"}'
```

### List Snapshots

```bash
curl -X POST http://localhost:8080/api/debug \
  -H 'Content-Type: application/json' \
  -d '{"action": "local_backup_list"}'
```

### Restore Snapshot

```bash
curl -X POST http://localhost:8080/api/debug \
  -H 'Content-Type: application/json' \
  -d '{"action": "local_backup_restore", "file": "geogram-backup-CALLSIGN-2026-03-03-143000.zip"}'
```

### Delete Snapshot

```bash
curl -X POST http://localhost:8080/api/debug \
  -H 'Content-Type: application/json' \
  -d '{"action": "local_backup_delete", "file": "geogram-backup-CALLSIGN-2026-03-03-143000.zip"}'
```

### Get Status

```bash
curl -X POST http://localhost:8080/api/debug \
  -H 'Content-Type: application/json' \
  -d '{"action": "local_backup_status"}'
```
