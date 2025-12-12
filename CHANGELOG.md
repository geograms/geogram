# Geogram Desktop Changelog

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
