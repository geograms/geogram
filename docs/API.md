# Geogram Station API

This document describes the HTTP API endpoints available on Geogram radio stations.

## Table of Contents

- [Overview](#overview)
- [Base URL](#base-url)
- [Endpoints](#endpoints)
  - [Status](#status)
  - [Clients](#clients)
  - [Software Updates](#software-updates)
  - [Map Tiles](#map-tiles)
  - [Chat](#chat)
  - [Direct Messages](#direct-messages)
  - [Blog](#blog)
  - [Logs](#logs)
  - [Debug API](#debug-api)
- [WebSocket Connection](#websocket-connection)
- [Station Configuration](#station-configuration)

## Overview

Geogram stations provide a local HTTP API that enables:

- **Offgrid Software Updates**: Mirrors GitHub releases for clients without internet
- **Map Tile Caching**: Serves cached OpenStreetMap and satellite tiles
- **Chat & Messaging**: Room-based chat and direct messages
- **Blog Publishing**: Serves user blog posts as HTML
- **Device Status**: Information about connected devices

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
  "version": "1.5.36",
  "callsign": "STATION-42",
  "description": "My local Geogram station",
  "connected_devices": 5,
  "uptime": 3600,
  "station_mode": true,
  "location": "Grid Square",
  "latitude": 38.7169,
  "longitude": -9.1399,
  "tile_server": true,
  "osm_fallback": true,
  "cache_size": 150,
  "cache_size_bytes": 52428800
}
```

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Station name |
| `version` | string | Geogram version |
| `callsign` | string | Station callsign |
| `description` | string | Station description |
| `connected_devices` | int | Number of connected clients |
| `uptime` | int | Uptime in seconds |
| `station_mode` | bool | Whether running as station |
| `location` | string | Location description |
| `latitude` | float | Station latitude |
| `longitude` | float | Station longitude |
| `tile_server` | bool | Tile server enabled |
| `osm_fallback` | bool | OSM fallback enabled |
| `cache_size` | int | Tiles in cache |
| `cache_size_bytes` | int | Cache size in bytes |

---

### Clients

#### GET /api/clients

Returns list of connected clients, grouped by callsign.

**Response (200 OK):**
```json
{
  "station": "STATION-42",
  "count": 3,
  "clients": [
    {
      "callsign": "USER-123",
      "nickname": "Alice",
      "npub": "npub1abc...",
      "connection_types": ["local", "lora"],
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
| `npub` | string | Nostr public key (if available) |
| `connection_types` | array | Connection methods (`local`, `lora`, `meshtastic`) |
| `latitude` | float | Client's latitude (if shared) |
| `longitude` | float | Client's longitude (if shared) |
| `connected_at` | string | ISO 8601 connection timestamp |
| `last_activity` | string | ISO 8601 last activity timestamp |
| `is_online` | bool | Online status |

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

#### GET /api/dm/{recipientId}/messages

Returns direct messages with a specific recipient.

**Parameters:**
| Parameter | Description |
|-----------|-------------|
| `recipientId` | Recipient's callsign or identifier |

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
| `refresh_devices` | Refresh all device sources | None |
| `local_scan` | Scan local network for devices | None |
| `connect_station` | Connect to a station | `url` (optional): Station WebSocket URL |
| `disconnect_station` | Disconnect from current station | None |

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
```

---

## WebSocket Connection

The station accepts WebSocket connections for real-time messaging.

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
