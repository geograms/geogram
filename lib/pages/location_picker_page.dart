/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../services/log_service.dart';
import '../services/i18n_service.dart';

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
  final MapController _mapController = MapController();
  late TextEditingController _latController;
  late TextEditingController _lonController;
  late LatLng _selectedPosition;
  bool _isOnline = true;

  @override
  void initState() {
    super.initState();
    _selectedPosition = widget.initialPosition ?? const LatLng(0, 0);
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

  void _confirmSelection() {
    Navigator.of(context).pop(_selectedPosition);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(_i18n.t('select_location_on_map')),
        actions: [
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
      body: Row(
        children: [
          // Map View (Left Side)
          Expanded(
            flex: 2,
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
                        urlTemplate: 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png',
                        userAgentPackageName: 'dev.geogram.geogram_desktop',
                        subdomains: const ['a', 'b', 'c', 'd'],
                        retinaMode: RetinaMode.isHighDensity(context),
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

          // Manual Input Panel (Right Side)
          SizedBox(
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
      ),
    );
  }
}
