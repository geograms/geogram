# Bluetooth Low Energy (BLE) Implementation

This document covers BLE architecture, lessons learned, and the reliable transmission protocol.

---

## Part 1: Understanding GATT (Why It Matters)

### What is GATT?

**GATT** (Generic Attribute Profile) defines how BLE devices exchange data. It uses a client-server model:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         GATT EXPLAINED                                  │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  GATT SERVER (Peripheral)              GATT CLIENT (Central)            │
│  ┌─────────────────────┐               ┌─────────────────────┐          │
│  │ • Hosts data        │               │ • Initiates scans   │          │
│  │ • Advertises        │◄─────────────►│ • Connects          │          │
│  │ • Waits for         │   BLE Radio   │ • Reads/writes data │          │
│  │   connections       │               │ • Subscribes to     │          │
│  │ • Responds to       │               │   notifications     │          │
│  │   requests          │               │                     │          │
│  └─────────────────────┘               └─────────────────────┘          │
│                                                                         │
│  Think of it like:                                                      │
│  • Server = Restaurant (has the menu, waits for orders)                 │
│  • Client = Customer (browses menu, places orders, receives food)       │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### Why This Matters for Geogram

**The Problem:** Linux/macOS/Windows can ONLY be GATT clients. They cannot advertise or host services.

**The Solution:** Android/iOS devices run GATT servers that desktop devices connect to.

```
Linux/macOS/Windows (GATT Client)        Android/iOS (GATT Server)
┌─────────────────────────┐              ┌─────────────────────────┐
│   flutter_blue_plus     │              │    ble_peripheral       │
│                         │              │                         │
│  1. Scan for devices ──►│──BLE SCAN───►│  Advertising identity   │
│                         │              │                         │
│  2. Connect ───────────►│──CONNECT────►│  Accept connection      │
│                         │              │                         │
│  3. Write to 0xFFF1 ───►│──REQUEST────►│  Receive on 0xFFF1      │
│                         │              │                         │
│  4. Subscribe 0xFFF2    │◄──RESPONSE───│  Notify on 0xFFF2       │
└─────────────────────────┘              └─────────────────────────┘
```

### Platform Capabilities

| Platform | GATT Client | GATT Server | Can Discover | Can Be Discovered |
|----------|-------------|-------------|--------------|-------------------|
| Linux    | ✅ Yes      | ❌ No       | ✅ Yes       | ❌ No*            |
| macOS    | ✅ Yes      | ❌ No       | ✅ Yes       | ❌ No*            |
| Windows  | ✅ Yes      | ❌ No       | ✅ Yes       | ❌ No*            |
| Android  | ✅ Yes      | ✅ Yes      | ✅ Yes       | ✅ Yes            |
| iOS      | ✅ Yes      | ✅ Yes      | ✅ Yes       | ✅ Yes            |

*Desktop platforms can only be discovered by devices that already know their MAC address.

### GATT Service Structure

```
Geogram BLE Service
├── Service UUID: 0000FFF0-0000-1000-8000-00805F9B34FB
│
├── Characteristic 0xFFF1 (Write)
│   ├── Properties: WRITE, WRITE_WITHOUT_RESPONSE
│   └── Purpose: Client sends messages to server
│
├── Characteristic 0xFFF2 (Notify)
│   ├── Properties: NOTIFY, READ
│   └── Purpose: Server sends responses/data to client
│
└── Characteristic 0xFFF3 (Read)
    ├── Properties: READ
    └── Purpose: Connection status
```

### Communication Flow

**Desktop → Android (Desktop as Client):**
1. Desktop scans, finds Android advertising
2. Desktop connects to Android
3. Desktop writes message to 0xFFF1
4. Android processes, sends response via 0xFFF2 notification
5. Desktop receives notification

**Android → Desktop (Android as Client):**
1. Android must know Desktop's MAC address (no advertising)
2. Android connects to Desktop's BlueZ GATT server
3. Same write/notify flow

---

## Part 2: Packages Used

### flutter_blue_plus (Client Operations)

Used on ALL platforms for scanning and connecting to peripherals.

```dart
// Scan for Geogram devices
await FlutterBluePlus.startScan(
  withServices: [Guid(serviceUUID)],
  timeout: Duration(seconds: 10),
);

// Connect and discover services
await device.connect();
final services = await device.discoverServices();

// Write to characteristic
await writeChar.write(bytes, withoutResponse: true);

// Subscribe to notifications
await notifyChar.setNotifyValue(true);
notifyChar.onValueReceived.listen((data) { ... });
```

### ble_peripheral (Server Operations)

Used on Android/iOS ONLY for advertising and hosting GATT services.

```dart
// Add GATT service
await BlePeripheral.addService(
  BleService(
    uuid: serviceUUID,
    primary: true,
    characteristics: [
      BleCharacteristic(
        uuid: writeCharUUID,
        properties: [CharacteristicProperties.write],
        permissions: [AttributePermissions.writeable],
      ),
      BleCharacteristic(
        uuid: notifyCharUUID,
        properties: [CharacteristicProperties.notify, CharacteristicProperties.read],
        permissions: [AttributePermissions.readable],
      ),
    ],
  ),
);

// Handle incoming writes
BlePeripheral.setWriteRequestCallback((deviceId, characteristicId, offset, value) {
  final message = utf8.decode(value);
  // Process incoming message
  return WriteRequestResult(
    characteristicId: characteristicId,
    offset: offset,
    status: true,
  );
});

// Send notification to client
await BlePeripheral.updateCharacteristic(
  characteristicId: notifyCharUUID,
  value: utf8.encode(jsonResponse),
  deviceId: targetDeviceId,
);
```

---

## Part 3: Lessons Learned

### Transmission Constraints

**MTU and Chunk Sizing:**
- Linux BLE typically negotiates MTU of 23 bytes (20 bytes usable after ATT header)
- Request higher MTU at connection time: `await device.requestMtu(512)`
- Actual MTU varies by platform/device; always check: `await device.mtu.first`
- Chunk size = MTU - 3 (leave room for ATT header)

**Connection Drops:**
- **Problem**: Sending >300 bytes continuously causes connection drops with ATT error 0x0e
- **Root cause**: BLE stack buffer overflow on some devices
- **Solution**: 280-byte parcels with 500ms pause between parcels

**Timing Requirements:**
```
Within a parcel:  30ms delay between MTU-sized chunks
Between parcels:  500ms pause to let BLE stack recover
```

**Write Mode:**
- Use `withoutResponse: true` for chunked writes (faster, non-blocking)
- Use `withoutResponse: false` only for single small writes (<MTU)

### Android MAC Address Randomization

- Android randomizes BLE MAC address periodically (every ~15 minutes)
- Device identity cannot rely solely on MAC address
- Solution: Advertise callsign + device_id in advertising data
- Track MAC-to-identity mapping, update on change

### Discovery

**Geogram Marker:**
- First byte of advertising data: `0x3E` (ASCII '>')
- Followed by device_id and callsign
- Service UUID: `0000FFF0-0000-1000-8000-00805F9B34FB`

**UUID Matching:**
- Some platforms report short UUID (fff0), others full 128-bit
- Always compare case-insensitive with both formats:
```dart
final matches = uuid.toLowerCase() == 'fff0' ||
    uuid.toLowerCase() == '0000fff0-0000-1000-8000-00805f9b34fb';
```

**Advertisement Size:**
- BLE advertising payload: 20 bytes max
- Format: `[0x3E marker][device_id: 1 byte][callsign: up to 18 bytes]`

### Simultaneous Send/Receive

- Most devices cannot reliably send and receive BLE data simultaneously
- Implement "listen windows" during long transmissions
- Pause sending periodically to check for incoming data

### RSSI and Proximity

```dart
RSSI > -50 dBm  → "Very close" (~0-2m)
RSSI > -70 dBm  → "Nearby" (~2-5m)
RSSI > -85 dBm  → "In range" (~5-15m)
RSSI < -85 dBm  → "Far" (>15m)

// Distance estimation (rough)
distance = 10^((txPower - rssi) / (10 * pathLossExponent))
// pathLossExponent typically 2.0-2.5 for indoor
```

---

## Part 4: Reliable Transmission Protocol

### Overview

A packet-based protocol with:
- Message fragmentation into parcels
- Unique message ID for correlation
- Checksum for data integrity
- Selective retransmission of missing parcels
- Queue management with listen windows
- Automatic missing parcel requests after timeout
- Sent message retention for delayed retransmission requests

### Identity Format

Full device identity = `callsign` + `-` + `device_id`

| Component | Description | Example |
|-----------|-------------|---------|
| callsign | User's ham callsign | X34PSK |
| device_id | Number 1-15 derived from hardware (APRS SSID compatible) | 7 |
| Full identity | Combined | X34PSK-7 |

The device_id is computed from hardware characteristics (e.g., `/etc/machine-id` on Linux) ensuring it remains consistent across app reinstalls on the same device. The 1-15 range is compatible with APRS SSID conventions.

**Advertisement Format (20 bytes max):**
```
[0x3E marker][device_id: 1 byte (1-15)][callsign: up to 18 bytes]
```

### Parcel Format

**Header Parcel (first parcel of message):**
```
Bytes 0-1:   MSG_ID (2 uppercase letters, e.g., "AK")
Bytes 2-3:   TOTAL_PARCELS (uint16, big-endian)
Bytes 4-7:   CHECKSUM (CRC32 of transmitted payload, big-endian)
Byte 8:      FLAGS (compression and future flags)
Bytes 9+:    DATA (up to 271 bytes in header parcel)
```

**FLAGS Byte Encoding:**
```
Bits 0-3: Compression algorithm
  0x0 = None (uncompressed)
  0x1 = DEFLATE (zlib)
  0x2 = Reserved (Zstandard)
  0x3 = Reserved (LZ4)
  0x4-0xF = Reserved for future algorithms

Bits 4-7: Reserved for future flags
```

**Data Parcel (subsequent parcels):**
```
Bytes 0-1:   MSG_ID (same as header)
Bytes 2-3:   PARCEL_NUM (uint16, 1-indexed, big-endian)
Bytes 4+:    DATA (up to 276 bytes)
```

**Size Calculations:**
- Parcel size: 280 bytes max (proven stable)
- Header overhead: 9 bytes (MSG_ID(2) + TOTAL(2) + CRC32(4) + FLAGS(1))
- Header parcel data: 280 - 9 = 271 bytes
- Data parcel data: 280 - 4 = 276 bytes

### Message ID Generation

```dart
String generateMessageId() {
  final random = Random();
  final chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  return String.fromCharCodes([
    chars.codeUnitAt(random.nextInt(26)),
    chars.codeUnitAt(random.nextInt(26)),
  ]);
}
```

### Checksum

CRC32 of the transmitted payload (compressed if compression is used, original otherwise).

```dart
int calculateChecksum(Uint8List transmittedPayload) {
  return calculateCrc32(transmittedPayload);
}
```

### Compression

Optional compression reduces bandwidth for larger payloads while maintaining backward compatibility.

**When Compression Is Applied:**
- Payload size ≥ 300 bytes (threshold)
- Peer advertised compression support in HELLO handshake
- Data doesn't appear to be already compressed (PNG, JPEG, GZIP, etc.)
- Compression actually reduces size (otherwise skipped)

**Compression Flow:**
```
┌─────────────────────────────────────────────────────────────────────────┐
│                    COMPRESSION DECISION FLOW                             │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  Sender:                                                                │
│  1. Check if peer supports compression (from HELLO capability)          │
│  2. Check if payload ≥ 300 bytes                                        │
│  3. Check if data doesn't look already compressed                       │
│  4. Compress with DEFLATE                                               │
│  5. If compressed < original: use compressed, set FLAGS=0x01            │
│     Else: use original, set FLAGS=0x00                                  │
│  6. Calculate CRC32 on transmitted data                                 │
│  7. Send parcels                                                        │
│                                                                         │
│  Receiver:                                                              │
│  1. Receive all parcels                                                 │
│  2. Verify CRC32 on received data                                       │
│  3. Check FLAGS byte for compression algorithm                          │
│  4. If FLAGS != 0x00: decompress before returning payload               │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

**Capability Negotiation:**

Compression support is advertised in the HELLO handshake capabilities list:

```json
{
  "type": "hello",
  "payload": {
    "capabilities": ["chat", "compression:deflate"],
    ...
  }
}
```

Only compress when sending to peers that include `compression:deflate` in their capabilities.

**Backward Compatibility:**
- Old receivers (FLAGS=0x00): Work fine, no decompression needed
- New senders to old receivers: Don't compress (peer didn't advertise support)
- Old senders to new receivers: FLAGS byte may be parsed as part of data (graceful degradation via checksum failure and retry)

**Compression Constants:**
```dart
class BLEParcelConstants {
  static const int compressionNone = 0x00;
  static const int compressionDeflate = 0x01;
  static const int compressionThreshold = 300;  // bytes
}
```

**Expected Compression Ratios:**
| Data Type | Typical Ratio |
|-----------|---------------|
| JSON (HELLO, chat) | 40-60% reduction |
| Station data | 50-70% reduction |
| Binary data | Varies (may be worse) |
| Already compressed | Not compressed |

### Receipt Protocol

After receiving all parcels (or timeout), receiver sends ONE response:

**Complete:**
```json
{"msg_id": "AK", "status": "complete"}
```

**Missing parcels:**
```json
{"msg_id": "AK", "status": "missing", "parcels": [3, 7, 12]}
```

**Checksum failure:**
```json
{"msg_id": "AK", "status": "checksum_failed"}
```

Sender retransmits only the requested parcels, then waits for another receipt.

### Retention and Timeout Policies

The protocol implements automatic recovery mechanisms for dropped parcels:

**Timing Constants:**

| Constant | Value | Description |
|----------|-------|-------------|
| `sentMessageRetention` | 2 minutes | How long sender keeps parcels for retransmission requests |
| `missingParcelRequestDelay` | 5 seconds | How long receiver waits before requesting missing parcels |
| `incompleteMessageTimeout` | 60 seconds | How long to keep incomplete incoming messages |
| `housekeepingInterval` | 10 seconds | How often housekeeping tasks run |
| `receiptTimeout` | 10 seconds | How long sender waits for receipt before considering send failed |

**Sender Behavior:**

1. After sending all parcels, sender retains the message in memory for 2 minutes
2. If a "missing" receipt arrives (even after initial transmission completes), sender retransmits requested parcels
3. After 2 minutes, sent message is removed from retention cache
4. If retransmission is requested after retention expires, sender cannot fulfill the request

**Receiver Behavior:**

1. Receiver buffers incoming parcels by message ID
2. If no new parcels arrive for 5 seconds and message is incomplete, receiver sends "missing" receipt
3. Receiver continues requesting missing parcels every 5 seconds until complete or timeout
4. After 60 seconds total, incomplete messages are discarded
5. Each new parcel received resets the 5-second request timer

**Housekeeping:**

A background timer runs every 10 seconds to:
- Remove expired sent messages from retention cache
- Check for stalled incoming messages and request missing parcels
- Clean up incomplete messages that have timed out

```
Timeline Example (parcel 4 dropped):

T+0.0s   Sender: Send parcels 1-5
T+0.5s   Receiver: Receives parcels 1,2,3,5 (4 dropped)
T+2.5s   Sender: Waits for receipt...
T+5.5s   Receiver: No parcel 4 after 5s, sends {"status":"missing","parcels":[4]}
T+5.6s   Sender: Receives missing request, retransmits parcel 4
T+6.1s   Receiver: Receives parcel 4, message complete
T+6.2s   Receiver: Sends {"status":"complete"}
T+6.3s   Sender: Transmission confirmed

If T+120s: Sender removes message from retention (no longer retransmittable)
If T+60s (no progress): Receiver discards incomplete message
```

### Transmission Flow

```
SENDER                              RECEIVER
  |                                    |
  |-- Header Parcel (MSG_ID=AK) ------>|
  |     [AK][total=5][crc32][data...]  |
  |                                    |
  |-- Parcel 2 ----------------------->|
  |     [AK][2][data...]               |
  |                                    |
  |-- Parcel 3 ----------------------->|
  |     [AK][3][data...]               |
  |                                    |
  |<< LISTEN WINDOW (200ms) >>         |
  |                                    |
  |-- Parcel 4 ----------------------->|  (dropped)
  |     [AK][4][data...]               |
  |                                    |
  |-- Parcel 5 ----------------------->|
  |     [AK][5][data...]               |
  |                                    |
  |<------- Receipt -------------------|
  |  {"msg_id":"AK","status":"missing",|
  |   "parcels":[4]}                   |
  |                                    |
  |-- Parcel 4 (retry) --------------->|
  |     [AK][4][data...]               |
  |                                    |
  |<------- Receipt -------------------|
  |  {"msg_id":"AK","status":"complete"}
  |                                    |
```

### Queue Management

```dart
class BLEParcelConstants {
  // Parcel sizing
  static const parcelSize = 280;
  static const headerOverhead = 9;      // MSG_ID(2) + TOTAL(2) + CRC32(4) + FLAGS(1)
  static const dataOverhead = 4;        // MSG_ID(2) + PARCEL_NUM(2)

  // Transmission timing
  static const parcelsBeforePause = 5;  // Listen window every N parcels
  static const listenWindowMs = 200;    // Duration of listen window
  static const interParcelDelayMs = 500;
  static const intraChunkDelayMs = 30;
  static const receiptTimeoutMs = 10000;
  static const maxRetries = 3;

  // Compression
  static const compressionNone = 0x00;
  static const compressionDeflate = 0x01;
  static const compressionThreshold = 300;  // Minimum bytes to consider compression
}

class BLERetentionConstants {
  static const sentMessageRetention = Duration(minutes: 2);
  static const missingParcelRequestDelay = Duration(seconds: 5);
  static const incompleteMessageTimeout = Duration(seconds: 60);
  static const housekeepingInterval = Duration(seconds: 10);
}

class BLETransmitQueue {
  final Queue<BLEOutgoingMessage> _queue = Queue();
  final Map<String, SentMessageRecord> _sentMessages = {};  // Retention cache
  bool _isSending = false;
  Timer? _housekeepingTimer;

  Future<void> enqueue(BLEOutgoingMessage message);
  Future<void> _processQueue();
  Future<void> _sendMessage(BLEOutgoingMessage message);
  Future<void> _waitForReceipt(String msgId);
  void _pauseForListening();
  void _performHousekeeping();  // Runs every 10s
  void _handleRetransmissionRequest(BLEReceipt receipt);
}
```

### Receive Buffer

```dart
class BLEReceiveBuffer {
  final Map<String, _PendingMessage> _pending = {};

  void addParcel(String msgId, int parcelNum, Uint8List data, {
    int? totalParcels,
    int? expectedChecksum,
  });

  bool isComplete(String msgId);
  Uint8List? assemble(String msgId);
  List<int> getMissingParcels(String msgId);
  void clear(String msgId);
}

class _PendingMessage {
  final int totalParcels;
  final int expectedChecksum;
  final Map<int, Uint8List> parcels;
  final DateTime startTime;
  DateTime lastParcelReceivedAt;      // For timeout detection
  DateTime? lastMissingRequestAt;     // To avoid spamming requests

  // Used by housekeeping to track when to request missing parcels
  void markParcelRequestSent();
  bool isStale({Duration timeout});
}
```

### Identity Service

```dart
class BLEIdentityService {
  int? _deviceId;  // 1-15, derived from hardware
  String? _lastKnownMac;
  Timer? _advertisementTimer;

  // Initialize on app start
  Future<void> initialize() async {
    _deviceId = await _computeHardwareDeviceId();
    startPeriodicAdvertisement();
  }

  // Compute device ID from hardware fingerprint (1-15)
  Future<int> _computeHardwareDeviceId() async {
    String? fingerprint;
    if (Platform.isLinux) {
      // Read /etc/machine-id (persistent unique machine identifier)
      fingerprint = await File('/etc/machine-id').readAsString();
    } else if (Platform.isAndroid) {
      // Use Build.FINGERPRINT or ANDROID_ID
      fingerprint = await _getAndroidHardwareId();
    }
    // Hash and reduce to 1-15
    return (hashString(fingerprint) % 15) + 1;
  }

  // Advertise every 30 seconds
  void startPeriodicAdvertisement() {
    _advertisementTimer = Timer.periodic(
      Duration(seconds: 30),
      (_) => _advertiseIdentity(),
    );
  }

  // Check for MAC change (Android)
  Future<void> _checkMacChange() async {
    if (!Platform.isAndroid) return;
    final currentMac = await _getCurrentMac();
    if (currentMac != _lastKnownMac) {
      _lastKnownMac = currentMac;
      await _broadcastIdentityUpdate();
    }
  }

  // Get full identity string (APRS SSID compatible)
  String get fullIdentity => '$callsign-$_deviceId';
}
```

### Identity Update Message

Broadcast when MAC changes:
```json
{
  "type": "identity_update",
  "callsign": "X34PSK",
  "device_id": 7,
  "mac": "7D:18:06:49:4E:7B",
  "timestamp": 1733750400
}
```

### Message Protocol (JSON Envelope)

All application messages use this format:

```json
{
  "v": 1,
  "id": "uuid-for-correlation",
  "type": "hello|hello_ack|chat|chat_ack|error",
  "seq": 0,
  "total": 1,
  "payload": { ... }
}
```

---

## Part 5: Implementation Files

| File | Purpose |
|------|---------|
| `lib/services/ble_discovery_service.dart` | BLE scanning, GATT client, device tracking |
| `lib/services/ble_gatt_server_service.dart` | GATT server for Android/iOS |
| `lib/services/ble_message_service.dart` | High-level messaging API |
| `lib/services/ble_queue_service.dart` | Transmission queue, listen windows, retry logic |
| `lib/services/ble_identity_service.dart` | Device ID, MAC monitoring, periodic advertisement |
| `lib/models/ble_parcel.dart` | Parcel models, header/data format, checksum |
| `lib/models/ble_message.dart` | Message models |

---

## Part 6: Error Handling

### Transmission Errors

| Error | Action |
|-------|--------|
| Parcel write fails | Retry up to 3 times with exponential backoff |
| Receipt timeout | Request status from receiver, or abort |
| Checksum mismatch | Request full retransmission |
| Connection lost | Re-queue message, attempt reconnect |

### Buffer Overflow Prevention

- Max pending messages per device: 5
- Max message size: 50KB (178 parcels)
- Stale message timeout: 60 seconds (clear incomplete)

### Logging

All BLE operations logged with prefix for easy filtering:
```
BLEDiscovery:  Scanning and discovery
BLEQueue:      Queue operations
BLEParcel:     Parcel send/receive
BLEIdentity:   Identity advertisement
BLEReceipt:    Receipt handling
```

---

## Part 7: Platform Setup

### Android

Required permissions in `AndroidManifest.xml`:
```xml
<uses-permission android:name="android.permission.BLUETOOTH_SCAN"/>
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT"/>
<uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE"/>
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
```

### iOS

Required in `Info.plist`:
```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Geogram uses Bluetooth to discover nearby devices</string>
```

### Linux

Requirements:
- BlueZ installed and running (`sudo systemctl start bluetooth`)
- User in `bluetooth` group (`sudo usermod -aG bluetooth $USER`)

---

## Part 8: Testing

### Test Scripts

Platform-specific test scripts are in the `test/` folder:

| File | Description |
|------|-------------|
| `test/ble_linux_linux.sh` | Test between two Linux devices |
| `test/ble_linux_android.sh` | Test between Linux and Android |
| `test/ble_android_android.sh` | Test between two Android devices |
| `test/ble_api_test.dart` | Dart test suite (shared logic) |

### Running Tests

**Linux to Linux:**
```bash
# On both machines, start Geogram Desktop
# Then from one machine:
./test/ble_linux_linux.sh 192.168.1.100
```

**Linux to Android:**
```bash
# Start Geogram on both devices
# From Linux:
./test/ble_linux_android.sh 192.168.1.50
```

**Android to Android:**
```bash
# Start Geogram on both Android devices
# Run from any machine that can reach both:
./test/ble_android_android.sh 192.168.1.50 192.168.1.51
```

**Single Device (scan only):**
```bash
./test/ble_linux_linux.sh
```

### Test Cases

| Test | Description | Requirements |
|------|-------------|--------------|
| `scan` | BLE device scanning | Single device |
| `discovery` | Device discovery | Two devices in range |
| `advertise` | BLE advertising | Android/iOS only |
| `hello` | HELLO handshake | Two devices |
| `bidirectional` | Both directions | Two devices |

### Debug API Endpoints

Tests use the debug API at port 3456:

**Trigger BLE Actions:**
```bash
# BLE Scan
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "ble_scan"}'

# BLE Advertise
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "ble_advertise"}'

# BLE HELLO Handshake
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "ble_hello"}'
```

**Read Logs:**
```bash
# All BLE logs
curl "http://localhost:3456/log?filter=BLE"

# Last 50 logs with filter
curl "http://localhost:3456/log?filter=BLEDiscovery&limit=50"
```

### Expected Log Patterns

**Successful Scan:**
```
BLEDiscovery: Starting BLE scan...
BLEDiscovery: Found device XX:XX:XX:XX:XX:XX (identity: CALLSIGN-7, ...)
BLEDiscovery: Scan stopped. Found N devices
```

**Successful HELLO:**
```
BLEDiscovery: Connecting to XX:XX:XX:XX:XX:XX...
BLEMessageService: HELLO handshake successful with CALLSIGN
```

**Advertising Started:**
```
BLEDiscovery: Started advertising as CALLSIGN-7
BLEIdentity: Started periodic advertisement (30s interval)
```

### Test Matrix

| Scenario | Linux | Android | iOS |
|----------|-------|---------|-----|
| BLE Scan | ✅ | ✅ | ✅ |
| Discover Android | ✅ | N/A | ✅ |
| Discover Linux | ❌* | ✅ | ✅ |
| HELLO as Client | ✅ | ✅ | ✅ |
| HELLO as Server | ❌* | ✅ | ✅ |
| Advertise | ❌* | ✅ | ✅ |

*Linux cannot advertise (ble_peripheral limitation), so Linux devices can only be discovered via direct connection, not advertising.
