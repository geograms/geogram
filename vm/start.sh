#!/bin/bash
# Start the Geogram dev VM using the bundled QEMU binary.
# No installation required — everything is in this folder.
#
# The VM auto-logs in on the serial console.
# SSH: ssh dev@localhost -p 2222 (password: dev)
#
# Flags:
#   --background    Detach (no console)
#   --memory 8G     RAM (default: 4G)
#   --cpus 4        CPU cores (default: half of host)
#   --share PATH    Mount host directory at /mnt/share inside VM

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QEMU="$SCRIPT_DIR/bin/linux/qemu-system-x86_64"
IMAGE="$SCRIPT_DIR/geogram-dev.qcow2"

# Check bundled QEMU
if [ ! -x "$QEMU" ]; then
    echo "Bundled QEMU not found at: $QEMU"
    echo "The vm/ folder may be incomplete. Re-download from releases."
    exit 1
fi

# Check image
if [ ! -f "$IMAGE" ]; then
    echo "VM image not found at: $IMAGE"
    echo "The vm/ folder may be incomplete. Re-download from releases."
    exit 1
fi

# Defaults
MEMORY="4G"
CPUS=$(( $(nproc) / 2 ))
[ "$CPUS" -lt 2 ] && CPUS=2
BACKGROUND=false
SHARE_DIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --background) BACKGROUND=true ;;
        --memory) MEMORY="$2"; shift ;;
        --cpus) CPUS="$2"; shift ;;
        --share) SHARE_DIR="$2"; shift ;;
        *) ;;
    esac
    shift
done

# Detect KVM
ACCEL=""
if [ -w /dev/kvm ]; then
    ACCEL="-enable-kvm -cpu host"
else
    echo "Note: /dev/kvm not available. VM will run without hardware acceleration (slower)."
    ACCEL="-cpu qemu64"
fi

QEMU_CMD=(
    "$QEMU"
    -m "$MEMORY"
    -smp "$CPUS"
    $ACCEL
    -drive "file=$IMAGE,format=qcow2,if=virtio"
    -netdev "user,id=net0,hostfwd=tcp::2222-:22"
    -device virtio-net-pci,netdev=net0
)

if [ -n "$SHARE_DIR" ]; then
    QEMU_CMD+=(
        -fsdev "local,security_model=mapped-xattr,id=fsdev0,path=$SHARE_DIR"
        -device "virtio-9p-pci,fsdev=fsdev0,mount_tag=hostshare"
    )
    echo "Shared: $SHARE_DIR -> mount inside VM: sudo mount -t 9p -o trans=virtio hostshare /mnt/share"
fi

if $BACKGROUND; then
    QEMU_CMD+=(-nographic -daemonize)
    "${QEMU_CMD[@]}"
    echo "VM running in background."
else
    QEMU_CMD+=(-nographic)
    echo "Starting VM... (Ctrl-A X to quit)"
    echo ""
    "${QEMU_CMD[@]}"
fi
