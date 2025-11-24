/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import '../models/place.dart';
import '../services/place_service.dart';
import '../services/i18n_service.dart';
import 'add_edit_place_page.dart';

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

  List<Place> _allPlaces = [];
  List<Place> _filteredPlaces = [];
  Place? _selectedPlace;
  String? _selectedType;
  Set<String> _types = {};
  bool _isLoading = true;

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
  }

  Future<void> _loadPlaces() async {
    setState(() => _isLoading = true);

    try {
      await _placeService.initializeCollection(widget.collectionPath);
      final places = await _placeService.loadAllPlaces();

      // Sort by name
      places.sort((a, b) => a.name.compareTo(b.name));

      final types = _placeService.getTypes(places);

      setState(() {
        _allPlaces = places;
        _filteredPlaces = places;
        _types = types;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading places: $e')),
        );
      }
    }
  }

  void _filterPlaces() {
    setState(() {
      var filtered = _allPlaces;

      // Apply type filter
      if (_selectedType != null) {
        filtered = _placeService.filterByType(filtered, _selectedType);
      }

      // Apply search filter
      if (_searchController.text.isNotEmpty) {
        filtered = _placeService.searchPlaces(filtered, _searchController.text);
      }

      _filteredPlaces = filtered;
    });
  }

  void _selectPlace(Place place) {
    setState(() {
      _selectedPlace = place;
    });
  }

  void _selectType(String? type) {
    setState(() {
      _selectedType = type;
    });
    _filterPlaces();
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
          setState(() => _selectedPlace = null);
        }
        await _loadPlaces();
      }
    }
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
                await _loadPlaces();
              }
            },
            tooltip: _i18n.t('new_place'),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadPlaces,
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
                            label: Text('${_i18n.t('all')} (${_allPlaces.length})'),
                            selected: _selectedType == null,
                            onSelected: (_) => _selectType(null),
                          ),
                          const SizedBox(width: 8),
                          ..._types.map((type) {
                            final count = _allPlaces.where((p) => p.type == type).length;
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
                  child: _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : _filteredPlaces.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.place, size: 64, color: Colors.grey),
                                  const SizedBox(height: 16),
                                  Text(
                                    _searchController.text.isNotEmpty || _selectedType != null
                                        ? _i18n.t('no_places_found')
                                        : _i18n.t('no_places_yet'),
                                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                          color: Colors.grey,
                                        ),
                                  ),
                                ],
                              ),
                            )
                          : ListView.builder(
                              itemCount: _filteredPlaces.length,
                              itemBuilder: (context, index) {
                                final place = _filteredPlaces[index];
                                return _buildPlaceListTile(place, isMobileView: isMobileView);
                              },
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
            child: _buildPlaceDetail(_selectedPlace!),
          );
  }

  Widget _buildPlaceListTile(Place place, {bool isMobileView = false}) {
    return ListTile(
      leading: CircleAvatar(
        child: Icon(_getTypeIcon(place.type)),
      ),
      title: Text(place.name),
      subtitle: Text(
        [
          if (place.type != null) place.type,
          if (place.address != null) place.address,
        ].join(' • '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      selected: _selectedPlace?.folderPath == place.folderPath,
      onTap: () => isMobileView ? _selectPlaceMobile(place) : _selectPlace(place),
      trailing: PopupMenuButton(
        itemBuilder: (context) => [
          PopupMenuItem(value: 'delete', child: Text(_i18n.t('delete'))),
        ],
        onSelected: (value) {
          if (value == 'delete') _deletePlace(place);
        },
      ),
    );
  }

  Future<void> _selectPlaceMobile(Place place) async {
    if (!mounted) return;

    // Navigate to full-screen detail view
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) => _PlaceDetailPage(
          place: place,
          placeService: _placeService,
          i18n: _i18n,
        ),
      ),
    );

    // Reload places if changes were made
    if (result == true && mounted) {
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

  Widget _buildPlaceDetail(Place place) {
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

          // Basic info
          _buildInfoSection(_i18n.t('basic_information'), [
            _buildInfoRow(_i18n.t('coordinates'), place.coordinatesString, monospace: true),
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
          if (place.description.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              _i18n.t('description'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(place.description),
              ),
            ),
          ],

          // History
          if (place.history != null && place.history!.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              _i18n.t('history'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(place.history!),
              ),
            ),
          ],

          const SizedBox(height: 24),

          // Actions
          FilledButton.icon(
            icon: const Icon(Icons.delete),
            label: Text(_i18n.t('delete')),
            onPressed: () => _deletePlace(place),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red,
            ),
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
}

/// Full-screen place detail page for mobile view
class _PlaceDetailPage extends StatefulWidget {
  final Place place;
  final PlaceService placeService;
  final I18nService i18n;

  const _PlaceDetailPage({
    Key? key,
    required this.place,
    required this.placeService,
    required this.i18n,
  }) : super(key: key);

  @override
  State<_PlaceDetailPage> createState() => _PlaceDetailPageState();
}

class _PlaceDetailPageState extends State<_PlaceDetailPage> {
  bool _hasChanges = false;

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

  @override
  Widget build(BuildContext context) {
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

              // Basic info
              _buildInfoSection(widget.i18n.t('basic_information'), [
                _buildInfoRow(widget.i18n.t('coordinates'), widget.place.coordinatesString, monospace: true),
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
              if (widget.place.description.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  widget.i18n.t('description'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(widget.place.description),
                  ),
                ),
              ],

              // History
              if (widget.place.history != null && widget.place.history!.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  widget.i18n.t('history'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(widget.place.history!),
                  ),
                ),
              ],

              const SizedBox(height: 24),

              // Actions
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
