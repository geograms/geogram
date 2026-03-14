#!/bin/sh
# Build all WASM modules in wasm/modules/.
#
# Usage:
#   ./build-all.sh              # build all modules
#   ./build-all.sh clean        # clean all modules
#   ./build-all.sh echo_lib     # build one module
#
# Environment:
#   WASI_SDK_PATH  — path to wasi-sdk (default: ~/wasi-sdk)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODULES_DIR="$SCRIPT_DIR/modules"
WASI_SDK_PATH="${WASI_SDK_PATH:-$HOME/wasi-sdk}"

export WASI_SDK_PATH

# Verify wasi-sdk
if [ ! -x "$WASI_SDK_PATH/bin/clang" ]; then
    echo "wasi-sdk not found at $WASI_SDK_PATH"
    echo "Run: ./install-wasi-sdk.sh"
    exit 1
fi

ACTION="${1:-build}"

# If argument is "clean", clean all modules
if [ "$ACTION" = "clean" ]; then
    echo "Cleaning all modules..."
    for dir in "$MODULES_DIR"/*/; do
        [ -f "$dir/Makefile" ] || continue
        name=$(basename "$dir")
        echo "  $name"
        make -C "$dir" clean --no-print-directory 2>/dev/null || true
    done
    echo "Done."
    exit 0
fi

# If argument is a module name, build just that one
if [ -d "$MODULES_DIR/$ACTION" ] && [ -f "$MODULES_DIR/$ACTION/Makefile" ]; then
    echo "Building $ACTION..."
    make -C "$MODULES_DIR/$ACTION" --no-print-directory
    exit 0
fi

# Otherwise build all
echo "Building all WASM modules..."
echo "  WASI_SDK_PATH=$WASI_SDK_PATH"
echo ""

TOTAL=0
BUILT=0
FAILED=0

for dir in "$MODULES_DIR"/*/; do
    [ -f "$dir/Makefile" ] || continue
    name=$(basename "$dir")
    TOTAL=$((TOTAL + 1))

    if make -C "$dir" --no-print-directory 2>&1; then
        BUILT=$((BUILT + 1))
    else
        echo "  FAILED: $name"
        FAILED=$((FAILED + 1))
    fi
done

echo ""
echo "Results: $BUILT/$TOTAL built"
[ "$FAILED" -gt 0 ] && echo "  $FAILED failed" && exit 1

# Summary table
echo ""
echo "Module sizes:"
printf "  %-25s %s\n" "MODULE" "SIZE"
printf "  %-25s %s\n" "-------------------------" "--------"
for wasm in "$MODULES_DIR"/*/*.wasm; do
    [ -f "$wasm" ] || continue
    name=$(basename "$wasm")
    size=$(wc -c < "$wasm" | tr -d ' ')
    if [ "$size" -lt 1024 ]; then
        human="${size}B"
    else
        human="$(echo "$size" | awk '{printf "%.1fKB", $1/1024}')";
    fi
    printf "  %-25s %s\n" "$name" "$human"
done
