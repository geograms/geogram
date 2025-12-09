# Security Settings

This document describes the security and privacy settings available in Geogram and how they work.

## Overview

Security settings are managed by the `SecurityService` singleton and are persisted in the application's `config.json` file. These settings control API access and location privacy.

## Settings

### HTTP API (`security.httpApiEnabled`)

Controls whether the HTTP API server is running and accessible to other devices on the network.

- **Default**: `true` (enabled)
- **When enabled**: Other devices on the same network can discover this device and connect to it via HTTP at `/api/`
- **When disabled**: The HTTP server is stopped and no incoming connections are accepted

All API endpoints are available under `/api/`:
- `/api/` - API root with endpoint listing
- `/api/status` - Device status and location
- `/api/log` - Log entries
- `/api/files` - Browse collections
- `/api/files/content` - Get file content
- `/api/debug` - Debug API (requires debug API enabled)

**Usage in code:**
```dart
import 'package:geogram_desktop/services/security_service.dart';

// Check if HTTP API is enabled
if (SecurityService().httpApiEnabled) {
  await LogApiService().start();
}

// Toggle HTTP API
SecurityService().httpApiEnabled = false;
```

### Debug API (`security.debugApiEnabled`)

Controls whether the debug API endpoints are accessible. The debug API allows external scripts to trigger actions in the application for testing purposes.

- **Default**: `false` (disabled)
- **When enabled**: The `/api/debug` endpoint accepts requests
- **When disabled**: The `/api/debug` endpoint returns 403 Forbidden

**Warning**: Only enable this setting if you know what you're doing. The debug API can trigger BLE scans, send data, and navigate the UI.

**Usage in code:**
```dart
import 'package:geogram_desktop/services/security_service.dart';

// Check if debug API is enabled
if (SecurityService().debugApiEnabled) {
  // Allow debug action
}

// Toggle debug API
SecurityService().debugApiEnabled = true;
```

### Location Granularity (`security.locationGranularityMeters`)

Controls how precisely location data is shared with other devices. This is a privacy feature that rounds coordinates to a configurable precision.

- **Default**: `50000.0` (50 km) - middle position on the slider
- **Minimum**: `5.0` meters (very precise)
- **Maximum**: `100000.0` meters (100 km, very private)

The slider in the UI uses a logarithmic scale for better UX across the wide range.

**Privacy levels:**
| Distance | Privacy Level | Description |
|----------|--------------|-------------|
| ≤10m | Very precise | Exact location |
| ≤100m | Precise | Street level |
| ≤1km | Moderate | Neighborhood level |
| ≤10km | City | City/town level |
| ≤50km | Regional | Regional level |
| >50km | Country | Country/area level |

**Usage in code:**
```dart
import 'package:geogram_desktop/services/security_service.dart';

// Get current granularity in meters
final granularityMeters = SecurityService().locationGranularityMeters;

// Set granularity to 1km
SecurityService().locationGranularityMeters = 1000.0;

// Apply granularity to coordinates before sharing
final profile = ProfileService().getProfile();
final (roundedLat, roundedLon) = SecurityService().applyLocationGranularity(
  profile.latitude,
  profile.longitude,
);

// Use roundedLat and roundedLon when sharing location

// For slider UI (0.0 to 1.0)
final sliderValue = SecurityService().locationGranularitySliderValue;
SecurityService().locationGranularitySliderValue = 0.5; // Sets to ~50km

// Get human-readable display
final display = SecurityService().locationGranularityDisplay; // e.g., "50 km"
final level = SecurityService().privacyLevelDescription; // e.g., "Regional level"
```

## Configuration File

Security settings are stored in the main configuration file at:
- **Linux/macOS**: `~/.config/geogram/config.json`
- **Windows**: `%APPDATA%\geogram\config.json`
- **Android**: App data directory

Example configuration:
```json
{
  "security": {
    "httpApiEnabled": true,
    "debugApiEnabled": false,
    "locationGranularityMeters": 50000.0
  }
}
```

## Integration Points

### HTTP API Status Endpoint

When other devices request `/api/status`, the location coordinates are automatically rounded according to the granularity setting before being returned.

```dart
// In LogApiService._handleStatusRequest()
final (roundedLat, roundedLon) = SecurityService().applyLocationGranularity(
  profile.latitude,
  profile.longitude,
);
```

### BLE HELLO Messages

When sending location in BLE HELLO messages, apply the same granularity:

```dart
// Before sending location in BLE messages
final (lat, lon) = SecurityService().applyLocationGranularity(
  profile.latitude,
  profile.longitude,
);
// Use lat and lon in the BLE message
```

### Device Discovery

When reporting location in station/device discovery responses, always use the granularity-adjusted coordinates:

```dart
final securityService = SecurityService();
final (adjustedLat, adjustedLon) = securityService.applyLocationGranularity(
  originalLat,
  originalLon,
);
```

## Listening for Changes

The `SecurityService` provides a `ValueNotifier` to listen for settings changes:

```dart
SecurityService().settingsNotifier.addListener(() {
  // Settings changed, update UI or restart services as needed
});
```

## API Reference

### SecurityService Methods

| Method | Description |
|--------|-------------|
| `debugApiEnabled` | Get/set debug API enabled state |
| `httpApiEnabled` | Get/set HTTP API enabled state |
| `locationGranularityMeters` | Get/set location granularity in meters |
| `locationGranularitySliderValue` | Get/set granularity as 0.0-1.0 slider value |
| `locationGranularityDisplay` | Get human-readable granularity (e.g., "50 km") |
| `privacyLevelDescription` | Get privacy level description |
| `applyLocationGranularity(lat, lon)` | Apply granularity to coordinates |

### Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `minGranularityMeters` | 5.0 | Minimum granularity (most precise) |
| `maxGranularityMeters` | 100000.0 | Maximum granularity (most private) |
