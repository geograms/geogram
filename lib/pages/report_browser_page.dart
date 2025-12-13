/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../models/report.dart';
import '../services/report_service.dart';
import '../services/profile_service.dart';
import '../services/i18n_service.dart';
import '../services/alert_sharing_service.dart';
import '../services/station_alert_service.dart';
import '../services/user_location_service.dart';
import '../services/log_service.dart';
import '../services/storage_config.dart';
import 'report_detail_page.dart';
import 'report_settings_page.dart';

/// Report browser page with list and map views
class ReportBrowserPage extends StatefulWidget {
  final String? collectionPath;
  final String? collectionTitle;

  /// Remote device URL for viewing alerts from another device (e.g., "http://localhost:5577")
  final String? remoteDeviceUrl;

  /// Remote device callsign (for display)
  final String? remoteDeviceCallsign;

  /// Remote device name (for display)
  final String? remoteDeviceName;

  const ReportBrowserPage({
    super.key,
    this.collectionPath,
    this.collectionTitle,
    this.remoteDeviceUrl,
    this.remoteDeviceCallsign,
    this.remoteDeviceName,
  });

  /// Check if viewing remote device alerts
  bool get isRemoteDevice => remoteDeviceUrl != null;

  @override
  State<ReportBrowserPage> createState() => _ReportBrowserPageState();
}

class _ReportBrowserPageState extends State<ReportBrowserPage> {
  final ReportService _reportService = ReportService();
  final ProfileService _profileService = ProfileService();
  final StationAlertService _stationAlertService = StationAlertService();
  final UserLocationService _userLocationService = UserLocationService();
  final I18nService _i18n = I18nService();
  final TextEditingController _searchController = TextEditingController();

  List<Report> _allReports = [];
  List<Report> _filteredReports = [];
  List<Report> _stationAlerts = []; // Alerts fetched from station
  List<Report> _filteredStationAlerts = []; // Station alerts filtered by distance
  ReportSeverity? _filterSeverity;
  ReportStatus? _filterStatus;
  bool _isLoading = true;
  bool _isUploading = false;
  bool _isLoadingRelayAlerts = false;
  int _sortMode = 0; // 0: date desc, 1: severity, 2: distance
  double _radiusKm = 50.0; // Default 50km radius
  String _lastFetchTime = 'Never';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_filterReports);
    _userLocationService.addListener(_onLocationChanged);
    _initialize();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _userLocationService.removeListener(_onLocationChanged);
    super.dispose();
  }

  /// Called when user location changes
  void _onLocationChanged() {
    // Re-filter all alerts when location updates
    _filterReports();
    _filterRelayAlertsByDistance();
  }

  Future<void> _initialize() async {
    if (widget.isRemoteDevice) {
      // Remote mode: load alerts from remote device API
      await _loadRemoteAlerts();
    } else {
      // Local mode: load from local collection
      await _reportService.initializeCollection(widget.collectionPath ?? '');
      await _loadReports();

      // Initialize user location service for automatic updates
      await _userLocationService.initialize();

      // Load cached station alerts from disk (instant display)
      await _stationAlertService.loadCachedAlerts();
      _stationAlerts = _stationAlertService.cachedAlerts;
      _filterRelayAlertsByDistance();
      _lastFetchTime = _stationAlertService.getTimeSinceLastFetch();

      // Update UI with cached alerts immediately
      if (mounted) setState(() {});

      // Start background polling and fetch fresh data from station
      _stationAlertService.startPolling();
      _loadRelayAlerts();
    }
  }

  /// Load alerts from remote device via API
  Future<void> _loadRemoteAlerts() async {
    if (!widget.isRemoteDevice) return;

    setState(() => _isLoading = true);

    try {
      final url = '${widget.remoteDeviceUrl}/api/alerts';
      LogService().log('Fetching remote alerts from: $url');

      final response = await http.get(
        Uri.parse(url),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final alertsJson = data['alerts'] as List<dynamic>? ?? [];

        _allReports = alertsJson
            .map((json) => Report.fromApiJson(json as Map<String, dynamic>))
            .toList();

        LogService().log('Loaded ${_allReports.length} alerts from remote device');
      } else {
        LogService().log('Failed to load remote alerts: ${response.statusCode}');
        _allReports = [];
      }
    } catch (e) {
      LogService().log('Error loading remote alerts: $e');
      _allReports = [];
    }

    if (mounted) {
      setState(() {
        _filteredReports = _allReports;
        _isLoading = false;
      });
      _filterReports();
    }
  }

  /// Get full alert details from remote device API
  Future<Report?> _getRemoteAlertDetails(String alertId) async {
    if (!widget.isRemoteDevice) return null;

    try {
      final url = '${widget.remoteDeviceUrl}/api/alerts/$alertId';
      LogService().log('Fetching remote alert details from: $url');

      final response = await http.get(
        Uri.parse(url),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return Report.fromApiJson(data);
      }
    } catch (e) {
      LogService().log('Error fetching remote alert details: $e');
    }
    return null;
  }

  Future<void> _loadReports() async {
    setState(() => _isLoading = true);

    _allReports = await _reportService.loadReports();

    setState(() {
      _filteredReports = _allReports;
      _isLoading = false;
    });

    _filterReports();
  }

  void _filterReports() {
    final query = _searchController.text.toLowerCase();
    final userLocation = _userLocationService.currentLocation;

    setState(() {
      _filteredReports = _allReports.where((report) {
        // Filter by severity
        if (_filterSeverity != null && report.severity != _filterSeverity) {
          return false;
        }

        // Filter by status
        if (_filterStatus != null && report.status != _filterStatus) {
          return false;
        }

        // Filter by distance (if location is available and radius is not unlimited)
        if (userLocation != null && userLocation.isValid && _radiusKm < 500) {
          final distance = _calculateDistance(
            userLocation.latitude,
            userLocation.longitude,
            report.latitude,
            report.longitude,
          );
          if (distance > _radiusKm) {
            return false;
          }
        }

        // Filter by search query
        if (query.isEmpty) return true;

        final title = report.getTitle('EN').toLowerCase();
        final description = report.getDescription('EN').toLowerCase();
        final type = report.type.toLowerCase();
        return title.contains(query) || description.contains(query) || type.contains(query);
      }).toList();

      // Sort reports
      switch (_sortMode) {
        case 0: // Date descending
          _filteredReports.sort((a, b) => b.dateTime.compareTo(a.dateTime));
          break;
        case 1: // Severity
          _filteredReports.sort((a, b) {
            final severityOrder = {
              ReportSeverity.emergency: 0,
              ReportSeverity.urgent: 1,
              ReportSeverity.attention: 2,
              ReportSeverity.info: 3,
            };
            return (severityOrder[a.severity] ?? 3).compareTo(severityOrder[b.severity] ?? 3);
          });
          break;
      }
    });
  }

  /// Filter station alerts by distance from user's current location
  void _filterRelayAlertsByDistance() {
    if (!mounted) return;

    final userLocation = _userLocationService.currentLocation;
    final profile = _profileService.getProfile();
    final currentUserCallsign = profile.callsign;

    setState(() {
      if (userLocation == null || !userLocation.isValid || _radiusKm >= 500) {
        // No location or unlimited radius - show all alerts (except user's own)
        _filteredStationAlerts = _stationAlerts.where((alert) {
          // Filter out alerts created by the current user
          return alert.author != currentUserCallsign;
        }).toList();
      } else {
        // Filter alerts within the radius (except user's own)
        _filteredStationAlerts = _stationAlerts.where((alert) {
          // Filter out alerts created by the current user
          if (alert.author == currentUserCallsign) {
            return false;
          }
          final distance = _calculateDistance(
            userLocation.latitude,
            userLocation.longitude,
            alert.latitude,
            alert.longitude,
          );
          return distance <= _radiusKm;
        }).toList();
      }

      // Sort filtered station alerts by date (newest first)
      _filteredStationAlerts.sort((a, b) => b.dateTime.compareTo(a.dateTime));
    });
  }

  /// Calculate distance between two coordinates in km (Haversine formula)
  double _calculateDistance(double lat1, double lon1, double lat2, double lon2) {
    const earthRadius = 6371.0; // Earth radius in kilometers
    final dLat = _degreesToRadians(lat2 - lat1);
    final dLon = _degreesToRadians(lon2 - lon1);

    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_degreesToRadians(lat1)) *
            cos(_degreesToRadians(lat2)) *
            sin(dLon / 2) *
            sin(dLon / 2);

    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthRadius * c;
  }

  double _degreesToRadians(double degrees) {
    return degrees * pi / 180;
  }

  String _getDisplayTitle() {
    // For remote mode, show device name
    if (widget.isRemoteDevice) {
      final deviceName = widget.remoteDeviceName ?? widget.remoteDeviceCallsign ?? '';
      return '${_i18n.t('collection_type_alerts')} - $deviceName';
    }

    // Translate known fixed type names
    final title = widget.collectionTitle ?? '';
    if (title.toLowerCase() == 'alerts') {
      return _i18n.t('collection_type_alerts');
    }
    return title;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(_getDisplayTitle()),
        actions: [
          // Refresh button for remote mode
          if (widget.isRemoteDevice)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _loadRemoteAlerts,
              tooltip: _i18n.t('refresh'),
            ),
          // Upload all unsent alerts (local mode only)
          if (!widget.isRemoteDevice && _getUnsentAlertCount() > 0)
            _isUploading
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    icon: Badge(
                      label: Text('${_getUnsentAlertCount()}'),
                      child: const Icon(Icons.cloud_upload),
                    ),
                    tooltip: _i18n.t('upload_unsent_alerts'),
                    onPressed: _uploadUnsentAlerts,
                  ),
          // Filter by severity
          PopupMenuButton<ReportSeverity?>(
            icon: Icon(_filterSeverity == null ? Icons.filter_alt_outlined : Icons.filter_alt),
            tooltip: _i18n.t('filter_by_severity'),
            onSelected: (severity) {
              setState(() {
                _filterSeverity = severity;
                _filterReports();
              });
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: null,
                child: Text(_i18n.t('all_severities')),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: ReportSeverity.emergency,
                child: Row(
                  children: [
                    _buildSeverityBadge(ReportSeverity.emergency),
                    const SizedBox(width: 8),
                    Text(_i18n.t('emergency')),
                  ],
                ),
              ),
              PopupMenuItem(
                value: ReportSeverity.urgent,
                child: Row(
                  children: [
                    _buildSeverityBadge(ReportSeverity.urgent),
                    const SizedBox(width: 8),
                    Text(_i18n.t('urgent')),
                  ],
                ),
              ),
              PopupMenuItem(
                value: ReportSeverity.attention,
                child: Row(
                  children: [
                    _buildSeverityBadge(ReportSeverity.attention),
                    const SizedBox(width: 8),
                    Text(_i18n.t('attention')),
                  ],
                ),
              ),
              PopupMenuItem(
                value: ReportSeverity.info,
                child: Row(
                  children: [
                    _buildSeverityBadge(ReportSeverity.info),
                    const SizedBox(width: 8),
                    Text(_i18n.t('info')),
                  ],
                ),
              ),
            ],
          ),
          // Filter by status
          PopupMenuButton<ReportStatus?>(
            icon: Icon(_filterStatus == null ? Icons.swap_vert : Icons.check_circle),
            tooltip: _i18n.t('filter_by_status'),
            onSelected: (status) {
              setState(() {
                _filterStatus = status;
                _filterReports();
              });
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: null,
                child: Text(_i18n.t('all_statuses')),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: ReportStatus.open,
                child: Text(_i18n.t('open')),
              ),
              PopupMenuItem(
                value: ReportStatus.inProgress,
                child: Text(_i18n.t('in_progress')),
              ),
              PopupMenuItem(
                value: ReportStatus.resolved,
                child: Text(_i18n.t('resolved')),
              ),
              PopupMenuItem(
                value: ReportStatus.closed,
                child: Text(_i18n.t('closed')),
              ),
            ],
          ),
          // Sort
          PopupMenuButton<int>(
            icon: const Icon(Icons.sort),
            tooltip: _i18n.t('sort_by'),
            onSelected: (mode) {
              setState(() {
                _sortMode = mode;
                _filterReports();
              });
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 0,
                child: Row(
                  children: [
                    if (_sortMode == 0) const Icon(Icons.check, size: 16),
                    if (_sortMode == 0) const SizedBox(width: 8),
                    Text(_i18n.t('date_newest')),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 1,
                child: Row(
                  children: [
                    if (_sortMode == 1) const Icon(Icons.check, size: 16),
                    if (_sortMode == 1) const SizedBox(width: 8),
                    Text(_i18n.t('severity')),
                  ],
                ),
              ),
            ],
          ),
          // Settings (local mode only)
          if (!widget.isRemoteDevice)
            IconButton(
              icon: const Icon(Icons.settings),
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => ReportSettingsPage(
                      collectionPath: widget.collectionPath ?? '',
                    ),
                  ),
                );
                _loadReports();
              },
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Radius slider - compact for mobile (hide in remote mode)
                if (!widget.isRemoteDevice) _buildRadiusSlider(theme),

                // Search bar - compact
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: _i18n.t('search_alerts'),
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixIcon: _searchController.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, size: 20),
                              onPressed: () {
                                _searchController.clear();
                              },
                            )
                          : null,
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      isDense: true,
                    ),
                  ),
                ),

                // Active filters display
                if (_filterSeverity != null || _filterStatus != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: Wrap(
                      spacing: 8,
                      children: [
                        if (_filterSeverity != null)
                          Chip(
                            label: Text(_filterSeverity!.name, style: const TextStyle(fontSize: 12)),
                            onDeleted: () {
                              setState(() {
                                _filterSeverity = null;
                                _filterReports();
                              });
                            },
                            visualDensity: VisualDensity.compact,
                          ),
                        if (_filterStatus != null)
                          Chip(
                            label: Text(_filterStatus!.name, style: const TextStyle(fontSize: 12)),
                            onDeleted: () {
                              setState(() {
                                _filterStatus = null;
                                _filterReports();
                              });
                            },
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
                  ),

                // Alerts list with sections
                Expanded(
                  child: _buildAlertsList(theme),
                ),
              ],
            ),
      floatingActionButton: widget.isRemoteDevice
          ? null
          : FloatingActionButton.extended(
              onPressed: _createReport,
              icon: const Icon(Icons.add),
              label: Text(_i18n.t('new_alert')),
            ),
    );
  }

  /// Build the radius slider widget
  Widget _buildRadiusSlider(ThemeData theme) {
    // Format radius display
    String radiusText;
    if (_radiusKm >= 500) {
      radiusText = _i18n.t('radius_unlimited');
    } else if (_radiusKm >= 100) {
      radiusText = '${_radiusKm.round()} km';
    } else if (_radiusKm >= 10) {
      radiusText = '${_radiusKm.round()} km';
    } else {
      radiusText = '${_radiusKm.toStringAsFixed(1)} km';
    }

    // Get location status for indicator
    final userLocation = _userLocationService.currentLocation;
    final hasLocation = userLocation?.isValid ?? false;
    final isUpdating = _userLocationService.isUpdating;

    // Location source icon
    IconData locationIcon;
    String locationTooltip;
    if (isUpdating) {
      locationIcon = Icons.my_location;
      locationTooltip = _i18n.t('detecting_location');
    } else if (!hasLocation) {
      locationIcon = Icons.location_off;
      locationTooltip = _i18n.t('location_unknown');
    } else {
      switch (userLocation!.source) {
        case 'gps':
          locationIcon = Icons.gps_fixed;
          locationTooltip = _i18n.t('location_from_gps');
          break;
        case 'ip':
          locationIcon = Icons.public;
          locationTooltip = _i18n.t('location_from_ip');
          break;
        case 'browser':
          locationIcon = Icons.language;
          locationTooltip = _i18n.t('location_from_browser');
          break;
        default:
          locationIcon = Icons.location_on;
          locationTooltip = userLocation.locationName ?? _i18n.t('location_detected');
      }
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.5),
        border: Border(
          bottom: BorderSide(color: theme.dividerColor, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          // Location indicator with refresh capability
          GestureDetector(
            onTap: isUpdating ? null : () => _userLocationService.refresh(),
            child: Tooltip(
              message: locationTooltip,
              child: isUpdating
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: theme.colorScheme.primary,
                      ),
                    )
                  : Icon(
                      locationIcon,
                      size: 18,
                      color: hasLocation
                          ? theme.colorScheme.primary
                          : theme.colorScheme.error,
                    ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _i18n.t('radius'),
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
              ),
              child: Slider(
                value: _radiusKm,
                min: 1,
                max: 500,
                divisions: 49, // 1, 10, 20, ..., 500
                onChanged: (value) {
                  setState(() {
                    // Snap to nice values
                    if (value <= 10) {
                      _radiusKm = value.roundToDouble();
                    } else if (value <= 50) {
                      _radiusKm = (value / 5).round() * 5.0;
                    } else if (value <= 100) {
                      _radiusKm = (value / 10).round() * 10.0;
                    } else {
                      _radiusKm = (value / 25).round() * 25.0;
                    }
                  });
                },
                onChangeEnd: (value) {
                  // Filter station alerts by the new radius
                  _filterRelayAlertsByDistance();
                  _filterReports();
                },
              ),
            ),
          ),
          SizedBox(
            width: 70,
            child: Text(
              radiusText,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
              ),
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }

  /// Build the alerts list with sections
  Widget _buildAlertsList(ThemeData theme) {
    // Separate my alerts and station alerts (filtered by distance)
    final myAlerts = _filteredReports;
    final stationAlerts = _filteredStationAlerts;

    if (myAlerts.isEmpty && stationAlerts.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.report_outlined, size: 64, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text(
              _allReports.isEmpty ? _i18n.t('no_alerts_yet') : _i18n.t('no_matching_alerts'),
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              _allReports.isEmpty
                  ? _i18n.t('create_first_alert')
                  : _i18n.t('try_adjusting_filters'),
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 80), // Space for FAB
      children: [
        // My Alerts section
        if (myAlerts.isNotEmpty) ...[
          _buildSectionHeader(
            theme,
            icon: Icons.person,
            title: _i18n.t('my_alerts'),
            count: myAlerts.length,
          ),
          ...myAlerts.map((report) => _buildReportCard(report, theme, isMyAlert: true)),
        ],

        // Station Alerts section
        _buildSectionHeader(
          theme,
          icon: Icons.cloud,
          title: _i18n.t('station_alerts'),
          count: stationAlerts.length,
          isLoading: _isLoadingRelayAlerts,
          onRefresh: _loadRelayAlerts,
          subtitle: _lastFetchTime,
        ),
        if (stationAlerts.isNotEmpty)
          ...stationAlerts.map((report) => _buildReportCard(report, theme, isMyAlert: false))
        else if (!_isLoadingRelayAlerts)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: Column(
                children: [
                  Icon(Icons.cloud_off, size: 32, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(height: 8),
                  Text(
                    _i18n.t('no_station_alerts'),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// Build section header
  Widget _buildSectionHeader(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required int count,
    bool isLoading = false,
    VoidCallback? onRefresh,
    String? subtitle,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
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
              if (subtitle != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 10,
                      color: theme.colorScheme.onSurfaceVariant,
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

  /// Load alerts from station
  Future<void> _loadRelayAlerts() async {
    if (_isLoadingRelayAlerts) return;

    setState(() => _isLoadingRelayAlerts = true);

    try {
      // Get user's current location for server-side filtering
      final userLocation = _userLocationService.currentLocation;
      double? lat;
      double? lon;

      if (userLocation != null && userLocation.isValid) {
        lat = userLocation.latitude;
        lon = userLocation.longitude;
      } else {
        // Fall back to profile location
        final profile = _profileService.getProfile();
        lat = profile.latitude != 0 ? profile.latitude : null;
        lon = profile.longitude != 0 ? profile.longitude : null;
      }

      // Fetch from station - get all alerts, we'll filter client-side
      // Server-side filtering is optional but can reduce bandwidth
      final result = await _stationAlertService.fetchAlerts(
        lat: lat,
        lon: lon,
        radiusKm: null, // Get all alerts, filter client-side for responsiveness
      );

      if (mounted) {
        setState(() {
          _stationAlerts = result.alerts;
          _lastFetchTime = _stationAlertService.getTimeSinceLastFetch();
        });
        // Apply client-side distance filtering
        _filterRelayAlertsByDistance();
      }
    } catch (e) {
      LogService().log('Error loading station alerts: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoadingRelayAlerts = false);
      }
    }
  }

  Widget _buildReportCard(Report report, ThemeData theme, {bool isMyAlert = true}) {
    // Calculate distance from user's location
    final userLocation = _userLocationService.currentLocation;
    double? distanceKm;
    if (userLocation != null && userLocation.isValid) {
      distanceKm = _calculateDistance(
        userLocation.latitude,
        userLocation.longitude,
        report.latitude,
        report.longitude,
      );
    }

    // Format distance string
    String? distanceText;
    if (distanceKm != null) {
      if (distanceKm < 1) {
        distanceText = '${(distanceKm * 1000).round()} m';
      } else if (distanceKm < 10) {
        distanceText = '${distanceKm.toStringAsFixed(1)} km';
      } else {
        distanceText = '${distanceKm.round()} km';
      }
    }

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: InkWell(
        onTap: () => _openReport(report),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // First row: badges and date
              Row(
                children: [
                  _buildSeverityBadge(report.severity),
                  const SizedBox(width: 6),
                  _buildStatusBadge(report.status),
                  if (isMyAlert) ...[
                    const SizedBox(width: 6),
                    _buildRelayStatusBadge(report),
                  ],
                  const Spacer(),
                  Text(
                    _formatDate(report.dateTime),
                    style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              // Title
              Text(
                report.getTitle('EN'),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              // Type tag
              Text(
                report.type,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontSize: 11,
                ),
              ),
              const SizedBox(height: 4),
              // Description (shorter for mobile)
              Text(
                report.getDescription('EN'),
                style: theme.textTheme.bodySmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              // Location and stats row
              Row(
                children: [
                  Icon(Icons.location_on, size: 14, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      report.address ?? '${report.latitude.toStringAsFixed(3)}, ${report.longitude.toStringAsFixed(3)}',
                      style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // Show distance from user
                  if (distanceText != null) ...[
                    const SizedBox(width: 6),
                    Icon(Icons.straighten, size: 14, color: theme.colorScheme.primary),
                    const SizedBox(width: 2),
                    Text(
                      distanceText,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                  if (report.verificationCount > 0) ...[
                    const SizedBox(width: 8),
                    Icon(Icons.verified, size: 14, color: Colors.green),
                    const SizedBox(width: 2),
                    Text(
                      '${report.verificationCount}',
                      style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                    ),
                  ],
                  if (report.subscriberCount > 0) ...[
                    const SizedBox(width: 8),
                    Icon(Icons.people, size: 14, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 2),
                    Text(
                      '${report.subscriberCount}',
                      style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                    ),
                  ],
                  if (report.pointCount > 0) ...[
                    const SizedBox(width: 8),
                    Icon(Icons.star, size: 14, color: Colors.amber),
                    const SizedBox(width: 2),
                    Text(
                      '${report.pointCount}',
                      style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                    ),
                  ],
                  // Show author for station alerts
                  if (!isMyAlert && report.author.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Icon(Icons.person, size: 14, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 2),
                    Text(
                      report.author,
                      style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSeverityBadge(ReportSeverity severity) {
    Color color;
    IconData icon;
    String labelKey;

    switch (severity) {
      case ReportSeverity.emergency:
        color = Colors.red;
        icon = Icons.emergency;
        labelKey = 'emergency';
        break;
      case ReportSeverity.urgent:
        color = Colors.orange;
        icon = Icons.warning;
        labelKey = 'urgent';
        break;
      case ReportSeverity.attention:
        color = Colors.yellow.shade700;
        icon = Icons.report_problem;
        labelKey = 'attention';
        break;
      case ReportSeverity.info:
        color = Colors.blue;
        icon = Icons.info;
        labelKey = 'info';
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.2),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 4),
          Text(
            _i18n.t(labelKey),
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBadge(ReportStatus status) {
    Color color;
    String labelKey;

    switch (status) {
      case ReportStatus.open:
        color = Colors.grey;
        labelKey = 'open';
        break;
      case ReportStatus.inProgress:
        color = Colors.blue;
        labelKey = 'in_progress';
        break;
      case ReportStatus.resolved:
        color = Colors.green;
        labelKey = 'resolved';
        break;
      case ReportStatus.closed:
        color = Colors.grey.shade700;
        labelKey = 'closed';
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.2),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        _i18n.t(labelKey),
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inDays == 0) {
      if (diff.inHours == 0) {
        if (diff.inMinutes == 0) {
          return _i18n.t('just_now');
        }
        return _i18n.t('minutes_ago').replaceAll('{0}', '${diff.inMinutes}');
      }
      return _i18n.t('hours_ago').replaceAll('{0}', '${diff.inHours}');
    } else if (diff.inDays == 1) {
      return _i18n.t('yesterday');
    } else if (diff.inDays < 7) {
      return _i18n.t('days_ago').replaceAll('{0}', '${diff.inDays}');
    } else {
      return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    }
  }

  void _openReport(Report report) {
    // Determine collection path based on whether it's a station alert or local
    String collectionPath;
    if (report.metadata['from_station'] == 'true') {
      // Station alerts: construct path from devices directory
      final storageConfig = StorageConfig();
      final callsign = report.metadata['station_callsign'] ?? 'unknown';
      collectionPath = '${storageConfig.devicesDir}/$callsign/alerts';
    } else {
      // Local alerts: use widget's collection path
      collectionPath = widget.collectionPath ?? '';
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ReportDetailPage(
          collectionPath: collectionPath,
          report: report,
        ),
      ),
    ).then((_) => _loadReports());
  }

  void _createReport() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ReportDetailPage(
          collectionPath: widget.collectionPath ?? '',
        ),
      ),
    ).then((_) => _loadReports());
  }

  /// Check if a report has been successfully sent to at least one station
  bool _isReportSentToRelay(Report report) {
    return report.stationShares.any((share) => share.status == StationShareStatusType.confirmed);
  }

  /// Get count of alerts that have not been sent to any station
  int _getUnsentAlertCount() {
    return _allReports.where((report) => !_isReportSentToRelay(report)).length;
  }

  /// Build station status badge for a report
  Widget _buildRelayStatusBadge(Report report) {
    final isSent = _isReportSentToRelay(report);
    final confirmedCount = report.stationShares.where((s) => s.status == StationShareStatusType.confirmed).length;
    final failedCount = report.stationShares.where((s) => s.status == StationShareStatusType.failed).length;

    if (isSent) {
      return Tooltip(
        message: _i18n.t('sent_to_stations').replaceAll('{0}', '$confirmedCount'),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.green.withOpacity(0.2),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_done, size: 14, color: Colors.green),
              if (confirmedCount > 1) ...[
                const SizedBox(width: 2),
                Text(
                  '$confirmedCount',
                  style: const TextStyle(
                    color: Colors.green,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    } else if (failedCount > 0) {
      return Tooltip(
        message: _i18n.t('station_send_failed'),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.orange.withOpacity(0.2),
            borderRadius: BorderRadius.circular(4),
          ),
          child: const Icon(Icons.cloud_off, size: 14, color: Colors.orange),
        ),
      );
    } else {
      return Tooltip(
        message: _i18n.t('not_sent_to_station'),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.grey.withOpacity(0.2),
            borderRadius: BorderRadius.circular(4),
          ),
          child: const Icon(Icons.cloud_upload_outlined, size: 14, color: Colors.grey),
        ),
      );
    }
  }

  /// Upload all unsent alerts to stations
  Future<void> _uploadUnsentAlerts() async {
    final unsentReports = _allReports.where((report) => !_isReportSentToRelay(report)).toList();
    if (unsentReports.isEmpty) return;

    setState(() => _isUploading = true);

    final alertService = AlertSharingService();
    int successCount = 0;
    int failCount = 0;

    for (final report in unsentReports) {
      try {
        LogService().log('Uploading alert: ${report.folderName}');
        final result = await alertService.shareAlert(report);

        if (result.anySuccess) {
          successCount++;
          // Update report with station status
          var updatedReport = report;
          for (final sendResult in result.results) {
            updatedReport = alertService.updateStationShareStatus(
              updatedReport,
              sendResult.stationUrl,
              sendResult.success
                  ? StationShareStatusType.confirmed
                  : StationShareStatusType.failed,
              nostrEventId: result.eventId,
            );
          }
          await _reportService.saveReport(updatedReport, notifyRelays: false);
        } else {
          failCount++;
        }
      } catch (e) {
        LogService().log('Error uploading alert ${report.folderName}: $e');
        failCount++;
      }
    }

    // Reload reports to show updated status
    await _loadReports();

    setState(() => _isUploading = false);

    // Show result snackbar
    if (mounted) {
      final message = successCount > 0
          ? _i18n.t('alerts_uploaded').replaceAll('{0}', '$successCount')
          : _i18n.t('upload_failed');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message + (failCount > 0 ? ' (${_i18n.t('failed')}: $failCount)' : '')),
          backgroundColor: successCount > 0 ? Colors.green : Colors.red,
        ),
      );
    }
  }
}
