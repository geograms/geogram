#!/bin/bash
# =============================================================================
# Geogram ESP32 Firmware Builder
# Interactive menu to select which firmware target to build
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

# Available firmware targets
declare -A TARGETS
TARGETS=(
    [1]="esp32s3_epaper_1in54|ESP32-S3 ePaper 1.54\" (Waveshare)|esp32s3|ePaper, RTC, humidity, PSRAM, SD card"
    [2]="esp32_generic|ESP32 Generic (no display)|esp32|Skeleton / barebones"
    [3]="esp32c3_mini|ESP32-C3 Mini|esp32c3|WiFi + BLE only, minimal"
    [4]="kv4p|KV4P-HT (SA818 radio)|esp32|SA818 radio module, no display"
    [5]="heltec_v1|Heltec WiFi LoRa 32 V1|esp32|SX1276 LoRa + SSD1306 OLED"
    [6]="heltec_v2|Heltec WiFi LoRa 32 V2|esp32|SX1276 LoRa + SSD1306 OLED"
    [7]="heltec_v3|Heltec WiFi LoRa 32 V3|esp32s3|SX1262 LoRa + SSD1306 OLED"
)

ACTION="build"

print_header() {
    echo ""
    echo "================================================"
    echo "  Geogram ESP32 Firmware Builder"
    echo "================================================"
    echo ""
}

print_menu() {
    echo "Available firmware targets:"
    echo ""
    for i in $(seq 1 ${#TARGETS[@]}); do
        IFS='|' read -r env name mcu features <<< "${TARGETS[$i]}"
        printf "  %d) %-35s [%s] %s\n" "$i" "$name" "$mcu" "$features"
    done
    echo ""
    echo "  a) Build ALL targets"
    echo "  q) Quit"
    echo ""
}

build_target() {
    local env="$1"
    local name="$2"

    echo ""
    echo "------------------------------------------------"
    echo "  Building: $name"
    echo "  Environment: $env"
    echo "------------------------------------------------"
    echo ""

    if [ "$ACTION" = "upload" ]; then
        $PIO run -e "$env" --target upload
    elif [ "$ACTION" = "clean" ]; then
        $PIO run -e "$env" --target clean
    else
        $PIO run -e "$env"
    fi
}

build_all() {
    echo ""
    echo "Building ALL firmware targets..."
    for i in $(seq 1 ${#TARGETS[@]}); do
        IFS='|' read -r env name mcu features <<< "${TARGETS[$i]}"
        build_target "$env" "$name"
    done
    echo ""
    echo "All builds complete."
}

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --upload|-u)
            ACTION="upload"
            shift
            ;;
        --clean|-c)
            ACTION="clean"
            shift
            ;;
        --all|-a)
            print_header
            build_all
            exit 0
            ;;
        --env|-e)
            # Direct environment build (non-interactive)
            shift
            if [ -z "$1" ]; then
                echo "Error: --env requires an environment name"
                exit 1
            fi
            print_header
            build_target "$1" "$1"
            exit 0
            ;;
        --list|-l)
            print_header
            print_menu
            exit 0
            ;;
        --help|-h)
            print_header
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --upload, -u     Build and upload firmware"
            echo "  --clean, -c      Clean build files"
            echo "  --all, -a        Build all targets"
            echo "  --env, -e NAME   Build specific environment (non-interactive)"
            echo "  --list, -l       List available targets"
            echo "  --help, -h       Show this help"
            echo ""
            echo "Without options, shows interactive menu."
            exit 0
            ;;
        *)
            echo "Unknown option: $1 (use --help for usage)"
            exit 1
            ;;
    esac
done

# Interactive mode
print_header

if [ "$ACTION" = "upload" ]; then
    echo "  Mode: BUILD + UPLOAD"
elif [ "$ACTION" = "clean" ]; then
    echo "  Mode: CLEAN"
else
    echo "  Mode: BUILD"
fi

print_menu

read -rp "Select target [1-${#TARGETS[@]}/a/q]: " choice

case $choice in
    [1-7])
        IFS='|' read -r env name mcu features <<< "${TARGETS[$choice]}"
        build_target "$env" "$name"
        ;;
    a|A)
        build_all
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
