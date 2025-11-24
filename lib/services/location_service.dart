/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'dart:math';
import 'package:flutter/services.dart' show rootBundle;

/// Model for a city entry from the worldcities database
class CityEntry {
  final String city;
  final String cityAscii;
  final double lat;
  final double lng;
  final String country;
  final String iso2;
  final String iso3;
  final String adminName;
  final String capital;
  final String population;
  final String id;

  CityEntry({
    required this.city,
    required this.cityAscii,
    required this.lat,
    required this.lng,
    required this.country,
    required this.iso2,
    required this.iso3,
    required this.adminName,
    required this.capital,
    required this.population,
    required this.id,
  });

  factory CityEntry.fromCsvRow(List<String> fields) {
    return CityEntry(
      city: fields[0],
      cityAscii: fields[1],
      lat: double.parse(fields[2]),
      lng: double.parse(fields[3]),
      country: fields[4],
      iso2: fields[5],
      iso3: fields[6],
      adminName: fields[7],
      capital: fields[8],
      population: fields[9],
      id: fields[10],
    );
  }
}

/// Result of nearest city lookup
class NearestCityResult {
  final String country;
  final String adminName;
  final String city;
  final double distance; // in kilometers

  NearestCityResult({
    required this.country,
    required this.adminName,
    required this.city,
    required this.distance,
  });

  /// Get folder path for this location (Country/Region/City or Country/City)
  String get folderPath {
    final parts = <String>[];

    // Level 1: Country (sanitized)
    parts.add(_sanitize(country));

    // Check if city and admin region are the same (case-insensitive ASCII comparison)
    if (city.toLowerCase() == adminName.toLowerCase()) {
      // Only 2 levels: Country/City
      parts.add(_sanitize(city));
    } else {
      // 3 levels: Country/Region/City
      parts.add(_sanitize(adminName));
      parts.add(_sanitize(city));
    }

    return parts.join('/');
  }

  /// Sanitize a name for use as folder name
  String _sanitize(String name) {
    String sanitized = name;

    // Replace spaces and special chars with hyphens
    sanitized = sanitized.replaceAll(RegExp(r'[^\w\s-]'), '');
    sanitized = sanitized.replaceAll(RegExp(r'[\s_]+'), '-');

    // Collapse multiple hyphens
    sanitized = sanitized.replaceAll(RegExp(r'-+'), '-');

    // Remove leading/trailing hyphens
    sanitized = sanitized.replaceAll(RegExp(r'^-+|-+$'), '');

    // Limit length
    if (sanitized.length > 50) {
      sanitized = sanitized.substring(0, 50);
    }

    return sanitized;
  }
}

/// Service for location-based operations using the worldcities database
class LocationService {
  static final LocationService _instance = LocationService._internal();
  factory LocationService() => _instance;
  LocationService._internal();

  List<CityEntry>? _cities;
  bool _isLoaded = false;

  /// Initialize the service by loading the city database
  Future<void> init() async {
    if (_isLoaded) return;

    try {
      stderr.writeln('Loading worldcities database...');

      // Load CSV from assets
      final csvString = await rootBundle.loadString('assets/worldcities.csv');

      // Parse CSV
      final lines = const LineSplitter().convert(csvString);
      _cities = [];

      // Skip header line
      for (var i = 1; i < lines.length; i++) {
        final line = lines[i];
        if (line.trim().isEmpty) continue;

        try {
          // Parse CSV line (handling quoted fields)
          final fields = _parseCsvLine(line);
          if (fields.length >= 11) {
            _cities!.add(CityEntry.fromCsvRow(fields));
          }
        } catch (e) {
          // Skip malformed lines
          continue;
        }
      }

      _isLoaded = true;
      stderr.writeln('Loaded ${_cities!.length} cities from database');
    } catch (e, stackTrace) {
      stderr.writeln('Error loading worldcities database: $e');
      stderr.writeln(stackTrace);
      _cities = [];
      _isLoaded = false;
    }
  }

  /// Parse a CSV line handling quoted fields
  List<String> _parseCsvLine(String line) {
    final fields = <String>[];
    var current = StringBuffer();
    var inQuotes = false;

    for (var i = 0; i < line.length; i++) {
      final char = line[i];

      if (char == '"') {
        if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
          // Escaped quote
          current.write('"');
          i++;
        } else {
          // Toggle quotes
          inQuotes = !inQuotes;
        }
      } else if (char == ',' && !inQuotes) {
        // Field separator
        fields.add(current.toString());
        current = StringBuffer();
      } else {
        current.write(char);
      }
    }

    // Add last field
    fields.add(current.toString());

    return fields;
  }

  /// Find the nearest city to given coordinates
  Future<NearestCityResult?> findNearestCity(double lat, double lng) async {
    if (!_isLoaded) {
      await init();
    }

    if (_cities == null || _cities!.isEmpty) {
      stderr.writeln('City database not loaded');
      return null;
    }

    CityEntry? nearest;
    double minDistance = double.infinity;

    for (final city in _cities!) {
      final distance = _calculateDistance(lat, lng, city.lat, city.lng);

      if (distance < minDistance) {
        minDistance = distance;
        nearest = city;
      }
    }

    if (nearest == null) {
      return null;
    }

    return NearestCityResult(
      country: nearest.country,
      adminName: nearest.adminName,
      city: nearest.cityAscii,
      distance: minDistance,
    );
  }

  /// Calculate distance between two coordinates using Haversine formula
  /// Returns distance in kilometers
  double _calculateDistance(double lat1, double lng1, double lat2, double lng2) {
    const earthRadius = 6371.0; // Earth radius in kilometers

    final dLat = _degreesToRadians(lat2 - lat1);
    final dLng = _degreesToRadians(lng2 - lng1);

    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_degreesToRadians(lat1)) *
            cos(_degreesToRadians(lat2)) *
            sin(dLng / 2) *
            sin(dLng / 2);

    final c = 2 * atan2(sqrt(a), sqrt(1 - a));

    return earthRadius * c;
  }

  /// Convert degrees to radians
  double _degreesToRadians(double degrees) {
    return degrees * pi / 180;
  }

  /// Check if the service is loaded
  bool get isLoaded => _isLoaded;

  /// Get total number of cities in database
  int get cityCount => _cities?.length ?? 0;
}
