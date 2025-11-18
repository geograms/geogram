import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../services/profile_service.dart';
import '../services/log_service.dart';

class LocationPage extends StatefulWidget {
  const LocationPage({super.key});

  @override
  State<LocationPage> createState() => _LocationPageState();
}

class _LocationPageState extends State<LocationPage> {
  final ProfileService _profileService = ProfileService();
  final MapController _mapController = MapController();
  final TextEditingController _latController = TextEditingController();
  final TextEditingController _lonController = TextEditingController();
  final TextEditingController _locationNameController = TextEditingController();

  LatLng _currentPosition = const LatLng(0, 0); // Default to equator
  String _locationName = '';
  bool _hasLocation = false;
  bool _isOnline = true;
  bool _locationFromIP = false;

  @override
  void initState() {
    super.initState();
    _loadLocation();
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

      // For now, check if profile has location data
      // In future, this would load from profile.latitude/longitude
      // Since we haven't added these fields to Profile yet, try IP geolocation

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
        LogService().log('Location detected from IP: ${ipLocation.latitude}, ${ipLocation.longitude}');
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
        const SnackBar(content: Text('Invalid coordinates')),
      );
      return;
    }

    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Coordinates out of range')),
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

      // TODO: Save to profile service when profile has location fields
      // await _profileService.updateProfile(
      //   latitude: _currentPosition.latitude,
      //   longitude: _currentPosition.longitude,
      //   locationName: _locationName,
      // );

      LogService().log('Saved location: $_locationName (${_currentPosition.latitude}, ${_currentPosition.longitude})');
    } catch (e) {
      LogService().log('Error saving location: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving location: $e'),
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
        title: const Text('Location Settings'),
      ),
      body: Row(
        children: [
          // Map View (Left Side)
          Expanded(
            flex: 2,
            child: Column(
              children: [
                // Map Controls Bar
                Container(
                  padding: const EdgeInsets.all(12),
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Row(
                    children: [
                      Icon(
                        Icons.map,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Interactive World Map',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const Spacer(),
                      if (!_isOnline)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.orange.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Row(
                            children: [
                              Icon(Icons.cloud_off, size: 16, color: Colors.orange),
                              SizedBox(width: 4),
                              Text('Offline', style: TextStyle(fontSize: 12)),
                            ],
                          ),
                        ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: _resetToCurrentView,
                        icon: const Icon(Icons.my_location, size: 18),
                        label: const Text('Use Map Center'),
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ],
                  ),
                ),

                // Map Widget
                Expanded(
                  child: FlutterMap(
                    mapController: _mapController,
                    options: MapOptions(
                      initialCenter: _currentPosition,
                      initialZoom: 2.0,
                      minZoom: 1.0,
                      maxZoom: 18.0,
                      onTap: _onMapTap,
                    ),
                    children: [
                      TileLayer(
                        urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'dev.geogram.geogram_desktop',
                        errorTileCallback: (tile, error, stackTrace) {
                          // Map tiles failed to load - probably offline
                          if (!_isOnline) return;
                          setState(() {
                            _isOnline = false;
                          });
                          LogService().log('Map tiles unavailable - offline mode');
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
                          'Click anywhere on the map to set your location. Use mouse wheel or +/- buttons to zoom.',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Manual Input Panel (Right Side)
          SizedBox(
            width: 350,
            child: Container(
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
                          'Location Details',
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
                          'Coordinates',
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
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.wifi, size: 12, color: Colors.blue),
                                SizedBox(width: 4),
                                Text(
                                  'Auto-detected',
                                  style: TextStyle(fontSize: 11, color: Colors.blue),
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
                          ? 'Location detected from IP address. Click map or enter coordinates to change.'
                          : 'Click on map or enter coordinates manually',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),

                    const SizedBox(height: 16),

                    // Latitude Input
                    Text(
                      'Latitude',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _latController,
                      decoration: InputDecoration(
                        hintText: '-90 to 90',
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
                      'Longitude',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _lonController,
                      decoration: InputDecoration(
                        hintText: '-180 to 180',
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
                        label: const Text('Update Map Position'),
                      ),
                    ),

                    const SizedBox(height: 24),
                    const Divider(),
                    const SizedBox(height: 16),

                    // Location Name
                    Text(
                      'Location Name (Optional)',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _locationNameController,
                      decoration: const InputDecoration(
                        hintText: 'e.g., Home, Office, Camp Site',
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
                                'Location Privacy',
                                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                      fontWeight: FontWeight.bold,
                                    ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Your location is stored locally and only shared when you explicitly choose to do so.',
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
                      title: const Text('Coordinate Format Help'),
                      leading: const Icon(Icons.help_outline, size: 20),
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: const EdgeInsets.all(12),
                      children: [
                        Text(
                          'Latitude ranges from -90° (South Pole) to +90° (North Pole).\n\n'
                          'Longitude ranges from -180° (West) to +180° (East).\n\n'
                          'Use decimal format:\n'
                          '• New York: 40.7128, -74.0060\n'
                          '• London: 51.5074, -0.1278\n'
                          '• Tokyo: 35.6762, 139.6503',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
