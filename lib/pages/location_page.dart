import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../services/profile_service.dart';
import '../services/log_service.dart';
import '../services/i18n_service.dart';
import '../services/map_tile_service.dart' show MapTileService, TileLoadingStatus, MapLayerType;

class LocationPage extends StatefulWidget {
  const LocationPage({super.key});

  @override
  State<LocationPage> createState() => _LocationPageState();
}

class _LocationPageState extends State<LocationPage> {
  final ProfileService _profileService = ProfileService();
  final I18nService _i18n = I18nService();
  final MapTileService _mapTileService = MapTileService();
  final MapController _mapController = MapController();
  final TextEditingController _latController = TextEditingController();
  final TextEditingController _lonController = TextEditingController();
  final TextEditingController _locationNameController = TextEditingController();

  LatLng _currentPosition = const LatLng(0, 0); // Default to equator
  String _locationName = '';
  bool _hasLocation = false;
  bool _isOnline = true;
  bool _locationFromIP = false;
  bool _mapInitialized = false;

  @override
  void initState() {
    super.initState();
    _initializeMap();
    _loadLocation();
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

  @override
  void dispose() {
    _latController.dispose();
    _lonController.dispose();
    _locationNameController.dispose();
    super.dispose();
  }

  Future<void> _loadLocation() async {
    try {
      final profile = _profileService.getProfile();

      // Check if profile already has location data
      if (profile.latitude != null && profile.longitude != null) {
        setState(() {
          _currentPosition = LatLng(profile.latitude!, profile.longitude!);
          _latController.text = _currentPosition.latitude.toStringAsFixed(6);
          _lonController.text = _currentPosition.longitude.toStringAsFixed(6);
          if (profile.locationName != null) {
            _locationNameController.text = profile.locationName!;
            _locationName = profile.locationName!;
          }
          _hasLocation = true;
        });
        // Move map to saved location
        _mapController.move(_currentPosition, 5.0);
        LogService().log('Location loaded from profile: ${profile.latitude}, ${profile.longitude}');
        return;
      }

      // Try to get location from IP address
      final ipLocation = await _getLocationFromIP();

      if (ipLocation != null) {
        setState(() {
          _currentPosition = ipLocation;
          _latController.text = _currentPosition.latitude.toStringAsFixed(6);
          _lonController.text = _currentPosition.longitude.toStringAsFixed(6);
          _hasLocation = true;
          _locationFromIP = true;
        });
        // Move map to detected location
        _mapController.move(_currentPosition, 5.0);
        LogService().log('Location detected from IP: ${ipLocation.latitude}, ${ipLocation.longitude}');

        // Auto-save IP-detected location to profile
        _saveLocation();
      } else {
        setState(() {
          // Fallback to center of world map
          _currentPosition = const LatLng(20, 0);
          _latController.text = _currentPosition.latitude.toStringAsFixed(6);
          _lonController.text = _currentPosition.longitude.toStringAsFixed(6);
        });
        LogService().log('Location page initialized with default coordinates');
      }
    } catch (e) {
      LogService().log('Error loading location: $e');
    }
  }

  /// Get approximate location from IP address using free API
  Future<LatLng?> _getLocationFromIP() async {
    try {
      // Use ip-api.com - free, no API key required
      final response = await http.get(
        Uri.parse('http://ip-api.com/json/'),
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data['status'] == 'success') {
          final lat = data['lat'] as double;
          final lon = data['lon'] as double;
          final city = data['city'] as String?;
          final country = data['country'] as String?;

          // Optionally set location name if available
          if (city != null && country != null && _locationNameController.text.isEmpty) {
            setState(() {
              _locationNameController.text = '$city, $country';
            });
          }

          LogService().log('IP geolocation successful: $city, $country ($lat, $lon)');
          return LatLng(lat, lon);
        }
      }

      LogService().log('IP geolocation failed: Invalid response');
      return null;
    } catch (e) {
      // Offline or API unavailable - this is expected and not an error
      LogService().log('IP geolocation unavailable (offline mode)');
      return null;
    }
  }

  void _onMapTap(TapPosition tapPosition, LatLng position) {
    setState(() {
      _currentPosition = position;
      _latController.text = position.latitude.toStringAsFixed(6);
      _lonController.text = position.longitude.toStringAsFixed(6);
      _hasLocation = true;
      _locationFromIP = false; // User manually selected location
    });

    _saveLocation();
    LogService().log('Location selected: ${position.latitude}, ${position.longitude}');
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
      _currentPosition = LatLng(lat, lon);
      _hasLocation = true;
      _locationFromIP = false; // User manually entered coordinates
    });

    // Move map to new position
    _mapController.move(_currentPosition, _mapController.camera.zoom);

    _saveLocation();
    LogService().log('Location updated manually: $lat, $lon');
  }

  Future<void> _saveLocation() async {
    try {
      _locationName = _locationNameController.text.trim();

      // Save to profile
      await _profileService.updateProfile(
        latitude: _currentPosition.latitude,
        longitude: _currentPosition.longitude,
        locationName: _locationName.isNotEmpty ? _locationName : null,
      );

      LogService().log('Saved location: $_locationName (${_currentPosition.latitude}, ${_currentPosition.longitude})');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('location_saved')),
            backgroundColor: Colors.green,
          ),
        );
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

  void _resetToCurrentView() {
    final center = _mapController.camera.center;
    setState(() {
      _currentPosition = center;
      _latController.text = center.latitude.toStringAsFixed(6);
      _lonController.text = center.longitude.toStringAsFixed(6);
      _hasLocation = true;
      _locationFromIP = false; // User manually selected map center
    });
    _saveLocation();
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_i18n.t('location_settings')),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth > 700;

          if (isWide) {
            // Desktop: side-by-side layout
            return Row(
              children: [
                Expanded(
                  flex: 2,
                  child: _buildMapSection(context),
                ),
                SizedBox(
                  width: 350,
                  child: _buildFormPanel(context),
                ),
              ],
            );
          } else {
            // Mobile: stacked layout
            return Column(
              children: [
                Expanded(
                  flex: 2,
                  child: _buildMapSection(context),
                ),
                Expanded(
                  flex: 3,
                  child: _buildFormPanel(context),
                ),
              ],
            );
          }
        },
      ),
    );
  }

  Widget _buildMapSection(BuildContext context) {
    return Column(
      children: [
        // Map Widget
        Expanded(
          child: Stack(
                    children: [
                      FlutterMap(
                        mapController: _mapController,
                        options: MapOptions(
                          initialCenter: _currentPosition,
                          initialZoom: 5.0,
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
                                subdomains: const [], // No subdomains for relay/OSM
                                tileProvider: _mapTileService.getTileProvider(layerType),
                                errorTileCallback: (tile, error, stackTrace) {
                                  // Map tiles failed to load - probably offline
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
                              if (_hasLocation)
                                Marker(
                                  point: _currentPosition,
                                  width: 60,
                                  height: 60,
                                  child: Column(
                                    children: [
                                      Icon(
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
                                    : Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.9),
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
                                        color: Theme.of(context).colorScheme.onSurface,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      _i18n.t('loading_tiles', params: [status.loadingCount.toString()]),
                                      style: Theme.of(context).textTheme.bodySmall,
                                    ),
                                  ] else if (status.hasFailures) ...[
                                    const Icon(Icons.cloud_off, size: 16, color: Colors.white),
                                    const SizedBox(width: 8),
                                    Flexible(
                                      child: Text(
                                        _i18n.t('tiles_failed', params: [status.failedCount.toString()]),
                                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white),
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
                      // Layer toggle button
                      Positioned(
                        top: 16,
                        right: 16,
                        child: ValueListenableBuilder<MapLayerType>(
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
                      ),
                    ],
                  ),
                ),

                // Map Instructions
                Container(
                  padding: const EdgeInsets.all(12),
                  color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.3),
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        size: 16,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _i18n.t('map_instructions'),
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
  }

  Widget _buildFormPanel(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          left: BorderSide(
            color: Theme.of(context).colorScheme.outline.withOpacity(0.2),
          ),
        ),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Icon(
                  Icons.edit_location,
                  color: Theme.of(context).colorScheme.primary,
                ),
                        const SizedBox(width: 8),
                        Text(
                          _i18n.t('location_details'),
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 24),

                    // Unified Coordinate Input Section
                    Row(
                      children: [
                        Icon(
                          Icons.my_location,
                          color: Theme.of(context).colorScheme.primary,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _i18n.t('coordinates'),
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                        ),
                        if (_locationFromIP) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.blue.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: Colors.blue.withOpacity(0.3)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.wifi, size: 12, color: Colors.blue),
                                const SizedBox(width: 4),
                                Text(
                                  _i18n.t('auto_detected'),
                                  style: const TextStyle(fontSize: 11, color: Colors.blue),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _locationFromIP
                          ? _i18n.t('location_auto_detected_desc')
                          : _i18n.t('location_manual_desc'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),

                    const SizedBox(height: 16),

                    // Latitude Input
                    Text(
                      _i18n.t('latitude'),
                      style: Theme.of(context).textTheme.titleSmall,
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
                          color: Theme.of(context).colorScheme.primary,
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
                      style: Theme.of(context).textTheme.titleSmall,
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
                          color: Theme.of(context).colorScheme.primary,
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

                    const SizedBox(height: 24),
                    const Divider(),
                    const SizedBox(height: 16),

                    // Location Name
                    Text(
                      _i18n.t('location_name_optional'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _locationNameController,
                      decoration: InputDecoration(
                        hintText: _i18n.t('location_name_hint'),
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.label),
                        filled: true,
                      ),
                      onChanged: (_) => _saveLocation(),
                    ),

                    const SizedBox(height: 24),
                    const Divider(),
                    const SizedBox(height: 16),

                    // Info Box
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.info,
                                size: 16,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _i18n.t('location_privacy'),
                                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                      fontWeight: FontWeight.bold,
                                    ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _i18n.t('location_privacy_desc'),
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),

            // Coordinate Format Help
            ExpansionTile(
              title: Text(_i18n.t('coordinate_format_help')),
              leading: const Icon(Icons.help_outline, size: 20),
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.all(12),
              children: [
                Text(
                  _i18n.t('coordinate_help_text'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
