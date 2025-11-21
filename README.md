# Geogram Desktop

A cross-platform desktop and mobile application for Geogram, built with Flutter.

## Supported Platforms

- **Linux** (Desktop) - Full support
- **Windows** (Desktop) - Full support (requires Windows to build, or use GitHub Actions)
- **macOS** (Desktop) - Full support
- **Web** - Full support
- **Android** - Full support
- **iOS** - Full support

## Prerequisites

- Flutter SDK (installed in ~/flutter)
- For Linux: GTK development libraries
- For Windows: Visual Studio 2022 with C++ tools
- For macOS: Xcode
- For Android: Android Studio and SDK
- For iOS: Xcode (macOS only)
- For Web: Chrome or another web browser

## Building

### Quick Start Scripts

- Linux: `./rebuild-desktop.sh` or `./launch-desktop.sh`
- Windows: `build-windows.bat` or `build-windows.sh`
- Web: `./launch-web.sh`
- Android: `./launch-android.sh`

### Detailed Build Instructions

- **Linux**: See [docs/installation/INSTALL.md](docs/installation/INSTALL.md)
- **Windows**: See [docs/build/BUILD_WINDOWS.md](docs/build/BUILD_WINDOWS.md) and [docs/installation/INSTALL_WINDOWS.md](docs/installation/INSTALL_WINDOWS.md)
- **Releases**: See [docs/build/RELEASE.md](docs/build/RELEASE.md) for creating releases
- **GitHub Actions**: Automated builds for all platforms - see `.github/workflows/`

## Running the Application

### Adding Flutter to PATH

Add Flutter to your PATH for easier access:

```bash
export PATH="$PATH:$HOME/flutter/bin"
```

To make this permanent, add it to your `~/.bashrc` or `~/.zshrc`.

### Linux Desktop

```bash
cd geogram_desktop
flutter run -d linux
```

### macOS Desktop

```bash
cd geogram_desktop
flutter run -d macos
```

### Web

```bash
cd geogram_desktop
flutter run -d chrome
```

Or to build for web deployment:

```bash
flutter build web
```

The built files will be in `build/web/`.

### Android

Connect an Android device or start an emulator, then:

```bash
cd geogram_desktop
flutter run -d android
```

### iOS

Connect an iOS device or start a simulator (macOS only), then:

```bash
cd geogram_desktop
flutter run -d ios
```

## Project Structure

```
geogram_desktop/
├── lib/
│   └── main.dart          # Main application code
├── android/               # Android-specific files
├── ios/                   # iOS-specific files
├── linux/                 # Linux-specific files
├── macos/                 # macOS-specific files
├── web/                   # Web-specific files
└── test/                  # Tests
```

## Current Features

Geogram Desktop is a fully-featured offline-first communication and data management platform:

### Core Functionality

- **Collections Management**: Browse, create, and manage collections (chat logs, forums, file storage)
  - File browser with folder navigation and file operations
  - Search functionality across collections
  - Collection metadata and configuration

- **Chat System**: Full-featured text-based communication
  - Multiple channels per collection
  - Direct messages and group chats
  - File attachments with SHA1-based deduplication
  - NOSTR key integration for message signing
  - Message deletion for admins/moderators

- **Forum System**: Threaded discussions with category organization
  - Multiple categories per forum
  - Thread creation and management
  - Post replies with metadata support
  - Admin controls (create/rename/delete categories)
  - Thread and post deletion for admins
  - File attachments with SHA1 naming

- **User Profile**: Customizable callsign and NOSTR identity
  - Profile management with callsign and NOSTR key storage
  - Secure key generation and import

- **Device Management**: Connect and manage multiple Geogram devices
  - BLE device discovery and pairing
  - Device connection status monitoring
  - Relay device connectivity (Hello protocol)

- **Logging System**: Comprehensive application logging
  - Real-time log display with timestamps
  - Pause/resume, filter, and clear functionality
  - Copy to clipboard
  - File logging to `~/Documents/geogram/log.txt`

### Technical Features

- Material 3 design with light/dark theme support
- Responsive layout for all screen sizes
- Cross-platform support (Linux, Windows, macOS, Android, iOS, Web)
- Offline-first architecture with text-based storage
- SHA1-based file deduplication

### Log Functionality

The Log page provides a comprehensive logging interface similar to the Android app:

- **Real-time log display**: View application logs with timestamps
- **Pause/Resume**: Pause log updates while investigating
- **Filter**: Search/filter logs by text
- **Clear**: Clear all log messages
- **Copy to Clipboard**: Copy all filtered logs to clipboard
- **Auto-scroll**: Automatically scrolls to newest log entries
- **Performance optimized**: Limited to last 1000 messages
- **Monospace font**: Easy-to-read log format
- **File logging**: All logs are written to `~/Documents/geogram/log.txt`

#### Reading Log Files

To read the log file from terminal:
```bash
# Show last 100 lines (default)
./read-log.sh

# Show last 50 lines
./read-log.sh -n 50

# Follow log in real-time
./read-log.sh -f
```

## Development

### Hot Reload

While the app is running, you can make changes to the code and press `r` in the terminal to hot reload, or `R` to hot restart.

### Checking Platform Support

```bash
flutter devices
```

### Running Tests

```bash
flutter test
```

## Roadmap

### Completed

- ✅ Collections management system
- ✅ Chat functionality with channels and DMs
- ✅ Forum system with threading
- ✅ File attachments and management
- ✅ NOSTR key integration
- ✅ User profiles with callsigns
- ✅ Device connectivity (BLE and relay)
- ✅ Admin/moderator controls

### In Progress

- Map integration
- Enhanced search capabilities
- Real-time sync between devices

### Planned

- Video/audio file support
- Location tagging and map views
- Enhanced NOSTR signature verification
- Multi-device sync improvements
- Export/import functionality

## Documentation

### Installation & Building

- [Linux Installation](docs/installation/INSTALL.md)
- [Windows Installation](docs/installation/INSTALL_WINDOWS.md)
- [Windows Build Guide](docs/build/BUILD_WINDOWS.md)
- [Release Process](docs/build/RELEASE.md)

### Features & Implementation

- [Forum Format Specification](docs/features/FORUM_FORMAT.md)
- [Profile System](docs/features/PROFILE_IMPLEMENTATION.md)
- [Search Functionality](docs/features/SEARCH_IMPLEMENTATION.md)
- [NOSTR Keys Integration](docs/features/NOSTR_KEYS_IMPLEMENTATION.md)
- [Relay Hello Protocol](docs/features/RELAY_HELLO_IMPLEMENTATION.md)
- [Collapsible Folders](docs/features/COLLAPSIBLE_FOLDERS.md)
- [Collections File Management](docs/features/COLLECTIONS_FILE_MANAGEMENT.md)
- [File Browser Enhancements](docs/features/FILE_BROWSER_ENHANCEMENTS.md)

### Development Notes

- [Bug Fixes](docs/development/BUGFIX.md)
- [Profile Bug Fixes](docs/development/PROFILE_BUGFIX.md)
- [File Browser Updates](docs/development/FILE_BROWSER_UPDATES.md)
- [Folder Rename on Title Change](docs/development/FOLDER_RENAME_ON_TITLE_CHANGE.md)
- [Summary Updates](docs/development/SUMMARY_UPDATES.md)
- [Desktop Icon](docs/development/DESKTOP_ICON.md)
- [Windows Support](docs/development/WINDOWS_SUPPORT.md)
- [Hello Protocol Testing](docs/development/TEST_HELLO.md)

## Resources

- [Flutter Documentation](https://docs.flutter.dev/)
- [Material 3 Design](https://m3.material.io/)
- [Geogram Project](https://github.com/your-repo/geogram)
