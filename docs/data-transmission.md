# Data Transmission Architecture

This document explains how Geogram handles device-to-device data transmission through the ConnectionManager and its various transport mechanisms.

---

## Table of Contents

- [Overview](#overview)
- [ConnectionManager](#connectionmanager)
- [Transport Layer](#transport-layer)
- [Transport Types](#transport-types)
  - [LAN Transport](#lan-transport)
  - [WebRTC Transport](#webrtc-transport)
  - [Station Transport](#station-transport)
  - [Bluetooth Classic Transport (BLE+)](#bluetooth-classic-transport-ble)
  - [BLE Transport](#ble-transport)
- [Priority-Based Routing](#priority-based-routing)
- [Message Flow](#message-flow)
- [Fallback Mechanism](#fallback-mechanism)
- [Adding New Transports](#adding-new-transports)
- [Configuration](#configuration)
- [Testing](#testing)

---

## Overview

Geogram uses a **transport-agnostic** approach to device-to-device communication. Instead of applications directly managing network connections, all communication flows through the **ConnectionManager**, which automatically selects the best transport based on availability and priority.

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          APPLICATION LAYER                               │
│                                                                          │
│   DirectMessageService    DevicesService    ChatService    FileSync     │
│           │                    │                │             │          │
│           └────────────────────┴────────────────┴─────────────┘          │
│                                    │                                     │
│                                    ▼                                     │
│                         ┌──────────────────┐                             │
│                         │ ConnectionManager │                            │
│                         │    (Singleton)    │                            │
│                         └────────┬─────────┘                             │
│                                  │                                       │
├──────────────────────────────────┼───────────────────────────────────────┤
│                          TRANSPORT LAYER                                 │
│                                  │                                       │
│      ┌───────────┬───────────────┼───────────────┬───────────┐          │
│      ▼           ▼               ▼               ▼           ▼          │
│  ┌───────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌───────┐  ┌───────┐│
│  │  LAN  │  │ WebRTC  │  │ Station │  │  BLE+   │  │  BLE  │  │Future ││
│  │  (10) │  │  (15)   │  │  (30)   │  │  (35)   │  │  (40) │  │ LoRa  ││
│  └───┬───┘  └────┬────┘  └────┬────┘  └────┬────┘  └───┬───┘  └───────┘│
│      │           │              │              │                        │
├──────┼───────────┼──────────────┼──────────────┼────────────────────────┤
│      │           │              │              │                        │
│      ▼           ▼              ▼              ▼         NETWORK LAYER  │
│   Direct      Peer-to-       Station        Bluetooth                   │
│    HTTP       Peer via       WebSocket        Radio                     │
│             NAT Traversal     Relay                                     │
└─────────────────────────────────────────────────────────────────────────┘
```

**Key Benefits:**
- Apps don't need to know which transport is used
- Automatic fallback when one transport fails
- Easy to add new transports (LoRa, mesh, radio)
- Consistent API regardless of underlying connection

---

## ConnectionManager

The `ConnectionManager` is a singleton that manages all device-to-device communication.

### Location
```
lib/connection/connection_manager.dart
```

### Core Responsibilities
1. **Transport Registration** - Maintains list of available transports
2. **Priority Routing** - Tries transports in priority order
3. **Message Queueing** - Optional store-and-forward for offline devices
4. **Metrics Tracking** - Latency, success rate per transport

### API

```dart
// Get the singleton
final cm = ConnectionManager();

// Register transports (done at startup in main.dart)
cm.registerTransport(LanTransport());
cm.registerTransport(WebRTCTransport());
cm.registerTransport(StationTransport());
cm.registerTransport(BleTransport());

// Initialize all transports
await cm.initialize();

// Make an API request (transport selected automatically)
final result = await cm.apiRequest(
  callsign: 'X1ABCD',
  method: 'GET',
  path: '/api/status',
);

// Send a direct message
final result = await cm.sendDM(
  callsign: 'X1ABCD',
  signedEvent: nostrEvent.toJson(),
);

// Check if device is reachable
final reachable = await cm.isReachable('X1ABCD');

// Get available transports for a device
final transports = await cm.getAvailableTransports('X1ABCD');
```

### TransportResult

All send operations return a `TransportResult`:

```dart
class TransportResult {
  final bool success;        // Whether send succeeded
  final String? error;       // Error message if failed
  final int? statusCode;     // HTTP status code (for API requests)
  final dynamic responseData; // Response body
  final String? transportUsed; // 'lan', 'webrtc', 'station', 'ble'
  final Duration? latency;   // Round-trip time
}
```

---

## Transport Layer

### Transport Interface

All transports implement the `Transport` abstract class:

```dart
abstract class Transport {
  String get id;           // 'lan', 'webrtc', 'station', 'ble'
  String get name;         // 'Local Network', 'Peer-to-Peer', etc.
  int get priority;        // Lower = preferred (10, 15, 30, 40)
  bool get isAvailable;    // Platform availability

  Future<bool> canReach(String callsign);
  Future<TransportResult> send(TransportMessage message);
  Stream<TransportMessage> get incomingMessages;

  Future<void> initialize();
  Future<void> dispose();
}
```

### Location
```
lib/connection/transport.dart
lib/connection/transport_message.dart
lib/connection/transports/
  ├── lan_transport.dart
  ├── webrtc_transport.dart
  ├── station_transport.dart
  └── ble_transport.dart
```

---

## Transport Types

### LAN Transport

**Priority: 10 (Highest)**

Direct HTTP communication on the local network. Fastest option when both devices are on the same WiFi/LAN.

```
┌─────────────────┐         Direct HTTP        ┌─────────────────┐
│    Device A     │◄──────────────────────────►│    Device B     │
│  192.168.1.10   │       Same Network         │  192.168.1.20   │
└─────────────────┘                            └─────────────────┘
```

**How it works:**
1. Devices register their local IP addresses with ConnectionManager
2. When sending, checks if target has a known local URL
3. Makes direct HTTP request to device's local API

**Capabilities:**
- ✅ API requests (GET, POST, PUT, DELETE)
- ✅ Direct messages
- ✅ File transfers
- ✅ Real-time sync

**Limitations:**
- Only works on same local network
- Requires devices to discover each other's IPs
- Firewalls may block connections

**Configuration:**
```dart
LanTransport(
  timeout: Duration(seconds: 10),
)
```

---

### WebRTC Transport

**Priority: 15**

Peer-to-peer communication via WebRTC NAT traversal. Enables direct connections between devices on different networks without routing data through a server.

```
┌─────────────────┐                              ┌─────────────────┐
│    Device A     │                              │    Device B     │
│  Behind NAT     │                              │  Behind NAT     │
└────────┬────────┘                              └────────┬────────┘
         │                                                │
         │  1. Signaling (via Station)                    │
         │◄──────────────────────────────────────────────►│
         │     Offer/Answer/ICE Candidates                │
         │                                                │
         │  2. Direct P2P Data Channel                    │
         │◄══════════════════════════════════════════════►│
         │     (NAT Hole Punched)                         │
         │                                                │
```

**How it works:**
1. **Signaling**: Device A sends WebRTC offer to Device B via station
2. **ICE Gathering**: Both devices gather ICE candidates (local, STUN-discovered)
3. **NAT Traversal**: ICE candidates are exchanged via station
4. **Connection**: Direct P2P data channel established
5. **Data Transfer**: All data flows directly, bypassing station

**Signaling Flow:**
```
Device A                    Station                    Device B
    │                          │                          │
    │── webrtc_offer ─────────►│                          │
    │                          │── webrtc_offer ─────────►│
    │                          │                          │
    │                          │◄── webrtc_answer ────────│
    │◄── webrtc_answer ────────│                          │
    │                          │                          │
    │◄──────────── ICE Candidates Exchange ──────────────►│
    │                          │                          │
    │◄═══════════ Direct P2P Data Channel ═══════════════►│
```

**Capabilities:**
- ✅ All data types (DMs, API calls, files, sync)
- ✅ Works across NAT/firewalls (most types)
- ✅ Low latency once connected
- ✅ No bandwidth cost on station server

**Limitations:**
- Requires initial signaling through station
- May fail with symmetric NAT (falls back to Station)
- Connection setup takes a few seconds

**STUN Servers (for NAT discovery):**
```dart
// Default STUN servers (free, public)
- stun:stun.l.google.com:19302
- stun:stun1.l.google.com:19302
- stun:global.stun.twilio.com:3478
- stun:stun.services.mozilla.com:3478
```

**Configuration:**
```dart
// In lib/services/webrtc_config.dart
WebRTCConfig(
  iceGatheringTimeoutMs: 5000,    // 5 seconds
  connectionTimeoutMs: 15000,     // 15 seconds
  dataChannelOrdered: true,       // Reliable delivery
)
```

**Connection States:**
```
IDLE → OFFERING → CONNECTING → CONNECTED → READY
                      │
                   FAILED → Fallback to Station Transport
```

---

### Station Transport

**Priority: 30**

Internet relay through the station server (default: p2p.radio). Used when direct connections aren't possible.

```
┌─────────────────┐                              ┌─────────────────┐
│    Device A     │                              │    Device B     │
│  Any Network    │                              │  Any Network    │
└────────┬────────┘                              └────────┬────────┘
         │                                                │
         │      ┌─────────────────────┐                   │
         │      │      Station        │                   │
         └─────►│    p2p.radio        │◄──────────────────┘
                │                     │
                │  HTTP Proxy +       │
                │  WebSocket Relay    │
                └─────────────────────┘
```

**How it works:**
1. **HTTP Proxy**: `POST https://p2p.radio/{callsign}/api/dm/send`
   - Station finds target's WebSocket connection
   - Forwards request via WebSocket
   - Returns response back to caller

2. **WebSocket Relay**: NOSTR-signed events
   - Device sends EVENT via WebSocket
   - Station relays to target device
   - Used for DMs, chat, real-time sync

**Capabilities:**
- ✅ Works globally (any internet connection)
- ✅ Reliable delivery
- ✅ Store-and-forward (coming soon)
- ✅ Fallback when P2P fails

**Limitations:**
- Higher latency than direct connections
- Bandwidth costs on station server
- Requires internet connectivity

**Configuration:**
```dart
StationTransport(
  timeout: Duration(seconds: 30),
)
```

---

### Bluetooth Classic Transport (BLE+)

**Priority: 35**

Bluetooth Classic (SPP/RFCOMM) for faster offline data transfers. When a device has both BLE and Bluetooth Classic paired, it's labeled "BLE+" in the UI. BLE is used for discovery (no pairing needed), while Bluetooth Classic is used for high-speed bulk data transfers.

```
┌─────────────────┐     Bluetooth Classic     ┌─────────────────┐
│    Desktop      │◄═══════════════════════════►│    Android      │
│  RFCOMM Client  │      SPP (~2-3 Mbps)        │   SPP Server    │
│ (Linux/macOS)   │                             │                 │
└─────────────────┘                             └─────────────────┘
```

**How it works:**
1. **Discovery**: Device is first discovered via BLE (no pairing needed)
2. **Upgrade**: User clicks "Upgrade to BLE+" in device menu
3. **Pairing**: System Bluetooth pairing dialog appears (PIN confirmation)
4. **Storage**: Pairing info stored locally (callsign → classic_mac mapping)
5. **Routing**: Large transfers (>10KB) automatically use Bluetooth Classic

**Architecture:**

```
┌───────────────────────────────────────────────────────────────────────┐
│                        BLE+ Flow                                       │
├───────────────────────────────────────────────────────────────────────┤
│                                                                        │
│   1. BLE Discovery (no pairing)                                        │
│      └─► Device appears with "BLE" label                               │
│                                                                        │
│   2. User initiates "Upgrade to BLE+"                                  │
│      └─► System pairing dialog (PIN confirmation on both devices)      │
│                                                                        │
│   3. After pairing                                                     │
│      └─► Device label changes to "BLE+"                                │
│      └─► classic_mac stored in BluetoothClassicPairingService          │
│                                                                        │
│   4. Data transfer routing                                             │
│      ├─► Small data (<10KB): Uses BLE transport                        │
│      └─► Large data (≥10KB): Uses Bluetooth Classic transport          │
│                                                                        │
│   5. Batch operations (TransferSession)                                │
│      └─► Apps declare expected total bytes                             │
│      └─► Connection kept open for duration                             │
│                                                                        │
└───────────────────────────────────────────────────────────────────────┘
```

**Platform Support:**

| Platform | BLE Client | BLE Server | BT Classic Client | BT Classic Server |
|----------|------------|------------|-------------------|-------------------|
| Android  | ✅ Yes     | ✅ Yes     | ✅ Yes            | ✅ Yes (SPP)      |
| Linux    | ✅ Yes     | ❌ No      | ✅ Yes (BlueZ)    | ❌ No             |
| macOS    | ✅ Yes     | ❌ No      | ⏳ Planned        | ❌ No             |
| Windows  | ✅ Yes     | ❌ No      | ⏳ Planned        | ❌ No             |
| iOS      | ✅ Yes     | ✅ Yes     | ❌ Not supported  | ❌ Not supported  |

**Implementation Status:**

| Component | Status | Location |
|-----------|--------|----------|
| Dart Service | ✅ Complete | `lib/services/bluetooth_classic_service.dart` |
| Pairing Service | ✅ Complete | `lib/services/bluetooth_classic_pairing_service.dart` |
| Device Model | ✅ Complete | `lib/models/bluetooth_classic_device.dart` |
| Transport | ✅ Complete | `lib/connection/transports/bluetooth_classic_transport.dart` |
| Transfer Session | ✅ Complete | `lib/connection/transfer_session.dart` |
| Android Native | ✅ Complete | `android/.../BluetoothClassicPlugin.kt` |
| Linux Native | ✅ Complete | `linux/runner/bluetooth_classic_plugin.cc` |
| macOS Native | ⏳ Planned | - |
| Windows Native | ⏳ Planned | - |
| UI Integration | ✅ Complete | `lib/pages/devices_browser_page.dart` |

**Capabilities:**
- ✅ Fast transfers (~2-3 Mbps vs ~0.1-0.5 Mbps for BLE)
- ✅ Works offline (no internet)
- ✅ Automatic size-based routing
- ✅ Batch operation support (TransferSession)

**Limitations:**
- Requires one-time Bluetooth pairing (PIN confirmation)
- iOS does not support Bluetooth Classic SPP
- Desktop platforms can only be clients (not servers)
- Range similar to BLE (~10-100m)

**SPP UUID:**
```
00001101-0000-1000-8000-00805f9b34fb
```

**TransferSession (Batch Operations):**

Apps can declare expected total bytes for multi-request operations:

```dart
// App knows it will sync 50 small files (~100KB total)
final session = await TransferSession.start(
  callsign: 'X1ABCD',
  expectedTotalBytes: 100 * 1024,  // 100KB expected
);

try {
  // Multiple small requests - all use BLE+ since session declared 100KB
  for (final file in files) {
    await connectionManager.send(callsign: 'X1ABCD', data: file.bytes);
  }
} finally {
  await session.end();  // Disconnect BLE+
}
```

**Native Implementation Notes:**

*Android (BluetoothClassicPlugin.kt):*
- SPP server using `BluetoothServerSocket`
- Client connections via `BluetoothSocket`
- Pairing via `BluetoothDevice.createBond()`
- Full send/receive via socket streams

*Linux (bluetooth_classic_plugin.cc):*
- BlueZ DBus integration for device discovery and pairing
- RFCOMM socket client (requires `libbluetooth-dev` for full support)
- Graceful degradation when Bluetooth headers not available

**Configuration:**
```dart
BluetoothClassicTransport(
  sizeThresholdBytes: 10240,  // 10KB threshold for automatic switching
)
```

**HELLO Protocol Extension:**

The BLE HELLO_ACK message includes `classic_mac` when the device supports BLE+:

```json
{
  "callsign": "X1ABCD",
  "capabilities": ["bluetooth_classic:spp", ...],
  "classic_mac": "AA:BB:CC:DD:EE:FF"
}
```

---

### BLE Transport

**Priority: 40 (Lowest)**

Bluetooth Low Energy for offline, short-range communication. Works without any network infrastructure.

```
┌─────────────────┐        Bluetooth        ┌─────────────────┐
│    Device A     │◄───────────────────────►│    Device B     │
│  GATT Client    │      ~10-100m range     │  GATT Server    │
│ (Linux/macOS)   │                         │ (Android/iOS)   │
└─────────────────┘                         └─────────────────┘
```

**How it works:**
1. **Discovery**: Devices advertise their callsign via BLE
2. **Connection**: GATT client connects to GATT server
3. **Communication**: Messages sent via GATT characteristics
4. **Parceling**: Large messages split into 280-byte parcels

**Android-Android Peer Discovery:**

Since both Android devices can act as GATT servers simultaneously, peer discovery requires active scanning. Geogram implements automatic periodic background scanning:

1. **Advertising**: Each device advertises every 30 seconds (existing behavior)
2. **Scanning**: Each device scans for 8 seconds every 45 seconds (new behavior)
3. **Discovery Window**: Devices typically discover each other within 45 seconds of coming into range
4. **Stale Cleanup**: Devices not seen for 90 seconds are removed from discovered list

**Battery Impact:**
- Scanning duty cycle: ~18% (8 seconds per 45 seconds)
- Combined with advertising: ~35-40% total BLE activity
- Comparable to other background services
- Automatically pauses when Bluetooth is disabled

**Capabilities:**
- ✅ Works completely offline
- ✅ No internet required
- ✅ Emergency communications

**Limitations:**
- Short range (~10-100 meters)
- Slow (BLE bandwidth limits)
- Platform restrictions (GATT server only on Android/iOS)
- **Android peer discovery**: Requires up to 45 seconds for first discovery (periodic scan interval)
- **Battery consideration**: Background scanning uses ~18% duty cycle

**Platform Support:**

| Platform | GATT Client | GATT Server | Can Discover | Can Be Discovered |
|----------|-------------|-------------|--------------|-------------------|
| Android  | ✅ Yes      | ✅ Yes      | ✅ Yes       | ✅ Yes            |
| iOS      | ✅ Yes      | ✅ Yes      | ✅ Yes       | ✅ Yes            |
| Linux    | ✅ Yes      | ❌ No       | ✅ Yes       | ❌ No             |
| macOS    | ✅ Yes      | ❌ No       | ✅ Yes       | ❌ No             |
| Windows  | ✅ Yes      | ❌ No       | ✅ Yes       | ❌ No             |

**Note**: On Android-Android communication, automatic peer discovery via periodic background scanning ensures devices find each other without manual intervention. Discovery typically completes within 45 seconds of devices coming into range.

See [BLE.md](BLE.md) for detailed BLE implementation documentation.

---

## Priority-Based Routing

The ConnectionManager uses a **priority-based routing strategy**. When sending a message:

```
┌──────────────────────────────────────────────────────────────────┐
│                     Priority Routing Flow                         │
├──────────────────────────────────────────────────────────────────┤
│                                                                   │
│  1. Sort transports by priority (lower = preferred)               │
│     [LAN:10, WebRTC:15, Station:30, BLE+:35, BLE:40]             │
│                                                                   │
│  2. For each transport:                                           │
│     ├─ Can this transport reach the target? (canReach)            │
│     │   └─ No → Skip to next transport                            │
│     │                                                             │
│     ├─ Yes → Try to send                                          │
│     │   ├─ Success → Return result with transportUsed             │
│     │   └─ Failure → Try next transport                           │
│     │                                                             │
│  3. All transports failed → Return failure                        │
│                                                                   │
└──────────────────────────────────────────────────────────────────┘
```

### Example Scenario

Device A wants to send a message to Device B:

| Step | Transport | canReach? | Result | Action |
|------|-----------|-----------|--------|--------|
| 1 | LAN (10) | No - different networks | Skip | Try next |
| 2 | WebRTC (15) | Yes - both on station | Try | Connection timeout |
| 3 | Station (30) | Yes - station connected | Try | **Success!** |
| 4 | BLE (40) | Not checked | - | Already succeeded |

**Result:** Message delivered via Station transport.

---

## Message Flow

### API Request Flow

```dart
// Application makes request
final result = await ConnectionManager().apiRequest(
  callsign: 'X1ABCD',
  method: 'GET',
  path: '/api/status',
);
```

```
App                ConnectionManager         LAN        WebRTC       Station
 │                       │                    │            │            │
 │── apiRequest() ──────►│                    │            │            │
 │                       │                    │            │            │
 │                       │── canReach? ──────►│            │            │
 │                       │◄── false ──────────│            │            │
 │                       │                    │            │            │
 │                       │── canReach? ───────────────────►│            │
 │                       │◄── true ───────────────────────│            │
 │                       │                    │            │            │
 │                       │── send() ──────────────────────►│            │
 │                       │                    │            │            │
 │                       │   [WebRTC tries to establish    │            │
 │                       │    P2P connection... timeout]   │            │
 │                       │                    │            │            │
 │                       │◄── failure ────────────────────│            │
 │                       │                    │            │            │
 │                       │── canReach? ─────────────────────────────────►│
 │                       │◄── true ─────────────────────────────────────│
 │                       │                    │            │            │
 │                       │── send() ────────────────────────────────────►│
 │                       │◄── success ──────────────────────────────────│
 │                       │                    │            │            │
 │◄── TransportResult ───│                    │            │            │
 │   (transportUsed:     │                    │            │            │
 │    'station')         │                    │            │            │
```

### Direct Message Flow

```dart
// Send a signed NOSTR direct message
final result = await ConnectionManager().sendDM(
  callsign: 'X1ABCD',
  signedEvent: dmEvent.toJson(),
);
```

The flow is similar, but uses WebSocket relay for Station transport instead of HTTP proxy.

---

## Fallback Mechanism

When a transport fails, the ConnectionManager automatically tries the next one:

```
┌─────────────────────────────────────────────────────────────────┐
│                    Automatic Fallback                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   LAN fails?  ──────► Try WebRTC                                │
│                           │                                     │
│                      WebRTC fails? ──────► Try Station          │
│                                                │                │
│                                           Station fails?        │
│                                                │                │
│                                                ▼                │
│                                           Try BLE               │
│                                                │                │
│                                           BLE fails?            │
│                                                │                │
│                                                ▼                │
│                                      Return failure             │
│                                      (all transports failed)    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**Failure Reasons by Transport:**

| Transport | Common Failures |
|-----------|-----------------|
| LAN | Different networks, firewall, device offline |
| WebRTC | Symmetric NAT, timeout, ICE failure |
| Station | No internet, station down, device not connected |
| BLE+ | Not paired, out of range, unsupported platform (iOS) |
| BLE | Out of range, BLE disabled, platform limitation |

---

## Adding New Transports

To add a new transport (e.g., LoRa radio):

### 1. Create Transport Class

```dart
// lib/connection/transports/lora_transport.dart
class LoRaTransport extends Transport with TransportMixin {
  @override String get id => 'lora';
  @override String get name => 'LoRa Radio';
  @override int get priority => 35; // Between Station (30) and BLE (40)
  @override bool get isAvailable => _hasLoRaHardware();

  @override
  Future<bool> canReach(String callsign) async {
    // Check if device is within LoRa range
    return _loRaDevices.contains(callsign);
  }

  @override
  Future<TransportResult> send(TransportMessage message) async {
    // Send via LoRa radio
    await _loRaRadio.send(message.targetCallsign, message.toJson());
    return TransportResult.success(transportUsed: id);
  }

  @override
  Future<void> sendAsync(TransportMessage message) async {
    // Fire and forget
    _loRaRadio.sendAsync(message.targetCallsign, message.toJson());
  }
}
```

### 2. Register in main.dart

```dart
// lib/main.dart
final connectionManager = ConnectionManager();
connectionManager.registerTransport(LanTransport());
connectionManager.registerTransport(WebRTCTransport());
connectionManager.registerTransport(StationTransport());
connectionManager.registerTransport(LoRaTransport());  // New!
connectionManager.registerTransport(BleTransport());
await connectionManager.initialize();
```

### 3. Priority Guidelines

| Priority Range | Description |
|----------------|-------------|
| 1-10 | Direct, high-speed (LAN, USB) |
| 11-20 | P2P internet (WebRTC) |
| 21-30 | Relayed internet (Station) |
| 31-40 | Offline (LoRa, Radio, Mesh) |
| 41-50 | Last resort (BLE, manual) |

---

## Configuration

### Transport Registration (main.dart)

```dart
// Transport priority: LAN (10) > WebRTC (15) > Station (30) > BLE+ (35) > BLE (40)
final connectionManager = ConnectionManager();
connectionManager.registerTransport(LanTransport());
connectionManager.registerTransport(WebRTCTransport());
connectionManager.registerTransport(StationTransport());
connectionManager.registerTransport(BluetoothClassicTransport());
connectionManager.registerTransport(BleTransport());
await connectionManager.initialize();
```

### WebRTC Configuration

```dart
// lib/services/webrtc_config.dart
WebRTCConfig(
  // STUN/TURN servers
  iceServers: [
    {'urls': 'stun:stun.l.google.com:19302'},
    {'urls': 'stun:global.stun.twilio.com:3478'},
  ],

  // Timeouts
  iceGatheringTimeoutMs: 5000,   // 5 seconds
  connectionTimeoutMs: 15000,    // 15 seconds
  offerTimeoutMs: 10000,         // 10 seconds

  // Data channel
  dataChannelOrdered: true,
  dataChannelLabel: 'geogram',
)
```

### Station Configuration

```dart
// Default station URL
--station=wss://p2p.radio/ws
```

---

## Testing

### Run WebRTC Tests

```bash
cd /home/brito/code/geograms/geogram-desktop

# Full automated test (starts station + 2 instances)
./tests/run_webrtc_test.sh

# Manual Dart tests (after starting instances)
dart tests/webrtc_test.dart --port-a=5577 --port-b=5588 --station-port=8765
```

### What the Tests Verify

1. **Station connectivity** - Station is running and accessible
2. **Instance status** - Both test instances are running
3. **Station clients** - Both instances connected to station
4. **Transport availability** - WebRTC transport is registered
5. **Message delivery** - Messages can be sent between instances
6. **Signaling** - WebRTC signaling messages are relayed
7. **Log analysis** - WebRTC activity appears in logs

### Testing Across Networks

For full NAT traversal testing, run instances on different networks:

```bash
# On Network A
./geogram_desktop --port=5577 --station=wss://p2p.radio/ws

# On Network B (different location)
./geogram_desktop --port=5577 --station=wss://p2p.radio/ws

# Then test messaging between the two
```

---

## File Reference

| File | Description |
|------|-------------|
| `lib/connection/connection_manager.dart` | Main ConnectionManager singleton |
| `lib/connection/transport.dart` | Abstract Transport interface |
| `lib/connection/transport_message.dart` | TransportMessage and TransportResult classes |
| `lib/connection/routing_strategy.dart` | Priority and quality routing strategies |
| `lib/connection/transports/lan_transport.dart` | LAN (priority 10) |
| `lib/connection/transports/webrtc_transport.dart` | WebRTC (priority 15) |
| `lib/connection/transports/station_transport.dart` | Station (priority 30) |
| `lib/connection/transports/bluetooth_classic_transport.dart` | BLE+ / Bluetooth Classic (priority 35) |
| `lib/connection/transports/ble_transport.dart` | BLE (priority 40) |
| `lib/connection/transfer_session.dart` | TransferSession for batch operations |
| `lib/services/bluetooth_classic_service.dart` | Bluetooth Classic service (method channel) |
| `lib/services/bluetooth_classic_pairing_service.dart` | BLE+ pairing storage and management |
| `lib/models/bluetooth_classic_device.dart` | Paired device model |
| `android/.../BluetoothClassicPlugin.kt` | Android SPP server/client native code |
| `linux/runner/bluetooth_classic_plugin.cc` | Linux BlueZ RFCOMM client native code |
| `lib/services/webrtc_config.dart` | WebRTC STUN/TURN configuration |
| `lib/services/webrtc_signaling_service.dart` | WebRTC signaling via WebSocket |
| `lib/services/webrtc_peer_manager.dart` | WebRTC peer connection management |
| `tests/run_webrtc_test.sh` | Automated WebRTC test runner |
| `tests/webrtc_test.dart` | WebRTC Dart test suite |
