#!/bin/bash
# =============================================================================
# Geogram ESP32 Firmware Upload
# Builds firmware via build.sh, then flashes the selected target
# Usage: ./upload.sh [-e ENV]   (non-interactive, specific target)
#        ./upload.sh            (interactive menu)
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

# Pass all arguments through to build.sh
echo "=== Step 1: Build firmware ==="
"$SCRIPT_DIR/build.sh" "$@"

# Determine which environment was built so we can flash it
# Parse args the same way build.sh does to find the target
ENV=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --env|-e)
            shift
            ENV="$1"
            shift
            ;;
        *)
            shift
            ;;
    esac
done

if [ -z "$ENV" ]; then
    # Interactive mode — ask which target to flash
    declare -A TARGETS
    TARGETS=(
        [1]="esp32s3_epaper_1in54|ESP32-S3 ePaper 1.54\""
        [2]="esp32_generic|ESP32 Generic"
        [3]="esp32c3_mini|ESP32-C3 Mini"
        [4]="kv4p|KV4P-HT (SA818 radio)"
        [5]="heltec_v1|Heltec WiFi LoRa 32 V1"
        [6]="heltec_v2|Heltec WiFi LoRa 32 V2"
        [7]="heltec_v3|Heltec WiFi LoRa 32 V3"
    )

    echo ""
    echo "=== Step 2: Flash firmware ==="
    echo ""
    echo "Which target did you just build?"
    echo ""
    for i in $(seq 1 ${#TARGETS[@]}); do
        IFS='|' read -r env name <<< "${TARGETS[$i]}"
        # Only show targets that have a built firmware
        if [ -f ".pio/build/${env}/firmware.bin" ]; then
            printf "  %d) %s  [firmware ready]\n" "$i" "$name"
        else
            printf "  %d) %s  [not built]\n" "$i" "$name"
        fi
    done
    echo "  q) Quit (skip flash)"
    echo ""
    read -rp "Select target to flash [1-${#TARGETS[@]}/q]: " choice

    case $choice in
        [1-7])
            IFS='|' read -r ENV name <<< "${TARGETS[$choice]}"
            ;;
        q|Q)
            echo "Build done, skipping flash."
            exit 0
            ;;
        *)
            echo "Invalid selection: $choice"
            exit 1
            ;;
    esac
fi

FIRMWARE=".pio/build/${ENV}/firmware.bin"
if [ ! -f "$FIRMWARE" ]; then
    echo "Error: Firmware not found at $FIRMWARE"
    echo "Did the build succeed for environment '$ENV'?"
    exit 1
fi

echo ""
echo "=== Step 2: Flash firmware ==="
echo "  Environment: $ENV"
echo "  Firmware: $FIRMWARE"
echo ""

$PIO run -e "$ENV" --target upload

echo ""
echo "Upload complete!"
