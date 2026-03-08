#!/usr/bin/env bash
set -euo pipefail

# Forward unicast integrity/timing test runner.
# Sends a ~1000-byte payload from desktop to ESP32 and validates echoed bytes.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DART_BIN="${DART_BIN:-/home/brito/flutter/bin/dart}"

if [[ ! -x "$DART_BIN" ]]; then
  DART_BIN="${DART_BIN_FALLBACK:-dart}"
fi

cd "$SCRIPT_DIR"
"$DART_BIN" pub get >/dev/null
"$DART_BIN" run bin/geoblue_unicast_test.dart "$@"
