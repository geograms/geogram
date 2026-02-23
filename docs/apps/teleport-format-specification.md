# Teleport Format Specification

**Version**: 1.0
**Last Updated**: 2026-02-22
**Status**: Active

## Table of Contents

- [Overview](#overview)
- [Terminology](#terminology)
- [File Organization](#file-organization)
- [Configuration Files](#configuration-files)
- [Bridge Architecture](#bridge-architecture)
- [Unified Message Format](#unified-message-format)
- [Supported Platforms](#supported-platforms)
- [Bridge Lifecycle](#bridge-lifecycle)
- [Protocol Messages](#protocol-messages)
- [Debug API](#debug-api)
- [Security Considerations](#security-considerations)
- [Best Practices](#best-practices)
- [Related Documentation](#related-documentation)
- [Change Log](#change-log)

## Overview

This document specifies the Teleport app for the Geogram platform. Teleport is a modular bridge/gateway system that connects Geogram to external messaging platforms, enabling users to send and receive messages across multiple networks from a single unified interface.

### Key Features

- **Modular Platform Bridges**: Each external platform is handled by an independent bridge module
- **Unified Messaging Interface**: All bridged messages normalized into a common format
- **Per-Bridge Credential Isolation**: Credentials for each platform stored and encrypted separately
- **Connection Monitoring**: Real-time status tracking for each bridge connection
- **Extensible Architecture**: New platform bridges can be added without modifying the core system

### Supported Platforms (Planned)

- Signal
- Telegram
- WhatsApp
- NOSTR
- Bluesky
- IRC
- Matrix
- XMPP

## Terminology

| Term | Definition |
|------|-----------|
| **Bridge** | A module that connects Geogram to a specific external messaging platform. Each bridge handles authentication, message translation, and connection management for its platform. |
| **Platform** | An external messaging service (e.g., Signal, Telegram) that a bridge connects to. |
| **Gateway** | The Teleport system as a whole, acting as a gateway between Geogram and external platforms. |
| **Sync** | The process of pulling new messages from an external platform into Geogram's unified message format. |
| **Credential Store** | The encrypted, per-bridge storage location for platform-specific authentication credentials. Each bridge's credentials are isolated from other bridges. |

## File Organization

### Directory Structure

```
devices/{CALLSIGN}/teleport/
├── config.json          # App-level config: { version, bridges[], updated_at }
├── extra/               # Standard app metadata (app.js, security.json)
├── bridges/             # Per-platform bridge directories
│   └── {platform}/
│       ├── config.json  # Credentials + platform-specific settings
│       ├── status.json  # Connection status + sync state
│       └── messages/    # Message sync cache
└── media/               # Shared media storage for bridged attachments
```

### Key Directories

| Directory | Purpose |
|-----------|---------|
| `teleport/` | Root directory for the Teleport app |
| `teleport/extra/` | Standard Geogram app metadata (app manifest, security settings) |
| `teleport/bridges/` | Contains one subdirectory per enabled platform bridge |
| `teleport/bridges/{platform}/` | Platform-specific configuration, status, and cached messages |
| `teleport/bridges/{platform}/messages/` | Local cache of synced messages for the platform |
| `teleport/media/` | Shared storage for media attachments received through any bridge |

## Configuration Files

### App Configuration (config.json)

The top-level configuration file tracks which bridges are enabled and the overall app state.

```json
{
  "version": "1.0",
  "bridges": [
    {
      "platform": "telegram",
      "enabled": true,
      "added_at": "2026-02-22T10:00:00Z"
    },
    {
      "platform": "signal",
      "enabled": false,
      "added_at": "2026-02-20T08:30:00Z"
    }
  ],
  "updated_at": "2026-02-22T10:00:00Z"
}
```

#### Field Definitions

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `version` | string | Yes | Format version (currently "1.0") |
| `bridges` | array | Yes | List of enabled bridge entries |
| `bridges[].platform` | string | Yes | Platform identifier (e.g., "signal", "telegram") |
| `bridges[].enabled` | boolean | Yes | Whether this bridge is currently active |
| `bridges[].added_at` | string | Yes | ISO 8601 timestamp of when the bridge was added |
| `updated_at` | string | Yes | ISO 8601 timestamp of last modification |

### Bridge Configuration (bridges/{platform}/config.json)

Each bridge has its own configuration file containing platform-specific credentials and settings.

```json
{
  "platform": "telegram",
  "enabled": true,
  "credentials": {
    "bot_token": "encrypted:v1:...",
    "api_id": "encrypted:v1:...",
    "api_hash": "encrypted:v1:..."
  },
  "settings": {
    "polling_interval_seconds": 30,
    "sync_depth_days": 7,
    "auto_reconnect": true,
    "max_message_cache": 1000
  },
  "created_at": "2026-02-22T10:00:00Z",
  "updated_at": "2026-02-22T10:00:00Z"
}
```

#### Field Definitions

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `platform` | string | Yes | Platform identifier (signal, telegram, whatsapp, nostr, bluesky, irc, matrix, xmpp) |
| `enabled` | boolean | Yes | Whether this bridge is currently active |
| `credentials` | object | Yes | Platform-specific authentication credentials (encrypted at rest) |
| `settings` | object | Yes | Platform-specific settings |
| `settings.polling_interval_seconds` | integer | No | How often to poll for new messages (default varies by platform) |
| `settings.sync_depth_days` | integer | No | How many days of history to sync on first connection |
| `settings.auto_reconnect` | boolean | No | Whether to automatically reconnect on connection loss |
| `settings.max_message_cache` | integer | No | Maximum number of messages to keep in local cache |
| `created_at` | string | Yes | ISO 8601 timestamp of bridge creation |
| `updated_at` | string | Yes | ISO 8601 timestamp of last configuration change |

### Bridge Status (bridges/{platform}/status.json)

Tracks the real-time connection state and sync progress for each bridge.

```json
{
  "platform": "telegram",
  "state": "connected",
  "last_connected": "2026-02-22T10:05:00Z",
  "last_sync": "2026-02-22T10:30:00Z",
  "error": null,
  "message_count": 247,
  "updated_at": "2026-02-22T10:30:00Z"
}
```

#### Field Definitions

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `platform` | string | Yes | Platform identifier |
| `state` | string | Yes | Current connection state (see [State Diagram](#state-diagram)) |
| `last_connected` | string\|null | Yes | ISO 8601 timestamp of last successful connection, or null if never connected |
| `last_sync` | string\|null | Yes | ISO 8601 timestamp of last successful message sync, or null if never synced |
| `error` | string\|null | Yes | Last error message if state is "error", otherwise null |
| `message_count` | integer | Yes | Total number of messages synced through this bridge |
| `updated_at` | string | Yes | ISO 8601 timestamp of last status update |

#### Valid States

| State | Description |
|-------|-------------|
| `disconnected` | Bridge is configured but not connected |
| `connecting` | Bridge is attempting to establish a connection |
| `connected` | Bridge is connected and idle |
| `error` | Bridge encountered an error (see `error` field for details) |
| `syncing` | Bridge is actively pulling or pushing messages |

## Bridge Architecture

### Interface Contract

Every bridge implementation must provide these operations:

| Operation | Signature | Description |
|-----------|-----------|-------------|
| `configure` | `configure(credentials, settings)` | Set up the bridge with platform credentials and settings |
| `connect` | `connect()` | Establish connection to the external platform |
| `disconnect` | `disconnect()` | Gracefully close the connection |
| `sync` | `sync()` | Pull new messages from the platform |
| `send` | `send(message)` | Send a message through the bridge to the platform |
| `getStatus` | `getStatus()` | Return the current bridge status object |
| `destroy` | `destroy()` | Clean up all bridge data (credentials, cache, status) |

### State Diagram

```
disconnected --> connecting --> connected <--> syncing
     ^               |              |
     |               v              v
     +---------- error <-----------+
```

Transitions:

- `disconnected` -> `connecting`: When `connect()` is called
- `connecting` -> `connected`: When connection is successfully established
- `connecting` -> `error`: When connection attempt fails
- `connected` -> `syncing`: When `sync()` is called
- `syncing` -> `connected`: When sync completes successfully
- `syncing` -> `error`: When sync encounters a failure
- `connected` -> `error`: When an unexpected disconnection or platform error occurs
- `error` -> `disconnected`: When `disconnect()` is called or error is acknowledged
- `connected` -> `disconnected`: When `disconnect()` is called

## Unified Message Format

All messages from external platforms are normalized into a common format for display and storage within Geogram.

```json
{
  "id": "msg_a1b2c3d4e5f6",
  "bridge": "telegram",
  "direction": "inbound",
  "sender": {
    "id": "user_789",
    "name": "Alice",
    "platform_id": "tg_12345678"
  },
  "content": {
    "type": "text",
    "body": "Hello world"
  },
  "timestamp": "2026-02-22T10:30:00Z",
  "platform_message_id": "tg_msg_99887766",
  "metadata": {}
}
```

### Field Definitions

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique message identifier (prefixed with `msg_`) |
| `bridge` | string | Yes | Platform bridge identifier that produced this message |
| `direction` | string | Yes | "inbound" (received from platform) or "outbound" (sent to platform) |
| `sender` | object | Yes | Information about the message sender |
| `sender.id` | string | Yes | Internal sender identifier |
| `sender.name` | string | Yes | Display name of the sender |
| `sender.platform_id` | string | Yes | Sender's identifier on the originating platform |
| `content` | object | Yes | Message content payload |
| `content.type` | string | Yes | Content type: "text", "image", "file", "audio", "video", "location" |
| `content.body` | string | Yes | Text content or description of non-text content |
| `timestamp` | string | Yes | ISO 8601 timestamp of when the message was sent |
| `platform_message_id` | string | Yes | Original message identifier on the source platform |
| `metadata` | object | No | Additional platform-specific metadata |

## Supported Platforms

| Platform | Bridge ID | Protocol | Status |
|----------|-----------|----------|--------|
| Signal | `signal` | Signal Protocol | Planned |
| Telegram | `telegram` | Bot API / MTProto | Planned |
| WhatsApp | `whatsapp` | WhatsApp Web | Planned |
| NOSTR | `nostr` | WebSocket (NIP-01) | Planned |
| Bluesky | `bluesky` | AT Protocol | Planned |
| IRC | `irc` | IRC Protocol | Planned |
| Matrix | `matrix` | Matrix Client-Server API | Planned |
| XMPP | `xmpp` | XMPP/Jabber | Planned |

## Bridge Lifecycle

### Adding a Bridge

1. User selects a platform from the available bridge list
2. Platform bridge config directory created under `bridges/{platform}/`
3. User provides platform credentials
4. Bridge `config.json` written with encrypted credentials
5. Bridge `status.json` initialized with state `disconnected`
6. Bridge entry added to the app-level `config.json` bridges array
7. Initial connection attempted

### Removing a Bridge

1. Bridge disconnected if currently active
2. Bridge entry removed from the app-level `config.json`
3. Bridge directory deleted (config, status, and cached messages)
4. Shared media optionally cleaned up (media files not referenced by other bridges)

## Protocol Messages

Bridge state changes are published as NOSTR-signed events using kind 30078 (application-specific data) for cross-device synchronization:

```json
{
  "kind": 30078,
  "tags": [
    ["d", "teleport:{platform}:status"],
    ["platform", "{platform}"],
    ["state", "connected"]
  ],
  "content": "{encrypted_status_json}"
}
```

### Tag Definitions

| Tag | Description |
|-----|-------------|
| `d` | Parameterized replaceable event identifier, scoped to `teleport:{platform}:status` |
| `platform` | The bridge platform identifier |
| `state` | Current bridge state (mirrors `status.json` state field) |

The `content` field contains the full `status.json` payload encrypted with the profile encryption key, ensuring bridge status is only readable by the device owner.

## Debug API

The debug API provides endpoints for development and testing of bridge functionality.

### Endpoints

#### Get All Bridge Status

```
GET /api/teleport/status

Response:
{
  "bridges": [
    {
      "platform": "telegram",
      "state": "connected",
      "message_count": 247,
      "last_sync": "2026-02-22T10:30:00Z"
    },
    {
      "platform": "signal",
      "state": "disconnected",
      "message_count": 0,
      "last_sync": null
    }
  ]
}
```

#### Add a Bridge

```
POST /api/teleport/bridges/{platform}/add
{
  "credentials": { ... },
  "settings": { ... }
}

Response:
{
  "success": true,
  "platform": "telegram",
  "state": "connecting"
}
```

#### Remove a Bridge

```
DELETE /api/teleport/bridges/{platform}/remove

Response:
{
  "success": true,
  "platform": "telegram",
  "removed": true
}
```

## Security Considerations

### Credential Protection

- All credentials encrypted at rest using the profile encryption key
- Per-bridge isolation: compromising one bridge does not affect others
- Credentials never logged or included in sync data
- Credential values prefixed with `encrypted:v1:` to indicate encryption format

### Transport Security

- Bridge connections use TLS where the platform supports it
- NOSTR protocol messages carrying bridge status are encrypted in the `content` field
- Audit trail of bridge state changes maintained in the app log

### Data Handling

- Message content not stored permanently unless the user opts in
- Media files stored in shared `media/` directory with no external references
- Bridge `destroy()` operation performs complete data removal (credentials, cache, status)

## Best Practices

### Setup

- Enable one bridge at a time during initial setup to isolate connection issues
- Verify credentials are correct before enabling auto-reconnect
- Start with a short `sync_depth_days` value and increase once the bridge is stable

### Monitoring

- Regularly check bridge status for connection issues
- Review the `error` field in `status.json` when a bridge enters the error state
- Monitor media storage usage for high-volume bridges

### Maintenance

- Keep bridge credentials up to date (rotate tokens, refresh API keys)
- Use platform-specific two-factor authentication where available
- Periodically clean the message cache for bridges with high traffic

## Related Documentation

- [Chat Format Specification](chat-format-specification.md) - Geogram's native chat message format
- [Backup Format Specification](backup-format-specification.md) - Device backup and restore procedures

## Change Log

| Version | Date       | Changes         |
|---------|------------|-----------------|
| 1.0     | 2026-02-22 | Initial release |

---

*This specification is part of the Geogram project.*
*License: Apache-2.0*
