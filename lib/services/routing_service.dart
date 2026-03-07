/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

// Offline routing engine using cached OSM road network data.
// Downloads road data via station-first / internet-fallback pattern,
// then performs on-device A* pathfinding for fully offline navigation.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:collection';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'config_service.dart';
import 'log_service.dart';
import 'station_service.dart';
import 'storage_config.dart';
import 'network_monitor_service.dart';
import '../version.dart';

/// Travel mode for routing
enum TravelMode { driving, walking }

/// Result of a route calculation
class RouteResult {
  final List<LatLng> points;
  final double distanceMeters;
  final double durationSeconds;

  const RouteResult({
    required this.points,
    required this.distanceMeters,
    required this.durationSeconds,
  });
}

/// A node in the road graph
class _GraphNode {
  final int id;
  final double lat;
  final double lon;
  final List<_GraphEdge> edges;

  _GraphNode({required this.id, required this.lat, required this.lon})
      : edges = [];
}

/// An edge in the road graph
class _GraphEdge {
  final int targetNodeId;
  final double distanceMeters;
  final String highwayType;
  final bool isOneway;

  const _GraphEdge({
    required this.targetNodeId,
    required this.distanceMeters,
    required this.highwayType,
    required this.isOneway,
  });
}

/// Road graph built from OSM data
class _RoadGraph {
  final Map<int, _GraphNode> nodes;

  _RoadGraph(this.nodes);

  /// Speed in km/h for driving mode by road type
  static double drivingSpeed(String highwayType) {
    switch (highwayType) {
      case 'motorway':
      case 'motorway_link':
        return 110;
      case 'trunk':
      case 'trunk_link':
        return 90;
      case 'primary':
      case 'primary_link':
        return 70;
      case 'secondary':
      case 'secondary_link':
        return 50;
      case 'tertiary':
      case 'tertiary_link':
        return 40;
      case 'residential':
      case 'living_street':
      case 'unclassified':
        return 30;
      case 'service':
        return 20;
      default:
        return 30;
    }
  }

  static const double walkingSpeedKmh = 5.0;

  /// Highway types not suitable for driving
  static const _walkOnlyTypes = {
    'footway', 'path', 'cycleway', 'pedestrian', 'steps',
  };
}

/// Offline routing service
class RoutingService {
  static final RoutingService _instance = RoutingService._internal();
  factory RoutingService() => _instance;
  RoutingService._internal();

  _RoadGraph? _cachedGraph;
  bool _isDownloading = false;

  static const String _configRoot = 'roadDataCache';

  /// Whether road data is available locally
  bool get hasRoadData {
    if (_cachedGraph != null) return true;
    final cachePath = _getRoadCachePath();
    if (cachePath == null) return false;
    final file = File(cachePath);
    return file.existsSync() && file.lengthSync() > 0;
  }

  /// Whether a download is in progress
  bool get isDownloading => _isDownloading;

  /// Get cached road data info (center, radius, timestamp)
  Map<String, dynamic> getRoadDataInfo() {
    final config = ConfigService();
    final lat = config.getNestedValue('$_configRoot.centerLat');
    final lon = config.getNestedValue('$_configRoot.centerLon');
    final radius = config.getNestedValue('$_configRoot.radiusKm');
    final lastDownloaded = config.getNestedValue('$_configRoot.lastDownloaded') as String?;
    return {
      'centerLat': lat is num ? lat.toDouble() : null,
      'centerLon': lon is num ? lon.toDouble() : null,
      'radiusKm': radius is num ? radius.toDouble() : null,
      'lastDownloaded': lastDownloaded,
    };
  }

  /// Get the size of cached road data on disk
  Future<int> getRoadDataSizeBytes() async {
    final cachePath = _getRoadCachePath();
    if (cachePath == null) return 0;
    final file = File(cachePath);
    if (await file.exists()) {
      return (await file.stat()).size;
    }
    return 0;
  }

  /// Download road data for an area around a center point.
  /// Tries station first, falls back to direct Overpass API.
  Future<void> downloadRoadData({
    required double lat,
    required double lon,
    required double radiusKm,
  }) async {
    if (_isDownloading) return;
    _isDownloading = true;

    try {
      // Compute bounding box
      final bbox = _computeBbox(lat, lon, radiusKm);
      final south = bbox['south']!;
      final west = bbox['west']!;
      final north = bbox['north']!;
      final east = bbox['east']!;

      String? jsonData;

      // 1. Try station first
      jsonData = await _fetchFromStation(south, west, north, east);

      // 2. Fallback to direct Overpass API
      if (jsonData == null) {
        jsonData = await _fetchFromOverpass(south, west, north, east);
      }

      if (jsonData == null) {
        throw Exception('Failed to download road data from station and Overpass API');
      }

      // Parse and build graph
      final graph = _parseOverpassResponse(jsonData);
      _cachedGraph = graph;

      // Save to disk
      final cachePath = _getRoadCachePath();
      if (cachePath != null) {
        final file = File(cachePath);
        await file.parent.create(recursive: true);
        await file.writeAsString(jsonData);
      }

      // Update config metadata
      final config = ConfigService();
      config.setNestedValue('$_configRoot.centerLat', lat);
      config.setNestedValue('$_configRoot.centerLon', lon);
      config.setNestedValue('$_configRoot.radiusKm', radiusKm);
      config.setNestedValue('$_configRoot.lastDownloaded', DateTime.now().toIso8601String());

      LogService().log('RoutingService: Road data downloaded (${graph.nodes.length} nodes)');
    } finally {
      _isDownloading = false;
    }
  }

  /// Calculate a route between two points.
  /// Auto-downloads road data if none is cached or if the cached data
  /// doesn't cover the route area.
  Future<RouteResult> getRoute({
    required double fromLat,
    required double fromLon,
    required double toLat,
    required double toLon,
    TravelMode mode = TravelMode.driving,
  }) async {
    var graph = await _getGraph();

    // Check if we need to download/re-download road data
    final needsDownload = graph == null || graph.nodes.isEmpty
        || _findNearestNode(graph, fromLat, fromLon) == null
        || _findNearestNode(graph, toLat, toLon) == null;

    if (needsDownload) {
      // Compute center + radius covering both from and to with margin
      final centerLat = (fromLat + toLat) / 2;
      final centerLon = (fromLon + toLon) / 2;
      final dist = _haversineMeters(fromLat, fromLon, toLat, toLon);
      // Radius must cover half the distance plus 2km margin, max 15km
      final minRadius = dist / 2000 + 2.0;
      final radiusKm = minRadius.clamp(2.0, 15.0);

      if (minRadius > 15.0) {
        throw Exception(
          'Route too long for auto-download (${(dist / 1000).toStringAsFixed(0)}km). '
          'Zoom in closer to the route area first.');
      }

      LogService().log('RoutingService: Auto-downloading road data '
          '(center: $centerLat,$centerLon, radius: ${radiusKm.toStringAsFixed(1)}km)');
      await downloadRoadData(lat: centerLat, lon: centerLon, radiusKm: radiusKm);
      graph = _cachedGraph;
    }

    if (graph == null || graph.nodes.isEmpty) {
      throw Exception('No road data available and download failed');
    }

    // Snap start/end to nearest graph nodes
    LogService().log('RoutingService: Snapping to graph (${graph.nodes.length} nodes)...');
    final startNode = _findNearestNode(graph, fromLat, fromLon);
    final endNode = _findNearestNode(graph, toLat, toLon);

    if (startNode == null || endNode == null) {
      LogService().log('RoutingService: Snap failed — start=$startNode, end=$endNode');
      throw Exception('Could not find road network near the given coordinates');
    }

    LogService().log('RoutingService: Snapped start=${startNode.id}, end=${endNode.id}. Running A*...');
    // A* pathfinding
    final path = _astar(graph, startNode, endNode, mode);
    if (path == null) {
      LogService().log('RoutingService: A* found no path');
      throw Exception('No route found between the given points');
    }
    LogService().log('RoutingService: Route found with ${path.length} nodes');

    // Build result
    final points = <LatLng>[];
    double totalDistanceMeters = 0;
    double totalDurationSeconds = 0;

    for (int i = 0; i < path.length; i++) {
      final node = graph.nodes[path[i]]!;
      points.add(LatLng(node.lat, node.lon));

      if (i > 0) {
        final prevNode = graph.nodes[path[i - 1]]!;
        final segDist = _haversineMeters(prevNode.lat, prevNode.lon, node.lat, node.lon);
        totalDistanceMeters += segDist;

        // Find edge for speed
        String edgeType = 'residential';
        for (final edge in prevNode.edges) {
          if (edge.targetNodeId == node.id) {
            edgeType = edge.highwayType;
            break;
          }
        }

        final speedKmh = mode == TravelMode.walking
            ? _RoadGraph.walkingSpeedKmh
            : _RoadGraph.drivingSpeed(edgeType);
        totalDurationSeconds += (segDist / 1000.0) / speedKmh * 3600.0;
      }
    }

    return RouteResult(
      points: points,
      distanceMeters: totalDistanceMeters,
      durationSeconds: totalDurationSeconds,
    );
  }

  /// Clear cached graph (forces reload from disk on next use)
  void clearCache() {
    _cachedGraph = null;
  }

  // ============ Private Methods ============

  String? _getRoadCachePath() {
    try {
      final tilesDir = StorageConfig().tilesDir;
      return '$tilesDir/cache/roads/road_graph.json';
    } catch (e) {
      return null;
    }
  }

  Future<_RoadGraph?> _getGraph() async {
    if (_cachedGraph != null) return _cachedGraph;

    final cachePath = _getRoadCachePath();
    if (cachePath == null) return null;

    final file = File(cachePath);
    if (!await file.exists()) return null;

    try {
      final jsonData = await file.readAsString();
      if (jsonData.trim().isEmpty) return null;
      _cachedGraph = _parseOverpassResponse(jsonData);
      return _cachedGraph;
    } catch (e) {
      LogService().log('RoutingService: Failed to load cached graph: $e');
      return null;
    }
  }

  /// Get station base URL (HTTP, no trailing slash).
  /// Reuses same pattern as MapTileService.getStationTileUrl().
  String? _getStationBaseUrl() {
    try {
      final station = StationService().getPreferredStation();
      if (station == null || station.url.isEmpty) return null;

      var stationUrl = station.url;

      if (stationUrl.startsWith('ws://')) {
        stationUrl = stationUrl.replaceFirst('ws://', 'http://');
      } else if (stationUrl.startsWith('wss://')) {
        stationUrl = stationUrl.replaceFirst('wss://', 'https://');
      }

      if (stationUrl.endsWith('/')) {
        stationUrl = stationUrl.substring(0, stationUrl.length - 1);
      }

      return stationUrl;
    } catch (e) {
      return null;
    }
  }

  Future<String?> _fetchFromStation(double south, double west, double north, double east) async {
    try {
      final baseUrl = _getStationBaseUrl();
      if (baseUrl == null) return null;

      final url = '$baseUrl/api/roads?south=$south&west=$west&north=$north&east=$east';
      LogService().log('RoutingService: Trying station: $url');

      final response = await http.get(
        Uri.parse(url),
        headers: {'User-Agent': 'Geogram/$appVersion'},
      ).timeout(const Duration(seconds: 120));

      if (response.statusCode == 200 && response.body.isNotEmpty) {
        // Validate JSON
        json.decode(response.body);
        LogService().log('RoutingService: Got road data from station (${response.body.length} bytes)');
        return response.body;
      }
      LogService().log('RoutingService: Station returned ${response.statusCode}');
    } catch (e) {
      LogService().log('RoutingService: Station failed: $e');
    }
    return null;
  }

  Future<String?> _fetchFromOverpass(double south, double west, double north, double east) async {
    try {
      if (!NetworkMonitorService().hasLan) {
        LogService().log('RoutingService: No internet for Overpass fallback');
        return null;
      }

      final query = '[out:json][timeout:120];'
          'way["highway"~"motorway|trunk|primary|secondary|tertiary|residential|unclassified|living_street|service|pedestrian|footway|path|cycleway|track"]'
          '($south,$west,$north,$east);(._;>;);out body;';

      LogService().log('RoutingService: Trying Overpass API directly');

      final response = await http.post(
        Uri.parse('https://overpass-api.de/api/interpreter'),
        headers: {'User-Agent': 'Geogram/$appVersion'},
        body: 'data=${Uri.encodeQueryComponent(query)}',
      ).timeout(const Duration(seconds: 120));

      if (response.statusCode == 200 && response.body.isNotEmpty) {
        json.decode(response.body);
        LogService().log('RoutingService: Got road data from Overpass (${response.body.length} bytes)');
        return response.body;
      }
      LogService().log('RoutingService: Overpass returned ${response.statusCode}');
    } catch (e) {
      LogService().log('RoutingService: Overpass failed: $e');
    }
    return null;
  }

  Map<String, double> _computeBbox(double lat, double lon, double radiusKm) {
    // Approximate bbox from center + radius
    const earthRadiusKm = 6371.0;
    final latDelta = (radiusKm / earthRadiusKm) * (180.0 / math.pi);
    final lonDelta = latDelta / math.cos(lat * math.pi / 180.0);

    return {
      'south': lat - latDelta,
      'west': lon - lonDelta,
      'north': lat + latDelta,
      'east': lon + lonDelta,
    };
  }

  _RoadGraph _parseOverpassResponse(String jsonData) {
    final data = json.decode(jsonData) as Map<String, dynamic>;
    final elements = data['elements'] as List<dynamic>? ?? [];

    final nodes = <int, _GraphNode>{};
    final ways = <Map<String, dynamic>>[];

    // First pass: extract nodes and ways
    for (final element in elements) {
      final type = element['type'] as String?;
      if (type == 'node') {
        final id = element['id'] as int;
        final lat = (element['lat'] as num).toDouble();
        final lon = (element['lon'] as num).toDouble();
        nodes[id] = _GraphNode(id: id, lat: lat, lon: lon);
      } else if (type == 'way') {
        ways.add(element as Map<String, dynamic>);
      }
    }

    // Second pass: build edges from ways
    for (final way in ways) {
      final nodeIds = (way['nodes'] as List<dynamic>).cast<int>();
      final tags = way['tags'] as Map<String, dynamic>? ?? {};
      final highway = tags['highway'] as String? ?? 'unclassified';
      final oneway = tags['oneway'] as String?;
      final isOneway = oneway == 'yes' || oneway == '1' || oneway == 'true';

      for (int i = 0; i < nodeIds.length - 1; i++) {
        final fromId = nodeIds[i];
        final toId = nodeIds[i + 1];
        final fromNode = nodes[fromId];
        final toNode = nodes[toId];
        if (fromNode == null || toNode == null) continue;

        final dist = _haversineMeters(fromNode.lat, fromNode.lon, toNode.lat, toNode.lon);

        // Forward edge
        fromNode.edges.add(_GraphEdge(
          targetNodeId: toId,
          distanceMeters: dist,
          highwayType: highway,
          isOneway: isOneway,
        ));

        // Reverse edge (unless oneway)
        if (!isOneway) {
          toNode.edges.add(_GraphEdge(
            targetNodeId: fromId,
            distanceMeters: dist,
            highwayType: highway,
            isOneway: false,
          ));
        }
      }
    }

    // Remove isolated nodes (no edges)
    nodes.removeWhere((id, node) => node.edges.isEmpty);

    return _RoadGraph(nodes);
  }

  _GraphNode? _findNearestNode(_RoadGraph graph, double lat, double lon) {
    _GraphNode? nearest;
    double minDist = double.infinity;

    for (final node in graph.nodes.values) {
      final dist = _haversineMeters(lat, lon, node.lat, node.lon);
      if (dist < minDist) {
        minDist = dist;
        nearest = node;
      }
    }

    // Only snap if within 5km (rural areas have sparse road networks)
    if (minDist > 5000) return null;
    return nearest;
  }

  /// A* pathfinding with Haversine heuristic
  List<int>? _astar(_RoadGraph graph, _GraphNode start, _GraphNode end, TravelMode mode) {
    final openSet = SplayTreeMap<double, List<int>>();
    final gScore = <int, double>{};
    final cameFrom = <int, int>{};
    final inOpenSet = <int>{};

    gScore[start.id] = 0;
    final startH = _haversineMeters(start.lat, start.lon, end.lat, end.lon);
    openSet.putIfAbsent(startH, () => []).add(start.id);
    inOpenSet.add(start.id);

    while (openSet.isNotEmpty) {
      // Get node with lowest f-score
      final lowestKey = openSet.firstKey()!;
      final nodeList = openSet[lowestKey]!;
      final currentId = nodeList.removeLast();
      if (nodeList.isEmpty) openSet.remove(lowestKey);
      inOpenSet.remove(currentId);

      if (currentId == end.id) {
        // Reconstruct path
        final path = <int>[currentId];
        var cur = currentId;
        while (cameFrom.containsKey(cur)) {
          cur = cameFrom[cur]!;
          path.add(cur);
        }
        return path.reversed.toList();
      }

      final currentNode = graph.nodes[currentId];
      if (currentNode == null) continue;

      final currentG = gScore[currentId] ?? double.infinity;

      for (final edge in currentNode.edges) {
        // Filter edges based on travel mode
        if (mode == TravelMode.driving && _RoadGraph._walkOnlyTypes.contains(edge.highwayType)) {
          continue; // Skip walk-only roads for driving
        }

        final neighborId = edge.targetNodeId;
        final neighborNode = graph.nodes[neighborId];
        if (neighborNode == null) continue;

        final tentativeG = currentG + edge.distanceMeters;

        if (tentativeG < (gScore[neighborId] ?? double.infinity)) {
          cameFrom[neighborId] = currentId;
          gScore[neighborId] = tentativeG;

          final h = _haversineMeters(neighborNode.lat, neighborNode.lon, end.lat, end.lon);
          final f = tentativeG + h;

          if (!inOpenSet.contains(neighborId)) {
            openSet.putIfAbsent(f, () => []).add(neighborId);
            inOpenSet.add(neighborId);
          }
        }
      }
    }

    return null; // No path found
  }

  /// Haversine distance in meters
  static double _haversineMeters(double lat1, double lon1, double lat2, double lon2) {
    const earthRadiusM = 6371000.0;
    final dLat = _degToRad(lat2 - lat1);
    final dLon = _degToRad(lon2 - lon1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_degToRad(lat1)) *
            math.cos(_degToRad(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadiusM * c;
  }

  static double _degToRad(double degrees) => degrees * (math.pi / 180.0);
}
