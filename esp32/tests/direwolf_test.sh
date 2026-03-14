#!/bin/bash
# Cross-validate our APRS implementation with Direwolf
# Run after: sudo apt install -y direwolf sox
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== Step 1: Generate APRS audio WAV with our encoder ==="
python3 aprs_tx.py --wav test_packet.wav --no-tx --message "Direwolf cross-check"

echo ""
echo "=== Step 2: Decode with Direwolf (gold standard) ==="
if command -v direwolf &>/dev/null; then
    # Use atest (Direwolf's offline decoder) if available
    if command -v atest &>/dev/null; then
        echo "Using atest (Direwolf offline decoder):"
        atest test_packet.wav 2>&1 || true
    else
        # direwolf can decode from stdin with -r flag
        echo "Using direwolf -r (audio file decode):"
        direwolf -r 48000 -t 0 -q d test_packet.wav 2>&1 | head -20 || true
    fi
else
    echo "WARNING: Direwolf not installed. Run: sudo apt install -y direwolf"
fi

echo ""
echo "=== Step 3: Decode with our decoder ==="
python3 aprs_rx.py --wav test_packet.wav

echo ""
echo "=== Step 4: Generate Direwolf reference packet and decode with our tool ==="
if command -v gen_packets &>/dev/null; then
    echo "Generating reference packet with gen_packets..."
    echo "HCKRF0>X3XU3F:>Direwolf reference packet" > /tmp/aprs_test/ref_input.txt
    gen_packets -r 48000 -o direwolf_ref.wav /tmp/aprs_test/ref_input.txt 2>&1 || true
    if [ -f direwolf_ref.wav ]; then
        echo "Verifying with atest:"
        atest direwolf_ref.wav 2>&1 || true
        echo "Decoding Direwolf reference with our decoder:"
        python3 aprs_rx.py --wav direwolf_ref.wav
    fi
else
    echo "WARNING: gen_packets not found. It ships with Direwolf."
fi

echo ""
echo "=== Done ==="
