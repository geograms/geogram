# Desktop App Icon Setup

This document explains how the custom app icon is configured for the Linux desktop version of Geogram.

## Icon Location

The app icon is stored at:
```
linux/data/app_icon.png
```

This is a 512x512 PNG image that serves as the window icon for the desktop application.

## How It Works

1. **Icon File**: The icon is copied from the web icons directory during initial setup
2. **CMakeLists.txt**: The build system is configured to install the icon to the bundle's data directory
3. **Application Code**: The `my_application.cc` file loads and sets the icon when the window is created

## Updating the Icon

To use a custom icon:

1. Replace the icon file at `linux/data/app_icon.png` with your custom PNG image
2. Recommended size: 512x512 pixels or larger
3. Rebuild the app using:
   ```bash
   ./rebuild-desktop.sh
   ```

## Technical Details

The icon is set in `linux/runner/my_application.cc`:
```cpp
// Set window icon
g_autoptr(GError) icon_error = nullptr;
const gchar* icon_path = "data/app_icon.png";
if (!gtk_window_set_icon_from_file(window, icon_path, &icon_error)) {
  g_warning("Failed to set window icon: %s", icon_error->message);
}
```

The icon path is relative to the bundle directory where the app is installed.

## Current Icon

Currently using the default Flutter icon. To create a custom Geogram icon:

1. Design an icon that represents Geogram (e.g., a map pin, location marker, or network nodes)
2. Export as PNG at 512x512 or larger
3. Replace `linux/data/app_icon.png`
4. Run `./rebuild-desktop.sh`
