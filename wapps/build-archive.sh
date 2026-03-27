#!/bin/sh
# Build all wapps in archive/ and package them as .wapp ZIP files.
#
# Usage:
#   ./build-archive.sh              # build and package all
#   ./build-archive.sh maps         # build and package one
#   ./build-archive.sh clean        # remove binaries/
#
# Output: binaries/<id>.wapp for each module (ZIP with app.wasm,
#         manifest.json, screens/, media/ at the root).
#
# Environment:
#   WASI_SDK_PATH  — path to wasi-sdk (default: ~/wasi-sdk)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARCHIVE_DIR="$SCRIPT_DIR/archive"
OUTPUT_DIR="$SCRIPT_DIR/binaries"
WASI_SDK_PATH="${WASI_SDK_PATH:-$HOME/wasi-sdk}"

export WASI_SDK_PATH

# Verify wasi-sdk
if [ ! -x "$WASI_SDK_PATH/bin/clang" ]; then
    echo "wasi-sdk not found at $WASI_SDK_PATH"
    echo "Run: ./install-wasi-sdk.sh"
    exit 1
fi

# Clean mode
if [ "${1:-}" = "clean" ]; then
    echo "Removing $OUTPUT_DIR..."
    rm -rf "$OUTPUT_DIR"
    echo "Done."
    exit 0
fi

mkdir -p "$OUTPUT_DIR"

# Build and package a single wapp directory.
build_wapp() {
    dir="$1"
    name=$(basename "$dir")

    [ -f "$dir/Makefile" ] || return 1
    [ -f "$dir/manifest.json" ] || return 1

    # Read id from manifest for the output filename
    wapp_id=$(grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' "$dir/manifest.json" \
        | head -1 | sed 's/.*"id"[[:space:]]*:[[:space:]]*"//;s/"//')
    [ -z "$wapp_id" ] && wapp_id="$name"

    echo "[$name] compiling..."
    if ! make -C "$dir" --no-print-directory 2>&1; then
        echo "[$name] FAILED to compile"
        return 1
    fi

    [ -f "$dir/app.wasm" ] || { echo "[$name] no app.wasm after build"; return 1; }

    echo "[$name] packaging $wapp_id.wapp..."
    wapp_file="$OUTPUT_DIR/$wapp_id.wapp"
    rm -f "$wapp_file"

    # ZIP from inside the wapp dir so paths are at the root
    (
        cd "$dir"
        zip -q -r "$wapp_file" \
            app.wasm \
            manifest.json \
            $([ -d screens ] && echo screens) \
            $([ -d media ] && echo media)
    )

    size=$(wc -c < "$wapp_file" | tr -d ' ')
    if [ "$size" -lt 1024 ]; then
        human="${size}B"
    else
        human="$(echo "$size" | awk '{printf "%.1fKB", $1/1024}')"
    fi
    echo "[$name] → $wapp_id.wapp ($human)"
    return 0
}

# Single module mode
if [ -n "${1:-}" ] && [ -d "$ARCHIVE_DIR/$1" ]; then
    build_wapp "$ARCHIVE_DIR/$1"
    exit $?
fi

# Build all
echo "Building all archive wapps..."
echo "  WASI_SDK_PATH=$WASI_SDK_PATH"
echo "  Output: $OUTPUT_DIR/"
echo ""

TOTAL=0
BUILT=0
FAILED=0

for dir in "$ARCHIVE_DIR"/*/; do
    [ -f "$dir/Makefile" ] || continue
    TOTAL=$((TOTAL + 1))

    if build_wapp "$dir"; then
        BUILT=$((BUILT + 1))
    else
        FAILED=$((FAILED + 1))
    fi
    echo ""
done

echo "Results: $BUILT/$TOTAL built"
[ "$FAILED" -gt 0 ] && echo "  $FAILED failed" && exit 1

# Summary
echo ""
echo "Packages:"
printf "  %-35s %s\n" "FILE" "SIZE"
printf "  %-35s %s\n" "-----------------------------------" "--------"
for wapp in "$OUTPUT_DIR"/*.wapp; do
    [ -f "$wapp" ] || continue
    fname=$(basename "$wapp")
    size=$(wc -c < "$wapp" | tr -d ' ')
    if [ "$size" -lt 1024 ]; then
        human="${size}B"
    else
        human="$(echo "$size" | awk '{printf "%.1fKB", $1/1024}')"
    fi
    printf "  %-35s %s\n" "$fname" "$human"
done
