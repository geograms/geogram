#!/bin/sh

# Geogram Desktop Launch Script
# This script sets up the Flutter environment and launches the desktop app

set -e

# Define Flutter path
FLUTTER_HOME="$HOME/flutter"
FLUTTER_BIN="$FLUTTER_HOME/bin/flutter"

# Check if Flutter is installed
if [ ! -f "$FLUTTER_BIN" ]; then
    echo "❌ Flutter not found at $FLUTTER_HOME"
    echo "Please run ./install-flutter.sh to install Flutter"
    exit 1
fi

# Check Dart SDK version (must be >= 3.10.0 as required by pubspec.yaml)
DART_VERSION=$("$FLUTTER_BIN" --version 2>&1 | sed -n 's/.*Dart \([0-9]*\.[0-9]*\).*/\1/p' | head -1)
DART_MAJOR=$(echo "$DART_VERSION" | cut -d. -f1)
DART_MINOR=$(echo "$DART_VERSION" | cut -d. -f2)

if [ "$DART_MAJOR" -lt 3 ] || ([ "$DART_MAJOR" -eq 3 ] && [ "$DART_MINOR" -lt 10 ]); then
    echo "❌ Dart version $DART_VERSION is too old"
    echo "This project requires Dart SDK ^3.10.0"
    echo "Please run ./install-flutter.sh to install the correct Flutter version (3.38.3+)"
    exit 1
fi

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Change to the geogram directory
cd "$SCRIPT_DIR"

# Native library cache directory (survives flutter clean)
NATIVE_CACHE="linux/native-cache"
FVP_CACHE="linux/fvp-cache"

# ObjectBox library version and arch
OBJECTBOX_VERSION="4.3.1"
OBJECTBOX_ARCH="x64"
OBJECTBOX_TARBALL="objectbox-linux-${OBJECTBOX_ARCH}.tar.gz"

# Function to cache objectbox download after a successful build
cache_objectbox() {
    local build_type=$1
    local src_dir="build/linux/x64/$build_type/_deps/objectbox-download-src"
    local tarball="build/linux/x64/$build_type/_deps/objectbox-download-subbuild/objectbox-download-populate-prefix/src/$OBJECTBOX_TARBALL"

    # Cache the extracted library
    if [ -d "$src_dir/lib" ]; then
        mkdir -p "$NATIVE_CACHE/objectbox"
        if [ ! -d "$NATIVE_CACHE/objectbox/lib" ]; then
            echo "📦 Caching ObjectBox library for offline builds..."
            cp -r "$src_dir/." "$NATIVE_CACHE/objectbox/"
        fi
    fi

    # Cache the tarball too (CMake FetchContent expects it)
    if [ -f "$tarball" ] && [ -s "$tarball" ]; then
        if [ ! -f "$NATIVE_CACHE/$OBJECTBOX_TARBALL" ]; then
            cp "$tarball" "$NATIVE_CACHE/$OBJECTBOX_TARBALL"
        fi
    fi
}

# Function to restore objectbox into the build dir so CMake skips the download
restore_objectbox() {
    local build_type=$1
    local src_dir="build/linux/x64/$build_type/_deps/objectbox-download-src"
    local stamp_dir="build/linux/x64/$build_type/_deps/objectbox-download-subbuild/objectbox-download-populate-prefix/src/objectbox-download-populate-stamp"
    local tarball_dst="build/linux/x64/$build_type/_deps/objectbox-download-subbuild/objectbox-download-populate-prefix/src/$OBJECTBOX_TARBALL"

    # Skip if already populated
    if [ -d "$src_dir/lib" ]; then
        return
    fi

    # Restore from cache if available
    if [ -d "$NATIVE_CACHE/objectbox/lib" ]; then
        echo "📦 Restoring ObjectBox $build_type from cache (offline)..."
        mkdir -p "$src_dir"
        cp -r "$NATIVE_CACHE/objectbox/." "$src_dir/"

        # Also restore the tarball so CMake's FetchContent considers it populated
        if [ -f "$NATIVE_CACHE/$OBJECTBOX_TARBALL" ]; then
            mkdir -p "$(dirname "$tarball_dst")"
            cp "$NATIVE_CACHE/$OBJECTBOX_TARBALL" "$tarball_dst"
        fi

        # Create stamp files so CMake thinks the download already completed
        mkdir -p "$stamp_dir"
        touch "$stamp_dir/objectbox-download-populate-download"
        touch "$stamp_dir/objectbox-download-populate-verify"
        touch "$stamp_dir/objectbox-download-populate-extract"
        touch "$stamp_dir/objectbox-download-populate-done"
    fi
}

# Function to restore fvp cache if needed
restore_fvp_if_needed() {
    local build_type=$1
    local cache_src="$FVP_CACHE/$build_type/fvp"
    local build_dst="build/linux/x64/$build_type/plugins"

    if [ -d "$cache_src" ] && [ ! -d "$build_dst/fvp" ]; then
        echo "📦 Restoring fvp $build_type build from cache..."
        mkdir -p "$build_dst"
        cp -r "$cache_src" "$build_dst/"
    fi
}

# Function to cache fvp build
cache_fvp() {
    local build_type=$1
    local build_src="build/linux/x64/$build_type/plugins/fvp"
    local cache_dst="$FVP_CACHE/$build_type"

    if [ -d "$build_src" ]; then
        mkdir -p "$cache_dst"
        rm -rf "$cache_dst/fvp"
        cp -r "$build_src" "$cache_dst/"
    fi
}

echo "🚀 Launching Geogram Desktop..."
echo "📍 Working directory: $SCRIPT_DIR"

# Kill any existing geogram processes to free up ports
if pgrep -f "geogram" > /dev/null 2>&1; then
    echo "🔄 Killing existing geogram processes..."
    pkill -f "geogram" 2>/dev/null || true
    sleep 1
fi

# Get dependencies - try offline first, fall back to online
echo "📦 Checking dependencies..."
if ! "$FLUTTER_BIN" pub get --offline 2>/dev/null; then
    echo "📡 Fetching dependencies online..."
    "$FLUTTER_BIN" pub get
fi

# Only clean if explicitly requested via --clean flag
CLEAN=false
for arg in "$@"; do
    case "$arg" in --clean) CLEAN=true ;; esac
done
if $CLEAN; then
    echo "🧹 Cleaning previous build..."
    # Cache native libs before cleaning
    cache_objectbox "debug"
    cache_objectbox "release"
    cache_fvp "debug"
    cache_fvp "release"

    "$FLUTTER_BIN" clean

    # Re-fetch dependencies after clean
    echo "📦 Re-fetching dependencies..."
    "$FLUTTER_BIN" pub get --offline 2>/dev/null || "$FLUTTER_BIN" pub get
fi

# Restore cached native libraries
restore_objectbox "debug"
restore_objectbox "release"
restore_fvp_if_needed "debug"
restore_fvp_if_needed "release"

echo ""
echo "▶️  Starting app..."

# Filter out our custom flags before passing to flutter
FLUTTER_ARGS=""
for arg in "$@"; do
    if [ "$arg" != "--clean" ]; then
        FLUTTER_ARGS="$FLUTTER_ARGS $arg"
    fi
done

# Run the app on Linux desktop
# shellcheck disable=SC2086
"$FLUTTER_BIN" run -d linux --no-pub $FLUTTER_ARGS

# Cache native libs after successful run
cache_objectbox "debug"
cache_objectbox "release"
cache_fvp "debug"
cache_fvp "release"
