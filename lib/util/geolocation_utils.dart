/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Utility class for geolocation services.
 * Provides unified access to location detection via:
 * - GPS (mobile devices)
 * - Browser Geolocation API (web)
 * - Multiple IP geolocation services (desktop)
 * - User profile location (fallback)
 */

import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../services/log_service.dart';
import '../services/profile_service.dart';

/// Result of a geolocation attempt
class GeolocationResult {
  final double latitude;
  final double longitude;
  final String source; // 'gps', 'browser', 'ip', 'profile'
  final String? city;
  final String? country;
  final String? serviceName; // Which IP service was used (if IP-based)

  GeolocationResult({
    required this.latitude,
    required this.longitude,
    required this.source,
    this.city,
    this.country,
    this.serviceName,
  });

  LatLng get latLng => LatLng(latitude, longitude);

  bool get isValid => latitude != 0.0 || longitude != 0.0;

  @override
  String toString() =>
      'GeolocationResult($latitude, $longitude, source: $source${serviceName != null ? ', service: $serviceName' : ''})';
}

/// Utility class for geolocation services
class GeolocationUtils {
  GeolocationUtils._();

  static final ProfileService _profileService = ProfileService();

  /// Get user's current location using the best available method
  /// Priority: GPS/Browser > Profile location > IP geolocation
  ///
  /// [useProfile] - If true, checks profile location before IP services (default: true)
  /// [timeout] - Timeout for GPS/browser detection (default: 15 seconds)
  static Future<GeolocationResult?> getCurrentLocation({
    bool useProfile = true,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    try {
      if (kIsWeb) {
        // Web: Try browser geolocation
        final result = await _detectViaBrowser(timeout: timeout);
        if (result != null) return result;

        // Fallback to profile then IP
        if (useProfile) {
          final profileResult = getProfileLocation();
          if (profileResult != null) return profileResult;
        }
        return await detectViaIP();
      } else if (Platform.isAndroid || Platform.isIOS) {
        // Mobile: Try GPS
        final result = await _detectViaGPS(timeout: timeout);
        if (result != null) return result;

        // Fallback to profile then IP
        if (useProfile) {
          final profileResult = getProfileLocation();
          if (profileResult != null) return profileResult;
        }
        return await detectViaIP();
      } else {
        // Desktop: Profile location first, then IP
        if (useProfile) {
          final profileResult = getProfileLocation();
          if (profileResult != null) return profileResult;
        }
        return await detectViaIP();
      }
    } catch (e) {
      LogService().log('GeolocationUtils: Error getting location: $e');
      return null;
    }
  }

  /// Get location from user's profile settings
  static GeolocationResult? getProfileLocation() {
    final profile = _profileService.getProfile();
    if (profile.latitude != null &&
        profile.longitude != null &&
        (profile.latitude != 0.0 || profile.longitude != 0.0)) {
      LogService().log(
          'GeolocationUtils: Using profile location: ${profile.latitude}, ${profile.longitude}');
      return GeolocationResult(
        latitude: profile.latitude!,
        longitude: profile.longitude!,
        source: 'profile',
      );
    }
    return null;
  }

  /// Detect location via GPS (Android/iOS)
  /// Returns null if permission denied or service disabled
  static Future<GeolocationResult?> detectViaGPS({
    Duration timeout = const Duration(seconds: 15),
    bool requestPermission = false,
  }) async {
    if (kIsWeb || (!Platform.isAndroid && !Platform.isIOS)) {
      return null;
    }
    return _detectViaGPS(timeout: timeout, requestPermission: requestPermission);
  }

  static Future<GeolocationResult?> _detectViaGPS({
    Duration timeout = const Duration(seconds: 15),
    bool requestPermission = false,
  }) async {
    try {
      // Check if location services are enabled
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        LogService().log('GeolocationUtils: Location services disabled');
        return null;
      }

      // Check permission
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied && requestPermission) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        LogService().log('GeolocationUtils: GPS permission denied');
        return null;
      }

      // Get current position
      final position = await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: timeout,
        ),
      );

      LogService().log(
          'GeolocationUtils: GPS location: ${position.latitude}, ${position.longitude}');

      return GeolocationResult(
        latitude: position.latitude,
        longitude: position.longitude,
        source: 'gps',
      );
    } catch (e) {
      LogService().log('GeolocationUtils: GPS detection failed: $e');
      return null;
    }
  }

  /// Detect location via Browser Geolocation API (Web)
  static Future<GeolocationResult?> detectViaBrowser({
    Duration timeout = const Duration(seconds: 15),
    bool requestPermission = true,
  }) async {
    if (!kIsWeb) return null;
    return _detectViaBrowser(timeout: timeout, requestPermission: requestPermission);
  }

  static Future<GeolocationResult?> _detectViaBrowser({
    Duration timeout = const Duration(seconds: 15),
    bool requestPermission = true,
  }) async {
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied && requestPermission) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        LogService().log('GeolocationUtils: Browser permission denied');
        return null;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: timeout,
        ),
      );

      LogService().log(
          'GeolocationUtils: Browser location: ${position.latitude}, ${position.longitude}');

      return GeolocationResult(
        latitude: position.latitude,
        longitude: position.longitude,
        source: 'browser',
      );
    } catch (e) {
      LogService().log('GeolocationUtils: Browser geolocation failed: $e');
      return null;
    }
  }

  /// Detect location via IP address using multiple services
  /// Tries services in order until one succeeds
  static Future<GeolocationResult?> detectViaIP() async {
    // Try multiple services in order of reliability
    final services = <Future<GeolocationResult?> Function()>[
      _tryIpApiCom,
      _tryIpInfoIo,
      _tryIpWhoIs,
    ];

    for (final service in services) {
      try {
        final result = await service();
        if (result != null) {
          return result;
        }
      } catch (e) {
        LogService().log('GeolocationUtils: IP service failed: $e');
      }
    }

    LogService().log('GeolocationUtils: All IP geolocation services failed');
    return null;
  }

  /// Try ip-api.com service
  static Future<GeolocationResult?> _tryIpApiCom() async {
    final response = await http
        .get(
          Uri.parse('http://ip-api.com/json/?fields=status,lat,lon,city,country'),
        )
        .timeout(const Duration(seconds: 5));

    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      if (data['status'] == 'success') {
        final lat = (data['lat'] as num).toDouble();
        final lon = (data['lon'] as num).toDouble();

        LogService().log(
            'GeolocationUtils: ip-api.com location: $lat, $lon (${data['city']}, ${data['country']})');

        return GeolocationResult(
          latitude: lat,
          longitude: lon,
          source: 'ip',
          city: data['city'] as String?,
          country: data['country'] as String?,
          serviceName: 'ip-api.com',
        );
      }
    }
    return null;
  }

  /// Try ipinfo.io service (often more accurate for European ISPs)
  static Future<GeolocationResult?> _tryIpInfoIo() async {
    final response = await http
        .get(Uri.parse('https://ipinfo.io/json'))
        .timeout(const Duration(seconds: 5));

    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      final loc = data['loc'] as String?;
      if (loc != null && loc.contains(',')) {
        final parts = loc.split(',');
        final lat = double.tryParse(parts[0]);
        final lon = double.tryParse(parts[1]);
        if (lat != null && lon != null) {
          LogService().log(
              'GeolocationUtils: ipinfo.io location: $lat, $lon (${data['city']}, ${data['country']})');

          return GeolocationResult(
            latitude: lat,
            longitude: lon,
            source: 'ip',
            city: data['city'] as String?,
            country: data['country'] as String?,
            serviceName: 'ipinfo.io',
          );
        }
      }
    }
    return null;
  }

  /// Try ipwhois.app service
  static Future<GeolocationResult?> _tryIpWhoIs() async {
    final response = await http
        .get(Uri.parse('https://ipwho.is/'))
        .timeout(const Duration(seconds: 5));

    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      if (data['success'] == true) {
        final lat = (data['latitude'] as num?)?.toDouble();
        final lon = (data['longitude'] as num?)?.toDouble();
        if (lat != null && lon != null) {
          LogService().log(
              'GeolocationUtils: ipwhois.app location: $lat, $lon (${data['city']}, ${data['country']})');

          return GeolocationResult(
            latitude: lat,
            longitude: lon,
            source: 'ip',
            city: data['city'] as String?,
            country: data['country'] as String?,
            serviceName: 'ipwhois.app',
          );
        }
      }
    }
    return null;
  }

  /// Check if GPS/location services are available on this device
  static Future<bool> isGPSAvailable() async {
    if (kIsWeb) return false;
    if (!Platform.isAndroid && !Platform.isIOS) return false;

    try {
      return await Geolocator.isLocationServiceEnabled();
    } catch (e) {
      return false;
    }
  }

  /// Check current location permission status
  static Future<LocationPermission> checkPermission() async {
    return await Geolocator.checkPermission();
  }

  /// Request location permission
  static Future<LocationPermission> requestPermission() async {
    return await Geolocator.requestPermission();
  }

  /// Calculate distance between two coordinates in kilometers (Haversine formula)
  static double calculateDistance(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const Distance distance = Distance();
    return distance.as(
      LengthUnit.Kilometer,
      LatLng(lat1, lon1),
      LatLng(lat2, lon2),
    );
  }
}
