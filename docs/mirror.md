# Mirror Synchronization

Peer-to-peer app data synchronization between Geogram instances on the same LAN.

## Overview

Mirror keeps app data (blog posts, chat messages, contacts, etc.) synchronized between two or more devices running the same Geogram account. Each device runs an HTTP server on port **3456** that handles discovery, authentication, and file transfer.

## Architecture

```
Device A (initiator)                    Device B (responder)
─────────────────────                   ─────────────────────
mirror_wizard_page.dart                 log_api_service.dart
  ├─ _startDiscovery()                    ├─ GET /api/status
  │   scans subnet:3456 ──────────────►   │   returns npub, callsign, etc.
  │
  ├─ _finishWizard()
  │   POST /api/mirror/pair ──────────►   ├─ POST /api/mirror/pair
  │   sends: our npub, callsign, apps     │   adds A to allowedPeers
  │   gets: their npub, callsign          │   creates reciprocal MirrorPeer
  │                                       │   returns own npub, callsign
  │   addAllowedPeer(B.npub)
  │   addPeer(B) to config
  │
  ├─ syncFolder(peerUrl, appId) ×N
  │   for each selected app:
  │                                       │
  │   GET /api/mirror/challenge ──────►   ├─ GET /api/mirror/challenge
  │   gets nonce                          │   generates 2-min nonce
  │                                       │
  │   sign(nonce) with our nsec           │
  │   POST /api/mirror/request ───────►   ├─ POST /api/mirror/request
  │   sends NOSTR-signed event            │   verifies signature
  │   gets access token                   │   checks npub in allowedPeers
  │                                       │   issues 1-hour token
  │                                       │
  │   GET /api/mirror/manifest ───────►   ├─ GET /api/mirror/manifest
  │   gets file list with SHA1 hashes     │   scans folder, returns entries
  │                                       │
  │   diff against local folder           │
  │                                       │
  │   GET /api/mirror/file ───────────►   ├─ GET /api/mirror/file
  │   downloads changed files (×N)        │   serves file bytes + SHA1
  │   verifies SHA1 after download        │
  └─ markPeerSynced()                   └─
```

## Data Model

### MirrorPeer (persisted in mirror_config.json)

```dart
class MirrorPeer {
  String peerId;           // npub (stable crypto identity)
  String name;             // Display name (nickname or callsign)
  String callsign;         // Geogram callsign
  String npub;             // NOSTR public key — used for auth
  List<String> addresses;  // LAN addresses (e.g. "192.168.1.50:3456")
  Map<String, AppSyncConfig> apps;  // Per-app sync settings
  String? platform;        // "linux", "android", etc.
  DateTime? lastSyncAt;
}
```

### AppSyncConfig (per app per peer)

```dart
class AppSyncConfig {
  String appId;       // "blog", "chat", "contacts", etc.
  SyncStyle style;    // sendReceive, receiveOnly, sendOnly, paused
  bool enabled;
  SyncState state;    // idle, scanning, syncing, error, outOfSync
}
```

### SyncStyle behavior

| Style | Pull from peer | Peer can pull from us |
|-------|:-:|:-:|
| sendReceive | Yes | Yes |
| receiveOnly | Yes | No |
| sendOnly | No | Yes |
| paused | No | No |

## Key Files

| File | Role |
|------|------|
| `lib/models/mirror_config.dart` | Data models (MirrorPeer, AppSyncConfig, MirrorConfig) |
| `lib/services/mirror_config_service.dart` | Config persistence (load/save mirror_config.json) |
| `lib/services/mirror_sync_service.dart` | Sync engine: challenge-response auth, manifest diff, file download |
| `lib/services/mirror_auto_sync_service.dart` | Periodic auto-sync timer + `syncAllPeers()` shared logic |
| `lib/services/log_api_service.dart` | HTTP server — mirror API endpoints (lines 13064+) |
| `lib/pages/mirror_wizard_page.dart` | Add Mirror Device wizard UI |
| `lib/pages/mirror_settings_page.dart` | Mirror settings + Sync Now / Sync All |
| `lib/pages/setup_mirror_page.dart` | Passive page showing this device's IP |

## API Endpoints

All served on port 3456 by log_api_service.dart.

### Discovery

#### `GET /api/status`

Returns device identity for discovery scanning.

**Response:**
```json
{
  "service": "Geogram Desktop",
  "version": "1.17.0",
  "type": "desktop",
  "status": "online",
  "callsign": "X1ABC123",
  "nickname": "My Laptop",
  "npub": "npub1abc...",
  "platform": "linux",
  "port": 3456
}
```

### Pairing

#### `POST /api/mirror/pair`

Mutual peer registration. Called by the initiating device to register itself on the remote and get the remote's identity back.

**Request:**
```json
{
  "npub": "npub1requester...",
  "callsign": "X1ABC123",
  "device_name": "My Phone",
  "platform": "android",
  "address": "192.168.1.42:3456",
  "apps": ["blog", "chat", "contacts", "places"]
}
```

**Response:**
```json
{
  "success": true,
  "npub": "npub1responder...",
  "callsign": "X1DEF456",
  "device_name": "My Laptop",
  "platform": "linux"
}
```

**What it does on the receiving side:**
1. Adds requester's npub to `MirrorSyncService._allowedPeers`
2. Creates a `MirrorPeer` entry in local `mirror_config.json`
3. Enables mirror if not already enabled

### Sync Protocol

#### `GET /api/mirror/challenge?folder=<app_id>`

Get a one-time nonce for authentication. Nonce expires in 2 minutes.

**Response:**
```json
{
  "success": true,
  "nonce": "5f8c...64d8",
  "folder": "blog",
  "expires_at": 1738857600
}
```

#### `POST /api/mirror/request`

Submit a NOSTR-signed challenge response to get an access token.

**Request:**
```json
{
  "event": {
    "pubkey": "hex-pubkey...",
    "created_at": 1738857590,
    "kind": 1,
    "content": "mirror_response:<nonce>:<folder>",
    "tags": [["t", "mirror_response"], ["folder", "blog"], ["nonce", "5f8c..."]],
    "sig": "hex-signature..."
  },
  "folder": "blog"
}
```

**Response:**
```json
{
  "success": true,
  "allowed": true,
  "token": "uuid-access-token",
  "expires_at": 1738861200
}
```

**Verification steps:**
1. NOSTR signature is valid
2. Request is fresh (< 5 minutes old)
3. Peer's npub is in `_allowedPeers` map
4. Nonce exists and hasn't expired
5. Folder matches the challenge

#### `GET /api/mirror/manifest?folder=<app_id>&token=<token>`

Get file listing with SHA1 hashes for diffing.

**Response:**
```json
{
  "success": true,
  "folder": "blog",
  "total_files": 42,
  "total_bytes": 104857600,
  "files": [
    {"path": "posts/hello.md", "sha1": "2aae6c35...", "mtime": 1738857600, "size": 1024}
  ],
  "generated_at": 1738857600
}
```

#### `GET /api/mirror/file?path=<relative_path>&token=<token>`

Download a single file. Supports HTTP Range requests for resume.

**Response:** Raw bytes with headers:
```
Content-Type: application/octet-stream
Content-Length: 1024
X-SHA1: 2aae6c35...
```

## Debug API

All debug actions are sent via `POST /api/debug` with `{"action": "<action>", ...params}`.

### Available Mirror Debug Actions

#### `mirror_enable` — Enable/disable mirror

```bash
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "mirror_enable", "enabled": true}'
```

#### `mirror_get_status` — Get mirror status and allowed peers

```bash
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "mirror_get_status"}'
```

**Response:**
```json
{
  "success": true,
  "enabled": true,
  "status": {"state": "idle", "files_processed": 0, "total_files": 0},
  "allowed_peers": [
    {"npub": "npub1abc...", "callsign": "X1ABC123"}
  ]
}
```

#### `mirror_add_allowed_peer` — Register a peer as allowed to sync from us

```bash
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "mirror_add_allowed_peer", "npub": "npub1abc...", "callsign": "X1ABC123"}'
```

#### `mirror_remove_allowed_peer` — Remove a peer from allowed list

```bash
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "mirror_remove_allowed_peer", "npub": "npub1abc..."}'
```

#### `mirror_request_sync` — Trigger a folder sync from a peer

Pulls a specific app folder from a remote device. The remote must have our npub in its allowed peers.

```bash
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "mirror_request_sync", "peer_url": "http://192.168.1.50:3456", "folder": "blog"}'
```

**Response:**
```json
{
  "success": true,
  "files_added": 12,
  "files_modified": 3,
  "files_deleted": 0,
  "bytes_transferred": 524288,
  "duration_ms": 1250
}
```

#### `mirror_auto_sync_status` — Check auto-sync timer state

```bash
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "mirror_auto_sync_status"}'
```

**Response:**
```json
{
  "success": true,
  "active": true,
  "interval_minutes": 15,
  "is_syncing": false,
  "last_sync_at": "2026-03-03T12:00:00.000Z"
}
```

#### `mirror_auto_sync_trigger` — Trigger an immediate sync of all peers

```bash
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "mirror_auto_sync_trigger"}'
```

**Response:**
```json
{
  "success": true,
  "files_added": 5,
  "files_modified": 2,
  "files_uploaded": 1,
  "errors": 0,
  "peers_skipped": 0,
  "peers_synced": 1,
  "details": [{"peer": "X1ABC", "app": "blog", "added": 5, "modified": 2, "uploaded": 1}]
}
```

#### `mirror_relay_status` — Check station relay URLs per peer

```bash
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "mirror_relay_status"}'
```

**Response:**
```json
{
  "success": true,
  "station_connected": true,
  "station_url": "wss://station.example.com",
  "peers": [
    {
      "callsign": "X1ABC123",
      "direct_address": "192.168.1.50:3456",
      "station_relay_url": "https://station.example.com/device/X1ABC123",
      "addresses": ["192.168.1.50:3456", "station://station.example.com/device/X1ABC123"]
    }
  ]
}
```

## Auto-Sync

When mirror is enabled with `autoSync: true` in connection preferences, the `MirrorAutoSyncService` runs a periodic timer (default every 15 minutes) that syncs all peers automatically.

- Timer is started after profile load and stopped on profile switch
- Subscribes to `MirrorConfigService.configStream` to react to config changes (enable/disable, interval change)
- Guarded by `_isSyncing` flag to prevent overlapping syncs
- Falls back to station relay when direct LAN connection fails

## Station Relay

Mirror sync works over LAN by default (direct HTTP to `http://peer-ip:3456/api/mirror/*`). When devices aren't on the same network, sync requests are relayed through the station's device proxy.

**How it works:**

1. When a device connects to a station via WebSocket, relay addresses (`station://host/device/{callsign}`) are added to each mirror peer's address list
2. When auto-sync runs, it probes the direct address first (3s timeout)
3. If direct fails, falls back to station relay URL (`https://host/device/{callsign}/api/mirror/*`)
4. The station's existing HTTP proxy forwards the request through WebSocket to the target device
5. Binary transfers work through base64 encoding in WebSocket messages
6. On disconnect, relay addresses are cleaned up

## Testing Mirror Between Two Devices

### Manual test via debug API (curl)

This demonstrates the full mirror flow between Device A (192.168.1.42) and Device B (192.168.1.50):

```bash
# 1. Get Device A's identity
curl http://192.168.1.42:3456/api/status | jq '.npub, .callsign'
# → "npub1aaa...", "X1AAAAAA"

# 2. Get Device B's identity
curl http://192.168.1.50:3456/api/status | jq '.npub, .callsign'
# → "npub1bbb...", "X1BBBBBB"

# 3. Enable mirror on both devices
curl -X POST http://192.168.1.42:3456/api/debug \
  -d '{"action": "mirror_enable", "enabled": true}'
curl -X POST http://192.168.1.50:3456/api/debug \
  -d '{"action": "mirror_enable", "enabled": true}'

# 4. On Device B: allow Device A to sync from B
curl -X POST http://192.168.1.50:3456/api/debug \
  -d '{"action": "mirror_add_allowed_peer", "npub": "npub1aaa...", "callsign": "X1AAAAAA"}'

# 5. On Device A: pull blog from Device B
curl -X POST http://192.168.1.42:3456/api/debug \
  -d '{"action": "mirror_request_sync", "peer_url": "http://192.168.1.50:3456", "folder": "blog"}'

# 6. Verify sync status
curl -X POST http://192.168.1.42:3456/api/debug \
  -d '{"action": "mirror_get_status"}' | jq

# For bidirectional: repeat steps 4-5 in the other direction
# On Device A: allow Device B
curl -X POST http://192.168.1.42:3456/api/debug \
  -d '{"action": "mirror_add_allowed_peer", "npub": "npub1bbb...", "callsign": "X1BBBBBB"}'

# On Device B: pull blog from Device A
curl -X POST http://192.168.1.50:3456/api/debug \
  -d '{"action": "mirror_request_sync", "peer_url": "http://192.168.1.42:3456", "folder": "blog"}'
```

### Via the UI

1. On Device B: open Settings > Profile > Setup Mirror (shows B's IP address)
2. On Device A: open Settings > Mirror > Add Device wizard
3. Wizard discovers Device B, select it, choose apps, finish
4. Pairing endpoint registers both devices, initial sync pulls data
5. Either device: Mirror settings > Sync Now to pull latest changes

## Implementation Gaps (TODO)

~~1. `POST /api/mirror/pair` endpoint~~ — Done.
~~2. `npub` field on `MirrorPeer`~~ — Done.
~~3. `_finishWizard()` in mirror_wizard_page.dart~~ — Done.
~~4. `_syncNow()` / `_syncAll()`~~ — Done (shared via `MirrorAutoSyncService.syncAllPeers()`).
~~5. `_allowedPeers` persistence~~ — Done (loaded from config on startup).
~~6. Auto-sync timer~~ — Done (`MirrorAutoSyncService`).
~~7. Station relay fallback~~ — Done (direct → station proxy fallback).

## Security

- **NOSTR challenge-response**: Prevents unauthorized sync. Only peers whose npub is in `_allowedPeers` can authenticate.
- **Token-based access**: After auth, a 1-hour token is issued for manifest/file requests.
- **Single-use nonce**: Challenges expire after 2 minutes and can only be used once (replay prevention).
- **SHA1 verification**: Every downloaded file is verified against its manifest hash.
- **Path traversal protection**: File paths are normalized to prevent directory escape.
- **LAN-only pairing**: The `/api/mirror/pair` endpoint is only reachable on the local network.
