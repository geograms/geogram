/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

import '../models/place.dart';
import '../services/log_service.dart';
import '../services/place_service.dart';
import '../services/profile_service.dart';
import '../services/station_service.dart';

/// Service for uploading places to the preferred station
class PlaceSharingService {
  static final PlaceSharingService _instance = PlaceSharingService._internal();
  factory PlaceSharingService() => _instance;
  PlaceSharingService._internal();

  final StationService _stationService = StationService();
  final ProfileService _profileService = ProfileService();
  final PlaceService _placeService = PlaceService();

  /// Get configured station URLs
  List<String> getRelayUrls() {
    final preferredStation = _stationService.getPreferredStation();
    if (preferredStation != null && preferredStation.url.isNotEmpty) {
      LogService().log('PlaceSharingService: Using preferred station: ${preferredStation.url}');
      return [preferredStation.url];
    }

    LogService().log('PlaceSharingService: No preferred station, using default wss://p2p.radio');
    return ['wss://p2p.radio'];
  }

  /// Upload a place (place.txt + photos) to all configured stations
  Future<int> uploadPlaceToStations(Place place, String collectionPath) async {
    if (kIsWeb) return 0;

    int uploadedTotal = 0;
    final stationUrls = getRelayUrls();
    for (final stationUrl in stationUrls) {
      uploadedTotal += await uploadPlaceToStation(place, collectionPath, stationUrl);
    }
    return uploadedTotal;
  }

  /// Upload a place (place.txt + photos) to a specific station
  Future<int> uploadPlaceToStation(
    Place place,
    String collectionPath,
    String stationUrl,
  ) async {
    if (kIsWeb) return 0;

    try {
      await _placeService.initializeCollection(collectionPath);

      final profile = _profileService.getProfile();
      final callsign = profile.callsign;
      if (callsign.isEmpty) {
        LogService().log('PlaceSharingService: No callsign, cannot upload');
        return 0;
      }

      final placeFolderPath = await _placeService.getPlaceFolderPath(place);
      if (placeFolderPath == null) {
        LogService().log('PlaceSharingService: Failed to resolve place folder path');
        return 0;
      }

      final placesBasePath = path.basename(collectionPath) == 'places'
          ? collectionPath
          : path.join(collectionPath, 'places');
      final relativePlacePath = path.relative(placeFolderPath, from: placesBasePath);
      if (relativePlacePath.startsWith('..')) {
        LogService().log('PlaceSharingService: Invalid relative place path: $relativePlacePath');
        return 0;
      }

      final filesToUpload = <(File, String)>[];

      final placeFile = File(path.join(placeFolderPath, 'place.txt'));
      if (await placeFile.exists()) {
        filesToUpload.add((placeFile, 'place.txt'));
      }

      final imagesDir = Directory(path.join(placeFolderPath, 'images'));
      if (await imagesDir.exists()) {
        await for (final entity in imagesDir.list()) {
          if (entity is File) {
            final ext = path.extension(entity.path).toLowerCase();
            if (_isImageExtension(ext)) {
              final filename = path.basename(entity.path);
              filesToUpload.add((
                entity,
                path.join('images', filename),
              ));
            }
          }
        }
      }

      // Backwards compatibility: root-level images
      final folderDir = Directory(placeFolderPath);
      await for (final entity in folderDir.list()) {
        if (entity is File) {
          final ext = path.extension(entity.path).toLowerCase();
          if (_isImageExtension(ext) && path.basename(entity.path) != 'place.txt') {
            final filename = path.basename(entity.path);
            filesToUpload.add((
              entity,
              filename,
            ));
          }
        }
      }

      if (filesToUpload.isEmpty) {
        LogService().log('PlaceSharingService: No files to upload for ${place.name}');
        return 0;
      }

      final baseUrl = _stationToHttpUrl(stationUrl);
      final baseUri = Uri.parse(baseUrl);
      int uploadedCount = 0;

      for (final (file, relativePath) in filesToUpload) {
        try {
          final bytes = await file.readAsBytes();
          final contentType = _contentTypeForPath(relativePath);
          final placeSegments = _splitUrlPath(relativePlacePath);
          final fileSegments = _splitUrlPath(relativePath);
          final uri = baseUri.replace(
            pathSegments: [
              ...baseUri.pathSegments,
              callsign,
              'api',
              'places',
              ...placeSegments,
              'files',
              ...fileSegments,
            ],
          );

          final response = await http.post(
            uri,
            headers: {
              'Content-Type': contentType,
              'X-Callsign': callsign,
            },
            body: bytes,
          ).timeout(const Duration(seconds: 60));

          if (response.statusCode == 200 || response.statusCode == 201) {
            uploadedCount++;
          } else {
            LogService().log(
              'PlaceSharingService: Upload failed ${response.statusCode} for $relativePath',
            );
          }
        } catch (e) {
          LogService().log('PlaceSharingService: Error uploading $relativePath: $e');
        }
      }

      LogService().log('PlaceSharingService: Uploaded $uploadedCount/${filesToUpload.length} files to $stationUrl');
      return uploadedCount;
    } catch (e) {
      LogService().log('PlaceSharingService: Error uploading place: $e');
      return 0;
    }
  }

  bool _isImageExtension(String ext) {
    return ext == '.jpg' ||
        ext == '.jpeg' ||
        ext == '.png' ||
        ext == '.gif' ||
        ext == '.webp';
  }

  String _contentTypeForPath(String relativePath) {
    final ext = path.extension(relativePath).toLowerCase();
    if (ext == '.jpg' || ext == '.jpeg') return 'image/jpeg';
    if (ext == '.png') return 'image/png';
    if (ext == '.gif') return 'image/gif';
    if (ext == '.webp') return 'image/webp';
    if (ext == '.txt') return 'text/plain';
    return 'application/octet-stream';
  }

  String _stationToHttpUrl(String stationUrl) {
    if (stationUrl.startsWith('wss://')) {
      return stationUrl.replaceFirst('wss://', 'https://');
    }
    if (stationUrl.startsWith('ws://')) {
      return stationUrl.replaceFirst('ws://', 'http://');
    }
    return stationUrl;
  }

  List<String> _splitUrlPath(String value) {
    return value
        .replaceAll('\\', '/')
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .toList();
  }
}
