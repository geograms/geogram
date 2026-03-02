# APRS Bridge for Geogram

**Version**: 1.0
**Status**: Active
**Last Updated**: 2026-03-02

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [APRS-IS Connection](#aprs-is-connection)
- [Message Types](#message-types)
- [Conversations](#conversations)
- [Geo-Chat](#geo-chat)
- [BlueAPRS (APRS over BLE)](#blueaprs-aprs-over-ble)
- [Caching & Persistence](#caching--persistence)
- [GPS Integration](#gps-integration)
- [UI Components](#ui-components)
- [Debug API](#debug-api)
- [Configuration](#configuration)
- [File Reference](#file-reference)

## Overview

Geogram integrates APRS (Automatic Packet Reporting System) as a Teleport bridge, allowing ham radio operators to send and receive APRS messages, position reports, and geo-chat through the Geogram interface.

**Key Features:**
- APRS-IS TCP connection for internet-based APRS messaging
- Direct 1:1 messaging with ACK/NAK support
- Hashtag group channels (`#cq`, `#wx`, etc.) via bulletins
- Geo-chat: position reports with human-authored comments shown on a map
- BlueAPRS: APRS over Bluetooth Low Energy (iGate + repeater)
- Conversation grouping with unread tracking
- Offline persistence via SQLite cache
- GPS-driven filter updates for location-aware packet reception

## Architecture

```
                              ┌─── APRS-IS (TCP)
                              │    rotate.aprs2.net:10152
                              │
AprsService (singleton) ──────┤─── AprsIsClient (TCP socket)
    ├── streamPackets          │
    ├── messages               │
    ├── geoChatMessages        │
    └── conversations          │
                              │
BLE Clients ── BLEMessageService ── BlueAprsService ── AprsService
                (channel: _aprs)     (iGate + repeater)
```

### Singleton Pattern

`AprsService` follows the same singleton pattern as other Teleport bridges (Telegram, Signal). It manages all APRS state including packet lists, conversations, and the APRS-IS client connection.

### Key Classes

| Class | File | Purpose |
|-------|------|---------|
| `AprsService` | `aprs_service.dart` | Core singleton — enable/disable, send/receive, conversations |
| `AprsIsClient` | `aprs_is_client.dart` | TCP connection to APRS-IS servers |
| `AprsPacket` | `models/aprs_packet.dart` | Data model for all packet types |
| `AprsConversation` | `models/aprs_conversation.dart` | Conversation grouping model |
| `AprsCacheService` | `aprs_cache_service.dart` | SQLite persistence via ProfileStorage |
| `BlueAprsService` | `blue_aprs_service.dart` | BLE ↔ APRS-IS bridge |

## APRS-IS Connection

### Login & Authentication

Geogram connects to `rotate.aprs2.net:10152` using the standard APRS-IS passcode algorithm. The passcode is computed from the base callsign (without SSID) using the XOR-hash algorithm defined in the APRS protocol.

```
user MYCALL-5 pass 12345 vers Geogram 1.28 filter r/38.72/-9.14/100 g/MYCALL-5
```

### Filter String

The APRS-IS filter controls which packets the server forwards:

- `r/LAT/LON/RADIUS` — Position packets within radius (km)
- `g/MYCALL` — Messages addressed to our callsign

The filter is updated when:
- GPS position changes by >5 km
- 10 minutes have elapsed since last update
- User manually changes location or radius

### Reconnection

`AprsIsClient` handles automatic reconnection with exponential backoff (5s → 10s → 20s → ... → 300s max). The connection state is reported via `AprsEvent.connected` / `AprsEvent.disconnected`.

### Passcode Computation

```dart
// Standard APRS-IS XOR-hash passcode
static int aprsPasscode(String callsign) {
  final base = callsign.split('-').first.toUpperCase();
  int hash = 0x73e2;
  for (int i = 0; i < base.length; i += 2) {
    hash ^= base.codeUnitAt(i) << 8;
    if (i + 1 < base.length) hash ^= base.codeUnitAt(i + 1);
  }
  return hash & 0x7FFF;
}
```

## Message Types

### AprsPacketType Enum

| Type | Description |
|------|-------------|
| `position` | Position report with lat/lon (may include comment) |
| `message` | Directed message to a callsign or bulletin |
| `status` | Status report |
| `weather` | Weather data |
| `telemetry` | Telemetry data |
| `other` | Unclassified packets |

### Sending Messages

**Direct messages** are addressed to a specific callsign with an auto-incrementing sequence number for ACK tracking:

```
MYCALL>APRS::N0CALL   :Hello from Geogram{42
```

Long messages are automatically split at word boundaries using `splitAprsText()` (max 67 chars per packet).

**Tag/group messages** are sent as bulletins with the tag prefix:

```
MYCALL>APRS::BLN9     :#cq Good morning everyone!
```

### Receiving & ACK

When a message addressed to our callsign arrives with a message ID, the service auto-sends an ACK:

```
MYCALL>APRS::SENDER   :ack42
```

Incoming ACKs update the corresponding outgoing message's `isAcked` flag.

### Message Size Limits

| Constant | Value | Usage |
|----------|-------|-------|
| `aprsMaxMessageLen` | 67 | Max chars in a directed message body |
| `aprsMaxCommentLen` | 107 | Max chars in a position report comment |

## Conversations

Messages are grouped into conversations of two types:

### Direct Conversations

1:1 message exchanges between our callsign and another station. Keyed by the other party's callsign.

### Tag Conversations

Group messages matching subscribed hashtags. Default subscription: `#cq`. Users can add/remove tags via the UI or debug API.

### Conversation List

`AprsService.getConversations()` returns a sorted list of `AprsConversation` objects, most recent first. Each conversation includes:
- `id` — Callsign or `#tag`
- `type` — `direct` or `tag`
- `lastMessage` — Most recent packet
- `messageCount` — Total messages
- `partnerPosition` — Last known position (direct only)

### Message Merging

Consecutive messages from the same sender within 30 seconds are merged for display using `mergeConsecutiveMessages()`. This handles multi-part APRS messages that were split due to the 67-char limit.

## Geo-Chat

Geo-chat uses APRS position reports with human-authored comments. These are distinct from automated beacons (which are filtered out by `isBeaconComment`).

### Sending

```dart
AprsService().sendGeoChat('Hello from Lisbon!');
// Sends: MYCALL>APRS,TCPIP*:!3843.34N/00908.36W$Hello from Lisbon!
```

The position is taken from `savedLatitude`/`savedLongitude`. The `$` symbol table character indicates "other" (generic position).

### Beacon Filtering

The `isBeaconComment` getter on `AprsPacket` filters out automated position comments by detecting:
- Altitude reports (`/A=000377`)
- Course/speed data (`124/000`)
- Infrastructure keywords (igate, digi, repeater, tracker)
- Frequency mentions (`438.500 MHz`)
- Battery/telemetry data
- Software version strings

Only human-authored comments appear in the geo-chat panel.

### Map Display

Geo-chat messages are displayed as floating bubbles on the map via `AprsGeoChatPanel`, showing sender callsign, comment text, and distance from the user.

## BlueAPRS (APRS over BLE)

BlueAPRS adds a Bluetooth Low Energy transport layer, enabling nearby BLE devices to send and receive APRS-compatible messages through Geogram. The station acts as both an **iGate** (BLE ↔ APRS-IS) and a **repeater** (BLE ↔ BLE).

### Architecture

```
BLE Client A  ──┐                              ┌── APRS-IS
BLE Client B  ──┤── BLEMessageService ── BlueAprsService ── AprsService ──┤── (internet)
BLE Client C  ──┘    (channel: _aprs)      (bridge)        (existing)     └── APRS UI
```

### Protocol

BlueAPRS reuses the existing BLE chat protocol with:
- **System channel**: `_aprs` (not shown in regular chat)
- **Capability flag**: `aprs` (advertised in BLE HELLO handshake)
- **Payload**: `BLEAprsPayload` JSON inside `BLEChatPayload.content`

No changes to `BLEMessageType` enum — fully backward-compatible.

### BLEAprsPayload

```json
{
  "to": "N0CALL",
  "text": "Hello via BLE",
  "type": "message",
  "lat": 38.72,
  "lon": -9.14,
  "from": "BLE1-5",
  "msgId": "42"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `to` | String? | Destination callsign or `#tag` |
| `text` | String | Message body |
| `type` | String | `message`, `geochat`, or `position` |
| `lat`, `lon` | double? | Optional position |
| `comment` | String? | Position comment |
| `from` | String? | Source callsign (RX path only) |
| `msgId` | String? | APRS message ID (for ACK tracking) |

### iGate TX (BLE → APRS-IS)

1. BlueAprsService listens to `BLEMessageService.incomingChats` filtered for `_aprs` channel
2. Parses `BLEAprsPayload` from content JSON
3. Validates APRS size limits
4. Routes to `AprsService.sendMessage()` or `.sendGeoChat()`
5. Messages appear in APRS UI automatically

### iGate RX (APRS-IS → BLE)

1. Listens to `AprsService.events` for `messageReceived`
2. Checks if any message is addressed to a connected BLE client's callsign
3. Constructs `_aprs` channel payload and sends via `BLEMessageService.sendChatToClient()`
4. Dedup via `_pushedPacketHashes` set

### BLE → BLE Repeater

When a BLE client sends an APRS message, it is forwarded to all other connected BLE clients that have the `aprs` capability. This enables mesh-like APRS communication between BLE devices.

### Rate Limiting

1 message per 30 seconds per BLE device (APRS etiquette). Simulated test clients are exempt from rate limiting.

### Position Beacon

BlueAPRS can periodically broadcast the station's position to nearby BLE devices. This allows BLE-only clients to discover the iGate and see its location.

**Configuration** (via APRS Settings UI or debug API):
- **Enable**: Toggle on/off independently from BlueAPRS bridge
- **Interval**: 1, 2, 5 (default), 10, or 15 minutes

The beacon sends a `BLEAprsPayload` with `type: "position"` containing the station's lat/lon and callsign on the `_aprs` channel.

```json
{
  "type": "position",
  "from": "MYCALL-5",
  "text": "",
  "lat": 38.72,
  "lon": -9.14,
  "comment": "BlueAPRS beacon"
}
```

### Lifecycle

BlueAPRS is controlled independently from APRS via the BlueAPRS enable toggle in APRS Settings:
- `AprsService.enable()` → if BlueAPRS is enabled and BLE is initialized, calls `BlueAprsService.activate()`
- `DevicesService` BLE init → if APRS and BlueAPRS are enabled, calls `BlueAprsService.activate()`
- `AprsService.disable()` → calls `BlueAprsService.deactivate()`
- BlueAPRS can be toggled on/off without restarting APRS

## Caching & Persistence

`AprsCacheService` provides SQLite-backed persistence via `ProfileStorage`:

- Packets are batched (queue flushes every 2 seconds or at 100 packets)
- On enable, cached packets are loaded and filtered by current position + radius
- Cache survives app restarts; display lists are rebuilt from cache

### Position Cache

`lastKnownPositions` tracks the most recent coordinates per callsign. This allows message packets (which don't carry coordinates) to be placed on the map using the sender's last known position.

## GPS Integration

`AprsService` registers as a consumer of `LocationProviderService` with a 120-second interval. GPS updates trigger APRS-IS filter updates when:
- Position has moved >5 km since last filter update
- 10 minutes have elapsed

The user can also set a manual position via `setLocation()` or the debug API.

## UI Components

### Pages

| Page | File | Description |
|------|------|-------------|
| `AprsMainPage` | `pages/aprs_main_page.dart` | Tab view: Stream, Messages, Geo-Chat |
| `AprsConversationPage` | `pages/aprs_conversation_page.dart` | Individual conversation view |
| `AprsSettingsPage` | `pages/aprs_settings_page.dart` | Location, radius, callsign settings |

### Widgets

| Widget | File | Description |
|--------|------|-------------|
| `AprsConversationList` | `widgets/aprs_conversation_list.dart` | Conversation list with unread badges |
| `AprsMessageBubble` | `widgets/aprs_message_bubble.dart` | Message display with ACK indicator |
| `AprsGeoChatPanel` | `widgets/aprs_geo_chat_panel.dart` | Floating map overlay for geo-chat |

### UI Event Throttling

Packet events are throttled to 500ms intervals to prevent UI freezes from high-volume APRS-IS streams. Dirty flags (`_uiDirtyStream`, `_uiDirtyMessages`) are set on packet arrival and batched into `AprsEvent` emissions.

## Debug API

All APRS debug actions are sent via `POST /api/debug` with JSON body.

### Core APRS Actions

| Action | Description |
|--------|-------------|
| `aprs_status` | Current state: enabled, connected, radius, position, recent packets |
| `aprs_enable` | Enable APRS (requires location set first) |
| `aprs_disable` | Disable APRS |
| `aprs_set_location` | Set position: `{"lat": 38.72, "lon": -9.14}` |
| `aprs_set_radius` | Set radius: `{"radiusKm": 100}` |
| `aprs_send` | Send message: `{"destination": "N0CALL", "text": "Hello"}` |
| `aprs_send_oneshot` | Send via one-shot connection (no persistent connection) |
| `aprs_geochat` | List geo-chat messages |
| `aprs_send_geochat` | Send geo-chat: `{"text": "Hello from here"}` |
| `aprs_conversations` | List all conversations |
| `aprs_tags` | Manage tag subscriptions: `{"op": "add", "tag": "#wx"}` |
| `aprs_cache_inspect` | Inspect SQLite cache stats |
| `aprs_cache_clear` | Clear the packet cache |
| `aprs_logs` | Recent APRS-related log entries |

### BlueAPRS Debug Actions

| Action | Description |
|--------|-------------|
| `blue_aprs_status` | Bridge state, connected BLE clients, TX/RX/repeat stats, beacon status |
| `blue_aprs_enable` | Enable/disable BlueAPRS: `{"enabled": true}` |
| `blue_aprs_beacon` | Control beacon: `{"enabled": true, "intervalSec": 300}` |
| `blue_aprs_register_client` | Register simulated BLE client: `{"deviceId": "sim-1", "callsign": "BLE1-5"}` |
| `blue_aprs_inject_ble` | Simulate BLE client sending APRS message (iGate TX test) |
| `blue_aprs_inject_aprs` | Simulate APRS-IS packet for BLE client (iGate RX test) |
| `blue_aprs_client_inbox` | Check simulated BLE client's received messages |

### Automated Testing

```bash
# Run the full BlueAPRS test suite
dart run tests/blue_aprs_test.dart

# Run the APRS-IS connection test
dart run tests/aprs_is_test.dart CALLSIGN --seconds 30
```

## Configuration

APRS configuration is persisted via `AprsCacheService.saveConfig()`:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | bool | false | Auto-start on next launch |
| `callsign` | String | - | Station callsign with SSID |
| `radiusKm` | double | 100 | Receive radius (1–1000 km) |
| `latitude` | double | - | Saved position latitude |
| `longitude` | double | - | Saved position longitude |
| `subscribedTags` | List | `['#cq']` | Subscribed hashtag channels |
| `blueAprsEnabled` | bool | false | Enable BlueAPRS BLE bridge |
| `blueAprsBeaconEnabled` | bool | false | Enable position beacon |
| `blueAprsBeaconIntervalSec` | int | 300 | Beacon interval in seconds |

## File Reference

| File | Purpose |
|------|---------|
| `lib/teleport/aprs/aprs_service.dart` | Core singleton service |
| `lib/teleport/aprs/aprs_is_client.dart` | APRS-IS TCP client |
| `lib/teleport/aprs/aprs_cache_service.dart` | SQLite persistence |
| `lib/teleport/aprs/aprs_message_utils.dart` | Text splitting, size constants |
| `lib/teleport/aprs/blue_aprs_service.dart` | BLE ↔ APRS bridge |
| `lib/teleport/aprs/models/aprs_packet.dart` | Packet data model |
| `lib/teleport/aprs/models/aprs_conversation.dart` | Conversation model |
| `lib/teleport/aprs/pages/aprs_main_page.dart` | Main UI (3-tab layout) |
| `lib/teleport/aprs/pages/aprs_conversation_page.dart` | Conversation view |
| `lib/teleport/aprs/pages/aprs_settings_page.dart` | Settings page |
| `lib/teleport/aprs/widgets/aprs_conversation_list.dart` | Conversation list widget |
| `lib/teleport/aprs/widgets/aprs_message_bubble.dart` | Message bubble widget |
| `lib/teleport/aprs/widgets/aprs_geo_chat_panel.dart` | Map geo-chat panel |
| `lib/models/ble_message.dart` | `BLEAprsPayload` model |
| `lib/services/ble_message_service.dart` | BLE `aprs` capability |
| `tests/aprs_is_test.dart` | APRS-IS connection test |
| `tests/blue_aprs_test.dart` | BlueAPRS integration test |
| `docs/bridges/APRS-bulletins.md` | Bulletin protocol research |
