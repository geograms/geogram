#!/bin/bash
# End-to-End Wallet Signature Test
#
# Tests the COMPLETE signature workflow:
# 1. Instance A (creditor) creates a debt with Instance B as debtor
# 2. Instance A sends the debt to Instance B via sync API
# 3. Instance B receives and approves the debt (signs it)
# 4. Both parties now have valid signatures
#
# This tests the full P2P signature flow as specified in wallet-format-specification.md

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Configuration
PORT_A=5577
PORT_B=5588
TEMP_DIR_A="/tmp/geogram-A-${PORT_A}"
TEMP_DIR_B="/tmp/geogram-B-${PORT_B}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo "=============================================="
echo "End-to-End Wallet Signature Test"
echo "=============================================="
echo ""

# Binary
BINARY_PATH="$PROJECT_DIR/build/linux/x64/release/bundle/geogram"

if [ ! -f "$BINARY_PATH" ]; then
    echo -e "${RED}Binary not found. Building...${NC}"
    cd "$PROJECT_DIR"
    ~/flutter/bin/flutter build linux --release
fi

# Clean up temp directories
rm -rf "$TEMP_DIR_A" "$TEMP_DIR_B"
mkdir -p "$TEMP_DIR_A" "$TEMP_DIR_B"

# Cleanup function
cleanup() {
    echo ""
    echo -e "${YELLOW}Stopping instances...${NC}"
    kill $PID_A $PID_B 2>/dev/null || true
    echo -e "${GREEN}Done${NC}"
}
trap cleanup EXIT

# Start Instance A (Creditor)
echo -e "${YELLOW}Starting Instance A (Creditor) on port $PORT_A...${NC}"
"$BINARY_PATH" \
    --port=$PORT_A \
    --data-dir="$TEMP_DIR_A" \
    --new-identity \
    --nickname="Creditor" \
    --skip-intro \
    --http-api \
    --debug-api \
    --scan-localhost=${PORT_A}-${PORT_B} \
    &
PID_A=$!

# Start Instance B (Debtor)
echo -e "${YELLOW}Starting Instance B (Debtor) on port $PORT_B...${NC}"
"$BINARY_PATH" \
    --port=$PORT_B \
    --data-dir="$TEMP_DIR_B" \
    --new-identity \
    --nickname="Debtor" \
    --skip-intro \
    --http-api \
    --debug-api \
    --scan-localhost=${PORT_A}-${PORT_B} \
    &
PID_B=$!

# Wait for APIs
echo -e "${YELLOW}Waiting for APIs...${NC}"
for i in {1..30}; do
    STATUS_A=$(curl -s "http://localhost:$PORT_A/api/status" 2>/dev/null || echo "")
    STATUS_B=$(curl -s "http://localhost:$PORT_B/api/status" 2>/dev/null || echo "")
    if [ -n "$STATUS_A" ] && [ -n "$STATUS_B" ]; then
        break
    fi
    sleep 1
done

# Get callsigns
CALLSIGN_A=$(curl -s "http://localhost:$PORT_A/api/status" | python3 -c "import sys,json; print(json.load(sys.stdin).get('callsign',''))" 2>/dev/null)
CALLSIGN_B=$(curl -s "http://localhost:$PORT_B/api/status" | python3 -c "import sys,json; print(json.load(sys.stdin).get('callsign',''))" 2>/dev/null)

# Get npubs from debug API
DEBUG_A=$(curl -s "http://localhost:$PORT_A/api/debug")
DEBUG_B=$(curl -s "http://localhost:$PORT_B/api/debug")

NPUB_A=$(echo "$DEBUG_A" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('profile',{}).get('npub',''))" 2>/dev/null)
NPUB_B=$(echo "$DEBUG_B" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('profile',{}).get('npub',''))" 2>/dev/null)

echo -e "${GREEN}Instance A (Creditor): $CALLSIGN_A${NC}"
echo -e "${GREEN}Instance B (Debtor): $CALLSIGN_B${NC}"
echo -e "${CYAN}  A npub: $NPUB_A${NC}"
echo -e "${CYAN}  B npub: $NPUB_B${NC}"

# Wait for discovery
echo ""
echo -e "${YELLOW}Waiting for device discovery (8 seconds)...${NC}"
sleep 8

echo ""
echo "=============================================="
echo "STEP 1: Creditor Creates Debt"
echo "=============================================="
echo ""

echo -e "${YELLOW}[A] Creating debt where A is creditor, B is debtor...${NC}"
CREATE_RESULT=$(curl -s -X POST "http://localhost:$PORT_A/api/wallet/debts" \
    -H 'Content-Type: application/json' \
    -d "{
        \"description\": \"E2E Test Debt\",
        \"creditor\": \"$CALLSIGN_A\",
        \"creditor_npub\": \"$NPUB_A\",
        \"creditor_name\": \"Creditor\",
        \"debtor\": \"$CALLSIGN_B\",
        \"debtor_npub\": \"$NPUB_B\",
        \"debtor_name\": \"Debtor\",
        \"amount\": 100.00,
        \"currency\": \"EUR\"
    }")

DEBT_ID=$(echo "$CREATE_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('debt_id',''))" 2>/dev/null)

if [ -z "$DEBT_ID" ]; then
    echo -e "${RED}FAILED: Could not create debt${NC}"
    echo "$CREATE_RESULT"
    exit 1
fi

echo -e "${GREEN}Created debt: $DEBT_ID${NC}"
echo ""

# Get the raw debt file content for syncing
echo -e "${YELLOW}[A] Getting debt file content...${NC}"
DEBT_FILE="$TEMP_DIR_A/devices/$CALLSIGN_A/wallet/debts/${DEBT_ID}.md"
sleep 1  # Wait for file to be written

if [ ! -f "$DEBT_FILE" ]; then
    echo -e "${RED}FAILED: Debt file not found at $DEBT_FILE${NC}"
    find "$TEMP_DIR_A" -name "*.md" 2>/dev/null
    exit 1
fi

DEBT_CONTENT=$(cat "$DEBT_FILE")
echo -e "${CYAN}Debt file exists with $(wc -l < "$DEBT_FILE") lines${NC}"

echo ""
echo "=============================================="
echo "STEP 2: Send Debt to Debtor for Signing"
echo "=============================================="
echo ""

# Escape the content for JSON
ESCAPED_CONTENT=$(echo "$DEBT_CONTENT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')

echo -e "${YELLOW}[A->B] Sending debt to Instance B via sync API...${NC}"
SYNC_RESULT=$(curl -s -X POST "http://localhost:$PORT_B/api/wallet/sync" \
    -H 'Content-Type: application/json' \
    -d "{
        \"type\": \"debt_approval\",
        \"sender_callsign\": \"$CALLSIGN_A\",
        \"sender_npub\": \"$NPUB_A\",
        \"ledger\": $ESCAPED_CONTENT
    }")

echo "Sync result: $SYNC_RESULT"

REQUEST_ID=$(echo "$SYNC_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('request_id',''))" 2>/dev/null)

if [ -z "$REQUEST_ID" ]; then
    echo -e "${RED}FAILED: Could not send debt to debtor${NC}"
    exit 1
fi

echo -e "${GREEN}Sent to debtor, request ID: $REQUEST_ID${NC}"

echo ""
echo "=============================================="
echo "STEP 3: Check Pending Requests on Debtor"
echo "=============================================="
echo ""

echo -e "${YELLOW}[B] Listing pending requests...${NC}"
REQUESTS=$(curl -s "http://localhost:$PORT_B/api/wallet/requests")
echo "$REQUESTS" | python3 -m json.tool 2>/dev/null || echo "$REQUESTS"

REQUEST_COUNT=$(echo "$REQUESTS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null)
echo ""
echo -e "${CYAN}Pending requests: $REQUEST_COUNT${NC}"

echo ""
echo "=============================================="
echo "STEP 4: Debtor Approves the Debt"
echo "=============================================="
echo ""

echo -e "${YELLOW}[B] Approving request $REQUEST_ID...${NC}"
APPROVE_RESULT=$(curl -s -X POST "http://localhost:$PORT_B/api/wallet/requests/$REQUEST_ID/approve" \
    -H 'Content-Type: application/json' \
    -d '{}')

echo "Approve result: $APPROVE_RESULT"

APPROVE_SUCCESS=$(echo "$APPROVE_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('success',False))" 2>/dev/null)

if [ "$APPROVE_SUCCESS" != "True" ]; then
    echo -e "${RED}FAILED: Debtor could not approve the debt${NC}"
    # Continue anyway to see what happened
fi

echo ""
echo "=============================================="
echo "STEP 5: Send Signed Ledger Back to Creditor"
echo "=============================================="
echo ""

# Get the debtor's signed ledger and send back to creditor via HTTP API
# (simulates what P2P transport would do)
DEBT_FILE_B="$TEMP_DIR_B/devices/$CALLSIGN_B/wallet/debts/${DEBT_ID}.md"
sleep 1

if [ -f "$DEBT_FILE_B" ]; then
    echo -e "${YELLOW}[B->A] Sending signed ledger back to creditor via sync API...${NC}"
    DEBT_CONTENT_B=$(cat "$DEBT_FILE_B")
    ESCAPED_CONTENT_B=$(echo "$DEBT_CONTENT_B" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')

    MERGE_RESULT=$(curl -s -X POST "http://localhost:$PORT_A/api/wallet/sync" \
        -H 'Content-Type: application/json' \
        -d "{
            \"type\": \"amendmentApproval\",
            \"sender_callsign\": \"$CALLSIGN_B\",
            \"sender_npub\": \"$NPUB_B\",
            \"ledger\": $ESCAPED_CONTENT_B
        }")
    echo "Merge result: $MERGE_RESULT"

    AUTO_MERGED=$(echo "$MERGE_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('auto_merged',False))" 2>/dev/null)
    if [ "$AUTO_MERGED" == "True" ]; then
        echo -e "${GREEN}Signed ledger auto-merged successfully${NC}"
    fi
else
    echo -e "${RED}FAILED: Debtor's debt file not found at $DEBT_FILE_B${NC}"
fi

sleep 1

echo ""
echo "=============================================="
echo "STEP 6: Verify Both Parties Have Signed"
echo "=============================================="
echo ""

# Check debt on Instance A
echo -e "${YELLOW}[A] Checking debt on Creditor side...${NC}"
DEBT_A=$(curl -s "http://localhost:$PORT_A/api/wallet/debts/$DEBT_ID")
ENTRIES_A=$(echo "$DEBT_A" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('entries',[])))" 2>/dev/null)
echo "Entries on A: $ENTRIES_A"

# Check debt on Instance B
echo -e "${YELLOW}[B] Checking debts on Debtor side...${NC}"
DEBTS_B=$(curl -s "http://localhost:$PORT_B/api/wallet/debts")
echo "Debts on B:"
echo "$DEBTS_B" | python3 -m json.tool 2>/dev/null || echo "$DEBTS_B"

echo ""
echo "=============================================="
echo "STEP 7: Check Raw Files for Signatures"
echo "=============================================="
echo ""

echo -e "${CYAN}Creditor's debt file:${NC}"
if [ -f "$DEBT_FILE" ]; then
    cat "$DEBT_FILE"

    SIG_COUNT=$(grep -c "signature:" "$DEBT_FILE" 2>/dev/null || echo "0")
    echo ""
    echo -e "${CYAN}Signatures in file: $SIG_COUNT${NC}"
else
    echo -e "${RED}File not found${NC}"
fi

echo ""
echo -e "${CYAN}Debtor's debt files:${NC}"
find "$TEMP_DIR_B" -name "*.md" -path "*/debts/*" 2>/dev/null | while read f; do
    echo "File: $f"
    cat "$f"
    echo ""
done

echo ""
echo "=============================================="
echo "Test Summary"
echo "=============================================="
echo ""
echo "Creditor: $CALLSIGN_A"
echo "Debtor: $CALLSIGN_B"
echo "Debt ID: $DEBT_ID"
echo "Request ID: $REQUEST_ID"

if [ "$SIG_COUNT" -ge "2" ]; then
    echo ""
    echo -e "${GREEN}SUCCESS: Both parties have signed the debt!${NC}"
    EXIT_CODE=0
else
    echo ""
    echo -e "${YELLOW}Signatures found: $SIG_COUNT (expected 2 for full agreement)${NC}"
    EXIT_CODE=1
fi

echo ""
echo "Test complete. Stopping instances..."
exit $EXIT_CODE
