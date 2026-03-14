# Geogram HTTP API

The Geogram firmware provides an HTTP API for device status, configuration, and control. The API is available when the device is connected to WiFi.

## Base URL

When connected to WiFi as a station:
```
http://<device-ip>/
```

When in AP mode (setup):
```
http://192.168.4.1/
```

## Endpoints

### WiFi Configuration

#### `GET /`

Returns the WiFi configuration page (HTML form).

**Response:** HTML page with WiFi setup form.

Used during initial device setup when the device is in AP mode.

---

#### `POST /connect`

Submit WiFi credentials to connect to a network.

**Content-Type:** `application/x-www-form-urlencoded`

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `ssid` | string | Yes | WiFi network name (max 32 chars) |
| `password` | string | No | WiFi password (max 64 chars) |

**Example:**
```bash
curl -X POST http://192.168.4.1/connect \
  -d "ssid=MyNetwork&password=secret123"
```

**Response:** HTML success page. Device will attempt to connect to the specified network.

**Side Effects:**
- Credentials are saved to NVS for auto-reconnection on reboot
- Device will disable AP mode and connect as a station

---

### Status Endpoints

#### `GET /status`

Basic status check endpoint.

**Response:**
```json
{
  "status": "ok",
  "device": "geogram"
}
```

---

#### `GET /api/status`

Full device status with station information. Only available when Station API is enabled (after WiFi connection).

**Response:**
```json
{
  "station": {
    "callsign": "ESPAB12",
    "name": "Geogram Station",
    "version": "1.0.0",
    "uptime": 3600,
    "clients": 0
  },
  "wifi": {
    "status": "connected",
    "ip": "192.168.1.50"
  },
  "sensors": {
    "temperature": 23.5,
    "humidity": 45.2
  },
  "sdcard": {
    "mounted": true,
    "capacity_gb": 7.45
  },
  "heap": {
    "free": 245632
  }
}
```

**Headers:**
- `Access-Control-Allow-Origin: *` (CORS enabled)

**Example:**
```bash
curl http://192.168.1.50/api/status
```

---

### WebSocket (Planned)

#### `WS /ws`

WebSocket endpoint for real-time communication with connected clients.

**Status:** Not currently enabled. Requires `CONFIG_HTTPD_WS_SUPPORT=y` in sdkconfig.

**Planned Message Types:**

**Client -> Server:**
```json
{"type": "HELLO", "callsign": "CLIENT1", "nickname": "User", "platform": "Android"}
```

```json
{"type": "PING"}
```

**Server -> Client:**
```json
{"type": "HELLO_ACK", "success": true, "message": "Welcome"}
```

```json
{"type": "PONG", "timestamp": 1234567890}
```

---

## Station API

The Station API provides information about the Geogram device acting as a local "station" that clients can connect to.

### Callsign

Each device has a unique callsign generated from its MAC address (e.g., `ESPAB12`). This identifies the station on the network.

### Client Management

The station can track up to 8 connected clients (via WebSocket when enabled). Each client has:
- `callsign` - Unique client identifier
- `nickname` - Display name
- `platform` - Client platform (Android, iOS, Linux, etc.)
- `connected_at` - Connection timestamp
- `last_activity` - Last message timestamp

---

## Error Responses

### HTTP 400 Bad Request

Missing or invalid parameters.

```json
{"error": "Missing SSID"}
```

### HTTP 500 Internal Server Error

Server-side error.

```json
{"error": "Failed to process request"}
```

---

## Usage Examples

### Python

```python
import requests

# Get device status
response = requests.get('http://192.168.1.50/api/status')
status = response.json()
print(f"Callsign: {status['station']['callsign']}")
print(f"Uptime: {status['station']['uptime']}s")
print(f"Temperature: {status['sensors']['temperature']}C")

# Configure WiFi (when in AP mode)
requests.post('http://192.168.4.1/connect', data={
    'ssid': 'MyNetwork',
    'password': 'secret123'
})
```

### JavaScript

```javascript
// Fetch device status
fetch('http://192.168.1.50/api/status')
  .then(response => response.json())
  .then(status => {
    console.log(`Callsign: ${status.station.callsign}`);
    console.log(`Temperature: ${status.sensors.temperature}C`);
  });
```

### curl

```bash
# Get status
curl http://192.168.1.50/api/status | jq

# Configure WiFi
curl -X POST http://192.168.4.1/connect \
  -d "ssid=MyNetwork&password=secret123"
```

---

## Device Modes

### AP Mode (Setup)

When no WiFi credentials are saved or connection fails, the device starts in Access Point mode:
- SSID: `Geogram-Setup`
- Password: (none - open network)
- IP: `192.168.4.1`

Connect to this network and navigate to `http://192.168.4.1/` to configure WiFi.

### Station Mode (Connected)

After successful WiFi connection, the device:
- Obtains an IP address via DHCP
- Starts the Station API server on port 80
- Exposes `/api/status` and `/ws` endpoints

---

## APRS API (KV4P only)

These endpoints are only available on the KV4P board, which has an SA818 radio module with full APRS TX/RX capability. The radio is shared — all messages are visible to all connected clients.

### `GET /api/aprs?since=<id>`

Returns APRS messages with id greater than `since`. Omit `since` or pass `""` to get all messages.

**Response:**
```json
{
  "epoch": "K",
  "latest_id": "K42",
  "count": 3,
  "messages": [
    {
      "id": "K40",
      "timestamp": 1709312400,
      "from": "N0CALL",
      "to": "APRS",
      "message": "!4903.50N/07201.75W-PHG2360",
      "raw": "N0CALL>APRS,WIDE1-1:!4903.50N/...",
      "beacon": true,
      "beacon_count": 15,
      "outgoing": false
    }
  ]
}
```

**Epoch-prefixed IDs:** Each message ID is prefixed with a random uppercase letter (A-Z) chosen at boot. This letter is the "epoch" — it changes on every reboot or reflash. When a client polls with `since=K5` but the device epoch is now `M`, the server knows the index was reset and returns all messages. The `epoch` field in the response can also be used to detect resets.

**Beacon deduplication:** Repeated position/status beacons from the same callsign with identical content are deduplicated. The `beacon_count` field shows how many times the beacon was received. The message's `id` is bumped on each repeat so it appears as "new" when polling with `since`.

**Store capacity:** 128 messages in a circular buffer. When full, the oldest message is overwritten.

**Example:**
```bash
# Get all messages
curl http://192.168.5.1/api/aprs

# Poll for new messages since ID K42
curl http://192.168.5.1/api/aprs?since=K42
```

---

### `POST /api/aprs`

Send an APRS message via the SA818 radio. Messages longer than 67 characters are automatically split into multiple APRS frames with `[1/N]` prefix.

**Content-Type:** `application/x-www-form-urlencoded`

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `from` | string | Yes | Sender callsign (max 16 chars) |
| `to` | string | Yes | Destination callsign (max 16 chars) |
| `message` | string | Yes | Message text (max 500 chars) |

**Multi-part splitting:**
- Messages up to 67 chars are sent as a single APRS frame (no prefix).
- Messages longer than 67 chars are split into parts of 61 chars each, prefixed with `[1/N] `, `[2/N] `, etc. (6-char prefix + 61-char payload = 67-char APRS limit).
- Maximum 500 chars input = up to 9 parts.
- Each part is stored and transmitted independently.

**Response:**
```json
{"ok": true, "parts": 3, "queued": 3}
```

**Error Response:**
```json
{"ok": false, "error": "TX failed"}
```

**Example:**
```bash
# Short message — single part
curl -X POST http://192.168.5.1/api/aprs \
  -d "from=MYCALL&to=THEIRCALL&message=Hello"

# Long message — automatically split into multiple parts
curl -X POST http://192.168.5.1/api/aprs \
  -d "from=MYCALL&to=THEIRCALL&message=This+is+a+long+message+that+exceeds+the+67+character+APRS+limit+and+will+be+split+into+multiple+parts"
```

---

### `GET /api/aprs/status`

Returns APRS radio status.

**Response:**
```json
{
  "enabled": true,
  "frequency": 144.800,
  "tx_supported": true,
  "total_rx": 123,
  "total_tx": 5
}
```

**Fields:**
| Field | Description |
|-------|-------------|
| `enabled` | Whether the radio is powered on |
| `frequency` | Current APRS frequency in MHz |
| `tx_supported` | Whether APRS TX is supported (requires audio_out pin) |
| `total_rx` | Total received APRS frames (including deduplicated beacons) |
| `total_tx` | Total transmitted APRS messages |

**Example:**
```bash
curl http://192.168.5.1/api/aprs/status
```

---

## OTA Firmware Update (KV4P only)

Over-the-air firmware updates via HTTP. The device uses a dual OTA partition scheme (A/B) — new firmware is written to the inactive slot, validated, then the device reboots into it.

**Note:** The first flash after enabling OTA must be via USB (partition table change). After that, all updates can be done over HTTP.

### `GET /ota`

Firmware update web page with file picker, upload progress bar, and reboot polling.

**Response:** HTML page.

---

### `GET /api/ota/status`

Returns current firmware version and partition info.

**Response:**
```json
{
  "version": "1.0.0",
  "partition": "ota_0",
  "ota_ready": true
}
```

| Field | Description |
|-------|-------------|
| `version` | Current firmware version string |
| `partition` | Active partition label (`ota_0` or `ota_1`) |
| `ota_ready` | Whether an OTA update partition is available |

**Example:**
```bash
curl http://192.168.1.94/api/ota/status
```

---

### `POST /api/ota`

Upload a firmware binary to flash. The binary is streamed in chunks, written to the inactive OTA partition, validated, and then the device reboots.

**Content-Type:** `application/octet-stream`

**Body:** Raw firmware `.bin` file.

**Response (success):**
```json
{"ok": true}
```
Device reboots ~500ms after sending the response.

**Error Responses:**
```json
{"error": "No OTA partition available"}
{"error": "Firmware too large for partition"}
{"error": "Invalid firmware image"}
{"error": "Flash write failed"}
{"error": "Validation failed: <reason>"}
```

**Examples:**
```bash
# Upload via curl
curl -X POST http://192.168.1.94/api/ota \
  -H "Content-Type: application/octet-stream" \
  --data-binary @esp32/firmware/geogram-KV4P-HT.bin

# Upload via web browser
# Navigate to http://192.168.1.94/ota
```

**Partition size limit:** ~1.9MB (1,966,080 bytes). Current firmware is ~1.6MB.

---

## Rate Limiting

There is no rate limiting implemented. For polling `/api/status`, a reasonable interval is 1-5 seconds.

---

## Security Considerations

- The HTTP API has no authentication
- WiFi credentials are stored in NVS (non-volatile storage)
- CORS is enabled (`Access-Control-Allow-Origin: *`)
- Intended for local network use only

For production deployments, consider:
- Adding API authentication
- Using HTTPS (requires certificate configuration)
- Restricting CORS origins
