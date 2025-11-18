#!/bin/bash

# Geogram Desktop Installation Script for Linux

set -e

APP_NAME="geogram_desktop"
INSTALL_DIR="/opt/geogram-desktop"
DESKTOP_FILE="/usr/share/applications/dev.geogram.geogram_desktop.desktop"
ICON_DIR="/usr/share/icons/hicolor/512x512/apps"

echo "Installing Geogram Desktop..."

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (use sudo)"
    exit 1
fi

# Create installation directory
echo "Creating installation directory..."
mkdir -p "$INSTALL_DIR"

# Copy application files
echo "Copying application files..."
cp -r build/linux/x64/release/bundle/* "$INSTALL_DIR/"

# Install icon
echo "Installing application icon..."
mkdir -p "$ICON_DIR"
cp "$INSTALL_DIR/data/app_icon.png" "$ICON_DIR/geogram.png"

# Install desktop file
echo "Installing desktop entry..."
cat > "$DESKTOP_FILE" << EOF
[Desktop Entry]
Type=Application
Name=Geogram Desktop
Comment=Resilient, Decentralized Communication
Exec=$INSTALL_DIR/geogram_desktop
Icon=geogram
Categories=Network;Communication;
Terminal=false
StartupWMClass=geogram_desktop
EOF

# Make executable
chmod +x "$INSTALL_DIR/$APP_NAME"

# Update desktop database
echo "Updating desktop database..."
update-desktop-database /usr/share/applications 2>/dev/null || true

# Update icon cache
echo "Updating icon cache..."
gtk-update-icon-cache /usr/share/icons/hicolor 2>/dev/null || true

echo ""
echo "✓ Geogram Desktop installed successfully!"
echo ""
echo "You can now:"
echo "  - Launch from your application menu"
echo "  - Run from terminal: $INSTALL_DIR/$APP_NAME"
echo ""
echo "To uninstall, run: sudo rm -rf $INSTALL_DIR $DESKTOP_FILE $ICON_DIR/geogram.png"
echo ""
