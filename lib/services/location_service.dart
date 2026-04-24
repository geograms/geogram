/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'dart:math';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

import 'websocket_service.dart';

/// Result of IP-based geolocation
class GeoIpResult {
  final double latitude;
  final double longitude;
  final String? city;
  final String? country;

  GeoIpResult({
    required this.latitude,
    required this.longitude,
    this.city,
    this.country,
  });

  String get locationName {
    if (city != null && country != null) {
      return '$city, $country';
    } else if (city != null) {
      return city!;
    } else if (country != null) {
      return country!;
    }
    return 'Unknown';
  }
}

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

/// Jurisdiction information from location detection.
/// Used for legal documents and contracts.
class JurisdictionInfo {
  final String country;
  final String? region;
  final String? city;
  final String? countryCode;

  JurisdictionInfo({
    required this.country,
    this.region,
    this.city,
    this.countryCode,
  });

  /// Full jurisdiction string for legal documents.
  /// Returns "Region, Country" or just "Country" if no region.
  String get fullJurisdiction {
    if (region != null && region!.isNotEmpty) {
      return '$region, $country';
    }
    return country;
  }

  @override
  String toString() => fullJurisdiction;
}

/// Result of nearest city lookup
class NearestCityResult {
  final String country;
  final String iso2;
  final String iso3;
  final String adminName;
  final String city;
  final String capital;
  final double distance; // in kilometers

  NearestCityResult({
    required this.country,
    this.iso2 = '',
    this.iso3 = '',
    required this.adminName,
    required this.city,
    this.capital = '',
    required this.distance,
  });

  /// Get jurisdiction info for legal documents.
  JurisdictionInfo get jurisdiction => JurisdictionInfo(
        country: country,
        region: adminName,
        city: city,
        countryCode: iso2.isNotEmpty ? iso2 : null,
      );

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
      iso2: nearest.iso2,
      iso3: nearest.iso3,
      adminName: nearest.adminName,
      city: nearest.cityAscii,
      capital: nearest.capital,
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

  /// Find the N nearest cities to given coordinates
  Future<List<NearestCityResult>> findNearestCities(
    double lat,
    double lng, {
    int count = 5,
  }) async {
    if (!_isLoaded) {
      await init();
    }

    if (_cities == null || _cities!.isEmpty) {
      return [];
    }

    // Calculate distance for all cities
    final citiesWithDistance = <MapEntry<CityEntry, double>>[];
    for (final city in _cities!) {
      final distance = _calculateDistance(lat, lng, city.lat, city.lng);
      citiesWithDistance.add(MapEntry(city, distance));
    }

    // Sort by distance
    citiesWithDistance.sort((a, b) => a.value.compareTo(b.value));

    // Return top N
    return citiesWithDistance.take(count).map((entry) {
      return NearestCityResult(
        country: entry.key.country,
        iso2: entry.key.iso2,
        iso3: entry.key.iso3,
        adminName: entry.key.adminName,
        city: entry.key.cityAscii,
        capital: entry.key.capital,
        distance: entry.value,
      );
    }).toList();
  }

  /// Find a city by name (case-insensitive search)
  /// Returns the first match or null if not found
  Future<CityEntry?> findCityByName(String name) async {
    if (!_isLoaded) {
      await init();
    }

    if (_cities == null || _cities!.isEmpty) {
      return null;
    }

    final searchName = name.toLowerCase().trim();

    // Try exact match first (city or cityAscii)
    for (final city in _cities!) {
      if (city.city.toLowerCase() == searchName ||
          city.cityAscii.toLowerCase() == searchName) {
        return city;
      }
    }

    // Try partial match
    for (final city in _cities!) {
      if (city.city.toLowerCase().contains(searchName) ||
          city.cityAscii.toLowerCase().contains(searchName)) {
        return city;
      }
    }

    return null;
  }

  /// Search the full cities database and return up to [limit] matches
  /// ordered by how strongly they match [query], most relevant first.
  ///
  /// Ranking (higher beats lower):
  ///   1. Exact city-name match (case-insensitive, on either `city` or
  ///      `cityAscii`).
  ///   2. City name starts with the query.
  ///   3. City name contains the query anywhere.
  ///   4. Country / region contains the query.
  ///
  /// Within the same rank, cities with a larger population come first
  /// — users almost always mean the bigger city when typing a short
  /// prefix.
  ///
  /// An empty or whitespace-only query returns the top [limit] most
  /// populous cities, so the picker has something to show on open.
  Future<List<CityEntry>> searchCitiesByName(
    String query, {
    int limit = 50,
  }) async {
    if (!_isLoaded) {
      await init();
    }
    final cities = _cities;
    if (cities == null || cities.isEmpty) return const [];

    int popOf(CityEntry c) => int.tryParse(c.population) ?? 0;

    final trimmed = query.trim().toLowerCase();
    if (trimmed.isEmpty) {
      final sorted = [...cities]..sort((a, b) => popOf(b).compareTo(popOf(a)));
      return sorted.take(limit).toList();
    }

    final exact = <CityEntry>[];
    final prefix = <CityEntry>[];
    final contains = <CityEntry>[];
    final regional = <CityEntry>[];

    for (final c in cities) {
      final name = c.city.toLowerCase();
      final ascii = c.cityAscii.toLowerCase();
      if (name == trimmed || ascii == trimmed) {
        exact.add(c);
      } else if (name.startsWith(trimmed) || ascii.startsWith(trimmed)) {
        prefix.add(c);
      } else if (name.contains(trimmed) || ascii.contains(trimmed)) {
        contains.add(c);
      } else if (c.country.toLowerCase().contains(trimmed) ||
          c.adminName.toLowerCase().contains(trimmed)) {
        regional.add(c);
      }
      // Early exit if we've already found far more than we need across
      // all buckets (bounded pre-sort cost for a very common query).
      if (exact.length +
              prefix.length +
              contains.length +
              regional.length >
          limit * 20) {
        break;
      }
    }

    int byPop(CityEntry a, CityEntry b) => popOf(b).compareTo(popOf(a));
    exact.sort(byPop);
    prefix.sort(byPop);
    contains.sort(byPop);
    regional.sort(byPop);

    return [...exact, ...prefix, ...contains, ...regional].take(limit).toList();
  }

  /// Get the full CityEntry for the nearest city
  Future<CityEntry?> getNearestCityEntry(double lat, double lng) async {
    if (!_isLoaded) {
      await init();
    }

    if (_cities == null || _cities!.isEmpty) {
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

    return nearest;
  }

  /// Calculate distance between two coordinates (public access)
  /// Returns distance in kilometers
  double calculateDistance(double lat1, double lng1, double lat2, double lng2) {
    return _calculateDistance(lat1, lng1, lat2, lng2);
  }

  /// Check if the service is loaded
  bool get isLoaded => _isLoaded;

  /// Get total number of cities in database
  int get cityCount => _cities?.length ?? 0;

  /// Get list of all unique countries sorted alphabetically
  Future<List<String>> getAllCountries() async {
    if (!_isLoaded) {
      await init();
    }

    if (_cities == null || _cities!.isEmpty) {
      return [];
    }

    final countries = <String>{};
    for (final city in _cities!) {
      countries.add(city.country);
    }

    final sortedCountries = countries.toList()..sort();
    return sortedCountries;
  }

  /// Detect jurisdiction from coordinates using worldcities database.
  /// Returns jurisdiction info suitable for legal documents.
  Future<JurisdictionInfo?> detectJurisdiction(
    double latitude,
    double longitude,
  ) async {
    final result = await findNearestCity(latitude, longitude);
    if (result == null) return null;
    return result.jurisdiction;
  }

  /// Detect location via IP address using the connected station's GeoIP service
  /// This provides privacy-preserving IP geolocation without external API calls
  Future<GeoIpResult?> detectLocationViaIP() async {
    try {
      // Get the connected station URL
      final stationUrl = WebSocketService().connectedUrl;
      if (stationUrl == null) {
        stderr.writeln('LocationService: Not connected to station, cannot detect IP location');
        return null;
      }

      // Convert WebSocket URL to HTTP URL
      final httpUrl = stationUrl
          .replaceFirst('wss://', 'https://')
          .replaceFirst('ws://', 'http://');

      final response = await http.get(
        Uri.parse('$httpUrl/api/geoip'),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final lat = (data['latitude'] as num?)?.toDouble();
        final lon = (data['longitude'] as num?)?.toDouble();

        if (lat != null && lon != null) {
          return GeoIpResult(
            latitude: lat,
            longitude: lon,
            city: data['city'] as String?,
            country: data['country'] as String?,
          );
        }
      }
      return null;
    } catch (e) {
      stderr.writeln('LocationService: Failed to detect location via IP: $e');
      return null;
    }
  }
}
