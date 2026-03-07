# Reusable Widgets and Components

This document catalogs reusable UI components available in the Geogram codebase. These widgets are designed to be used across multiple features and pages.

## Index

### Picker Widgets
- [UserPickerWidget](#userpickerwidget) - Select users from devices
- [CurrencyPickerWidget](#currencypickerwidget) - Select currencies
- [TypeSelectorWidget](#typeselectorwidget) - Select inventory types
- [FileFolderPicker](#filefolderpicker) - Full-featured file and folder picker

### Notification Helpers
- [BackupNotificationService](#backupnotificationservice) - Backup event notifications
- [Notification Tap Handling Pattern](#notification-tap-handling-pattern) - Handle notification taps

### Web Components
- [NostrLoginComponent](#nostrlogincomponent) - Reusable Nostr login with NIP-07 extension + client-side key generation
- [NostrToolsBundle](#nostrtoolsbundle) - Embedded nostr-tools JS bundle for client-side signing

### Map & Navigation
- [RoutingService](#routingservice) - Offline A* routing with cached OSM road data
- [RoadHandler](#roadhandler) - Station endpoint for road data (Overpass API cache)
- [launchExternalNavigator](#launchexternalnavigator) - Open external maps app (Android/iOS/Desktop)
- [RouteResult](#routeresult) - Route calculation result (polyline, distance, duration)
- [MapTileService.getStationBaseUrl](#maptileservicegetstationbaseurl) - Station HTTP base URL (reusable for tiles and road data)

### Cross-Platform Patterns
- [Platform-Adaptive WebView](#platform-adaptive-webview) - Render local HTML with JS on all platforms
- [URL-Linkified SelectableText](#url-linkified-selectabletext) - Make URLs clickable in text widgets
- [Command Registry](#command-registry) - Self-describing console commands shared across CLI and Desktop
- [Navigation Handler](#navigation-handler) - Shared virtual filesystem navigation (cd/ls/pwd) with `/chat/<station>/<room>` hierarchy
- [ConsoleCommandMixin](#consolecommandmixin) - Shared /api/cli implementation for station servers
- [ChatModerationMixin](#chatmoderationmixin) - Shared global moderator management and API response helpers
- [ChatModificationMixin](#chatmodificationmixin) - Shared NOSTR auth verification for chat message edit/delete (NIP-09 + legacy)
- [ChatNip05Mixin](#chatnip05mixin) - Shared NIP-05 registration for chat message senders
- [Nip05RegistryService.buildNostrJsonResponse](#nip05registryservicebuildnostrjsonresponse) - Build NIP-05 nostr.json response (used by all station handlers)

### Conference Components (SFU Star Topology)
- [ConferenceMixin](#conferencemixin) - Station-side conference signaling relay (shared mixin)
- [ConferenceSignalingServer](#conferencesignalingserver) - Host-side HTTP+WS signaling server (LAN mode)
- [ConferenceHostPeerManager](#conferencehostpeermanager) - Host-side SFU WebRTC manager (one connection per participant, track forwarding)
- [ConferenceParticipantPeerManager](#conferenceparticipantpeermanager) - Participant-side SFU WebRTC manager (single connection to host)
- [ConferencePeerManager](#conferencepeermanager) - Legacy audio WebRTC mesh peer connections (deprecated)
- [ConferenceService](#conferenceservice) - Orchestration (SFU topology, host/join, role management, promote/demote)

### Karma Gamification
- [KarmaMixin](#karmamixin) - Station mixin: `karmaRecord()`, API handlers, periodic leaderboard recomputation
- [KarmaEngine](#karmaengine) - Pure business logic: point values, daily caps, streak multipliers, levels, validation
- [KarmaStore](#karmastore) - File I/O: append-only JSONL event logs, cached profiles, streaks, leaderboards
- [KarmaLeaderboard](#karmaleaderboard) - Leaderboard computation and caching for weekly/monthly/yearly/alltime
- [KarmaPage](#karmapage) - Client-side dashboard: level, streak, daily progress, category cards, leaderboard
- [KarmaApi](#karmaapi) - Client-side API wrapper for karma endpoints

### API Handlers (Shared between CLI and Desktop stations)
- [AppsHandler](#appshandler) - Aggregated app discovery (`GET /api/apps`) — returns availability + counts for blog, chat, events, alerts, shared in a single call

### Shared Folder Components
- [SharedFolder Model](#sharedfolder-model) - Data model for shared folder entries (JSON serialization, visibility)
- [SharedFolderService](#sharedfolderservice) - ProfileStorage CRUD for shared folder entries
- [SharedBrowserPage](#sharedbrowserpage) - List, add, edit, delete shared folders; opens FilesBrowserPage

### Background Task Infrastructure
- [Background Task Monitor](#background-task-monitor) - Centralized registry for all background tasks with pause/resume and debug API

### APRS Components
- [APRS Message Utils](#aprsmessageutils) - Constants, text splitting, and display merging for APRS messages
- [APRS Geo-Chat Panel](#aprs-geo-chat-panel) - Floating map overlay for sending/receiving position reports with comments
- [BlueAprsService](#blueaprsservice) - APRS over BLE bridge (iGate + repeater)
- [BLEAprsPayload](#bleaprspayload) - Structured APRS data model for BLE transport

### MeshCore Components
- [MeshCore Protocol Codec](#meshcore-protocol-codec) - Pure Dart binary encode/decode for MeshCore BLE commands (CLI-reusable)
- [MeshCore BLE Client](#meshcore-ble-client) - Nordic UART BLE transport with scan, connect, send/receive
- [MeshCore Message Bubble](#meshcore-message-bubble) - Chat bubble with SNR indicator and ACK checkmark

### BitChat Components
- [BitChat Protocol](#bitchat-protocol) - Pure Dart binary encode/decode for BitChat mesh packets (CLI-reusable)
- [BitChat BLE Client](#bitchat-ble-client) - Multi-peer BLE transport with mesh relay
- [BitChat Service](#bitchat-service) - Singleton with event stream, bloom filter dedup, batch writes
- [BitChat Message Bubble](#bitchat-message-bubble) - Chat bubble with hop count indicator and delivery status

### Meshtastic Components
- [Meshtastic Protobuf Codec](#meshtastic-protobuf-codec) - Hand-coded protobuf encoder/decoder for Meshtastic wire format (pure Dart, CLI-reusable)
- [Meshtastic Crypto](#meshtastic-crypto) - AES256-CTR channel encryption with PSK expansion (pure Dart, CLI-reusable)
- [Meshtastic BLE Client](#meshtastic-ble-client) - Meshtastic BLE transport with two-step notification model
- [Meshtastic Service](#meshtastic-service) - Singleton with config dump flow, packet routing, node database
- [Meshtastic Message Bubble](#meshtastic-message-bubble) - Chat bubble with SNR, RSSI, hop count badges

### Pure Dart Utilities
- [Geohash](#geohash) - Geohash encode/decode/neighbors (pure Dart, CLI-reusable)
- [Noise XX Handshake](#noise-xx-handshake) - Noise Protocol XX pattern using cryptography package
- [Bloom Filter](#bloom-filter) - Probabilistic set membership for message dedup

### Hashing Utilities
- [TLSH (Locality Sensitive Hash)](#tlsh-locality-sensitive-hash) - Fuzzy similarity hashing for binary data
- [SHA1 Content Hashing](#sha1-content-hashing) - Exact content deduplication via crypto package

### Viewer Pages
- [PhotoViewerPage](#photoviewerpage) - Image & video gallery
- [LocationPickerPage](#locationpickerpage) - Map location selection
- [PlacePickerPage](#placepickerpage) - Place selection with sorting
- [ContactPickerPage](#contactpickerpage) - Contact selection with sorting
- [DocumentViewerWidget](#documentviewerwidget) - Embeddable document viewer (no Scaffold)
- [DocumentViewerEditorPage](#documentviewereditorpage) - PDF, text, markdown viewer
- [ContractDocumentPage](#contractdocumentpage) - Markdown document viewer
- [NostrUserProfilePage](#nostruserprofilepage) - NOSTR profile view with follow/unfollow and posts

### Player Widgets
- [VoicePlayerWidget](#voiceplayerwidget) - Voice messages
- [MusicPlayerWidget](#musicplayerwidget) - Music tracks
- [VoiceRecorderWidget](#voicerecorderwidget) - Record voice
- [MiniPlayerWidget](#miniplayerwidget) - Music mini player bar
- [NowPlayingWidget](#nowplayingwidget) - Full-screen music player

### Music Widgets
- [TrackTileWidget](#tracktilewidget) - Music track list tile
- [AlbumCardWidget](#albumcardwidget) - Album grid card
- [ArtistCardWidget](#artistcardwidget) - Artist grid card

### Dialog Widgets
- [NewChannelDialog](#newchanneldialog) - Create chat channels
- [NewThreadDialog](#newthreaddialog) - Create forum threads
- [AddTrackableDialog](#addtrackabledialog) - Add exercise or measurement entries

### Selector Widgets
- [CallsignSelectorWidget](#callsignselectorwidget) - Profile switching
- [ProfileSwitcher](#profileswitcher) - App bar profile

### Map Widgets
- [TrackerMapCard](#trackermapcard) - Reusable satellite map miniature
- [StaticMapService](#staticmapservice) - Generate static map images from coordinates using cached tiles

### Tree Widgets
- [FolderTreeWidget](#foldertreewidget) - Folder navigation

### Code Utilities
- [SyntaxHighlightController](#syntaxhighlightcontroller) - TextEditingController with live syntax coloring
- [convertNodesToSpans](#convertnodetospans) - Convert highlight.js nodes to Flutter TextSpan list

### Garmin Watch App (Monkey C)
- [GeoUtils module](#geoutils-module) - Haversine distance, bearing, cardinal direction, coordinate formatting
- [DrawUtils module](#drawutils-module) - Word wrapping, severity colors for Garmin views
- [BaseListView](#baselistview) - Scrollable list with header, states, selection for Garmin
- [DataStore module](#datastore-module) - Settings + cached data via Application.Storage
- [StationClient](#stationclient-garmin) - HTTP client for station API (makeWebRequest)
- [ProximityChecker](#proximitychecker) - Background service for geo-fence alerts

### QR Code Widgets
- [QrPreviewWidget](#qrpreviewwidget) - QR code preview with customizations

### Message Widgets
- [MessageBubbleWidget](#messagebubblewidget) - Chat bubbles
- [MessageInputWidget](#messageinputwidget) - Message composer

### Services
- [LocationService](#locationservice) - City lookup from coordinates
- [LocationProviderService](#locationproviderservice) - Shared GPS positioning for all apps
- [PathRecordingService](#pathrecordingservice) - GPS path recording (uses LocationProviderService)
- [PlaceService.findPlacesWithinRadius](#placeservicefindplaceswithinradius) - Find places within GPS radius
- [CollectionService.generateBlogCache](#collectionservicegenerateblogcache) - Generate blog posts cache
- [StunServerService](#stunserverservice) - Self-hosted STUN server for WebRTC NAT traversal
- [VideoMetadataExtractor](#videometadataextractor) - Video metadata and thumbnail generation using media_kit
- [DirectMessageService Message Cache](#directmessageservice-message-cache) - DM message caching for performance
- [ChatFileDownloadManager](#chatfiledownloadmanager) - Connection-aware file downloads with progress and resume
- [TransferService](#transferservice) - Centralized multi-transport transfers with caching and resume
- [MirrorSyncService](#mirrorsyncservice) - Simple one-way folder sync with NOSTR authentication
- [MirrorAutoSyncService](#mirrorautosyncservice) - Periodic auto-sync timer with station relay fallback
- [DnsResponder](#dnsresponder) - Captive portal DNS responder (UDP port 53, resolves all queries to gateway IP)
- [HotspotPortalService](#hotspotportalservice) - Captive portal HTTP server with portal home page and download page
- [Hotspot Toggle Pattern](#hotspot-toggle-pattern) - Shared Wi-Fi Direct hotspot toggle logic (used by station_dashboard_page and hotspot_settings_page)
- [NostrClientService.searchFeed](#nostrclientservicesearchfeed) - Search in-memory NOSTR feed items
- [NostrClientService.followUser/unfollowUser/likeEvent](#nostrclientservicefollowuserunfollowuserlikeevent) - Follow/unfollow users and like posts
- [NostrNip19.decode](#nostrnip19decode) - Decode nostr: URIs (note/npub/nevent/nprofile/naddr)
- [GeogramApi](#geogramapi) - Unified transport-agnostic API facade
- [MessageRetentionService](#messageretentionservice) - Shared message retention/auto-delete logic for DMs and group chat
- [RetentionPickerWidget](#retentionpickerwidget) - Reusable retention period picker dialog
- [FileBrowserCacheService](#filebrowsercacheservice) - Persistent cache for file browser operations
- [SQLiteLoader](#sqliteloader) - Platform-aware SQLite database loading
- [BackupEncryption (ECIES)](#backupencryption-ecies) - ECIES encryption for arbitrary data using npub/nsec
- [EmailRelayService Callbacks](#emailrelayservice-callbacks) - Reusable callback pattern for email routing
- [EmailRelayService Encrypted Cache](#emailrelayservice-encrypted-cache) - SQLite + ECIES offline email storage
- [ProfileStorage](#profilestorage) - Abstraction layer for encrypted/filesystem storage
- [TrayService](#trayservice) - System tray icon with minimize-to-tray and restore
- [AprsIsClient](#aprsisclient) - APRS-IS TCP client with TNC2 parsing
- [AprsIsClient.sendOneShot](#sendoneshot-standalone-one-shot-sender) - Standalone one-shot APRS-IS message sender
- [IrcClient](#ircclient) - IRC protocol client with background isolate TCP/TLS
- [IrcService](#ircservice) - Multi-server IRC singleton service with event stream
- [IrcMessageBubble](#ircmessagebubble) - Dark-mode IRC message bubble
- [XmppClient](#xmppclient) - XMPP protocol client wrapping whixp (STARTTLS, SASL, MUC)
- [XmppService](#xmppservice) - Multi-server XMPP singleton service with event stream
- [XmppMessageBubble](#xmppmessagebubble) - Dark-mode XMPP message bubble

### Desktop Patterns
- [Desktop Platform Guard](#desktop-platform-guard) - Reusable check for Linux/Windows/macOS

### USB/Transport Services
- [UsbAoaService](#usbaoapservice) - Cross-platform USB AOA service layer
- [UsbAoaLinux](#usbaoaplinux) - Linux USB host FFI implementation
- [UsbAoaTransport](#usbaoapransport) - USB transport for message delivery

### Reader Services
- [RssService](#rssservice) - RSS/Atom feed parsing and HTML-to-Markdown conversion
- [MangaService](#mangaservice) - CBZ extraction and chapter creation
- [SourceService](#sourceservice) - Source.js discovery and parsing
- [ReaderService](#readerservice) - Main reader service orchestrating all content types

### Installer Patterns
- [Installer Registry Pattern](#installer-registry-pattern) - Package registry JSON management
- [JSON Widget Tree Renderer](#json-widget-tree-renderer) - Render JSON-described UI as Flutter widgets
- [JS Sandbox API Bridge](#js-sandbox-api-bridge) - Host API injection for QuickJS contexts
- [Extension Hook System](#extension-hook-system) - Plugin registration and lifecycle for core apps
- [Manifest Validation](#manifest-validation) - Package manifest schema validation
- [Folder Name Collision Check](#folder-name-collision-check) - Validate against reserved app type names

### Flasher Components
- [FlasherService](#flasherservice) - Main service for flash operations
- [FlasherStorageService](#flasherstorageservice) - Device definitions storage (v1.0 and v2.0)
- [FirmwareTreeWidget](#firmwaretreewidget) - Hierarchical firmware library tree view
- [SelectedFirmwareCard](#selectedfirmwarecard) - Selected firmware display card
- [FirmwareVersion](#firmwareversion) - Firmware version model with metadata
- [ProtocolRegistry](#protocolregistry) - Protocol factory
- [DeviceCard](#devicecard-widget) - Device selection card
- [FlashProgressWidget](#flashprogresswidget) - Progress display

### Work App Components
- [WorkStorageService](#workstorageservice) - Workspace storage management
- [NdfService](#ndfservice) - NDF document parsing and creation
- [Workspace](#workspace-model) - Workspace model with collaborators
- [NdfDocument](#ndfdocument-model) - NDF document metadata model
- [NdfPermission](#ndfpermission-model) - NDF permissions and access control
- [NdfImageEmbedBuilder](#ndfimageembedbuilder) - Custom QuillEditor image embed for asset:// URLs
- [PresentationContent](#presentationcontent-model) - Presentation content models (slides, elements, theme)
- [SlideTemplate](#slidetemplate) - Predefined slide templates (Cyber, Retro80s, Black&White, etc.)
- [SlideCanvasWidget](#slidecanvaswidget) - Renders slide at proper aspect ratio
- [Inline Text Editing Pattern](#inline-text-editing-pattern) - WYSIWYG inline text editing in canvas widgets
- [SlideThumbnailWidget](#slidethumbnailwidget) - Slide preview thumbnail for panel
- [SheetGridWidget](#sheetgridwidget) - Reusable spreadsheet grid with formulas
- [TodoContent](#todocontent-model) - TODO content models (items, links, updates, settings)
- [TodoItemCardWidget](#todoitemcardwidget) - Expandable TODO item card with pictures/links/updates
- [NDF Logo and Thumbnail Embedding](#ndf-logo-and-thumbnail-embedding) - Embed and read logos/thumbnails from NDF documents

### API Common Utilities
- [GeometryUtils](#geometryutils) - Haversine distance calculation between coordinates
- [FileTreeBuilder](#filetreebuilder) - Recursive file tree for sync operations
- [StationInfo](#stationinfo) - Station metadata for API responses

### Server Chat Models
- [ServerChatRoom](#serverchatroom) - Server-side chat room management
- [ServerChatMessage](#serverchatmessage) - Server-side message with NOSTR signatures

### CLI/Console Abstractions
- [ConsoleIO](#consoleio) - Platform-agnostic console I/O interface
- [ConsoleHandler](#consolehandler) - Shared command logic for CLI/UI/Telegram
- [ConsoleCompleter](#consolecompleter) - Shared TAB completion logic
- [LogService Isolate Reading](#logservice-isolate-reading) - Read large logs off UI thread

### Web Theme Components
- [WebNavigation](#webnavigation) - Reusable navigation menu generator (shared library)
- [getChatPageScripts](#getchatpagescripts) - Reusable chat page JavaScript (shared library)

### QR Widgets
- [QrShareReceiveWidget](#qrsharereceivewidget) - Share/receive data via QR
- [QrCodeService](#qrcodeservice) - Storage/CRUD for QR codes and barcodes
- [QrCode Model](#qrcode-model) - QR code data model with format types

### Speech Input Widgets
- [TranscribeButtonWidget](#transcribebuttonwidget) - Voice-to-text for text fields
- [TtsPlayerWidget](#ttsplayerwidget) - Text-to-speech playback

### Constants
- [App Constants](#app-constants) - Centralized app type definitions
- [App Type Theme](#app-type-theme) - Centralized icons and gradients for app types

### Platform Helpers
- [file_image_helper](#file_image_helper) - Platform-aware file and memory image loading

### AT Protocol Core (lib/atproto/)
- [DagCbor](#dagcbor) - Deterministic CBOR encoder/decoder (DAG-CBOR with sorted keys, CID tag 42)
- [Cid](#cid) - CID v1 content identifiers (SHA-256, base32lower, bytes/string round-trip)
- [MerkleSearchTree](#merklesearchtree) - MST for content-addressed key-value storage
- [CarWriter / CarReader](#carwriter--carreader) - CAR v1 archive format read/write
- [Tid](#tid) - Timestamp ID generator (13-char base32-sortable)
- [AtprotoSigning](#atprotosigning) - ECDSA-secp256k1 signing with low-S normalization and Multikey encoding
- [AtprotoStorage](#atprotostorage) - SQLite block store implementing MstBlockStore
- [AtprotoRepo](#atprotorepo) - Repository manager (MST + signing + storage + CAR export)
- [XrpcRouter](#xrpcrouter) - XRPC endpoint router for AT Protocol HTTP dispatch
- [JwtService](#jwtservice) - HS256 JWT session management with refresh rotation
- [DidService](#didservice) - DID:web document generation with Multikey verification
- [AtprotoPdsMixin](#atprotopdsmixin) - Shared PDS mixin for station servers
- [AtUri](#aturi) - AT-URI parser (at://authority/collection/rkey)
- [FirehoseManager](#firehosemanager) - AT Protocol event stream manager with cursor replay
- [CollectionAdapter](#collectionadapter) - Base class for mapping Geogram content to AT Proto records
- [BlogCollection](#blogcollection) - Blog post adapter (radio.geogram.blog.post)
- [PlacesCollection](#placescollection) - Places adapter (radio.geogram.places.entry)
- [EventsCollection](#eventscollection) - Events adapter (radio.geogram.events.entry)
- [AlertsCollection](#alertscollection) - Alerts adapter (radio.geogram.alerts.report)
- [CollectionSyncManager](#collectionsyncmanager) - Orchestrates idempotent sync of all collections

### Stories App Components
- [SceneEditorCanvas](#sceneeditorcanvas) - Interactive scene canvas for Story Studio
- [ElementPropertiesPanel](#elementpropertiespanel) - Properties editor for story elements
- [ScenePropertiesPanel](#scenepropertiespanel) - Scene-level settings editor
- [AnchorSelectorWidget](#anchorselectorwidget) - 9-point anchor picker for positioning
- [AddElementDialog](#addelementdialog) - Dialog for adding text/image/button elements
- [SelectionFrame Pattern](#selectionframe-pattern) - Reusable selection frame with drag handles
- [SoundPickerWidget](#soundpickerwidget) - Background music picker for stories

---

## Picker Widgets

### UserPickerWidget

**File:** `lib/widgets/user_picker_widget.dart`

Select a user from known devices organized by folders with search functionality.

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `i18n` | I18nService | Yes | Localization service |
| `excludeNpub` | String? | No | Npub to exclude from selection (e.g., current user) |

**Returns:** `UserPickerResult` with `callsign`, `npub`, and `displayName`

**Usage:**
```dart
final result = await showModalBottomSheet<UserPickerResult>(
  context: context,
  isScrollControlled: true,
  builder: (_) => UserPickerWidget(
    i18n: widget.i18n,
    excludeNpub: currentUserNpub,
  ),
);

if (result != null) {
  print('Selected: ${result.callsign} (${result.npub})');
}
```

**Features:**
- Users organized by device folders
- Search by callsign, display name, or npub
- Auto-expands single folder
- Filters out users without npub
- DraggableScrollableSheet UI

---

### CurrencyPickerWidget

**File:** `lib/widgets/wallet/currency_picker_widget.dart`

Select from available currencies including crypto, fiat, time-based, and custom currencies.

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `i18n` | I18nService | Yes | Localization service |
| `selectedCurrency` | String? | No | Currently selected currency code |
| `showTime` | bool | No | Show time-based currencies (default: true) |
| `showCrypto` | bool | No | Show cryptocurrencies (default: true) |
| `showFiat` | bool | No | Show fiat currencies (default: true) |
| `showCustom` | bool | No | Show custom currencies (default: true) |

**Returns:** Currency code as `String`

**Usage:**
```dart
final currency = await showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  builder: (_) => CurrencyPickerWidget(
    i18n: widget.i18n,
    selectedCurrency: 'EUR',
    showCrypto: true,
    showFiat: true,
  ),
);
```

**Features:**
- Categorized list (Time, Crypto, Fiat, Custom)
- Color-coded category badges
- Currency symbols display
- Checkmark for selected currency

---

### TypeSelectorWidget

**File:** `lib/widgets/inventory/type_selector_widget.dart`

Select an item type from the inventory catalog with category filtering.

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `i18n` | I18nService | Yes | Localization service |
| `selectedType` | String | Yes | Currently selected type ID |
| `scrollController` | ScrollController? | No | External scroll controller |

**Returns:** Type ID as `String`

**Usage:**
```dart
final typeId = await showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  builder: (_) => TypeSelectorWidget(
    i18n: widget.i18n,
    selectedType: currentTypeId,
  ),
);
```

**Features:**
- 16 item categories (food, electronics, tools, etc.)
- Category tabs for quick navigation
- Search with category filtering
- Icons for each category

---

### FileFolderPicker

**File:** `lib/widgets/file_folder_picker.dart`

A professional file and folder picker widget with rich features.

**Features:**
- Browse files and folders with rich type-specific icons and colors
- Show file sizes and folder total sizes (calculated in background)
- Sort by name, size, or modification date
- Access storage locations (Home, Downloads, Documents, Pictures)
- Detect removable media (USB drives on Linux, SD cards on Android)
- Multi-select support
- Grid and list view modes
- Show/hide hidden files toggle
- Breadcrumb navigation
- OS-level drag & drop: drop files from Nemo/Explorer into the widget
- Internal drag & drop: move files/folders between directories (desktop click-drag, mobile long-press-drag)
- OS clipboard paste: Ctrl+V pastes files copied in Nemo/Nautilus/Dolphin/Explorer
- OS clipboard copy: Ctrl+C copies selected files to system clipboard for pasting in file managers
- Import progress overlay with per-file progress bar
- ProfileStorage-aware: files dropped into encrypted storage use `ProfileStorage.copyFromExternal()`
- Conflict resolution with " (copy)" / " (copy N)" suffix naming
- Recursive directory import support
- Create new folders from the toolbar (with validation and duplicate detection)
- Works on Linux, Windows, and Android

**Usage:**

```dart
final selected = await FileFolderPicker.show(
  context,
  title: 'Select files or folders',
  allowMultiSelect: true,
  showHiddenFiles: false,
);

if (selected != null && selected.isNotEmpty) {
  for (final path in selected) {
    print('Selected: $path');
  }
}
```

**Parameters:**
| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `initialDirectory` | String? | No | $HOME or /storage/emulated/0 | Starting directory |
| `title` | String | No | 'Select files or folders' | Dialog title |
| `allowMultiSelect` | bool | No | true | Enable multi-selection |
| `showHiddenFiles` | bool | No | false | Show hidden files initially |
| `explorerMode` | bool | No | false | Hide selection UI; files opened via `onFileOpen` |
| `onFileOpen` | ValueChanged\<String\>? | No | null | Called when a file is tapped in explorer mode |
| `extraLocations` | List\<StorageLocation\>? | No | null | Additional storage shortcuts in the location bar |

**Returns:** `List<String>?` - List of selected file/folder paths, or null if cancelled

**Explorer mode example:**
```dart
FileFolderPicker(
  initialDirectory: '/path/to/profile',
  title: 'Files',
  explorerMode: true,
  onFileOpen: (path) => _openFile(path),
  extraLocations: [
    StorageLocation(
      name: 'Geogram',
      path: '/path/to/profile',
      icon: Icons.snippet_folder,
    ),
  ],
)
```

---

## Notification Helpers

### BackupNotificationService

**File:** `lib/services/backup_notification_service.dart`

Lightweight local notification handler for backup events (invite received/accepted/declined, backup/restore start/complete/fail, snapshot note updates). It listens to `BackupEvent` on `EventBus` and shows platform notifications on Android/iOS when allowed by `NotificationService` settings.

**Initialization (mobile only):**
```dart
// After NotificationService/DMNotificationService setup
await BackupNotificationService().initialize(skipPermissionRequest: firstLaunch);
```

**How it works:**
- Subscribes to `BackupEvent` (types in `lib/util/event_bus.dart`).
- Respects notification preferences (`enableNotifications`, `notifySystemAlerts`).
- Uses `flutter_local_notifications` with channel `geogram_backup`.

**Reuse in other apps/features:**
1. Fire `BackupEvent` with a relevant `BackupEventType` from your flow (e.g., for a new app that piggybacks on backup transfers). Example:
   ```dart
   EventBus().fire(BackupEvent(
     type: BackupEventType.backupCompleted,
     role: 'client',
     counterpartCallsign: providerCallsign,
     snapshotId: snapshotId,
     totalFiles: totalFiles,
     totalBytes: totalBytes,
   ));
   ```
2. Ensure `BackupNotificationService().initialize()` is called during app startup (already wired in `main.dart`).
3. Add any new `BackupEventType` variants to `lib/util/event_bus.dart` and handle them in `_handleEvent` if you want notifications.

**Notes:**
- No notifications on desktop/web (mobile-only guard).
- Honors OS permission prompts; set `skipPermissionRequest` during onboarding as needed.
- Uses plain title/body; extend `_handleEvent` for richer payloads if your app needs it.

---

### Notification Tap Handling Pattern

**Files:** `lib/services/dm_notification_service.dart`, `lib/main.dart`

Handle navigation when users tap on notifications. This pattern works reliably across all app states (foreground, background, terminated).

#### Why Not EventBus for Notification Taps?

When a notification is tapped on Android, the callback may run in a **separate Dart isolate**. Each isolate has its own memory, so `EventBus()` returns a different singleton instance. Events fired in the notification isolate never reach the main UI isolate.

**Use EventBus for:** Creating notifications when events occur (same isolate)
**Don't use EventBus for:** Handling notification taps (cross-isolate)

#### The Pattern: Static Pending Action + Lifecycle Check

1. **Define a static pending action variable** in the notification service
2. **Set it in notification tap callbacks** (both foreground and background)
3. **Check it on app resume** via `WidgetsBindingObserver.didChangeAppLifecycleState`

#### Payload Format

Use a standardized payload format: `type:data`

| Type | Format | Example | Action |
|------|--------|---------|--------|
| dm | `dm:CALLSIGN` | `dm:ALPHA1` | Open DM chat with ALPHA1 |
| chat | `chat:ROOM_ID` | `chat:general` | Open chat room |
| alert | `alert:ALERT_ID` | `alert:abc123` | Open alert details |
| backup | `backup:SNAPSHOT_ID` | `backup:xyz789` | Open backup details |

#### Implementation

**In notification service (e.g., `dm_notification_service.dart`):**

```dart
/// Notification action from tap - stored statically to persist across isolates
class NotificationAction {
  final String type;
  final String data;
  NotificationAction({required this.type, required this.data});
}

class DMNotificationService {
  /// Pending action from notification tap - checked on app resume
  static NotificationAction? pendingAction;

  // In notification tap callback:
  void _onNotificationTapped(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null) return;

    final colonIndex = payload.indexOf(':');
    if (colonIndex > 0) {
      pendingAction = NotificationAction(
        type: payload.substring(0, colonIndex),
        data: payload.substring(colonIndex + 1),
      );
    }
  }
}
```

**In main.dart:**

```dart
class _GeogramAppState extends State<GeogramApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Check on startup too (handles cold start)
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkPendingNotification());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkPendingNotification();
    }
  }

  void _checkPendingNotification() {
    final action = DMNotificationService.pendingAction;
    if (action == null) return;
    DMNotificationService.pendingAction = null; // Clear it

    switch (action.type) {
      case 'dm':
        _navigateToDMChat(action.data);
        break;
      case 'chat':
        _navigateToChatRoom(action.data);
        break;
      // Add more types as needed
    }
  }
}
```

#### Adding New Notification Types

1. Define the payload format: `newtype:DATA`
2. Create notifications with that payload in your service
3. Add case to `_checkPendingNotification()` switch in main.dart
4. Implement the navigation method

---

## Viewer Pages

### PhotoViewerPage

**File:** `lib/pages/photo_viewer_page.dart`

Full-screen media viewer for photos and videos with zoom, pan, and navigation.

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `imagePaths` | List\<String\> | Yes | List of local or network media paths (images and videos) |
| `initialIndex` | int | No | Starting media index (default: 0) |

**Usage:**
```dart
Navigator.push(
  context,
  MaterialPageRoute(
    builder: (_) => PhotoViewerPage(
      imagePaths: ['/path/to/image.jpg', '/path/to/video.mp4'],
      initialIndex: 0,
    ),
  ),
);
```

**Features:**
- **Images:** Zoom (0.5x to 4.0x) with pinch gesture, pan support
- **Videos:** Tap to play/pause, progress bar with scrubbing, duration display
- Swipe navigation between media items
- Keyboard navigation (arrows, escape)
- Media counter display
- Page indicator dots
- Save/download button (images and videos)
- Network and local file support
- Black background (cinema mode)

**Supported Video Formats:**
`.mp4`, `.avi`, `.mkv`, `.mov`, `.wmv`, `.flv`, `.webm`

---

### LocationPickerPage

**File:** `lib/pages/location_picker_page.dart`

Interactive map-based location picker or viewer.

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `initialPosition` | LatLng? | No | Starting coordinates |
| `viewOnly` | bool | No | Read-only mode (default: false) |

**Returns:** `LatLng` (selected position)

**Usage:**
```dart
final position = await Navigator.push<LatLng>(
  context,
  MaterialPageRoute(
    builder: (_) => LocationPickerPage(
      initialPosition: LatLng(38.7223, -9.1393),
      viewOnly: false,
    ),
  ),
);

if (position != null) {
  print('Selected: ${position.latitude}, ${position.longitude}');
}
```

**Features:**
- Map tap to select location
- Manual latitude/longitude input
- Auto-detect current location
- Zoom in/out controls
- Layer toggle (Standard/Satellite)
- Reset north compass
- Tile caching for offline use
- 6 decimal precision coordinates

---

### PlacePickerPage

**File:** `lib/pages/place_picker_page.dart`

Full-screen place picker with sortable results. Shows all places from the user's place collections with distance calculation and flexible sorting options.

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `i18n` | I18nService | Yes | Localization service |
| `initialPosition` | Position? | No | Override GPS position for distance calculation |

**Returns:** `PlacePickerResult` with `place`, `collectionTitle`, and `distance`

**Usage:**
```dart
final result = await Navigator.push<PlacePickerResult>(
  context,
  MaterialPageRoute(
    builder: (context) => PlacePickerPage(i18n: widget.i18n),
  ),
);

if (result != null) {
  print('Selected: ${result.place.getName('EN')}');
  print('Distance: ${result.distance?.toStringAsFixed(1)} km');
  print('Collection: ${result.collectionTitle}');
}
```

**Features:**
- **Sort toggle:** Switch between sorting by distance or by time (newest first)
- **GPS-based sorting:** Places sorted by distance from user's current position
- **Time-based sorting:** Places sorted by creation date (newest first)
- **Distance display:** Shows formatted distance next to each place (e.g., "2.2km", "350m")
- **Fallback location:** Uses IP-based geolocation on desktop/web or when GPS is unavailable
- **Full-text search:** Filter places by name, address, description, type, history, region, and collection name (searches all language variants)
- **Location status:** Visual indicators for GPS status (loading, available, unavailable)
- **Multiple collections:** Loads places from all configured place collections

**Sort Modes:**
| Mode | Description |
|------|-------------|
| Distance | Places sorted by proximity to user (closest first) |
| Time | Places sorted by creation date (newest first) |

**Search Fields:**
The search box filters across all of these fields:
- Place name (all language variants)
- Address
- Description (all language variants)
- Type/category
- History
- Region path
- Collection name

**Location Detection Priority:**
1. GPS (mobile with permission)
2. Browser Geolocation API (web)
3. IP-based geolocation (fallback)
4. Alphabetical sort (when location unavailable)

**PlacePickerResult Fields:**
| Field | Type | Description |
|-------|------|-------------|
| `place` | Place | The selected place object |
| `collectionTitle` | String? | Name of the collection the place belongs to |
| `distance` | double? | Distance from user in kilometers (null if location unavailable) |

**Dependencies:**
- `geolocator: ^13.0.2` - GPS location access
- `LocationService` - Distance calculation and IP geolocation

**Required i18n Keys:**
- `choose_place` - Page title
- `search_places` - Search hint
- `no_places_found` - Empty state message
- `sorted_by_distance` - Status text when sorting by distance
- `sorted_by_time` - Status text when sorting by time
- `location_unavailable` - Status when GPS unavailable

---

### ContactPickerPage

**File:** `lib/pages/contact_picker_page.dart`

Full-screen contact picker with search and sorting. Shows all contacts from the user's contact collections with flexible sorting options.

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `i18n` | I18nService | Yes | Localization service |
| `multiSelect` | bool | No | Enable multiple selection (default: false) |
| `initialSelection` | Set\<String\>? | No | Pre-selected callsigns for multi-select mode |

**Returns:**
- Single select: `ContactPickerResult` with `contact` and `collectionTitle`
- Multi-select: `List<ContactPickerResult>`

**Usage (Single Select):**
```dart
final result = await Navigator.push<ContactPickerResult>(
  context,
  MaterialPageRoute(
    builder: (context) => ContactPickerPage(i18n: widget.i18n),
  ),
);

if (result != null) {
  print('Selected: ${result.contact.displayName}');
  print('Callsign: ${result.contact.callsign}');
  print('Collection: ${result.collectionTitle}');
}
```

**Usage (Multi-Select):**
```dart
final results = await Navigator.push<List<ContactPickerResult>>(
  context,
  MaterialPageRoute(
    builder: (context) => ContactPickerPage(
      i18n: widget.i18n,
      multiSelect: true,
      initialSelection: {'ALPHA1', 'BRAVO2'},
    ),
  ),
);

if (results != null) {
  for (final result in results) {
    print('Selected: ${result.contact.callsign}');
  }
}
```

**Features:**
- **Sort toggle:** Switch between alphabetical (A-Z) and recent (newest first)
- **Full-text search:** Filter contacts by name, callsign, group path, collection, emails, phones, tags, notes
- **Multi-select mode:** Optional checkbox selection for multiple contacts
- **Multiple collections:** Loads contacts from all configured contact collections
- **Visual feedback:** Avatar initials, selected state indicators

**Sort Modes:**
| Mode | Description |
|------|-------------|
| Alphabetical | Contacts sorted A-Z by display name |
| Recent | Contacts sorted by firstSeen date (newest first) |

**Search Fields:**
The search box filters across:
- Display name
- Callsign
- Group path
- Collection name
- Emails
- Phones
- Tags
- Notes

**ContactPickerResult Fields:**
| Field | Type | Description |
|-------|------|-------------|
| `contact` | Contact | The selected contact object |
| `collectionTitle` | String? | Name of the collection the contact belongs to |

**Required i18n Keys:**
- `select_contact` - Page title
- `search_contacts` - Search hint
- `no_contacts_found` - Empty state message
- `sorted_alphabetically` - Status text when sorting A-Z
- `sorted_by_recent` - Status text when sorting by recent

---

### DocumentViewerWidget

**File:** `lib/pages/document_viewer_editor_page.dart`

Scaffold-free document viewer widget for embedding in split-pane layouts, dialogs, or any custom container. Supports text, markdown, and PDF with auto-detection. Reloads automatically when `filePath` changes via `didUpdateWidget`. When `editable` is true, shows an edit toolbar for text/markdown files with inline editing, save, and cancel (with unsaved-changes guard).

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `filePath` | String | Yes | Path to the document file |
| `viewerType` | DocumentViewerType | No | Force viewer type (default: auto) |
| `editable` | bool | No | Enable editing for text-based files (default: false) |
| `showEditToolbar` | bool | No | Show built-in edit toolbar (default: true). Set false when host provides its own edit button via GlobalKey |
| `onSaved` | VoidCallback? | No | Called after a successful file save |

**Static helper:**
- `DocumentViewerWidget.isEditableExtension(String ext)` — returns true for extensions that support text editing: `txt`, `log`, `json`, `xml`, `csv`, `yaml`, `yml`, `ini`, `conf`, `cfg`, `toml`, `md`, `markdown`, `html`, `htm`, `css`, `dart`, `py`, `js`, `ts`, `java`, `c`, `cpp`, `h`, `sh`, `bat`, `kt`, `go`, `rs`, `rb`, `php`, `sql`, `lua`, `swift`, `r`, `pl`, `pm`, `scala`, `hs`, `ex`, `exs`, `clj`, `zig`, `nim`, `makefile`, `dockerfile`, `gradle`, `tf`, `ps1`, `fish`, `zsh`, `scss`, `sass`, `less`, `jsx`, `tsx`, `vue`, `svelte`, `graphql`, `gql`, `bash`, `properties`.

**Public state API** (via `GlobalKey<DocumentViewerWidgetState>`):
- `isEditing` — whether the widget is in edit mode
- `isEditableType` — whether the resolved type supports editing
- `hasUnsavedChanges` — whether there are pending changes
- `startEditing()` — enter edit mode
- `saveFile()` — save and exit edit mode
- `cancelEditing()` — cancel with unsaved-changes guard

**Usage (built-in toolbar):**
```dart
DocumentViewerWidget(
  filePath: selectedPath,
  viewerType: DocumentViewerType.text,
  editable: true,
)
```

**Usage (external edit control via GlobalKey):**
```dart
final _viewerKey = GlobalKey<DocumentViewerWidgetState>();

// In header bar:
IconButton(
  icon: const Icon(Icons.edit),
  onPressed: () => _viewerKey.currentState?.startEditing(),
)

// Widget:
DocumentViewerWidget(
  key: _viewerKey,
  filePath: selectedPath,
  editable: true,
  showEditToolbar: false,
)
```

**Used by:** `FilesBrowserPage` (split-pane preview, external edit control), `DocumentViewerEditorPage` (full-screen wrapper, built-in toolbar).

---

### DocumentViewerEditorPage

**File:** `lib/pages/document_viewer_editor_page.dart`

Universal document viewer with auto-detection for text, markdown, and PDF files. Wraps `DocumentViewerWidget` in a Scaffold with AppBar. Uses continuous vertical scrolling. Automatically enables editing for text-based file extensions when not in readOnly mode.

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `filePath` | String | Yes | Path to the document file |
| `viewerType` | DocumentViewerType | No | Force viewer type (default: auto) |
| `title` | String? | No | Custom app bar title (default: filename) |
| `readOnly` | bool | No | Read-only mode (default: false) |

**Viewer Types:**
- `DocumentViewerType.auto` - Detect from file extension (default)
- `DocumentViewerType.text` - Plain text (.txt, .log, .json, .xml, etc.)
- `DocumentViewerType.markdown` - Markdown (.md, .markdown)
- `DocumentViewerType.pdf` - PDF documents
- `DocumentViewerType.cbz` - Comic book archives (future)

**Usage:**
```dart
Navigator.push(
  context,
  MaterialPageRoute(
    builder: (_) => DocumentViewerEditorPage(
      filePath: '/path/to/document.pdf',
      // viewerType: DocumentViewerType.auto, // optional
      // title: 'My Document', // optional
    ),
  ),
);
```

**Features:**
- Auto-detection from file extension
- Continuous vertical scroll (webtoon-style)
- PDF pages rendered as images for smooth scrolling
- Markdown with styled headings, code blocks, blockquotes
- Plain text with monospace font
- Selectable text
- Page count display for PDFs
- Error handling with retry button
- Syntax highlighting for 50+ languages (preview & edit mode)

---

### SyntaxHighlightController

**File:** `lib/widgets/syntax_highlight_controller.dart`

A `TextEditingController` that applies syntax highlighting via the `highlighting` package (Dart port of highlight.js). Drop into any `TextField` for live coloring while typing. Includes a text cache to avoid re-parsing on every frame, and a 100 KB size limit that falls back to plain text for large files.

**Constructor:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `languageId` | String | Yes | highlight.js language ID (e.g. `'dart'`, `'json'`) |
| `brightness` | Brightness | No | Initial theme brightness (default: `Brightness.dark`) |
| `text` | String? | No | Initial text content |

**Methods:**
- `updateBrightness(Brightness)` — swap between `vs2015Theme` (dark) and `githubTheme` (light)

**Usage:**
```dart
final controller = SyntaxHighlightController(languageId: 'dart');
TextField(controller: controller, maxLines: null, ...)
```

**Helper functions (same file):**
- `languageIdForFile(String path)` — returns highlight.js language ID for a file path, or `null` for plain text
- `convertNodesToSpans(List<Node> nodes, Map<String, TextStyle> theme)` — converts a highlight.js parse tree to `TextSpan` list (reusable for read-only preview)
- `extensionToLanguageId` — const map of file extension → language ID (50+ entries)

**Used by:** `DocumentViewerWidget` (both preview and edit modes).

---

### ContractDocumentPage

**File:** `lib/pages/contract_document_page.dart`

Display raw contract/debt document with markdown rendering.

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `collectionPath` | String | Yes | Path to the wallet collection |
| `debtId` | String | Yes | ID of the debt to display |
| `i18n` | I18nService | Yes | Localization service |

**Usage:**
```dart
Navigator.push(
  context,
  MaterialPageRoute(
    builder: (_) => ContractDocumentPage(
      collectionPath: '/path/to/collection',
      debtId: 'debt-123',
      i18n: widget.i18n,
    ),
  ),
);
```

**Features:**
- Full markdown rendering
- Signature status indicators in app bar
- Selectable text
- Styled headings, blockquotes, code blocks
- Shadow box document container

---

## Player Widgets

### VoicePlayerWidget

**File:** `lib/widgets/voice_player_widget.dart`

Play voice messages with download support.

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `filePath` | String | Yes | Local file path or remote URL |
| `durationSeconds` | int? | No | Metadata duration for display |
| `isLocal` | bool | No | Whether file is local (default: true) |
| `onDownloadRequested` | Future\<String?\> Function()? | No | Download callback for remote files |
| `backgroundColor` | Color? | No | Background color for widget |

**Usage:**
```dart
VoicePlayerWidget(
  filePath: '/path/to/voice.opus',
  durationSeconds: 15,
  isLocal: true,
  backgroundColor: Colors.blue.shade100,
)
```

**Features:**
- Play/pause/stop controls
- Elapsed/total time display
- Download progress indicator
- Loading state with spinner
- Automatic playback end detection

---

### MusicPlayerWidget

**File:** `lib/widgets/music_player_widget.dart`

Display and play generated music tracks.

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `track` | MusicTrack | Yes | Music track object |
| `showGenre` | bool | No | Display genre label (default: true) |
| `showModel` | bool | No | Display model used label (default: true) |
| `backgroundColor` | Color? | No | Bubble background color |
| `onDelete` | VoidCallback? | No | Delete callback |

**Usage:**
```dart
MusicPlayerWidget(
  track: musicTrack,
  showGenre: true,
  showModel: true,
  onDelete: () => deleteTrack(musicTrack.id),
)
```

**Features:**
- Play/pause/stop controls
- Progress bar with seek
- Track info (genre, model, duration)
- Delete button

---

### VoiceRecorderWidget

**File:** `lib/widgets/voice_recorder_widget.dart`

Record and preview voice messages before sending.

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `onSend` | void Function(String filePath, int durationSeconds) | Yes | Send callback |
| `onCancel` | VoidCallback | Yes | Cancel callback |

**Usage:**
```dart
VoiceRecorderWidget(
  onSend: (filePath, duration) {
    sendVoiceMessage(filePath, duration);
  },
  onCancel: () {
    setState(() => _showRecorder = false);
  },
)
```

**Features:**
- Recording state with animated dot
- Duration timer (max 30 seconds)
- Preview playback with progress
- Seek during preview
- Cancel/Delete and Send buttons

---

## Dialog Widgets

### NewChannelDialog

**File:** `lib/widgets/new_channel_dialog.dart`

Create new chat channels (direct message or group).

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `existingChannelIds` | List\<String\> | Yes | Existing IDs for validation |
| `knownCallsigns` | List\<String\> | Yes | Available participants for groups |

**Returns:** `ChatChannel` object

**Usage:**
```dart
final channel = await showDialog<ChatChannel>(
  context: context,
  builder: (_) => NewChannelDialog(
    existingChannelIds: existingIds,
    knownCallsigns: callsigns,
  ),
);

if (channel != null) {
  createChannel(channel);
}
```

**Features:**
- Toggle between Direct Message and Group
- Form validation
- Participant selection with FilterChips
- Duplicate ID detection

---

### NewThreadDialog

**File:** `lib/widgets/new_thread_dialog.dart`

Create new forum threads with title and content.

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `existingThreadTitles` | List\<String\> | Yes | For duplicate detection |
| `maxTitleLength` | int | No | Max title length (default: 100) |
| `maxContentLength` | int | No | Max content length (default: 5000) |

**Returns:** `Map<String, String>` with 'title' and 'content' keys

**Usage:**
```dart
final result = await showDialog<Map<String, String>>(
  context: context,
  builder: (_) => NewThreadDialog(
    existingThreadTitles: titles,
    maxTitleLength: 100,
  ),
);

if (result != null) {
  createThread(result['title']!, result['content']!);
}
```

**Features:**
- Title and content validation
- Duplicate title detection
- Character counters
- Helpful tip box

---

### AddTrackableDialog

**File:** `lib/tracker/dialogs/add_trackable_dialog.dart`

Unified dialog for adding exercise or measurement entries. Replaces separate AddExerciseDialog and AddMeasurementDialog with a single implementation.

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `service` | TrackerService | Yes | Tracker service for saving entries |
| `i18n` | I18nService | Yes | Localization service |
| `kind` | TrackableKind | Yes | Type: exercise or measurement |
| `preselectedTypeId` | String? | No | Pre-select a specific type (hides dropdown) |
| `year` | int | Yes | Year for storage |

**Static Methods:**

| Method | Returns | Description |
|--------|---------|-------------|
| `showExercise(context, ...)` | `Future<bool?>` | Show dialog for exercise entry |
| `showMeasurement(context, ...)` | `Future<bool?>` | Show dialog for measurement entry |

**Usage (Exercise):**
```dart
final saved = await AddTrackableDialog.showExercise(
  context,
  service: trackerService,
  i18n: widget.i18n,
  year: DateTime.now().year,
  preselectedTypeId: 'pushups', // Optional: pre-select type
);

if (saved == true) {
  // Entry was saved, refresh data
  await loadExercises();
}
```

**Usage (Measurement):**
```dart
final saved = await AddTrackableDialog.showMeasurement(
  context,
  service: trackerService,
  i18n: widget.i18n,
  year: DateTime.now().year,
  preselectedTypeId: 'weight', // Optional: pre-select type
);

if (saved == true) {
  await loadMeasurements();
}
```

**Supported Types:**

Exercises (TrackableKind.exercise):
| ID | Name | Unit | Max | Category |
|----|------|------|-----|----------|
| pushups | Push-ups | reps | 100 | Strength |
| abdominals | Abdominals | reps | 100 | Strength |
| squats | Squats | reps | 100 | Strength |
| pullups | Pull-ups | reps | 100 | Strength |
| lunges | Lunges | reps | 100 | Strength |
| planks | Planks | seconds | 300 | Strength |
| running | Running | meters | 50000 | Cardio |
| walking | Walking | meters | 50000 | Cardio |
| cycling | Cycling | meters | 100000 | Cardio |
| swimming | Swimming | meters | 10000 | Cardio |

Measurements (TrackableKind.measurement):
| ID | Name | Unit | Range | Decimals |
|----|------|------|-------|----------|
| weight | Weight | kg | 0-500 | 1 |
| height | Height | cm | 0-300 | 1 |
| heart_rate | Heart Rate | bpm | 0-300 | 0 |
| blood_glucose | Blood Glucose | mg/dL | 0-600 | 0 |
| body_fat | Body Fat | % | 0-100 | 1 |
| body_temperature | Temperature | °C | 30-45 | 1 |
| body_water | Body Water | % | 0-100 | 1 |
| muscle_mass | Muscle Mass | kg | 0-200 | 1 |
| blood_pressure | Blood Pressure | mmHg | Special | N/A |

**Input Modes:**

1. **Integer Dropdown** (exercises, heart_rate, blood_glucose):
   - Dropdown from 1 to maxCount
   - Remembers last selected value per type
   - Stored in ConfigService: `tracker.lastValue.{typeId}`

2. **Decimal Field** (weight, body_fat, etc.):
   - Text field with decimal keyboard
   - Validates min/max range
   - Shows unit suffix

3. **Blood Pressure** (special case):
   - Separate systolic/diastolic fields (required)
   - Optional heart rate field
   - Validates: systolic 50-300, diastolic 30-200

**Features:**
- Type dropdown (hidden when preselectedTypeId is set)
- Duration field for cardio exercises (minutes)
- Notes field with voice-to-text transcription button
- Remembers last value for integer types
- Form validation with localized error messages
- Loading state with spinner during save

**Related Models:**

`TrackableTypeConfig` (lib/tracker/models/trackable_type.dart):
```dart
enum TrackableKind { exercise, measurement }
enum TrackableCategory { strength, cardio, flexibility, health }

class TrackableTypeConfig {
  final String id;
  final String displayName;
  final String unit;
  final TrackableKind kind;
  final TrackableCategory category;
  final int decimalPlaces;    // 0 for integers
  final double? minValue;
  final double? maxValue;
  final int? maxCount;        // For dropdown max

  bool get isExercise;
  bool get isMeasurement;
  bool get isInteger;
  bool get isCardio;

  static Map<String, TrackableTypeConfig> builtInTypes;
  static Map<String, TrackableTypeConfig> exerciseTypes;
  static Map<String, TrackableTypeConfig> measurementTypes;
}
```

**Required i18n Keys:**
- `tracker_add_exercise`, `tracker_add_measurement`
- `tracker_exercise_type`, `tracker_measurement_type`
- `tracker_count`, `tracker_distance_meters`, `tracker_duration_minutes`
- `tracker_value`, `tracker_notes`
- `tracker_required_field`, `tracker_invalid_number`
- `tracker_required`, `tracker_invalid`
- `tracker_systolic`, `tracker_diastolic`, `tracker_heart_rate_optional`
- `tracker_min`, `tracker_max`
- `tracker_blood_pressure`
- `tracker_exercise_{id}` for each exercise type
- `tracker_measurement_{id}` for each measurement type
- `save`, `cancel`

---

## Selector Widgets

### CallsignSelectorWidget

**File:** `lib/widgets/callsign_selector_widget.dart`

Switch between multiple callsigns/profiles.

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `onProfileSwitch` | Function(Profile)? | No | Callback on profile switch |
| `onCreateNewProfile` | VoidCallback? | No | Custom create handler |
| `showCreateOption` | bool | No | Show "add new callsign" option |
| `compact` | bool | No | Compact chip vs full list mode |

**Usage:**
```dart
// Full mode
CallsignSelectorWidget(
  onProfileSwitch: (profile) => switchTo(profile),
  showCreateOption: true,
  compact: false,
)

// Compact mode (for tight spaces)
CallsignSelectorWidget(
  compact: true,
)
```

**Features:**
- Two display modes: compact (dropdown chip) and full (expandable list)
- Profile avatar display
- Active profile indicator
- Create new profile dialog
- Relay profile badge

---

### ProfileSwitcher

**File:** `lib/widgets/profile_switcher.dart`

App bar widget for profile switching with popup menu.

**Usage:**
```dart
AppBar(
  title: const Text('App Title'),
  actions: [
    ProfileSwitcher(),
  ],
)
```

**Features:**
- Popup menu on tap
- Profile avatar with custom images
- Nickname and callsign display
- Navigate to profile management

---

## Map Widgets

### TrackerMapCard

**File:** `lib/tracker/widgets/tracker_map_card.dart`

Reusable satellite map card widget for the Tracker feature. Displays a map with optional markers, polylines, and overlays. Supports auto-fitting to bounds and fullscreen expansion.

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `points` | List\<LatLng\> | Yes | Points used to calculate map bounds (auto-fit camera) |
| `markers` | List\<Marker\> | No | Markers to display on the map (default: []) |
| `polylines` | List\<Polyline\>? | No | Optional polylines to draw (paths, routes) |
| `height` | double | No | Card height in pixels (default: 260) |
| `onTap` | VoidCallback? | No | Callback when map is tapped (not on marker) |
| `onFullscreen` | VoidCallback? | No | Callback for fullscreen button press |
| `bottomLeftOverlay` | Widget? | No | Optional overlay widget at bottom-left (e.g., city label) |
| `showTransportLabels` | bool | No | Show transport/road labels (default: false) |
| `boundsPadding` | EdgeInsets | No | Padding around bounds (default: EdgeInsets.all(32)) |
| `fallbackCenter` | LatLng | No | Fallback center when no points (default: LatLng(0, 0)) |
| `fallbackZoom` | double | No | Fallback zoom level (default: 14) |

**Usage:**
```dart
TrackerMapCard(
  points: [
    LatLng(40.7128, -74.0060),
    LatLng(40.7580, -73.9855),
  ],
  markers: [
    Marker(
      point: LatLng(40.7128, -74.0060),
      width: 40,
      height: 40,
      child: Icon(Icons.location_on, color: Colors.red),
    ),
  ],
  height: 300,
  showTransportLabels: true,
  onFullscreen: () => Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => FullscreenMapPage()),
  ),
  bottomLeftOverlay: MapLabelOverlay(text: 'New York'),
)
```

**Features:**
- **Satellite tiles** with borders and labels overlay
- **Auto-fit camera** to show all points with padding
- **Fullscreen button** (optional, top-right)
- **Marker layer** for custom markers
- **Polyline layer** for paths/routes
- **Transport labels** for road names (optional)
- **Offline tile handling** with warning indicator
- **MapLabelOverlay helper** for styled bottom-left labels

**MapLabelOverlay Helper:**
```dart
// Use for consistent styled labels on the map
TrackerMapCard(
  points: points,
  bottomLeftOverlay: MapLabelOverlay(text: 'Lisbon → Madrid'),
)
```

**Example: Path Display:**
```dart
// Display a recorded path with start/end markers
TrackerMapCard(
  points: pathPoints.map((p) => LatLng(p.lat, p.lon)).toList(),
  markers: [
    Marker(
      point: LatLng(pathPoints.first.lat, pathPoints.first.lon),
      child: Icon(Icons.trip_origin, color: Colors.green),
    ),
    Marker(
      point: LatLng(pathPoints.last.lat, pathPoints.last.lon),
      child: Icon(Icons.flag, color: Colors.red),
    ),
  ],
  polylines: [
    Polyline(
      points: pathPoints.map((p) => LatLng(p.lat, p.lon)).toList(),
      strokeWidth: 3,
      color: Colors.blue,
    ),
  ],
  onTap: () => openFullscreenMap(),
)
```

**Example: Proximity Contacts:**
```dart
// Display contact locations with tap handlers
TrackerMapCard(
  points: clusters.map((c) => LatLng(c.lat, c.lon)).toList(),
  markers: clusters.map((cluster) => Marker(
    point: LatLng(cluster.lat, cluster.lon),
    width: 40,
    height: 40,
    child: GestureDetector(
      onTap: () => showClusterDetails(cluster),
      child: CircleAvatar(
        backgroundColor: Colors.blue,
        child: Text('${cluster.count}'),
      ),
    ),
  )).toList(),
  height: 300,
  showTransportLabels: true,
)
```

**Tile Layers:**
The widget uses these tile layers in order:
1. Satellite base layer (MapTileService)
2. Borders overlay with enhanced contrast
3. Labels layer (place names)
4. Transport labels (road names) - optional

**Dependencies:**
- `flutter_map: ^7.0.0` - Map widget
- `latlong2: ^0.9.1` - Coordinates
- `MapTileService` - Tile management and caching

---

### StaticMapService

**File:** `lib/services/static_map_service.dart`

Generates static map images (PNG bytes) for given coordinates by composing
cached satellite/map tiles. Uses Esri World Imagery (satellite) with optional
label overlays and a center pin marker.

**Usage:**
```dart
final pngBytes = await StaticMapService.generateStaticMap(
  lat: 51.5074,
  lon: -0.1278,
  width: 300,
  height: 200,
  zoom: 15,
);
if (pngBytes != null) {
  // Use Image.memory(pngBytes) or store as BLOB
}
```

**Parameters:**
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `lat` | double | required | Latitude of the center point |
| `lon` | double | required | Longitude of the center point |
| `width` | int | 300 | Output image width in pixels |
| `height` | int | 200 | Output image height in pixels |
| `zoom` | int | 15 | Tile zoom level (street-level detail) |
| `withLabels` | bool | true | Overlay Esri place/boundary labels |
| `withPin` | bool | true | Draw a location pin at center |

**Features:**
- Satellite imagery (Esri World Imagery) with labels overlay
- Automatic tile cache integration (reads from MapTileService cache)
- Downloads missing tiles on-demand with Esri fallback
- Configurable dimensions, zoom level, pin marker
- Web Mercator projection math (reusable static helpers)

**Public Helpers (for reuse):**
```dart
// Web Mercator math
StaticMapService.lonToTileX(lon, zoom)
StaticMapService.latToTileY(lat, zoom)
StaticMapService.tileXToLon(x, zoom)
StaticMapService.tileYToLat(y, zoom)

// Tile cache I/O
StaticMapService.readCachedTile(tilesPath, layer, z, x, y)

// Canvas drawing
StaticMapService.drawTileLayer(canvas, tiles, tileToScreen, colorFilter)
```

**Used by:**
- `TelegramCacheService` — generates map thumbnails for location/venue messages
- `PathShareService` — composes satellite tile backgrounds for shared path images

---

## Tree Widgets

### FolderTreeWidget

**File:** `lib/widgets/inventory/folder_tree_widget.dart`

Display hierarchical folder structure for navigation.

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `i18n` | I18nService | Yes | Localization service |
| `selectedPath` | List\<String\> | Yes | Current selected path |
| `onFolderSelected` | ValueChanged\<List\<String\>\> | Yes | Selection callback |
| `onCreateFolder` | VoidCallback? | No | Create folder action |
| `onItemDropped` | OnItemDropped? | No | Drag & drop callback |
| `onFolderAction` | OnFolderAction? | No | Context menu actions |

**Usage:**
```dart
FolderTreeWidget(
  i18n: widget.i18n,
  selectedPath: ['folder1', 'subfolder'],
  onFolderSelected: (path) {
    setState(() => _currentPath = path);
  },
  onCreateFolder: () => showCreateFolderDialog(),
)
```

**Features:**
- Recursive folder expansion
- Lazy loading of subfolders
- Drag & drop support
- Context menu for folder actions
- Auto-expand selected path

---

## QR Code Widgets

### QrPreviewWidget

**File:** `lib/widgets/qr_preview_widget.dart`

Reusable widget for displaying QR code previews with customization support (colors, rounded modules, logos).

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `code` | QrCode | Yes | QR code model with content and customizations |
| `size` | double | No | Size of the preview (default: 48) |
| `showShadow` | bool | No | Show shadow decoration (default: false) |
| `showContainer` | bool | No | Show container with border/shadow (default: true) |

**Usage:**
```dart
// Thumbnail in list
QrPreviewWidget(code: code, size: 48)

// Detail view with shadow
QrPreviewWidget(
  code: code,
  size: 200,
  showShadow: true,
)
```

**Features:**
- Displays stored base64 PNG for all codes (preserves visual customizations and notes)
- Falls back to live rendering for QR codes (with customization support)
- Falls back to flutter_zxing re-encoding for other formats
- Automatic fallback to placeholder for barcodes or invalid images

### BarcodeEncoderService

**File:** `lib/services/barcode_encoder_service.dart`

Utility service for encoding barcodes/QR codes to PNG and adding notes to images.

**Static Methods:**
| Method | Description |
|--------|-------------|
| `encodeToImage({content, format, width, height, margin})` | Encode content as barcode/QR to PNG bytes. Handles flexible dimensions (PDF417). |
| `addNotesToImage(pngBytes, notes, {fontSize, bold})` | Add notes text below a PNG image. fontSize: 14/24/48. Bold simulated via offset. |
| `is1DFormat(format)` | Check if ZXing format is a 1D barcode |
| `getZxingFormat(name)` | Convert ZXing format name string to int constant |

**Usage:**
```dart
// Encode a barcode
final png = BarcodeEncoderService.encodeToImage(
  content: 'Hello', format: Format.qrCode, width: 300,
);

// Add notes to an existing image
final withNotes = BarcodeEncoderService.addNotesToImage(
  pngBytes, 'My note', fontSize: 24, bold: true,
);
```

---

## Message Widgets

### MessageBubbleWidget

**File:** `lib/widgets/message_bubble_widget.dart`

Display individual chat messages with rich content support.

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `message` | ChatMessage | Yes | Message object |
| `isGroupChat` | bool | No | Group vs DM display |
| `onFileOpen` | VoidCallback? | No | File open callback |
| `onLocationView` | VoidCallback? | No | Location view callback |
| `onDelete` | VoidCallback? | No | Delete callback |
| `onQuote` | VoidCallback? | No | Quote/reply callback |
| `onReact` | Function(String)? | No | Reaction callback |
| `voiceFilePath` | String? | No | Voice file path |
| `canDelete` | bool | No | Permission to delete |

**Features:**
- Text message display
- File attachments
- Voice message playback
- Image display
- Location map preview
- Reaction emoji system (7 reactions)
- Quote/reply preview
- Hide/unhide messages

---

### MessageInputWidget

**File:** `lib/widgets/message_input_widget.dart`

Text input for composing chat messages.

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `onSend` | Function(String, String?) | Yes | Send callback (content, filePath) |
| `maxLength` | int | No | Max message length (default: 500) |
| `allowFiles` | bool | No | Enable file attachments |
| `onMicPressed` | VoidCallback? | No | Microphone button callback |
| `quotedMessage` | ChatMessage? | No | Quote/reply context |
| `onClearQuote` | VoidCallback? | No | Clear quote callback |

**Usage:**
```dart
MessageInputWidget(
  onSend: (content, filePath) {
    sendMessage(content, filePath);
  },
  maxLength: 500,
  allowFiles: true,
  onMicPressed: () => showVoiceRecorder(),
  quotedMessage: _replyingTo,
  onClearQuote: () => setState(() => _replyingTo = null),
)
```

**Features:**
- Text input with max length
- File/image attachment
- Quote preview
- Mic button for voice
- Character counter

---

## Services

### LocationService

**File:** `lib/services/location_service.dart`

Find nearest cities and country information from GPS coordinates using the worldcities database (~44,000 cities).

**Initialization:**
```dart
final locationService = LocationService();
await locationService.init();
```

**Methods:**

| Method | Returns | Description |
|--------|---------|-------------|
| `findNearestCity(lat, lng)` | `NearestCityResult?` | Find the single nearest city |
| `findNearestCities(lat, lng, {count})` | `List<NearestCityResult>` | Find N nearest cities (default: 5) |
| `findCityByName(name)` | `CityEntry?` | Search city by name (case-insensitive) |
| `getNearestCityEntry(lat, lng)` | `CityEntry?` | Get full city data for nearest city |
| `detectJurisdiction(lat, lng)` | `JurisdictionInfo?` | Get jurisdiction info for legal docs |
| `calculateDistance(lat1, lng1, lat2, lng2)` | `double` | Distance in km (Haversine formula) |
| `getAllCountries()` | `List<String>` | All unique countries sorted |

**NearestCityResult Fields:**
| Field | Type | Description |
|-------|------|-------------|
| `country` | String | Country name |
| `iso2` | String | ISO 3166-1 alpha-2 code (e.g., "US", "PT") |
| `iso3` | String | ISO 3166-1 alpha-3 code (e.g., "USA", "PRT") |
| `adminName` | String | Region/state/province name |
| `city` | String | City name (ASCII) |
| `capital` | String | "primary", "admin", or empty |
| `distance` | double | Distance in kilometers |
| `folderPath` | String | Sanitized path: Country/Region/City |

**CityEntry Fields:**
All of the above plus: `lat`, `lng`, `population`, `id`

**JurisdictionInfo Fields:**
| Field | Type | Description |
|-------|------|-------------|
| `country` | String | Country name |
| `region` | String? | Region/state/province name |
| `city` | String? | City name |
| `countryCode` | String? | ISO2 country code |
| `fullJurisdiction` | String | Formatted: "Region, Country" or "Country" |

**Usage Examples:**

```dart
// Find nearest city to coordinates
final result = await LocationService().findNearestCity(38.7223, -9.1393);
if (result != null) {
  print('${result.city}, ${result.country} (${result.iso2})');
  print('Distance: ${result.distance.toStringAsFixed(1)} km');
  print('Folder path: ${result.folderPath}');
}

// Find 10 nearest cities
final cities = await LocationService().findNearestCities(
  38.7223, -9.1393,
  count: 10,
);
for (final city in cities) {
  print('${city.city}: ${city.distance.toStringAsFixed(1)} km');
}

// Search city by name
final tokyo = await LocationService().findCityByName('Tokyo');
if (tokyo != null) {
  print('${tokyo.city}, ${tokyo.country}');
  print('Population: ${tokyo.population}');
  print('Coordinates: ${tokyo.lat}, ${tokyo.lng}');
}

// Calculate distance between two points
final distance = LocationService().calculateDistance(
  38.7223, -9.1393,  // Lisbon
  40.4168, -3.7038,  // Madrid
);
print('Distance: ${distance.toStringAsFixed(0)} km');

// Detect jurisdiction for legal documents
final jurisdiction = await LocationService().detectJurisdiction(38.7223, -9.1393);
if (jurisdiction != null) {
  print('Jurisdiction: ${jurisdiction.fullJurisdiction}');
  print('Country code: ${jurisdiction.countryCode}');
}
```

**Database:** `assets/worldcities.csv` (SimpleMaps World Cities Database)

---

### LocationProviderService

**File:** `lib/services/location_provider_service.dart`

Singleton service that maintains a GPS lock and provides positions to multiple consumers. Instead of each app/feature acquiring its own GPS lock, they can request the already-locked position from this shared service.

**Key Benefits:**
- **Battery efficient:** Single GPS lock shared across all consumers
- **Already locked position:** Get accurate GPS immediately without waiting for lock
- **Consumer management:** Auto-starts when first consumer registers, auto-stops when last one unregisters
- **Cross-app sharing:** Write position to shared file for external app access

**Initialization:**
```dart
final service = LocationProviderService();

// Option 1: Register as a consumer (recommended)
final dispose = await service.registerConsumer(
  intervalSeconds: 30,
  onPosition: (pos) => print('Got position: $pos'),
);

// When done, call dispose to unregister
dispose();

// Option 2: Manual start/stop
await service.start(
  intervalSeconds: 30,
  sharedFilePath: '/path/to/shared/location.json', // optional
);
service.stop();
```

**Getting the Current Locked Position:**
```dart
final service = LocationProviderService();

// Check if we have a valid, fresh position
if (service.hasValidPosition) {
  final pos = service.currentPosition!;
  print('Using locked position: ${pos.latitude}, ${pos.longitude}');
  print('Accuracy: ${pos.accuracy}m');
  print('Age: ${DateTime.now().difference(pos.timestamp).inSeconds}s');
}

// Or request an immediate position (blocks until GPS lock)
final pos = await service.requestImmediatePosition();
if (pos != null) {
  print('Got position: $pos');
}
```

**Listening to Position Updates (EventBus - Recommended):**
```dart
import '../util/event_bus.dart';

// Subscribe to PositionUpdatedEvent via EventBus (decoupled, no loops)
final subscription = EventBus().on<PositionUpdatedEvent>((event) {
  print('New position: ${event.latitude}, ${event.longitude}');
  print('Source: ${event.source}'); // 'gps', 'network', 'ip'
  print('Accuracy: ${event.accuracy}m');
});

// Cancel when done
subscription.cancel();
```

**Alternative: Stream or ChangeNotifier**
```dart
// Real-time stream of positions
service.positionStream.listen((pos) {
  print('New position: ${pos.latitude}, ${pos.longitude}');
  print('Source: ${pos.source}'); // 'gps', 'network', 'ip'
});

// Or use ChangeNotifier
service.addListener(() {
  final pos = service.currentPosition;
  if (pos != null) updateUI(pos);
});
```

**Cross-App Position Sharing:**
```dart
// App A: Start service with shared file
await LocationProviderService().start(
  intervalSeconds: 30,
  sharedFilePath: '/data/shared/current_location.json',
);

// App B: Read the shared position (static method, no service needed)
final pos = await LocationProviderService.readSharedPosition(
  '/data/shared/current_location.json',
);
if (pos != null && pos.isFresh()) {
  print('Got shared position: $pos');
}
```

**LockedPosition Properties:**

| Property | Type | Description |
|----------|------|-------------|
| `latitude` | double | Latitude in degrees |
| `longitude` | double | Longitude in degrees |
| `altitude` | double | Altitude in meters |
| `accuracy` | double | Horizontal accuracy in meters |
| `speed` | double | Speed in m/s |
| `heading` | double | Heading in degrees |
| `timestamp` | DateTime | When position was acquired |
| `source` | String | Position source: 'gps', 'network', 'ip', 'browser' |

**LockedPosition Methods:**

| Method | Returns | Description |
|--------|---------|-------------|
| `isFresh({maxAge})` | bool | Check if position is within maxAge (default: 5 min) |
| `isHighAccuracy` | bool | True if accuracy < 50m |
| `toJson()` | Map | Serialize for storage/sharing |

**Service Properties:**

| Property | Type | Description |
|----------|------|-------------|
| `isRunning` | bool | Service is actively acquiring positions |
| `currentPosition` | LockedPosition? | Latest position (may be null) |
| `hasValidPosition` | bool | Has a fresh, valid position |
| `consumerCount` | int | Number of active consumers |
| `positionStream` | Stream | Real-time position updates |

**Platform Support:**

| Platform | Method | Background Support |
|----------|--------|-------------------|
| Android | Foreground Service | Yes - persistent notification |
| iOS | Position Stream | Yes - background location indicator |
| Desktop | Timer + Geolocator | Limited - foreground only |
| Web | Timer + Browser API | Limited - tab must be active |

**Example: Multiple Features Sharing GPS:**
```dart
// Feature 1: Path recording
final disposeForPath = await LocationProviderService().registerConsumer(
  intervalSeconds: 60,
  onPosition: (pos) => recordPathPoint(pos),
);

// Feature 2: Proximity detection (same GPS, different interval ignored)
final disposeForProximity = await LocationProviderService().registerConsumer(
  intervalSeconds: 30,
  onPosition: (pos) => checkNearbyUsers(pos),
);

// Feature 3: Just needs current position occasionally
void shareLocation() {
  final pos = LocationProviderService().currentPosition;
  if (pos != null && pos.isFresh()) {
    sendLocationToContact(pos);
  }
}

// When features are done
disposeForPath();
disposeForProximity();
// Service auto-stops when all consumers unregister
```

**Dependencies:**
- `geolocator: ^13.0.2` - GPS location access
- Location permissions required (handled automatically)

---

### PathRecordingService

**File:** `lib/tracker/services/path_recording_service.dart`

GPS path recording service with crash recovery and platform-specific optimizations. Uses [LocationProviderService](#locationproviderservice) for GPS positioning, so it shares the GPS lock with other consumers.

**Initialization:**
```dart
final recordingService = PathRecordingService();
recordingService.initialize(trackerService);
recordingService.addListener(_onRecordingChanged);

// Check for active recording from app restart/crash
await recordingService.checkAndResumeRecording();
```

**Methods:**

| Method | Returns | Description |
|--------|---------|-------------|
| `startRecording(pathType, title, ...)` | `Future<TrackerPath?>` | Start new GPS recording |
| `pauseRecording()` | `Future<bool>` | Pause current recording |
| `resumeRecording()` | `Future<bool>` | Resume paused recording |
| `stopRecording()` | `Future<TrackerPath?>` | Stop and complete recording |
| `cancelRecording()` | `Future<bool>` | Cancel and discard recording |
| `checkAndResumeRecording()` | `Future<bool>` | Resume from crash recovery |

**Properties:**

| Property | Type | Description |
|----------|------|-------------|
| `isRecording` | bool | Currently recording GPS points |
| `isPaused` | bool | Recording is paused |
| `hasActiveRecording` | bool | Has an active (recording or paused) session |
| `activePathId` | String? | Current path ID |
| `pointCount` | int | Number of recorded GPS points |
| `totalDistance` | double | Total distance in meters |
| `elapsedTime` | Duration | Time since recording started |
| `recordingState` | TrackerRecordingState? | Full state object |

**StartRecording Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `pathType` | TrackerPathType | Yes | Type of path (walk, run, bicycle, etc.) |
| `title` | String | Yes | Path title |
| `description` | String? | No | Optional description |
| `intervalSeconds` | int | No | GPS capture interval (default: 60) |

**Path Types:**

| Type | ID | Icon | Description |
|------|----|------|-------------|
| walk | walk | directions_walk | Walking path |
| run | run | directions_run | Running/jogging |
| bicycle | bicycle | directions_bike | Bicycle ride |
| car | car | directions_car | Car trip |
| train | train | train | Train journey |
| airplane | airplane | flight | Flight path |
| hike | hike | terrain | Hiking trail |
| other | other | route | Generic path |

**Usage Example:**

```dart
// Start recording
final path = await recordingService.startRecording(
  pathType: TrackerPathType.walk,
  title: 'Morning Walk - Jan 8',
  description: 'Around the park',
  intervalSeconds: 60,  // Record every minute
);

if (path != null) {
  print('Recording started: ${path.id}');
}

// Monitor recording state
recordingService.addListener(() {
  print('Points: ${recordingService.pointCount}');
  print('Distance: ${recordingService.totalDistance / 1000} km');
  print('Time: ${recordingService.elapsedTime}');
});

// Pause/resume
await recordingService.pauseRecording();
await recordingService.resumeRecording();

// Stop and save
final completedPath = await recordingService.stopRecording();
if (completedPath != null) {
  print('Recording complete: ${completedPath.totalDistanceMeters}m');
}
```

**Platform Support:**

| Platform | Method | Background Support | Notes |
|----------|--------|-------------------|-------|
| Android | Foreground Service + Geolocator | Yes | Persistent notification shows recording status |
| iOS | Geolocator position stream | Yes | Background location indicator, requires `allowBackgroundLocationUpdates` |
| Desktop | Timer + Geolocator | Limited | Falls back to IP geolocation when GPS unavailable |
| Web | Timer + Browser Geolocation | Limited | Uses browser Geolocation API via geolocator_web |

**Android Foreground Service:**

The service uses Geolocator's built-in foreground notification on Android:

```dart
AndroidSettings(
  accuracy: LocationAccuracy.high,
  distanceFilter: 0,
  intervalDuration: Duration(seconds: intervalSeconds),
  foregroundNotificationConfig: ForegroundNotificationConfig(
    notificationTitle: 'Recording Path',
    notificationText: 'GPS tracking is active',
    enableWakeLock: true,
  ),
)
```

**iOS Background Settings:**

```dart
AppleSettings(
  accuracy: LocationAccuracy.high,
  activityType: ActivityType.fitness,
  pauseLocationUpdatesAutomatically: false,
  allowBackgroundLocationUpdates: true,
  showBackgroundLocationIndicator: true,
)
```

**Crash Recovery:**

Recording state is persisted to disk, allowing recovery after app crashes or restarts:

```dart
// State stored at: {collection}/recording_state.json
class TrackerRecordingState {
  final String activePathId;
  final int activePathYear;
  final RecordingStatus status;
  final int intervalSeconds;
  final String startedAt;
  final String? lastPointTimestamp;
  final int pointCount;
}

// On app startup, check for active recording:
final resumed = await recordingService.checkAndResumeRecording();
if (resumed) {
  print('Resumed recording from crash recovery');
}
```

**GPS Unavailable Handling:**

When GPS/Internet is unavailable, the service skips recording points rather than saving empty values. Recording continues automatically when position data becomes available again.

**Storage Format:**

Paths are stored in year-based folders:
```
{collection}/paths/{YYYY}/{pathId}/
  ├── path.json      # Path metadata (title, status, tags, etc.)
  └── points.json    # GPS points array
```

**Point Data Structure:**

```dart
class TrackerPoint {
  final int index;
  final String timestamp;
  final double lat;
  final double lon;
  final double? altitude;
  final double? accuracy;
  final double? speed;
  final double? bearing;
}
```

**Dependencies:**
- `geolocator: ^13.0.2` - GPS location access with platform-specific settings
- Requires location permissions: `ACCESS_FINE_LOCATION` (Android), `NSLocationWhenInUseUsageDescription` (iOS)
- For background on Android: `FOREGROUND_SERVICE_LOCATION` permission
- For background on iOS: `NSLocationAlwaysAndWhenInUseUsageDescription`

**Integration with UI:**

Use with `StartPathDialog` and `ActiveRecordingBanner`:

```dart
// Show start dialog
final path = await StartPathDialog.show(
  context,
  recordingService: _recordingService,
  i18n: widget.i18n,
);

// Show recording banner in your UI
if (_recordingService.hasActiveRecording)
  ActiveRecordingBanner(
    recordingService: _recordingService,
    i18n: widget.i18n,
    onStop: _loadPaths,
  ),
```

**Required i18n Keys:**
- `tracker_start_path`, `tracker_stop_path`, `tracker_pause_path`, `tracker_resume_path`
- `tracker_path_type`, `tracker_path_title`, `tracker_path_description`
- `tracker_gps_interval`, `tracker_recording_in_progress`, `tracker_recording_paused`
- `tracker_path_type_walk/run/bicycle/car/train/airplane/hike/other`
- `tracker_interval_30s/1m/2m/5m`
- `tracker_gps_permission_required`, `tracker_gps_disabled`
- `tracker_morning`, `tracker_afternoon`, `tracker_evening`, `tracker_night`
- `tracker_confirm_stop`, `tracker_confirm_stop_message`

---

### PlaceService.findPlacesWithinRadius

**File:** `lib/services/place_service.dart`

Find all saved places within a given radius from GPS coordinates. Uses disk cache for fast lookups that auto-updates when places change.

**Static Method:**
```dart
static Future<List<PlaceWithDistance>> findPlacesWithinRadius({
  required double lat,
  required double lon,
  required double radiusMeters,
})
```

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `lat` | double | Yes | Latitude of search center |
| `lon` | double | Yes | Longitude of search center |
| `radiusMeters` | double | Yes | Search radius in meters |

**Returns:** `List<PlaceWithDistance>` - Places found within the radius

**PlaceWithDistance Fields:**
| Field | Type | Description |
|-------|------|-------------|
| `name` | String | Place name |
| `lat` | double | Place latitude |
| `lon` | double | Place longitude |
| `folderPath` | String | Full path to the place folder |
| `distanceMeters` | double | Distance from search center |

**Usage:**
```dart
final nearbyPlaces = await PlaceService.findPlacesWithinRadius(
  lat: 52.428919,
  lon: 10.800239,
  radiusMeters: 100,
);

for (final place in nearbyPlaces) {
  print('${place.name} is ${place.distanceMeters.toStringAsFixed(0)}m away');
  print('Location: ${place.lat}, ${place.lon}');
  print('Folder: ${place.folderPath}');
}
```

**Caching:**
- Cache stored at `{baseDir}/places/cache.json`
- Automatically updates when places are added/removed (compares folder paths)
- First call scans all device folders and creates cache
- Subsequent calls use cache (faster)
- Call `PlaceService.refreshPlacesCache()` to force refresh

**Debug Logging:**
The function logs detailed information for troubleshooting:
```
PlaceService.findPlacesWithinRadius: Searching at (52.43, 10.80) with radius 100m
PlaceService.findPlacesWithinRadius: Loaded 15 places from cache
PlaceService.findPlacesWithinRadius: "My Place" is 45m away (within range)
PlaceService.findPlacesWithinRadius: Found 2 places within 100m
```

**Directory Structure Supported:**
The function scans both directory structures:
- `{devicesDir}/{callsign}/places/places/...` (nested structure)
- `{devicesDir}/{callsign}/places/...` (flat structure)

**Force Refresh Cache:**
```dart
// Force rescan all places and update cache
await PlaceService.refreshPlacesCache();
```

**CachedPlaceEntry Fields:**
| Field | Type | Description |
|-------|------|-------------|
| `name` | String | Place name |
| `lat` | double | Place latitude |
| `lon` | double | Place longitude |
| `folderPath` | String | Full path to place folder |

**Cache File Format:**
```json
{
  "updated": "2026-01-12T10:30:00.000Z",
  "places": [
    {
      "name": "My Place",
      "lat": 52.428919,
      "lon": 10.800239,
      "folderPath": "/data/.../places/Germany/Lower_Saxony/Wolfsburg/my_place"
    }
  ]
}
```

**Algorithm:** Uses Haversine formula for accurate distance calculation on Earth's surface.

**Example: Proximity Detection in Tracker:**
```dart
// Check for nearby places every scan
Future<void> _checkNearbyPlaces(double lat, double lon) async {
  final nearbyPlaces = await PlaceService.findPlacesWithinRadius(
    lat: lat,
    lon: lon,
    radiusMeters: 100, // 100 meter radius
  );

  for (final place in nearbyPlaces) {
    // Record proximity detection for each nearby place
    await recordPlaceProximity(place);
  }
}
```

---

### CollectionService.generateBlogCache

**File:** `lib/services/collection_service.dart`

Scans a blog collection folder and generates a `cache.json` file containing metadata for all blog posts. This cache is used by the www homepage to display links to available blogs.

**Signature:**
```dart
Future<Map<String, dynamic>> generateBlogCache(String blogCollectionPath) async
```

**Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `blogCollectionPath` | String | Absolute path to the blog collection folder |

**Returns:** `Map<String, dynamic>` containing all posts metadata

**Output File:** `{blogCollectionPath}/cache.json`

**Cache JSON Structure:**
```json
{
  "generated": "2025-01-12T10:30:00.000Z",
  "totalPosts": 5,
  "publishedCount": 3,
  "draftCount": 2,
  "posts": [
    {
      "id": "2025-01-10_my-first-post",
      "title": "My First Post",
      "author": "CR7BBQ",
      "created": "2025-01-10 10:00_00",
      "edited": null,
      "description": "A short description",
      "status": "published",
      "tags": ["welcome", "intro"],
      "year": "2025",
      "path": "2025/2025-01-10_my-first-post/post.md"
    }
  ]
}
```

**Post Fields:**
| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Post folder name |
| `title` | string | Post title from `# BLOG: <title>` |
| `author` | string | Author callsign |
| `created` | string | Creation timestamp |
| `edited` | string? | Edit timestamp (null if never edited) |
| `description` | string? | Post description |
| `status` | string | "published" or "draft" |
| `tags` | string[] | Post tags |
| `year` | string | Year subdirectory |
| `path` | string | Relative path to post.md |

**Usage:**
```dart
final collectionService = CollectionService();
final cache = await collectionService.generateBlogCache('/path/to/blog');

// Get published posts only
final published = (cache['posts'] as List)
    .where((p) => p['status'] == 'published')
    .toList();
print('Found ${published.length} published posts');
```

**Blog Folder Structure:**
```
blog/
├── cache.json              # Generated cache file
├── collection.js
├── 2024/
│   └── 2024-12-20_year-review/
│       └── post.md
└── 2025/
    └── 2025-01-10_my-first-post/
        └── post.md
```

**Notes:**
- Cache is regenerated on each call
- Only folders containing `post.md` are included
- Posts sorted by created date (newest first)
- Used by www homepage to display blog links

---

### StunServerService

**File:** `lib/services/stun_server_service.dart`

Self-hosted STUN server implementing RFC 5389 Binding method for WebRTC NAT traversal. Replaces external STUN servers (Google, Twilio, Mozilla) with privacy-respecting self-hosted capability on station servers.

**Key Methods:**
```dart
Future<bool> start({int port = 3478}) async  // Start UDP server
Future<void> stop() async                     // Stop server
Map<String, dynamic> getStatus()              // Get server status for API
```

**Properties:**
| Property | Type | Description |
|----------|------|-------------|
| `isRunning` | bool | Whether STUN server is running |
| `port` | int | Current UDP port (valid when running) |
| `requestsHandled` | int | Requests handled since start |

**Protocol Flow:**
1. Client sends UDP Binding Request to port 3478
2. Server responds with XOR-MAPPED-ADDRESS (client's public IP:port)
3. WebRTC uses this reflexive address for NAT traversal

**Integration with Station:**
```dart
// In StationServerSettings (station_server_service.dart)
bool stunServerEnabled = true;  // Default: enabled
int stunServerPort = 3478;      // Standard STUN port

// In hello_ack response to clients
'stun_server': {
  'enabled': true,
  'port': 3478,
}
```

**Client Usage:**
```dart
// websocket_service.dart stores STUN info from hello_ack
StationStunInfo? get connectedStationStunInfo

// webrtc_peer_manager.dart uses station STUN
WebRTCConfig.withStationStun(
  stationHost: 'station.example.com',
  stunPort: 3478,
)
```

**Test Script:**
```bash
dart run bin/stun_test.dart localhost 3478
```

**Privacy Benefits:**
- No client IPs logged by STUN server
- No external dependencies or third-party contacts
- No Google/Twilio/Mozilla STUN servers
- LAN connections work without any external servers

---

### VideoMetadataExtractor

**File:** `lib/util/video_metadata_extractor.dart`

Cross-platform video metadata extraction and thumbnail generation using `media_kit`. Works on all platforms (Windows, Linux, macOS, Android, iOS) without requiring FFmpeg CLI installation.

**Key Methods:**
```dart
// Extract video metadata (duration, resolution, file size)
static Future<VideoMetadata?> extract(String videoPath) async

// Generate thumbnail at specific timestamp
static Future<String?> generateThumbnail(
  String videoPath,
  String outputPath, {
  int atSeconds = 1,
  int width = 1280,  // ignored - media_kit returns native resolution
}) async

// Get recommended thumbnail time (10% of duration)
static int getRecommendedThumbnailTime(int durationSeconds)
```

**VideoMetadata Class:**
| Property | Type | Description |
|----------|------|-------------|
| `duration` | int | Duration in seconds |
| `width` | int | Video width in pixels |
| `height` | int | Video height in pixels |
| `fileSize` | int | File size in bytes |
| `mimeType` | String | MIME type (e.g., "video/mp4") |
| `frameRate` | double? | Frame rate (from CLI fallback) |
| `bitrate` | int? | Bitrate (from CLI fallback) |
| `videoCodec` | String? | Video codec (from CLI fallback) |
| `audioCodec` | String? | Audio codec (from CLI fallback) |

**Thumbnail Generation Pattern (using media_kit):**
```dart
// The core pattern for taking screenshots with media_kit:
Player? player;
try {
  player = Player();
  // VideoController is REQUIRED for screenshot() to work
  final videoController = VideoController(player);

  // Wait for duration to confirm media is loaded
  final completer = Completer<Duration>();
  late StreamSubscription sub;
  sub = player.stream.duration.listen((duration) {
    if (duration > Duration.zero && !completer.isCompleted) {
      completer.complete(duration);
      sub.cancel();
    }
  });

  // Open media without playing
  await player.open(Media(videoPath), play: false);

  // Wait for load with timeout
  final duration = await completer.future.timeout(
    const Duration(seconds: 10),
    onTimeout: () => Duration.zero,
  );

  if (duration == Duration.zero) return null;

  // Seek to desired position
  await player.seek(Duration(seconds: atSeconds));
  await Future.delayed(const Duration(milliseconds: 300));

  // Play briefly to decode frames, then pause
  player.play();
  await Future.delayed(const Duration(milliseconds: 200));
  player.pause();
  await Future.delayed(const Duration(milliseconds: 200));

  // Take screenshot (returns PNG bytes)
  final bytes = await player.screenshot();

  await player.dispose();

  if (bytes == null || bytes.isEmpty) return null;

  // Save to file (media_kit outputs PNG format)
  await File(outputPath).writeAsBytes(bytes, flush: true);
  return outputPath;
} catch (e) {
  await player?.dispose();
  return null;
}
```

**Usage Example:**
```dart
import 'package:geogram/util/video_metadata_extractor.dart';

// Extract metadata
final metadata = await VideoMetadataExtractor.extract('/path/to/video.mp4');
if (metadata != null) {
  print('Duration: ${metadata.duration}s');
  print('Resolution: ${metadata.resolution}');
}

// Generate thumbnail
final thumbnailTime = VideoMetadataExtractor.getRecommendedThumbnailTime(metadata.duration);
final thumbnailPath = await VideoMetadataExtractor.generateThumbnail(
  '/path/to/video.mp4',
  '/path/to/thumbnail.png',  // Use .png extension - media_kit outputs PNG
  atSeconds: thumbnailTime,
);
```

**Notes:**
- media_kit `screenshot()` requires `VideoController` to be attached (for frame decoding)
- Output format is always PNG regardless of file extension
- Use `.png` file extension for thumbnails (see `VideoFolderUtils.buildThumbnailPath()`)
- Falls back to CLI ffprobe for detailed metadata (codec info, bitrate) on desktop

---

## Web Theme Components

### WebNavigation

**File:** `lib/util/web_navigation.dart`

Generates `<li>` menu items for web page navigation. Pure Dart library (no Flutter deps) used across station and device pages.

**Format:** `station > home | chat | blog` (station pages) or `home | chat | blog` (device pages)

**Path modes:**
- `isStationPage: true` - absolute paths: `/chat/`
- `isRootLevel: true` - root-relative: `./chat/` (for pages at `/{callsign}/`)
- default (sub-level) - up-one-level: `../chat/` (for pages at `/{callsign}/blog/`)

**Low-level methods (WebNavigation):**

`generateStationMenuItems` - For station server pages (absolute paths, prefixed with "station >")

`generateDeviceMenuItems` - For device pages (relative paths, `isRootLevel` controls prefix)

**Unified method (AppService):**

For device pages, always use `AppService().generateDeviceMenu()` instead of calling `WebNavigation.generateDeviceMenuItems()` directly. This method auto-detects which apps are publicly available by scanning sibling app directories.

```dart
// In any page generator:
final menuItems = await AppService().generateDeviceMenu(
  activeApp: 'chat',
  appsPath: p.dirname(chatAppPath),  // optional, defaults to profile apps dir
  isRootLevel: false,                // true for /{callsign}/ root pages
);
```

The detection (`AppService().getPublicApps()`) checks each app directory for existence and non-private visibility via `app.js`.

**Usage in Templates:**
Templates use `{{MENU_ITEMS}}` placeholder inside `<ul class="menu__inner">`:
```html
<nav class="menu">
  <ul class="menu__inner">
    {{MENU_ITEMS}}
  </ul>
</nav>
```

**Supported Apps:**
| ID | Label | Station Path | Device Path (sub) | Device Path (root) |
|----|-------|--------------|-------------------|-------------------|
| home | home | / | ../ | ./ |
| blog | blog | /blog/ | ../blog/ | ./blog/ |
| chat | chat | /chat/ | ../chat/ | ./chat/ |
| events | events | /events/ | ../events/ | ./events/ |
| places | places | /places/ | ../places/ | ./places/ |
| files | files | /files/ | ../files/ | ./files/ |
| alerts | alerts | /alerts/ | ../alerts/ | ./alerts/ |
| download | download | /download/ | ../download/ | ./download/ |

**CSS Classes (in themes/default/styles.css):**
```css
.menu__inner li { }            /* Menu items */
.menu__inner li.active a { }   /* Current page */
.menu__inner li.separator { }  /* The "|" between items */
.menu__inner a { }             /* Navigation links */
```

**Consumers:**
| Location | Method | Purpose |
|----------|--------|---------|
| `lib/station.dart` | `generateStationMenuItems()` | Station chat/homepage |
| `lib/cli/pure_station.dart` | `generateStationMenuItems()` | Station chat/homepage |
| `lib/services/app_service.dart` | `generateDeviceMenu()` | All device pages (www, blog, chat) |
| `lib/services/log_api_service.dart` | `generateDeviceMenu()` | Blog post pages (on-the-fly) |

---

### StationHtmlTemplates

**File:** `lib/util/station_html_templates.dart`

Shared HTML builders for station and device pages. Pure Dart library (no Flutter deps). Eliminates duplication across station.dart, pure_station.dart, and service files.

**Key Methods:**

| Method | Purpose |
|--------|---------|
| `getBaseStyles()` | Returns Terminimal theme CSS |
| `buildStationHomepage({...})` | Station homepage with device grid, map, API endpoints |
| `buildAlertsPage({stationName, alerts})` | Alerts listing page with filter/search |
| `buildBlogPostPage({...})` | Blog post page with optional NOSTR likes, comments |
| `buildDownloadPage({...})` | Software download page |
| `getNostrLikesScript({...})` | NOSTR NIP-07 likes JavaScript |

**Usage:**
```dart
import 'util/station_html_templates.dart';

final html = StationHtmlTemplates.buildBlogPostPage(
  postTitle: post.title,
  postDate: post.displayDate,
  author: author,
  htmlContent: htmlContent,
  globalStyles: StationHtmlTemplates.getBaseStyles(),
);
```

**Consumers:**
| Location | Methods Used |
|----------|-------------|
| `lib/station.dart` | `buildStationHomepage`, `buildAlertsPage`, `buildBlogPostPage` |
| `lib/cli/pure_station.dart` | `buildStationHomepage`, `buildAlertsPage`, `buildBlogPostPage` |
| `lib/services/station_server_service.dart` | `buildBlogPostPage`, `buildDownloadPage` |
| `lib/services/websocket_service.dart` | `buildBlogPostPage` |
| `lib/services/log_api_service.dart` | `buildBlogPostPage` |

---

### getChatPageScripts

**File:** `lib/util/chat_scripts.dart`

Provides reusable JavaScript for chat page interactivity. This is a shared pure Dart library (no Flutter dependencies) used by:
- Station server (`pure_station.dart`) - CLI mode, imports directly
- Remote device chat pages via `WebThemeService.getChatScripts()` - Flutter apps

**Function:**
```dart
String getChatPageScripts()
```

**Returns:** JavaScript code as a string for chat page interactivity

**Usage in Template Processing:**
```dart
final themeService = WebThemeService();
await themeService.init();

final html = themeService.processTemplate(template, {
  'GLOBAL_STYLES': await themeService.getGlobalStyles() ?? '',
  'APP_STYLES': await themeService.getAppStyles('chat') ?? '',
  'COLLECTION_NAME': stationName,
  'CHANNELS_LIST': channelsHtml.toString(),
  'CONTENT': messagesHtml.toString(),
  'DATA_JSON': dataJson,
  'SCRIPTS': themeService.getChatScripts(),  // <- Reusable scripts
});
```

**Required HTML Elements:**
The scripts expect these DOM elements to exist:
- `.channel-item` - Channel/room buttons with `data-room-id` attribute
- `#current-room` - Element to display current room name
- `#messages` - Container for messages

**Required GEOGRAM_DATA:**
The scripts read from `window.GEOGRAM_DATA`:
```javascript
window.GEOGRAM_DATA = {
  channels: [{ id: 'room1', name: 'Room 1' }],
  currentRoom: 'room1',
  apiBasePath: '/api/chat/rooms'  // or '../api/chat/rooms' for relative
};
```

**Features:**
- Channel switching with active state updates
- Message loading with date separators
- 5-second polling for new messages
- Auto-scroll to bottom on new messages
- HTML escaping for XSS prevention
- Error states for failed loads

**API Endpoints Used:**
- `GET {apiBasePath}/{roomId}/messages` - Load messages for a room
- `GET {apiBasePath}/{roomId}/messages?after={timestamp}` - Poll for new messages

**Message Format Expected:**
```json
{
  "messages": [
    {
      "timestamp": "2025-01-12 10:30_00",
      "author": "USER1",
      "content": "Hello world"
    }
  ]
}
```

**Consumers:**
| Location | Purpose |
|----------|---------|
| `lib/cli/pure_station.dart` `_handleChatPage()` | Station server chat page at `/chat` |
| `lib/services/collection_service.dart` `generateChatIndex()` | Remote device chat pages |

**Template File:**
`themes/default/chat/index.html` - HTML template with placeholders

**CSS File:**
`themes/default/chat/styles.css` - Chat-specific styles including:
- `.chat-layout` - Grid layout with sidebar
- `.channels-sidebar` - Channel list sidebar
- `.channel-item` - Individual channel buttons
- `.messages-area` - Message container
- `.message` - Individual message styling
- `.date-separator` - Date dividers between messages

**Example: Full Chat Page Generation:**
```dart
Future<void> _handleChatPage(HttpRequest request) async {
  final themeService = WebThemeService();
  await themeService.init();

  // Get styles
  final globalStyles = await themeService.getGlobalStyles() ?? '';
  final appStyles = await themeService.getAppStyles('chat') ?? '';

  // Build channel list HTML
  final channelsHtml = StringBuffer();
  for (final room in chatRooms) {
    channelsHtml.writeln('''
<div class="channel-item" data-room-id="${room.id}">
  <span class="channel-name">#${room.name}</span>
</div>''');
  }

  // Build data JSON
  final dataJson = jsonEncode({
    'channels': chatRooms.map((r) => {'id': r.id, 'name': r.name}).toList(),
    'currentRoom': chatRooms.first.id,
    'apiBasePath': '/api/chat/rooms',
  });

  // Get template and process
  final template = await themeService.getTemplate('chat');
  final html = themeService.processTemplate(template!, {
    'GLOBAL_STYLES': globalStyles,
    'APP_STYLES': appStyles,
    'COLLECTION_NAME': 'My Station',
    'CHANNELS_LIST': channelsHtml.toString(),
    'CONTENT': '', // Initial messages loaded by JS
    'DATA_JSON': dataJson,
    'SCRIPTS': themeService.getChatScripts(),
  });

  request.response.headers.contentType = ContentType.html;
  request.response.write(html);
}
```

---

## QR Widgets

### QrShareReceiveWidget

**File:** `lib/widgets/qr_share_receive_widget.dart`

Generic, reusable QR code share and receive widget with tabs. Designed to work with any data type through configuration.

**Generic Type Parameter:** `T` - The type of data being shared/received

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `dataToShare` | T? | No | Data to display as QR code (null shows empty state) |
| `config` | QrShareReceiveConfig\<T\> | Yes | Configuration for encoding/decoding |
| `i18n` | I18nService | Yes | Localization service |
| `initialTab` | int | No | Initial tab (0=Send, 1=Receive) |
| `onDataReceived` | void Function(T)? | No | Callback when data is received |

**QrShareReceiveConfig Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `shareTabTitle` | String | Yes | Tab title for send/share |
| `receiveTabTitle` | String | Yes | Tab title for receive/scan |
| `appBarTitle` | String | Yes | App bar title |
| `getFields` | List\<QrShareField\> Function(T) | Yes | Get selectable fields from data |
| `encode` | String Function(T, List\<QrShareField\>) | Yes | Encode data to JSON string |
| `decode` | QrScanResult\<T\> Function(String) | Yes | Decode JSON string to data |
| `onSave` | Future\<bool\> Function(T) | Yes | Save scanned data |
| `buildPreview` | Widget Function(BuildContext, T) | Yes | Build preview for scanned data |
| `validate` | Future\<String?\> Function(T)? | No | Validate before saving |
| `formatVersion` | String | No | Format version identifier (default: '1.0') |
| `maxRecommendedSize` | int | No | Max QR size in bytes (default: 1500) |
| `warningThreshold` | int | No | Warning threshold in bytes (default: 1000) |

**QrShareField Properties:**
| Property | Type | Description |
|----------|------|-------------|
| `id` | String | Unique field identifier |
| `label` | String | Display label |
| `icon` | IconData | Icon to display |
| `isRequired` | bool | Cannot be deselected if true |
| `isSelected` | bool | Currently selected state |
| `subFields` | List\<QrShareSubField\>? | Individual items for multi-value fields |
| `estimatedSize` | int | Estimated size in bytes |

**QrShareSubField Properties:**
| Property | Type | Description |
|----------|------|-------------|
| `id` | String | Unique identifier |
| `value` | String | Display value |
| `parentId` | String | Parent field ID |
| `isSelected` | bool | Selection state |

**Usage Example (Contacts):**
```dart
// Create configuration for contacts
final config = QrShareReceiveConfig<Contact>(
  shareTabTitle: 'Send',
  receiveTabTitle: 'Receive',
  appBarTitle: 'QR Code',
  getFields: (contact) => [
    QrShareField(
      id: 'displayName',
      label: 'Name',
      icon: Icons.person,
      isRequired: true,
    ),
    QrShareField(
      id: 'emails',
      label: 'Emails',
      icon: Icons.email,
      subFields: contact.emails.asMap().entries.map((e) =>
        QrShareSubField(
          id: 'email_${e.key}',
          value: e.value,
          parentId: 'emails',
        ),
      ).toList(),
    ),
  ],
  encode: (contact, fields) => jsonEncode({
    'type': 'contact',
    'name': contact.displayName,
    'emails': _getSelectedEmails(fields, contact.emails),
  }),
  decode: (json) {
    try {
      final data = jsonDecode(json);
      if (data['type'] != 'contact') {
        return QrScanResult(error: 'Invalid QR code');
      }
      return QrScanResult(data: Contact.fromJson(data));
    } catch (e) {
      return QrScanResult(error: 'Invalid format');
    }
  },
  onSave: (contact) async {
    await contactService.saveContact(contact);
    return true;
  },
  buildPreview: (context, contact) => ListTile(
    leading: const Icon(Icons.person),
    title: Text(contact.displayName),
    subtitle: Text('${contact.emails.length} emails'),
  ),
);

// Use the widget
Navigator.push(
  context,
  MaterialPageRoute(
    builder: (_) => QrShareReceiveWidget<Contact>(
      dataToShare: selectedContact,
      config: config,
      i18n: i18n,
      initialTab: 0, // Send tab
      onDataReceived: (contact) {
        print('Received: ${contact.displayName}');
      },
    ),
  ),
);
```

**Features:**
- **Send Tab:**
  - QR code generation with real-time updates
  - Field selection with checkboxes
  - Sub-field selection for multi-value fields (e.g., individual emails)
  - "Select All" and "Minimal" quick actions
  - Size indicator (OK/Warning/Too Large)
  - Copy JSON to clipboard
- **Receive Tab:**
  - Camera-based QR code scanning
  - Permission handling (request, denied, permanently denied)
  - Preview dialog before saving
  - Validation support
  - Error handling with user feedback
- **General:**
  - Fully generic - works with any data type
  - Localization support
  - Material 3 styling

**Platform Support:**
| Platform | Send (QR Generation) | Receive (Camera Scan) | Notes |
|----------|---------------------|----------------------|-------|
| Android | ✅ | ✅ | CameraX/ML Kit |
| iOS | ✅ | ✅ | AVFoundation/Apple Vision |
| macOS | ✅ | ✅ | AVFoundation/Apple Vision |
| Web | ✅ | ✅ | QR generation works everywhere; scanning uses browser camera API (ZXing) |
| Windows | ✅ | ❌ | QR generation only - no native camera support |
| Linux | ✅ | ❌ | QR generation only - no native camera support |

**Dependencies:**
- `qr_flutter: ^4.1.0` - QR code generation (cross-platform)
- `mobile_scanner: ^7.1.4` - Camera-based QR scanning (Android, iOS, macOS, Web)

**Web Camera Notes:**
- Uses browser's `getUserMedia` API for camera access
- User must grant camera permission in browser
- Works in Chrome, Firefox, Safari, Edge
- HTTPS required for camera access (except localhost)

**Required i18n Keys:**
- `qr_size_ok`, `qr_size_warning`, `qr_size_too_large`
- `copied_to_clipboard`, `qr_size`
- `minimal`, `select_all`, `select_fields_to_share`
- `field_required`, `no_data_to_share`
- `camera_permission_required`, `camera_permission_denied`
- `camera_not_supported`, `initializing_camera`, `scanning_qr`
- `open_settings`, `try_again`
- `data_scanned`, `saved_successfully`, `save_failed`
- `save`, `cancel`

---

### QrCodeService

**File:** `lib/services/qr_code_service.dart`

Service for managing QR codes and barcodes storage. Supports both created and scanned codes with subfolder organization.

**Key Methods:**
| Method | Description |
|--------|-------------|
| `saveQrCode(QrCode code, {String? customName, String? subfolder})` | Save a QR code to storage |
| `loadQrCodes({required QrCodeSource source, String? subfolder})` | Load codes from created or scanned folder |
| `updateQrCode(QrCode code)` | Update existing code |
| `deleteQrCode(String filePath)` | Delete a code |
| `searchQrCodes(String query)` | Search by name, content, or tags |
| `getSubfolders(QrCodeSource source)` | List user-created subfolders |
| `createSubfolder(QrCodeSource source, String name)` | Create new subfolder |

**Usage:**
```dart
final qrService = QrCodeService();

// Set up storage (required before use)
final profileStorage = AppService().profileStorage;
final scopedStorage = ScopedProfileStorage.fromAbsolutePath(
  profileStorage,
  appPath,
);
qrService.setStorage(scopedStorage);
await qrService.initializeApp(appPath);

// Save a scanned code
final code = QrCode(
  name: 'WiFi: MyNetwork',
  format: QrFormat.qrStandard,
  content: 'WIFI:T:WPA;S:MyNetwork;P:password;;',
  source: QrCodeSource.scanned,
  image: 'data:image/png;base64,...',
);
final saved = await qrService.saveQrCode(code, subfolder: 'wifi');

// Load all scanned codes
final scannedCodes = await qrService.loadQrCodes(source: QrCodeSource.scanned);
```

---

### QrCode Model

**File:** `lib/models/qr_code.dart`

Data model for QR codes and barcodes with support for multiple code types.

**Key Classes:**
- `QrCode` - Full code with image data
- `QrCodeSummary` - Lightweight summary for lists
- `QrFormat` - Enum of supported code types
- `QrContentType` - Detected content type (WiFi, URL, vCard, etc.)
- `WifiQrContent` - Helper for parsing/generating WiFi QR content

**Supported Formats:**
| Type | Code Types |
|------|------------|
| 2D | QR Code, Micro QR, Data Matrix, Aztec, PDF417, MaxiCode |
| 1D | Code 39, Code 93, Code 128, Codabar, EAN-8, EAN-13, ITF, UPC-A, UPC-E |

**Usage:**
```dart
// Create a WiFi QR code
final wifi = WifiQrContent(
  ssid: 'MyNetwork',
  password: 'secret123',
  authType: 'WPA',
);
final code = QrCode(
  name: 'Home WiFi',
  format: QrFormat.qrStandard,
  content: wifi.toQrString(),
  source: QrCodeSource.created,
  image: imageBase64,
  errorCorrection: QrErrorCorrection.m,
);

// Detect content type
final contentType = QrContentType.detect(code.content);
// Returns QrContentType.wifi

// Parse WiFi content
final parsedWifi = WifiQrContent.parse(code.content);
print(parsedWifi.ssid); // MyNetwork
```

---

## Speech Input Widgets

### TranscribeButtonWidget

**File:** `lib/widgets/transcribe_button_widget.dart`

Voice-to-text button for text fields. Shows an audio waveform icon that opens a recording/transcription dialog.

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `i18n` | I18nService | Yes | Localization service |
| `onTranscribed` | void Function(String) | Yes | Callback with transcribed text |
| `enabled` | bool | No | Enable/disable button (default: true) |
| `iconSize` | double | No | Icon size (default: 24) |

**Usage:**
```dart
TextFormField(
  controller: _descriptionController,
  decoration: InputDecoration(
    labelText: 'Description',
    suffixIcon: TranscribeButtonWidget(
      i18n: widget.i18n,
      onTranscribed: (text) {
        if (_descriptionController.text.isEmpty) {
          _descriptionController.text = text;
        } else {
          _descriptionController.text += ' $text';
        }
      },
    ),
  ),
)
```

**Features:**
- Auto-downloads Whisper model on first use (~465 MB)
- 30-second maximum recording duration
- Offline processing (no internet required after model download)
- Progress indicators for download and transcription
- Automatic platform detection (hides on unsupported platforms)
- Resume support for interrupted downloads

**Platform Support:**
| Platform | Supported | Notes |
|----------|-----------|-------|
| Android 5.0+ | Yes | |
| iOS 13+ | Yes | |
| macOS 11+ | Yes | |
| Windows | No | Icon hidden |
| Linux | No | Icon hidden |
| Web | No | Icon hidden |

**Dialog States:**
1. **Checking model** - Verifies if speech model is downloaded
2. **Downloading** - Auto-downloads Whisper Small model with progress bar
3. **Idle** - Ready to record, tap Start button
4. **Recording** - Animated waveform, timer, max 30 seconds
5. **Processing** - Transcribing audio (runs in background)
6. **Error** - Shows error with retry option

**Dependencies:**
- `whisper_flutter_new: ^1.3.0` - Offline speech recognition

**Model Storage:**
- Location: `{data-root}/bot/models/whisper/`
- Default model: Whisper Small (~465 MB)
- Downloaded from HuggingFace (ggerganov/whisper.cpp)

**Required i18n Keys:**
- `voice_to_text` - Tooltip
- `tap_to_start_recording` - Idle state hint
- `listening` - Recording title
- `recording` - Recording state label
- `processing_speech` - Processing title
- `transcribing_audio` - Processing state
- `downloading_speech_model` - Download title
- `first_time_download` - First-time hint
- `max_duration_seconds` - Duration hint with placeholder
- `microphone_permission_required` - Permission error
- `transcription_failed` - Error message
- `no_speech_detected` - Empty result message

### TtsPlayerWidget

**File:** `lib/widgets/tts_player_widget.dart`

Text-to-speech player using Supertonic for on-device voice synthesis.
Automatically uses the app's selected language (English or Portuguese).

**Parameters:**
| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `text` | String | Yes | - | Text to synthesize |
| `autoPlay` | bool | No | false | Play immediately on mount |
| `showControls` | bool | No | true | Show play/loading indicator |
| `voice` | TtsVoice | No | f3 | Voice style (m3-m5, f3-f5) |
| `onAudioGenerated` | Function? | No | null | Callback with audio samples |
| `child` | Widget? | No | null | Custom trigger widget |
| `iconSize` | double | No | 24.0 | Icon size for default controls |
| `iconColor` | Color? | No | null | Icon color |

**Usage:**
```dart
// Simple - shows play button
TtsPlayerWidget(
  text: 'Hello, welcome to Geogram!',
)

// Auto-play notification
TtsPlayerWidget(
  text: notification.message,
  autoPlay: true,
  showControls: false,
)

// Custom trigger with male voice
TtsPlayerWidget(
  text: article.content,
  voice: TtsVoice.m4,
  child: IconButton(
    icon: Icon(Icons.volume_up),
    onPressed: null, // Widget handles tap
  ),
)

// Generate audio samples
TtsPlayerWidget(
  text: script,
  onAudioGenerated: (samples) {
    // samples is Float32List at 24kHz
    // Save or process audio...
  },
)
```

**Features:**
- Auto-downloads Supertonic model from station server on first use (~66 MB)
- Falls back to HuggingFace if no station connected
- Offline processing (no internet required after model download)
- Language matches app's I18n setting (en_US = English, pt_PT = Portuguese)
- Progress indicator during model download
- Multiple voice options (male/female variants)

**Platform Support:**
| Platform | Status | Notes |
|----------|--------|-------|
| macOS | Tested | Full support via flutter_onnxruntime |
| Android | Expected | flutter_onnxruntime supports ARM64 |
| iOS | Expected | flutter_onnxruntime supports iOS |
| Linux | Untested | May need ONNX Runtime build |

**Model Storage:**
- Location: `{data-root}/bot/models/supertonic/`
- Model: supertonic-2.onnx (~66 MB)
- Downloaded from station server or HuggingFace

**Console Integration:**
The TTS service is also available via console commands:
- `say <text>` - Speak text using TTS
- `CTRL+S` - Speak the last command output

---

## Patterns

### Platform-Adaptive WebView

**Files:**
- `lib/pages/website_browser_page.dart` — `_buildPreviewContent()`, `_loadPreview()`
- `lib/work/pages/websnapshot_viewer_page.dart` — `_useWebView`, `_extractAndLoad()`

**Pattern:** Load HTML content using native WebView on each platform for full JS support:

| Platform | Package | Widget |
|----------|---------|--------|
| Android / iOS / macOS | `webview_flutter` | `WebViewWidget(controller:)` |
| Windows | `webview_windows` | `wv_windows.Webview(controller)` |
| Linux | `webf` | `WebF.fromControllerName(bundle:)` |
| Fallback | `flutter_widget_from_html_core` | `HtmlWidget(html)` (no JS) |

```dart
// Platform check + controller init pattern:
if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
  _webViewController ??= WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..setNavigationDelegate(NavigationDelegate(
      onNavigationRequest: (r) => r.url.startsWith('file://')
          ? NavigationDecision.navigate
          : NavigationDecision.prevent,
    ));
  _webViewController!.loadFile(indexPath);
} else if (Platform.isWindows) {
  _winController ??= wv_windows.WebviewController();
  await _winController!.initialize();
  await _winController!.loadUrl(Uri.file(indexPath).toString());
} else if (Platform.isLinux) {
  // WebF uses widget-based API — increment key to force rebuild
  WebFControllerManager.instance.initialize(const WebFControllerManagerConfig(
    maxAliveInstances: 1, maxAttachedInstances: 1, enableDevTools: false,
  ));
  // Widget: WebF.fromControllerName(bundle: WebFBundle.fromUrl(Uri.file(path).toString()))
}
```

**Encrypted storage**: When files are inside encrypted `ProfileStorage`, extract the entire folder to a temp directory first (using `listDirectory(recursive: true)` + `copyToExternal()`), then load from the temp path. Clean up in `dispose()`.

### URL-Linkified SelectableText

**File:** `lib/widgets/message_bubble_widget.dart` — `_buildLinkedText()`

**Pattern:** Convert plain text containing URLs into a `SelectableText.rich()` with tappable link spans. Reusable anywhere you display user-generated text that may contain URLs.

```dart
static final _urlRegex = RegExp(
  r'(https?://[^\s<>\[\]{}|\\^`]+|www\.[^\s<>\[\]{}|\\^`]+)',
  caseSensitive: false,
);
List<TapGestureRecognizer> _linkRecognizers = [];

Widget _buildLinkedText(String text, TextStyle? baseStyle) {
  for (final r in _linkRecognizers) { r.dispose(); }
  _linkRecognizers = [];

  final matches = _urlRegex.allMatches(text).toList();
  if (matches.isEmpty) return SelectableText(text, style: baseStyle);

  final spans = <InlineSpan>[];
  int lastEnd = 0;
  for (final match in matches) {
    if (match.start > lastEnd) {
      spans.add(TextSpan(text: text.substring(lastEnd, match.start)));
    }
    final urlText = match.group(0)!;
    final launchUrl = urlText.startsWith('http') ? urlText : 'https://$urlText';
    final recognizer = TapGestureRecognizer()
      ..onTap = () => FileLauncherService().openUrl(launchUrl);
    _linkRecognizers.add(recognizer);
    spans.add(TextSpan(
      text: urlText,
      style: baseStyle?.copyWith(
        decoration: TextDecoration.underline,
        decorationColor: baseStyle.color,
      ),
      recognizer: recognizer,
    ));
    lastEnd = match.end;
  }
  if (lastEnd < text.length) {
    spans.add(TextSpan(text: text.substring(lastEnd)));
  }
  return SelectableText.rich(TextSpan(style: baseStyle, children: spans));
}

// Don't forget to dispose recognizers:
@override
void dispose() {
  for (final r in _linkRecognizers) { r.dispose(); }
  super.dispose();
}
```

**Key points:**
- `www.` URLs without a scheme get `https://` prepended before launching
- `TapGestureRecognizer` instances must be disposed to avoid memory leaks
- Recognizers are rebuilt each `build()` call (old ones disposed first)
- Uses `FileLauncherService().openUrl()` which wraps `url_launcher`

**Reuse potential**: Any feature that needs to render local HTML with JavaScript support (website preview, web snapshots, HTML-based games, documentation viewers).

### Contact Nickname Map

**File:** `lib/services/contact_service.dart` — `buildNicknameMap()`

Builds a `Map<String, String>` (uppercased callsign -> display name) from contact summaries. Useful whenever you need to resolve callsigns to human-readable names (chat bubbles, participant lists, logs, etc.).

```dart
final nicknameMap = await ContactService().buildNicknameMap();
final name = nicknameMap['X1ABCD']; // "John Doe" or null
```

Combined with `DevicesService().getDevice(callsign)?.nickname` for BLE-discovered device nicknames, this gives a two-tier resolution: device nickname (live) -> contact nickname (saved) -> raw callsign.

### Service-Specific Connectivity Checking

**Problem:** Generic internet checks (pinging google.com/cloudflare.com) raise privacy concerns and don't tell you if your specific service is actually reachable.

**Solution:** Each service checks its own endpoint rather than relying on a generic "hasInternet" flag.

**Examples:**

**MapTileService** (`lib/services/map_tile_service.dart`):
```dart
/// Check if tile server is reachable (cached for 30s)
bool get canUseInternet {
  if (_canReachTileServer != null && _lastTileServerCheck != null) {
    if (DateTime.now().difference(_lastTileServerCheck!) < Duration(seconds: 30)) {
      return _canReachTileServer!;
    }
  }
  _checkTileServerReachability(); // async, updates cache
  return _canReachTileServer ?? false;
}

Future<bool> _checkTileServerReachability() async {
  try {
    final response = await httpClient.head(
      Uri.parse('https://tile.openstreetmap.org/0/0/0.png'),
    ).timeout(const Duration(seconds: 5));
    _canReachTileServer = response.statusCode >= 200 && response.statusCode < 400;
    _lastTileServerCheck = DateTime.now();
    return _canReachTileServer!;
  } catch (e) {
    _canReachTileServer = false;
    _lastTileServerCheck = DateTime.now();
    return false;
  }
}
```

**PlaceSharingService** (`lib/services/place_sharing_service.dart`):
```dart
/// Check if relay station is reachable
Future<bool> canReachRelay() async {
  final relayUrls = getRelayUrls();
  for (final relayUrl in relayUrls) {
    try {
      final httpUrl = _stationToHttpUrl(relayUrl);
      final response = await http.head(Uri.parse(httpUrl))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode >= 200 && response.statusCode < 400) {
        return true;
      }
    } catch (e) {
      continue;
    }
  }
  return false;
}
```

**Key Benefits:**
- No privacy-concerning pings to big tech companies
- More accurate - tells you if YOUR service works, not just "internet"
- Cached results avoid repeated checks
- Lazy evaluation - only checks when needed

**NetworkMonitorService** (`lib/services/network_monitor_service.dart`) now only monitors:
- LAN availability (has private IP address)
- No longer checks generic internet connectivity

---

### BLE Connection Retry with Exponential Backoff

**Problem:** BLE connections on Linux (BlueZ) are unreliable - connections may fail, service discovery may return empty, and notification subscriptions may not take effect immediately.

**Solution:** Wrap BLE operations in retry loops with exponential backoff, and use platform-specific timeouts.

**File:** `lib/services/ble_discovery_service.dart`

**Connection Retry Pattern:**
```dart
// Platform-specific timeout: Linux/BlueZ needs more time
final connectTimeout = Platform.isLinux
    ? const Duration(seconds: 15)
    : const Duration(seconds: 10);

// Retry connection up to 3 times with exponential backoff
bool connected = false;
for (int attempt = 1; attempt <= 3; attempt++) {
  try {
    LogService().log('Connection attempt $attempt/3');
    await bleDevice.connect(timeout: connectTimeout);
    connected = true;
    break;
  } catch (e) {
    LogService().log('Attempt $attempt failed: $e');
    if (attempt == 3) rethrow;
    // Exponential backoff: 500ms, 1000ms, 1500ms
    await Future.delayed(Duration(milliseconds: 500 * attempt));
  }
}
```

**Service Discovery Retry Pattern:**
```dart
List<BluetoothService> services = [];
for (int attempt = 1; attempt <= 3; attempt++) {
  services = await bleDevice.discoverServices();
  if (services.isNotEmpty) break;
  LogService().log('Discovery attempt $attempt returned empty');
  // Exponential backoff: 300ms, 600ms, 900ms
  await Future.delayed(Duration(milliseconds: 300 * attempt));
}
```

**Safe UUID Matching (handles BlueZ short/long formats):**
```dart
BluetoothService? findGeogramService(List<BluetoothService> services) {
  const shortUUID = 'fff0';
  const fullUUID = '0000fff0-0000-1000-8000-00805f9b34fb';

  for (final service in services) {
    final uuid = service.uuid.toString().toLowerCase();
    if (uuid == fullUUID ||
        uuid == shortUUID ||
        uuid.contains(shortUUID) ||
        uuid.startsWith('0000fff0')) {
      return service;
    }
  }
  return null; // Return null instead of throwing
}
```

**Key Benefits:**
- Handles BlueZ flakiness with retries
- Platform-specific timeouts (15s for Linux vs 10s for mobile)
- Exponential backoff prevents overwhelming the BLE stack
- Safe UUID matching handles both short (fff0) and full UUID formats
- Graceful degradation instead of throwing on first failure

---

## Constants

### App Constants

**File:** `lib/util/app_constants.dart`

Centralized constants for app/collection types. This file has no Flutter dependencies so it can be used in CLI mode.

**Constants:**

| Constant | Type | Description |
|----------|------|-------------|
| `knownAppTypesConst` | `List<String>` | All known app types for URL routing |
| `singleInstanceTypesConst` | `Set<String>` | App types that can only have one instance per profile |

**knownAppTypesConst:**
Used for URL routing and collection management. Contains all app types that can be routed to via URL.

```dart
const List<String> knownAppTypesConst = [
  'www', 'blog', 'chat', 'email', 'forum', 'events', 'alerts',
  'places', 'files', 'contacts', 'groups', 'news', 'postcards',
  'market', 'station', 'documents', 'photos', 'inventory',
  'wallet', 'log', 'backup', 'console', 'tracker',
];
```

**singleInstanceTypesConst:**
App types that can only have a single instance per profile. Used by `CreateCollectionPage` to prevent duplicate creation and by `main.dart` to show default apps.

```dart
const Set<String> singleInstanceTypesConst = {
  'forum', 'chat', 'blog', 'email', 'events', 'news', 'www',
  'postcards', 'places', 'market', 'alerts', 'groups', 'backup',
  'transfer', 'inventory', 'wallet', 'log', 'console', 'tracker',
  'contacts',
};
```

**Usage:**
```dart
import '../util/app_constants.dart';

// Check if a type is single-instance
if (singleInstanceTypesConst.contains(collectionType)) {
  // Only allow one instance
}

// Check if a type is known/routable
if (knownAppTypesConst.contains(urlType)) {
  // Route to the app
}
```

**Notes:**
- `files` is the only multi-instance type (users can create multiple file collections)
- When adding a new app type, add it to both constants if it should be single-instance
- This file is used by both Flutter UI and CLI code

---

### App Type Theme

**File:** `lib/util/app_type_theme.dart`

Centralized theming utilities for app/collection types. This file has Flutter dependencies (for Icons and LinearGradient). For pure Dart constants, use `app_constants.dart`.

**Functions:**

| Function | Returns | Description |
|----------|---------|-------------|
| `getAppTypeIcon(String type)` | `IconData` | Get the icon for an app/collection type |
| `getAppTypeGradient(String type, bool isDark)` | `LinearGradient` | Get the gradient colors for an app/collection type |

**Usage:**
```dart
import '../util/app_type_theme.dart';

// Get icon for a collection type
final icon = getAppTypeIcon('email');  // Returns Icons.email

// Get gradient for a collection type
final gradient = getAppTypeGradient('email', isDark);
```

**Supported Types:**
All types from `knownAppTypesConst` are supported with consistent icons and gradients:
- chat, email, blog, forum, events, alerts, places, contacts
- groups, inventory, wallet, log, backup, console, tracker
- files, news, www, market, postcards, station, transfer

**When adding a new app type:**
1. Add the type to `knownAppTypesConst` in `app_constants.dart`
2. Add to `singleInstanceTypesConst` if it should be single-instance
3. Add icon case to `getAppTypeIcon()` in `app_type_theme.dart`
4. Add gradient case to `getAppTypeGradient()` in `app_type_theme.dart`

---

### file_image_helper

**File:** `lib/platform/file_image_helper.dart`

Platform-aware file image helper that provides FileImage support on native platforms while gracefully handling web. Supports both file-based images (for filesystem storage) and memory-based images (for encrypted storage where files stay in RAM).

**Functions:**

| Function | Returns | Description |
|----------|---------|-------------|
| `getFileImageProvider(String path)` | `ImageProvider?` | Get a FileImage provider from a file path |
| `fileExists(String path)` | `bool` | Check if a file exists at the given path |
| `buildFileImage(String path, {...})` | `Widget?` | Build an Image widget from a file path |
| `buildMemoryImage(Uint8List bytes, {...})` | `Widget?` | Build an Image widget from bytes in memory |

**Usage for filesystem storage:**
```dart
import '../platform/file_image_helper.dart' as file_helper;

// Check if file exists before displaying
if (file_helper.fileExists(imagePath)) {
  final imageWidget = file_helper.buildFileImage(
    imagePath,
    width: 280,
    height: 200,
    fit: BoxFit.cover,
  );
  if (imageWidget != null) {
    // Display the image
  }
}
```

**Usage for encrypted storage (RAM-only):**
```dart
import '../platform/file_image_helper.dart' as file_helper;

// Display image from encrypted bytes without writing to disk
final imageWidget = file_helper.buildMemoryImage(
  imageBytes,  // Uint8List from decrypted storage
  width: 280,
  height: 200,
  fit: BoxFit.cover,
);
```

**Pattern for dual-mode (encrypted + filesystem):**
```dart
// Return tuple: (path, bytes) - one will be null
Future<(String?, Uint8List?)> getAttachmentData(Message msg) async {
  if (useEncryptedStorage) {
    final bytes = await storage.getBytes(msg.file);
    return (null, bytes);  // RAM only - never write to disk
  }
  return (getFilePath(msg.file), null);  // Filesystem path
}

// Display using whichever is available
Widget? buildImage(String? path, Uint8List? bytes) {
  if (bytes != null) {
    return file_helper.buildMemoryImage(bytes, ...);
  }
  if (path != null) {
    return file_helper.buildFileImage(path, ...);
  }
  return null;
}
```

**Platform behavior:**
- **Native platforms (Linux, macOS, Windows, Android, iOS):** Full support for file operations
- **Web:** Returns null for file operations (files not accessible), memory images work

---

### DirectMessageService Message Cache

**File:** `lib/services/direct_message_service.dart`

In-memory message caching pattern to avoid repeated file I/O and expensive signature verification. The cache:
- Returns cached messages if fresh (< 5 seconds old) and has enough messages for the request
- Automatically updates cache when new messages are sent/received (incremental updates)
- Invalidates cache when conversation is deleted

**Cache Structure:**
```dart
class _MessageCache {
  List<ChatMessage> messages;
  DateTime lastLoaded;
  String? newestTimestamp;
  bool isComplete; // true if all messages loaded

  bool get isFresh => DateTime.now().difference(lastLoaded).inSeconds < 5;
  bool hasEnoughMessages(int limit) => messages.length >= limit || isComplete;
}

// Cache map: callsign -> cached messages
final Map<String, _MessageCache> _messageCache = {};
```

**Usage Pattern:**
```dart
// Cache-aware message loading
Future<List<ChatMessage>> loadMessages(String callsign, {int limit = 100}) async {
  // Check cache first
  final cache = _messageCache[callsign];
  if (cache != null && cache.isFresh && cache.hasEnoughMessages(limit)) {
    return cache.messages.take(limit).toList();
  }

  // Cache miss - load from disk
  final messages = await _loadMessagesFromDisk(callsign);

  // Update cache
  _messageCache[callsign] = _MessageCache(
    messages: messages,
    lastLoaded: DateTime.now(),
    isComplete: true,
  );

  return messages;
}

// Incremental cache update (avoids full reload)
void _addMessageToCache(String callsign, ChatMessage message) {
  final cache = _messageCache[callsign];
  if (cache != null) {
    cache.messages.add(message);
    cache.messages.sort();
    cache.lastLoaded = DateTime.now();
  }
}
```

**Benefits:**
- Second open of same conversation returns instantly from cache
- Sending/receiving messages updates cache incrementally
- No "Not responding" dialog from Android on large conversations
- Cache auto-expires after 5 seconds for freshness

---

### ChatFileDownloadManager

**File:** `lib/services/chat_file_download_manager.dart`

Unified file download manager for all chat types. Handles connection-aware auto-download thresholds, progress tracking, and resume capability.

**Features:**
- Connection-aware thresholds: BLE (100KB), LAN/WiFi/Internet (5MB)
- Progress tracking with speed display
- Resume capability for partial downloads
- Reusable across DM, remote rooms, and station rooms

**Enums:**
```dart
enum ConnectionBandwidth { ble, lan, internet }
enum ChatDownloadStatus { idle, downloading, paused, completed, failed }
```

**ChatDownload Class:**
```dart
class ChatDownload {
  final String id;              // Unique identifier (sourceId_filename)
  final String sourceId;        // Callsign or room ID
  final String filename;
  final int expectedBytes;
  int bytesTransferred = 0;
  ChatDownloadStatus status;
  double? speedBytesPerSecond;
  String? localPath;            // Final path after completion

  double get progressPercent => (bytesTransferred / expectedBytes * 100);
  String get fileSizeFormatted => _formatBytes(expectedBytes);
  String? get speedFormatted => speedBytesPerSecond != null
      ? '${_formatBytes(speedBytesPerSecond!.toInt())}/s' : null;
}
```

**Usage:**
```dart
final _downloadManager = ChatFileDownloadManager();

// Check if file should auto-download
bool _shouldShowDownloadButton(ChatMessage message) {
  final fileSize = int.tryParse(message.getMeta('file_size') ?? '0') ?? 0;
  final bandwidth = _downloadManager.getDeviceBandwidth(callsign);
  return !_downloadManager.shouldAutoDownload(bandwidth, fileSize);
}

// Start download with progress
await _downloadManager.downloadFile(
  id: '${callsign}_$filename',
  sourceId: callsign,
  filename: filename,
  expectedBytes: fileSize,
  downloadFn: (resumeFrom, onProgress) async {
    return await _dmService.downloadFileWithProgress(
      callsign, filename, resumeFrom: resumeFrom, onProgress: onProgress,
    );
  },
);

// Get current download state
final download = _downloadManager.getDownload(downloadId);

// Subscribe to progress events
EventBus().on<ChatDownloadProgressEvent>((event) {
  if (event.downloadId.startsWith(sourceId)) {
    setState(() {});
    if (event.status == 'completed') _loadMessages();
  }
});
```

**UI Integration (MessageBubbleWidget):**
```dart
MessageBubbleWidget(
  // ... existing props ...
  showDownloadButton: _shouldShowDownloadButton(message),
  fileSize: int.tryParse(message.getMeta('file_size') ?? '0'),
  downloadState: _downloadManager.getDownload(downloadId),
  onDownloadPressed: () => _onDownloadPressed(message),
  onCancelDownload: () => _onCancelDownload(message),
)
```

**Thresholds:**
| Connection | Auto-download threshold |
|------------|------------------------|
| BLE        | < 100 KB               |
| LAN/WiFi   | < 5 MB                 |
| Internet   | < 5 MB                 |

---

### TransferService

**File:** `lib/transfer/services/transfer_service.dart`  
**Spec:** `docs/apps/transfer-format-specification.md`

Centralized hub for uploads, downloads, and streaming with automatic transport switching (BLE/LAN/Internet), resume, and per-transfer records/caching.

**Usage:**
```dart
final transfer = await TransferService().requestDownload(
  const TransferRequest(
    direction: TransferDirection.download,
    callsign: 'X1ABCD',
    remotePath: '/files/photo.jpg',
    localPath: '/downloads/photo.jpg',
    expectedHash: 'sha1:abc...',
    requestingApp: 'gallery',
  ),
);
// HTTP(S) downloads follow the spec's `remoteUrl` locator (add when available).
```

**Notes:**
- Checks the transfer cache first; repeated requests return immediately on a verified cache hit (per-record `cache_hit` is set).
- Records live under `{data_dir}/transfers/records/` and are auto-pruned after 30 days; see the spec for per-transport segment format and fallback order.
- Negotiates SHA-1 with peers when possible; verification gates final file placement.
- Emits `TransferProgressEvent` / `TransferCompletedEvent` on EventBus so UIs can refresh progress and consume cache hits.

**Download helpers**
- HTTP/S: set `remoteUrl` (e.g., `https://p2p.radio/bot/models/whisper/ggml-small.bin`) and `localPath`. `remotePath` is derived automatically.
- Callsign/mesh: set `callsign` + `remotePath` (e.g., `/X1ABCD/files/doc.pdf`) and `localPath`.
- Data strings: write the string to a temp file first (or a memory buffer if you know the bytes) and use the same download/upload calls—transfer tracks bytes regardless of payload type.

**Upload helpers**
```dart
final upload = await TransferService().requestUpload(
  TransferRequest(
    direction: TransferDirection.upload,
    callsign: 'X1ABCD',
    remotePath: '/inbox/photo.jpg', // destination on peer
    localPath: '/tmp/local/photo.jpg', // source on disk
    expectedHash: 'sha1:...',
    requestingApp: 'gallery',
  ),
);
```
- For HTTP uploads to a station URL, include `stationUrl` in the `TransferRequest`.
- For raw data strings, serialize to a temp file and point `localPath` to it.

**Querying queue/cache state**
- `findTransfer(callsign: 'X1ABCD', remotePath: '/files/photo.jpg', remoteUrl: null)` returns the first active/queued/failed/completed match (or `null`).
- `isAlreadyRequested(callsign, remotePath)` is a convenience check for duplicates.
- `getTransfer(transferId)` returns the in-memory instance from active/queue/failed/completed caches.
- Status comes from `transfer.status` (`queued`, `connecting`, `transferring`, `verifying`, `completed`, `failed`, `cancelled`, `paused`, `waiting`).
- Progress: `transfer.bytesTransferred`, `transfer.expectedBytes`, `transfer.progressPercent`, `transfer.speedBytesPerSecond`, `transfer.estimatedTimeRemaining`.
- Transport and origin: `transfer.transportUsed` (e.g., `internet_http`, `ble`) and `remoteUrl`/`sourceCallsign` help other dialogs show the source and path.

**Events for UI/dialogs**
- Subscribe to `TransferProgressEvent` / `TransferCompletedEvent` / `TransferFailedEvent` on `EventBus` to refresh UI badges or dialogs.
- Each event carries `transferId`, `status`, `bytesTransferred`, `totalBytes`, and ETA so dialogs can display live percentage and state (paused/in queue/failed/cancelled/completed).

**Cleaning transfer state**
- Use `TransferService().clearAll()` to purge queue, records, metrics, and cache (also exposed in the Transfers settings UI).

---

### MirrorSyncService

**File:** `lib/services/mirror_sync_service.dart`
**Docs:** `docs/API_synch.md`

Bidirectional folder synchronization between Geogram instances using NOSTR-signed authentication.

**Usage (as source - serving sync requests):**
```dart
final mirrorService = MirrorSyncService.instance;

// Add allowed peer
mirrorService.addAllowedPeer(peerNpub, peerCallsign);

// Verify incoming request
final result = await mirrorService.verifyRequest(nostrEvent, folder);
if (result.allowed) {
  // Token returned for subsequent manifest/file requests
  print('Token: ${result.token}');
}

// Generate folder manifest
final manifest = await mirrorService.generateManifest('/path/to/folder');
```

**Usage (as destination - performing sync):**
```dart
// Bidirectional sync (sendReceive): most recent mtime wins
final result = await mirrorService.syncFolder(
  'http://192.168.1.100:3456',
  'collections/blog',
  syncStyle: SyncStyle.sendReceive,
  ignorePatterns: ['*.tmp', 'cache/*'],
);

if (result.success) {
  print('Added: ${result.filesAdded}');
  print('Modified: ${result.filesModified}');
  print('Uploaded: ${result.filesUploaded}');
  print('Downloaded: ${result.bytesTransferred} bytes');
  print('Uploaded: ${result.bytesUploaded} bytes');
}
```

**Glob matching (reusable top-level functions):**
```dart
// Check if a path matches a single glob pattern (* ? **)
bool matchesIgnorePattern(String path, String pattern);

// Check if a path matches any pattern in a list
bool isIgnored(String relativePath, List<String> patterns);
```

**Key Features:**
- NOSTR event signature verification for authentication
- SHA1 file hashing for change detection
- Bidirectional sync (`sendReceive`): mtime-wins conflict resolution
- One-way sync (`receiveOnly`): source always overwrites destination
- Per-app ignore patterns with glob matching (`*`, `**`, `?`)
- File upload to peer via `POST /api/mirror/upload`
- Token-based session management (1 hour expiry)
- Range header support for resumable downloads
- Path traversal protection

---

### MirrorAutoSyncService

**File:** `lib/services/mirror_auto_sync_service.dart`

Periodic auto-sync timer + shared `syncAllPeers()` logic with station relay fallback.

**Usage:**
```dart
// Start auto-sync (subscribes to config stream)
MirrorAutoSyncService.instance.start();

// Stop auto-sync
MirrorAutoSyncService.instance.stop();

// Trigger immediate sync (with relay fallback)
final result = await MirrorAutoSyncService.instance.syncAllPeers();
print('Added: ${result.filesAdded}, Errors: ${result.errors}');

// Check status
print(MirrorAutoSyncService.instance.toJson());
// → {active: true, interval_minutes: 15, is_syncing: false, last_sync_at: ...}
```

**Key Features:**
- Periodic timer driven by `ConnectionPreferences.autoSync` and `syncIntervalMinutes`
- Subscribes to `MirrorConfigService.configStream` for live config changes
- Direct LAN → station relay fallback (3s probe timeout)
- `MirrorSyncAllResult` with per-peer details
- Guard flag prevents overlapping syncs

---

### DnsResponder

**File:** `lib/services/dns_responder.dart`

Minimal UDP DNS responder for captive portal detection. Listens on port 53 and answers every DNS query with an A record pointing to the specified gateway IP.

**Usage:**
```dart
final dns = DnsResponder();
await dns.start('192.168.49.1');  // All DNS queries → 192.168.49.1
// ...
await dns.stop();
```

**Key Features:**
- Pure `dart:io` (no dependencies)
- Responds to all query types with A record
- 60-second TTL
- Handles multiple questions per packet

---

### HotspotPortalService

**File:** `lib/services/hotspot_portal_service.dart`

Captive portal HTTP server + DNS responder orchestration. Manages the web portal (NOT the Wi-Fi Direct hotspot — that's `WifiDirectService`).

**Usage:**
```dart
final portal = HotspotPortalService();
await portal.start(stationName: 'MyStation');
// Portal available at http://192.168.49.1:3456/
await portal.stop();
```

**Key Features:**
- HTTP server on port 3456 with captive portal detection (Android, Apple, Windows, Firefox)
- Portal serves device's own web page via `WebSocketService.handleLocalHttpRequest()`
- Download page via `StationHtmlTemplates.buildDownloadPage()`
- Debug API at `POST /api/debug/hotspot-portal` (actions: `start`, `stop`)
- DNS responder on port 53 (best-effort, needs root)

---

### Hotspot Toggle Pattern

**Files:** `lib/pages/station_dashboard_page.dart`, `lib/pages/hotspot_settings_page.dart`

Both pages share the same Wi-Fi Direct hotspot toggle pattern using `WifiDirectService`. The service talks to a single Android `MethodChannel`, so multiple Dart instances safely share the same native group.

**Pattern:**
```dart
final wifiDirect = WifiDirectService();

// Check existing state
final enabled = await wifiDirect.isHotspotEnabled();
if (enabled) {
  final info = await wifiDirect.getHotspotInfo();
}

// Toggle on (requests permissions first)
await Permission.location.request();
await Permission.nearbyWifiDevices.request();
final info = await wifiDirect.enableHotspot(stationName);

// Toggle off
await wifiDirect.disableHotspot();
```

---

### MessageRetentionService

**File:** `lib/services/message_retention_service.dart`

Shared singleton service for message retention (disappearing messages). Handles retention period configuration, message purging, and periodic cleanup. Designed to be reusable across DMs and group chat rooms.

**Key Components:**
- `RetentionPeriod` enum: `oneDay`, `oneWeek`, `oneMonth`, `oneYear`, `forever`
- `retentionLabel()`, `retentionToDuration()`, `retentionToKey()`/`keyToRetention()` — conversion helpers
- `purgeExpiredMessages(content, period)` — pure function, filters message text by timestamp
- `getRetentionForConfig(config)` / `setRetentionInConfig(config, period)` — read/write `message_retention` in config.json
- `purgeConversation(storage, path, period)` — I/O method to purge a conversation's messages.txt
- `startCleanupTimer()` / `stopCleanupTimer()` — periodic (30 min) scan of all DM conversations

**Config format:** `"message_retention": "1d"` / `"1w"` / `"1m"` / `"1y"` / `null` (forever)

**Usage:**
```dart
// Set retention for a DM conversation
await DirectMessageService().setRetention('CR7BBQ', RetentionPeriod.oneWeek);

// Pure purge (no I/O)
final filtered = MessageRetentionService().purgeExpiredMessages(rawText, RetentionPeriod.oneDay);

// Start background cleanup timer
MessageRetentionService().startCleanupTimer();
```

---

### RetentionPickerWidget

**File:** `lib/widgets/retention_picker_widget.dart`

Reusable dialog for selecting a message retention period. Returns `RetentionPeriod?` (null if cancelled).

**Usage:**
```dart
final picked = await showRetentionPicker(context, currentPeriod);
if (picked != null) {
  await DirectMessageService().setRetention(otherCallsign, picked);
}
```

---

### FileBrowserCacheService

**File:** `lib/services/file_browser_cache_service.dart`
**Models:** `lib/models/file_browser_cache_models.dart`

Singleton service for persistent caching of file browser data. Provides instant loading for previously visited folders and persistent video thumbnail storage.

**Key Features:**
- Directory listing cache (file names, sizes, modification times)
- Folder size calculations (persisted to avoid repeated scans)
- Video thumbnail ZIP archives per storage volume
- Automatic cache invalidation when directories change
- Volume-based organization (internal, USB drives, SD cards)

**Cache Directory Structure:**
```
{StorageConfig.baseDir}/file_browser_cache/
├── files_internal.json           # Directory listings for internal storage
├── files_media_USB_NAME.json     # Directory listings for removable media
├── thumbnails_internal.zip       # Thumbnail archive for internal storage
├── thumbnails_internal_meta.json # Thumbnail metadata
└── thumbnails_media_USB_NAME.zip # Thumbnail archive per volume
```

**Usage:**
```dart
final cacheService = FileBrowserCacheService();
await cacheService.initialize();

// Get cached directory listing
final cache = await cacheService.getDirectoryCache('/home/user/Pictures');
if (cache != null && !cache.isStale(currentDirModified)) {
  // Use cached entries - instant load!
  final items = cache.entries.map((e) => e.toFileSystemItem()).toList();
}

// Save directory cache after scanning
await cacheService.saveDirectoryCache(path, entries, dirModified);

// Folder sizes
final size = await cacheService.getCachedFolderSize('/path/to/folder');
await cacheService.saveFolderSize('/path/to/folder', calculatedSize);

// Thumbnails
if (await cacheService.hasThumbnail(videoPath, sourceModified)) {
  final thumbPath = await cacheService.getThumbnailTempPath(videoPath);
} else {
  await cacheService.saveThumbnail(videoPath, pngBytes, sourceModified);
}

// Volume detection
final volumeId = cacheService.getVolumeId('/media/user/USB_NAME/file.mp4');
// Returns: "media_USB_NAME"

// Clear cache for unmounted volume
await cacheService.clearVolumeCache('media_USB_NAME');
```

**Volume Detection Logic:**
| Path Pattern | Volume ID |
|--------------|-----------|
| `/storage/emulated/0/...` | `internal` |
| `/storage/XXXX-XXXX/...` | `sdcard_XXXX-XXXX` |
| `$HOME/...` | `internal` |
| `/media/user/NAME/...` | `media_NAME` |
| `/mnt/NAME/...` | `mnt_NAME` |
| Other | `default` |

**Cache Invalidation:**
- Directory cache: Compare `Directory.stat().modified` with stored timestamp
- Thumbnail cache: Compare source file's `modified` with stored `sourceModified`
- Automatic flush to disk with 2-second debounce for batching

---

## CLI/Console Abstractions

### ConsoleIO

**File:** `lib/cli/console_io.dart`

Platform-agnostic interface for console I/O. Allows the same command logic to work across different platforms.

**Implementations:**
- `CliConsoleIO` (`lib/cli/console_io_cli.dart`) - CLI mode using stdin/stdout
- `BufferConsoleIO` (`lib/cli/console_io_buffer.dart`) - Buffer-based for Flutter UI and async platforms

**Interface:**
```dart
abstract class ConsoleIO {
  void writeln([String text = '']);
  void write(String text);
  Future<String?> readLine();
  Future<int> readByte();
  void clear();
  set echoMode(bool value);
  set lineMode(bool value);
  bool get supportsRawMode;
  String? getOutput();
  void clearOutput();
}
```

**Usage - CLI Mode:**
```dart
final io = CliConsoleIO();
io.writeln('Hello, world!');
final input = await io.readLine();
```

**Usage - Flutter/Buffer Mode:**
```dart
final io = BufferConsoleIO();
io.writeln('Hello, world!');
final output = io.getOutput(); // Returns collected output
io.clearOutput();
```

---

### ConsoleHandler

**File:** `lib/cli/console_handler.dart`

Shared command logic for all console interfaces. Platform-agnostic - uses ConsoleIO for I/O.

**Service Interfaces:**
- `ProfileServiceInterface` - Profile management operations
- `StationServiceInterface` - Station server control

**Commands Supported:**
- Navigation: `ls`, `cd`, `pwd`
- Profile: `profile list`, `profile switch`, `profile create`, `profile info`
- Station: `station start`, `station stop`, `station status`, `station port`, `station cache`
- Games: `games list`, `games info`, `play <name>`
- General: `help`, `status`, `clear`, `quit`

**Virtual Filesystem:**
- `/profiles/` - Profile management
- `/config/` - Configuration
- `/logs/` - Log files
- `/station/` - Station control
- `/games/` - Text adventure games

**Usage:**
```dart
final io = BufferConsoleIO();
final handler = ConsoleHandler(
  io: io,
  profileService: MyProfileServiceAdapter(),
  stationService: MyStationServiceAdapter(),
  gameConfig: GameConfig(),
);

// Process command
await handler.processCommand('station status');
final output = io.getOutput();
```

**Adding New Platforms:**
To add support for a new platform (e.g., Telegram):

1. Create a new ConsoleIO implementation:
```dart
class TelegramConsoleIO implements ConsoleIO {
  final TelegramBot bot;
  final int chatId;
  final StringBuffer _output = StringBuffer();

  @override
  void writeln([String text = '']) => _output.writeln(text);

  @override
  String? getOutput() => _output.toString();

  // Implement other methods...
}
```

2. Create service adapters for your platform
3. Instantiate ConsoleHandler with your ConsoleIO

---

### ConsoleCompleter

**File:** `lib/cli/console_completer.dart`

Shared TAB completion logic for console interfaces. Used by both CLI and Flutter UI.

**Key Classes:**
- `Candidate` - Completion candidate with value, display text, and grouping
- `CompletionResult` - Result of a completion operation (completed text, candidates)
- `CompletionDataProvider` - Interface for dynamic data (profiles, devices, chat rooms)
- `ConsoleCompleter` - Main completion logic

**Features:**
- Command completion (global and context-aware)
- Sub-command completion with descriptions
- Virtual filesystem path completion
- Game file completion
- Profile callsign completion

**Usage:**
```dart
final completer = ConsoleCompleter(
  gameConfig: myGameConfig,
  dataProvider: myDataProvider,
  rootDirs: ['profiles', 'config', 'logs', 'station', 'games'],
);

final result = completer.complete('play tu', '/games');
if (result.exactMatch) {
  // Single match - use result.completedText
} else if (result.candidates.isNotEmpty) {
  // Multiple matches - display candidates
  final lines = completer.formatCandidatesForDisplay(result.candidates);
}
```

**Implementing CompletionDataProvider:**
```dart
class MyDataProvider implements CompletionDataProvider {
  @override
  List<String> getConnectedCallsigns() => ['ABC123', 'XYZ789'];

  @override
  Map<String, String> getChatRooms() => {'room1': 'General'};

  @override
  List<({String callsign, String? nickname, bool isStation})> getProfiles() {
    return [(callsign: 'ABC123', nickname: 'Alice', isStation: false)];
  }
}
```

---

### LogService Isolate Reading

**File:** `lib/services/log_service_native.dart`

Read large log files off the UI thread using Flutter's `compute()` function for isolate-based processing.

**Classes:**
- `LogReadResult` - Result containing lines, total count, and truncation status
- `_LogReadParams` - Parameters for the isolate function

**Method:**
```dart
Future<LogReadResult> readTodayLogAsync({int maxLines = 1000})
```

**Usage:**
```dart
// Read log lines in isolate (non-blocking)
final result = await LogService().readTodayLogAsync(maxLines: 1000);

// Access results
print('Lines: ${result.lines.length}');
print('Total: ${result.totalLines}');
print('Truncated: ${result.truncated}');

// Display with ListView.builder for performance
ListView.builder(
  itemCount: result.lines.length,
  itemBuilder: (context, index) => Text(result.lines[index]),
);
```

**Performance Notes:**
- Uses `compute()` to read files in a separate isolate
- Returns only the last N lines (default 1000) to limit memory
- Indicates if log was truncated for UI display
- Combines with `ListView.builder` for efficient rendering of large log files

---

## Summary Table

| Component | Location | Type | Main Use |
|-----------|----------|------|----------|
| UserPickerWidget | widgets/ | Picker | Select users from devices |
| CurrencyPickerWidget | widgets/wallet/ | Picker | Select currencies |
| TypeSelectorWidget | widgets/inventory/ | Picker | Select inventory types |
| PhotoViewerPage | pages/ | Viewer | Image & video gallery |
| DocumentViewerWidget | pages/ | Widget | Embeddable document viewer (no Scaffold) |
| DocumentViewerEditorPage | pages/ | Viewer | PDF, text, markdown (wraps DocumentViewerWidget) |
| LocationPickerPage | pages/ | Picker | Map location selection |
| PlacePickerPage | pages/ | Picker | Place selection with distance/time sorting |
| ContactPickerPage | pages/ | Picker | Contact selection with A-Z/recent sorting |
| ContractDocumentPage | pages/ | Viewer | Markdown document |
| VoicePlayerWidget | widgets/ | Player | Voice messages |
| MusicPlayerWidget | widgets/ | Player | Music tracks |
| VoiceRecorderWidget | widgets/ | Recorder | Record voice |
| NewChannelDialog | widgets/ | Dialog | Create chat channels |
| NewThreadDialog | widgets/ | Dialog | Create forum threads |
| AddTrackableDialog | tracker/dialogs/ | Dialog | Add exercise or measurement entries |
| CallsignSelectorWidget | widgets/ | Selector | Profile switching |
| ProfileSwitcher | widgets/ | Selector | App bar profile |
| TrackerMapCard | tracker/widgets/ | Map | Satellite map miniature with markers |
| FolderTreeWidget | widgets/inventory/ | Tree | Folder navigation |
| MessageBubbleWidget | widgets/ | Message | Chat bubbles |
| MessageInputWidget | widgets/ | Input | Message composer |
| LocationService | services/ | Service | City lookup from coordinates |
| LocationProviderService | services/ | Service | Shared GPS positioning for all apps |
| PathRecordingService | tracker/services/ | Service | GPS path recording (uses LocationProviderService) |
| PlaceService.findPlacesWithinRadius | services/ | Service | Find places within GPS radius |
| WebNavigation | util/ | Web Theme | Dynamic navigation menu generator (shared) |
| StationHtmlTemplates | util/ | Web Theme | Shared HTML builders for station/device pages |
| getChatPageScripts | util/ | Web Theme | Reusable chat page JavaScript (shared) |
| QrShareReceiveWidget | widgets/ | QR | Share/receive data via QR |
| TranscribeButtonWidget | widgets/ | Input | Voice-to-text for text fields |
| App Constants | util/ | Constants | Centralized app type definitions |
| App Type Theme | util/ | Utility | Centralized icons and gradients for app types |
| ConsoleIO | cli/ | Interface | Platform-agnostic console I/O |
| ConsoleHandler | cli/ | Service | Shared command logic for CLI/UI/Telegram |
| ConsoleCompleter | cli/ | Service | Shared TAB completion logic |
| LogService.readTodayLogAsync | services/ | Service | Read logs off UI thread in isolate |
| StunServerService | services/ | Service | Self-hosted STUN server for WebRTC |
| GeoIpService | services/ | Service | Offline IP geolocation using MMDB database |

## GeoIpService

Privacy-preserving offline IP geolocation using DB-IP MMDB database.

**Location**: `lib/services/geoip_service.dart`

### Station API Endpoint

Stations expose `/api/geoip` endpoint that:
1. Extracts client IP from HTTP request
2. Looks up IP in local MMDB database
3. Returns JSON: `{ip, latitude, longitude, city, country, countryCode}`

### Client Usage Pattern

Clients call the connected station's `/api/geoip` endpoint:

```dart
// Get connected station URL and convert to HTTP
final stationUrl = WebSocketService().connectedUrl;
if (stationUrl == null) return null;

final httpUrl = stationUrl
    .replaceFirst('wss://', 'https://')
    .replaceFirst('ws://', 'http://');

final response = await http.get(Uri.parse('$httpUrl/api/geoip'));
if (response.statusCode == 200) {
  final data = json.decode(response.body);
  final lat = (data['latitude'] as num?)?.toDouble();
  final lon = (data['longitude'] as num?)?.toDouble();
  // Use lat, lon, data['city'], data['country']
}
```

### Files Using This Pattern
- `lib/util/geolocation_utils.dart`
- `lib/services/user_location_service.dart`
- `lib/services/location_service.dart`
- `lib/pages/maps_browser_page.dart`
- `lib/pages/location_page.dart`
- `lib/pages/stations_page.dart`
- `lib/cli/cli_location_service.dart`

### Station-Side Initialization
- Flutter station: `GeoIpService().initFromAssets()` (loads from Flutter assets)
- CLI station: `GeoIpService().initFromFile(path)` (loads from filesystem)

## ChatFileUploadManager

Singleton service for tracking file uploads (sender-side progress when serving files to receivers).

**Location**: `lib/services/chat_file_upload_manager.dart`

### Purpose

In the pull model for BLE file transfers:
1. Sender stores file locally and sends message with metadata
2. Receiver sees download button and requests file on demand
3. Sender serves the file when receiver requests it
4. **ChatFileUploadManager tracks the serving progress for sender's UI**

### Upload States

```dart
enum ChatUploadStatus {
  pending,     // File sent, waiting for receiver to request
  uploading,   // Transfer in progress (receiver downloading)
  completed,   // File fully transferred
  failed,      // Transfer failed (can retry)
}
```

### Key Features

1. **Progress Tracking**: Tracks bytes transferred, speed, percentage
2. **Auto-Resume**: Listens for `DeviceStatusChangedEvent` and auto-retries failed uploads when device reconnects
3. **Event Bus Integration**: Fires `ChatUploadProgressEvent` for UI updates
4. **Retry Support**: `requestRetry()` sends notification to receiver to re-request file

### Usage Pattern

**1. Initialize in page state:**
```dart
final ChatFileUploadManager _uploadManager = ChatFileUploadManager();

@override
void initState() {
  _uploadManager.initialize(); // Start listening for device reconnections
}
```

**2. Subscribe to upload events:**
```dart
EventBus().on<ChatUploadProgressEvent>((event) {
  if (event.receiverCallsign == targetCallsign) {
    setState(() {}); // Refresh UI
  }
});
```

**3. Get upload state for a message:**
```dart
ChatUpload? getUploadState(ChatMessage message) {
  if (!message.hasFile) return null;
  return _uploadManager.getUploadForFile(
    receiverCallsign,
    message.attachedFile!,
  );
}
```

**4. Handle retry button:**
```dart
Future<void> onRetryUpload(ChatMessage message) async {
  final success = await _uploadManager.requestRetry(
    receiverCallsign,
    message.attachedFile!,
  );
}
```

### Server-Side Integration

In `log_api_service.dart`, the GET file handler tracks progress:

```dart
// In _handleDMFileGetRequest:
uploadManager.startUpload(receiverCallsign, filename, totalBytes);

Stream<List<int>> fileStream() async* {
  for (var offset = 0; offset < totalBytes; offset += chunkSize) {
    final chunk = fileBytes.sublist(offset, end);
    bytesSent += chunk.length;
    uploadManager.updateProgress(receiverCallsign, filename, bytesSent);
    yield chunk;
  }
  uploadManager.completeUpload(receiverCallsign, filename);
}
```

### ChatUpload Data Model

```dart
class ChatUpload {
  final String id;              // "{receiverCallsign}_{filename}"
  final String messageId;
  final String receiverCallsign;
  final String filename;
  final int totalBytes;
  int bytesTransferred;
  ChatUploadStatus status;
  double? speedBytesPerSecond;
  String? error;
  int retryCount;

  double get progressPercent;
  String get fileSizeFormatted;
  String get bytesTransferredFormatted;
  String? get speedFormatted;
}
```

### Related Components

| Component | Location | Purpose |
|-----------|----------|---------|
| ChatUploadProgressEvent | util/event_bus.dart | Event for UI updates |
| DeviceStatusChangedEvent | util/event_bus.dart | Triggers auto-resume |
| ChatFileDownloadManager | services/ | Similar pattern for downloads |
| MessageBubbleWidget | widgets/ | Shows upload progress UI |
| DMChatPage | pages/ | Integrates upload tracking |

---

## GeogramApi

**Location**: `lib/api/api.dart`

Unified, transport-agnostic API facade for device-to-device communication. All operations require a target callsign and are routed through `ConnectionManager` to the best available transport (LAN, BLE, Station relay).

### Basic Usage

```dart
final api = GeogramApi();

// Get device status
final status = await api.status.get('X3STATION');
if (status.success) {
  print('Device: ${status.data!.callsign}');
}

// List alerts with filtering
final alerts = await api.alerts.list('X3STATION',
  lat: 40.7128,
  lon: -74.0060,
  radius: 10, // km
);

// Send feedback
await api.feedback.pointAlert('X3STATION', alertId, signedEvent);
```

### Available Endpoint Modules

| Module | File | Purpose |
|--------|------|---------|
| `api.status` | endpoints/status_api.dart | Device status, GeoIP |
| `api.chat` | endpoints/chat_api.dart | Chat rooms, messages, files |
| `api.dm` | endpoints/dm_api.dart | Direct messages, sync |
| `api.alerts` | endpoints/alerts_api.dart | Alerts listing, details |
| `api.places` | endpoints/places_api.dart | Places listing, details |
| `api.events` | endpoints/events_api.dart | Events, media uploads |
| `api.blog` | endpoints/blog_api.dart | Blog posts, comments |
| `api.videos` | endpoints/videos_api.dart | Videos, categories |
| `api.feedback` | endpoints/feedback_api.dart | Points, likes, comments |
| `api.backup` | endpoints/backup_api.dart | Backup providers, snapshots |
| `api.updates` | endpoints/updates_api.dart | Version updates |

### Response Handling

All API calls return `ApiResponse<T>` with success/error handling:

```dart
final response = await api.alerts.list('X3STATION');

if (response.success) {
  final alerts = response.data!;
  print('Found ${alerts.length} alerts');
} else {
  print('Error: ${response.error?.message}');
}

// Or use helper methods
final alerts = response.dataOr([]);  // Default if null
final alert = response.dataOrThrow;  // Throws if failed
```

### List Responses with Pagination

```dart
final response = await api.blog.list('X3STATION', limit: 10, offset: 0);

print('Got ${response.count} posts');
print('Total: ${response.total}');
print('Has more: ${response.hasMore}');
```

### Path Utilities (from ChatApi)

The ChatApi includes static path builders (merged from `lib/util/chat_api.dart`):

```dart
// Build paths
final path = ChatApi.messagesPath('general');  // /api/chat/general/messages
final url = ChatApi.remoteMessagesUrl(baseUrl, 'X3ABC', 'general');

// Pattern matching
if (ChatApi.isMessagesPath(request.path)) {
  final roomId = ChatApi.extractRoomId(request.path);
}
```

### Transport-Agnostic Design

The API automatically routes through the best available transport:

1. **LAN** (priority 10) - Direct HTTP on local network
2. **BLE** (priority 20) - Bluetooth mesh for offline
3. **Station** (priority 30) - WebSocket relay via station

```dart
// Check device reachability
final reachable = await api.isReachable('X3DEVICE');
final transports = await api.getAvailableTransports('X3DEVICE');
// Returns: ['lan', 'station']
```

### Direct Messaging via ConnectionManager

For NOSTR-signed messages that need proper transport routing:

```dart
// Send DM (queued if offline)
await api.sendDirectMessage('X1TARGET', signedEvent,
  queueIfOffline: true,
  ttl: Duration(hours: 24),
);

// Send chat message
await api.sendChatMessage('X3STATION', 'general', signedEvent);
```

### Error Handling

```dart
final response = await api.status.get('X3OFFLINE');

if (!response.success) {
  final error = response.error!;

  if (error.isNetworkError) {
    print('Device unreachable');
  } else if (error.isNotFound) {
    print('Resource not found');
  } else if (error.isUnauthorized) {
    print('Auth required');
  }
}
```

### Related Components

| Component | Location | Purpose |
|-----------|----------|---------|
| ConnectionManager | connection/connection_manager.dart | Transport routing |
| Transport | connection/transport.dart | Transport interface |
| TransportResult | connection/transport_message.dart | Result type |
| ApiResponse | api/api_response.dart | Generic response wrapper |
| ApiError | api/api_error.dart | Error types |

---

## API Common Utilities (`lib/api/common/`)

Shared utilities for API handlers to avoid code duplication across alert, place, blog, and feedback handlers.

### GeometryUtils

**File:** `lib/api/common/geometry_utils.dart`

Calculate distances between GPS coordinates using the Haversine formula.

```dart
import 'package:geogram/api/common/geometry_utils.dart';

// Calculate distance in kilometers
final distance = GeometryUtils.calculateDistanceKm(
  40.7128, -74.0060,  // lat1, lon1 (New York)
  34.0522, -118.2437, // lat2, lon2 (Los Angeles)
);
print('Distance: ${distance.toStringAsFixed(2)} km'); // 3935.75 km
```

### FileTreeBuilder

**File:** `lib/api/common/file_tree_builder.dart`

Build recursive file tree structures for sync operations. Used by alert and place APIs to return file metadata.

```dart
import 'package:geogram/api/common/file_tree_builder.dart';

// Build file tree for a directory
final tree = await FileTreeBuilder.build('/path/to/alert/folder');
// Returns:
// {
//   'report.txt': {'size': 1024, 'mtime': 1706000000},
//   'images/': {
//     'photo1.jpg': {'size': 204800, 'mtime': 1706000100},
//   }
// }
```

### StationInfo

**File:** `lib/api/common/station_info.dart`

Station metadata for API responses. Identifies which station served the request.

```dart
import 'package:geogram/api/common/station_info.dart';

final station = StationInfo(
  name: 'My Station',
  callsign: 'X3ABC',
  npub: 'npub1...',
);

// Include in API response
final response = {
  'success': true,
  'station': station.toJson(),
  'data': [...],
};
```

**Also exported from:** `lib/api/handlers/alert_handler.dart` for backward compatibility.

### Usage in Handlers

```dart
// In AlertHandler
final distance = GeometryUtils.calculateDistanceKm(lat, lon, alertLat, alertLon);
final fileTree = await FileTreeBuilder.build(alertDir.path);

// In PlaceHandler
final distance = GeometryUtils.calculateDistanceKm(lat, lon, placeLat, placeLon);
final fileTree = await FileTreeBuilder.build(placePath);
```

---

## Server Chat Models (`lib/server/models/`)

Server-side models for chat room management with WebSocket support. These are distinct from client-side models used for file parsing.

### ServerChatRoom

**File:** `lib/server/models/server_chat_room.dart`

Server-side chat room model for managing chat rooms with WebSocket clients.

```dart
import 'package:geogram/server/models/server_chat_room.dart';

// Create a new room
final room = ServerChatRoom(
  id: 'general',
  name: 'General Chat',
  description: 'Public discussion room',
  creatorCallsign: 'X3ABC',
  isPublic: true,
);

// Add messages
room.messages.add(message);
room.lastActivity = DateTime.now().toUtc();

// Serialize
final json = room.toJson();  // Without messages
final fullJson = room.toJsonWithMessages();  // With messages
```

### ServerChatMessage

**File:** `lib/server/models/server_chat_message.dart`

Server-side chat message model with NOSTR signature verification support.

```dart
import 'package:geogram/server/models/server_chat_message.dart';

// Create a signed message
final message = ServerChatMessage(
  id: eventId,  // NOSTR event ID
  roomId: 'general',
  senderCallsign: 'X3ABC',
  senderNpub: 'npub1...',
  signature: signatureHex,
  content: 'Hello world!',
  timestamp: DateTime.now().toUtc(),
  verified: true,
);

// Parse from API response
final msg = ServerChatMessage.fromJson(json, 'general');

// Serialize
final json = message.toJson();
```

### Model Comparison

| Model | Location | Purpose |
|-------|----------|---------|
| `ServerChatRoom` | lib/server/models/ | Server-side room management |
| `ServerChatMessage` | lib/server/models/ | Server-side message storage |
| `ChatMessage` | lib/models/chat_message.dart | Client-side file parsing |
| `ChatRoom`/`ChatMessage` | lib/api/endpoints/chat_api.dart | API response DTOs |

### Usage in pure_station.dart

```dart
// Type aliases for backward compatibility
typedef ChatRoom = ServerChatRoom;
typedef ChatMessage = ServerChatMessage;

// Room management
final Map<String, ChatRoom> _chatRooms = {};
_chatRooms['general'] = ChatRoom(
  id: 'general',
  name: 'General',
  creatorCallsign: callsign,
);
```

---

## Station Server Base (`lib/server/`)

A unified server architecture that both CLI (PureStationServer) and App (StationServerService) implementations extend. Provides feature parity across platforms through shared base class and mixins.

### Consolidation Progress

The codebase has two parallel station server implementations being consolidated:

| Component | `PureStationServer` | `lib/server/` | Status |
|-----------|---------------------|---------------|--------|
| Alert/Place/Feedback APIs | Uses AlertHandler, PlaceHandler, FeedbackHandler | Uses AlertHandler, PlaceHandler, FeedbackHandler | **Shared** |
| Chat models | Uses ServerChatRoom, ServerChatMessage | Uses ServerChatRoom, ServerChatMessage | **Shared** |
| Rate limit class | Uses IpRateLimit from mixin | Defines IpRateLimit in mixin | **Shared** |
| Geometry utils | Uses GeometryUtils | Uses GeometryUtils | **Shared** |
| File tree builder | Uses FileTreeBuilder | Uses FileTreeBuilder | **Shared** |
| Station info | Uses StationInfo | Uses StationInfo | **Shared** |
| Rate limit logic | Private `_checkRateLimit()` | RateLimitMixin | Duplicate |
| Health watchdog | Private `_runHealthWatchdog()` | HealthWatchdogMixin | Duplicate |
| SSL/HTTPS | Private SSL methods | SslMixin | Duplicate |
| Chat room management | 12+ methods | Not in base | PureStationServer only |

**Migration path:** PureStationServer (12,000+ lines) will incrementally adopt mixins from `lib/server/mixins/` to reduce duplication. Current focus is on sharing data classes and utilities.

**Full plan:** See [docs/consolidation-plan.md](consolidation-plan.md) for detailed phases 4-8 covering:
- Phase 4: Adopt RateLimitMixin and HealthWatchdogMixin (~250 lines)
- Phase 5: Extract HTTP handlers to shared modules (~450 lines)
- Phase 6: Extract update/model mirroring services (~600 lines)
- Phase 7: Consolidate SSL/certificate management (~500 lines)
- Phase 8: WebSocket message routing (~200 lines)

### Directory Structure

```
lib/server/
├── station_settings.dart      # Unified settings class
├── station_client.dart        # Connected client model
├── station_tile_cache.dart    # LRU tile cache
├── station_stats.dart         # Server statistics
├── platform_adapter.dart      # Platform abstraction interface
├── station_server_base.dart   # Abstract base class
├── handlers/                  # HTTP handler modules
│   ├── status_handler.dart    # /api/status endpoints
│   ├── tile_handler.dart      # /tiles/* endpoints
│   ├── update_handler.dart    # /updates/* endpoints
│   └── blossom_handler.dart   # /blossom/* endpoints
├── models/                    # Server-side data models
│   ├── server_chat_room.dart  # Chat room model
│   └── server_chat_message.dart # Chat message model
└── mixins/                    # Feature mixins
    ├── rate_limit_mixin.dart  # IP rate limiting + banning
    ├── health_watchdog_mixin.dart  # Auto-recovery
    ├── ssl_mixin.dart         # HTTPS + Let's Encrypt
    ├── smtp_mixin.dart        # SMTP server
    └── stun_mixin.dart        # WebRTC STUN server
```

### Usage - Extending Base Class

```dart
class MyStationServer extends StationServerBase
    with SslMixin, RateLimitMixin, HealthWatchdogMixin {

  @override
  void log(String level, String message) {
    print('[$level] $message');
  }

  @override
  Future<void> saveSettingsToStorage() async {
    // Save _settings to disk/prefs
  }

  @override
  Future<bool> handlePlatformRoute(HttpRequest request, String path, String method) async {
    // Handle platform-specific routes
    if (path == '/my/special/route') {
      // Handle it
      return true; // Handled
    }
    return false; // Not handled, continue to base routing
  }
}
```

### Unified Settings

```dart
final settings = StationSettings(
  httpPort: 8080,
  httpsPort: 8443,
  enableSsl: true,
  sslDomain: 'mystation.example.com',
  tileServerEnabled: true,
  stunServerEnabled: true,
  maxConnectedDevices: 100,
);

// Save/load via JSON
final json = settings.toJson();
final restored = StationSettings.fromJson(json);
```

### Rate Limiting Mixin

```dart
class MyServer extends StationServerBase with RateLimitMixin {
  void handleRequest(HttpRequest request) {
    final ip = request.connectionInfo?.remoteAddress.address ?? 'unknown';

    if (isIpBanned(ip)) {
      // Return 429
      return;
    }

    if (!checkRateLimit(ip)) {
      banIp(ip); // Exponential backoff: 5min -> 15min -> 1hr -> 24hr
      return;
    }

    // Process request...
  }
}
```

### Health Watchdog Mixin

```dart
class MyServer extends StationServerBase with HealthWatchdogMixin {
  @override
  int get httpPort => settings.httpPort;

  @override
  bool get isServerRunning => _running;

  @override
  int get connectedClientsCount => _clients.length;

  @override
  Future<void> autoRecover() async {
    // Restart HTTP server
    await stopServer();
    await startServer();
  }

  @override
  void logCrash(String reason) {
    log('CRASH', reason);
  }
}

// Watchdog monitors:
// - Self health check (HTTP request to own /api/status)
// - Attack detection (high request/error rates, connection exhaustion)
```

### Tile Handler

```dart
final tileHandler = TileHandler(
  getSettings: () => settings,
  tileCache: tileCache,
  stats: stats,
  tilesDirectory: '/data/tiles',
  log: (level, msg) => print('[$level] $msg'),
);

// Handles:
// - GET /tiles/{z}/{x}/{y}.png
// - Memory cache + disk cache
// - OSM fallback fetch
// - Tile validation (PNG/JPEG headers)
```

### Related Components

| Component | Location | Purpose |
|-----------|----------|---------|
| StationSettings | server/station_settings.dart | Unified configuration |
| StationClient | server/station_client.dart | WebSocket client model |
| StationTileCache | server/station_tile_cache.dart | LRU tile cache |
| RateLimitMixin | server/mixins/rate_limit_mixin.dart | IP rate limiting |
| SslMixin | server/mixins/ssl_mixin.dart | HTTPS support |
| HealthWatchdogMixin | server/mixins/health_watchdog_mixin.dart | Auto-recovery |
| EmailHandlerMixin | server/mixins/email_handler_mixin.dart | Shared email send/receive/delivery |
| BlogHandlerMixin | server/mixins/blog_handler_mixin.dart | Blog URL resolution, NIP-05 callsign lookup, local/proxy serving |

---

## Storage Path Helpers

### getChatDir

**Files:**
- `lib/services/storage_config.dart` (App)
- `lib/cli/pure_storage_config.dart` (CLI)

Get the canonical chat directory path for a specific callsign. Ensures consistent paths across App and CLI servers.

**Signature:**
```dart
String getChatDir(String callsign)
```

**Returns:** `{baseDir}/devices/{sanitizedCallsign}/chat`

**Usage:**
```dart
// App mode
final chatPath = StorageConfig().getChatDir('KB1ABC');
// Result: /home/user/.local/share/geogram/devices/KB1ABC/chat

// CLI mode
final chatPath = PureStorageConfig().getChatDir('KB1ABC');
// Result: /opt/geogram/devices/KB1ABC/chat
```

**Canonical Directory Structure:**
```
{baseDir}/
├── config.json
├── station_config.json
├── devices/                    # Per-callsign data
│   └── {CALLSIGN}/
│       ├── alerts/
│       ├── blog/
│       ├── chat/              # Chat rooms stored here
│       ├── events/
│       ├── places/
│       └── videos/
├── tiles/
├── ssl/
├── logs/
├── updates/
└── nostr/
```

**Related Helpers:**
| Helper | Returns |
|--------|---------|
| `getCallsignDir(callsign)` | `{baseDir}/devices/{callsign}` |
| `devicesDir` | `{baseDir}/devices` |
| `tilesDir` | `{baseDir}/tiles` |
| `sslDir` | `{baseDir}/ssl` |
| `logsDir` | `{baseDir}/logs` |

---

## Reader Services (`lib/reader/services/`)

The Reader app provides an e-reader with source-based architecture supporting RSS feeds, Manga, and Books.

### RssService

**File:** `lib/reader/services/rss_service.dart`

Parse RSS 2.0 and Atom feeds, convert HTML content to Markdown.

**Usage:**
```dart
final rssService = RssService();

// Parse feed from URL
final items = await rssService.parseFeed('https://example.com/feed.xml');
for (final item in items) {
  print('${item.title} - ${item.publishedAt}');
}

// Convert HTML to Markdown
final markdown = rssService.htmlToMarkdown('<p>Hello <b>world</b></p>');
// Result: "Hello **world**"

// Download and convert article content
final content = await rssService.fetchArticleContent('https://example.com/article');
```

**RssFeedItem Fields:**
| Field | Type | Description |
|-------|------|-------------|
| `id` | String | Unique identifier |
| `title` | String | Article title |
| `link` | String | Article URL |
| `description` | String? | Summary/excerpt |
| `content` | String? | Full content (if available) |
| `author` | String? | Author name |
| `publishedAt` | DateTime? | Publish date |
| `categories` | List<String> | Categories/tags |
| `imageUrl` | String? | Featured image |

---

### MangaService

**File:** `lib/reader/services/manga_service.dart`

Handle CBZ (Comic Book ZIP) files: extraction, page caching, chapter creation.

**Usage:**
```dart
final mangaService = MangaService();

// Extract pages from CBZ file
final pages = await mangaService.extractPages('/path/to/chapter.cbz');
for (final page in pages) {
  // page.data is Uint8List of image bytes
  // page.filename is the original filename
  Image.memory(page.data);
}

// Get chapter files from manga folder
final chapters = await mangaService.getChapterFiles('/path/to/manga/series');
// Returns sorted list: ['chapter-001.cbz', 'chapter-002.cbz', ...]

// Create CBZ from downloaded images
await mangaService.createCbz(
  outputPath: '/path/to/chapter-001.cbz',
  images: imageBytesList,  // List<Uint8List>
);

// Clear page cache to free memory
mangaService.clearCache();
```

**MangaPage Fields:**
| Field | Type | Description |
|-------|------|-------------|
| `filename` | String | Original image filename |
| `data` | Uint8List | Image bytes |
| `width` | int? | Image width (if detected) |
| `height` | int? | Image height (if detected) |

**CBZ Format Notes:**
- CBZ is a ZIP archive containing image files
- Images sorted alphanumerically by filename
- Supports: JPG, PNG, GIF, WEBP
- Naming convention: `chapter-001.cbz`, `chapter-002.cbz`

---

### SourceService

**File:** `lib/reader/services/source_service.dart`

Discover and parse source.js configuration files for RSS and Manga sources.

**Usage:**
```dart
final sourceService = SourceService();

// Discover all sources in a category
final rssSources = await sourceService.discoverSources('/path/to/reader/rss');
final mangaSources = await sourceService.discoverSources('/path/to/reader/manga');

for (final source in rssSources) {
  print('${source.name} (${source.type}) - ${source.url}');
}

// Load source configuration
final config = await sourceService.loadSourceConfig('/path/to/reader/rss/hackernews');
print(config.name);       // "Hacker News"
print(config.feedUrl);    // "https://news.ycombinator.com/rss"
```

**Source Configuration (source.js):**
```javascript
// reader/rss/hackernews/source.js
module.exports = {
  name: "Hacker News",
  type: "rss",
  url: "https://news.ycombinator.com/rss",
  settings: {
    maxPosts: 100,
    fetchIntervalHours: 1,
    downloadImages: true
  }
};
```

**Source Fields:**
| Field | Type | Description |
|-------|------|-------------|
| `id` | String | Source folder name |
| `name` | String | Display name |
| `type` | SourceType | rss, manga, or local |
| `url` | String? | Feed/API URL |
| `isLocal` | bool | True for local-only sources |

---

### ReaderService

**File:** `lib/reader/services/reader_service.dart`

Main orchestrating service for the Reader app. Manages sources, content, and reading progress.

**Usage:**
```dart
final readerService = ReaderService();

// Initialize with collection path
await readerService.initialize('/path/to/reader');

// RSS Operations
final rssSources = await readerService.getRssSources();
final posts = await readerService.getPosts('hackernews');
await readerService.markPostRead('hackernews', 'post-slug');
await readerService.togglePostStarred('hackernews', 'post-slug');

// Manga Operations
final mangaSources = await readerService.getMangaSources();
final series = await readerService.getMangaSeries('mangadex');
final chapters = await readerService.getMangaChapters('mangadex', 'one-punch-man');
readerService.markChapterRead('mangadex', 'one-punch-man', 'chapter-001.cbz');

// Book Operations
final folders = await readerService.getBookFolders(['fiction']);
final books = await readerService.getBooks(['fiction', 'sci-fi']);

// Progress Tracking
final bookProgress = readerService.getBookProgress('/path/to/book.epub');
readerService.updateBookProgress('/path/to/book.epub', page: 142, percent: 45.2);

final mangaProgress = readerService.getMangaProgress('mangadex', 'one-punch-man');
readerService.updateMangaProgress('mangadex', 'one-punch-man', 'chapter-003.cbz', page: 12);

// Settings
final settings = readerService.settings;
settings.general.fontSize = 18;
await readerService.saveSettings();
```

**ReaderSettings Fields:**
| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `general.fontSize` | int | 16 | Reading font size |
| `general.lineHeight` | double | 1.5 | Line spacing |
| `general.theme` | String | 'system' | Theme preference |
| `rss.autoRefresh` | bool | true | Auto-refresh feeds |
| `rss.refreshIntervalMinutes` | int | 30 | Refresh interval |
| `manga.readingDirection` | String | 'ltr' | Reading direction |
| `manga.webtoonMode` | bool | false | Vertical scroll mode |
| `books.rememberPosition` | bool | true | Save reading position |

---

### ReaderPathUtils

**File:** `lib/reader/utils/reader_path_utils.dart`

Path building utilities for Reader content.

**Usage:**
```dart
// Slugify title for folder names
final slug = ReaderPathUtils.slugify('My Manga Title!');
// Result: 'my-manga-title'

// Build paths
final postPath = ReaderPathUtils.buildPostPath(collectionPath, sourceId, slug);
// Result: '{collection}/rss/{sourceId}/posts/{date}_{slug}'

final mangaPath = ReaderPathUtils.buildMangaPath(collectionPath, sourceId, slug);
// Result: '{collection}/manga/{sourceId}/series/{slug}'

final chapterPath = ReaderPathUtils.buildChapterPath(collectionPath, sourceId, mangaSlug, 'chapter-001.cbz');
// Result: '{collection}/manga/{sourceId}/series/{mangaSlug}/chapter-001.cbz'

// Format date for folder names
final dateStr = ReaderPathUtils.formatDateForFolder(DateTime.now());
// Result: '2026-01-24'
```

---

### Related Components

| Component | Location | Purpose |
|-----------|----------|---------|
| ReaderHomePage | reader/pages/reader_home_page.dart | Main category selection |
| RssSourcesPage | reader/pages/rss_sources_page.dart | RSS sources list |
| RssPostsPage | reader/pages/rss_posts_page.dart | Posts from a source |
| ArticleReaderPage | reader/pages/article_reader_page.dart | Markdown article reader |
| MangaSourcesPage | reader/pages/manga_sources_page.dart | Manga sources list |
| MangaSeriesPage | reader/pages/manga_series_page.dart | Manga series grid/list |
| MangaReaderPage | reader/pages/manga_reader_page.dart | Full-screen chapter reader |
| MangaSettingsPage | reader/pages/manga_settings_page.dart | Extension management (add/remove) |
| MangaFolderBrowserPage | reader/pages/manga_folder_browser_page.dart | Series folder with update check/download |
| BookBrowserPage | reader/pages/book_browser_page.dart | Local book file browser |

### Manga Extension System

**Files:**
- `lib/reader/models/manga_extension.dart` — `MangaExtension`, `ScrapeConfig`, `ExtensionField`, `PageConfig`, `BrowseConfig` models
- `lib/reader/services/manga_scraper.dart` — HTML scraping engine with CSS selector extraction
- `lib/reader/services/manga_extension_service.dart` — Extension lifecycle and scraping orchestration
- `lib/reader/services/manga_download_service.dart` — Download chapters into existing series folders
- `lib/reader/services/manga_cloudflare_service.dart` — Cloudflare challenge handling + cookie caching

JSON-driven extension system for downloading manga from websites. Extensions are JSON manifests with CSS selectors, stored in `{basePath}/manga/extensions/{id}/extension.json`.

**Usage:**
```dart
final extService = MangaExtensionService();
await extService.initialize('path/to/extensions');

// Search for manga
final results = await extService.search('mangapill', 'one piece');

// Browse catalog (popular, latest, new)
final catalog = await extService.browse('mangapill', 0); // first browse tab

// Search all extensions at once
final allResults = await extService.searchAllExtensions('naruto');

// Get chapters
final chapters = await extService.listChapters('mangapill', mangaUrl);

// Download missing chapters into series folder
final downloadService = MangaDownloadService();
final missing = await downloadService.findMissingChapters(
  seriesDir: '/path/to/series',
  extensionId: 'mangakakalot',
  sourceMangaId: mangaUrl,
);
for (final chapter in missing.missing) {
  await downloadService.downloadChapter(
    seriesDir: '/path/to/series',
    extensionId: 'mangakakalot',
    chapter: chapter,
  );
}
```

**Key classes:**
| Class | Purpose |
|-------|---------|
| `MangaExtension` | Parsed extension manifest (id, selectors, headers, rate limit) |
| `MangaScraper` | HTTP fetch + HTML parse + CSS select + field extraction |
| `MangaExtensionService` | Load/install/remove extensions, search/browse/chapters/pages |
| `MangaDownloadService` | Find missing chapters, download as chapter-N.cbz |
| `BrowseConfig` | Named catalog page (popular, latest, new) with ScrapeConfig |
| `ExtensionField` | Field extraction rule (selector, attr, regex, map, type) |

---

## Flasher Components

The Flasher module provides components for flashing firmware to ESP32 and other USB-connected devices.

### FlasherService

**File:** `lib/flasher/services/flasher_service.dart`

Main service for orchestrating flash operations.

**Usage:**
```dart
import 'package:geogram/flasher/flasher.dart';

// Create service
final service = FlasherService.withPath('flasher');

// List serial ports
final ports = await service.listPorts();

// Auto-detect connected device
final device = await service.autoDetectDevice();

// Flash device
await service.flashDevice(
  device: device!,
  portPath: ports.first.path,
  onProgress: (progress) {
    print('${progress.percentage}% - ${progress.message}');
  },
);
```

---

### FlasherStorageService

**File:** `lib/flasher/services/flasher_storage_service.dart`

Service for loading device definitions from the flasher/ directory. Supports both v1.0 and v2.0 directory structures:
- **v1.0:** `flasher/{family}/{device}.json`
- **v2.0:** `flasher/{project}/{architecture}/{model}/device.json`

**Usage:**
```dart
final storage = FlasherStorageService('flasher');

// Load all devices (both v1.0 and v2.0)
final devices = await storage.loadAllDevices();

// Load devices in hierarchical structure (v2.0)
final hierarchy = await storage.loadDevicesByHierarchy();
// Returns: Map<String, Map<String, List<DeviceDefinition>>>
// Example: hierarchy['geogram']['esp32'] = [device1, device2]

// Load devices grouped by family (v1.0 compatibility)
final byFamily = await storage.loadDevicesByFamily();

// v2.0 specific methods
final projects = await storage.listProjects();
final architectures = await storage.listArchitectures('geogram');
final models = await storage.listModels('geogram', 'esp32');
final versions = await storage.loadVersions('geogram', 'esp32', 'esp32-c3-mini');
final device = await storage.loadDeviceV2('geogram', 'esp32', 'esp32-c3-mini');

// Find device by USB VID/PID
final device = await storage.findDeviceByUsb(0x303A, 0x1001);

// Load specific device (v1.0)
final esp32 = await storage.loadDevice('esp32', 'esp32-c3-mini');
```

---

### FirmwareTreeWidget

**File:** `lib/flasher/widgets/firmware_tree_widget.dart`

Hierarchical tree view for browsing the firmware library. Shows: Project -> Architecture -> Model -> Version.

**Usage:**
```dart
FirmwareTreeWidget(
  hierarchy: _hierarchy, // Map<String, Map<String, List<DeviceDefinition>>>
  selectedDevice: _selectedDevice,
  selectedVersion: _selectedVersion,
  onSelected: (device, version) {
    setState(() {
      _selectedDevice = device;
      _selectedVersion = version;
    });
  },
  isLoading: _isLoading,
)
```

**Features:**
- Expand/collapse folders
- Tap version to select for flashing
- Long-press version to show details (release notes, size, date)
- Auto-expand to current selection
- Visual indicators for latest version

---

### SelectedFirmwareCard

**File:** `lib/flasher/widgets/selected_firmware_card.dart`

Card widget showing the selected firmware with device info, version path, and Change button.

**Usage:**
```dart
SelectedFirmwareCard(
  device: _selectedDevice,
  version: _selectedVersion,
  onChangeTap: () {
    _tabController.animateTo(0); // Switch to Library tab
  },
)

// Compact chip variant
SelectedFirmwareChip(
  device: device,
  version: version,
  onTap: () { ... },
)
```

**Displays:**
- Device photo (or placeholder icon)
- Device title
- Path: project / architecture / version
- Flash info badges (size, protocol)
- Change button to switch selection

---

### ProtocolRegistry

**File:** `lib/flasher/protocols/protocol_registry.dart`

Factory for creating flash protocol instances.

**Usage:**
```dart
import 'package:geogram/flasher/flasher.dart';

// Create protocol by ID
final protocol = ProtocolRegistry.create('esptool');

// List available protocols
final protocols = ProtocolRegistry.availableProtocols;
// ['esptool', 'quansheng']

// Check if protocol is available
if (ProtocolRegistry.isAvailable('esptool')) {
  // Use protocol
}
```

---

### DeviceCard Widget

**File:** `lib/flasher/widgets/device_card.dart`

Card widget for displaying a flashable device with photo and details.

**Usage:**
```dart
DeviceCard(
  device: deviceDefinition,
  isSelected: _selectedDevice?.id == deviceDefinition.id,
  onTap: () {
    setState(() {
      _selectedDevice = deviceDefinition;
    });
  },
)
```

---

### FlashProgressWidget

**File:** `lib/flasher/widgets/flash_progress_widget.dart`

Widget for displaying flash operation progress with status, progress bar, and details.

**Usage:**
```dart
FlashProgressWidget(
  progress: _flashProgress,
  showDetails: true,
)

// Compact version for app bars
CompactFlashProgress(
  progress: _flashProgress,
)
```

---

### FlashProgress Model

**File:** `lib/flasher/models/flash_progress.dart`

Progress state model with factory constructors for each phase.

**Usage:**
```dart
// Create progress states
final connecting = FlashProgress.connecting();
final writing = FlashProgress.writing(
  progress: 0.5,
  bytesWritten: 51200,
  totalBytes: 102400,
  currentChunk: 50,
  totalChunks: 100,
);
final error = FlashProgress.error('Device disconnected');
final completed = FlashProgress.completed(Duration(seconds: 30));

// Check state
if (progress.isInProgress) { ... }
if (progress.isCompleted) { ... }
if (progress.isError) { ... }
```

---

### DeviceDefinition Model

**File:** `lib/flasher/models/device_definition.dart`

Model for device definitions loaded from JSON files. Supports both v1.0 and v2.0 formats.

**Key Classes:**
- `DeviceDefinition` - Main device model
- `FirmwareVersion` - Version with metadata (checksum, size, release notes)
- `FlashConfig` - Flash configuration (protocol, baud rate, etc.)
- `UsbIdentifier` - USB VID/PID
- `DeviceFamily` - Family metadata (v1.0)
- `FlasherProject` - Project metadata (v2.0)
- `FlasherMetadata` - Collection metadata

**Usage:**
```dart
// Parse from JSON
final json = jsonDecode(content) as Map<String, dynamic>;
final device = DeviceDefinition.fromJson(json);

// Access properties (both v1.0 and v2.0)
print(device.title);                     // "ESP32-C3-mini"
print(device.flash.protocol);            // "esptool"
print(device.usb?.vidInt);               // 0x303A

// v2.0 hierarchical properties
print(device.effectiveProject);          // "geogram"
print(device.effectiveArchitecture);     // "esp32"
print(device.effectiveModel);            // "esp32-c3-mini"

// Firmware versions
for (final version in device.versions) {
  print('v${version.version}: ${version.size} bytes');
}
print(device.latestFirmwareVersion?.version);

// Create copy with selected version
final withVersion = device.withSelectedVersion(version);

// Get translated description
final desc = device.getDescription('pt');
```

### FirmwareVersion

**File:** `lib/flasher/models/device_definition.dart`

Model for firmware version metadata.

**Properties:**
- `version` - Version string (e.g., "1.2.0")
- `releaseNotes` - Optional release notes
- `releaseDate` - Optional release date
- `checksum` - Optional SHA256 checksum
- `size` - Optional file size in bytes

**Usage:**
```dart
final version = FirmwareVersion(
  version: '1.2.0',
  releaseNotes: 'Bug fixes and improvements',
  releaseDate: '2026-01-24',
  checksum: 'abc123...',
  size: 524288,
);

// Get firmware path relative to device folder
print(version.firmwarePath);  // "1.2.0/firmware.bin"
```

---

### Related Components

| Component | Location | Purpose |
|-----------|----------|---------|
| FlasherPage | flasher/pages/flasher_page.dart | Main UI for device flashing |
| DeviceCard | flasher/widgets/device_card.dart | Device selection card |
| FlashProgressWidget | flasher/widgets/flash_progress_widget.dart | Progress display |
| EspToolProtocol | flasher/protocols/esptool_protocol.dart | ESP32 flashing protocol |
| SerialPort | flasher/serial/serial_port.dart | Cross-platform USB serial (native APIs) |
| Esp32UsbIdentifiers | flasher/serial/serial_port.dart | ESP32 VID/PID matching utilities |
| NativeSerialAndroid | flasher/serial/native_serial_android.dart | Android USB Host API wrapper |
| NativeSerialLinux | flasher/serial/native_serial_linux.dart | Linux libc termios wrapper |
| UsbSerialPlugin | android/.../UsbSerialPlugin.kt | Android USB CDC-ACM plugin |

---

## Native Serial Port (Pure Platform APIs)

### Overview

Pure-Dart serial port implementation using native OS APIs - **no third-party dependencies**.

| Platform | Backend | Library |
|----------|---------|---------|
| **Android** | USB Host API (`android.hardware.usb.*`) | Built into Android SDK |
| **Linux** | libc termios | Built into Linux kernel |
| **macOS** | libc termios | Built into macOS (TODO) |
| **Windows** | kernel32 | Built into Windows (TODO) |

### NativeSerialLinux

**File:** `lib/flasher/serial/native_serial_linux.dart`

Pure-Dart FFI implementation for Linux serial ports.

**Key Features:**
- Uses libc termios (always available on Linux)
- Scans `/sys/class/tty/` for USB serial devices (ttyACM*, ttyUSB*)
- Reads VID/PID from sysfs
- Non-blocking I/O with poll()

**Usage:**
```dart
// List ports
final ports = await NativeSerialLinux.listPorts();
for (final port in ports) {
  print('${port.path}: VID=${port.vidHex}, PID=${port.pidHex}');
}

// Open and use
final serial = NativeSerialLinux();
if (await serial.open('/dev/ttyACM0', 115200)) {
  serial.setDTR(false);
  serial.setRTS(true);
  await Future.delayed(Duration(milliseconds: 100));
  serial.setDTR(true);

  await serial.write(Uint8List.fromList([0x7F])); // Sync byte
  final response = await serial.read(100, timeoutMs: 1000);
  print('Received: ${response.length} bytes');

  await serial.close();
}
```

**FFI Bindings (libc.so.6):**
```dart
// File operations
int open(const char* path, int flags);
int close(int fd);
ssize_t read(int fd, void* buf, size_t count);
ssize_t write(int fd, const void* buf, size_t count);

// Terminal control
int tcgetattr(int fd, struct termios* t);
int tcsetattr(int fd, int action, const struct termios* t);
int cfsetispeed(struct termios* t, speed_t speed);
int cfsetospeed(struct termios* t, speed_t speed);
int tcflush(int fd, int queue);
int tcdrain(int fd);

// DTR/RTS control via ioctl
int ioctl(int fd, TIOCMBIS/TIOCMBIC, &bits);
```

### NativeSerialAndroid

**File:** `lib/flasher/serial/native_serial_android.dart`

Dart wrapper for the Android USB Serial plugin (method channel).

**Usage:**
```dart
// List devices
final devices = await NativeSerialAndroid.listDevices();
for (final d in devices) {
  print('${d['deviceName']}: ${d['productName']} (ESP32: ${d['isEsp32']})');
}

// Request permission (shows system dialog)
final deviceName = devices.first['deviceName'] as String;
if (!await NativeSerialAndroid.hasPermission(deviceName)) {
  await NativeSerialAndroid.requestPermission(deviceName);
}

// Open and use
await NativeSerialAndroid.open(deviceName, baudRate: 115200);
await NativeSerialAndroid.setDTR(deviceName, false);
await NativeSerialAndroid.setRTS(deviceName, true);
await Future.delayed(Duration(milliseconds: 100));
await NativeSerialAndroid.setDTR(deviceName, true);

await NativeSerialAndroid.write(deviceName, Uint8List.fromList([0x7F]));
final data = await NativeSerialAndroid.read(deviceName, maxBytes: 100);
await NativeSerialAndroid.close(deviceName);
```

### UsbSerialPlugin (Kotlin)

**File:** `android/app/src/main/kotlin/dev/geogram/UsbSerialPlugin.kt`

Android plugin implementing CDC-ACM USB serial via Android USB Host API.

**CDC-ACM Control Requests:**
```kotlin
// Set baud rate, parity, stop bits
val lineCoding = ByteArray(7)  // 7-byte structure
connection.controlTransfer(0x21, SET_LINE_CODING, 0, 0, lineCoding, 7, 1000)

// Set DTR/RTS signals
val value = (if (dtr) 0x01 else 0x00) or (if (rts) 0x02 else 0x00)
connection.controlTransfer(0x21, SET_CONTROL_LINE_STATE, value, 0, null, 0, 1000)
```

**Method Channel API:**
- `listDevices` - List USB serial devices
- `requestPermission` - Show Android permission dialog
- `hasPermission` - Check permission status
- `open` - Open device connection
- `close` - Close device connection
- `read` - Read via bulk transfer
- `write` - Write via bulk transfer
- `setDTR` / `setRTS` - Control line signals
- `setBaudRate` - Change baud rate
- `flush` - Clear buffers

### UsbAttachmentService

**File:** `lib/services/usb_attachment_service.dart`

Dart service that handles USB device attachment events from Android. Listens to native MethodChannel and triggers navigation to Flasher Monitor tab when an ESP32 device is connected via USB OTG.

**Architecture:**
1. Android `AndroidManifest.xml` declares `USB_DEVICE_ATTACHED` intent filter with `device_filter.xml`
2. `MainActivity.kt` receives the intent, extracts VID/PID, checks against known ESP32 identifiers
3. Sends event to Dart via MethodChannel `dev.geogram/usb_attach`
4. `UsbAttachmentService` receives the event and triggers `DebugController.openFlasherMonitor`
5. HomePage listens for the action and navigates to FlasherPage with Monitor tab

**Usage:**
```dart
// Initialize once in main.dart (Android only)
if (Platform.isAndroid) {
  UsbAttachmentService().initialize();
}

// The service automatically handles USB attachment events
// No manual interaction required - it's event-driven
```

**Known ESP32 USB Identifiers (in device_filter.xml and MainActivity.kt):**
| Description | VID | PID |
|-------------|------|------|
| Espressif native USB (ESP32-C3/S2/S3) | 0x303A | 0x1001 |
| Espressif USB Bridge | 0x303A | 0x0002 |
| CP210x USB-UART | 0x10C4 | 0xEA60 |
| CH340 USB-UART | 0x1A86 | 0x7523 |
| CH9102 USB-UART | 0x1A86 | 0x55D4 |
| FTDI FT232 | 0x0403 | 0x6001 |
| FTDI FT231X | 0x0403 | 0x6015 |

**DebugController Integration:**
```dart
// Trigger flasher monitor navigation programmatically
DebugController().triggerOpenFlasherMonitor(devicePath: '/dev/bus/usb/001/002');

// Listen for the action in UI
_debugController.actionStream.listen((event) {
  if (event.action == DebugAction.openFlasherMonitor) {
    // Navigate to FlasherPage with initialTab: 2 (Monitor)
  }
});
```

### FileViewerService

**File:** `lib/services/file_viewer_service.dart`

Dart service that handles external file VIEW intents from Android. When user opens an image, video, or PDF with "Open with" and selects Geogram, this service receives the file and navigates to the appropriate viewer.

**Architecture:**
1. Android `AndroidManifest.xml` declares `ACTION_VIEW` intent filters for supported MIME types
2. `MainActivity.kt` receives the intent, copies file to cache, extracts path and MIME type
3. Sends event to Dart via MethodChannel `dev.geogram/file_viewer`
4. `FileViewerService` receives the event and triggers `DebugController.openExternalFile`
5. HomePage listens for the action and navigates to PhotoViewerPage or DocumentViewerEditorPage

**Supported MIME Types:**
- Images: `image/png`, `image/jpeg`
- Videos: `video/mp4`, `video/x-msvideo`, `video/x-matroska`, `video/quicktime`, `video/x-ms-wmv`, `video/x-flv`, `video/webm`
- Documents: `application/pdf`

**Usage:**
```dart
// Initialize once in main.dart (Android only)
if (Platform.isAndroid) {
  FileViewerService().initialize();
}

// The service automatically handles VIEW intents
// No manual interaction required - it's event-driven
```

**DebugController Integration:**
```dart
// Trigger file viewer navigation programmatically
DebugController().triggerOpenExternalFile(
  path: '/data/data/dev.geogram/cache/external_files/photo.jpg',
  mimeType: 'image/jpeg',
);

// Listen for the action in UI
_debugController.actionStream.listen((event) {
  if (event.action == DebugAction.openExternalFile) {
    final path = event.params['path'] as String;
    final mimeType = event.params['mimeType'] as String?;
    // Navigate to PhotoViewerPage for images/videos
    // Navigate to DocumentViewerEditorPage for PDFs
  }
});
```

### UsbAoaService

**File:** `lib/services/usb_aoa_service.dart`

Dart service for USB AOA (Android Open Accessory) device-to-device communication. Enables zero-config bidirectional communication between two Android phones connected via USB-C cable.

**Key Features:**
- Method channel bridge to native `UsbAoaPlugin.kt`
- Connection state stream for tracking USB connection status
- Data stream for receiving messages from connected device
- Linux host mode support via FFI (in addition to Android accessory mode)
- Auto-reconnect on unexpected disconnects (3 attempts with exponential backoff)
- Hotplug detection every 2 seconds on Linux

**Usage:**
```dart
final usbService = UsbAoaService();
await usbService.initialize();

// Listen for connection changes
usbService.connectionStateStream.listen((state) {
  print('USB state: $state');
});

// Listen for incoming data
usbService.dataStream.listen((data) {
  final message = utf8.decode(data);
  print('Received: $message');
});

// Write data to connected device
await usbService.write(Uint8List.fromList(utf8.encode('Hello')));
```

### UsbAoaTransport

**File:** `lib/connection/transports/usb_aoa_transport.dart`

Transport implementation for USB AOA communication. Highest priority transport (5) - faster and more reliable than all other transports.

**Transport Priority:** 5 (USB) > 10 (LAN) > 15 (WebRTC) > 30 (Station) > 35 (BT Classic) > 40 (BLE)

**Message Format:**
```json
{
  "channel": "_api|_api_response|_dm|_system|<room_id>",
  "content": "<message JSON>",
  "timestamp": 1706000000000
}
```

Messages are length-prefixed (4 bytes big-endian) for reliable framing over the USB byte stream.

**Platform Support:**
- Android: Accessory mode (receives connection from Linux/Android host)
- Linux: Host mode (initiates AOA handshake to Android device)
- Other platforms: Not supported

### UsbAoaLinux

**File:** `lib/services/usb_aoa_linux.dart`

Pure Dart FFI implementation for Linux USB AOA host mode. Uses libc and kernel usbdevfs ioctls - no external dependencies.

**Key Features:**
- Device enumeration via `/sys/bus/usb/devices/`
- AOA handshake (GET_PROTOCOL, SEND_STRING, START)
- Bulk transfer I/O via `USBDEVFS_BULK` ioctl
- No libusb dependency - uses kernel APIs directly

**FFI Pattern (reusable for other USB implementations):**
```dart
// Load libc
final lib = DynamicLibrary.open('libc.so.6');

// Get function pointers
final open = lib.lookupFunction<OpenNative, OpenDart>('open');
final ioctl = lib.lookupFunction<IoctlPtrNative, IoctlPtrDart>('ioctl');

// USB control transfer structure
final class UsbCtrlTransfer extends Struct {
  @Uint8() external int bRequestType;
  @Uint8() external int bRequest;
  @Uint16() external int wValue;
  @Uint16() external int wIndex;
  @Uint16() external int wLength;
  @Uint32() external int timeout;
  external Pointer<Void> data;
}

// Perform control transfer
final ctrl = calloc<UsbCtrlTransfer>();
ctrl.ref.bRequestType = 0xC0; // IN, vendor, device
ctrl.ref.bRequest = 51; // AOA_GET_PROTOCOL
ctrl.ref.wLength = 2;
ctrl.ref.timeout = 1000;
ctrl.ref.data = buffer.cast();
ioctl(fd, USBDEVFS_CONTROL, ctrl.cast());
```

**USB Constants (from linux/usbdevice_fs.h):**
```dart
const USBDEVFS_CONTROL = 0xC0185500;
const USBDEVFS_BULK = 0xC0185502;
const USBDEVFS_CLAIMINTERFACE = 0x8004550F;
const USBDEVFS_RELEASEINTERFACE = 0x80045510;
const USBDEVFS_CLEAR_HALT = 0x80045515;
```

**IMPORTANT: poll() doesn't work reliably with USB device file descriptors on Linux**

When reading data from USB devices opened via `/dev/bus/usb/xxx/yyy`, the `poll()` system call may not properly signal data availability. The solution is to try a bulk read with a short timeout even when poll returns timeout:

```dart
// Read loop pattern for Linux USB
while (isReading && isConnected) {
  // Poll for incoming data (may not work reliably on USB)
  final pollResult = poll(pollFd.cast(), 1, 100);

  if (pollResult == 0) {
    // Timeout - but poll() may miss USB data!
    // Try a non-blocking bulk read anyway
    bulk.ref.ep = epIn;
    bulk.ref.len = bufferSize;
    bulk.ref.timeout = 50; // Short timeout for non-blocking check
    bulk.ref.data = buffer.cast();

    final bytesRead = ioctl(fd, USBDEVFS_BULK, bulk.cast());
    if (bytesRead > 0) {
      // Data was available even though poll() didn't report it!
      processData(buffer, bytesRead);
    }
    continue;
  }

  // Handle POLLIN, POLLERR, POLLHUP as normal
}
```

This pattern is used in `UsbAoaLinux._readLoopAsync()` to reliably receive data from Android devices.

## Work Document Editor Components

### NdfImageEmbedBuilder

**File:** `lib/work/pages/document_editor_page.dart`

Custom QuillEditor EmbedBuilder that handles `asset://` URLs stored in NDF archives.

**Use Case:**
When images are embedded in Work documents, they are stored inside the NDF zip archive under `assets/images/`. The Quill document references them using `asset://images/filename.jpg` URLs. This embed builder extracts assets to temp files and displays them.

**Architecture:**
1. User clicks image button in toolbar
2. `_pickAndSaveImage()` picks image via ImagePicker, saves to NDF archive via `NdfService.saveAsset()`
3. Returns `asset://images/{timestamp}.{ext}` URL which is inserted into Quill document
4. `_NdfImageEmbedBuilder.build()` is called when rendering
5. `_getAssetImageProvider()` extracts asset to temp file via `NdfService.extractAssetToTemp()`
6. Image is displayed with FileImage provider, cached for performance

**Code Pattern:**
```dart
// Custom embed builder for asset:// URLs
class _NdfImageEmbedBuilder extends EmbedBuilder {
  final Future<ImageProvider?> Function(String imageUrl) getImageProvider;

  _NdfImageEmbedBuilder({required this.getImageProvider});

  @override
  String get key => BlockEmbed.imageType;

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final imageUrl = embedContext.node.value.data as String;
    return FutureBuilder<ImageProvider?>(
      future: getImageProvider(imageUrl),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const CircularProgressIndicator();
        }
        final provider = snapshot.data;
        if (provider == null) return const Icon(Icons.broken_image);
        return Image(image: provider, fit: BoxFit.contain);
      },
    );
  }
}

// Configure QuillEditor with custom embed builder
QuillEditor(
  controller: _quillController,
  config: QuillEditorConfig(
    embedBuilders: [
      _NdfImageEmbedBuilder(getImageProvider: _getAssetImageProvider),
    ],
  ),
)
```

**Related Methods:**
- `NdfService.saveAsset(filePath, assetPath, bytes)` - Save asset to archive
- `NdfService.extractAssetToTemp(filePath, assetPath)` - Extract to temp file
- `NdfService.readAsset(filePath, assetPath)` - Read asset bytes directly

---

### PresentationContent Model

**File:** `lib/work/models/presentation_content.dart`

Data models for NDF presentation files following the ndf-slides-1.0 schema.

**Key Classes:**
| Class | Description |
|-------|-------------|
| `PresentationContent` | Main content (main.json) with slide list, theme, transitions |
| `PresentationSlide` | Individual slide with layout, background, elements, notes |
| `SlideElement` | Element on a slide (text for MVP) |
| `ElementPosition` | Position as percentages (x, y, w, h) |
| `SlideTextStyle` | Text styling (color, fontSize, align, bold, italic) |
| `SlideTextSpan` | Text span with formatting marks |
| `SlideBackground` | Slide background (solid color for MVP) |
| `PresentationTheme` | Theme with colors and fonts |

**Enums:**
- `SlideLayout`: blank, title, titleContent, twoColumn, sectionHeader
- `SlideElementType`: text (MVP - images later)
- `SlideTextAlign`: left, center, right

**Factory Methods:**
```dart
// Create a blank slide
PresentationSlide.blank(id: 'slide-001', index: 0);

// Create a title slide
PresentationSlide.title(id: 'slide-001', index: 0, title: 'Welcome', subtitle: 'Subtitle');

// Create a title + content slide
PresentationSlide.titleContent(id: 'slide-002', index: 1, title: 'Agenda', content: 'Topics...');

// Create a text element
SlideElement.text(
  id: 'text-001',
  position: ElementPosition.centerTitle(),
  text: 'Hello World',
  style: SlideTextStyle(fontSize: 48, bold: true, align: SlideTextAlign.center),
);
```

**Usage:**
```dart
// Read presentation
final content = await ndfService.readPresentationContent(filePath);
final slide = await ndfService.readSlide(filePath, 'slide-001');

// Save presentation
await ndfService.savePresentation(filePath, content, slidesMap);
```

---

### SlideTemplate

**File:** `lib/work/models/presentation_content.dart`

Predefined slide templates with color themes for presentations.

**Available Templates:**
| ID | Name | Description |
|----|------|-------------|
| `classic` | Classic | Traditional white background with navy/blue accents |
| `blackwhite` | Black & White | Monochrome, elegant design |
| `dark` | Dark Mode | Dark background with light text |
| `cyber` | Cyber | Neon colors on dark background (cyan, magenta) |
| `retro80s` | Retro 80s | Amber CRT-style terminal look |
| `retro_green` | Green CRT | Green phosphor CRT terminal style |
| `corporate` | Corporate | Professional blue business theme |
| `nature` | Nature | Green, organic, natural colors |
| `sunset` | Sunset | Warm orange/red colors |
| `ocean` | Ocean | Teal and cyan aquatic theme |
| `purple` | Purple | Elegant purple/violet theme |
| `minimalist` | Minimalist | Clean gray minimal design |

**Usage:**
```dart
// Get all templates
final templates = SlideTemplate.templates;

// Get template by ID
final cyber = SlideTemplate.getById('cyber');

// Access template colors
final bgColor = cyber!.colors.background;  // '#0D0D1A'
final textColor = cyber.colors.text;        // '#00FFFF'
final primary = cyber.colors.primary;       // '#00FFFF'
final accent = cyber.colors.accent;         // '#00FF00'
```

**Template Colors Structure:**
```dart
ThemeColors(
  primary: '#...',      // Headers, titles
  secondary: '#...',    // Subtitles, secondary elements
  accent: '#...',       // Highlights, buttons
  background: '#...',   // Slide background
  text: '#...',         // Body text
)
```

---

### SlideCanvasWidget

**File:** `lib/work/widgets/presentation/slide_canvas_widget.dart`

Renders a slide at the correct aspect ratio with all elements.

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `slide` | PresentationSlide | Yes | The slide to render |
| `theme` | PresentationTheme | Yes | Theme for colors/fonts |
| `aspectRatio` | double | No | Aspect ratio (default: 16:9) |
| `selectedElementId` | String? | No | Currently selected element |
| `isEditing` | bool | No | Show selection highlight |
| `onElementTap` | Function? | No | Callback when element tapped |

**Usage:**
```dart
SlideCanvasWidget(
  slide: currentSlide,
  theme: content.theme,
  aspectRatio: content.aspectRatioValue,
  selectedElementId: _selectedElementId,
  isEditing: true,
  onElementTap: (elementId) => setState(() => _selectedElementId = elementId),
)
```

---

### SlideThumbnailWidget

**File:** `lib/work/widgets/presentation/slide_thumbnail_widget.dart`

Mini slide preview for the slide panel sidebar.

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `slide` | PresentationSlide | Yes | The slide to render |
| `theme` | PresentationTheme | Yes | Theme for colors/fonts |
| `slideNumber` | int | Yes | Slide number to display |
| `isSelected` | bool | No | Highlight as selected |
| `onTap` | VoidCallback? | No | Tap callback |

**Usage:**
```dart
SlideThumbnailWidget(
  slide: slide,
  theme: content.theme,
  slideNumber: index + 1,
  isSelected: index == _currentSlideIndex,
  onTap: () => _goToSlide(index),
)
```

**DraggableSlideThumbnail** - Same but with drag handle for reordering in ReorderableListView.

---

### SheetGridWidget

**File:** `lib/work/widgets/spreadsheet/sheet_grid_widget.dart`

A fully-featured spreadsheet grid widget that can be embedded in any page. Supports cell editing, formulas, formatting, copy/paste, undo/redo, and column resizing.

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `sheet` | SpreadsheetSheet | Yes | The sheet data to display |
| `onChanged` | ValueChanged\<SpreadsheetSheet\> | Yes | Called when sheet is modified |
| `readOnly` | bool | No | If true, prevents editing (default: false) |

**Features:**
- Cell editing with formula support (=SUM, =AVG, =MIN, =MAX, etc.)
- Formula autocomplete dropdown
- Cell formatting (bold, italic, font size, text/background colors)
- Currency formatting (fiat and crypto)
- Text alignment (left, center, right)
- Copy/paste with Ctrl+C/Ctrl+V
- Undo with Ctrl+Z
- Column resizing via drag
- Select all via corner cell click
- Context menu on right-click/long-press

**Usage in Form Responses:**
```dart
// Display form responses as editable spreadsheet
SheetGridWidget(
  sheet: _responsesSheet!,
  onChanged: (sheet) {
    setState(() {
      _responsesSheet = sheet;
      _hasChanges = true;
    });
  },
)
```

**Building a Spreadsheet from Data:**
```dart
SpreadsheetSheet _buildDataSpreadsheet(List<DataItem> items) {
  final sheet = SpreadsheetSheet.create(id: 'data', name: 'Data');
  sheet.cols = 5;
  sheet.rows = items.length + 10;

  // Header row
  sheet.setCell(0, 0, SpreadsheetCell(value: 'ID', type: CellType.string));
  sheet.setCell(0, 1, SpreadsheetCell(value: 'Name', type: CellType.string));
  sheet.setCell(0, 2, SpreadsheetCell(value: 'Value', type: CellType.string));

  // Data rows
  for (int i = 0; i < items.length; i++) {
    final item = items[i];
    sheet.setCell(i + 1, 0, SpreadsheetCell(value: i + 1, type: CellType.number));
    sheet.setCell(i + 1, 1, SpreadsheetCell(value: item.name, type: CellType.string));
    sheet.setCell(i + 1, 2, SpreadsheetCell(value: item.value, type: CellType.number));
  }

  return sheet;
}
```

**NdfService Methods for Persistence:**
```dart
// Read spreadsheet from NDF archive
final sheet = await _ndfService.readResponsesSpreadsheet(filePath);

// Save spreadsheet to NDF archive
await _ndfService.saveResponsesSpreadsheet(filePath, sheet);
```

---

### TodoContent Model

**File:** `lib/work/models/todo_content.dart`

Models for TODO document type in the NDF format. Includes content model, item model, links, updates, and settings.

**Classes:**
| Class | Description |
|-------|-------------|
| `TodoContent` | Main content stored in content/main.json |
| `TodoItem` | Individual task with title, description, pictures, links, updates |
| `TodoLink` | A link with title and URL |
| `TodoUpdate` | A progress update/note with timestamp |
| `TodoSettings` | Display settings (show completed, sort order, default expanded) |
| `TodoSortOrder` | Enum for sorting (createdAsc, createdDesc, completedFirst, pendingFirst) |

**TodoItem Features:**
- `toggleCompleted()` - Toggle completion and set completedAt timestamp
- `durationSummary` getter - Returns human-readable completion duration ("2d 3h", "45m")
- Pictures stored as asset paths (images/item-xxx-timestamp.jpg)
- Links with id, title, url
- Updates with id, content, createdAt

**Usage:**
```dart
// Create a new item
final item = TodoItem.create(
  title: 'Fix login bug',
  description: 'Email validation not working',
);

// Toggle completion
item.toggleCompleted();
print(item.durationSummary); // "2h 15m"

// Add attachments
item.addPicture('images/screenshot.png');
item.addLink(TodoLink.create(title: 'Issue', url: 'https://github.com/...'));
item.addUpdate(TodoUpdate.create(content: 'Found the root cause'));
```

---

### TodoItemCardWidget

**File:** `lib/work/widgets/todo/todo_item_card_widget.dart`

An expandable card widget for displaying TODO items. Shows checkbox, title, badges, and expands to show full details with pictures, links, and updates.

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `item` | TodoItem | Yes | The TODO item to display |
| `isExpanded` | bool | Yes | Whether details are shown |
| `ndfFilePath` | String | Yes | Path to NDF file for loading pictures |
| `onToggleCompleted` | VoidCallback | Yes | Called when checkbox toggled |
| `onToggleExpanded` | VoidCallback | Yes | Called when expand/collapse tapped |
| `onEdit` | VoidCallback | Yes | Called to edit item |
| `onDelete` | VoidCallback | Yes | Called to delete item |
| `onAddPicture` | VoidCallback | Yes | Called to add picture |
| `onRemovePicture` | Function(String) | Yes | Called to remove picture by path |
| `onAddLink` | VoidCallback | Yes | Called to add link |
| `onRemoveLink` | Function(String) | Yes | Called to remove link by ID |
| `onOpenLink` | Function(TodoLink) | Yes | Called to open link in browser |
| `onAddUpdate` | VoidCallback | Yes | Called to add update |
| `onRemoveUpdate` | Function(String) | Yes | Called to remove update by ID |

**Features:**
- Checkbox for completion toggle with strikethrough text when completed
- Duration badge showing completion time ("Completed in 2d 3h")
- Badges showing pictures/updates/links count
- Expandable section with:
  - Description text
  - Picture grid with thumbnails loaded from NDF assets
  - Updates list with timestamps
  - Links list with tap-to-open
- Edit/Delete action buttons

**Platform-aware Image Picker Pattern:**
```dart
void _addPicture(TodoItem item) async {
  final isMobile = Platform.isAndroid || Platform.isIOS;
  if (isMobile) {
    // Show bottom sheet with Camera + Gallery options
    showModalBottomSheet(
      context: context,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.camera_alt),
            title: Text('Take Photo'),
            onTap: () { Navigator.pop(context); _takePhoto(item); },
          ),
          ListTile(
            leading: const Icon(Icons.photo_library),
            title: Text('From Gallery'),
            onTap: () { Navigator.pop(context); _pickFromGallery(item); },
          ),
        ],
      ),
    );
  } else {
    // Desktop: file picker only
    _pickFromGallery(item);
  }
}
```

---

## Presentation Decoration Painters

**File:** `lib/work/widgets/presentation/slide_canvas_widget.dart`

Custom painters for rendering slide template decorations. These can be reused in other contexts where similar visual patterns are needed.

### _DiagonalStripesPainter

Draws diagonal stripes pattern (like hazard tape or decorative backgrounds).

**Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `color` | Color | Stripe color |
| `count` | int | Number of stripes |

**Usage:**
```dart
CustomPaint(
  painter: _DiagonalStripesPainter(
    color: Colors.blue.withOpacity(0.3),
    count: 5,
  ),
  size: Size(200, 100),
)
```

### _DotsPainter

Draws a grid of dots (polka dot pattern).

**Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `color` | Color | Dot color |
| `count` | int | Dots per row/column |

### _GridPainter

Draws a grid pattern (like graph paper or cyber aesthetic).

**Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `color` | Color | Line color |
| `count` | int | Number of vertical lines |

### _ScanlinesPainter

Draws horizontal scanlines (CRT monitor effect).

**Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `color` | Color | Line color |
| `count` | int | Number of lines |

### _CornerAccentPainter

Draws a corner triangle accent decoration.

**Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `color` | Color | Triangle fill color |

### _WavePainter

Draws a wave pattern (ocean/nature themes).

**Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `color` | Color | Wave fill color |

### _TrianglePainter

Draws a simple triangle shape.

**Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `color` | Color | Triangle fill color |

### SlideTemplate

Predefined slide templates with decorations, colors, and visual patterns.

**Available Templates:**
| ID | Name Key | Style |
|----|----------|-------|
| `classic` | work_template_classic | Professional with header bar |
| `blackwhite` | work_template_blackwhite | Elegant monochrome |
| `dark` | work_template_dark | Dark mode with gradient |
| `cyber` | work_template_cyber | Neon grid cyberpunk |
| `retro80s` | work_template_retro80s | Amber CRT terminal |
| `retro_green` | work_template_retro_green | Green phosphor CRT |
| `corporate` | work_template_corporate | Business professional |
| `nature` | work_template_nature | Organic green waves |
| `sunset` | work_template_sunset | Warm gradient tones |
| `ocean` | work_template_ocean | Blue wave patterns |
| `purple` | work_template_purple | Elegant purple gradient |
| `minimalist` | work_template_minimalist | Clean subtle accents |

**Usage:**
```dart
// Get a template
final template = SlideTemplate.getById('cyber');

// Apply to SlideCanvasWidget
SlideCanvasWidget(
  slide: slide,
  theme: content.theme,
  template: template,  // Renders decorations
  aspectRatio: 16 / 9,
)
```

**Template Properties:**
| Property | Type | Description |
|----------|------|-------------|
| `id` | String | Unique identifier |
| `nameKey` | String | i18n translation key |
| `colors` | ThemeColors | primary, secondary, accent, background, text |
| `decorations` | List<SlideDecoration> | Visual decorations to render |
| `titleBarColor` | String? | Color for header bar |
| `hasGradientBackground` | bool | Use gradient instead of solid |

---

## Debounced Auto-Save Pattern

Pattern for automatically saving content after a short delay following user edits. Prevents excessive saves while ensuring changes are not lost.

**State Variables:**
```dart
Timer? _autoSaveTimer;
bool _hasChanges = false;
```

**Trigger Auto-Save:**
```dart
void _triggerAutoSave() {
  _autoSaveTimer?.cancel();
  _autoSaveTimer = Timer(const Duration(seconds: 3), () {
    if (_hasChanges && mounted) {
      _saveContent(silent: true);  // Silent save without UI notification
    }
  });
}
```

**Usage in Update Methods:**
```dart
void _updateContent(Content updated) {
  setState(() {
    _content = updated;
    _hasChanges = true;
  });
  _triggerAutoSave();  // Restart debounce timer
}
```

**Cleanup:**
```dart
@override
void dispose() {
  _autoSaveTimer?.cancel();
  super.dispose();
}
```

**Save Method with Silent Option:**
```dart
Future<void> _saveContent({bool silent = false}) async {
  await _storage.save(_content);
  setState(() => _hasChanges = false);

  if (mounted && !silent) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Saved')),
    );
  }
}
```

**Reference:** `lib/stories/pages/story_studio_page.dart`

---

## Inline Text Editing Pattern

Pattern for inline text editing directly in a canvas/widget instead of using popup dialogs. This provides WYSIWYG editing where users see exactly how text looks while typing.

**State Variables:**
```dart
bool _isInlineEditing = false;
final TextEditingController _textEditController = TextEditingController();
final FocusNode _textEditFocusNode = FocusNode();
String? _originalTextBeforeEdit;  // For cancel/restore
```

**Enter Edit Mode:**
```dart
void _editElement(String elementId) {
  final element = /* get element */;

  // Store original text for cancel
  _originalTextBeforeEdit = element.plainText;

  setState(() {
    _selectedElementId = elementId;
    _isInlineEditing = true;
  });

  _textEditController.text = element.plainText;

  // Request focus after build
  WidgetsBinding.instance.addPostFrameCallback((_) {
    _textEditFocusNode.requestFocus();
  });
}
```

**Commit Edit:**
```dart
void _commitInlineEdit() {
  if (!_isInlineEditing || _selectedElementId == null) return;

  // Update element with new text
  final newText = _textEditController.text.isEmpty
      ? placeholderText
      : _textEditController.text;

  // Apply to element...

  setState(() {
    _isInlineEditing = false;
    _originalTextBeforeEdit = null;
  });
}
```

**Cancel Edit (Restore Original):**
```dart
void _cancelInlineEdit() {
  if (!_isInlineEditing) return;

  // Restore original text
  if (_originalTextBeforeEdit != null) {
    // Restore element text...
  }

  setState(() {
    _isInlineEditing = false;
    _originalTextBeforeEdit = null;
  });
}
```

**Widget-Side Rendering (with Rich Text Overlay):**

To show formatted text (bold, italic) while editing, use a Stack with:
1. RichText layer (shows formatted content visually)
2. Transparent TextField layer (captures input and selection)

To capture Ctrl+B/I shortcuts before TextField consumes them, wrap in `Focus` with `onKeyEvent` returning `KeyEventResult.handled`.

```dart
// Conditionally render TextField when editing
if (isSelected && widget.isInlineEditing && widget.textEditController != null) {
  return Focus(
    onKeyEvent: (node, event) {
      if (event is KeyDownEvent) {
        final isCtrl = HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed;
        if (isCtrl && event.logicalKey == LogicalKeyboardKey.keyB) {
          widget.onToggleFormatting?.call('bold');
          return KeyEventResult.handled; // CRITICAL: consume event before TextField gets it
        }
        if (isCtrl && event.logicalKey == LogicalKeyboardKey.keyI) {
          widget.onToggleFormatting?.call('italic');
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.escape) {
          widget.onTextEditCancel?.call();
          return KeyEventResult.handled;
        }
      }
      return KeyEventResult.ignored; // Let TextField handle other keys
    },
    child: Stack(
      children: [
        // Visual layer: RichText showing formatted spans
        Positioned.fill(
          child: IgnorePointer(
            child: RichText(
              text: TextSpan(children: _buildFormattedSpans(element)),
              textAlign: textAlign,
            ),
          ),
        ),
        // Input layer: Transparent TextField for typing/selection
        TextField(
          controller: widget.textEditController,
          focusNode: widget.textEditFocusNode,
          autofocus: true,
          maxLines: null,
          style: TextStyle(
            fontSize: scaledFontSize,
            color: Colors.transparent, // Invisible text
          ),
          cursorColor: textColor, // Visible cursor
          decoration: const InputDecoration(
            border: InputBorder.none,
            contentPadding: EdgeInsets.zero,
            isDense: true,
          ),
          textInputAction: TextInputAction.newline,
        ),
      ],
    ),
  );
}

// Otherwise render normal RichText
return RichText(...);
```

**Key patterns:**
- `KeyboardListener` does NOT work for capturing Ctrl+B/I because it fires AFTER TextField
- `Focus.onKeyEvent` returning `KeyEventResult.handled` intercepts events BEFORE TextField
- Stack with transparent TextField + visible RichText shows formatting while allowing selection

**Input Handling:**
| Platform | Input | Action |
|----------|-------|--------|
| Desktop | Double-click | Start editing |
| Desktop | Escape | Cancel, restore original |
| Desktop | Ctrl+Enter | Commit text |
| Desktop | Ctrl+B | Toggle bold (selection or whole text) |
| Desktop | Ctrl+I | Toggle italic (selection or whole text) |
| Desktop | Ctrl+U | Toggle underline (selection or whole text) |
| Desktop | Click away | Commit text |
| Mobile | Long-press | Start editing |
| Mobile | Tap away | Commit text |

**Inline Formatting Toggle (with existing formatting preservation):**
```dart
/// Toggle formatting during inline editing.
/// - Selected text: toggles mark on selection only, preserves other formatting
/// - No selection: toggles element-level style
void _toggleInlineFormatting(String mark) {
  // If no selection, toggle element-level style
  if (!selection.isValid || selection.isCollapsed || text.isEmpty) {
    _toggleElementStyle(mark);
    return;
  }

  // Build character-level map of marks from existing spans
  final charMarks = <int, Set<String>>{};
  int pos = 0;
  for (final span in element.content) {
    for (int i = 0; i < span.value.length; i++) {
      charMarks[pos++] = Set<String>.from(span.marks);
    }
  }

  // Check if ALL selected characters have this mark (to toggle off)
  bool allHaveMark = true;
  for (int i = start; i < end; i++) {
    if (!(charMarks[i]?.contains(mark) ?? false)) {
      allHaveMark = false;
      break;
    }
  }

  // Toggle mark on selected characters only
  for (int i = start; i < end; i++) {
    if (allHaveMark) {
      charMarks[i]!.remove(mark);
    } else {
      charMarks[i]!.add(mark);
    }
  }

  // Convert back to spans - merge consecutive chars with same marks
  // ...
}

bool _setsEqual(Set<String>? a, Set<String>? b) {
  if (a == null && b == null) return true;
  if (a == null || b == null) return false;
  return a.length == b.length && a.containsAll(b);
}
```

**Files using this pattern:**
- `lib/work/pages/presentation_editor_page.dart`
- `lib/work/widgets/presentation/slide_canvas_widget.dart`

---

## NDF Logo and Thumbnail Embedding

### Description
Pattern for embedding and reading logo and thumbnail images from NDF documents. Logos and thumbnails are stored as assets inside the NDF archive and referenced via `asset://` URIs in the metadata.

### Usage

**Embed logo into document:**
```dart
final ndfService = NdfService();

// Embed workspace logo into a document
await ndfService.embedLogo(filePath, logoBytes, 'png');

// Read logo from document
final logoBytes = await ndfService.readLogo(filePath);

// Remove logo
await ndfService.removeLogo(filePath);
```

**Embed thumbnail into document:**
```dart
// Embed custom thumbnail
await ndfService.embedThumbnail(filePath, imageBytes);

// Read thumbnail
final thumbnailBytes = await ndfService.readThumbnail(filePath);

// Remove thumbnail
await ndfService.removeThumbnail(filePath);
```

**Workspace logo management:**
```dart
final storage = WorkStorageService(basePath);

// Save workspace logo
await storage.saveWorkspaceLogo(workspaceId, bytes, 'png');

// Read workspace logo
final logoBytes = await storage.readWorkspaceLogo(workspaceId);

// Delete workspace logo
await storage.deleteWorkspaceLogo(workspaceId);
```

**Apply workspace logo to all documents:**
```dart
Future<void> _applyLogoToAllDocuments() async {
  if (_workspaceLogo == null || _workspace?.logo == null) return;

  final extension = _workspace!.logo!.split('.').last;
  for (final doc in _documents) {
    final filePath = _storage.documentPath(workspaceId, doc.filename);
    await _ndfService.embedLogo(filePath, _workspaceLogo!, extension);
  }
}
```

### Metadata Fields
```json
{
  "ndf": "1.0.0",
  "type": "document",
  "logo": "asset://logo.png",
  "thumbnail": "asset://thumbnails/preview.png"
}
```

**Files using this pattern:**
- `lib/work/services/ndf_service.dart` - Core logo/thumbnail methods
- `lib/work/services/work_storage_service.dart` - Workspace logo management
- `lib/work/pages/workspace_detail_page.dart` - UI integration



---

## VoiceMemoClipCardWidget

Expandable card widget for displaying voice memo clips with playback controls.

**Location:** `lib/work/widgets/voicememo/voicememo_clip_card_widget.dart`

**Features:**
- Expandable/collapsible design
- Play/stop audio button
- Duration and timestamp display
- Transcription display
- Merge indicator for merged clips
- Social data display (ratings, comments)
- Action buttons (transcribe, merge, edit, delete)

**Usage:**
```dart
VoiceMemoClipCardWidget(
  clip: clip,
  isExpanded: _expandedClips.contains(clip.id),
  isPlaying: _playingClipId == clip.id,
  settings: _content.settings,
  onToggleExpanded: () => _toggleClipExpanded(clip.id),
  onPlay: () => _playClip(clip),
  onEdit: () => _editClip(clip),
  onDelete: () => _deleteClip(clip),
  onMerge: () => _mergeClip(clip),
  onTranscribe: () => _transcribeClip(clip),
)
```

---

## VoiceMemoRatingWidget

Rating widget supporting both star ratings (1-5) and like/dislike buttons.

**Location:** `lib/work/widgets/voicememo/voicememo_rating_widget.dart`

**Features:**
- Star rating (1-5)
- Like/dislike buttons
- Configurable rating type (stars, likeDislike, or both)
- Interactive or display-only mode

**Usage:**
```dart
// Interactive rating
VoiceMemoRatingWidget(
  currentStars: userRating?.stars,
  currentLiked: userRating?.liked,
  ratingType: RatingType.both,
  onStarsChanged: (stars) => _setStars(clipId, stars),
  onLikeChanged: (liked) => _setLike(clipId, liked),
  enabled: true,
)

// Display-only rating
VoiceMemoRatingDisplayWidget(
  social: clip.social,
  ratingType: settings.ratingType,
)
```

---

## Voice Memo Recording Format

Voice memos are recorded in **WAV format (16kHz mono PCM)** for direct compatibility with Whisper transcription, avoiding the need for ffmpeg conversion on mobile platforms.

**Pattern** (from `TranscriptionDialog` and `VoiceMemoRecorderWidget`):
```dart
final AudioRecorder recorder = AudioRecorder();
await recorder.start(
  RecordConfig(
    encoder: AudioEncoder.wav,
    sampleRate: 16000,
    numChannels: 1,
  ),
  path: outputPath,
);
```

**Amplitude polling** for visual feedback:
```dart
final amp = await recorder.getAmplitude();
// amp.current is in dBFS (-160 = silence, 0 = max)
final normalized = ((amp.current + 60) / 60).clamp(0.0, 1.0);
```

**Trade-off:** WAV files are ~10MB per 5-min clip vs ~500KB in Opus/OGG. This is acceptable since voice memos are stored in NDF archives and transcription compatibility on Android is the priority.

**Files using this pattern:**
- `lib/widgets/transcription_dialog.dart` — short transcription recordings
- `lib/work/widgets/voicememo/voicememo_recorder_widget.dart` — voice memo clips

---

## Audio Merge Approach

The VoiceMemoMergeService handles concatenating OGG/Opus audio clips.

**Location:** `lib/work/utils/voicememo_merge_service.dart`

**Approach:**
1. Read both audio files from NDF archive
2. Use FFmpeg (if available) for proper audio concatenation
3. Update target clip metadata (duration, mergedFrom)
4. Clear transcription (needs re-transcription)
5. Save merged audio and metadata

**FFmpeg concat approach:**
```dart
// Create concat file list
await File(listPath).writeAsString(
  "file '$firstPath'\nfile '$secondPath'\n",
);

// Run ffmpeg concat
final result = await Process.run('ffmpeg', [
  '-f', 'concat',
  '-safe', '0',
  '-i', listPath,
  '-c', 'copy', // Copy codec, no re-encoding
  '-y',
  outputPath,
]);
```

**Usage:**
```dart
final mergeService = VoiceMemoMergeService();
final updatedClip = await mergeService.mergeClips(
  ndfFilePath: filePath,
  sourceClip: clipToMerge,
  targetClip: targetClip,
);

if (updatedClip != null) {
  // Delete source clip after successful merge
  await _ndfService.deleteVoiceMemoClip(
    filePath,
    clipToMerge.id,
    clipToMerge.audioFile,
  );
}
```

**Files using this pattern:**
- `lib/work/utils/voicememo_merge_service.dart` - Merge service
- `lib/work/pages/voicememo_editor_page.dart` - UI integration

---

## SQLiteLoader

Platform-aware SQLite database loading that works across Flutter (mobile, desktop) and pure Dart/CLI contexts.

**Location:** `lib/services/sqlite_loader.dart` (conditional export)

**Purpose:**
- Flutter builds: Uses `sqlite3_flutter_libs` to provide bundled native SQLite libraries
- Pure Dart/CLI builds: Loads bundled native libs from `third_party/sqlite/` or system fallback

**Pattern - Conditional Export:**
```dart
// lib/services/sqlite_loader.dart
export 'sqlite_loader_pure.dart'
    if (dart.library.ui) 'sqlite_loader_flutter.dart';
```

**Flutter Implementation:**
```dart
// lib/services/sqlite_loader_flutter.dart
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite3_flutter_libs/sqlite3_flutter_libs.dart';

class SQLiteLoader {
  SQLiteLoader._();

  static Database openDatabase(String dbPath) {
    return sqlite3.open(dbPath);
  }

  static Database openInMemory() {
    return sqlite3.openInMemory();
  }
}
```

**Pure Dart/CLI Implementation:**
```dart
// lib/services/sqlite_loader_pure.dart
import 'dart:ffi';
import 'dart:io';
import 'package:sqlite3/open.dart' as sqlite_open;
import 'package:sqlite3/sqlite3.dart';

class SQLiteLoader {
  static bool _initialized = false;

  static void _ensureInitialized() {
    if (_initialized) return;
    final libPath = _resolveLibPath();
    if (libPath != null) {
      final loader = () => DynamicLibrary.open(libPath);
      switch (Platform.operatingSystem) {
        case 'linux':
          sqlite_open.open.overrideFor(sqlite_open.OperatingSystem.linux, loader);
        case 'macos':
          sqlite_open.open.overrideFor(sqlite_open.OperatingSystem.macOS, loader);
        case 'windows':
          sqlite_open.open.overrideFor(sqlite_open.OperatingSystem.windows, loader);
      }
    }
    _initialized = true;
  }

  static Database openDatabase(String dbPath) {
    _ensureInitialized();
    return sqlite3.open(dbPath);
  }

  // _resolveLibPath() searches:
  // 1. SQLITE_DYLIB_PATH environment variable
  // 2. third_party/sqlite/{platform}/ directories
  // 3. libs/ directory
  // 4. Falls back to system SQLite
}
```

**Required Dependencies:**
```yaml
dependencies:
  sqlite3: ^2.4.0
  sqlite3_flutter_libs: ^0.5.24  # Native SQLite libs for Flutter platforms
```

**Usage:**
```dart
import 'package:your_package/sqlite_loader.dart';

// Open a database file
final db = SQLiteLoader.openDatabase('/path/to/database.sqlite3');

// Open in-memory database
final memDb = SQLiteLoader.openInMemory();

// Use database
db.execute('CREATE TABLE IF NOT EXISTS items (id INTEGER PRIMARY KEY)');
final rows = db.select('SELECT * FROM items');
db.dispose();
```

**Files using this pattern:**
- `lib/services/sqlite_loader.dart` - Conditional export
- `lib/services/sqlite_loader_flutter.dart` - Flutter implementation
- `lib/services/sqlite_loader_pure.dart` - Pure Dart implementation
- `lib/services/nostr_relay_storage.dart` - NOSTR relay storage
- `lib/services/nostr_blossom_service.dart` - Blossom blob storage
- `packages/encrypted_archive/lib/src/sqlite_loader.dart` - Encrypted archive package

---

## BackupEncryption (ECIES)

ECIES encryption (secp256k1 + HKDF-SHA256 + ChaCha20-Poly1305) for encrypting arbitrary data using NOSTR npub/nsec keys.

**Location:** `lib/util/backup_encryption.dart`

**Usage:**
```dart
// Encrypt data for a recipient (only their nsec can decrypt)
final encrypted = BackupEncryption.encryptFile(plaintextBytes, recipientNpub);

// Decrypt with own nsec
final decrypted = BackupEncryption.decryptFile(encryptedBytes, myNsec);
```

**Reused by:** Backup service, Email cache (offline delivery)

---

## EmailRelayService Callbacks

The `EmailRelayService` uses a callback pattern that decouples email routing from the transport layer (WebSocket). Station servers provide callbacks for sending to clients.

**Location:** `lib/services/email_relay_service.dart`

**Callback types:**
```dart
typedef SendToClientCallback = bool Function(String clientId, String message);
typedef FindClientByCallsignCallback = String? Function(String callsign);
typedef GetStationDomainCallback = String Function();
typedef GetClientNpubCallback = String? Function(String callsign);
```

**Usage (from station server):**
```dart
EmailRelayService().handleEmailSend(
  message: message,
  senderCallsign: client.callsign!,
  senderId: client.id,
  sendToClient: (id, msg) => safeSocketSend(clients[id]!, msg),
  findClientByCallsign: _findClientByCallsign,
  getStationDomain: () => settings.sslDomain ?? settings.callsign,
);
```

---

## EmailRelayService Encrypted Cache

SQLite + ECIES encrypted offline email storage. When a recipient is offline, incoming emails are encrypted with their npub and stored in a per-recipient SQLite database. Delivered and cleared when the client reconnects.

**Location:** `lib/services/email_relay_service.dart` (cache methods)

**Key methods:**
- `cacheEmailForRecipient()` — Encrypt and store for offline recipient
- `retrieveAndClearCache()` — Retrieve all cached blobs and delete the DB

**Size limit:** 10 MB per recipient. Uses `BackupEncryption.encryptFile()` so only the nsec holder can decrypt.

---

## Encrypted Storage Service

The `EncryptedStorageService` provides profile data encryption using the `encrypted_archive` package. It derives encryption keys from the user's NOSTR nsec using HKDF-SHA256.

### Usage Pattern

```dart
import 'package:geogram/services/encrypted_storage_service.dart';

final encryptedStorage = EncryptedStorageService();

// Check if encryption is enabled
final status = await encryptedStorage.getStatus(callsign);
if (status.enabled) {
  print('Profile is encrypted: ${status.archivePath}');
}

// Enable encryption (migrate files to .ear archive)
final result = await encryptedStorage.migrateToEncrypted(
  callsign,
  nsec,
);
if (result.success) {
  print('Migrated ${result.filesProcessed} files');
}

// Disable encryption (extract files back to folders)
final result = await encryptedStorage.migrateToPlaintext(
  callsign,
  nsec,
);
```

### Debug API Endpoints

```bash
# Check encryption status
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "encrypt_storage_status"}'

# Enable encryption
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "encrypt_storage_enable"}'

# Disable encryption
curl -X POST http://localhost:3456/api/debug \
  -H "Content-Type: application/json" \
  -d '{"action": "encrypt_storage_disable"}'
```

**Files:**
- `lib/services/encrypted_storage_service.dart` - Main service
- `lib/services/storage_config.dart` - Archive path helpers
- `packages/encrypted_archive/` - Encrypted archive package

---

## File Launcher Service

The `FileLauncherService` provides cross-platform support for opening files and folders in the system's default application.

### Supported Platforms

| Platform | Folders | Files | Method |
|----------|---------|-------|--------|
| Linux | ✓ | ✓ | xdg-open |
| macOS | ✓ | ✓ | open |
| Windows | ✓ | ✓ | explorer / start |
| Android | ✓ | ✓ | url_launcher (ACTION_VIEW) |
| iOS | Limited | ✓ | url_launcher (Files app) |
| Web | ✗ | ✗ | Not supported |

### Usage Pattern

```dart
import 'package:geogram/services/file_launcher_service.dart';

final launcher = FileLauncherService();

// Open a folder in the system file browser
final success = await launcher.openFolder('/path/to/folder');

// Open a file with its associated application
final success = await launcher.openFile('/path/to/file.pdf');

// Open a URL in the default browser
final success = await launcher.openUrl('https://example.com');

// Check platform capabilities
if (launcher.canOpenFolders) {
  // Show open folder button
}
```

**Files:**
- `lib/services/file_launcher_service.dart` - Singleton service

---

## ProfileStorage

Abstraction layer for profile storage operations that works transparently with both filesystem storage and encrypted archive storage.

### Classes

**ProfileStorage** - Abstract interface for storage operations
**FilesystemProfileStorage** - Wraps FileSystemService for platform-agnostic file operations (works on native and web)
**EncryptedProfileStorage** - Wraps EncryptedStorageService for encrypted archives
**StorageEntry** - Directory listing entry with name, path, isDirectory, size, modified

### Usage Pattern

```dart
import 'package:geogram/services/profile_storage.dart';

// CollectionService provides the storage instance
final storage = CollectionService().profileStorage;

// Read/write files
final content = await storage.readString('extra/channels.json');
await storage.writeString('extra/config.json', jsonContent);

// Read/write binary data
final bytes = await storage.readBytes('media/photo.jpg');
await storage.writeBytes('media/new_photo.jpg', imageBytes);

// Check existence
if (await storage.exists('extra/settings.json')) {
  // File exists
}

// List directory contents
final entries = await storage.listDirectory('posts', recursive: false);
for (final entry in entries) {
  if (entry.isDirectory) {
    print('Dir: ${entry.name}');
  } else {
    print('File: ${entry.name} (${entry.size} bytes)');
  }
}

// Directory operations
await storage.createDirectory('new_folder');
await storage.deleteDirectory('old_folder', recursive: true);

// Convenience JSON methods
final data = await storage.readJson('config.json');
await storage.writeJson('config.json', {'key': 'value'});

// Copy files to/from external paths
await storage.copyFromExternal('/tmp/upload.jpg', 'media/upload.jpg');
await storage.copyToExternal('media/photo.jpg', '/tmp/export.jpg');
```

### Service Integration Pattern

Services receive storage via `setStorage()` method:

```dart
class MyService {
  ProfileStorage? _storage;

  void setStorage(ProfileStorage? storage) {
    _storage = storage;
  }

  bool get useEncryptedStorage => _storage?.isEncrypted ?? false;

  Future<void> loadData() async {
    if (_storage != null) {
      // Use storage abstraction
      final content = await _storage!.readString('data.json');
    } else {
      // Fallback to direct File() operations
      final file = File('$_collectionPath/data.json');
      if (await file.exists()) {
        final content = await file.readAsString();
      }
    }
  }
}

// In initialization:
final storage = CollectionService().profileStorage;
MyService().setStorage(storage);
```

### UI Pattern: Displaying Attachments from Encrypted Storage

When displaying attachments (images, files) that might be in encrypted storage, UI code cannot use `Image.file()` or `File()` directly because the files don't exist on disk. Instead, extract to temp file first:

```dart
import 'package:path_provider/path_provider.dart';

Future<String?> _resolveAttachmentPath(String channelFolder, String filename) async {
  // For encrypted storage, extract to temp file
  if (_service.useEncryptedStorage) {
    final bytes = await _service.getAttachmentBytes(channelFolder, filename);
    if (bytes == null) return null;

    final tempDir = await getTemporaryDirectory();
    final tempFile = File('${tempDir.path}/cache_folder/$filename');
    await tempFile.parent.create(recursive: true);
    await tempFile.writeAsBytes(bytes);
    return tempFile.path;
  }

  // For filesystem storage, return direct path
  return path.join(storagePath, channelFolder, 'files', filename);
}
```

The service should expose a method to get attachment bytes:

```dart
// In ChatService or similar:
Future<Uint8List?> getAttachmentBytes(String channelFolder, String filename) async {
  final relativePath = '$channelFolder/files/$filename';
  return await _storage.readBytes(relativePath);
}
```

**Files using this pattern:**
- `lib/pages/chat_browser_page.dart` - `_resolveAttachedFilePath()` for chat images
- `lib/services/chat_service.dart` - `getAttachmentBytes()` for reading via ProfileStorage
- `lib/pages/email_thread_page.dart` - `_buildImageThumbnail()` uses `Image.memory()` from `readAttachmentBytes()`
- `lib/pages/email_thread_page.dart` - `_openFile()` / `_openImageViewer()` use `exportAttachmentToTemp()`
- `lib/pages/email_compose_page.dart` - `_copyAttachmentsToThread()` uses `writeAttachment()`
- `lib/services/email_service.dart` - `writeAttachment()`, `readAttachmentBytes()`, `exportAttachmentToTemp()`

### Supported Services

The following services support ProfileStorage:
- CollectionService (creates and provides storage)
- ChatService
- ContactService
- BlogService
- EmailService
- EventService
- GroupsService
- ForumService
- MarketService
- NewsService
- PostcardService
- ReportService
- DirectMessageService
- ConsoleService
- VideoService
- PlaceService

**Files:**
- `lib/services/profile_storage.dart` - Abstract class and implementations
- `lib/services/encrypted_storage_service.dart` - Encrypted archive backend

- WorkStorageService (Work app - workspaces and NDF documents)

### Work App Storage Pattern

WorkStorageService uses ProfileStorage for workspace and document management:

```dart
// Create WorkStorageService with ProfileStorage
final profileStorage = CollectionService().profileStorage;
if (profileStorage != null) {
  final workStorage = WorkStorageService(profileStorage, relativePath);
  
  // Load workspaces
  final workspaces = await workStorage.loadWorkspaces();
  
  // Create workspace
  final workspace = await workStorage.createWorkspace(
    name: 'My Workspace',
    ownerNpub: profile.npub,
  );
  
  // List documents
  final docs = await workStorage.listDocuments(workspaceId);
  
  // Read/write NDF document bytes
  final ndfBytes = await workStorage.readDocumentBytes(workspaceId, filename);
  await workStorage.writeDocumentBytes(workspaceId, filename, newBytes);
}
```

### NDF Bytes-Based Operations

For encrypted storage support, NdfService provides bytes-based methods:

```dart
final ndfService = NdfService();

// Read metadata from bytes (no file path needed)
final bytes = await storage.readBytes('doc.ndf');
final metadata = ndfService.readMetadataFromBytes(bytes);

// Read thumbnail/logo from bytes
final thumbBytes = ndfService.readThumbnailFromBytes(bytes);
final logoBytes = ndfService.readLogoFromBytes(bytes);

// Create new document as bytes
final ndfBytes = ndfService.createDocumentAsBytes(
  metadata: metadata,
  permissions: permissions,
);
await storage.writeBytes('new_doc.ndf', ndfBytes);
```

**Note:** Some NDF operations (embedLogo, updateMetadata, document editing) are not yet
supported for encrypted storage and will show "feature not available" messages.

**Files:**
- `lib/work/services/work_storage_service.dart` - Workspace storage with ProfileStorage
- `lib/work/services/ndf_service.dart` - NDF document operations (file and bytes-based)

### Singleton Persistent Archive Pattern

EncryptedStorageService uses singleton pattern with persistent connections for performance:

```dart
// Archives are cached and reused (40-60x faster than opening per operation)
final archive = await _getArchive(callsign, nsec);

// Periodic flush every 30 seconds
_flushTimer = Timer.periodic(Duration(seconds: 30), (_) {
  for (final archive in _openArchives.values) {
    archive.checkpoint();  // WAL checkpoint
  }
});

// Close on profile switch
await EncryptedStorageService().closeArchive(oldCallsign);

// Close all on app shutdown
await EncryptedStorageService().closeAllArchives();
```

**Files:**
- `lib/services/encrypted_storage_service.dart` - Singleton with persistent connections
- `packages/encrypted_archive/lib/src/archive.dart` - checkpoint() method

### Temp File Pattern for NDF Editing with Encrypted Storage

When editing NDF documents in encrypted storage, use temp files:

```dart
Future<void> _openDocument(NdfDocumentRef doc) async {
  String filePath;
  String? tempFilePath;

  if (_storage.storage.isEncrypted) {
    // Extract to temp file
    final ndfBytes = await _storage.readDocumentBytes(workspaceId, doc.filename);
    final tempDir = await Directory.systemTemp.createTemp('geogram_ndf_');
    tempFilePath = p.join(tempDir.path, doc.filename);
    await File(tempFilePath).writeAsBytes(ndfBytes);
    filePath = tempFilePath;
  } else {
    filePath = _storage.storage.getAbsolutePath(relativePath);
  }

  // Open editor with filePath...

  // On editor close: save back and cleanup
  Future<void> onEditorClosed() async {
    if (tempFilePath != null) {
      final modifiedBytes = await File(tempFilePath).readAsBytes();
      await _storage.writeDocumentBytes(workspaceId, doc.filename, modifiedBytes);
      await File(tempFilePath).delete();
      await File(tempFilePath).parent.delete();
    }
  }
}
```

This pattern allows existing file-based editors to work with encrypted storage without modification.

---

## NNTP Package

The `packages/nntp/` package provides a pure Dart implementation of the NNTP (Network News Transfer Protocol) client following RFC 3977 for reading and posting to Usenet newsgroups.

### Location
`packages/nntp/`

### Public API
```dart
import 'package:nntp/nntp.dart';
```

### Core Classes

#### NNTPClient
High-level client for interacting with NNTP servers.

```dart
final client = NNTPClient(
  host: 'news.example.com',
  port: 119,       // 563 for NNTPS
  useTLS: false,
);

// Connect and authenticate
await client.connect();
await client.authenticate('username', 'password');

// List newsgroups
final groups = await client.listGroups(pattern: 'comp.lang.*');

// Select a group
final group = await client.selectGroup('comp.lang.dart');

// Fetch overview data
final entries = await client.fetchOverview(range: Range(1, 100));

// Fetch full article
final article = await client.fetchArticle(12345);

// Post a new article
await client.post(NNTPArticle(
  messageId: '',  // Server assigns
  subject: 'Hello World',
  from: 'John Doe <john@example.com>',
  newsgroups: 'comp.lang.dart',
  body: 'Article body here...',
  date: DateTime.now(),
));

// Disconnect
await client.disconnect();
```

#### Models

- **Newsgroup** - Newsgroup metadata (name, article range, posting status)
- **NNTPArticle** - Complete article with headers and body
- **OverviewEntry** - Compact article summary from XOVER
- **Range** - Article number range for queries

#### Exceptions

All NNTP errors are typed exceptions:
- `NNTPConnectionException` - Socket/TLS errors
- `NNTPAuthException` - Authentication failures
- `NNTPNoSuchGroupException` - Group not found
- `NNTPArticleNotFoundException` - Article not found
- `NNTPPostingException` - Posting not allowed or failed
- `NNTPProtocolException` - Invalid server response

### Integration Service

The `NNTPService` (`lib/services/nntp_service.dart`) provides geogram integration:

```dart
final service = NNTPService();

// Set storage (ProfileStorage abstraction)
service.setStorage(scopedStorage);

// Initialize
await service.initialize();

// Account management
await service.addAccount(NNTPAccount.eternalSeptember(
  username: 'user',
  password: 'pass',
));
await service.connect('eternal-september');

// Subscribe to newsgroups
await service.subscribe('eternal-september', 'comp.lang.dart');

// Fetch and read articles
final overview = await service.fetchOverview('eternal-september', 'comp.lang.dart');
final article = await service.fetchArticle('eternal-september', 'comp.lang.dart', 12345);

// Build threads from overview
final threads = service.buildThreads(overview);

// Post articles
await service.post('eternal-september', article);

// Events
service.onNNTPChange.listen((event) {
  // Handle connection, subscription, sync events
});
```

### UI Components

Located in `lib/usenet/`:

- **UsenetAppPage** - Main app entry point
- **NewsgroupListPage** - Browse and subscribe to groups
- **ThreadViewPage** - Read articles in threaded view
- **ArticleTile** - Article list item widget
- **NewsgroupTile** - Subscription list item widget
- **ComposeDialog** - Write new articles or replies
- **AccountSetupDialog** - Configure NNTP server connection

### Article Format

Articles can be stored in markdown format:

```dart
import 'package:geogram/usenet/utils/article_format.dart';

// Export article to markdown
final markdown = ArticleFormat.export(article);

// Parse markdown back to article
final article = ArticleFormat.parse(markdown);

// Quote for reply
final quoted = ArticleFormat.quoteForReply(article);

// Create reply
final reply = ArticleFormat.createReply(
  original: article,
  from: 'Jane <jane@example.com>',
  body: 'Reply content...',
);
```

### Supported Servers

Pre-configured presets:
- **Eternal September** - `news.eternal-september.org` (free registration required)
- **Gmane** - `news.gmane.io` (read-only, no auth)
- **Aioe** - `news.aioe.org` (no auth)

Or configure any RFC 3977 compliant NNTP server.

---

## WebSnapshotService

**Location:** `lib/work/services/web_snapshot_service.dart`

Service for capturing websites for offline viewing. Downloads HTML pages and their assets (images, CSS, JS, fonts), rewrites URLs to use local paths.

### Usage

```dart
import 'package:geogram/work/services/web_snapshot_service.dart';
import 'package:geogram/work/models/websnapshot_content.dart';

final service = WebSnapshotService();
final snapshot = WebSnapshot.create(
  url: 'https://example.com',
  depth: CrawlDepth.one,
);

// Capture website with progress updates
service.captureWebsite(
  url: 'https://example.com',
  depth: CrawlDepth.one,
  settings: WebSnapshotSettings(),
  snapshot: snapshot,
  saveAsset: (path, data) async {
    // Save asset to storage
    await ndfService.saveSnapshotAssets(filePath, snapshot.id, {path: data});
  },
).listen((progress) {
  print('Phase: ${progress.phase}, Progress: ${progress.progress}');
  print('Assets: ${progress.assetsDownloaded}/${progress.totalAssets}');
});

// Cancel capture
service.cancel();
```

### CrawlDepth Options

- `CrawlDepth.single` - Single page only
- `CrawlDepth.one` - 1 level of linked pages
- `CrawlDepth.two` - 2 levels deep
- `CrawlDepth.three` - 3 levels deep

### CaptureProgress

```dart
class CaptureProgress {
  final CapturePhase phase;      // fetching, parsing, downloading, rewriting, complete, failed
  final double progress;         // 0.0 - 1.0
  final String message;
  final int pagesProcessed;
  final int totalPages;
  final int assetsDownloaded;
  final int totalAssets;
}
```

### Related Widgets

- **SnapshotCardWidget** - Displays snapshot with metadata, status icon, stats
- **CaptureProgressWidget** - Shows capture progress with phase indicator and cancel button

---

## Stories App Components

### SceneEditorCanvas

**File:** `lib/stories/widgets/scene_editor_canvas.dart`

Interactive canvas widget for editing story scenes in Story Studio. Renders the scene background, elements, and touch areas with editing capabilities.

**Parameters:**
- `scene` - The StoryScene to edit
- `story` - The parent Story (needed for media loading)
- `storage` - StoriesStorageService instance
- `selectedElementId` - Currently selected element ID
- `onSelectionChanged` - Callback when selection changes
- `onElementChanged` - Callback when element is modified
- `onDeleteSelected` - Callback to delete selected element

**Features:**
- Renders background image (required for each scene)
- Responsive BoxFit: cover in portrait, contain in landscape
- Displays all positioned elements (text, buttons)
- Shows selection frame around selected element
- Touch areas displayed with cyan overlay
- Keyboard support (Delete to remove, Escape to deselect)
- Uses `_SelectionFrame` for drag/resize (reusable pattern)

**Text/Title Intrinsic Sizing and Centering Pattern:**
Text and title elements should use intrinsic sizing (null width/height) rather than percentage-based sizing. Since they use intrinsic sizing, they must be positioned at the anchor point and use `FractionalTranslation` to center horizontally.

```dart
// In _buildElements():
final isTextOrTitle = element.type == ElementType.text || element.type == ElementType.title;

if (isTextOrTitle) {
  // Position at anchor point, use FractionalTranslation to center
  final (anchorX, anchorY) = position.anchorPercent;
  final leftPx = (anchorX / 100) * w + (position.offsetX / 100) * w;
  final topPx = (anchorY / 100) * h + (position.offsetY / 100) * h;

  return Positioned(
    left: leftPx,
    top: topPx,
    child: FractionalTranslation(
      translation: const Offset(-0.5, 0), // Center horizontally on anchor
      child: child,
    ),
  );
} else {
  // For buttons, use percentage-based sizing
  final (left, top) = position.calculatePosition();
  final leftPx = (left / 100) * w;
  final topPx = (top / 100) * h;
  final widthPx = position.widthPercent > 0 ? (position.widthPercent / 100) * w : null;
  final heightPx = position.heightPercent != null ? (position.heightPercent! / 100) * h : null;

  return Positioned(left: leftPx, top: topPx, width: widthPx, height: heightPx, child: child);
}
```

**Why this is needed:** The `calculatePosition()` method adjusts the left position based on `widthPercent` to center elements. But for text/title with intrinsic sizing (`widthPx = null`), the actual width differs from `widthPercent`, so the centering calculation is wrong. Using `FractionalTranslation(-0.5, 0)` centers the element based on its actual rendered width.

### ElementPropertiesPanel

**File:** `lib/stories/widgets/element_properties_panel.dart`

Panel for editing element properties (text, button). Adapts based on element type.

**Parameters:**
- `element` - StoryElement to edit
- `scene` - Parent StoryScene
- `allScenes` - All scenes (for trigger targets)
- `i18n` - I18nService for translations
- `onElementChanged` - Callback when element modified
- `onTriggerChanged` - Callback when trigger modified

**Sections:**
- Position (anchor point, offset sliders)
- Size (ElementSize chips)
- Timing (appear delay slider)
- Type-specific properties (text content, colors, etc.)
- Trigger configuration (goToScene, openUrl)

### ScenePropertiesPanel

**File:** `lib/stories/widgets/scene_properties_panel.dart`

Panel for editing scene-level properties like background and auto-advance.

**Parameters:**
- `scene` - StoryScene to edit
- `allScenes` - All scenes (for auto-advance targets)
- `i18n` - I18nService
- `onSceneChanged` - Callback when scene modified
- `onSelectBackgroundImage` - Callback to open image picker
- `onSceneTitleChanged` - Callback for auto-managed title element (optional)
- `onSceneDescriptionChanged` - Callback for auto-managed description element (optional)

**Sections:**
- Scene title (with auto-managed element support)
- Scene description (with auto-managed element support)
- Background image (required) with placeholder/letterbox color
- Background music override
- Navigation settings (allow back)
- Auto-advance (enable, delay, target, countdown)

**Auto-Managed Elements Pattern:**
When `onSceneTitleChanged` or `onSceneDescriptionChanged` callbacks are provided, the parent page can automatically create/update/remove corresponding title or text elements on the scene canvas. This allows users to set scene title/description in the properties panel and have it automatically appear on the image.

```dart
// In parent page:
void _updateSceneTitleElement(String? title) {
  var elements = List<StoryElement>.from(_selectedScene!.elements);
  final existingIndex = elements.indexWhere((e) => e.id == '_scene_title');

  if (title != null && title.isNotEmpty) {
    final titleElement = StoryElement.title(
      id: '_scene_title',
      text: title,
      position: const ElementPosition(anchor: AnchorPoint.topCenter, offsetY: 5),
    );
    if (existingIndex >= 0) {
      elements[existingIndex] = titleElement;
    } else {
      elements.insert(0, titleElement);
    }
  } else if (existingIndex >= 0) {
    elements.removeAt(existingIndex);
  }
  _updateScene(_selectedScene!.copyWith(elements: elements));
}
```

### AnchorSelectorWidget

**File:** `lib/stories/widgets/anchor_selector_widget.dart`

Visual 9-point grid for selecting anchor positions.

**Parameters:**
- `selected` - Current AnchorPoint
- `onChanged` - Callback when anchor changes
- `size` - Widget size (default 80)

**Also includes:** `CompactAnchorSelector` - dropdown variant for inline use.

### AddElementDialog

**File:** `lib/stories/widgets/add_element_dialog.dart`

Dialog for adding new elements to a scene.

**Usage:**
```dart
final element = await showAddElementDialog(
  context,
  elementType: ElementType.text,
  i18n: widget.i18n,
);
if (element != null) {
  // Add element to scene
}
```

**Also includes:** `AddElementBottomSheet` - bottom sheet to select element type first.

### SoundPickerWidget

**File:** `lib/stories/widgets/sound_picker_widget.dart`

A reusable bottom sheet widget for picking background music tracks from bundled sound clips.

**Parameters:**
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `i18n` | I18nService | Yes | Localization service |
| `currentTrack` | String? | No | Currently selected track path (e.g., "cinematic/epilogue.mp3") |

**Returns:** `SoundTrack?` - the selected track, `SoundTrack.none()` if "None" was selected, or `null` if cancelled

**Usage:**
```dart
final selected = await SoundPickerWidget.show(
  context,
  i18n: i18n,
  currentTrack: currentMusicPath,
);

// null = cancelled (keep current), SoundTrack.none() = "None" selected, otherwise = track selected
if (selected != null) {
  final newPath = selected.isNone ? null : selected.file;
  print('Selected: $newPath');
}
```

**Features:**
- Categories displayed as ExpansionTile groups
- Play/stop preview for each track using just_audio
- Current selection highlighted
- "None" option to clear music selection
- Displays track title, mood, and duration

**Related:**
- `SoundClipsService` - Singleton service managing bundled sounds
- `SoundTrack` / `SoundCategory` - Model classes for track metadata

---

### SelectionFrame Pattern

**File:** `lib/stories/widgets/scene_editor_canvas.dart` (private `_SelectionFrame`)

Reusable PowerPoint-style selection frame with resize handles. Adapted from `lib/work/widgets/presentation/slide_canvas_widget.dart`.

**Pattern usage:**
```dart
_SelectionFrame(
  left: leftPx,
  top: topPx,
  width: widthPx,
  height: heightPx,
  canvasWidth: constraints.maxWidth,
  canvasHeight: constraints.maxHeight,
  onTap: () => onTap(),
  onMove: (deltaXPercent, deltaYPercent) => updatePosition(),
  onResize: (widthPercent, heightPercent) => updateSize(),
  child: childWidget,
)
```

**Features:**
- 8 resize handles (4 corners + 4 edges)
- Move cursor on content area
- Appropriate cursors on handles
- Minimum size enforcement
- Reports changes as percentages of canvas


---

### DMQueueService - Background Message Delivery Pattern

**File:** `lib/services/dm_queue_service.dart`

Singleton service for background message delivery with optimistic UI pattern. Uses `Timer.periodic` for cross-platform compatibility (no Android foreground service needed).

**Pattern usage:**
```dart
// Initialize in main.dart (deferred services section)
await DMQueueService().initialize();

// Register callback for immediate delivery trigger (done automatically in initialize)
DirectMessageService().onTriggerBackgroundDelivery = DMQueueService().processQueue;

// Check queue status
final count = await DMQueueService().getQueuedMessageCount(callsign);
final hasQueued = await DMQueueService().hasQueuedMessages(callsign);
```

**Features:**
- Timer.periodic queue processing (10-second interval)
- Exponential backoff for retries (base 15s, max 10 retries)
- Fires `DMMessageStatusChangedEvent` for UI updates
- Uses `ConnectionManager.sendDM()` for transport selection (WebRTC → Station)
- Preserves signed NOSTR events for later delivery

**Related:**
- `DirectMessageService` - Main DM service, calls `onTriggerBackgroundDelivery`
- `DMMessageStatusChangedEvent` - Event bus event for status updates
- `MessageStatus` enum - pending/delivered/failed states

---

### Optimistic UI for DM Sending

**File:** `lib/services/direct_message_service.dart` (`sendMessage()` method)

Pattern for immediate UI feedback when sending messages, with background delivery.

**Pattern:**
```dart
// 1. Create message with 'pending' status
final message = ChatMessage.now(
  author: profile.callsign,
  content: content,
  metadata: {'status': 'pending'},
);

// 2. Sign the message
final signedEvent = await signingService.generateSignedEvent(...);

// 3. Save to queue for background delivery
await _saveToQueue(callsign, message);

// 4. Add to UI cache immediately
_addMessageToCache(callsign, message);

// 5. Fire event for immediate UI display
_fireMessageEvent(message, callsign, fromSync: false);

// 6. Trigger background delivery (fire and forget)
onTriggerBackgroundDelivery?.call();
```

**Features:**
- Message appears immediately with "queued" indicator
- Background delivery via DMQueueService
- Status updates via `DMMessageStatusChangedEvent`
- Existing `isPending`/`isFailed` indicators in `MessageBubbleWidget`

---

### Local IP Address Detection

**Pattern:** Get local WiFi/LAN IPv4 addresses for device-to-device communication.

**Used in:** `lib/pages/station_dashboard_page.dart`, `lib/pages/setup_mirror_page.dart`

```dart
Future<List<String>> _getLocalIpAddresses() async {
  final ips = <String>[];
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    for (final interface in interfaces) {
      for (final addr in interface.addresses) {
        if (!addr.isLoopback && addr.address.startsWith('192.') ||
            addr.address.startsWith('10.') ||
            addr.address.startsWith('172.')) {
          ips.add(addr.address);
        }
      }
    }
  } catch (e) {
    LogService().log('Error getting local IPs: $e');
  }
  return ips;
}
```

**Notes:**
- Filters to private network ranges (192.x, 10.x, 172.x)
- Requires `dart:io` — not available on web
- Consider extracting to a shared utility if used in more places

---

## Installer Patterns

### Installer Registry Pattern

**Pattern**: JSON-based package registry for tracking installed third-party packages.

**Location**: `installed/registry.json` within each user profile

**Reuse potential**: The registry pattern (JSON file with versioned schema, array of entries, timestamps, and enabled/disabled state) is applicable to any feature that manages a list of user-installed or user-configured items.

**Key structure**:
```json
{
  "version": "1.0",
  "packages": [
    {
      "id": "com.example.package",
      "folder_name": "package-name",
      "kind": "app",
      "version": "1.0.0",
      "installed_at": "ISO-8601",
      "enabled": true
    }
  ]
}
```

**See**: [docs/apps/installer-format-specification.md](apps/installer-format-specification.md)

---

### JSON Widget Tree Renderer

**Pattern**: JSON-to-Flutter widget tree rendering. JS apps describe UI as JSON objects with `type`, `children`, and properties. The Flutter host maps these to native widgets.

**Reuse potential**: This renderer can be reused by any feature that needs to display user-defined or remote-defined UI layouts — for example, dynamic forms, server-driven UI, or theming.

**Key structure**:
```json
{
  "type": "Column",
  "children": [
    { "type": "Text", "text": "Hello", "style": { "fontSize": 24 } },
    { "type": "Button", "text": "Click", "onPressed": "handleClick" }
  ]
}
```

**See**: [docs/apps/js-runtime-api.md](apps/js-runtime-api.md#json-widget-tree-specification)

---

### JS Sandbox API Bridge

**Pattern**: Injecting a controlled set of host APIs into a sandboxed JS engine (QuickJS via flutter_js). Each API namespace is gated by a named permission.

**Reuse potential**: The bridge pattern (Dart function registered as a JS global, permission-checked, returning Futures mapped to JS Promises) is reusable for any QuickJS-based scripting feature.

**See**: [docs/apps/js-runtime-api.md](apps/js-runtime-api.md)

---

### Extension Hook System

**Pattern**: Third-party extensions declare hook points in their manifest. Core apps query a registration directory to discover and load extensions at runtime.

**Reuse potential**: The hook point pattern (registration files in a well-known directory, lifecycle callbacks, render functions returning widget trees) can be applied to any plugin system.

**See**: [docs/apps/extension-mechanism.md](apps/extension-mechanism.md)

---

### Manifest Validation

**Pattern**: JSON manifest validation with field tables, required/optional fields, semver version checking, and cross-reference validation.

**Reuse potential**: The validation approach (schema check → file existence check → cross-reference check → size limit check) is a general pattern for validating any package or bundle format.

**See**: [docs/apps/manifest-schema.md](apps/manifest-schema.md#validation-rules)

---

### Folder Name Collision Check

**Pattern**: Validating user-provided folder names against a reserved list derived from `knownAppTypesConst`.

**Reuse potential**: Any feature that creates user-named directories within the profile should check against the reserved names list to avoid collisions with core apps.

**Key code reference**: `lib/util/app_constants.dart` — `knownAppTypesConst`

**Validation**:
```dart
bool isReservedName(String name) {
  final reserved = {...knownAppTypesConst, 'flasher', 'shared_folder', 'installed', 'extensions'};
  return reserved.contains(name.toLowerCase());
}
```

**See**: [docs/apps/manifest-schema.md](apps/manifest-schema.md#reserved-folder-names)

---

### TrayService

**File**: `lib/services/tray_service.dart`

**Pattern**: Singleton desktop service that manages the system tray icon, context menu, and window hide/restore.

**Usage**:
```dart
// Initialize (call once during startup, after window_manager)
await TrayService().initialize();

// Hide window to tray
await TrayService().hideToTray();

// Restore from tray
await TrayService().restoreFromTray();

// Check if hidden
if (TrayService().isWindowHidden) { ... }

// Check platform support
if (TrayService().isSupported) { ... }
```

**Reuse potential**: Any feature that needs to check window visibility or restore the window (e.g., notification tap handlers) should use `TrayService().restoreFromTray()`.

---

### AprsMessageUtils

**File**: `lib/teleport/aprs/aprs_message_utils.dart`

**Pattern**: Shared constants, text splitting, and display-side message merging for APRS messages. Used by `AprsService`, `AprsIsClient`, conversation page, geo-chat panel, and debug API.

**Constants**:
- `aprsMaxMessageLen` (67) — max chars in a single APRS message packet body
- `aprsMaxCommentLen` (107) — max comment length in an APRS position report
- `aprsAvailableChars(String? tag)` — available body chars accounting for `#tag ` prefix

**Text Splitting**:
```dart
// Split long text into APRS-safe chunks at word boundaries
final chunks = splitAprsText('long message text...', 67);
// => ['long message', 'text...']

// Count parts without splitting
final n = aprsPartCount(text, aprsMaxMessageLen);
```

**Display Merge** (consecutive messages from same sender within 30s):
```dart
final merged = mergeConsecutiveMessages(
  rawMessages,
  myCallsign: 'MYCALL',
  mergeWindow: Duration(seconds: 30),
);
// Merged packets have joined messageText, last timestamp, allAcked logic
```

**Reuse potential**: Any APRS UI or service that sends/displays messages should import this library instead of hard-coding constants or splitting logic.

---

### AprsIsClient

**File**: `lib/teleport/aprs/aprs_is_client.dart`

**Pattern**: TCP client for APRS Internet Service. Connects to APRS-IS servers, authenticates with computed passcode, receives and parses TNC2 packets, maintains keepalive, and auto-reconnects.

**Usage**:
```dart
// Create client
final client = AprsIsClient(
  callsign: 'CR7BBQ-5',
  latitude: 38.7,
  longitude: -9.1,
  radiusKm: 100,
);

// Connect (auto-reconnects on disconnect)
await client.connect();

// Compute APRS-IS passcode (static utility)
final passcode = AprsIsClient.aprsPasscode('CR7BBQ-5'); // => 17827

// Update server-side filter while connected
client.updateFilter(radiusKm: 200);

// Disconnect
client.disconnect();
```

**Reuse potential**: The `aprsPasscode()` static method can be used anywhere an APRS-IS passcode is needed. The TCP client pattern (banner wait, line buffering, reconnect with fixed delay) is reusable for other line-oriented TCP protocols.

#### sendOneShot (standalone one-shot sender)

**Pattern**: Static utility method for sending a single APRS message via a short-lived TCP connection. Completely independent of `AprsService` — connects, authenticates, sends, optionally waits for ACK, then disconnects.

```dart
final result = await AprsIsClient.sendOneShot(
  callsign: 'MYCALL',
  destination: 'N0CALL',
  message: 'Hello from Geogram!',
  ackTimeout: Duration(seconds: 15), // optional
);
// result: {sent: true, acked: false, verified: true, line: '...', seqNo: 12345}
```

**Debug API**: `{"action":"aprs_send_oneshot","destination":"CR7BBQ","text":"Hello"}` — uses the running profile's callsign by default, or specify `"callsign":"MYCALL"` explicitly.

---

### Desktop Platform Guard

**Pattern**: Reusable platform check for desktop (Linux/Windows/macOS). Used in `DMNotificationService`, `BackupNotificationService`, `NotificationsPage`, and `TrayService`.

```dart
bool _isDesktopPlatform() {
  return defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS;
}

bool _isSupportedPlatform() {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS;
}
```

**Reuse potential**: Any service that should run on all native platforms (not just mobile) should use `_isSupportedPlatform()`. For desktop-only features, use `_isDesktopPlatform()`.

---

### TeleportChatUtils

**File**: `lib/teleport/shared/teleport_chat_utils.dart`

**Pattern**: Shared chat UI utilities for all teleport sources (Telegram, Signal, etc.).

**Components**:
- `teleportSenderColor(String name)` — Deterministic 7-color palette for sender names, consistent across messages
- `TeleportDateSeparator` — Pill-shaped day separator widget with natural date labels (Today, Yesterday, month/day)

**Usage**:
```dart
import 'package:geogram/teleport/shared/teleport_chat_utils.dart';

// Get a sender color
final color = teleportSenderColor('Alice');

// Use the date separator in a chat list
TeleportDateSeparator(date: message.dateTime);

// Create a typedef alias for backward compat
typedef TelegramDateSeparator = TeleportDateSeparator;
```

**Reuse potential**: Any new teleport source (WhatsApp, Matrix, etc.) should use these shared utilities instead of duplicating the color palette and date separator.

---

### AprsMessageBubble

**File**: `lib/teleport/aprs/widgets/aprs_message_bubble.dart`

**Pattern**: Simplified dark-mode chat bubble for APRS messages. Same color scheme as Signal/Telegram (#2B5278 outgoing, #1E2D3D incoming). Asymmetric rounded corners, sender callsign via `teleportSenderColor`, timestamp + ACK status icons.

**Usage**:
```dart
AprsMessageBubble(
  message: aprsPacket,
  isOutgoing: true,
  showSender: false, // true in tag rooms for incoming
)
```

---

### AprsConversationList

**File**: `lib/teleport/aprs/widgets/aprs_conversation_list.dart`

**Pattern**: Conversation list widget for APRS Messages tab. Shows grouped conversations (direct 1:1 and tag rooms) with FAB for composing new messages. Uses `AprsService().getConversations()` for grouping.

---

### AprsConversationPage

**File**: `lib/teleport/aprs/pages/aprs_conversation_page.dart`

**Pattern**: Chat view for APRS conversations. Reversed ListView with message bubbles, TeleportDateSeparator between days, compose bar with 67-char APRS limit and auto-prepend for tag rooms.

---

### IrcClient

**File**: `lib/teleport/irc/irc_client.dart`

**Pattern**: Pure Dart IRC protocol client. Background isolate TCP/TLS socket, IRC registration (NICK+USER), PING/PONG keepalive, nick collision handling (433), NickServ IDENTIFY, CTCP ACTION. Same isolate pattern as `AprsIsClient`.

**Reuse potential**: The IRC line parser (`_parseIrcLine`) and nick extraction (`_extractNick`) are reusable. The TLS/TCP isolate pattern is identical to APRS.

---

### IrcService

**File**: `lib/teleport/irc/irc_service.dart`

**Pattern**: Singleton multi-server IRC service with event stream. Manages `Map<String, IrcClient>` keyed by server config ID. 500ms UI throttle timer, batched SQLite writes, slash command routing.

**Debug API**: `irc_status`, `irc_connect`, `irc_disconnect`, `irc_join`, `irc_part`, `irc_send`, `irc_list`, `irc_add_server`, `irc_cache_inspect`, `irc_cache_clear`

---

### IrcMessageBubble

**File**: `lib/teleport/irc/widgets/irc_message_bubble.dart`

**Pattern**: Dark-mode chat bubble matching the Telegram/Signal style (#2B5278 outgoing, #1E2D3D incoming). Sender colors via `teleportSenderColor()`. `/me` actions rendered in italics. `IrcSystemMessage` widget for join/part/quit as centered gray text.

---

### XmppClient

**File**: `lib/teleport/xmpp/xmpp_client.dart`

**Pattern**: Pure Dart XMPP client wrapping the whixp library. Handles STARTTLS, SASL auth, stream management, and auto-reconnection internally (no isolate needed). MUC (XEP-0045) via standard stanzas: `sendPresence` for join/leave, `sendMessage` with `MessageType.groupchat` for room messages.

**Reuse potential**: The MUC join/leave/send pattern is encapsulated in methods (`joinRoom`, `leaveRoom`, `sendGroupMessage`). The event callback pattern (`onEvent` map emission) is identical to IrcClient and AprsIsClient.

---

### XmppService

**File**: `lib/teleport/xmpp/xmpp_service.dart`

**Pattern**: Singleton multi-server XMPP service with event stream. Manages `Map<String, XmppClient>` keyed by server config ID. 500ms UI throttle timer, batched SQLite writes (2s + 50-msg threshold), slash command routing (`/join`, `/part`, `/subject`, `/msg`). Max 5000 messages in memory per room.

**Debug API**: `xmpp_status`, `xmpp_connect`, `xmpp_disconnect`, `xmpp_join`, `xmpp_part`, `xmpp_send`, `xmpp_discover`, `xmpp_add_server`, `xmpp_load_chat`, `xmpp_cache_inspect`, `xmpp_cache_clear`

---

### XmppMessageBubble

**File**: `lib/teleport/xmpp/widgets/xmpp_message_bubble.dart`

**Pattern**: Dark-mode chat bubble matching the Telegram/Signal/IRC style (#2B5278 outgoing, #1E2D3D incoming). Sender colors via `teleportSenderColor()`. Clickable URLs via regex. `XmppSystemMessage` widget for join/leave/subject as centered gray italic text.

---

### XmppServerMixin

**File**: `lib/server/mixins/xmpp_server_mixin.dart`

**Pattern**: Shared mixin for XMPP server lifecycle. Both `StationServer` (Desktop) and `PureStationServer` (CLI) mix this in. Handles `XmppServer` creation with S2S federation params, start/stop, admin auto-provisioning. Requires `void log(String level, String message)` from the host class.

**Usage**:
```dart
class MyStation with XmppServerMixin {
  void log(String level, String message) => print('[$level] $message');

  Future<void> startServices() async {
    await startXmppServer(
      dataDir: '/data',
      domain: 'example.com',
      callsign: 'X1ABC',
      port: 5222,         // C2S port (default 5222)
      s2sEnabled: true,   // S2S federation (default true)
      s2sPort: 5269,      // S2S port (default 5269)
    );
  }

  Future<void> stopServices() async {
    await stopXmppServer();
  }
}
```

---

### XmppS2sManager

**File**: `lib/services/xmpp_s2s.dart`

**Pattern**: XMPP Server-to-Server federation manager. Handles outbound connections to remote XMPP servers (port 5269), inbound connections from remote servers, XEP-0220 dialback authentication, and connection pooling. Created and managed internally by `XmppServer` when `s2sEnabled: true`.

**Verified working**: Tested with conversations.im — full flow including STARTTLS, dialback auth, MUC join/leave, message send/receive, room discovery via disco#items, and disco#info responses to remote servers.

**Key components**:
- SRV lookup: `_xmpp-server._tcp.{domain}` via `dnsolve`, strips trailing dots
- Dialback auth: HMAC-SHA256 key generation, persistent secret in `{dataDir}/xmpp/s2s_secret.txt`
- Connection pool: one per remote domain, 30min idle timeout, 5min whitespace keepalive
- Stanza relay: forwards C2S stanzas to remote domains, routes incoming S2S stanzas to local sessions
- IQ routing: remote-addressed IQs (disco, etc.) forwarded via S2S; server-directed IQs answered locally

**XML builders** in `lib/util/xmpp_s2s_xml.dart`: S2S stream open/close (`jabber:server` namespace), STARTTLS+dialback features, `db:result`/`db:verify` stanzas.

**Critical bugs fixed**:
- STARTTLS race condition: must `await conn.pendingWrite` before TLS upgrade (both C2S and S2S)
- `XmppStanzaExtractor`: `_closingTags` must include `stream:features|features|failure`; `_selfClosing` must include `proceed|failure`
- Bare domain routing: `Jid.parse` returns null for bare domains (no `@`); `_forwardViaS2s` uses `to.split('/').first` as fallback

**Debug API**: `xmpp_server_s2s_status`, `xmpp_server_s2s_connect`, `xmpp_server_s2s_test`

---

## Garmin Watch App (Monkey C)

### GeoUtils module

**Location**: `garmin/source/GeoUtils.mc`

Reusable geographic math functions for Garmin Connect IQ apps:
- `calculateDistance(lat1, lon1, lat2, lon2)` — Haversine distance in km
- `calculateBearing(lat1, lon1, lat2, lon2)` — Bearing in degrees (0-360)
- `bearingToCardinal(bearing)` — Converts bearing to "N", "NE", etc.
- `formatCoord(value, positive, negative)` — Formats coordinate as "38'24N"
- `formatDistance(distKm)` — Formats as "2.3 km" or "450 m"

**Reuse potential**: Any Garmin app needing distance/direction calculations.

### DrawUtils module

**Location**: `garmin/source/BaseListView.mc`

Shared drawing utilities for Garmin views:
- `drawWrappedText(dc, x, y, font, text, maxWidth)` — Draw word-wrapped text, returns Y after last line
- `getSeverityColor(severity)` — Map severity string ("emergency", "urgent", "attention") to Garmin color

**Reuse potential**: Any Garmin view needing wrapped text or color-coded severity levels.

### BaseListView

**Location**: `garmin/source/BaseListView.mc`

Abstract scrollable list view with header, loading/error/empty states, row selection highlight, scroll indicator, and UP/DOWN/BACK input handling. Subclasses override `getHeaderTitle()`, `getItems()`, `drawRow()`, `onItemSelect()`. Paired with `BaseListDelegate` for input handling.

**Reuse potential**: Any Garmin list screen — extend BaseListView and implement 4 methods instead of rebuilding scroll/select/state logic.

### DataStore module

**Location**: `garmin/source/DataStore.mc`

Wraps `Application.Storage` for typed settings and cached data access with defaults. Pattern: each setting has a `get` + `set` function that handles type checking and default values.

**Reuse potential**: Pattern can be reused for any Garmin app that needs persistent settings.

### StationClient (Garmin)

**Location**: `garmin/source/StationClient.mc`

HTTP client pattern using `Communications.makeWebRequest()` with callback methods. Handles JSON response parsing and error reporting.

**Reuse potential**: Pattern for any Garmin HTTP API client.

### ProximityChecker

**Location**: `garmin/source/ProximityChecker.mc`

Background `ServiceDelegate` that runs on a temporal event (every 5 minutes), checks proximity to stored locations, and fires `requestApplicationWake()` notifications. Includes deduplication to avoid repeat alerts.

**Reuse potential**: Pattern for any Garmin geo-fence or location-based background alerting.

---

## Command Registry

**Location**: `lib/cli/commands/`

Self-describing command pattern for console interfaces. Each command is a class with metadata (name, aliases, description, category, contextPaths, subcommands). A central `CommandRegistry` handles dispatch, TAB completion, and help generation.

### Core Files

| File | Purpose |
|------|---------|
| `command.dart` | `Command` abstract class, `SubCommand` data class, `CommandCategory` enum |
| `command_context.dart` | `CommandContext` — flat context object with I/O, navigation state, and `Object?` service refs |
| `command_registry.dart` | `CommandRegistry` — dispatch, context-aware resolution, completion, help generation |
| `service_interfaces.dart` | Shared interfaces (`StationCommandInterface`, `ProfileCommandInterface`, etc.) so commands don't couple to platform-specific types |

### Usage

```dart
// Create and populate registry
final registry = CommandRegistry();
registry.registerAll([
  HelpCommand(registry),
  StationCommand(),
  ChatCommand(),
  // ...
]);

// Build context for each command invocation
final ctx = CommandContext(
  io: CliConsoleIO(),
  currentPath: '/station',
  station: myStation,
  profileService: myProfileService,
);

// Dispatch
final result = await registry.dispatch('start', [], ctx);
// Context-aware: 'start' in /station dispatches to 'station start'

// TAB completion
final candidates = registry.getCompletions('stat', ctx);
```

### Adding a New Command

```dart
class MyCommand extends Command {
  @override String get name => 'mycommand';
  @override String get description => 'Does something';
  @override CommandCategory get category => CommandCategory.general;

  @override
  List<SubCommand> get subcommands => [
    SubCommand(name: 'sub1', description: 'First sub', execute: _sub1),
  ];

  @override
  Future<void> execute(CommandContext ctx) async {
    // Default when no subcommand matched
  }

  static Future<void> _sub1(CommandContext ctx) async {
    final station = ctx.station as StationCommandInterface;
    ctx.success('Done!');
  }
}
```

### Per-Command Environment Filtering

Commands declare which platforms they support via `CommandEnvironment`. The registry filters at registration time — dispatch, help, and TAB completion automatically exclude unsupported commands with zero runtime checks.

```dart
// CommandEnvironment enum (in command.dart)
// Values: linux, windows, macOS, android, iOS, esp32, web
// Convenience sets: .all, .desktop, .mobile, .cli

// Default: all environments (backward-compatible)
class MyCommand extends Command {
  // No override needed — runs everywhere
}

// Restrict to specific environments
class SslCommand extends Command {
  @override
  Set<CommandEnvironment> get environments => {CommandEnvironment.linux};
}

// Use convenience sets
class StationCommand extends Command {
  @override
  Set<CommandEnvironment> get environments => CommandEnvironment.cli;
}

// Exclude specific environments
class GamesCommand extends Command {
  @override
  Set<CommandEnvironment> get environments =>
      CommandEnvironment.all.difference({CommandEnvironment.esp32});
}

// Registry filters at registration time
final registry = CommandRegistry(environment: CommandEnvironment.linux);
registry.registerAll(allCommands); // SSL included, web-only excluded
```

### Key Design Decisions

- **Shared interfaces** — commands cast `ctx.station as StationCommandInterface` and `ctx.profileService as ProfileCommandInterface`. Both CLI (`StationServer`, `CliProfileService`) and Desktop (adapter classes in `cli_console_controller.dart`) implement these interfaces, so all commands work on both platforms.
- **`setSetting(key, value)`** — interface-safe mutation pattern replacing `settings.copyWith()` + `updateSettings()`, avoids exposing concrete settings types.
- **`contextPaths`** — commands declare which virtual directories they're available in (e.g., `['/station']`), enabling context-aware dispatch without hard-coding directory logic.
- **`SubCommand`** data class — avoids 40+ tiny Command subclasses; just declare name/description/execute callbacks.
- **Navigation stays on host** — `ls`, `cd`, `pwd` mutate console state and are dispatched before the registry.
- **`CommandEnvironment` filtering** — commands declare supported platforms, registry filters at registration time. Default is `all` for backward compatibility.

**Reuse potential**: Any new console command gets help, TAB completion, and context-aware dispatch for free by extending `Command` and registering it. Commands automatically work on both CLI and Desktop platforms through the shared interfaces. Environment filtering ensures commands only appear on supported platforms.

## Navigation Handler

**Location**: `lib/cli/commands/navigation_handler.dart`

Shared virtual filesystem navigation (`cd`, `ls`, `pwd`) used by both CLI (`PureConsole`) and Desktop (`CliConsoleController`). Eliminates duplicated path resolution, directory listing, and chat context management.

### Architecture

| Class | Purpose |
|-------|---------|
| `NavigationDataProvider` | Abstract interface — host console provides I/O, root dirs, station/profile interfaces |
| `NavigationHandler` | Owns `_currentPath`, `_currentChatStation`, `_currentChatRoom`; implements `handleCd`, `handleLs`, `handlePwd`, `resolvePath`, `getChildEntries` |

### Chat Directory Hierarchy

```
/chat/
  X3ABCD/          <- local station (has rooms)
    general/
    random/
  X3WXYZ/          <- known remote station (rooms not available yet)
```

- `ls /chat` lists known stations (X3* callsigns from `getAllDevicesSorted()` + local station)
- `cd /chat/X3ABCD` then `ls` lists chat rooms from `StationCommandInterface.chatRoomsReadable`
- `cd /chat/X3ABCD/general` enters the room; host shows last 10 messages
- Remote stations show `(remote — rooms not available yet)` on `ls`
- `CallsignGenerator.isStationCallsign()` validates station callsigns

### Wiring Pattern

Both consoles implement `NavigationDataProvider` as a private inner class:

```dart
// CLI (pure_console.dart)
class _PureConsoleDataProvider implements NavigationDataProvider {
  final PureConsole _console;
  ConsoleIO get io => _console._io;
  List<String> get rootDirs => _console.rootDirs;
  StationCommandInterface? get stationInterface => _console._station;
  ProfileCommandInterface? get profileInterface => _console._profileService;
  Object? get gameConfig => _console._gameConfig;
  Object? get sslManager => _console._sslManager;
}

// Desktop (cli_console_controller.dart)
class _DesktopDataProvider implements NavigationDataProvider { ... }

// Station server (via ConsoleCommandMixin)
class _ConsoleDataProvider implements NavigationDataProvider { ... }
```

## ConsoleCommandMixin

**Location**: `lib/server/mixins/console_command_mixin.dart`

Shared mixin that provides console command execution (`/api/cli`) for station servers. Both `StationServer` (station.dart) and `PureStationServer` (pure_station.dart) mix this in.

### Architecture

Uses `BufferConsoleIO` + `CommandRegistry` + `NavigationHandler` — same infrastructure as `CliConsoleController` but without Flutter dependencies.

### Abstract Slots

| Slot | Type | Description |
|------|------|-------------|
| `consoleStationInterface` | `StationCommandInterface` | The station itself (required) |
| `consoleProfileInterface` | `ProfileCommandInterface?` | Profile service (optional) |
| `consoleGameConfig` | `Object?` | Game config (optional) |
| `consoleSslManager` | `Object?` | SSL manager (optional) |
| `consoleRootDirs` | `List<String>` | Virtual filesystem root dirs (has default) |

### Usage

```dart
class StationServer with ..., ConsoleCommandMixin implements StationCommandInterface {
  @override
  StationCommandInterface get consoleStationInterface => this;

  Future<void> _handleCliCommand(HttpRequest request) async {
    final result = await executeConsoleCommand(command);
    request.response.write(jsonEncode(result));
  }
}
```

### API Contract

```
POST /api/cli  →  {"command": "ls /chat"}
Response:       {"status": "ok", "output": "...", "path": "/chat"}
```

Navigation commands are dispatched *before* the command registry (since they mutate path state), with one special case: when `_nav.isInChatRoom` is true, `ls` shows chat history instead of directory listing.

### Key Design Decisions

- **`handleCd` returns `bool`** — `true` when entering a chat room, so the host can display the room header and last messages using its own I/O (CLI uses stdout directly, Desktop uses buffered I/O).
- **`getChildEntries(path)`** — public method for TAB completion; returns child names at a given path without formatting.
- **`StationCommandInterface`** typed provider — CLI's `StationServer` already implements it; Desktop uses `_StationServiceAdapter`.

---

## ChatModerationMixin

**Location**: `lib/server/mixins/chat_moderation_mixin.dart`

Shared mixin for global chat moderator management and API response helpers. Used by both CLI (`PureStationServer`) and Desktop (`StationServer`) stations.

**Key methods:**
- `addGlobalModerator(npub)` / `removeGlobalModerator(npub)` / `getGlobalModerators()` — Manage global moderators stored under `'*'` key in `ChatSecurity.moderators`
- `resolveIdentityToNpub(nameOrCallsign)` — Resolve callsign/nickname to npub via NIP-05 registry
- `injectModeratorFlag(roomJson, roomId, authNpub)` — Add `isModerator: true` to room JSON for authenticated moderators
- `injectModBadge(msgJson, msgNpub, roomId)` — Add `is_mod: 'true'` to message metadata for moderator authors
- `canModifyMessage(actorNpub, messageNpub, roomId)` — Check if actor can edit/delete a message (author or moderator)
- `buildModEditAttribution(actorNpub, messageNpub)` — Build `edited_by_mod`, `mod_callsign`, `mod_nickname` metadata for mod edits

**Abstract members (must be overridden):**
- `ChatSecurity get chatSecurity` — Provide the active security instance
- `Future<void> saveChatSecurity(ChatSecurity)` — Persist security changes

**Usage:**
```dart
class MyStation with ChatModerationMixin {
  @override
  ChatSecurity get chatSecurity => _security;
  @override
  Future<void> saveChatSecurity(ChatSecurity s) async { /* save */ }
}
```

---

## ChatModificationMixin

**Location**: `lib/server/mixins/chat_modification_mixin.dart`

Shared mixin for NOSTR event verification on chat message modifications (edit/delete). Used by both `LogApiService` (Desktop station) and `PureStationServer` (CLI station).

### Methods

| Method | Returns | Description |
|--------|---------|-------------|
| `verifyModificationEvent(authHeader, expectedAction, expectedRoomId)` | `NostrEvent?` | Parse Authorization header, verify sig + 5-min freshness, accept kind 5 for delete or kind 1 for both |
| `validateDeletionTarget(event, storedEventId)` | `bool` | For kind 5, checks `["e"]` tag matches stored event ID |

### Usage

```dart
class MyStation with ChatModificationMixin {
  void handleDelete(String authHeader, String roomId) {
    final event = verifyModificationEvent(authHeader, 'delete', roomId);
    if (event == null) { /* unauthorized */ }
    // For kind 5: validateDeletionTarget(event, storedEventId)
  }
}
```

---

## ChatNip05Mixin

**Location**: `lib/server/mixins/chat_nip05_mixin.dart`

Shared mixin for registering chat message senders in the NIP-05 registry. Binds callsign→npub so web chat participants are discoverable via `.well-known/nostr.json`. Used by both `StationServer` (Desktop) and `PureStationServer` (CLI).

### Methods

| Method | Returns | Description |
|--------|---------|-------------|
| `registerChatSender(callsign, npub)` | `void` | Register callsign→npub in NIP-05 registry; skips if npub is null/empty |

### Usage

```dart
class MyStation with ChatNip05Mixin {
  void handlePost(String callsign, String? npub) {
    // After message creation
    registerChatSender(callsign, npub);
  }
}
```

---

## Nip05RegistryService.buildNostrJsonResponse

**Location**: `lib/services/nip05_registry_service.dart`

Builds the complete NIP-05 `nostr.json` response map for a given name query. Handles single-name lookup (returns all names for that identity — callsign + nickname) and full-registry dump. Used by all 3 station `_handleWellKnownNostr` handlers.

### Signature

```dart
Map<String, dynamic> buildNostrJsonResponse(String? name, String relayUrl)
```

### Usage

```dart
final response = Nip05RegistryService()
    .buildNostrJsonResponse(nameParam, 'wss://p2p.radio');
request.response.write(jsonEncode(response));
```

---

## NostrLoginComponent

**File:** `lib/util/nostr_login_scripts.dart`

Reusable Nostr login component for web pages served by station servers. Supports NIP-07 browser extensions (Alby, nos2x) AND client-side key generation via embedded nostr-tools bundle. Button is always visible regardless of extension availability.

### Functions

| Function | Returns | Description |
|----------|---------|-------------|
| `getNostrLoginHeaderHtml()` | HTML string | Button + callsign display div (always visible) |
| `getNostrLoginStyles()` | `<style>` + `<script>` block | CSS + nostr.bundle.js script tag for head |
| `getNostrLoginScripts()` | JS string | Extension detection, key generation, polyfill, localStorage persistence |

### Integration

1. Add `getNostrLoginStyles()` to `<head>` (loads CSS + nostr-tools bundle)
2. Add `getNostrLoginHeaderHtml()` inside `.header__inner` (after logo)
3. Prepend `getNostrLoginScripts()` before page-specific scripts in `<script>` tag
4. Page JS listens for `nostr-connected` CustomEvent or checks `window.GeogramNostr.connected`

### Login Flow

1. Button always shown (no extension required)
2. Polls for NIP-07 extension (10 attempts x 200ms)
3. If extension found: uses it (extension always takes priority)
4. If no extension: uses nostr-tools for client-side key generation
5. Installs `window.nostr` polyfill so chat_scripts and blog likes work unchanged
6. On refresh: auto-reconnects from localStorage

### localStorage Keys

- `geogram_nostr_pubkey` — hex pubkey (used by both extension and generated)
- `geogram_nostr_privkey` — hex private key (only for generated identities)

### Global State: `window.GeogramNostr`

```js
{ pubkey: string|null, callsign: string|null, connected: boolean }
```

### Events

- **`nostr-connected`** — Dispatched on `document` when user connects. Detail: `{ pubkey, callsign }`

---

## NostrToolsBundle

**File:** `lib/util/nostr_bundle.dart`

Embedded nostr-tools JavaScript bundle (224KB) for client-side Nostr operations. Sets `window.NostrTools` with key generation, signing, and event finalization.

### Functions

| Function | Returns | Description |
|----------|---------|-------------|
| `getNostrBundleJs()` | JS string | Complete nostr-tools bundle content |

### Available APIs (via `window.NostrTools`)

- `generateSecretKey()` — Returns Uint8Array private key
- `getPublicKey(skBytes)` — Returns hex public key from Uint8Array secret key
- `finalizeEvent(event, skBytes)` — Complete signed event with id + sig
- `getEventHash(event)` — SHA-256 event ID
- `schnorr.sign(msg, key)` — BIP-340 Schnorr signature

### Route

Both stations serve the bundle at `/lib/nostr.bundle.js` with `Content-Type: application/javascript` and 24h cache.

### localStorage

- Key: `geogram_nostr_pubkey` — Stores hex pubkey for auto-connect on page reload

### Template Variables

When using themed templates, wire these in the station handler:
- `{{NOSTR_HEADER}}` → `getNostrLoginHeaderHtml()`
- `{{NOSTR_STYLES}}` → `getNostrLoginStyles()`
- `{{SCRIPTS}}` → `getNostrLoginScripts() + '\n' + getChatPageScripts()`

### WebThemeService Named Templates

**File:** `lib/services/web_theme_service.dart`

Use `getNamedTemplate(appType, templateName)` to load templates other than `index.html` (e.g., `directory.html` for shared folder directory listings).

```dart
final template = await WebThemeService().getNamedTemplate('shared', 'directory.html');
```

### Shared Folder Theme Templates

**Files:** `themes/default/shared/{index.html, directory.html, styles.css}`

The shared folder app uses device-side dynamic rendering (HTML generated per request in `websocket_service.dart`) because folder contents change at runtime. Templates are loaded via `WebThemeService` and filled with `processTemplate()`. Falls back to minimal inline HTML if templates fail to load.

Key template variables:
- `{{COLLECTION_NAME}}` — device owner's nickname or callsign
- `{{CONTENT}}` — folder cards (index) or file rows (directory)
- `{{FOLDER_NAME}}` — folder title (directory template only)
- `{{MENU_ITEMS}}` — nav menu via `AppService().generateDeviceMenu()`
- `{{HOME_URL}}` — relative path back to device root (`../` or `../../`)
- `{{NOSTR_STYLES}}` / `{{NOSTR_HEADER}}` — Nostr login component

**CSS serving:** When `filePath` is `/styles.css` or `{slug}/styles.css`, the device serves combined styles via `WebThemeService().getCombinedStyles('shared')`.

## Conference Components

### ConferenceMixin

**File:** `lib/server/mixins/conference_mixin.dart`

Station-side conference signaling relay (SFU star topology), shared by both `StationServer` (Desktop) and `PureStationServer` (CLI). The station acts as a relay for WebRTC signaling only — no audio media passes through it. Tracks speaker/listener roles and enforces speaker limits.

**Abstract contract (implement in station):**
- `conferenceLog(level, message)` — logging
- `conferenceSendToClient(clientId, data)` — send string to client
- `conferenceFindClientId(callsign)` — find client ID by callsign
- `conferenceGetClientCallsign(clientId)` — get callsign from client ID

**Public methods:**
- `handleConferenceMessage(clientId, message)` — dispatch incoming conference messages
- `conferenceHandleClientDisconnect(clientId)` — clean up on disconnect
- `getConferenceRooms()` — list active rooms

**Message types:** `conference_create`, `conference_join`, `conference_leave`, `conference_end`, `conference_signal`, `conference_role_change`, `conference_list`

### ConferenceSignalingServer

**File:** `lib/services/conference_signaling_server.dart`

Lightweight HTTP + WebSocket server run by the host for LAN-mode SFU signaling. Tracks speaker/listener roles per participant. Speakers limited by `maxSpeakers`; listeners unlimited.

**Endpoints:**
- `GET /meet/info` — room info JSON (speakers, listeners, counts)
- `WS /meet/ws` — WebSocket signaling relay
- `GET /meet/{code}` — serves browser web client

**Usage:**
```dart
final server = ConferenceSignalingServer(
  roomId: 'ABCD@MYCALL',
  roomName: 'My Conference',
  hostCallsign: 'MYCALL',
  maxSpeakers: 6,
);
server.setWebClientHtml(htmlString);
final port = await server.start();
await server.stop();
```

### ConferenceHostPeerManager

**File:** `lib/services/conference_host_peer_manager.dart`

Host-side SFU manager. Maintains one `RTCPeerConnection` per participant. Receives audio tracks from speakers via `onTrack` and forwards them to every other connection. Listeners receive all speaker tracks but send no audio. No audio mixing — individual tracks forwarded as-is.

**Key methods:**
- `startLocalAudio()` — capture host's microphone (host is always a speaker)
- `handleOffer(callsign, sessionId, sdp, role)` — answer incoming offer with all speaker tracks
- `handleAnswer/handleIceCandidate/handleBye` — standard WebRTC signaling
- `promoteToSpeaker(callsign)` — renegotiate to accept audio from participant
- `demoteToListener(callsign)` — remove participant's track from all connections
- `dispose()` — release all resources

### ConferenceParticipantPeerManager

**File:** `lib/services/conference_participant_peer_manager.dart`

Participant-side SFU manager. Maintains exactly ONE connection to the host. Receives multiple speaker tracks from the host. Sends local audio only if the participant is a speaker.

**Key methods:**
- `connectToHost(hostCallsign)` — create connection to host, send offer
- `handleOffer(callsign, sessionId, sdp)` — handle renegotiation from host (new speaker tracks)
- `handleAnswer/handleIceCandidate/handleBye` — standard WebRTC signaling
- `onPromotedToSpeaker()` — start mic, add track to host connection
- `onDemotedToListener()` — stop mic, remove track
- `startLocalAudio()` / `stopLocalAudio()` — mic control

### ConferencePeerManager (DEPRECATED)

**File:** `lib/services/conference_peer_manager.dart`

Legacy mesh peer manager. Keep temporarily for shared types (`ConferenceAudioPeer`, `ConferenceEvent`, `ConferenceSignalSender`). Will be removed after full migration.

### ConferenceService

**File:** `lib/services/conference_service.dart`

Singleton orchestration service. SFU star topology — all participants connect to host only. Auto-selects signaling mode (LAN or station). Supports speaker/listener roles with promote/demote.

**Host flow:**
```dart
final room = await ConferenceService().hostConference(roomName: 'My Room', maxSpeakers: 6);
final urls = await ConferenceService().getMeetUrls();
await ConferenceService().promoteToSpeaker('CALLSIGN');
await ConferenceService().demoteToListener('CALLSIGN');
```

**Joiner flow (default: listener, no mic):**
```dart
await ConferenceService().joinLan('ws://192.168.1.5:12345/meet/ws');
await ConferenceService().joinLan(url, participantRole: ConferenceParticipantRole.speaker);
await ConferenceService().discoverAndJoin('ABCD@X1SU86');
```

**State management:**
- `stateStream` — ConferenceState changes (idle/starting/active/ending)
- `events` — ConferenceEvent stream (peer connected/disconnected/role_changed)
- `isLocalMuted`, `toggleMute()`, `endConference()`

---

## AppsHandler

**File:** `lib/api/handlers/apps_handler.dart`

Shared handler for `GET /api/apps` — returns aggregated app availability and item counts in a single response. Used by both `PureStationServer` (CLI) and `LogApiService` (Desktop). Performs cheap filesystem scans via `ProfileStorage` (not full data loads), making it much faster than querying each app endpoint individually.

**Constructor:** `AppsHandler({required ProfileStorage storage, void Function(String, String)? log})`

**Methods:**
- `getApps()` → `Future<Map<String, dynamic>>` — returns `{success, timestamp, apps: {blog, chat, events, alerts, shared}}`

**Usage:**
```dart
final handler = AppsHandler(
  storage: FilesystemProfileStorage('$dataDir/devices/$callsign'),
  log: (level, message) => print('[$level] $message'),
);
final result = await handler.getApps();
// result['apps']['blog'] == {'available': true, 'count': 5}
```

---

## SharedFolder Model

**File:** `lib/models/shared_folder.dart`

Data model for shared folder entries. Follows the QrCode model pattern with JSON serialization and copyWith support.

**Fields:** `id`, `title`, `location`, `visibility` (public/private/restricted), `allowedReaders`, `description`, `createdAt`, `modifiedAt`, `filePath`

**Usage:**
```dart
final folder = SharedFolder(
  title: 'My Photos',
  location: '/home/user/Photos',
  visibility: SharedFolderVisibility.public,
);
final json = folder.toJsonString(); // Serialize to JSON
final loaded = SharedFolder.fromJsonString(json, filePath: path); // Deserialize
```

---

## SharedFolderService

**File:** `lib/services/shared_folder_service.dart`

Singleton service for CRUD operations on shared folder entries via ProfileStorage. Follows QrCodeService pattern.

**Key methods:**
- `setStorage(ProfileStorage)` — set the storage backend
- `initializeApp(String appPath)` — initialize the app directory
- `loadAll()` — load all shared folder entries
- `save(SharedFolder)` — create a new entry
- `update(SharedFolder)` — update an existing entry
- `delete(String filePath)` — remove entry (does NOT delete actual folder)
- `migrateFromLegacy(ProfileStorage)` — migrate old shared_folder apps

---

## SharedBrowserPage

**File:** `lib/pages/shared_browser_page.dart`

Browser page for the "Shared" app. Lists shared folder entries and allows add/edit/delete. Tapping an entry opens `FilesBrowserPage` pointing to the folder's disk location.

**Constructor:** `SharedBrowserPage(appPath: String, appTitle: String)`

**Features:**
- Empty state with icon and instructions
- FAB to add new shared folders (title, folder picker, visibility)
- Long-press context menu for edit/delete
- Automatic legacy migration on first open

---

## AT Protocol Core

### DagCbor

**File:** `lib/atproto/dag_cbor.dart`

Deterministic CBOR encoder/decoder implementing the IPLD DAG-CBOR codec. Guarantees identical bytes for identical data through sorted map keys and a custom byte-level encoder.

**API:**
- `DagCbor.encode(dynamic value)` → `Uint8List` — encode Dart value to DAG-CBOR bytes
- `DagCbor.decode(Uint8List bytes)` → `dynamic` — decode DAG-CBOR bytes; CID links returned as `CidLink`
- `CidLink(Cid cid)` — wrapper type for CID references (encoded as CBOR tag 42)

### Cid

**File:** `lib/atproto/cid.dart`

CID v1 content identifiers using SHA-256 + DAG-CBOR codec. Includes base32lower multibase encoding and unsigned varint support.

**API:**
- `Cid.fromContent(Uint8List dagCborBytes)` — hash content to produce CID
- `Cid.fromBytes(Uint8List)` / `Cid.fromString(String)` — parse from binary or multibase string
- `toBytes()` / `toBase32()` — serialize to binary or `b`-prefixed base32lower string

### MerkleSearchTree

**File:** `lib/atproto/mst.dart`

AT Protocol Merkle Search Tree. Deterministic tree shape from key hashing (SHA-256 leading zeros). Implements `MstBlockStore` interface for pluggable storage.

**API:**
- `MerkleSearchTree(MstBlockStore store)` — create new empty MST
- `insert(String key, Cid valueCid)` / `delete(String key)` / `get(String key)`
- `list({prefix, limit, cursor})` — paginated key listing
- `entries` — all entries sorted
- `MstBlockStore` — abstract interface: `getBlock(Cid)`, `putBlock(Uint8List)`
- `MemoryBlockStore` — in-memory implementation for testing

### CarWriter / CarReader

**File:** `lib/atproto/car.dart`

CAR v1 (Content-Addressable aRchive) format for bundling content-addressed blocks.

**API:**
- `CarWriter.write(Cid root, Map<Cid, Uint8List> blocks)` → `Uint8List`
- `CarReader.read(Uint8List carBytes)` → `CarFile(roots, blocks)`

### Tid

**File:** `lib/atproto/tid.dart`

Timestamp ID generator producing 13-character base32-sortable identifiers. Monotonic within a process.

**API:**
- `Tid.next()` → `String` — new TID for current microsecond
- `Tid.fromDateTime(DateTime)` → `String` — TID from specific time
- `Tid.parse(String)` → `DateTime` — extract timestamp from TID
- `Tid.isValid(String)` → `bool`

### AtprotoSigning

**File:** `lib/atproto/signing.dart`

ECDSA-secp256k1 signing with low-S normalization (required by AT Proto). Includes RFC 6979 deterministic nonces, Multikey encoding, and base58 support.

**API:**
- `generateKeyPair()` → `({Uint8List privateKey, Uint8List publicKey})`
- `derivePublicKey(Uint8List privateKey)` → `Uint8List` (33-byte compressed)
- `sign(Uint8List data, Uint8List privateKey)` → `Uint8List` (64-byte r||s)
- `verify(Uint8List data, Uint8List signature, Uint8List publicKey)` → `bool`
- `publicKeyToMultikey(Uint8List)` / `multikeyToPublicKey(String)` — Multikey round-trip

### AtprotoStorage

**File:** `lib/atproto/atproto_storage.dart`

SQLite-backed block store implementing `MstBlockStore`. Tables: blocks, repos, records, sequence.

**API:**
- `AtprotoStorage.open(String dbPath)` / `openInMemory()`
- Block ops: `getBlock(Cid)`, `putBlock(Uint8List)`, `hasBlock(Cid)`
- Repo metadata: `getHead(did)`, `setHead(did, head, signingKey)`, `getSigningKey(did)`
- Record index: `indexRecord(uri, cid, collection, rkey)`, `listRecords(collection, ...)`, `countRecords(collection)`
- Firehose: `appendEvent(Uint8List)`, `getEventsSince(cursor)`, `getLatestSeq()`
- `transaction<T>(T Function() fn)` — ACID transactions

### AtprotoRepo

**File:** `lib/atproto/repo.dart`

Repository manager orchestrating MST, signing, and storage into a complete AT Proto repo.

**API:**
- `AtprotoRepo.create({did, storage, signingKey})` — new repo
- `AtprotoRepo.open({did, storage})` — load existing repo
- `createRecord(collection, record, {rkey})` → `({String uri, Cid cid})`
- `getRecord(collection, rkey)` → `RepoRecord?`
- `putRecord(collection, rkey, record)` — upsert
- `deleteRecord(collection, rkey)` → `bool`
- `listRecords(collection, {limit, cursor, reverse})` → `List<RepoRecord>`
- `commit()` → `Cid` — create signed commit
- `exportCar()` → `Uint8List` — full repo as CAR v1

### XrpcRouter

**File:** `lib/atproto/xrpc_router.dart`

XRPC endpoint router for AT Protocol. Maps NSID-based endpoints to handlers, dispatches HTTP GET (queries) and POST (procedures), and provides JSON/error response helpers.

**API:**
- `XrpcRouter()` — create router
- `query(String nsid, XrpcHandler handler)` — register GET endpoint
- `procedure(String nsid, XrpcHandler handler)` — register POST endpoint
- `handle(HttpRequest request, String path)` → `Future<bool>` — dispatch request
- `XrpcRouter.writeJson(request, Map data)` — write JSON response
- `XrpcRouter.writeError(request, XrpcError error)` — write XRPC error response
- `XrpcRouter.readJsonBody(request)` → `Future<Map?>` — read POST JSON body
- `XrpcRouter.extractBearerToken(request)` → `String?` — extract Authorization bearer token

### JwtService

**File:** `lib/atproto/jwt_service.dart`

HS256 JWT session management for single-user AT Proto PDS. Handles access/refresh token creation, verification, refresh rotation, and revocation.

**API:**
- `JwtService({required secret, required did, required handle})` — create service
- `createSession()` → `SessionTokens` — issue access (5min) + refresh (90d) tokens
- `refreshSession(String refreshJwt)` → `SessionTokens?` — rotate refresh token (old one revoked)
- `deleteSession(String refreshJwt)` → `bool` — revoke refresh token
- `verifyAccessToken(String jwt)` → `String?` — verify and return DID, or null
- `SessionTokens({accessJwt, refreshJwt, did, handle})` — token bundle with `toJson()`

### DidService

**File:** `lib/atproto/did_service.dart`

DID:web document generator for AT Protocol. Builds `/.well-known/did.json` with Multikey verification method and AtprotoPersonalDataServer service entry.

**API:**
- `DidService({required domain, required publicKey, required handle})` — create service
- `did` → `String` — e.g. `did:web:example.com`
- `handle` → `String` (settable)
- `serviceEndpoint` → `String` — `https://{domain}`
- `buildDidDocument()` → `Map<String, dynamic>` — full DID document
- `isDid(String did)` → `bool` — check if DID matches this service
- `DidService.resolveDomain(String did)` → `String?` — extract domain from did:web

### AtprotoPdsMixin

**File:** `lib/server/mixins/atproto_pds_mixin.dart`

Shared mixin providing AT Protocol PDS lifecycle for both `AppStationServer` and `CliStationServer`. Initializes storage, signing, DID, JWT, repo, and XRPC router. Handles `/xrpc/*`, `/.well-known/did.json`, and `/api/atproto/*` debug routes.

**API:**
- `startAtprotoPds()` — initialize and start PDS (call from `onServerStart()`)
- `stopAtprotoPds()` — shut down PDS (call from `onServerStop()`)
- `handleAtprotoRequest(request, path, method)` → `Future<bool>` — route handler
- `isAtprotoRunning` → `bool`
- `atprotoDid` → `String?`
- `getAtprotoStatus()` → `Map<String, dynamic>` — debug status info

### AtUri

**File:** `lib/atproto/at_uri.dart`

Parser for AT-URI scheme strings (`at://authority/collection/rkey`). Supports DID and handle authorities, optional collection and rkey components.

**API:**
- `AtUri.parse(String uri)` — parse AT-URI, throws `FormatException` on invalid
- `AtUri.tryParse(String uri)` → `AtUri?` — parse, returns null on invalid
- `authority` → `String` — DID or handle
- `collection` → `String?` — NSID collection name
- `rkey` → `String?` — record key
- `isRecord` → `bool` — true if both collection and rkey are present
- `isDid` → `bool` — true if authority starts with "did:"
- `toString()` — reconstruct the AT-URI string

### FirehoseManager

**File:** `lib/atproto/firehose.dart`

AT Protocol event stream manager. Encodes commit/identity/info events as binary frames, stores in sequence table, broadcasts to WebSocket subscribers, supports cursor-based reconnection.

**API:**
- `FirehoseManager({required storage, required did})` — create manager
- `emitCommit({commitCid, rev, ops, prev})` → `int` — emit #commit event, returns seq
- `emitInfo(name, message)` → `int` — emit #info event
- `addSubscriber(WebSocket ws, {int? cursor})` — add subscriber, replays missed events
- `removeSubscriber(WebSocket ws)` — remove subscriber
- `getEventsSince(int cursor, {int? limit})` — replay events after cursor
- `latestSeq` → `int?` — latest sequence number
- `subscriberCount` → `int` — connected subscriber count
- `close()` — close all subscribers
- Static: `encodeCommitFrame(...)`, `encodeIdentityFrame(...)`, `encodeInfoFrame(...)`, `decodeFrame(Uint8List)` — frame encoding/decoding

### CollectionAdapter

**File:** `lib/atproto/collections/collection_adapter.dart`

Base class for collection adapters that map Geogram content types to AT Proto records. Provides shared helpers for idempotent record creation and TID generation from Geogram timestamps.

**API:**
- `nsid` → `String` — AT Protocol NSID for this collection
- `displayName` → `String` — human-readable name
- `syncAll(AtprotoRepo repo)` → `Future<int>` — sync all content, returns records created
- `createIfAbsent(repo, rkey, record)` → `bool` — create record if rkey doesn't exist
- Static: `rkeyFromTimestamp(String timestamp)` → `String` — generate TID from Geogram timestamp

### BlogCollection

**File:** `lib/atproto/collections/blog_collection.dart`

Maps BlogPost to `radio.geogram.blog.post` records. Only syncs published posts. Supports title, content, summary, tags, location (lat/lon), image reference, and edit timestamp.

**API:**
- `BlogCollection({required listPosts})` — create with post provider
- Static: `toRecord(BlogPost post)` → `Map<String, dynamic>` — convert to AT Proto record
- Static: `fromRecord(String rkey, Map record)` → `BlogPost` — convert from AT Proto record
- `syncAll(repo)` → `Future<int>` — sync published posts

### PlacesCollection

**File:** `lib/atproto/collections/places_collection.dart`

Maps Place to `radio.geogram.places.entry` records. Only syncs public/restricted places. Supports name, coordinates, radius, category, description, multilingual names/descriptions, address, history, hours.

**API:**
- `PlacesCollection({required listPlaces})` — create with place provider
- Static: `toRecord(Place place)` → `Map<String, dynamic>`
- Static: `fromRecord(String rkey, Map record)` → `Place`
- `syncAll(repo)` → `Future<int>` — sync non-private places

### EventsCollection

**File:** `lib/atproto/collections/events_collection.dart`

Maps Event to `radio.geogram.events.entry` records. Only syncs public/group events. Supports title, location, content, startDate/endDate, locationName, agenda, contacts.

**API:**
- `EventsCollection({required listEvents})` — create with event provider
- Static: `toRecord(Event event)` → `Map<String, dynamic>`
- Static: `fromRecord(String rkey, Map record)` → `Event`
- `syncAll(repo)` → `Future<int>` — sync non-private events

### AlertsCollection

**File:** `lib/atproto/collections/alerts_collection.dart`

Maps Report to `radio.geogram.alerts.report` records. Skips closed reports. Maps severity (emergency→critical, urgent/attention→warning, info→info). Derives region from coordinates.

**API:**
- `AlertsCollection({required listReports})` — create with report provider
- Static: `toRecord(Report report)` → `Map<String, dynamic>`
- Static: `fromRecord(String rkey, Map record)` → `Report`
- `syncAll(repo)` → `Future<int>` — sync non-closed reports

### CollectionSyncManager

**File:** `lib/atproto/collection_sync.dart`

Orchestrates syncing Geogram content collections into the AT Proto repository. Sync is idempotent — existing records matched by rkey are skipped. Creates a single commit for all new records across all collections.

**API:**
- `CollectionSyncManager({required repo, firehose, required log})` — create manager
- `register(CollectionAdapter adapter)` — register a collection adapter
- `adapters` → `List<CollectionAdapter>` — registered adapters
- `syncAll()` → `Future<Map<String, int>>` — sync all collections, returns NSID→count map
- `syncCollection(String nsid)` → `Future<int>` — sync single collection by NSID
- `getCollectionStatus()` → `List<Map<String, dynamic>>` — status info for all collections

---

## Hashing Utilities

### TLSH (Locality Sensitive Hash)

**File:** `lib/util/tlsh.dart`

Pure Dart implementation of TLSH (Trend Micro Locality Sensitive Hash). Produces fuzzy hashes that remain similar for similar inputs — useful for detecting near-duplicate media, documents, or binary data.

**API:**
- `TLSH.hash(Uint8List data)` → `String?` — returns uppercase hex hash string, or `null` if data is < 50 bytes

**Usage:** Used in `TelegramCacheService.ingestMediaBlob()` for fuzzy similarity detection of media files stored as BLOBs.

### SHA1 Content Hashing

**Package:** `crypto` (already in pubspec.yaml)

Standard SHA1 hashing for exact content deduplication.

**API:**
- `import 'package:crypto/crypto.dart';`
- `sha1.convert(bytes).toString()` → lowercase hex SHA1 hash string

**Usage:** Used in `TelegramCacheService.ingestMediaBlob()` to detect identical media files within the same per-chat SQLite database, avoiding duplicate BLOB storage for forwarded or re-sent media.

---

## Background Task Monitor

**Files:**
- `lib/models/monitored_task.dart` — Data model + enums
- `lib/services/task_monitor_service.dart` — Singleton registry
- `lib/util/task_monitor_helpers.dart` — Drop-in wrappers
- `lib/pages/task_settings_page.dart` — Settings UI

Centralized registry for all background tasks (Timer.periodic, Isolate, async loops). Provides visibility into what's running, success/fail counts, duration tracking, pause/resume, and a debug API.

### Quick Start — Adopting Timer.periodic

Replace a raw `Timer.periodic` with a monitored wrapper:

```dart
// Before:
_timer = Timer.periodic(Duration(seconds: 10), (_) => processQueue());

// After:
import '../util/task_monitor_helpers.dart';
import '../models/monitored_task.dart';

_timer = MonitoredAsyncPeriodicTimer(
  id: 'dm_queue.process',
  name: 'DM Queue Processor',
  description: 'Delivers queued direct messages via WebRTC or Station',
  serviceName: 'DMQueueService',
  interval: Duration(seconds: 10),
  priority: TaskPriority.normal,
  callback: (_) async => await processQueue(),
);

// Teardown (replaces _timer?.cancel()):
_timer.cancel();
```

For sync callbacks, use `MonitoredPeriodicTimer` instead.

### Isolate / FFI Task Registration

For tasks running in isolates (APRS-IS, TDLib, Signal bridge) where the callback can't be wrapped:

```dart
import '../util/task_monitor_helpers.dart';
import '../models/monitored_task.dart';

final _handle = MonitoredIsolateHandle(
  id: 'aprs.is_client',
  name: 'APRS-IS Connection',
  description: 'Maintains TCP connection to APRS-IS network',
  serviceName: 'AprsService',
  priority: TaskPriority.normal,
);

// Call from main isolate when status changes:
_handle.markRunning();   // connection established
_handle.markIdle();      // clean disconnect
_handle.markError(e);    // connection lost

// Teardown:
_handle.dispose();
```

### API Reference

**TaskMonitorService** (singleton):
- `register(MonitoredTask)` / `unregister(id)` — add/remove tasks
- `reportStart(id)` / `reportSuccess(id)` / `reportFailure(id, error)` — lifecycle hooks
- `tasks` → `List<MonitoredTask>` — all registered tasks
- `getTask(id)` → `MonitoredTask?`
- `tasksByService` → `Map<String, List<MonitoredTask>>`
- `tasksByPriority` → `Map<TaskPriority, List<MonitoredTask>>`
- `pause(id)` → `bool` (refuses critical), `resume(id)` → `bool`
- `pauseAllNonCritical()` → `int`, `resumeAll()` → `int`
- `stateChanges` → `Stream<TaskStateChangedEvent>` (for UI)
- `toJson()` → summary map with task list

**MonitoredTask** fields: `id`, `name`, `description`, `serviceName`, `priority` (critical/normal/low), `type` (periodic/isolate/oneshot), `interval`, `status` (idle/running/paused/error), `lastRunAt`, `lastDuration`, `runCount`, `successCount`, `failCount`, `lastError`, `registeredAt`

### Debug API

```bash
# List all tasks with summary counts
curl -X POST http://localhost:8080/api/debug \
  -d '{"action":"task_status"}'

# Pause a specific task (refuses critical)
curl -X POST http://localhost:8080/api/debug \
  -d '{"action":"task_pause","id":"dm_queue.process"}'

# Resume a paused task
curl -X POST http://localhost:8080/api/debug \
  -d '{"action":"task_resume","id":"dm_queue.process"}'
```

### Settings UI

Available at Settings drawer → "Tasks". Shows summary card with colored status chips, grouped task list (by service or priority), expandable tiles with status dot, run stats, error details, and pause/resume switch per task.

## CSV Append-Only Storage Pattern

**Files:**
- `lib/tracker/models/tracker_path.dart` — `TrackerPoint.toCsvLine()`, `TrackerPoint.fromCsvLine()`, `TrackerPathPoints.fromCsv()`, `TrackerPathPoints.toCsv()`
- `lib/tracker/services/tracker_storage_service.dart` — `appendPathPointCsv()`, CSV-aware `readPathPoints()`, `writePathPoints()`
- `lib/tracker/utils/tracker_path_utils.dart` — `pathPointsCsvFile()`

For high-frequency append-only data (GPS points, sensor readings), use CSV with `ProfileStorage.appendString()` instead of JSON read-modify-write. This is O(1) per write and crash-safe (partial last line is silently skipped on read).

### Usage

```dart
// Append one point (O(1)):
await storage.appendPathPointCsv(year, pathId, point);

// Read all points (tolerates corrupt lines):
final points = await storage.readPathPoints(year, pathId);
// Tries points.csv first, falls back to points.json

// Bulk write (merge, trim):
await storage.writePathPoints(year, pathId, points);

// Clean up legacy JSON after migration:
await storage.cleanupLegacyPointsJson(year, pathId);
```

### CSV Format
`index,timestamp,lat,lon,altitude,accuracy,speed,bearing` — empty string for null optional fields.

### When to Use
- Data grows by append only during recording/collection
- Crash recovery matters (JSON corruption from partial writes)
- Individual records are small and uniform (same fields per line)

## NOSTR Client Bridge

**Files:**
- `lib/teleport/nostr/models/nostr_relay_config.dart` — Relay configuration model
- `lib/teleport/nostr/models/nostr_feed_item.dart` — Feed item wrapper for UI
- `lib/teleport/nostr/nostr_relay_client.dart` — WebSocket client per relay
- `lib/teleport/nostr/nostr_cache_service.dart` — SQLite cache (per relay DB)
- `lib/teleport/nostr/nostr_client_service.dart` — Main singleton service
- `lib/teleport/nostr/pages/nostr_main_page.dart` — Feed page with compose bar
- `lib/teleport/nostr/pages/nostr_settings_page.dart` — Relay management UI
- `lib/teleport/nostr/widgets/nostr_event_tile.dart` — Dark-mode bubble widget
- `lib/teleport/nostr/widgets/nostr_relay_list.dart` — Relay list with status

Connects to external NOSTR relays via WebSocket, receives kind:1 text notes (+ kind:0 metadata, kind:3 contacts), and provides a feed UI with Firehose/Only-Follows filtering. Reuses existing `NostrEvent`, `NostrCrypto`, and `SigningService` for event signing.

### Architecture

- **Multi-relay**: One `NostrRelayClient` WebSocket per configured relay
- **Singleton service**: `NostrClientService()` — same pattern as `IrcService()`
- **SQLite per relay**: `teleport/nostr/cache/{relay_id}.db` via ProfileStorage
- **UI throttle**: 500ms timer (same as IRC/APRS)
- **Batch writes**: 2-second flush timer for SQLite
- **Task monitor**: `MonitoredIsolateHandle` per relay connection
- **Event dedup**: Global set of seen event IDs

### Quick Start

```dart
// Service auto-starts in main.dart post-frame callback
final nostr = NostrClientService();

// Add a relay
await nostr.addRelay(NostrRelayConfig(
  id: NostrRelayConfig.idFromUrl('wss://relay.damus.io'),
  url: 'wss://relay.damus.io',
  name: 'relay.damus.io',
));

// Connect
nostr.connect('relay_damus_io');

// Listen to feed updates
nostr.events.listen((event) {
  if (event.type == NostrClientEventType.feedUpdated) {
    final items = nostr.feedItems; // filtered by feedFilter
  }
});

// Publish a note
await nostr.publish('Hello NOSTR!');
```

### Debug API

```bash
# Get relay status, feed count, follows count
curl localhost:PORT/debug?action=nostr_status

# Connect to a relay by URL
curl localhost:PORT/debug?action=nostr_connect&url=wss://relay.damus.io

# Disconnect
curl localhost:PORT/debug?action=nostr_disconnect&relayId=relay_damus_io
```

### NostrClientService.searchFeed

**File:** `lib/teleport/nostr/nostr_client_service.dart`

Searches the in-memory NOSTR feed using a case-insensitive match on content,
author display name, NIP-05, npub, and pubkey hex. Honors the current feed
filter (firehose vs. follows).

**Usage:**
```dart
final results = NostrClientService().searchFeed('mesh');
```

### NostrClientService.requestSearch

**File:** `lib/teleport/nostr/nostr_client_service.dart`

Queries connected relays using the NIP-50 `search` filter for text notes.
Pairs with `searchFeed()` for local cached filtering.

**Usage:**
```dart
NostrClientService().requestSearch('mesh');
```

### NostrClientService.followUser/unfollowUser/likeEvent

**File:** `lib/teleport/nostr/nostr_client_service.dart`

Reusable helpers for NIP-02 follow/unfollow (kind:3 contact list) and
NIP-25 reactions (kind:7). These publish to write-enabled relays and
update the in-memory feed optimistically.

**Usage:**
```dart
await NostrClientService().followUser(pubkeyHex);
await NostrClientService().unfollowUser(pubkeyHex);
await NostrClientService().likeEvent(eventId, authorPubkeyHex);
```


### NostrClientService.publishReply

**File:** `lib/teleport/nostr/nostr_client_service.dart`

Publishes a NIP-10 reply (kind:1 with root/reply `e` tags and a `p` tag)
for a target event.

**Usage:**
```dart
await NostrClientService().publishReply('Reply text', targetEvent);
```

### NostrUserProfilePage

**File:** `lib/teleport/nostr/pages/nostr_user_profile_page.dart`

Profile view for a NOSTR user showing avatar, display name, NIP-05, bio,
follow/unfollow action, and recent posts (with like support). Calls
`requestUserPosts(pubkey)` to fetch from relays.

**Usage:**
```dart
Navigator.of(context).push(
  MaterialPageRoute(
    builder: (_) => NostrUserProfilePage(pubkey: pubkeyHex),
  ),
);
```

### NostrNip19.decode

**File:** `lib/util/nostr_nip19.dart`

Decode NIP-19 `nostr:` URIs and extract event IDs or pubkeys. Supports
`note`, `npub`, `nevent`, `nprofile`, and `naddr`.

**Usage:**
```dart
final decoded = NostrNip19.decode('nostr:nevent1...');
if (decoded?.eventIdHex != null) {
  print(decoded!.eventIdHex);
}
```

---

## APRS Geo-Chat Panel

**Files:**
- `lib/teleport/aprs/widgets/aprs_geo_chat_panel.dart` — Floating chat panel widget
- `lib/teleport/aprs/aprs_service.dart` — `geoChatMessages` list + `sendGeoChat()` method
- `lib/teleport/aprs/aprs_is_client.dart` — `_extractPositionComment()` parser
- `lib/teleport/aprs/models/aprs_packet.dart` — `comment` field on `AprsPacket`

Geo-chat uses standard APRS position reports with comment text (`!DDMM.MMN/DDDMM.MMW$comment`). Every station in the APRS-IS radius filter already receives these — the parser extracts the comment from position packets and collects them in `AprsService.geoChatMessages`.

### Widget: AprsGeoChatPanel

Floating overlay on the right side of the APRS Map tab. Desktop: always visible (320px wide). Mobile: toggled via FAB.

```dart
AprsGeoChatPanel(
  messages: aprsService.geoChatMessages,
  myLocation: myLocation,
  onMessageTap: (lat, lon) => mapController.move(LatLng(lat, lon), zoom),
  onClose: () => setState(() => showGeoChat = false),
)
```

### Service: sendGeoChat()

Builds and sends an APRS position report with comment text:

```dart
final echo = AprsService().sendGeoChat('Hello from here');
// Sends: MYCALL>APRS,TCPIP*:!DDMM.MMN/DDDMM.MMW$Hello from here
// Returns local echo AprsPacket with isOutgoing: true
```

### Debug API

- `aprs_geochat` — List all geo-chat messages (sender, lat, lon, comment, timestamp, isOutgoing, distKm)
- `aprs_send_geochat` — Send a geo-chat message: `{"action":"aprs_send_geochat","text":"Hello"}`

## BlueAprsService

**File:** `lib/teleport/aprs/blue_aprs_service.dart`

APRS over Bluetooth Low Energy bridge. Acts as both an iGate (BLE ↔ APRS-IS) and a repeater (BLE ↔ BLE). Reuses the existing BLE chat protocol with a `_aprs` system channel and `aprs` capability flag.

**Key APIs:**
- `BlueAprsService().activate()` / `.deactivate()` — Start/stop the bridge
- `BlueAprsService().isActive` — Whether the bridge is running
- `BlueAprsService().getStatus()` — Bridge status including connected BLE clients and stats
- `BlueAprsService().injectBleAprsMessage()` — Simulate a BLE client sending APRS (debug API)
- `BlueAprsService().injectAprsPacket()` — Simulate APRS-IS packet for BLE client (debug API)
- `BlueAprsService().registerSimulatedClient()` — Register test BLE client (debug API)
- `BlueAprsService().getClientInbox()` — Check simulated client inbox (debug API)

**Architecture:**
```
BLE Clients ── BLEMessageService ── BlueAprsService ── AprsService ── APRS-IS
                (channel: _aprs)      (bridge)          (existing)
```

**Rate limiting:** 1 message per 30 seconds per BLE device.

## BLEAprsPayload

**File:** `lib/models/ble_message.dart`

Data class for structured APRS data carried inside `BLEChatPayload.content` (JSON string) on the `_aprs` system channel.

**Fields:** `to`, `text`, `lat`, `lon`, `comment`, `type` (message/geochat/position), `from`, `msgId`

**Usage:**
```dart
final payload = BLEAprsPayload(to: 'N0CALL', text: 'Hello', type: 'message');
final error = payload.validate(); // null if valid
final jsonStr = json.encode(payload.toJson());
```

## MeshCore Protocol Codec

**File:** `lib/teleport/meshcore/meshcore_protocol.dart`

Pure Dart binary encoder/decoder for the MeshCore companion radio BLE protocol. No Flutter dependency — reusable from CLI tools.

### Encoding

```dart
import 'package:geogram/teleport/meshcore/meshcore_protocol.dart';

// Start session
final cmd = encodeAppStart(); // → [0x01]

// Sync device clock
final timeCmd = encodeSetDeviceTime(DateTime.now());

// Send direct message (32-byte Ed25519 pub key)
final sendCmd = encodeSendTxtMsg(pubKey32, 'Hello mesh!');

// Send channel message (index 0-7)
final chCmd = encodeSendChannelTxtMsg(0, 'Hello channel!');

// Poll next queued message
final syncCmd = encodeSyncNextMessage();
```

### Decoding

```dart
final response = decodeResponse(rawBytes);
switch (response) {
  case SelfInfoResponse():
    print('Device: ${response.name}, key: ${bytesToHex(response.pubKey)}');
  case ContactMessageResponse():
    print('From: ${response.senderPrefixHex}, text: ${response.text}, SNR: ${response.snr}');
  case NoMoreMessagesResponse():
    print('All messages synced');
  case PushMsgWaiting():
    // Poll with encodeSyncNextMessage()
}
```

### Constants
- `meshCoreMaxTextBytes = 133` — Maximum message text length
- Command codes: `MeshCoreCmd.appStart`, `.sendTxtMsg`, `.syncNextMessage`, etc.
- Response codes: `MeshCoreResp.selfInfo`, `.contactMessage`, `.channelMessage`, etc.
- Push codes: `MeshCorePush.msgWaiting`, `.sendConfirmed`, `.advert`, etc.

## MeshCore BLE Client

**File:** `lib/teleport/meshcore/meshcore_ble_client.dart`

Nordic UART Service (NUS) BLE transport for communicating with MeshCore companion radios. Handles scan, connect, send, and receive with Linux BlueZ retry patterns.

```dart
final client = MeshCoreBleClient();

// Scan for MeshCore devices (filters by NUS UUID)
final devices = await client.scanForDevices();

// Connect
await client.connect(devices.first.device);

// Send command and wait for specific response
final resp = await client.sendAndWait(
  encodeAppStart(),
  expectedCode: MeshCoreResp.selfInfo,
);

// Listen to all responses
client.responses.listen((response) { ... });
```

## MeshCore Message Bubble

**File:** `lib/teleport/meshcore/widgets/meshcore_message_bubble.dart`

Chat bubble widget with SNR signal quality badge (color-coded: green/orange/red) and ACK delivery checkmark (single check = sent, double check = acknowledged).

```dart
MeshCoreMessageBubble(message: meshCoreMessage)
```

## LocalBackupService

**File:** `lib/services/local_backup_service.dart`
**Models:** `lib/models/local_backup_models.dart`

Singleton service for creating and restoring local ZIP archive backups of the active profile. Supports both filesystem and encrypted (SQLite) profiles. Includes auto-backup timer and snapshot pruning.

```dart
final service = LocalBackupService();
service.initialize();

// Configure
service.setBackupFolder('/path/to/backups');
service.updateSettings(autoBackupEnabled: true, maxSnapshots: 10);

// Create/list/restore/delete
final snapshot = await service.createBackup();
final snapshots = await service.listSnapshots();
await service.restoreSnapshot(snapshot.filePath);
await service.deleteSnapshot(snapshot.filePath);

// Auto-backup timer
service.startAutoBackup();
service.stopAutoBackup();
```

Debug API actions: `local_backup_set_folder`, `local_backup_create`, `local_backup_list`, `local_backup_restore`, `local_backup_delete`, `local_backup_status`.

---

## NowService — EventBus-driven activity feed

**Pattern**: Singleton service that aggregates events from multiple sources via a single EventBus event type (`NowItemEvent`). Any service can participate by firing `NowItemEvent` — no coupling required.

**Key components**: `NowItemEvent` (event_bus.dart), `NowItem` (models/now_item.dart), `NowService` (services/now_service.dart), `NowPage` (pages/now_page.dart)

**Reusable patterns**:
- Muting sources via ConfigService (`now.mutedSources`)
- Read state tracking via ConfigService (`now.readItems`, capped at 500)
- Priority-based sorting with two-level grouping (appType → sourceId)
- Badge count via StreamController broadcast
- Per-group settings with cascading resolution (`appType:sourceId` → `appType` → `_default` → hardcoded) via `NowGroupSettings`
- Per-group item limits and TTL-based expiry with periodic pruning timer
- Collapsible two-level UI sections with long-press settings bottom sheet
- IRC integration: `IrcService._addMessage()` fires `NowItemEvent` for incoming messages; sourceId format `serverId:channel` enables direct navigation to `IrcChatPage`
- Blog/Events/Places integration: Local services fire `BlogPostPublishedEvent`, `EventCreatedEvent`, `PlaceCreatedEvent` → NowService converts to `NowItemEvent`. Station broadcasts `UPDATE:` to clients. `StationContentNotificationService` listens for remote UPDATE notifications and fires `NowItemEvent` for client-side display.

---

## BitChat Protocol

**File**: `lib/teleport/bitchat/bitchat_protocol.dart`
**Pattern**: Pure Dart binary protocol codec with sealed classes (CLI-reusable, no Flutter deps)

Encodes/decodes BitChat mesh packets: 13-byte header (version, type, TTL, timestamp, flags, payload length, hop count), 8-byte sender ID, optional 8-byte recipient ID, variable payload.

```dart
// Encode
final data = encodeBroadcast(senderId: sid, text: 'hello');
final data = encodeDirect(senderId: sid, recipientId: rid, text: 'hi');
final data = encodeAck(senderId: sid, messageUuid: uuid);
final data = encodeAnnounce(senderId: sid, nickname: 'bob', geohash: 'u33d');

// Decode
final packet = decodePacket(rawBytes);
switch (packet) {
  case BitchatBroadcastPacket(): ...
  case BitchatDirectPacket(): ...
  case BitchatAckPacket(): ...
  case BitchatAnnouncePacket(): ...
}
```

---

## BitChat BLE Client

**File**: `lib/teleport/bitchat/bitchat_ble_client.dart`
**Pattern**: Multi-peer BLE transport with mesh relay (follows MeshCore BLE client pattern)

Manages concurrent BLE connections to multiple BitChat peers. Scans by service UUID, connects, chunks by MTU, reassembles packets from notifications.

```dart
final client = BitchatBleClient();
client.enable();
final peers = await client.scanForPeers();
await client.connectToPeer(peers.first.device);
await client.broadcastToAll(packetBytes);
client.packets.listen((rawData) { ... });
```

---

## BitChat Service

**File**: `lib/teleport/bitchat/bitchat_service.dart`
**Pattern**: Singleton with event stream, bloom filter dedup, 500ms UI throttle, 2s batch writes

```dart
final service = BitchatService();
service.autoStart(storage);
service.enable();
service.updateLocation(lat, lon);
await service.sendBroadcast('hello mesh');
await service.sendPrivate('hi', recipientId);
service.events.listen((e) { ... });
```

---

## BitChat Message Bubble

**File**: `lib/teleport/bitchat/widgets/bitchat_message_bubble.dart`
**Pattern**: Chat bubble with hop count badge, delivery status icons, sender color via `teleportSenderColor()`

---

## Meshtastic Protobuf Codec

**File**: `lib/teleport/meshtastic/meshtastic_protobuf.dart`
**Pattern**: Pure Dart protobuf wire format encoder/decoder. No generated code, no protobuf dependency. CLI-reusable.

Implements `ProtobufWriter` and `ProtobufReader` for generic protobuf wire types (varint, fixed32, length-delimited, fixed64). Also contains all Meshtastic-specific message classes (FromRadio, ToRadio, MeshPacket, Data, User, Position, NodeInfo, Channel, ServiceEnvelope) with encode/decode methods.

BLE framing helpers: `frameBlePacket()` (0x94C3 + 2-byte BE length), `deframeBleData()`.

```dart
// Encode a ToRadio message
final toRadio = MeshtasticToRadio(wantConfigId: 12345);
final bytes = toRadio.encode();
final frame = frameBlePacket(bytes);

// Decode a FromRadio message
final fromRadio = MeshtasticFromRadio.decode(payload);
if (fromRadio.packet != null) { /* handle mesh packet */ }
```

---

## Meshtastic Crypto

**File**: `lib/teleport/meshtastic/meshtastic_crypto.dart`
**Pattern**: AES256-CTR encryption for Meshtastic channel packets using `pointycastle`. Pure Dart, CLI-reusable.

```dart
final key = expandPsk(Uint8List.fromList([0x01])); // Default LongFast key
final encrypted = encryptMeshtastic(plaintext, key, packetId, fromNode);
final decrypted = decryptMeshtastic(ciphertext, key, packetId, fromNode);
```

---

## Meshtastic BLE Client

**File**: `lib/teleport/meshtastic/meshtastic_ble_client.dart`
**Pattern**: BLE transport with Meshtastic service UUID and two-step notification model (FromNum notifies, then read FromRadio repeatedly until empty).

---

## Meshtastic Service

**File**: `lib/teleport/meshtastic/meshtastic_service.dart`
**Pattern**: Singleton service with event stream, config request flow (wantConfigId -> MyNodeInfo/NodeInfo/Channel/configComplete), packet routing by portnum, node database, channel PSK decryption.

---

## Meshtastic Message Bubble

**File**: `lib/teleport/meshtastic/widgets/meshtastic_message_bubble.dart`
**Pattern**: Chat bubble with SNR badge, RSSI badge, hop count badge, delivery status icons. Uses `teleportSenderColor()` from shared utilities.

---

## Geohash

**File**: `lib/util/geohash.dart`
**Pattern**: Pure Dart, CLI-reusable. Encode/decode lat/lon to geohash strings, compute 8 neighbors.

```dart
final hash = geohashEncode(38.7, -9.14, precision: 6); // 'eyc4p2'
final decoded = geohashDecode(hash); // center + error margins
final neighbors = geohashNeighbors(hash); // 8 surrounding cells
final region = geohashRegion(38.7, -9.14, precision: 4); // center + 8 neighbors
```

---

## Noise XX Handshake

**File**: `lib/util/noise_xx.dart`
**Pattern**: Noise Protocol Framework XX pattern using `cryptography` package (X25519 + ChaCha20-Poly1305 + SHA-256)

```dart
final kp = await NoiseXXHandshake.generateKeyPair();
final initiator = NoiseXXHandshake(staticKeyPair: kp);
final msg1 = await initiator.initiatorHello();
// ... exchange messages ...
final transport = await initiator.split();
final encrypted = await transport.encrypt(plaintext);
```

---

## Bloom Filter

**File**: `lib/util/bloom_filter.dart`
**Pattern**: Pure Dart probabilistic set membership. Used for message UUID dedup.

```dart
final filter = BloomFilter(capacity: 10000, errorRate: 0.01);
filter.addString(messageUuid);
if (filter.mightContainString(uuid)) { /* probably seen */ }
```

---

## RoutingService

**File**: `lib/services/routing_service.dart`
**Pattern**: Offline A* routing engine. Downloads OSM road network via station-first/internet-fallback, caches locally, performs on-device pathfinding.

```dart
// Download road data for offline use
await RoutingService().downloadRoadData(lat: 38.7, lon: -9.1, radiusKm: 30);

// Calculate a route
final result = await RoutingService().getRoute(
  fromLat: 38.72, fromLon: -9.14,
  toLat: 38.75, toLon: -9.10,
  mode: TravelMode.driving,
);
// result.points (List<LatLng>), result.distanceMeters, result.durationSeconds
```

---

## RoadHandler

**File**: `lib/server/handlers/road_handler.dart`
**Pattern**: Station endpoint for road data. Fetches from Overpass API, caches on disk, serves to clients.

Endpoint: `GET /api/roads?south=X&west=X&north=X&east=X`

---

## launchExternalNavigator

**File**: `lib/util/navigator_launcher.dart`
**Pattern**: Shared utility for opening external map/navigation apps. Handles Android (geo: intent), iOS (Apple Maps), and desktop/web (OpenStreetMap).

```dart
await launchExternalNavigator(38.72, -9.14);
```

---

## MapTileService.getStationBaseUrl

**File**: `lib/services/map_tile_service.dart`
**Pattern**: Returns station HTTP base URL (no trailing slash, no tile path). Handles ws->http conversion and local-only detection. Reusable for tiles, road data, and other station endpoints.

```dart
final baseUrl = MapTileService().getStationBaseUrl();
// e.g. "http://192.168.1.100:8080"
```
