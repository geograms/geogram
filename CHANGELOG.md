# Geogram Desktop Changelog

## 2026-04-27 - v1.39.0-beta.15

### Fixes
- File browser thumbnails: cache now actually caches across reopens. `FileBrowserCacheService.saveThumbnail` used to schedule a 2-second debounced flush of the metadata JSON; if the picker closed before the timer fired, the ZIP held the bytes but the JSON didn't reference them — so every subsequent open ran the generator from scratch. Metadata is now flushed synchronously inside `saveThumbnail`, so a thumbnail is durable the instant the call returns.
- File browser thumbnails: storage layout is no longer O(N²). The previous ZIP-per-volume layout decoded + re-encoded the entire archive on every save, which made each save proportional to the cache size. Each thumbnail is now a single raw file at `<cacheDir>/thumbs/<volumeId>/<sha1>.<ext>` — every save is one O(1) file write. Old `.zip` cache files are deleted on first init.
- File browser thumbnails: video frame extraction is genuinely off the UI thread now. `media_kit` is a Flutter platform plugin and cannot be moved to a Dart isolate, so a single big video would freeze the picker for several seconds even with serialization in place. The new `ThumbnailExtractor` abstraction dispatches by platform — desktop uses `ffmpeg` via `Process.run` (separate OS process, UI thread free), Android uses a `MethodChannel` to `MediaMetadataRetriever` running on a Java background thread, and `media_kit` is only the last-resort fallback.

### Changes
- Cross-platform cache: `FileBrowserCacheService` no longer imports `dart:io` — all reads / writes go through `FileSystemService` (the existing dart:io-on-native, fs_shim/IndexedDB-on-web abstraction in `lib/platform/`). The cache file compiles cleanly for the web target instead of relying on `kIsWeb` early-returns to gate broken code.
- Web thumbnails: new `WebThumbnailExtractor` uses an HTMLVideoElement + Canvas2D pipeline to grab a frame at the requested second and return PNG bytes. Picked at compile time via the conditional import in `thumbnail_extractor.dart`.
- Android: new `geogram/thumbnail` MethodChannel (handler in `MainActivity.kt` → `extractVideoFrameAsync`) calls `MediaMetadataRetriever.getFrameAtTime` on a worker thread, downscales to 480 px on the long edge, encodes PNG, and returns bytes. Cache size stays modest and the UI doesn't stutter.
- New helper `FileBrowserCacheService.getThumbnailBytes` returns cached bytes regardless of platform — needed for web (no real on-disk path) and used by `MediaThumbnailUtils` for HTTP-served gallery thumbnails.

## 2026-04-26 - v1.39.0-beta.14

### Fixes
- File browser thumbnails: opening a folder full of HD videos no longer crashes the app. The picker used to fire `VideoMetadataExtractor.generateThumbnail` synchronously per visible tile during `build`, spawning one `media_kit` Player instance for every video at once — N parallel video files getting opened into RAM is what OOM-killed geogram on phones. Generation is now funneled through a new `ThumbnailGeneratorService` singleton that processes one request at a time and yields between each so the UI thread stays responsive.
- File browser thumbnails: hard size cap before generation. Images > 50 MB and videos > 500 MB are skipped — the picker shows the generic file icon instead of trying to decode a 4 GB recording. Avoids the worst single-file OOMs (`Player.open` on a multi-GB file can't be made safe regardless of queue depth).

### Changes
- New `ThumbnailGeneratorService` registers itself with the Task Monitor (`Settings → Tasks` shows "Thumbnail Generator") via `MonitoredIsolateHandle`, reporting `running` while a thumbnail is in flight and `idle` between requests, with success / failure counters per file. Pause / resume from the monitor is supported because it's a non-critical background job.
- Picker thumbnail loading is now fire-and-forget — `_loadThumbnail` returns immediately and the `.then(...)` updates state when the result lands, instead of awaiting on the build path.

## 2026-04-26 - v1.39.0-beta.13

### Fixes
- Events browser: when the home-screen badge says an event needs attention, the user can now actually find it. Years that contain an event with unseen activity (pending access requests, new comments / likes, pending contributor uploads) are auto-expanded on entry, and the year header carries a small red dot when collapsed — previously only the most-recent year was expanded, so an attention item from a prior year was hidden behind a chevron with no indicator.
- Event tile badge: now refreshes live. The tile subscribes to `NowItemEvent` / `NowGroupRemoveEvent` for its own event id, so the dot appears the moment a new comment / like / contribution lands and disappears the moment the owner clears them — instead of staying stale until the page is reopened.
- Postcards browser: the right-pane detail panel no longer auto-grabs a third of the screen on entry — selection now requires an explicit marker tap. Markers stacking at high zoom is fixed by bumping cluster `maxZoom` to 18 and shrinking marker / cluster radii so coincident postcards always group into a single count bubble.
- Postcards map: arrows now draw for brand-new postcards with no carrier stamps yet — a synthetic "pickup" hop at the user's current GPS fix anchors the journey when the local user is the sender, so the faded arrows to each possible destination appear immediately.

### Changes
- Postcards map UX: tapping a marker shows a floating preview card (status pill, title, "From → To · N hops", Open / Close) instead of the old sidebar; wide and narrow layouts now share the same flow.
- Postcards map: camera glides between selections via a 600 ms `easeInOutCubic` animation instead of snapping. Cluster bubbles are heat-coloured (green → red, sized by `sqrt(count)`) so the courier sees pile-ups at a glance; counts above 999 render compact ("1.2k").
- Postcards courier helper: new "alt_route" FAB opens a draggable sheet — set "I am here" + "Going to" via the city picker, and the panel ranks every loaded postcard by straight-line distance to the destination and lets you tap straight onto the best candidate.
- Postcards seeding: a standalone "Inject samples" button now lives in the AppBar (no longer hidden behind a debug menu) and writes 2000 synthetic postcards across Portuguese cities for visual map testing, with progress logging.

## 2026-04-26 - v1.39.0-beta.12

### Changes
- Backup / Auto-backup task: the monitored periodic timer is now registered unconditionally on `LocalBackupService.initialize()`, so the "Auto Backup" entry shows up on the Task Monitor (Settings → Tasks) at all times — even when the toggle is off — and can be paused / resumed from there. The tick handler short-circuits silently when auto-backup is disabled or no folder is set, so an inactive task doesn't spam the monitor.
- Backup / Auto-backup catch-up: when the user enables auto-backup, or when the app boots with auto-backup already enabled, an immediate (30 s deferred) backup runs if `lastBackupAt` is older than the configured interval. Previously a 7-day interval meant the user had to wait a week to see the first backup happen, which read as "it never works".

## 2026-04-26 - v1.39.0-beta.11

### Fixes
- Backup / Local: the "Backup Now" UI now shows real progress instead of a never-ending indeterminate bar. `LocalBackupService` exposes a `ValueNotifier<LocalBackupStatus>` and routes every status mutation through it, so the page rebuilds as files are processed. The in-progress label switched from a single static line to "filesProcessed / filesTotal · NN%" plus the current filename underneath, matching what the service has been computing all along.
- Backup / Auto-backup: the periodic timer now actually runs. `LocalBackupService.initialize()` is called from `main.dart` next to `UpdateService().initialize()`, so the auto-backup timer starts at app boot rather than only when the user opens the Backup page. Previously the auto-backup setting could be toggled on, the user could close the app, and the timer would never start in any future session unless they navigated back to the Backup screen first.

## 2026-04-26 - v1.39.0-beta.10

### Fixes
- Self-updater: the install button on the Updates page now lights up immediately when an APK from a prior session is already on disk, instead of staying grey until a fresh GitHub round-trip succeeds. The disk scan ran only deep inside the page's background-update-check flow — so on poor / no network, after backgrounding the app, after process restart, etc., the user saw a downloaded APK but no way to install it. `UpdateService` now recovers the completed-download state from disk both on `init()` and at the end of every `checkForUpdates()`, and `UpdatePage._loadData` does the same scan up-front so the button is correct even before the network call returns.
- Self-updater: when `downloadUpdate` re-uses an already-complete partial-file (renames `.partial` → `.apk` without re-fetching), it now also fires `_setCompletedDownload` so the `completedDownloadPathNotifier` listeners (banner, install button) actually see the transition.

## 2026-04-25 - v1.39.0-beta.9

### Fixes
- Places: photos picked when creating or editing a place now actually land in the place's `images/` folder. The save path used raw `Directory(...)` against a relative path that the storage layer hands out — on Android the process CWD is `/`, so directory creation silently failed and every place ended up with zero photos despite the editor showing them as "added". Save (`_saveImages`), edit-time existing-image listing (`_loadExistingImages`), and detail-page photo loading (`_loadPhotos`) all now go through the new `PlaceService.copyPlacePhotos` / `PlaceService.listPlacePhotos` helpers, which use the same `ProfileStorage` abstraction `savePlace` already used to write `place.txt`. Encrypted profiles work for the same reason.

## 2026-04-25 - v1.39.0-beta.8

### Fixes
- Events: "Add photo" / "Add another photo" / "Select trailer video" no longer occasionally save a 240×180 thumbnail instead of the full-resolution image. The Android-only branch was using the native `image_picker` plugin, which on Motorola (and other OEMs that surface Google Photos cloud entries via the system picker) returns a path to a tiny cached thumbnail rather than the original. Both `_selectFlyer` and `_selectTrailer` now use the same `FileFolderPicker` the multi-select photo grid already uses on every platform — full files, encrypted-profile-aware, no thumbnail surprises. The unused `image_picker` import and the `_isMobile` getter went with it.

## 2026-04-25 - v1.39.0-beta.7

### Fixes
- Tracker / Paths: recorded tracks no longer pick up cell-tower / Wi-Fi triangulation as if it were GPS. Path recording now requests `LocationAccuracy.bestForNavigation` (pure GPS on Android, instead of fused location which silently falls back to cell), and any incoming fix coarser than 100 m is dropped before being persisted — so the recorded line stops zig-zagging across whole neighborhoods during cold-start or weak-signal periods.
- Tracker / Paths: the watchdog one-shot fallback also forces pure GPS and uses a 30 s timeout (was 10 s) so cold-start has time to lock satellites.
- App-wide user position (the dot on Maps, marketplace/devices distance sorting, default APRS beacon position, etc.): the always-on `UserLocationService` stream is now `LocationAccuracy.high` instead of `medium`, so the OS prefers real GPS rather than cell-tower triangulation. Battery is held in check by a 60 s Android `intervalDuration` and iOS `pauseLocationUpdatesAutomatically`, plus the unchanged 100 m `distanceFilter` throttle.

### Changes
- Tracker active-recording banner: while no fix has been accepted yet, shows "Acquiring GPS…" for the first 30 s and "Weak GPS signal (~Nm)" after that, instead of looking idle. Added en/pt/de strings.

## 2026-04-25 - v1.39.0-beta.6

### Fixes
- Events: editing an existing event to add new photos or videos no longer drops the files — the editor now copies pending media into the event folder after `updateEvent`, so the gallery picks them up on reload. Affected all three edit entry points (detail page, browser sidebar, tile menu) which previously called `updateEvent` and never persisted the new picks.
- Events gallery: video entries (mp4 / mov / mkv / webm / avi / wmv / flv) now render a play-button poster instead of a broken-image icon; tap opens the existing full-screen video player in `PhotoViewerPage`.

### Changes
- Refactor: pending-media file copies moved into `EventService.copyPendingMediaFiles` so the create flow and all edit flows share one path; the per-page `_copyPendingFiles` / `_ensureUniqueFileName` helpers in `events_browser_page.dart` are gone, and the new helper writes through `ProfileStorage` so encrypted profiles work.

## 2026-04-24 - v1.39.0-beta.5

### Changes
- DM chat: prewarm the WebRTC connection when the page opens so the first message no longer waits ~15 s for a fresh handshake
- Devices list: keep offline peers visible when we have chat history with them so the DM entry point stays reachable for recap
- Web app: custom homepage switch + "It works!" starter as default
- Web app preview: load via local HTTP server
- Web app: split toggle from "Reset to It works!" action
- launch-android.sh: cap gradle workers and nice the build so the desktop stays usable

## 2026-04-23 - v1.39.0-beta.4

### Fixes
- DATA LOSS: device cleanup no longer wipes the local profile folder when a discovered peer happens to share the local callsign (e.g. the same NOSTR identity running on two devices)

### Changes
- Update check: compare prerelease suffixes so beta.N → beta.N+1 updates
- Sync comparison: one auth + one manifest for the whole session
- Sync comparison: parallelize folders, pre-hash cache misses, dedup manifests
- Sync comparison: clarify labels using local/remote
- Sync comparison panel: folder-based tree navigation

## 2026-04-22 - v1.39.0-beta.1

### Changes
- Blog tile: replace inline pin icon with three-dot overflow menu
- Blog detail API: expose likers / pointers / dislikers / subscribers as npub lists
- Followed authors: read cached posts back so they survive offline
- Blog: pin + follow controls on every post tile, plus author cache
- Blog browser: same mine/global scope toggle as the events browser
- Events browser: persist the mine/global scope choice across sessions
- Encrypted-profile compliance: route this-week's event scanners through ProfileStorage
- RemoteEventCache: route all I/O through ProfileStorage
- SECURITY: scope per-callsign event listing to that callsign only
- External events cache: also persist likes + comments
- External events: disk cache so re-opens are fast (and offline-friendly)
- Events: pin / unpin any event (local or remote) and float to top
- Events browser: aggregate global events from every reachable device
- Events browser: wire the scope toggle + tailored empty state
- Events browser: scope-toggle icon next to the search field
- Now panel + Devices list: tappable text + dedupe duplicate entries
- Events: author opt-in toggle for visitor contributions (default off)
- Events list: include pending contributions in the per-event badge
- Public event page: client-side menu-href rewriter for relayed URLs
- Forward relay prefix to device so menu hrefs survive the proxy hop
- Contributors: thumbnail strip, not full-size carousel
- Events: filter author from contributors + swipe carousel per contributor
- Events: render approved contributors on the public page + author detail
- Remote events: show "Your submissions" panel on the Flutter detail page
- Remote events: stack the Contribute panel vertically
- Public uploader: cache thumbnails of server-known submissions in IDB
- Public uploader: ask the device for "my submissions" on every load
- Public uploader: keep submissions visible until they're approved
- Public uploader: refresh status banner as items actually land
- Forward X-* headers through the device proxy
- Public event uploads: persistent IndexedDB queue + retry-with-backoff
- Carry binary uploads through the station→device proxy chain
- Events: visitor contributor UI + author approval + public display
- Events: visitor contributor submissions (server side + approval gate)
- Event gallery: prefetch neighbouring photos so the lightbox feels instant
- Events: photos are photos; only the chosen cover is the flyer
- Thumbnail reliability: offload resize to isolates + in-flight dedup + retry
- Gallery thumbnails on /api/content + station event files + lightbox
- Generic /api/content/{appType} — one browse surface for every app
- Speed up app comparison and fix sync wording
- Fix lazy hash diff tracking in mirror sync
- Speed up mirror diffing and surface sync failures
- Preserve recovered profiles on reinstall


## 2026-04-21 - v1.38.1

### Changes
- Android: bump shared_storage's pinned compileSdkVersion 30 to 35
- release.sh: probe ~/flutter/bin/dart so version.dart actually syncs


## 2026-04-21 - v1.38.0

### Changes
- Restore Linux tray_manager registrant + ignore .claude/
- BlogService: use paths relative to the storage scope
- Remote blog actions: fix comment signature verification + debug-API test harness
- Remote blog detail: working like/comment + views/likes/comments on the page
- Station blog: wire POST like/comment/dislike/point/subscribe/react + DELETE comment
- Station: serve /api/blog via the shared BlogHandler
- Station: serve /api/apps via the shared AppsHandler
- Android build: compatibility shims for AGP 8 / Kotlin 2
- Device-detail tiles: fix counts via a reusable AppContentProvider
- Backup: route Local Backup writes through SAF on Android
- EventActivityNotifier: clear in-memory NowItems when marking seen
- Events: split off "Interactions" tab and i18n every recent string
- NowPage: tapping an event activity card actually opens the editor
- Events: unified EventActivityNotifier for owner attention items
- Events: let the author (or comment author) delete a comment
- Events: NOSTR-signed comments on the public event page
- Station homepage: events list shows author + likes/comments/views
- Events: approved-request fallback so cookie-only viewers get access
- Events: per-viewer access lookup + station-homepage probe
- Station: publish events on visibility change + Recent Events section
- Events: capture requester profile nickname + auto-add a Contact
- Events: scan pending access requests at app startup
- Apps grid: badge the Events tile when an event needs owner action
- Events: guide owner from event-tile badge to the pending-requests list
- Events: pending-request badge on tile + re-emit Now items on load
- Now panel: tap an access-request card opens the event's Access tab
- Events: request-access prompt + note + Now-panel notification
- Events: themed 404, contact-picker access list, request-access inbox
- Events: extend visibility with unlisted + request_access + grants
- Events: surface engagement stats at the top + add a comment counter
- Events: engagement row reads the live like count from feedback file
- Events: web Like writes the canonical feedback/ path so the GUI sees it
- Events API: URL-decode event id segments so likes/lookups match
- Events: show view count in the desktop/Android event detail page
- LogApiService: route /api/feedback/{type}/{id}/[action] like the stations
- Events: NOSTR-signed page-view counter on the public detail page
- Events: serve cached thumbnails for the public gallery
- Events: include callsign in shareable URL and fix file paths on station
- Events: hide station URL on private/group events
- Events: open photo picker in grid view at the user's media folder
- Events: accept video clips alongside photos in the media gallery
- Regenerate themes_embedded.dart so blog/styles.css gets the timeline CSS
- release.sh: regenerate lib/version.dart, skip F-Droid summary on pre-release


## 2026-04-19 - v1.38.0-beta.2

### Changes
- Desktop: move USB AOA read loop off the UI thread; scan only the gateway-routed subnet
- Station homepage: surface blog likes and refresh cache hourly
- Devices: route mirrors through the existing LAN-direct path
- Devices: relabel station-relayed peers as "relay" instead of internet
- Devices: label station-relayed mirrors as internet, not station
- Sync/Devices: compose mirror display name as "nickname (callsign, device)"
- Devices: include station-relayed mirrors in the device list
- Devices: show same-callsign LAN/DHT peers in the device list
- Station: shared SSL, recent blog posts on homepage, install fixes
- iwi: wapp categorization, functionality API, NDF store with social features
- iwi: Flutter web port + Android build + App Creator Save button
- iwi: wapp i18n phase 1 + Translations editor in App Creator
- iwi: wapp store overhaul, NOSTR signing, WYSIWYG UI editor
- Add expense category breakdown with pie chart and ranked list
- iwi: profile support + SVG icons + wapp-signing plan
- App Creator: preserve C source + navigation split
- App Creator: Projects tab + title/name split + built-in editing
- Add App Creator wapp — in-app C authoring, compile + install
- Add geogram widget provider registry
- Add geogram architectural foundation + tasks/tester wapps
- Add per-entry currency selector and Material/People categories
- Fix accounting entries overwriting each other due to ID collision
- Fix self-updater not offering stable releases to beta users
- Add accounting NDF document type for personal finance tracking
- Add performance task pause controls
- Reduce background chat and P2P CPU load
- Restore non-blocking chat room discovery
- Run dchat discovery as a monitored background task
- Stop dchat loading from blocking chat startup
- Wire distributed chat rooms into the chat UI
- Add epoch key rotation to distributed chat
- Migrate distributed chat service to SQLite room storage
- Add dchat SQLite room storage library
- Add distributed chat room foundation
- Fix sync exclude snackbar dismissal
- Stream shared folder file downloads instead of loading into RAM
- Fix shared folder subdirectories appearing empty via web browser
- Fix shared folder URL missing callsign, add buildStationAppUrl utility
- Fix duplicate messages in web chat after sending
- Live chat updates for station device via ChatMessageEvent
- Fix installer: use folder names as labels, confirm installs from renderer, fix Settings tab
- Rename Shop to Archive, add Uninstall button for installed wapps
- Install wapp: extract ZIPs, show installed apps on launcher
- Shop: render catalog as Material cards instead of raw text
- Fix deleteMessage async signature in all implementors
- Fix pure_station deleteMessage to use ChatMessageStore
- Disk-based chat messages via shared ChatMessageStore
- Merge GPS locate and auto-follow into single map button
- Clean up test logging after verifying install wapp works
- Fix WASM engine: skip unused imports that wasm_run rejects
- Fix KV persistence: remove try/catch swallowing errors, auto-detect source
- WappPage: separate output-only screen from terminal, fix error handling
- Install wapp: toast on save, auto-fetch catalog, proper screen detection
- Install wapp: persistent KV, renderer-side index loading, launcher cleanup
- Track built .wapp binaries in repo for web distribution
- Add install wapp: browse, install, and update wapps from a repository
- build-archive: organize binaries into per-wapp subdirectories
- Use shared debug keystore from secret for CI debug APK builds
- build-archive: use folder names and add versioned filenames + index
- Add build-archive.sh: compile and package all archive wapps
- Add debug channel for silent self-update on unattended stations
- Add delete option for local chat channels
- CLI: make search command discoverable in help at all levels
- Maps: add location search across all renderers (Nominatim geocoding)
- Flutter: generic WappPage renders any wapp from .ui.json screens
- Add maps wapp: satellite imagery with slippy map and tile cache
- Add web launcher: HTML/JS wapp runner with .wapp ZIP loading
- Settings: add button to open data directory in file explorer
- Launcher: add Settings page with wapp data directory config
- CLI: add Tab auto-completion and command history
- CLI: blank line after screen description before first section
- CLI: one blank line between sections in screen listing
- CLI: compact screen listing — single line per section
- CLI: add GeoUI screen navigation; fix ls/mkdir/stat in terminal wapp
- Add wapp CLI: interactive terminal for WASM modules via libwasm_bridge
- GeoUI renderer: native Material 3 look for settings UI
- Launcher: auto-discover wapps from archive, fix icon centering
- Convert GeoUI from custom .ui format to JSON (.ui.json)
- Build terminal wapp directly as app.wasm
- Remove duplicate terminal.wasm, keep only app.wasm
- Add terminal wapp: WASM module + GeoUI screens + manifest
- Iwi: GeoUI parser, renderer, and .ui-driven terminal settings
- Iwi: self-contained terminal, settings, and preferences
- Iwi: add terminal app and launcher home screen
- Iwi: add wasm_run_flutter engine with Geogram HAL host functions
- Iwi: use hamburger menu icon, fix SDK constraint
- Update KV4P firmware binary and themes_embedded.dart
- Captive portal: GET send endpoint + multi-fallback + CORS preflight
- Fix captive portal send: remove fetch interceptor, use relative URLs
- Fix captive portal sends: absolute URLs, Connection:close, error visibility
- Fix captive portal: resilient boot sequence, catch generateKeys failure
- Captive portal: serve chat page directly with cookie/server-session fallback
- Fix chat blocked by background apps exhausting HTTP sockets
- T-Dongle: remove WiFi AP password, use open network
- Fix captive portal: serve landing page on probes, 302 only on 404
- Revert captive portal to 302 redirect so chat JS works on Android
- Captive portal: show landing page with browser link instead of auto-redirect
- Fix chat API blocked by captive portal probes hogging sockets
- Fix captive portal: serve chat page directly instead of 302 redirect
- Extract chat page to standalone file, enable on T-Dongle S3
- Fix T-Dongle WiFi AP crash: password must be >= 8 chars
- Add WiFi AP, captive portal, and mesh support to T-Dongle S3
- Replace 'x' prefix with Bluetooth symbol for device count on display
- Fix BLE device count: scan while connected, suppress spurious adv warning
- Fix BLE discovery: advertise FFE0 service UUID for Flutter scan filter
- Fix BLE visibility: time-share advertising and scanning
- Fix BLE HELLO: only restart advertising on failed connect or disconnect
- Add BLE HELLO protocol to T-Dongle S3: advertise, scan, GATT handshake
- Fix LVGL tick: call lv_tick_inc() manually since lv_conf.h is not seen
- Fix T-Dongle uptime counter: drive LVGL from main loop like old code
- Strip T-Dongle S3 to display-only, fix LVGL task hang
- Fix T-Dongle S3 display: correct ST7735 offsets, rounded bars, BLE crash
- Add ST7735 LCD display and LVGL chat UI to T-Dongle S3
- Restore p2p.radio as default station — removing it broke station updates for all clients
- Fix profile pic loading to use ProfileStorage for encrypted support
- Show profile pictures for DM channels in chat list
- Unify update polling: both stations use UpdateMirrorUtils.fetchReleases
- Fix chat channel sorting and DM nickname display
- Skip beta binary download on Android (metadata only, link to GitHub)
- Add beta release track via shared UpdateMirrorUtils
- Fix DM list showing contacts with no messages
- Re-enable update mirror polling on Android
- Station UI cleanup: remove FAB, simplify actions, log storage slider
- Show DM conversations in Chat app under This Device
- New channel: full-screen page, default Group, storage type option
- Fix chat rooms empty: remove general→main alias in ChatService
- Auto-detect daily file storage for chat channels
- Add dailyFiles setting to chat channels, fix message loading
- Unify chat: station rooms stored in channels.json (shared with ChatService)
- Fix chat room admin: use profile identity, add mobile room management
- Fix chat admin: grant moderator to operator npub
- Fire NowItemEvent for station chat messages locally
- Auto-set station owner as chat admin on startup
- Add station metrics: daily preview card + full metrics page
- Skip self-connection when device is the station
- Android station: HTTPS, Let's Encrypt, OOM fixes, p2p.radio removal
- Fix devices list for same-account devices
- Document current connection mechanism
- Fix DM timestamp display and dedupe device rows
- Fix asymmetric cross-network DM routing
- Add USB access security setting
- Tighten peer relay DM routing
- Fix cross-network DM routing and discovery leaks
- Fix DM chat app bar overflow on Android
- Replace devices browser ListTile with custom layout
- Fix USB AOA host handshake timing
- Reduce Android USB ANR and crash log pressure
- Fix peer relay fallback for public DHT peers
- Add peer relay fallback and public DHT HTTP announces
- Update BT-DHT bridge status for NAT transport findings
- Improve DHT rendezvous probing and diagnostics
- Refresh DHT peer probes and candidate selection
- Improve DHT peer probing and filtering
- Use DHT rendezvous for peer signaling
- Add iwi standalone Flutter project
- Remove 50-candidate cap from iterative lookups
- Use full getPeers for npub probe on all platforms
- DhtTransport: UDP fallback when HTTP fails through NAT
- Switch DHT queries to parallel Future.wait to unblock UI
- Restore full DHT convergence: 10 rounds, no early exit
- Use implied_port=1 for correct NAT-mapped peer addresses
- Announce BEP 42 external port, not local port
- Use full announce() for geogram topic on all platforms
- Add fresh getPeers scans at startup+30s+periodic refresh
- Announce DHT port on geogram topic, not HTTP port
- Fix double main(): detect secondary engine via BLE channel check
- Fix double main(): defer plugin registration to Activity context
- Wire P2P libraries end-to-end into geogram app
- Add full P2P connection test with two geogram instances
- Expand DHT test to full P2P connection flow (26 tests)
- Fix double main(): defer plugin registration to Activity context
- Add geogram DHT messaging for NATted peer connectivity
- Fix build: remove leftover _startPunchSocket call and unused fields
- Add hole punching on separate UDP socket (not DHT socket)
- Revert DHT changes to working 460MB state
- Only forward JSON packets to punch handler, drop random BT traffic
- Rate-limit incoming DHT queries to 10/sec
- Fix double main() from AudioServicePlugin background engine
- Wire up UDP hole punching for DHT-discovered peers
- Fix double FlutterEngine causing 2x memory on Android
- Fix double main() execution causing 2x memory on Android
- Support multiple devices per callsign in Devices UI
- Use lightweight DHT on Android: no iterative lookups
- Restore early exit with 3-round minimum for convergence + memory
- Limit DHT lookups to prevent cumulative Dart heap growth
- Fix cross-network device discovery: iterative npub lookup
- Fix DHT lookup convergence broken by memory leak fix
- Fix 3.4GB memory leak: sequential DHT queries instead of Future.wait
- TEMP: Disable DHT on Android to isolate memory leak
- Reduce DHT memory: 5 rounds max, 50 candidates cap, clear tokens
- Rate-limit error handler to break OOM death spiral
- Limit crash log to 50 reports, reduce appended logs to 10
- Fix LAN scan flooding and blocking HTTP connections
- Reduce HTTP probe timeouts from 5-10s to 2-3s
- Fix power transition OOM and media_kit false crash restart
- Fix permanent UI freeze: npub probes were doing full iterative lookups
- Move DHT back to Isolate.spawn — UI stays responsive
- Wire DHT devices into ConnectionManager for full connectivity
- Move DHT back to Isolate.spawn — UI stays responsive
- Show AT Proto as inactive in Teleport when disabled
- Stop AT Proto timers immediately when disabled via switch
- Fix AT Proto: don't start 6 timers when disabled, add enable switch
- Performance tab first, continuous tasks above startup
- Clarify Performance tab: one-time startup vs continuous tasks
- Add Performance tab to Task Monitor page
- Instrument all startup services with CPU + memory profiling
- Disable auto-transcription and file indexing at startup
- Add complete background services inventory
- Update BT-DHT docs with test results and iterative lookup details
- Add standalone DHT discovery test — two nodes find each other
- Revert "Disable DHT on Android — OOM from iterative lookups"
- Disable DHT on Android — OOM from iterative lookups
- Use fireGetPeers for npub cache — no iterative lookup on Android
- Preserve DHT internet tag — don't let station checks override it
- Staggered npub lookups: one per 15s via Timer, full iterative
- Non-blocking npub cache: fireGetPeers sends UDP without awaiting
- Keep DHT-discovered devices online (green) in Devices UI
- Limit DHT npub probe to 5 devices, check cache first
- Probe known devices via DHT npub lookup for internet tag
- Don't exit iterative lookup early when no new candidates
- Fix Android OOM: only fetch station clients when connected
- Run DHT on main isolate — Isolate.spawn causes OOM on Android
- Revert Isolate.run for HTTP probes — causes Android freeze
- Fix iterative DHT lookup — proper BEP 5 convergence
- Update BT-DHT docs with implementation findings and known issues
- Targeted routing table refresh near SHA1(geogram) hash
- Fix: process nodes from ALL DHT responses, not just get_peers
- Refresh routing table every 2 min instead of 15
- Fix same-household discovery: don't filter by public IP
- Run device/station HTTP probes in background isolates
- Run DHT in a background isolate — never blocks main thread
- Use same 2s DHT start delay on all platforms
- Delay DHT start 30s on Android to avoid startup OOM
- Fix OOM: light periodic scan using cached peers only
- Fully non-blocking DHT: fire queries, collect from store
- Split DHT phases into separate Timer callbacks
- Fire-and-wait DHT queries: send 3, wait 2s for responses
- Sequential DHT queries: 1 node per round, 3 rounds max
- Lightweight bootstrap: 1 round + 500ms inter-round delays
- Remove aggressive growth timer that caused Android hangs
- Add aggressive routing table growth 30s after bootstrap
- Increase DHT iterative lookup rounds back to 5
- Show DHT peers in Devices UI with proper identity via HELLO probe
- Add more bootstrap nodes and retry on mobile networks
- Show DHT peers in Devices UI immediately, probe identity later
- Fix Android hanging: defer all DHT heavy work via Timer
- Fix Android ANR: use real delays instead of Duration.zero yields
- Wire DHT-discovered peers into Devices UI panel
- Learn public IP from BEP 42 DHT responses, remove STUN dependency
- Use MonitoredIsolateHandle for P2P task tracking
- Fix STUN: every peer is a reflector on its API port
- Fix Android ANR and improve DHT bootstrap resilience
- Move P2P Discovery section to Connections page
- Add BT DHT bridge documentation
- Separate DHT peer discovery from mirror system
- Fix DHT announce port and add dht_add_node debug action
- Remove external STUN servers, use only Geogram peers as reflectors
- Fix DHT bootstrap IPv6 and STUN NAT detection
- Add DHT debug API endpoints for testing P2P discovery
- Add P2P discovery via BitTorrent Mainline DHT
- Add timeline CSS to blog styles
- Regenerate embedded themes with shared directory styles fix
- Fix shared folder directory listing missing styles
- Strike through description for completed TODO items in PDF export
- Include pictures in TODO PDF export
- Add Export as PDF option to TODO NDF three-dot menu
- Fix shared folder breadcrumbs and nav links at depth > 1
- Fix shared folder subfolder navigation and show URLs in listing
- Add restart button on solved quiz story thumbnails
- Clean up debug logging from blur thumbnail feature
- Fix blurred thumbnail: use blur asset presence as quiz indicator
- Show blurred thumbnail for unsolved quiz stories in gallery
- Reload stories list after closing viewer to reflect thumbnail changes
- Add ESC to exit story viewer, blur/unblur thumbnail on quiz reset/solve
- Add restart button to Story Viewer
- Fix quiz not working in Flutter Story Viewer
- Server-side secure interactive quiz for Story web viewer
- Add section header and top padding to This Device section in Mirror Config
- Move local device config above mirror devices list in Mirror Config page
- Client-driven device priority via HELLO protocol
- Revert accent color to original and fix brown UI elements
- Serve NDF assets via HTTP instead of base64 encoding
- Cache pre-rendered HTML inside NDF archives for faster web viewing
- Fix share URL and unlisted key access for NDF documents
- Extract sync transfer into background SyncTransferService
- Move mirror config entry from profile settings to Device Sync menu
- Show selected/total file count in select-all label
- Fix folder-level checkboxes losing taps to adjacent InkWell
- Cap station updates directory at 5GB by pruning old versions
- Fix non-responsive checkboxes in mirror sync diff view
- Prefer device name over profile nickname in LAN discovery
- Expose device nickname in discovery and fix STT double-load OOM
- Use peer nickname in mirror device display name
- Fix exclude rules not filtering folder-scoped patterns in diff
- Add 'Exclude from sync' option to file items in diff view
- Add select/deselect all checkbox to mirror sync diff view
- Remove mirror_enabled filter from LAN discovery
- Add LAN-based mirror sync discovery
- Update version.dart to 1.36.0+12
- Fix presentation filling entire screen on navigation
- Fix presentation auto-fullscreening on navigation click
- Only show Whisper models when previously downloaded by station
- Keep only Whisper Tiny and Base, link to HuggingFace
- Remove Vision AI models from download page, always show Whisper
- Italicize blog post description in timeline
- Match blog timeline CSS exactly to events page
- Fix blog index year type cast error
- Add work file explorer: browse workspaces and documents via HTTP
- Redesign blog index with year-grouped timeline layout
- Remove divider above like button in story sidebar
- Add likes/comments sidebar to story viewer
- Shift bottom-positioned story elements up by their own height
- Shrink story viewer viewport and remove footer
- Fix stories gallery Nostr login flickering
- Remove text outside story viewer, use site theme container
- Redesign presentation web viewer as immersive story
- Fix story viewer: CSS order, viewport size, and navigation links
- Fix stories route: add portal pass-through for /stories/ paths
- Add Story web viewer: gallery browsing and individual story pages via HTTP
- Remove brown accent-alpha-20 backgrounds, use borders and orange accent
- Add vertical text alignment to presentation editor
- Fix TODO viewer: add post styles, lightbox, use theme colors throughout
- Add visibility/interaction settings to TODO editor, wire up HTTP serving
- Fix presentation editor inline text editing not readable
- Add HTML web viewer for TODO NDF documents
- Update auto-generated themes_embedded.dart
- Fix backup test data creation to use profile-scoped directory
- Fix backup service: snapshot ID regex mismatch and basePath scoping
- Move excluded files menu to Device Sync page
- Use hamburger menu icon for Mirror settings menu
- Add debug API for sync exclude rules and pass rules to diff test
- Add sync exclude rules: skip files by pattern during mirror sync
- Fix Bluesky enabled by default in Teleport: require explicit opt-in
- Fix presentation feedback spacing and fullscreen arrow keys
- Increase spacing before likes/comments in presentation viewer
- Cache www index.html and only regenerate when content changes
- Polish presentation viewer: remove folder name, fix spacing, click-to-fullscreen
- Document beta/stable update channels in AGENTS.md and API docs
- Add beta/stable update channels with opt-in toggle
- Add fullscreen button to presentation viewer
- Register all background work with TaskMonitorService, fix 600% CPU
- Redesign karma app: magenta theme, merge Stats+Leaderboard into Ranking tab
- Improve event and blog web pages with maps, URLs, and unified navigation
- Replace emoji icons with monochrome SVG icons on event detail page
- Redesign events listing as vertical timeline with year separators
- Remove likes/comments from stats bar, keep only registration counts
- Fix like button URL, remove back button, add events to nav bar
- Fix event detail page layout and theme consistency
- Fix event detail page: full data load, like API, and always-visible like button
- Full event detail page with gallery, likes, links, updates, comments
- Make event URL slug independent of folder name
- Add events web pages (listing + detail) with custom URL slug support
- Add audio progress slider, seek, and equalizer animation to voice memos
- Presentation themes/decorations, voice memo audio playback, proper feedback
- Add presentation and voice memo NDF web viewers
- Add NDF document (rich text) web viewer with shared page shell
- NDF document web viewer with visibility, likes, and comments
- BlueAPRS: APRS over BLE advertisements between ESP32 devices
- Merge chat and APRS into unified view with dual-send and callsign list
- Restore full Wartext landing page to KV4P captive portal
- Add multi-device push mode to Device Sync page
- Stop mirror device list from flickering in Device Sync UI
- Fix folder sync comparison when folder missing on remote device
- Fix synced folders not recognized as installed apps
- Unify device identity across mirrors, event upload API, expanded sync folders
- Improve background transcription: queue progress tracking, skip ffprobe when duration known, cleanup temp files
- Add meeting visibility (public/private/restricted/unlisted) and background auto-transcription
- Show last sync time for each mirror device in Device Sync panel
- Nudge sync badge up 5px
- Move sync badge to lower-right corner
- Fix sync badge offset, instant config display, persist peers across restarts
- Style sync badge: grey background, offset to upper-right
- Add missing device_sync i18n translation key
- Clean up Device Sync settings UI
- Document serialized callback pattern in reusable.md
- Add profile_switch debug API endpoint for testing
- Fix mirror stability: FD leak, circular import, post-switch mirror loss
- Show per-install UUID prefix in sibling device names
- Fix sync page checkboxes, add push/pull direction filter
- Fix NAT dedup loop & device sync comparison for multi-device support
- Auto-focus search field on app creation page, add place types, swipeable event flyers
- Optimize events list loading — progressive streaming, parallel I/O, lazy rendering
- Station as pure proxy — collapse 4 device-routing checks into 1
- Auto-transition meeting HTML page between active and archive states
- Fix meeting chat messages showing as unverified — full NOSTR signing and verification
- Add meeting archive thumbnails, chat parity, recording reactions, view counters, and fix chat identity spoofing
- Add Wapps module system: WASM runtime, HAL, Dart FFI, and example modules
- Add APRS store improvements, radio commands, test scripts, and API docs
- Revert KV4P from mesh mode to standalone WiFi for LAN discoverability
- Fix APRS AFSK tone frequencies: use float phase for exact 1200/2200 Hz
- Fix KV4P APRS TX: switch from PDM to I2S DAC mode for correct AFSK tones
- Fix KV4P APRS RX demodulator and add HTTP API endpoints
- Add VM launcher GUI and packaging for distribution
- Add NDF meeting archives, audio-only recording, background transcription, and ffprobe duration fix
- Add Meeting transcription, NDF document type, and archive export
- Add Meetings moderation, file picker filtering, managed HTTP client, and video player improvements
- Add Meetings archive tags, auto-recording, history tabs, and fix FD leak
- Improve Meetings web page: dates, errors, nicknames, and description style
- Fix Meetings chat/screen relay, lowercase codes, and add description field
- Add Meetings scheduling, archive pages, and fix CLI build
- Fix Meetings browser hosting and station routes
- Add Meetings history, recording, and station web access
- Extend Meetings archive and recording regression tests
- Add Meetings archive history
- Add pinch zoom to meeting screen-share viewer
- Restore meeting screen-share preview path
- Simplify meeting screen-share fullscreen viewer
- Add fullscreen meeting screen-share viewer
- Reduce Linux screen-share prompts
- Fix CLI build: remove Flutter dependency chain from pure_console
- Improve meeting screen-share recovery
- Fix meeting screen-share visibility and startup
- Fix PlaceCreatedEvent not firing on station place upload
- Fix meeting screen-share stability and Android join
- Fix Linux meeting teardown cleanup
- Fix meeting screen-share overflow
- Add meeting screen sharing
- Improve meeting audio flow and regression coverage
- Move chat_reaction karma from Send Messages to Engage Socially mission
- Add meeting conference regression coverage
- Change karma blog mission text to "Write a blog post"
- Add station activity regression tests
- Add station activity feed service
- Filter automated APRS geo chat repeats
- Trim stale Claude bootstrap guidance
- Consolidate repo agent guidance
- Rename karma levels to prepper/offgrid/cyberpunk theme
- Fix Karma rank badge using KarmaStore instead of direct file access
- Fix leaderboard rank badge to read from loaded leaderboard data
- Show leaderboard position in Karma summary bar
- Rebalance Karma points so daily maximum is 100 points
- Fix Karma summary showing 0 points and add max points display
- Add expandable descriptions to Karma mission cards
- Fix Karma badge using stale data and unify mission logic in KarmaEngine
- Fix APRS geo chat notification navigating to wrong destination
- Fix Karma badge to count only unstarted missions instead of incomplete ones
- Fix TODO editor showing unsaved changes dialog after saving
- Fix Windows path bug in device names and unify cache services via CacheServiceBase
- Fix event pictures not showing in thumbnails and edit mode
- Add welcome_finalize debug API endpoint for first-launch testing
- Fix first-install callsign bug: orphaned random callsign folder
- Add PowerAwareService for Android battery drain reduction
- Fix karma UI: read directly from local KarmaStore instead of HTTP API
- Open TODO images in full-screen PhotoViewerPage on tap
- Add tests README documenting E2E test runner and conventions
- Add test runner and organize karma tests into suite folder
- Background manga downloads via coordinator + TransferService integration
- Fix karma not recording on desktop: lazy-init dataDir from StorageConfig
- Fix karma UI not updating: add KarmaUpdatedEvent to EventBus
- Fix empty chapters, add series info, and responsive grid
- Record all karma actions locally for social, alert, and reaction events
- Bump MangaPill extension to v1.3.1 to sync renamed browse tab
- Redesign manga Browse Online page with catalog grid and global search
- Separate map viewport from pinned user location
- Restore geochat on Now panel with content-based dedup
- Remove geochat from Now panel — keep it in Geo Chat tab only
- Add manga online browsing, library downloads, and extension auto-sync
- Record karma locally when sending chat messages to any destination
- Fix search bar skipping Nominatim for address queries with house numbers
- Fix karma API auth: generate NOSTR headers for profile requests
- Remove station flagging, rely on existing beacon/dedup filters
- Replace direction popup menus with direct car/walk buttons
- Filter automated stations from APRS Now panel, keep geochat
- Filter Now panel to only show APRS messages addressed to user
- Persist route across tab changes with floating control bar
- Fix manga reader zoom and bundle default extensions
- Auto-fetch road data when routing, fix map UX bugs
- Document manga extension system in reusable.md
- Add manga download extensions system
- Document road data API and map_search debug action
- Add map_search debug API and fix build issues
- Fix manga series count for local folder sources
- Add map search bar and fix road handler for CLI station
- Add ESC key to exit manga reader on desktop
- Allow zooming out below 1x in manga reader (min 25%)
- Fix Karma page: full words, working navigation, mission badge counter
- Add per-series manga_meta.json for read tracking and metadata
- Filter temp files from folder browser and add zoom to manga reader
- Open manga reader in full-screen mode on desktop
- Redesign Karma page with 3-tab daily missions layout
- Set webtoon as default manga reading mode
- Add local folder browser for manga CBZ files
- Add offline navigation (car/walking) to Map UI panel
- Add clear all notifications button to Now panel AppBar
- Add configurable log level to Meshtastic integration
- Add Meshtastic Teleport integration (LoRa mesh networking)
- Add BitChat Teleport integration (BLE mesh P2P messaging)
- Sort local devices (BLE/LAN) above Internet-only in device list
- Fix rate limiting: exempt tiles, root page, and public endpoints
- Add KarmaMixin to PureStationServer (CLI station)
- Add separate karma.json language files for all languages
- Add karma i18n strings for pt_PT and de_DE
- Fix karma app visibility and add to station server service
- Add karma points gamification system
- Fix hotspot binary downloads and chat API issues
- Fix SSL auto-renewal: implement certificate expiry parsing
- Fix geochat FAB overlap and auto-obtain position on APRS enable
- Release v1.30.2
- Move APRS Map tab to first position and add geochat comment dedup
- Add multi-device support and cryptographic callsign verification
- Fix APRS geochat reply from Now panel sending directed message instead of position report
- Fix priority dropdown: default to 5 instead of ambiguous 'Default' label
- Add priority override, pin to top, and clear messages to Now card menu
- Show user's own reply in Now feed for visual confirmation
- Add D-Bus notification backend for reliable Linux click handling
- Fix ESP32 heltec_v2 build: guard KV4P-only wifi_bsp call, clean up notification bridge
- Fix ESP32 and Windows CI build failures
- Sort teleport integrations dynamically: active first, available second, coming soon last
- Mirror Now activity feed to Android notification tray via NowNotificationBridge
- Add inline reply from Now activity feed cards
- Add blog, events, and places to Now activity feed
- Fix station chat Now feed: show real sender/content and proper navigation
- Add Telegram messages to Now activity feed
- Add APRS messages and geo-chat to Now activity feed
- Deduplicate repeated IRC messages within last 5 in a channel
- Truncate card messages at 60 chars and make text selectable
- Fix Leave Channel not working — clean up local state immediately
- Add Now activity feed specification document
- Add NowGroupRemoveEvent for de-registering sources and fix card word wrap
- Auto-mark Now items as read while feed tab is open
- Reduce minimum card width to 170px for two-column phone portrait layout
- Use responsive multi-column masonry layout for Now feed cards
- Redesign Now feed as card-based layout with chronological messages
- Add IRC chatroom notifications to Now feed with click-to-open navigation
- Add two-level grouping, per-group limits & expiry to Now feed
- Add disappearing messages for 1:1 DMs with reusable retention service
- Add "Now" activity feed panel — EventBus-driven activity aggregation
- Reject all unsigned chat messages — require NOSTR signatures on all 5 endpoints
- Fix remote chat room messages attributed to device owner instead of actual sender
- Fix IRC channel browser: clicking a channel now joins without navigating away
- Fix Android USB crash on device app discovery
- Fast device app discovery: single /api/apps endpoint, parallel fallback, reduced LAN timeout
- Auto-connect Nostr extension + use nickname as page display name
- Unify Nostr login on blog post pages with the rest of the site
- Replace emoji icons with SVG icons matching geogram.radio/#downloads
- Mirror all platform binaries (Android, Linux, Windows) on update check
- Fix download page: scan disk for binaries, add nav link, fix key format
- Add download page to portal for serving update binaries
- Portal serves device's own web page with full CSS and Nostr login
- Reuse station server homepage for portal — eliminate duplicated HTML
- Reuse WebNavigation and delegate to station server for portal pages
- Fix captive portal: DNS header, always-on web portal, path leak
- Fix captive portal crash by merging into existing HTTP server
- Add hotspot settings page with captive portal
- Add local ZIP backup with time-machine restore
- Fix BLE scan showing fake devices with broken names
- Add mirror auto-sync timer and station relay fallback
- Update ESP32 CI to build all 7 firmware environments
- Fix IRC CAP negotiation stalling connections on most servers
- Add BlueAPRS settings UI and position beacon support
- Fix Teleport bridge availability: use runtime FFI check for Telegram/Signal
- Add comprehensive APRS bridge documentation
- Add BlueAPRS — APRS over Bluetooth Low Energy bridge
- Fix Teleport: stop Bluesky auto-enable, show Telegram/Signal as Available, fix Android FFI loading
- Prune IRC system messages (join/part/quit) older than 12 hours
- Make entire Teleport app translatable (en_US, pt_PT, de_DE)
- Fix permanently remove devices from device panel (#32)
- Add MeshCore Teleport service for LoRa mesh messaging via BLE
- Replace TODO add/edit task dialogs with full-screen pages + voice input
- upload.sh: ask target once, reuse for build and flash
- Rewrite upload.sh to build+flash, fix APRS socket and UI issues
- Fix APRS web page socket exhaustion: consolidate init + poll fetches
- Fix APRS web page: messages not displaying + UI hang after TX
- Fix APRS TX crash and duplicate messages on KV4P
- KV4P: fix APRS status reporting, add radio diagnostics and retry
- APRS web page: fix status bar updates, dynamic enable_aprs, 2s polling
- Fix WiFi STA connection crash on KV4P
- KV4P: auto-connect WiFi STA on boot from saved NVS credentials
- OTA firmware update for KV4P over local network
- WiFi setup: password visibility toggle, connection validation, IP display
- Fix WiFi scan and STA connection on KV4P AP-only mode
- Strip KV4P web portal to APRS-only, add WiFi scan API
- Re-enable APRS RX on KV4P with WiFi coexistence fixes
- Disable APRS RX demodulator on KV4P to fix WiFi/HTTP stability
- Fix KV4P heap exhaustion causing WiFi init failure and abort
- Revert APRS store buffer to 64 entries to fix WiFi OOM on KV4P
- Add APRS tab to KV4P web portal
- Increase APRS store buffer from 64 to 200 entries
- Add APRS HTTP API for KV4P board
- Fix config.json corruption causing profile loss on Android update
- Complete board configurations and wire into platformio.ini
- Use translatable strings for Task Monitor UI
- Rename Tasks to Task Monitor in settings menu and page title
- Fix build.sh: auto-detect PlatformIO path
- Fix document title not passed to content when creating NDF documents
- Remove double confirmation on Linux self-update
- Add interactive ESP32 firmware build script
- Fix voice memo transcription on Android: record WAV directly
- Voice memo: auto-generate clip title and warn on cancel discard
- Improve GPS reliability: aggressive watchdog, stream restart, direct fallback
- Fix tracker path crashes with CSV storage, add merge and task monitor
- Fix version mismatch in release builds: sync version.dart in CI
- Fix Windows self-update: use Inno Setup installer instead of batch script (#30)
- Update appVersion to 1.27.0 in version.dart
- WIP: Sync all pending work for laptop transfer
- Speed up station chat send
- Retry station chat queue continuously
- Fix station chat verification
- Skip system messages (join/leave) in unread counter
- Clean up chat duplicates
- Deduplicate station chat cache
- Rewrite XMPP main page to group rooms by actual server domain
- Change XMPP public server chips to browse rooms via S2S federation
- Fix station chat pending status metadata
- Add room browser with live discovery and fix TextEditingController dispose
- Update AT Proto like/repost state immediately in all views
- Fix XMPP registration parser for self-closing IQ responses
- Fix AT Proto thread routing and copyable error details
- Show local PDS replies in AT Proto threads
- Show public XMPP servers directly on settings page
- Add AT Proto media tab, avatar zoom, and graph lists
- Add mention/copy actions and broaden AT Proto timeline feed
- Replace XMPP server presets with xmpp-providers API list and fix S2S SRV fallback
- Restore Bluesky timeline sync after local profile fallback
- Fix S2S federation: STARTTLS race, stanza extraction, IQ routing
- Fix AT Proto self-profile fallback and debug self-check
- Document XmppServerMixin and XmppS2sManager in reusable.md
- Move XMPP server lifecycle into XmppServerMixin, remove duplication
- Enable S2S federation by default when XMPP server is on
- Add XMPP S2S federation for joining external MUC rooms
- Add AT Proto profile shortcut and network search
- Persist follows and add following activity timeline
- Separate XMPP domain from connection host in registration
- Route Bluesky links internally and linkify profile descriptions
- Fix XMPP client connection: DirectTLS via SRV, database path
- Improve AT Proto post UX with profiles, follows, and threads
- Add AT Proto reply thread reading support
- Fix AT Proto feed fallback and automatic like recovery
- Stabilize automatic AT Proto local PDS integration
- Add station-hosted XMPP server (no S2S, v1)
- Add AT Proto image embed gallery and preview
- Polish AT Proto feed UI and profile experience
- Show public AT feed without authentication
- Show loading state during AT Proto auto-bootstrap
- Automate AT Proto credentials and login flow
- Add debug API action to read Bluesky author feed
- Add Teleport AT Proto bridge and consolidate PDS path
- Add IRC typing indicators
- Improve Telegram forum topic loading
- Preserve cached Telegram history
- Add XMPP bridge with multi-server MUC support
- Paginate followed feed
- Load followed feed from cache and relays
- Silence TDLib log output by default
- Gate Telegram logs behind verbose
- Lazy-load Telegram chat list
- Add clear button to geo-chat panel
- Add clear/delete for APRS message conversations
- Add APRS multi-part long message support
- Toast on auto-paste NSEC
- Auto-scroll geo-chat on new messages
- Filter beacon comments from geo-chat and add copy
- Add APRS geo-chat on map tab
- Auto-paste NSEC from clipboard
- Add NSEC import to welcome flow
- Show previews for NOSTR links
- Show link previews in NOSTR feed
- Link bare nevent identifiers
- Suppress update banner after later
- Add NOSTR replies
- Avoid network avatar errors
- Add follow menu and relay search
- Handle nostr: links in NOSTR feed
- Fix NOSTR search and like wiring
- Redesign NOSTR feed as social activity browser with profile avatars and metadata
- Add NOSTR teleport bridge with multi-relay WebSocket client and feed UI
- Emit messageReceived event immediately on send for instant UI update
- Use BLN9 bulletin slot for APRS chatrooms, add BLN* to IS filter
- Fix Signal SynchronizeMessage handling, add APRS teleport pages, and multiple feature updates
- Add APRS conversations, message sending, and hashtag channels
- Fix Signal SynchronizeMessage handling, add APRS teleport pages, and multiple feature updates
- Fix Signal message rendering, is_outgoing detection, and extract shared teleport chat utils
- Add CLAUDE.md, teleport format spec, static map service, and Signal bridge scaffolding
- Fix emoji rendering with color font fallback on all platforms
- Add tap-to-scroll on reply previews and keep input focused after send
- Add prebuilt TDLib (libtdjson.so) for Android arm64
- Add Telegram teleport source files missing from prior commit
- Fix Telegram SQLite cache: persist media paths and add debug API
- Restyle chat bubbles to Telegram dark-mode design
- Make launch-desktop.sh POSIX-compatible for sh/dash
- Fix duplicate chat messages by consolidating timestamp utils to UTC
- Document AT Protocol Phase 5 collection adapters in reusable.md and API.md
- Implement AT Protocol PDS Phase 5: Geogram content collection adapters
- Document AT Protocol Phase 4 sync/firehose components in reusable.md and API.md
- Implement AT Protocol PDS Phase 4: sync endpoints and firehose
- Document AT Protocol Phase 3 components in reusable.md and API.md
- Implement AT Protocol PDS Phase 3: repo CRUD endpoints
- Document AT Protocol Phase 2 components in reusable.md and API.md
- Implement AT Protocol PDS Phase 2: XRPC routing, JWT auth, DID service
- Document AT Protocol core components in reusable.md
- Implement AT Protocol PDS Phase 1: core data structures
- Add AT Protocol PDS implementation plan
- Show extension hint for nsec when using NIP-07 browser extension
- Add npub/nsec copy buttons and QR codes to NOSTR profile menu
- Rename install.sh to install-dev.sh and add missing Linux build deps
- Use device nicknames for restricted folder contact labels
- Resolve hex pubkeys to contact names in restricted folder chips
- Show nicknames in contact picker and sort nicknamed contacts first
- Fix contacts not persisting in restricted shared folder settings
- Add shared_update debug API action for testing folder updates
- Fix contacts not being saved in restricted shared folder settings
- Convert edit shared folder dialog to full-screen page
- Add three-dot menu to shared folder tiles for visibility control
- Document shared folder debug API endpoints in API.md
- Add shared folder debug API for access control testing
- Implement Nostr-based access control for restricted shared folders
- Add missing Nostr login scripts to device page templates
- Fix chat page template variables and hardcoded storage path
- Add APRS-style descriptions to SSID dropdown selector
- Fix blog post 404 when served through station proxy
- Fix nav link paths for shared folder subdirectory pages
- Add shared folder link to device navigation menu
- Add APRS-style SSID field for multi-device identification
- Document shared folder theme templates in reusable.md
- Theme shared folder pages with Terminimal design
- Fix Content-Type for proxied responses and tree.json crash
- Fix URL-encoded paths in shared folder file serving
- Refactor conference from mesh to star (SFU) topology
- Redesign shared_folder into single-instance Shared app
- Fix clickable URLs in chat not opening browser on desktop
- Fix Files app not showing as existing in Add App dialog
- Include nickname in QR code and remove editable nickname field from import
- Add QR code scanner to import profile dialog
- Add Import button to Manage Profiles for importing profiles via NSEC
- Fix QR code not rendering in profile share dialog
- Fix chat message duplication and ordering
- Add "Share as QR" option to profile menu showing NSEC QR code
- Fix meet page rate limiting and LAN meeting discovery
- Rename Conference to Meetings UI + LAN meeting discovery
- Browser conference client: Nostr auth + chat page styling
- Browser web client for conference meetings via station proxy
- Station proxy for meet URLs: /{callsign}/meet/* now proxied to client
- Remove old /conference/* paths, use only /meet/* endpoints
- Resolve chat nicknames from NIP-05 registry for anonymous visitors
- Clean meet URLs: http://ip:port/meet/XXXX for LAN, station/CALLSIGN/meet/XXXX
- Add hash-based URL routing for chat rooms
- Add Android media session integration for Music app
- Fix conference call page: show room ID, fix share sheet URLs
- Add email as a default app for new profiles
- Remove backup, inventory, and website from default apps
- Meeting discovery: room ID format XXXX@callsign + LAN discovery
- Fix Android file VIEW intent: pull-based cold start + standalone viewer mode
- Fix slow initial chat room message loading
- Register Conference as installable app in main UI panel
- Optimistic UI for room rename — update name instantly, revert on failure
- Add moderator room management (create/rename/delete) for station chat
- Rename conference doc to match naming convention
- Add conference app documentation
- Add P2P audio conferencing with LAN and station signaling modes
- Send NOSTR auth on room fetch so server returns isModerator flag
- Add global chat moderator system with CLI command, mod badges, and edit attribution
- Resolve chat nicknames from station NIP-05 registry
- Document buildNostrJsonResponse in reusable.md
- Deduplicate NIP-05 handler into buildNostrJsonResponse on registry service
- Return all identity names in NIP-05 responses for discoverability
- Unify NIP-05 registry to one record per pubkey with callsign + nickname
- Fix chat deletion race condition where deleted messages reappear
- Show callsigns instead of 'anonymous' in web chat messages
- Make callsign dropdown chevron larger and more visible
- Fix CLI using wrong station class (StationServer instead of PureStationServer)
- Add debug API actions for chat delete/edit and improve delete logging
- Add dropdown chevron and hover underline to callsign display
- Implement NIP-09 chat message deletion and message editing
- Add profile menu with nickname support to chat header
- Fix last message hidden behind chat input after Nostr connect
- Fix chat input box overlapping messages on desktop
- Cache-bust chat CSS, disable CSS caching to prevent stale styles
- Add per-room mute notifications for chat rooms
- Restore exact original desktop chat CSS, mobile-only viewport lock
- Restore desktop Terminimal look, apply mobile-only viewport-locked layout
- Add background chat sync on startup for faster chat UI loading
- Fix initialRoomId not auto-selecting in remote device mode
- Add chat room notification tap → navigate to chat room
- Fix CSS 500 error: remove double response.close() in _handleThemeFile
- Show cached rooms and messages immediately, fetch only incremental updates
- Rewrite chat CSS: proper viewport-locked layout, working mobile support
- Fix sidebar showing "Not reachable" during initial station connection
- Fix messages not scrolling fully to bottom, input covering last message
- Fix chat layout: full-viewport scrollable messages, ESP32-style input area
- Fix connecting indicator to show in empty state and sidebar
- Fix auto-update polling: init lastTimestamp from server-rendered messages, poll every 30s
- Show "Connecting..." instead of "Offline" during initial station load
- Fix timestamp handling for before pagination and ISO format consistency
- Add mobile-friendly chat layout with scroll-up pagination
- Enable Nostr login without browser extension via client-side key generation
- Add left margin to Nostr header login button for spacing
- Move Nostr login to header bar with localStorage persistence
- Derive X1 callsign from pubkey in web chat, remove nickname prompt
- Add callsign nickname prompt after Nostr connect
- Enable web chat writing via NIP-07 browser extension signing
- Implement Blossom DELETE per BUD-02 protocol
- Fix wiki: update /api/status response and remove unimplemented DELETE
- Update CLI Station Installation wiki with accurate email docs
- Embed theme files in CLI binary, auto-sync to disk on startup
- Fix web chat CSS — serve global + app-specific stylesheets separately
- Show cached chat messages instantly, fetch fresh ones in background
- Show local chat rooms at /chat level, fetch fresh messages on cd/ls
- Render actual chat messages on ls/cd inside a room
- Fix empty messages and pre-load all chat rooms with content
- Document Desktop local /api/cli endpoint on port 3456
- Fix Android CI: increase JVM memory to fix Metaspace OOM
- Show preferred station's chat rooms in Desktop console
- Unify CLI and Desktop console chat — eliminate duplication
- Fix ls /chat on Desktop and wire /api/cli to shelf server
- Implement /api/cli console command API with shared ConsoleCommandMixin
- Fix Android CI: increase timeouts, remove --no-daemon
- Fix ls /chat showing no stations for client profiles
- Fix Android CI: disable Gradle daemon and improve orphan cleanup
- Fix Android CI: kill orphaned Gradle daemons and remove stale lock files
- Add nip05 CLI admin command for managing NIP-05 registrations
- Add chat and devices dirs to Desktop console rootDirs
- Remove directory-exists check from NIP-05 callsign resolution
- Fix blog URL resolution: add BlogHandlerMixin with NIP-05 callsign lookup
- Add shared NavigationHandler with /chat/<station>/<room> hierarchy
- Add per-command environment filtering to command registry
- Fix "Too many open files" crash when opening chat room
- Update reusable docs with shared interfaces and service_interfaces.dart reference
- Add shared interfaces for CLI/Desktop command registry, wire Desktop to use registry
- Remove dead command code from PureConsole, update reusable docs
- Wire command registry into PureConsole dispatch and completion
- Add core command registry framework and remaining command files
- Add GamesCommand, PlayCommand, and monitoring commands to CLI registry
- Add SSL command class to CLI command registry
- Add ConfigCommand for CLI command registry
- Add ProfileCommand for CLI command registry
- Add DevicesCommand class for CLI command registry
- Fix FD exhaustion: close leaked HTTP clients and pool connections in StationService
- Add FD monitoring to health watchdog and fix more HttpClient leaks
- Make URLs clickable in chat message bubbles
- Fix HttpClient file descriptor leaks causing 'Too many open files' crash
- Fix Linux build: filter tray_manager from Linux plugin registration
- Fix KV4P captive portal DNS and redirect handling
- Add Windows system tray support using tray_manager
- Revert "Optimize chat sync with delta cursors and compact payloads"
- Optimize chat sync with delta cursors and compact payloads
- Fix conditional imports: use dart.library.ui for Flutter-only code paths
- Fix CI builds: disable web, guard ESP32-C3 DAC, fix CLI compilation
- Fix chat parsing for numeric timestamps from ESP32
- Add device_api_request action to log API service
- Harden BLE discovery and transport reliability
- Update lockfile for local geoblue package
- Adopt geoblue frames in Dart BLE transport and ESP32 handler
- Replace system tray icons with outlined variant for light/dark theme support
- Add BLE broadcast delivery test with ESP32 receipt ack
- Add reverse geoblue unicast test scripts and ESP32 validation
- Add geoblue 1000-byte unicast roundtrip integrity test
- Add geoblue shared BLE library and CLI HELLO test
- Tune KV4P BLE memory settings and firmware artifact
- Harden BLE routing and parcel transport reliability
- Fix KV4P BLE manufacturer payload for Geogram discovery
- Stabilize KV4P BLE+mesh runtime memory and service startup
- Garmin UI: adapt all views for round watch display
- Add KV4P BLE service with Geogram HELLO/chat/API support
- Add debug mock data for Garmin simulator testing
- Garmin watch app: menu-driven UI redesign with 4 sections
- Add Garmin build + simulator launch script
- Add Garmin Connect IQ watch app for Fenix 7 Pro
- Checkpoint remaining KV4P ESP32 config and firmware artifact
- Prevent SA818 RX task watchdog by periodic idle yield
- Disable periodic SA818 APRS RX stats logs by default
- Switch SA818 APRS RX to APRS-ESP HDLC/AX25 flow
- Align SA818 APRS RX path closer to APRS-ESP demod flow
- Fix KV4P APRS TX to decode reliably on HackRF/DireWolf
- Fix console reboot on command history persistence
- Persist console history and tune SA818 APRS TX path
- Port KV4P APRS TX to APRS-ESP modem path
- Add reusable SA818 radio module with APRS CLI support
- Suppress noisy mesh-lite vendor_ie warnings
- Disable ANSI log escapes and force plain serial console mode
- Reset ESP32 before opening serial monitor
- Set serial monitor to LF line endings
- Fix serial console prompt for pio monitor terminals
- Add serial.sh helper for ESP32 serial console
- Add KV4P firmware target and reusable SA818 module
- Fix blank map tiles: optimistic reachability + parallel downloads + keepBuffer
- Add pdf.js to web/index.html for pdfx plugin compatibility
- Fix dart:ffi web compilation errors by breaking native-only import chains
- Fix launch-web.sh to use main_web.dart entry point
- Update reusable.md: FilesystemProfileStorage now uses FileSystemService
- Reactivate web platform with Chat + Log only
- Fix Log Browser UI freeze on low-end devices
- Fix crash from corrupted UTF-8 in log files during pruning
- Fix Android crash-restart loop: ensure provideFlutterEngine never returns null
- Prevent WebFPlugin crash on Android by catching Throwable
- Fix Android crash on startup: foreground service and WebFPlugin NPE
- Fix email threading, notifications, and attachment handling
- Commit remaining workspace changes
- Fix SMTP multipart boundary for attachments
- Fix email folder rail label visibility on desktop
- Add 10MB email attachment handling and thread delivery
- Fix Windows self-update: extract ZIP bundle, stage with .bat script
- Include remaining workspace changes
- Add encrypted offline email cache replay and desktop notifications
- Complete pt_PT key coverage for common and contacts
- Refactor locale key ownership and expand music translations
- Fix missing COLLECTION_NAME in blog and chat templates
- Fix nav to only show apps with actual public content
- Fix ContactService crash: set storage before initializeApp in _loadAllowedPubkeys
- Unify device navigation: auto-detect public apps instead of hardcoding
- Fix CLI compilation: remove Flutter-only imports from email_relay_service
- Release v1.21.0
- Disable ECIES email encryption, unify email handling via EmailHandlerMixin
- Unify email handling: delegate to EmailRelayService in all station implementations
- Clean up dead code and standardize templates with dynamic navigation
- Implement email reception, reply threading, and offline delivery
- Extract duplicate station HTML into shared builders in station_html_templates.dart
- Format outgoing email body with NOSTR signature block for external recipients
- Convert all templates to external CSS via <link> tags
- Consolidate duplicate utility functions into html_utils.dart
- Fix Email app infinite inbox loading by setting up ProfileStorage
- Fix Email app to use ProfileStorage for attachment operations
- Add Regenerate Template button to Website Browser Files tab
- Hide Mirror menu item from profile settings
- Remove Groups from default apps panel
- Extract CSS from www index.html into external styles.css
- Add internal drag-and-drop file move to FileFolderPicker
- Add --minimized CLI flag for start-hidden-to-tray on auto-start
- Add New Folder button to FileFolderPicker toolbar
- Add OS-level drag & drop and clipboard file import/export to FileFolderPicker
- Pin Flutter to 3.38.x across all CI workflows
- Fix Android CI build hanging indefinitely
- Add CTRL+S save shortcut and find-in-file feature to document viewer
- Add lld to Linux CI dependencies for webf native build
- Upgrade website preview to platform-adaptive WebView with JS support
- Debounce editor gutter updates to fix typing lag
- Highlight active line number on click in preview and edit modes
- Add line numbers to text preview and edit modes
- Fix horizontal centering in text preview by forcing full-width layout
- Add syntax highlighting to DocumentViewerWidget for 50+ languages
- Hide storage bar and restrict breadcrumbs to web folder in website browser
- Open website public URL in system browser on tap, copy on long-press
- Add WebsiteBrowserPage with Files + Preview tabs for www collections
- Fix website serving via p2p.radio: use ProfileStorage instead of raw File access
- Add system tray, desktop notifications, icon assets, and Windows autostart
- Add Windows autostart via registry entry in Inno Setup installer
- Disable minimize button when tray is active to fix taskbar icon persistence
- Fix Windows installer build: remove unsupported DisableLicensePage directive
- Rewrite all Linux install scripts with lessons learned
- Ensure index.theme exists before updating icon cache
- Use official smiley icon set for Linux desktop integration
- Replace satellite icon with smiley face icon on Linux
- Fix desktop integration: chmod +x .desktop files, preserve user data
- Fix desktop file: use valid category and add search keywords
- Fix install-desktop.sh BUNDLE_DIR pointing one level too high
- Move Linux install one-liner to top of README
- Fix blog HTML endpoint using wrong storage when station sets X-Device-Callsign
- Update README with one-line Linux install command
- Add autostart on login via XDG autostart desktop entry
- Launch Geogram automatically after install
- Add one-line Linux installer script
- Fix blog HTML endpoint returning 404 for encrypted profiles
- Add Linux desktop icon integration with user-space install
- Remove underline from blog post station URL
- Make blog post station URL clickable to open in browser
- Fix blog post station URL not showing for published posts
- Fix CI: resolve RepeatMode name collision and iOS code signing
- Add partial German (de_DE) translation files
- Route all profile folder I/O through ProfileStorage, fix blog serving crash
- Fix Windows path handling in music_library and folder_browser_widget
- Fix Windows path handling: use p.join, p.normalize, p.isWithin throughout
- Fix chat rooms not displaying: initialize ContactService before building nickname map
- Eliminate stray file writes outside work folder
- Fix CI: build portable zip first, make installer non-blocking
- Fix CI: install Inno Setup on windows-latest (now Server 2025)
- Show nicknames in DM chat AppBar and info dialog
- Add Windows desktop support: cross-platform fixes and dev scripts
- Fix app icon: use smiley face (geogram_icon_transparent.png)
- Add Windows installer (Inno Setup) and update app icon
- Fix CRT bundling: search all x64 candidates, pick newest version
- Fix CRT version mismatch: bundle VC143 runtime, not VC142
- Fix CI: mark diagnostic steps as continue-on-error
- Fix Windows CI: pin Flutter 3.38.5, bundle all DLLs, add smoke test
- Fix DM notification tap to navigate directly to 1:1 chat
- Fix DM timestamps to use sender's created_at instead of arrival time
- Fix station title display and preserve cached rooms when offline
- Add status grid to ESP32 wiki page — only C3 Mini is ready
- Fix 1:1 DM delivery via LAN and Station transports
- Add wiki with ESP32 devices, CLI station guide, and community pages
- Progressive chat loading with visible progress indicator
- Exclude mirror folder from Apps panel listing
- Optimize Android build for low-RAM laptops: reuse Gradle daemon, build offline
- Display nicknames in chat message bubbles instead of raw callsigns
- Fix chat not scrolling to bottom by switching to reverse ListView
- Replace full-screen intent boot approach with headless FlutterEngine
- Fix Android auto-start after reboot using full-screen intent notification
- Fix missing setStorage() in station_server_service and cli_chat_service
- Fix LateInitializationError crash in station server (Issue #6)
- Fix firmware flashed to wrong address (offset 0 instead of 0x10000)
- Fix swapped ESP32-S2/S3 chip detection magic values
- Fix library showing empty by using directoryExists for folder checks
- Auto-select downloaded firmware in Flasher tab
- Fix downloaded firmware not visible in library and not used for flashing
- Add build artifacts and updated firmware binaries
- Add Heltec WiFi LoRa 32 V1 board support with flasher entry
- Update device.json modified_at when firmware changes
- Only sync flasher firmware when binary content actually changes
- Auto-sync firmware to flasher downloads on build
- Add Heltec V2 and V3 flasher download entries
- Add Heltec WiFi LoRa 32 V2 board support with SX1276 LoRa driver
- Add Heltec WiFi LoRa 32 V3 board support with SSD1306 OLED and SX1262 LoRa drivers
- Allow firmware binaries in downloads/flasher/ to be tracked by git
- Add ESP32-C3 Mini firmware binary to fix 404 on Flasher download
- Fix USB AOA URI from geogram.dev to geogram.radio
- Fix Download FAB layout and ESP32-C3 firmware URL
- Simplify firmware download to save firmware.bin next to device.json
- Add firmware download browser to Library tab
- Fix non-exhaustive switch on DebugAction enum
- Fix launch-desktop.sh re-downloading ObjectBox on every build
- Add flasher firmware downloads index
- Show chip mismatch dialog instead of snackbar on incompatible firmware
- Add chip compatibility verification to prevent flashing wrong firmware
- Fix Flash button disabled when using Browse for custom firmware
- Add mirror debug API endpoints for remote troubleshooting
- Fix mirror sync using wrong callsign: active profile vs peer callsign
- Revert mirror_wizard_page.dart changes that broke device discovery
- Fix mirror sync pipeline: 5 bugs preventing file transfers
- Fix mirror state leaking between profiles on profile switch
- Enable image browsing across folder siblings in full-screen viewer
- Store mirror config per-profile via ProfileStorage instead of global file
- Show padlock icon next to callsign in file browser when storage is encrypted
- Auto-scroll file browser breadcrumb to show deepest folder
- Add missing blog_post translation key to en_US and pt_PT
- Wire file browser through ProfileStorage for encrypted storage support
- Delete profile data from disk when profile is removed
- Pass ProfileStorage in mirror settings page sync calls
- Wire LogService through ProfileStorage for encrypted storage support
- Wire Stories app through ProfileStorage for encrypted storage support
- Wire mirror sync through ProfileStorage for encrypted storage support
- Navigate back to main UI after mirror pairing dialog on device B
- Show folder size estimates in mirror wizard Select Apps step
- Remove duplicate Next button from Select Apps step
- Hide mirror info card once a device is discovered
- Improve Mirror Find Device UI
- Switch to mirror profile on device B after pairing
- Move Next button to top of Apps step in mirror wizard
- Remove confusing initial sync options from mirror wizard
- Fix mirror sync to use callsign-based paths instead of raw baseDir
- Fix setState called after dispose crash in NewProfilePage
- Move installer docs to docs/apps/ and fix cross-references
- Add installer app specification documentation
- Exclude log folder from mirror sync
- Implement bidirectional mirror sync with ignore patterns
- Rewrite mirror sync integration tests as self-contained pure Dart tests
- Implement real mirror synchronization with reciprocal pairing
- Add mirror synchronization documentation
- Update mirror wizard app list with all syncable apps, remove Files
- Move sync style dropdown below app title/description in mirror wizard
- Stop mirror discovery scan when a device is selected
- Simplify mirror wizard discovery — scan subnet on port 3456 directly
- Wire mirror wizard to real network discovery + fix IP filter bug
- Fix Setup Mirror page not updating when WiFi connects
- Clarify Setup Mirror messaging: this device becomes a mirror
- Add Setup Mirror page to profile management menu
- Fix Export all Profiles doing nothing on Android
- Fix RenderFlex overflow in import/export profiles dialog title
- Release v1.17.0 — QR code editor improvements and fixes
- Fix barcode generation and scanning image display
- Add QR code folder management UI and editing support
- Improve QR generator UX
- Fix RenderFlex overflow in QR generator barcode preview
- Fix QR code page compilation errors
- Add QR app to create app UI panel and add translations
- Add QR codes app for scanning and generating QR codes and barcodes
- Fix RenderFlex overflow in transfer widgets on small screens
- Fix FileFolderPicker crashes and sync LAN devices to ConnectionManager
- Fix UI freeze from BLE scan spam and setState after dispose crashes
- Fix back gesture closing FileFolderPicker instead of navigating up
- Trigger LAN discovery when BLE devices are found
- Fix RenderFlex overflow when keyboard opens on transfer send page
- Fix remaining RenderFlex overflows in transfer send page
- Fix RenderFlex overflow in device option dropdown
- Fix RenderFlex overflow in transfer send empty state
- Fix crash logging and DownloadForegroundService, update default location granularity to 50km
- Fix PDF rendering on Linux, add PDF navigation, fix video slider overflow
- Replace Up button with ".." folder entry in file picker
- Fix "unverified" badge flash after DM delivery
- Fix DM delivery failures: eliminate racing paths and BLE false delivery
- Add BLE-only mode, response routing, JSON buffer parsing, and device ping
- Fix DM messages not loading into chat UI due to directory existence check
- Fix DM messages not displaying due to file truncation race condition
- Fix native crash log filename and two crash bugs
- Auto-remove crash logs older than 5 days
- Add Contributor License Agreement (CLA) setup
- Add station server deployment guide
- Add optimistic UI and background delivery for DMs
- Fix Android FileUriExposedException on file open
- Fix crash reports and add image error handling
- Fix Windows 0xc0000142 startup error
- Fix import order in stories_home_page.dart
- Fix Flutter icon tree-shaking error in Stories app
- Add background music and search/filter to Stories app
- Change Stories app icon color to red
- Add Stories app to collection types and dependencies
- Add Story Studio app for creating interactive visual stories
- Add Android storage permissions for Music app
- Revamp Music app UI and improve Work app file naming
- Add on-demand album artwork fetching when displayed
- Miscellaneous improvements and fixes
- Add automatic album artwork fetching from Cover Art Archive
- Fix Portuguese translations with proper accents
- Add Music app translations for collection type UI
- Add Music app to create collection UI panel
- Add Music app for local music playback
- Add platform-specific rendering for web snapshots
- Add embedded WebView for viewing web snapshots
- Add Linux support for Whisper and improve transcription UI
- Add NDF websnapshot document type for offline website capture
- Fix CLI build: add encrypted storage stub for pure Dart builds
- Remove sqlite3_flutter_libs from encrypted_archive package
- Add encrypted storage support and new features
- Add getAttachmentBytes to ChatService for encrypted storage support
- Fix chat images not loading with encrypted storage
- Add ScopedProfileStorage and update browser pages for encrypted storage
- Add encrypted storage support for Work app
- Complete ChatService migration to ProfileStorage abstraction
- Add background progress tracking for encryption/decryption operations
- Fix email storage to use per-profile paths
- Add detailed logo and thumbnail documentation to NDF specification
- Add document description, workspace logo, and document thumbnail features
- Add priority levels to TODO items (High, Normal, Low)
- Fix TODO rename to also update document metadata title
- Remove edit icon from TODO title, keep tap-to-rename
- Add rename option for TODO document title
- Add presentation models, document editor improvements, and dependencies
- Add TODO document type to NDF/Work app
- Add form responses spreadsheet view and submission controls
- Fix inline text formatting shortcuts and visual feedback in presentation editor
- Add Work module, transfer improvements, and USB AOA enhancements
- Add column resize and Ctrl+S save to spreadsheet
- Fix P2P transfer progress and remember last recipient
- Improve FileFolderPicker grid view thumbnails for images
- Fix RelayCacheService to use StorageConfig for data directory
- Fix ghost devices in Transfer Send dropdown and add nickname support
- Add P2P debug API endpoints and E2E test script
- Add P2P file transfer for direct device-to-device sharing
- Fix USB hello handshake not completing after restart
- Fix USB AOA POLLERR handling when already connected
- Fix USB AOA Linux poll() returning EINTR and Android single instance
- Fix USB AOA race condition on transport initialization
- Add USB hotplug detection for Linux
- Fix USB AOA bidirectional communication and device discovery
- Fix USB AOA: async I/O to prevent UI blocking and Android 14+ crash
- Fix firmware source SegmentedButton overflow on narrow screens
- Improve Add Firmware Wizard UX
- Fix Serial Monitor toolbar to wrap in portrait, scroll in landscape
- Add Copy from ESP32 feature and fix UI crashes
- Add Android USB serial detection for ESP32 auto-navigation to Flasher
- Consolidate settings into EndDrawer and remove SettingsPage
- Move Flash Device button higher for better mobile visibility
- Fix version mismatch causing endless update alerts
- Remove managed_components and build artifacts from git tracking
- Add Android USB Serial Plugin using native USB Host API
- Remove ESP32 dependencies.lock with hardcoded paths
- Add native USB serial implementation for Flasher
- Remove flutter_libserialport dependency
- Improve Flasher UI layout and serial monitor features
- Add multi-device flash, serial monitor, and UX improvements
- Add ESP32 flash test for esptool protocol verification
- Show item count in folder labels (e.g., 'esp32 (2)')
- Add inline expandable details to firmware library tree
- Add protocol selector to firmware wizard and major updates
- Add native USB serial port detection without external libraries
- Add Flasher app for ESP32 and USB device flashing
- Add chat_api_paths.dart for pure Dart CLI support
- Fix CLI build: use chat_api_paths.dart instead of chat_api.dart
- Fix CLI build: use dart instead of dart run for game generation
- Add Blog API test for p2p.radio
- Fix HELLO handshake for clients with double-encoded events
- Add server integration tests with NOSTR authentication
- Add unified API layer and cleanup outdated tests
- Migrate from lib/util/chat_api.dart to lib/api/endpoints/
- Add server health watchdog with auto-recovery
- Fix: Proximity tracking + UI consistency improvements
- Hide Plan and Proximity tabs in tracker
- Fix: Android UI freeze after error recovery
- Fix: Location fallback + full uptime format in HTML
- Release 1.10.6: Transfer system overhaul + BLE discovery improvements
- Fix: BLE bidirectional DM between Android and Linux
- Feat: Full-screen welcome page with vanity callsign generator
- Feat: BLE advertising reliability + README binary size section
- Fix: Android 15+ foreground service timeout handling
- Add patched ble_peripheral to third_party
- Feat: BLE pull model for file transfers + progress tracking
- Perf: DM message caching and loading optimization
- Fix: Video player disposal crash + enhanced crash reporting
- Fix: CI build failures - sqlite loader, Linux deps, CLI pubspec
- Add NOSTR relay and SQLite loader updates
- Feat: runtime whisper library download for F-Droid builds
- Fix: Linux build - use ONNX Runtime 1.22.0 (matches plugin)
- Fix: Linux build - bundle libonnxruntime.so.1
- Fix: Windows build - use ONNX Runtime v1.21.0 for v1.21.1 (no Windows binaries)
- Fix: Windows build - pre-download ONNX Runtime
- Fix: Update to maxminddb async API (v1.4.x)
- Fix: CLI build - remove Flutter imports from geoip_service.dart
- Feat: Privacy-first networking - remove all external service dependencies (v1.9.0)
- CI: fix Linux build (dangling symlinks) and disable web build (FFI not supported)
- Feat: WebSocket reconnection after Android 15 dataSync timeout (v1.8.2)
- Fix: Android 15+ foreground service dataSync timeout crashes (v1.8.1)
- Feat: console terminal, log performance, game fixes (v1.8.0)
- Update F-Droid docs: manual updates required for Flutter apps
- Update F-Droid docs with tag-filtered auto-update workflow
- Feat: add --auto-station support to CLI for consistency
- Fix: use correct daemon mode command for CLI
- Fix: ensure onnxruntime.dll is bundled in Windows release
- Fix: dereference symlinks in Linux release archive
- Feat: download page improvements, whisper model mirroring, and crash fixes
- Feat: download page, console VM, and email/logging improvements
- Feat: video browser, SMTP relay support, and email improvements
- Feat: log browser, shared web utilities, and station server improvements
- Feat: themed station homepage and email service foundation
- Fix: hide blog link on homepage when no blog posts exist
- Docs: add NOSTR likes API and blog format documentation
- Feat: NOSTR likes, chat web interface, and blog improvements
- Release v1.7.4
- Feat: crash logging and auto-recovery for Android
- Feat: Wi-Fi Direct hotspot, QR codes, and station UI improvements
- Feat: auto-start on boot, place improvements, and tracker enhancements


## 2026-01-10 - v1.7.1

### Changes
- UI: add settings drawer, improve Apps panel layout, and fix tracker icons


## 2026-01-10 - v1.7.0

### Changes
- Release: bump version to 1.7.0+12
- Feat: add share image with cached map tiles, truck path type, and expenses
- Release: bump version to 1.6.108+11
- Feat: add tracker plans, path details, and motivation features
- Release: bump version to 1.6.107+10
- Feat: improve chat device title display and unify tracker dialogs
- Release: bump version to 1.6.106+9
- Feat: map cache settings and tracker exercises improvements
- Stabilize BLE messaging and WebRTC offline handling
- Fix: refresh event files section after uploading media
- Release: bump version to 1.6.105+8
- Fix BLE+ pairing handshake
- Release: bump version to 1.6.104+7
- Fix BLE DM routing and document transport flow
- Release: bump version to 1.6.103+6
- Feat: improve offline GPS, UI fixes, and blog FAB
- Release: bump version to 1.6.102+5
- Feat: add date reminders for contacts
- Docs: update voice.md with current preload implementation
- Perf: start whisper preload immediately after runApp()
- Fix: coordinate whisper model preloading with dialog
- Docs: update voice.md with preloading and performance details
- Perf: lazy load whisper model at app startup
- Perf: speed up voice transcription 100x
- UI: move NPUB and callsign to collapsible Details section
- UI: fix contact detail display issues
- Docs: update F-Droid publishing guide
- UI: improve interaction dialog and list
- UI: contact panel improvements
- UI: remove Group field from contact detail view
- Refactor: create shared PlaceCoordinatesRow widget
- UI: move coordinates value below label for readability
- Release v1.6.101
- ProGuard: remove Flutter keep rules to allow R8 to strip Play Core
- Release v1.6.100
- Release v1.6.99
- Android: add Play Core exclusions for F-Droid compliance
- Android: fix R8 build failure by ignoring Play Core classes
- Android: fix R8 build failure by ignoring Play Core classes
- Docs: add F-Droid publishing guide
- CLI: make log_service conditional (stub on non-Flutter)
- CLI: remove ensemble_ts_interpreter (depends on Flutter)
- CLI: create separate pure-Dart package for CLI build
- Contacts: fix recreation after deleting all contacts
- Web: make speech-to-text conditional (stub on web)
- CI: disable web build (whisper_flutter_new requires dart:ffi)
- CI: clear pub cache before web build to remove cached ffi
- CI: delete pubspec.lock before web build to ensure clean ffi removal
- CI: fix CLI and Web build failures
- Voice-to-text: skip idle state, start recording immediately
- Android: F-Droid compliance fixes
- Docs: add voice recognition documentation
- Voice-to-text: fix download and WAV recording for Whisper
- Contacts: improve merge duplicates tool
- Contacts: add "Clear Cache & Metrics" tool option
- Contacts: fix back button to navigate up folder hierarchy
- Contacts: ignore system folders at root level, support nested groups
- Contacts: simplify folder structure (remove nested contacts/contacts)
- Events: add contacts feature and consolidate event editing
- Contacts: add Short message interaction and auto-capitalize text fields
- Contacts: add email action icons and metrics tracking
- Contacts: consolidate QR sharing to use single ContactQrPage
- CI: fix sed syntax for macOS
- CI: try macOS runner for Android build (Maven Central issue)
- Add privacy policy for Google Play Store
- CI: remove conflicting Maven repository configs
- CI: add Maven mirrors and retry logic for Android builds
- Android: add Maven repository fallbacks
- CI: add Gradle caching for Android builds
- Contacts: add multi-select, merge tool, and Quick Access grid
- Contacts: add QR code sharing and scanning
- Contacts: fix empty state and improve loading feedback
- Contacts: add Event interaction to associate contacts with events
- Contacts: make group names translatable
- Contacts: implement folder-style navigation for groups
- Add Import Contacts option to empty contacts state on Android
- Fix Import Contacts layout: move Select All buttons below app bar
- Improve Contacts loading and Location/Place interactions
- Fix Software Updates: race condition causing "Up to Date" with update available
- Fix web build: add missing io_stub exports
- Fix Console: use default station URL when no station connected
- Fix Console: embed JSLinux scripts from local cache
- Fix Console VM: remove Content-Disposition header for JS files
- Fix Console: improve JSLinux loading and use better icon
- Fix web build: add stubs for PTY/terminal and missing stub methods
- Add Console VM app with bundled TinyEMU for Linux
- Add place map view and fix theme settings crash
- Improve places filtering with exponential radius slider and local caching
- Fix web build: use file_helper for cross-platform image handling
- Enhance contacts with social handles, location types, and UI improvements
- Update app icons and add video playback to event media
- Add video playback support to PhotoViewerPage and fix event file refresh
- Add radius filter for station places and UI improvements
- Add first-launch offline map pre-download
- Add Linux desktop update procedure and centralize location services
- Update Android notification icon
- Add callsign generator to profile creation dialog and improve Log app
- Remove AUTHOR and GROUPS from event.txt generation
- Sync Edit Event UI with Create Event improvements
- Fix redundant station name in Android notification
- Fix window icon path to be relative to executable
- Wrap LogPage content in Scaffold for proper structure
- Fix duplicate events folder in path structure
- Add photos section to Create Event with cover photo selection
- Fix _isOnline reference - use _locationType instead
- Improve Create Event UI: location dropdown, move agenda to Updates tab
- Fix EventFilesSection Row overflow on narrow screens
- Replace Events header + button with bottom-right FAB


## 2026-01-03 - v1.6.65

### Changes
- Add Google Play release plan documentation
- Keep update button blue when download is ready to install
- Update release script to include F-Droid metadata updates
- Add screenshots and feature graphic for F-Droid listing
- Update F-Droid metadata to v1.6.75
- Add F-Droid fastlane metadata with icon and descriptions
- Add Apache 2.0 license for F-Droid submission
- Add signed NOSTR authentication for RESTRICTED chat rooms
- Fix VC++ Runtime DLL discovery path
- Bundle VC++ Runtime DLLs with Windows build
- Fix Podfiles: Use static linkage for onnxruntime compatibility
- Add Podfiles for iOS/macOS with correct platform versions
- Fix iOS/macOS builds: Update deployment targets for flutter_onnxruntime
- Release v1.6.72 - Inventory app, Transfer system, and UI improvements
- Add horizontal rules between sections for GitHub rendering
- Improve README formatting: Details prefix, extra spacing between sections
- Move documentation links to bottom of each app section
- Replace em-dashes with regular hyphens
- Add Device Discovery section explaining P2P communication
- Improve README with warmer tone and new sections
- Improve documentation with project overview and technical reference
- Release v1.6.71 - Fix Android build with proguard rules
- Add proguard rules for Google Play Core classes
- Fix Android build and refactor TFLite service for cross-platform support
- Release v1.6.70 - Update system improvements and window state persistence
- Fix DM image transfers and add debug API for 1:1 testing
- Fix web build: use stub-compatible header methods
- Fix DM file transfers - upload files to remote before sending
- Release v1.6.67
- Fix scroll hijacking when images load in chat
- Improve chat UX, fix DM quotes, and enhance privacy
- Release v1.6.65


## 2025-12-29 - v1.6.64

### Changes
- Improve chat UX, station sync, and update flow


## 2025-12-29 - v1.6.63

### Changes
- Minor updates and improvements


## 2025-12-28 - v1.6.62

### Changes
- Fix web focus detection for title attention


## 2025-12-28 - v1.6.61

### Changes
- Export TitleManager type for attention service


## 2025-12-28 - v1.6.60

### Changes
- Improve notifications, identity refresh, and feedback/service docs


## 2025-12-28 - v1.6.59

### Changes
- Events: media contributions, visibility, maps, station sync


## 2025-12-27 - v1.6.58

### Changes
- Improve events workflow and group sync
- Fix async return in alert comment save
- Deduplicate feedback comments locally
- Open place profile pics and hide mobile refresh


## 2025-12-26 - v1.6.57

### Changes
- Normalize station place upload paths
- Add place profile pics and dedupe station places


## 2025-12-25 - v1.6.56

### Changes
- Add place feedback handling and update feedback storage
- maps: reload items after pan and radius change
- maps: refresh on profile location updates
- maps: fix station places dedupe set


## 2025-12-25 - v1.6.55

### Changes
- maps: load station places and refresh collections
- app: add Places to default collections
- places: sync local uploads and station init
- maps: fetch station alerts on initial load
- ci: fix macOS archive app name


## 2025-12-25 - v1.6.54

### Changes
- tests: refresh alert tests and archive legacy suites
- docs: update feedback API and app format specs
- places: improve editor, browser, and station sync
- alerts: adopt shared feedback utils and update station APIs


## 2025-12-24 - v1.6.53

### Changes
- Minor updates and improvements


## 2025-12-24 - v1.6.42

### Changes
- Add repository guidelines documentation
- Defer notification permission request to onboarding flow
- Fix crash when starting foreground service without Bluetooth permissions
- Prepare repository rename: geogram-desktop → geogram
- Release v1.6.51 - Places App Improvements and Feedback System
- Fix remote chat messaging with proper NOSTR signing
- Release v1.6.49 - Remote Device Browsing Fixes and Optimizations
- Optimize: Cache-first loading for remote device browsing
- Fix: Add X-Device-Callsign support for chat messages endpoint
- Fix: Add X-Device-Callsign header support for blog and chat APIs
- Release v1.6.48 - Bug Fixes for Station URL and Blog Proxy
- Fix: Use device station URL with fallback to preferred station
- Fix: Remove non-existent stationUrl property from RemoteDevice
- Release v1.6.47 - Device Apps Browser and Notifications
- Fix compilation error: use DevicesService instead of ConnectionManagerService
- Add device apps browser for viewing public data
- Remove broken link from blog footer
- Enable core library desugaring for Android
- Fix ProfileService method call in dm_notification_service
- Add push notifications for direct messages on Android/iOS
- Release v1.6.43
- Fix blog HTML proxy path in CLI station mode
- Fix blog HTML proxy path format
- Release v1.6.42 - BLE peer discovery and blog improvements


## 2025-12-15 - v1.6.41

### Connection Stability Improvements
- Add server-side heartbeat timer that PINGs all clients every 30 seconds
- Add stale client detection and automatic cleanup after 90 seconds of inactivity
- Add safe socket send wrapper with graceful error handling
- Fix kickDevice() to use proper null handling instead of unsafe firstWhere pattern
- Add proper client cleanup on disconnect (closes socket, cleans pending proxy requests)
- Update server stop() to properly terminate all connections and pending requests
- Improve WebRTC signaling error handling with sender notification on forward failure

### Bug Fixes
- Fix WebSocket null socket errors in WebRTC signaling, COLLECTIONS_REQUEST, and COLLECTIONS_RESPONSE handlers
- Prevent WebRTC self-routing (device sending to itself)

## 2025-12-15 - v1.6.40

### Changes
- Update version file to 1.6.39
- Add blog debug API and p2p.radio proxy support


## 2025-12-14 - v1.6.38

### Bug Fixes
- Fix Software Update UI not recognizing completed background downloads
- When returning to Software Update screen after a background download completes, the UI now shows "Ready to Install" instead of forcing re-download
- Added `findCompletedDownload()` method to check for existing downloaded update files
- Added `hasCompletedDownload` state to persist completed download information across page navigation

## 2025-12-14 - v1.6.37

### Alert Folder Structure
- Create centralized `AlertFolderUtils` utility for consistent folder path handling across all components
- Standardize alert folder structure: `active/{regionFolder}/{folderName}/`
- Photos stored in `images/` subfolder with sequential naming (`photo1.png`, `photo2.png`, etc.)
- Comments stored in `comments/` subfolder with format `YYYY-MM-DD_HH-MM-SS_AUTHOR.txt`
- Region folder calculated as rounded coordinates (e.g., `49.7_8.6`)

### Bug Fixes
- Fix photo upload to station when creating alerts via desktop UI - photos are now uploaded after being saved locally
- Fix station alert file path regex to support `images/` subfolder in upload/download paths
- Fix `_findAlertById` to search recursively within `active/{region}/` directory structure
- Fix UI photo save path to use correct `active/{regionFolder}/{folderName}/images/` structure

### Code Quality
- Remove duplicate folder path functions from `report.dart`, `station_alert_service.dart`, `station_alert_api.dart`, and `pure_station.dart`
- All components now use shared `AlertFolderUtils` for path construction

### Testing
- Enhanced `app_alert_test.dart` with folder structure consistency checks
- Verify `images/` subfolder exists on station after photo upload
- Test sequential photo naming (`photo1.ext`, `photo2.ext`)
- All 49 folder structure tests passing

## 2025-12-14 - v1.6.36

### UI Improvements
- Add keyboard navigation to photo viewer (Left/Right arrows to browse, Escape to close)
- Auto-capitalize first letter in Title and Description fields when creating alerts
- Improve location picker default zoom from 10 to 17 for better usability
- Remember user's preferred zoom level in location picker between sessions

### Bug Fixes
- Refresh alert data after successful comment and point/unpoint sync to station

## 2025-12-14 - v1.6.35

### Alert Comments
- Add comment sync between clients and station
- Comments submitted to station are now downloaded by other clients during sync
- Alert details API now includes full comment list with author, timestamp, and content

### Station API Improvements
- Merge CLI and GUI station API handlers into shared `StationAlertApi` class
- Both CLI (`pure_station.dart`) and GUI (`station_server_service.dart`) now use identical handlers
- Add POST `/{callsign}/api/alerts/{folderName}/comment` endpoint for adding comments
- Alert details endpoint now includes `comments`, `comment_count`, `pointed_by`, `verified_by`, `last_modified`, and `report_content` fields
- Fix HTTP status handling - use `http_status` field to avoid conflict with alert `status` field
- Handle report parsing failures gracefully - still return raw `report_content` for client sync

### Testing
- Add comment flow tests to `tests/app_alert_test.dart`
- Test Client B adding comment, station sync, and Client A receiving comment

### Documentation
- Update API.md with comment endpoint and expanded alert details response
- Document comment object structure and all new response fields

## 2025-12-14 - v1.6.34

### Bug Fixes
- Fix photo upload path for station alerts - use coordinate-based folder name instead of date-based ID
- Photo files are now correctly uploaded alongside alert data when sharing to stations
- Fix NOSTR event format for alert sharing - use `{type: 'EVENT', event: {...}}` instead of array format

### Station Server Improvements
- StationServerService now uses `AppArgs().port + 1` as default port instead of hardcoded 8080
  - Prevents port conflicts when running multiple instances
  - Station API port is always API port + 1 (e.g., API on 3456 means station on 3457)
- Added `runningPort` getter to get the actual port the station server is running on
- Added alert file upload handler - POST `/{callsign}/api/alerts/{folderName}/files/{filename}`
- Added alert file download handler - GET `/{callsign}/api/alerts/{folderName}/files/{filename}`
- Station now stores uploaded photos locally instead of proxying to connected clients

### UI Improvements
- Increase default zoom level from 10 to 16 when selecting alert location on map
- Auto-capitalize first letter when writing comments in Alert Details

### Debug API
- Add `alert_share` action to share alerts via NOSTR and upload photos to station
- Add `photo` parameter to `alert_create` action for creating test alerts with photos
- Add recursive search for alerts in nested directory structure
- Add `station_server_start` action to start the station server programmatically
- Add `station_server_stop` action to stop the station server
- Add `station_server_status` action to get station server status including running port
- Add `alert_upload_photos` action for direct HTTP photo upload to station

### Testing
- Add comprehensive Dart test for alert photo functionality (`tests/alert_photo_test.dart`)
- Test launches temporary station + 2 clients for end-to-end alert photo verification

### Documentation
- Update API.md with new debug API actions for alert testing
- Expand alert format specification with photo handling details


## 2025-12-13 - v1.6.33

### New Features
- Add foreground service for software update downloads to prevent interruption when screen turns off or app goes to background
- Download progress notification with real-time MB progress display
- Wake lock during downloads to keep network operations active

### Improvements
- Add dataSync permission to BLE foreground service for WebSocket and API operations
- WebSocket connections and API requests through p2p.radio station proxy now continue when display is powered off
- Network operations remain active in background for better station connectivity


## 2025-12-13 - v1.6.32

### New Features
- Add full-screen photo viewer for alert images with zoom, pan, and swipe navigation
- Add left/right navigation buttons and page indicators in photo viewer

### UI Improvements
- Close New Alert panel automatically after saving
- Move Save button to bottom-right corner with consistent FloatingActionButton styling
- Move Points chip to top badges area next to severity and status in alert details
- Capitalize severity labels (Emergency, Urgent, Attention, Info) and status labels in UI
- Filter user's own alerts from "Nearby Alerts" section to avoid duplicates
- Replace separate Favorite/Delete icons with a single menu button in Apps panel
- Move apps menu icon to top-right corner for cleaner appearance
- Move favorite badge to top-left corner when apps are favorited

### Removed
- Remove Subscribe and Verify actions from alert details (not working properly)

### Bug Fixes
- Fix catchError handlers for fire-and-forget station sync calls


## 2025-12-13 - v1.6.30

### Changes
- Fix station HTTP relay using direct function calls instead of localhost HTTP
- Fix device list settings icon position in portrait mode
- Auto-check for updates when visiting Software Updates page


## 2025-12-12 - v1.6.28

### Changes
- Add Events API for remote viewing via /api/events endpoints
- Add Alerts API for remote viewing via /api/alerts endpoints with geographic filtering
- Add debug actions for events (event_create, event_list, event_delete)
- Add debug actions for alerts (alert_create, alert_list, alert_delete)
- Add alerts API test script (41 tests)


## 2025-12-12 - v1.6.27

### Changes
- Fix station distance display by fetching lat/lon on connect
- Add voice debug actions to DebugController enum
- Fix WebRTC P2P message delivery and add station device list
- Fix just_audio not available on Linux - skip initialization
- Fix web build by adding conditional imports for FFI code
- Add self-contained audio playback for Linux via ALSA FFI
- Add voice messages to 1:1 DM chat
- Add unread DM badge to Devices navigation icon
- Add laptop icon for desktop devices (Linux/macOS/Windows)
- Fix device distance display and chat bubble readability
- Fix update mirror to sync all binaries even if GitHub Actions is still building


## 2025-12-10 - v1.6.15

### Changes
- Fix Android-to-Android BLE communication, add foreground service


## 2025-12-10 - v1.6.14

### Changes
- Add i18n strings for BLE+ upgrade and folder features


## 2025-12-10 - v1.6.11

### Changes
- Remove success snackbar from location detection on Maps panel
- Add diagnostic logging for default collections creation
- Add i18n support for About page and Device folders
- Persist folder state and add drag-to-reorder folders


## 2025-12-10 - v1.6.10

### Changes
- Change folder device count badge to grey square


## 2025-12-10 - v1.6.9

### Changes
- Add folder organization for devices


## 2025-12-10 - v1.6.8

### Changes
- Add multi-select mode to Devices panel


## 2025-12-10 - v1.6.7

### Changes
- Show changelog when update is available


## 2025-12-10 - v1.6.6

### Changes
- Fix splash screen cropping and update About page


## 2025-12-10 - v1.6.5

### Changes
- Update app icons and improve onboarding UI


## 2025-12-10 - v1.6.4

### Changes
- Remove pending status - only save messages after delivery confirmed
- Add automated DM delivery test script
- Fix double JSON encoding in transport API requests
- Fix DM verification by using stored created_at instead of recalculating
- Fix DM signature verification using wrong roomId for incoming messages
- Disable back gesture on onboarding screen to ensure permissions are requested
- Redesign onboarding header to horizontal layout for better visibility on small screens
- Add WebRTC NAT hole punching for direct P2P connections


## 2025-12-10 - v1.6.3

### Changes
- Add ConnectionManager for unified device-to-device communication


## 2025-11-18

### Added
- **Custom App Icon**: Created custom Geogram icon with location marker design
  - Blue gradient background with white location pin
  - Network node indicators
  - 512x512 PNG format
  - Displays in window title bar, taskbar, and system tray

- **Log System**: Implemented full-featured logging functionality
  - LogService singleton for centralized logging
  - Real-time log display with timestamps
  - Pause/Resume functionality
  - Text filter/search
  - Clear all logs
  - Copy to clipboard
  - Auto-scroll to newest entries
  - Limited to 1000 messages for performance
  - Black background with white monospace text
  - Similar to Android app implementation

### Changed
- Renamed "Messages" to "GeoChat"
- Replaced "Map" with "Collections"
- Updated navigation icons to match new page names
- Changed window title from "geogram_desktop" to "Geogram"
- Updated app bar icon to collections icon

### Scripts Added
- `launch-desktop.sh`: Launch the Linux desktop app
- `launch-web.sh`: Launch the web version in Chrome
- `launch-android.sh`: Launch on Android device
- `rebuild-desktop.sh`: Clean rebuild of desktop app
- `create_icon.sh`: Generate custom app icon
- `install-linux-deps.sh`: Install required Linux dependencies

### Documentation
- `DESKTOP_ICON.md`: Documentation for app icon customization
- Updated `README.md` with current features and log functionality
- This `CHANGELOG.md` file

## Initial Release

### Features
- Basic skeleton UI with Material 3 design
- Navigation drawer and bottom navigation
- Four placeholder pages (Map, Messages, Devices, Settings)
- Light/dark theme support
- Cross-platform support (Linux, macOS, Web, Android, iOS)
