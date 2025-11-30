/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io' show Platform;
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
import '../services/map_tile_service.dart';

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

  // Default to central Europe (Munich/Vienna area)
  static const LatLng _defaultPosition = LatLng(48.0, 10.0);

  @override
  void initState() {
    super.initState();
    _initializeMap();

    // Priority: 1) provided initialPosition, 2) last saved position, 3) GeoIP, 4) Europe default
    if (widget.initialPosition != null) {
      _selectedPosition = widget.initialPosition!;
      _initializeControllers();
    } else {
      // Try to get last saved position from config
      final lastLat = _configService.get('lastLocationPickerLat');
      final lastLon = _configService.get('lastLocationPickerLon');

      if (lastLat != null && lastLon != null) {
        _selectedPosition = LatLng(lastLat as double, lastLon as double);
        _initializeControllers();
      } else {
        // Try GeoIP, fallback to Europe default
        _selectedPosition = _defaultPosition;
        _initializeControllers();
        _fetchGeoIPLocation();
      }
    }
  }

  Future<void> _initializeMap() async {
    // Initialize tile caching
    await _mapTileService.initialize();
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
      _mapController.move(_selectedPosition, 10.0);
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
          _mapController.move(_selectedPosition, 10.0);

          LogService().log('GeoIP location: $lat, $lon');
        }
      }
    } catch (e) {
      // Silently fail - already defaulted to Europe
      LogService().log('Could not fetch GeoIP location: $e');
    }
  }

  /// Auto-detect current location
  /// Uses GPS on Android, IP-based geolocation on desktop
  Future<void> _autoDetectLocation() async {
    if (_isDetectingLocation) return;

    setState(() {
      _isDetectingLocation = true;
    });

    try {
      // Check if we're on Android (mobile) or desktop
      final isAndroid = Platform.isAndroid;

      if (isAndroid) {
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

      _mapController.move(_selectedPosition, 15.0);

      LogService().log('GPS location: ${position.latitude}, ${position.longitude}');

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_i18n.t('location_detected_gps'))),
      );
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

        _mapController.move(_selectedPosition, 10.0);

        LogService().log('IP-based location: $lat, $lon ($city, $country)');

        final locationText = city.isNotEmpty ? '$city, $country' : _i18n.t('location_detected');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(locationText)),
        );
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

  void _updateFromManualInput() {
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
    });

    // Move map to new position
    _mapController.move(_selectedPosition, _mapController.camera.zoom);
  }

  Future<void> _confirmSelection() async {
    // Save the selected position for next time
    await _configService.set('lastLocationPickerLat', _selectedPosition.latitude);
    await _configService.set('lastLocationPickerLon', _selectedPosition.longitude);

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
        actions: [
          // Auto-detect location button
          _isDetectingLocation
              ? const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : IconButton.filledTonal(
                  onPressed: _autoDetectLocation,
                  icon: const Icon(Icons.my_location),
                  tooltip: _i18n.t('auto_detect_location'),
                ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: _confirmSelection,
            icon: const Icon(Icons.check),
            label: Text(_i18n.t('confirm_location')),
            style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
          const SizedBox(width: 16),
        ],
      ),
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
                  child: FlutterMap(
                    mapController: _mapController,
                    options: MapOptions(
                      initialCenter: _selectedPosition,
                      initialZoom: 10.0,
                      minZoom: 1.0,
                      maxZoom: 18.0,
                      onTap: _onMapTap,
                    ),
                    children: [
                      TileLayer(
                        urlTemplate: _mapTileService.getTileUrl(),
                        userAgentPackageName: 'dev.geogram.geogram_desktop',
                        subdomains: const [], // No subdomains for relay/OSM
                        tileProvider: _mapTileService.getTileProvider(),
                        errorTileCallback: (tile, error, stackTrace) {
                          if (!_isOnline) return;
                          setState(() {
                            _isOnline = false;
                          });
                          LogService().log('Map tiles unavailable - offline mode');
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
                ),

                // Map Instructions
                Container(
                  padding: const EdgeInsets.all(12),
                  color: theme.colorScheme.primaryContainer.withOpacity(0.3),
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        size: 16,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _i18n.t('map_instructions'),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Manual Input Panel
          isPortrait
              ? Container(
                  height: 200,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    border: Border(
                      top: BorderSide(
                        color: theme.colorScheme.outline.withOpacity(0.2),
                      ),
                    ),
                  ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Coordinates Section
                    Row(
                      children: [
                        Icon(
                          Icons.my_location,
                          color: theme.colorScheme.primary,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _i18n.t('coordinates'),
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Latitude Input
                    Text(
                      _i18n.t('latitude'),
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _latController,
                      decoration: InputDecoration(
                        hintText: _i18n.t('latitude_range'),
                        border: const OutlineInputBorder(),
                        filled: true,
                        suffixText: '°',
                        prefixIcon: Icon(
                          Icons.arrow_upward,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                        signed: true,
                      ),
                    ),

                    const SizedBox(height: 16),

                    // Longitude Input
                    Text(
                      _i18n.t('longitude'),
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _lonController,
                      decoration: InputDecoration(
                        hintText: _i18n.t('longitude_range'),
                        border: const OutlineInputBorder(),
                        filled: true,
                        suffixText: '°',
                        prefixIcon: Icon(
                          Icons.arrow_forward,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                        signed: true,
                      ),
                    ),

                    const SizedBox(height: 16),

                    // Update Button
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _updateFromManualInput,
                        icon: const Icon(Icons.update),
                        label: Text(_i18n.t('update_map_position')),
                      ),
                    ),
                  ],
                ),
              ),
            )
              : SizedBox(
                  width: 350,
                  child: Container(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface,
                      border: Border(
                        left: BorderSide(
                          color: theme.colorScheme.outline.withOpacity(0.2),
                        ),
                      ),
                    ),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Coordinates Section
                          Row(
                            children: [
                              Icon(
                                Icons.my_location,
                                color: theme.colorScheme.primary,
                                size: 20,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _i18n.t('coordinates'),
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),

                          // Latitude Input
                          Text(
                            _i18n.t('latitude'),
                            style: theme.textTheme.titleSmall,
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _latController,
                            decoration: InputDecoration(
                              hintText: _i18n.t('latitude_range'),
                              border: const OutlineInputBorder(),
                              filled: true,
                              suffixText: '°',
                              prefixIcon: Icon(
                                Icons.arrow_upward,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                              signed: true,
                            ),
                          ),

                          const SizedBox(height: 16),

                          // Longitude Input
                          Text(
                            _i18n.t('longitude'),
                            style: theme.textTheme.titleSmall,
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _lonController,
                            decoration: InputDecoration(
                              hintText: _i18n.t('longitude_range'),
                              border: const OutlineInputBorder(),
                              filled: true,
                              suffixText: '°',
                              prefixIcon: Icon(
                                Icons.arrow_forward,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                              signed: true,
                            ),
                          ),

                          const SizedBox(height: 16),

                          // Update Button
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: _updateFromManualInput,
                              icon: const Icon(Icons.update),
                              label: Text(_i18n.t('update_map_position')),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
