import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/tracker_models.dart';
import '../models/trackable_type.dart';
import '../models/tracker_proximity_track.dart';
import '../services/tracker_service.dart';
import '../services/path_recording_service.dart';
import '../services/proximity_detection_service.dart';
import '../dialogs/add_trackable_dialog.dart';
import '../dialogs/create_plan_dialog.dart';
import '../dialogs/edit_path_dialog.dart';
import '../dialogs/start_path_dialog.dart';
import '../widgets/active_recording_banner.dart';
import 'path_detail_page.dart';
import 'exercise_detail_page.dart';
import 'measurement_detail_page.dart';
import 'plan_detail_page.dart';
import 'proximity_detail_page.dart';
import '../../services/i18n_service.dart';
import '../../services/config_service.dart';
import '../../services/profile_service.dart';
import '../../services/log_service.dart';
import '../../services/app_service.dart';
import '../../services/profile_storage.dart';

/// Tab type for the tracker browser
enum TrackerTab {
  paths,
  exercises,
  measurements,
  plans,
  proximity, // Unified: devices + places (within 50m)
  sharing,
}

/// Filter for proximity tab display
enum ProximityFilter { all, devices, places }

/// Tabs that are hidden (not yet functional)
const Set<TrackerTab> _hiddenTabs = {TrackerTab.plans, TrackerTab.sharing};

/// Get the list of visible tabs (excluding hidden ones)
List<TrackerTab> get _visibleTabValues =>
    TrackerTab.values.where((t) => !_hiddenTabs.contains(t)).toList();

/// Main tracker browser page with tabbed layout
class TrackerBrowserPage extends StatefulWidget {
  final String appPath;
  final String appTitle;
  final I18nService i18n;
  final String? ownerCallsign;

  const TrackerBrowserPage({
    super.key,
    required this.appPath,
    required this.appTitle,
    required this.i18n,
    this.ownerCallsign,
  });

  @override
  State<TrackerBrowserPage> createState() => _TrackerBrowserPageState();
}

class _TrackerBrowserPageState extends State<TrackerBrowserPage>
    with SingleTickerProviderStateMixin {
  final TrackerService _service = TrackerService();
  final PathRecordingService _recordingService = PathRecordingService();
  final ConfigService _configService = ConfigService();

  late TabController _tabController;
  bool _loading = true;
  StreamSubscription? _changesSub;

  /// Tabs sorted by weighted usage score (frequency + recency with 30-day decay)
  List<TrackerTab> _sortedTabs = _visibleTabValues;
  Map<String, List<int>> _tabUsageHistory = {}; // tab name -> list of usage timestamps

  /// User-selected trackables to show in each tab
  List<String> _visibleExercises = [];
  List<String> _visibleMeasurements = [];

  // Data for each tab
  Map<int, List<TrackerPath>> _pathsByYear = {};
  List<int> _pathYears = [];
  final Set<String> _expandedYearKeys = {};
  final Set<String> _expandedWeekKeys = {};
  final TextEditingController _pathSearchController = TextEditingController();
  String _pathSearchQuery = '';

  // Multi-select for path merge
  bool _multiSelectMode = false;
  final Set<String> _selectedPathIds = {};
  int? _selectedPathYear;
  List<String> _exerciseTypes = [];
  List<String> _measurementTypes = [];
  Map<String, int> _weeklyTotals = {}; // Used for both exercises and measurements
  List<TrackerPlan> _activePlans = [];

  // Proximity data (organized by year/week like paths)
  Map<int, Map<int, List<ProximityTrack>>> _proximityByYearWeek = {};
  List<int> _proximityYears = [];
  final Set<String> _expandedProximityYearKeys = {};
  final Set<String> _expandedProximityWeekKeys = {};
  ProximityFilter _proximityFilter = ProximityFilter.all;
  bool _proximityTrackingEnabled = true;

  List<GroupShare> _groupShares = [];
  List<TemporaryShare> _temporaryShares = [];
  List<ReceivedLocation> _receivedLocations = [];

  int _selectedYear = DateTime.now().year;

  @override
  void initState() {
    super.initState();
    _loadTabUsage();
    _loadProximityTrackingEnabled();
    _tabController = TabController(length: _visibleTabValues.length, vsync: this);
    _tabController.addListener(_onTabChanged);
    _loadVisibleTrackables();
    _initializeService();
  }

  void _loadProximityTrackingEnabled() {
    final saved = _configService.getNestedValue('tracker.proximityTrackingEnabled');
    _proximityTrackingEnabled = saved != false; // Default true if not set
  }

  void _setProximityTrackingEnabled(bool enabled) {
    LogService().log('TrackerBrowser: _setProximityTrackingEnabled($enabled) called');
    setState(() => _proximityTrackingEnabled = enabled);
    _configService.setNestedValue('tracker.proximityTrackingEnabled', enabled);

    if (enabled) {
      // Store collection path for auto-start on app restart
      _configService.setNestedValue('tracker.proximityCollectionPath', widget.appPath);
      LogService().log('TrackerBrowser: Calling ProximityDetectionService().start()');
      ProximityDetectionService().start(_service);
    } else {
      LogService().log('TrackerBrowser: Calling ProximityDetectionService().stop()');
      ProximityDetectionService().stop();
    }
  }

  // ============ Tab Usage Tracking (weighted score with 30-day decay) ============

  /// Expiration period for usage history (30 days in milliseconds)
  static const int _usageExpirationMs = 30 * 24 * 60 * 60 * 1000;

  void _loadTabUsage() {
    final saved = _configService.getNestedValue('tracker.tabUsageHistory');
    if (saved is Map) {
      // New format: Map<String, List<int>>
      _tabUsageHistory = Map<String, List<int>>.from(
        saved.map((k, v) => MapEntry(
          k.toString(),
          (v as List).map((e) => e as int).toList(),
        )),
      );
    } else {
      // Check for old format migration: Map<String, int>
      final oldSaved = _configService.getNestedValue('tracker.tabLastUsed');
      if (oldSaved is Map) {
        // Migrate old format to new format
        _tabUsageHistory = Map<String, List<int>>.from(
          oldSaved.map((k, v) => MapEntry(k.toString(), [v as int])),
        );
        // Save in new format and clear old key
        _saveTabUsage();
      }
    }
    _cleanupExpiredUsage();
    _sortTabs();
  }

  void _saveTabUsage() {
    _configService.setNestedValue('tracker.tabUsageHistory', _tabUsageHistory);
  }

  void _cleanupExpiredUsage() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final cutoff = now - _usageExpirationMs;

    for (final tabName in _tabUsageHistory.keys) {
      _tabUsageHistory[tabName] = _tabUsageHistory[tabName]!
          .where((ts) => ts >= cutoff)
          .toList();
    }
    // Remove empty entries
    _tabUsageHistory.removeWhere((_, timestamps) => timestamps.isEmpty);
  }

  /// Calculate weighted usage score for a tab.
  /// Recent uses count more than older ones, with exponential decay over 30 days.
  double _calculateTabScore(List<int>? timestamps) {
    if (timestamps == null || timestamps.isEmpty) return 0;

    final now = DateTime.now().millisecondsSinceEpoch;
    final cutoff = now - _usageExpirationMs;
    double score = 0;

    for (final ts in timestamps) {
      if (ts < cutoff) continue; // Skip expired entries

      // Age in days (0-30)
      final ageMs = now - ts;
      final ageDays = ageMs / (24 * 60 * 60 * 1000);

      // Weight: 1.0 for today, decreasing to ~0.25 at 30 days
      // Using formula: 1 / (1 + ageDays * 0.1)
      final weight = 1.0 / (1.0 + ageDays * 0.1);
      score += weight;
    }
    return score;
  }

  void _sortTabs() {
    _sortedTabs = _visibleTabValues;
    _sortedTabs.sort((a, b) {
      final aScore = _calculateTabScore(_tabUsageHistory[a.name]);
      final bScore = _calculateTabScore(_tabUsageHistory[b.name]);
      return bScore.compareTo(aScore); // Highest score first
    });
  }

  void _recordTabUsage(TrackerTab tab) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _tabUsageHistory.putIfAbsent(tab.name, () => []);
    _tabUsageHistory[tab.name]!.add(now);

    // Cleanup expired entries periodically
    _cleanupExpiredUsage();
    _saveTabUsage();
    // Re-sort tabs for next time (don't reorder while user is viewing)
  }

  // ============ Visibility Management (unified for exercises & measurements) ============

  void _loadVisibleTrackables() {
    final savedExercises = _configService.getNestedValue('tracker.visibleExercises');
    if (savedExercises is List) {
      _visibleExercises = savedExercises.cast<String>().toList();
    }
    final savedMeasurements = _configService.getNestedValue('tracker.visibleMeasurements');
    if (savedMeasurements is List) {
      _visibleMeasurements = savedMeasurements.cast<String>().toList();
    }
  }

  List<String> _getVisibleList(TrackableKind kind) =>
      kind == TrackableKind.exercise ? _visibleExercises : _visibleMeasurements;

  void _saveVisibleList(TrackableKind kind) {
    final key = kind == TrackableKind.exercise
        ? 'tracker.visibleExercises'
        : 'tracker.visibleMeasurements';
    final list = _getVisibleList(kind);
    _configService.setNestedValue(key, list);
  }

  void _addToVisibleList(TrackableKind kind, String typeId) {
    final list = _getVisibleList(kind);
    if (!list.contains(typeId)) {
      setState(() => list.add(typeId));
      _saveVisibleList(kind);
      _loadCurrentTab(); // Reload to get weekly totals
    }
  }

  void _removeFromVisibleList(TrackableKind kind, String typeId) {
    final list = _getVisibleList(kind);
    setState(() => list.remove(typeId));
    _saveVisibleList(kind);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _changesSub?.cancel();
    _recordingService.removeListener(_onRecordingChanged);
    _pathSearchController.dispose();
    super.dispose();
  }

  Future<void> _initializeService() async {
    final profileCallsign = ProfileService().getProfile().callsign;
    final ownerCallsign =
        widget.ownerCallsign != null && widget.ownerCallsign!.isNotEmpty
            ? widget.ownerCallsign!
            : profileCallsign;

    // Set up storage for the service (encrypted or filesystem)
    final profileStorage = AppService().profileStorage;
    if (profileStorage != null) {
      final scopedStorage = ScopedProfileStorage.fromAbsolutePath(
        profileStorage,
        widget.appPath,
      );
      _service.setStorage(scopedStorage);
    } else {
      _service.setStorage(FilesystemProfileStorage(widget.appPath));
    }

    await _service.initializeApp(
      widget.appPath,
      callsign: ownerCallsign,
    );
    _changesSub = _service.changes.listen(_onTrackerChange);

    // Initialize recording service and check for any active recording
    _recordingService.initialize(_service);
    _recordingService.addListener(_onRecordingChanged);
    await _recordingService.checkAndResumeRecording();

    // Start proximity detection service if enabled
    LogService().log('TrackerBrowser: _initializeService checking proximity: $_proximityTrackingEnabled');
    if (_proximityTrackingEnabled) {
      LogService().log('TrackerBrowser: Starting ProximityDetectionService from _initializeService');
      ProximityDetectionService().start(_service);
    }

    await _loadCurrentTab();
  }

  void _onTrackerChange(TrackerChange change) {
    _loadCurrentTab();
  }

  void _onRecordingChanged() {
    if (mounted) setState(() {});
  }

  void _onTabChanged() {
    if (_tabController.indexIsChanging) {
      _recordTabUsage(_currentTab);
      _loadCurrentTab();
    }
  }

  TrackerTab get _currentTab => _sortedTabs[_tabController.index];

  Future<void> _loadCurrentTab() async {
    setState(() => _loading = true);

    try {
      switch (_currentTab) {
        case TrackerTab.paths:
          final years = await _service.listPathYears();
          if (!years.contains(DateTime.now().year)) {
            years.add(DateTime.now().year);
          }
          years.sort((a, b) => b.compareTo(a));

          final byYear = <int, List<TrackerPath>>{};
          for (final year in years) {
            final paths = await _service.listPaths(year: year);
            paths.sort((a, b) =>
                b.startedAtDateTime.compareTo(a.startedAtDateTime));
            if (paths.isNotEmpty) {
              byYear[year] = paths;
            }
          }

          _pathYears = byYear.keys.toList()..sort((a, b) => b.compareTo(a));
          _pathsByYear = byYear;
          break;
        case TrackerTab.exercises:
          _exerciseTypes = await _service.listExerciseTypes(year: _selectedYear);
          // Load weekly totals for all visible exercises
          for (final typeId in _visibleExercises) {
            _weeklyTotals[typeId] = await _service.getExerciseWeekCount(
              typeId,
              year: _selectedYear,
            );
          }
          break;
        case TrackerTab.measurements:
          _measurementTypes = await _service.listMeasurementTypes(year: _selectedYear);
          // Load weekly totals for all visible measurements
          for (final typeId in _visibleMeasurements) {
            _weeklyTotals[typeId] = await _service.getMeasurementWeekCount(
              typeId,
              year: _selectedYear,
            );
          }
          break;
        case TrackerTab.plans:
          _activePlans = await _service.listActivePlans();
          break;
        case TrackerTab.proximity:
          // Load proximity data organized by year/week
          final years = await _service.listProximityYears();
          final now = DateTime.now();
          if (!years.contains(now.year)) {
            years.add(now.year);
          }
          years.sort((a, b) => b.compareTo(a));

          final byYearWeek = <int, Map<int, List<ProximityTrack>>>{};
          for (final year in years) {
            final weeks = await _service.listProximityWeeks(year: year);
            // Always include current week for current year
            if (year == now.year && !weeks.contains(getWeekNumber(now))) {
              weeks.add(getWeekNumber(now));
            }
            weeks.sort((a, b) => b.compareTo(a));

            if (weeks.isNotEmpty) {
              byYearWeek[year] = {};
              for (final week in weeks) {
                final tracks = await _service.getProximityTracks(year: year, week: week);
                // Sort by total time and limit to top 50
                tracks.sort((a, b) =>
                    b.weekSummary.totalSeconds.compareTo(a.weekSummary.totalSeconds));
                byYearWeek[year]![week] = tracks.take(50).toList();
              }
            }
          }

          _proximityYears = byYearWeek.keys.toList()..sort((a, b) => b.compareTo(a));
          _proximityByYearWeek = byYearWeek;
          break;
        case TrackerTab.sharing:
          _groupShares = await _service.listGroupShares();
          _temporaryShares = await _service.listTemporaryShares();
          _receivedLocations = await _service.listReceivedLocations();
          break;
      }
    } catch (e) {
      // Handle errors silently, data will be empty
    }

    if (mounted) {
      setState(() => _loading = false);
    }
  }

  String _getDisplayTitle() {
    if (widget.appTitle.startsWith('app_type_')) {
      return widget.i18n.t(widget.appTitle);
    }
    return widget.appTitle;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: _multiSelectMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: _exitMultiSelect,
              )
            : null,
        title: _multiSelectMode
            ? Text('${_selectedPathIds.length} ${widget.i18n.t('tracker_selected')}')
            : Text(_getDisplayTitle()),
        bottom: _multiSelectMode
            ? null
            : TabBar(
                controller: _tabController,
                isScrollable: true,
                tabs: _sortedTabs.map((tab) => _buildTab(tab)).toList(),
              ),
        actions: [
          if (_showYearSelector)
            PopupMenuButton<int>(
              initialValue: _selectedYear,
              onSelected: (year) {
                setState(() => _selectedYear = year);
                _loadCurrentTab();
              },
              itemBuilder: (context) {
                final currentYear = DateTime.now().year;
                return List.generate(5, (i) => currentYear - i)
                    .map((year) => PopupMenuItem(
                          value: year,
                          child: Text(year.toString()),
                        ))
                    .toList();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_selectedYear.toString()),
                    const Icon(Icons.arrow_drop_down),
                  ],
                ),
              ),
            ),
        ],
      ),
      body: TabBarView(
        controller: _tabController,
        children: _sortedTabs.map((tab) => _buildTabContent(tab)).toList(),
      ),
      floatingActionButton: _buildFab(),
    );
  }

  bool get _showYearSelector {
    // Note: paths tab has its own year/week expansion tiles
    // Note: exercises/measurements tabs now use user-selected lists, no year filter needed
    // Note: proximity tab now has its own year/week expansion tiles
    return false;
  }

  Tab _buildTab(TrackerTab tab) {
    switch (tab) {
      case TrackerTab.paths:
        return Tab(icon: const Icon(Icons.route), text: widget.i18n.t('tracker_paths'));
      case TrackerTab.exercises:
        return Tab(icon: const Icon(Icons.fitness_center), text: widget.i18n.t('tracker_exercises'));
      case TrackerTab.measurements:
        return Tab(icon: const Icon(Icons.monitor_weight), text: widget.i18n.t('tracker_measurements'));
      case TrackerTab.plans:
        return Tab(icon: const Icon(Icons.flag), text: widget.i18n.t('tracker_plans'));
      case TrackerTab.proximity:
        return Tab(icon: const Icon(Icons.people), text: widget.i18n.t('tracker_proximity'));
      case TrackerTab.sharing:
        return Tab(icon: const Icon(Icons.share_location), text: widget.i18n.t('tracker_sharing'));
    }
  }

  Widget _buildTabContent(TrackerTab tab) {
    switch (tab) {
      case TrackerTab.paths:
        return _buildPathsTab();
      case TrackerTab.exercises:
        return _buildTrackableTab(TrackableKind.exercise);
      case TrackerTab.measurements:
        return _buildTrackableTab(TrackableKind.measurement);
      case TrackerTab.plans:
        return _buildPlansTab();
      case TrackerTab.proximity:
        return _buildProximityTab();
      case TrackerTab.sharing:
        return _buildSharingTab();
    }
  }

  Widget? _buildFab() {
    // In multi-select mode, show merge button
    if (_multiSelectMode && _selectedPathIds.length >= 2) {
      return FloatingActionButton.extended(
        onPressed: _showMergeDialog,
        icon: const Icon(Icons.merge),
        label: Text('${widget.i18n.t('tracker_merge')} (${_selectedPathIds.length})'),
      );
    }

    IconData icon;
    VoidCallback? onPressed;

    switch (_currentTab) {
      case TrackerTab.paths:
        icon = Icons.add_location_alt;
        onPressed = _onAddPath;
        break;
      case TrackerTab.exercises:
        icon = Icons.add;
        onPressed = () => _showAddToListDialog(TrackableKind.exercise);
        break;
      case TrackerTab.measurements:
        icon = Icons.add;
        onPressed = () => _showAddToListDialog(TrackableKind.measurement);
        break;
      case TrackerTab.plans:
        icon = Icons.add;
        onPressed = _onAddPlan;
        break;
      case TrackerTab.sharing:
        icon = Icons.share;
        onPressed = _onAddShare;
        break;
      default:
        return null;
    }

    return FloatingActionButton(
      onPressed: onPressed,
      child: Icon(icon),
    );
  }

  // ============ Tab Content Builders ============

  Widget _buildPathsTab() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final hasPaths = _pathsByYear.isNotEmpty;
    final hasSearch = _pathSearchQuery.isNotEmpty;

    return Column(
      children: [
        // Active recording banner
        if (_recordingService.hasActiveRecording)
          ActiveRecordingBanner(
            recordingService: _recordingService,
            i18n: widget.i18n,
            onStop: _loadCurrentTab,
            onTap: _openActivePath,
          ),

        // Search box
        if (hasPaths || hasSearch)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              controller: _pathSearchController,
              decoration: InputDecoration(
                hintText: widget.i18n.t('tracker_search_paths'),
                prefixIcon: const Icon(Icons.search),
                suffixIcon: hasSearch
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _pathSearchController.clear();
                          setState(() => _pathSearchQuery = '');
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                isDense: true,
              ),
              onChanged: (value) => setState(() => _pathSearchQuery = value),
            ),
          ),

        // Popular tags (always visible when paths exist)
        if (hasPaths) _buildPopularTags(),

        // Search results summary
        if (hasSearch) _buildSearchSummary(),

        // Path list
        Expanded(
          child: !hasPaths && !_recordingService.hasActiveRecording && !hasSearch
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.route, size: 64, color: Colors.grey[400]),
                      const SizedBox(height: 16),
                      Text(
                        widget.i18n.t('tracker_no_paths'),
                        style: TextStyle(color: Colors.grey[600]),
                      ),
                    ],
                  ),
                )
              : hasSearch
                  ? _buildSearchResults()
                  : ListView(
                      padding: const EdgeInsets.all(8),
                      children: _buildPathGroups(),
                    ),
        ),
      ],
    );
  }

  /// Get the most used tags across all paths (up to 10)
  List<String> _getPopularTags() {
    final tagCounts = <String, int>{};
    for (final paths in _pathsByYear.values) {
      for (final path in paths) {
        for (final tag in path.userTags) {
          tagCounts[tag] = (tagCounts[tag] ?? 0) + 1;
        }
      }
    }
    final sortedTags = tagCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sortedTags.take(10).map((e) => e.key).toList();
  }

  /// Build popular tags row
  Widget _buildPopularTags() {
    final popularTags = _getPopularTags();
    if (popularTags.isEmpty) return const SizedBox.shrink();

    // Get currently selected tag (if searching with #)
    final currentTagFilter = _pathSearchQuery.startsWith('#')
        ? _pathSearchQuery.substring(1).toLowerCase()
        : null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: popularTags.map((tag) {
            final isSelected = currentTagFilter == tag;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text('#$tag'),
                selected: isSelected,
                onSelected: (_) {
                  if (isSelected) {
                    // Clear filter if tapping currently selected tag
                    _pathSearchController.clear();
                    setState(() => _pathSearchQuery = '');
                  } else {
                    _pathSearchController.text = '#$tag';
                    setState(() => _pathSearchQuery = '#$tag');
                  }
                },
                visualDensity: VisualDensity.compact,
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  /// Build flat search results list (no year/week grouping)
  Widget _buildSearchResults() {
    final filteredPaths = _getFilteredPaths();
    if (filteredPaths.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              widget.i18n.t('tracker_no_paths'),
              style: TextStyle(color: Colors.grey[600]),
            ),
          ],
        ),
      );
    }

    // Sort by date descending
    filteredPaths.sort((a, b) => b.startedAtDateTime.compareTo(a.startedAtDateTime));

    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: filteredPaths.length,
      itemBuilder: (context, index) {
        final path = filteredPaths[index];
        final year = path.startedAtDateTime.year;
        return _buildPathTile(path, year);
      },
    );
  }

  /// Get filtered paths based on search query
  List<TrackerPath> _getFilteredPaths() {
    final allPaths = _pathsByYear.values.expand((paths) => paths).toList();
    if (_pathSearchQuery.isEmpty) return allPaths;
    return allPaths.where((path) => path.matchesSearch(_pathSearchQuery)).toList();
  }

  /// Build search results summary widget
  Widget _buildSearchSummary() {
    final filteredPaths = _getFilteredPaths();
    final pathCount = filteredPaths.length;
    final totalDistance = filteredPaths.fold<double>(
      0,
      (sum, path) => sum + path.totalDistanceMeters,
    );
    final totalPoints = filteredPaths.fold<int>(
      0,
      (sum, path) => sum + path.totalPoints,
    );
    final totalDuration = filteredPaths.fold<int>(
      0,
      (sum, path) => sum + (path.durationSeconds ?? 0),
    );

    final distanceKm = (totalDistance / 1000).toStringAsFixed(1);
    final durationStr = _formatDurationCompact(Duration(seconds: totalDuration));

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.3),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$pathCount ${widget.i18n.t('tracker_paths').toLowerCase()} • $distanceKm km • $durationStr • $totalPoints ${widget.i18n.t('tracker_points')}',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w500,
            ),
        textAlign: TextAlign.center,
      ),
    );
  }

  List<Widget> _buildPathGroups() {
    final now = DateTime.now();
    final currentWeekStart = _startOfWeek(now);
    final singleYear = _pathYears.length == 1;
    final widgets = <Widget>[];

    for (final year in _pathYears) {
      final paths = _pathsByYear[year] ?? const [];
      if (paths.isEmpty) continue;

      final weekGroups = _groupPathsByWeek(paths);
      final yearKey = 'year:$year';
      final isCurrentYear = year == now.year;
      final isExpanded = _expandedYearKeys.contains(yearKey) ||
          isCurrentYear ||
          (singleYear && isCurrentYear);

      final yearWidget = ExpansionTile(
        key: PageStorageKey<String>(yearKey),
        initiallyExpanded: isExpanded,
        title: Text(year.toString()),
        onExpansionChanged: (expanded) {
          setState(() {
            if (expanded) {
              _expandedYearKeys.add(yearKey);
            } else {
              _expandedYearKeys.remove(yearKey);
            }
          });
        },
        children: weekGroups.entries
            .map((entry) => _buildWeekTile(
                  entry.key,
                  entry.value,
                  currentWeekStart,
                  year,
                ))
            .toList(),
      );

      if (singleYear && isCurrentYear) {
        widgets.addAll(
          weekGroups.entries.map((entry) => _buildWeekTile(
                entry.key,
                entry.value,
                currentWeekStart,
                year,
              )),
        );
      } else {
        widgets.add(yearWidget);
      }
    }

    return widgets;
  }

  Map<DateTime, List<TrackerPath>> _groupPathsByWeek(List<TrackerPath> paths) {
    final grouped = <DateTime, List<TrackerPath>>{};
    for (final path in paths) {
      final start = path.startedAtDateTime;
      final weekStart = _startOfWeek(start);
      grouped.putIfAbsent(weekStart, () => []).add(path);
    }

    final sortedKeys = grouped.keys.toList()
      ..sort((a, b) => b.compareTo(a));
    final sorted = <DateTime, List<TrackerPath>>{};
    for (final key in sortedKeys) {
      final weekPaths = grouped[key] ?? [];
      weekPaths.sort(
        (a, b) => b.startedAtDateTime.compareTo(a.startedAtDateTime),
      );
      sorted[key] = weekPaths;
    }

    return sorted;
  }

  Widget _buildWeekTile(
    DateTime weekStart,
    List<TrackerPath> paths,
    DateTime currentWeekStart,
    int year,
  ) {
    final weekKey = 'week:$year:${weekStart.toIso8601String()}';
    final isCurrentWeek =
        weekStart.year == currentWeekStart.year &&
        weekStart.month == currentWeekStart.month &&
        weekStart.day == currentWeekStart.day;
    final isExpanded =
        _expandedWeekKeys.contains(weekKey) || isCurrentWeek;
    final weekLabel = DateFormat.MMMd().format(weekStart);

    return ExpansionTile(
      key: PageStorageKey<String>(weekKey),
      initiallyExpanded: isExpanded,
      title: Text('${widget.i18n.t('tracker_week_of')} $weekLabel'),
      subtitle: Text('${paths.length} ${widget.i18n.t('tracker_sessions')}'),
      onExpansionChanged: (expanded) {
        setState(() {
          if (expanded) {
            _expandedWeekKeys.add(weekKey);
          } else {
            _expandedWeekKeys.remove(weekKey);
          }
        });
      },
      children: paths.map((path) => _buildPathTile(path, year)).toList(),
    );
  }

  Widget _buildPathTile(TrackerPath path, int year) {
    final pathType = TrackerPathType.fromTags(path.tags);
    final startedAt = DateFormat.yMMMd().add_jm().format(path.startedAtDateTime);
    final isActive = _recordingService.activePathId == path.id;
    final points = isActive ? _recordingService.pointCount : path.totalPoints;
    final distance = isActive
        ? _recordingService.totalDistance
        : path.totalDistanceMeters;
    final duration = _resolvePathDuration(path, isActive: isActive);
    final durationLabel = duration != null ? _formatDurationCompact(duration) : null;
    final theme = Theme.of(context);
    final statStyle = theme.textTheme.bodySmall;
    final isSelected = _selectedPathIds.contains(path.id);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: isSelected ? theme.colorScheme.primaryContainer : null,
      child: ListTile(
        leading: _multiSelectMode
            ? Checkbox(
                value: isSelected,
                onChanged: (_) => _togglePathSelection(path.id, year),
              )
            : Icon(
                pathType?.icon ?? Icons.route,
                color: path.status == TrackerPathStatus.recording
                    ? Colors.red
                    : null,
              ),
        title: Text(path.title ?? path.id),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(startedAt),
            const SizedBox(height: 4),
            Wrap(
              spacing: 12,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (durationLabel != null && durationLabel.isNotEmpty)
                  _buildStatItem(
                    Icons.timer_outlined,
                    durationLabel,
                    statStyle,
                  ),
                _buildStatItem(
                  Icons.emoji_events_outlined,
                  '$points ${widget.i18n.t('tracker_points')}',
                  statStyle,
                ),
                _buildStatItem(
                  Icons.straighten,
                  _formatDistance(distance),
                  statStyle,
                ),
              ],
            ),
          ],
        ),
        trailing: _multiSelectMode
            ? null
            : PopupMenuButton<String>(
                onSelected: (value) => _handlePathMenu(value, path, year),
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'edit',
                    child: Text(widget.i18n.t('tracker_edit_path')),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text(widget.i18n.t('tracker_delete_path')),
                  ),
                ],
              ),
        onTap: _multiSelectMode
            ? () => _togglePathSelection(path.id, year)
            : () => _onPathTapped(path, year),
        onLongPress: !_multiSelectMode
            ? () => _enterMultiSelect(path.id, year)
            : null,
      ),
    );
  }

  void _enterMultiSelect(String pathId, int year) {
    setState(() {
      _multiSelectMode = true;
      _selectedPathIds.clear();
      _selectedPathIds.add(pathId);
      _selectedPathYear = year;
    });
  }

  void _togglePathSelection(String pathId, int year) {
    setState(() {
      if (_selectedPathIds.contains(pathId)) {
        _selectedPathIds.remove(pathId);
        if (_selectedPathIds.isEmpty) {
          _multiSelectMode = false;
          _selectedPathYear = null;
        }
      } else {
        _selectedPathIds.add(pathId);
        _selectedPathYear = year;
      }
    });
  }

  void _exitMultiSelect() {
    setState(() {
      _multiSelectMode = false;
      _selectedPathIds.clear();
      _selectedPathYear = null;
    });
  }

  DateTime _startOfWeek(DateTime date) {
    final normalized = DateTime(date.year, date.month, date.day);
    return normalized.subtract(Duration(days: normalized.weekday - 1));
  }

  /// Unified tab builder for exercises and measurements
  Widget _buildTrackableTab(TrackableKind kind) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final isExercise = kind == TrackableKind.exercise;
    final visibleList = _getVisibleList(kind);
    final typesWithData = isExercise ? _exerciseTypes : _measurementTypes;
    final availableTypes = isExercise
        ? TrackableTypeConfig.exerciseTypes
        : TrackableTypeConfig.measurementTypes;

    // Empty state
    final emptyMessage = isExercise
        ? 'tracker_no_visible_exercises'
        : 'tracker_no_visible_measurements';
    final addButtonLabel = isExercise
        ? 'tracker_add_exercise_to_list'
        : 'tracker_add_measurement_to_list';
    final emptyIcon = isExercise ? Icons.fitness_center : Icons.monitor_weight;

    if (visibleList.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(emptyIcon, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              widget.i18n.t(emptyMessage),
              style: TextStyle(color: Colors.grey[600]),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () => _showAddToListDialog(kind),
              icon: const Icon(Icons.add),
              label: Text(widget.i18n.t(addButtonLabel)),
            ),
          ],
        ),
      );
    }

    final hideLabel = isExercise ? 'tracker_hide_exercise' : 'tracker_hide_measurement';
    final typePrefix = isExercise ? 'tracker_exercise_' : 'tracker_measurement_';

    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: visibleList.length,
      itemBuilder: (context, index) {
        final typeId = visibleList[index];
        final config = availableTypes[typeId];
        if (config == null) return const SizedBox.shrink();

        final hasData = typesWithData.contains(typeId);

        return Card(
          child: ListTile(
            leading: Icon(
              _getTrackableIcon(kind, typeId, config.category),
              color: Colors.white,
            ),
            title: Text(widget.i18n.t('$typePrefix$typeId')),
            subtitle: Text('${_weeklyTotals[typeId] ?? 0} ${widget.i18n.t('tracker_this_week')}'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.add_circle_outline),
                  tooltip: widget.i18n.t('tracker_log_entry'),
                  onPressed: () => _onAddEntry(kind, typeId),
                ),
                PopupMenuButton<String>(
                  onSelected: (action) {
                    if (action == 'remove') {
                      _removeFromVisibleList(kind, typeId);
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'remove',
                      child: Row(
                        children: [
                          const Icon(Icons.visibility_off),
                          const SizedBox(width: 8),
                          Text(widget.i18n.t(hideLabel)),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
            onTap: () => _onTrackableTapped(kind, typeId),
          ),
        );
      },
    );
  }

  /// Unified add-to-list dialog for exercises and measurements
  void _showAddToListDialog(TrackableKind kind) {
    final isExercise = kind == TrackableKind.exercise;
    final visibleList = _getVisibleList(kind);
    final availableTypes = isExercise
        ? TrackableTypeConfig.exerciseTypes
        : TrackableTypeConfig.measurementTypes;

    // Get types not yet in the visible list
    final availableIds = availableTypes.keys
        .where((id) => !visibleList.contains(id))
        .toList();

    final allAddedMessage = isExercise
        ? 'tracker_all_exercises_added'
        : 'tracker_all_measurements_added';
    final dialogTitle = isExercise
        ? 'tracker_add_exercise_to_list'
        : 'tracker_add_measurement_to_list';
    final typePrefix = isExercise ? 'tracker_exercise_' : 'tracker_measurement_';

    if (availableIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.i18n.t(allAddedMessage))),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.i18n.t(dialogTitle)),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: availableIds.length,
            itemBuilder: (context, index) {
              final typeId = availableIds[index];
              final config = availableTypes[typeId]!;

              return ListTile(
                leading: Icon(
                  _getTrackableIcon(kind, typeId, config.category),
                  color: Colors.white,
                ),
                title: Text(widget.i18n.t('$typePrefix$typeId')),
                onTap: () {
                  _addToVisibleList(kind, typeId);
                  Navigator.of(context).pop();
                },
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(widget.i18n.t('cancel')),
          ),
        ],
      ),
    );
  }

  Widget _buildPlansTab() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_activePlans.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.flag, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              widget.i18n.t('tracker_no_plans'),
              style: TextStyle(color: Colors.grey[600]),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: _activePlans.length,
      itemBuilder: (context, index) {
        final plan = _activePlans[index];
        return Card(
          child: ListTile(
            leading: const Icon(Icons.flag),
            title: Text(plan.title),
            subtitle: Text('${plan.goals.length} ${widget.i18n.t('tracker_goals')}'),
            trailing: plan.status == TrackerPlanStatus.active
                ? const Icon(Icons.play_circle, color: Colors.green)
                : null,
            onTap: () => _onPlanTapped(plan),
          ),
        );
      },
    );
  }

  Widget _buildProximityTab() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final hasData = _proximityByYearWeek.isNotEmpty &&
        _proximityByYearWeek.values.any((weeks) =>
            weeks.values.any((tracks) => tracks.isNotEmpty));

    return Column(
      children: [
        // Enable/disable switch and filter
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              // Enable/disable switch
              Row(
                children: [
                  Icon(
                    _proximityTrackingEnabled ? Icons.sensors : Icons.sensors_off,
                    color: _proximityTrackingEnabled ? Colors.green : Colors.grey,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.i18n.t('tracker_proximity_tracking'),
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                  ),
                  Switch(
                    value: _proximityTrackingEnabled,
                    onChanged: _setProximityTrackingEnabled,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Segmented control for filter
              SegmentedButton<ProximityFilter>(
                segments: [
                  ButtonSegment(
                    value: ProximityFilter.all,
                    label: Text(widget.i18n.t('tracker_proximity_all')),
                    icon: const Icon(Icons.select_all),
                  ),
                  ButtonSegment(
                    value: ProximityFilter.devices,
                    label: Text(widget.i18n.t('tracker_proximity_devices')),
                    icon: const Icon(Icons.bluetooth),
                  ),
                  ButtonSegment(
                    value: ProximityFilter.places,
                    label: Text(widget.i18n.t('tracker_proximity_places')),
                    icon: const Icon(Icons.place),
                  ),
                ],
                selected: {_proximityFilter},
                onSelectionChanged: (selected) {
                  setState(() => _proximityFilter = selected.first);
                },
              ),
            ],
          ),
        ),
        // Year/week list
        Expanded(
          child: !hasData
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _proximityFilter == ProximityFilter.places
                            ? Icons.place
                            : _proximityFilter == ProximityFilter.devices
                                ? Icons.bluetooth
                                : Icons.people,
                        size: 64,
                        color: Colors.grey[400],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        widget.i18n.t('tracker_no_proximity'),
                        style: TextStyle(color: Colors.grey[600]),
                      ),
                      if (!_proximityTrackingEnabled) ...[
                        const SizedBox(height: 8),
                        Text(
                          widget.i18n.t('tracker_enable_tracking_hint'),
                          style: TextStyle(color: Colors.grey[500], fontSize: 12),
                        ),
                      ],
                    ],
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(8),
                  children: _buildProximityGroups(),
                ),
        ),
      ],
    );
  }

  List<Widget> _buildProximityGroups() {
    final now = DateTime.now();
    final currentWeek = getWeekNumber(now);
    final singleYear = _proximityYears.length == 1;
    final widgets = <Widget>[];

    for (final year in _proximityYears) {
      final weeksMap = _proximityByYearWeek[year] ?? {};
      if (weeksMap.isEmpty) continue;

      final yearKey = 'prox_year:$year';
      final isCurrentYear = year == now.year;
      final isExpanded = _expandedProximityYearKeys.contains(yearKey) ||
          isCurrentYear ||
          (singleYear && isCurrentYear);

      final weekEntries = weeksMap.entries.toList()
        ..sort((a, b) => b.key.compareTo(a.key));

      final yearWidget = ExpansionTile(
        key: PageStorageKey<String>(yearKey),
        initiallyExpanded: isExpanded,
        title: Text(year.toString()),
        onExpansionChanged: (expanded) {
          setState(() {
            if (expanded) {
              _expandedProximityYearKeys.add(yearKey);
            } else {
              _expandedProximityYearKeys.remove(yearKey);
            }
          });
        },
        children: weekEntries
            .map((entry) => _buildProximityWeekTile(
                  year,
                  entry.key,
                  entry.value,
                  currentWeek,
                ))
            .toList(),
      );

      if (singleYear && isCurrentYear) {
        widgets.addAll(
          weekEntries.map((entry) => _buildProximityWeekTile(
                year,
                entry.key,
                entry.value,
                currentWeek,
              )),
        );
      } else {
        widgets.add(yearWidget);
      }
    }

    return widgets;
  }

  Widget _buildProximityWeekTile(
    int year,
    int week,
    List<ProximityTrack> tracks,
    int currentWeek,
  ) {
    final weekKey = 'prox_week:$year:$week';
    final isCurrentWeek = year == DateTime.now().year && week == currentWeek;
    final isExpanded = _expandedProximityWeekKeys.contains(weekKey) || isCurrentWeek;

    // Filter tracks based on selected filter
    final filteredTracks = tracks.where((track) {
      switch (_proximityFilter) {
        case ProximityFilter.all:
          return true;
        case ProximityFilter.devices:
          return track.type == ProximityTargetType.device;
        case ProximityFilter.places:
          return track.type == ProximityTargetType.place;
      }
    }).toList();

    // Calculate week start date for display
    final weekStartDate = _getWeekStartDate(year, week);
    final weekLabel = DateFormat.MMMd().format(weekStartDate);

    final deviceCount = tracks.where((t) => t.type == ProximityTargetType.device).length;
    final placeCount = tracks.where((t) => t.type == ProximityTargetType.place).length;

    return ExpansionTile(
      key: PageStorageKey<String>(weekKey),
      initiallyExpanded: isExpanded,
      shape: const Border(),
      collapsedShape: const Border(),
      title: Text('${widget.i18n.t('tracker_week_of')} $weekLabel'),
      subtitle: Text('$deviceCount ${widget.i18n.t('tracker_proximity_devices').toLowerCase()}, '
          '$placeCount ${widget.i18n.t('tracker_proximity_places').toLowerCase()}'),
      onExpansionChanged: (expanded) {
        setState(() {
          if (expanded) {
            _expandedProximityWeekKeys.add(weekKey);
          } else {
            _expandedProximityWeekKeys.remove(weekKey);
          }
        });
      },
      children: filteredTracks.isEmpty
          ? [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  widget.i18n.t('tracker_no_proximity'),
                  style: TextStyle(color: Colors.grey[600]),
                ),
              ),
            ]
          : filteredTracks.map((track) => _buildProximityTrackCard(track, year, week)).toList(),
    );
  }

  /// Get the start date of a week given year and week number
  DateTime _getWeekStartDate(int year, int week) {
    // ISO week date calculation
    final jan4 = DateTime(year, 1, 4);
    final daysSinceJan4 = (week - 1) * 7;
    final mondayOfWeek1 = jan4.subtract(Duration(days: jan4.weekday - 1));
    return mondayOfWeek1.add(Duration(days: daysSinceJan4));
  }

  Widget _buildProximityTrackCard(ProximityTrack track, int year, int week) {
    final isDevice = track.type == ProximityTargetType.device;
    final icon = isDevice ? Icons.bluetooth : Icons.place;
    final durationText = _formatDurationHuman(track.weekSummary.totalSeconds);

    final lastSeen = track.weekSummary.lastDetection != null
        ? DateFormat.MMMd().add_jm().format(DateTime.parse(track.weekSummary.lastDetection!).toLocal())
        : null;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        onTap: () => _openProximityDetail(track, year, week),
        leading: Icon(icon, color: isDevice ? Colors.blue : Colors.green),
        title: Text(track.displayName),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$durationText ${widget.i18n.t('tracker_this_week')}'),
            if (lastSeen != null)
              Text(
                '${widget.i18n.t('tracker_last_update')}: $lastSeen',
                style: TextStyle(color: Colors.grey[500], fontSize: 12),
              ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${track.weekSummary.totalEntries}',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: isDevice ? Colors.blue : Colors.green,
                  ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, color: Colors.grey[400]),
          ],
        ),
      ),
    );
  }

  void _openProximityDetail(ProximityTrack track, int year, int week) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => ProximityDetailPage(
          service: _service,
          i18n: widget.i18n,
          track: track,
          year: year,
          week: week,
        ),
      ),
    );
  }

  Widget _buildSharingTab() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Group Shares
          _buildSectionHeader(widget.i18n.t('tracker_group_shares')),
          if (_groupShares.isEmpty)
            _buildEmptySection(widget.i18n.t('tracker_no_group_shares'))
          else
            ..._groupShares.map((share) => Card(
                  child: ListTile(
                    leading: const Icon(Icons.group),
                    title: Text(share.groupName),
                    subtitle: Text(
                      '${share.members.length} ${widget.i18n.t('tracker_members')} - '
                      '${share.active ? widget.i18n.t('tracker_active') : widget.i18n.t('tracker_inactive')}',
                    ),
                    trailing: Switch(
                      value: share.active,
                      onChanged: (value) => _onShareToggle(share, value),
                    ),
                  ),
                )),

          const SizedBox(height: 24),

          // Temporary Shares
          _buildSectionHeader(widget.i18n.t('tracker_temporary_shares')),
          if (_temporaryShares.isEmpty)
            _buildEmptySection(widget.i18n.t('tracker_no_temporary_shares'))
          else
            ..._temporaryShares.map((share) => Card(
                  child: ListTile(
                    leading: Icon(
                      Icons.timer,
                      color: share.hasExpired ? Colors.grey : Colors.orange,
                    ),
                    title: Text(share.reason ?? widget.i18n.t('tracker_temporary_share')),
                    subtitle: Text(
                      share.hasExpired
                          ? widget.i18n.t('tracker_expired')
                          : '${widget.i18n.t('tracker_expires')}: ${_formatDateTime(share.expiresAtDateTime)}',
                    ),
                  ),
                )),

          const SizedBox(height: 24),

          // Received Locations
          _buildSectionHeader(widget.i18n.t('tracker_received_locations')),
          if (_receivedLocations.isEmpty)
            _buildEmptySection(widget.i18n.t('tracker_no_received_locations'))
          else
            ..._receivedLocations.map((location) => Card(
                  child: ListTile(
                    leading: const Icon(Icons.person_pin_circle),
                    title: Text(location.displayName ?? location.callsign),
                    subtitle: Text(
                      '${widget.i18n.t('tracker_last_update')}: ${location.lastUpdate}',
                    ),
                    onTap: () => _onReceivedLocationTapped(location),
                  ),
                )),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }

  Widget _buildEmptySection(String message) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        message,
        style: TextStyle(color: Colors.grey[600]),
      ),
    );
  }

  // ============ Helper Methods ============

  /// Get icon for a trackable type
  IconData _getTrackableIcon(TrackableKind kind, String typeId, TrackableCategory category) {
    if (kind == TrackableKind.measurement) {
      // Measurements have type-specific icons
      switch (typeId) {
        case 'weight':
          return Icons.monitor_weight;
        case 'height':
          return Icons.height;
        case 'blood_pressure':
          return Icons.favorite;
        case 'heart_rate':
          return Icons.monitor_heart;
        case 'blood_glucose':
          return Icons.water_drop;
        case 'body_fat':
          return Icons.percent;
        case 'body_temperature':
          return Icons.thermostat;
        case 'body_water':
          return Icons.water;
        case 'muscle_mass':
          return Icons.fitness_center;
        default:
          return Icons.straighten;
      }
    }
    // Exercises use category-based icons
    switch (category) {
      case TrackableCategory.strength:
        return Icons.fitness_center;
      case TrackableCategory.cardio:
        return Icons.directions_run;
      case TrackableCategory.flexibility:
        return Icons.self_improvement;
      case TrackableCategory.health:
        return Icons.favorite;
    }
  }

  String _formatDistance(double meters) {
    if (meters >= 1000) {
      return '${(meters / 1000).toStringAsFixed(1)} km';
    }
    return '${meters.toInt()} m';
  }

  Widget _buildStatItem(
    IconData icon,
    String label,
    TextStyle? textStyle,
  ) {
    final color = textStyle?.color ?? Colors.grey;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(label, style: textStyle),
      ],
    );
  }

  Duration? _resolvePathDuration(TrackerPath path, {required bool isActive}) {
    if (isActive) {
      return _recordingService.elapsedTime;
    }
    final start = path.startedAtDateTime;
    final end = path.endedAtDateTime ?? DateTime.now();
    return end.difference(start);
  }

  String _formatDurationCompact(Duration duration) {
    final totalMinutes = duration.inMinutes;
    if (totalMinutes <= 0) return '';
    if (totalMinutes < 60) {
      return '${totalMinutes}m';
    }
    final hours = duration.inHours;
    if (hours < 24) {
      final minutes = totalMinutes.remainder(60);
      if (minutes == 0) {
        return '${hours}h';
      }
      return '${hours}h ${minutes}m';
    }
    return '${duration.inHours}h';
  }

  /// Format seconds into a human-readable duration string
  /// Examples: "10 minutes", "1 hour and 30 minutes", "2 days and 5 hours"
  String _formatDurationHuman(int totalSeconds) {
    if (totalSeconds < 60) {
      return totalSeconds == 1 ? '1 second' : '$totalSeconds seconds';
    }

    final totalMinutes = totalSeconds ~/ 60;
    if (totalMinutes < 60) {
      return totalMinutes == 1 ? '1 minute' : '$totalMinutes minutes';
    }

    final hours = totalMinutes ~/ 60;
    final minutes = totalMinutes % 60;
    if (hours < 24) {
      final hourText = hours == 1 ? '1 hour' : '$hours hours';
      if (minutes == 0) {
        return hourText;
      }
      final minuteText = minutes == 1 ? '1 minute' : '$minutes minutes';
      return '$hourText and $minuteText';
    }

    final days = hours ~/ 24;
    final remainingHours = hours % 24;
    if (days < 30) {
      final dayText = days == 1 ? '1 day' : '$days days';
      if (remainingHours == 0) {
        return dayText;
      }
      final hourText = remainingHours == 1 ? '1 hour' : '$remainingHours hours';
      return '$dayText and $hourText';
    }

    final months = days ~/ 30;
    final remainingDays = days % 30;
    final monthText = months == 1 ? '1 month' : '$months months';
    if (remainingDays == 0) {
      return monthText;
    }
    final dayText = remainingDays == 1 ? '1 day' : '$remainingDays days';
    return '$monthText and $dayText';
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  String _formatDateTime(DateTime dateTime) {
    return '${_formatDate(dateTime)} ${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')}';
  }

  // ============ Action Handlers ============

  Future<void> _showMergeDialog() async {
    final titleController = TextEditingController(text: 'Merged Path');
    bool deleteOriginals = false;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(widget.i18n.t('tracker_merge_paths')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${widget.i18n.t('tracker_merge_count')}: ${_selectedPathIds.length}'),
              const SizedBox(height: 16),
              TextField(
                controller: titleController,
                decoration: InputDecoration(
                  labelText: widget.i18n.t('tracker_path_title'),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              CheckboxListTile(
                title: Text(widget.i18n.t('tracker_delete_originals')),
                value: deleteOriginals,
                onChanged: (v) => setDialogState(() => deleteOriginals = v ?? false),
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(widget.i18n.t('cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(widget.i18n.t('tracker_merge')),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true) {
      final merged = await _service.mergePaths(
        _selectedPathIds.toList(),
        year: _selectedPathYear,
        deleteOriginals: deleteOriginals,
        title: titleController.text.trim().isNotEmpty
            ? titleController.text.trim()
            : 'Merged Path',
      );
      titleController.dispose();

      _exitMultiSelect();
      _loadCurrentTab();

      if (merged != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(widget.i18n.t('tracker_paths_merged'))),
        );
      }
    } else {
      titleController.dispose();
    }
  }

  Future<void> _onAddPath() async {
    // Don't allow starting a new recording if one is already active
    if (_recordingService.hasActiveRecording) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.i18n.t('tracker_recording_in_progress'))),
      );
      return;
    }

    final path = await StartPathDialog.show(
      context,
      recordingService: _recordingService,
      i18n: widget.i18n,
    );

    if (path != null) {
      // Recording started successfully
      _loadCurrentTab();
    }
  }

  /// Unified add entry handler for exercises and measurements
  Future<void> _onAddEntry(TrackableKind kind, String typeId) async {
    final result = kind == TrackableKind.exercise
        ? await AddTrackableDialog.showExercise(
            context,
            service: _service,
            i18n: widget.i18n,
            preselectedTypeId: typeId,
            year: _selectedYear,
          )
        : await AddTrackableDialog.showMeasurement(
            context,
            service: _service,
            i18n: widget.i18n,
            preselectedTypeId: typeId,
            year: _selectedYear,
          );

    if (result == true) {
      _loadCurrentTab();
    }
  }

  /// Unified tap handler for exercises and measurements
  void _onTrackableTapped(TrackableKind kind, String typeId) {
    if (kind == TrackableKind.exercise) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => ExerciseDetailPage(
            service: _service,
            i18n: widget.i18n,
            exerciseId: typeId,
            year: _selectedYear,
          ),
        ),
      );
    } else {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => MeasurementDetailPage(
            service: _service,
            i18n: widget.i18n,
            typeId: typeId,
            year: _selectedYear,
          ),
        ),
      );
    }
  }

  Future<void> _onAddPlan() async {
    final result = await CreatePlanDialog.show(
      context,
      service: _service,
      i18n: widget.i18n,
    );

    if (result == true) {
      _loadCurrentTab();
    }
  }

  void _onAddShare() {
    // TODO: Show dialog to create new share
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(widget.i18n.t('tracker_add_share_coming_soon'))),
    );
  }

  void _onPathTapped(TrackerPath path, int year) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => PathDetailPage(
          service: _service,
          i18n: widget.i18n,
          path: path,
          year: year,
          recordingService: _recordingService,
        ),
      ),
    );
  }

  Future<void> _handlePathMenu(
    String action,
    TrackerPath path,
    int year,
  ) async {
    switch (action) {
      case 'edit':
        final result = await EditPathDialog.show(
          context,
          path: path,
          i18n: widget.i18n,
        );
        if (result == null) return;
        final updated = path
            .copyWith(
              title: result.title,
              description: result.description,
            )
            .withUserTags(result.tags);
        await _service.updatePath(updated, year: year);
        _loadCurrentTab();
        return;
      case 'delete':
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(widget.i18n.t('tracker_delete_path')),
            content: Text(widget.i18n.t('tracker_delete_path_confirm')),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(widget.i18n.t('cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(widget.i18n.t('tracker_delete_path')),
              ),
            ],
          ),
        );
        if (confirmed == true) {
          await _service.deletePath(path.id, year: year);
          _loadCurrentTab();
        }
        return;
    }
  }

  Future<void> _openActivePath() async {
    final state = _recordingService.recordingState;
    if (state == null) return;
    final path = await _service.getPath(
      state.activePathId,
      year: state.activePathYear,
    );
    if (path == null || !mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => PathDetailPage(
          service: _service,
          i18n: widget.i18n,
          path: path,
          year: state.activePathYear,
          recordingService: _recordingService,
        ),
      ),
    );
  }

  void _onPlanTapped(TrackerPlan plan) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => PlanDetailPage(
          service: _service,
          i18n: widget.i18n,
          planId: plan.id,
        ),
      ),
    );
  }

  void _onReceivedLocationTapped(ReceivedLocation location) {
    // TODO: Navigate to location detail or show on map
  }

  void _onShareToggle(GroupShare share, bool active) {
    // TODO: Toggle share active state
  }
}
