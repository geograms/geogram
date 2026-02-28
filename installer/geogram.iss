; Geogram — Inno Setup Script
; Builds a per-user installer EXE with Full and Portable modes.
; Compile: iscc installer\geogram.iss
;   (version is auto-read from pubspec.yaml; override with /DMyAppVersion=x.y.z)

#ifndef MyAppVersion
  ; Auto-read version from pubspec.yaml so it stays in sync
  #define MyAppVersion "0.0.0"
  #define _PubHandle FileOpen(SourcePath + "..\pubspec.yaml")
  #if _PubHandle
    #sub _ParseLine
      #define private _L FileRead(_PubHandle)
      #if Pos("version:", _L) == 1
        #define private _V Trim(Copy(_L, 9))
        #if Pos("+", _V) > 0
          #define public MyAppVersion Copy(_V, 1, Pos("+", _V) - 1)
        #else
          #define public MyAppVersion _V
        #endif
      #endif
    #endsub
    #for {0; !FileEof(_PubHandle); 0} _ParseLine
    #expr FileClose(_PubHandle)
  #endif
#endif

#pragma message "Building installer for version " + MyAppVersion

#define MyAppName "Geogram"
#define MyAppExeName "geogram.exe"
#define MyAppPublisher "Geogram"
#define MyAppURL "https://github.com/geograms/geogram"

[Setup]
AppId={{B7E4F9A2-3C1D-4A8E-9F6B-2D5E8C7A1F03}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={localappdata}\{#MyAppName}
DefaultGroupName={#MyAppName}
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=..\build\installer
OutputBaseFilename=geogram-windows-x64-setup
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2/ultra64
SolidCompression=yes
LZMAUseSeparateProcess=yes
DisableProgramGroupPage=yes
DisableDirPage=no
CloseApplications=force
RestartApplications=no
CreateUninstallRegKey=not IsPortableMode
Uninstallable=not IsPortableMode
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Types]
Name: "full"; Description: "Full installation (recommended)"
Name: "portable"; Description: "Portable — extract files only, no shortcuts or registry"

[Components]
Name: "main"; Description: "Geogram application files"; Types: full portable; Flags: fixed
Name: "shortcuts"; Description: "Start Menu and optional Desktop shortcuts"; Types: full

[Tasks]
Name: "desktopicon"; Description: "Create a &Desktop shortcut"; Components: shortcuts; Flags: unchecked

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; \
  Flags: ignoreversion recursesubdirs createallsubdirs
; Portable marker — only written in portable mode
Source: "..\installer\portable.marker"; DestDir: "{app}"; \
  Flags: ignoreversion; Check: IsPortableMode

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Components: shortcuts
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"; Components: shortcuts
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; \
  ValueName: "{#MyAppName}"; ValueType: string; ValueData: """{app}\{#MyAppExeName}"" --minimized"; \
  Flags: uninsdeletevalue; Components: shortcuts

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; \
  Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Code]
function IsPortableMode: Boolean;
begin
  Result := WizardSetupType(False) = 'portable';
end;
