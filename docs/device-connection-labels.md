# Device Connection Labels

This document describes the connection path labels displayed in the Devices UI panel, how they are verified, and the priority order for data exchange between devices.

## 1. Connection Types

The application supports multiple connection paths between devices. Each path has different characteristics in terms of speed, reliability, and range.

### 1.1 Primary Connection Types

| Type | Label | Color | Description |
|------|-------|-------|-------------|
| **LAN/WiFi** | `wifi_local` / `lan` | Blue | Direct connection over local network (same WiFi/Ethernet) |
| **Internet** | `internet` | Green | Connection via internet relay station (WebSocket) |
| **Bluetooth LE** | `bluetooth` | Light Blue | Bluetooth Low Energy for nearby devices (<100m) |
| **LoRa** | `lora` | Orange | Long-range low-power radio (future) |
| **Radio** | `radio` | Purple | Amateur radio packet (future) |
| **ESP32 Mesh** | `esp32_mesh` | Teal | ESP32-based mesh networking (future) |
| **Wi-Fi HaLow** | `wifi_halow` / `halow` | Cyan | Long-range WiFi 802.11ah (future) |

### 1.2 Device Source Types

Defined in `lib/models/device_source.dart`:

- **Local**: The device running this application
- **Station**: Internet gateway/relay server
- **Direct**: Peer-to-peer connection to another device
- **BLE**: Bluetooth Low Energy discovered device

---

## 2. Connection Verification Approach

### 2.1 Core Principles

1. **Non-blocking UI**: All connection scans run in background isolates or async tasks
2. **Progressive discovery**: Labels appear as connections are verified, not all at once
3. **Graceful degradation**: If a scan fails, existing labels remain until explicitly invalidated
4. **Battery awareness**: Scan intervals are longer on mobile to preserve battery

### 2.2 Scan Types and Intervals

| Scan Type | Initial Delay | Interval | Timeout | Platform |
|-----------|---------------|----------|---------|----------|
| **BLE Discovery** | 2 seconds | Continuous (event-driven) | 10s per device | All (Central only on desktop) |
| **LAN Discovery** | 5 seconds | 5 minutes | 3s per host | All |
| **Station Clients** | On connect | 30 seconds | 5s | All |
| **Direct Reachability** | 10 seconds | 30 seconds | 5s per device | All |

### 2.3 Connection Verification Methods

#### 2.3.1 LAN/WiFi (`wifi_local`)

**Detection Method:**
1. Scan local network subnets for known ports (3456, 8080, 80, 8081, 3000, 5000)
2. HTTP GET to `/api/status` endpoint on discovered hosts
3. Check if IP is private (RFC 1918) to confirm LAN vs Internet

**Add Label When:**
- Device responds to `/api/status` on local network
- Response IP is a private address (10.x.x.x, 172.16-31.x.x, 192.168.x.x)

**Remove Label When:**
- Device fails to respond after 3 consecutive checks (90 seconds)
- Device IP changes to public address

**Implementation:** `StationDiscoveryService.scanNetwork()` and `DevicesService._checkDirectConnection()`

#### 2.3.2 Internet (`internet`)

**Detection Method:**
1. Query connected relay station's `/api/devices` endpoint
2. Check device reachability via station proxy at `/device/{callsign}`
3. Direct connection check returns public IP

**Add Label When:**
- Device appears in station's connected clients list
- Device is reachable via station proxy endpoint
- Direct connection succeeds with public IP

**Remove Label When:**
- Device disconnects from station (not in clients list)
- Station proxy check fails after 3 consecutive attempts
- Station itself disconnects

**Implementation:** `StationService.fetchConnectedClients()` and `DevicesService._checkViaRelayProxy()`

#### 2.3.3 Bluetooth LE (`bluetooth`)

**Detection Method:**
1. BLE scan for devices advertising service UUID `0000FFF0-0000-1000-8000-00805F9B34FB`
2. Parse advertising data for marker byte `0x3E`, device ID, and callsign
3. HELLO handshake via GATT characteristics for full device info

**Add Label When:**
- Device discovered in BLE scan with valid advertising marker
- HELLO handshake completes successfully
- Device seen within last 60 seconds

**Remove Label When:**
- Device not present in current BLE scan results (immediate removal)
- BLE cleanup runs on every scan completion (event-driven, typically every 10 seconds)
- BLE tags are session-based and not persisted from cache
- BLE disabled on local device

**Proximity Levels (based on RSSI):**
| RSSI Range | Label | Typical Distance |
|------------|-------|------------------|
| > -50 dBm | Very close | < 1 meter |
| -50 to -70 dBm | Nearby | 1-10 meters |
| -70 to -85 dBm | In range | 10-30 meters |
| < -85 dBm | Far | 30-100 meters |

**Implementation:** `BLEDiscoveryService`

#### 2.3.4 Future Connection Types

**LoRa (`lora`):**
- Will use serial connection to LoRa module
- Expected range: 2-15 km depending on terrain
- Scan interval: Event-driven (on packet receive)

**Radio (`radio`):**
- Amateur radio packet mode via TNC
- Range: Line of sight, typically 50+ km
- Requires amateur radio license

**ESP32 Mesh (`esp32_mesh`):**
- ESP-NOW or ESP-MDF mesh protocol
- Range: 200m per hop, multi-hop extends range
- Scan interval: 10 seconds

**Wi-Fi HaLow (`wifi_halow`):**
- IEEE 802.11ah sub-GHz WiFi
- Range: 1 km+
- Scan interval: 30 seconds

#### 2.3.5 Connection Method Lifecycle

Each connection type is managed independently by its discovery method:

| Type | Added When | Removed When | Cached? |
|------|-----------|--------------|---------|
| **BLE** | Device in current BLE scan | Device not in current BLE scan | No (session-based) |
| **Internet** | Device connected to station | Device disconnected from station OR station offline | No (connection-based) |
| **LAN** | Device responds on local network | 3 consecutive failed checks (90s) | Yes |

**Key Principle:** Connection methods reflect **current reachability**, not historical discovery.
BLE and Internet tags are never loaded from cache - they come only from active discovery/connections.

### 2.4 Background Scanning Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Main UI Thread                          │
│  - Receives stream updates from services                    │
│  - Updates device labels reactively                         │
│  - Never blocks for scan results                            │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ StreamController
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    DevicesService                           │
│  - Aggregates results from all discovery services           │
│  - Maintains canonical device list                          │
│  - Emits updates via devicesStream                          │
└─────────────────────────────────────────────────────────────┘
         │              │               │              │
         ▼              ▼               ▼              ▼
┌──────────────┐ ┌─────────────┐ ┌────────────┐ ┌────────────┐
│BLEDiscovery  │ │StationDisco-│ │StationSer- │ │Direct      │
│Service       │ │veryService  │ │vice        │ │Reachability│
│              │ │             │ │            │ │Check       │
│Async BLE scan│ │Async network│ │WebSocket   │ │HTTP/HTTPS  │
│with callbacks│ │port scan    │ │connection  │ │ping        │
└──────────────┘ └─────────────┘ └────────────┘ └────────────┘
```

### 2.5 Label State Machine

```
                    ┌─────────────────┐
                    │   Not Visible   │
                    └────────┬────────┘
                             │
                    Scan discovers device
                    with this connection type
                             │
                             ▼
                    ┌─────────────────┐
           ┌───────│    Pending      │───────┐
           │       │  (verifying)    │       │
           │       └─────────────────┘       │
           │                                  │
    Verification              Verification
      succeeds                  fails
           │                                  │
           ▼                                  ▼
┌─────────────────┐              ┌─────────────────┐
│     Active      │              │   Not Visible   │
│  (label shown)  │              └─────────────────┘
└────────┬────────┘
         │
         │◄─── Refresh success (stay Active)
         │
    3 consecutive
    failures or
    explicit removal
         │
         ▼
┌─────────────────┐
│   Not Visible   │
└─────────────────┘
```

---

## 3. Connection Priority Levels

When multiple connection paths are available to a device, the application selects the optimal path based on the following priority order.

### 3.1 Priority Order (Highest to Lowest)

| Priority | Connection | Latency | Bandwidth | Rationale |
|----------|------------|---------|-----------|-----------|
| 1 | **LAN/WiFi** | ~1-5ms | High (100+ Mbps) | Direct local connection, no intermediary |
| 2 | **Wi-Fi HaLow** | ~10-20ms | Medium (1-10 Mbps) | Long-range WiFi, still direct |
| 3 | **ESP32 Mesh** | ~20-50ms | Low-Medium (0.5-2 Mbps) | Local mesh, low latency per hop |
| 4 | **Bluetooth LE** | ~50-100ms | Low (0.1-0.5 Mbps) | Very short range but no infrastructure needed |
| 5 | **Internet** | ~50-200ms | Medium-High (varies) | Requires relay station, adds latency |
| 6 | **LoRa** | ~500ms-2s | Very Low (0.3-50 kbps) | Long range but very low bandwidth |
| 7 | **Radio** | ~1-5s | Very Low (1.2-9.6 kbps) | Emergency/backup, highest latency |

### 3.2 Selection Algorithm

```dart
ConnectionPath selectBestPath(RemoteDevice device) {
  final methods = device.connectionMethods;

  // Priority order
  final priorityOrder = [
    'wifi_local', 'lan',
    'wifi_halow', 'halow',
    'esp32_mesh',
    'bluetooth',
    'internet',
    'lora',
    'radio',
  ];

  for (final method in priorityOrder) {
    if (methods.contains(method)) {
      return ConnectionPath(method);
    }
  }

  return ConnectionPath.none;
}
```

### 3.3 Fallback Strategy

When the primary connection fails:

1. **Immediate fallback**: Try next priority connection
2. **Retry primary**: After 30 seconds, re-check if primary is available
3. **Graceful degradation**: Adjust message size/frequency for low-bandwidth connections

### 3.4 Connection Selection by Use Case

| Use Case | Preferred Connection | Fallback |
|----------|---------------------|----------|
| **Real-time chat** | LAN > Internet > BLE | Any available |
| **File transfer** | LAN > Internet | Queue for later if unavailable |
| **Location sharing** | BLE > LAN > Internet | Any (small payload) |
| **Emergency alerts** | Radio > LoRa > Any | Broadcast on all available |
| **Sync operations** | LAN > Internet | Queue for LAN availability |

### 3.5 Multi-Path Usage

For critical messages, the application may use multiple paths simultaneously:

```
┌─────────────────────────────────────────────────────────────┐
│                    Message Router                           │
├─────────────────────────────────────────────────────────────┤
│  Priority Message (emergency/alert):                        │
│    → Send via ALL available paths                           │
│    → First acknowledgment confirms delivery                 │
│    → Deduplicate on receiver side                           │
│                                                             │
│  Normal Message:                                            │
│    → Send via highest priority path only                    │
│    → Fallback to next priority on failure                   │
│                                                             │
│  Large File Transfer:                                       │
│    → Use LAN or Internet only (bandwidth required)          │
│    → Queue if neither available                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 4. UI Implementation Guidelines

### 4.1 Label Display Order

Labels should be displayed in priority order (left to right):
```
[WiFi] [Internet] [Bluetooth] [LoRa] [Radio]
```

### 4.2 Label Colors

```dart
Color getConnectionColor(String method) {
  switch (method) {
    case 'wifi_local':
    case 'lan':
      return Colors.blue;
    case 'internet':
      return Colors.green;
    case 'bluetooth':
      return Colors.lightBlue;
    case 'lora':
      return Colors.orange;
    case 'radio':
      return Colors.purple;
    case 'esp32_mesh':
      return Colors.teal;
    case 'wifi_halow':
    case 'halow':
      return Colors.cyan;
    default:
      return Colors.grey;
  }
}
```

### 4.3 Status Indicators

In addition to connection labels, show:

| Indicator | Meaning |
|-----------|---------|
| Green dot | Device is online (at least one connection active) |
| Gray dot | Device is offline (no connections) |
| "Cached" badge | Device offline but cached data available |
| "Unreachable" badge | Device offline, no cached data |
| Latency value | Round-trip time in ms (when measurable) |

### 4.4 Label Animation

- **Appearing**: Fade in over 200ms when connection verified
- **Disappearing**: Fade out over 300ms after removal confirmed
- **Pending**: Subtle pulse animation while verifying

---

## 5. Troubleshooting

### 5.1 Common Issues

| Issue | Possible Cause | Solution |
|-------|----------------|----------|
| LAN label not appearing | Firewall blocking port | Check ports 3456, 8080 are open |
| BLE label disappears quickly | Device out of range | Move devices closer together |
| Internet label but high latency | Distant relay station | Connect to closer station |
| No labels appearing | All scans failing | Check network connectivity, BLE permissions |

### 5.2 Debug Information

Enable debug mode to see:
- Raw scan results before filtering
- Connection attempt logs
- Timing information for each scan type
- RSSI values for BLE devices

---

## 6. Future Considerations

### 6.1 Planned Improvements

1. **Connection quality indicators**: Show signal strength/quality, not just presence
2. **Automatic path optimization**: Learn which paths work best for each device
3. **Bandwidth estimation**: Measure actual throughput per connection type
4. **Connection bonding**: Use multiple paths simultaneously for increased throughput

### 6.2 Configuration Options

Future user preferences:
- Preferred connection type (override automatic selection)
- Disable specific connection types
- Custom scan intervals
- Battery saver mode (reduced scan frequency)
