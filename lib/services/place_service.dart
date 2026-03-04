/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'dart:math';
import '../models/place.dart';
import '../util/place_parser.dart';
import 'location_service.dart';
import '../util/event_bus.dart';
import 'log_service.dart';
import 'profile_storage.dart';
import 'storage_config.dart';

// ============================================================================
// Place Proximity Lookup - Reusable classes and methods
// ============================================================================

/// Cached place entry for fast proximity lookups
class CachedPlaceEntry {
  final String name;
  final double lat;
  final double lon;
  final String folderPath;

  const CachedPlaceEntry({
    required this.name,
    required this.lat,
    required this.lon,
    required this.folderPath,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'lat': lat,
    'lon': lon,
    'folderPath': folderPath,
  };

  factory CachedPlaceEntry.fromJson(Map<String, dynamic> json) => CachedPlaceEntry(
    name: json['name'] as String,
    lat: (json['lat'] as num).toDouble(),
    lon: (json['lon'] as num).toDouble(),
    folderPath: json['folderPath'] as String,
  );
}

/// Place with distance from a reference point
class PlaceWithDistance {
  final String name;
  final double lat;
  final double lon;
  final String folderPath;
  final double distanceMeters;

  const PlaceWithDistance({
    required this.name,
    required this.lat,
    required this.lon,
    required this.folderPath,
    required this.distanceMeters,
  });
}

/// Service for managing places collection
class PlaceService {
  static final PlaceService _instance = PlaceService._internal();
  factory PlaceService() => _instance;
  PlaceService._internal();

  /// Profile storage for file operations (encrypted or filesystem)
  /// IMPORTANT: This MUST be set before using the service.
  /// All file operations go through this abstraction.
  late ProfileStorage _storage;

  /// Whether using encrypted storage
  bool get useEncryptedStorage => _storage.isEncrypted;

  /// Set the profile storage for file operations
  /// MUST be called before initializeApp
  void setStorage(ProfileStorage storage) {
    _storage = storage;
  }

  /// Initialize the service with a collection path
  Future<void> initializeApp(String appPath) async {
    // Create places directory using storage abstraction
    if (!await _storage.exists('places')) {
      await _storage.createDirectory('places');
    }

    // Initialize LocationService for city lookup
    final locationService = LocationService();
    if (!locationService.isLoaded) {
      await locationService.init();
    }
  }

  /// Load all places from the collection
  Future<List<Place>> loadAllPlaces() async {
    final places = <Place>[];

    if (!await _storage.exists('places')) {
      return places;
    }

    await _scanDirectoryForPlaces('places', places);
    return places;
  }

  /// Recursively scan a directory for place.txt files
  Future<void> _scanDirectoryForPlaces(String relativePath, List<Place> places) async {
    final entries = await _storage.listDirectory(relativePath);
    for (final entry in entries) {
      if (entry.isDirectory) {
        // Check if this directory contains a place.txt file
        final placeFilePath = '${entry.path}/place.txt';
        if (await _storage.exists(placeFilePath)) {
          // This is a place folder
          final place = await _loadPlaceFromFolder(entry.path, '');
          if (place != null) {
            places.add(place);
          }
        } else {
          // Recursively scan subdirectories
          await _scanDirectoryForPlaces(entry.path, places);
        }
      }
    }
  }

  /// Load a single place from its folder
  Future<Place?> _loadPlaceFromFolder(String relativeFolderPath, String regionName) async {
    final placeFilePath = '$relativeFolderPath/place.txt';
    final content = await _storage.readString(placeFilePath);

    if (content == null) {
      return null;
    }

    try {
      return PlaceParser.parsePlaceContent(
        content: content,
        filePath: placeFilePath,
        folderPath: relativeFolderPath,
        regionName: regionName,
        log: (message) => LogService().log(message),
      );
    } catch (e) {
      LogService().log('Error loading place from $relativeFolderPath: $e');
      return null;
    }
  }

  /// Parse place content into a Place model.
  /// Useful for server-side APIs that read place.txt directly.
  Place? parsePlaceContent({
    required String content,
    required String filePath,
    required String folderPath,
    String regionName = '',
  }) {
    return PlaceParser.parsePlaceContent(
      content: content,
      filePath: filePath,
      folderPath: folderPath,
      regionName: regionName,
      log: (message) => LogService().log(message),
    );
  }

  /// Format a place as place.txt content
  String formatPlaceFile(Place place) {
    final buffer = StringBuffer();

    // Title(s)
    if (place.names.isNotEmpty) {
      // Multilingual
      for (final entry in place.names.entries) {
        buffer.writeln('# PLACE_${entry.key}: ${entry.value}');
      }
    } else {
      // Single language
      buffer.writeln('# PLACE: ${place.name}');
    }

    buffer.writeln();

    // Required fields
    buffer.writeln('CREATED: ${place.created}');
    buffer.writeln('AUTHOR: ${place.author}');
    buffer.writeln('COORDINATES: ${place.latitude},${place.longitude}');
    buffer.writeln('RADIUS: ${place.radius}');

    // Optional fields
    if (place.address != null) {
      buffer.writeln('ADDRESS: ${place.address}');
    }
    if (place.type != null) {
      buffer.writeln('TYPE: ${place.type}');
    }
    if (place.founded != null) {
      buffer.writeln('FOUNDED: ${place.founded}');
    }
    if (place.hours != null) {
      buffer.writeln('HOURS: ${place.hours}');
    }
    if (place.profileImage != null && place.profileImage!.isNotEmpty) {
      buffer.writeln('PROFILE_PIC: ${place.profileImage}');
    }
    if (place.admins.isNotEmpty) {
      buffer.writeln('ADMINS: ${place.admins.join(', ')}');
    }
    if (place.moderators.isNotEmpty) {
      buffer.writeln('MODERATORS: ${place.moderators.join(', ')}');
    }

    // Visibility
    buffer.writeln('VISIBILITY: ${place.visibility}');
    if (place.visibility == 'restricted' && place.allowedGroups.isNotEmpty) {
      buffer.writeln('ALLOWED_GROUPS: ${place.allowedGroups.join(', ')}');
    }

    buffer.writeln();

    // Description
    if (place.descriptions.isNotEmpty) {
      // Multilingual
      for (final entry in place.descriptions.entries) {
        buffer.writeln('[${entry.key}]');
        buffer.writeln(entry.value);
        buffer.writeln();
      }
    } else if (place.description.isNotEmpty) {
      // Single language
      buffer.writeln(place.description);
      buffer.writeln();
    }

    // History
    if (place.histories.isNotEmpty) {
      for (final entry in place.histories.entries) {
        buffer.writeln('HISTORY_${entry.key}:');
        buffer.writeln(entry.value);
        buffer.writeln();
      }
    } else if (place.history != null && place.history!.isNotEmpty) {
      buffer.writeln('HISTORY:');
      buffer.writeln(place.history);
      buffer.writeln();
    }

    // NOSTR metadata
    if (place.metadataNpub != null) {
      buffer.writeln('--> npub: ${place.metadataNpub}');
    }
    if (place.signature != null) {
      buffer.writeln('--> signature: ${place.signature}');
    }

    return buffer.toString();
  }

  /// Save a place (create or update)
  Future<String?> savePlace(Place place) async {
    try {
      // Find nearest city using LocationService
      final locationService = LocationService();
      final nearestCity = await locationService.findNearestCity(
        place.latitude,
        place.longitude,
      );

      if (nearestCity == null) {
        return 'Could not determine location for place';
      }

      // Build human-readable path: Country/Region/City
      final locationPath = nearestCity.folderPath;
      final placeFolderName = place.placeFolderName;
      final relativeFolderPath = 'places/$locationPath/$placeFolderName';
      final placeFilePath = '$relativeFolderPath/place.txt';
      final content = formatPlaceFile(place);

      // Create directory structure if it doesn't exist
      if (!await _storage.exists(relativeFolderPath)) {
        await _storage.createDirectory(relativeFolderPath);
      }

      // Write place.txt file
      await _storage.writeString(placeFilePath, content);

      // Notify Now feed
      EventBus().fire(PlaceCreatedEvent(
        placeId: placeFolderName,
        author: place.author,
        name: place.name,
      ));

      return null; // Success
    } catch (e) {
      return 'Error saving place: $e';
    }
  }

  /// Get the folder path for a place (used for saving photos)
  /// Returns relative path
  Future<String?> getPlaceFolderPath(Place place) async {
    try {
      final locationService = LocationService();
      final nearestCity = await locationService.findNearestCity(
        place.latitude,
        place.longitude,
      );

      if (nearestCity == null) {
        return null;
      }

      final locationPath = nearestCity.folderPath;
      final placeFolderName = place.placeFolderName;
      return 'places/$locationPath/$placeFolderName';
    } catch (e) {
      LogService().log('Error getting place folder path: $e');
      return null;
    }
  }


  /// Delete a place
  Future<bool> deletePlace(Place place) async {
    if (place.folderPath == null) {
      return false;
    }

    try {
      // folderPath should be relative for storage abstraction
      if (await _storage.exists(place.folderPath!)) {
        await _storage.deleteDirectory(place.folderPath!, recursive: true);
        return true;
      }
      return false;
    } catch (e) {
      LogService().log('Error deleting place: $e');
      return false;
    }
  }

  /// Search places by name, type, or description
  List<Place> searchPlaces(List<Place> places, String query) {
    if (query.isEmpty) return places;

    final lowerQuery = query.toLowerCase();
    return places.where((place) {
      return place.name.toLowerCase().contains(lowerQuery) ||
             (place.type?.toLowerCase().contains(lowerQuery) ?? false) ||
             place.description.toLowerCase().contains(lowerQuery) ||
             (place.address?.toLowerCase().contains(lowerQuery) ?? false);
    }).toList();
  }

  /// Filter places by type
  List<Place> filterByType(List<Place> places, String? type) {
    if (type == null || type.isEmpty) return places;
    return places.where((place) => place.type == type).toList();
  }

  /// Get unique types from places
  Set<String> getTypes(List<Place> places) {
    return places
        .where((p) => p.type != null)
        .map((p) => p.type!)
        .toSet();
  }

  // ==========================================================================
  // Static methods for proximity lookup with disk caching
  // Note: These use direct filesystem for cross-profile cache (not per-profile)
  // ==========================================================================

  /// Cache file path: {baseDir}/places/cache.json
  static String get _cacheFilePath {
    final storageConfig = StorageConfig();
    return '${storageConfig.baseDir}/places/cache.json';
  }

  /// Find all places within a radius of a coordinate.
  /// Uses disk cache for fast lookups, updates cache if places changed.
  ///
  /// Usage:
  /// ```dart
  /// final nearbyPlaces = await PlaceService.findPlacesWithinRadius(
  ///   lat: 52.428919,
  ///   lon: 10.800239,
  ///   radiusMeters: 100,
  /// );
  /// ```
  static Future<List<PlaceWithDistance>> findPlacesWithinRadius({
    required double lat,
    required double lon,
    required double radiusMeters,
  }) async {
    LogService().log('PlaceService.findPlacesWithinRadius: Searching at ($lat, $lon) with radius ${radiusMeters}m');

    // Load or update cache
    final allPlaces = await _loadOrUpdateCache();
    LogService().log('PlaceService.findPlacesWithinRadius: Loaded ${allPlaces.length} places from cache');

    // Filter by distance
    final results = <PlaceWithDistance>[];
    for (final place in allPlaces) {
      final distance = _haversineDistance(lat, lon, place.lat, place.lon);
      if (distance <= radiusMeters) {
        results.add(PlaceWithDistance(
          name: place.name,
          lat: place.lat,
          lon: place.lon,
          folderPath: place.folderPath,
          distanceMeters: distance,
        ));
        LogService().log('PlaceService.findPlacesWithinRadius: "${place.name}" is ${distance.toStringAsFixed(0)}m away (within range)');
      }
    }

    LogService().log('PlaceService.findPlacesWithinRadius: Found ${results.length} places within ${radiusMeters}m');
    return results;
  }

  /// Load cache from disk, or scan and create if doesn't exist
  static Future<List<CachedPlaceEntry>> _loadOrUpdateCache() async {
    try {
      final storageConfig = StorageConfig();
      if (!storageConfig.isInitialized) {
        LogService().log('PlaceService: StorageConfig not initialized');
        return [];
      }

      // Ensure places directory exists
      final placesDir = Directory('${storageConfig.baseDir}/places');
      if (!await placesDir.exists()) {
        await placesDir.create(recursive: true);
      }

      final cacheFile = File(_cacheFilePath);
      List<CachedPlaceEntry> cachedPlaces = [];

      // Load existing cache if available
      if (await cacheFile.exists()) {
        try {
          final content = await cacheFile.readAsString();
          final json = jsonDecode(content) as Map<String, dynamic>;
          final entries = json['places'] as List<dynamic>? ?? [];
          cachedPlaces = entries
              .map((e) => CachedPlaceEntry.fromJson(e as Map<String, dynamic>))
              .toList();
          LogService().log('PlaceService: Loaded ${cachedPlaces.length} places from cache');
        } catch (e) {
          LogService().log('PlaceService: Cache corrupted, will rebuild: $e');
          cachedPlaces = [];
        }
      }

      // Scan disk for actual places
      final diskPlaces = await _scanAllPlaces();
      LogService().log('PlaceService: Scanned disk, found ${diskPlaces.length} places');

      // Check if cache needs update (compare folder paths)
      final cacheSet = cachedPlaces.map((p) => p.folderPath).toSet();
      final diskSet = diskPlaces.map((p) => p.folderPath).toSet();

      if (cacheSet.length != diskSet.length || !cacheSet.containsAll(diskSet)) {
        // Mismatch - update cache
        await _saveCache(diskPlaces);
        LogService().log('PlaceService: Updated cache (${diskPlaces.length} places)');
        return diskPlaces;
      }

      return cachedPlaces;
    } catch (e) {
      LogService().log('PlaceService: Cache error: $e');
      return [];
    }
  }

  /// Scan all device folders for places
  static Future<List<CachedPlaceEntry>> _scanAllPlaces() async {
    final results = <CachedPlaceEntry>[];

    try {
      final storageConfig = StorageConfig();
      final devicesDir = Directory(storageConfig.devicesDir);
      if (!await devicesDir.exists()) {
        LogService().log('PlaceService: Devices directory not found: ${storageConfig.devicesDir}');
        return results;
      }

      await for (final callsignEntity in devicesDir.list()) {
        if (callsignEntity is! Directory) continue;

        // Check both directory structures (places/places and places)
        for (final placesPath in [
          '${callsignEntity.path}/places/places',
          '${callsignEntity.path}/places',
        ]) {
          final placesDir = Directory(placesPath);
          if (await placesDir.exists()) {
            await _scanForPlacesRecursive(placesDir, results);
            break; // Found places folder, don't check other path
          }
        }
      }
    } catch (e) {
      LogService().log('PlaceService: Scan error: $e');
    }

    return results;
  }

  /// Recursively scan directory for place.txt files
  static Future<void> _scanForPlacesRecursive(Directory dir, List<CachedPlaceEntry> results) async {
    try {
      await for (final entity in dir.list()) {
        if (entity is Directory) {
          final placeFile = File('${entity.path}/place.txt');
          if (await placeFile.exists()) {
            final place = await _parsePlaceFileForCache(placeFile);
            if (place != null) results.add(place);
          } else {
            await _scanForPlacesRecursive(entity, results);
          }
        }
      }
    } catch (e) {
      // Skip inaccessible directories
    }
  }

  /// Parse a place.txt file for caching
  static Future<CachedPlaceEntry?> _parsePlaceFileForCache(File placeFile) async {
    try {
      final content = await placeFile.readAsString();
      String? name;
      double? lat, lon;

      for (final line in content.split('\n')) {
        if (line.startsWith('# PLACE:')) {
          name = line.substring('# PLACE:'.length).trim();
        } else if (line.startsWith('# PLACE_') && name == null) {
          final colonIdx = line.indexOf(':', 8);
          if (colonIdx > 0) name = line.substring(colonIdx + 1).trim();
        } else if (line.startsWith('COORDINATES:')) {
          final coords = line.substring('COORDINATES:'.length).trim().split(',');
          if (coords.length == 2) {
            lat = double.tryParse(coords[0].trim());
            lon = double.tryParse(coords[1].trim());
          }
        }
      }

      if (name != null && lat != null && lon != null) {
        return CachedPlaceEntry(
          name: name,
          lat: lat,
          lon: lon,
          folderPath: placeFile.parent.path,
        );
      }
    } catch (e) {
      // Skip unparseable files
    }
    return null;
  }

  /// Save cache to disk
  static Future<void> _saveCache(List<CachedPlaceEntry> places) async {
    try {
      final cacheFile = File(_cacheFilePath);
      final json = {
        'updated': DateTime.now().toIso8601String(),
        'places': places.map((p) => p.toJson()).toList(),
      };
      await cacheFile.writeAsString(jsonEncode(json));
    } catch (e) {
      LogService().log('PlaceService: Error saving cache: $e');
    }
  }

  /// Haversine distance calculation in meters
  static double _haversineDistance(double lat1, double lon1, double lat2, double lon2) {
    const earthRadius = 6371000.0;
    final dLat = (lat2 - lat1) * pi / 180;
    final dLon = (lon2 - lon1) * pi / 180;
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180) * cos(lat2 * pi / 180) *
        sin(dLon / 2) * sin(dLon / 2);
    return earthRadius * 2 * atan2(sqrt(a), sqrt(1 - a));
  }

  /// Force refresh the places cache
  static Future<void> refreshPlacesCache() async {
    final places = await _scanAllPlaces();
    await _saveCache(places);
    LogService().log('PlaceService: Force refreshed cache (${places.length} places)');
  }
}
