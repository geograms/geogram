# Building Geogram Desktop for Windows

## Important Notes

**Flutter does not officially support cross-compiling Windows applications from Linux.** You need a Windows machine with Visual Studio to build Windows executables.

## Prerequisites (Windows)

1. **Flutter SDK** installed (https://docs.flutter.dev/get-started/install/windows)
2. **Visual Studio 2022** or later with:
   - "Desktop development with C++" workload
   - Windows 10 SDK
3. **Git for Windows** (optional, for running bash scripts)

## Building on Windows

### Option 1: Using the Batch Script

Double-click `build-windows.bat` or run from Command Prompt:

```cmd
build-windows.bat
```

### Option 2: Using PowerShell/Bash Script

From PowerShell, Git Bash, or WSL:

```bash
chmod +x build-windows.sh
./build-windows.sh
```

### Option 3: Manual Build

```cmd
REM Clean previous build
flutter clean

REM Get dependencies
flutter pub get

REM Build release
flutter build windows --release
```

The executable will be at: `build\windows\x64\runner\Release\geogram_desktop.exe`

## Building from Linux (Experimental)

Unfortunately, **cross-compiling Windows apps from Linux is not officially supported** by Flutter. The Windows build requires:
- Visual Studio C++ compiler
- Windows SDK
- CMake configured for Windows

### Alternatives for Linux Developers

1. **Use GitHub Actions** (recommended)
   - Push code to GitHub
   - GitHub Actions will build Windows binaries automatically
   - See `.github/workflows/build-windows.yml`

2. **Use a Windows VM**
   - VirtualBox, VMware, or QEMU
   - Install Windows and build tools
   - Run build scripts inside VM

3. **Use Wine + MinGW (experimental, not recommended)**
   - Install mingw-w64: `sudo apt install mingw-w64`
   - This method is unreliable and not officially supported
   - May work for simple apps but likely to fail

4. **Remote Windows Machine**
   - Use SSH or RDP to connect to a Windows build server
   - Run build scripts remotely

## Creating an Installer

After building, create a Windows installer using:

### Inno Setup (Recommended)

1. Download from https://jrsoftware.org/isinfo.php
2. Create an `.iss` script file
3. Package the `build\windows\x64\runner\Release\` directory

### NSIS

1. Download from https://nsis.sourceforge.io/
2. Create an `.nsi` script
3. Build installer with `makensis`

### WiX Toolset

1. Download from https://wixtoolset.org/
2. Create `.wxs` XML files
3. Build MSI installer

## Distribution

The complete Windows distribution includes:

```
geogram_desktop.exe          - Main executable (5-10 MB)
flutter_windows.dll          - Flutter engine
data/                        - Application resources
  icudtl.dat                 - Unicode data
  flutter_assets/            - App assets
```

**Total size**: ~50-70 MB

## Troubleshooting

### "CMake not found"
Install Visual Studio with C++ tools or standalone CMake.

### "Windows SDK not found"
Install Windows 10/11 SDK via Visual Studio Installer.

### "flutter_windows.dll not found"
The DLL must be in the same directory as the .exe file.

### Build fails with C++ errors
Ensure Visual Studio 2022 or later is installed with C++ workload.

## GitHub Actions (Automated)

We provide a GitHub Actions workflow that automatically builds Windows releases:

- Triggers on pushes to `main` branch and tags
- Builds Windows release bundle
- Creates artifacts/releases
- No Windows machine needed for development!

See `.github/workflows/build-windows.yml` for configuration.

## Resources

- [Flutter Windows Desktop Support](https://docs.flutter.dev/platform-integration/windows/building)
- [Visual Studio Downloads](https://visualstudio.microsoft.com/downloads/)
- [Flutter Desktop Embedding](https://github.com/flutter/flutter/wiki/Desktop-shells)
