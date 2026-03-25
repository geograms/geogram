#!/bin/sh
# Geogram Iwi — Web Launcher
#
# Packs wapps from wapps/archive/ into .wapp ZIPs, generates a
# wapps.json manifest, and serves everything on localhost:8080.
#
# Usage: ./launch-web.sh [port]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ARCHIVE_DIR="$REPO_ROOT/wapps/archive"
WEB_DIR="$SCRIPT_DIR/web"
SERVE_DIR="$WEB_DIR/.serve"
PORT="${1:-8080}"

# ── Build .wapp files ─────────────────────────────────────────────────

mkdir -p "$SERVE_DIR/wapps"

echo "Packing wapps..."
WAPPS_JSON="["
FIRST=true

for wapp_dir in "$ARCHIVE_DIR"/*/; do
    [ -f "$wapp_dir/manifest.json" ] || continue
    [ -f "$wapp_dir/app.wasm" ] || continue

    name=$(basename "$wapp_dir")
    wapp_file="$SERVE_DIR/wapps/$name.wapp"

    # Pack as ZIP (stored, no compression — browser DecompressionStream
    # handles deflate but stored is simpler and wapps are small)
    (cd "$wapp_dir" && zip -r -0 "$wapp_file" \
        manifest.json app.wasm \
        screens/*.ui.json \
        media/ \
        2>/dev/null) || true

    # Read manifest for the launcher JSON
    desc=$(python3 -c "import json,sys; m=json.load(open('$wapp_dir/manifest.json')); print(m.get('description',''))" 2>/dev/null || echo "$name")
    id=$(python3 -c "import json,sys; m=json.load(open('$wapp_dir/manifest.json')); print(m.get('id',''))" 2>/dev/null || echo "$name")

    if [ "$FIRST" = true ]; then FIRST=false; else WAPPS_JSON="$WAPPS_JSON,"; fi
    WAPPS_JSON="$WAPPS_JSON{\"name\":\"$name\",\"description\":\"$desc\",\"id\":\"$id\",\"wapp\":\"/wapps/$name.wapp\"}"

    echo "  $name.wapp ($(du -h "$wapp_file" | cut -f1))"
done

WAPPS_JSON="$WAPPS_JSON]"
echo "$WAPPS_JSON" > "$SERVE_DIR/wapps.json"

# ── Copy web assets ───────────────────────────────────────────────────

cp "$WEB_DIR/index.html" "$SERVE_DIR/"
cp "$WEB_DIR/app.js" "$SERVE_DIR/"

# ── Serve ─────────────────────────────────────────────────────────────

echo ""
echo "Serving at http://localhost:$PORT"
echo "Press Ctrl+C to stop."
echo ""

cd "$SERVE_DIR"

# Try python3, then python, then dart
if command -v python3 >/dev/null 2>&1; then
    exec python3 -m http.server "$PORT" --bind 127.0.0.1
elif command -v python >/dev/null 2>&1; then
    exec python -m http.server "$PORT" --bind 127.0.0.1
else
    echo "Error: python3 not found. Install Python or serve $SERVE_DIR manually."
    exit 1
fi
