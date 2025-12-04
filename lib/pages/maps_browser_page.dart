/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:math' as math;
import 'dart:io' show Platform;
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import '../models/map_item.dart';
import '../models/report.dart';
import '../services/maps_service.dart';
import '../services/profile_service.dart';
import '../services/map_tile_service.dart' show MapTileService, TileLoadingStatus, MapLayerType;
import '../services/i18n_service.dart';
import '../services/log_service.dart';
import '../services/config_service.dart';
import 'report_detail_page.dart';

/// Maps browser page showing geo-located items
class MapsBrowserPage extends StatefulWidget {
  const MapsBrowserPage({super.key});

  @override
  State<MapsBrowserPage> createState() => _MapsBrowserPageState();
}

class _MapsBrowserPageState extends State<MapsBrowserPage> with SingleTickerProviderStateMixin {
  final MapsService _mapsService = MapsService();
  final ProfileService _profileService = ProfileService();
  final MapTileService _mapTileService = MapTileService();
  final I18nService _i18n = I18nService();
  final ConfigService _configService = ConfigService();
  final MapController _mapController = MapController();

  late TabController _tabController;

  // State
  List<MapItem> _allItems = [];
  Map<MapItemType, List<MapItem>> _groupedItems = {};
  List<MapItemType> _sortedTypes = [];
  MapItem? _selectedItem;
  final Set<MapItemType> _visibleLayers = Set.from(MapItemType.values);
  double _radiusKm = 30.0;
  double _currentZoom = 10.0;
  LatLng? _centerPosition;
  bool _isLoading = true;
  final Set<MapItemType> _expandedGroups = Set.from(MapItemType.values);

  // Map loading state
  int _tilesLoading = 0;
  int _tilesLoaded = 0;
  bool _mapReady = false;
  bool _isDetectingLocation = false;
  bool _rotationEnabled = true;
  double _currentRotation = 0.0;

  // Radius slider range (logarithmic scale for fine control at lower values)
  static const double _minRadius = 1.0;
  static const double _maxRadius = 500.0;

  /// Convert radius to slider value (0-1) using logarithmic scale
  double _radiusToSlider(double radius) {
    // Using log scale: sliderValue = log(radius/minRadius) / log(maxRadius/minRadius)
    final clampedRadius = radius.clamp(_minRadius, _maxRadius);
    return math.log(clampedRadius / _minRadius) / math.log(_maxRadius / _minRadius);
  }

  /// Convert slider value (0-1) to radius using logarithmic scale
  double _sliderToRadius(double sliderValue) {
    // Using log scale: radius = minRadius * (maxRadius/minRadius)^sliderValue
    return _minRadius * math.pow(_maxRadius / _minRadius, sliderValue);
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _initialize();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    // Initialize tile caching
    await _mapTileService.initialize();
    // Trigger rebuild to ensure GeogramTileProvider is used
    if (mounted) {
      setState(() {});
    }

    // Try to load saved map state first
    final savedLat = _configService.getNestedValue('mapState.latitude') as double?;
    final savedLon = _configService.getNestedValue('mapState.longitude') as double?;
    final savedZoom = _configService.getNestedValue('mapState.zoom') as double?;
    final savedRadius = _configService.getNestedValue('mapState.radius') as double?;

    // Load saved filter settings
    final savedFilters = _configService.getNestedValue('mapState.visibleLayers') as List<dynamic>?;
    if (savedFilters != null) {
      _visibleLayers.clear();
      for (final filter in savedFilters) {
        try {
          final type = MapItemType.values.firstWhere((t) => t.name == filter);
          _visibleLayers.add(type);
        } catch (_) {
          // Ignore invalid filter names
        }
      }
      LogService().log('MapsBrowserPage: Restored ${_visibleLayers.length} saved filters');
    }

    if (savedLat != null && savedLon != null) {
      // Restore saved position
      setState(() {
        _centerPosition = LatLng(savedLat, savedLon);
        _currentZoom = savedZoom ?? _getZoomForRadius(_radiusKm);
        _radiusKm = savedRadius ?? 30.0;
      });
      LogService().log('MapsBrowserPage: Restored saved map state');
    } else {
      // Get user's saved location from profile
      final userLocation = _mapsService.getUserLocation();
      if (userLocation != null) {
        setState(() {
          _centerPosition = LatLng(userLocation.$1, userLocation.$2);
          _currentZoom = _getZoomForRadius(_radiusKm);
        });
      } else {
        // First time - set temporary default and auto-detect location
        setState(() {
          _centerPosition = const LatLng(20, 0);
          _currentZoom = 3.0;
        });

        // Auto-detect location in background (GPS on Android, IP on Desktop/Web)
        _autoDetectLocationSilently();
      }
    }

    await _loadItems();
  }

  /// Save current map state to config (debounced in ConfigService)
  void _saveMapState() {
    if (_centerPosition == null) return;

    _configService.setNestedValue('mapState.latitude', _centerPosition!.latitude);
    _configService.setNestedValue('mapState.longitude', _centerPosition!.longitude);
    _configService.setNestedValue('mapState.zoom', _currentZoom);
    _configService.setNestedValue('mapState.radius', _radiusKm);
  }

  /// Save filter settings to config (debounced in ConfigService)
  void _saveFilterState() {
    final filterNames = _visibleLayers.map((t) => t.name).toList();
    _configService.setNestedValue('mapState.visibleLayers', filterNames);
  }

  Future<void> _loadItems({bool forceRefresh = false}) async {
    if (_centerPosition == null) return;

    setState(() => _isLoading = true);

    try {
      // Always load all item types - filtering happens at display time
      final items = await _mapsService.loadAllMapItems(
        centerLat: _centerPosition!.latitude,
        centerLon: _centerPosition!.longitude,
        radiusKm: _radiusKm,
        visibleTypes: Set.from(MapItemType.values),
        forceRefresh: forceRefresh,
      );

      final grouped = _mapsService.groupByType(items);
      final sortedTypes = _mapsService.getTypesSortedByCount(grouped);

      setState(() {
        _allItems = items;
        _groupedItems = grouped;
        _sortedTypes = sortedTypes;
        _isLoading = false;
      });

      LogService().log('MapsBrowserPage: Loaded ${items.length} items');
    } catch (e) {
      LogService().log('MapsBrowserPage: Error loading items: $e');
      setState(() => _isLoading = false);
    }
  }

  void _toggleLayer(MapItemType type) {
    setState(() {
      if (_visibleLayers.contains(type)) {
        _visibleLayers.remove(type);
      } else {
        _visibleLayers.add(type);
      }
    });
    _saveFilterState();
    // No need to reload - filtering happens at display time
  }

  void _setRadius(double radius) {
    final zoom = _getZoomForRadius(radius);
    setState(() {
      _radiusKm = radius;
      _currentZoom = zoom;
    });

    // Zoom map to fit the new radius
    if (_centerPosition != null && _mapReady) {
      _mapController.move(_centerPosition!, zoom);
    }
  }

  void _onRadiusChangeEnd(double radius) {
    // Save state and reload items when user finishes dragging the slider
    _saveMapState();
    _loadItems();
  }

  /// Calculate appropriate zoom level to show the given radius
  /// Formula derived from: radius_in_pixels = radius_in_meters / meters_per_pixel
  /// meters_per_pixel at equator = 156543.03 / 2^zoom
  double _getZoomForRadius(double radiusKm) {
    // We want the radius circle to fit nicely in the view
    // Assuming a typical screen width of ~800px, we want diameter to be ~70% of width
    // So radius should be ~280px
    const targetRadiusPixels = 280.0;
    final radiusMeters = radiusKm * 1000;

    // Account for latitude (meters per pixel varies with latitude)
    final lat = _centerPosition?.latitude ?? 0;
    final latRadians = lat * math.pi / 180;
    final metersPerPixelAtZoom0 = 156543.03 * math.cos(latRadians);

    // Calculate zoom: meters_per_pixel = metersPerPixelAtZoom0 / 2^zoom
    // We want: radiusMeters / meters_per_pixel = targetRadiusPixels
    // So: meters_per_pixel = radiusMeters / targetRadiusPixels
    // Therefore: 2^zoom = metersPerPixelAtZoom0 / (radiusMeters / targetRadiusPixels)
    // zoom = log2(metersPerPixelAtZoom0 * targetRadiusPixels / radiusMeters)

    final zoom = math.log(metersPerPixelAtZoom0 * targetRadiusPixels / radiusMeters) / math.ln2;

    // Clamp to reasonable values
    return zoom.clamp(1.0, 18.0);
  }

  /// Calculate radius from zoom level (inverse of _getZoomForRadius)
  double _getRadiusForZoom(double zoom) {
    const targetRadiusPixels = 280.0;

    // Account for latitude
    final lat = _centerPosition?.latitude ?? 0;
    final latRadians = lat * math.pi / 180;
    final metersPerPixelAtZoom0 = 156543.03 * math.cos(latRadians);

    // Inverse formula: radiusMeters = metersPerPixelAtZoom0 * targetRadiusPixels / 2^zoom
    final radiusMeters = metersPerPixelAtZoom0 * targetRadiusPixels / math.pow(2, zoom);
    final radiusKm = radiusMeters / 1000;

    return radiusKm.clamp(_minRadius, _maxRadius);
  }

  void _selectItem(MapItem item) {
    setState(() {
      _selectedItem = item;
    });

    // Center map on item
    if (_mapReady) {
      _mapController.move(
        LatLng(item.latitude, item.longitude),
        _mapController.camera.zoom,
      );
    }
  }

  void _openItemDetail(MapItem item) {
    // Open detail page based on item type
    switch (item.type) {
      case MapItemType.alert:
        if (item.collectionPath != null && item.sourceItem is Report) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => ReportDetailPage(
                collectionPath: item.collectionPath!,
                report: item.sourceItem as Report,
              ),
            ),
          );
        }
        break;
      case MapItemType.event:
        // TODO: Open event detail page when available
        _showItemSnackbar(item);
        break;
      case MapItemType.place:
        // TODO: Open place detail page when available
        _showItemSnackbar(item);
        break;
      case MapItemType.news:
        // TODO: Open news detail page when available
        _showItemSnackbar(item);
        break;
      case MapItemType.relay:
        // TODO: Open relay detail page when available
        _showItemSnackbar(item);
        break;
      case MapItemType.contact:
        // TODO: Open contact detail page when available
        _showItemSnackbar(item);
        break;
    }
  }

  void _showItemSnackbar(MapItem item) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${item.type.singularName}: ${item.title}'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _toggleGroup(MapItemType type) {
    setState(() {
      if (_expandedGroups.contains(type)) {
        _expandedGroups.remove(type);
      } else {
        _expandedGroups.add(type);
      }
    });
  }

  /// Auto-detect current location using GPS (Android) or IP (Desktop/Web)
  Future<void> _autoDetectLocation() async {
    setState(() => _isDetectingLocation = true);

    try {
      // Web always uses IP-based geolocation
      if (kIsWeb) {
        await _detectLocationViaIP();
      } else if (Platform.isAndroid || Platform.isIOS) {
        // Mobile platforms use GPS
        await _detectLocationViaGPS();
      } else {
        // Desktop (Linux/Windows/macOS): use IP-based geolocation
        await _detectLocationViaIP();
      }
    } catch (e) {
      LogService().log('MapsBrowserPage: Error detecting location: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('location_detection_failed')),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isDetectingLocation = false);
      }
    }
  }

  /// Auto-detect location silently on first load (no error messages)
  Future<void> _autoDetectLocationSilently() async {
    LogService().log('MapsBrowserPage: Auto-detecting initial location...');
    setState(() => _isDetectingLocation = true);

    try {
      // Web always uses IP-based geolocation
      if (kIsWeb) {
        await _detectLocationViaIP();
      } else if (Platform.isAndroid || Platform.isIOS) {
        // Mobile platforms use GPS
        await _detectLocationViaGPSSilently();
      } else {
        // Desktop (Linux/Windows/macOS): use IP-based geolocation
        await _detectLocationViaIP();
      }
      LogService().log('MapsBrowserPage: Initial location detected successfully');
    } catch (e) {
      // Silently fail on first load - user can manually detect later
      LogService().log('MapsBrowserPage: Silent location detection failed: $e');
    } finally {
      if (mounted) {
        setState(() => _isDetectingLocation = false);
      }
    }
  }

  /// Detect location via GPS silently (no permission denied messages)
  Future<void> _detectLocationViaGPSSilently() async {
    // Check if location services are enabled
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw Exception('Location services disabled');
    }

    // Check permission - only proceed if already granted
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      // Try to request permission
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw Exception('Location permission denied');
      }
    }

    if (permission == LocationPermission.deniedForever) {
      throw Exception('Location permission permanently denied');
    }

    // Get current position
    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.medium, // Use medium for faster detection
        timeLimit: Duration(seconds: 15),
      ),
    );

    _updateLocationAndReload(position.latitude, position.longitude, 'location_detected_gps');
  }

  /// Detect location via GPS (for Android/iOS)
  Future<void> _detectLocationViaGPS() async {
    // Check if location services are enabled
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('location_services_disabled')),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
      return;
    }

    // Check permission
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_i18n.t('location_permission_denied')),
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
          );
        }
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('location_permission_permanent_denied')),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
      return;
    }

    // Get current position
    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 10),
      ),
    );

    _updateLocationAndReload(position.latitude, position.longitude, 'location_detected_gps');
  }

  /// Detect location via IP address (for Desktop)
  Future<void> _detectLocationViaIP() async {
    final response = await http.get(
      Uri.parse('http://ip-api.com/json/?fields=status,lat,lon,city,country'),
    );

    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      if (data['status'] == 'success') {
        final lat = (data['lat'] as num).toDouble();
        final lon = (data['lon'] as num).toDouble();
        _updateLocationAndReload(lat, lon, 'location_detected');
      } else {
        throw Exception('IP geolocation failed');
      }
    } else {
      throw Exception('Failed to fetch IP location');
    }
  }

  /// Update the map center and reload items
  void _updateLocationAndReload(double lat, double lon, String successMessageKey) {
    setState(() {
      _centerPosition = LatLng(lat, lon);
      _currentZoom = _getZoomForRadius(_radiusKm);
    });

    // Move map to new position
    if (_mapReady) {
      _mapController.move(_centerPosition!, _currentZoom);
    }

    // Save and reload
    _saveMapState();
    _loadItems();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_i18n.t(successMessageKey)),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  Color _getTypeColor(MapItemType type) {
    switch (type) {
      case MapItemType.event:
        return Colors.blue;
      case MapItemType.place:
        return Colors.green;
      case MapItemType.news:
        return Colors.orange;
      case MapItemType.alert:
        return Colors.red;
      case MapItemType.relay:
        return Colors.purple;
      case MapItemType.contact:
        return Colors.teal;
    }
  }

  IconData _getTypeIcon(MapItemType type) {
    switch (type) {
      case MapItemType.event:
        return Icons.event;
      case MapItemType.place:
        return Icons.place;
      case MapItemType.news:
        return Icons.newspaper;
      case MapItemType.alert:
        return Icons.notifications_active;
      case MapItemType.relay:
        return Icons.cell_tower;
      case MapItemType.contact:
        return Icons.person_pin;
    }
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          // Top bar with tabs and radius selector
          _buildTopBar(),

          // Layer toggles
          _buildLayerToggles(),

          // Main content
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildMapView(),
                _buildListView(),
              ],
            ),
          ),

          // Selected item detail panel
          if (_selectedItem != null) _buildDetailPanel(),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 550;

        if (isNarrow) {
          // Portrait/narrow mode: stack radius slider above tabs
          return Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border: Border(
                bottom: BorderSide(
                  color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
                ),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Radius slider row
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Row(
                    children: [
                      Text(
                        _i18n.t('radius'),
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Slider(
                          value: _radiusToSlider(_radiusKm),
                          min: 0.0,
                          max: 1.0,
                          divisions: 100,
                          label: '${_radiusKm.round()} km',
                          onChanged: (sliderValue) => _setRadius(_sliderToRadius(sliderValue)),
                          onChangeEnd: (sliderValue) => _onRadiusChangeEnd(_sliderToRadius(sliderValue)),
                        ),
                      ),
                      SizedBox(
                        width: 60,
                        child: Text(
                          '${_radiusKm.round()} km',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: _isDetectingLocation
                            ? SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              )
                            : const Icon(Icons.my_location),
                        onPressed: _isDetectingLocation ? null : _autoDetectLocation,
                        tooltip: _i18n.t('auto_detect_location'),
                      ),
                      IconButton(
                        icon: const Icon(Icons.refresh),
                        onPressed: () => _loadItems(forceRefresh: true),
                        tooltip: _i18n.t('refresh'),
                      ),
                    ],
                  ),
                ),
                // Tab bar row
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: TabBar(
                    controller: _tabController,
                    tabs: [
                      Tab(text: _i18n.t('map_view')),
                      Tab(text: _i18n.t('list_view')),
                    ],
                  ),
                ),
              ],
            ),
          );
        }

        // Wide mode: everything in one row
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border(
              bottom: BorderSide(
                color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
              ),
            ),
          ),
          child: Row(
            children: [
              // Tab bar
              SizedBox(
                width: 200,
                child: TabBar(
                  controller: _tabController,
                  tabs: [
                    Tab(text: _i18n.t('map_view')),
                    Tab(text: _i18n.t('list_view')),
                  ],
                ),
              ),

              const SizedBox(width: 16),

              // Radius slider
              Text(
                _i18n.t('radius'),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 200,
                child: Slider(
                  value: _radiusToSlider(_radiusKm),
                  min: 0.0,
                  max: 1.0,
                  divisions: 100,
                  label: '${_radiusKm.round()} km',
                  onChanged: (sliderValue) => _setRadius(_sliderToRadius(sliderValue)),
                  onChangeEnd: (sliderValue) => _onRadiusChangeEnd(_sliderToRadius(sliderValue)),
                ),
              ),
              SizedBox(
                width: 70,
                child: Text(
                  '${_radiusKm.round()} km',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),

              const SizedBox(width: 8),

              // Auto-detect location button
              IconButton(
                icon: _isDetectingLocation
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      )
                    : const Icon(Icons.my_location),
                onPressed: _isDetectingLocation ? null : _autoDetectLocation,
                tooltip: _i18n.t('auto_detect_location'),
              ),

              // Refresh button
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: () => _loadItems(forceRefresh: true),
                tooltip: _i18n.t('refresh'),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildLayerToggles() {
    // Only show layer types that have items
    final typesWithItems = MapItemType.values
        .where((type) => (_groupedItems[type]?.length ?? 0) > 0)
        .toList();

    // Hide the entire row if no items exist
    if (typesWithItems.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: typesWithItems.map((type) {
            final isActive = _visibleLayers.contains(type);
            final count = _groupedItems[type]?.length ?? 0;

            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                selected: isActive,
                label: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _getTypeIcon(type),
                      size: 16,
                      color: isActive
                          ? _getTypeColor(type)
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Text(_i18n.t('layer_${type.name}')),
                    const SizedBox(width: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: isActive
                            ? _getTypeColor(type).withValues(alpha: 0.2)
                            : Theme.of(context).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        count.toString(),
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ),
                  ],
                ),
                onSelected: (_) => _toggleLayer(type),
                selectedColor: _getTypeColor(type).withValues(alpha: 0.1),
                checkmarkColor: _getTypeColor(type),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildMapView() {
    if (_centerPosition == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final visibleItems = _allItems
        .where((item) => _visibleLayers.contains(item.type))
        .toList();

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: _centerPosition!,
            initialZoom: _currentZoom,
            minZoom: 1.0,
            maxZoom: 18.0,
            interactionOptions: InteractionOptions(
              flags: _rotationEnabled
                  ? InteractiveFlag.all
                  : InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
            onMapReady: () {
              setState(() => _mapReady = true);
            },
            onTap: (_, __) {
              setState(() => _selectedItem = null);
            },
            onPositionChanged: (position, hasGesture) {
              // Update current zoom, position and rotation when user interacts
              if (hasGesture && position.center != null) {
                final newZoom = position.zoom;
                final newRadius = _getRadiusForZoom(newZoom);
                // Update state and rebuild UI so slider syncs with zoom
                setState(() {
                  _centerPosition = position.center;
                  _currentZoom = newZoom;
                  _radiusKm = newRadius;
                  _currentRotation = position.rotation;
                });
                // Save state (debounced by the config service)
                _saveMapState();
              }
            },
          ),
          children: [
            // TileLayer wrapped to react to layer type changes
            ValueListenableBuilder<MapLayerType>(
              valueListenable: _mapTileService.layerTypeNotifier,
              builder: (context, layerType, child) {
                return TileLayer(
                  urlTemplate: _mapTileService.getTileUrl(layerType),
                  userAgentPackageName: 'dev.geogram.geogram_desktop',
                  subdomains: const [],
                  tileBuilder: (context, tileWidget, tile) {
                    return tileWidget;
                  },
                  evictErrorTileStrategy: EvictErrorTileStrategy.notVisibleRespectMargin,
                  tileProvider: _mapTileService.getTileProvider(layerType),
                );
              },
            ),
            // Country/region borders overlay for satellite view
            ValueListenableBuilder<MapLayerType>(
              valueListenable: _mapTileService.layerTypeNotifier,
              builder: (context, layerType, child) {
                if (layerType != MapLayerType.satellite) {
                  return const SizedBox.shrink();
                }
                // Apply color filter to make borders visible on satellite imagery
                return ColorFiltered(
                  colorFilter: const ColorFilter.matrix(<double>[
                    // Boost contrast for visible borders on satellite
                    1.2, 0,   0,   0, 0,   // Red channel
                    0,   1.2, 0,   0, 0,   // Green channel
                    0,   0,   1.2, 0, 0,   // Blue channel
                    0,   0,   0,   0.7, 0, // Alpha (slightly transparent)
                  ]),
                  child: TileLayer(
                    urlTemplate: _mapTileService.getBordersUrl(),
                    userAgentPackageName: 'dev.geogram.geogram_desktop',
                    subdomains: const [],
                    tileProvider: _mapTileService.getBordersProvider(),
                  ),
                );
              },
            ),
            // Labels overlay for satellite view (city names, place labels)
            ValueListenableBuilder<MapLayerType>(
              valueListenable: _mapTileService.layerTypeNotifier,
              builder: (context, layerType, child) {
                if (layerType != MapLayerType.satellite) {
                  return const SizedBox.shrink();
                }
                return TileLayer(
                  urlTemplate: _mapTileService.getLabelsUrl(),
                  userAgentPackageName: 'dev.geogram.geogram_desktop',
                  subdomains: const [],
                  tileProvider: _mapTileService.getLabelsProvider(),
                );
              },
            ),
            // Transport labels overlay for satellite view (road names, route numbers - only at higher zoom levels)
            ValueListenableBuilder<MapLayerType>(
              valueListenable: _mapTileService.layerTypeNotifier,
              builder: (context, layerType, child) {
                // Only show transport labels on satellite view at higher zoom levels (Google Maps style)
                // Hide at low zoom (< 12) to reduce visual clutter, similar to Google Maps
                if (layerType != MapLayerType.satellite || _currentZoom < 12) {
                  return const SizedBox.shrink();
                }
                // Apply soft grey color filter for readable road labels
                return ColorFiltered(
                  colorFilter: const ColorFilter.matrix(<double>[
                    // Soft grey matrix - darkened background with readable white text
                    0.3, 0.3, 0.3, 0, 30,  // Red channel (soft grey)
                    0.3, 0.3, 0.3, 0, 30,  // Green channel
                    0.3, 0.3, 0.3, 0, 30,  // Blue channel
                    0,   0,   0,   1.0, 0, // Alpha (fully opaque)
                  ]),
                  child: TileLayer(
                    urlTemplate: _mapTileService.getTransportLabelsUrl(),
                    userAgentPackageName: 'dev.geogram.geogram_desktop',
                    subdomains: const [],
                    tileProvider: _mapTileService.getTransportLabelsProvider(),
                  ),
                );
              },
            ),

            // Radius circle
            CircleLayer(
              circles: [
                CircleMarker(
                  point: _centerPosition!,
                  radius: _radiusKm * 1000, // Convert km to meters
                  useRadiusInMeter: true,
                  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
                  borderColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5),
                  borderStrokeWidth: 2,
                ),
              ],
            ),

            // Item markers with clustering (rendered before user marker so user marker is on top)
            MarkerClusterLayerWidget(
              options: MarkerClusterLayerOptions(
                maxClusterRadius: 80,
                size: const Size(48, 48),
                alignment: Alignment.center,
                padding: const EdgeInsets.all(50),
                maxZoom: 15,
                markers: visibleItems.map((item) {
                  final isSelected = _selectedItem == item;
                  return Marker(
                    point: LatLng(item.latitude, item.longitude),
                    width: isSelected ? 50 : 40,
                    height: isSelected ? 50 : 40,
                    child: GestureDetector(
                      onTap: () => _selectItem(item),
                      child: Container(
                        decoration: BoxDecoration(
                          color: isSelected
                              ? _getTypeColor(item.type)
                              : _getTypeColor(item.type).withValues(alpha: 0.8),
                          shape: BoxShape.circle,
                          border: isSelected
                              ? Border.all(color: Colors.white, width: 3)
                              : null,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.3),
                              blurRadius: 4,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Icon(
                          _getTypeIcon(item.type),
                          color: Colors.white,
                          size: isSelected ? 28 : 22,
                        ),
                      ),
                    ),
                  );
                }).toList(),
                builder: (context, markers) {
                  // Cluster marker - green circle with count
                  return Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.green.shade600,
                      border: Border.all(color: Colors.white, width: 3),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.3),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Center(
                      child: Text(
                        markers.length.toString(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),

            // User location marker - more prominent with pulsing effect
            MarkerLayer(
              markers: [
                Marker(
                  point: _centerPosition!,
                  width: 80,
                  height: 80,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // Outer glow/pulse ring
                      Container(
                        width: 60,
                        height: 60,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
                          border: Border.all(
                            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
                            width: 2,
                          ),
                        ),
                      ),
                      // Middle ring
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
                          border: Border.all(
                            color: Theme.of(context).colorScheme.primary,
                            width: 2,
                          ),
                        ),
                      ),
                      // Inner dot
                      Container(
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Theme.of(context).colorScheme.primary,
                          border: Border.all(
                            color: Colors.white,
                            width: 3,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5),
                              blurRadius: 8,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                      ),
                      // "You are here" indicator
                      Positioned(
                        bottom: 0,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary,
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.3),
                                blurRadius: 4,
                              ),
                            ],
                          ),
                          child: Text(
                            _i18n.t('you'),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),

        // Zoom controls
        Positioned(
          right: 16,
          top: 16,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Zoom in button
              FloatingActionButton.small(
                heroTag: 'zoom_in',
                onPressed: () {
                  final newZoom = (_currentZoom + 1).clamp(1.0, 18.0);
                  final newRadius = _getRadiusForZoom(newZoom);
                  setState(() {
                    _currentZoom = newZoom;
                    _radiusKm = newRadius;
                  });
                  if (_mapReady && _centerPosition != null) {
                    _mapController.move(_centerPosition!, newZoom);
                  }
                  _saveMapState();
                },
                tooltip: _i18n.t('zoom_in'),
                child: const Icon(Icons.add),
              ),
              const SizedBox(height: 8),
              // Zoom out button
              FloatingActionButton.small(
                heroTag: 'zoom_out',
                onPressed: () {
                  final newZoom = (_currentZoom - 1).clamp(1.0, 18.0);
                  final newRadius = _getRadiusForZoom(newZoom);
                  setState(() {
                    _currentZoom = newZoom;
                    _radiusKm = newRadius;
                  });
                  if (_mapReady && _centerPosition != null) {
                    _mapController.move(_centerPosition!, newZoom);
                  }
                  _saveMapState();
                },
                tooltip: _i18n.t('zoom_out'),
                child: const Icon(Icons.remove),
              ),
              const SizedBox(height: 16),
              // Layer toggle button
              ValueListenableBuilder<MapLayerType>(
                valueListenable: _mapTileService.layerTypeNotifier,
                builder: (context, layerType, child) {
                  return FloatingActionButton.small(
                    heroTag: 'layer_toggle',
                    onPressed: () => _mapTileService.toggleLayer(),
                    tooltip: layerType == MapLayerType.standard
                        ? _i18n.t('switch_to_satellite')
                        : _i18n.t('switch_to_standard'),
                    child: Icon(
                      layerType == MapLayerType.standard
                          ? Icons.satellite_alt
                          : Icons.map,
                    ),
                  );
                },
              ),
              const SizedBox(height: 8),
              // Compass / rotation toggle button
              FloatingActionButton.small(
                heroTag: 'compass',
                onPressed: () {
                  if (_rotationEnabled) {
                    // Lock rotation and reset to north
                    _mapController.rotate(0);
                    setState(() {
                      _currentRotation = 0;
                      _rotationEnabled = false;
                    });
                  } else {
                    // Unlock rotation
                    setState(() {
                      _rotationEnabled = true;
                    });
                  }
                },
                tooltip: _rotationEnabled
                    ? _i18n.t('lock_rotation')
                    : _i18n.t('unlock_rotation'),
                backgroundColor: _rotationEnabled
                    ? null
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Transform.rotate(
                  angle: -_currentRotation * math.pi / 180,
                  child: Icon(
                    Icons.explore,
                    color: _rotationEnabled
                        ? null
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),

        // Tile loading status indicator
        ValueListenableBuilder<TileLoadingStatus>(
          valueListenable: _mapTileService.statusNotifier,
          builder: (context, status, child) {
            if (!status.isLoading && !status.hasFailures) {
              return const SizedBox.shrink();
            }
            return Positioned(
              bottom: 16,
              left: 16,
              right: 80, // Leave space for zoom controls
              child: AnimatedOpacity(
                opacity: (status.isLoading || status.hasFailures) ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 300),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: status.hasFailures
                        ? Colors.orange.shade800.withValues(alpha: 0.9)
                        : Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.2),
                        blurRadius: 4,
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (status.isLoading) ...[
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _i18n.t('loading_tiles', params: [status.loadingCount.toString()]),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ] else if (status.hasFailures) ...[
                        const Icon(
                          Icons.cloud_off,
                          size: 16,
                          color: Colors.white,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            _i18n.t('tiles_failed', params: [status.failedCount.toString()]),
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Colors.white,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        ),

        // Loading overlay with progress indicator
        if (!_mapReady || _isLoading)
          Positioned.fill(
            child: Container(
              color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.8),
              child: Center(
                child: Card(
                  elevation: 8,
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 48,
                          height: 48,
                          child: CircularProgressIndicator(strokeWidth: 3),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _i18n.t('loading_map'),
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _i18n.t('loading_map_hint'),
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildListView() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    // Use sorted types, filter for visible layers, and exclude empty categories
    final visibleTypes = _sortedTypes
        .where((type) => _visibleLayers.contains(type))
        .where((type) => (_groupedItems[type]?.isNotEmpty ?? false))
        .toList();

    if (_allItems.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.map_outlined,
              size: 64,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              _i18n.t('no_items_in_radius'),
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: visibleTypes.length,
      itemBuilder: (context, index) {
        final type = visibleTypes[index];
        final items = _groupedItems[type] ?? [];
        final isExpanded = _expandedGroups.contains(type);

        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: Column(
            children: [
              // Group header
              InkWell(
                onTap: () => _toggleGroup(type),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: _getTypeColor(type).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          _getTypeIcon(type),
                          color: _getTypeColor(type),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _i18n.t('layer_${type.name}'),
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: items.isEmpty
                              ? Theme.of(context).colorScheme.surfaceContainerHighest
                              : _getTypeColor(type).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          items.length.toString(),
                          style: TextStyle(
                            color: items.isEmpty
                                ? Theme.of(context).colorScheme.onSurfaceVariant
                                : _getTypeColor(type),
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        isExpanded
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                      ),
                    ],
                  ),
                ),
              ),

              // Group items (indented to show hierarchy)
              if (isExpanded && items.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 24),
                  child: ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, indent: 16),
                    itemBuilder: (context, itemIndex) {
                      final item = items[itemIndex];
                      final isSelected = _selectedItem == item;

                      return ListTile(
                        selected: isSelected,
                        selectedTileColor:
                            _getTypeColor(type).withValues(alpha: 0.1),
                        contentPadding: const EdgeInsets.only(left: 8, right: 16),
                        leading: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: _getTypeColor(type).withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            _getTypeIcon(type),
                            color: _getTypeColor(type),
                            size: 18,
                          ),
                        ),
                        title: Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: item.subtitle != null
                            ? Text(
                                item.subtitle!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              )
                            : null,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              item.distanceString,
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                            ),
                            const SizedBox(width: 8),
                            Icon(
                              Icons.chevron_right,
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ],
                        ),
                        onTap: () => _openItemDetail(item),
                      );
                    },
                  ),
                ),

              if (isExpanded && items.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 40, top: 16, bottom: 16, right: 16),
                  child: Text(
                    _i18n.t('no_items_type'),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDetailPanel() {
    final item = _selectedItem!;

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Row(
        children: [
          // Main clickable area (opens details)
          Expanded(
            child: InkWell(
              onTap: () => _openItemDetail(item),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    // Type icon
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: _getTypeColor(item.type),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        _getTypeIcon(item.type),
                        color: Colors.white,
                        size: 28,
                      ),
                    ),

                    const SizedBox(width: 16),

                    // Item info
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            item.title,
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: _getTypeColor(item.type).withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  item.type.singularName,
                                  style: TextStyle(
                                    color: _getTypeColor(item.type),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Icon(
                                Icons.straighten,
                                size: 14,
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                item.distanceString,
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color:
                                          Theme.of(context).colorScheme.onSurfaceVariant,
                                    ),
                              ),
                              if (item.subtitle != null) ...[
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Text(
                                    item.subtitle!,
                                    style:
                                        Theme.of(context).textTheme.bodySmall?.copyWith(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                            ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Close button
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => setState(() => _selectedItem = null),
              tooltip: _i18n.t('close'),
            ),
          ),
        ],
      ),
    );
  }
}
