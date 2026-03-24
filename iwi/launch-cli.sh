#!/bin/sh
# Geogram Wapp CLI Launcher
#
# Usage: ./launch-cli.sh <wapp-name>
# Example: ./launch-cli.sh terminal
#
# Loads the named wapp from wapps/archive/<name>/ and runs it
# interactively in the terminal via libwasm_bridge.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ARCHIVE_DIR="$REPO_ROOT/wapps/archive"
BRIDGE_DIR="$REPO_ROOT/wasm_bridge"
DART_BIN="$HOME/flutter/bin/dart"

# ── Argument check ────────────────────────────────────────────────────

if [ -z "$1" ]; then
    echo "Usage: $(basename "$0") <wapp-name>"
    echo ""
    echo "Available wapps:"
    for dir in "$ARCHIVE_DIR"/*/; do
        [ -f "$dir/manifest.json" ] || continue
        name=$(basename "$dir")
        desc=$(grep '"description"' "$dir/manifest.json" 2>/dev/null \
            | head -1 | sed 's/.*: *"\(.*\)".*/\1/')
        printf "  %-16s %s\n" "$name" "$desc"
    done
    exit 1
fi

WAPP_NAME="$1"
WAPP_DIR="$ARCHIVE_DIR/$WAPP_NAME"

if [ ! -d "$WAPP_DIR" ]; then
    echo "Error: wapp '$WAPP_NAME' not found in $ARCHIVE_DIR/"
    exit 1
fi

if [ ! -f "$WAPP_DIR/app.wasm" ]; then
    echo "Error: $WAPP_DIR/app.wasm not found"
    echo "Build it with: cd $WAPP_DIR && make"
    exit 1
fi

# ── Check Dart SDK ────────────────────────────────────────────────────

if [ ! -f "$DART_BIN" ]; then
    # Try system dart
    DART_BIN="$(which dart 2>/dev/null || true)"
    if [ -z "$DART_BIN" ]; then
        echo "Error: Dart SDK not found"
        echo "Install Flutter or add dart to PATH"
        exit 1
    fi
fi

# ── Build wasm_bridge if needed ───────────────────────────────────────

LIB_EXT="so"
case "$(uname -s)" in
    Darwin*) LIB_EXT="dylib" ;;
    MINGW*|MSYS*|CYGWIN*) LIB_EXT="dll" ;;
esac

BRIDGE_LIB="$BRIDGE_DIR/target/release/libwasm_bridge.$LIB_EXT"

if [ ! -f "$BRIDGE_LIB" ]; then
    echo "Building wasm_bridge (first run)..."
    (cd "$BRIDGE_DIR" && cargo build --release)
    if [ ! -f "$BRIDGE_LIB" ]; then
        echo "Error: Failed to build libwasm_bridge.$LIB_EXT"
        exit 1
    fi
fi

# ── Get dependencies ──────────────────────────────────────────────────

cd "$SCRIPT_DIR"
"$DART_BIN" pub get --offline 2>/dev/null || "$DART_BIN" pub get

# ── Run ───────────────────────────────────────────────────────────────

# Suppress Rust tracing noise; set RUST_LOG=info to see bridge logs
export RUST_LOG="${RUST_LOG:-warn}"

exec "$DART_BIN" run bin/wapp_cli.dart "$WAPP_DIR"
