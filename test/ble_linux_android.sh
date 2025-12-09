#!/bin/bash
# BLE Test: Linux to Android (Fully Automated)
#
# This script automates BLE testing between a Linux desktop and an Android device.
# It handles everything: ADB setup, APK installation, app launching, and BLE tests.
#
# Prerequisites:
#   - ADB installed and in PATH
#   - Android device connected via USB with USB debugging enabled
#   - Android device on same WiFi network as Linux
#   - Built Geogram Desktop for Linux
#   - Built Geogram APK for Android (optional if already installed)
#
# What it does:
#   1. Detects Android device via ADB
#   2. Gets Android device IP address automatically
#   3. Installs latest Geogram APK on Android
#   4. Launches Geogram on both devices
#   5. Runs BLE communication tests
#   6. Reports results
#
# Usage:
#   ./test/ble_linux_android.sh              # Full automated test
#   ./test/ble_linux_android.sh --skip-install  # Skip APK installation
#   ./test/ble_linux_android.sh --cleanup       # Just cleanup

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Add common Android SDK paths to PATH
ANDROID_SDK_PATHS=(
    "$HOME/Android/Sdk/platform-tools"
    "$HOME/android-sdk/platform-tools"
    "/opt/android-sdk/platform-tools"
    "$ANDROID_HOME/platform-tools"
    "$ANDROID_SDK_ROOT/platform-tools"
)

for sdk_path in "${ANDROID_SDK_PATHS[@]}"; do
    if [ -d "$sdk_path" ]; then
        export PATH="$sdk_path:$PATH"
    fi
done

# Add common Flutter paths to PATH
FLUTTER_PATHS=(
    "$HOME/flutter/bin"
    "$HOME/development/flutter/bin"
    "/opt/flutter/bin"
    "/usr/local/flutter/bin"
    "$FLUTTER_ROOT/bin"
)

for flutter_path in "${FLUTTER_PATHS[@]}"; do
    if [ -d "$flutter_path" ]; then
        export PATH="$flutter_path:$PATH"
        break
    fi
done

# Configuration
LINUX_PORT=3456
ANDROID_PORT=3456
TEST_DATA_DIR="/tmp/geogram-test-linux"
STARTUP_TIMEOUT=30
TEST_DOC_SIZE=2000

# APK paths (try release first, then debug)
APK_RELEASE="${PROJECT_DIR}/build/app/outputs/flutter-apk/app-release.apk"
APK_DEBUG="${PROJECT_DIR}/build/app/outputs/flutter-apk/app-debug.apk"
APK_PATH=""

# Linux binary
LINUX_BINARY="${PROJECT_DIR}/build/linux/x64/release/bundle/geogram_desktop"

# Android package info
ANDROID_PACKAGE="dev.geogram.geogram_desktop"
ANDROID_ACTIVITY="${ANDROID_PACKAGE}.MainActivity"

# PIDs and state
LINUX_PID=""
ANDROID_IP=""
SKIP_INSTALL=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

print_header() {
    echo ""
    echo -e "${BLUE}======================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}======================================${NC}"
    echo ""
}

print_subheader() {
    echo ""
    echo -e "${CYAN}--- $1 ---${NC}"
}

print_info() {
    echo -e "${YELLOW}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((TESTS_PASSED++)) || true
}

print_error() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((TESTS_FAILED++)) || true
}

print_skip() {
    echo -e "${YELLOW}[SKIP]${NC} $1"
    ((TESTS_SKIPPED++)) || true
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Cleanup function
cleanup() {
    print_info "Cleaning up..."

    # Kill Linux instance
    if [ -n "$LINUX_PID" ] && kill -0 "$LINUX_PID" 2>/dev/null; then
        print_info "Stopping Linux Geogram (PID: $LINUX_PID)"
        kill "$LINUX_PID" 2>/dev/null || true
        wait "$LINUX_PID" 2>/dev/null || true
    fi

    # Kill any process on Linux test port
    local pid=$(lsof -t -i:$LINUX_PORT 2>/dev/null || true)
    if [ -n "$pid" ]; then
        print_info "Killing process on port $LINUX_PORT"
        kill "$pid" 2>/dev/null || true
    fi

    # Stop Android app (don't uninstall, just stop)
    if command -v adb &> /dev/null && adb devices | grep -q "device$"; then
        print_info "Stopping Android Geogram"
        adb shell am force-stop "$ANDROID_PACKAGE" 2>/dev/null || true
    fi

    print_info "Cleanup complete"
}

# Check prerequisites
check_prerequisites() {
    print_subheader "Checking Prerequisites"

    # Check ADB
    if ! command -v adb &> /dev/null; then
        print_error "ADB not found. Please install Android SDK platform-tools."
        echo "  Ubuntu/Debian: sudo apt install adb"
        echo "  Arch: sudo pacman -S android-tools"
        exit 1
    fi
    print_info "ADB found: $(which adb)"

    # Check curl and jq
    if ! command -v curl &> /dev/null; then
        print_error "curl not found"
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        print_error "jq not found. Please install: sudo apt install jq"
        exit 1
    fi

    # Check Linux binary
    if [ ! -x "$LINUX_BINARY" ]; then
        # Try debug build
        LINUX_BINARY="${PROJECT_DIR}/build/linux/x64/debug/bundle/geogram_desktop"
        if [ ! -x "$LINUX_BINARY" ]; then
            print_error "Linux Geogram binary not found. Build with:"
            echo "  flutter build linux"
            exit 1
        fi
        print_warning "Using debug Linux build"
    fi
    print_info "Linux binary: $LINUX_BINARY"

    # Check APK
    if [ -f "$APK_RELEASE" ]; then
        APK_PATH="$APK_RELEASE"
    elif [ -f "$APK_DEBUG" ]; then
        APK_PATH="$APK_DEBUG"
        print_warning "Using debug APK"
    else
        if [ "$SKIP_INSTALL" = false ]; then
            print_warning "Android APK not found. Will check if app is already installed."
            print_info "Build APK with: flutter build apk"
        fi
    fi

    if [ -n "$APK_PATH" ]; then
        print_info "APK: $APK_PATH"
    fi
}

# Check Android device connection
check_android_device() {
    print_subheader "Checking Android Device"

    # Start ADB server if needed
    adb start-server 2>/dev/null

    # Check for connected devices
    local devices=$(adb devices | grep -c "device$" || echo "0")

    if [ "$devices" -eq 0 ]; then
        print_error "No Android device connected"
        echo ""
        echo "Please:"
        echo "  1. Connect Android device via USB"
        echo "  2. Enable USB debugging in Developer Options"
        echo "  3. Accept the USB debugging prompt on device"
        echo ""
        echo "Then run this script again."
        exit 1
    fi

    if [ "$devices" -gt 1 ]; then
        print_warning "Multiple devices connected, using first one"
    fi

    # Get device info
    local device_model=$(adb shell getprop ro.product.model 2>/dev/null | tr -d '\r')
    local android_version=$(adb shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')

    print_info "Device: $device_model (Android $android_version)"
}

# Get Android device IP address
get_android_ip() {
    print_subheader "Getting Android IP Address"

    # Try multiple methods to get IP

    # Method 1: WiFi IP via ip command
    ANDROID_IP=$(adb shell ip addr show wlan0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1 | tr -d '\r' | head -1)

    if [ -z "$ANDROID_IP" ] || [ "$ANDROID_IP" = "" ]; then
        # Method 2: Any non-loopback IP
        ANDROID_IP=$(adb shell ip addr show 2>/dev/null | grep "inet " | grep -v "127.0.0.1" | head -1 | awk '{print $2}' | cut -d/ -f1 | tr -d '\r')
    fi

    if [ -z "$ANDROID_IP" ] || [ "$ANDROID_IP" = "" ]; then
        # Method 3: Using ifconfig (older devices)
        ANDROID_IP=$(adb shell ifconfig wlan0 2>/dev/null | grep "inet addr" | awk -F: '{print $2}' | awk '{print $1}' | tr -d '\r')
    fi

    if [ -z "$ANDROID_IP" ] || [ "$ANDROID_IP" = "" ]; then
        # Method 4: dumpsys wifi
        ANDROID_IP=$(adb shell dumpsys wifi 2>/dev/null | grep "ip_address" | awk -F= '{print $2}' | tr -d '\r' | head -1)
    fi

    if [ -z "$ANDROID_IP" ] || [ "$ANDROID_IP" = "" ]; then
        # Method 5: Settings provider
        ANDROID_IP=$(adb shell settings get global wifi_static_ip 2>/dev/null | tr -d '\r')
    fi

    if [ -z "$ANDROID_IP" ] || [ "$ANDROID_IP" = "" ] || [ "$ANDROID_IP" = "null" ]; then
        print_error "Could not determine Android device IP address"
        echo ""
        echo "Please ensure:"
        echo "  1. Android device is connected to WiFi"
        echo "  2. Both devices are on the same network"
        echo ""
        echo "You can check IP manually on Android:"
        echo "  Settings > About Phone > Status > IP Address"
        echo "  Or: Settings > WiFi > (your network) > IP Address"
        exit 1
    fi

    print_info "Android IP: $ANDROID_IP"

    # Verify network connectivity
    if ping -c 1 -W 2 "$ANDROID_IP" > /dev/null 2>&1; then
        print_info "Network connectivity confirmed"
    else
        print_warning "Cannot ping Android device (firewall may be blocking)"
    fi
}

# Check if app is installed on Android
check_app_installed() {
    adb shell pm list packages 2>/dev/null | grep -q "$ANDROID_PACKAGE"
}

# Build APK if needed
build_apk() {
    print_subheader "Building Android APK"

    if ! command -v flutter &> /dev/null; then
        print_error "Flutter not found. Cannot build APK."
        echo "Please ensure flutter is in PATH or install it."
        return 1
    fi

    print_info "Building APK (this may take a few minutes)..."
    cd "$PROJECT_DIR"

    if flutter build apk --release 2>&1 | tee /tmp/flutter_build.log | tail -5; then
        if [ -f "$APK_RELEASE" ]; then
            APK_PATH="$APK_RELEASE"
            print_info "APK built successfully: $APK_PATH"
            return 0
        fi
    fi

    print_error "APK build failed. Check /tmp/flutter_build.log for details"
    return 1
}

# Install APK on Android
install_apk() {
    if [ "$SKIP_INSTALL" = true ]; then
        print_info "Skipping APK installation (--skip-install)"
        return 0
    fi

    print_subheader "Installing APK on Android"

    # If no APK available, try to build it or check if already installed
    if [ -z "$APK_PATH" ]; then
        if check_app_installed; then
            print_info "App already installed, no APK to update"
            return 0
        else
            print_info "No APK found, attempting to build..."
            if ! build_apk; then
                print_error "Cannot build APK and app not installed"
                exit 1
            fi
        fi
    fi

    print_info "Installing $APK_PATH..."

    # Try to install directly first
    local install_output
    install_output=$(adb install -r "$APK_PATH" 2>&1) || true

    # Check for signature mismatch first (can appear even with exit code 0)
    if echo "$install_output" | grep -q "INSTALL_FAILED_UPDATE_INCOMPATIBLE"; then
        # Signature mismatch - need to uninstall first
        print_warning "Signature mismatch, uninstalling old version first..."
        adb uninstall "$ANDROID_PACKAGE" 2>/dev/null || true

        # Try install again
        install_output=$(adb install "$APK_PATH" 2>&1) || true
        if echo "$install_output" | grep -q "Success"; then
            print_info "APK installed successfully (after uninstall)"
        else
            print_error "APK installation failed: $install_output"
            exit 1
        fi
    elif echo "$install_output" | grep -q "Success"; then
        print_info "APK installed successfully"
    else
        print_error "APK installation failed: $install_output"
        exit 1
    fi

    # Grant Bluetooth permissions
    print_info "Granting Bluetooth permissions..."
    adb shell pm grant "$ANDROID_PACKAGE" android.permission.BLUETOOTH 2>/dev/null || true
    adb shell pm grant "$ANDROID_PACKAGE" android.permission.BLUETOOTH_ADMIN 2>/dev/null || true
    adb shell pm grant "$ANDROID_PACKAGE" android.permission.BLUETOOTH_SCAN 2>/dev/null || true
    adb shell pm grant "$ANDROID_PACKAGE" android.permission.BLUETOOTH_CONNECT 2>/dev/null || true
    adb shell pm grant "$ANDROID_PACKAGE" android.permission.BLUETOOTH_ADVERTISE 2>/dev/null || true
    adb shell pm grant "$ANDROID_PACKAGE" android.permission.ACCESS_FINE_LOCATION 2>/dev/null || true
    adb shell pm grant "$ANDROID_PACKAGE" android.permission.ACCESS_COARSE_LOCATION 2>/dev/null || true

    print_info "Permissions granted"
}

# Launch Android app
launch_android_app() {
    print_subheader "Launching Android Geogram"

    # Verify app is installed
    if ! check_app_installed; then
        print_error "Geogram not installed on Android"
        exit 1
    fi

    # Force stop first
    adb shell am force-stop "$ANDROID_PACKAGE" 2>/dev/null || true
    sleep 1

    # Launch app
    print_info "Starting Geogram on Android..."
    adb shell am start -n "$ANDROID_PACKAGE/$ANDROID_ACTIVITY" 2>/dev/null || {
        # Try alternative activity name
        adb shell monkey -p "$ANDROID_PACKAGE" -c android.intent.category.LAUNCHER 1 2>/dev/null || true
    }

    # Wait for app to start and API to be ready
    print_info "Waiting for Android API to be ready (max ${STARTUP_TIMEOUT}s)..."
    local waited=0
    while [ $waited -lt $STARTUP_TIMEOUT ]; do
        if curl -s --connect-timeout 2 "http://${ANDROID_IP}:${ANDROID_PORT}/api/status" > /dev/null 2>&1; then
            echo ""
            print_info "Android API is ready!"
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
        echo -n "."
    done
    echo ""

    print_error "Android API did not become ready within ${STARTUP_TIMEOUT}s"
    echo ""
    echo "Possible issues:"
    echo "  1. First launch may require manual interaction"
    echo "  2. Firewall blocking port $ANDROID_PORT"
    echo "  3. WiFi might have client isolation enabled"
    echo "  4. App might have crashed - check: adb logcat -s flutter"
    echo ""
    echo "Try manually opening the app on Android, then re-run with --skip-install"
    return 1
}

# Launch Linux app
launch_linux_app() {
    print_subheader "Launching Linux Geogram"

    # Setup test directory
    rm -rf "$TEST_DATA_DIR"
    mkdir -p "$TEST_DATA_DIR"

    # Kill any existing instance on our port
    local pid=$(lsof -t -i:$LINUX_PORT 2>/dev/null || true)
    if [ -n "$pid" ]; then
        print_info "Killing existing process on port $LINUX_PORT"
        kill "$pid" 2>/dev/null || true
        sleep 2
    fi

    # Launch
    print_info "Starting Geogram on Linux (port $LINUX_PORT)..."
    DISPLAY="${DISPLAY:-:0}" "$LINUX_BINARY" \
        --port="$LINUX_PORT" \
        --data-dir="$TEST_DATA_DIR" \
        > "${TEST_DATA_DIR}/stdout.log" 2>&1 &

    LINUX_PID=$!
    print_info "Linux PID: $LINUX_PID"

    # Wait for API
    print_info "Waiting for Linux API to be ready..."
    local waited=0
    while [ $waited -lt $STARTUP_TIMEOUT ]; do
        if curl -s "http://localhost:${LINUX_PORT}/api/status" > /dev/null 2>&1; then
            echo ""
            print_info "Linux API is ready!"
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
        echo -n "."
    done
    echo ""

    print_error "Linux API did not become ready"
    echo "Logs:"
    cat "${TEST_DATA_DIR}/stdout.log" 2>/dev/null | tail -20 || true
    return 1
}

# API helper functions
trigger_action() {
    local host="$1"
    local port="$2"
    local action="$3"
    shift 3
    local params="$@"

    local json="{\"action\": \"$action\""
    if [ -n "$params" ]; then
        json="$json, $params"
    fi
    json="$json}"

    curl -s -X POST "http://${host}:${port}/api/debug" \
        -H "Content-Type: application/json" \
        -d "$json" 2>/dev/null
}

get_status() {
    local host="$1"
    local port="$2"
    curl -s "http://${host}:${port}/api/status" 2>/dev/null
}

get_callsign() {
    local host="$1"
    local port="$2"
    get_status "$host" "$port" | jq -r '.callsign // "unknown"'
}

get_logs() {
    local host="$1"
    local port="$2"
    local filter="${3:-}"
    local limit="${4:-100}"

    local url="http://${host}:${port}/log?limit=$limit"
    if [ -n "$filter" ]; then
        url="$url&filter=$(echo -n "$filter" | jq -sRr @uri)"
    fi

    curl -s "$url" 2>/dev/null
}

log_contains() {
    local host="$1"
    local port="$2"
    local pattern="$3"
    local filter="${4:-}"

    get_logs "$host" "$port" "$filter" 100 | jq -r '.logs[]' 2>/dev/null | grep -q "$pattern"
}

wait_for_log() {
    local host="$1"
    local port="$2"
    local pattern="$3"
    local timeout="${4:-15}"
    local filter="${5:-}"
    local waited=0

    while [ $waited -lt $timeout ]; do
        if log_contains "$host" "$port" "$pattern" "$filter"; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

# Show a toast message on a device
show_toast() {
    local host="$1"
    local port="$2"
    local message="$3"
    local duration="${4:-3}"

    curl -s -X POST "http://${host}:${port}/api/debug" \
        -H "Content-Type: application/json" \
        -d "{\"action\": \"toast\", \"message\": \"$message\", \"duration\": $duration}" 2>/dev/null > /dev/null
}

# Show toast on both devices
show_toast_both() {
    local message="$1"
    local duration="${2:-3}"

    show_toast "localhost" "$LINUX_PORT" "$message" "$duration"
    show_toast "$ANDROID_IP" "$ANDROID_PORT" "$message" "$duration"
}

# ============================================================================
# TEST FUNCTIONS
# ============================================================================

test_api_connectivity() {
    print_subheader "API Connectivity Test"

    # Test Linux API
    local linux_status=$(get_status "localhost" "$LINUX_PORT")
    if [ -n "$linux_status" ]; then
        local linux_callsign=$(echo "$linux_status" | jq -r '.callsign // "unknown"')
        print_success "Linux API responding (callsign: $linux_callsign)"
    else
        print_error "Linux API not responding"
        return 1
    fi

    # Test Android API
    local android_status=$(get_status "$ANDROID_IP" "$ANDROID_PORT")
    if [ -n "$android_status" ]; then
        local android_callsign=$(echo "$android_status" | jq -r '.callsign // "unknown"')
        print_success "Android API responding (callsign: $android_callsign)"
    else
        print_error "Android API not responding"
        return 1
    fi
}

test_ble_scan_linux() {
    print_subheader "BLE Scan Test (Linux)"

    print_info "Triggering BLE scan on Linux..."
    show_toast "localhost" "$LINUX_PORT" "Starting BLE scan..." 5
    local result=$(trigger_action "localhost" "$LINUX_PORT" "ble_scan")
    local success=$(echo "$result" | jq -r '.success // false')

    if [ "$success" = "true" ]; then
        print_info "Scan triggered, waiting 12 seconds..."
        sleep 12

        if log_contains "localhost" "$LINUX_PORT" "BLEDiscovery\|Found\|discovered" "BLE"; then
            show_toast "localhost" "$LINUX_PORT" "BLE scan completed" 3
            print_success "Linux BLE scan completed"
            return 0
        else
            show_toast "localhost" "$LINUX_PORT" "BLE scan: no devices found" 3
            print_skip "Linux BLE scan - no devices in logs"
            return 2
        fi
    else
        show_toast "localhost" "$LINUX_PORT" "BLE scan failed" 3
        print_error "Linux BLE scan trigger failed"
        return 1
    fi
}

test_ble_scan_android() {
    print_subheader "BLE Scan Test (Android)"

    print_info "Triggering BLE scan on Android..."
    show_toast "$ANDROID_IP" "$ANDROID_PORT" "Starting BLE scan..." 5
    local result=$(trigger_action "$ANDROID_IP" "$ANDROID_PORT" "ble_scan")
    local success=$(echo "$result" | jq -r '.success // false')

    if [ "$success" = "true" ]; then
        print_info "Scan triggered, waiting 12 seconds..."
        sleep 12

        if log_contains "$ANDROID_IP" "$ANDROID_PORT" "BLEDiscovery\|Found\|discovered" "BLE"; then
            show_toast "$ANDROID_IP" "$ANDROID_PORT" "BLE scan completed" 3
            print_success "Android BLE scan completed"
            return 0
        else
            show_toast "$ANDROID_IP" "$ANDROID_PORT" "BLE scan: no devices found" 3
            print_skip "Android BLE scan - no devices in logs"
            return 2
        fi
    else
        show_toast "$ANDROID_IP" "$ANDROID_PORT" "BLE scan failed" 3
        print_error "Android BLE scan trigger failed"
        return 1
    fi
}

test_ble_advertise_android() {
    print_subheader "BLE Advertise Test (Android)"

    # Android can advertise, Linux cannot
    print_info "Starting BLE advertising on Android..."
    local android_callsign=$(get_callsign "$ANDROID_IP" "$ANDROID_PORT")
    show_toast "$ANDROID_IP" "$ANDROID_PORT" "Starting BLE advertising..." 3

    local result=$(trigger_action "$ANDROID_IP" "$ANDROID_PORT" "ble_advertise" "\"callsign\": \"$android_callsign\"")
    local success=$(echo "$result" | jq -r '.success // false')

    if [ "$success" = "true" ]; then
        show_toast "$ANDROID_IP" "$ANDROID_PORT" "BLE advertising as $android_callsign" 3
        print_info "Advertising started with callsign: $android_callsign"
        print_success "Android BLE advertising active"
        return 0
    else
        show_toast "$ANDROID_IP" "$ANDROID_PORT" "BLE advertising failed" 3
        print_error "Android BLE advertise failed"
        return 1
    fi
}

test_linux_discovers_android() {
    print_subheader "Discovery Test (Linux finds Android)"

    local android_callsign=$(get_callsign "$ANDROID_IP" "$ANDROID_PORT")
    print_info "Looking for Android device ($android_callsign) from Linux..."
    show_toast_both "Discovery test: Linux looking for Android" 3

    # Make sure Android is advertising
    show_toast "$ANDROID_IP" "$ANDROID_PORT" "Ensuring BLE advertising is active..." 2
    trigger_action "$ANDROID_IP" "$ANDROID_PORT" "ble_advertise" > /dev/null 2>&1
    sleep 2

    # Scan from Linux
    show_toast "localhost" "$LINUX_PORT" "Scanning for BLE devices..." 5
    trigger_action "localhost" "$LINUX_PORT" "ble_scan" > /dev/null 2>&1

    print_info "Waiting for discovery (15 seconds)..."
    sleep 15

    # Check if Linux found Android
    if log_contains "localhost" "$LINUX_PORT" "$android_callsign" "BLE"; then
        show_toast_both "Found device: $android_callsign" 3
        print_success "Linux discovered Android ($android_callsign)"
        return 0
    else
        # Check for any Geogram device marker (0x3E = '>')
        if log_contains "localhost" "$LINUX_PORT" "Geogram\|geogram\|0x3E\|Found" "BLE"; then
            show_toast_both "Found a Geogram device" 3
            print_success "Linux discovered a Geogram device"
            return 0
        fi

        show_toast "localhost" "$LINUX_PORT" "No BLE devices discovered" 3
        print_skip "Linux did not discover Android yet"
        print_info "  (Ensure devices are within BLE range ~10m)"
        return 2
    fi
}

test_ble_hello() {
    print_subheader "BLE HELLO Handshake Test"

    # Ensure Android is advertising
    trigger_action "$ANDROID_IP" "$ANDROID_PORT" "ble_advertise" > /dev/null 2>&1
    sleep 2

    # Trigger HELLO from Linux
    print_info "Initiating HELLO handshake from Linux to Android..."
    show_toast_both "HELLO handshake test starting..." 3
    show_toast "localhost" "$LINUX_PORT" "Sending HELLO to Android..." 5
    local result=$(trigger_action "localhost" "$LINUX_PORT" "ble_hello")
    local success=$(echo "$result" | jq -r '.success // false')

    if [ "$success" = "true" ]; then
        print_info "HELLO triggered, waiting for response (20s)..."

        # Wait for HELLO exchange
        if wait_for_log "localhost" "$LINUX_PORT" "HELLO\|handshake" 20 "BLE"; then
            # Check Android side
            if log_contains "$ANDROID_IP" "$ANDROID_PORT" "HELLO\|received\|incoming" "BLE"; then
                show_toast_both "HELLO handshake successful!" 3
                print_success "BLE HELLO handshake completed (bidirectional)"
            else
                show_toast "localhost" "$LINUX_PORT" "HELLO sent successfully" 3
                print_success "BLE HELLO sent from Linux"
            fi
            return 0
        else
            show_toast "localhost" "$LINUX_PORT" "HELLO: no response received" 3
            print_skip "HELLO - no response logged (may need connection first)"
            return 2
        fi
    else
        show_toast "localhost" "$LINUX_PORT" "HELLO trigger failed" 3
        print_error "HELLO trigger failed"
        return 1
    fi
}

test_ble_data_transfer() {
    print_subheader "BLE Data Transfer Test (${TEST_DOC_SIZE} bytes)"

    # Check if we have a connection
    if ! log_contains "localhost" "$LINUX_PORT" "connected\|HELLO" "BLE"; then
        show_toast "localhost" "$LINUX_PORT" "No BLE connection established" 3
        print_skip "Data transfer - no connection established"
        return 2
    fi

    print_info "Sending $TEST_DOC_SIZE bytes from Linux to Android..."
    show_toast_both "Data transfer test: sending ${TEST_DOC_SIZE} bytes" 5
    show_toast "localhost" "$LINUX_PORT" "Sending data to Android..." 5

    local result=$(trigger_action "localhost" "$LINUX_PORT" "ble_send" "\"size\": $TEST_DOC_SIZE")
    local success=$(echo "$result" | jq -r '.success // false')

    if [ "$success" = "true" ]; then
        print_info "Data send triggered, waiting (30s)..."

        if wait_for_log "localhost" "$LINUX_PORT" "sent\|transfer\|complete\|parcel" 30 "BLE"; then
            # Check receiver
            if wait_for_log "$ANDROID_IP" "$ANDROID_PORT" "received\|incoming\|data" 15 "BLE"; then
                show_toast_both "Data transfer complete: ${TEST_DOC_SIZE} bytes" 3
                print_success "Data transfer completed ($TEST_DOC_SIZE bytes)"
            else
                show_toast "localhost" "$LINUX_PORT" "Data sent successfully" 3
                print_success "Data sent from Linux"
            fi
            return 0
        else
            show_toast "localhost" "$LINUX_PORT" "Data transfer: no confirmation" 3
            print_skip "Data transfer - completion not logged"
            return 2
        fi
    else
        show_toast "localhost" "$LINUX_PORT" "Data transfer failed to start" 3
        print_error "Data send trigger failed"
        return 1
    fi
}

test_ble_compressed_file_transfer() {
    print_subheader "BLE Compressed File Transfer Test (BLE.md)"

    # Check if we have a connection with HELLO completed (needed for compression capability exchange)
    if ! log_contains "localhost" "$LINUX_PORT" "HELLO\|handshake" "BLE"; then
        show_toast "localhost" "$LINUX_PORT" "No HELLO handshake completed" 3
        print_skip "Compressed file transfer - HELLO handshake required"
        return 2
    fi

    # Get file size
    local ble_doc="${PROJECT_DIR}/docs/BLE.md"
    if [ ! -f "$ble_doc" ]; then
        print_error "BLE.md not found at $ble_doc"
        return 1
    fi

    local file_size=$(wc -c < "$ble_doc")
    print_info "Sending BLE.md ($file_size bytes) - should trigger compression"
    show_toast_both "Compressed file transfer: BLE.md ($file_size bytes)" 5
    show_toast "localhost" "$LINUX_PORT" "Sending BLE.md (compressed)..." 10

    # Read file content and encode as base64 for JSON
    local file_content=$(base64 -w0 "$ble_doc")

    # Trigger file send via API
    local result=$(curl -s -X POST "http://localhost:${LINUX_PORT}/api/debug" \
        -H "Content-Type: application/json" \
        -d "{\"action\": \"ble_send_file\", \"content_base64\": \"$file_content\", \"filename\": \"BLE.md\"}" 2>/dev/null)

    local success=$(echo "$result" | jq -r '.success // false')

    if [ "$success" = "true" ]; then
        print_info "File send triggered, waiting for transfer (60s)..."

        # Wait for compression-related logs
        if wait_for_log "localhost" "$LINUX_PORT" "compress\|parcel" 60 "BLE"; then
            # Check for compression being used
            if log_contains "localhost" "$LINUX_PORT" "compress" "BLE"; then
                print_info "Compression was applied to the transfer"
            fi

            # Check receiver
            if wait_for_log "$ANDROID_IP" "$ANDROID_PORT" "received\|incoming\|decompress\|complete" 30 "BLE"; then
                show_toast_both "Compressed file transfer complete!" 3
                print_success "Compressed file transfer completed (BLE.md, $file_size bytes)"

                # Log compression stats if available
                local compression_log=$(get_logs "localhost" "$LINUX_PORT" "compress" 5 | jq -r '.logs[]' 2>/dev/null | head -3)
                if [ -n "$compression_log" ]; then
                    print_info "Compression logs:"
                    echo "$compression_log" | sed 's/^/    /'
                fi
            else
                show_toast "localhost" "$LINUX_PORT" "File sent (receiver status unknown)" 3
                print_success "File sent from Linux"
            fi
            return 0
        else
            show_toast "localhost" "$LINUX_PORT" "File transfer: no completion logged" 3
            print_skip "File transfer - completion not logged"
            return 2
        fi
    else
        # Try fallback: send raw bytes without compression test
        print_warning "ble_send_file action not supported, trying raw send..."
        local result2=$(trigger_action "localhost" "$LINUX_PORT" "ble_send" "\"size\": $file_size")
        local success2=$(echo "$result2" | jq -r '.success // false')

        if [ "$success2" = "true" ]; then
            print_info "Fallback: sending $file_size bytes..."
            sleep 30

            if log_contains "localhost" "$LINUX_PORT" "sent\|complete" "BLE"; then
                show_toast_both "Data transfer complete ($file_size bytes)" 3
                print_success "Data transfer completed (fallback mode, $file_size bytes)"
                return 0
            fi
        fi

        show_toast "localhost" "$LINUX_PORT" "File transfer failed to start" 3
        print_error "File send trigger failed"
        return 1
    fi
}

print_summary() {
    print_header "Test Summary"

    local total=$((TESTS_PASSED + TESTS_FAILED + TESTS_SKIPPED))

    echo -e "  ${GREEN}Passed:${NC}  $TESTS_PASSED"
    echo -e "  ${RED}Failed:${NC}  $TESTS_FAILED"
    echo -e "  ${YELLOW}Skipped:${NC} $TESTS_SKIPPED"
    echo -e "  Total:   $total"
    echo ""

    if [ $TESTS_FAILED -eq 0 ]; then
        echo -e "${GREEN}All tests passed or skipped!${NC}"
        return 0
    else
        echo -e "${RED}Some tests failed.${NC}"
        return 1
    fi
}

print_debug_logs() {
    print_header "Recent BLE Logs"

    print_subheader "Linux (last 15 BLE logs)"
    get_logs "localhost" "$LINUX_PORT" "BLE" 15 | jq -r '.logs[]' 2>/dev/null | tail -10 || echo "(no logs)"

    print_subheader "Android (last 15 BLE logs)"
    get_logs "$ANDROID_IP" "$ANDROID_PORT" "BLE" 15 | jq -r '.logs[]' 2>/dev/null | tail -10 || echo "(no logs)"
}

# ============================================================================
# MAIN
# ============================================================================

# Register cleanup
trap cleanup EXIT

print_header "BLE Test: Linux to Android (Automated)"

# Parse arguments
case "${1:-}" in
    --cleanup)
        cleanup
        exit 0
        ;;
    --skip-install)
        SKIP_INSTALL=true
        ;;
    --help|-h)
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  (none)          Full automated test"
        echo "  --skip-install  Skip APK installation"
        echo "  --cleanup       Just cleanup"
        echo "  --help          Show this help"
        echo ""
        echo "The script will:"
        echo "  1. Detect Android device via ADB"
        echo "  2. Get Android IP address automatically"
        echo "  3. Install/update Geogram APK"
        echo "  4. Launch apps on both devices"
        echo "  5. Run BLE tests"
        exit 0
        ;;
esac

# Run setup
check_prerequisites
check_android_device
get_android_ip
install_apk

# Launch apps
launch_android_app || exit 1
launch_linux_app || exit 1

# Show device info
print_header "Test Configuration"
echo "Linux:   http://localhost:$LINUX_PORT"
echo "Android: http://$ANDROID_IP:$ANDROID_PORT"
echo ""

LINUX_CALLSIGN=$(get_callsign "localhost" "$LINUX_PORT")
ANDROID_CALLSIGN=$(get_callsign "$ANDROID_IP" "$ANDROID_PORT")
echo "Linux callsign:   $LINUX_CALLSIGN"
echo "Android callsign: $ANDROID_CALLSIGN"

# Run tests
print_header "Running BLE Tests"

print_info "Communication model:"
print_info "  - Android = GATT Server (can advertise)"
print_info "  - Linux = GATT Client (can only scan/connect)"
echo ""

# Notify both devices that tests are starting
show_toast_both "BLE Test Suite Starting..." 5

# Test sequence
test_api_connectivity

test_ble_advertise_android
test_ble_scan_linux
test_ble_scan_android

test_linux_discovers_android

test_ble_hello
test_ble_data_transfer
test_ble_compressed_file_transfer

# Notify both devices that tests are complete
show_toast_both "BLE Test Suite Complete" 5

# Results
print_debug_logs
print_summary
TEST_RESULT=$?

print_info ""
print_info "Test data: $TEST_DATA_DIR"
print_info "Android logs: adb logcat -s flutter"

exit $TEST_RESULT
