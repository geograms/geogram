#!/bin/bash
#
# Geogram CLI Deployment Script
# Compiles, uploads, and deploys geogram-cli to p2p.radio
#

# Configuration
REMOTE_HOST="root@p2p.radio"
REMOTE_DIR="/root/geogram"
REMOTE_BINARY="$REMOTE_DIR/geogram-cli"
SCREEN_NAME="geogram"
PORT=80

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Local binary path
LOCAL_BINARY="$SCRIPT_DIR/build/geogram-cli"

echo "=============================================="
echo "  Geogram CLI Deployment"
echo "=============================================="
echo ""
echo "Target: $REMOTE_HOST:$REMOTE_DIR"
echo "Port: $PORT"
echo ""

# Step 1: Build the CLI binary
echo -e "${YELLOW}[1/6] Building CLI binary...${NC}"
if ! ./launch-cli.sh --build-only; then
    echo -e "${RED}Error: Build failed${NC}"
    exit 1
fi

if [ ! -f "$LOCAL_BINARY" ]; then
    echo -e "${RED}Error: Binary not found at $LOCAL_BINARY${NC}"
    exit 1
fi

echo -e "${GREEN}Build complete.${NC}"
echo ""

# Step 2: Kill existing instances on remote
echo -e "${YELLOW}[2/6] Stopping existing instances...${NC}"
ssh "$REMOTE_HOST" "screen -S $SCREEN_NAME -X quit >/dev/null 2>&1; pkill -f geogram-cli >/dev/null 2>&1; sleep 1" || true
echo -e "${GREEN}Existing instances stopped.${NC}"
echo ""

# Step 3: Upload binary
echo -e "${YELLOW}[3/6] Uploading binary to $REMOTE_HOST...${NC}"
ssh "$REMOTE_HOST" "mkdir -p $REMOTE_DIR"
if ! scp "$LOCAL_BINARY" "$REMOTE_HOST:$REMOTE_BINARY"; then
    echo -e "${RED}Error: Failed to upload binary${NC}"
    exit 1
fi
ssh "$REMOTE_HOST" "chmod +x $REMOTE_BINARY"
echo -e "${GREEN}Upload complete.${NC}"
echo ""

# Step 4: Check if setup is needed (empty deployment folder)
echo -e "${YELLOW}[4/6] Checking deployment status...${NC}"

NEEDS_SETUP=$(ssh "$REMOTE_HOST" "test -f $REMOTE_DIR/config.json && echo 'no' || echo 'yes'")

if [ "$NEEDS_SETUP" = "yes" ]; then
    echo -e "${CYAN}"
    echo "=============================================="
    echo "  First-time Setup Required"
    echo "=============================================="
    echo -e "${NC}"
    echo "No existing configuration found. Running setup wizard..."
    echo ""

    # Ask for relay name/description
    echo -e "${YELLOW}--- RELAY IDENTITY ---${NC}"
    printf "Relay name [${CYAN}p2p.radio${NC}]: "
    read RELAY_NAME
    RELAY_NAME=${RELAY_NAME:-"p2p.radio"}

    printf "Description [${CYAN}Geogram Relay Server${NC}]: "
    read RELAY_DESC
    RELAY_DESC=${RELAY_DESC:-"Geogram Relay Server"}
    echo ""

    # Ask for location
    echo -e "${YELLOW}--- LOCATION (optional, press ENTER to skip) ---${NC}"
    printf "Location name (e.g., Lisbon, Portugal): "
    read RELAY_LOCATION

    RELAY_LAT=""
    RELAY_LON=""
    if [ -n "$RELAY_LOCATION" ]; then
        printf "Latitude (e.g., 38.7223): "
        read RELAY_LAT
        printf "Longitude (e.g., -9.1393): "
        read RELAY_LON
    fi
    echo ""

    # Ask for SSL configuration
    echo -e "${YELLOW}--- SSL/HTTPS CONFIGURATION ---${NC}"
    printf "Domain for SSL [${CYAN}p2p.radio${NC}]: "
    read SSL_DOMAIN
    SSL_DOMAIN=${SSL_DOMAIN:-"p2p.radio"}

    # Auto-generate email from domain
    SSL_EMAIL="admin@${SSL_DOMAIN}"
    ENABLE_SSL="true"
    echo -e "SSL Email: ${CYAN}${SSL_EMAIL}${NC} (auto-generated)"
    echo ""

    # Ask for network role
    echo -e "${YELLOW}--- NETWORK ROLE ---${NC}"
    echo "Select relay role:"
    echo "  1) Root Relay - Primary relay (accepts node connections)"
    echo "  2) Node Relay - Connects to an existing root relay"
    printf "Enter choice (1 or 2) [${CYAN}1${NC}]: "
    read ROLE_CHOICE
    ROLE_CHOICE=${ROLE_CHOICE:-1}

    RELAY_ROLE="root"
    PARENT_URL=""
    if [ "$ROLE_CHOICE" = "2" ]; then
        RELAY_ROLE="node"
        printf "Parent relay URL (e.g., wss://relay.example.com): "
        read PARENT_URL
    fi
    echo ""

    # Generate NOSTR keys using openssl
    echo -e "${YELLOW}Generating cryptographic keys...${NC}"

    # Generate a random 32-byte private key
    PRIVKEY_HEX=$(openssl rand -hex 32)

    # For simplicity, we'll use a placeholder npub/nsec format
    # The actual bech32 encoding would be done by the CLI
    NPUB="npub1$(echo $PRIVKEY_HEX | cut -c1-58)"
    NSEC="nsec1$(echo $PRIVKEY_HEX)"

    # Generate X3 callsign from npub (simplified - take chars and convert)
    CALLSIGN="X3$(echo $PRIVKEY_HEX | tr 'a-f' 'A-F' | cut -c1-4)"

    echo -e "${GREEN}Generated callsign: $CALLSIGN${NC}"
    echo ""

    # Show summary
    echo -e "${CYAN}"
    echo "=============================================="
    echo "  Setup Summary"
    echo "=============================================="
    echo -e "${NC}"
    echo -e "Relay Name:    ${CYAN}$RELAY_NAME${NC}"
    echo -e "Description:   ${CYAN}$RELAY_DESC${NC}"
    echo -e "Callsign:      ${CYAN}$CALLSIGN${NC}"
    echo -e "Role:          ${CYAN}$RELAY_ROLE${NC}"
    if [ -n "$RELAY_LOCATION" ]; then
        echo -e "Location:      ${CYAN}$RELAY_LOCATION${NC}"
    fi
    if [ "$ENABLE_SSL" = "true" ]; then
        echo -e "SSL Domain:    ${CYAN}$SSL_DOMAIN${NC}"
        echo -e "SSL Email:     ${CYAN}$SSL_EMAIL${NC}"
    fi
    echo ""

    read -p "Proceed with this configuration? (y/n) [y]: " CONFIRM
    CONFIRM=${CONFIRM:-y}

    if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
        echo -e "${YELLOW}Setup cancelled.${NC}"
        exit 0
    fi

    echo ""
    echo -e "${YELLOW}Creating configuration files...${NC}"

    # Build JSON for optional fields
    LAT_JSON="${RELAY_LAT:-null}"
    LON_JSON="${RELAY_LON:-null}"
    LOCATION_JSON="null"
    [ -n "$RELAY_LOCATION" ] && LOCATION_JSON="\"$RELAY_LOCATION\""
    PARENT_JSON="null"
    [ -n "$PARENT_URL" ] && PARENT_JSON="\"$PARENT_URL\""
    SSL_DOMAIN_JSON="null"
    [ -n "$SSL_DOMAIN" ] && SSL_DOMAIN_JSON="\"$SSL_DOMAIN\""
    SSL_EMAIL_JSON="null"
    [ -n "$SSL_EMAIL" ] && SSL_EMAIL_JSON="\"$SSL_EMAIL\""
    CREATED_DATE=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)

    # Create relay_config.json
    ssh "$REMOTE_HOST" "cat > $REMOTE_DIR/relay_config.json" << RELAY_EOF
{
  "httpPort": $PORT,
  "enabled": true,
  "tileServerEnabled": true,
  "osmFallbackEnabled": true,
  "maxZoomLevel": 15,
  "maxCacheSizeMB": 500,
  "name": "$RELAY_NAME",
  "description": "$RELAY_DESC",
  "location": $LOCATION_JSON,
  "latitude": $LAT_JSON,
  "longitude": $LON_JSON,
  "npub": "$NPUB",
  "nsec": "$NSEC",
  "enableAprs": false,
  "enableCors": true,
  "httpRequestTimeout": 30000,
  "maxConnectedDevices": 100,
  "relayRole": "$RELAY_ROLE",
  "parentRelayUrl": $PARENT_JSON,
  "setupComplete": true,
  "enableSsl": $ENABLE_SSL,
  "sslDomain": $SSL_DOMAIN_JSON,
  "sslEmail": $SSL_EMAIL_JSON,
  "sslAutoRenew": true,
  "httpsPort": 443
}
RELAY_EOF

    # Create config.json with relay profile
    ssh "$REMOTE_HOST" "cat > $REMOTE_DIR/config.json" << CONFIG_EOF
{
  "activeProfileId": "relay-profile",
  "profiles": [
    {
      "id": "relay-profile",
      "name": "$RELAY_NAME",
      "callsign": "$CALLSIGN",
      "description": "$RELAY_DESC",
      "type": "relay",
      "npub": "$NPUB",
      "nsec": "$NSEC",
      "locationName": $LOCATION_JSON,
      "latitude": $LAT_JSON,
      "longitude": $LON_JSON,
      "port": $PORT,
      "relayRole": "$RELAY_ROLE",
      "parentRelayUrl": $PARENT_JSON,
      "tileServerEnabled": true,
      "osmFallbackEnabled": true,
      "enableAprs": false,
      "created": "$CREATED_DATE"
    }
  ]
}
CONFIG_EOF

    # Create required directories
    ssh "$REMOTE_HOST" "mkdir -p $REMOTE_DIR/devices $REMOTE_DIR/tiles $REMOTE_DIR/ssl $REMOTE_DIR/logs"

    echo -e "${GREEN}Configuration files created.${NC}"

    # If SSL is enabled, set up certificates
    if [ "$ENABLE_SSL" = "true" ]; then
        echo ""
        echo -e "${YELLOW}Setting up SSL certificates...${NC}"
        echo "The relay will automatically request SSL certificates from Let's Encrypt"
        echo "when it starts. Make sure port 80 is open for the ACME challenge."
        echo ""
    fi
else
    echo -e "${GREEN}Existing configuration found. Skipping setup.${NC}"
fi
echo ""

# Step 5: Start with screen
echo -e "${YELLOW}[5/6] Starting geogram-cli on port $PORT...${NC}"

# Start in screen
ssh "$REMOTE_HOST" "cd $REMOTE_DIR && screen -dmS $SCREEN_NAME ./geogram-cli --data-dir=$REMOTE_DIR"

# Wait for startup and send relay start command
sleep 2
ssh "$REMOTE_HOST" "screen -S $SCREEN_NAME -p 0 -X stuff 'relay start\n'" || true

echo -e "${GREEN}Started in screen session '$SCREEN_NAME'.${NC}"
echo ""

# Step 6: Test that it's online
echo -e "${YELLOW}[6/6] Testing deployment...${NC}"
sleep 3

# Test HTTP endpoint
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 "http://p2p.radio/api/status" 2>/dev/null || echo "000")

if [ "$HTTP_STATUS" = "200" ]; then
    echo -e "${GREEN}SUCCESS: Server is online and responding (HTTP $HTTP_STATUS)${NC}"
    echo ""

    # Check if SSL is enabled and wait for certificate
    STATUS_JSON=$(curl -s "http://p2p.radio/api/status" 2>/dev/null)
    HTTPS_ENABLED=$(echo "$STATUS_JSON" | grep -o '"https_enabled":true' || echo "")

    if [ -n "$HTTPS_ENABLED" ]; then
        echo -e "${YELLOW}SSL enabled, waiting for certificate request to complete...${NC}"
        for i in 1 2 3 4 5 6 7 8 9 10; do
            sleep 2
            STATUS_JSON=$(curl -s "http://p2p.radio/api/status" 2>/dev/null)
            HTTPS_RUNNING=$(echo "$STATUS_JSON" | grep -o '"https_running":true' || echo "")
            if [ -n "$HTTPS_RUNNING" ]; then
                echo -e "${GREEN}HTTPS is now running on port 443${NC}"
                break
            fi
            printf "."
        done
        echo ""
        if [ -z "$HTTPS_RUNNING" ]; then
            echo -e "${YELLOW}Note: HTTPS may still be starting (certificate request in progress)${NC}"
        fi
    fi

    # Show status details
    echo ""
    echo "Server status:"
    curl -s "http://p2p.radio/api/status" 2>/dev/null | head -c 600
    echo ""
    echo ""
    echo "Endpoints:"
    echo "  HTTP:      http://p2p.radio/api/status"
    if [ -n "$HTTPS_RUNNING" ]; then
        echo "  HTTPS:     https://p2p.radio/api/status"
    fi
    echo "  WebSocket: ws://p2p.radio/"
    echo ""
    echo "Management:"
    echo "  Monitor: ssh $REMOTE_HOST 'screen -r $SCREEN_NAME'"
    echo "  Stop:    ssh $REMOTE_HOST 'screen -S $SCREEN_NAME -X quit'"
else
    echo -e "${YELLOW}WARNING: Server may still be starting (HTTP $HTTP_STATUS)${NC}"
    echo ""
    echo "Checking screen session..."
    ssh "$REMOTE_HOST" "screen -ls" || true
    echo ""
    echo "Try again in a few seconds:"
    echo "  curl http://p2p.radio/api/status"
    echo ""
    echo "To debug: ssh $REMOTE_HOST 'screen -r $SCREEN_NAME'"
fi

echo ""
echo "=============================================="
echo "  Deployment complete"
echo "=============================================="
