#!/bin/bash
#
# Geogram CLI Server Monitor
# Connects to the remote server's screen session for live monitoring
#

REMOTE_HOST="root@p2p.radio"
SCREEN_NAME="geogram"

echo "Connecting to geogram relay console on $REMOTE_HOST..."
echo "Press Ctrl+A, D to detach from screen (leave server running)"
echo ""

ssh -t "$REMOTE_HOST" "screen -r $SCREEN_NAME || (echo 'Screen session not found. Starting new session...' && cd /root/geogram && screen -S $SCREEN_NAME ./geogram-cli --data-dir=/root/geogram)"
