#!/bin/bash

# Geogram Desktop - Linux Dependencies Installation Script
# This script installs required dependencies for Flutter Linux desktop development

echo "📦 Installing Flutter Linux desktop build dependencies..."
echo ""
echo "The following packages will be installed:"
echo "  - clang (C/C++ compiler)"
echo "  - cmake (build system generator)"
echo "  - ninja-build (build system)"
echo "  - pkg-config (library discovery)"
echo "  - libgtk-3-dev (GTK development libraries)"
echo "  - liblzma-dev (XZ compression library)"
echo "  - libmpv-dev (media player library)"
echo "  - lld (LLVM linker)"
echo ""

# Check if running with sudo or as root
if [ "$EUID" -ne 0 ]; then
    echo "This script requires sudo privileges to install packages."
    echo "You will be prompted for your password."
    echo ""
    SUDO="sudo"
else
    SUDO=""
fi

# Update package list
echo "Updating package list..."
$SUDO apt-get update

# Install dependencies
echo ""
echo "Installing dependencies..."
$SUDO apt-get install -y \
    clang \
    cmake \
    ninja-build \
    pkg-config \
    libgtk-3-dev \
    liblzma-dev \
    libmpv-dev \
    lld

echo ""
echo "✅ Dependencies installed successfully!"
echo ""
echo "You can now run the desktop app with:"
echo "  ./launch-desktop.sh"
