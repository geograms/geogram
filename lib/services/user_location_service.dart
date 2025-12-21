/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Service for automatically detecting and updating user's location.
 * - On Windows/Linux: Uses IP-based geolocation when connected to internet
 * - On Android/iOS: Uses device GPS/location services
 * - On Web: Uses browser Geolocation API
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb, ChangeNotifier;
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'log_service.dart';
import 'profile_service.dart';

/// User's current location with metadata
class UserLocation {
  final double latitude;
  final double longitude;
  final DateTime timestamp;
  final String source; // 'gps', 'ip', 'browser', 'profile', 'unknown'
  final String? locationName;

  UserLocation({
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    required this.source,
    this.locationName,
  });

  LatLng get latLng => LatLng(latitude, longitude);

  bool get isValid => latitude != 0.0 || longitude != 0.0;

  @override
  String toString() => 'UserLocation($latitude, $longitude, source: $source)';
}

/// Service for automatic user location detection and updates
class UserLocationService extends ChangeNotifier {
  static final UserLocationService _instance = UserLocationService._internal();
  factory UserLocationService() => _instance;
  UserLocationService._internal();

  final ProfileService _profileService = ProfileService();

  UserLocation? _currentLocation;
  Timer? _updateTimer;
  bool _isUpdating = false;
  StreamSubscription<Position>? _positionSubscription;

  /// Update interval for IP-based location (desktop)
  static const Duration ipUpdateInterval = Duration(minutes: 10);

  /// Get current user location
  UserLocation? get currentLocation => _currentLocation;

  /// Check if location is available
  bool get hasLocation => _currentLocation?.isValid ?? false;

  /// Check if currently updating location
  bool get isUpdating => _isUpdating;

  /// Initialize the service and start location updates
  Future<void> initialize() async {
    LogService().log('UserLocationService: Initializing...');

    // First, try to get location from profile
    _loadFromProfile();

    // Then start platform-specific location detection
    await _startLocationUpdates();
  }

  /// Load initial location from user profile
  void _loadFromProfile() {
    final profile = _profileService.getProfile();
    if (profile.latitude != null && profile.longitude != null &&
        (profile.latitude != 0.0 || profile.longitude != 0.0)) {
      _currentLocation = UserLocation(
        latitude: profile.latitude!,
        longitude: profile.longitude!,
        timestamp: DateTime.now(),
        source: 'profile',
        locationName: profile.locationName,
      );
      LogService().log('UserLocationService: Loaded from profile: ${profile.latitude}, ${profile.longitude}');
    }
  }

  /// Start platform-specific location updates
  Future<void> _startLocationUpdates() async {
    if (kIsWeb) {
      // Web: Use browser geolocation API
      await _startBrowserLocationUpdates();
    } else if (Platform.isAndroid || Platform.isIOS) {
      // Mobile: Use GPS with continuous updates
      await _startMobileLocationUpdates();
    } else {
      // Desktop (Windows/Linux/macOS): Use IP-based geolocation
      await _startDesktopLocationUpdates();
    }
  }

  /// Start browser-based location updates (Web)
  Future<void> _startBrowserLocationUpdates() async {
    LogService().log('UserLocationService: Starting browser location updates');

    // Initial detection
    await _detectBrowserLocation();

    // Set up periodic updates (less frequent on web)
    _updateTimer?.cancel();
    _updateTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      _detectBrowserLocation();
    });
  }

  /// Detect location using browser Geolocation API
  Future<void> _detectBrowserLocation() async {
    if (_isUpdating) return;
    _isUpdating = true;
    notifyListeners();

    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        // Fall back to IP-based
        await _detectLocationViaIP();
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 15),
        ),
      );

      _updateLocation(
        position.latitude,
        position.longitude,
        'browser',
      );
    } catch (e) {
      LogService().log('UserLocationService: Browser geolocation failed: $e');
      // Fall back to IP-based
      await _detectLocationViaIP();
    } finally {
      _isUpdating = false;
      notifyListeners();
    }
  }

  /// Start mobile GPS location updates (Android/iOS)
  Future<void> _startMobileLocationUpdates() async {
    LogService().log('UserLocationService: Starting mobile GPS updates');

    // Check if location services are enabled
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      LogService().log('UserLocationService: Location services disabled, using IP');
      await _detectLocationViaIP();
      _startDesktopLocationUpdates(); // Fall back to IP polling
      return;
    }

    // Check permission status - do NOT auto-request for returning users
    // First-time users will be prompted during onboarding
    LocationPermission permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      LogService().log('UserLocationService: GPS permission denied, using IP');
      await _detectLocationViaIP();
      _startDesktopLocationUpdates(); // Fall back to IP polling
      return;
    }

    // Get initial position
    try {
      _isUpdating = true;
      notifyListeners();

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );

      _updateLocation(position.latitude, position.longitude, 'gps');
    } catch (e) {
      LogService().log('UserLocationService: Initial GPS failed: $e');
      await _detectLocationViaIP();
    } finally {
      _isUpdating = false;
      notifyListeners();
    }

    // Start continuous position stream for mobile
    _positionSubscription?.cancel();
    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.medium,
        distanceFilter: 100, // Update when moved 100+ meters
      ),
    ).listen(
      (Position position) {
        _updateLocation(position.latitude, position.longitude, 'gps');
      },
      onError: (error) {
        LogService().log('UserLocationService: GPS stream error: $error');
      },
    );
  }

  /// Start desktop IP-based location updates (Windows/Linux/macOS)
  Future<void> _startDesktopLocationUpdates() async {
    LogService().log('UserLocationService: Starting IP-based location updates');

    // Initial detection
    await _detectLocationViaIP();

    // Set up periodic IP-based updates
    _updateTimer?.cancel();
    _updateTimer = Timer.periodic(ipUpdateInterval, (_) {
      _detectLocationViaIP();
    });
  }

  /// Detect location via IP address (works on all platforms)
  Future<void> _detectLocationViaIP() async {
    if (_isUpdating) return;
    _isUpdating = true;
    notifyListeners();

    try {
      final response = await http.get(
        Uri.parse('http://ip-api.com/json/?fields=status,lat,lon,city,country'),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['status'] == 'success') {
          final lat = (data['lat'] as num).toDouble();
          final lon = (data['lon'] as num).toDouble();
          final city = data['city'] as String?;
          final country = data['country'] as String?;

          String? locationName;
          if (city != null && country != null) {
            locationName = '$city, $country';
          }

          _updateLocation(lat, lon, 'ip', locationName: locationName);
        }
      }
    } catch (e) {
      LogService().log('UserLocationService: IP geolocation failed: $e');
    } finally {
      _isUpdating = false;
      notifyListeners();
    }
  }

  /// Update the current location
  void _updateLocation(double lat, double lon, String source, {String? locationName}) {
    // Skip if coordinates are invalid
    if (lat == 0.0 && lon == 0.0) return;

    // Don't allow IP geolocation to overwrite a profile location
    // Profile location is explicitly set by the user and should have highest priority
    if (_currentLocation != null && _currentLocation!.source == 'profile' && source == 'ip') {
      LogService().log('UserLocationService: Skipping IP location update - profile location has priority');
      return;
    }

    // Check if location has changed significantly (> 100m)
    if (_currentLocation != null) {
      final distance = _calculateDistance(
        _currentLocation!.latitude,
        _currentLocation!.longitude,
        lat,
        lon,
      );
      if (distance < 0.1) {
        // Less than 100m, don't update
        return;
      }
    }

    _currentLocation = UserLocation(
      latitude: lat,
      longitude: lon,
      timestamp: DateTime.now(),
      source: source,
      locationName: locationName,
    );

    LogService().log('UserLocationService: Location updated to $lat, $lon (source: $source)');
    notifyListeners();
  }

  /// Calculate distance between two coordinates in km (Haversine)
  double _calculateDistance(double lat1, double lon1, double lat2, double lon2) {
    const earthRadius = 6371.0;
    final dLat = _degreesToRadians(lat2 - lat1);
    final dLon = _degreesToRadians(lon2 - lon1);

    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_degreesToRadians(lat1)) *
            cos(_degreesToRadians(lat2)) *
            sin(dLon / 2) *
            sin(dLon / 2);

    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthRadius * c;
  }

  double _degreesToRadians(double degrees) {
    return degrees * pi / 180;
  }

  /// Calculate distance from current location to a point in km
  double? distanceTo(double lat, double lon) {
    if (_currentLocation == null || !_currentLocation!.isValid) return null;
    return _calculateDistance(
      _currentLocation!.latitude,
      _currentLocation!.longitude,
      lat,
      lon,
    );
  }

  /// Force a location refresh
  Future<void> refresh() async {
    LogService().log('UserLocationService: Forcing refresh');

    if (kIsWeb) {
      await _detectBrowserLocation();
    } else if (Platform.isAndroid || Platform.isIOS) {
      try {
        _isUpdating = true;
        notifyListeners();

        final position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 15),
          ),
        );
        _updateLocation(position.latitude, position.longitude, 'gps');
      } catch (e) {
        LogService().log('UserLocationService: GPS refresh failed: $e');
        await _detectLocationViaIP();
      } finally {
        _isUpdating = false;
        notifyListeners();
      }
    } else {
      await _detectLocationViaIP();
    }
  }

  /// Stop location updates and clean up
  @override
  void dispose() {
    _updateTimer?.cancel();
    _updateTimer = null;
    _positionSubscription?.cancel();
    _positionSubscription = null;
    LogService().log('UserLocationService: Disposed');
    super.dispose();
  }
}
