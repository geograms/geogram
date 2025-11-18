#!/bin/bash

# Geogram Desktop - Windows Build Script (for Windows via WSL or Git Bash)

set -e

echo "Building Geogram Desktop for Windows..."
echo ""

# Ensure Flutter is in PATH
export PATH="$PATH:$HOME/flutter/bin"

# Clean previous build
echo "Cleaning previous build..."
flutter clean

# Get dependencies
echo "Getting dependencies..."
flutter pub get

# Build Windows release
echo "Building Windows release..."
flutter build windows --release

echo ""
echo "Build complete!"
echo ""
echo "Executable location: build/windows/x64/runner/Release/geogram_desktop.exe"
echo ""
echo "To create an installer, you can use:"
echo "  - Inno Setup (https://jrsoftware.org/isinfo.php)"
echo "  - NSIS (https://nsis.sourceforge.io/)"
echo "  - WiX Toolset (https://wixtoolset.org/)"
echo ""
