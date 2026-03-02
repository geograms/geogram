#!/bin/bash
# =============================================================================
# Geogram ESP32 Firmware Upload
# Builds firmware via build.sh, then flashes the selected target
# Usage: ./upload.sh [-e ENV]   (non-interactive, specific target)
#        ./upload.sh            (interactive menu — asks once, builds + flashes)
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Find PlatformIO CLI
if command -v pio &>/dev/null; then
    PIO="pio"
elif [ -x "$HOME/.platformio/penv/bin/pio" ]; then
    PIO="$HOME/.platformio/penv/bin/pio"
else
    echo "Error: PlatformIO (pio) not found."
    echo "Install it from https://platformio.org/install/cli"
    exit 1
fi

# Parse -e ENV from arguments
ENV=""
EXTRA_ARGS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --env|-e)
            shift
            ENV="$1"
            shift
            ;;
        *)
            EXTRA_ARGS+=("$1")
            shift
            ;;
    esac
done

# If no -e given, ask the user once and reuse for both build and flash
if [ -z "$ENV" ]; then
    declare -A TARGETS
    TARGETS=(
        [1]="esp32s3_epaper_1in54|ESP32-S3 ePaper 1.54\" (Waveshare)"
        [2]="esp32_generic|ESP32 Generic (no display)"
        [3]="esp32c3_mini|ESP32-C3 Mini"
        [4]="kv4p|KV4P-HT (SA818 radio)"
        [5]="heltec_v1|Heltec WiFi LoRa 32 V1"
        [6]="heltec_v2|Heltec WiFi LoRa 32 V2"
        [7]="heltec_v3|Heltec WiFi LoRa 32 V3"
    )

    echo ""
    echo "================================================"
    echo "  Geogram ESP32 Build + Flash"
    echo "================================================"
    echo ""
    echo "Available targets:"
    echo ""
    for i in $(seq 1 ${#TARGETS[@]}); do
        IFS='|' read -r env name <<< "${TARGETS[$i]}"
        printf "  %d) %s\n" "$i" "$name"
    done
    echo "  q) Quit"
    echo ""
    read -rp "Select target [1-${#TARGETS[@]}/q]: " choice

    case $choice in
        [1-7])
            IFS='|' read -r ENV name <<< "${TARGETS[$choice]}"
            ;;
        q|Q)
            echo "Bye."
            exit 0
            ;;
        *)
            echo "Invalid selection: $choice"
            exit 1
            ;;
    esac
fi

# Step 1: Build
echo ""
echo "=== Step 1: Build firmware ($ENV) ==="
echo ""
"$SCRIPT_DIR/build.sh" -e "$ENV" "${EXTRA_ARGS[@]}"

# Step 2: Flash
FIRMWARE=".pio/build/${ENV}/firmware.bin"
if [ ! -f "$FIRMWARE" ]; then
    echo "Error: Firmware not found at $FIRMWARE"
    echo "Did the build succeed for environment '$ENV'?"
    exit 1
fi

echo ""
echo "=== Step 2: Flash firmware ($ENV) ==="
echo ""
$PIO run -e "$ENV" --target upload

echo ""
echo "Upload complete!"
