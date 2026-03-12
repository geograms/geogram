#!/bin/bash
# Run all Flasher tests
# No external dependencies required - uses native OS facilities

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DART="/home/brito/flutter/bin/dart"

echo "========================================"
echo "Flasher USB Detection Tests"
echo "========================================"
echo ""
echo "Platform: $(uname -s) $(uname -r)"
echo ""

# Quick system check
echo "System Check:"
echo "----------------------------------------"

# Check for USB serial devices
if [[ -e /dev/ttyUSB0 ]] || [[ -e /dev/ttyACM0 ]]; then
    echo "  Serial devices: $(ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null | tr '\n' ' ')"
else
    echo "  Serial devices: none found"
fi

# Check dialout group membership
if groups | grep -q dialout; then
    echo "  Dialout group: YES"
else
    echo "  Dialout group: NO (may need: sudo usermod -a -G dialout \$USER)"
fi

# Check lsusb for Espressif
if command -v lsusb &> /dev/null; then
    esp_device=$(lsusb | grep -i "303a\|espressif" | head -1)
    if [[ -n "$esp_device" ]]; then
        echo "  ESP32 USB: $esp_device"
    else
        echo "  ESP32 USB: not found"
    fi
fi

echo ""
echo "Running Dart tests:"
echo "----------------------------------------"
echo ""

# Run the Dart test
$DART "$SCRIPT_DIR/usb_detect_test.dart"
exit_code=$?

echo ""
if [[ $exit_code -eq 0 ]]; then
    echo "========================================"
    echo "All tests passed!"
    echo "========================================"
else
    echo "========================================"
    echo "Some tests failed (exit code: $exit_code)"
    echo "========================================"
fi

exit $exit_code
