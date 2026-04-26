/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:math' as math;

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
import 'city_picker_page.dart';
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

  /// Long-press handler on the "+" AppBar icon. Generates 2000
  /// synthetic postcards spread across Portuguese cities so the map
  /// can be evaluated against realistic density.
  Future<void> _seedSamples() async {
    final messenger = ScaffoldMessenger.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Inject sample postcards'),
        content: const Text(
          'This adds 2000 synthetic postcards across 30 Portuguese '
          'cities, with random journeys and statuses. Useful for '
          'testing the map; safe to delete from the postcards/ '
          'directory afterwards.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Inject 2000'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    messenger.showSnackBar(
      const SnackBar(content: Text('Seeding 2000 sample postcards…')),
    );
    final n = await _postcardService.seedSamplePostcards(count: 2000);
    if (!mounted) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(content: Text('Seeded $n sample postcards.')),
    );
    await _loadPostcards();
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
            icon: const Icon(Icons.science_outlined),
            tooltip: 'Inject 2000 sample postcards (debug)',
            onPressed: _seedSamples,
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

                // Map is always full-width. The selected-postcard
                // preview lives as a floating card on top of the map
                // (rendered inside _PostcardsMapView), and tapping
                // "Open" on that card pushes the full detail page.
                return mainView;
              },
            ),
    );
  }

  // ── Map view ──────────────────────────────────────────────────────

  Widget _buildMapView(ThemeData theme, {required bool isMobileView}) {
    return _PostcardsMapView(
      postcards: _filteredPostcards,
      selectedPostcard: _selectedPostcard,
      myLocation: _myLocation,
      myCallsign: _currentCallsign,
      statusFilter: _statusFilter,
      onStatusFilter: _setStatusFilter,
      statusCount: _getStatusCount,
      i18n: _i18n,
      searchController: _searchController,
      onPostcardTap: _selectPostcard,
      onClearSelection: () => setState(() => _selectedPostcard = null),
      onOpenSelected: () async {
        if (_selectedPostcard == null) return;
        await _selectPostcardMobile(_selectedPostcard!);
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
  final Postcard? selectedPostcard;
  final LatLng? myLocation;
  final String? myCallsign;
  final String statusFilter;
  final ValueChanged<String> onStatusFilter;
  final int Function(String status) statusCount;
  final I18nService i18n;
  final TextEditingController searchController;
  final ValueChanged<Postcard> onPostcardTap;
  final VoidCallback onClearSelection;
  final VoidCallback onOpenSelected;

  String? get selectedPostcardId => selectedPostcard?.id;

  const _PostcardsMapView({
    required this.postcards,
    required this.selectedPostcard,
    required this.myLocation,
    required this.myCallsign,
    required this.statusFilter,
    required this.onStatusFilter,
    required this.statusCount,
    required this.i18n,
    required this.searchController,
    required this.onPostcardTap,
    required this.onClearSelection,
    required this.onOpenSelected,
  });

  @override
  State<_PostcardsMapView> createState() => _PostcardsMapViewState();
}

class _PostcardsMapViewState extends State<_PostcardsMapView>
    with TickerProviderStateMixin {
  final MapController _mapController = MapController();
  final MapTileService _mapTileService = MapTileService();
  bool _mapInitialized = false;

  static const LatLng _defaultCenter = LatLng(40.0, -3.7);
  static const double _defaultZoom = 4.0;

  // Smooth camera animation. The map controller's move/fitCamera are
  // instant snaps; we animate by ticking move() per frame.
  AnimationController? _camController;
  Animation<double>? _camAnim;
  LatLng? _camFromCenter;
  LatLng? _camToCenter;
  double _camFromZoom = 0;
  double _camToZoom = 0;

  @override
  void initState() {
    super.initState();
    _initializeMap();
  }

  @override
  void dispose() {
    _camController?.dispose();
    super.dispose();
  }

  /// Smoothly animate the map from its current camera state to
  /// [target] (centre + zoom). Used on selection changes so picking a
  /// postcard glides instead of teleporting.
  void _animateCameraTo(LatLng target, double zoom) {
    _camController?.dispose();
    _camFromCenter = _mapController.camera.center;
    _camToCenter = target;
    _camFromZoom = _mapController.camera.zoom;
    _camToZoom = zoom;

    _camController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _camAnim = CurvedAnimation(
      parent: _camController!,
      curve: Curves.easeInOutCubic,
    );
    _camAnim!.addListener(() {
      final t = _camAnim!.value;
      final lat = _camFromCenter!.latitude +
          (_camToCenter!.latitude - _camFromCenter!.latitude) * t;
      final lng = _camFromCenter!.longitude +
          (_camToCenter!.longitude - _camFromCenter!.longitude) * t;
      final z = _camFromZoom + (_camToZoom - _camFromZoom) * t;
      _mapController.move(LatLng(lat, lng), z);
    });
    _camController!.forward();
  }

  /// Animate the camera so [points] all fit on screen with padding.
  /// Computes the centre and a zoom that fits the bounding box.
  void _animateFitBounds(List<LatLng> points, {double pad = 60}) {
    if (points.isEmpty) return;
    if (points.length == 1) {
      _animateCameraTo(points.first, 10);
      return;
    }
    var minLat = double.infinity, maxLat = -double.infinity;
    var minLng = double.infinity, maxLng = -double.infinity;
    for (final p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    final centre = LatLng((minLat + maxLat) / 2, (minLng + maxLng) / 2);
    // Use flutter_map's camera-fit math by asking it to compute the
    // target zoom for these bounds, then animate to that.
    final fit = CameraFit.bounds(
      bounds: LatLngBounds(LatLng(minLat, minLng), LatLng(maxLat, maxLng)),
      padding: EdgeInsets.all(pad),
    );
    final fitted = fit.fit(_mapController.camera);
    _animateCameraTo(centre, fitted.zoom);
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
        _animateFitBounds(pts);
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

  /// Density colour for cluster bubbles. Light green for a handful of
  /// postcards, scaling through blue / orange / red as the count rises
  /// — at a glance the courier sees where messages pile up.
  Color _heatColor(int count) {
    if (count >= 200) return Colors.red.shade700;
    if (count >= 100) return Colors.deepOrange.shade600;
    if (count >= 40) return Colors.orange.shade600;
    if (count >= 15) return Colors.amber.shade700;
    if (count >= 5) return Colors.lightBlue.shade600;
    return Colors.green.shade600;
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

  Postcard? _selectedPostcard() => widget.selectedPostcard;

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
                    // Tapping empty map area dismisses the selected
                    // postcard's floating preview / journey overlay.
                    onTap: (_, __) {
                      if (widget.selectedPostcard != null) {
                        widget.onClearSelection();
                      }
                    },
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
                        builder: (_, markers) {
                          // Heat colour: light → blue → orange → red as
                          // the cluster gets denser. Tells the courier
                          // at a glance "lots of mail wants to go here".
                          final n = markers.length;
                          final color = _heatColor(n);
                          final size = (28 + math.sqrt(n) * 4)
                              .clamp(28.0, 64.0);
                          return Container(
                            width: size,
                            height: size,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: color.withValues(alpha: 0.92),
                              border: Border.all(
                                color: Colors.white,
                                width: 2,
                              ),
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
                                n > 999 ? '${(n / 1000).toStringAsFixed(1)}k' : '$n',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          );
                        },
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
              // Courier-helper FAB sits top-right; pops a bottom
              // sheet that asks where the user is going and lists
              // postcards heading toward the same area.
              if (_mapInitialized)
                Positioned(
                  right: 12,
                  top: 12,
                  child: FloatingActionButton.small(
                    heroTag: 'courier_helper',
                    backgroundColor: theme.colorScheme.primary,
                    foregroundColor: theme.colorScheme.onPrimary,
                    onPressed: _openCourierHelper,
                    tooltip: 'Help deliver — find postcards heading my way',
                    child: const Icon(Icons.alt_route),
                  ),
                ),
              // Floating preview for the currently-selected postcard.
              if (selected != null)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 16,
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 480),
                      child: _PostcardPreviewCard(
                        postcard: selected,
                        statusColor: _statusColor(selected.status),
                        onClose: widget.onClearSelection,
                        onOpen: widget.onOpenSelected,
                        i18n: widget.i18n,
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

  // ── Courier helper ──────────────────────────────────────────────

  LatLng? _courierFrom;
  LatLng? _courierTo;
  String? _courierFromLabel;
  String? _courierToLabel;

  Future<void> _openCourierHelper() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final theme = Theme.of(ctx);
          final candidates = _courierTo == null
              ? const <_CourierCandidate>[]
              : _bestCandidates(_courierTo!);
          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.6,
            minChildSize: 0.35,
            maxChildSize: 0.92,
            builder: (_, scroll) => Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.outlineVariant,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Help deliver',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    'Pick where you are and where you are going. We\'ll show '
                    'postcards heading near your destination.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.my_location, size: 16),
                          label: Text(
                            _courierFromLabel ?? 'I am here…',
                            overflow: TextOverflow.ellipsis,
                          ),
                          onPressed: () async {
                            final c = await Navigator.push<CityEntry>(
                              ctx,
                              MaterialPageRoute(
                                builder: (_) => const CityPickerPage(),
                              ),
                            );
                            if (c == null) return;
                            setSheet(() {
                              _courierFrom = LatLng(c.lat, c.lng);
                              _courierFromLabel = c.city;
                            });
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.flag_outlined, size: 16),
                          label: Text(
                            _courierToLabel ?? 'Going to…',
                            overflow: TextOverflow.ellipsis,
                          ),
                          onPressed: () async {
                            final c = await Navigator.push<CityEntry>(
                              ctx,
                              MaterialPageRoute(
                                builder: (_) => const CityPickerPage(),
                              ),
                            );
                            if (c == null) return;
                            setSheet(() {
                              _courierTo = LatLng(c.lat, c.lng);
                              _courierToLabel = c.city;
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_courierTo == null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                        child: Text(
                          'Set a destination to see candidates.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    )
                  else if (candidates.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                        child: Text(
                          'No postcards near $_courierToLabel yet.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    )
                  else
                    Expanded(
                      child: ListView.separated(
                        controller: scroll,
                        itemCount: candidates.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final c = candidates[i];
                          return ListTile(
                            dense: true,
                            leading: CircleAvatar(
                              radius: 14,
                              backgroundColor: _statusColor(c.postcard.status),
                              child: const Icon(
                                Icons.mail_outline,
                                size: 14,
                                color: Colors.white,
                              ),
                            ),
                            title: Text(
                              c.postcard.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${c.postcard.senderCallsign} → '
                              '${c.postcard.recipientCallsign ?? '—'}'
                              '   ·   ${c.distanceKm.toStringAsFixed(0)} km',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () {
                              Navigator.pop(ctx);
                              widget.onPostcardTap(c.postcard);
                            },
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Score every postcard by straight-line distance from its first
  /// recipient location to the courier's destination, return the top 30.
  List<_CourierCandidate> _bestCandidates(LatLng dest) {
    final scored = <_CourierCandidate>[];
    for (final p in widget.postcards) {
      final d = _destinationOf(p);
      if (d == null) continue;
      final km = LocationService().calculateDistance(
        dest.latitude,
        dest.longitude,
        d.latitude,
        d.longitude,
      );
      scored.add(_CourierCandidate(postcard: p, distanceKm: km));
    }
    scored.sort((a, b) => a.distanceKm.compareTo(b.distanceKm));
    return scored.take(30).toList();
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

    // Synthesize an origin point so we always have something to draw
    // arrows from. Priority:
    //   1) my GPS fix when I am the sender (the real origin),
    //   2) my GPS fix even when I'm not the sender (visual reference
    //      so the map still tells a story),
    //   3) first recipient location as a synthetic departure point
    //      (clearly a fallback — flagged with the "pickup" icon and
    //      labelled with the sender callsign).
    if (p.stamps.isEmpty) {
      LatLng? origin;
      if (widget.myLocation != null &&
          widget.myCallsign != null &&
          p.senderCallsign.toUpperCase() ==
              widget.myCallsign!.toUpperCase()) {
        origin = widget.myLocation;
      } else if (widget.myLocation != null) {
        origin = widget.myLocation;
      } else if (p.recipientLocations.isNotEmpty) {
        final r = p.recipientLocations.first;
        origin = LatLng(r.latitude, r.longitude);
      }
      if (origin != null) {
        hops.add(_Hop(
          position: origin,
          label: p.senderCallsign,
          sublabel: widget.i18n.t('sender'),
          timestamp: p.createdDateTime,
          kind: _HopKind.pickup,
          index: 0,
        ));
      }
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

/// Floating preview card shown over the map when a postcard is
/// selected. Gives the title, From → To, and a path summary, plus
/// "Close" / "Open" actions. Replaces the wide-screen right-pane
/// detail panel, which the user found disruptive.
class _PostcardPreviewCard extends StatelessWidget {
  final Postcard postcard;
  final Color statusColor;
  final VoidCallback onClose;
  final VoidCallback onOpen;
  final I18nService i18n;

  const _PostcardPreviewCard({
    required this.postcard,
    required this.statusColor,
    required this.onClose,
    required this.onOpen,
    required this.i18n,
  });

  String _summary() {
    final from = postcard.senderCallsign;
    final to = postcard.recipientCallsign ?? '—';
    final hops = postcard.stamps.length;
    final hopsLabel = hops == 0
        ? 'no hops yet'
        : '$hops hop${hops == 1 ? '' : 's'}';
    return '$from → $to · $hopsLabel';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(12),
      color: theme.colorScheme.surface.withValues(alpha: 0.97),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 4,
              height: 44,
              margin: const EdgeInsets.only(right: 12, top: 2),
              decoration: BoxDecoration(
                color: statusColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    postcard.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _summary(),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          i18n.t(postcard.status.replaceAll('-', '_')),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: statusColor,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Column(
              children: [
                IconButton(
                  icon: const Icon(Icons.open_in_new, size: 18),
                  tooltip: 'Open',
                  onPressed: onOpen,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'Close',
                  onPressed: onClose,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One row in the courier-helper bottom sheet's results list.
class _CourierCandidate {
  final Postcard postcard;
  final double distanceKm;
  const _CourierCandidate({required this.postcard, required this.distanceKm});
}
