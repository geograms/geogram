/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Map view page for displaying a place location with user's current position.
 * Automatically zooms to show both markers on screen.
 */

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../models/place.dart';
import '../services/i18n_service.dart';
import '../services/map_tile_service.dart' show MapTileService, MapLayerType;
import '../services/user_location_service.dart' show UserLocation;

class PlaceMapViewPage extends StatefulWidget {
  final Place place;
  final UserLocation? userLocation;

  const PlaceMapViewPage({
    super.key,
    required this.place,
    this.userLocation,
  });

  @override
  State<PlaceMapViewPage> createState() => _PlaceMapViewPageState();
}

class _PlaceMapViewPageState extends State<PlaceMapViewPage> {
  final I18nService _i18n = I18nService();
  final MapTileService _mapTileService = MapTileService();
  final MapController _mapController = MapController();

  @override
  void initState() {
    super.initState();
    _initializeMap();
  }

  Future<void> _initializeMap() async {
    await _mapTileService.initialize();
    if (mounted) {
      setState(() {});
      // Fit bounds after the map is ready
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _fitBoundsToMarkers();
      });
    }
  }

  void _fitBoundsToMarkers() {
    final placeLatLng = LatLng(widget.place.latitude, widget.place.longitude);
    final userLoc = widget.userLocation;

    if (userLoc != null && userLoc.isValid) {
      final userLatLng = LatLng(userLoc.latitude, userLoc.longitude);

      // Calculate bounds that include both points with padding
      final minLat = math.min(placeLatLng.latitude, userLatLng.latitude);
      final maxLat = math.max(placeLatLng.latitude, userLatLng.latitude);
      final minLon = math.min(placeLatLng.longitude, userLatLng.longitude);
      final maxLon = math.max(placeLatLng.longitude, userLatLng.longitude);

      // Add padding (10% of the range)
      final latPadding = (maxLat - minLat) * 0.15;
      final lonPadding = (maxLon - minLon) * 0.15;

      // Ensure minimum padding for very close points
      final effectiveLatPadding = math.max(latPadding, 0.005);
      final effectiveLonPadding = math.max(lonPadding, 0.005);

      final bounds = LatLngBounds(
        LatLng(minLat - effectiveLatPadding, minLon - effectiveLonPadding),
        LatLng(maxLat + effectiveLatPadding, maxLon + effectiveLonPadding),
      );

      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: bounds,
          padding: const EdgeInsets.all(50),
        ),
      );
    } else {
      // Only place location available, center on it with default zoom
      _mapController.move(placeLatLng, 15);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final placeLatLng = LatLng(widget.place.latitude, widget.place.longitude);
    final userLoc = widget.userLocation;
    final userLatLng = (userLoc != null && userLoc.isValid)
        ? LatLng(userLoc.latitude, userLoc.longitude)
        : null;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.place.name),
      ),
      floatingActionButton: Column(
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
          const SizedBox(height: 8),
          // Fit to both markers
          if (userLatLng != null)
            FloatingActionButton.small(
              heroTag: 'fit_bounds',
              onPressed: _fitBoundsToMarkers,
              tooltip: _i18n.t('fit_to_view'),
              child: const Icon(Icons.zoom_out_map),
            ),
          if (userLatLng != null) const SizedBox(height: 8),
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
        ],
      ),
      body: FlutterMap(
        mapController: _mapController,
        options: MapOptions(
          initialCenter: placeLatLng,
          initialZoom: 15,
          minZoom: 1.0,
          maxZoom: 18.0,
          interactionOptions: const InteractionOptions(
            flags: InteractiveFlag.all,
          ),
        ),
        children: [
          ValueListenableBuilder<MapLayerType>(
            valueListenable: _mapTileService.layerTypeNotifier,
            builder: (context, layerType, child) {
              return TileLayer(
                urlTemplate: _mapTileService.getTileUrl(layerType),
                userAgentPackageName: 'dev.geogram',
                subdomains: const [],
                keepBuffer: 3,
                tileProvider: _mapTileService.getTileProvider(layerType),
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
                userAgentPackageName: 'dev.geogram',
                subdomains: const [],
                keepBuffer: 3,
                tileProvider: _mapTileService.getLabelsProvider(),
              );
            },
          ),
          MarkerLayer(
            markers: [
              // Place marker (red pin)
              Marker(
                point: placeLatLng,
                width: 60,
                height: 60,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        borderRadius: BorderRadius.circular(4),
                        boxShadow: [
                          BoxShadow(
                            blurRadius: 4,
                            color: Colors.black.withOpacity(0.3),
                          ),
                        ],
                      ),
                      child: Text(
                        widget.place.name,
                        style: TextStyle(
                          color: theme.colorScheme.onPrimary,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Icon(
                      Icons.location_pin,
                      color: Colors.red,
                      size: 36,
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
              // User location marker (blue dot)
              if (userLatLng != null)
                Marker(
                  point: userLatLng,
                  width: 30,
                  height: 30,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.blue,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 3),
                      boxShadow: [
                        BoxShadow(
                          blurRadius: 4,
                          color: Colors.black.withOpacity(0.3),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.person,
                      color: Colors.white,
                      size: 16,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
