/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io' if (dart.library.html) '../platform/io_stub.dart' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'dart:convert';
import '../services/log_service.dart';
import '../services/i18n_service.dart';
import '../services/profile_service.dart';
import '../services/config_service.dart';
import '../services/map_tile_service.dart' show MapTileService, TileLoadingStatus, MapLayerType;

/// Full-page reusable location picker
/// Can be used throughout the app for selecting coordinates
class LocationPickerPage extends StatefulWidget {
  final LatLng? initialPosition;

  const LocationPickerPage({
    Key? key,
    this.initialPosition,
  }) : super(key: key);

  @override
  State<LocationPickerPage> createState() => _LocationPickerPageState();
}

class _LocationPickerPageState extends State<LocationPickerPage> {
  final I18nService _i18n = I18nService();
  final ProfileService _profileService = ProfileService();
  final ConfigService _configService = ConfigService();
  final MapTileService _mapTileService = MapTileService();
  final MapController _mapController = MapController();
  late TextEditingController _latController;
  late TextEditingController _lonController;
  late LatLng _selectedPosition;
  bool _isOnline = true;
  bool _isDetectingLocation = false;
  double _currentZoom = 17.0; // Default zoom level for usable location selection

  // Default to central Europe (Munich/Vienna area)
  static const LatLng _defaultPosition = LatLng(48.0, 10.0);
  static const double _defaultZoom = 17.0;

  @override
  void initState() {
    super.initState();
    _initializeMap();

    // Load saved zoom level preference
    final savedZoom = _configService.get('lastLocationPickerZoom');
    if (savedZoom != null) {
      _currentZoom = (savedZoom as num).toDouble();
    }

    // Priority: 1) provided initialPosition, 2) auto-detect current location, 3) last saved, 4) default
    if (widget.initialPosition != null) {
      _selectedPosition = widget.initialPosition!;
      _initializeControllers();
    } else {
      // Start with default position, then try to auto-detect
      _selectedPosition = _defaultPosition;
      _initializeControllers();

      // Automatically try to detect the user's current location
      _autoDetectLocationOnStart();
    }
  }

  /// Automatically detect location when the picker opens
  /// Falls back to last saved position, then GeoIP if detection fails
  Future<void> _autoDetectLocationOnStart() async {
    setState(() {
      _isDetectingLocation = true;
    });

    try {
      if (kIsWeb) {
        // On web, try browser geolocation first
        await _tryBrowserGeolocation();
      } else if (Platform.isAndroid || Platform.isIOS) {
        // On mobile, try GPS
        await _tryGPSLocation();
      } else {
        // On desktop, use IP-based geolocation
        await _detectLocationViaIP();
      }
    } catch (e) {
      LogService().log('Auto-detect failed, trying fallbacks: $e');

      // Fallback 1: Try last saved position
      final lastLat = _configService.get('lastLocationPickerLat');
      final lastLon = _configService.get('lastLocationPickerLon');

      if (lastLat != null && lastLon != null && mounted) {
        final lat = lastLat as double;
        final lon = lastLon as double;
        setState(() {
          _selectedPosition = LatLng(lat, lon);
          _latController.text = lat.toStringAsFixed(6);
          _lonController.text = lon.toStringAsFixed(6);
        });
        _mapController.move(_selectedPosition, _currentZoom);
        LogService().log('Using last saved position');
      } else {
        // Fallback 2: Try GeoIP
        try {
          await _fetchGeoIPLocation();
        } catch (e2) {
          LogService().log('GeoIP also failed: $e2');
          // Stay at default position
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _isDetectingLocation = false;
        });
      }
    }
  }

  /// Try to get browser geolocation without showing error messages
  Future<void> _tryBrowserGeolocation() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      // Fall back to IP-based
      await _detectLocationViaIP();
      return;
    }

    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 10),
      ),
    );

    if (mounted) {
      setState(() {
        _selectedPosition = LatLng(position.latitude, position.longitude);
        _latController.text = position.latitude.toStringAsFixed(6);
        _lonController.text = position.longitude.toStringAsFixed(6);
      });
      _mapController.move(_selectedPosition, _currentZoom);
      LogService().log('Browser geolocation on start: ${position.latitude}, ${position.longitude}');
    }
  }

  /// Try to get GPS location without showing error messages
  Future<void> _tryGPSLocation() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      // Fall back to IP-based
      await _detectLocationViaIP();
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      // Fall back to IP-based
      await _detectLocationViaIP();
      return;
    }

    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 10),
      ),
    );

    if (mounted) {
      setState(() {
        _selectedPosition = LatLng(position.latitude, position.longitude);
        _latController.text = position.latitude.toStringAsFixed(6);
        _lonController.text = position.longitude.toStringAsFixed(6);
      });
      _mapController.move(_selectedPosition, _currentZoom);
      LogService().log('GPS location on start: ${position.latitude}, ${position.longitude}');
    }
  }

  Future<void> _initializeMap() async {
    // Initialize tile caching
    await _mapTileService.initialize();
    // Rebuild after initialization to ensure GeogramTileProvider is used
    if (mounted) {
      setState(() {});
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
      _mapController.move(_selectedPosition, _currentZoom);
    });
  }

  Future<void> _fetchGeoIPLocation() async {
    try {
      // Use ip-api.com free GeoIP service (no API key required)
      final response = await http.get(
        Uri.parse('http://ip-api.com/json/?fields=lat,lon'),
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final lat = data['lat'] as double?;
        final lon = data['lon'] as double?;

        if (lat != null && lon != null && mounted) {
          setState(() {
            _selectedPosition = LatLng(lat, lon);
            _latController.text = lat.toStringAsFixed(6);
            _lonController.text = lon.toStringAsFixed(6);
          });

          // Smoothly move map to GeoIP location
          _mapController.move(_selectedPosition, _currentZoom);

          LogService().log('GeoIP location: $lat, $lon');
        }
      }
    } catch (e) {
      // Silently fail - already defaulted to Europe
      LogService().log('Could not fetch GeoIP location: $e');
    }
  }

  /// Auto-detect current location
  /// Uses browser Geolocation API on web, GPS on Android, IP-based geolocation on desktop
  Future<void> _autoDetectLocation() async {
    if (_isDetectingLocation) return;

    setState(() {
      _isDetectingLocation = true;
    });

    try {
      if (kIsWeb) {
        // Use browser Geolocation API on web (requests permission automatically)
        await _detectLocationViaBrowser();
      } else if (Platform.isAndroid) {
        // Use GPS on Android
        await _detectLocationViaGPS();
      } else {
        // Use IP-based geolocation on desktop (Windows, Linux, macOS)
        await _detectLocationViaIP();
      }
    } catch (e) {
      LogService().log('Error auto-detecting location: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('location_detection_failed'))),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isDetectingLocation = false;
        });
      }
    }
  }

  /// Detect location using GPS (Android)
  Future<void> _detectLocationViaGPS() async {
    // Check if location services are enabled
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('location_services_disabled'))),
        );
      }
      return;
    }

    // Check and request permission
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_i18n.t('location_permission_denied'))),
          );
        }
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('location_permission_permanent_denied'))),
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

    if (mounted) {
      setState(() {
        _selectedPosition = LatLng(position.latitude, position.longitude);
        _latController.text = position.latitude.toStringAsFixed(6);
        _lonController.text = position.longitude.toStringAsFixed(6);
      });

      _mapController.move(_selectedPosition, _currentZoom);

      LogService().log('GPS location: ${position.latitude}, ${position.longitude}');
    }
  }

  /// Detect location using Browser Geolocation API (Web)
  /// This will prompt the user for permission if not already granted
  Future<void> _detectLocationViaBrowser() async {
    // Check and request permission - geolocator handles browser permission dialog
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_i18n.t('location_permission_denied'))),
          );
        }
        // Fall back to IP-based geolocation
        await _detectLocationViaIP();
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('location_permission_permanent_denied'))),
        );
      }
      // Fall back to IP-based geolocation
      await _detectLocationViaIP();
      return;
    }

    // Get current position using browser's Geolocation API
    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 15),
      ),
    );

    if (mounted) {
      setState(() {
        _selectedPosition = LatLng(position.latitude, position.longitude);
        _latController.text = position.latitude.toStringAsFixed(6);
        _lonController.text = position.longitude.toStringAsFixed(6);
      });

      _mapController.move(_selectedPosition, _currentZoom);

      LogService().log('Browser geolocation: ${position.latitude}, ${position.longitude}');
    }
  }

  /// Detect location using IP address (Desktop)
  Future<void> _detectLocationViaIP() async {
    final response = await http.get(
      Uri.parse('http://ip-api.com/json/?fields=lat,lon,city,country'),
    ).timeout(const Duration(seconds: 10));

    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      final lat = data['lat'] as double?;
      final lon = data['lon'] as double?;
      final city = data['city'] as String? ?? '';
      final country = data['country'] as String? ?? '';

      if (lat != null && lon != null && mounted) {
        setState(() {
          _selectedPosition = LatLng(lat, lon);
          _latController.text = lat.toStringAsFixed(6);
          _lonController.text = lon.toStringAsFixed(6);
        });

        _mapController.move(_selectedPosition, _currentZoom);

        LogService().log('IP-based location: $lat, $lon ($city, $country)');
      }
    } else {
      throw Exception('Failed to fetch IP location: ${response.statusCode}');
    }
  }

  @override
  void dispose() {
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
        title: Text(_i18n.t('select_location_on_map')),
      ),
      floatingActionButton: FloatingActionButton.extended(
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
                      FlutterMap(
                        mapController: _mapController,
                        options: MapOptions(
                          initialCenter: _selectedPosition,
                          initialZoom: _currentZoom,
                          minZoom: 1.0,
                          maxZoom: 18.0,
                          interactionOptions: const InteractionOptions(
                            flags: InteractiveFlag.all,
                          ),
                          onTap: _onMapTap,
                        ),
                        children: [
                          ValueListenableBuilder<MapLayerType>(
                            valueListenable: _mapTileService.layerTypeNotifier,
                            builder: (context, layerType, child) {
                              return TileLayer(
                                urlTemplate: _mapTileService.getTileUrl(layerType),
                                userAgentPackageName: 'dev.geogram.geogram_desktop',
                                subdomains: const [], // No subdomains for station/OSM
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
                                userAgentPackageName: 'dev.geogram.geogram_desktop',
                                subdomains: const [],
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
                                  userAgentPackageName: 'dev.geogram.geogram_desktop',
                                  subdomains: const [],
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
                            right: 16,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color: status.hasFailures
                                    ? Colors.orange.shade800.withValues(alpha: 0.9)
                                    : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.9),
                                borderRadius: BorderRadius.circular(8),
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
                                        color: theme.colorScheme.onSurface,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      _i18n.t('loading_tiles', params: [status.loadingCount.toString()]),
                                      style: theme.textTheme.bodySmall,
                                    ),
                                  ] else if (status.hasFailures) ...[
                                    const Icon(Icons.cloud_off, size: 16, color: Colors.white),
                                    const SizedBox(width: 8),
                                    Flexible(
                                      child: Text(
                                        _i18n.t('tiles_failed', params: [status.failedCount.toString()]),
                                        style: theme.textTheme.bodySmall?.copyWith(color: Colors.white),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                      // Map controls (same layout as main map)
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
                                  _mapController.move(_mapController.camera.center, currentZoom + 1);
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
                                  _mapController.move(_mapController.camera.center, currentZoom - 1);
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
                            const SizedBox(height: 8),
                            // Auto-detect location button
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
