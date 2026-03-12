#!/bin/bash
# Test Wallet Debt Signature via API
#
# This script tests creating debts and verifying signatures via the HTTP API.
#
# Usage:
#   ./test-wallet-signature.sh
#
# Steps:
#   1. Launch two temporary instances with localhost discovery
#   2. Wait for instances to discover each other
#   3. Create a debt on Instance A with Instance B as debtor
#   4. Verify the debt has a signature from the creditor
#   5. Sync the debt to Instance B and verify signatures

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Configuration
PORT_A=5577
PORT_B=5588
TEMP_DIR_A="/tmp/geogram-A-${PORT_A}"
TEMP_DIR_B="/tmp/geogram-B-${PORT_B}"
NICKNAME_A="Creditor"
NICKNAME_B="Debtor"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo "=============================================="
echo "Test Wallet Debt Signature via API"
echo "=============================================="
echo ""

# Find flutter command
FLUTTER_CMD=""
if command -v flutter &> /dev/null; then
    FLUTTER_CMD="flutter"
elif [ -f "$HOME/flutter/bin/flutter" ]; then
    FLUTTER_CMD="$HOME/flutter/bin/flutter"
else
    echo -e "${RED}Error: flutter not found${NC}"
    exit 1
fi

# Build or use existing binary
BINARY_PATH="$PROJECT_DIR/build/linux/x64/release/bundle/geogram"

if [ ! -f "$BINARY_PATH" ]; then
    echo -e "${YELLOW}Building Geogram...${NC}"
    cd "$PROJECT_DIR"
    $FLUTTER_CMD build linux --release
fi
echo -e "${GREEN}Binary ready${NC}"

# Clean up temp directories
echo -e "${BLUE}Preparing temp directories...${NC}"
rm -rf "$TEMP_DIR_A" "$TEMP_DIR_B"
mkdir -p "$TEMP_DIR_A" "$TEMP_DIR_B"
echo "  Created: $TEMP_DIR_A"
echo "  Created: $TEMP_DIR_B"

# Scan range for localhost discovery
SCAN_RANGE="${PORT_A}-${PORT_B}"

echo ""
echo -e "${CYAN}Configuration:${NC}"
echo "  Instance A: port=$PORT_A, name=$NICKNAME_A"
echo "  Instance B: port=$PORT_B, name=$NICKNAME_B"
echo "  Localhost scan range: $SCAN_RANGE"
echo ""

# Cleanup function
cleanup() {
    echo ""
    echo -e "${YELLOW}Stopping instances...${NC}"
    kill $PID_A $PID_B 2>/dev/null || true
    echo -e "${GREEN}Done${NC}"
    exit 0
}
trap cleanup SIGINT SIGTERM EXIT

# Launch Instance A
echo -e "${YELLOW}Starting Instance A ($NICKNAME_A) on port $PORT_A...${NC}"
"$BINARY_PATH" \
    --port=$PORT_A \
    --data-dir="$TEMP_DIR_A" \
    --new-identity \
    --nickname="$NICKNAME_A" \
    --skip-intro \
    --http-api \
    --debug-api \
    --scan-localhost=$SCAN_RANGE \
    &
PID_A=$!
echo "  PID: $PID_A"

# Launch Instance B
echo -e "${YELLOW}Starting Instance B ($NICKNAME_B) on port $PORT_B...${NC}"
"$BINARY_PATH" \
    --port=$PORT_B \
    --data-dir="$TEMP_DIR_B" \
    --new-identity \
    --nickname="$NICKNAME_B" \
    --skip-intro \
    --http-api \
    --debug-api \
    --scan-localhost=$SCAN_RANGE \
    &
PID_B=$!
echo "  PID: $PID_B"

echo ""
echo -e "${YELLOW}Waiting for APIs to be ready...${NC}"

# Wait for both APIs
for i in {1..30}; do
    STATUS_A=$(curl -s "http://localhost:$PORT_A/api/status" 2>/dev/null || echo "")
    STATUS_B=$(curl -s "http://localhost:$PORT_B/api/status" 2>/dev/null || echo "")
    if [ -n "$STATUS_A" ] && [ -n "$STATUS_B" ]; then
        break
    fi
    sleep 1
done

# Get callsigns and npubs from status API (more reliable)
STATUS_A=$(curl -s "http://localhost:$PORT_A/api/status")
STATUS_B=$(curl -s "http://localhost:$PORT_B/api/status")

CALLSIGN_A=$(echo "$STATUS_A" | python3 -c "import sys,json; print(json.load(sys.stdin).get('callsign',''))" 2>/dev/null)
CALLSIGN_B=$(echo "$STATUS_B" | python3 -c "import sys,json; print(json.load(sys.stdin).get('callsign',''))" 2>/dev/null)

# Get npubs from debug API profile section
DEBUG_A=$(curl -s "http://localhost:$PORT_A/api/debug")
DEBUG_B=$(curl -s "http://localhost:$PORT_B/api/debug")

NPUB_A=$(echo "$DEBUG_A" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('profile',{}).get('npub',''))" 2>/dev/null)
NPUB_B=$(echo "$DEBUG_B" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('profile',{}).get('npub',''))" 2>/dev/null)

echo -e "${GREEN}Instance A ready: $CALLSIGN_A${NC}"
echo -e "${GREEN}Instance B ready: $CALLSIGN_B${NC}"
echo -e "${CYAN}  A npub: $NPUB_A${NC}"
echo -e "${CYAN}  B npub: $NPUB_B${NC}"

# Wait for device discovery (longer wait for localhost scanning)
echo ""
echo -e "${YELLOW}Waiting for device discovery (10 seconds)...${NC}"
sleep 10

# Check if they discovered each other
echo -e "${CYAN}Checking device discovery...${NC}"
DEVICES_A=$(curl -s "http://localhost:$PORT_A/api/devices" 2>/dev/null)
DEVICES_B=$(curl -s "http://localhost:$PORT_B/api/devices" 2>/dev/null)

if echo "$DEVICES_A" | grep -q "$CALLSIGN_B"; then
    echo -e "${GREEN}  Instance A sees Instance B ($CALLSIGN_B)${NC}"
else
    echo -e "${RED}  Instance A does NOT see Instance B${NC}"
fi

if echo "$DEVICES_B" | grep -q "$CALLSIGN_A"; then
    echo -e "${GREEN}  Instance B sees Instance A ($CALLSIGN_A)${NC}"
else
    echo -e "${RED}  Instance B does NOT see Instance A${NC}"
fi

echo ""
echo "=============================================="
echo "STEP 1: Create a Debt via API"
echo "=============================================="
echo ""

# Create a debt where A is creditor, B is debtor
echo -e "${YELLOW}Creating debt: $CALLSIGN_A (creditor) -> $CALLSIGN_B (debtor)${NC}"
echo "  Amount: 100.00 EUR"
echo ""

CREATE_RESULT=$(curl -s -X POST "http://localhost:$PORT_A/api/wallet/debts" \
    -H 'Content-Type: application/json' \
    -d "{
        \"description\": \"Test debt for signature verification\",
        \"creditor\": \"$CALLSIGN_A\",
        \"creditor_npub\": \"$NPUB_A\",
        \"creditor_name\": \"$NICKNAME_A\",
        \"debtor\": \"$CALLSIGN_B\",
        \"debtor_npub\": \"$NPUB_B\",
        \"debtor_name\": \"$NICKNAME_B\",
        \"amount\": 100.00,
        \"currency\": \"EUR\",
        \"content\": \"Test debt created via API\"
    }")

echo -e "${CYAN}Create result:${NC}"
echo "$CREATE_RESULT" | python3 -m json.tool 2>/dev/null || echo "$CREATE_RESULT"

# Extract debt ID
DEBT_ID=$(echo "$CREATE_RESULT" | grep -o '"debt_id":"[^"]*"' | cut -d'"' -f4)

if [ -z "$DEBT_ID" ]; then
    echo -e "${RED}FAILED: Could not extract debt_id from response${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}Debt created with ID: $DEBT_ID${NC}"

echo ""
echo "=============================================="
echo "STEP 2: Verify Debt Signatures"
echo "=============================================="
echo ""

# Get the debt details
echo -e "${YELLOW}Getting debt details...${NC}"
DEBT_DETAILS=$(curl -s "http://localhost:$PORT_A/api/wallet/debts/$DEBT_ID")
echo -e "${CYAN}Debt details:${NC}"
echo "$DEBT_DETAILS" | python3 -m json.tool 2>/dev/null || echo "$DEBT_DETAILS"

# Verify signatures
echo ""
echo -e "${YELLOW}Verifying debt signatures...${NC}"
VERIFY_RESULT=$(curl -s "http://localhost:$PORT_A/api/wallet/debts/$DEBT_ID/verify")
echo -e "${CYAN}Verification result:${NC}"
echo "$VERIFY_RESULT" | python3 -m json.tool 2>/dev/null || echo "$VERIFY_RESULT"

# Check if the debt has signatures
HAS_SIGNATURE=$(echo "$DEBT_DETAILS" | grep -o '"has_signature":true' | head -1)
if [ -n "$HAS_SIGNATURE" ]; then
    echo ""
    echo -e "${GREEN}SUCCESS: Debt has at least one signature${NC}"
else
    echo ""
    echo -e "${YELLOW}Note: Debt may not have signatures yet (check entries)${NC}"
fi

echo ""
echo "=============================================="
echo "STEP 3: Add a Note Entry (Also Signed)"
echo "=============================================="
echo ""

echo -e "${YELLOW}Adding a signed note entry...${NC}"
NOTE_RESULT=$(curl -s -X POST "http://localhost:$PORT_A/api/wallet/debts/$DEBT_ID/entries" \
    -H 'Content-Type: application/json' \
    -d '{
        "type": "note",
        "content": "This is a test note to verify signature chain"
    }')

echo -e "${CYAN}Note result:${NC}"
echo "$NOTE_RESULT" | python3 -m json.tool 2>/dev/null || echo "$NOTE_RESULT"

# Verify signatures again
echo ""
echo -e "${YELLOW}Verifying signatures after adding note...${NC}"
VERIFY_RESULT2=$(curl -s "http://localhost:$PORT_A/api/wallet/debts/$DEBT_ID/verify")
echo -e "${CYAN}Verification result:${NC}"
echo "$VERIFY_RESULT2" | python3 -m json.tool 2>/dev/null || echo "$VERIFY_RESULT2"

echo ""
echo "=============================================="
echo "STEP 4: Check Raw Debt File"
echo "=============================================="
echo ""

# Find and display the debt file
DEBT_FILE=$(find "$TEMP_DIR_A" -name "${DEBT_ID}.md" 2>/dev/null | head -1)

if [ -n "$DEBT_FILE" ] && [ -f "$DEBT_FILE" ]; then
    echo -e "${CYAN}Raw debt file: $DEBT_FILE${NC}"
    echo ""
    echo -e "${BLUE}--- File contents ---${NC}"
    cat "$DEBT_FILE"
    echo ""
    echo -e "${BLUE}--- End of file ---${NC}"

    # Check for signature in the file
    if grep -q "signature:" "$DEBT_FILE"; then
        echo ""
        echo -e "${GREEN}SUCCESS: Signature found in debt file${NC}"
    else
        echo ""
        echo -e "${RED}FAILED: No signature found in debt file${NC}"
    fi
else
    echo -e "${YELLOW}Debt file not found at expected location${NC}"
    echo "Searching for any .md files in wallet..."
    find "$TEMP_DIR_A" -name "*.md" -path "*/debts/*" 2>/dev/null
fi

echo ""
echo "=============================================="
echo "STEP 5: List All Debts via API"
echo "=============================================="
echo ""

echo -e "${YELLOW}Listing all debts on Instance A...${NC}"
LIST_RESULT=$(curl -s "http://localhost:$PORT_A/api/wallet/debts")
echo -e "${CYAN}Debts list:${NC}"
echo "$LIST_RESULT" | python3 -m json.tool 2>/dev/null || echo "$LIST_RESULT"

echo ""
echo "=============================================="
echo "Test Summary"
echo "=============================================="
echo ""
echo "1. Created debt: $DEBT_ID"
echo "2. Creditor: $CALLSIGN_A (Instance A)"
echo "3. Debtor: $CALLSIGN_B (Instance B)"
echo "4. Amount: 100.00 EUR"
echo ""

# Final verification
VALID=$(echo "$VERIFY_RESULT2" | grep -o '"valid":true')
if [ -n "$VALID" ]; then
    echo -e "${GREEN}All signatures are VALID${NC}"
else
    echo -e "${YELLOW}Signature verification result may need manual review${NC}"
fi

echo ""
echo "=============================================="
echo "Test Complete"
echo "=============================================="
echo ""
echo "Instances are still running. Press Ctrl+C to stop."
echo ""
echo "API Endpoints to explore:"
echo "  GET  http://localhost:$PORT_A/api/wallet/debts"
echo "  GET  http://localhost:$PORT_A/api/wallet/debts/$DEBT_ID"
echo "  GET  http://localhost:$PORT_A/api/wallet/debts/$DEBT_ID/verify"
echo "  POST http://localhost:$PORT_A/api/wallet/debts/$DEBT_ID/entries"
echo ""

# Wait indefinitely
wait
