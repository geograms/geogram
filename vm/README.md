# Geogram Dev VM

Self-contained development environment. No internet or local toolchain required.

## Quick Start

**Linux:**

1. Download [geogram-vm-linux.tar.gz](https://p2p.radio/vm/geogram-vm-linux.tar.gz)
2. Extract: `tar xzf geogram-vm-linux.tar.gz`
3. Double-click `vm_launcher` (or run `./vm_launcher` from a terminal)

That's it. The launcher finds the bundled QEMU and VM image, lets you configure memory and CPU cores, and starts the VM with one click. Boot output streams into the built-in terminal and the VM auto-logs in as `dev`.

**Windows:**

1. Download [geogram-vm-windows.zip](https://p2p.radio/vm/geogram-vm-windows.zip)
2. Extract the zip
3. Double-click `start.bat`

The VM boots and auto-logs in on the serial console. Close the window to stop.

**macOS:** Install QEMU via `brew install qemu`, then run `./start.sh`.

## What's Inside

| Component | Details |
|-----------|---------|
| **OS** | Debian 12 (bookworm) |
| **Flutter** | 3.38.5 with Linux desktop precached |
| **Rust** | Latest stable + cargo |
| **Build tools** | clang, cmake, ninja, pkg-config, lld |
| **Libraries** | GTK3-dev, libmpv-dev, liblzma-dev, protobuf-compiler |
| **AI assistants** | Claude Code, opencode, Codex |
| **Utilities** | ripgrep, fd, fzf, bat, tmux, htop, jq |
| **Geogram** | Cloned with deps fetched and debug build cached |

## System Requirements

- **CPU**: x86_64
- **RAM**: 4 GB minimum (default), 8 GB recommended
- **Acceleration**: KVM recommended on Linux, WHPX recommended on Windows
- **Disk**: ~5 GB for the compressed VM image

## Inside the VM

```bash
cd ~/geogram
git pull           # update code (when online)
flutter build linux
flutter analyze
flutter test
```

AI tool setup (one-time, credentials persist in the VM):
```bash
claude login       # Anthropic
codex auth         # OpenAI
opencode           # configure on first run
```

## Manual Access (Advanced)

If you prefer to launch QEMU yourself and connect via SSH:

```bash
./start.sh
# In another terminal:
ssh dev@localhost -p 2222    # password: dev
```

Options:
```bash
./start.sh --memory 8G          # more RAM
./start.sh --cpus 6             # more cores
./start.sh --background         # detach from terminal
./start.sh --share ~/my-code    # mount host dir at /mnt/share
```

## Building This Image (Maintainers)

Requires Linux host with KVM, internet, and ~30 min:

```bash
sudo apt-get install -y qemu-system-x86 qemu-utils cloud-image-utils p7zip-full
./vm/build.sh
```

## Packaging for Distribution (Maintainers)

```bash
./vm/package.sh
```

Builds the launcher, bundles it with QEMU and the VM image, and produces ready-to-run archives with checksums.
