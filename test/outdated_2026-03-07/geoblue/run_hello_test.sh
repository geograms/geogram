#!/usr/bin/env bash
set -euo pipefail

# HELLO interoperability test runner.
# Validates bidirectional HELLO/HELLO_ACK exchange between desktop and ESP32.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DART_BIN="${DART_BIN:-/home/brito/flutter/bin/dart}"

if [[ ! -x "$DART_BIN" ]]; then
  DART_BIN="${DART_BIN_FALLBACK:-dart}"
fi

cd "$SCRIPT_DIR"
"$DART_BIN" pub get >/dev/null
"$DART_BIN" run bin/geoblue_console.dart "$@"
