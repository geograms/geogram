/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Shared Places API handlers for station servers.
 */

import 'dart:io';
import 'dart:math' as math;
import 'package:path/path.dart' as path;
import '../models/place.dart';
import '../util/place_parser.dart';

class StationPlaceApi {
  final String dataDir;
  final String? stationName;
  final String? stationCallsign;
  final String? stationNpub;
  final void Function(String level, String message)? log;

  StationPlaceApi({
    required this.dataDir,
    this.stationName,
    this.stationCallsign,
    this.stationNpub,
    this.log,
  });

  void _log(String level, String message) {
    log?.call(level, message);
  }

  Map<String, dynamic> _stationInfoJson() => {
    'name': stationName ?? 'Geogram Station',
    'callsign': stationCallsign,
    'npub': stationNpub,
  };

  /// GET /api/places - list places with optional filtering
  Future<Map<String, dynamic>> getPlaces({
    int? sinceTimestamp,
    double? lat,
    double? lon,
    double? radiusKm,
  }) async {
    try {
      var places = await _loadAllPlaces();

      if (sinceTimestamp != null) {
        final sinceDate = DateTime.fromMillisecondsSinceEpoch(sinceTimestamp * 1000);
        places = places.where((place) {
          final lastModifiedStr = place['last_modified'] as String?;
          if (lastModifiedStr == null || lastModifiedStr.isEmpty) {
            return true;
          }
          try {
            return DateTime.parse(lastModifiedStr).isAfter(sinceDate);
          } catch (_) {
            return true;
          }
        }).toList();
      }

      if (lat != null && lon != null && radiusKm != null && radiusKm > 0) {
        places = places.where((place) {
          final placeLat = place['latitude'] as double?;
          final placeLon = place['longitude'] as double?;
          if (placeLat == null || placeLon == null) return false;
          final distance = _calculateDistanceKm(lat, lon, placeLat, placeLon);
          return distance <= radiusKm;
        }).toList();
      }

      return {
        'success': true,
        'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'station': _stationInfoJson(),
        'filters': {
          if (sinceTimestamp != null) 'since': sinceTimestamp,
          if (lat != null) 'lat': lat,
          if (lon != null) 'lon': lon,
          if (radiusKm != null) 'radius_km': radiusKm,
        },
        'count': places.length,
        'places': places,
      };
    } catch (e) {
      _log('ERROR', 'Error in places API: $e');
      return {
        'success': false,
        'error': 'Internal server error',
        'message': e.toString(),
      };
    }
  }

  /// GET /api/places/{callsign}/{folderName} - place details
  Future<Map<String, dynamic>> getPlaceDetails(String callsign, String folderName) async {
    try {
      final placePath = await _findPlacePath(callsign, folderName);
      if (placePath == null) {
        return {'error': 'Place not found', 'http_status': 404};
      }

      final placeFile = File('$placePath/place.txt');
      if (!await placeFile.exists()) {
        return {'error': 'Place file not found', 'http_status': 404};
      }

      final content = await placeFile.readAsString();
      final place = PlaceParser.parsePlaceContent(
        content: content,
        filePath: placeFile.path,
        folderPath: placePath,
        log: (message) => _log('WARN', message),
      );

      if (place == null) {
        return {'error': 'Invalid place format', 'http_status': 500};
      }

      final relativePath = path.relative(
        placePath,
        from: '$dataDir/devices/$callsign/places',
      );

      final photos = _listPhotos(placePath);
      final lastModified = await placeFile.lastModified();
      final fileTree = await _buildFileTree(placePath);

      final placeJson = _placeToApiJson(
        place,
        callsign: callsign,
        folderName: folderName,
        relativePath: relativePath,
        lastModified: lastModified.toUtc().toIso8601String(),
        photoCount: photos.length,
      );

      return {
        ...placeJson,
        'photos': photos,
        'files': fileTree,
        'place_content': content,
      };
    } catch (e) {
      _log('ERROR', 'Error in place details: $e');
      return {
        'error': 'Internal server error',
        'message': e.toString(),
        'http_status': 500,
      };
    }
  }

  /// Find a place folder path by callsign and folder name.
  /// Returns null if not found.
  Future<String?> findPlacePath(String callsign, String folderName) {
    return _findPlacePath(callsign, folderName);
  }

  Future<List<Map<String, dynamic>>> _loadAllPlaces() async {
    final places = <Map<String, dynamic>>[];
    final devicesDir = Directory('$dataDir/devices');

    if (!await devicesDir.exists()) {
      return places;
    }

    await for (final deviceEntity in devicesDir.list()) {
      if (deviceEntity is! Directory) continue;

      final callsign = path.basename(deviceEntity.path);
      final placesDir = Directory('${deviceEntity.path}/places');
      if (!await placesDir.exists()) continue;

      await for (final entity in placesDir.list(recursive: true)) {
        if (entity is! File) continue;
        if (!entity.path.endsWith('/place.txt')) continue;

        final placeFolder = entity.parent;
        final folderName = path.basename(placeFolder.path);
        final relativePath = path.relative(placeFolder.path, from: placesDir.path);

        try {
          final content = await entity.readAsString();
          final place = PlaceParser.parsePlaceContent(
            content: content,
            filePath: entity.path,
            folderPath: placeFolder.path,
            log: (message) => _log('WARN', message),
          );

          if (place == null) {
            continue;
          }

          final lastModified = await entity.lastModified();
          final photos = _listPhotos(placeFolder.path);

          final placeJson = _placeToApiJson(
            place,
            callsign: callsign,
            folderName: folderName,
            relativePath: relativePath,
            lastModified: lastModified.toUtc().toIso8601String(),
            photoCount: photos.length,
          );

          places.add(placeJson);
        } catch (e) {
          _log('WARN', 'Failed to parse place: ${entity.path}');
        }
      }
    }

    places.sort((a, b) => (b['created'] as String).compareTo(a['created'] as String));
    return places;
  }

  Future<String?> _findPlacePath(String callsign, String folderName) async {
    final placesRoot = Directory('$dataDir/devices/$callsign/places');
    if (!await placesRoot.exists()) return null;

    await for (final entity in placesRoot.list(recursive: true)) {
      if (entity is! File) continue;
      if (!entity.path.endsWith('/place.txt')) continue;

      final folder = entity.parent;
      final name = path.basename(folder.path);
      if (name == folderName) {
        return folder.path;
      }
    }
    return null;
  }

  /// Build a file tree structure for a place folder.
  /// Returns a nested map with file/directory names as keys.
  /// Files have {size: int, mtime: int} values.
  /// Directories end with '/' and contain nested file maps.
  Future<Map<String, dynamic>> _buildFileTree(String placePath) async {
    final tree = <String, dynamic>{};
    final placeDir = Directory(placePath);

    if (!await placeDir.exists()) return tree;

    await for (final entity in placeDir.list(recursive: false)) {
      final name = entity.path.split('/').last;

      if (entity is File) {
        final stat = await entity.stat();
        tree[name] = {
          'size': stat.size,
          'mtime': stat.modified.millisecondsSinceEpoch ~/ 1000,
        };
      } else if (entity is Directory) {
        tree['$name/'] = await _buildFileTree(entity.path);
      }
    }

    return tree;
  }

  List<String> _listPhotos(String placePath) {
    final photos = <String>[];
    final extensions = ['.jpg', '.jpeg', '.png', '.gif', '.webp'];

    final imagesDir = Directory('$placePath/images');
    if (imagesDir.existsSync()) {
      for (final entity in imagesDir.listSync()) {
        if (entity is File) {
          final filename = path.basename(entity.path);
          final ext = filename.toLowerCase();
          if (extensions.any((e) => ext.endsWith(e))) {
            photos.add('images/$filename');
          }
        }
      }
    }

    final rootDir = Directory(placePath);
    if (rootDir.existsSync()) {
      for (final entity in rootDir.listSync()) {
        if (entity is File) {
          final filename = path.basename(entity.path);
          if (filename == 'place.txt') continue;
          final ext = filename.toLowerCase();
          if (extensions.any((e) => ext.endsWith(e))) {
            photos.add(filename);
          }
        }
      }
    }

    return photos;
  }

  Map<String, dynamic> _placeToApiJson(
    Place place, {
    required String callsign,
    required String folderName,
    required String relativePath,
    required String lastModified,
    required int photoCount,
  }) {
    final json = place.toJson();
    json.remove('filePath');
    json.remove('folderPath');
    json.remove('regionPath');

    final description = json['description'] as String?;
    if (description != null && description.length > 300) {
      json['description'] = '${description.substring(0, 300)}...';
    }

    json['callsign'] = callsign;
    json['folderName'] = folderName;
    json['relativePath'] = relativePath;
    json['last_modified'] = lastModified;
    json['photoCount'] = photoCount;

    return json;
  }

  double _calculateDistanceKm(double lat1, double lon1, double lat2, double lon2) {
    const earthRadiusKm = 6371.0;
    final dLat = _toRadians(lat2 - lat1);
    final dLon = _toRadians(lon2 - lon1);

    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_toRadians(lat1)) * math.cos(_toRadians(lat2)) *
            math.sin(dLon / 2) * math.sin(dLon / 2);

    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadiusKm * c;
  }

  double _toRadians(double degrees) => degrees * math.pi / 180.0;
}
