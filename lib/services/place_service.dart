/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import '../models/place.dart';
import '../util/place_parser.dart';
import 'location_service.dart';
import 'log_service.dart';

/// Service for managing places collection
class PlaceService {
  static final PlaceService _instance = PlaceService._internal();
  factory PlaceService() => _instance;
  PlaceService._internal();

  String? _collectionPath;

  /// Initialize the service with a collection path
  Future<void> initializeCollection(String collectionPath) async {
    _collectionPath = collectionPath;
    final placesDir = Directory('$collectionPath/places');
    if (!await placesDir.exists()) {
      await placesDir.create(recursive: true);
    }

    // Initialize LocationService for city lookup
    final locationService = LocationService();
    if (!locationService.isLoaded) {
      await locationService.init();
    }
  }

  /// Load all places from the collection
  Future<List<Place>> loadAllPlaces() async {
    if (_collectionPath == null) {
      throw Exception('PlaceService not initialized');
    }

    final places = <Place>[];
    final placesDir = Directory('$_collectionPath/places');

    if (!await placesDir.exists()) {
      return places;
    }

    // Recursively find all place.txt files
    await _scanDirectoryForPlaces(placesDir, places);

    return places;
  }

  /// Recursively scan a directory for place.txt files
  Future<void> _scanDirectoryForPlaces(Directory dir, List<Place> places) async {
    final entities = await dir.list().toList();
    for (final entity in entities) {
      if (entity is Directory) {
        // Check if this directory contains a place.txt file
        final placeFile = File('${entity.path}/place.txt');
        if (await placeFile.exists()) {
          // This is a place folder
          final place = await _loadPlaceFromFolder(entity.path, '');
          if (place != null) {
            places.add(place);
          }
        } else {
          // Recursively scan subdirectories
          await _scanDirectoryForPlaces(entity, places);
        }
      }
    }
  }

  /// Load a single place from its folder
  Future<Place?> _loadPlaceFromFolder(String folderPath, String regionName) async {
    final placeFile = File('$folderPath/place.txt');

    if (!await placeFile.exists()) {
      return null;
    }

    try {
      final content = await placeFile.readAsString();
      return PlaceParser.parsePlaceContent(
        content: content,
        filePath: placeFile.path,
        folderPath: folderPath,
        regionName: regionName,
        log: (message) => LogService().log(message),
      );
    } catch (e) {
      LogService().log('Error loading place from $folderPath: $e');
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
    if (place.admins.isNotEmpty) {
      buffer.writeln('ADMINS: ${place.admins.join(', ')}');
    }
    if (place.moderators.isNotEmpty) {
      buffer.writeln('MODERATORS: ${place.moderators.join(', ')}');
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
    if (_collectionPath == null) {
      return 'PlaceService not initialized';
    }

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
      final fullPath = '$_collectionPath/places/$locationPath';

      // Create location folder structure if it doesn't exist
      final locationDir = Directory(fullPath);
      if (!await locationDir.exists()) {
        await locationDir.create(recursive: true);
      }

      // Create place folder
      final placeFolderName = place.placeFolderName;
      final placeFolderPath = '$fullPath/$placeFolderName';
      final placeDir = Directory(placeFolderPath);

      if (!await placeDir.exists()) {
        await placeDir.create(recursive: true);
      }

      // Write place.txt file
      final placeFile = File('$placeFolderPath/place.txt');
      final content = formatPlaceFile(place);
      await placeFile.writeAsString(content);

      return null; // Success
    } catch (e) {
      return 'Error saving place: $e';
    }
  }

  /// Get the folder path for a place (used for saving photos)
  Future<String?> getPlaceFolderPath(Place place) async {
    if (_collectionPath == null) {
      return null;
    }

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
      final fullPath = '$_collectionPath/places/$locationPath';
      final placeFolderName = place.placeFolderName;
      return '$fullPath/$placeFolderName';
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
      final placeDir = Directory(place.folderPath!);
      if (await placeDir.exists()) {
        await placeDir.delete(recursive: true);
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
}
