/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Shared Places API handlers for station servers.
 */

import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../../models/place.dart';
import '../../util/event_bus.dart';
import '../../util/place_parser.dart';
import '../common/file_tree_builder.dart';
import '../common/geometry_utils.dart';
import '../common/station_info.dart';

class PlaceHandler {
  final String dataDir;
  final StationInfo stationInfo;
  final void Function(String level, String message)? log;

  PlaceHandler({
    required this.dataDir,
    required this.stationInfo,
    this.log,
  });

  void _log(String level, String message) {
    log?.call(level, message);
  }

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
          final distance = GeometryUtils.calculateDistanceKm(lat, lon, placeLat, placeLon);
          return distance <= radiusKm;
        }).toList();
      }

      return {
        'success': true,
        'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'station': stationInfo.toJson(),
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

      final relativePath = p.relative(
        placePath,
        from: '$dataDir/devices/$callsign/places',
      );

      final photos = _listPhotos(placePath);
      final lastModified = await placeFile.lastModified();
      final fileTree = await FileTreeBuilder.build(placePath);

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

      final callsign = p.basename(deviceEntity.path);
      final placesDir = Directory('${deviceEntity.path}/places');
      if (!await placesDir.exists()) continue;

      await for (final entity in placesDir.list(recursive: true)) {
        if (entity is! File) continue;
        if (!entity.path.endsWith('/place.txt')) continue;

        final placeFolder = entity.parent;
        final folderName = p.basename(placeFolder.path);
        final relativePath = p.relative(placeFolder.path, from: placesDir.path);

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
      final name = p.basename(folder.path);
      if (name == folderName) {
        return folder.path;
      }
    }
    return null;
  }

  List<String> _listPhotos(String placePath) {
    final photos = <String>[];
    final extensions = ['.jpg', '.jpeg', '.png', '.gif', '.webp'];

    final imagesDir = Directory('$placePath/images');
    if (imagesDir.existsSync()) {
      for (final entity in imagesDir.listSync()) {
        if (entity is File) {
          final filename = p.basename(entity.path);
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
          final filename = p.basename(entity.path);
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

  // --- Place file upload/serve (moved from station files) ---

  /// Check if path matches place file upload/serve pattern.
  bool isFileUploadPath(String path) {
    return _parsePlaceFileRequest(path) != null;
  }

  /// Handle POST /{callsign}/api/places/files/{path} - upload place file
  Future<void> uploadFile(HttpRequest request) async {
    try {
      final pathValue = request.uri.path;
      final parsed = _parsePlaceFileRequest(pathValue);
      if (parsed == null) {
        request.response.statusCode = 400;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Invalid path format'}));
        return;
      }

      final callsign = parsed.callsign;
      final relativePath = _normalizePlaceRelativePath(parsed.relativePath);

      if (_isInvalidRelativePath(relativePath)) {
        request.response.statusCode = 400;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Invalid path'}));
        return;
      }

      final bytes = await request.fold<List<int>>(
        <int>[],
        (previous, element) => previous..addAll(element),
      );

      if (bytes.isEmpty) {
        request.response.statusCode = 400;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Empty file'}));
        return;
      }

      final placesRoot = p.join(dataDir, 'devices', callsign, 'places');
      final filePath = p.join(placesRoot, relativePath);
      final parentDir = Directory(p.dirname(filePath));
      if (!await parentDir.exists()) {
        await parentDir.create(recursive: true);
      }

      final file = File(filePath);
      await file.writeAsBytes(bytes, flush: true);

      // Fire PlaceCreatedEvent when place.txt is uploaded
      if (relativePath.endsWith('/place.txt') || relativePath == 'place.txt') {
        final parts = relativePath.split('/');
        final folderName = parts.length > 1 ? parts[parts.length - 2] : relativePath;
        EventBus().fire(PlaceCreatedEvent(
          placeId: folderName,
          author: callsign,
          name: folderName,
        ));
      }

      request.response.statusCode = 201;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'success': true,
        'path': '/$callsign/places/$relativePath',
        'size': bytes.length,
      }));
    } catch (e) {
      _log('ERROR', 'Error handling place file upload: $e');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Internal server error', 'message': e.toString()}));
    }
  }

  /// Handle GET /{callsign}/api/places/files/{path} - serve place file
  Future<void> serveFile(HttpRequest request) async {
    try {
      final pathValue = request.uri.path;
      final parsed = _parsePlaceFileRequest(pathValue);
      if (parsed == null) {
        request.response.statusCode = 400;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Invalid path format'}));
        return;
      }

      final callsign = parsed.callsign;
      final relativePath = parsed.relativePath;

      if (_isInvalidRelativePath(relativePath)) {
        request.response.statusCode = 400;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Invalid path'}));
        return;
      }

      final placesRoot = p.join(dataDir, 'devices', callsign, 'places');
      final filePath = p.join(placesRoot, relativePath);
      final file = File(filePath);

      if (!await file.exists()) {
        request.response.statusCode = 404;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'File not found'}));
        return;
      }

      final ext = p.extension(filePath).toLowerCase();
      String contentType = 'application/octet-stream';
      if (ext == '.jpg' || ext == '.jpeg') {
        contentType = 'image/jpeg';
      } else if (ext == '.png') {
        contentType = 'image/png';
      } else if (ext == '.gif') {
        contentType = 'image/gif';
      } else if (ext == '.webp') {
        contentType = 'image/webp';
      } else if (ext == '.txt') {
        contentType = 'text/plain';
      }

      final bytes = await file.readAsBytes();
      request.response.headers.set('Content-Type', contentType);
      request.response.headers.set('Content-Length', bytes.length.toString());
      request.response.add(bytes);
    } catch (e) {
      _log('ERROR', 'Error serving place file: $e');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Internal server error', 'message': e.toString()}));
    }
  }

  ({String callsign, String relativePath})? _parsePlaceFileRequest(String path) {
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.length < 5) return null;
    if (parts[1] != 'api' || parts[2] != 'places') return null;

    final callsign = parts[0].toUpperCase();

    if (parts[3] == 'files') {
      if (parts.length < 5) return null;
      return (callsign: callsign, relativePath: parts.sublist(4).join('/'));
    }

    final filesIndex = parts.indexOf('files');
    if (filesIndex <= 3 || filesIndex == parts.length - 1) return null;

    final placePath = parts.sublist(3, filesIndex).join('/');
    final filePath = parts.sublist(filesIndex + 1).join('/');
    if (placePath.isEmpty || filePath.isEmpty) return null;

    return (callsign: callsign, relativePath: '$placePath/$filePath');
  }

  String _normalizePlaceRelativePath(String relativePath) {
    final segments = relativePath
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .toList();
    if (segments.length > 1 && segments.first == 'places') {
      return segments.sublist(1).join('/');
    }
    return relativePath;
  }

  bool _isInvalidRelativePath(String relativePath) {
    if (relativePath.isEmpty) return true;
    if (relativePath.contains('\\')) return true;
    final normalized = p.normalize(relativePath);
    if (p.isAbsolute(normalized)) return true;
    final segments = normalized.split(p.separator);
    return segments.any((segment) => segment == '..');
  }
}
