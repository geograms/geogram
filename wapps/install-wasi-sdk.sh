#!/bin/sh
# Install wasi-sdk for compiling WASM modules.
#
# Downloads wasi-sdk 25 to ~/wasi-sdk (or WASI_SDK_PATH if set).
# Re-running is safe — skips if already installed.

set -e

WASI_SDK_VERSION="25"
WASI_SDK_FULL="25.0"
INSTALL_DIR="${WASI_SDK_PATH:-$HOME/wasi-sdk}"

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  ARCH_SUFFIX="x86_64" ;;
    aarch64) ARCH_SUFFIX="aarch64" ;;
    arm64)   ARCH_SUFFIX="aarch64" ;;
    *)
        echo "Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

# Detect OS
OS=$(uname -s)
case "$OS" in
    Linux)  OS_SUFFIX="linux" ;;
    Darwin) OS_SUFFIX="macos" ;;
    *)
        echo "Unsupported OS: $OS"
        exit 1
        ;;
esac

# Check if already installed
if [ -x "$INSTALL_DIR/bin/clang" ]; then
    VERSION=$("$INSTALL_DIR/bin/clang" --version 2>/dev/null | head -1)
    echo "wasi-sdk already installed at $INSTALL_DIR"
    echo "  $VERSION"
    exit 0
fi

TARBALL="wasi-sdk-${WASI_SDK_FULL}-${ARCH_SUFFIX}-${OS_SUFFIX}.tar.gz"
URL="https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-${WASI_SDK_VERSION}/${TARBALL}"

echo "Installing wasi-sdk ${WASI_SDK_FULL} (${ARCH_SUFFIX}-${OS_SUFFIX})"
echo "  From: $URL"
echo "  To:   $INSTALL_DIR"
echo ""

# Download
TMPDIR=$(mktemp -d)
echo "Downloading..."
curl -sL "$URL" -o "$TMPDIR/$TARBALL"

# Extract
echo "Extracting..."
mkdir -p "$INSTALL_DIR"
tar xzf "$TMPDIR/$TARBALL" -C "$INSTALL_DIR" --strip-components=1

# Clean up
rm -rf "$TMPDIR"

# Verify
if [ -x "$INSTALL_DIR/bin/clang" ]; then
    echo ""
    echo "Installed successfully."
    echo ""
    echo "Add to your shell profile:"
    echo "  export WASI_SDK_PATH=$INSTALL_DIR"
    echo ""
    echo "Or pass it to make:"
    echo "  WASI_SDK_PATH=$INSTALL_DIR make"
else
    echo "Installation failed — $INSTALL_DIR/bin/clang not found"
    exit 1
fi
