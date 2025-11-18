# Windows Support Implementation Summary

This document summarizes the Windows platform support added to Geogram Desktop.

## What Was Done

### 1. Platform Files Created

Flutter generated the Windows platform code:

```
windows/
├── CMakeLists.txt                    - Build configuration
├── flutter/                          - Flutter engine integration
│   ├── CMakeLists.txt
│   ├── generated_plugin_registrant.cc
│   ├── generated_plugin_registrant.h
│   └── generated_plugins.cmake
└── runner/                           - Windows application code
    ├── CMakeLists.txt
    ├── flutter_window.cpp/.h         - Flutter window implementation
    ├── main.cpp                      - Application entry point
    ├── win32_window.cpp/.h           - Win32 window wrapper
    ├── utils.cpp/.h                  - Utility functions
    ├── Runner.rc                     - Windows resources
    ├── runner.exe.manifest           - Application manifest
    ├── resource.h                    - Resource definitions
    └── resources/
        └── app_icon.ico              - Application icon
```

### 2. Build Scripts Created

**For Windows users:**
- `build-windows.bat` - Windows batch script for Command Prompt
- `build-windows.sh` - Bash script for Git Bash/WSL/PowerShell

Both scripts:
- Clean previous builds
- Get dependencies
- Build Windows release
- Show output location

### 3. Documentation Created

**BUILD_WINDOWS.md**
- Prerequisites (Visual Studio, Windows SDK)
- Build instructions for Windows
- Explanation of cross-compilation limitations from Linux
- Alternative approaches (GitHub Actions, VM, remote build)
- Installer creation guide (Inno Setup, NSIS, WiX)
- Troubleshooting guide

**INSTALL_WINDOWS.md**
- Installation instructions for end users
- Portable vs system installation
- System requirements
- Troubleshooting (missing DLLs, SmartScreen warnings, antivirus)
- Code signing information
- Installer creation examples
- Data storage locations

### 4. GitHub Actions Workflows

**build-windows.yml**
- Builds Windows releases automatically on push
- Uses windows-latest runner with Visual Studio
- Creates ZIP archives
- Uploads artifacts
- Creates GitHub releases on tags

**build-all-platforms.yml**
- Builds for Linux, Windows, macOS, and Web
- Parallel builds on different runners
- Creates multi-platform releases
- No local Windows machine needed!

### 5. README Updates

Updated main README.md to:
- List Windows as supported platform
- Add prerequisites for Windows
- Link to build and install documentation
- Explain GitHub Actions automated builds

## Cross-Compilation Limitations

### Why Can't We Build Windows Apps from Linux?

Flutter Windows apps require:
1. **Visual Studio C++ compiler** (MSVC)
2. **Windows SDK**
3. **Win32 API headers**
4. **CMake configured for Windows targets**

These tools are Windows-specific and don't run on Linux.

### Attempted Solutions

❌ **MinGW cross-compilation**
- MinGW provides GCC for Windows but lacks MSVC compatibility
- Flutter requires MSVC-specific features
- Windows SDK not available for Linux

❌ **Wine + Windows toolchain**
- Wine can run some Windows tools
- Visual Studio doesn't work reliably under Wine
- Build process is complex and error-prone

✅ **GitHub Actions** (RECOMMENDED)
- Uses real Windows runners
- Automatic builds on push
- No Windows machine needed for development
- Professional and reliable

✅ **Windows VM**
- VirtualBox, VMware, or QEMU
- Install Windows + Visual Studio
- Run build scripts inside VM
- Requires Windows license

✅ **Remote Windows machine**
- SSH or RDP to Windows build server
- Cloud services (AWS, Azure, DigitalOcean)
- Run builds remotely

## How to Build Windows Releases

### Option 1: GitHub Actions (Easiest)

1. Push code to GitHub:
   ```bash
   git push origin main
   ```

2. Wait for GitHub Actions to complete (~5-10 minutes)

3. Download artifacts from GitHub Actions page

4. For releases, create a tag:
   ```bash
   git tag v1.0.0
   git push origin v1.0.0
   ```

### Option 2: On Windows

1. Install prerequisites:
   - Visual Studio 2022 with C++ tools
   - Flutter SDK

2. Run build script:
   ```cmd
   build-windows.bat
   ```

3. Find executable at:
   ```
   build\windows\x64\runner\Release\geogram_desktop.exe
   ```

### Option 3: Windows VM

1. Create Windows 10/11 VM (VirtualBox, VMware)
2. Install Visual Studio + Flutter
3. Copy project to VM
4. Run `build-windows.bat`
5. Copy built files back to host

## Distribution

### Portable Distribution

Just ZIP the entire `Release` folder:
```
geogram_desktop.exe
flutter_windows.dll
data/
  icudtl.dat
  flutter_assets/
```

Users extract and run `geogram_desktop.exe`.

### Installer Distribution

Use Inno Setup or NSIS to create proper installers:
- Start menu shortcuts
- Desktop icons
- Uninstaller
- File associations
- Registry entries

See `BUILD_WINDOWS.md` for examples.

## Testing

### On Windows

Run the executable directly to test.

### On Linux (limited)

No way to test Windows executables on Linux without:
- Windows VM
- Wine (not recommended for Flutter apps)
- Remote Windows machine

**Recommendation**: Use GitHub Actions for automated testing.

## Configuration

### Application Icon

The Windows icon is at: `windows/runner/resources/app_icon.ico`

Flutter auto-generated a default icon. To replace:
1. Create/convert PNG to ICO format
2. Include multiple sizes: 16x16, 32x32, 48x48, 256x256
3. Replace `app_icon.ico`
4. Rebuild

### Version Information

Edit `windows/runner/Runner.rc` for:
- Version number
- Company name
- Copyright
- Product name
- File description

### Application Manifest

`runner.exe.manifest` controls:
- DPI awareness
- Windows version compatibility
- UAC requirements
- Theme support

## Future Improvements

1. **Custom installer**
   - Create Inno Setup/NSIS scripts
   - Add to repository
   - Automate in GitHub Actions

2. **Code signing**
   - Obtain code signing certificate
   - Sign executables in CI/CD
   - Eliminate SmartScreen warnings

3. **Windows Store**
   - Package as MSIX
   - Submit to Microsoft Store
   - Automatic updates

4. **Chocolatey package**
   - Create Chocolatey package
   - Publish to community repository
   - Easy installation: `choco install geogram-desktop`

5. **Auto-update mechanism**
   - Check for updates on launch
   - Download and install updates
   - Notify users of new versions

## Resources

- [Flutter Windows Documentation](https://docs.flutter.dev/platform-integration/windows/building)
- [Visual Studio Downloads](https://visualstudio.microsoft.com/downloads/)
- [Inno Setup](https://jrsoftware.org/isinfo.php)
- [NSIS](https://nsis.sourceforge.io/)
- [GitHub Actions Windows Runners](https://docs.github.com/en/actions/using-github-hosted-runners/about-github-hosted-runners)
- [Code Signing Guide](https://docs.microsoft.com/en-us/windows/win32/seccrypto/cryptography-tools)
