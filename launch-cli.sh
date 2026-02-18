#!/bin/bash

# Geogram Desktop CLI Launch Script
# This script builds and launches the standalone CLI version
# Uses dart compile exe for pure Dart CLI (no Flutter UI)

set -e

# Define Flutter path (we use its Dart SDK)
FLUTTER_HOME="$HOME/flutter"
FLUTTER_BIN="$FLUTTER_HOME/bin/flutter"
DART_BIN="$FLUTTER_HOME/bin/dart"

# Check if Flutter/Dart is installed
if [ ! -f "$DART_BIN" ]; then
    echo "Error: Dart not found at $FLUTTER_HOME"
    echo "Please run ./install-flutter.sh to install Flutter"
    exit 1
fi

# Check Dart SDK version (must be >= 3.10.0 as required by pubspec.yaml)
DART_VERSION=$("$DART_BIN" --version 2>&1 | grep -oP 'Dart SDK version: \K[0-9]+\.[0-9]+' | head -1)
DART_MAJOR=$(echo "$DART_VERSION" | cut -d. -f1)
DART_MINOR=$(echo "$DART_VERSION" | cut -d. -f2)

if [ "$DART_MAJOR" -lt 3 ] || ([ "$DART_MAJOR" -eq 3 ] && [ "$DART_MINOR" -lt 10 ]); then
    echo "Error: Dart version $DART_VERSION is too old"
    echo "This project requires Dart SDK ^3.10.0"
    echo "Please run ./install-flutter.sh to install the correct Flutter version (3.38.3+)"
    exit 1
fi

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Change to the geogram directory
cd "$SCRIPT_DIR"

# CLI binary path (standalone Dart, not Flutter)
CLI_BINARY="$SCRIPT_DIR/build/geogram-cli"

# Parse arguments
BUILD_ONLY=false
SKIP_BUILD=false
CLI_ARGS=()
for arg in "$@"; do
    case $arg in
        --build-only)
            BUILD_ONLY=true
            ;;
        --skip-build)
            SKIP_BUILD=true
            ;;
        --help|-h)
            echo "Geogram CLI Launcher"
            echo ""
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --build-only   Build only, don't launch"
            echo "  --skip-build   Skip build, use existing binary"
            echo "  --help, -h     Show this help message"
            echo ""
            echo "CLI Commands (once launched):"
            echo "  help           Show available commands"
            echo "  status         Show app and station status"
            echo "  station start    Start the station server"
            echo "  station stop     Stop the station server"
            echo "  profile list   List all profiles"
            echo "  quit           Exit the CLI"
            exit 0
            ;;
        *)
            CLI_ARGS+=("$arg")
            ;;
    esac
done

echo "=============================================="
echo "  Geogram CLI Mode"
echo "=============================================="
echo ""

# Build if needed
# Use the geogram-cli subdirectory which has its own pubspec.yaml
# without native build hooks (dart compile exe doesn't support hooks)
CLI_PROJECT_DIR="$SCRIPT_DIR/geogram-cli"

if [ "$SKIP_BUILD" = false ]; then
    # Ensure dependencies are available - try offline first, fall back to online
    echo "Checking dependencies..."
    pushd "$CLI_PROJECT_DIR" > /dev/null
    if ! "$DART_BIN" pub get --offline --no-example 2>/dev/null; then
        echo "Fetching dependencies online..."
        "$DART_BIN" pub get --no-example
    fi
    popd > /dev/null

    # Check if binary exists and is newer than source files
    NEEDS_BUILD=false

    if [ ! -f "$CLI_BINARY" ]; then
        NEEDS_BUILD=true
        echo "CLI binary not found, building..."
    else
        # Check if any source file is newer than the binary
        NEWEST_SOURCE=$(find "$SCRIPT_DIR/lib" "$SCRIPT_DIR/bin" "$CLI_PROJECT_DIR/bin" -name "*.dart" -newer "$CLI_BINARY" 2>/dev/null | head -1)
        NEWEST_THEME=$(find "$SCRIPT_DIR/themes" \( -name "*.html" -o -name "*.css" \) -newer "$CLI_BINARY" 2>/dev/null | head -1)
        if [ -n "$NEWEST_SOURCE" ] || [ -n "$NEWEST_THEME" ]; then
            NEEDS_BUILD=true
            echo "Source files changed, rebuilding..."
        fi
    fi

    if [ "$NEEDS_BUILD" = true ]; then
        echo "Generating embedded games..."
        pushd "$SCRIPT_DIR" > /dev/null
        "$DART_BIN" run bin/generate_embedded_games.dart
        popd > /dev/null

        echo "Generating embedded themes..."
        pushd "$SCRIPT_DIR" > /dev/null
        "$DART_BIN" run bin/generate_embedded_themes.dart
        popd > /dev/null

        echo "Compiling standalone CLI binary..."
        mkdir -p "$SCRIPT_DIR/build"
        # Compile from geogram-cli/ subdirectory (no build hooks)
        # Temp file first to avoid "Text file busy" error
        pushd "$CLI_PROJECT_DIR" > /dev/null
        "$DART_BIN" compile exe bin/cli.dart -o "$CLI_BINARY.tmp"
        popd > /dev/null
        mv -f "$CLI_BINARY.tmp" "$CLI_BINARY"
        echo ""
        echo "Build completed."
    else
        echo "CLI binary is up to date, skipping build."
    fi
fi

if [ "$BUILD_ONLY" = true ]; then
    echo ""
    echo "Build complete. CLI binary located at:"
    echo "  $CLI_BINARY"
    echo ""
    echo "To run CLI mode:"
    echo "  $CLI_BINARY"
    exit 0
fi

# Check if binary exists
if [ ! -f "$CLI_BINARY" ]; then
    echo "Error: CLI binary not found at $CLI_BINARY"
    echo "Run without --skip-build to build first."
    exit 1
fi

echo ""
echo "Launching CLI mode..."
echo "----------------------------------------------"
echo ""

# Launch the CLI
exec "$CLI_BINARY" "${CLI_ARGS[@]}"
