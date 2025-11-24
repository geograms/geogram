/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import '../models/place.dart';
import 'location_service.dart';

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
      return _parsePlaceFile(content, placeFile.path, folderPath, regionName);
    } catch (e) {
      print('Error loading place from $folderPath: $e');
      return null;
    }
  }

  /// Parse a place.txt file
  Place? _parsePlaceFile(String content, String filePath, String folderPath, String regionName) {
    final lines = content.split('\n');

    // Parse header
    String? name;
    final names = <String, String>{};
    String? created;
    String? author;
    double? latitude;
    double? longitude;
    int? radius;
    String? address;
    String? type;
    String? founded;
    String? hours;
    final admins = <String>[];
    final moderators = <String>[];
    String? metadataNpub;
    String? signature;

    // Parse description/history
    String description = '';
    final descriptions = <String, String>{};
    String? history;
    final histories = <String, String>{};

    bool inHeader = true;
    String? currentLang;
    final descriptionBuffer = StringBuffer();
    final historyBuffer = StringBuffer();
    bool inHistory = false;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final trimmed = line.trim();

      // Parse title line
      if (trimmed.startsWith('# PLACE:')) {
        name = trimmed.substring(8).trim();
      } else if (trimmed.startsWith('# PLACE_')) {
        final parts = trimmed.substring(2).split(':');
        if (parts.length == 2) {
          final langCode = parts[0].substring(6).trim(); // Extract language code
          names[langCode] = parts[1].trim();
          if (name == null) name = parts[1].trim();
        }
      }
      // Parse metadata fields
      else if (trimmed.startsWith('CREATED:')) {
        created = trimmed.substring(8).trim();
      } else if (trimmed.startsWith('AUTHOR:')) {
        author = trimmed.substring(7).trim();
      } else if (trimmed.startsWith('COORDINATES:')) {
        final coords = trimmed.substring(12).trim().split(',');
        if (coords.length == 2) {
          latitude = double.tryParse(coords[0].trim());
          longitude = double.tryParse(coords[1].trim());
        }
      } else if (trimmed.startsWith('RADIUS:')) {
        radius = int.tryParse(trimmed.substring(7).trim());
      } else if (trimmed.startsWith('ADDRESS:')) {
        address = trimmed.substring(8).trim();
      } else if (trimmed.startsWith('TYPE:')) {
        type = trimmed.substring(5).trim();
      } else if (trimmed.startsWith('FOUNDED:')) {
        founded = trimmed.substring(8).trim();
      } else if (trimmed.startsWith('HOURS:')) {
        hours = trimmed.substring(6).trim();
      } else if (trimmed.startsWith('ADMINS:')) {
        final adminList = trimmed.substring(7).trim().split(',');
        admins.addAll(adminList.map((a) => a.trim()).where((a) => a.isNotEmpty));
      } else if (trimmed.startsWith('MODERATORS:')) {
        final modList = trimmed.substring(11).trim().split(',');
        moderators.addAll(modList.map((m) => m.trim()).where((m) => m.isNotEmpty));
      }
      // Parse NOSTR metadata
      else if (trimmed.startsWith('--> npub:')) {
        metadataNpub = trimmed.substring(9).trim();
      } else if (trimmed.startsWith('--> signature:')) {
        signature = trimmed.substring(14).trim();
      }
      // Language sections
      else if (RegExp(r'^\[([A-Z]{2})\]$').hasMatch(trimmed)) {
        inHeader = false;
        currentLang = RegExp(r'^\[([A-Z]{2})\]$').firstMatch(trimmed)!.group(1);
        descriptionBuffer.clear();
      }
      // History sections
      else if (trimmed.startsWith('HISTORY:')) {
        inHeader = false;
        inHistory = true;
        historyBuffer.clear();
        final histText = trimmed.substring(8).trim();
        if (histText.isNotEmpty) {
          historyBuffer.writeln(histText);
        }
      } else if (RegExp(r'^HISTORY_([A-Z]{2}):').hasMatch(trimmed)) {
        inHeader = false;
        inHistory = true;
        final match = RegExp(r'^HISTORY_([A-Z]{2}):').firstMatch(trimmed);
        currentLang = match!.group(1);
        historyBuffer.clear();
        final histText = trimmed.substring(match.group(0)!.length).trim();
        if (histText.isNotEmpty) {
          historyBuffer.writeln(histText);
        }
      }
      // Content lines
      else if (!inHeader && trimmed.isNotEmpty && !trimmed.startsWith('-->')) {
        if (inHistory) {
          historyBuffer.writeln(line);
        } else {
          descriptionBuffer.writeln(line);
        }
      }
      // Empty line - save current section
      else if (trimmed.isEmpty && !inHeader) {
        if (currentLang != null) {
          if (inHistory) {
            histories[currentLang] = historyBuffer.toString().trim();
            historyBuffer.clear();
          } else {
            descriptions[currentLang] = descriptionBuffer.toString().trim();
            descriptionBuffer.clear();
          }
        } else if (inHistory) {
          history = historyBuffer.toString().trim();
          historyBuffer.clear();
        } else {
          description = descriptionBuffer.toString().trim();
          descriptionBuffer.clear();
        }
      }
      // Check if we've left the header
      else if (inHeader && trimmed.isEmpty && created != null) {
        inHeader = false;
      }
    }

    // Save any remaining content
    if (currentLang != null) {
      if (inHistory && historyBuffer.isNotEmpty) {
        histories[currentLang] = historyBuffer.toString().trim();
      } else if (descriptionBuffer.isNotEmpty) {
        descriptions[currentLang] = descriptionBuffer.toString().trim();
      }
    } else if (inHistory && historyBuffer.isNotEmpty) {
      history = historyBuffer.toString().trim();
    } else if (descriptionBuffer.isNotEmpty) {
      description = descriptionBuffer.toString().trim();
    }

    // Validate required fields
    if (name == null || created == null || author == null ||
        latitude == null || longitude == null || radius == null) {
      print('Missing required fields in $filePath');
      return null;
    }

    // Count photos (files in folder excluding place.txt and subfolders)
    var photoCount = 0;
    try {
      final folder = Directory(folderPath);
      final entities = folder.listSync();
      photoCount = entities.where((e) {
        if (e is! File) return false;
        final name = e.path.split('/').last;
        return name != 'place.txt' &&
               (name.endsWith('.jpg') || name.endsWith('.jpeg') ||
                name.endsWith('.png') || name.endsWith('.gif'));
      }).length;
    } catch (e) {
      // Ignore errors
    }

    return Place(
      name: name,
      names: names,
      created: created,
      author: author,
      latitude: latitude,
      longitude: longitude,
      radius: radius,
      address: address,
      type: type,
      founded: founded,
      hours: hours,
      description: description,
      descriptions: descriptions,
      history: history,
      histories: histories,
      admins: admins,
      moderators: moderators,
      metadataNpub: metadataNpub,
      signature: signature,
      filePath: filePath,
      folderPath: folderPath,
      regionPath: regionName,
      photoCount: photoCount,
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
      print('Error deleting place: $e');
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
