#!/usr/bin/env bash
set -euo pipefail

# BLE broadcast integration test runner.
# Desktop sends one broadcast frame; ESP32 listener acknowledges delivery
# over BLE channel geoblue_broadcast_receipt.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DART_BIN="${DART_BIN:-/home/brito/flutter/bin/dart}"

if [[ ! -x "$DART_BIN" ]]; then
  DART_BIN="${DART_BIN_FALLBACK:-dart}"
fi

TOKEN="${BROADCAST_TOKEN:-GEOBLUE-BCAST-$(date +%s%3N)}"
TOPIC="${BROADCAST_TOPIC:-geoblue_global_chat}"

cd "$SCRIPT_DIR"
"$DART_BIN" pub get >/dev/null

"$DART_BIN" run bin/geoblue_broadcast_test.dart \
  --topic "$TOPIC" \
  --content "$TOKEN" \
  "$@"

echo "Broadcast listener check: PASS (token=$TOKEN)"
