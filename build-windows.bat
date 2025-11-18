@echo off
REM Geogram Desktop - Windows Build Script
REM This script should be run on Windows with Visual Studio installed

echo Building Geogram Desktop for Windows...
echo.

REM Add Flutter to PATH if not already there
set PATH=%PATH%;%USERPROFILE%\flutter\bin

REM Clean previous build
echo Cleaning previous build...
flutter clean

REM Get dependencies
echo Getting dependencies...
flutter pub get

REM Build Windows release
echo Building Windows release...
flutter build windows --release

echo.
echo Build complete!
echo.
echo Executable location: build\windows\x64\runner\Release\geogram_desktop.exe
echo.
echo To create an installer, you can use:
echo   - Inno Setup (https://jrsoftware.org/isinfo.php)
echo   - NSIS (https://nsis.sourceforge.io/)
echo   - WiX Toolset (https://wixtoolset.org/)
echo.
pause
