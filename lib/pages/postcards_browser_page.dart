/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:latlong2/latlong.dart';

import '../models/postcard.dart';
import '../services/app_service.dart';
import '../services/location_provider_service.dart';
import '../services/location_service.dart';
import '../services/map_tile_service.dart' show MapTileService, MapLayerType;
import '../services/postcard_service.dart';
import '../services/profile_service.dart';
import '../services/profile_storage.dart';
import '../services/i18n_service.dart';
import '../widgets/postcard_tile_widget.dart';
import '../widgets/postcard_detail_widget.dart';
import 'new_postcard_page.dart';

enum _ViewMode { map, list }

/// Postcards browser page with 2-panel layout
class PostcardsBrowserPage extends StatefulWidget {
  final String appPath;
  final String appTitle;

  const PostcardsBrowserPage({
    Key? key,
    required this.appPath,
    required this.appTitle,
  }) : super(key: key);

  @override
  State<PostcardsBrowserPage> createState() => _PostcardsBrowserPageState();
}

class _PostcardsBrowserPageState extends State<PostcardsBrowserPage> {
  final PostcardService _postcardService = PostcardService();
  final ProfileService _profileService = ProfileService();
  final I18nService _i18n = I18nService();
  final TextEditingController _searchController = TextEditingController();

  List<Postcard> _allPostcards = [];
  List<Postcard> _filteredPostcards = [];
  Postcard? _selectedPostcard;
  bool _isLoading = true;
  Set<int> _expandedYears = {};
  String? _currentUserNpub;
  String? _currentCallsign;
  String _statusFilter = 'all'; // all, in-transit, delivered, acknowledged, expired

  // Map-first view: default. Toggle with the AppBar action.
  _ViewMode _viewMode = _ViewMode.map;
  // Cached "me" coordinate for arrow + distance overlays. Refreshed
  // when the LocationProviderService sees a fresh fix.
  LatLng? _myLocation;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_filterPostcards);
    _initialize();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    // Get current user info
    final profile = _profileService.getProfile();
    _currentUserNpub = profile.npub;
    _currentCallsign = profile.callsign;

    // Set profile storage for encrypted storage support
    final profileStorage = AppService().profileStorage;
    if (profileStorage != null) {
      final scopedStorage = ScopedProfileStorage.fromAbsolutePath(
        profileStorage,
        widget.appPath,
      );
      _postcardService.setStorage(scopedStorage);
    } else {
      _postcardService.setStorage(FilesystemProfileStorage(widget.appPath));
    }

    // Initialize postcard service
    await _postcardService.initializeApp(widget.appPath);

    await _loadPostcards();

    // Expand most recent year by default
    if (_allPostcards.isNotEmpty) {
      _expandedYears.add(_allPostcards.first.year);
    }

    // Pull a cached GPS fix for the map-overlay arrows. Non-blocking;
    // the map renders fine without it (no arrow, no distance label).
    _refreshMyLocation();
  }

  void _refreshMyLocation() {
    final pos = LocationProviderService().currentPosition;
    if (pos == null) return;
    setState(() => _myLocation = LatLng(pos.latitude, pos.longitude));
  }

  Future<void> _loadPostcards() async {
    setState(() => _isLoading = true);

    final postcards = await _postcardService.loadPostcards();

    setState(() {
      _allPostcards = postcards;
      _filteredPostcards = postcards;
      _isLoading = false;

      // Expand most recent year by default
      if (_allPostcards.isNotEmpty && _expandedYears.isEmpty) {
        _expandedYears.add(_allPostcards.first.year);
      }
    });

    _filterPostcards();
    // No auto-select. The detail pane stays collapsed until the user
    // taps a marker.
  }

  void _filterPostcards() {
    final query = _searchController.text.toLowerCase();

    setState(() {
      var filtered = _allPostcards;

      // Apply status filter
      if (_statusFilter != 'all') {
        filtered = filtered.where((p) => p.status == _statusFilter).toList();
      }

      // Apply search filter
      if (query.isNotEmpty) {
        filtered = filtered.where((postcard) {
          return postcard.title.toLowerCase().contains(query) ||
                 postcard.senderCallsign.toLowerCase().contains(query) ||
                 (postcard.recipientCallsign?.toLowerCase().contains(query) ?? false) ||
                 postcard.content.toLowerCase().contains(query);
        }).toList();
      }

      _filteredPostcards = filtered;
    });
  }

  Future<void> _selectPostcard(Postcard postcard) async {
    // Load full postcard with all stamps
    final fullPostcard = await _postcardService.loadPostcard(postcard.id);
    setState(() {
      _selectedPostcard = fullPostcard;
    });
  }

  void _toggleYear(int year) {
    setState(() {
      if (_expandedYears.contains(year)) {
        _expandedYears.remove(year);
      } else {
        _expandedYears.add(year);
      }
    });
  }

  void _setStatusFilter(String status) {
    setState(() {
      _statusFilter = status;
    });
    _filterPostcards();
  }

  Future<void> _createNewPostcard() async {
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(builder: (_) => const NewPostcardPage()),
    );

    if (result != null && mounted) {
      final profile = _profileService.getProfile();
      final postcard = await _postcardService.createPostcard(
        title: result['title'] as String,
        senderCallsign: profile.callsign,
        senderNpub: profile.npub!,
        recipientCallsign: result['recipientCallsign'] as String?,
        recipientNpub: result['recipientNpub'] as String,
        recipientLocations: result['recipientLocations'] as List<RecipientLocation>,
        type: result['type'] as String,
        content: result['content'] as String,
        ttl: result['ttl'] as int?,
        priority: result['priority'] as String? ?? 'normal',
      );

      if (postcard != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('postcard_created')),
            backgroundColor: Colors.green,
          ),
        );
        await _loadPostcards();
        await _selectPostcard(postcard);
      }
    }
  }

  int _getStatusCount(String status) {
    if (status == 'all') return _allPostcards.length;
    return _allPostcards.where((p) => p.status == status).length;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isMap = _viewMode == _ViewMode.map;

    return Scaffold(
      appBar: AppBar(
        title: Text(_i18n.t('postcards')),
        actions: [
          IconButton(
            icon: Icon(isMap ? Icons.list : Icons.map_outlined),
            tooltip: isMap ? _i18n.t('list_view') : _i18n.t('map_view'),
            onPressed: () => setState(
              () => _viewMode = isMap ? _ViewMode.list : _ViewMode.map,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: _i18n.t('refresh'),
            onPressed: _loadPostcards,
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: _i18n.t('new_postcard'),
            onPressed: _createNewPostcard,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(
              builder: (context, constraints) {
                final isWideScreen = constraints.maxWidth >= 600;

                final mainView = isMap
                    ? _buildMapView(theme, isMobileView: !isWideScreen)
                    : _buildPostcardList(theme, isMobileView: !isWideScreen);

                if (isWideScreen) {
                  // Wide: main view fills the screen until the user
                  // taps a postcard. Then the detail pane slides in
                  // on the right and takes 1/3 of the width. With no
                  // selection there is no empty placeholder column.
                  if (_selectedPostcard == null) {
                    return mainView;
                  }
                  return Row(
                    children: [
                      Expanded(flex: 2, child: mainView),
                      const VerticalDivider(width: 1),
                      Expanded(flex: 1, child: _buildPostcardDetail(theme)),
                    ],
                  );
                }
                return mainView;
              },
            ),
    );
  }

  // ── Map view ──────────────────────────────────────────────────────

  Widget _buildMapView(ThemeData theme, {required bool isMobileView}) {
    return _PostcardsMapView(
      postcards: _filteredPostcards,
      selectedPostcardId: _selectedPostcard?.id,
      myLocation: _myLocation,
      myCallsign: _currentCallsign,
      statusFilter: _statusFilter,
      onStatusFilter: _setStatusFilter,
      statusCount: _getStatusCount,
      i18n: _i18n,
      searchController: _searchController,
      onPostcardTap: (postcard) async {
        if (isMobileView) {
          await _selectPostcardMobile(postcard);
        } else {
          await _selectPostcard(postcard);
        }
      },
    );
  }

  Widget _buildPostcardList(ThemeData theme, {bool isMobileView = false}) {
    return Container(
      width: isMobileView ? null : 350,
      color: theme.colorScheme.surface,
      child: Column(
        children: [
          // Status filter chips
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _buildFilterChip('all', 'all', _getStatusCount('all'), theme),
                _buildFilterChip('in_transit', 'in-transit', _getStatusCount('in-transit'), theme),
                _buildFilterChip('delivered', 'delivered', _getStatusCount('delivered'), theme),
                _buildFilterChip('acknowledged', 'acknowledged', _getStatusCount('acknowledged'), theme),
                _buildFilterChip('expired', 'expired', _getStatusCount('expired'), theme),
              ],
            ),
          ),
          // Search bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: _i18n.t('search_postcards'),
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          _filterPostcards();
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                filled: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ),
          const Divider(height: 1),
          // Postcard list
          Expanded(
            child: _filteredPostcards.isEmpty
                ? _buildEmptyState(theme)
                : _buildYearGroupedList(theme, isMobileView: isMobileView),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String label, String status, int count, ThemeData theme) {
    final isSelected = _statusFilter == status;
    return FilterChip(
      label: Text('${_i18n.t(label)} ($count)'),
      selected: isSelected,
      onSelected: (selected) {
        if (selected) {
          _setStatusFilter(status);
        }
      },
      showCheckmark: false,
      selectedColor: theme.colorScheme.primaryContainer,
      labelStyle: TextStyle(
        color: isSelected
            ? theme.colorScheme.onPrimaryContainer
            : theme.colorScheme.onSurfaceVariant,
        fontSize: 12,
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.mail_outline,
              size: 64,
              color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5),
            ),
            const SizedBox(height: 16),
            Text(
              _searchController.text.isNotEmpty || _statusFilter != 'all'
                  ? _i18n.t('no_matching_postcards')
                  : _i18n.t('no_postcards_yet'),
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _searchController.text.isNotEmpty || _statusFilter != 'all'
                  ? _i18n.t('try_different_search')
                  : _i18n.t('create_first_postcard'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withOpacity(0.7),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildYearGroupedList(ThemeData theme, {bool isMobileView = false}) {
    // Group postcards by year
    final Map<int, List<Postcard>> postcardsByYear = {};
    for (var postcard in _filteredPostcards) {
      postcardsByYear.putIfAbsent(postcard.year, () => []).add(postcard);
    }

    final years = postcardsByYear.keys.toList()..sort((a, b) => b.compareTo(a));

    return ListView.builder(
      itemCount: years.length,
      itemBuilder: (context, index) {
        final year = years[index];
        final postcards = postcardsByYear[year]!;
        final isExpanded = _expandedYears.contains(year);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Year header
            Material(
              color: theme.colorScheme.surfaceVariant,
              child: InkWell(
                onTap: () => _toggleYear(year),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        isExpanded
                            ? Icons.expand_more
                            : Icons.chevron_right,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        year.toString(),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '${postcards.length} ${postcards.length == 1 ? _i18n.t('postcard') : _i18n.t('postcards')}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // Postcards for this year
            if (isExpanded)
              ...postcards.map((postcard) => PostcardTileWidget(
                    postcard: postcard,
                    isSelected: _selectedPostcard?.id == postcard.id,
                    onTap: () => isMobileView
                        ? _selectPostcardMobile(postcard)
                        : _selectPostcard(postcard),
                  )),
          ],
        );
      },
    );
  }

  Future<void> _selectPostcardMobile(Postcard postcard) async {
    // Load full postcard with all stamps
    final fullPostcard = await _postcardService.loadPostcard(postcard.id);

    if (!mounted || fullPostcard == null) return;

    final isSender = fullPostcard.senderCallsign == _currentCallsign;
    final isRecipient = fullPostcard.recipientCallsign == _currentCallsign;

    // Navigate to full-screen detail view
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) => _PostcardDetailPage(
          postcard: fullPostcard,
          appPath: widget.appPath,
          postcardService: _postcardService,
          i18n: _i18n,
          currentCallsign: _currentCallsign,
          currentUserNpub: _currentUserNpub,
          isSender: isSender,
          isRecipient: isRecipient,
        ),
      ),
    );

    // Reload postcards if changes were made
    if (result == true && mounted) {
      await _loadPostcards();
    }
  }

  Widget _buildPostcardDetail(ThemeData theme) {
    if (_selectedPostcard == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.mail_outline,
              size: 64,
              color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5),
            ),
            const SizedBox(height: 16),
            Text(
              _i18n.t('select_postcard_to_view'),
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    final isSender = _selectedPostcard!.senderCallsign == _currentCallsign;
    final isRecipient = _selectedPostcard!.recipientCallsign == _currentCallsign;

    return PostcardDetailWidget(
      postcard: _selectedPostcard!,
      appPath: widget.appPath,
      currentCallsign: _currentCallsign,
      currentUserNpub: _currentUserNpub,
      isSender: isSender,
      isRecipient: isRecipient,
      onRefresh: () async {
        final updated = await _postcardService.loadPostcard(_selectedPostcard!.id);
        setState(() {
          _selectedPostcard = updated;
        });
        await _loadPostcards(); // Reload list to update counts
      },
    );
  }
}

/// Full-screen postcard detail page for mobile view
class _PostcardDetailPage extends StatefulWidget {
  final Postcard postcard;
  final String appPath;
  final PostcardService postcardService;
  final I18nService i18n;
  final String? currentCallsign;
  final String? currentUserNpub;
  final bool isSender;
  final bool isRecipient;

  const _PostcardDetailPage({
    Key? key,
    required this.postcard,
    required this.appPath,
    required this.postcardService,
    required this.i18n,
    required this.currentCallsign,
    required this.currentUserNpub,
    required this.isSender,
    required this.isRecipient,
  }) : super(key: key);

  @override
  State<_PostcardDetailPage> createState() => _PostcardDetailPageState();
}

class _PostcardDetailPageState extends State<_PostcardDetailPage> {
  late Postcard _postcard;
  bool _hasChanges = false;

  @override
  void initState() {
    super.initState();
    _postcard = widget.postcard;
  }

  Future<void> _refresh() async {
    final updated = await widget.postcardService.loadPostcard(_postcard.id);
    if (updated != null) {
      final postcard = updated;
      setState(() {
        _postcard = postcard;
      });
      _hasChanges = true;
    }
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
          title: Text(_postcard.title),
        ),
        body: PostcardDetailWidget(
          postcard: _postcard,
          appPath: widget.appPath,
          currentCallsign: widget.currentCallsign,
          currentUserNpub: widget.currentUserNpub,
          isSender: widget.isSender,
          isRecipient: widget.isRecipient,
          onRefresh: _refresh,
        ),
      ),
    );
  }
}

// ── Map view widget ─────────────────────────────────────────────────

/// Map-first overview of the postcards collection.
///
/// Renders one marker per postcard at its first recipient location,
/// clustered so thousands of pins remain navigable. Marker colour
/// encodes status (in-transit / delivered / acknowledged / expired).
/// When a postcard is selected, an arrow polyline + distance label is
/// drawn from the user's current location to the destination, so the
/// "where is this message going" question is one tap away.
class _PostcardsMapView extends StatefulWidget {
  final List<Postcard> postcards;
  final String? selectedPostcardId;
  final LatLng? myLocation;
  final String? myCallsign;
  final String statusFilter;
  final ValueChanged<String> onStatusFilter;
  final int Function(String status) statusCount;
  final I18nService i18n;
  final TextEditingController searchController;
  final ValueChanged<Postcard> onPostcardTap;

  const _PostcardsMapView({
    required this.postcards,
    required this.selectedPostcardId,
    required this.myLocation,
    required this.myCallsign,
    required this.statusFilter,
    required this.onStatusFilter,
    required this.statusCount,
    required this.i18n,
    required this.searchController,
    required this.onPostcardTap,
  });

  @override
  State<_PostcardsMapView> createState() => _PostcardsMapViewState();
}

class _PostcardsMapViewState extends State<_PostcardsMapView> {
  final MapController _mapController = MapController();
  final MapTileService _mapTileService = MapTileService();
  bool _mapInitialized = false;

  static const LatLng _defaultCenter = LatLng(40.0, -3.7);
  static const double _defaultZoom = 4.0;

  @override
  void initState() {
    super.initState();
    _initializeMap();
  }

  Future<void> _initializeMap() async {
    await _mapTileService.initialize();
    if (mounted) {
      setState(() => _mapInitialized = true);
    }
  }

  @override
  void didUpdateWidget(_PostcardsMapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // When the selection changes, fit the map so every hop AND every
    // possible destination of the new postcard fit on screen.
    if (oldWidget.selectedPostcardId != widget.selectedPostcardId &&
        widget.selectedPostcardId != null &&
        _mapInitialized) {
      final selected = _selectedPostcard();
      if (selected == null) return;
      final journey = _journeyOf(selected);
      if (journey == null) return;
      final pts = <LatLng>[
        for (final h in journey.hops) h.position,
        ...journey.possibleDestinations,
      ];
      if (pts.isEmpty) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (pts.length == 1) {
          _mapController.move(pts.first, 8);
          return;
        }
        _mapController.fitCamera(
          CameraFit.bounds(
            bounds: LatLngBounds.fromPoints(pts),
            padding: const EdgeInsets.all(60),
          ),
        );
      });
    }
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'in-transit':
        return Colors.blue.shade600;
      case 'delivered':
        return Colors.green.shade600;
      case 'acknowledged':
        return Colors.grey.shade600;
      case 'expired':
        return Colors.red.shade400;
      default:
        return Colors.blue.shade600;
    }
  }

  /// First recipient location for a postcard, or null when none was set.
  LatLng? _destinationOf(Postcard p) {
    if (p.recipientLocations.isEmpty) return null;
    final loc = p.recipientLocations.first;
    return LatLng(loc.latitude, loc.longitude);
  }

  /// Resolve initial map center: my location → first postcard → default.
  LatLng _initialCenter() {
    if (widget.myLocation != null) return widget.myLocation!;
    for (final p in widget.postcards) {
      final dst = _destinationOf(p);
      if (dst != null) return dst;
    }
    return _defaultCenter;
  }

  Postcard? _selectedPostcard() {
    final id = widget.selectedPostcardId;
    if (id == null) return null;
    for (final p in widget.postcards) {
      if (p.id == id) return p;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = _selectedPostcard();
    final me = widget.myLocation;
    final journey = selected == null ? null : _journeyOf(selected);

    return Column(
      children: [
        _buildToolbar(theme),
        Expanded(
          child: Stack(
            children: [
              if (_mapInitialized)
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: _initialCenter(),
                    initialZoom: _defaultZoom,
                    minZoom: 1.0,
                    maxZoom: 18.0,
                    interactionOptions: const InteractionOptions(
                      flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                    ),
                  ),
                  children: [
                    ValueListenableBuilder<MapLayerType>(
                      valueListenable: _mapTileService.layerTypeNotifier,
                      builder: (context, layerType, _) {
                        return TileLayer(
                          urlTemplate: _mapTileService.getTileUrl(layerType),
                          userAgentPackageName: 'dev.geogram',
                          subdomains: const [],
                          keepBuffer: 3,
                          tileBuilder: (_, w, __) => w,
                          evictErrorTileStrategy:
                              EvictErrorTileStrategy.notVisibleRespectMargin,
                          tileProvider:
                              _mapTileService.getTileProvider(layerType),
                        );
                      },
                    ),
                    // "Me" marker stays as a tertiary reference dot.
                    if (me != null)
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: me,
                            width: 22,
                            height: 22,
                            child: Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: theme.colorScheme.primary,
                                border: Border.all(
                                  color: Colors.white,
                                  width: 3,
                                ),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Colors.black26,
                                    blurRadius: 4,
                                    offset: Offset(0, 2),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    // Postcard markers, clustered. maxZoom matches the
                    // FlutterMap maxZoom so postcards sharing exact
                    // recipient coordinates always group into a single
                    // count bubble instead of stacking on top of each
                    // other at high zoom.
                    MarkerClusterLayerWidget(
                      options: MarkerClusterLayerOptions(
                        maxClusterRadius: 60,
                        size: const Size(36, 36),
                        alignment: Alignment.center,
                        padding: const EdgeInsets.all(50),
                        maxZoom: 18,
                        markers: [
                          for (final p in widget.postcards)
                            if (_destinationOf(p) != null)
                              Marker(
                                point: _destinationOf(p)!,
                                width: 22,
                                height: 22,
                                child: GestureDetector(
                                  onTap: () => widget.onPostcardTap(p),
                                  child: _PostcardMarker(
                                    color: _statusColor(p.status),
                                    selected: p.id == widget.selectedPostcardId,
                                  ),
                                ),
                              ),
                        ],
                        builder: (_, markers) => Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: theme.colorScheme.primary
                                .withValues(alpha: 0.92),
                            border: Border.all(color: Colors.white, width: 2),
                            boxShadow: const [
                              BoxShadow(
                                color: Colors.black26,
                                blurRadius: 4,
                                offset: Offset(0, 1),
                              ),
                            ],
                          ),
                          child: Center(
                            child: Text(
                              '${markers.length}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // ── Journey overlay for the selected postcard ──
                    if (journey != null) ...[
                      // Solid arrows between consecutive hops the
                      // postcard has actually been at.
                      if (journey.actualSegments.isNotEmpty)
                        PolylineLayer(
                          polylines: [
                            for (final seg in journey.actualSegments)
                              Polyline(
                                points: [seg.from, seg.to],
                                strokeWidth: 3,
                                color: journey.color,
                              ),
                          ],
                        ),
                      // Semi-transparent arrows from the last-known
                      // location to each "possible destination".
                      if (journey.possibleSegments.isNotEmpty)
                        PolylineLayer(
                          polylines: [
                            for (final seg in journey.possibleSegments)
                              Polyline(
                                points: [seg.from, seg.to],
                                strokeWidth: 2,
                                color: journey.color.withValues(alpha: 0.35),
                              ),
                          ],
                        ),
                      // Distance + age pills at each segment midpoint.
                      MarkerLayer(
                        markers: [
                          for (final seg in journey.actualSegments)
                            _segmentLabelMarker(
                              seg,
                              color: journey.color,
                            ),
                          for (final seg in journey.possibleSegments)
                            _segmentLabelMarker(
                              seg,
                              color: journey.color,
                              dim: true,
                            ),
                        ],
                      ),
                      // Hop markers (pickup, intermediate carriers,
                      // last-seen) drawn on top of the arrows so the
                      // dots sit at the line endpoints visually.
                      MarkerLayer(
                        markers: [
                          for (final hop in journey.hops)
                            _hopMarker(hop),
                          for (final dst in journey.possibleDestinations)
                            Marker(
                              point: dst,
                              width: 26,
                              height: 26,
                              child: Container(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: journey.color
                                      .withValues(alpha: 0.45),
                                  border: Border.all(
                                    color: Colors.white,
                                    width: 2,
                                  ),
                                ),
                                child: const Icon(
                                  Icons.flag_outlined,
                                  size: 14,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                )
              else
                const Center(child: CircularProgressIndicator()),
              if (widget.postcards.isEmpty && _mapInitialized)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 16,
                  child: Material(
                    elevation: 2,
                    borderRadius: BorderRadius.circular(20),
                    color: theme.colorScheme.surface.withValues(alpha: 0.92),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      child: Text(
                        widget.i18n.t('no_postcards_match_filter'),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Journey overlay computation ─────────────────────────────────

  /// Build the geographic story for the given postcard:
  ///   • hops = where it has actually been (each carrier stamp + the
  ///            delivery receipt location if delivered).
  ///   • possibleDestinations = recipient_locations not yet reached.
  ///   • actualSegments = arrows between consecutive hops.
  ///   • possibleSegments = arrows from the last known location to
  ///     each possible destination.
  /// Returns null when the postcard has no journey data at all (no
  /// stamps and no recipient locations) — there's nothing to draw.
  _Journey? _journeyOf(Postcard p) {
    final hops = <_Hop>[];

    // If the postcard has no carrier stamps yet but I am the sender
    // and we have a fresh GPS fix, my current location is the natural
    // origin — that's where the postcard physically came from.
    if (p.stamps.isEmpty &&
        widget.myLocation != null &&
        widget.myCallsign != null &&
        p.senderCallsign.toUpperCase() == widget.myCallsign!.toUpperCase()) {
      hops.add(_Hop(
        position: widget.myLocation!,
        label: p.senderCallsign,
        sublabel: widget.i18n.t('sender'),
        timestamp: p.createdDateTime,
        kind: _HopKind.pickup,
        index: 0,
      ));
    }

    for (var i = 0; i < p.stamps.length; i++) {
      final s = p.stamps[i];
      hops.add(_Hop(
        position: LatLng(s.latitude, s.longitude),
        label: s.stamperCallsign,
        sublabel: s.locationName,
        timestamp: s.dateTime,
        kind: i == 0 && hops.isEmpty ? _HopKind.pickup : _HopKind.carrier,
        index: i + 1,
      ));
    }

    if (p.deliveryReceipt != null) {
      final r = p.deliveryReceipt!;
      hops.add(_Hop(
        position: LatLng(r.deliveryLatitude, r.deliveryLongitude),
        label: p.recipientCallsign ?? widget.i18n.t('recipient'),
        sublabel: r.deliveryLocationName,
        timestamp: r.dateTime,
        kind: _HopKind.delivered,
        index: hops.length + 1,
      ));
    } else if (p.stamps.isNotEmpty) {
      // Only promote when there are actual carrier stamps. A synthesized
      // origin (sender-with-no-stamps) keeps the pickup icon — it has not
      // been "last seen" anywhere new.
      hops[hops.length - 1] = hops.last.asLastSeen();
    }

    final possibleDestinations = <LatLng>[];
    if (p.deliveryReceipt == null) {
      for (final loc in p.recipientLocations) {
        final pos = LatLng(loc.latitude, loc.longitude);
        // Skip recipient locations the postcard has already reached
        // (collapses the trivial "last seen == only destination" case).
        if (hops.isNotEmpty &&
            hops.last.position.latitude == pos.latitude &&
            hops.last.position.longitude == pos.longitude) {
          continue;
        }
        possibleDestinations.add(pos);
      }
    }

    if (hops.isEmpty && possibleDestinations.isEmpty) return null;

    final actualSegments = <_Segment>[];
    for (var i = 0; i < hops.length - 1; i++) {
      actualSegments.add(_Segment(
        from: hops[i].position,
        to: hops[i + 1].position,
        sinceTimestamp: hops[i + 1].timestamp,
      ));
    }

    final possibleSegments = <_Segment>[];
    if (hops.isNotEmpty) {
      final from = hops.last.position;
      for (final dst in possibleDestinations) {
        possibleSegments.add(_Segment(
          from: from,
          to: dst,
          sinceTimestamp: null,
        ));
      }
    }

    return _Journey(
      hops: hops,
      possibleDestinations: possibleDestinations,
      actualSegments: actualSegments,
      possibleSegments: possibleSegments,
      color: _statusColor(p.status),
    );
  }

  Marker _hopMarker(_Hop hop) {
    final IconData icon;
    final Color fill;
    switch (hop.kind) {
      case _HopKind.pickup:
        icon = Icons.flag;
        fill = Colors.green.shade700;
        break;
      case _HopKind.carrier:
        icon = Icons.location_on;
        fill = Colors.blue.shade700;
        break;
      case _HopKind.lastSeen:
        icon = Icons.location_searching;
        fill = Colors.orange.shade700;
        break;
      case _HopKind.delivered:
        icon = Icons.mark_email_read_outlined;
        fill = Colors.green.shade700;
        break;
    }
    return Marker(
      point: hop.position,
      width: 36,
      height: 36,
      child: Container(
        decoration: BoxDecoration(
          color: fill,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: const [
            BoxShadow(
              color: Colors.black38,
              blurRadius: 5,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Icon(icon, color: Colors.white, size: 18),
      ),
    );
  }

  Marker _segmentLabelMarker(
    _Segment seg, {
    required Color color,
    bool dim = false,
  }) {
    final mid = LatLng(
      (seg.from.latitude + seg.to.latitude) / 2,
      (seg.from.longitude + seg.to.longitude) / 2,
    );
    final km = LocationService().calculateDistance(
      seg.from.latitude,
      seg.from.longitude,
      seg.to.latitude,
      seg.to.longitude,
    );
    final since = seg.sinceTimestamp;
    final age = since == null ? null : _formatAge(since);
    return Marker(
      point: mid,
      width: 150,
      height: 32,
      child: _SegmentPill(
        km: km,
        ageLabel: age,
        color: dim ? color.withValues(alpha: 0.7) : color,
      ),
    );
  }

  /// "3h ago" / "2d ago" / "Apr 24" — short and dense for an arrow label.
  String _formatAge(DateTime when) {
    final delta = DateTime.now().difference(when);
    if (delta.isNegative) return '';
    if (delta.inMinutes < 60) {
      final m = delta.inMinutes.clamp(1, 59);
      return '${m}m ago';
    }
    if (delta.inHours < 24) return '${delta.inHours}h ago';
    if (delta.inDays < 14) return '${delta.inDays}d ago';
    final m = when.month.toString().padLeft(2, '0');
    final d = when.day.toString().padLeft(2, '0');
    return '$m-$d';
  }

  Widget _buildToolbar(ThemeData theme) {
    final filters = const ['all', 'in-transit', 'delivered', 'acknowledged', 'expired'];
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Column(
        children: [
          TextField(
            controller: widget.searchController,
            decoration: InputDecoration(
              hintText: widget.i18n.t('search_postcards'),
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: widget.searchController.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: widget.searchController.clear,
                    ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 32,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final s in filters) ...[
                  _filterChip(s, theme),
                  const SizedBox(width: 6),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterChip(String status, ThemeData theme) {
    final selected = widget.statusFilter == status;
    final count = widget.statusCount(status);
    final label = status == 'all'
        ? widget.i18n.t('all')
        : widget.i18n.t(status.replaceAll('-', '_'));
    return ChoiceChip(
      label: Text('$label ($count)'),
      selected: selected,
      onSelected: (_) => widget.onStatusFilter(status),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}

/// Plain coloured dot for a single (un-clustered) postcard. The status
/// is conveyed by the colour; trying to pack an icon inside a 22 px
/// circle made things look cluttered, especially when several
/// postcards landed at adjacent coords.
class _PostcardMarker extends StatelessWidget {
  final Color color;
  final bool selected;

  const _PostcardMarker({required this.color, required this.selected});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        border: Border.all(
          color: Colors.white,
          width: selected ? 3 : 2,
        ),
        boxShadow: const [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 3,
            offset: Offset(0, 1),
          ),
        ],
      ),
    );
  }
}

/// One step on the postcard's geographic story.
enum _HopKind { pickup, carrier, lastSeen, delivered }

class _Hop {
  final LatLng position;
  final String label;
  final String? sublabel;
  final DateTime timestamp;
  final _HopKind kind;
  final int index;

  const _Hop({
    required this.position,
    required this.label,
    this.sublabel,
    required this.timestamp,
    required this.kind,
    required this.index,
  });

  _Hop asLastSeen() => _Hop(
        position: position,
        label: label,
        sublabel: sublabel,
        timestamp: timestamp,
        kind: _HopKind.lastSeen,
        index: index,
      );
}

/// A single arrow segment on the map.
class _Segment {
  final LatLng from;
  final LatLng to;
  final DateTime? sinceTimestamp;
  const _Segment({
    required this.from,
    required this.to,
    required this.sinceTimestamp,
  });
}

/// Aggregated geographic story for a selected postcard.
class _Journey {
  final List<_Hop> hops;
  final List<LatLng> possibleDestinations;
  final List<_Segment> actualSegments;
  final List<_Segment> possibleSegments;
  final Color color;

  const _Journey({
    required this.hops,
    required this.possibleDestinations,
    required this.actualSegments,
    required this.possibleSegments,
    required this.color,
  });
}

/// Pill rendered at the midpoint of a journey segment. Single line for
/// distance only ("412 km"), two lines when an "since" age is included
/// ("412 km · 3d ago").
class _SegmentPill extends StatelessWidget {
  final double km;
  final String? ageLabel;
  final Color color;
  const _SegmentPill({
    required this.km,
    required this.color,
    this.ageLabel,
  });

  String _formatKm(double km) {
    if (km < 1) return '${(km * 1000).round()} m';
    if (km < 10) return '${km.toStringAsFixed(1)} km';
    return '${km.round()} km';
  }

  @override
  Widget build(BuildContext context) {
    final txt = ageLabel == null || ageLabel!.isEmpty
        ? _formatKm(km)
        : '${_formatKm(km)} · $ageLabel';
    return IgnorePointer(
      child: Center(
        child: Material(
          elevation: 2,
          borderRadius: BorderRadius.circular(14),
          color: Colors.white.withValues(alpha: 0.95),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.arrow_forward, size: 14, color: color),
                const SizedBox(width: 4),
                Text(
                  txt,
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
