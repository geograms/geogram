#!/bin/sh
# Geogram Iwi — Web Launcher
#
# Builds the Flutter web bundle from the same Dart source that
# powers the desktop launcher and serves it plus every wapp from
# wapps/archive/ over a local HTTP server. Dropping into Chrome on
# the returned URL gives the user the EXACT same GeoUI / renderer /
# i18n / store / App Creator / signing stack as the desktop build,
# only hosted in the browser instead of a GTK window.
#
# Usage: ./launch-web.sh [port]

set -e

FLUTTER_BIN="${FLUTTER_BIN:-$HOME/flutter/bin/flutter}"
if [ ! -x "$FLUTTER_BIN" ]; then
    echo "Error: flutter not found at $FLUTTER_BIN"
    echo "Set FLUTTER_BIN or install Flutter first."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ARCHIVE_DIR="$REPO_ROOT/wapps/archive"
BUILD_DIR="$SCRIPT_DIR/build/web"
PORT="${1:-8080}"

cd "$SCRIPT_DIR"

# ── Build Flutter web ────────────────────────────────────────────────

echo "Building Flutter web bundle..."
# --pwa-strategy=none disables the service worker so every page
# reload re-downloads main.dart.js from disk. Without this the
# previous build's JS stays cached in the browser and users see
# stale code after rebuilds — including the project-tab regression
# that was fixed in Dart but still visible in the cached JS.
"$FLUTTER_BIN" build web --no-tree-shake-icons --pwa-strategy=none

# ── Pack .wapp archives into the served build ────────────────────────

mkdir -p "$BUILD_DIR/wapps"

echo "Packing wapps from $ARCHIVE_DIR..."
WAPPS_JSON="["
FIRST=true

for wapp_dir in "$ARCHIVE_DIR"/*/; do
    [ -f "$wapp_dir/manifest.json" ] || continue
    [ -f "$wapp_dir/app.wasm" ] || continue

    name=$(basename "$wapp_dir")
    wapp_file="$BUILD_DIR/wapps/$name.wapp"

    rm -f "$wapp_file"
    (cd "$wapp_dir" && zip -qr "$wapp_file" \
        manifest.json app.wasm \
        $([ -f main.c ] && echo main.c) \
        $([ -d screens ] && echo screens) \
        $([ -d media ] && echo media) \
        $([ -d lang ] && echo lang) \
        2>/dev/null) || true

    id=$(python3 -c "import json; m=json.load(open('$wapp_dir/manifest.json')); print(m.get('id',''))" 2>/dev/null || echo "$name")
    desc=$(python3 -c "import json; m=json.load(open('$wapp_dir/manifest.json')); print(m.get('description',''))" 2>/dev/null || echo "$name")

    if [ "$FIRST" = true ]; then FIRST=false; else WAPPS_JSON="$WAPPS_JSON,"; fi
    WAPPS_JSON="$WAPPS_JSON{\"name\":\"$name\",\"description\":\"$desc\",\"id\":\"$id\",\"wapp\":\"/wapps/$name.wapp\"}"

    echo "  $name.wapp ($(du -h "$wapp_file" 2>/dev/null | cut -f1))"
done

WAPPS_JSON="$WAPPS_JSON]"
echo "$WAPPS_JSON" > "$BUILD_DIR/wapps.json"

# ── Serve ────────────────────────────────────────────────────────────

echo ""
echo "Serving at http://localhost:$PORT"
echo "Press Ctrl+C to stop."
echo ""

cd "$BUILD_DIR"

# Kill anything already bound to the target port so the launcher is
# idempotent — repeated runs of this script during development are
# the common case, and leaving a zombie python3 around from a
# previous run forces the user to "Address already in use" every
# time.
PORT_HOLDER=$(ss -tlnp 2>/dev/null | awk -v port="$PORT" '$4 ~ ":"port"$" {print $NF}' | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2 || true)
if [ -n "$PORT_HOLDER" ]; then
    echo "Stopping previous server (pid $PORT_HOLDER)..."
    kill "$PORT_HOLDER" 2>/dev/null || true
    sleep 1
fi

if command -v python3 >/dev/null 2>&1; then
    PY=python3
elif command -v python >/dev/null 2>&1; then
    PY=python
else
    echo "Error: python3 not found. Install Python or serve $BUILD_DIR manually."
    exit 1
fi

# Serve with aggressive no-cache headers so rebuilds land instantly
# in the browser. Without these the browser's HTTP cache (even
# without a service worker) holds on to main.dart.js across reloads
# and the user sees stale code. An inline NoCacheHandler adds
# Cache-Control / Pragma / Expires on every response — the entire
# `build/web` tree is dev-time output so there's no reason to cache
# anything here.
exec "$PY" -c "
import sys, http.server, socketserver
class NoCacheHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cache-Control', 'no-store, no-cache, must-revalidate, max-age=0')
        self.send_header('Pragma', 'no-cache')
        self.send_header('Expires', '0')
        super().end_headers()
socketserver.TCPServer.allow_reuse_address = True
httpd = socketserver.TCPServer(('127.0.0.1', $PORT), NoCacheHandler)
try:
    httpd.serve_forever()
except KeyboardInterrupt:
    httpd.server_close()
"
