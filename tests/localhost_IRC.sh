#!/bin/sh
# Geogram IRC Bridge Development Server
#
# This script launches a temporary Geogram station with IRC server enabled
# for testing and development purposes.
#
# Usage:
#   ./tests/localhost_IRC.sh
#
# Prerequisites:
#   - Build CLI: ./launch-cli.sh --build-only

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Configuration
DATA_DIR="/tmp/geogram-irc-dev"
API_PORT=6000
IRC_PORT=6667
STATION_URL="localhost"

printf "${BLUE}==============================================\n"
printf "  Geogram IRC Bridge Development Server\n"
printf "==============================================${NC}\n"
printf "\n"

cd "$PROJECT_DIR"

# Check if CLI exists, build if needed
CLI_PATH="build/geogram-cli"
if [ ! -f "$CLI_PATH" ]; then
    printf "${YELLOW}CLI build not found, building now...${NC}\n"
    ./launch-cli.sh --build-only

    if [ ! -f "$CLI_PATH" ]; then
        printf "${RED}Error: CLI build failed${NC}\n"
        exit 1
    fi

    printf "${GREEN}✓ CLI build complete${NC}\n"
    echo ""
fi

# Clean up old data
if [ -d "$DATA_DIR" ]; then
    printf "${YELLOW}Cleaning up old data...${NC}\n"
    rm -rf "$DATA_DIR"
fi

printf "${CYAN}Configuration:${NC}\n"
echo "  Data directory: $DATA_DIR"
echo "  API server:     http://$STATION_URL:$API_PORT"
echo "  IRC server:     irc://$STATION_URL:$IRC_PORT"
echo ""

# Cleanup function
cleanup() {
    echo ""
    printf "${YELLOW}Shutting down...${NC}\n"

    if [ -n "$STATION_PID" ]; then
        kill $STATION_PID 2>/dev/null || true
    fi

    if [ -n "$PIPE_PID" ]; then
        kill $PIPE_PID 2>/dev/null || true
    fi

    if [ -n "$PIPE_FILE" ] && [ -p "$PIPE_FILE" ]; then
        rm -f "$PIPE_FILE"
    fi

    printf "${GREEN}Cleanup complete${NC}\n"
    exit 0
}

trap cleanup INT TERM

# Launch station
printf "${GREEN}Starting Geogram Station with IRC server...${NC}\n"
echo ""

# Create a named pipe for CLI input
PIPE_FILE="/tmp/geogram-irc-cli-pipe-$$"
mkfifo "$PIPE_FILE"

# Launch CLI with input from pipe
$CLI_PATH \
    --port=$API_PORT \
    --data-dir=$DATA_DIR \
    --new-identity \
    --identity-type=station \
    --skip-intro \
    --http-api \
    --debug-api \
    --irc-server \
    --irc-port=$IRC_PORT \
    --nickname=DevStation \
    < "$PIPE_FILE" &

STATION_PID=$!

# Send the 'station start' command to start the station server
(
    sleep 2
    echo "station start" > "$PIPE_FILE"
    # Keep pipe open
    sleep infinity > "$PIPE_FILE"
) &
PIPE_PID=$!

# Wait for startup
printf "${CYAN}Waiting for services to start...${NC}\n"
sleep 3

# Check if process is still running
if ! kill -0 $STATION_PID 2>/dev/null; then
    printf "${RED}Error: Station process died during startup${NC}\n"
    echo "Check the logs above for errors"
    exit 1
fi

# Wait for API server
MAX_WAIT=15
WAITED=0
API_READY=false

while [ $WAITED -lt $MAX_WAIT ]; do
    if curl -s "http://$STATION_URL:$API_PORT/api/" > /dev/null 2>&1; then
        API_READY=true
        break
    fi
    sleep 1
    WAITED=$((WAITED + 1))
    echo -n "."
done
echo ""

if [ "$API_READY" = false ]; then
    printf "${RED}Error: API server did not start within $MAX_WAIT seconds${NC}\n"
    kill $STATION_PID 2>/dev/null || true
    exit 1
fi

printf "${GREEN}✓ API server ready${NC}\n"

# Wait for IRC server
IRC_READY=false
WAITED=0

while [ $WAITED -lt $MAX_WAIT ]; do
    if nc -z -w1 $STATION_URL $IRC_PORT 2>/dev/null; then
        IRC_READY=true
        break
    fi
    sleep 1
    WAITED=$((WAITED + 1))
done

if [ "$IRC_READY" = false ]; then
    printf "${RED}Error: IRC server did not start within $MAX_WAIT seconds${NC}\n"
    kill $STATION_PID 2>/dev/null || true
    exit 1
fi

printf "${GREEN}✓ IRC server ready${NC}\n"
echo ""

# Get station info
STATION_INFO=$(curl -s "http://$STATION_URL:$API_PORT/api/" 2>/dev/null)
CALLSIGN=$(echo "$STATION_INFO" | grep -o '"callsign":"[^"]*"' | cut -d'"' -f4 || echo "UNKNOWN")
VERSION=$(echo "$STATION_INFO" | grep -o '"version":"[^"]*"' | cut -d'"' -f4 || echo "unknown")

printf "${MAGENTA}Station Information:${NC}\n"
echo "  Callsign: $CALLSIGN"
echo "  Version:  $VERSION"
echo ""

# Get chat rooms
printf "${MAGENTA}Fetching available chat rooms...${NC}\n"
ROOMS_JSON=$(curl -s "http://$STATION_URL:$API_PORT/api/chat/" 2>/dev/null)
ROOM_COUNT=$(echo "$ROOMS_JSON" | grep -o '"rooms":\[' | wc -l)

if [ "$ROOM_COUNT" -gt 0 ]; then
    # Parse room information
    echo "$ROOMS_JSON" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    rooms = data.get('rooms', [])

    print('${CYAN}Available Chat Rooms:${NC}')
    print('')

    for room in rooms:
        room_id = room.get('id', 'unknown')
        name = room.get('name', 'Unnamed')
        visibility = room.get('visibility', 'UNKNOWN')
        room_type = room.get('type', 'unknown')

        # IRC channel name
        irc_channel = f'#{room_id}'

        # Color based on visibility
        if visibility == 'PUBLIC':
            vis_color = '${GREEN}'
        elif visibility == 'PRIVATE':
            vis_color = '${RED}'
        else:
            vis_color = '${YELLOW}'

        print(f'  {irc_channel}')
        print(f'    Name:       {name}')
        print(f'    Visibility: {vis_color}{visibility}${NC}')
        print(f'    Type:       {room_type}')
        print('')
except Exception as e:
    print('Could not parse room data:', str(e), file=sys.stderr)
" 2>/dev/null || printf "${YELLOW}  Could not parse room data${NC}\n"
else
    printf "${YELLOW}  No chat rooms found${NC}\n"
    echo "  Creating default 'main' room..."

    # The station should auto-create a main room on first use
    # For now, just note it will be created when first message is sent
    echo ""
    printf "${CYAN}Available Chat Rooms:${NC}\n"
    echo ""
    echo "  #main"
    echo "    Name:       Main Chat"
    echo "    Visibility: ${GREEN}PUBLIC${NC}"
    echo "    Type:       main"
    echo "    (Will be created on first message)"
    echo ""
fi

# Connection instructions
printf "${BLUE}==============================================\n"
echo "  IRC Connection Information"
printf "==============================================${NC}\n"
echo ""
printf "${CYAN}Server:${NC}  $STATION_URL\n"
printf "${CYAN}Port:${NC}    $IRC_PORT\n"
echo ""

printf "${MAGENTA}Connect with IRC client:${NC}\n"
echo ""

printf "${CYAN}irssi:${NC}\n"
echo "  irssi -c $STATION_URL -p $IRC_PORT"
echo "  /nick YourNick"
echo "  /join #main"
echo ""

printf "${CYAN}WeeChat:${NC}\n"
echo "  weechat"
echo "  /server add geogram $STATION_URL/$IRC_PORT"
echo "  /connect geogram"
echo "  /nick YourNick"
echo "  /join #main"
echo ""

printf "${CYAN}HexChat:${NC}\n"
echo "  Network List → Add"
echo "  Server: $STATION_URL/$IRC_PORT"
echo "  Nickname: YourNick"
echo "  Connect and /join #main"
echo ""

printf "${CYAN}nc (netcat) for quick test:${NC}\n"
echo "  nc $STATION_URL $IRC_PORT"
echo "  Then type: NICK TestUser"
echo "  Then type: USER test 0 * :Test User"
echo "  Then type: JOIN #main"
echo "  Then type: PRIVMSG #main :Hello from IRC!"
echo ""

printf "${BLUE}==============================================\n"
echo "  API Endpoints"
printf "==============================================${NC}\n"
echo ""
printf "${CYAN}Chat API:${NC}\n"
echo "  List rooms:     curl http://$STATION_URL:$API_PORT/api/chat/"
echo "  Get messages:   curl http://$STATION_URL:$API_PORT/api/chat/main/messages"
echo "  Post message:   curl -X POST http://$STATION_URL:$API_PORT/api/chat/main/messages \\"
echo "                    -H 'Content-Type: application/json' \\"
echo "                    -d '{\"content\":\"Hello from API\"}'"
echo ""
printf "${CYAN}Station Info:${NC}\n"
echo "  curl http://$STATION_URL:$API_PORT/api/"
echo ""

printf "${GREEN}==============================================\n"
echo "  Server is running!"
printf "==============================================${NC}\n"
echo ""
printf "${YELLOW}Press Ctrl+C to stop the server${NC}\n"
echo ""

# Keep running
wait $STATION_PID
