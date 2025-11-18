#!/bin/bash

# Script to read the application log file
# Log location: ~/Documents/geogram/log.txt

LOG_FILE="$HOME/Documents/geogram/log.txt"

if [ ! -f "$LOG_FILE" ]; then
    echo "❌ Log file not found at: $LOG_FILE"
    echo ""
    echo "The log file will be created when you run the app."
    exit 1
fi

echo "📄 Reading Geogram log file..."
echo "Location: $LOG_FILE"
echo "Size: $(du -h "$LOG_FILE" | cut -f1)"
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Check if we want to follow the log (tail -f style)
if [ "$1" == "-f" ] || [ "$1" == "--follow" ]; then
    tail -f "$LOG_FILE"
elif [ "$1" == "-n" ]; then
    # Show last N lines
    tail -n "${2:-50}" "$LOG_FILE"
else
    # Show last 100 lines by default
    tail -n 100 "$LOG_FILE"
fi
