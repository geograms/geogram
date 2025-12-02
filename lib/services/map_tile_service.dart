/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show kIsWeb, ValueNotifier;
import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart' as fmtc;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'profile_service.dart';
import 'relay_service.dart';
import 'log_service.dart';
import 'config_service.dart';

/// Map layer types
enum MapLayerType {
  standard,  // OpenStreetMap
  satellite, // Esri World Imagery
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

/// Centralized service for managing map tiles with offline caching
/// Tile fetching priority: 1) Cache, 2) Relay, 3) Direct Internet (OSM)
/// Tiles are stored in ~/Documents/geogram/tiles/
class MapTileService {
  static final MapTileService _instance = MapTileService._internal();
  factory MapTileService() => _instance;
  MapTileService._internal();

  final ProfileService _profileService = ProfileService();
  bool _initialized = false;
  fmtc.FMTCStore? _tileStore;
  String? _tilesPath;

  /// Shared HTTP client for all tile fetches (prevents "too many open files")
  final http.Client httpClient = http.Client();

  /// Notifier for tile loading status (loading count, failed count)
  final ValueNotifier<TileLoadingStatus> statusNotifier =
      ValueNotifier(const TileLoadingStatus());

  /// Timer to auto-clear failure status after a delay
  Timer? _failureClearTimer;

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

  /// Get the tiles storage path
  String? get tilesPath => _tilesPath;

  /// Initialize the tile caching system
  /// Should be called once at app startup or before first map use
  /// Tiles are stored in ~/Documents/geogram/tiles/
  Future<void> initialize() async {
    if (_initialized || kIsWeb) return;

    try {
      // Create tiles directory at ~/Documents/geogram/tiles/
      final appDir = await getApplicationDocumentsDirectory();
      _tilesPath = '${appDir.path}/geogram/tiles';
      final tilesDir = Directory(_tilesPath!);

      if (!await tilesDir.exists()) {
        await tilesDir.create(recursive: true);
      }

      // Initialize FMTC with custom root directory
      await fmtc.FMTCObjectBoxBackend().initialise(
        rootDirectory: _tilesPath,
      );

      _tileStore = fmtc.FMTCStore('mapTiles');
      await _tileStore!.manage.create();
      _initialized = true;
      LogService().log('MapTileService: Tile cache initialized at $_tilesPath');

      // Log relay tile URL availability for debugging
      final relayUrl = getRelayTileUrl();
      if (relayUrl != null) {
        LogService().log('MapTileService: Relay tiles enabled');
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

  /// Get the relay tile URL if relay is available
  /// [layerType] specifies the layer type (standard or satellite)
  String? getRelayTileUrl([MapLayerType? layerType]) {
    try {
      final relay = RelayService().getPreferredRelay();
      final profile = _profileService.getProfile();

      // Check requirements for relay tile URL
      if (relay == null) {
        return null;
      }
      if (relay.url.isEmpty) {
        return null;
      }
      if (profile.callsign.isEmpty) {
        LogService().log('MapTileService: User callsign is empty, cannot use relay for tiles');
        return null;
      }

      var relayUrl = relay.url;

      // Convert ws:// to http:// and wss:// to https://
      if (relayUrl.startsWith('ws://')) {
        relayUrl = relayUrl.replaceFirst('ws://', 'http://');
      } else if (relayUrl.startsWith('wss://')) {
        relayUrl = relayUrl.replaceFirst('wss://', 'https://');
      }

      // Remove trailing slash if present
      if (relayUrl.endsWith('/')) {
        relayUrl = relayUrl.substring(0, relayUrl.length - 1);
      }

      // Add layer query parameter for satellite tiles
      final layer = layerType ?? _currentLayerType;
      final layerParam = layer == MapLayerType.satellite ? '?layer=satellite' : '';

      return '$relayUrl/tiles/${profile.callsign}/{z}/{x}/{y}.png$layerParam';
    } catch (e) {
      LogService().log('MapTileService: Error getting relay tile URL: $e');
    }
    return null;
  }

  /// Get the tile URL template for the specified layer type
  String getTileUrl([MapLayerType? layerType]) {
    final type = layerType ?? _currentLayerType;
    return type == MapLayerType.satellite ? satelliteTileUrl : osmTileUrl;
  }

  /// Get the tile provider with priority: Cache -> Relay -> Internet
  TileProvider getTileProvider([MapLayerType? layerType]) {
    final type = layerType ?? _currentLayerType;
    if (_initialized && _tileStore != null && !kIsWeb) {
      // Use custom provider with fallback logic
      return GeogramTileProvider(
        tileStore: _tileStore!,
        mapTileService: this,
        layerType: type,
      );
    }
    // Fallback to network-only provider
    return NetworkTileProvider();
  }

  /// Get the labels overlay tile provider (for satellite view)
  TileProvider getLabelsProvider() {
    if (_initialized && _tileStore != null && !kIsWeb) {
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
    if (_initialized && _tileStore != null && !kIsWeb) {
      return GeogramBordersTileProvider(
        mapTileService: this,
      );
    }
    return NetworkTileProvider();
  }

  /// Get the transport labels tile provider (for detailed road info at high zoom)
  TileProvider getTransportLabelsProvider() {
    if (_initialized && _tileStore != null && !kIsWeb) {
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

  /// Test tile fetching by simulating map navigation
  /// This clears specific test tiles from cache and fetches them fresh
  /// to verify the relay -> internet fallback chain works correctly
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
      'relayUrl': getRelayTileUrl(),
      'errors': <String>[],
    };

    LogService().log('=== TILE FETCH TEST START ===');
    LogService().log('Test location: lat=$lat, lon=$lon, zoom=$zoom');
    LogService().log('Relay URL template: ${results['relayUrl'] ?? 'NOT AVAILABLE'}');

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
        // First try relay
        final relayUrl = getRelayTileUrl();
        if (relayUrl != null) {
          final url = relayUrl
              .replaceAll('{z}', z.toString())
              .replaceAll('{x}', x.toString())
              .replaceAll('{y}', y.toString());

          LogService().log('TEST [$z/$x/$y] Trying relay: $url');
          try {
            final response = await httpClient
                .get(Uri.parse(url))
                .timeout(const Duration(seconds: 5));

            if (response.statusCode == 200 && response.bodyBytes.length > 100) {
              tileResult['source'] = 'RELAY';
              tileResult['bytes'] = response.bodyBytes.length;
              LogService().log('TEST [$z/$x/$y] SUCCESS from RELAY (${response.bodyBytes.length} bytes)');
              (results['tiles'] as List).add(tileResult);
              continue;
            } else {
              LogService().log('TEST [$z/$x/$y] Relay returned ${response.statusCode} (${response.bodyBytes.length} bytes)');
            }
          } catch (e) {
            LogService().log('TEST [$z/$x/$y] Relay failed: $e');
          }
        } else {
          LogService().log('TEST [$z/$x/$y] No relay URL configured');
        }

        // Fall back to internet
        final osmUrl = 'https://tile.openstreetmap.org/$z/$x/$y.png';
        LogService().log('TEST [$z/$x/$y] Trying internet: $osmUrl');
        final osmResponse = await httpClient
            .get(Uri.parse(osmUrl), headers: {'User-Agent': 'dev.geogram.geogram_desktop'})
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
    final relayCount = tiles.where((t) => t['source'] == 'RELAY').length;
    final internetCount = tiles.where((t) => t['source'] == 'INTERNET').length;
    final failedCount = tiles.where((t) => t['error'] != null).length;

    results['success'] = failedCount == 0;
    results['summary'] = {
      'total': tiles.length,
      'fromRelay': relayCount,
      'fromInternet': internetCount,
      'failed': failedCount,
    };

    LogService().log('=== TILE FETCH TEST COMPLETE ===');
    LogService().log('Results: ${tiles.length} tiles tested');
    LogService().log('  From RELAY: $relayCount');
    LogService().log('  From INTERNET: $internetCount');
    LogService().log('  FAILED: $failedCount');

    if (relayCount == 0 && results['relayUrl'] != null) {
      LogService().log('WARNING: Relay URL is configured but NO tiles came from relay!');
      LogService().log('This indicates the desktop app is NOT using the relay for tiles.');
    }

    return results;
  }
}

/// Custom tile provider with fallback logic:
/// 1. Check cache first
/// 2. Try relay if available (standard layer only)
/// 3. Fall back to direct internet (OSM or Esri satellite)
class GeogramTileProvider extends TileProvider {
  final fmtc.FMTCStore tileStore;
  final MapTileService mapTileService;
  final MapLayerType layerType;

  GeogramTileProvider({
    required this.tileStore,
    required this.mapTileService,
    required this.layerType,
  });

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    return GeogramTileImageProvider(
      coordinates: coordinates,
      options: options,
      tileStore: tileStore,
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
  final fmtc.FMTCStore tileStore;
  final MapTileService mapTileService;
  final http.Client httpClient;
  final MapLayerType layerType;

  GeogramTileImageProvider({
    required this.coordinates,
    required this.options,
    required this.tileStore,
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

  /// Load tile with priority: Cache -> Relay (standard only) -> Internet
  /// Retries failed tiles for up to 2 minutes with exponential backoff
  Future<ui.Codec> _loadTileWithFallback(ImageDecoderCallback decode) async {
    final z = coordinates.z.toInt();
    final x = coordinates.x.toInt();
    final y = coordinates.y.toInt();

    bool needsNetworkFetch = true;
    Uint8List? tileData;

    // 1. Try file cache first
    try {
      final cachePath = _getTileCachePath(z, x, y);
      final cacheFile = File(cachePath);
      if (await cacheFile.exists()) {
        final cachedBytes = await cacheFile.readAsBytes();
        if (cachedBytes.isNotEmpty && _isValidImageData(cachedBytes)) {
          // Cache hit with valid image - try to decode
          try {
            needsNetworkFetch = false;
            LogService().log('TILE [$z/$x/$y] SOURCE: LOCAL_CACHE (${cachedBytes.length} bytes)');
            final buffer = await ui.ImmutableBuffer.fromUint8List(cachedBytes);
            return decode(buffer);
          } catch (e) {
            // Cached tile is corrupted, delete it and re-fetch
            LogService().log('TILE [$z/$x/$y] Cache corrupted, re-fetching');
            await cacheFile.delete();
            needsNetworkFetch = true;
          }
        } else {
          // Invalid cached data, delete it
          LogService().log('TILE [$z/$x/$y] Invalid cache data, deleting');
          await cacheFile.delete();
        }
      }
    } catch (e) {
      // Cache miss or error, continue to next source
    }

    // Network fetch needed - track loading status
    if (needsNetworkFetch) {
      mapTileService._startLoading();
    }

    try {
      // Retry logic: try for up to 2 minutes with exponential backoff
      const maxRetryDuration = Duration(minutes: 2);
      final startTime = DateTime.now();
      int retryDelay = 2; // Start with 2 seconds

      while (tileData == null) {
        // 2. Try relay if available (supports both standard and satellite tiles)
        final relayUrl = mapTileService.getRelayTileUrl(layerType);
        if (relayUrl != null) {
          final url = relayUrl
              .replaceAll('{z}', z.toString())
              .replaceAll('{x}', x.toString())
              .replaceAll('{y}', y.toString());
          LogService().log('TILE [$z/$x/$y] Trying RELAY: $url');
          try {
            final response = await httpClient
                .get(Uri.parse(url))
                .timeout(const Duration(seconds: 5));

            if (response.statusCode == 200 && _isValidImageData(response.bodyBytes)) {
              tileData = response.bodyBytes;
              LogService().log('TILE [$z/$x/$y] SOURCE: RELAY (${tileData.length} bytes)');
              // Cache the tile for future use
              await _cacheTile(z, x, y, tileData);
              break;
            } else {
              LogService().log('TILE [$z/$x/$y] Relay returned status ${response.statusCode}');
            }
          } catch (e) {
            // Relay failed, continue to internet
            LogService().log('TILE [$z/$x/$y] Relay FAILED: $e');
          }
        } else {
          LogService().log('TILE [$z/$x/$y] No relay URL available');
        }

        // 3. Try direct internet
        try {
          String url;
          if (layerType == MapLayerType.satellite) {
            // Esri satellite uses z/y/x order
            url = MapTileService.satelliteTileUrl
                .replaceAll('{z}', z.toString())
                .replaceAll('{y}', y.toString())
                .replaceAll('{x}', x.toString());
          } else {
            // OSM uses z/x/y order
            url = MapTileService.osmTileUrl
                .replaceAll('{z}', z.toString())
                .replaceAll('{x}', x.toString())
                .replaceAll('{y}', y.toString());
          }
          LogService().log('TILE [$z/$x/$y] Trying INTERNET: $url');

          final response = await httpClient
              .get(
                Uri.parse(url),
                headers: {'User-Agent': 'dev.geogram.geogram_desktop'},
              )
              .timeout(const Duration(seconds: 10));

          if (response.statusCode == 200 && _isValidImageData(response.bodyBytes)) {
            tileData = response.bodyBytes;
            LogService().log('TILE [$z/$x/$y] SOURCE: INTERNET (${tileData.length} bytes)');
            // Cache the tile for future use
            await _cacheTile(z, x, y, tileData);
            break;
          } else {
            LogService().log('TILE [$z/$x/$y] Internet returned status ${response.statusCode}');
          }
        } catch (e) {
          // Network failed - will retry if within time limit
          LogService().log('TILE [$z/$x/$y] Internet FAILED: $e');
        }

        // Check if we should retry
        final elapsed = DateTime.now().difference(startTime);
        if (elapsed >= maxRetryDuration) {
          break; // Give up after 2 minutes
        }

        // Wait before retrying (exponential backoff, max 30 seconds)
        await Future.delayed(Duration(seconds: retryDelay));
        retryDelay = (retryDelay * 2).clamp(2, 30);
      }

      // Return fetched tile or transparent placeholder on failure
      if (tileData == null || tileData.isEmpty || !_isValidImageData(tileData)) {
        mapTileService._recordFailure();
        // Return transparent placeholder instead of throwing
        final buffer = await ui.ImmutableBuffer.fromUint8List(_transparentTile);
        return decode(buffer);
      }

      // Try to decode the tile, fall back to transparent on error
      try {
        final buffer = await ui.ImmutableBuffer.fromUint8List(tileData);
        return decode(buffer);
      } catch (e) {
        // Decode failed, return transparent placeholder
        final buffer = await ui.ImmutableBuffer.fromUint8List(_transparentTile);
        return decode(buffer);
      }
    } finally {
      if (needsNetworkFetch) {
        mapTileService._finishLoading();
      }
    }
  }

  /// Cache the tile data to a file
  Future<void> _cacheTile(int z, int x, int y, Uint8List data) async {
    try {
      final cachePath = _getTileCachePath(z, x, y);
      final cacheFile = File(cachePath);

      // Create parent directories if they don't exist
      final cacheDir = cacheFile.parent;
      if (!await cacheDir.exists()) {
        await cacheDir.create(recursive: true);
      }

      // Write tile data to file
      await cacheFile.writeAsBytes(data);

      // Prefetch the alternate layer tile in the background for instant switching
      _prefetchAlternateLayer(z, x, y);
    } catch (e) {
      // Silently ignore cache write errors - not critical
      LogService().log('MapTileService: Failed to cache tile $z/$x/$y: $e');
    }
  }

  /// Prefetch the alternate layer tile (standard <-> satellite) for instant layer switching
  void _prefetchAlternateLayer(int z, int x, int y) async {
    try {
      final tilesPath = mapTileService.tilesPath;
      final alternateLayer = layerType == MapLayerType.satellite ? 'standard' : 'satellite';
      final cachePath = '$tilesPath/cache/$alternateLayer/$z/$x/$y.png';
      final cacheFile = File(cachePath);

      // Skip if already cached
      if (await cacheFile.exists()) return;

      String url;
      if (layerType == MapLayerType.satellite) {
        // Currently viewing satellite, prefetch standard (OSM)
        url = MapTileService.osmTileUrl
            .replaceAll('{z}', z.toString())
            .replaceAll('{x}', x.toString())
            .replaceAll('{y}', y.toString());
      } else {
        // Currently viewing standard, prefetch satellite (Esri uses z/y/x)
        url = MapTileService.satelliteTileUrl
            .replaceAll('{z}', z.toString())
            .replaceAll('{y}', y.toString())
            .replaceAll('{x}', x.toString());
      }

      final response = await httpClient
          .get(Uri.parse(url), headers: {'User-Agent': 'dev.geogram.geogram_desktop'})
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final cacheDir = cacheFile.parent;
        if (!await cacheDir.exists()) {
          await cacheDir.create(recursive: true);
        }
        await cacheFile.writeAsBytes(response.bodyBytes);
      }
    } catch (e) {
      // Silently ignore prefetch failures - not critical
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

    // 1. Try file cache first
    try {
      final cachePath = _getLabelsCachePath(z, x, y);
      final cacheFile = File(cachePath);
      if (await cacheFile.exists()) {
        final cachedBytes = await cacheFile.readAsBytes();
        if (cachedBytes.isNotEmpty && _isValidImageData(cachedBytes)) {
          try {
            final buffer = await ui.ImmutableBuffer.fromUint8List(cachedBytes);
            return decode(buffer);
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

    // 2. Fetch from network - Esri uses z/y/x order
    try {
      final url = MapTileService.labelsOnlyUrl
          .replaceAll('{z}', z.toString())
          .replaceAll('{y}', y.toString())
          .replaceAll('{x}', x.toString());

      final response = await httpClient
          .get(
            Uri.parse(url),
            headers: {'User-Agent': 'dev.geogram.geogram_desktop'},
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
      final buffer = await ui.ImmutableBuffer.fromUint8List(_transparentTile);
      return decode(buffer);
    }

    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(tileData);
      return decode(buffer);
    } catch (e) {
      // Decode failed, return transparent
      final buffer = await ui.ImmutableBuffer.fromUint8List(_transparentTile);
      return decode(buffer);
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
          .get(Uri.parse(url), headers: {'User-Agent': 'dev.geogram.geogram_desktop'})
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final cacheDir = cacheFile.parent;
        if (!await cacheDir.exists()) {
          await cacheDir.create(recursive: true);
        }
        await cacheFile.writeAsBytes(response.bodyBytes);
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

    // 1. Try file cache first
    try {
      final cachePath = _getTransportCachePath(z, x, y);
      final cacheFile = File(cachePath);
      if (await cacheFile.exists()) {
        final cachedBytes = await cacheFile.readAsBytes();
        if (cachedBytes.isNotEmpty && _isValidImageData(cachedBytes)) {
          try {
            final buffer = await ui.ImmutableBuffer.fromUint8List(cachedBytes);
            return decode(buffer);
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

    // 2. Fetch from network - Esri uses z/y/x order
    try {
      final url = MapTileService.transportLabelsUrl
          .replaceAll('{z}', z.toString())
          .replaceAll('{y}', y.toString())
          .replaceAll('{x}', x.toString());

      final response = await httpClient
          .get(Uri.parse(url), headers: {'User-Agent': 'dev.geogram.geogram_desktop'})
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
      final buffer = await ui.ImmutableBuffer.fromUint8List(_transparentTile);
      return decode(buffer);
    }

    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(tileData);
      return decode(buffer);
    } catch (e) {
      final buffer = await ui.ImmutableBuffer.fromUint8List(_transparentTile);
      return decode(buffer);
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

    // 1. Try file cache first
    try {
      final cachePath = _getBordersCachePath(z, x, y);
      final cacheFile = File(cachePath);
      if (await cacheFile.exists()) {
        final cachedBytes = await cacheFile.readAsBytes();
        if (cachedBytes.isNotEmpty && _isValidImageData(cachedBytes)) {
          try {
            final buffer = await ui.ImmutableBuffer.fromUint8List(cachedBytes);
            return decode(buffer);
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

    // 2. Fetch from network - Esri uses z/y/x order
    try {
      final url = MapTileService.bordersUrl
          .replaceAll('{z}', z.toString())
          .replaceAll('{y}', y.toString())
          .replaceAll('{x}', x.toString());

      final response = await httpClient
          .get(Uri.parse(url), headers: {'User-Agent': 'dev.geogram.geogram_desktop'})
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
      final buffer = await ui.ImmutableBuffer.fromUint8List(_transparentTile);
      return decode(buffer);
    }

    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(tileData);
      return decode(buffer);
    } catch (e) {
      final buffer = await ui.ImmutableBuffer.fromUint8List(_transparentTile);
      return decode(buffer);
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
