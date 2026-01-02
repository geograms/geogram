# Transfer Format Specification

**Version**: 1.0
**Last Updated**: 2026-01-01
**Status**: Draft

## Table of Contents

- [Overview](#overview)
- [Terminology](#terminology)
- [File Organization](#file-organization)
- [Configuration Files](#configuration-files)
- [Transfer Lifecycle](#transfer-lifecycle)
- [Transfer Types](#transfer-types)
- [Queue Management](#queue-management)
- [Retry Policy](#retry-policy)
- [Patient Mode](#patient-mode)
- [Ban List](#ban-list)
- [Verification](#verification)
- [Protocol Messages](#protocol-messages)
- [API Endpoints](#api-endpoints)
- [EventBus Integration](#eventbus-integration)
- [Metrics & Statistics](#metrics--statistics)
- [Error Handling](#error-handling)
- [Security Considerations](#security-considerations)
- [Related Documentation](#related-documentation)
- [Change Log](#change-log)

## Overview

The Transfer app provides a centralized download/upload/streaming center for Geogram. It handles all file transfers across apps with unified progress tracking, retry logic, resume capability, and a full management UI.

### Key Features

1. **Bidirectional transfers**: Downloads, uploads, and streaming
2. **Resume capability**: Interrupted transfers can continue from last position
3. **Automatic retry**: Exponential backoff with configurable limits
4. **Patient mode**: Waits up to 30 days for offline peers
5. **Priority queue**: Urgent, high, normal, and low priorities
6. **Manual control**: Pause, resume, cancel, and retry operations
7. **Ban list**: Block specific callsigns from initiating downloads
8. **Verification**: Size and hash validation before final placement
9. **Metrics**: Comprehensive statistics and visualization
10. **EventBus integration**: Apps receive notifications on transfer events

### Design Philosophy

- **Centralized**: All apps use a single transfer service
- **Non-blocking**: Files placed at destination only after complete and verified
- **Patient**: Tolerates offline peers with extended waiting periods
- **Observable**: Real-time progress and metrics for monitoring
- **Resilient**: Automatic recovery from network failures

## Terminology

| Term | Definition |
|------|------------|
| **Transfer** | A single file being uploaded, downloaded, or streamed |
| **Queue** | Ordered list of pending transfers waiting for execution |
| **Worker** | Process that executes individual transfers |
| **Worker Pool** | Manager for concurrent transfer workers |
| **Patient Mode** | Extended waiting period for offline peers |
| **Transport** | Connection method: LAN, WebRTC, Station, BLE |
| **Callsign** | Unique identifier for a Geogram device |
| **Station** | Relay server for indirect connections |

## File Organization

### Storage Structure

Transfer data is stored in a dedicated directory:

```
{data_dir}/transfers/
├── settings.json                    # Global transfer settings
├── queue.json                       # Active and queued transfers
├── metrics.json                     # Statistics and metrics
└── history/                         # Completed transfer archives
    ├── 2025-12.json                 # Monthly history files
    ├── 2025-11.json
    └── ...
```

### Naming Conventions

- **History files**: Named by year-month `YYYY-MM.json`
- **Transfer IDs**: Format `tr_{uuid}` (e.g., `tr_abc123def456`)
- **Timestamps**: ISO 8601 format with timezone

## Configuration Files

### Global Settings

`{data_dir}/transfers/settings.json`:

```json
{
  "version": "1.0",
  "enabled": true,
  "max_concurrent_transfers": 3,
  "max_retries": 10,
  "base_retry_delay_seconds": 30,
  "max_retry_delay_seconds": 3600,
  "retry_backoff_multiplier": 2.0,
  "patient_mode_timeout_days": 30,
  "max_queue_size": 1000,
  "banned_callsigns": [],
  "updated_at": "2026-01-01T10:00:00Z"
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `version` | string | "1.0" | Settings format version |
| `enabled` | boolean | true | Whether transfer service is active |
| `max_concurrent_transfers` | integer | 3 | Maximum simultaneous transfers |
| `max_retries` | integer | 10 | Maximum retry attempts per transfer |
| `base_retry_delay_seconds` | integer | 30 | Initial retry delay |
| `max_retry_delay_seconds` | integer | 3600 | Maximum retry delay (1 hour) |
| `retry_backoff_multiplier` | double | 2.0 | Exponential backoff multiplier |
| `patient_mode_timeout_days` | integer | 30 | Days to wait for offline peers |
| `max_queue_size` | integer | 1000 | Maximum queued transfers |
| `banned_callsigns` | array | [] | Callsigns blocked from downloads |
| `updated_at` | string | - | Last settings update timestamp |

### Queue File

`{data_dir}/transfers/queue.json`:

```json
{
  "version": "1.0",
  "updated_at": "2026-01-01T12:00:00Z",
  "transfers": [
    {
      "id": "tr_abc123",
      "direction": "download",
      "source_callsign": "X1ABCD",
      "source_station_url": "https://station.example.com",
      "target_callsign": "X2BCDE",
      "remote_path": "/files/photo.jpg",
      "local_path": "/downloads/photo.jpg",
      "filename": "photo.jpg",
      "expected_bytes": 1048576,
      "expected_hash": "sha256:abc123...",
      "mime_type": "image/jpeg",
      "status": "queued",
      "priority": "normal",
      "bytes_transferred": 0,
      "retry_count": 0,
      "created_at": "2026-01-01T10:00:00Z",
      "started_at": null,
      "completed_at": null,
      "last_activity_at": null,
      "next_retry_at": null,
      "error": null,
      "transport_used": null,
      "speed_bytes_per_second": null,
      "requesting_app": "gallery",
      "metadata": {}
    }
  ]
}
```

### History Files

`{data_dir}/transfers/history/YYYY-MM.json`:

```json
{
  "version": "1.0",
  "month": "2025-12",
  "transfers": [
    {
      "id": "tr_xyz789",
      "direction": "download",
      "source_callsign": "X1ABCD",
      "target_callsign": "X2BCDE",
      "remote_path": "/files/document.pdf",
      "local_path": "/downloads/document.pdf",
      "filename": "document.pdf",
      "total_bytes": 2097152,
      "status": "completed",
      "priority": "normal",
      "created_at": "2025-12-15T14:00:00Z",
      "completed_at": "2025-12-15T14:05:00Z",
      "duration_seconds": 300,
      "transport_used": "lan",
      "average_speed_bytes_per_second": 6990.5,
      "retry_count": 0,
      "requesting_app": "files",
      "metadata": {}
    }
  ]
}
```

## Transfer Lifecycle

### States

```
[queued] --> [connecting] --> [transferring] --> [verifying] --> [completed]
    |              |               |                  |
    |              v               v                  v
    +---------> [waiting] <----+----+             [failed]
    |              |           |
    |              v           |
    +---------> [paused] <-----+
    |
    v
[cancelled]
```

| State | Description |
|-------|-------------|
| `queued` | Waiting in queue for an available worker |
| `connecting` | Establishing connection to remote peer |
| `transferring` | Active data transfer in progress |
| `verifying` | Checking integrity (size/hash) |
| `completed` | Successfully finished and file placed at destination |
| `failed` | Permanently failed after all retries exhausted |
| `cancelled` | User cancelled the transfer |
| `paused` | User paused the transfer |
| `waiting` | Waiting for offline peer (patient mode) |

### State Transitions

| From | To | Trigger |
|------|-----|---------|
| queued | connecting | Worker picks up transfer |
| queued | paused | User pauses |
| queued | cancelled | User cancels |
| connecting | transferring | Connection established |
| connecting | waiting | Peer offline |
| connecting | failed | Connection error (retries exhausted) |
| transferring | verifying | Transfer complete |
| transferring | waiting | Connection lost |
| transferring | paused | User pauses |
| transferring | cancelled | User cancels |
| verifying | completed | Verification passed |
| verifying | failed | Verification failed |
| waiting | connecting | Peer comes online |
| waiting | failed | Patient mode timeout |
| waiting | cancelled | User cancels |
| paused | queued | User resumes |
| paused | cancelled | User cancels |
| failed | queued | User retries |

## Transfer Types

### Download

Files downloaded from a remote peer to local storage.

```dart
TransferRequest(
  direction: TransferDirection.download,
  callsign: "X1ABCD",           // Source callsign
  stationUrl: "https://...",    // Optional station URL
  remotePath: "/files/doc.pdf", // Path on remote device
  localPath: "/downloads/doc.pdf", // Destination path
  expectedBytes: 1048576,       // Optional expected size
  expectedHash: "sha256:...",   // Optional hash for verification
  priority: TransferPriority.normal,
  requestingApp: "gallery",     // App that requested this
  metadata: {},                 // Optional app-specific data
)
```

### Upload

Files uploaded from local storage to a remote peer.

```dart
TransferRequest(
  direction: TransferDirection.upload,
  callsign: "X1ABCD",           // Target callsign
  stationUrl: "https://...",    // Optional station URL
  remotePath: "/inbox/doc.pdf", // Destination on remote
  localPath: "/documents/doc.pdf", // Local source path
  priority: TransferPriority.normal,
  requestingApp: "share",
  metadata: {},
)
```

### Stream

Continuous data stream (e.g., audio/video).

```dart
TransferRequest(
  direction: TransferDirection.stream,
  callsign: "X1ABCD",
  stationUrl: "https://...",
  remotePath: "/streams/audio",
  localPath: null,              // No local storage for streams
  priority: TransferPriority.high,
  requestingApp: "voip",
  metadata: {"codec": "opus", "bitrate": 64000},
)
```

## Queue Management

### Priority Ordering

Transfers are ordered by:
1. **Priority** (descending): urgent > high > normal > low
2. **Creation time** (ascending): FIFO within same priority

| Priority | Use Case |
|----------|----------|
| `urgent` | User-initiated immediate transfers |
| `high` | Interactive transfers (chat media) |
| `normal` | Background downloads (gallery sync) |
| `low` | Batch operations (backup restoration) |

### Queue Operations

```dart
// Request new transfer
Transfer transfer = await transferService.requestDownload(request);

// Query transfers
Transfer? t = transferService.getTransfer(transferId);
Transfer? t = transferService.findTransfer(callsign: "X1ABCD", remotePath: "/file.txt");
bool exists = transferService.isAlreadyRequested("X1ABCD", "/file.txt");
List<Transfer> active = transferService.getActiveTransfers();
List<Transfer> queued = transferService.getQueuedTransfers();
List<Transfer> completed = transferService.getCompletedTransfers(limit: 50);

// Control transfers
await transferService.pause(transferId);
await transferService.resume(transferId);
await transferService.cancel(transferId);
await transferService.retry(transferId);
```

## Retry Policy

### Exponential Backoff

Retry delays increase exponentially up to a maximum:

```
delay = min(base * (multiplier ^ retry_count), max_delay)
```

With defaults (base=30s, multiplier=2, max=1h):

| Retry | Delay | Cumulative Wait |
|-------|-------|-----------------|
| 1 | 30s | 30s |
| 2 | 1m | 1.5m |
| 3 | 2m | 3.5m |
| 4 | 4m | 7.5m |
| 5 | 8m | 15.5m |
| 6 | 16m | 31.5m |
| 7 | 32m | 1h 3.5m |
| 8+ | 1h | ~4h+ |

### Retry Triggers

Automatic retry occurs for:
- Connection timeout
- Connection reset
- Network unreachable
- Peer temporarily unavailable

No retry for:
- File not found (404)
- Permission denied (403)
- Invalid request (400)
- User cancellation

## Patient Mode

When a peer is offline, transfers enter "waiting" state instead of failing immediately.

### Behavior

1. Transfer attempts connection
2. Connection fails (peer offline)
3. Transfer enters `waiting` state
4. Periodic reconnection attempts (using retry backoff)
5. After `patient_mode_timeout_days`, transfer fails

### Patient Mode Settings

```json
{
  "patient_mode_timeout_days": 30
}
```

### Use Cases

- Sending files to mobile devices that are frequently offline
- Syncing with devices on slow/intermittent connections
- Backup transfers to devices behind NAT without relay

## Ban List

Block specific callsigns from downloading files.

### Usage

```dart
// Add to ban list
await transferService.banCallsign("X1ABCD");

// Remove from ban list
await transferService.unbanCallsign("X1ABCD");

// Check if banned
bool banned = transferService.isCallsignBanned("X1ABCD");
```

### Effect

When a banned callsign attempts to download:
1. Transfer request is rejected
2. `TransferFailedEvent` fired with error "callsign_banned"
3. No entry created in transfer queue

### API

```
GET    /api/transfers/banned              - List banned callsigns
POST   /api/transfers/banned              - Add to ban list
DELETE /api/transfers/banned/{callsign}   - Remove from ban list
```

## Verification

### Size Verification

All downloads verify file size after transfer:

```dart
if (transfer.expectedBytes != null) {
  if (downloadedBytes != transfer.expectedBytes) {
    // Mark as failed, trigger retry
  }
}
```

### Hash Verification

Optional SHA-256 hash verification:

```dart
if (transfer.expectedHash != null) {
  String actualHash = await computeSha256(tempFile);
  if (actualHash != transfer.expectedHash) {
    // Mark as failed, trigger retry
  }
}
```

### File Placement

Files are placed at final destination only after verification:

1. Download to temporary location: `{temp_dir}/transfer_{id}.tmp`
2. Verify size (if expected_bytes provided)
3. Verify hash (if expected_hash provided)
4. Move to final destination: `{local_path}`
5. Fire `TransferCompletedEvent`

## Protocol Messages

### Remote API Endpoints

These endpoints are exposed for peer-to-peer transfers:

#### GET /api/files/content

Download file content.

**Query Parameters:**
- `path` - File path to download

**Response:** File content with appropriate Content-Type

**Errors:**
- 404: File not found
- 403: Access denied / Callsign banned

#### POST /api/files/upload

Upload file to remote device.

**Query Parameters:**
- `path` - Destination path

**Headers:**
- `Content-Type` - File MIME type
- `Content-Length` - File size
- `X-Expected-Hash` - Optional SHA-256 hash

**Body:** File content

**Response:**
```json
{
  "success": true,
  "path": "/inbox/file.txt",
  "bytes_received": 1024
}
```

#### GET /api/files/stream/{path}

Stream file content (chunked transfer encoding).

**Response:** Chunked stream with appropriate Content-Type

### Transfer Session Protocol

For batch transfers (BLE+), transfers are grouped into sessions:

```json
{
  "type": "transfer_session_start",
  "session_id": "sess_abc123",
  "transfers": [
    {"id": "tr_001", "path": "/file1.txt", "size": 1024},
    {"id": "tr_002", "path": "/file2.txt", "size": 2048}
  ]
}
```

## API Endpoints

### Local API

#### GET /api/transfers

List transfers with optional filtering.

**Query Parameters:**
- `status` - Filter by status (comma-separated)
- `direction` - Filter by direction
- `callsign` - Filter by remote callsign
- `limit` - Maximum results (default: 50)
- `offset` - Pagination offset

**Response:**
```json
{
  "transfers": [...],
  "total": 150,
  "limit": 50,
  "offset": 0
}
```

#### GET /api/transfers/{id}

Get single transfer details.

#### POST /api/transfers

Request new transfer.

**Request:**
```json
{
  "direction": "download",
  "callsign": "X1ABCD",
  "remote_path": "/files/doc.pdf",
  "local_path": "/downloads/doc.pdf",
  "priority": "normal",
  "requesting_app": "files"
}
```

**Response:**
```json
{
  "id": "tr_abc123",
  "status": "queued",
  "position": 5
}
```

#### DELETE /api/transfers/{id}

Cancel transfer.

#### PUT /api/transfers/{id}/pause

Pause transfer.

#### PUT /api/transfers/{id}/resume

Resume paused transfer.

#### PUT /api/transfers/{id}/retry

Retry failed transfer.

#### GET /api/transfers/settings

Get transfer settings.

#### PUT /api/transfers/settings

Update transfer settings.

#### GET /api/transfers/metrics

Get transfer statistics.

**Response:**
```json
{
  "active_transfers": 2,
  "active_connections": 3,
  "queued_transfers": 5,
  "current_speed_bytes_per_second": 2621440,
  "today": {
    "upload_count": 15,
    "download_count": 42,
    "bytes_uploaded": 104857600,
    "bytes_downloaded": 524288000,
    "success_rate": 0.95
  }
}
```

## EventBus Integration

The Transfer service fires events on the EventBus for app notifications.

### Events

#### TransferRequestedEvent

Fired when a new transfer is requested.

```dart
class TransferRequestedEvent extends AppEvent {
  String transferId;
  TransferEventDirection direction;
  String callsign;
  String path;
  String? requestingApp;
}
```

#### TransferProgressEvent

Fired periodically during active transfers.

```dart
class TransferProgressEvent extends AppEvent {
  String transferId;
  TransferStatus status;
  int bytesTransferred;
  int totalBytes;
  double? speedBytesPerSecond;
  Duration? eta;
}
```

#### TransferCompletedEvent

Fired when transfer completes successfully.

```dart
class TransferCompletedEvent extends AppEvent {
  String transferId;
  TransferEventDirection direction;
  String callsign;
  String localPath;
  int totalBytes;
  Duration duration;
  String transportUsed;
  String? requestingApp;
  Map<String, dynamic>? metadata;
}
```

#### TransferFailedEvent

Fired when transfer fails.

```dart
class TransferFailedEvent extends AppEvent {
  String transferId;
  TransferEventDirection direction;
  String callsign;
  String path;
  String error;
  bool willRetry;
  DateTime? nextRetryAt;
  String? requestingApp;
}
```

#### TransferCancelledEvent

Fired when user cancels a transfer.

```dart
class TransferCancelledEvent extends AppEvent {
  String transferId;
  String? requestingApp;
}
```

#### TransferPausedEvent

Fired when user pauses a transfer.

```dart
class TransferPausedEvent extends AppEvent {
  String transferId;
}
```

#### TransferResumedEvent

Fired when user resumes a transfer.

```dart
class TransferResumedEvent extends AppEvent {
  String transferId;
}
```

### Subscribing to Events

Apps can subscribe to transfer events:

```dart
eventBus.on<TransferCompletedEvent>((event) {
  if (event.requestingApp == 'gallery') {
    // Handle gallery download completion
    refreshGallery(event.localPath);
  }
});
```

## Metrics & Statistics

### Real-Time Metrics

```dart
class TransferMetrics {
  int activeConnections;           // Current open connections
  int activeTransfers;             // Currently transferring
  int queuedTransfers;             // Waiting in queue
  double currentSpeedBytesPerSecond; // Aggregate speed

  TransferPeriodStats today;
  TransferPeriodStats thisWeek;
  TransferPeriodStats thisMonth;
  TransferPeriodStats allTime;

  Map<String, TransportStats> byTransport;
  List<CallsignStats> topCallsigns;
}
```

### Period Statistics

```dart
class TransferPeriodStats {
  int uploadCount;
  int downloadCount;
  int streamCount;
  int bytesUploaded;
  int bytesDownloaded;
  int failedCount;
  Duration totalTransferTime;
  double averageSpeedBytesPerSecond;
  double successRate;  // 0.0 - 1.0
}
```

### Transport Statistics

```dart
class TransportStats {
  String transportId;  // lan, webrtc, station, ble
  int transferCount;
  int bytesTransferred;
  double averageSpeed;
  double successRate;
}
```

### Callsign Statistics

```dart
class CallsignStats {
  String callsign;
  int uploadCount;
  int downloadCount;
  int bytesUploaded;
  int bytesDownloaded;
  DateTime lastActivity;
}
```

### Metrics Storage

`{data_dir}/transfers/metrics.json`:

```json
{
  "version": "1.0",
  "updated_at": "2026-01-01T12:00:00Z",
  "all_time": {
    "upload_count": 1234,
    "download_count": 5678,
    "stream_count": 89,
    "bytes_uploaded": 10737418240,
    "bytes_downloaded": 53687091200,
    "failed_count": 45,
    "first_transfer_at": "2025-06-15T10:00:00Z"
  },
  "daily": {
    "2026-01-01": {
      "upload_count": 12,
      "download_count": 34,
      "bytes_uploaded": 104857600,
      "bytes_downloaded": 524288000,
      "failed_count": 2,
      "history": [
        {"hour": 0, "bytes": 10485760, "connections": 2},
        {"hour": 1, "bytes": 5242880, "connections": 1}
      ]
    }
  },
  "by_callsign": {
    "X1ABCD": {
      "upload_count": 50,
      "download_count": 120,
      "bytes_uploaded": 524288000,
      "bytes_downloaded": 1073741824,
      "last_activity": "2026-01-01T11:30:00Z"
    }
  },
  "by_transport": {
    "lan": {"count": 500, "bytes": 10737418240, "success_rate": 0.98},
    "webrtc": {"count": 200, "bytes": 2147483648, "success_rate": 0.85},
    "station": {"count": 150, "bytes": 1073741824, "success_rate": 0.92},
    "ble": {"count": 50, "bytes": 52428800, "success_rate": 0.80}
  }
}
```

## Error Handling

### Common Errors

| Error Code | Description | Retry? |
|------------|-------------|--------|
| `connection_timeout` | Connection attempt timed out | Yes |
| `connection_refused` | Remote peer refused connection | Yes |
| `peer_offline` | Remote peer is offline | Yes (patient mode) |
| `file_not_found` | Remote file does not exist | No |
| `permission_denied` | Access denied to remote file | No |
| `callsign_banned` | Callsign is on ban list | No |
| `size_mismatch` | Downloaded size != expected | Yes |
| `hash_mismatch` | Hash verification failed | Yes |
| `disk_full` | Local disk space exhausted | No |
| `cancelled` | User cancelled transfer | No |
| `patient_timeout` | Patient mode timeout exceeded | No |

### Error Recovery

1. **Transient errors**: Automatic retry with backoff
2. **Permanent errors**: Mark failed, notify requesting app
3. **Partial downloads**: Resume from last position on retry
4. **Verification failures**: Delete temp file, retry from start

## Security Considerations

### Authentication

- All P2P transfers authenticated via ConnectionManager
- Station relay transfers use NOSTR signatures
- API endpoints require local authentication

### Authorization

- Ban list prevents unauthorized downloads
- Apps can only access their own transfer metadata
- Remote file access controlled by file permissions

### Data Integrity

- Optional SHA-256 hash verification
- Size verification for all transfers
- Atomic file placement (temp -> final)

### Privacy

- Transfer history stored locally only
- Metrics aggregated, no detailed logs shared
- Callsign statistics kept private

### Resource Limits

- Queue size limits prevent memory exhaustion
- Concurrent transfer limits prevent bandwidth monopolization
- Automatic cleanup of stale transfers

## Related Documentation

- [Data Transmission](../data-transmission.md) - ConnectionManager details
- [EventBus](../EventBus.md) - Event system documentation
- [Backup Format Specification](./backup-format-specification.md) - Similar app pattern

## Change Log

### Version 1.0 (2026-01-01)

- Initial specification
- Core transfer functionality (upload/download/stream)
- Priority queue with exponential backoff retry
- Patient mode for offline peers
- Ban list management
- Verification (size and hash)
- EventBus integration
- Comprehensive metrics and statistics
- Full UI with Active/Queued/Completed/Failed/Stats views

---

*This specification is part of the Geogram project.*
*License: Apache-2.0*
