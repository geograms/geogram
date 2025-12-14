# Geogram Station API

This document describes the HTTP API endpoints available on Geogram radio stations.

## Table of Contents

- [Overview](#overview)
- [Connection Manager](#connection-manager)
- [Base URL](#base-url)
- [Endpoints](#endpoints)
  - [Status](#status)
  - [Clients](#clients)
  - [Device Proxy](#device-proxy)
  - [Alert File Upload/Download](#alert-file-uploaddownload-station)
  - [Software Updates](#software-updates)
  - [Map Tiles](#map-tiles)
  - [Chat](#chat)
  - [Direct Messages](#direct-messages)
  - [Blog](#blog)
  - [Events](#events)
  - [Alerts](#alerts)
  - [Logs](#logs)
  - [Debug API](#debug-api)
  - [Backup](#backup)
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
| `uptime` | int | Uptime in seconds (stations only) |
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
  "photos": ["photo1.jpg", "photo2.png", "test_photo.png"],
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
| `photos` | array | List of photo filenames in the alert folder |
| `comments` | array | List of comment objects (see below) |
| `comment_count` | int | Number of comments |
| `callsign` | string | Alert owner's callsign |
| `report_content` | string | Raw report.txt content for sync |

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

#### POST /{callsign}/api/alerts/{folderName}/comment

Adds a comment to an alert on the station.

**Parameters:**
| Parameter | Description |
|-----------|-------------|
| `callsign` | Callsign of the alert owner (uppercase) |
| `folderName` | Alert folder name (e.g., `38_7223_n9_1393_broken-sidewalk`) |

**Request Body:**
```json
{
  "content": "I can confirm this issue is still present.",
  "author": "X1ABCD",
  "npub": "npub1xyz...",
  "signature": "sig123..."
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `content` | string | Yes | Comment text |
| `author` | string | No | Author's callsign (defaults to sender) |
| `npub` | string | No | Author's NOSTR public key |
| `signature` | string | No | NOSTR signature for verification |

**Response (200 OK):**
```json
{
  "success": true,
  "filename": "1702000000000.txt",
  "message": "Comment added successfully"
}
```

**Response (404 Not Found):**
```json
{
  "error": "Alert not found"
}
```

**Example Usage:**
```bash
# Add a comment to an alert
curl -X POST http://localhost:3457/X1ABCD/api/alerts/38_7222_n9_1393_broken-sidewalk/comment \
  -H "Content-Type: application/json" \
  -d '{"content": "I can confirm this issue!", "author": "X2BCDE"}'
```

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

#### GET /api/chat/rooms/{roomId}/messages

Returns messages for a specific chat room.

**Parameters:**
| Parameter | Description |
|-----------|-------------|
| `roomId` | Room identifier (e.g., `general`) |

**Response (200 OK):**
```json
{
  "room": "general",
  "messages": []
}
```

#### POST /api/chat/rooms/{roomId}/messages

Posts a message to a chat room.

**Response (201 Created):**
```json
{
  "status": "ok"
}
```

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

### Blog

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
| `send_dm` | Send a direct message | `callsign`: Target callsign (required), `content`: Message (required) |
| `sync_dm` | Sync DMs with a device | `callsign`: Target callsign (required), `url` (optional): Device URL |
| `voice_record` | Record audio for testing | `duration` (optional): Seconds to record (default: 5) |
| `voice_stop` | Stop recording and get file path | None |
| `voice_status` | Get recording/playback status | None |
| `backup_provider_enable` | Enable backup provider mode | `max_storage_bytes` (optional): Max total storage, `max_client_storage` (optional): Per-client limit, `max_snapshots` (optional): Max snapshots per client |
| `backup_create_test_data` | Create random test files for backup testing | `file_count` (optional): Number of files (default: 10), `max_file_size` (optional): Max bytes per file (default: 10240) |
| `backup_send_invite` | Send backup invite to a provider | `provider_callsign` (required): Target provider callsign, `interval_days` (optional): Backup interval (default: 3) |
| `backup_accept_invite` | Accept a pending backup invite (provider side) | `client_callsign` (required): Client to accept |
| `backup_start` | Start backup to a provider | `provider_callsign` (required): Target provider |
| `backup_get_status` | Get current backup/restore status | None |
| `backup_restore` | Start restore from a provider snapshot | `provider_callsign` (required): Provider callsign, `snapshot_id` (optional): Snapshot date (YYYY-MM-DD) |
| `backup_list_snapshots` | List available snapshots from a provider | `provider_callsign` (required): Provider callsign |
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
| `station_server_start` | Start the station server | None. Starts StationServerService on port (API port + 1) |
| `station_server_stop` | Stop the station server | None. Stops the running station server |
| `station_server_status` | Get station server status | None. Returns running state, port, and connected client count |

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
  "available_actions": ["navigate", "ble_scan", "ble_advertise", "refresh_devices", "local_scan", "connect_station", "disconnect_station"]
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

# Start BLE advertising
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "ble_advertise"}'

# Refresh all devices
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "refresh_devices"}'

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
  -d '{"action": "backup_list_snapshots", "provider_callsign": "X2BCDE"}'

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
```

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
      "total_files": 1234,
      "total_bytes": 524288000,
      "started_at": "2025-12-12T15:30:00Z",
      "completed_at": "2025-12-12T16:45:00Z"
    }
  ]
}
```

##### GET /api/backup/clients/{callsign}/snapshots/{date}

Get snapshot manifest (encrypted).

**Parameters:**
| Parameter | Description |
|-----------|-------------|
| `callsign` | Client's callsign |
| `date` | Snapshot date `YYYY-MM-DD` |

**Response (200 OK):** Encrypted manifest JSON (decryptable only by client).

##### GET /api/backup/clients/{callsign}/snapshots/{date}/files/{name}

Download encrypted file from snapshot.

**Response (200 OK):** Binary encrypted file data.

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
  "file": "a94a8fe5.enc",
  "bytes": 4128
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
  "snapshot_id": "2025-12-12",
  "status": "in_progress"
}
```

##### GET /api/backup/status

Get current backup status.

**Response (200 OK):**
```json
{
  "active_backup": {
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
}
```

##### POST /api/backup/restore

Start restore from a provider snapshot.

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
  "status": "downloading",
  "total_files": 1234,
  "total_bytes": 524288000
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
