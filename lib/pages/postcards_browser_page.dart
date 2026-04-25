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

    // Auto-select the most recent postcard (first in the list)
    if (_allPostcards.isNotEmpty && _selectedPostcard == null) {
      await _selectPostcard(_allPostcards.first);
    }
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
                  // Wide: main view on the left (map gets the lion's
                  // share), detail on the right.
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

  IconData _statusIcon(String status) {
    switch (status) {
      case 'delivered':
        return Icons.mark_email_read_outlined;
      case 'acknowledged':
        return Icons.done_all;
      case 'expired':
        return Icons.schedule;
      default:
        return Icons.mail_outline;
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
    final selectedDst = selected == null ? null : _destinationOf(selected);
    final me = widget.myLocation;

    final hasArrow = me != null && selectedDst != null;
    final distanceKm = hasArrow
        ? LocationService().calculateDistance(
            me.latitude, me.longitude,
            selectedDst.latitude, selectedDst.longitude,
          )
        : null;

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
                    // Arrow + distance overlay for the selected postcard.
                    if (me != null && selected != null && selectedDst != null) ...[
                      PolylineLayer(
                        polylines: [
                          Polyline(
                            points: [me, selectedDst],
                            strokeWidth: 3,
                            color: _statusColor(selected.status)
                                .withValues(alpha: 0.85),
                          ),
                        ],
                      ),
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: LatLng(
                              (me.latitude + selectedDst.latitude) / 2,
                              (me.longitude + selectedDst.longitude) / 2,
                            ),
                            width: 110,
                            height: 28,
                            child: _DistancePill(
                              km: distanceKm ?? 0,
                              color: _statusColor(selected.status),
                            ),
                          ),
                        ],
                      ),
                    ],
                    // "Me" marker.
                    if (me != null)
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: me,
                            width: 28,
                            height: 28,
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
                    // Postcard markers, clustered.
                    MarkerClusterLayerWidget(
                      options: MarkerClusterLayerOptions(
                        maxClusterRadius: 80,
                        size: const Size(48, 48),
                        alignment: Alignment.center,
                        padding: const EdgeInsets.all(50),
                        maxZoom: 15,
                        markers: [
                          for (final p in widget.postcards)
                            if (_destinationOf(p) != null)
                              Marker(
                                point: _destinationOf(p)!,
                                width: 38,
                                height: 38,
                                child: GestureDetector(
                                  onTap: () => widget.onPostcardTap(p),
                                  child: _PostcardMarker(
                                    color: _statusColor(p.status),
                                    icon: _statusIcon(p.status),
                                    selected: p.id == widget.selectedPostcardId,
                                  ),
                                ),
                              ),
                        ],
                        builder: (_, markers) => Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: theme.colorScheme.primary,
                            border: Border.all(color: Colors.white, width: 3),
                            boxShadow: const [
                              BoxShadow(
                                color: Colors.black26,
                                blurRadius: 6,
                                offset: Offset(0, 2),
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

class _PostcardMarker extends StatelessWidget {
  final Color color;
  final IconData icon;
  final bool selected;

  const _PostcardMarker({
    required this.color,
    required this.icon,
    required this.selected,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        border: Border.all(
          color: selected ? Colors.white : Colors.white.withValues(alpha: 0.6),
          width: selected ? 3 : 2,
        ),
        boxShadow: const [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 4,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Icon(icon, color: Colors.white, size: selected ? 22 : 18),
    );
  }
}

class _DistancePill extends StatelessWidget {
  final double km;
  final Color color;
  const _DistancePill({required this.km, required this.color});

  String _format(double km) {
    if (km < 1) return '${(km * 1000).round()} m';
    if (km < 10) return '${km.toStringAsFixed(1)} km';
    return '${km.round()} km';
  }

  @override
  Widget build(BuildContext context) {
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
                  _format(km),
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
