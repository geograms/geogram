#!/usr/bin/env bash
set -euo pipefail

# Reverse unicast test runner.
# The Dart test requests reverse capability in HELLO so ESP32 initiates a
# 1000-byte transfer to desktop; desktop echoes it back and waits for ESP32
# validation result.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DART_BIN="${DART_BIN:-/home/brito/flutter/bin/dart}"

if [[ ! -x "$DART_BIN" ]]; then
  DART_BIN="${DART_BIN_FALLBACK:-dart}"
fi

cd "$SCRIPT_DIR"
"$DART_BIN" pub get >/dev/null
"$DART_BIN" run bin/geoblue_unicast_reverse_test.dart "$@"
