#!/bin/bash
# Package the Geogram Dev VM for distribution.
#
# Produces:
#   geogram-vm-linux.tar.gz   — GUI launcher + QEMU + VM image
#   geogram-vm-windows.zip    — start.bat + QEMU + VM image
#
# Prerequisites:
#   - Flutter SDK (for building the launcher)
#   - Compressed VM image at vm/geogram-dev.qcow2
#   - Bundled QEMU binaries in vm/bin/{linux,windows}/

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM_DIR="$REPO_ROOT/vm"
LAUNCHER_DIR="$REPO_ROOT/vm-launcher"
STAGING="/tmp/geogram-vm-staging"
VERSION=$(date +%Y%m%d)

# Find Flutter SDK
FLUTTER="${FLUTTER:-$(command -v flutter 2>/dev/null || echo "$HOME/flutter/bin/flutter")}"
if [ ! -x "$FLUTTER" ]; then
    echo "Flutter not found. Set FLUTTER=/path/to/flutter or add it to PATH."
    exit 1
fi

echo "=== Geogram VM Packager ==="
echo ""

# Verify prerequisites
for f in "$VM_DIR/geogram-dev.qcow2" "$VM_DIR/bin/linux/qemu-system-x86_64" "$VM_DIR/start.sh" "$VM_DIR/start.bat" "$VM_DIR/README.md"; do
    if [ ! -e "$f" ]; then
        echo "Missing: $f"
        exit 1
    fi
done

# Step 1: Build Linux launcher
echo "[1/4] Building Linux launcher..."
cd "$LAUNCHER_DIR"
"$FLUTTER" build linux --release 2>&1 | tail -1
BUNDLE_DIR="$LAUNCHER_DIR/build/linux/x64/release/bundle"
if [ ! -f "$BUNDLE_DIR/vm_launcher" ]; then
    echo "Build failed — launcher binary not found."
    exit 1
fi

# Step 2: Stage Linux package
echo "[2/4] Staging Linux package..."
rm -rf "$STAGING"
mkdir -p "$STAGING/geogram-vm/vm/bin/linux"

# Launcher bundle
cp -r "$BUNDLE_DIR"/* "$STAGING/geogram-vm/"

# VM files
cp "$VM_DIR/geogram-dev.qcow2" "$STAGING/geogram-vm/vm/"
cp -r "$VM_DIR/bin/linux/"* "$STAGING/geogram-vm/vm/bin/linux/"
cp "$VM_DIR/start.sh" "$STAGING/geogram-vm/vm/"
cp "$VM_DIR/README.md" "$STAGING/geogram-vm/"

# Make executables
chmod +x "$STAGING/geogram-vm/vm_launcher"
chmod +x "$STAGING/geogram-vm/vm/start.sh"
chmod +x "$STAGING/geogram-vm/vm/bin/linux/qemu-system-x86_64"

# Create Linux archive
echo "[3/4] Creating Linux archive..."
cd "$STAGING"
tar czf "$VM_DIR/geogram-vm-linux.tar.gz" geogram-vm/
echo "  -> vm/geogram-vm-linux.tar.gz"

# Step 3: Stage Windows package
echo "[4/4] Creating Windows archive..."
rm -rf "$STAGING"
mkdir -p "$STAGING/geogram-vm/bin/windows"

cp "$VM_DIR/geogram-dev.qcow2" "$STAGING/geogram-vm/"
cp "$VM_DIR/start.bat" "$STAGING/geogram-vm/"
cp "$VM_DIR/README.md" "$STAGING/geogram-vm/"

if [ -d "$VM_DIR/bin/windows" ]; then
    cp -r "$VM_DIR/bin/windows/"* "$STAGING/geogram-vm/bin/windows/"
fi

cd "$STAGING"
if command -v zip &>/dev/null; then
    zip -rq "$VM_DIR/geogram-vm-windows.zip" geogram-vm/
    echo "  -> vm/geogram-vm-windows.zip"
else
    echo "  [skip] zip not installed — Windows archive not created"
fi

# Cleanup
rm -rf "$STAGING"

# Checksums
echo ""
echo "=== SHA-256 Checksums ==="
cd "$VM_DIR"
for f in geogram-vm-linux.tar.gz geogram-vm-windows.zip geogram-dev.qcow2; do
    [ -f "$f" ] && sha256sum "$f"
done

echo ""
echo "Done. Upload to p2p.radio:"
echo "  scp vm/geogram-vm-linux.tar.gz root@p2p.radio:/root/geogram/console/vm/"
echo "  scp vm/geogram-vm-windows.zip root@p2p.radio:/root/geogram/console/vm/"
echo "  scp vm/geogram-dev.qcow2 root@p2p.radio:/root/geogram/console/vm/"
