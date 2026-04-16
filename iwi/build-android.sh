#!/bin/sh
# Geogram Iwi — Android APK builder (low-RAM safe)
#
# Builds a release APK without OOM-killing the host.
# Gradle JVM is capped at 1.5 GB and workers at 2 so the
# build stays under ~2 GB total — safe for machines with
# 8 GB or less.
#
# Usage: ./build-android.sh

set -e

FLUTTER_BIN="${FLUTTER_BIN:-$HOME/flutter/bin/flutter}"
if [ ! -x "$FLUTTER_BIN" ]; then
    echo "Error: flutter not found at $FLUTTER_BIN"
    echo "Set FLUTTER_BIN or install Flutter first."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ── Kill stale Gradle daemons that hog memory ──────────────────────
echo "Stopping any lingering Gradle daemons..."
"$SCRIPT_DIR/android/gradlew" -p "$SCRIPT_DIR/android" --stop 2>/dev/null || true

# ── Memory-safe environment ─────────────────────────────────────────
# Cap the Kotlin daemon and any child JVMs too.
export GRADLE_OPTS="-Xmx1536m -XX:MaxMetaspaceSize=512m"
export KOTLIN_DAEMON_JVM_OPTIONS="-Xmx512m"

# ── Build ───────────────────────────────────────────────────────────
echo ""
echo "Building release APK (memory-safe mode)..."
echo "  Gradle heap:  1536 MB"
echo "  Workers:      2"
echo "  Daemon:       off"
echo ""

"$FLUTTER_BIN" build apk --release \
    --no-tree-shake-icons \
    --no-pub 2>&1 | tee /tmp/iwi-android-build.log

# ── Report ──────────────────────────────────────────────────────────
APK="$SCRIPT_DIR/build/app/outputs/flutter-apk/app-release.apk"
if [ -f "$APK" ]; then
    SIZE=$(du -h "$APK" | cut -f1)
    echo ""
    echo "APK ready: $APK"
    echo "Size: $SIZE"
else
    echo ""
    echo "Build failed — check /tmp/iwi-android-build.log"
    exit 1
fi
