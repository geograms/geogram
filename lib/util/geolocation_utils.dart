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
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart' show InternetAddressType, NetworkInterface, Platform, File, Directory;

import 'dart:typed_data';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart' show InternetAddressType, NetworkInterface, Platform;

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show rootBundle;
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../services/geoip_service.dart';
import '../services/log_service.dart';
import '../services/profile_service.dart';
import '../services/websocket_service.dart';
import '../services/storage_config.dart';
import '../services/station_service.dart';
import '../services/profile_storage.dart';

/// Result of a geolocation attempt
class GeolocationResult {
  final double latitude;
  final double longitude;
  final String source; // 'gps', 'browser', 'ip', 'profile'
  final String? city;
  final String? country;
  final String? serviceName; // Which IP service was used (if IP-based)
  final double? accuracy; // Accuracy in meters (for GPS/browser sources)

  GeolocationResult({
    required this.latitude,
    required this.longitude,
    required this.source,
    this.city,
    this.country,
    this.serviceName,
    this.accuracy,
  });

  LatLng get latLng => LatLng(latitude, longitude);

  bool get isValid => latitude != 0.0 || longitude != 0.0;

  @override
  String toString() =>
      'GeolocationResult($latitude, $longitude, source: $source${serviceName != null ? ', service: $serviceName' : ''}${accuracy != null ? ', accuracy: ${accuracy}m' : ''})';
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
  /// Returns null if permission denied, service disabled, or accuracy exceeds threshold
  /// [minAccuracyMeters] - If provided, rejects positions with accuracy worse than this
  ///   (useful for filtering out cell tower locations which typically have 500m+ accuracy)
  /// [timeout] - Default 60s for cold GPS start without A-GPS assistance
  static Future<GeolocationResult?> detectViaGPS({
    Duration timeout = const Duration(seconds: 60),
    bool requestPermission = false,
    double? minAccuracyMeters,
  }) async {
    if (kIsWeb || (!Platform.isAndroid && !Platform.isIOS)) {
      return null;
    }
    return _detectViaGPS(
      timeout: timeout,
      requestPermission: requestPermission,
      minAccuracyMeters: minAccuracyMeters,
    );
  }

  static Future<GeolocationResult?> _detectViaGPS({
    Duration timeout = const Duration(seconds: 60),
    bool requestPermission = false,
    double? minAccuracyMeters,
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

      // Get current position with best accuracy
      final position = await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(
          accuracy: LocationAccuracy.best,
          timeLimit: timeout,
        ),
      );

      // Reject cell tower locations if accuracy threshold is specified
      if (minAccuracyMeters != null && position.accuracy > minAccuracyMeters) {
        LogService().log(
            'GeolocationUtils: GPS accuracy ${position.accuracy.toStringAsFixed(0)}m exceeds threshold ${minAccuracyMeters.toStringAsFixed(0)}m, rejecting');
        return null;
      }

      LogService().log(
          'GeolocationUtils: GPS location: ${position.latitude}, ${position.longitude} (accuracy: ${position.accuracy.toStringAsFixed(0)}m)');

      return GeolocationResult(
        latitude: position.latitude,
        longitude: position.longitude,
        source: 'gps',
        accuracy: position.accuracy,
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
          'GeolocationUtils: Browser location: ${position.latitude}, ${position.longitude} (accuracy: ${position.accuracy.toStringAsFixed(0)}m)');

      return GeolocationResult(
        latitude: position.latitude,
        longitude: position.longitude,
        source: 'browser',
        accuracy: position.accuracy,
      );
    } catch (e) {
      LogService().log('GeolocationUtils: Browser geolocation failed: $e');
      return null;
    }
  }

  /// Detect location via IP address using the connected station's GeoIP service
  /// This provides privacy-preserving IP geolocation without external API calls
  static Future<GeolocationResult?> detectViaIP() async {
    // 1. Try local GeoIP database directly (no station connection needed)
    final localResult = await _detectViaLocalGeoIP();
    if (localResult != null) return localResult;

    // 2. Fall back to station's /api/geoip endpoint
    try {
      final stationUrl = WebSocketService().connectedUrl;
      if (stationUrl == null) {
        LogService().log('GeolocationUtils: No local GeoIP and not connected to station');
        return null;
      }

      final httpUrl = stationUrl
          .replaceFirst('wss://', 'https://')
          .replaceFirst('ws://', 'http://');

      final response = await http
          .get(Uri.parse('$httpUrl/api/geoip'))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final lat = (data['latitude'] as num?)?.toDouble();
        final lon = (data['longitude'] as num?)?.toDouble();

        if (lat != null && lon != null) {
          LogService().log(
              'GeolocationUtils: Station GeoIP location: $lat, $lon (${data['city']}, ${data['country']})');

          return GeolocationResult(
            latitude: lat,
            longitude: lon,
            source: 'ip',
            city: data['city'] as String?,
            country: data['country'] as String?,
            serviceName: 'station-geoip',
          );
        }
      } else if (response.statusCode == 503) {
        LogService().log('GeolocationUtils: Station GeoIP service not initialized');
      } else {
        LogService().log('GeolocationUtils: Station GeoIP failed with status ${response.statusCode}');
      }

      return null;
    } catch (e) {
      LogService().log('GeolocationUtils: Station GeoIP failed: $e');
      return null;
    }
  }

  /// Try to geolocate using the local MMDB database + network interface IPs.
  /// Downloads GeoIP database from station server first, then falls back to jsdelivr CDN.
  static Future<GeolocationResult?> _detectViaLocalGeoIP() async {
    final geoip = GeoIpService();

    // Initialize GeoIpService - try multiple sources
    if (!geoip.isInitialized) {
      await _ensureGeoipDatabase();
    }

    if (!geoip.isInitialized) {
      LogService().log('GeolocationUtils: GeoIP DB not available');
      return null;
    }

    try {
      if (kIsWeb) return null; // No NetworkInterface on web

      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
      );

      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (ip.startsWith('127.') ||
              ip.startsWith('10.') ||
              ip.startsWith('192.168.') ||
              ip.startsWith('169.254.')) continue;
          if (ip.startsWith('172.')) {
            final second = int.tryParse(ip.split('.')[1]) ?? 0;
            if (second >= 16 && second <= 31) continue;
          }

          final result = await geoip.lookup(ip);
          if (result != null && result.hasLocation) {
            LogService().log(
                'GeolocationUtils: Local GeoIP for $ip: ${result.latitude}, ${result.longitude} (${result.locationName})');
            return GeolocationResult(
              latitude: result.latitude!,
              longitude: result.longitude!,
              source: 'ip',
              city: result.city,
              country: result.country,
              serviceName: 'local-geoip',
            );
          }
        }
      }

      // No public IP on any interface — typical behind NAT.
      // Will resolve once a station connection provides the public IP
      // via /api/geoip, or the periodic timer retries.
      return null;
    } catch (e) {
      LogService().log('GeolocationUtils: Local GeoIP lookup failed: $e');
      return null;
    }
  }

  /// Ensure GeoIP database is available by downloading from station or fallback CDN
  static Future<void> _ensureGeoipDatabase() async {
    final storage = StorageConfig();
    if (!storage.isInitialized) return;

    // Use FilesystemProfileStorage for baseDir-level storage (outside encrypted profiles)
    final baseStorage = FilesystemProfileStorage(storage.baseDir);
    const geoipRelativePath = 'geoip/dbip-city-lite.mmdb';

    // Already have it?
    if (await baseStorage.exists(geoipRelativePath)) {
      try {
        final bytes = await baseStorage.readBytes(geoipRelativePath);
        if (bytes != null) {
          await GeoIpService().initFromBytes(bytes);
          LogService().log('GeolocationUtils: Loaded GeoIP DB from cache');
          return;
        }
      } catch (e) {
        LogService().log('GeolocationUtils: Failed to load cached GeoIP DB: $e');
      }
    }

    // Try station server first
    if (!kIsWeb) {
      try {
        final station = StationService().getPreferredStation();
        if (station != null && station.url.isNotEmpty) {
          final httpUrl = station.url
              .replaceFirst('wss://', 'https://')
              .replaceFirst('ws://', 'http://');
          final url = '$httpUrl/geoip/dbip-city-lite.mmdb';

          LogService().log('GeolocationUtils: Downloading GeoIP DB from station...');
          final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 30));

          if (response.statusCode == 200) {
            await baseStorage.createDirectory('geoip');
            await baseStorage.writeBytes(geoipRelativePath, response.bodyBytes);
            await GeoIpService().initFromBytes(response.bodyBytes);
            LogService().log('GeolocationUtils: GeoIP DB loaded from station');
            return;
          }
        }
      } catch (e) {
        LogService().log('GeolocationUtils: Station GeoIP download failed: $e');
      }
    }

    // Fallback to jsdelivr CDN
    try {
      LogService().log('GeolocationUtils: Downloading GeoIP DB from jsdelivr...');
      const cdnUrl = 'https://cdn.jsdelivr.net/npm/dbip-city-lite/dbip-city-lite.mmdb.gz';
      final response = await http.get(Uri.parse(cdnUrl)).timeout(const Duration(seconds: 60));

      if (response.statusCode == 200) {
        // Decode gzip
        final compressed = response.bodyBytes;
        final decompressed = GZipDecoder().decodeBytes(compressed);

        await baseStorage.createDirectory('geoip');
        await baseStorage.writeBytes(geoipRelativePath, Uint8List.fromList(decompressed));
        await GeoIpService().initFromBytes(Uint8List.fromList(decompressed));
        LogService().log('GeolocationUtils: GeoIP DB loaded from CDN');
      }
    } catch (e) {
      LogService().log('GeolocationUtils: CDN GeoIP download failed: $e');
    }
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
