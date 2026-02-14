/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show kIsWeb, ValueNotifier, compute;
import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart' as fmtc;
import 'package:http/http.dart' as http;
import 'profile_service.dart';
import 'storage_config.dart';
import 'station_service.dart';
import 'log_service.dart';
import 'config_service.dart';
import 'network_monitor_service.dart';

/// Map layer types
enum MapLayerType {
  standard,  // OpenStreetMap
  satellite, // Esri World Imagery
}

/// Result of tile download operation
enum _TileDownloadResult {
  downloaded, // Tile was downloaded from network
  skipped,    // Tile was fresh in cache, skipped
  failed,     // Download failed
}

/// Priority levels for tile download requests
enum _TilePriority { high, low }

/// A tile download request in the queue
class _TileRequest {
  final int z;
  final int x;
  final int y;
  final MapLayerType layer;
  final _TilePriority priority;
  final int maxAgeDays;
  final Completer<_TileDownloadResult>? completer;

  _TileRequest({
    required this.z,
    required this.x,
    required this.y,
    required this.layer,
    required this.priority,
    this.maxAgeDays = 90,
    this.completer,
  });

  /// Unique key for deduplication
  String get key => '${layer.name}/$z/$x/$y';
}

/// Status of tile loading operations
class TileLoadingStatus {
  final int loadingCount;
  final int failedCount;
  final DateTime? lastFailure;

  const TileLoadingStatus({
    this.loadingCount = 0,
    this.failedCount = 0,
    this.lastFailure,
  });

  bool get isLoading => loadingCount > 0;
  bool get hasFailures => failedCount > 0;

  TileLoadingStatus copyWith({
    int? loadingCount,
    int? failedCount,
    DateTime? lastFailure,
  }) {
    return TileLoadingStatus(
      loadingCount: loadingCount ?? this.loadingCount,
      failedCount: failedCount ?? this.failedCount,
      lastFailure: lastFailure ?? this.lastFailure,
    );
  }
}

/// Download progress state for UI
class TileDownloadProgress {
  final bool isDownloading;
  final int downloadedTiles;
  final int totalTiles;
  final int skippedTiles;
  final String? error;

  const TileDownloadProgress({
    this.isDownloading = false,
    this.downloadedTiles = 0,
    this.totalTiles = 0,
    this.skippedTiles = 0,
    this.error,
  });

  double get progress => totalTiles > 0 ? downloadedTiles / totalTiles : 0.0;
}

/// Centralized service for managing map tiles with offline caching
/// Tile fetching priority: 1) Cache, 2) Station, 3) Direct Internet (OSM)
/// Tiles are stored in {data-root}/tiles/
class MapTileService {
  static final MapTileService _instance = MapTileService._internal();
  factory MapTileService() => _instance;
  MapTileService._internal();

  final ProfileService _profileService = ProfileService();
  final NetworkMonitorService _networkMonitor = NetworkMonitorService();
  bool _initialized = false;
  fmtc.FMTCStore? _tileStore;
  String? _tilesPath;
  Future<void>? _offlineDownloadFuture;

  // Separate radii for different layer types (off-grid optimization)
  static const double _offlineCacheRadiusKmStandard = 500.0; // Standard map: 500km
  static const double _offlineCacheRadiusKmSatellite = 100.0; // Satellite + overlays: 100km
  static const int _offlineCacheMinZoom = 8;
  static const int _offlineCacheMaxZoom = 12;
  static const double _offlineCacheMinMoveKm = 10.0;
  static const Duration _offlineCacheMaxAge = Duration(days: 14);
  static const String _offlineCacheConfigRoot = 'offlineMapCache';

  // High-zoom tile caching for immediate location (for LocationPickerPage at zoom 18)
  static const double _highZoomCacheRadiusKm = 5.0; // 5km radius for high zoom tiles
  static const int _highZoomMinZoom = 13;
  static const int _highZoomMaxZoom = 18;

  /// Shared HTTP client for all tile fetches (prevents "too many open files")
  final http.Client httpClient = http.Client();

  /// Notifier for tile loading status (loading count, failed count)
  final ValueNotifier<TileLoadingStatus> statusNotifier =
      ValueNotifier(const TileLoadingStatus());

  /// Notifier for download progress (persists across UI navigation)
  final ValueNotifier<TileDownloadProgress> downloadProgressNotifier =
      ValueNotifier(const TileDownloadProgress());

  /// Timer to auto-clear failure status after a delay
  Timer? _failureClearTimer;

  /// Priority queue for tile downloads
  final List<_TileRequest> _downloadQueue = [];
  final Set<String> _queuedKeys = {};  // O(1) deduplication check
  static const int _maxConcurrentDownloads = 4;
  int _activeDownloads = 0;

  /// Tile server reachability state (replaces generic internet check)
  bool? _canReachTileServer;
  DateTime? _lastTileServerCheck;
  static const Duration _tileServerCheckCacheDuration = Duration(seconds: 30);

  /// Increment loading count
  void _startLoading() {
    statusNotifier.value = statusNotifier.value.copyWith(
      loadingCount: statusNotifier.value.loadingCount + 1,
    );
  }

  /// Decrement loading count
  void _finishLoading() {
    final current = statusNotifier.value.loadingCount;
    statusNotifier.value = statusNotifier.value.copyWith(
      loadingCount: current > 0 ? current - 1 : 0,
    );
  }

  /// Record a tile load failure
  void _recordFailure() {
    statusNotifier.value = statusNotifier.value.copyWith(
      failedCount: statusNotifier.value.failedCount + 1,
      lastFailure: DateTime.now(),
    );

    // Auto-clear failure status after 5 seconds of no new failures
    _failureClearTimer?.cancel();
    _failureClearTimer = Timer(const Duration(seconds: 5), () {
      statusNotifier.value = statusNotifier.value.copyWith(
        failedCount: 0,
      );
    });
  }

  /// Clear all status
  void clearStatus() {
    _failureClearTimer?.cancel();
    statusNotifier.value = const TileLoadingStatus();
  }

  /// Add a tile to the download queue
  /// High priority tiles go to the front, low priority to the back
  Future<_TileDownloadResult> _enqueueDownload(_TileRequest request) {
    // Skip if already queued - return a future that completes when existing request does
    if (_queuedKeys.contains(request.key)) {
      // Find existing request and return its completer's future
      final existing = _downloadQueue.firstWhere(
        (r) => r.key == request.key,
        orElse: () => request,
      );
      return existing.completer?.future ?? Future.value(_TileDownloadResult.skipped);
    }

    // Create completer for async result
    final completer = Completer<_TileDownloadResult>();
    final requestWithCompleter = _TileRequest(
      z: request.z,
      x: request.x,
      y: request.y,
      layer: request.layer,
      priority: request.priority,
      maxAgeDays: request.maxAgeDays,
      completer: completer,
    );

    _queuedKeys.add(request.key);

    if (request.priority == _TilePriority.high) {
      // Insert at front for immediate processing
      _downloadQueue.insert(0, requestWithCompleter);
    } else {
      // Add to back for background processing
      _downloadQueue.add(requestWithCompleter);
    }

    // Start processor if capacity available
    _processQueue();

    return completer.future;
  }

  /// Process the download queue with concurrent workers
  void _processQueue() {
    while (_activeDownloads < _maxConcurrentDownloads && _downloadQueue.isNotEmpty) {
      final request = _downloadQueue.removeAt(0);
      _queuedKeys.remove(request.key);
      _activeDownloads++;

      _downloadAndCacheTileWithAge(
        request.z,
        request.x,
        request.y,
        request.layer,
        maxAgeDays: request.maxAgeDays,
      ).then((result) {
        request.completer?.complete(result);
      }).catchError((e) {
        LogService().log('MapTileService: Queue tile failed: ${request.key}: $e');
        request.completer?.complete(_TileDownloadResult.failed);
      }).whenComplete(() {
        _activeDownloads--;
        _processQueue(); // Pick up next item
      });
    }
  }

  /// Get the tiles storage path
  String? get tilesPath => _tilesPath;

  /// Network availability helpers (used to avoid retries in offline mode)
  /// canUseInternet checks if OSM tile server is reachable (cached for 30s)
  bool get canUseInternet {
    // If we have a fresh cached result, use it
    if (_canReachTileServer != null && _lastTileServerCheck != null) {
      if (DateTime.now().difference(_lastTileServerCheck!) < _tileServerCheckCacheDuration) {
        return _canReachTileServer!;
      }
    }
    // If no cached result, return true (optimistic) and trigger async check
    // The HTTP download already has a 10-second timeout as safety net for offline
    _checkTileServerReachability();
    return _canReachTileServer ?? true;
  }

  bool get canUseStation => _canReachTileServer != false || _networkMonitor.hasLan;

  /// Check if the OSM tile server is reachable (async, updates cached state)
  Future<bool> checkTileServerReachability() async {
    return _checkTileServerReachability();
  }

  /// Internal tile server reachability check
  Future<bool> _checkTileServerReachability() async {
    try {
      // HEAD request to tile server - minimal data transfer
      final response = await httpClient.head(
        Uri.parse('https://tile.openstreetmap.org/0/0/0.png'),
      ).timeout(const Duration(seconds: 5));

      _canReachTileServer = response.statusCode >= 200 && response.statusCode < 400;
      _lastTileServerCheck = DateTime.now();
      return _canReachTileServer!;
    } catch (e) {
      _canReachTileServer = false;
      _lastTileServerCheck = DateTime.now();
      return false;
    }
  }

  /// Initialize the tile caching system
  /// Should be called once at app startup or before first map use
  /// Tiles are stored in {data-root}/tiles/
  Future<void> initialize() async {
    if (_initialized || kIsWeb) return;

    try {
      // Create tiles directory at {data-root}/tiles/
      _tilesPath = StorageConfig().tilesDir;
      final tilesDir = Directory(_tilesPath!);

      if (!await tilesDir.exists()) {
        await tilesDir.create(recursive: true);
      }

      _initialized = true;
      LogService().log('MapTileService: Tile cache ready at $_tilesPath');

      try {
        // Initialize FMTC with custom root directory
        await fmtc.FMTCObjectBoxBackend().initialise(
          rootDirectory: _tilesPath,
        );

        _tileStore = fmtc.FMTCStore('mapTiles');
        await _tileStore!.manage.create();
        LogService().log('MapTileService: FMTC cache initialized');
      } catch (e) {
        LogService().log('MapTileService: FMTC cache unavailable, using file cache only: $e');
      }

      try {
        await _networkMonitor.initialize();
      } catch (e) {
        LogService().log('MapTileService: Network monitor init failed: $e');
      }

      // Check tile server reachability (async, non-blocking)
      _checkTileServerReachability().then((reachable) {
        LogService().log('MapTileService: Tile server ${reachable ? "reachable" : "unreachable"}');
      });

      // Log station tile URL availability for debugging
      final stationUrl = getStationTileUrl();
      if (stationUrl != null) {
        LogService().log('MapTileService: Station tiles enabled');
      }

      // Load saved layer preference
      final savedLayer = ConfigService().get('mapLayerType');
      if (savedLayer == 'satellite') {
        _currentLayerType = MapLayerType.satellite;
        layerTypeNotifier.value = MapLayerType.satellite;
        LogService().log('MapTileService: Restored saved layer preference: satellite');
      }
    } catch (e) {
      LogService().log('MapTileService: Failed to initialize tile cache: $e');
      _initialized = false;
    }
  }

  /// OpenStreetMap tile URL - always works with internet connection
  static const String osmTileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  /// Esri World Imagery satellite tile URL (free, no API key required)
  /// Note: Esri uses {z}/{y}/{x} order (y before x)
  static const String satelliteTileUrl = 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';

  /// Esri Reference layer - white labels with black outlines designed for satellite imagery
  /// Includes boundaries, places, roads at various zoom levels
  /// Note: Esri uses {z}/{y}/{x} order (y before x)
  static const String labelsOnlyUrl = 'https://services.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}';

  /// Esri Transportation Reference - road names and numbers (for higher zoom levels)
  static const String transportLabelsUrl = 'https://services.arcgisonline.com/ArcGIS/rest/services/Reference/World_Transportation/MapServer/tile/{z}/{y}/{x}';

  /// Esri Canvas Reference - provides visible country/region borders
  /// Uses light gray reference which shows borders prominently against satellite imagery
  static const String bordersUrl = 'https://services.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Light_Gray_Reference/MapServer/tile/{z}/{y}/{x}';

  /// Current map layer type (default: satellite)
  MapLayerType _currentLayerType = MapLayerType.satellite;

  /// Notifier for layer type changes
  final ValueNotifier<MapLayerType> layerTypeNotifier = ValueNotifier(MapLayerType.satellite);

  /// Get current layer type
  MapLayerType get currentLayerType => _currentLayerType;

  /// Set the current layer type
  void setLayerType(MapLayerType type) {
    if (_currentLayerType != type) {
      _currentLayerType = type;
      layerTypeNotifier.value = type;
      // Save preference
      ConfigService().set('mapLayerType', type.name);
      LogService().log('MapTileService: Layer changed to ${type.name}');
    }
  }

  /// Toggle between standard and satellite layers
  void toggleLayer() {
    setLayerType(_currentLayerType == MapLayerType.standard
        ? MapLayerType.satellite
        : MapLayerType.standard);
  }

  /// Get the station tile URL if station is available
  /// [layerType] specifies the layer type (standard or satellite)
  String? getStationTileUrl([MapLayerType? layerType]) {
    try {
      final station = StationService().getPreferredStation();
      final profile = _profileService.getProfile();

      // Check requirements for station tile URL
      if (station == null) {
        return null;
      }
      if (station.url.isEmpty) {
        return null;
      }
      if (profile.callsign.isEmpty) {
        LogService().log('MapTileService: User callsign is empty, cannot use station for tiles');
        return null;
      }

      var stationUrl = station.url;

      // Convert ws:// to http:// and wss:// to https://
      if (stationUrl.startsWith('ws://')) {
        stationUrl = stationUrl.replaceFirst('ws://', 'http://');
      } else if (stationUrl.startsWith('wss://')) {
        stationUrl = stationUrl.replaceFirst('wss://', 'https://');
      }

      // Remove trailing slash if present
      if (stationUrl.endsWith('/')) {
        stationUrl = stationUrl.substring(0, stationUrl.length - 1);
      }

      if (!canUseInternet) {
        final parsed = Uri.tryParse(stationUrl);
        final host = parsed?.host ?? '';
        if (host.isEmpty || !_isLikelyLocalHost(host)) {
          return null;
        }
      }

      // Add layer query parameter for satellite tiles
      final layer = layerType ?? _currentLayerType;
      final layerParam = layer == MapLayerType.satellite ? '?layer=satellite' : '';

      return '$stationUrl/tiles/${profile.callsign}/{z}/{x}/{y}.png$layerParam';
    } catch (e) {
      LogService().log('MapTileService: Error getting station tile URL: $e');
    }
    return null;
  }

  bool _isLikelyLocalHost(String host) {
    final lowerHost = host.toLowerCase();
    if (lowerHost == 'localhost' || lowerHost == '::1') return true;
    if (lowerHost.endsWith('.local') ||
        lowerHost.endsWith('.lan') ||
        lowerHost.endsWith('.localdomain')) {
      return true;
    }
    if (!host.contains('.')) return true;
    if (lowerHost.startsWith('fc') || lowerHost.startsWith('fd') || lowerHost.startsWith('fe80:')) {
      return true;
    }

    final parts = host.split('.');
    if (parts.length != 4) return false;
    final octets = <int>[];
    for (final part in parts) {
      final value = int.tryParse(part);
      if (value == null || value < 0 || value > 255) return false;
      octets.add(value);
    }

    if (octets[0] == 10) return true;
    if (octets[0] == 127) return true;
    if (octets[0] == 169 && octets[1] == 254) return true;
    if (octets[0] == 192 && octets[1] == 168) return true;
    if (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) return true;
    return false;
  }

  /// Get the tile URL template for the specified layer type
  String getTileUrl([MapLayerType? layerType]) {
    final type = layerType ?? _currentLayerType;
    return type == MapLayerType.satellite ? satelliteTileUrl : osmTileUrl;
  }

  /// Get the tile provider with priority: Cache -> Station -> Internet
  TileProvider getTileProvider([MapLayerType? layerType]) {
    final type = layerType ?? _currentLayerType;
    if (_initialized && !kIsWeb) {
      // Use custom provider with fallback logic
      return GeogramTileProvider(
        mapTileService: this,
        layerType: type,
      );
    }
    // Fallback to network-only provider
    return NetworkTileProvider();
  }

  /// Get the labels overlay tile provider (for satellite view)
  TileProvider getLabelsProvider() {
    if (_initialized && !kIsWeb) {
      return GeogramLabelsTileProvider(
        mapTileService: this,
      );
    }
    return NetworkTileProvider();
  }

  /// Get the labels overlay URL (boundaries and places)
  String getLabelsUrl() => labelsOnlyUrl;

  /// Get the transport labels URL (road names, route numbers - for higher zoom)
  String getTransportLabelsUrl() => transportLabelsUrl;

  /// Get the borders URL (country/region borders - for satellite view)
  String getBordersUrl() => bordersUrl;

  /// Get the borders tile provider (for country borders on satellite view)
  TileProvider getBordersProvider() {
    if (_initialized && !kIsWeb) {
      return GeogramBordersTileProvider(
        mapTileService: this,
      );
    }
    return NetworkTileProvider();
  }

  /// Get the transport labels tile provider (for detailed road info at high zoom)
  TileProvider getTransportLabelsProvider() {
    if (_initialized && !kIsWeb) {
      return GeogramTransportLabelsTileProvider(
        mapTileService: this,
      );
    }
    return NetworkTileProvider();
  }

  /// Check if tile caching is available and initialized
  bool get isCacheInitialized => _initialized && !kIsWeb;

  /// Get the tile store (for advanced operations if needed)
  fmtc.FMTCStore? get tileStore => _tileStore;

  /// Clear all cached tiles (useful for troubleshooting or storage management)
  Future<void> clearCache() async {
    if (kIsWeb) return;

    // Clear file-based cache
    if (_tilesPath != null) {
      try {
        final cacheDir = Directory('$_tilesPath/cache');
        if (await cacheDir.exists()) {
          await cacheDir.delete(recursive: true);
          LogService().log('MapTileService: File cache cleared successfully');
        }
      } catch (e) {
        LogService().log('MapTileService: Error clearing file cache: $e');
      }
    }

    // Clear FMTC store
    if (_tileStore != null) {
      try {
        await _tileStore!.manage.delete();
        await _tileStore!.manage.create();
        LogService().log('MapTileService: FMTC cache cleared successfully');
      } catch (e) {
        LogService().log('MapTileService: Error clearing FMTC cache: $e');
      }
    }
  }

  /// Helper math function for asinh (inverse hyperbolic sine)
  static double _asinh(double x) {
    // asinh(x) = ln(x + sqrt(x^2 + 1))
    if (x.isNaN) return 0.0;
    if (x.abs() < 1e-10) return x;
    final sign = x < 0 ? -1.0 : 1.0;
    final absX = x.abs();
    return sign * math.log(absX + math.sqrt(absX * absX + 1.0));
  }

  /// Validate tile image data by attempting to decode it
  /// Returns true if the image can be decoded successfully
  static Future<bool> validateTileData(Uint8List data) async {
    if (data.isEmpty) return false;

    // Check for valid PNG or JPEG header
    if (data.length < 8) return false;
    final isPng = data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47;
    final isJpeg = data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF;
    if (!isPng && !isJpeg) return false;

    try {
      // Actually try to decode the image to verify it's not corrupt
      final codec = await ui.instantiateImageCodec(data);
      // Try to get the first frame to force decompression
      await codec.getNextFrame();
      codec.dispose();
      return true;
    } catch (e) {
      LogService().log('MapTileService: Tile validation failed: $e');
      return false;
    }
  }

  /// Test tile fetching by simulating map navigation
  /// This clears specific test tiles from cache and fetches them fresh
  /// to verify the station -> internet fallback chain works correctly
  /// [layerType] can be 'standard' or 'satellite' to test different tile sources
  Future<Map<String, dynamic>> testTileFetching({
    double lat = 49.683,
    double lon = 8.622,
    int zoom = 5,
    bool clearTestTilesFirst = true,
    String layerType = 'standard',
  }) async {
    if (!_initialized) {
      await initialize();
    }

    final results = <String, dynamic>{
      'success': false,
      'tiles': <Map<String, dynamic>>[],
      'stationUrl': getStationTileUrl(),
      'errors': <String>[],
    };

    LogService().log('=== TILE FETCH TEST START ===');
    LogService().log('Test location: lat=$lat, lon=$lon, zoom=$zoom');
    LogService().log('Station URL template: ${results['stationUrl'] ?? 'NOT AVAILABLE'}');

    // Convert lat/lon to tile coordinates for the specified zoom level
    // Standard Web Mercator tile calculation
    final n = 1 << zoom; // 2^zoom
    final xTile = ((lon + 180.0) / 360.0 * n).floor();
    final latRad = lat * math.pi / 180.0;
    // asinh(tan(latRad))
    final tanLat = math.tan(latRad);
    final asinhTan = _asinh(tanLat);
    final yTile = ((1.0 - (asinhTan / math.pi)) / 2.0 * n).floor();

    // Test tiles: center tile and adjacent tiles
    final testTiles = <List<int>>[
      [zoom, xTile, yTile],
      [zoom, xTile + 1, yTile],
      [zoom, xTile, yTile + 1],
      [zoom, xTile - 1, yTile],
      [zoom, xTile, yTile - 1],
    ];

    LogService().log('Testing ${testTiles.length} tiles around [$zoom/$xTile/$yTile]');

    // Clear test tiles from cache if requested
    if (clearTestTilesFirst && _tilesPath != null) {
      LogService().log('Clearing test tiles from local cache...');
      for (final tile in testTiles) {
        final z = tile[0];
        final x = tile[1];
        final y = tile[2];
        final cachePath = '$_tilesPath/cache/standard/$z/$x/$y.png';
        try {
          final file = File(cachePath);
          if (await file.exists()) {
            await file.delete();
            LogService().log('  Deleted: $cachePath');
          }
        } catch (e) {
          // Ignore deletion errors
        }
      }
    }

    // Fetch each tile and record results
    for (final tile in testTiles) {
      final z = tile[0];
      final x = tile[1];
      final y = tile[2];
      final tileResult = <String, dynamic>{
        'z': z,
        'x': x,
        'y': y,
        'source': 'unknown',
        'bytes': 0,
        'error': null,
      };

      try {
        // First try station
        final stationUrl = getStationTileUrl();
        if (stationUrl != null) {
          final url = stationUrl
              .replaceAll('{z}', z.toString())
              .replaceAll('{x}', x.toString())
              .replaceAll('{y}', y.toString());

          LogService().log('TEST [$z/$x/$y] Trying station: $url');
          try {
            final response = await httpClient
                .get(Uri.parse(url))
                .timeout(const Duration(seconds: 5));

            if (response.statusCode == 200 && response.bodyBytes.length > 100) {
              tileResult['source'] = 'STATION';
              tileResult['bytes'] = response.bodyBytes.length;
              LogService().log('TEST [$z/$x/$y] SUCCESS from STATION (${response.bodyBytes.length} bytes)');
              (results['tiles'] as List).add(tileResult);
              continue;
            } else {
              LogService().log('TEST [$z/$x/$y] Station returned ${response.statusCode} (${response.bodyBytes.length} bytes)');
            }
          } catch (e) {
            LogService().log('TEST [$z/$x/$y] Station failed: $e');
          }
        } else {
          LogService().log('TEST [$z/$x/$y] No station URL configured');
        }

        // Fall back to internet
        final osmUrl = 'https://tile.openstreetmap.org/$z/$x/$y.png';
        LogService().log('TEST [$z/$x/$y] Trying internet: $osmUrl');
        final osmResponse = await httpClient
            .get(Uri.parse(osmUrl), headers: {'User-Agent': 'dev.geogram'})
            .timeout(const Duration(seconds: 10));

        if (osmResponse.statusCode == 200) {
          tileResult['source'] = 'INTERNET';
          tileResult['bytes'] = osmResponse.bodyBytes.length;
          LogService().log('TEST [$z/$x/$y] SUCCESS from INTERNET (${osmResponse.bodyBytes.length} bytes)');
        } else {
          tileResult['error'] = 'HTTP ${osmResponse.statusCode}';
          LogService().log('TEST [$z/$x/$y] Internet failed: HTTP ${osmResponse.statusCode}');
          (results['errors'] as List).add('Tile $z/$x/$y: HTTP ${osmResponse.statusCode}');
        }
      } catch (e) {
        tileResult['error'] = e.toString();
        LogService().log('TEST [$z/$x/$y] FAILED: $e');
        (results['errors'] as List).add('Tile $z/$x/$y: $e');
      }

      (results['tiles'] as List).add(tileResult);
    }

    // Summary
    final tiles = results['tiles'] as List;
    final stationCount = tiles.where((t) => t['source'] == 'STATION').length;
    final internetCount = tiles.where((t) => t['source'] == 'INTERNET').length;
    final failedCount = tiles.where((t) => t['error'] != null).length;

    results['success'] = failedCount == 0;
    results['summary'] = {
      'total': tiles.length,
      'fromStation': stationCount,
      'fromInternet': internetCount,
      'failed': failedCount,
    };

    LogService().log('=== TILE FETCH TEST COMPLETE ===');
    LogService().log('Results: ${tiles.length} tiles tested');
    LogService().log('  From STATION: $stationCount');
    LogService().log('  From INTERNET: $internetCount');
    LogService().log('  FAILED: $failedCount');

    if (stationCount == 0 && results['stationUrl'] != null) {
      LogService().log('WARNING: Station URL is configured but NO tiles came from station!');
      LogService().log('This indicates the desktop app is NOT using the station for tiles.');
    }

    return results;
  }

  // ============================================================
  // Offline tile pre-download methods
  // ============================================================

  /// Ensure offline tiles are cached for the current area (background-friendly).
  /// Downloads different radii for different layer types:
  /// - Standard map: 500km (for navigation/overview)
  /// - Satellite + labels: 100km (for detailed location picking)
  Future<void> ensureOfflineTiles({
    required double lat,
    required double lng,
    int minZoom = _offlineCacheMinZoom,
    int maxZoom = _offlineCacheMaxZoom,
  }) async {
    if (kIsWeb) return;
    if (lat.isNaN || lng.isNaN) return;

    if (!_initialized) {
      await initialize();
    }

    try {
      await _networkMonitor.checkNow();
    } catch (e) {
      LogService().log('MapTileService: Network check failed: $e');
    }

    final stationUrlAvailable =
        getStationTileUrl(MapLayerType.standard) != null ||
            getStationTileUrl(MapLayerType.satellite) != null;
    final allowStation = canUseStation && stationUrlAvailable;
    final allowInternet = canUseInternet;
    if (!allowStation && !allowInternet) {
      LogService().log('MapTileService: Offline - skipping tile pre-download');
      return;
    }

    if (_offlineDownloadFuture != null) {
      return;
    }

    _offlineDownloadFuture = () async {
      try {
        int totalDownloaded = 0;

        // Download standard tiles with 500km radius (zoom 8-12)
        totalDownloaded += await _ensureLayerTiles(
          lat: lat,
          lng: lng,
          radiusKm: _offlineCacheRadiusKmStandard,
          minZoom: minZoom,
          maxZoom: maxZoom,
          layer: MapLayerType.standard,
        );

        // Download satellite tiles with 100km radius (zoom 8-12)
        totalDownloaded += await _ensureLayerTiles(
          lat: lat,
          lng: lng,
          radiusKm: _offlineCacheRadiusKmSatellite,
          minZoom: minZoom,
          maxZoom: maxZoom,
          layer: MapLayerType.satellite,
        );

        // Download labels overlays with 100km radius (zoom 8-12)
        totalDownloaded += await _ensureOverlayTiles(
          lat: lat,
          lng: lng,
          radiusKm: _offlineCacheRadiusKmSatellite,
          minZoom: minZoom,
          maxZoom: maxZoom,
        );

        // Download HIGH-ZOOM tiles for immediate area (zoom 13-18)
        // This ensures LocationPickerPage (zoom 18) works offline
        totalDownloaded += await _ensureHighZoomTiles(
          lat: lat,
          lng: lng,
        );

        ConfigService().set('offlineMapPreDownloaded', true);
        LogService().log('MapTileService: Offline cache updated ($totalDownloaded tiles)');
      } catch (e) {
        LogService().log('MapTileService: Offline cache download failed: $e');
      }
    }();

    try {
      await _offlineDownloadFuture!;
    } finally {
      _offlineDownloadFuture = null;
    }
  }

  /// Helper: ensure tiles for a specific layer with its own cache tracking
  Future<int> _ensureLayerTiles({
    required double lat,
    required double lng,
    required double radiusKm,
    required int minZoom,
    required int maxZoom,
    required MapLayerType layer,
  }) async {
    final layerName = layer == MapLayerType.satellite ? 'satellite' : 'standard';
    final configRoot = '${_offlineCacheConfigRoot}_$layerName';
    final config = ConfigService();

    // Check if cache is still valid for this layer
    final lastLatValue = config.getNestedValue('$configRoot.centerLat');
    final lastLonValue = config.getNestedValue('$configRoot.centerLon');
    final lastRadiusValue = config.getNestedValue('$configRoot.radiusKm');
    final lastDownloadedRaw = config.getNestedValue('$configRoot.lastDownloaded') as String?;

    final lastLat = lastLatValue is num ? lastLatValue.toDouble() : null;
    final lastLon = lastLonValue is num ? lastLonValue.toDouble() : null;
    final lastRadius = lastRadiusValue is num ? lastRadiusValue.toDouble() : null;
    final lastDownloaded = lastDownloadedRaw != null ? DateTime.tryParse(lastDownloadedRaw) : null;

    final distanceKm = (lastLat != null && lastLon != null)
        ? _calculateDistanceKm(lat, lng, lastLat, lastLon)
        : double.infinity;
    final movedTooFar = distanceKm.isNaN || distanceKm > _offlineCacheMinMoveKm;
    final radiusOk = (lastRadius ?? 0) >= radiusKm;
    final cacheFresh = lastDownloaded != null &&
        DateTime.now().difference(lastDownloaded) <= _offlineCacheMaxAge;

    if (!movedTooFar && radiusOk && cacheFresh) {
      LogService().log('MapTileService: $layerName cache still valid, skipping');
      return 0;
    }

    LogService().log('MapTileService: Downloading $layerName tiles (${radiusKm}km radius)');

    final downloaded = await downloadTilesForRadius(
      lat: lat,
      lng: lng,
      radiusKm: radiusKm,
      minZoom: minZoom,
      maxZoom: maxZoom,
      layers: [layer],
    );

    // Update config for this layer
    config.setNestedValue('$configRoot.centerLat', lat);
    config.setNestedValue('$configRoot.centerLon', lng);
    config.setNestedValue('$configRoot.radiusKm', radiusKm);
    config.setNestedValue('$configRoot.lastDownloaded', DateTime.now().toIso8601String());

    return downloaded;
  }

  /// Helper: ensure overlay tiles (labels, transport) for satellite view
  Future<int> _ensureOverlayTiles({
    required double lat,
    required double lng,
    required double radiusKm,
    required int minZoom,
    required int maxZoom,
  }) async {
    final configRoot = '${_offlineCacheConfigRoot}_overlays';
    final config = ConfigService();

    // Check if overlay cache is still valid
    final lastLatValue = config.getNestedValue('$configRoot.centerLat');
    final lastLonValue = config.getNestedValue('$configRoot.centerLon');
    final lastRadiusValue = config.getNestedValue('$configRoot.radiusKm');
    final lastDownloadedRaw = config.getNestedValue('$configRoot.lastDownloaded') as String?;

    final lastLat = lastLatValue is num ? lastLatValue.toDouble() : null;
    final lastLon = lastLonValue is num ? lastLonValue.toDouble() : null;
    final lastRadius = lastRadiusValue is num ? lastRadiusValue.toDouble() : null;
    final lastDownloaded = lastDownloadedRaw != null ? DateTime.tryParse(lastDownloadedRaw) : null;

    final distanceKm = (lastLat != null && lastLon != null)
        ? _calculateDistanceKm(lat, lng, lastLat, lastLon)
        : double.infinity;
    final movedTooFar = distanceKm.isNaN || distanceKm > _offlineCacheMinMoveKm;
    final radiusOk = (lastRadius ?? 0) >= radiusKm;
    final cacheFresh = lastDownloaded != null &&
        DateTime.now().difference(lastDownloaded) <= _offlineCacheMaxAge;

    if (!movedTooFar && radiusOk && cacheFresh) {
      LogService().log('MapTileService: overlay cache still valid, skipping');
      return 0;
    }

    LogService().log('MapTileService: Downloading overlay tiles (${radiusKm}km radius)');

    int downloaded = 0;

    // Download labels overlay (place names, boundaries)
    downloaded += await _downloadOverlayTilesForRadius(
      lat: lat,
      lng: lng,
      radiusKm: radiusKm,
      minZoom: minZoom,
      maxZoom: maxZoom,
      urlTemplate: labelsOnlyUrl,
      cacheFolder: 'labels',
    );

    // Download transport labels (road names, route numbers)
    downloaded += await _downloadOverlayTilesForRadius(
      lat: lat,
      lng: lng,
      radiusKm: radiusKm,
      minZoom: minZoom,
      maxZoom: maxZoom,
      urlTemplate: transportLabelsUrl,
      cacheFolder: 'transport',
    );

    // Update config for overlays
    config.setNestedValue('$configRoot.centerLat', lat);
    config.setNestedValue('$configRoot.centerLon', lng);
    config.setNestedValue('$configRoot.radiusKm', radiusKm);
    config.setNestedValue('$configRoot.lastDownloaded', DateTime.now().toIso8601String());

    return downloaded;
  }

  /// Ensure high-zoom tiles (13-18) are cached for immediate area
  /// This is critical for LocationPickerPage which opens at zoom 18
  Future<int> _ensureHighZoomTiles({
    required double lat,
    required double lng,
  }) async {
    final configRoot = '${_offlineCacheConfigRoot}_highzoom';
    final config = ConfigService();

    // Check if high-zoom cache is still valid for this location
    final lastLatValue = config.getNestedValue('$configRoot.centerLat');
    final lastLonValue = config.getNestedValue('$configRoot.centerLon');
    final lastDownloadedRaw = config.getNestedValue('$configRoot.lastDownloaded') as String?;

    final lastLat = lastLatValue is num ? lastLatValue.toDouble() : null;
    final lastLon = lastLonValue is num ? lastLonValue.toDouble() : null;
    final lastDownloaded = lastDownloadedRaw != null ? DateTime.tryParse(lastDownloadedRaw) : null;

    // For high-zoom, we need to re-download if moved more than 1km (since radius is only 5km)
    final distanceKm = (lastLat != null && lastLon != null)
        ? _calculateDistanceKm(lat, lng, lastLat, lastLon)
        : double.infinity;
    final movedTooFar = distanceKm.isNaN || distanceKm > 1.0;
    final cacheFresh = lastDownloaded != null &&
        DateTime.now().difference(lastDownloaded) <= _offlineCacheMaxAge;

    if (!movedTooFar && cacheFresh) {
      LogService().log('MapTileService: high-zoom cache still valid, skipping');
      return 0;
    }

    LogService().log('MapTileService: Downloading high-zoom tiles (zoom $_highZoomMinZoom-$_highZoomMaxZoom, ${_highZoomCacheRadiusKm}km radius)');

    int downloaded = 0;

    // Download both standard and satellite at high zoom for the immediate area
    for (final layer in [MapLayerType.standard, MapLayerType.satellite]) {
      downloaded += await downloadTilesForRadius(
        lat: lat,
        lng: lng,
        radiusKm: _highZoomCacheRadiusKm,
        minZoom: _highZoomMinZoom,
        maxZoom: _highZoomMaxZoom,
        layers: [layer],
      );
    }

    // Also download overlay tiles (labels, transport) at high zoom
    for (int z = _highZoomMinZoom; z <= _highZoomMaxZoom; z++) {
      final tiles = _getTilesInRadius(lat, lng, _highZoomCacheRadiusKm, z);

      for (final tile in tiles) {
        // Labels
        final labelsPath = '$_tilesPath/cache/labels/$z/${tile.x}/${tile.y}.png';
        if (!await File(labelsPath).exists()) {
          try {
            final url = labelsOnlyUrl
                .replaceAll('{z}', z.toString())
                .replaceAll('{x}', tile.x.toString())
                .replaceAll('{y}', tile.y.toString());
            final response = await httpClient.get(Uri.parse(url)).timeout(
              const Duration(seconds: 10),
            );
            if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
              // Validate tile before caching
              if (await validateTileData(response.bodyBytes)) {
                await File(labelsPath).parent.create(recursive: true);
                await File(labelsPath).writeAsBytes(response.bodyBytes);
                downloaded++;
              }
            }
          } catch (_) {}
        }

        // Transport labels
        final transportPath = '$_tilesPath/cache/transport/$z/${tile.x}/${tile.y}.png';
        if (!await File(transportPath).exists()) {
          try {
            final url = transportLabelsUrl
                .replaceAll('{z}', z.toString())
                .replaceAll('{x}', tile.x.toString())
                .replaceAll('{y}', tile.y.toString());
            final response = await httpClient.get(Uri.parse(url)).timeout(
              const Duration(seconds: 10),
            );
            if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
              // Validate tile before caching
              if (await validateTileData(response.bodyBytes)) {
                await File(transportPath).parent.create(recursive: true);
                await File(transportPath).writeAsBytes(response.bodyBytes);
                downloaded++;
              }
            }
          } catch (_) {}
        }
      }
    }

    // Update config for high-zoom cache
    config.setNestedValue('$configRoot.centerLat', lat);
    config.setNestedValue('$configRoot.centerLon', lng);
    config.setNestedValue('$configRoot.lastDownloaded', DateTime.now().toIso8601String());

    LogService().log('MapTileService: High-zoom tiles downloaded: $downloaded');
    return downloaded;
  }

  /// Download overlay tiles for a radius (labels, transport, etc.)
  Future<int> _downloadOverlayTilesForRadius({
    required double lat,
    required double lng,
    required double radiusKm,
    required int minZoom,
    required int maxZoom,
    required String urlTemplate,
    required String cacheFolder,
  }) async {
    if (_tilesPath == null) return 0;

    int downloaded = 0;

    for (int z = minZoom; z <= maxZoom; z++) {
      final tiles = _getTilesInRadius(lat, lng, radiusKm, z);

      for (final tile in tiles) {
        final cachePath = '$_tilesPath/cache/$cacheFolder/$z/${tile.x}/${tile.y}.png';
        final cacheFile = File(cachePath);

        // Skip if already cached
        if (await cacheFile.exists()) continue;

        try {
          final url = urlTemplate
              .replaceAll('{z}', z.toString())
              .replaceAll('{x}', tile.x.toString())
              .replaceAll('{y}', tile.y.toString());

          final response = await httpClient.get(Uri.parse(url)).timeout(
            const Duration(seconds: 10),
          );

          if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
            // Validate tile before caching
            if (await validateTileData(response.bodyBytes)) {
              await cacheFile.parent.create(recursive: true);
              await cacheFile.writeAsBytes(response.bodyBytes);
              downloaded++;
            }
          }
        } catch (e) {
          // Skip failed tiles silently
        }
      }
    }

    return downloaded;
  }

  /// Pre-download tiles for offline use within a radius
  /// [lat], [lng] - center coordinates
  /// [radiusKm] - radius in kilometers (default: 100)
  /// [minZoom], [maxZoom] - zoom levels to download (default: 8-12)
  /// [layers] - which layers to download (default: both standard and satellite)
  /// [onProgress] - optional progress callback
  /// Returns the number of tiles successfully downloaded
  Future<int> downloadTilesForRadius({
    required double lat,
    required double lng,
    double radiusKm = 100,
    int minZoom = 8,
    int maxZoom = 12,
    List<MapLayerType> layers = const [MapLayerType.standard, MapLayerType.satellite],
    void Function(int downloaded, int total)? onProgress,
    void Function(int downloaded, int total, int skipped)? onProgressWithSkipped,
    int? maxAgeDays,
  }) async {
    if (!_initialized) await initialize();
    if (kIsWeb) return 0; // No caching on web

    final stationUrlAvailable =
        getStationTileUrl(MapLayerType.standard) != null ||
            getStationTileUrl(MapLayerType.satellite) != null;
    final allowStation = canUseStation && stationUrlAvailable;
    final allowInternet = canUseInternet;
    if (!allowStation && !allowInternet) {
      LogService().log('MapTileService: Offline - skipping pre-download');
      return 0;
    }

    int downloaded = 0;
    int skipped = 0;
    final tilesToDownload = <({int z, int x, int y, MapLayerType layer})>[];

    // Calculate tiles for each zoom level
    for (int z = minZoom; z <= maxZoom; z++) {
      final tiles = _getTilesInRadius(lat, lng, radiusKm, z);
      for (final tile in tiles) {
        for (final layer in layers) {
          tilesToDownload.add((z: z, x: tile.x, y: tile.y, layer: layer));
        }
      }
    }

    final total = tilesToDownload.length;
    LogService().log('MapTileService: Pre-downloading $total tiles for ${radiusKm}km radius (via priority queue)');

    // Download tiles via priority queue (low priority for background downloads)
    // This allows live UI tile requests to jump ahead in the queue
    for (final tile in tilesToDownload) {
      try {
        final result = await _enqueueDownload(_TileRequest(
          z: tile.z,
          x: tile.x,
          y: tile.y,
          layer: tile.layer,
          priority: _TilePriority.low,
          maxAgeDays: maxAgeDays ?? 90,
        ));
        if (result == _TileDownloadResult.downloaded) {
          downloaded++;
        } else if (result == _TileDownloadResult.skipped) {
          skipped++;
        }
        onProgress?.call(downloaded + skipped, total);
        onProgressWithSkipped?.call(downloaded + skipped, total, skipped);
      } catch (e) {
        // Log but continue - non-critical
        LogService().log('MapTileService: Failed to cache tile ${tile.z}/${tile.x}/${tile.y}: $e');
      }
    }

    LogService().log('MapTileService: Pre-download complete: $downloaded downloaded, $skipped skipped, total $total');
    return downloaded;
  }

  /// Start a background download that persists across UI navigation
  /// Updates downloadProgressNotifier with progress
  void startBackgroundDownload({
    required double lat,
    required double lng,
    required double satelliteRadiusKm,
    required int satelliteMaxZoom,
    required double standardRadiusKm,
    required int standardMaxZoom,
    required int maxAgeMonths,
  }) {
    // Don't start if already downloading
    if (downloadProgressNotifier.value.isDownloading) return;

    // Reset progress
    downloadProgressNotifier.value = const TileDownloadProgress(isDownloading: true);

    // Run download in background
    _runBackgroundDownload(
      lat: lat,
      lng: lng,
      satelliteRadiusKm: satelliteRadiusKm,
      satelliteMaxZoom: satelliteMaxZoom,
      standardRadiusKm: standardRadiusKm,
      standardMaxZoom: standardMaxZoom,
      maxAgeMonths: maxAgeMonths,
    );
  }

  Future<void> _runBackgroundDownload({
    required double lat,
    required double lng,
    required double satelliteRadiusKm,
    required int satelliteMaxZoom,
    required double standardRadiusKm,
    required int standardMaxZoom,
    required int maxAgeMonths,
  }) async {
    try {
      final maxAgeDays = maxAgeMonths * 30;
      int totalDownloaded = 0;
      int totalSkipped = 0;

      // Download satellite tiles
      final satelliteTiles = await downloadTilesForRadius(
        lat: lat,
        lng: lng,
        radiusKm: satelliteRadiusKm,
        minZoom: 8,
        maxZoom: satelliteMaxZoom,
        layers: [MapLayerType.satellite],
        maxAgeDays: maxAgeDays,
        onProgressWithSkipped: (downloaded, total, skipped) {
          downloadProgressNotifier.value = TileDownloadProgress(
            isDownloading: true,
            downloadedTiles: downloaded,
            totalTiles: total,
            skippedTiles: skipped,
          );
        },
      );
      totalDownloaded += satelliteTiles;

      // Download standard map tiles
      final standardTiles = await downloadTilesForRadius(
        lat: lat,
        lng: lng,
        radiusKm: standardRadiusKm,
        minZoom: 8,
        maxZoom: standardMaxZoom,
        layers: [MapLayerType.standard],
        maxAgeDays: maxAgeDays,
        onProgressWithSkipped: (downloaded, total, skipped) {
          downloadProgressNotifier.value = TileDownloadProgress(
            isDownloading: true,
            downloadedTiles: satelliteTiles + downloaded,
            totalTiles: satelliteTiles + total,
            skippedTiles: totalSkipped + skipped,
          );
          totalSkipped = skipped;
        },
      );
      totalDownloaded += standardTiles;

      // Download complete
      downloadProgressNotifier.value = TileDownloadProgress(
        isDownloading: false,
        downloadedTiles: totalDownloaded,
        totalTiles: downloadProgressNotifier.value.totalTiles,
        skippedTiles: totalSkipped,
      );

      LogService().log('MapTileService: Background download complete: $totalDownloaded tiles');
    } catch (e) {
      downloadProgressNotifier.value = TileDownloadProgress(
        isDownloading: false,
        error: e.toString(),
      );
      LogService().log('MapTileService: Background download failed: $e');
    }
  }

  /// Get cache statistics (size in bytes and tile count)
  /// Runs in an isolate to avoid blocking the UI
  Future<Map<String, int>> getCacheStatistics() async {
    if (!_initialized) await initialize();
    if (_tilesPath == null || kIsWeb) {
      return {'sizeBytes': 0, 'tileCount': 0};
    }

    final cachePath = '$_tilesPath/cache';
    // Run in isolate to avoid blocking UI
    return await compute(_computeCacheStatistics, cachePath);
  }

  /// Static function to compute cache statistics in an isolate
  static Future<Map<String, int>> _computeCacheStatistics(String cachePath) async {
    int totalSize = 0;
    int tileCount = 0;

    final cacheDir = Directory(cachePath);
    if (await cacheDir.exists()) {
      await for (final entity in cacheDir.list(recursive: true)) {
        if (entity is File && entity.path.endsWith('.png')) {
          try {
            final stat = await entity.stat();
            totalSize += stat.size;
            tileCount++;
          } catch (e) {
            // Skip files we can't stat
          }
        }
      }
    }

    return {'sizeBytes': totalSize, 'tileCount': tileCount};
  }

  double _calculateDistanceKm(double lat1, double lon1, double lat2, double lon2) {
    const earthRadiusKm = 6371.0;
    final dLat = _degToRad(lat2 - lat1);
    final dLon = _degToRad(lon2 - lon1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_degToRad(lat1)) *
            math.cos(_degToRad(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadiusKm * c;
  }

  double _degToRad(double degrees) => degrees * (math.pi / 180.0);

  /// Calculate all tile coordinates within a radius for a given zoom level
  List<({int x, int y})> _getTilesInRadius(double lat, double lng, double radiusKm, int zoom) {
    final tiles = <({int x, int y})>[];
    final n = 1 << zoom; // 2^zoom

    // Calculate center tile using Web Mercator projection
    final centerX = ((lng + 180.0) / 360.0 * n).floor();
    final latRad = lat * math.pi / 180.0;
    final centerY = ((1.0 - (_asinh(math.tan(latRad)) / math.pi)) / 2.0 * n).floor();

    // Calculate tile size in km at this latitude (approximate)
    // Earth circumference at this latitude / number of tiles
    final tileSizeKm = 40075.0 * math.cos(latRad) / n;

    // Calculate how many tiles we need in each direction
    final tilesNeeded = tileSizeKm > 0 ? (radiusKm / tileSizeKm).ceil() + 1 : 1;

    // Generate tile list within bounds
    for (int dx = -tilesNeeded; dx <= tilesNeeded; dx++) {
      for (int dy = -tilesNeeded; dy <= tilesNeeded; dy++) {
        final x = centerX + dx;
        final y = centerY + dy;
        // Validate tile coordinates are within valid range
        if (x >= 0 && x < n && y >= 0 && y < n) {
          tiles.add((x: x, y: y));
        }
      }
    }

    return tiles;
  }

  /// Get the file path for a cached tile
  String _getCachePath(int z, int x, int y, MapLayerType layer) {
    final layerFolder = layer == MapLayerType.satellite ? 'satellite' : 'standard';
    return '$_tilesPath/cache/$layerFolder/$z/$x/$y.png';
  }

  /// Download a single tile with age checking
  /// Returns result indicating whether tile was downloaded, skipped (cached), or failed
  Future<_TileDownloadResult> _downloadAndCacheTileWithAge(
    int z,
    int x,
    int y,
    MapLayerType layer, {
    int? maxAgeDays,
  }) async {
    if (_tilesPath == null) return _TileDownloadResult.failed;

    final cachePath = _getCachePath(z, x, y, layer);
    final file = File(cachePath);

    // Check if already cached and fresh
    if (await file.exists()) {
      if (maxAgeDays == null || maxAgeDays <= 0) {
        // Force refresh - always re-download
      } else {
        // Check file age
        try {
          final stat = await file.stat();
          final age = DateTime.now().difference(stat.modified);
          if (age.inDays < maxAgeDays) {
            return _TileDownloadResult.skipped; // Fresh enough, skip
          }
        } catch (e) {
          // Can't check age, assume fresh
          return _TileDownloadResult.skipped;
        }
      }
    }

    final allowStation = canUseStation;
    final allowInternet = canUseInternet;
    if (!allowStation && !allowInternet) {
      return _TileDownloadResult.failed;
    }

    // Build tile URL based on layer
    String directUrl;
    if (layer == MapLayerType.satellite) {
      // Esri uses z/y/x order
      directUrl = satelliteTileUrl
          .replaceAll('{z}', '$z')
          .replaceAll('{y}', '$y')
          .replaceAll('{x}', '$x');
    } else {
      // OSM uses z/x/y order
      directUrl = osmTileUrl
          .replaceAll('{z}', '$z')
          .replaceAll('{x}', '$x')
          .replaceAll('{y}', '$y');
    }

    // Try station first if available
    if (allowStation) {
      final stationUrl = getStationTileUrl(layer);
      if (stationUrl != null) {
        try {
          final url = stationUrl
              .replaceAll('{z}', '$z')
              .replaceAll('{x}', '$x')
              .replaceAll('{y}', '$y');
          final response = await httpClient
              .get(Uri.parse(url))
              .timeout(const Duration(seconds: 5));
          if (response.statusCode == 200 && response.bodyBytes.length > 100) {
            // Validate tile before caching
            if (await validateTileData(response.bodyBytes)) {
              await file.parent.create(recursive: true);
              await file.writeAsBytes(response.bodyBytes);
              return _TileDownloadResult.downloaded;
            }
          }
        } catch (_) {
          // Station failed, try direct internet
        }
      }
    }

    // Fallback to direct internet
    if (allowInternet) {
      try {
        final response = await httpClient
            .get(Uri.parse(directUrl), headers: {'User-Agent': 'dev.geogram'})
            .timeout(const Duration(seconds: 10));

        if (response.statusCode == 200 && response.bodyBytes.length > 100) {
          // Validate tile before caching
          if (await validateTileData(response.bodyBytes)) {
            await file.parent.create(recursive: true);
            await file.writeAsBytes(response.bodyBytes);
            return _TileDownloadResult.downloaded;
          }
        }
      } catch (e) {
        LogService().log('MapTileService: Direct download failed for $z/$x/$y: $e');
      }
    }

    return _TileDownloadResult.failed;
  }
}

/// Custom tile provider with fallback logic:
/// 1. Check cache first
/// 2. Try station if available (standard layer only)
/// 3. Fall back to direct internet (OSM or Esri satellite)
class GeogramTileProvider extends TileProvider {
  final MapTileService mapTileService;
  final MapLayerType layerType;

  GeogramTileProvider({
    required this.mapTileService,
    required this.layerType,
  });

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    return GeogramTileImageProvider(
      coordinates: coordinates,
      options: options,
      mapTileService: mapTileService,
      httpClient: mapTileService.httpClient, // Use shared client
      layerType: layerType,
    );
  }
}

/// Custom image provider that implements the fallback logic
class GeogramTileImageProvider extends ImageProvider<GeogramTileImageProvider> {
  final TileCoordinates coordinates;
  final TileLayer options;
  final MapTileService mapTileService;
  final http.Client httpClient;
  final MapLayerType layerType;

  GeogramTileImageProvider({
    required this.coordinates,
    required this.options,
    required this.mapTileService,
    required this.httpClient,
    required this.layerType,
  });

  @override
  Future<GeogramTileImageProvider> obtainKey(ImageConfiguration configuration) {
    return Future.value(this);
  }

  @override
  ImageStreamCompleter loadImage(
    GeogramTileImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _loadTileWithFallback(decode),
      scale: 1.0,
    );
  }

  /// Get the file path for a cached tile (separated by layer type)
  String _getTileCachePath(int z, int x, int y) {
    final tilesPath = mapTileService.tilesPath;
    final layerFolder = layerType == MapLayerType.satellite ? 'satellite' : 'standard';
    return '$tilesPath/cache/$layerFolder/$z/$x/$y.png';
  }

  /// 1x1 transparent PNG for failed tiles (valid minimal PNG)
  static final Uint8List _transparentTile = Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR length + type
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, // 1x1 dimensions
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, // RGBA, CRC
    0x00, 0x00, 0x00, 0x0B, 0x49, 0x44, 0x41, 0x54, // IDAT length + type
    0x78, 0x9C, 0x63, 0x60, 0x00, 0x02, 0x00, 0x00, 0x05, 0x00, 0x01, // zlib data
    0x69, 0x60, 0x19, 0x7A, // IDAT CRC
    0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, // IEND
    0xAE, 0x42, 0x60, 0x82, // IEND CRC
  ]);

  /// Check if data looks like a valid image (PNG or JPEG header)
  static bool _isValidImageData(Uint8List data) {
    if (data.length < 8) return false;
    // Check PNG signature
    if (data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47) {
      return true;
    }
    // Check JPEG signature
    if (data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF) {
      return true;
    }
    return false;
  }

  /// Load tile with priority: Cache -> Station -> Internet
  /// Fails fast on network errors for offline operation
  Future<ui.Codec> _loadTileWithFallback(ImageDecoderCallback decode) async {
    final z = coordinates.z.toInt();
    final x = coordinates.x.toInt();
    final y = coordinates.y.toInt();

    bool needsNetworkFetch = true;

    // Helper to safely decode transparent tile - never throws
    Future<ui.Codec> safeTransparent() async {
      try {
        final buffer = await ui.ImmutableBuffer.fromUint8List(_transparentTile);
        final codec = await decode(buffer);
        // Validate codec by getting first frame
        await codec.getNextFrame();
        return codec;
      } catch (e) {
        // Even transparent tile failed - create minimal 1x1 image
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        canvas.drawRect(
          const ui.Rect.fromLTWH(0, 0, 1, 1),
          ui.Paint()..color = const ui.Color(0x00000000),
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(1, 1);
        return await image.toByteData(format: ui.ImageByteFormat.png).then(
          (data) async {
            final buffer = await ui.ImmutableBuffer.fromUint8List(data!.buffer.asUint8List());
            return decode(buffer);
          },
        );
      }
    }

    // Helper to validate codec by decompressing first frame
    Future<ui.Codec?> validateCodec(ui.Codec codec) async {
      try {
        await codec.getNextFrame();
        return codec;
      } catch (e) {
        return null;
      }
    }

    try {
      // 1. Try file cache first (ALWAYS check cache before network)
      try {
        final cachePath = _getTileCachePath(z, x, y);
        final cacheFile = File(cachePath);
        if (await cacheFile.exists()) {
          final cachedBytes = Uint8List.fromList(await cacheFile.readAsBytes());
          if (cachedBytes.isNotEmpty && _isValidImageData(cachedBytes)) {
            // Cache hit with valid image - try to decode AND validate
            try {
              final buffer = await ui.ImmutableBuffer.fromUint8List(cachedBytes);
              final codec = await decode(buffer);
              // Validate by decompressing first frame
              final validated = await validateCodec(codec);
              if (validated != null) {
                needsNetworkFetch = false;
                // Re-decode since we consumed the frame
                final buffer2 = await ui.ImmutableBuffer.fromUint8List(cachedBytes);
                return decode(buffer2);
              } else {
                // Validation failed - delete corrupt cache
                await cacheFile.delete();
                LogService().log('TILE [$z/$x/$y] Corrupt cache deleted (validation failed)');
              }
            } catch (e) {
              // Decode failed - cached data is corrupt, delete it
              await cacheFile.delete();
              LogService().log('TILE [$z/$x/$y] Corrupt cache deleted');
            }
          } else {
            // Invalid cached data, delete it
            await cacheFile.delete();
          }
        }
      } catch (e) {
        // Cache miss or error, continue to next source
      }

      final allowStation = mapTileService.canUseStation;
      final allowInternet = mapTileService.canUseInternet;

      // If offline and no cache, return transparent immediately
      if (needsNetworkFetch && !allowStation && !allowInternet) {
        return safeTransparent();
      }

      // Network fetch needed - use priority queue with HIGH priority
      // This ensures live UI tile requests jump ahead of background downloads
      if (needsNetworkFetch) {
        mapTileService._startLoading();
      }

      try {
        // 2. Enqueue download with HIGH priority (jumps ahead of background downloads)
        final downloadResult = await mapTileService._enqueueDownload(_TileRequest(
          z: z,
          x: x,
          y: y,
          layer: layerType,
          priority: _TilePriority.high,
          maxAgeDays: 90,  // Use default age for live requests
        ));

        // 3. After queue processes, tile should be in cache - read and decode
        if (downloadResult == _TileDownloadResult.downloaded ||
            downloadResult == _TileDownloadResult.skipped) {
          final cachePath = _getTileCachePath(z, x, y);
          final cacheFile = File(cachePath);
          if (await cacheFile.exists()) {
            final cachedBytes = Uint8List.fromList(await cacheFile.readAsBytes());
            if (cachedBytes.isNotEmpty && _isValidImageData(cachedBytes)) {
              try {
                final buffer = await ui.ImmutableBuffer.fromUint8List(cachedBytes);
                final codec = await decode(buffer);
                final validated = await validateCodec(codec);
                if (validated != null) {
                  final buffer2 = await ui.ImmutableBuffer.fromUint8List(cachedBytes);
                  return decode(buffer2);
                }
              } catch (e) {
                // Decode failed
              }
            }
          }
        }

        // Download or decode failed - return transparent placeholder
        mapTileService._recordFailure();
        return safeTransparent();
      } finally {
        if (needsNetworkFetch) {
          mapTileService._finishLoading();
        }
      }
    } catch (e) {
      // Catch-all: any unhandled exception returns transparent
      return safeTransparent();
    }
  }

  @override
  bool operator ==(Object other) {
    if (other is GeogramTileImageProvider) {
      return coordinates == other.coordinates && layerType == other.layerType;
    }
    return false;
  }

  @override
  int get hashCode => Object.hash(coordinates, layerType);
}

/// Custom tile provider for labels overlay (city names, roads, etc.)
class GeogramLabelsTileProvider extends TileProvider {
  final MapTileService mapTileService;

  GeogramLabelsTileProvider({
    required this.mapTileService,
  });

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    return GeogramLabelsImageProvider(
      coordinates: coordinates,
      mapTileService: mapTileService,
      httpClient: mapTileService.httpClient, // Use shared client
    );
  }
}

/// Custom image provider for labels overlay tiles with caching
class GeogramLabelsImageProvider extends ImageProvider<GeogramLabelsImageProvider> {
  final TileCoordinates coordinates;
  final MapTileService mapTileService;
  final http.Client httpClient;

  GeogramLabelsImageProvider({
    required this.coordinates,
    required this.mapTileService,
    required this.httpClient,
  });

  @override
  Future<GeogramLabelsImageProvider> obtainKey(ImageConfiguration configuration) {
    return Future.value(this);
  }

  @override
  ImageStreamCompleter loadImage(
    GeogramLabelsImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _loadLabelsTile(decode),
      scale: 1.0,
    );
  }

  /// Get the file path for cached labels tiles
  String _getLabelsCachePath(int z, int x, int y) {
    final tilesPath = mapTileService.tilesPath;
    return '$tilesPath/cache/labels/$z/$x/$y.png';
  }

  /// 1x1 transparent PNG for failed tiles (valid minimal PNG)
  static final Uint8List _transparentTile = Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR length + type
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, // 1x1 dimensions
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, // RGBA, CRC
    0x00, 0x00, 0x00, 0x0B, 0x49, 0x44, 0x41, 0x54, // IDAT length + type
    0x78, 0x9C, 0x63, 0x60, 0x00, 0x02, 0x00, 0x00, 0x05, 0x00, 0x01, // zlib data
    0x69, 0x60, 0x19, 0x7A, // IDAT CRC
    0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, // IEND
    0xAE, 0x42, 0x60, 0x82, // IEND CRC
  ]);

  /// Check if data looks like a valid image (PNG or JPEG header)
  static bool _isValidImageData(Uint8List data) {
    if (data.length < 8) return false;
    // Check PNG signature
    if (data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47) {
      return true;
    }
    // Check JPEG signature
    if (data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF) {
      return true;
    }
    return false;
  }

  Future<ui.Codec> _loadLabelsTile(ImageDecoderCallback decode) async {
    final z = coordinates.z.toInt();
    final x = coordinates.x.toInt();
    final y = coordinates.y.toInt();
    Uint8List? tileData;

    // Helper to safely return transparent tile
    Future<ui.Codec> safeTransparent() async {
      try {
        final buffer = await ui.ImmutableBuffer.fromUint8List(_transparentTile);
        final codec = await decode(buffer);
        await codec.getNextFrame(); // Validate
        return codec;
      } catch (e) {
        // Last resort - create image programmatically
        final recorder = ui.PictureRecorder();
        ui.Canvas(recorder).drawRect(
          const ui.Rect.fromLTWH(0, 0, 1, 1),
          ui.Paint()..color = const ui.Color(0x00000000),
        );
        final image = await recorder.endRecording().toImage(1, 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final buffer = await ui.ImmutableBuffer.fromUint8List(data!.buffer.asUint8List());
        return decode(buffer);
      }
    }

    // Helper to validate codec
    Future<bool> validateCodec(ui.Codec codec) async {
      try {
        await codec.getNextFrame();
        return true;
      } catch (e) {
        return false;
      }
    }

    try {
      // 1. Try file cache first
      try {
        final cachePath = _getLabelsCachePath(z, x, y);
        final cacheFile = File(cachePath);
        if (await cacheFile.exists()) {
          final cachedBytes = Uint8List.fromList(await cacheFile.readAsBytes());
          if (cachedBytes.isNotEmpty && _isValidImageData(cachedBytes)) {
            try {
              final buffer = await ui.ImmutableBuffer.fromUint8List(cachedBytes);
              final codec = await decode(buffer);
              if (await validateCodec(codec)) {
                final buffer2 = await ui.ImmutableBuffer.fromUint8List(cachedBytes);
                return decode(buffer2);
              } else {
                await cacheFile.delete();
              }
            } catch (e) {
              // Corrupted cache, delete and re-fetch
              await cacheFile.delete();
            }
          } else {
            // Invalid cache data, delete it
            await cacheFile.delete();
          }
        }
      } catch (e) {
        // Cache miss, continue to network
      }

      if (!mapTileService.canUseInternet) {
        return safeTransparent();
      }

      // 2. Fetch from network - Esri uses z/y/x order
      try {
        final url = MapTileService.labelsOnlyUrl
            .replaceAll('{z}', z.toString())
            .replaceAll('{y}', y.toString())
            .replaceAll('{x}', x.toString());

        final response = await httpClient
            .get(
              Uri.parse(url),
              headers: {'User-Agent': 'dev.geogram'},
            )
            .timeout(const Duration(seconds: 10));

        if (response.statusCode == 200 && _isValidImageData(response.bodyBytes)) {
          tileData = response.bodyBytes;
          // Cache the tile
          await _cacheLabelsTile(z, x, y, tileData);
        }
      } catch (e) {
        // Network failed
      }

      // 3. Also fetch transport labels for detailed road names at higher zoom levels
      if (z >= 10 && tileData != null) {
        _prefetchTransportLabels(z, x, y);
      }

      if (tileData == null || tileData.isEmpty || !_isValidImageData(tileData)) {
        return safeTransparent();
      }

      try {
        final buffer = await ui.ImmutableBuffer.fromUint8List(tileData);
        final codec = await decode(buffer);
        if (await validateCodec(codec)) {
          final buffer2 = await ui.ImmutableBuffer.fromUint8List(tileData);
          return decode(buffer2);
        }
        return safeTransparent();
      } catch (e) {
        return safeTransparent();
      }
    } catch (e) {
      return safeTransparent();
    }
  }

  Future<void> _cacheLabelsTile(int z, int x, int y, Uint8List data) async {
    try {
      final cachePath = _getLabelsCachePath(z, x, y);
      final cacheFile = File(cachePath);
      final cacheDir = cacheFile.parent;
      if (!await cacheDir.exists()) {
        await cacheDir.create(recursive: true);
      }
      await cacheFile.writeAsBytes(data);
    } catch (e) {
      // Silently ignore
    }
  }

  /// Prefetch transport labels (road names, route numbers) for higher zoom levels
  void _prefetchTransportLabels(int z, int x, int y) async {
    try {
      final tilesPath = mapTileService.tilesPath;
      final cachePath = '$tilesPath/cache/transport/$z/$x/$y.png';
      final cacheFile = File(cachePath);

      // Skip if already cached
      if (await cacheFile.exists()) return;

      final url = MapTileService.transportLabelsUrl
          .replaceAll('{z}', z.toString())
          .replaceAll('{y}', y.toString())
          .replaceAll('{x}', x.toString());

      final response = await httpClient
          .get(Uri.parse(url), headers: {'User-Agent': 'dev.geogram'})
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        // Validate tile before caching
        if (await MapTileService.validateTileData(response.bodyBytes)) {
          final cacheDir = cacheFile.parent;
          if (!await cacheDir.exists()) {
            await cacheDir.create(recursive: true);
          }
          await cacheFile.writeAsBytes(response.bodyBytes);
        }
      }
    } catch (e) {
      // Silently ignore prefetch failures
    }
  }

  @override
  bool operator ==(Object other) {
    if (other is GeogramLabelsImageProvider) {
      return coordinates == other.coordinates;
    }
    return false;
  }

  @override
  int get hashCode => coordinates.hashCode;
}

/// Custom tile provider for transport labels (road names, route numbers)
class GeogramTransportLabelsTileProvider extends TileProvider {
  final MapTileService mapTileService;

  GeogramTransportLabelsTileProvider({
    required this.mapTileService,
  });

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    return GeogramTransportLabelsImageProvider(
      coordinates: coordinates,
      mapTileService: mapTileService,
      httpClient: mapTileService.httpClient, // Use shared client
    );
  }
}

/// Custom image provider for transport labels tiles with caching
class GeogramTransportLabelsImageProvider extends ImageProvider<GeogramTransportLabelsImageProvider> {
  final TileCoordinates coordinates;
  final MapTileService mapTileService;
  final http.Client httpClient;

  GeogramTransportLabelsImageProvider({
    required this.coordinates,
    required this.mapTileService,
    required this.httpClient,
  });

  @override
  Future<GeogramTransportLabelsImageProvider> obtainKey(ImageConfiguration configuration) {
    return Future.value(this);
  }

  @override
  ImageStreamCompleter loadImage(
    GeogramTransportLabelsImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _loadTransportLabelsTile(decode),
      scale: 1.0,
    );
  }

  String _getTransportCachePath(int z, int x, int y) {
    final tilesPath = mapTileService.tilesPath;
    return '$tilesPath/cache/transport/$z/$x/$y.png';
  }

  /// 1x1 transparent PNG for failed tiles (valid minimal PNG)
  static final Uint8List _transparentTile = Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR length + type
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, // 1x1 dimensions
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, // RGBA, CRC
    0x00, 0x00, 0x00, 0x0B, 0x49, 0x44, 0x41, 0x54, // IDAT length + type
    0x78, 0x9C, 0x63, 0x60, 0x00, 0x02, 0x00, 0x00, 0x05, 0x00, 0x01, // zlib data
    0x69, 0x60, 0x19, 0x7A, // IDAT CRC
    0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, // IEND
    0xAE, 0x42, 0x60, 0x82, // IEND CRC
  ]);

  /// Check if data looks like a valid image (PNG or JPEG header)
  static bool _isValidImageData(Uint8List data) {
    if (data.length < 8) return false;
    if (data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47) return true;
    if (data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF) return true;
    return false;
  }

  Future<ui.Codec> _loadTransportLabelsTile(ImageDecoderCallback decode) async {
    final z = coordinates.z.toInt();
    final x = coordinates.x.toInt();
    final y = coordinates.y.toInt();
    Uint8List? tileData;

    // Helper to safely return transparent tile
    Future<ui.Codec> safeTransparent() async {
      try {
        final buffer = await ui.ImmutableBuffer.fromUint8List(_transparentTile);
        final codec = await decode(buffer);
        await codec.getNextFrame();
        return codec;
      } catch (e) {
        final recorder = ui.PictureRecorder();
        ui.Canvas(recorder).drawRect(
          const ui.Rect.fromLTWH(0, 0, 1, 1),
          ui.Paint()..color = const ui.Color(0x00000000),
        );
        final image = await recorder.endRecording().toImage(1, 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final buffer = await ui.ImmutableBuffer.fromUint8List(data!.buffer.asUint8List());
        return decode(buffer);
      }
    }

    Future<bool> validateCodec(ui.Codec codec) async {
      try {
        await codec.getNextFrame();
        return true;
      } catch (e) {
        return false;
      }
    }

    try {
      // 1. Try file cache first
      try {
        final cachePath = _getTransportCachePath(z, x, y);
        final cacheFile = File(cachePath);
        if (await cacheFile.exists()) {
          final cachedBytes = Uint8List.fromList(await cacheFile.readAsBytes());
          if (cachedBytes.isNotEmpty && _isValidImageData(cachedBytes)) {
            try {
              final buffer = await ui.ImmutableBuffer.fromUint8List(cachedBytes);
              final codec = await decode(buffer);
              if (await validateCodec(codec)) {
                final buffer2 = await ui.ImmutableBuffer.fromUint8List(cachedBytes);
                return decode(buffer2);
              } else {
                await cacheFile.delete();
              }
            } catch (e) {
              // Corrupted cache, delete and re-fetch
              await cacheFile.delete();
            }
          } else {
            await cacheFile.delete();
          }
        }
      } catch (e) {
        // Cache miss
      }

      if (!mapTileService.canUseInternet) {
        return safeTransparent();
      }

      // 2. Fetch from network - Esri uses z/y/x order
      try {
        final url = MapTileService.transportLabelsUrl
            .replaceAll('{z}', z.toString())
            .replaceAll('{y}', y.toString())
            .replaceAll('{x}', x.toString());

        final response = await httpClient
            .get(Uri.parse(url), headers: {'User-Agent': 'dev.geogram'})
            .timeout(const Duration(seconds: 10));

        if (response.statusCode == 200 && _isValidImageData(response.bodyBytes)) {
          tileData = response.bodyBytes;
          // Cache the tile
          await _cacheTransportTile(z, x, y, tileData);
        }
      } catch (e) {
        // Network failed
      }

      if (tileData == null || tileData.isEmpty || !_isValidImageData(tileData)) {
        return safeTransparent();
      }

      try {
        final buffer = await ui.ImmutableBuffer.fromUint8List(tileData);
        final codec = await decode(buffer);
        if (await validateCodec(codec)) {
          final buffer2 = await ui.ImmutableBuffer.fromUint8List(tileData);
          return decode(buffer2);
        }
        return safeTransparent();
      } catch (e) {
        return safeTransparent();
      }
    } catch (e) {
      return safeTransparent();
    }
  }

  Future<void> _cacheTransportTile(int z, int x, int y, Uint8List data) async {
    try {
      final cachePath = _getTransportCachePath(z, x, y);
      final cacheFile = File(cachePath);
      final cacheDir = cacheFile.parent;
      if (!await cacheDir.exists()) {
        await cacheDir.create(recursive: true);
      }
      await cacheFile.writeAsBytes(data);
    } catch (e) {
      // Silently ignore
    }
  }

  @override
  bool operator ==(Object other) {
    if (other is GeogramTransportLabelsImageProvider) {
      return coordinates == other.coordinates;
    }
    return false;
  }

  @override
  int get hashCode => coordinates.hashCode;
}

/// Custom tile provider for country/region borders
class GeogramBordersTileProvider extends TileProvider {
  final MapTileService mapTileService;

  GeogramBordersTileProvider({
    required this.mapTileService,
  });

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    return GeogramBordersImageProvider(
      coordinates: coordinates,
      mapTileService: mapTileService,
      httpClient: mapTileService.httpClient, // Use shared client
    );
  }
}

/// Custom image provider for borders tiles with caching
class GeogramBordersImageProvider extends ImageProvider<GeogramBordersImageProvider> {
  final TileCoordinates coordinates;
  final MapTileService mapTileService;
  final http.Client httpClient;

  GeogramBordersImageProvider({
    required this.coordinates,
    required this.mapTileService,
    required this.httpClient,
  });

  @override
  Future<GeogramBordersImageProvider> obtainKey(ImageConfiguration configuration) {
    return Future.value(this);
  }

  @override
  ImageStreamCompleter loadImage(
    GeogramBordersImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _loadBordersTile(decode),
      scale: 1.0,
    );
  }

  String _getBordersCachePath(int z, int x, int y) {
    final tilesPath = mapTileService.tilesPath;
    return '$tilesPath/cache/borders/$z/$x/$y.png';
  }

  /// 1x1 transparent PNG for failed tiles (valid minimal PNG)
  static final Uint8List _transparentTile = Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR length + type
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, // 1x1 dimensions
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, // RGBA, CRC
    0x00, 0x00, 0x00, 0x0B, 0x49, 0x44, 0x41, 0x54, // IDAT length + type
    0x78, 0x9C, 0x63, 0x60, 0x00, 0x02, 0x00, 0x00, 0x05, 0x00, 0x01, // zlib data
    0x69, 0x60, 0x19, 0x7A, // IDAT CRC
    0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, // IEND
    0xAE, 0x42, 0x60, 0x82, // IEND CRC
  ]);

  /// Check if data looks like a valid image (PNG or JPEG header)
  static bool _isValidImageData(Uint8List data) {
    if (data.length < 8) return false;
    if (data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47) return true;
    if (data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF) return true;
    return false;
  }

  Future<ui.Codec> _loadBordersTile(ImageDecoderCallback decode) async {
    final z = coordinates.z.toInt();
    final x = coordinates.x.toInt();
    final y = coordinates.y.toInt();
    Uint8List? tileData;

    // Helper to safely return transparent tile
    Future<ui.Codec> safeTransparent() async {
      try {
        final buffer = await ui.ImmutableBuffer.fromUint8List(_transparentTile);
        return decode(buffer);
      } catch (e) {
        final recorder = ui.PictureRecorder();
        ui.Canvas(recorder).drawRect(
          const ui.Rect.fromLTWH(0, 0, 1, 1),
          ui.Paint()..color = const ui.Color(0x00000000),
        );
        final image = await recorder.endRecording().toImage(1, 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final buffer = await ui.ImmutableBuffer.fromUint8List(data!.buffer.asUint8List());
        return decode(buffer);
      }
    }

    Future<bool> validateCodec(ui.Codec codec) async {
      try {
        await codec.getNextFrame();
        return true;
      } catch (e) {
        return false;
      }
    }

    try {
      // 1. Try file cache first
      try {
        final cachePath = _getBordersCachePath(z, x, y);
        final cacheFile = File(cachePath);
        if (await cacheFile.exists()) {
          final cachedBytes = Uint8List.fromList(await cacheFile.readAsBytes());
          if (cachedBytes.isNotEmpty && _isValidImageData(cachedBytes)) {
            try {
              final buffer = await ui.ImmutableBuffer.fromUint8List(cachedBytes);
              final codec = await decode(buffer);
              if (await validateCodec(codec)) {
                final buffer2 = await ui.ImmutableBuffer.fromUint8List(cachedBytes);
                return decode(buffer2);
              } else {
                await cacheFile.delete();
              }
            } catch (e) {
              // Corrupted cache, delete and re-fetch
              await cacheFile.delete();
            }
          } else {
            await cacheFile.delete();
          }
        }
      } catch (e) {
        // Cache miss
      }

      if (!mapTileService.canUseInternet) {
        return safeTransparent();
      }

      // 2. Fetch from network - Esri uses z/y/x order
      try {
        final url = MapTileService.bordersUrl
            .replaceAll('{z}', z.toString())
            .replaceAll('{y}', y.toString())
            .replaceAll('{x}', x.toString());

        final response = await httpClient
            .get(Uri.parse(url), headers: {'User-Agent': 'dev.geogram'})
            .timeout(const Duration(seconds: 10));

        if (response.statusCode == 200 && _isValidImageData(response.bodyBytes)) {
          tileData = response.bodyBytes;
          // Cache the tile
          await _cacheBordersTile(z, x, y, tileData);
        }
      } catch (e) {
        // Network failed
      }

      if (tileData == null || tileData.isEmpty || !_isValidImageData(tileData)) {
        return safeTransparent();
      }

      try {
        final buffer = await ui.ImmutableBuffer.fromUint8List(tileData);
        final codec = await decode(buffer);
        if (await validateCodec(codec)) {
          final buffer2 = await ui.ImmutableBuffer.fromUint8List(tileData);
          return decode(buffer2);
        }
        return safeTransparent();
      } catch (e) {
        return safeTransparent();
      }
    } catch (e) {
      return safeTransparent();
    }
  }

  Future<void> _cacheBordersTile(int z, int x, int y, Uint8List data) async {
    try {
      final cachePath = _getBordersCachePath(z, x, y);
      final cacheFile = File(cachePath);
      final cacheDir = cacheFile.parent;
      if (!await cacheDir.exists()) {
        await cacheDir.create(recursive: true);
      }
      await cacheFile.writeAsBytes(data);
    } catch (e) {
      // Silently ignore
    }
  }

  @override
  bool operator ==(Object other) {
    if (other is GeogramBordersImageProvider) {
      return coordinates == other.coordinates;
    }
    return false;
  }

  @override
  int get hashCode => coordinates.hashCode;
}
