#!/bin/bash
# Bluetooth Classic Test: NoInputNoOutput Pairing
#
# This script tests automated Bluetooth Classic pairing between Linux devices
# using NoInputNoOutput agent (no user interaction required).
#
# Usage:
#   ./test/bt_classic_test.sh server    # Run as server (discoverable, waits for connections)
#   ./test/bt_classic_test.sh client    # Run as client (scans and connects)
#   ./test/bt_classic_test.sh scan      # Just scan for nearby devices
#   ./test/bt_classic_test.sh status    # Show Bluetooth status
#
# Requirements:
#   - bluetoothctl, rfcomm, sdptool
#   - Bluetooth adapter
#   - Root/sudo for rfcomm

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# RFCOMM channel for serial communication
RFCOMM_CHANNEL=1
RFCOMM_DEVICE="/dev/rfcomm0"

# Geogram SPP UUID (Serial Port Profile)
SPP_UUID="00001101-0000-1000-8000-00805f9b34fb"

# Custom Geogram service UUID for identification
GEOGRAM_UUID="0000fff0-0000-1000-8000-00805f9b34fb"

print_header() {
    echo ""
    echo -e "${BLUE}======================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}======================================${NC}"
    echo ""
}

print_info() {
    echo -e "${YELLOW}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Get local adapter MAC address
get_local_mac() {
    bluetoothctl show 2>/dev/null | grep "Controller" | awk '{print $2}'
}

# Get local adapter name
get_local_name() {
    bluetoothctl show 2>/dev/null | grep "Name:" | cut -d' ' -f2-
}

# Check if bluetoothd is running
check_bluetooth_service() {
    if ! systemctl is-active --quiet bluetooth; then
        print_error "Bluetooth service not running"
        print_info "Start with: sudo systemctl start bluetooth"
        exit 1
    fi
    print_success "Bluetooth service is running"
}

# Show current Bluetooth status
show_status() {
    print_header "Bluetooth Status"

    check_bluetooth_service

    echo ""
    echo -e "${CYAN}Adapter Info:${NC}"
    bluetoothctl show 2>/dev/null | grep -E "Controller|Name|Powered|Discoverable|Pairable|Class"

    echo ""
    echo -e "${CYAN}Paired Devices:${NC}"
    bluetoothctl paired-devices 2>/dev/null || echo "  (none)"

    echo ""
    echo -e "${CYAN}Connected Devices:${NC}"
    bluetoothctl devices Connected 2>/dev/null || echo "  (none)"

    echo ""
    echo -e "${CYAN}RFCOMM Status:${NC}"
    rfcomm -a 2>/dev/null || echo "  (no active connections)"
}

# Scan for nearby Bluetooth devices
scan_devices() {
    print_header "Scanning for Bluetooth Classic Devices"

    check_bluetooth_service

    print_info "Starting 10 second scan..."
    print_info "Looking for devices with Geogram service or any discoverable device"
    echo ""

    # Use bluetoothctl to scan
    timeout 12 bluetoothctl scan on &
    SCAN_PID=$!

    sleep 10

    # Kill scan
    kill $SCAN_PID 2>/dev/null || true
    bluetoothctl scan off 2>/dev/null || true

    echo ""
    print_info "Discovered devices:"
    bluetoothctl devices 2>/dev/null
}

# Setup NoInputNoOutput agent (auto-accept pairing)
setup_agent() {
    print_info "Setting up NoInputNoOutput agent..."

    # Create a simple expect-like script for bluetoothctl
    # This registers an agent that auto-accepts all pairing requests

    cat > /tmp/bt_agent.sh << 'AGENT_SCRIPT'
#!/usr/bin/expect -f
spawn bluetoothctl
expect "#"
send "power on\r"
expect "#"
send "agent NoInputNoOutput\r"
expect "#"
send "default-agent\r"
expect "#"
send "pairable on\r"
expect "#"
send "discoverable on\r"
expect "#"

# Keep running to handle pairing requests
set timeout -1
expect {
    "Confirm passkey" {
        send "yes\r"
        exp_continue
    }
    "Authorize" {
        send "yes\r"
        exp_continue
    }
    "Request confirmation" {
        send "yes\r"
        exp_continue
    }
    eof
}
AGENT_SCRIPT

    chmod +x /tmp/bt_agent.sh
}

# Register Serial Port Profile service
register_spp_service() {
    print_info "Registering Serial Port Profile (SPP) service..."

    # Add SPP record to SDP
    # This makes the device discoverable as having serial port capability
    sudo sdptool add --channel=$RFCOMM_CHANNEL SP 2>/dev/null || {
        print_info "SPP service may already be registered"
    }

    print_success "SPP service registered on channel $RFCOMM_CHANNEL"
}

# Server mode: Wait for incoming connections
run_server() {
    print_header "Bluetooth Classic Server Mode"

    check_bluetooth_service

    local_mac=$(get_local_mac)
    local_name=$(get_local_name)

    print_info "Local adapter: $local_name ($local_mac)"

    # Setup auto-accept agent
    print_info "Configuring NoInputNoOutput agent..."

    # Configure via bluetoothctl
    bluetoothctl power on
    bluetoothctl pairable on
    bluetoothctl discoverable on

    # Register SPP service
    register_spp_service

    print_success "Server is discoverable and pairable"
    print_info "Other devices can now discover: $local_name"
    print_info ""
    print_info "To connect from another Linux device:"
    print_info "  ./bt_classic_test.sh client $local_mac"
    print_info ""

    # Listen for RFCOMM connections
    print_info "Waiting for RFCOMM connections on channel $RFCOMM_CHANNEL..."
    print_info "Press Ctrl+C to stop"

    # Release any existing rfcomm binding
    sudo rfcomm release $RFCOMM_DEVICE 2>/dev/null || true

    # Listen for connections (this blocks)
    sudo rfcomm listen $RFCOMM_DEVICE $RFCOMM_CHANNEL &
    RFCOMM_PID=$!

    # Also run bluetoothctl agent in background to handle pairing
    (
        bluetoothctl << EOF
agent NoInputNoOutput
default-agent
EOF
        # Keep agent running
        sleep 3600
    ) &
    AGENT_PID=$!

    # Cleanup on exit
    trap "sudo rfcomm release $RFCOMM_DEVICE 2>/dev/null; kill $AGENT_PID 2>/dev/null; bluetoothctl discoverable off" EXIT

    # Wait and show status periodically
    while true; do
        sleep 5
        echo -n "."

        # Check if we got a connection
        if [ -e "$RFCOMM_DEVICE" ]; then
            echo ""
            print_success "Connection established on $RFCOMM_DEVICE!"
            print_info "You can now read/write to $RFCOMM_DEVICE"

            # Simple echo test
            print_info "Starting echo server (type to send back)..."
            cat $RFCOMM_DEVICE &
            cat > $RFCOMM_DEVICE
        fi
    done
}

# Client mode: Scan and connect to a server
run_client() {
    local target_mac="$1"

    print_header "Bluetooth Classic Client Mode"

    check_bluetooth_service

    local_mac=$(get_local_mac)
    local_name=$(get_local_name)

    print_info "Local adapter: $local_name ($local_mac)"

    # If no target specified, scan first
    if [ -z "$target_mac" ]; then
        print_info "No target MAC specified, scanning..."
        scan_devices

        echo ""
        print_info "Usage: $0 client <MAC_ADDRESS>"
        print_info "Example: $0 client AA:BB:CC:DD:EE:FF"
        exit 1
    fi

    print_info "Target device: $target_mac"

    # Setup auto-accept agent
    print_info "Configuring NoInputNoOutput agent..."
    bluetoothctl power on
    bluetoothctl pairable on

    # Start agent in background
    (
        bluetoothctl << EOF
agent NoInputNoOutput
default-agent
EOF
        sleep 3600
    ) &
    AGENT_PID=$!

    trap "kill $AGENT_PID 2>/dev/null; sudo rfcomm release $RFCOMM_DEVICE 2>/dev/null" EXIT

    # Check if already paired
    if bluetoothctl paired-devices | grep -q "$target_mac"; then
        print_info "Device already paired"
    else
        print_info "Attempting to pair with $target_mac..."

        # Try to pair (NoInputNoOutput should auto-accept)
        if timeout 30 bluetoothctl pair "$target_mac"; then
            print_success "Pairing successful!"
        else
            print_error "Pairing failed or timed out"
            print_info "Make sure the target device is in discoverable/pairable mode"
            exit 1
        fi
    fi

    # Trust the device for future connections
    bluetoothctl trust "$target_mac"
    print_success "Device trusted"

    # Connect via RFCOMM
    print_info "Connecting via RFCOMM channel $RFCOMM_CHANNEL..."

    # Release any existing binding
    sudo rfcomm release $RFCOMM_DEVICE 2>/dev/null || true

    # Connect
    if sudo rfcomm connect $RFCOMM_DEVICE "$target_mac" $RFCOMM_CHANNEL; then
        print_success "Connected to $RFCOMM_DEVICE!"
        print_info "You can now read/write to $RFCOMM_DEVICE"

        # Simple test: send hello
        echo "HELLO from $local_name" > $RFCOMM_DEVICE
        print_success "Sent HELLO message"

        # Read response
        print_info "Waiting for response..."
        timeout 10 cat $RFCOMM_DEVICE || true
    else
        print_error "RFCOMM connection failed"
        print_info "Make sure the server is running: ./bt_classic_test.sh server"
        exit 1
    fi
}

# Test pairing with a specific device
test_pairing() {
    local target_mac="$1"

    print_header "Testing NoInputNoOutput Pairing"

    if [ -z "$target_mac" ]; then
        print_error "Usage: $0 pair <MAC_ADDRESS>"
        exit 1
    fi

    check_bluetooth_service

    print_info "Target: $target_mac"
    print_info "Setting up NoInputNoOutput agent..."

    # Remove existing pairing if any
    bluetoothctl remove "$target_mac" 2>/dev/null || true

    # Configure
    bluetoothctl power on
    bluetoothctl pairable on

    # This is the key part - NoInputNoOutput means no user interaction
    print_info "Attempting automated pairing..."

    # Run bluetoothctl with agent
    timeout 30 bash -c "
        bluetoothctl << EOF
agent NoInputNoOutput
default-agent
pair $target_mac
EOF
    "

    # Check result
    if bluetoothctl paired-devices | grep -q "$target_mac"; then
        print_success "Pairing successful with NoInputNoOutput!"
        print_info "No user interaction was required on this side"

        # Trust for auto-reconnect
        bluetoothctl trust "$target_mac"
        print_success "Device trusted for future connections"
    else
        print_error "Pairing failed"
        print_info "The other device may need to also use NoInputNoOutput agent"
        print_info "Or the device may not support Just Works pairing"
    fi
}

# Main
case "${1:-status}" in
    server|s)
        run_server
        ;;
    client|c)
        run_client "${2:-}"
        ;;
    scan)
        scan_devices
        ;;
    pair|p)
        test_pairing "${2:-}"
        ;;
    status|st)
        show_status
        ;;
    *)
        echo "Usage: $0 <command> [options]"
        echo ""
        echo "Commands:"
        echo "  server          Run as server (discoverable, wait for connections)"
        echo "  client [MAC]    Run as client (scan and connect to MAC)"
        echo "  scan            Scan for nearby Bluetooth devices"
        echo "  pair <MAC>      Test NoInputNoOutput pairing with device"
        echo "  status          Show Bluetooth adapter status"
        echo ""
        echo "For automated testing between two Linux devices:"
        echo "  Device A: $0 server"
        echo "  Device B: $0 client <Device-A-MAC>"
        ;;
esac
