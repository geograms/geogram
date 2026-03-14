#!/bin/bash
# End-to-end APRS test with ESP32 KV4P-HT via HackRF
# Requires: direwolf, hackrf_transfer, python3 with numpy/scipy
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

ESP32_IP="${ESP32_IP:-192.168.178.78}"
FREQ=144800000

echo "=== ESP32 APRS Test Suite ==="
echo "Device: $ESP32_IP"
echo ""

# Phase 1: Test HTTP API
echo "--- Phase 1: HTTP API ---"
echo -n "Testing /api/aprs/status... "
if curl -s --connect-timeout 5 "http://$ESP32_IP/api/aprs/status" > /tmp/aprs_test/status.json 2>/dev/null; then
    echo "OK"
    cat /tmp/aprs_test/status.json
    echo ""
else
    echo "FAIL (connection error)"
    echo "Check: is ESP32 on $ESP32_IP? Try: curl http://$ESP32_IP/"
fi

# Phase 3: Test APRS RX (HackRF -> ESP32)
echo ""
echo "--- Phase 3: APRS RX (HackRF TX -> ESP32 RX) ---"
echo "Sending 5 test packets with 2s gaps..."
for i in 1 2 3 4 5; do
    MSG="HackRF test $i $(date +%H%M%S)"
    echo "  TX: $MSG"
    python3 aprs_tx.py --message "$MSG" --gain 20 2>&1 | grep -E "^(Transmitting|AX.25)"
    sleep 2
done

echo ""
echo "Checking ESP32 for received packets..."
sleep 1
curl -s "http://$ESP32_IP/api/aprs?since=0" 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "(no response)"

# Phase 4: Test APRS TX (ESP32 -> HackRF)
echo ""
echo "--- Phase 4: APRS TX (ESP32 TX -> HackRF RX) ---"
echo "Starting HackRF capture (10s)..."
python3 aprs_rx.py --capture 10 --iq /tmp/aprs_test/esp32_capture.iq8 &
CAPTURE_PID=$!

sleep 1
echo "Triggering ESP32 TX..."
for i in 1 2 3; do
    curl -s -X POST "http://$ESP32_IP/api/aprs" \
        -d "from=X3XU3F&to=HCKRF0&message=Hello+HackRF+$i" 2>/dev/null || echo "(TX trigger failed)"
    sleep 2
done

wait $CAPTURE_PID 2>/dev/null || true

echo ""
echo "Decoding captured packets..."
python3 aprs_rx.py --iq /tmp/aprs_test/esp32_capture.iq8 -v

# Also decode with Direwolf if we can convert IQ to audio
echo ""
echo "--- Phase 5: Store & Wrap Test ---"
echo "Checking message store..."
curl -s "http://$ESP32_IP/api/aprs?since=0" 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "(no response)"

echo ""
echo "=== Done ==="
