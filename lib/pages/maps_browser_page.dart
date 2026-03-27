/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
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
import '../models/event.dart';
import '../models/map_item.dart';
import '../models/report.dart';
import '../models/place.dart';
import '../services/maps_service.dart';
import '../services/profile_service.dart';
import '../services/user_location_service.dart';
import '../services/map_tile_service.dart' show MapTileService, MapLayerType;
import '../services/i18n_service.dart';
import '../services/log_service.dart';
import '../services/config_service.dart';
import '../services/storage_config.dart';
import '../services/event_service.dart';
import '../services/station_service.dart';
import '../services/station_alert_service.dart';
import '../services/app_service.dart';
import '../services/websocket_service.dart';
import '../services/routing_service.dart';
import '../services/debug_controller.dart';
import '../services/location_provider_service.dart';
import '../version.dart' show appVersion;
import 'report_detail_page.dart';
import 'place_detail_page.dart';
import 'event_detail_page.dart';
import 'map_cache_settings_page.dart';

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
  final AppService _appService = AppService();
  final MapController _mapController = MapController();

  late TabController _tabController;
  late final VoidCallback _appsListener;

  // State
  List<MapItem> _allItems = [];
  Map<MapItemType, List<MapItem>> _groupedItems = {};
  List<MapItemType> _sortedTypes = [];
  MapItem? _selectedItem;
  final Set<MapItemType> _visibleLayers = Set.from(MapItemType.values);
  double _radiusKm = 30.0;
  double _currentZoom = 10.0;
  LatLng? _centerPosition;
  LatLng? _userLocation;        // Pinned user location (marker, items, distances)
  bool _autoFollow = false;     // Auto-follow GPS mode (mobile only)
  VoidCallback? _locationConsumerDispose; // LocationProviderService consumer cleanup
  bool _isLoading = true;
  final Set<MapItemType> _expandedGroups = Set.from(MapItemType.values);

  // Map loading state
  int _tilesLoading = 0;
  int _tilesLoaded = 0;
  bool _mapReady = false;
  bool _isDetectingLocation = false;
  bool _rotationEnabled = false;
  double _currentRotation = 0.0;
  bool _awaitingProfileLocation = false;
  bool _hasUserMoved = false;

  // Navigation routing state (actual route data lives in RoutingService singleton)
  bool _isLoadingRoute = false;

  // Convenience accessors for route state in RoutingService
  final RoutingService _routing = RoutingService();
  List<LatLng> get _routePoints => _routing.activeRoute?.points ?? [];
  TravelMode? get _activeRouteMode => _routing.activeRouteMode;
  double? get _routeDistanceMeters => _routing.activeRoute?.distanceMeters;
  double? get _routeDurationSeconds => _routing.activeRoute?.durationSeconds;
  bool get _routeVisible => _routing.routeVisible;
  set _routeVisible(bool v) => _routing.routeVisible = v;

  // Search state
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  List<_SearchResult> _searchResults = [];
  bool _isSearching = false;
  bool _showSearchBar = false;
  _SearchResult? _searchMarker; // Pinned search result on map
  Timer? _searchDebounce;

  // Debug action subscription
  StreamSubscription? _debugSubscription;

  // Auto-refresh timer (every 5 minutes)
  Timer? _autoRefreshTimer;
  static const Duration _autoRefreshInterval = Duration(minutes: 5);
  late final VoidCallback _profileListener;

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
    _appsListener = () {
      if (!mounted) return;
      _mapsService.clearCache();
      _loadItems(forceRefresh: true);
    };
    _appService.appsNotifier.addListener(_appsListener);
    _profileListener = () {
      if (!mounted) return;
      _handleProfileLocationUpdate();
    };
    _profileService.profileNotifier.addListener(_profileListener);
    _initialize();
    _startAutoRefresh();
    _debugSubscription = DebugController().actionStream.listen((event) {
      if (event.action == DebugAction.mapSearch && mounted) {
        final query = event.params['query'] as String?;
        if (query != null && query.isNotEmpty) {
          setState(() {
            _showSearchBar = true;
            _searchController.text = query;
          });
          _performSearch(query);
        }
      } else if (event.action == DebugAction.mapPinLocation && mounted) {
        final lat = (event.params['lat'] is num)
            ? (event.params['lat'] as num).toDouble()
            : double.tryParse(event.params['lat']?.toString() ?? '');
        final lon = (event.params['lon'] is num)
            ? (event.params['lon'] as num).toDouble()
            : double.tryParse(event.params['lon']?.toString() ?? '');
        if (lat != null && lon != null) {
          _setPinnedLocation(LatLng(lat, lon));
        }
      } else if (event.action == DebugAction.mapRoute && mounted) {
        final toLat = (event.params['toLat'] is num)
            ? (event.params['toLat'] as num).toDouble()
            : double.tryParse(event.params['toLat']?.toString() ?? '');
        final toLon = (event.params['toLon'] is num)
            ? (event.params['toLon'] as num).toDouble()
            : double.tryParse(event.params['toLon']?.toString() ?? '');
        final modeStr = event.params['mode'] as String? ?? 'driving';
        final mode = modeStr == 'walking' ? TravelMode.walking : TravelMode.driving;
        if (toLat != null && toLon != null) {
          final item = MapItem(
            type: MapItemType.place,
            id: 'debug_route',
            title: 'Debug Route Target',
            latitude: toLat,
            longitude: toLon,
          );
          _navigateTo(item, mode);
        }
      }
    });
  }

  @override
  void dispose() {
    _debugSubscription?.cancel();
    _appService.appsNotifier.removeListener(_appsListener);
    _profileService.profileNotifier.removeListener(_profileListener);
    _locationConsumerDispose?.call();
    _autoRefreshTimer?.cancel();
    _searchDebounce?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _tabController.dispose();
    super.dispose();
  }

  /// Start auto-refresh timer (every 5 minutes)
  void _startAutoRefresh() {
    _autoRefreshTimer = Timer.periodic(_autoRefreshInterval, (_) {
      if (mounted) {
        _loadItems(forceRefresh: true);
      }
    });
  }

  Future<void> _initialize() async {
    _mapsService.clearCache();
    // Initialize tile caching
    await _mapTileService.initialize();
    // Trigger rebuild to ensure GeogramTileProvider is used
    if (!mounted) return;
    setState(() {});

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

    // Restore pinned user location if saved
    final savedUserLat = _configService.getNestedValue('mapState.userLatitude') as double?;
    final savedUserLon = _configService.getNestedValue('mapState.userLongitude') as double?;

    if (savedLat != null && savedLon != null) {
      // Restore saved position as initial view
      if (!mounted) return;
      setState(() {
        _centerPosition = LatLng(savedLat, savedLon);
        _currentZoom = savedZoom ?? _getZoomForRadius(_radiusKm);
        _radiusKm = savedRadius ?? 30.0;
        // Restore pinned location, fall back to viewport center
        _userLocation = (savedUserLat != null && savedUserLon != null)
            ? LatLng(savedUserLat, savedUserLon)
            : _centerPosition;
      });
      _awaitingProfileLocation = false;
      LogService().log('MapsBrowserPage: Restored saved map state');

      // On mobile, always fetch fresh GPS location to update to current position
      if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
        _autoDetectLocationSilently();
      }
    } else {
      // Get user's saved location from profile
      final userLocation = _mapsService.getUserLocation();
      if (userLocation != null) {
        if (!mounted) return;
        setState(() {
          _centerPosition = LatLng(userLocation.$1, userLocation.$2);
          _userLocation = _centerPosition;
          _currentZoom = _getZoomForRadius(_radiusKm);
        });
        _awaitingProfileLocation = false;
      } else {
        // First time - set temporary default and auto-detect location
        if (!mounted) return;
        setState(() {
          _centerPosition = const LatLng(20, 0);
          _currentZoom = 3.0;
        });
        _awaitingProfileLocation = true;

        // Auto-detect location in background (GPS on Android, IP on Desktop/Web)
        _autoDetectLocationSilently();
      }
    }

    if (!mounted) return;
    await _loadItems();
    if (!mounted) return;
    _ensureOfflineTiles();
  }

  void _ensureOfflineTiles() {
    final tileCenter = _userLocation ?? _centerPosition;
    if (tileCenter == null || _awaitingProfileLocation) return;
    unawaited(_mapTileService.ensureOfflineTiles(
      lat: tileCenter.latitude,
      lng: tileCenter.longitude,
    ));
  }

  /// Save current map state to config (debounced in ConfigService)
  void _saveMapState() {
    if (_centerPosition == null) return;

    _configService.setNestedValue('mapState.latitude', _centerPosition!.latitude);
    _configService.setNestedValue('mapState.longitude', _centerPosition!.longitude);
    _configService.setNestedValue('mapState.zoom', _currentZoom);
    _configService.setNestedValue('mapState.radius', _radiusKm);
    if (_userLocation != null) {
      _configService.setNestedValue('mapState.userLatitude', _userLocation!.latitude);
      _configService.setNestedValue('mapState.userLongitude', _userLocation!.longitude);
    }
  }

  /// Save filter settings to config (debounced in ConfigService)
  void _saveFilterState() {
    final filterNames = _visibleLayers.map((t) => t.name).toList();
    _configService.setNestedValue('mapState.visibleLayers', filterNames);
  }

  Future<void> _loadItems({bool forceRefresh = false}) async {
    final loadCenter = _userLocation ?? _centerPosition;
    if (loadCenter == null) return;

    // Only show loading indicator on first load, not auto-refresh
    final isFirstLoad = _allItems.isEmpty;
    if (isFirstLoad) {
      if (!mounted) return;
      setState(() => _isLoading = true);
    }

    try {
      final shouldFetchStationAlerts = isFirstLoad || forceRefresh;
      if (shouldFetchStationAlerts) {
        await StationAlertService().fetchAlerts(
          lat: loadCenter.latitude,
          lon: loadCenter.longitude,
          radiusKm: null,
        );
      }

      // Always load all item types - filtering happens at display time
      final items = await _mapsService.loadAllMapItems(
        centerLat: loadCenter.latitude,
        centerLon: loadCenter.longitude,
        radiusKm: _radiusKm,
        visibleTypes: Set.from(MapItemType.values),
        forceRefresh: forceRefresh,
      );
      if (!mounted) return;

      // Check if items have actually changed before updating state
      final hasChanges = _hasItemsChanged(items);

      if (hasChanges || isFirstLoad) {
        final grouped = _mapsService.groupByType(items);
        final sortedTypes = _mapsService.getTypesSortedByCount(grouped);

        if (!mounted) return;
        setState(() {
          _allItems = items;
          _groupedItems = grouped;
          _sortedTypes = sortedTypes;
          _isLoading = false;
        });

        LogService().log('MapsBrowserPage: Loaded ${items.length} items (updated)');
      } else {
        if (isFirstLoad) {
          if (!mounted) return;
          setState(() => _isLoading = false);
        }
        LogService().log('MapsBrowserPage: Auto-refresh - no changes detected');
      }
    } catch (e) {
      LogService().log('MapsBrowserPage: Error loading items: $e');
      if (isFirstLoad) {
        if (!mounted) return;
        setState(() => _isLoading = false);
      }
    }
  }

  void _handleProfileLocationUpdate() {
    if (!_awaitingProfileLocation || _hasUserMoved) return;
    final profile = _profileService.getProfile();
    double? lat = profile.latitude;
    double? lon = profile.longitude;

    // Fallback to UserLocationService if profile has no location
    if (lat == null || lon == null) {
      final userLocation = UserLocationService().currentLocation;
      if (userLocation != null && userLocation.isValid) {
        lat = userLocation.latitude;
        lon = userLocation.longitude;
      }
    }

    if (lat == null || lon == null) return;

    _updateLocationAndReload(lat, lon, 'location_detected');
  }

  /// Check if the new items differ from current items
  bool _hasItemsChanged(List<MapItem> newItems) {
    if (newItems.length != _allItems.length) return true;

    // Create a set of item identifiers for quick comparison
    final currentIds = _allItems.map((item) => '${item.type.name}:${item.id}').toSet();
    final newIds = newItems.map((item) => '${item.type.name}:${item.id}').toSet();

    // Check if the sets differ
    if (!currentIds.containsAll(newIds) || !newIds.containsAll(currentIds)) {
      return true;
    }

    // Check for changes in item properties (title, subtitle, coordinates)
    final currentMap = {for (var item in _allItems) '${item.type.name}:${item.id}': item};
    for (final newItem in newItems) {
      final key = '${newItem.type.name}:${newItem.id}';
      final currentItem = currentMap[key];
      if (currentItem != null) {
        if (currentItem.title != newItem.title ||
            currentItem.subtitle != newItem.subtitle ||
            currentItem.latitude != newItem.latitude ||
            currentItem.longitude != newItem.longitude) {
          return true;
        }
      }
    }

    return false;
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

    // Zoom map and re-center on pinned user location so radius circle is visible
    final center = _userLocation ?? _centerPosition;
    if (center != null && _mapReady) {
      _mapController.move(center, zoom);
      _centerPosition = center;
    }
  }

  void _onRadiusChangeEnd(double radius) {
    // Save state and reload items when user finishes dragging the slider
    _saveMapState();
    _loadItems(forceRefresh: true);
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
    final lat = _userLocation?.latitude ?? _centerPosition?.latitude ?? 0;
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
    final lat = _userLocation?.latitude ?? _centerPosition?.latitude ?? 0;
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

  Future<void> _openItemDetail(MapItem item) async {
    // Open detail page based on item type
    switch (item.type) {
      case MapItemType.alert:
        if (item.sourceItem is Report) {
          final report = item.sourceItem as Report;
          String appPath;

          if (item.isFromStation) {
            // Station alerts: construct path from devices directory
            final storageConfig = StorageConfig();
            final callsign = report.metadata['station_callsign'] ?? 'unknown';
            appPath = '${storageConfig.devicesDir}/$callsign/alerts';
          } else if (item.appPath != null) {
            // Local alerts: use the collection path
            appPath = item.appPath!;
          } else {
            // Fallback - shouldn't happen
            LogService().log('MapsBrowserPage: Alert has no collection path');
            return;
          }

          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => ReportDetailPage(
                appPath: appPath,
                report: report,
              ),
            ),
          );
        }
        break;
      case MapItemType.event:
        if (item.sourceItem is Event) {
          final event = item.sourceItem as Event;
          var appPath = item.appPath ?? '';
          var readOnly = false;

          if (item.isFromStation) {
            readOnly = true;
            final stationPath = await _resolveStationEventsCollectionPath();
            if (stationPath != null && stationPath.isNotEmpty) {
              appPath = stationPath;
            }
          }

          final eventService = EventService();
          if (appPath.isNotEmpty) {
            await eventService.initializeApp(appPath);
          }
          if (!mounted) return;

          final profile = _profileService.getProfile();
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => EventDetailPage(
                event: event,
                appPath: appPath,
                eventService: eventService,
                profileService: _profileService,
                i18n: _i18n,
                currentUserNpub: profile.npub,
                currentCallsign: profile.callsign,
                readOnly: readOnly,
              ),
            ),
          );
        } else {
          _showItemSnackbar(item);
        }
        break;
      case MapItemType.place:
        if (item.sourceItem is Place) {
          final place = item.sourceItem as Place;
          final appPath = item.appPath ?? '';

          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => PlaceDetailPage(
                appPath: appPath,
                place: place,
              ),
            ),
          );
        }
        break;
      case MapItemType.news:
        // TODO: Open news detail page when available
        _showItemSnackbar(item);
        break;
      case MapItemType.station:
        // TODO: Open station detail page when available
        _showItemSnackbar(item);
        break;
      case MapItemType.contact:
        // TODO: Open contact detail page when available
        _showItemSnackbar(item);
        break;
    }
  }

  Future<String?> _resolveStationEventsCollectionPath() async {
    final stationService = StationService();
    if (!stationService.isInitialized) {
      await stationService.initialize();
    }

    final station = stationService.getPreferredStation() ??
        stationService.getConnectedStation();
    if (station == null) return null;

    final identifier = (station.callsign != null && station.callsign!.isNotEmpty)
        ? station.callsign!
        : (station.name.isNotEmpty ? station.name : station.url);
    if (identifier.isEmpty) return null;

    return '${StorageConfig().getCallsignDir(identifier)}/events';
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
    if (!mounted) return;
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

  /// Detect location via IP address using the connected station's GeoIP service
  /// This provides privacy-preserving IP geolocation without external API calls
  Future<void> _detectLocationViaIP() async {
    // Get the connected station URL
    final stationUrl = WebSocketService().connectedUrl;
    if (stationUrl == null) {
      throw Exception('Not connected to station, cannot detect IP location');
    }

    // Convert WebSocket URL to HTTP URL
    final httpUrl = stationUrl
        .replaceFirst('wss://', 'https://')
        .replaceFirst('ws://', 'http://');

    final response = await http.get(
      Uri.parse('$httpUrl/api/geoip'),
    );

    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      final lat = (data['latitude'] as num?)?.toDouble();
      final lon = (data['longitude'] as num?)?.toDouble();

      if (lat != null && lon != null) {
        _updateLocationAndReload(lat, lon, 'location_detected');
      } else {
        throw Exception('Station GeoIP returned no location data');
      }
    } else {
      throw Exception('Failed to fetch IP location from station');
    }
  }

  /// Update the map center and reload items
  void _updateLocationAndReload(double lat, double lon, String successMessageKey) {
    if (!mounted) return;
    setState(() {
      _userLocation = LatLng(lat, lon);
      _centerPosition = _userLocation;
      _currentZoom = _getZoomForRadius(_radiusKm);
      _awaitingProfileLocation = false;
    });

    // Move map to new position
    if (_mapReady) {
      _mapController.move(_centerPosition!, _currentZoom);
    }

    // Save and reload
    _saveMapState();
    _loadItems();
    _ensureOfflineTiles();

    // No success notification needed - the map moving to new location is enough feedback
    LogService().log('Location detected: $lat, $lon (${_i18n.t(successMessageKey)})');
  }

  /// Pin user location at a specific point (long-press, search pin, debug API)
  void _setPinnedLocation(LatLng location) {
    if (!mounted) return;
    // Disable auto-follow on manual pin
    if (_autoFollow) {
      _autoFollow = false;
      _locationConsumerDispose?.call();
      _locationConsumerDispose = null;
    }
    setState(() {
      _userLocation = location;
    });
    _saveMapState();
    _loadItems(forceRefresh: true);
    _ensureOfflineTiles();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_i18n.t('location_pinned')),
        duration: const Duration(seconds: 2),
      ),
    );
    LogService().log('MapsBrowserPage: Location pinned at ${location.latitude}, ${location.longitude}');
  }

  /// Toggle auto-follow GPS mode (mobile only)
  /// Cycle GPS mode: off → locate once → auto-follow → off
  Future<void> _cycleLocationMode() async {
    if (_autoFollow) {
      // Follow → off
      await _toggleAutoFollow();
      setState(() => _userLocation = null);
      _showLocationModeSnackBar(_i18n.t('gps_off_description'));
    } else if (_userLocation != null) {
      // Located → follow (mobile only) or snap back (desktop)
      if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
        await _toggleAutoFollow();
        _showLocationModeSnackBar(_i18n.t('gps_following_description'));
      } else {
        // Desktop: snap back to location then turn off
        if (_centerPosition != null && _mapReady) {
          _mapController.move(_userLocation!, _currentZoom);
          setState(() => _centerPosition = _userLocation);
          _saveMapState();
        }
        setState(() => _userLocation = null);
        _showLocationModeSnackBar(_i18n.t('gps_off_description'));
      }
    } else {
      // Off → locate
      await _autoDetectLocation();
      if (_userLocation != null) {
        final canFollow = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
        _showLocationModeSnackBar(canFollow
            ? _i18n.t('gps_located_description')
            : _i18n.t('auto_detect_location'));
      }
    }
  }

  void _showLocationModeSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _toggleAutoFollow() async {
    if (_autoFollow) {
      // Turn off
      _locationConsumerDispose?.call();
      _locationConsumerDispose = null;
      setState(() => _autoFollow = false);
      LogService().log('MapsBrowserPage: Auto-follow GPS disabled');
    } else {
      // Turn on
      setState(() => _autoFollow = true);
      try {
        final dispose = await LocationProviderService().registerConsumer(
          intervalSeconds: 5,
          onPosition: (position) {
            if (!mounted || !_autoFollow) return;
            final newLoc = LatLng(position.latitude, position.longitude);
            setState(() {
              _userLocation = newLoc;
              _centerPosition = newLoc;
            });
            if (_mapReady) {
              _mapController.move(newLoc, _currentZoom);
            }
            _saveMapState();
          },
        );
        _locationConsumerDispose = dispose;
        LogService().log('MapsBrowserPage: Auto-follow GPS enabled');
      } catch (e) {
        setState(() => _autoFollow = false);
        LogService().log('MapsBrowserPage: Failed to enable auto-follow: $e');
      }
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
      case MapItemType.station:
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
        return Icons.campaign;
      case MapItemType.station:
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

  void _openCacheSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const MapCacheSettingsPage()),
    );
  }

  Widget _buildMenuButton() {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.menu),
      tooltip: _i18n.t('menu'),
      onSelected: (value) {
        if (value == 'cache') {
          _openCacheSettings();
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          value: 'cache',
          child: Row(
            children: [
              const Icon(Icons.download_for_offline),
              const SizedBox(width: 12),
              Text(_i18n.t('cache')),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTopBar() {
    // Get safe area padding for status bar
    final topPadding = MediaQuery.of(context).padding.top;

    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 550;

        if (isNarrow) {
          // Portrait/narrow mode: tabs with menu
          return Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
            ),
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, topPadding + 8, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TabBar(
                      controller: _tabController,
                      tabs: [
                        Tab(text: _i18n.t('map_view')),
                        Tab(text: _i18n.t('list_view')),
                      ],
                    ),
                  ),
                  _buildMenuButton(),
                ],
              ),
            ),
          );
        }

        // Wide mode: tabs with menu on right
        return Container(
          padding: EdgeInsets.fromLTRB(16, topPadding + 8, 8, 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
          ),
          child: Row(
            children: [
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
              const Spacer(),
              _buildMenuButton(),
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
              setState(() {
                _selectedItem = null;
              });
            },
            onPositionChanged: (position, hasGesture) {
              // Update current zoom, position and rotation when user interacts
              if (hasGesture && position.center != null) {
                setState(() {
                  _centerPosition = position.center;
                  _currentZoom = position.zoom;
                  _currentRotation = position.rotation;
                  _hasUserMoved = true;
                });
                _saveMapState();
              }
            },
            onLongPress: (tapPosition, latLng) => _setPinnedLocation(latLng),
          ),
          children: [
            // TileLayer wrapped to react to layer type changes
            ValueListenableBuilder<MapLayerType>(
              valueListenable: _mapTileService.layerTypeNotifier,
              builder: (context, layerType, child) {
                return TileLayer(
                  urlTemplate: _mapTileService.getTileUrl(layerType),
                  userAgentPackageName: 'dev.geogram',
                  subdomains: const [],
                  keepBuffer: 3,
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
                    userAgentPackageName: 'dev.geogram',
                    subdomains: const [],
                    keepBuffer: 3,
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
                  userAgentPackageName: 'dev.geogram',
                  subdomains: const [],
                  keepBuffer: 3,
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
                    userAgentPackageName: 'dev.geogram',
                    subdomains: const [],
                    keepBuffer: 3,
                    tileProvider: _mapTileService.getTransportLabelsProvider(),
                  ),
                );
              },
            ),

            // Radius circle (around pinned user location)
            if (_userLocation != null)
              CircleLayer(
                circles: [
                  CircleMarker(
                    point: _userLocation!,
                    radius: _radiusKm * 1000, // Convert km to meters
                    useRadiusInMeter: true,
                    color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
                    borderColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5),
                    borderStrokeWidth: 2,
                  ),
                ],
              ),

            // Route polyline overlay
            if (_routePoints.isNotEmpty && _routeVisible)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: _routePoints,
                    strokeWidth: 5,
                    color: _activeRouteMode == TravelMode.walking
                        ? Colors.green.withValues(alpha: 0.85)
                        : Colors.blue.withValues(alpha: 0.85),
                    borderStrokeWidth: 1,
                    borderColor: Colors.black38,
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
            if (_userLocation != null)
            MarkerLayer(
              markers: [
                Marker(
                  point: _userLocation!,
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
            // Search pin marker
            if (_searchMarker != null)
              MarkerLayer(
                markers: [
                  Marker(
                    point: LatLng(_searchMarker!.latitude, _searchMarker!.longitude),
                    width: 50,
                    height: 50,
                    child: const Icon(Icons.location_on, color: Colors.red, size: 50),
                  ),
                ],
              ),
          ],
        ),

        // Search bar overlay
        if (_showSearchBar)
          Positioned(
            top: 8,
            left: 16,
            right: 80,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Material(
                  elevation: 4,
                  borderRadius: BorderRadius.circular(28),
                  child: TextField(
                    controller: _searchController,
                    focusNode: _searchFocusNode,
                    onChanged: _onSearchChanged,
                    decoration: InputDecoration(
                      hintText: _i18n.t('search_place'),
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_isSearching)
                            const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                            ),
                          if (_searchController.text.isNotEmpty)
                            IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: _clearSearch,
                            )
                          else
                            IconButton(
                              icon: const Icon(Icons.close),
                              onPressed: () => setState(() {
                                _showSearchBar = false;
                                _searchResults = [];
                              }),
                            ),
                        ],
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(28),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      fillColor: Theme.of(context).colorScheme.surface,
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                if (_searchResults.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(top: 4),
                    constraints: const BoxConstraints(maxHeight: 300),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.15),
                          blurRadius: 8,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      itemCount: _searchResults.length,
                      itemBuilder: (context, index) {
                        final result = _searchResults[index];
                        return ListTile(
                          leading: Icon(result.icon, size: 24),
                          title: Text(
                            result.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: result.subtitle != null
                              ? Text(result.subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis)
                              : null,
                          dense: true,
                          onTap: () => _selectSearchResult(result),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),

        // Search marker detail panel
        if (_searchMarker != null && _selectedItem == null)
          Positioned(
            bottom: 16,
            left: 16,
            right: 16,
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.location_on, color: Colors.red, size: 32),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _searchMarker!.title,
                            style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (_searchMarker!.subtitle != null)
                            Text(
                              _searchMarker!.subtitle!,
                              style: Theme.of(context).textTheme.bodySmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.push_pin),
                      tooltip: _i18n.t('pin_location_here'),
                      onPressed: () {
                        final marker = _searchMarker!;
                        setState(() => _searchMarker = null);
                        _setPinnedLocation(LatLng(marker.latitude, marker.longitude));
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.directions_car),
                      tooltip: _i18n.t('driving'),
                      onPressed: () => _navigateToSearchMarker(TravelMode.driving),
                    ),
                    IconButton(
                      icon: const Icon(Icons.directions_walk),
                      tooltip: _i18n.t('walking'),
                      onPressed: () => _navigateToSearchMarker(TravelMode.walking),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() => _searchMarker = null),
                    ),
                  ],
                ),
              ),
            ),
          ),

        // Zoom controls
        Positioned(
          right: 16,
          top: 16,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Search button
              FloatingActionButton.small(
                heroTag: 'search',
                onPressed: () {
                  setState(() => _showSearchBar = !_showSearchBar);
                  if (_showSearchBar) {
                    Future.delayed(const Duration(milliseconds: 100), () {
                      _searchFocusNode.requestFocus();
                    });
                  }
                },
                tooltip: _i18n.t('search'),
                backgroundColor: _showSearchBar
                    ? Theme.of(context).colorScheme.primaryContainer
                    : null,
                child: const Icon(Icons.search),
              ),
              const SizedBox(height: 8),
              // Zoom in button
              FloatingActionButton.small(
                heroTag: 'zoom_in',
                onPressed: () {
                  final newZoom = (_currentZoom + 1).clamp(1.0, 18.0);
                  setState(() {
                    _currentZoom = newZoom;
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
                  setState(() {
                    _currentZoom = newZoom;
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
              const SizedBox(height: 8),
              // GPS location button — cycles: off → locate → follow → off
              FloatingActionButton.small(
                heroTag: 'gps_location',
                onPressed: _isDetectingLocation ? null : _cycleLocationMode,
                tooltip: _autoFollow
                    ? _i18n.t('gps_following')
                    : _userLocation != null
                        ? _i18n.t('gps_located')
                        : _i18n.t('gps_off'),
                backgroundColor: _autoFollow
                    ? Theme.of(context).colorScheme.primaryContainer
                    : _userLocation != null
                        ? Theme.of(context).colorScheme.secondaryContainer
                        : null,
                child: _isDetectingLocation
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Theme.of(context).colorScheme.onPrimaryContainer,
                        ),
                      )
                    : Icon(
                        _autoFollow
                            ? Icons.gps_fixed
                            : _userLocation != null
                                ? Icons.my_location
                                : Icons.gps_not_fixed,
                      ),
              ),
            ],
          ),
        ),

        // Floating route control bar (persists across tab changes)
        if (_routePoints.isNotEmpty || _isLoadingRoute)
          Positioned(
            bottom: 16,
            left: 16,
            right: 16,
            child: Material(
              elevation: 4,
              borderRadius: BorderRadius.circular(12),
              color: Theme.of(context).colorScheme.surface,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    if (_isLoadingRoute)
                      const SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else ...[
                      Icon(
                        _activeRouteMode == TravelMode.walking
                            ? Icons.directions_walk
                            : Icons.directions_car,
                        size: 20,
                        color: _activeRouteMode == TravelMode.walking
                            ? Colors.green
                            : Colors.blue,
                      ),
                      const SizedBox(width: 8),
                      if (_routeDistanceMeters != null)
                        Text(
                          '${_formatRouteDistance(_routeDistanceMeters!)} - ${_formatDuration(_routeDurationSeconds!)}',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                        ),
                    ],
                    const Spacer(),
                    // Recalculate from current position
                    if (!_isLoadingRoute && _routing.activeRouteTo != null)
                      IconButton(
                        icon: const Icon(Icons.refresh, size: 20),
                        onPressed: () {
                          final to = _routing.activeRouteTo!;
                          final item = MapItem(
                            type: MapItemType.place,
                            id: 'recalc_route',
                            title: 'Route Target',
                            latitude: to.latitude,
                            longitude: to.longitude,
                          );
                          _navigateTo(item, _activeRouteMode ?? TravelMode.driving);
                        },
                        tooltip: _i18n.t('refresh'),
                        visualDensity: VisualDensity.compact,
                      ),
                    // Toggle driving/walking
                    if (!_isLoadingRoute && _routing.activeRouteTo != null)
                      IconButton(
                        icon: Icon(
                          _activeRouteMode == TravelMode.driving
                              ? Icons.directions_walk
                              : Icons.directions_car,
                          size: 20,
                        ),
                        onPressed: () {
                          final to = _routing.activeRouteTo!;
                          final newMode = _activeRouteMode == TravelMode.driving
                              ? TravelMode.walking
                              : TravelMode.driving;
                          final item = MapItem(
                            type: MapItemType.place,
                            id: 'recalc_route',
                            title: 'Route Target',
                            latitude: to.latitude,
                            longitude: to.longitude,
                          );
                          _navigateTo(item, newMode);
                        },
                        tooltip: _activeRouteMode == TravelMode.driving
                            ? _i18n.t('walking')
                            : _i18n.t('driving'),
                        visualDensity: VisualDensity.compact,
                      ),
                    // Toggle visibility
                    if (!_isLoadingRoute)
                      IconButton(
                        icon: Icon(
                          _routeVisible ? Icons.visibility : Icons.visibility_off,
                          size: 20,
                        ),
                        onPressed: () => setState(() => _routeVisible = !_routeVisible),
                        tooltip: _routeVisible ? _i18n.t('hide') : _i18n.t('show'),
                        visualDensity: VisualDensity.compact,
                      ),
                    // Clear route
                    IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => setState(() => _clearRoute()),
                      tooltip: _i18n.t('close'),
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
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

  // ============ Map Search ============

  void _onSearchChanged(String query) {
    _searchDebounce?.cancel();
    if (query.trim().isEmpty) {
      setState(() {
        _searchResults = [];
        _isSearching = false;
      });
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 400), () {
      _performSearch(query.trim());
    });
  }

  Future<void> _performSearch(String query) async {
    setState(() => _isSearching = true);

    final results = <_SearchResult>[];

    // 1. Check if query is coordinates (e.g. "38.72, -9.14" or "38.72 -9.14")
    final coordMatch = RegExp(r'^(-?\d+\.?\d*)[,\s]+(-?\d+\.?\d*)$').firstMatch(query);
    if (coordMatch != null) {
      final lat = double.tryParse(coordMatch.group(1)!);
      final lon = double.tryParse(coordMatch.group(2)!);
      if (lat != null && lon != null && lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180) {
        results.add(_SearchResult(
          title: '${lat.toStringAsFixed(4)}, ${lon.toStringAsFixed(4)}',
          subtitle: _i18n.t('coordinates'),
          latitude: lat,
          longitude: lon,
          icon: Icons.pin_drop,
        ));
      }
    }

    // 2. Search existing map items by name
    final lowerQuery = query.toLowerCase();
    for (final item in _allItems) {
      if (item.title.toLowerCase().contains(lowerQuery) ||
          (item.subtitle?.toLowerCase().contains(lowerQuery) ?? false)) {
        results.add(_SearchResult(
          title: item.title,
          subtitle: item.distanceString,
          latitude: item.latitude,
          longitude: item.longitude,
          icon: _getTypeIcon(item.type),
          mapItem: item,
        ));
      }
      if (results.length >= 5) break;
    }

    // 3. Geocode via Nominatim if we have few local results and query isn't coordinates
    if (coordMatch == null) {
      try {
        final encoded = Uri.encodeComponent(query);
        final response = await http.get(
          Uri.parse('https://nominatim.openstreetmap.org/search?q=$encoded&format=json&limit=5'),
          headers: {'User-Agent': 'Geogram/$appVersion'},
        ).timeout(const Duration(seconds: 5));

        if (response.statusCode == 200) {
          final List<dynamic> data = json.decode(response.body);
          for (final item in data) {
            final lat = double.tryParse(item['lat']?.toString() ?? '');
            final lon = double.tryParse(item['lon']?.toString() ?? '');
            if (lat != null && lon != null) {
              results.add(_SearchResult(
                title: item['display_name']?.toString() ?? query,
                subtitle: item['type']?.toString(),
                latitude: lat,
                longitude: lon,
                icon: Icons.location_on,
              ));
            }
          }
        }
      } catch (e) {
        LogService().log('MapSearch: Nominatim failed: $e');
      }
    }

    // Sort results by distance from pinned user location (closest first)
    final sortRef = _userLocation ?? _centerPosition;
    if (sortRef != null && results.length > 1) {
      final cLat = sortRef.latitude;
      final cLon = sortRef.longitude;
      results.sort((a, b) {
        final dA = _distanceBetween(cLat, cLon, a.latitude, a.longitude);
        final dB = _distanceBetween(cLat, cLon, b.latitude, b.longitude);
        return dA.compareTo(dB);
      });
    }

    if (mounted) {
      setState(() {
        _searchResults = results;
        _isSearching = false;
      });
    }
  }

  void _selectSearchResult(_SearchResult result) {
    setState(() {
      _searchResults = [];
      _searchFocusNode.unfocus();

      if (result.mapItem != null) {
        // It's an existing map item — select it
        _selectedItem = result.mapItem;
        _searchMarker = null;
      } else {
        // It's a geocoded/coordinate result — place a search marker
        _searchMarker = result;
        _selectedItem = null;
      }
    });

    // Move map to result
    if (_mapReady) {
      _mapController.move(LatLng(result.latitude, result.longitude), 14);
    }
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() {
      _searchResults = [];
      _searchMarker = null;
      _showSearchBar = false;
    });
  }

  void _navigateToSearchMarker(TravelMode mode) {
    if (_searchMarker == null) return;
    // Create a temporary MapItem from search result for routing
    final marker = _searchMarker!;
    final tempItem = MapItem(
      type: MapItemType.place,
      id: 'search_${marker.latitude}_${marker.longitude}',
      title: marker.title,
      latitude: marker.latitude,
      longitude: marker.longitude,
    );
    setState(() {
      _selectedItem = tempItem;
      _searchMarker = null;
    });
    _navigateTo(tempItem, mode);
  }

  // ============ Navigation Routing ============

  void _clearRoute() {
    _routing.clearActiveRoute();
    _isLoadingRoute = false;
  }

  Future<void> _navigateTo(MapItem item, TravelMode mode) async {
    final origin = _userLocation ?? _centerPosition;
    if (origin == null || _isLoadingRoute) return;

    final from = origin;
    setState(() {
      _isLoadingRoute = true;
      _routing.activeRouteMode = mode;
    });

    try {
      final result = await _routing.getRoute(
        fromLat: from.latitude,
        fromLon: from.longitude,
        toLat: item.latitude,
        toLon: item.longitude,
        mode: mode,
      );

      if (mounted) {
        _routing.activeRoute = result;
        _routing.activeRouteFrom = from;
        _routing.activeRouteTo = LatLng(item.latitude, item.longitude);
        setState(() {
          _isLoadingRoute = false;
        });

        // Fit camera to show entire route
        if (result.points.length >= 2) {
          double minLat = double.infinity, maxLat = -double.infinity;
          double minLon = double.infinity, maxLon = -double.infinity;
          for (final p in result.points) {
            if (p.latitude < minLat) minLat = p.latitude;
            if (p.latitude > maxLat) maxLat = p.latitude;
            if (p.longitude < minLon) minLon = p.longitude;
            if (p.longitude > maxLon) maxLon = p.longitude;
          }
          final bounds = LatLngBounds(
            LatLng(minLat, minLon),
            LatLng(maxLat, maxLon),
          );
          _mapController.fitCamera(
            CameraFit.bounds(
              bounds: bounds,
              padding: const EdgeInsets.all(60),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingRoute = false;
          _clearRoute();
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${_i18n.t('route_error')}: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  String _formatDuration(double seconds) {
    final totalMinutes = (seconds / 60).round();
    if (totalMinutes < 60) return '$totalMinutes min';
    final hours = totalMinutes ~/ 60;
    final minutes = totalMinutes % 60;
    return '${hours}h ${minutes}m';
  }

  String _formatRouteDistance(double meters) {
    if (meters < 1000) return '${meters.round()} m';
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }

  /// Haversine distance in meters between two points
  static double _distanceBetween(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371000.0;
    final dLat = (lat2 - lat1) * math.pi / 180;
    final dLon = (lon2 - lon1) * math.pi / 180;
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180) * math.cos(lat2 * math.pi / 180) *
        math.sin(dLon / 2) * math.sin(dLon / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
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

          // Directions buttons
          IconButton(
            icon: const Icon(Icons.directions_car),
            tooltip: _i18n.t('driving'),
            onPressed: () => _navigateTo(item, TravelMode.driving),
          ),
          IconButton(
            icon: const Icon(Icons.directions_walk),
            tooltip: _i18n.t('walking'),
            onPressed: () => _navigateTo(item, TravelMode.walking),
          ),

          // Close button
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => setState(() {
                _selectedItem = null;
              }),
              tooltip: _i18n.t('close'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Search result model for map search
class _SearchResult {
  final String title;
  final String? subtitle;
  final double latitude;
  final double longitude;
  final IconData icon;
  final MapItem? mapItem; // non-null if this is an existing map item

  const _SearchResult({
    required this.title,
    this.subtitle,
    required this.latitude,
    required this.longitude,
    required this.icon,
    this.mapItem,
  });
}
