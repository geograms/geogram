# Geogram Desktop Changelog

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
