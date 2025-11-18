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

- **Linux**: See [INSTALL.md](INSTALL.md)
- **Windows**: See [BUILD_WINDOWS.md](BUILD_WINDOWS.md) and [INSTALL_WINDOWS.md](INSTALL_WINDOWS.md)
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

The app includes:

- Navigation drawer and bottom navigation bar
- Five main sections:
  - **Collections**: Placeholder for managing collections
  - **GeoChat**: Placeholder for conversations
  - **Devices**: Placeholder for connected devices
  - **Log**: Full-featured logging system (see below)
  - **Settings**: Basic settings page with menu items
- Material 3 design with light/dark theme support
- Responsive layout that adapts to different screen sizes
- Custom Geogram app icon

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

## Next Steps

- Implement map integration
- Add messaging functionality
- Integrate device management
- Connect to Geogram backend services
- Add authentication
- Implement real-time updates

## Resources

- [Flutter Documentation](https://docs.flutter.dev/)
- [Material 3 Design](https://m3.material.io/)
- [Geogram Project](https://github.com/your-repo/geogram)
