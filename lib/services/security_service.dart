/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:math';
import 'package:flutter/foundation.dart';
import 'config_service.dart';
import 'log_service.dart';

/// Service for managing security and privacy settings
class SecurityService {
  static final SecurityService _instance = SecurityService._internal();
  factory SecurityService() => _instance;
  SecurityService._internal();

  final ConfigService _config = ConfigService();

  /// Notifier for security settings changes
  final ValueNotifier<int> settingsNotifier = ValueNotifier<int>(0);

  // Config keys
  static const String _keyDebugApiEnabled = 'security.debugApiEnabled';
  static const String _keyHttpApiEnabled = 'security.httpApiEnabled';
  static const String _keyBleOnlyMode = 'security.bleOnlyMode';
  static const String _keyUsbAccessEnabled = 'security.usbAccessEnabled';
  static const String _keyLocationGranularity =
      'security.locationGranularityMeters';

  // Default values
  static const bool _defaultDebugApiEnabled = false;
  static const bool _defaultHttpApiEnabled = true;
  static const bool _defaultBleOnlyMode = false;
  static const bool _defaultUsbAccessEnabled = true;
  static const double _defaultLocationGranularity =
      50000.0; // 50 km default (middle of slider, region level)

  // Location granularity bounds
  // Uses bilinear-log scale: 5m - 50km - 100km with 50km at slider center (0.5)
  static const double minGranularityMeters = 5.0;
  static const double centerGranularityMeters = 50000.0; // 50 km at slider 0.5
  static const double maxGranularityMeters = 100000.0; // 100 km

  /// Check if debug API is enabled
  bool get debugApiEnabled {
    return _config.getNestedValue(_keyDebugApiEnabled, _defaultDebugApiEnabled)
        as bool;
  }

  /// Set debug API enabled state
  set debugApiEnabled(bool value) {
    _config.setNestedValue(_keyDebugApiEnabled, value);
    _notifyChange();
    LogService().log(
      'SecurityService: Debug API ${value ? 'enabled' : 'disabled'}',
    );
  }

  /// Check if BLE-only mode is enabled
  bool get bleOnlyMode {
    return _config.getNestedValue(_keyBleOnlyMode, _defaultBleOnlyMode) as bool;
  }

  /// Set BLE-only mode state
  set bleOnlyMode(bool value) {
    _config.setNestedValue(_keyBleOnlyMode, value);
    _notifyChange();
    LogService().log(
      'SecurityService: BLE-only mode ${value ? 'enabled' : 'disabled'}',
    );
  }

  /// Check if USB communication is enabled
  bool get usbAccessEnabled {
    return _config.getNestedValue(
          _keyUsbAccessEnabled,
          _defaultUsbAccessEnabled,
        )
        as bool;
  }

  /// Set USB communication enabled state
  set usbAccessEnabled(bool value) {
    _config.setNestedValue(_keyUsbAccessEnabled, value);
    _notifyChange();
    LogService().log(
      'SecurityService: USB access ${value ? 'enabled' : 'disabled'}',
    );
  }

  /// Check if HTTP API is enabled
  bool get httpApiEnabled {
    return _config.getNestedValue(_keyHttpApiEnabled, _defaultHttpApiEnabled)
        as bool;
  }

  /// Set HTTP API enabled state
  set httpApiEnabled(bool value) {
    _config.setNestedValue(_keyHttpApiEnabled, value);
    _notifyChange();
    LogService().log(
      'SecurityService: HTTP API ${value ? 'enabled' : 'disabled'}',
    );
  }

  /// Get location granularity in meters
  double get locationGranularityMeters {
    final value = _config.getNestedValue(
      _keyLocationGranularity,
      _defaultLocationGranularity,
    );
    if (value is int) return value.toDouble();
    return (value as double?) ?? _defaultLocationGranularity;
  }

  /// Set location granularity in meters
  set locationGranularityMeters(double value) {
    final clampedValue = value.clamp(
      minGranularityMeters,
      maxGranularityMeters,
    );
    _config.setNestedValue(_keyLocationGranularity, clampedValue);
    _notifyChange();
    LogService().log(
      'SecurityService: Location granularity set to ${_formatDistance(clampedValue)}',
    );
  }

  /// Get location granularity as a normalized slider value (0.0 to 1.0)
  /// Uses bilinear-log scale: 0.0-0.5 maps to 5m-25km, 0.5-1.0 maps to 25km-100km
  /// This ensures 25km (city level) is exactly at the slider center
  double get locationGranularitySliderValue {
    final meters = locationGranularityMeters;
    if (meters <= centerGranularityMeters) {
      // Map min-center to 0.0-0.5
      final logMin = log(minGranularityMeters);
      final logCenter = log(centerGranularityMeters);
      final t = (log(meters) - logMin) / (logCenter - logMin);
      return t * 0.5;
    } else {
      // Map center-max to 0.5-1.0
      final logCenter = log(centerGranularityMeters);
      final logMax = log(maxGranularityMeters);
      final t = (log(meters) - logCenter) / (logMax - logCenter);
      return 0.5 + t * 0.5;
    }
  }

  /// Set location granularity from a normalized slider value (0.0 to 1.0)
  set locationGranularitySliderValue(double sliderValue) {
    final clampedSlider = sliderValue.clamp(0.0, 1.0);
    if (clampedSlider <= 0.5) {
      // Map 0.0-0.5 to min-center (log scale)
      final t = clampedSlider * 2.0; // Normalize to 0-1
      final logMin = log(minGranularityMeters);
      final logCenter = log(centerGranularityMeters);
      locationGranularityMeters = exp(logMin + t * (logCenter - logMin));
    } else {
      // Map 0.5-1.0 to center-max (log scale)
      final t = (clampedSlider - 0.5) * 2.0; // Normalize to 0-1
      final logCenter = log(centerGranularityMeters);
      final logMax = log(maxGranularityMeters);
      locationGranularityMeters = exp(logCenter + t * (logMax - logCenter));
    }
  }

  /// Apply location granularity to coordinates
  /// Returns coordinates rounded to the configured precision
  /// This is used when sharing location with other devices
  (double?, double?) applyLocationGranularity(
    double? latitude,
    double? longitude,
  ) {
    if (latitude == null || longitude == null) return (null, null);

    final granularityMeters = locationGranularityMeters;

    // Convert granularity from meters to degrees
    // At equator: 1 degree = ~111,320 meters
    // For latitude, this is constant
    // For longitude, it varies with latitude, but we use equator as approximation
    const metersPerDegree = 111320.0;
    final granularityDegrees = granularityMeters / metersPerDegree;

    // Round coordinates to granularity
    final roundedLat =
        (latitude / granularityDegrees).round() * granularityDegrees;
    final roundedLon =
        (longitude / granularityDegrees).round() * granularityDegrees;

    return (roundedLat, roundedLon);
  }

  /// Format granularity distance for display
  String get locationGranularityDisplay {
    return _formatDistance(locationGranularityMeters);
  }

  /// Format a distance in meters for display
  static String _formatDistance(double meters) {
    if (meters >= 1000) {
      final km = meters / 1000;
      if (km >= 10) {
        return '${km.round()} km';
      }
      return '${km.toStringAsFixed(1)} km';
    }
    return '${meters.round()} m';
  }

  /// Get a human-readable description of the current privacy level
  String get privacyLevelDescription {
    final meters = locationGranularityMeters;
    if (meters <= 50) {
      return 'Very precise (exact location)';
    } else if (meters <= 500) {
      return 'Precise (street level)';
    } else if (meters <= 5000) {
      return 'Neighborhood level';
    } else if (meters <= 40000) {
      return 'City level';
    } else {
      return 'Region level';
    }
  }

  void _notifyChange() {
    settingsNotifier.value++;
  }
}
