#!/usr/bin/env bash
set -euo pipefail

PORT="${1:-/dev/ttyUSB0}"
BAUD="${2:-115200}"
RESET_BEFORE_MONITOR="${GEOGRAM_SERIAL_RESET_BEFORE_MONITOR:-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIO_BIN="${HOME}/.platformio/penv/bin/pio"
ESPTOOL_PY="${HOME}/.platformio/packages/tool-esptoolpy/esptool.py"

if [[ ! -x "${PIO_BIN}" ]]; then
  echo "PlatformIO binary not found at: ${PIO_BIN}" >&2
  exit 1
fi

cd "${SCRIPT_DIR}"

# Run the same reset sequence used for stable interactive console startup.
# Disable with: GEOGRAM_SERIAL_RESET_BEFORE_MONITOR=0 ./serial.sh
if [[ "${RESET_BEFORE_MONITOR}" == "1" && -f "${ESPTOOL_PY}" ]] && command -v python3 >/dev/null 2>&1; then
  python3 "${ESPTOOL_PY}" \
    --chip esp32 \
    --port "${PORT}" \
    --before default_reset \
    --after hard_reset \
    chip_id >/dev/null 2>&1 || true
  sleep 0.2
fi

exec "${PIO_BIN}" device monitor \
  -p "${PORT}" \
  -b "${BAUD}" \
  --eol LF
