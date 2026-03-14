#!/usr/bin/env bash
# Send an APRS message via the Geogram KV4P HTTP API.
# Usage: ./aprs.sh <message>
# Example: ./aprs.sh "hello world"

DEVICE_IP="${GEOGRAM_IP:-192.168.178.78}"
FROM="${APRS_FROM:-X3XU3F}"
TO="${APRS_TO:-APRS}"

if [ -z "$1" ]; then
    echo "Usage: $0 <message>"
    echo "  env GEOGRAM_IP=192.168.x.x  (default: $DEVICE_IP)"
    echo "  env APRS_FROM=CALLSIGN      (default: $FROM)"
    echo "  env APRS_TO=CALLSIGN        (default: $TO)"
    exit 1
fi

MESSAGE="$*"

curl -s -m 15 -X POST "http://${DEVICE_IP}/api/aprs" \
    -d "from=${FROM}&to=${TO}&message=$(printf '%s' "$MESSAGE" | jq -sRr @uri)"
echo
