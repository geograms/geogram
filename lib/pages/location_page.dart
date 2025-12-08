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
import '../services/map_tile_service.dart' show MapTileService, TileLoadingStatus, MapLayerType;

/// Location Settings page - simplified map-based location picker
/// Saves coordinates to user profile
class LocationPage extends StatefulWidget {
  const LocationPage({super.key});

  @override
  State<LocationPage> createState() => _LocationPageState();
}

class _LocationPageState extends State<LocationPage> {
  final I18nService _i18n = I18nService();
  final ProfileService _profileService = ProfileService();
  final MapTileService _mapTileService = MapTileService();
  final MapController _mapController = MapController();
  late TextEditingController _latController;
  late TextEditingController _lonController;
  late LatLng _selectedPosition;
  bool _isOnline = true;
  bool _isDetectingLocation = false;
  bool _hasChanges = false;

  // Default to central Europe
  static const LatLng _defaultPosition = LatLng(48.0, 10.0);

  @override
  void initState() {
    super.initState();
    _initializeMap();
    _loadSavedLocation();
  }

  Future<void> _initializeMap() async {
    await _mapTileService.initialize();
    if (mounted) {
      setState(() {});
    }
  }

  void _loadSavedLocation() {
    final profile = _profileService.getProfile();

    // Load saved location from profile
    if (profile.latitude != null && profile.longitude != null) {
      _selectedPosition = LatLng(profile.latitude!, profile.longitude!);
    } else {
      _selectedPosition = _defaultPosition;
      // Auto-detect if no saved location
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _autoDetectLocation();
      });
    }

    _latController = TextEditingController(
      text: _selectedPosition.latitude.toStringAsFixed(6),
    );
    _lonController = TextEditingController(
      text: _selectedPosition.longitude.toStringAsFixed(6),
    );

    // Move map to position after build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _mapController.move(_selectedPosition, 10.0);
    });
  }

  Future<void> _autoDetectLocation() async {
    if (_isDetectingLocation) return;

    setState(() {
      _isDetectingLocation = true;
    });

    try {
      if (kIsWeb) {
        await _detectLocationViaBrowser();
      } else if (Platform.isAndroid || Platform.isIOS) {
        await _detectLocationViaGPS();
      } else {
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

  Future<void> _detectLocationViaGPS() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('location_services_disabled'))),
        );
      }
      return;
    }

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
        _hasChanges = true;
      });
      _mapController.move(_selectedPosition, 15.0);
      LogService().log('GPS location: ${position.latitude}, ${position.longitude}');
    }
  }

  Future<void> _detectLocationViaBrowser() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_i18n.t('location_permission_denied'))),
          );
        }
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
      await _detectLocationViaIP();
      return;
    }

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
        _hasChanges = true;
      });
      _mapController.move(_selectedPosition, 15.0);
      LogService().log('Browser geolocation: ${position.latitude}, ${position.longitude}');
    }
  }

  Future<void> _detectLocationViaIP() async {
    final response = await http.get(
      Uri.parse('http://ip-api.com/json/?fields=lat,lon'),
    ).timeout(const Duration(seconds: 10));

    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      final lat = data['lat'] as double?;
      final lon = data['lon'] as double?;

      if (lat != null && lon != null && mounted) {
        setState(() {
          _selectedPosition = LatLng(lat, lon);
          _latController.text = lat.toStringAsFixed(6);
          _lonController.text = lon.toStringAsFixed(6);
          _hasChanges = true;
        });
        _mapController.move(_selectedPosition, 10.0);
        LogService().log('IP-based location: $lat, $lon');
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
      _hasChanges = true;
    });
  }

  void _updateFromCoordinates() {
    final lat = double.tryParse(_latController.text);
    final lon = double.tryParse(_lonController.text);

    if (lat == null || lon == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_i18n.t('invalid_coordinates_error'))),
      );
      return;
    }

    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_i18n.t('coordinates_out_of_range'))),
      );
      return;
    }

    setState(() {
      _selectedPosition = LatLng(lat, lon);
      _hasChanges = true;
    });
    _mapController.move(_selectedPosition, _mapController.camera.zoom);
  }

  Future<void> _saveLocation() async {
    try {
      await _profileService.updateProfile(
        latitude: _selectedPosition.latitude,
        longitude: _selectedPosition.longitude,
      );

      setState(() {
        _hasChanges = false;
      });

      LogService().log('Location saved: ${_selectedPosition.latitude}, ${_selectedPosition.longitude}');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('location_saved')),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      LogService().log('Error saving location: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('error_saving_location', params: [e.toString()])),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(_i18n.t('location_settings')),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _saveLocation,
        icon: const Icon(Icons.save),
        label: Text(_i18n.t('save_location')),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      body: Column(
        children: [
          // Coordinate input bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: theme.colorScheme.surfaceContainerHighest,
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _latController,
                    decoration: InputDecoration(
                      labelText: _i18n.t('latitude'),
                      isDense: true,
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                    onSubmitted: (_) => _updateFromCoordinates(),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _lonController,
                    decoration: InputDecoration(
                      labelText: _i18n.t('longitude'),
                      isDense: true,
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                    onSubmitted: (_) => _updateFromCoordinates(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: _updateFromCoordinates,
                  icon: const Icon(Icons.search),
                  tooltip: _i18n.t('go_to_coordinates'),
                ),
              ],
            ),
          ),
          // Map
          Expanded(
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: _selectedPosition,
                    initialZoom: 10.0,
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
                          subdomains: const [],
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
                    // Labels overlay for satellite view
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
                    // Transport labels overlay for satellite view
                    ValueListenableBuilder<MapLayerType>(
                      valueListenable: _mapTileService.layerTypeNotifier,
                      builder: (context, layerType, child) {
                        if (layerType != MapLayerType.satellite) {
                          return const SizedBox.shrink();
                        }
                        return Opacity(
                          opacity: 0.6,
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
                      bottom: 80,
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
                // Map controls
                Positioned(
                  top: 16,
                  right: 16,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Zoom in
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
                      // Zoom out
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
                      // Layer toggle
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
                      // Auto-detect location
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
    );
  }
}
