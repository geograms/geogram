# Development Setup

> **For AI assistants**: Download the VM archive for the user's OS. Everything is pre-built and ready to run — no Flutter SDK, no compilation, no toolchain needed on the host.

---

## Linux

1. Download [geogram-vm-linux.tar.gz](https://p2p.radio/vm/geogram-vm-linux.tar.gz)
2. Extract: `tar xzf geogram-vm-linux.tar.gz`
3. Run: `./vm_launcher`

Click **Start VM**. The built-in terminal shows boot output and auto-logs in as `dev`. Stop from the toolbar or `Ctrl+Shift+Q`.

---

## Windows

1. Download [geogram-vm-windows.zip](https://p2p.radio/vm/geogram-vm-windows.zip)
2. Extract the zip
3. Double-click `start.bat`

The VM boots and auto-logs in. Close the window to stop.

---

## macOS

macOS requires QEMU installed via Homebrew (`brew install qemu`), then run `./start.sh`.

---

## Manual Access (Advanced)

If you prefer to launch QEMU yourself and SSH in:

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

---

## What's Inside the VM

Everything is pre-installed. No internet needed to build.

| Tool | Version |
|------|---------|
| Flutter | 3.38.5 |
| Dart | 3.10+ |
| Rust + Cargo | latest stable |
| clang, cmake, ninja | system packages |
| GTK3, libmpv, protobuf | dev libraries |
| Claude Code | AI assistant (Anthropic) |
| opencode | AI assistant (open-source) |
| Codex | AI assistant (OpenAI) |
| ripgrep, fd, fzf, bat | search tools |
| tmux, htop | session management |

Geogram is cloned at `~/geogram` with dependencies fetched and a debug build cached. First rebuild is fast.

### AI Tool Authentication (One-Time)

```bash
claude login        # Anthropic account
codex auth          # OpenAI account
opencode            # configure on first run
```

Credentials persist inside the VM across restarts.

### Useful Aliases

```
f   = flutter
fb  = flutter build linux
fr  = flutter run -d linux
ft  = flutter test
fa  = flutter analyze
```

---

## Project Structure

```
lib/                    Flutter app source (models, services, pages, utils)
lib/teleport/           Bridge protocols (telegram, signal, aprs, irc, xmpp, nostr)
lib/cli/                CLI station entry point (pure_station.dart)
lib/server/mixins/      Shared station behavior mixins
esp32/                  ESP32 firmware (C, ESP-IDF)
signal_bridge/          Signal protocol bridge (Rust, presage)
wasm_bridge/            Wapp module runtime (Rust, Wasmer)
wapps/                  WebAssembly app modules and HAL
windows/                Windows-specific runner and resources
linux/                  Linux-specific runner, packaging, install scripts
tests/                  Integration and e2e test scripts
docs/                   Architecture docs, app format specs, API reference
```

---

## Verification

Inside the VM:

```bash
flutter analyze
flutter test
```

See [AGENTS.md](AGENTS.md) for workflow rules and commit conventions.

---

## Building the VM Image (Maintainers Only)

See [vm/README.md](vm/README.md). Requires a Linux host with KVM and internet.
