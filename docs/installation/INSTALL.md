# Geogram Desktop - Linux Installation

## Running the Application

### Option 1: Run Directly (Portable)

You can run Geogram Desktop without installing it:

```bash
cd build/linux/x64/release/bundle/
./geogram_desktop
```

The application will show with the Geogram icon in your task manager/window list.

### Option 2: System Installation

For a proper system installation with desktop integration:

```bash
sudo ./install.sh
```

This will:
- Install the application to `/opt/geogram-desktop`
- Add it to your application menu
- Install the Geogram icon system-wide
- Create a desktop launcher entry

After installation, you can:
- Launch from your application menu (search for "Geogram Desktop")
- Run from terminal: `/opt/geogram-desktop/geogram_desktop`

### Uninstalling

To remove a system installation:

```bash
sudo rm -rf /opt/geogram-desktop
sudo rm /usr/share/applications/dev.geogram.geogram_desktop.desktop
sudo rm /usr/share/icons/hicolor/512x512/apps/geogram.png
sudo update-desktop-database /usr/share/applications
sudo gtk-update-icon-cache /usr/share/icons/hicolor
```

## Distribution

To distribute the application, package the entire `build/linux/x64/release/bundle/` directory along with the `install.sh` script.

The bundle contains:
- `geogram_desktop` - Main executable
- `lib/` - Required shared libraries
- `data/` - Application data, icon, and resources

**Total size**: ~100MB

## Application Icon

The application icon is sourced from the official Geogram project and will be displayed:
- In the window title bar
- In the task manager/taskbar
- In the application switcher (Alt+Tab)
- In the system application menu (when installed)

The icon file is located at: `data/app_icon.png` (702x732 PNG)
