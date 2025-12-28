# Geogram Desktop Changelog

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
