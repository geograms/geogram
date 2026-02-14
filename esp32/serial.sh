#!/usr/bin/env bash
set -euo pipefail

PORT="${1:-/dev/ttyUSB0}"
BAUD="${2:-115200}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIO_BIN="${HOME}/.platformio/penv/bin/pio"

if [[ ! -x "${PIO_BIN}" ]]; then
  echo "PlatformIO binary not found at: ${PIO_BIN}" >&2
  exit 1
fi

cd "${SCRIPT_DIR}"

exec "${PIO_BIN}" device monitor \
  -p "${PORT}" \
  -b "${BAUD}" \
  --eol LF
