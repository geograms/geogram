/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Service for fetching places from the preferred station and caching locally.
 */

import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

import '../models/place.dart';
import '../services/log_service.dart';
import '../services/place_service.dart';
import '../services/station_service.dart';
import '../services/storage_config.dart';

class StationPlaceEntry {
  final Place place;
  final String callsign;
  final String? relativePath;

  StationPlaceEntry({
    required this.place,
    required this.callsign,
    this.relativePath,
  });
}

class StationPlaceFetchResult {
  final bool success;
  final List<StationPlaceEntry> places;
  final int timestamp;
  final String? error;

  StationPlaceFetchResult({
    required this.success,
    required this.places,
    required this.timestamp,
    this.error,
  });
}

class StationPlaceService {
  static final StationPlaceService _instance = StationPlaceService._internal();
  factory StationPlaceService() => _instance;
  StationPlaceService._internal();

  final StationService _stationService = StationService();
  final PlaceService _placeService = PlaceService();
  int _lastFetchTimestamp = 0;

  int get lastFetchTimestamp => _lastFetchTimestamp;

  Future<StationPlaceFetchResult> fetchPlaces({
    double? lat,
    double? lon,
    double? radiusKm,
    bool useSince = false,
  }) async {
    try {
      final station = _stationService.getPreferredStation();
      if (station == null || station.url.isEmpty) {
        return StationPlaceFetchResult(
          success: false,
          places: [],
          timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          error: 'No station configured',
        );
      }

      var baseUrl = station.url;
      if (baseUrl.startsWith('wss://')) {
        baseUrl = baseUrl.replaceFirst('wss://', 'https://');
      } else if (baseUrl.startsWith('ws://')) {
        baseUrl = baseUrl.replaceFirst('ws://', 'http://');
      }

      final queryParams = <String, String>{};
      if (useSince && _lastFetchTimestamp > 0) {
        queryParams['since'] = _lastFetchTimestamp.toString();
      }
      if (lat != null) queryParams['lat'] = lat.toString();
      if (lon != null) queryParams['lon'] = lon.toString();
      if (radiusKm != null && radiusKm > 0) queryParams['radius'] = radiusKm.toString();

      final uri = Uri.parse('$baseUrl/api/places').replace(queryParameters: queryParams);
      final response = await http.get(
        uri,
        headers: {'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        return StationPlaceFetchResult(
          success: false,
          places: [],
          timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          error: 'HTTP ${response.statusCode}',
        );
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      if (json['success'] != true) {
        return StationPlaceFetchResult(
          success: false,
          places: [],
          timestamp: json['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
          error: json['error'] as String? ?? 'Unknown error',
        );
      }

      final placesJson = json['places'] as List<dynamic>? ?? [];
      final entries = <StationPlaceEntry>[];

      for (final placeData in placesJson) {
        if (placeData is! Map<String, dynamic>) continue;
        try {
          final callsign = (placeData['callsign'] as String? ?? '').toUpperCase();
          final folderName = placeData['folderName'] as String? ?? '';
          final relativePath = placeData['relativePath'] as String?;
          final place = Place.fromJson(placeData);

          final cachedPlace = await _cachePlace(
            place,
            callsign: callsign,
            folderName: folderName,
            relativePath: relativePath,
            baseUrl: baseUrl,
          );

          entries.add(StationPlaceEntry(
            place: cachedPlace,
            callsign: callsign,
            relativePath: relativePath,
          ));
        } catch (e) {
          LogService().log('StationPlaceService: Error parsing place: $e');
        }
      }

      _lastFetchTimestamp = json['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;

      return StationPlaceFetchResult(
        success: true,
        places: entries,
        timestamp: _lastFetchTimestamp,
      );
    } catch (e) {
      LogService().log('StationPlaceService: Error fetching places: $e');
      return StationPlaceFetchResult(
        success: false,
        places: [],
        timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        error: e.toString(),
      );
    }
  }

  Future<Place> _cachePlace(
    Place place, {
    required String callsign,
    required String folderName,
    required String? relativePath,
    required String baseUrl,
  }) async {
    if (kIsWeb || relativePath == null || relativePath.isEmpty || callsign.isEmpty) {
      return place;
    }

    try {
      final storageConfig = StorageConfig();
      if (!storageConfig.isInitialized) return place;

      final placeDetails = await _fetchPlaceDetails(
        baseUrl: baseUrl,
        callsign: callsign,
        folderName: folderName,
      );

      final placeContent = placeDetails?['place_content'] as String?;
      final photos = (placeDetails?['photos'] as List<dynamic>?)
          ?.cast<String>() ?? [];
      final serverFiles = placeDetails?['files'] as Map<String, dynamic>?;

      final resolvedRelativeRoot =
          (relativePath == null || relativePath.isEmpty) ? folderName : relativePath;
      final placeFolderPath = path.join(
        storageConfig.devicesDir,
        callsign,
        'places',
        resolvedRelativeRoot,
      );
      final placeDir = Directory(placeFolderPath);
      if (!await placeDir.exists()) {
        await placeDir.create(recursive: true);
      }

      if (placeContent != null && placeContent.isNotEmpty) {
        final placeFile = File(path.join(placeFolderPath, 'place.txt'));
        await placeFile.writeAsString(placeContent, flush: true);
      }

      if (serverFiles != null) {
        await _syncPlaceFiles(
          placeFolderPath: placeFolderPath,
          serverFiles: serverFiles,
          baseUrl: baseUrl,
          callsign: callsign,
          relativeRoot: resolvedRelativeRoot,
        );
      } else {
        for (final photoPath in photos) {
          final localPhotoPath = path.join(placeFolderPath, photoPath);
          final photoFile = File(localPhotoPath);
          if (await photoFile.exists()) {
            continue;
          }

          await _downloadPlaceFile(
            baseUrl: baseUrl,
            callsign: callsign,
            relativeRoot: resolvedRelativeRoot,
            filePath: photoPath,
            localFile: photoFile,
          );
        }
      }

      Place resolvedPlace = place;
      if (placeContent != null && placeContent.isNotEmpty) {
        final parsedPlace = _placeService.parsePlaceContent(
          content: placeContent,
          filePath: path.join(placeFolderPath, 'place.txt'),
          folderPath: placeFolderPath,
        );
        if (parsedPlace != null) {
          resolvedPlace = parsedPlace;
        }
      }

      return resolvedPlace.copyWith(
        folderPath: placeFolderPath,
        filePath: path.join(placeFolderPath, 'place.txt'),
        photoCount: photos.length,
      );
    } catch (e) {
      LogService().log('StationPlaceService: Error caching place: $e');
      return place;
    }
  }

  Future<Map<String, dynamic>?> _fetchPlaceDetails({
    required String baseUrl,
    required String callsign,
    required String folderName,
  }) async {
    try {
      final uri = Uri.parse('$baseUrl/$callsign/api/places/$folderName');
      final response = await http.get(uri).timeout(const Duration(seconds: 30));
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
    } catch (e) {
      LogService().log('StationPlaceService: Error fetching place details: $e');
    }
    return null;
  }

  Future<void> _syncPlaceFiles({
    required String placeFolderPath,
    required Map<String, dynamic> serverFiles,
    required String baseUrl,
    required String callsign,
    required String? relativeRoot,
    String relativePath = '',
  }) async {
    for (final entry in serverFiles.entries) {
      final name = entry.key;
      final meta = entry.value;

      if (name.endsWith('/')) {
        final dirName = name.substring(0, name.length - 1);
        final localDirPath = relativePath.isEmpty
            ? path.join(placeFolderPath, dirName)
            : path.join(placeFolderPath, relativePath, dirName);
        await Directory(localDirPath).create(recursive: true);

        if (meta is Map<String, dynamic>) {
          await _syncPlaceFiles(
            placeFolderPath: placeFolderPath,
            serverFiles: meta,
            baseUrl: baseUrl,
            callsign: callsign,
            relativeRoot: relativeRoot,
            relativePath: relativePath.isEmpty ? dirName : '$relativePath/$dirName',
          );
        }
      } else {
        if (meta is! Map<String, dynamic>) continue;
        final serverMtime = meta['mtime'] as int? ?? 0;
        if (serverMtime == 0) continue;

        final localFilePath = relativePath.isEmpty
            ? path.join(placeFolderPath, name)
            : path.join(placeFolderPath, relativePath, name);
        final fileRelPath = relativePath.isEmpty ? name : '$relativePath/$name';

        final localFile = File(localFilePath);
        int localMtime = 0;
        if (await localFile.exists()) {
          localMtime = (await localFile.stat()).modified.millisecondsSinceEpoch ~/ 1000;
        }

        if (serverMtime > localMtime) {
          await _downloadPlaceFile(
            baseUrl: baseUrl,
            callsign: callsign,
            relativeRoot: relativeRoot,
            filePath: fileRelPath,
            localFile: localFile,
          );
        }
      }
    }
  }

  Future<bool> _downloadPlaceFile({
    required String baseUrl,
    required String callsign,
    required String? relativeRoot,
    required String filePath,
    required File localFile,
  }) async {
    try {
      final uri = _buildPlaceFileUri(
        baseUrl: baseUrl,
        callsign: callsign,
        relativeRoot: relativeRoot,
        filePath: filePath,
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final parent = localFile.parent;
        if (!await parent.exists()) {
          await parent.create(recursive: true);
        }
        await localFile.writeAsBytes(response.bodyBytes, flush: true);
        return true;
      }
    } catch (e) {
      LogService().log('StationPlaceService: Error downloading file: $e');
    }
    return false;
  }

  Uri _buildPlaceFileUri({
    required String baseUrl,
    required String callsign,
    required String? relativeRoot,
    required String filePath,
  }) {
    final baseUri = Uri.parse(baseUrl);
    final rootSegments = _splitUrlPath(relativeRoot ?? '');
    final fileSegments = _splitUrlPath(filePath);
    return baseUri.replace(
      pathSegments: [
        ...baseUri.pathSegments,
        callsign,
        'api',
        'places',
        ...rootSegments,
        'files',
        ...fileSegments,
      ],
    );
  }

  List<String> _splitUrlPath(String value) {
    return value
        .replaceAll('\\', '/')
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .toList();
  }
}
