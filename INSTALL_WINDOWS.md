# Geogram Desktop - Windows Installation

## Running the Application

### Option 1: Run Directly (Portable)

You can run Geogram Desktop without installing it:

1. Extract the ZIP file to any location
2. Double-click `geogram_desktop.exe`

The application will show with the Geogram icon in your taskbar.

### Option 2: System Installation

For a proper system installation:

1. Extract the ZIP file to `C:\Program Files\Geogram Desktop\`
2. Create a shortcut to `geogram_desktop.exe` on your Desktop
3. Pin to Start Menu or Taskbar if desired

## Distribution

The Windows distribution contains:

```
geogram_desktop.exe          - Main executable
flutter_windows.dll          - Flutter engine
data/                        - Application data and resources
  icudtl.dat                 - Unicode data
  flutter_assets/            - App assets, icons, and resources
```

**Total size**: ~50-70MB

## System Requirements

- Windows 10 (version 1809) or later
- Windows 11 (recommended)
- 64-bit (x64) processor
- 4 GB RAM minimum
- 200 MB disk space

## Troubleshooting

### "The application failed to start"

Install Visual C++ Redistributable:
- Download from: https://aka.ms/vs/17/release/vc_redist.x64.exe
- Or install via Windows Update

### "flutter_windows.dll is missing"

Ensure all files from the ZIP are in the same directory as `geogram_desktop.exe`.

### "Windows protected your PC"

This appears when running unsigned executables:
1. Click "More info"
2. Click "Run anyway"

To avoid this, the executable needs to be code-signed (requires certificate).

### Application doesn't start silently

Check Windows Event Viewer:
1. Open Event Viewer (eventvwr)
2. Windows Logs → Application
3. Look for Geogram Desktop errors

## Security

### Antivirus False Positives

Some antivirus software may flag unsigned executables as suspicious. This is a false positive. The application:
- Does not contain malware
- Is built from open source code
- Can be verified by building from source

To resolve:
1. Add exception in your antivirus software
2. Or build from source yourself

### Code Signing (for developers)

To distribute without Windows SmartScreen warnings:
1. Obtain a code signing certificate
2. Sign the executable with `signtool.exe`:
   ```cmd
   signtool sign /f certificate.pfx /p password /t http://timestamp.digicert.com geogram_desktop.exe
   ```

## Creating an Installer (for developers)

### Using Inno Setup

1. Install Inno Setup: https://jrsoftware.org/isinfo.php
2. Create `installer.iss`:

```iss
[Setup]
AppName=Geogram Desktop
AppVersion=1.0.0
DefaultDirName={autopf}\Geogram Desktop
DefaultGroupName=Geogram
OutputBaseFilename=GeogramDesktopSetup
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs

[Icons]
Name: "{group}\Geogram Desktop"; Filename: "{app}\geogram_desktop.exe"
Name: "{autodesktop}\Geogram Desktop"; Filename: "{app}\geogram_desktop.exe"

[Run]
Filename: "{app}\geogram_desktop.exe"; Description: "Launch Geogram Desktop"; Flags: nowait postinstall skipifsilent
```

3. Compile with Inno Setup Compiler

### Using NSIS

1. Install NSIS: https://nsis.sourceforge.io/
2. Create `installer.nsi`:

```nsis
!include "MUI2.nsh"

Name "Geogram Desktop"
OutFile "GeogramDesktopSetup.exe"
InstallDir "$PROGRAMFILES64\Geogram Desktop"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_LANGUAGE "English"

Section "Install"
  SetOutPath "$INSTDIR"
  File /r "build\windows\x64\runner\Release\*.*"

  CreateDirectory "$SMPROGRAMS\Geogram"
  CreateShortcut "$SMPROGRAMS\Geogram\Geogram Desktop.lnk" "$INSTDIR\geogram_desktop.exe"
  CreateShortcut "$DESKTOP\Geogram Desktop.lnk" "$INSTDIR\geogram_desktop.exe"

  WriteUninstaller "$INSTDIR\Uninstall.exe"
SectionEnd

Section "Uninstall"
  Delete "$INSTDIR\*.*"
  RMDir /r "$INSTDIR"
  Delete "$SMPROGRAMS\Geogram\Geogram Desktop.lnk"
  Delete "$DESKTOP\Geogram Desktop.lnk"
  RMDir "$SMPROGRAMS\Geogram"
SectionEnd
```

3. Build with: `makensis installer.nsi`

## Uninstalling

### Portable Installation

Simply delete the application folder.

### System Installation

1. Open Settings → Apps → Installed apps
2. Find "Geogram Desktop"
3. Click "Uninstall"

Or delete the installation folder manually.

## Updates

To update:
1. Close the application
2. Replace all files with the new version
3. Start the application

Configuration and data are stored separately and won't be affected.

## Application Data Location

User data is stored in:
```
%APPDATA%\geogram-desktop\
```

This includes:
- `config.json` - User settings
- `collections.json` - Collections data
- `logs/` - Application logs
