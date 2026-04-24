/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import '../services/log_service.dart';
import '../services/i18n_service.dart';
import '../services/config_service.dart';
import '../services/location_provider_service.dart';
import '../services/location_service.dart';
import '../services/user_location_service.dart';
import '../services/map_tile_service.dart' show MapTileService, MapLayerType;

/// Full-page reusable location picker/viewer
/// Can be used throughout the app for selecting or viewing coordinates
class LocationPickerPage extends StatefulWidget {
  final LatLng? initialPosition;
  final bool viewOnly; // If true, shows location without selection controls

  const LocationPickerPage({
    Key? key,
    this.initialPosition,
    this.viewOnly = false,
  }) : super(key: key);

  @override
  State<LocationPickerPage> createState() => _LocationPickerPageState();
}

class _LocationPickerPageState extends State<LocationPickerPage> {
  final I18nService _i18n = I18nService();
  final ConfigService _configService = ConfigService();
  final MapTileService _mapTileService = MapTileService();
  final MapController _mapController = MapController();
  late TextEditingController _latController;
  late TextEditingController _lonController;
  late LatLng _selectedPosition;
  bool _isOnline = true;
  bool _isDetectingLocation = false;
  bool _mapInitialized = false;
  bool _mapReady = false;
  LatLng? _pendingMapCenter;
  double? _pendingMapZoom;
  double _currentZoom = 18.0; // Default zoom level - maximum zoom for precise location selection
  VoidCallback? _disposeLocationConsumer;

  // Nearest city preview — refreshed on every tap / programmatic move.
  // Shown as a small pill overlay on the map so the user knows where
  // they are aiming before confirming.
  String? _nearestCityLabel;
  bool _nearestCityLoading = false;
  int _nearestCitySeq = 0;

  // Default to central Europe (Munich/Vienna area)
  static const LatLng _defaultPosition = LatLng(48.0, 10.0);

  LatLng _resolveInitialPosition() {
    if (widget.initialPosition != null) {
      return widget.initialPosition!;
    }

    final cachedGps = _getCachedGpsLatLng(log: true);
    if (cachedGps != null) {
      return cachedGps;
    }

    final lastLat = _configService.get('lastLocationPickerLat');
    final lastLon = _configService.get('lastLocationPickerLon');
    if (lastLat != null && lastLon != null) {
      LogService().log('Using last saved picker position: $lastLat, $lastLon');
      return LatLng(lastLat as double, lastLon as double);
    }

    return _defaultPosition;
  }

  LatLng? _getCachedGpsLatLng({bool log = false}) {
    final locationService = LocationProviderService();
    final userLocationService = UserLocationService();

    final providerPos = locationService.currentPosition;
    final userPos = userLocationService.currentLocation;

    LatLng? candidate;
    DateTime? candidateTime;
    String? candidateSource;
    double? candidateAccuracy;

    if (providerPos != null) {
      candidate = LatLng(providerPos.latitude, providerPos.longitude);
      candidateTime = providerPos.timestamp;
      candidateSource = 'LocationProviderService';
      candidateAccuracy = providerPos.accuracy;
    }

    if (userPos != null && userPos.isValid && userPos.source == 'gps') {
      if (candidateTime == null || userPos.timestamp.isAfter(candidateTime)) {
        candidate = userPos.latLng;
        candidateTime = userPos.timestamp;
        candidateSource = 'UserLocationService';
        candidateAccuracy = null;
      }
    }

    if (candidate != null && log) {
      final accuracyInfo = candidateAccuracy != null
          ? ' (accuracy: ${candidateAccuracy.toStringAsFixed(0)}m)'
          : '';
      LogService().log(
          'LocationPicker: Using cached GPS from $candidateSource$accuracyInfo');
    }

    return candidate;
  }

  @override
  void initState() {
    super.initState();
    _initializeMap();

    // Always start at maximum zoom for precise location picking
    // Don't restore saved zoom - users need precision when selecting locations
    _currentZoom = 18.0;

    // Set initial position from: 1) provided, 2) cached GPS, 3) last saved, 4) default
    _selectedPosition = _resolveInitialPosition();

    _initializeControllers();
    _refreshNearestCity(_selectedPosition);

    // ALWAYS try to detect GPS location (unless view-only mode)
    // This will update the map to current position if GPS is available
    if (!widget.viewOnly) {
      _autoDetectLocationOnStart();
    }
  }

  /// Automatically detect location when the picker opens
  /// Uses LocationProviderService for shared GPS positioning
  /// Patient acquisition: keeps spinner visible for up to 60s if no cached GPS is available
  Future<void> _autoDetectLocationOnStart() async {
    try {
      final locationService = LocationProviderService();
      final isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);

      final cachedGps = _getCachedGpsLatLng();
      if (cachedGps != null && mounted) {
        _setLocation(cachedGps.latitude, cachedGps.longitude);
      }

      if (!mounted) return;

      if (!isMobile) {
        setState(() => _isDetectingLocation = false);
        return;
      }

      setState(() {
        _isDetectingLocation = cachedGps == null;
      });

      Timer? spinnerTimeout;
      if (cachedGps == null) {
        spinnerTimeout = Timer(const Duration(seconds: 60), () {
          if (_isDetectingLocation && mounted) {
            LogService().log(
                'Auto-detect: GPS acquisition timeout after 60s, continuing in background');
            setState(() => _isDetectingLocation = false);
          }
        });
      }

      // Register as consumer to get GPS updates
      // Note: We keep listening even after initial detection, because offline GPS
      // can take 30-60+ seconds for cold start, and we want to update when it arrives
      _disposeLocationConsumer = await locationService.registerConsumer(
        intervalSeconds: 5, // Check frequently for startup
        onPosition: (pos) {
          // Accept any position - user can refine manually if needed
          // For offline/off-grid operation, we can't be picky about accuracy
          if (mounted) {
            _setLocation(pos.latitude, pos.longitude);
            LogService().log(
                'GPS position update: ${pos.latitude}, ${pos.longitude} (accuracy: ${pos.accuracy.toStringAsFixed(0)}m)');
            if (_isDetectingLocation) {
              spinnerTimeout?.cancel();
              setState(() => _isDetectingLocation = false);
            }
          }
        },
      );

      if (!mounted) return;

      // Quick last-known fix for cold starts (uses device cache)
      if (cachedGps == null) {
        final lastKnown = await _getLastKnownPosition();
        if (lastKnown != null && mounted) {
          _setLocation(lastKnown.latitude, lastKnown.longitude);
          LogService().log(
              'Auto-detected location (last known): ${lastKnown.latitude}, ${lastKnown.longitude} (accuracy: ${lastKnown.accuracy.toStringAsFixed(0)}m)');
          spinnerTimeout?.cancel();
          setState(() => _isDetectingLocation = false);
        }
      }

      // If still no good position, request one immediately
      LogService().log('Requesting immediate GPS position...');
      final immediatePos = await locationService.requestImmediatePosition();
      if (immediatePos != null && mounted) {
        // Accept any position for map centering, but log accuracy
        _setLocation(immediatePos.latitude, immediatePos.longitude);
        LogService().log(
            'Auto-detected location (immediate): ${immediatePos.latitude}, ${immediatePos.longitude} (accuracy: ${immediatePos.accuracy.toStringAsFixed(0)}m)');
        spinnerTimeout?.cancel();
        setState(() => _isDetectingLocation = false);
      }
    } catch (e) {
      LogService().log('Auto-detect failed: $e');
      if (mounted) {
        setState(() => _isDetectingLocation = false);
      }
    }
  }

  Future<Position?> _getLastKnownPosition() async {
    if (kIsWeb || (!Platform.isAndroid && !Platform.isIOS)) {
      return null;
    }
    try {
      return await Geolocator.getLastKnownPosition();
    } catch (e) {
      LogService().log('LocationPicker: Last known position failed: $e');
      return null;
    }
  }

  /// Set location and update UI
  /// If preserveZoom is true, keeps the current map zoom level instead of resetting
  void _setLocation(double lat, double lon, {bool preserveZoom = false}) {
    final zoomToUse =
        preserveZoom && _mapReady ? _mapController.camera.zoom : _currentZoom;
    setState(() {
      _selectedPosition = LatLng(lat, lon);
      _latController.text = lat.toStringAsFixed(6);
      _lonController.text = lon.toStringAsFixed(6);
    });
    if (_mapReady) {
      _mapController.move(_selectedPosition, zoomToUse);
    } else {
      _pendingMapCenter = _selectedPosition;
      _pendingMapZoom = zoomToUse;
    }

    _refreshNearestCity(_selectedPosition);

    // Trigger offline tile pre-download for this area (in background)
    _triggerOfflineTileDownload(lat, lon);
  }

  /// Look up the nearest city to [pos] in the bundled worldcities
  /// database and update the pill overlay. Uses a monotonic sequence
  /// number so a burst of taps doesn't surface a stale older result.
  Future<void> _refreshNearestCity(LatLng pos) async {
    final seq = ++_nearestCitySeq;
    setState(() => _nearestCityLoading = true);
    try {
      final result = await LocationService()
          .findNearestCity(pos.latitude, pos.longitude);
      if (!mounted || seq != _nearestCitySeq) return;
      setState(() {
        _nearestCityLoading = false;
        _nearestCityLabel = result == null
            ? null
            : (result.country.isNotEmpty
                ? '${result.city}, ${result.country}'
                : result.city);
      });
    } catch (e) {
      if (!mounted || seq != _nearestCitySeq) return;
      setState(() {
        _nearestCityLoading = false;
        _nearestCityLabel = null;
      });
    }
  }

  /// Pre-download tiles for offline use around the current position
  void _triggerOfflineTileDownload(double lat, double lon) {
    // Run in background, don't block UI
    _mapTileService.ensureOfflineTiles(lat: lat, lng: lon);
  }

  Future<void> _initializeMap() async {
    // Initialize tile caching
    await _mapTileService.initialize();
    // Rebuild after initialization to ensure GeogramTileProvider is used
    if (mounted) {
      setState(() {
        _mapInitialized = true;
      });
    }
  }

  void _initializeControllers() {
    _latController = TextEditingController(
      text: _selectedPosition.latitude.toStringAsFixed(6),
    );
    _lonController = TextEditingController(
      text: _selectedPosition.longitude.toStringAsFixed(6),
    );

    // Move map to initial position after build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_mapReady) {
        _mapController.move(_selectedPosition, _currentZoom);
      } else {
        _pendingMapCenter = _selectedPosition;
        _pendingMapZoom = _currentZoom;
      }
    });
  }

  /// Auto-detect current location (triggered by manual button press)
  /// Uses LocationProviderService for shared GPS positioning
  /// Patient acquisition: waits up to 90 seconds for offline cold-start GPS
  Future<void> _autoDetectLocation() async {
    if (_isDetectingLocation) return;

    setState(() {
      _isDetectingLocation = true;
    });

    try {
      final locationService = LocationProviderService();

      // First check if we already have a valid position (any accuracy since user requested it)
      if (locationService.hasValidPosition) {
        final pos = locationService.currentPosition!;
        _setLocation(pos.latitude, pos.longitude, preserveZoom: true);
        LogService().log('Manual detect: using cached position: ${pos.latitude}, ${pos.longitude} (accuracy: ${pos.accuracy.toStringAsFixed(0)}m)');
        setState(() => _isDetectingLocation = false);
        return;
      }

      // For offline GPS, we need to be patient - cold start can take 60+ seconds
      // Register consumer and wait for stream to deliver position
      // Keep spinner visible while waiting

      bool gotPosition = false;
      Timer? timeoutTimer;
      VoidCallback? disposeConsumer;

      disposeConsumer = await locationService.registerConsumer(
        intervalSeconds: 5, // Check more frequently for manual request
        onPosition: (pos) {
          if (!gotPosition && mounted) {
            gotPosition = true;
            timeoutTimer?.cancel();
            _setLocation(pos.latitude, pos.longitude, preserveZoom: true);
            LogService().log('Manual detect: GPS stream position: ${pos.latitude}, ${pos.longitude} (accuracy: ${pos.accuracy.toStringAsFixed(0)}m)');
            setState(() => _isDetectingLocation = false);
            disposeConsumer?.call();
          }
        },
      );

      // Set a generous timeout for offline GPS (90 seconds)
      timeoutTimer = Timer(const Duration(seconds: 90), () {
        if (!gotPosition && mounted) {
          disposeConsumer?.call();
          setState(() => _isDetectingLocation = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_i18n.t('location_detection_failed'))),
          );
          LogService().log('Manual detect: GPS timeout after 90 seconds');
        }
      });

      // Also try immediate position request as fast path
      final pos = await locationService.requestImmediatePosition();
      if (pos != null && !gotPosition && mounted) {
        gotPosition = true;
        timeoutTimer.cancel();
        disposeConsumer();
        _setLocation(pos.latitude, pos.longitude, preserveZoom: true);
        LogService().log('Manual detect: immediate GPS position: ${pos.latitude}, ${pos.longitude} (accuracy: ${pos.accuracy.toStringAsFixed(0)}m)');
        setState(() => _isDetectingLocation = false);
      }

    } catch (e) {
      LogService().log('Error auto-detecting location: $e');
      if (mounted) {
        setState(() => _isDetectingLocation = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('location_detection_failed'))),
        );
      }
    }
  }

  @override
  void dispose() {
    // Unregister from LocationProviderService
    _disposeLocationConsumer?.call();
    _latController.dispose();
    _lonController.dispose();
    super.dispose();
  }

  void _onMapTap(TapPosition tapPosition, LatLng position) {
    setState(() {
      _selectedPosition = position;
      _latController.text = position.latitude.toStringAsFixed(6);
      _lonController.text = position.longitude.toStringAsFixed(6);
    });
    _refreshNearestCity(position);
  }

  void _confirmSelection() {
    // Save the selected position and zoom level for next time
    _configService.set('lastLocationPickerLat', _selectedPosition.latitude);
    _configService.set('lastLocationPickerLon', _selectedPosition.longitude);
    _configService.set('lastLocationPickerZoom', _mapController.camera.zoom);

    if (mounted) {
      Navigator.of(context).pop(_selectedPosition);
    }
  }


  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.viewOnly
          ? _i18n.t('view_location')
          : _i18n.t('select_location_on_map')),
      ),
      floatingActionButton: widget.viewOnly
        ? null
        : FloatingActionButton.extended(
            onPressed: _confirmSelection,
            icon: const Icon(Icons.check),
            label: Text(_i18n.t('confirm_location')),
          ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      body: LayoutBuilder(
        builder: (context, constraints) {
          // Use portrait layout if width < height (portrait mode)
          final isPortrait = constraints.maxWidth < constraints.maxHeight;

          return Flex(
            direction: isPortrait ? Axis.vertical : Axis.horizontal,
            children: [
              // Map View
              Expanded(
                flex: isPortrait ? 3 : 2,
                child: Column(
              children: [
                // Map Widget
                Expanded(
                  child: Stack(
                    children: [
                      _mapInitialized
                          ? FlutterMap(
                              mapController: _mapController,
                              options: MapOptions(
                                initialCenter: _selectedPosition,
                                initialZoom: _currentZoom,
                                minZoom: 1.0,
                                maxZoom: 18.0,
                                interactionOptions: const InteractionOptions(
                                  flags: InteractiveFlag.all,
                                ),
                                onMapReady: () {
                                  if (!mounted) return;
                                  setState(() => _mapReady = true);
                                  if (_pendingMapCenter != null) {
                                    final center = _pendingMapCenter!;
                                    final zoom = _pendingMapZoom ?? _currentZoom;
                                    _pendingMapCenter = null;
                                    _pendingMapZoom = null;
                                    _mapController.move(center, zoom);
                                  }
                                },
                                onTap: widget.viewOnly ? null : _onMapTap,
                              ),
                              children: [
                                ValueListenableBuilder<MapLayerType>(
                                  valueListenable: _mapTileService.layerTypeNotifier,
                                  builder: (context, layerType, child) {
                                    return TileLayer(
                                      urlTemplate: _mapTileService.getTileUrl(layerType),
                                      userAgentPackageName: 'dev.geogram',
                                      subdomains: const [], // No subdomains for station/OSM
                                      keepBuffer: 3,
                                      tileProvider: _mapTileService.getTileProvider(layerType),
                                      errorTileCallback: (tile, error, stackTrace) {
                                        if (!_isOnline) return;
                                        setState(() {
                                          _isOnline = false;
                                        });
                                        LogService().log('Map tiles unavailable - offline mode');
                                      },
                                    );
                                  },
                                ),
                                // Labels overlay for satellite view (city names, roads, etc.)
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
                                // Transport labels overlay for satellite view (road names, route numbers)
                                ValueListenableBuilder<MapLayerType>(
                                  valueListenable: _mapTileService.layerTypeNotifier,
                                  builder: (context, layerType, child) {
                                    if (layerType != MapLayerType.satellite) {
                                      return const SizedBox.shrink();
                                    }
                                    return Opacity(
                                      opacity: 0.6, // Soften road colors
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
                                MarkerLayer(
                                  markers: [
                                    Marker(
                                      point: _selectedPosition,
                                      width: 60,
                                      height: 60,
                                      child: Icon(
                                        Icons.location_pin,
                                        color: Colors.red,
                                        size: 40,
                                        shadows: [
                                          Shadow(
                                            blurRadius: 4,
                                            color: Colors.black.withOpacity(0.5),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            )
                          : const Center(child: CircularProgressIndicator()),
                      // Nearest-city pill, shown above the FAB so the
                      // user sees "Coimbra, Portugal" before tapping
                      // "Confirm location".
                      if (_mapInitialized)
                        Positioned(
                          left: 16,
                          right: 92,
                          bottom: 16,
                          child: IgnorePointer(
                            child: _NearestCityPill(
                              label: _nearestCityLabel,
                              loading: _nearestCityLoading,
                              i18n: _i18n,
                            ),
                          ),
                        ),
                      // Map controls (same layout as main map)
                      if (_mapInitialized)
                        Positioned(
                          top: 16,
                          right: 16,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Zoom in button
                              FloatingActionButton.small(
                                heroTag: 'zoom_in',
                                onPressed: () {
                                  final currentZoom = _mapController.camera.zoom;
                                  if (currentZoom < 18.0) {
                                    _mapController.move(
                                        _mapController.camera.center, currentZoom + 1);
                                  }
                                },
                                tooltip: _i18n.t('zoom_in'),
                                child: const Icon(Icons.add),
                              ),
                              const SizedBox(height: 8),
                              // Zoom out button
                              FloatingActionButton.small(
                                heroTag: 'zoom_out',
                                onPressed: () {
                                  final currentZoom = _mapController.camera.zoom;
                                  if (currentZoom > 1.0) {
                                    _mapController.move(
                                        _mapController.camera.center, currentZoom - 1);
                                  }
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
                              // Reset north / compass button
                              FloatingActionButton.small(
                                heroTag: 'reset_north',
                                onPressed: () {
                                  _mapController.rotate(0);
                                },
                                tooltip: _i18n.t('reset_north'),
                                child: const Icon(Icons.explore),
                              ),
                              // Auto-detect location button (only in picker mode)
                              if (!widget.viewOnly) ...[
                                const SizedBox(height: 8),
                                FloatingActionButton.small(
                                  heroTag: 'auto_detect',
                                  onPressed: _isDetectingLocation ? null : _autoDetectLocation,
                                  tooltip: _i18n.t('auto_detect_location'),
                                  child: _isDetectingLocation
                                      ? const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(strokeWidth: 2),
                                        )
                                      : const Icon(Icons.my_location),
                                ),
                              ],
                            ],
                          ),
                        ),
                    ],
                  ),
                ),

              ],
            ),
          ),
            ],
          );
        },
      ),
    );
  }
}

/// Floating pill that shows the nearest city to the current
/// selection, e.g. "Coimbra, Portugal". Used as an overlay inside the
/// LocationPickerPage map stack. Intentionally a thin stateless widget
/// so flyover updates from the parent's setState ripple in instantly.
class _NearestCityPill extends StatelessWidget {
  final String? label;
  final bool loading;
  final I18nService i18n;

  const _NearestCityPill({
    required this.label,
    required this.loading,
    required this.i18n,
  });

  @override
  Widget build(BuildContext context) {
    final text = loading && label == null
        ? i18n.t('looking_up_nearest_city')
        : (label ?? i18n.t('no_city_nearby'));
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.bottomLeft,
      child: Material(
        elevation: 2,
        borderRadius: BorderRadius.circular(20),
        color: theme.colorScheme.surface.withValues(alpha: 0.92),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.location_city,
                size: 16,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 6),
              if (loading && label == null)
                const SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                ),
              if (loading && label == null) const SizedBox(width: 6),
              Flexible(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
