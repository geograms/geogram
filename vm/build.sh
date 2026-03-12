#!/bin/bash
# Build the complete self-contained Geogram dev VM distribution.
# This is a MAINTAINER script — run on a Linux host with KVM and internet.
# Output: vm/ folder with QEMU binaries for all platforms + VM image.
#
# Requirements: qemu-system-x86_64, qemu-img, cloud-image-utils, p7zip-full, curl
#
# Usage: ./vm/build.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

FLUTTER_VERSION="$(cat "$REPO_DIR/.flutter-version" | tr -d '[:space:]')"
DISK_SIZE="30G"
IMAGE_NAME="geogram-dev.qcow2"

# QEMU sources
QEMU_WIN_URL="https://qemu.weilnetz.de/w64/qemu-w64-setup-20260307.exe"
QEMU_WIN_INSTALLER="qemu-w64-setup.exe"
QEMU_APPIMAGE_URL="https://github.com/DanielMYT/qemu-appimage/releases/download/10.2.1/qemu-10.2.1-x86_64.AppImage"

# Debian cloud image
CLOUD_IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
CLOUD_IMAGE="debian-12-genericcloud-amd64.qcow2"

echo "========================================="
echo "  Geogram Dev VM — Full Build"
echo "========================================="
echo "  Flutter:  $FLUTTER_VERSION"
echo "  Disk:     $DISK_SIZE"
echo ""

# ============================================================
# Phase 1: Download QEMU binaries for all platforms
# ============================================================

echo "--- Phase 1: QEMU binaries ---"

# --- Linux: AppImage ---
mkdir -p "$SCRIPT_DIR/bin/linux"
if [ ! -f "$SCRIPT_DIR/bin/linux/qemu-system-x86_64" ]; then
    echo "[linux] Downloading QEMU AppImage..."
    curl -L -o "$SCRIPT_DIR/bin/linux/qemu-system-x86_64" "$QEMU_APPIMAGE_URL"
    chmod +x "$SCRIPT_DIR/bin/linux/qemu-system-x86_64"
else
    echo "[linux] QEMU AppImage already cached"
fi

# --- Windows: Extract from installer ---
mkdir -p "$SCRIPT_DIR/bin/windows"
if [ ! -f "$SCRIPT_DIR/bin/windows/qemu-system-x86_64.exe" ]; then
    echo "[windows] Downloading QEMU installer..."
    curl -L -o "/tmp/$QEMU_WIN_INSTALLER" "$QEMU_WIN_URL"

    echo "[windows] Extracting QEMU binaries..."
    EXTRACT_DIR=$(mktemp -d)
    7z x -o"$EXTRACT_DIR" "/tmp/$QEMU_WIN_INSTALLER" -y > /dev/null 2>&1 || \
        p7zip -d "/tmp/$QEMU_WIN_INSTALLER" -o"$EXTRACT_DIR" > /dev/null 2>&1

    # Copy only what we need: the x86_64 emulator, qemu-img, and all DLLs
    find "$EXTRACT_DIR" -name "qemu-system-x86_64.exe" -exec cp {} "$SCRIPT_DIR/bin/windows/" \;
    find "$EXTRACT_DIR" -name "qemu-img.exe" -exec cp {} "$SCRIPT_DIR/bin/windows/" \;
    find "$EXTRACT_DIR" -name "*.dll" -exec cp {} "$SCRIPT_DIR/bin/windows/" \;
    # Firmware files needed for boot
    SHARE_SRC=$(find "$EXTRACT_DIR" -type d -name "share" | head -1)
    if [ -n "$SHARE_SRC" ]; then
        mkdir -p "$SCRIPT_DIR/bin/windows/share"
        cp -r "$SHARE_SRC"/qemu "$SCRIPT_DIR/bin/windows/share/" 2>/dev/null || true
    fi

    rm -rf "$EXTRACT_DIR" "/tmp/$QEMU_WIN_INSTALLER"
    echo "[windows] Extracted $(ls "$SCRIPT_DIR/bin/windows/"*.exe 2>/dev/null | wc -l) executables, $(ls "$SCRIPT_DIR/bin/windows/"*.dll 2>/dev/null | wc -l) DLLs"
else
    echo "[windows] QEMU binaries already cached"
fi

# --- macOS: Instructions only (no portable binary available) ---
mkdir -p "$SCRIPT_DIR/bin/macos"
cat > "$SCRIPT_DIR/bin/macos/README.txt" << 'EOF'
macOS QEMU binaries cannot be portably distributed.
Install via Homebrew: brew install qemu
Then copy the binaries here:
  cp $(brew --prefix)/bin/qemu-system-x86_64 .
  cp $(brew --prefix)/bin/qemu-img .
  cp -r $(brew --prefix)/share/qemu ./share/
EOF
echo "[macos] Wrote instructions (no portable binary available)"

# ============================================================
# Phase 2: Build VM image
# ============================================================

echo ""
echo "--- Phase 2: VM image ---"

# Download base cloud image
if [ ! -f "$SCRIPT_DIR/$CLOUD_IMAGE" ]; then
    echo "[image] Downloading Debian 12 cloud image..."
    curl -L -o "$SCRIPT_DIR/$CLOUD_IMAGE" "$CLOUD_IMAGE_URL"
else
    echo "[image] Using cached Debian 12 cloud image"
fi

# Create the provisioning script
cat > "$SCRIPT_DIR/.provision.sh" << PROVISION_OUTER
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

FLUTTER_VERSION="$FLUTTER_VERSION"

echo ">>> [1/8] System packages..."
apt-get update
apt-get upgrade -y
apt-get install -y \
    git curl wget unzip xz-utils \
    clang cmake ninja-build pkg-config \
    libgtk-3-dev liblzma-dev libmpv-dev lld \
    protobuf-compiler \
    build-essential libssl-dev \
    openssh-server sudo \
    tmux htop jq ripgrep fd-find fzf bat \
    python3 python3-pip python3-venv \
    ca-certificates gnupg

echo ">>> [2/8] SSH server..."
sed -i 's/#PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/#PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config
systemctl enable ssh

echo ">>> [3/8] Creating dev user..."
if ! id -u dev &>/dev/null; then
    useradd -m -s /bin/bash -G sudo dev
    echo "dev:dev" | chpasswd
    echo "dev ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/dev
fi

# --- Everything below as dev ---
su - dev << 'DEV_EOF'
set -euo pipefail

FLUTTER_VERSION="$FLUTTER_VERSION"

echo ">>> [4/8] Flutter SDK..."
if [ ! -d "\$HOME/flutter" ]; then
    git clone -b "\$FLUTTER_VERSION" --depth 1 https://github.com/flutter/flutter.git "\$HOME/flutter"
    "\$HOME/flutter/bin/flutter" precache --linux
    "\$HOME/flutter/bin/flutter" config --enable-linux-desktop
fi

echo ">>> [5/8] Rust toolchain..."
if [ ! -d "\$HOME/.cargo" ]; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
fi
source "\$HOME/.cargo/env"

echo ">>> [6/8] Node.js + AI coding tools..."
if ! command -v node &>/dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
    sudo apt-get install -y nodejs
fi
sudo npm install -g @anthropic-ai/claude-code || true
sudo npm install -g @openai/codex || true
curl -fsSL https://opencode.ai/install | bash || true

echo ">>> [7/8] Clone geogram + pre-cache build..."
if [ ! -d "\$HOME/geogram" ]; then
    git clone https://github.com/geograms/geogram.git "\$HOME/geogram"
    cd "\$HOME/geogram"
    "\$HOME/flutter/bin/flutter" pub get
    echo ">>> Pre-building (caches all native dependencies)..."
    "\$HOME/flutter/bin/flutter" build linux --debug || true
    cd "\$HOME"
fi

echo ">>> [8/8] Shell profile..."
cat >> "\$HOME/.bashrc" << 'PROFILE'

# Geogram dev environment
export PATH="\$HOME/flutter/bin:\$HOME/.cargo/bin:\$PATH"
cd ~/geogram 2>/dev/null

alias f='flutter'
alias fb='flutter build linux'
alias fr='flutter run -d linux'
alias ft='flutter test'
alias fa='flutter analyze'

echo ""
echo "  Geogram Dev VM"
echo "  ───────────────────────────────────"
echo "  flutter : \$(flutter --version 2>/dev/null | head -1)"
echo "  rust    : \$(rustc --version 2>/dev/null)"
echo "  node    : \$(node --version 2>/dev/null)"
echo ""
echo "  AI tools (authenticate once, credentials persist):"
echo "    claude login        # Anthropic"
echo "    codex auth          # OpenAI"
echo "    opencode            # configure on first run"
echo ""
PROFILE

DEV_EOF

echo ">>> Cleanup..."
apt-get clean
rm -rf /var/lib/apt/lists/*
echo ">>> Provisioning complete."
PROVISION_OUTER

# Create cloud-init config
cat > "$SCRIPT_DIR/.user-data" << EOF
#cloud-config
password: dev
chpasswd:
  expire: false
ssh_pwauth: true
runcmd:
  - bash /provision.sh
  - rm -f /provision.sh
  - poweroff
write_files:
  - path: /provision.sh
    permissions: '0755'
    encoding: b64
    content: $(base64 -w0 "$SCRIPT_DIR/.provision.sh")
EOF

cat > "$SCRIPT_DIR/.meta-data" << EOF
instance-id: geogram-dev
local-hostname: geogram-dev
EOF

# Create seed ISO
echo "[image] Creating cloud-init seed ISO..."
if command -v cloud-localds &>/dev/null; then
    cloud-localds "$SCRIPT_DIR/.seed.iso" "$SCRIPT_DIR/.user-data" "$SCRIPT_DIR/.meta-data"
elif command -v genisoimage &>/dev/null; then
    genisoimage -output "$SCRIPT_DIR/.seed.iso" -volid cidata -joliet -rock \
        "$SCRIPT_DIR/.user-data" "$SCRIPT_DIR/.meta-data"
else
    echo "ERROR: Need cloud-localds (cloud-image-utils) or genisoimage"
    echo "  sudo apt-get install cloud-image-utils"
    exit 1
fi

# Create working disk
echo "[image] Creating VM disk ($DISK_SIZE)..."
cp "$SCRIPT_DIR/$CLOUD_IMAGE" "$SCRIPT_DIR/$IMAGE_NAME"
qemu-img resize "$SCRIPT_DIR/$IMAGE_NAME" "$DISK_SIZE"

# Boot and provision
echo "[image] Booting VM for provisioning..."
echo "        This takes 15-30 minutes. The VM shuts down when done."
echo ""
ACCEL_ARGS="-cpu qemu64 -accel tcg"
if [ -w /dev/kvm ]; then
    ACCEL_ARGS="-cpu host -enable-kvm"
fi

qemu-system-x86_64 \
    -m 4G \
    -smp 4 \
    $ACCEL_ARGS \
    -drive file="$SCRIPT_DIR/$IMAGE_NAME",format=qcow2,if=virtio \
    -drive file="$SCRIPT_DIR/.seed.iso",format=raw,if=virtio \
    -netdev user,id=net0 \
    -device virtio-net-pci,netdev=net0 \
    -nographic

# Cleanup temp files
rm -f "$SCRIPT_DIR/.seed.iso" "$SCRIPT_DIR/.user-data" "$SCRIPT_DIR/.meta-data" "$SCRIPT_DIR/.provision.sh"

echo ""
echo "========================================="
echo "  Build complete!"
echo "========================================="
echo ""
echo "  Image: vm/$IMAGE_NAME"
echo "  QEMU:  vm/bin/{linux,windows,macos}/"
echo ""
echo "  Distribute the entire vm/ folder."
echo "  Users run start.sh (Linux) or start.bat (Windows)."
echo ""
