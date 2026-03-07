// Road data HTTP handler for station server
// Downloads and caches OSM road network data via Overpass API
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../../version.dart';

/// Handler for road data endpoints.
/// Works with both StationServerBase and PureStationServer since it only
/// requires osmFallbackEnabled and httpRequestTimeout via callbacks.
class RoadHandler {
  final bool Function() getOsmFallbackEnabled;
  final int Function() getHttpRequestTimeout;
  final String tilesDirectory;
  final void Function(String, String) log;

  RoadHandler({
    required this.getOsmFallbackEnabled,
    required this.getHttpRequestTimeout,
    required this.tilesDirectory,
    required this.log,
  });

  /// Handle GET /api/roads?south=X&west=X&north=X&east=X
  Future<void> handleRoadDataRequest(HttpRequest request) async {
    if (!getOsmFallbackEnabled()) {
      request.response.statusCode = 503;
      request.response.write('Road data service disabled');
      return;
    }

    final params = request.uri.queryParameters;
    final south = double.tryParse(params['south'] ?? '');
    final west = double.tryParse(params['west'] ?? '');
    final north = double.tryParse(params['north'] ?? '');
    final east = double.tryParse(params['east'] ?? '');

    if (south == null || west == null || north == null || east == null) {
      request.response.statusCode = 400;
      request.response.write('Missing or invalid bbox parameters (south, west, north, east)');
      return;
    }

    // Validate bbox ranges
    if (south < -90 || south > 90 || north < -90 || north > 90 ||
        west < -180 || west > 180 || east < -180 || east > 180 ||
        south >= north) {
      request.response.statusCode = 400;
      request.response.write('Invalid bbox values');
      return;
    }

    final bboxKey = '${south.toStringAsFixed(4)}_${west.toStringAsFixed(4)}_${north.toStringAsFixed(4)}_${east.toStringAsFixed(4)}';
    final bboxHash = md5.convert(utf8.encode(bboxKey)).toString();

    // Check disk cache
    final roadsDir = '$tilesDirectory/roads';
    final cachePath = '$roadsDir/$bboxHash.json';
    final cacheFile = File(cachePath);

    if (await cacheFile.exists()) {
      try {
        final data = await cacheFile.readAsString();
        log('INFO', 'Road data served from cache: $bboxHash');
        request.response.headers.contentType = ContentType.json;
        request.response.write(data);
        return;
      } catch (e) {
        log('WARN', 'Failed to read road cache: $e');
      }
    }

    // Fetch from Overpass API
    final timeout = getHttpRequestTimeout();
    final overpassData = await _fetchFromOverpass(south, west, north, east, timeout);
    if (overpassData != null) {
      // Cache to disk
      try {
        await Directory(roadsDir).create(recursive: true);
        await cacheFile.writeAsString(overpassData);
        log('INFO', 'Road data cached: $bboxHash');
      } catch (e) {
        log('WARN', 'Failed to cache road data: $e');
      }

      request.response.headers.contentType = ContentType.json;
      request.response.write(overpassData);
      return;
    }

    request.response.statusCode = 502;
    request.response.write('Failed to fetch road data from Overpass API');
  }

  Future<String?> _fetchFromOverpass(double south, double west, double north, double east, int timeout) async {
    try {
      final query = '[out:json][timeout:120];'
          'way["highway"~"motorway|trunk|primary|secondary|tertiary|residential|unclassified|living_street|service|pedestrian|footway|path|cycleway|track"]'
          '($south,$west,$north,$east);(._;>;);out body;';

      final response = await http.post(
        Uri.parse('https://overpass-api.de/api/interpreter'),
        headers: {'User-Agent': 'Geogram/$appVersion'},
        body: 'data=${Uri.encodeQueryComponent(query)}',
      ).timeout(Duration(milliseconds: timeout > 0 ? timeout : 120000));

      if (response.statusCode == 200) {
        // Validate it's valid JSON
        json.decode(response.body);
        return response.body;
      }
      log('WARN', 'Overpass API returned ${response.statusCode}');
    } catch (e) {
      log('WARN', 'Failed to fetch from Overpass API: $e');
    }
    return null;
  }
}
