/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io' show Directory, File, Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:url_launcher/url_launcher.dart';
import '../models/place.dart';
import '../services/place_service.dart';
import '../services/i18n_service.dart';
import '../services/log_service.dart';
import '../services/station_place_service.dart';
import '../platform/file_image_helper.dart' as file_helper;
import 'add_edit_place_page.dart';
import 'photo_viewer_page.dart';

/// Places browser page
class PlacesBrowserPage extends StatefulWidget {
  final String collectionPath;
  final String collectionTitle;

  const PlacesBrowserPage({
    Key? key,
    required this.collectionPath,
    required this.collectionTitle,
  }) : super(key: key);

  @override
  State<PlacesBrowserPage> createState() => _PlacesBrowserPageState();
}

class _PlacesBrowserPageState extends State<PlacesBrowserPage> {
  final PlaceService _placeService = PlaceService();
  final I18nService _i18n = I18nService();
  final TextEditingController _searchController = TextEditingController();
  final StationPlaceService _stationPlaceService = StationPlaceService();

  List<Place> _allPlaces = [];
  List<Place> _filteredPlaces = [];
  List<StationPlaceEntry> _stationPlaces = [];
  List<StationPlaceEntry> _filteredStationPlaces = [];
  Place? _selectedPlace;
  List<String> _selectedPlacePhotos = [];
  String? _selectedType;
  Set<String> _types = {};
  bool _isLoading = true;
  bool _isLoadingStationPlaces = false;
  bool _selectedPlaceIsStation = false;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_filterPlaces);
    _initialize();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    await _loadPlaces();
    await _loadStationPlaces();
  }

  Future<void> _loadPlaces() async {
    setState(() => _isLoading = true);

    try {
      await _placeService.initializeCollection(widget.collectionPath);
      final places = await _placeService.loadAllPlaces();

      // Sort by name
      places.sort((a, b) => a.name.compareTo(b.name));

      Place? selectedPlace = _selectedPlace;
      if (!_selectedPlaceIsStation && _selectedPlace != null) {
        selectedPlace = places.firstWhere(
          (place) => place.folderPath == _selectedPlace?.folderPath,
          orElse: () => _selectedPlace!,
        );
      }

      if (!mounted) return;

      setState(() {
        _allPlaces = places;
        _selectedPlace = selectedPlace;
        _types = _computeTypes();
        _isLoading = false;
      });

      _filterPlaces();

      if (selectedPlace != null) {
        await _loadPlacePhotos(selectedPlace);
      } else if (mounted) {
        setState(() => _selectedPlacePhotos = []);
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading places: $e')),
        );
      }
    }
  }

  Future<void> _loadStationPlaces() async {
    setState(() => _isLoadingStationPlaces = true);

    final result = await _stationPlaceService.fetchPlaces();
    if (!mounted) return;

    if (!result.success) {
      setState(() => _isLoadingStationPlaces = false);
      if (result.error != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading station places: ${result.error}')),
        );
      }
      return;
    }

    final entries = result.places;
    entries.sort((a, b) => a.place.name.compareTo(b.place.name));

    StationPlaceEntry? selectedEntry;
    Place? selectedPlace = _selectedPlace;
    var selectedIsStation = _selectedPlaceIsStation;
    if (selectedIsStation && _selectedPlace?.folderPath != null) {
      for (final entry in entries) {
        if (entry.place.folderPath == _selectedPlace?.folderPath) {
          selectedEntry = entry;
          break;
        }
      }
      if (selectedEntry != null) {
        selectedPlace = selectedEntry.place;
      } else {
        selectedPlace = null;
        selectedIsStation = false;
      }
    }

    setState(() {
      _stationPlaces = entries;
      _selectedPlace = selectedPlace;
      _selectedPlaceIsStation = selectedIsStation;
      _types = _computeTypes();
      _isLoadingStationPlaces = false;
      if (selectedPlace == null) {
        _selectedPlacePhotos = [];
      }
    });

    _filterPlaces();

    if (selectedEntry != null) {
      await _loadPlacePhotos(selectedEntry.place);
    }
  }

  Set<String> _computeTypes() {
    final types = <String>{};
    types.addAll(_placeService.getTypes(_allPlaces));
    types.addAll(
      _placeService.getTypes(
        _stationPlaces.map((entry) => entry.place).toList(),
      ),
    );
    return types;
  }

  void _filterPlaces() {
    final query = _searchController.text;
    var filteredLocal = _allPlaces;
    var filteredStation = _stationPlaces;

    // Apply type filter
    if (_selectedType != null) {
      filteredLocal = _placeService.filterByType(filteredLocal, _selectedType);
      filteredStation = filteredStation
          .where((entry) => entry.place.type == _selectedType)
          .toList();
    }

    // Apply search filter
    if (query.isNotEmpty) {
      filteredLocal = _placeService.searchPlaces(filteredLocal, query);
      if (filteredStation.isNotEmpty) {
        final filteredStationPlaces = _placeService.searchPlaces(
          filteredStation.map((entry) => entry.place).toList(),
          query,
        );
        final allowed = filteredStationPlaces.toSet();
        filteredStation = filteredStation
            .where((entry) => allowed.contains(entry.place))
            .toList();
      }
    }

    setState(() {
      _filteredPlaces = filteredLocal;
      _filteredStationPlaces = filteredStation;
    });
  }

  void _selectPlace(Place place) {
    setState(() {
      _selectedPlace = place;
      _selectedPlaceIsStation = false;
      _selectedPlacePhotos = [];
    });
    _loadPlacePhotos(place);
  }

  void _selectStationPlace(StationPlaceEntry entry) {
    setState(() {
      _selectedPlace = entry.place;
      _selectedPlaceIsStation = true;
      _selectedPlacePhotos = [];
    });
    _loadPlacePhotos(entry.place);
  }

  void _selectType(String? type) {
    setState(() {
      _selectedType = type;
    });
    _filterPlaces();
  }

  Future<void> _refreshAllPlaces() async {
    await Future.wait([
      _loadPlaces(),
      _loadStationPlaces(),
    ]);
  }

  Future<void> _editPlace(Place place) async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (context) => AddEditPlacePage(
          collectionPath: widget.collectionPath,
          place: place,
        ),
      ),
    );

    if (result == true && mounted) {
      await _refreshAllPlaces();
    }
  }

  Future<void> _deletePlace(Place place) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('delete_place')),
        content: Text(_i18n.t('delete_place_confirm', params: [place.name])),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(_i18n.t('delete')),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final success = await _placeService.deletePlace(place);

      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_i18n.t('place_deleted', params: [place.name]))),
        );
        if (_selectedPlace?.folderPath == place.folderPath) {
          setState(() {
            _selectedPlace = null;
            _selectedPlacePhotos = [];
          });
        }
        await _loadPlaces();
      }
    }
  }

  Future<void> _loadPlacePhotos(Place place) async {
    if (kIsWeb || place.folderPath == null) {
      if (mounted) {
        setState(() => _selectedPlacePhotos = []);
      }
      return;
    }

    final folderPath = place.folderPath!;
    try {
      final photos = await _listPlacePhotos(folderPath);

      if (!mounted || _selectedPlace?.folderPath != folderPath) {
        return;
      }

      setState(() => _selectedPlacePhotos = photos);
    } catch (e) {
      LogService().log('PlacesBrowserPage: Error loading photos: $e');
    }
  }

  void _openPhotoViewer(int index) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PhotoViewerPage(
          imagePaths: _selectedPlacePhotos,
          initialIndex: index,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_i18n.t('places')),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () async {
              final result = await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => AddEditPlacePage(
                    collectionPath: widget.collectionPath,
                  ),
                ),
              );

              if (result == true) {
                await _refreshAllPlaces();
              }
            },
            tooltip: _i18n.t('new_place'),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refreshAllPlaces,
            tooltip: _i18n.t('refresh'),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          // Use two-panel layout for wide screens, single panel for narrow
          final isWideScreen = constraints.maxWidth >= 600;

          if (isWideScreen) {
            // Desktop/landscape: Two-panel layout
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Left panel: Place list
                Expanded(
                  flex: 1,
                  child: _buildPlaceList(context),
                ),
                const VerticalDivider(width: 1),
                // Right panel: Place detail
                Expanded(
                  flex: 2,
                  child: _buildPlaceDetailPanel(),
                ),
              ],
            );
          } else {
            // Mobile/portrait: Single panel
            // Show place list, detail opens in full screen
            return _buildPlaceList(context, isMobileView: true);
          }
        },
      ),
    );
  }

  Widget _buildPlaceList(BuildContext context, {bool isMobileView = false}) {
    final theme = Theme.of(context);
    final myPlaces = _filteredPlaces;
    final stationPlaces = _filteredStationPlaces;
    final hasFilters = _searchController.text.isNotEmpty || _selectedType != null;
    final totalPlaces = _allPlaces.length + _stationPlaces.length;

    return Column(
      children: [
        // Search bar
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: _i18n.t('search_places'),
              prefixIcon: const Icon(Icons.search),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () => _searchController.clear(),
                    )
                  : null,
            ),
          ),
        ),

        // Type filter
        if (_types.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  ChoiceChip(
                    label: Text('${_i18n.t('all')} ($totalPlaces)'),
                    selected: _selectedType == null,
                    onSelected: (_) => _selectType(null),
                  ),
                  const SizedBox(width: 8),
                  ..._types.map((type) {
                    final count = _allPlaces.where((p) => p.type == type).length +
                        _stationPlaces.where((entry) => entry.place.type == type).length;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text('$type ($count)'),
                        selected: _selectedType == type,
                        onSelected: (_) => _selectType(type),
                      ),
                    );
                  }),
                ],
              ),
            ),
          ),

        const Divider(height: 1),

        // Place list
        Expanded(
          child: _isLoading && myPlaces.isEmpty && stationPlaces.isEmpty && _isLoadingStationPlaces
              ? const Center(child: CircularProgressIndicator())
              : (myPlaces.isEmpty && stationPlaces.isEmpty && !_isLoading && !_isLoadingStationPlaces)
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.place, size: 64, color: Colors.grey),
                          const SizedBox(height: 16),
                          Text(
                            hasFilters ? _i18n.t('no_places_found') : _i18n.t('no_places_yet'),
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _refreshAllPlaces,
                      child: ListView(
                        padding: const EdgeInsets.only(bottom: 12),
                        children: [
                          if (myPlaces.isNotEmpty) ...[
                            _buildSectionHeader(
                              theme,
                              icon: Icons.person,
                              title: _i18n.t('my_places'),
                              count: myPlaces.length,
                            ),
                            ...myPlaces.map(
                              (place) => _buildPlaceListTile(
                                place,
                                isMobileView: isMobileView,
                              ),
                            ),
                          ],
                          _buildSectionHeader(
                            theme,
                            icon: Icons.cloud,
                            title: _i18n.t('station_places'),
                            count: stationPlaces.length,
                            isLoading: _isLoadingStationPlaces,
                            onRefresh: _loadStationPlaces,
                          ),
                          if (stationPlaces.isNotEmpty)
                            ...stationPlaces.map(
                              (entry) => _buildPlaceListTile(
                                entry.place,
                                isMobileView: isMobileView,
                                isReadOnly: true,
                                subtitleSuffix: entry.callsign,
                                onTap: () => isMobileView
                                    ? _selectPlaceMobile(entry.place, isReadOnly: true)
                                    : _selectStationPlace(entry),
                              ),
                            )
                          else if (!_isLoadingStationPlaces)
                            Padding(
                              padding: const EdgeInsets.all(16),
                              child: Center(
                                child: Column(
                                  children: [
                                    Icon(Icons.cloud_off, size: 32, color: theme.colorScheme.onSurfaceVariant),
                                    const SizedBox(height: 8),
                                    Text(
                                      _i18n.t('no_station_places'),
                                      style: theme.textTheme.bodyMedium?.copyWith(
                                        color: theme.colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
        ),
      ],
    );
  }

  Widget _buildPlaceDetailPanel() {
    return _selectedPlace == null
        ? Center(
            child: Text(_i18n.t('select_place_to_view')),
          )
        : Align(
            alignment: Alignment.topCenter,
            child: _buildPlaceDetail(
              _selectedPlace!,
              isReadOnly: _selectedPlaceIsStation,
            ),
          );
  }

  Widget _buildSectionHeader(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required int count,
    bool isLoading = false,
    VoidCallback? onRefresh,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Row(
            children: [
              Text(
                title,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '$count',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            ],
          ),
          const Spacer(),
          if (isLoading)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (onRefresh != null)
            IconButton(
              icon: const Icon(Icons.refresh, size: 18),
              onPressed: onRefresh,
              visualDensity: VisualDensity.compact,
              tooltip: _i18n.t('refresh'),
            ),
        ],
      ),
    );
  }

  Widget _buildPlaceListTile(
    Place place, {
    bool isMobileView = false,
    bool isReadOnly = false,
    String? subtitleSuffix,
    VoidCallback? onTap,
  }) {
    final subtitleParts = [
      if (place.type != null) place.type,
      if (place.address != null) place.address,
      if (subtitleSuffix != null && subtitleSuffix.isNotEmpty) subtitleSuffix,
    ];

    return ListTile(
      leading: CircleAvatar(
        child: Icon(_getTypeIcon(place.type)),
      ),
      title: Text(place.name),
      subtitle: Text(
        subtitleParts.join(' • '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      selected: _selectedPlace?.folderPath == place.folderPath &&
          _selectedPlaceIsStation == isReadOnly,
      onTap: onTap ??
          () => isMobileView
              ? _selectPlaceMobile(place, isReadOnly: isReadOnly)
              : _selectPlace(place),
      trailing: isReadOnly
          ? const Icon(Icons.cloud)
          : PopupMenuButton(
              itemBuilder: (context) => [
                PopupMenuItem(value: 'edit', child: Text(_i18n.t('edit'))),
                PopupMenuItem(value: 'delete', child: Text(_i18n.t('delete'))),
              ],
              onSelected: (value) {
                if (value == 'edit') _editPlace(place);
                if (value == 'delete') _deletePlace(place);
              },
            ),
    );
  }

  Future<void> _selectPlaceMobile(Place place, {bool isReadOnly = false}) async {
    if (!mounted) return;

    // Navigate to full-screen detail view
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) => _PlaceDetailPage(
          place: place,
          placeService: _placeService,
          i18n: _i18n,
          isReadOnly: isReadOnly,
        ),
      ),
    );

    // Reload places if changes were made
    if (result == true && mounted && !isReadOnly) {
      await _loadPlaces();
    }
  }

  IconData _getTypeIcon(String? type) {
    switch (type?.toLowerCase()) {
      case 'restaurant':
        return Icons.restaurant;
      case 'cafe':
      case 'coffee':
        return Icons.local_cafe;
      case 'monument':
      case 'landmark':
        return Icons.account_balance;
      case 'park':
        return Icons.park;
      case 'museum':
        return Icons.museum;
      case 'shop':
      case 'store':
        return Icons.store;
      case 'hotel':
        return Icons.hotel;
      case 'hospital':
        return Icons.local_hospital;
      case 'school':
        return Icons.school;
      case 'church':
        return Icons.church;
      default:
        return Icons.place;
    }
  }

  Widget _buildPlaceDetail(Place place, {bool isReadOnly = false}) {
    final currentLang = _i18n.currentLanguage.toUpperCase().split('_').first;
    final description = place.getDescription(currentLang);
    final history = place.getHistory(currentLang);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              CircleAvatar(
                radius: 30,
                child: Icon(_getTypeIcon(place.type), size: 30),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      place.name,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    if (place.type != null)
                      Text(
                        place.type!,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(context).colorScheme.secondary,
                            ),
                      ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),

          if (_selectedPlacePhotos.isNotEmpty) ...[
            Text(
              _i18n.t('photos'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _selectedPlacePhotos.asMap().entries.map((entry) {
                final imageWidget = file_helper.buildFileImage(
                  entry.value,
                  width: 120,
                  height: 120,
                  fit: BoxFit.cover,
                );
                if (imageWidget == null) return const SizedBox.shrink();
                return GestureDetector(
                  onTap: () => _openPhotoViewer(entry.key),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: imageWidget,
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
          ],

          // Basic info
          _buildInfoSection(_i18n.t('basic_information'), [
            _buildLocationRow(place),
            _buildInfoRow(_i18n.t('radius'), '${place.radius} ${_i18n.t('meters')}'),
            if (place.address != null)
              _buildInfoRow(_i18n.t('address'), place.address!),
            if (place.founded != null)
              _buildInfoRow(_i18n.t('founded'), place.founded!),
            if (place.hours != null)
              _buildInfoRow(_i18n.t('hours'), place.hours!),
            _buildInfoRow(_i18n.t('author'), place.author),
            _buildInfoRow(_i18n.t('created'), place.displayCreated),
          ]),

          // Description
          if (description.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              _i18n.t('description'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(description),
              ),
            ),
          ],

          // History
          if (history != null && history.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              _i18n.t('history'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(history),
              ),
            ),
          ],

          const SizedBox(height: 24),

          if (!isReadOnly)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.edit),
                  label: Text(_i18n.t('edit')),
                  onPressed: () => _editPlace(place),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.delete),
                  label: Text(_i18n.t('delete')),
                  onPressed: () => _deletePlace(place),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildInfoSection(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildInfoRow(String label, String value, {bool monospace = false}) {
    if (value.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: monospace
                  ? const TextStyle(fontFamily: 'monospace', fontSize: 12)
                  : null,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLocationRow(Place place) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              _i18n.t('coordinates'),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: SelectableText(
              place.coordinatesString,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy, size: 18),
            onPressed: () => _copyCoordinates(place),
            tooltip: _i18n.t('copy_coordinates'),
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            icon: const Icon(Icons.navigation, size: 18),
            onPressed: () => _openInNavigator(place),
            tooltip: _i18n.t('open_in_navigator'),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  void _copyCoordinates(Place place) {
    Clipboard.setData(ClipboardData(text: place.coordinatesString));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_i18n.t('coordinates_copied'))),
    );
  }

  Future<void> _openInNavigator(Place place) async {
    try {
      Uri mapUri;

      if (!kIsWeb && Platform.isAndroid) {
        // Android: canLaunchUrl often returns false for geo: URIs even when they work
        mapUri = Uri.parse('geo:${place.latitude},${place.longitude}?q=${place.latitude},${place.longitude}');
        await launchUrl(mapUri);
      } else if (!kIsWeb && Platform.isIOS) {
        // iOS: Use Apple Maps URL scheme
        mapUri = Uri.parse('https://maps.apple.com/?q=${place.latitude},${place.longitude}');
        await launchUrl(mapUri);
      } else {
        // Desktop/Web: Use OpenStreetMap
        mapUri = Uri.parse('https://www.openstreetmap.org/?mlat=${place.latitude}&mlon=${place.longitude}&zoom=15');
        if (await canLaunchUrl(mapUri)) {
          await launchUrl(mapUri, mode: LaunchMode.externalApplication);
        }
      }
    } catch (e) {
      LogService().log('PlacesBrowserPage: Error opening navigator: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open navigator: $e')),
        );
      }
    }
  }
}

/// Full-screen place detail page for mobile view
class _PlaceDetailPage extends StatefulWidget {
  final Place place;
  final PlaceService placeService;
  final I18nService i18n;
  final bool isReadOnly;

  const _PlaceDetailPage({
    Key? key,
    required this.place,
    required this.placeService,
    required this.i18n,
    this.isReadOnly = false,
  }) : super(key: key);

  @override
  State<_PlaceDetailPage> createState() => _PlaceDetailPageState();
}

class _PlaceDetailPageState extends State<_PlaceDetailPage> {
  bool _hasChanges = false;
  List<String> _photos = [];

  @override
  void initState() {
    super.initState();
    _loadPhotos();
  }

  Future<void> _loadPhotos() async {
    if (kIsWeb || widget.place.folderPath == null) {
      return;
    }

    try {
      final photos = await _listPlacePhotos(widget.place.folderPath!);

      if (!mounted) return;
      setState(() => _photos = photos);
    } catch (e) {
      LogService().log('PlaceDetailPage: Error loading photos: $e');
    }
  }

  void _openPhotoViewer(int index) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PhotoViewerPage(
          imagePaths: _photos,
          initialIndex: index,
        ),
      ),
    );
  }

  IconData _getTypeIcon(String? type) {
    switch (type?.toLowerCase()) {
      case 'restaurant':
        return Icons.restaurant;
      case 'cafe':
      case 'coffee':
        return Icons.local_cafe;
      case 'monument':
      case 'landmark':
        return Icons.account_balance;
      case 'park':
        return Icons.park;
      case 'museum':
        return Icons.museum;
      case 'shop':
      case 'store':
        return Icons.store;
      case 'hotel':
        return Icons.hotel;
      case 'hospital':
        return Icons.local_hospital;
      case 'school':
        return Icons.school;
      case 'church':
        return Icons.church;
      default:
        return Icons.place;
    }
  }

  Future<void> _deletePlace() async {
    if (widget.isReadOnly) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.i18n.t('delete_place')),
        content: Text(widget.i18n.t('delete_place_confirm', params: [widget.place.name])),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(widget.i18n.t('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(widget.i18n.t('delete')),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final success = await widget.placeService.deletePlace(widget.place);

      if (success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(widget.i18n.t('place_deleted', params: [widget.place.name]))),
        );
        _hasChanges = true;
        Navigator.pop(context, true);
      }
    }
  }

  Widget _buildInfoSection(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildInfoRow(String label, String value, {bool monospace = false}) {
    if (value.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: monospace
                  ? const TextStyle(fontFamily: 'monospace', fontSize: 12)
                  : null,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLocationRow() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              widget.i18n.t('coordinates'),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: SelectableText(
              widget.place.coordinatesString,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy, size: 18),
            onPressed: _copyCoordinates,
            tooltip: widget.i18n.t('copy_coordinates'),
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            icon: const Icon(Icons.navigation, size: 18),
            onPressed: _openInNavigator,
            tooltip: widget.i18n.t('open_in_navigator'),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  void _copyCoordinates() {
    Clipboard.setData(ClipboardData(text: widget.place.coordinatesString));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(widget.i18n.t('coordinates_copied'))),
    );
  }

  Future<void> _openInNavigator() async {
    try {
      Uri mapUri;
      final place = widget.place;

      if (!kIsWeb && Platform.isAndroid) {
        // Android: canLaunchUrl often returns false for geo: URIs even when they work
        mapUri = Uri.parse('geo:${place.latitude},${place.longitude}?q=${place.latitude},${place.longitude}');
        await launchUrl(mapUri);
      } else if (!kIsWeb && Platform.isIOS) {
        // iOS: Use Apple Maps URL scheme
        mapUri = Uri.parse('https://maps.apple.com/?q=${place.latitude},${place.longitude}');
        await launchUrl(mapUri);
      } else {
        // Desktop/Web: Use OpenStreetMap
        mapUri = Uri.parse('https://www.openstreetmap.org/?mlat=${place.latitude}&mlon=${place.longitude}&zoom=15');
        if (await canLaunchUrl(mapUri)) {
          await launchUrl(mapUri, mode: LaunchMode.externalApplication);
        }
      }
    } catch (e) {
      LogService().log('PlaceDetailPage: Error opening navigator: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open navigator: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentLang = widget.i18n.currentLanguage.toUpperCase().split('_').first;
    final description = widget.place.getDescription(currentLang);
    final history = widget.place.getHistory(currentLang);

    return PopScope(
      canPop: true,
      onPopInvoked: (didPop) {
        if (didPop && _hasChanges) {
          Navigator.of(context).pop(true);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.place.name),
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  CircleAvatar(
                    radius: 30,
                    child: Icon(_getTypeIcon(widget.place.type), size: 30),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.place.name,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        if (widget.place.type != null)
                          Text(
                            widget.place.type!,
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  color: Theme.of(context).colorScheme.secondary,
                                ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 24),

              if (_photos.isNotEmpty) ...[
                Text(
                  widget.i18n.t('photos'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _photos.asMap().entries.map((entry) {
                    final imageWidget = file_helper.buildFileImage(
                      entry.value,
                      width: 120,
                      height: 120,
                      fit: BoxFit.cover,
                    );
                    if (imageWidget == null) return const SizedBox.shrink();
                    return GestureDetector(
                      onTap: () => _openPhotoViewer(entry.key),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: imageWidget,
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
              ],

              // Basic info
              _buildInfoSection(widget.i18n.t('basic_information'), [
                _buildLocationRow(),
                _buildInfoRow(widget.i18n.t('radius'), '${widget.place.radius} ${widget.i18n.t('meters')}'),
                if (widget.place.address != null)
                  _buildInfoRow(widget.i18n.t('address'), widget.place.address!),
                if (widget.place.founded != null)
                  _buildInfoRow(widget.i18n.t('founded'), widget.place.founded!),
                if (widget.place.hours != null)
                  _buildInfoRow(widget.i18n.t('hours'), widget.place.hours!),
                _buildInfoRow(widget.i18n.t('author'), widget.place.author),
                _buildInfoRow(widget.i18n.t('created'), widget.place.displayCreated),
              ]),

              // Description
              if (description.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  widget.i18n.t('description'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(description),
                  ),
                ),
              ],

              // History
              if (history != null && history.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  widget.i18n.t('history'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(history),
                  ),
                ),
              ],

              const SizedBox(height: 24),

              if (!widget.isReadOnly)
                FilledButton.icon(
                  icon: const Icon(Icons.delete),
                  label: Text(widget.i18n.t('delete')),
                  onPressed: _deletePlace,
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.red,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<List<String>> _listPlacePhotos(String folderPath) async {
  final photos = <String>[];

  try {
    final imagesDir = Directory('$folderPath/images');
    if (await imagesDir.exists()) {
      final entities = await imagesDir.list().toList();
      photos.addAll(
        entities
            .whereType<File>()
            .where((file) => _isImagePath(file.path))
            .map((file) => file.path),
      );
    }

    final rootDir = Directory(folderPath);
    if (await rootDir.exists()) {
      final entities = await rootDir.list().toList();
      for (final entity in entities) {
        if (entity is! File) continue;
        if (entity.path.toLowerCase().endsWith('place.txt')) continue;
        if (_isImagePath(entity.path)) {
          photos.add(entity.path);
        }
      }
    }
  } catch (e) {
    LogService().log('PlacesBrowserPage: Error listing photos: $e');
  }

  photos.sort();
  return photos;
}

bool _isImagePath(String path) {
  final ext = path.toLowerCase();
  return ext.endsWith('.jpg') ||
      ext.endsWith('.jpeg') ||
      ext.endsWith('.png') ||
      ext.endsWith('.gif') ||
      ext.endsWith('.webp');
}
