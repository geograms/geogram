#!/bin/bash
# Geogram — Install all dependencies needed to build from source
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Install system dependencies
"$SCRIPT_DIR/install-linux-deps.sh"

# Install Flutter if not present
if [ ! -f "$HOME/flutter/bin/flutter" ]; then
    "$SCRIPT_DIR/install-flutter.sh"
fi
