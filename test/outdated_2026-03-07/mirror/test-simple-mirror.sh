#!/bin/bash
#
# Mirror Sync Integration Test Runner
#
# Runs the self-contained Dart integration test that:
# 1. Creates temp directories with test files
# 2. Starts a mock mirror source server
# 3. Initializes the MirrorSyncService client
# 4. Runs the full sync protocol (challenge-response auth + file transfer)
# 5. Verifies files on disk with SHA1 integrity checks
# 6. Tests update sync, new file sync, one-way mirror behavior
# 7. Tests pair endpoint and security (replay attacks, unauthorized peers)
#
# Usage:
#   ./test-simple-mirror.sh
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Find dart
if command -v dart &>/dev/null; then
    DART_CMD="dart"
elif [ -f "$HOME/flutter/bin/dart" ]; then
    DART_CMD="$HOME/flutter/bin/dart"
else
    echo "Error: dart not found. Install Flutter or add dart to PATH."
    exit 1
fi

cd "$PROJECT_DIR"
exec $DART_CMD run tests/mirror/mirror_sync_test.dart "$@"
