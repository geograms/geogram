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

# Change to the geogram-desktop directory
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
            echo "Geogram Desktop CLI Launcher"
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
            echo "  status         Show app and relay status"
            echo "  relay start    Start the relay server"
            echo "  relay stop     Stop the relay server"
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
echo "  Geogram Desktop CLI Mode"
echo "=============================================="
echo ""

# Build if needed
if [ "$SKIP_BUILD" = false ]; then
    # Ensure dependencies are available - try offline first, fall back to online
    echo "Checking dependencies..."
    if ! "$DART_BIN" pub get --offline --no-example 2>/dev/null; then
        echo "Fetching dependencies online..."
        "$DART_BIN" pub get --no-example
    fi

    # Check if binary exists and is newer than source files
    NEEDS_BUILD=false

    if [ ! -f "$CLI_BINARY" ]; then
        NEEDS_BUILD=true
        echo "CLI binary not found, building..."
    else
        # Check if any source file is newer than the binary
        NEWEST_SOURCE=$(find "$SCRIPT_DIR/lib" "$SCRIPT_DIR/bin" -name "*.dart" -newer "$CLI_BINARY" 2>/dev/null | head -1)
        if [ -n "$NEWEST_SOURCE" ]; then
            NEEDS_BUILD=true
            echo "Source files changed, rebuilding..."
        fi
    fi

    if [ "$NEEDS_BUILD" = true ]; then
        echo "Generating embedded games..."
        "$DART_BIN" run bin/generate_embedded_games.dart

        echo "Compiling standalone CLI binary..."
        mkdir -p "$SCRIPT_DIR/build"
        # Compile to temp file first, then replace (avoids "Text file busy" error)
        "$DART_BIN" compile exe bin/cli.dart -o "$CLI_BINARY.tmp"
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
