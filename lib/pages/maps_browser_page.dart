/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../models/map_item.dart';
import '../models/report.dart';
import '../services/maps_service.dart';
import '../services/profile_service.dart';
import '../services/relay_service.dart';
import '../services/i18n_service.dart';
import '../services/log_service.dart';
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
  final I18nService _i18n = I18nService();
  final MapController _mapController = MapController();

  late TabController _tabController;

  // State
  List<MapItem> _allItems = [];
  Map<MapItemType, List<MapItem>> _groupedItems = {};
  List<MapItemType> _sortedTypes = [];
  MapItem? _selectedItem;
  final Set<MapItemType> _visibleLayers = Set.from(MapItemType.values);
  double _radiusKm = 30.0;
  LatLng? _centerPosition;
  bool _isLoading = true;
  final Set<MapItemType> _expandedGroups = Set.from(MapItemType.values);

  // Map loading state
  int _tilesLoading = 0;
  int _tilesLoaded = 0;
  bool _mapReady = false;

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
    // Get user's saved location
    final userLocation = _mapsService.getUserLocation();
    if (userLocation != null) {
      setState(() {
        _centerPosition = LatLng(userLocation.$1, userLocation.$2);
      });
    } else {
      // Default to center of world map
      setState(() {
        _centerPosition = const LatLng(20, 0);
      });
    }

    await _loadItems();
  }

  Future<void> _loadItems({bool forceRefresh = false}) async {
    if (_centerPosition == null) return;

    setState(() => _isLoading = true);

    try {
      final items = await _mapsService.loadAllMapItems(
        centerLat: _centerPosition!.latitude,
        centerLon: _centerPosition!.longitude,
        radiusKm: _radiusKm,
        visibleTypes: _visibleLayers,
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
    _loadItems();
  }

  void _setRadius(double radius) {
    setState(() {
      _radiusKm = radius;
    });

    // Zoom map to fit the new radius
    if (_centerPosition != null && _mapReady) {
      final zoom = _getZoomForRadius(radius);
      _mapController.move(_centerPosition!, zoom);
    }
  }

  void _onRadiusChangeEnd(double radius) {
    // Only reload items when user finishes dragging the slider
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
      case MapItemType.report:
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

  Color _getTypeColor(MapItemType type) {
    switch (type) {
      case MapItemType.event:
        return Colors.blue;
      case MapItemType.place:
        return Colors.green;
      case MapItemType.news:
        return Colors.orange;
      case MapItemType.report:
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
      case MapItemType.report:
        return Icons.warning;
      case MapItemType.relay:
        return Icons.cell_tower;
      case MapItemType.contact:
        return Icons.person_pin;
    }
  }

  String _getTileUrl() {
    try {
      final relay = RelayService().getPreferredRelay();
      final profile = _profileService.getProfile();

      if (relay != null && relay.url.isNotEmpty && profile.callsign.isNotEmpty) {
        var relayUrl = relay.url;

        if (relayUrl.startsWith('ws://')) {
          relayUrl = relayUrl.replaceFirst('ws://', 'http://');
        } else if (relayUrl.startsWith('wss://')) {
          relayUrl = relayUrl.replaceFirst('wss://', 'https://');
        }

        if (relayUrl.endsWith('/')) {
          relayUrl = relayUrl.substring(0, relayUrl.length - 1);
        }

        return '$relayUrl/tiles/${profile.callsign}/{z}/{x}/{y}.png';
      }
    } catch (e) {
      LogService().log('MapsBrowserPage: Error getting relay tile URL: $e');
    }

    return 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
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

          // Refresh button
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _loadItems(forceRefresh: true),
            tooltip: _i18n.t('refresh'),
          ),
        ],
      ),
    );
  }

  Widget _buildLayerToggles() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: MapItemType.values.map((type) {
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
                    if (count > 0) ...[
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

    // Calculate initial zoom based on current radius
    final initialZoom = _getZoomForRadius(_radiusKm);

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: _centerPosition!,
            initialZoom: initialZoom,
            minZoom: 1.0,
            maxZoom: 18.0,
            onMapReady: () {
              setState(() => _mapReady = true);
            },
            onTap: (_, __) {
              setState(() => _selectedItem = null);
            },
          ),
          children: [
            TileLayer(
              urlTemplate: _getTileUrl(),
              userAgentPackageName: 'dev.geogram.geogram_desktop',
              subdomains: const [],
              tileBuilder: (context, tileWidget, tile) {
                return tileWidget;
              },
              evictErrorTileStrategy: EvictErrorTileStrategy.notVisibleRespectMargin,
              tileProvider: NetworkTileProvider(),
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

            // Item markers (rendered before user marker so user marker is on top)
            MarkerLayer(
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

    // Use sorted types (non-empty first) and filter for visible layers
    final visibleTypes = _sortedTypes
        .where((type) => _visibleLayers.contains(type))
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

              // Group items
              if (isExpanded && items.isNotEmpty)
                ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, itemIndex) {
                    final item = items[itemIndex];
                    final isSelected = _selectedItem == item;

                    return ListTile(
                      selected: isSelected,
                      selectedTileColor:
                          _getTypeColor(type).withValues(alpha: 0.1),
                      leading: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: _getTypeColor(type).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          _getTypeIcon(type),
                          color: _getTypeColor(type),
                          size: 20,
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

              if (isExpanded && items.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
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
      padding: const EdgeInsets.all(16),
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

          // Open details button
          FilledButton.icon(
            onPressed: () => _openItemDetail(item),
            icon: const Icon(Icons.open_in_new, size: 18),
            label: Text(_i18n.t('open')),
          ),

          const SizedBox(width: 8),

          // Close button
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => setState(() => _selectedItem = null),
            tooltip: _i18n.t('close'),
          ),
        ],
      ),
    );
  }
}
