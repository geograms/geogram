/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Offline IP geolocation service using DB-IP MMDB database.
 * Provides privacy-preserving IP geolocation without external API calls.
 *
 * Database: DB-IP Lite (https://db-ip.com) - CC BY 4.0 license
 * Attribution required: "IP Geolocation by DB-IP"
 *
 * Note: This file must remain pure Dart (no Flutter dependencies) for CLI compatibility.
 * Flutter apps should load assets via rootBundle and call initFromBytes().
 */

import 'dart:io';
import 'dart:typed_data';

import 'package:maxminddb/maxminddb.dart';

import '../util/network_utils.dart';
import 'log_service.dart';

/// Result of IP geolocation lookup
class GeoIpResult {
  final String ip;
  final double? latitude;
  final double? longitude;
  final String? city;
  final String? country;
  final String? countryCode;

  GeoIpResult({
    required this.ip,
    this.latitude,
    this.longitude,
    this.city,
    this.country,
    this.countryCode,
  });

  bool get hasLocation => latitude != null && longitude != null;

  String? get locationName {
    if (city != null && country != null) {
      return '$city, $country';
    } else if (city != null) {
      return city;
    } else if (country != null) {
      return country;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'ip': ip,
        'latitude': latitude,
        'longitude': longitude,
        'city': city,
        'country': country,
        'countryCode': countryCode,
      };

  @override
  String toString() =>
      'GeoIpResult($ip, lat: $latitude, lon: $longitude, city: $city, country: $country)';
}

/// Singleton service for offline IP geolocation
class GeoIpService {
  static final GeoIpService _instance = GeoIpService._internal();
  factory GeoIpService() => _instance;
  GeoIpService._internal();

  MaxMindDatabase? _database;
  bool _initialized = false;
  bool _initializing = false;

  /// Whether the database has been loaded
  bool get isInitialized => _initialized;

  /// Initialize the service by loading the MMDB database from a file path
  /// Used by CLI/pure station mode
  Future<void> initFromFile(String filePath) async {
    if (_initialized || _initializing) return;
    _initializing = true;

    try {
      LogService().log('GeoIpService: Loading DB-IP database from $filePath...');

      final file = File(filePath);
      if (!await file.exists()) {
        throw Exception('Database file not found: $filePath');
      }

      final bytes = await file.readAsBytes();
      _database = await MaxMindDatabase.memory(bytes);

      _initialized = true;
      LogService().log('GeoIpService: Database loaded successfully (${bytes.length} bytes)');
    } catch (e) {
      LogService().log('GeoIpService: Failed to load database from file: $e');
      _initializing = false;
      rethrow;
    }
  }

  /// Initialize from raw bytes (useful for tests or pre-loaded data)
  Future<void> initFromBytes(Uint8List bytes) async {
    if (_initialized) return;

    _database = await MaxMindDatabase.memory(bytes);
    _initialized = true;
    LogService().log('GeoIpService: Database loaded from bytes (${bytes.length} bytes)');
  }

  /// Look up geolocation for an IP address
  /// Returns null if database not initialized or IP not found
  Future<GeoIpResult?> lookup(String ipAddress) async {
    if (!_initialized || _database == null) {
      LogService().log('GeoIpService: Database not initialized');
      return null;
    }

    // Skip private/local IP addresses
    if (_isPrivateIP(ipAddress)) {
      LogService().log('GeoIpService: Skipping private IP: $ipAddress');
      return GeoIpResult(ip: ipAddress);
    }

    try {
      final result = await _database!.search(ipAddress);
      if (result == null) {
        LogService().log('GeoIpService: No result for IP: $ipAddress');
        return GeoIpResult(ip: ipAddress);
      }

      // DB-IP MMDB structure:
      // {
      //   "city": {"names": {"en": "City Name"}},
      //   "country": {"names": {"en": "Country Name"}, "iso_code": "XX"},
      //   "location": {"latitude": 0.0, "longitude": 0.0}
      // }
      final location = result['location'] as Map<String, dynamic>?;
      final city = result['city'] as Map<String, dynamic>?;
      final country = result['country'] as Map<String, dynamic>?;

      final latitude = location?['latitude'] as num?;
      final longitude = location?['longitude'] as num?;
      final cityNames = city?['names'] as Map<String, dynamic>?;
      final countryNames = country?['names'] as Map<String, dynamic>?;
      final countryCode = country?['iso_code'] as String?;

      final geoResult = GeoIpResult(
        ip: ipAddress,
        latitude: latitude?.toDouble(),
        longitude: longitude?.toDouble(),
        city: cityNames?['en'] as String?,
        country: countryNames?['en'] as String?,
        countryCode: countryCode,
      );

      LogService().log('GeoIpService: Found location for $ipAddress: $geoResult');
      return geoResult;
    } catch (e) {
      LogService().log('GeoIpService: Error looking up IP $ipAddress: $e');
      return GeoIpResult(ip: ipAddress);
    }
  }

  bool _isPrivateIP(String ip) => isPrivateIp(ip);

  /// Reset the service (for testing)
  void reset() {
    _database = null;
    _initialized = false;
    _initializing = false;
  }
}
