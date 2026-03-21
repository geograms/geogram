#!/usr/bin/env bash
set -euo pipefail

IFACE="${1:-wlp0s20f3}"
AP_SSID="${2:-geogram}"
DEFAULT_HOME_SSID="---___---"
HOME_SSID="${3:-${DEFAULT_HOME_SSID}}"
AP_IP="${4:-192.168.4.1}"
CONNECT_WAIT="${CONNECT_WAIT:-25}"
CURL_TIMEOUT="${CURL_TIMEOUT:-10}"

TMP_DIR="$(mktemp -d)"
ACTIVE_BEFORE="$(nmcli -t -f NAME,DEVICE connection show --active | awk -F: -v iface="${IFACE}" '$2==iface{print $1;exit}')"

cleanup() {
  echo ""
  echo "Reconnecting ${IFACE} to '${HOME_SSID}'..."
  nmcli --wait "${CONNECT_WAIT}" connection up "${HOME_SSID}" ifname "${IFACE}" >/dev/null 2>&1 \
    || nmcli --wait "${CONNECT_WAIT}" dev wifi connect "${HOME_SSID}" ifname "${IFACE}" >/dev/null 2>&1 \
    || true

  if nmcli -t -f IN-USE,SSID dev wifi list ifname "${IFACE}" | rg -q '^\*:.*'; then
    CONNECTED_SSID="$(nmcli -t -f IN-USE,SSID dev wifi list ifname "${IFACE}" | awk -F: '$1=="*"{print $2;exit}')"
    if [[ -n "${CONNECTED_SSID}" ]]; then
      echo "Connected to: ${CONNECTED_SSID}"
    fi
  fi

  if [[ -n "${ACTIVE_BEFORE}" && "${ACTIVE_BEFORE}" != "${HOME_SSID}" ]]; then
    echo "Previous active connection on ${IFACE} was: ${ACTIVE_BEFORE}"
  fi

  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

run_check() {
  local path="$1"
  local expected_status="$2"
  local desc="$3"
  local expect_substr="${4:-}"

  local safe_name
  safe_name="$(echo "${path}" | tr '/?' '__' | tr -cd '[:alnum:]_')"
  local headers_file="${TMP_DIR}/${safe_name}.headers"
  local body_file="${TMP_DIR}/${safe_name}.body"

  if ! curl -sS -m "${CURL_TIMEOUT}" -D "${headers_file}" -o "${body_file}" "http://${AP_IP}${path}"; then
    echo "[FAIL] ${desc}: curl failed (${path})"
    return 1
  fi

  local status
  status="$(awk 'NR==1 {print $2}' "${headers_file}")"
  if [[ "${status}" != "${expected_status}" ]]; then
    echo "[FAIL] ${desc}: expected HTTP ${expected_status}, got ${status:-<none>}"
    echo "  Path: ${path}"
    sed -n '1,8p' "${headers_file}" | sed 's/^/  /'
    return 1
  fi

  if [[ -n "${expect_substr}" ]] && ! rg -q --fixed-strings "${expect_substr}" "${body_file}"; then
    echo "[FAIL] ${desc}: body missing '${expect_substr}'"
    echo "  Path: ${path}"
    return 1
  fi

  echo "[PASS] ${desc}: HTTP ${status}"
  return 0
}

connect_to_ap() {
  nmcli dev disconnect "${IFACE}" >/dev/null 2>&1 || true
  sleep 1

  nmcli dev wifi rescan ifname "${IFACE}" >/dev/null 2>&1 || true
  sleep 2
  nmcli -t -f SSID,BSSID,CHAN,SIGNAL dev wifi list ifname "${IFACE}" | rg -F "${AP_SSID}" | sed 's/^/  /' || true

  if nmcli --wait "${CONNECT_WAIT}" dev wifi connect "${AP_SSID}" ifname "${IFACE}" >/dev/null 2>&1; then
    return 0
  fi

  nmcli dev wifi rescan ifname "${IFACE}" >/dev/null 2>&1 || true
  sleep 2
  nmcli -t -f SSID,BSSID,CHAN,SIGNAL dev wifi list ifname "${IFACE}" | rg -F "${AP_SSID}" | sed 's/^/  /' || true

  if nmcli --wait "${CONNECT_WAIT}" dev wifi connect "${AP_SSID}" ifname "${IFACE}" >/dev/null 2>&1; then
    return 0
  fi

  nmcli --wait "${CONNECT_WAIT}" dev wifi connect "${AP_SSID}" ifname "${IFACE}" hidden yes >/dev/null 2>&1
}

echo "Switching ${IFACE} to '${AP_SSID}'..."
connect_to_ap
sleep 2

echo "Running captive portal checks via http://${AP_IP}..."
FAILURES=0

run_check "/" "200" "Chat landing page loads" "api/chat/messages" || FAILURES=$((FAILURES + 1))
run_check "/generate_204" "200" "Android captive endpoint serves chat" "api/chat/messages" || FAILURES=$((FAILURES + 1))
run_check "/hotspot-detect.html" "200" "Apple captive endpoint serves chat" "api/chat/messages" || FAILURES=$((FAILURES + 1))
run_check "/ncsi.txt" "302" "Windows captive endpoint redirects" || FAILURES=$((FAILURES + 1))

if (( FAILURES > 0 )); then
  echo ""
  echo "Captive portal check failed (${FAILURES} failing checks)."
  exit 1
fi

echo ""
echo "All captive portal checks passed."
