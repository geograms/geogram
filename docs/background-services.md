# Geogram Background Services & Tasks

Complete inventory of all processes, timers, isolates, and streams that run after app launch.

**Last Updated**: 2026-03-22

## Startup Sequence

### Phase 1: Blocking (before UI renders)

| # | Service | What |
|---|---------|------|
| 1 | CrashService | Crash recovery detection |
| 2 | StorageConfig | Base directory setup |
| 3 | ConfigService | App config from JSON |
| 4 | I18nService | Load 4368 translations |
| 5 | AppThemeService | Theme init |
| 6 | AppService | Core storage, profile storage |
| 7 | ProfileService | Load active profile |
| 8 | NotificationService | Badge counts |
| 9 | ChatNotificationService | Unread chat counts |
| 10 | StationContentNotificationService | Blog/events in Now feed |
| 11 | StationChatQueueService | Queued chat delivery |
| 12 | StationActivityPublisherService | Queued feed updates |
| 13 | DMNotificationService | Push notification setup |
| 14 | BackupNotificationService | Backup alerts |
| 15 | MessageAttentionService | Message attention |
| 16 | **MeetingTranscriptionService** | Wires auto-transcription (triggers on AppStartedEvent after 10s) |
| 17 | TrayService | System tray (desktop) |
| 18 | UsbAttachmentService | USB ESP32 detection (Android) |
| 19 | FileViewerService | File intent handler (Android) |
| 20 | FileIndexService | Starts background file indexing (5s delay) |

### Phase 2: Deferred (after first frame, via addPostFrameCallback)

| # | Service | Starts | Timer |
|---|---------|--------|-------|
| 21 | UserLocationService | GPS/IP location | **5 min** periodic |
| 22 | ConnectionManager | 7 transports registered | Queue: **30s** |
| 23 | UpdateService | App update checks | Periodic |
| 24 | StationDiscoveryService | LAN device scanning | **5 min** |
| 25 | **P2PService (DHT)** | BitTorrent DHT bootstrap + announce | **2s** start, **2 min** refresh |
| 26 | LogApiService | HTTP API on port 3456 | — |
| 27 | DevicesService | BLE + USB + station subs | **2 hour** cleanup |
| 28 | StationService | WebSocket to station | — |
| 29 | NetworkMonitorService | LAN/internet check | **10s** fg / **60s** bg |
| 30 | BackupService | E2E encrypted backups | Provider announce periodic |
| 31 | DMQueueService | Queued DM delivery | **10s** |
| 32 | MessageRetentionService | Purge expired DMs | **30 min** |
| 33 | ConferenceService | Scheduled meeting timers | — |
| 34 | GroupSyncService | Folder chat rooms | One-shot |
| 35 | ProximityDetectionService | BLE + GPS proximity | **60s** fg / **120s** bg |
| 36 | NowService | Feed expiry | **60s** |

### Phase 2b: Teleport Bridges (if enabled, auto-start)

| # | Service | Timers | Memory |
|---|---------|--------|--------|
| 37 | AprsService | Background TCP | Moderate |
| 38 | IrcService | **500ms** UI + **2s** write flush | Moderate |
| 39 | XmppService | **500ms** UI + **2s** write flush | Moderate |
| 40 | NostrClientService | Background WebSocket | Moderate |
| 41 | **AtprotoClientService** | **6 timers**: 5min/20s/60s/10s/15min/2min | **Heavy** |
| 42 | MeshCoreService | Background | Low |
| 43 | BitchatService | Background BLE mesh | Low |
| 44 | MeshtasticService | Background LoRa | Low |

## All Registered Task Monitor Timers

Sorted by frequency (most active first):

| Timer ID | Type | Interval | Service |
|----------|------|----------|---------|
| `network_monitor.lan_check` | AsyncPeriodic | **10s** (fg) / 60s (bg) | NetworkMonitorService |
| `dm_queue.process` | AsyncPeriodic | **10s** | DMQueueService |
| `atproto.client.feed_sync` | AsyncPeriodic | **20s** | AtprotoClientService |
| `atproto.client.queue_flush` | AsyncPeriodic | **10s** | AtprotoClientService |
| `websocket.reconnect` | Periodic | **10s** | WebSocketService |
| `ble_identity.advertise` | Periodic | **30s** | BLEIdentityService |
| `websocket.ping` | Periodic | **30s** | WebSocketService |
| `connection_manager.queue` | AsyncPeriodic | **30s** (fg) / 60-120s (bg) | ConnectionManager |
| `encrypted_storage.flush` | Periodic | **30s** | EncryptedStorageService |
| `station_node.stats` | Periodic | **30s** | StationNodeService |
| `ble_discovery.scan` | Periodic | **45s** (fg) / 120s (bg) | BLEDiscoveryService |
| `irc.ui_update` | Periodic | **500ms** | IrcService |
| `xmpp.ui_update` | Periodic | **500ms** | XmppService |
| `now.expiry_check` | Periodic | **60s** | NowService |
| `atproto.client.notify_relays` | AsyncPeriodic | **60s** | AtprotoClientService |
| `irc.write_flush` | AsyncPeriodic | **2s** | IrcService |
| `xmpp.write_flush` | AsyncPeriodic | **2s** | XmppService |
| `atproto.client.repo_checkpoint` | AsyncPeriodic | **2 min** | AtprotoClientService |
| `atproto.client.session_refresh` | AsyncPeriodic | **5 min** | AtprotoClientService |
| `atproto.client.cache_prune` | AsyncPeriodic | **15 min** | AtprotoClientService |
| `station_discovery.scan` | AsyncPeriodic | **5 min** | StationDiscoveryService |
| `user_location.refresh` | AsyncPeriodic | **5 min** | UserLocationService |
| `xmpp_s2s.idle_check` | Periodic | **5 min** | XMPP S2S |
| `xmpp_s2s.keepalive` | Periodic | **5 min** | XMPP S2S |
| `message_retention.cleanup` | AsyncPeriodic | **30 min** | MessageRetentionService |
| `file_index.background_scan` | AsyncPeriodic | **1 hour** | FileIndexService |
| `devices.cleanup` | AsyncPeriodic | **2 hours** | DevicesService |
| `mirror_sync.auto` | AsyncPeriodic | Configurable | MirrorAutoSyncService |
| `update.periodic_check` | AsyncPeriodic | Configurable | UpdateService |
| `backup.provider_announce` | AsyncPeriodic | Configurable | BackupService |
| `local_backup.auto` | AsyncPeriodic | Configurable | LocalBackupService |
| `station_alert.poll` | AsyncPeriodic | Configurable | StationAlertService |
| `ble_queue.housekeeping` | Periodic | Configurable | BLEQueueService |
| `p2p_discovery.dht` | IsolateHandle | — | P2PService |

## Isolate/Thread Handles

| Handle ID | Service | Actual Isolate? |
|-----------|---------|-----------------|
| `p2p_discovery.dht` | P2PService | No — runs on main isolate |
| `aprs.is_client` | AprsService | Yes — TCP receive loop |
| `irc.*` | IrcService | Yes — per-server |
| `nostr.*` | NostrClientService | Yes — per-relay |
| `signal.client` | SignalClient | Yes |
| `telegram.receive_loop` | TdlibClient | Yes — FFI |
| `wasm.*` | WasmClient | Yes — FFI |
| `path_recording.tracker` | PathRecordingService | Yes |
| `meeting_transcription.transcribe` | MeetingTranscriptionService | One-shot task |
| `sync_transfer.*` | SyncTransferService | One-shot task |

## Stream Subscriptions (Service-Level)

| Service | Stream | Purpose |
|---------|--------|---------|
| DevicesService | BLE device updates | Device list |
| DevicesService | BLE chat messages | Chat relay |
| DevicesService | USB connection state | USB detection |
| DevicesService | USB callsign | USB device ID |
| DevicesService | Station connection events | Online/offline |
| DevicesService | Profile change events | Identity switch |
| DevicesService | Debug actions | Debug API |
| BLEDiscoveryService | Bluetooth adapter state | On/off |
| BLEDiscoveryService | BLE scan results | Device discovery |
| BLEDiscoveryService | Power mode changes | Scan interval |
| WebSocketService | WebSocket messages | Station comms |
| ProximityDetectionService | GPS location | Position updates |
| ProximityDetectionService | Power mode | Interval adjust |
| ConferenceService | Station connection | Re-announce |
| P2PService | DHT peer found | Peer discovery |

## Whisper / Speech-to-Text

**MeetingTranscriptionService** wires into `AppStartedEvent` at startup (line 499 in main.dart). After a 10-second delay, it scans for untranscribed meeting recordings and starts transcribing them one by one.

When transcription runs:
1. Downloads Whisper model from HuggingFace if needed (~140MB for base model)
2. Loads model into memory via FFI (~310MB heap for base model)
3. Extracts audio from MP4 → WAV
4. Runs Whisper inference in a separate isolate

The model stays loaded after first transcription. On a device with limited RAM, this alone can consume 300-400MB.

**SpeechToTextService** logs confirm model loading happens at startup if there are pending transcriptions:
```
whisper_model_load: model size = 140.54 MB
whisper_model_load: mem required = 310.00 MB (+ 6.00 MB per decoder)
```

## Memory Budget (Android)

Typical Android app gets ~256-512MB heap depending on device. With all services:

| Component | Estimate |
|-----------|----------|
| Flutter framework + UI | ~80MB |
| Shelf HTTP server | ~5MB |
| BLE scanning | ~10MB |
| WebSocket + TLS | ~15MB |
| SQLite databases | ~10MB |
| DHT (if active) | ~6MB |
| Whisper model (if loaded) | **~310MB** |
| Teleport bridges (if active) | ~20-50MB |
| **Total without Whisper** | **~130MB** |
| **Total with Whisper** | **~440MB** |

The Whisper model is the elephant. On low-RAM devices, it must not auto-load at startup.
