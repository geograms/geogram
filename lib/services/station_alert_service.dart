/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Service for fetching alerts from station and caching them locally.
 * Polls every 5 minutes and stores alerts in ./devices/{callsign}/alerts/
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import '../models/report.dart';
import 'log_service.dart';
import 'station_service.dart';
import 'config_service.dart';
import 'storage_config.dart';

/// Result of fetching alerts from station
class StationAlertFetchResult {
  final bool success;
  final List<Report> alerts;
  final int timestamp;
  final String? error;
  final String? stationName;
  final String? stationCallsign;

  StationAlertFetchResult({
    required this.success,
    required this.alerts,
    required this.timestamp,
    this.error,
    this.stationName,
    this.stationCallsign,
  });
}

/// Service for fetching and caching alerts from station
class StationAlertService {
  static final StationAlertService _instance = StationAlertService._internal();
  factory StationAlertService() => _instance;
  StationAlertService._internal();

  final StationService _stationService = StationService();
  final ConfigService _configService = ConfigService();

  Timer? _pollTimer;
  int _lastFetchTimestamp = 0;
  List<Report> _cachedAlerts = [];
  bool _isPolling = false;

  /// Duration between polls (5 minutes)
  static const Duration pollInterval = Duration(minutes: 5);

  /// Get the last fetch timestamp
  int get lastFetchTimestamp => _lastFetchTimestamp;

  /// Get cached alerts
  List<Report> get cachedAlerts => List.unmodifiable(_cachedAlerts);

  /// Start polling for alerts
  void startPolling() {
    if (_isPolling) return;
    _isPolling = true;

    LogService().log('StationAlertService: Starting polling every ${pollInterval.inMinutes} minutes');

    // Fetch immediately, then poll
    fetchAlerts();

    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(pollInterval, (_) {
      fetchAlerts();
    });
  }

  /// Stop polling
  void stopPolling() {
    _isPolling = false;
    _pollTimer?.cancel();
    _pollTimer = null;
    LogService().log('StationAlertService: Stopped polling');
  }

  /// Fetch alerts from the station
  ///
  /// Parameters:
  /// - lat: User's latitude for distance filtering
  /// - lon: User's longitude for distance filtering
  /// - radiusKm: Maximum distance in km (null for unlimited)
  /// - useSince: If true, only fetch alerts newer than last fetch
  Future<StationAlertFetchResult> fetchAlerts({
    double? lat,
    double? lon,
    double? radiusKm,
    bool useSince = true,
  }) async {
    LogService().log('StationAlertService: Starting fetch, useSince=$useSince');
    try {
      final station = _stationService.getPreferredStation();
      if (station == null || station.url.isEmpty) {
        LogService().log('StationAlertService: No preferred station configured');
        return StationAlertFetchResult(
          success: false,
          alerts: [],
          timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          error: 'No station configured',
        );
      }

      // Build URL - convert wss:// to https://
      var baseUrl = station.url;
      if (baseUrl.startsWith('wss://')) {
        baseUrl = baseUrl.replaceFirst('wss://', 'https://');
      } else if (baseUrl.startsWith('ws://')) {
        baseUrl = baseUrl.replaceFirst('ws://', 'http://');
      }

      // Build query parameters
      final queryParams = <String, String>{};

      if (useSince && _lastFetchTimestamp > 0) {
        queryParams['since'] = _lastFetchTimestamp.toString();
      }

      if (lat != null) queryParams['lat'] = lat.toString();
      if (lon != null) queryParams['lon'] = lon.toString();
      if (radiusKm != null && radiusKm < 500) {
        queryParams['radius'] = radiusKm.toString();
      }

      final uri = Uri.parse('$baseUrl/api/alerts').replace(queryParameters: queryParams);

      LogService().log('StationAlertService: Fetching from $uri');

      final response = await http.get(
        uri,
        headers: {'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        LogService().log('StationAlertService: HTTP ${response.statusCode}');
        return StationAlertFetchResult(
          success: false,
          alerts: _cachedAlerts,
          timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          error: 'HTTP ${response.statusCode}',
        );
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;

      if (json['success'] != true) {
        final error = json['error'] as String? ?? 'Unknown error';
        LogService().log('StationAlertService: API error: $error');
        return StationAlertFetchResult(
          success: false,
          alerts: _cachedAlerts,
          timestamp: json['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
          error: error,
        );
      }

      // Parse alerts
      final alertsJson = json['alerts'] as List<dynamic>? ?? [];
      final newAlerts = <Report>[];

      for (final alertData in alertsJson) {
        try {
          final report = _parseAlertFromJson(alertData as Map<String, dynamic>);
          if (report != null) {
            newAlerts.add(report);
          }
        } catch (e) {
          LogService().log('StationAlertService: Error parsing alert: $e');
        }
      }

      // Update cache
      final serverTimestamp = json['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
      _lastFetchTimestamp = serverTimestamp;

      // Merge new alerts with existing cache (avoid duplicates)
      _mergeAlerts(newAlerts);

      // Store alerts locally and download photos
      await _storeAlertsLocally(newAlerts, baseUrl);

      // Save last fetch timestamp
      _saveLastFetchTimestamp();

      final stationInfo = json['station'] as Map<String, dynamic>?;

      LogService().log('StationAlertService: Fetched ${newAlerts.length} alerts, cache now has ${_cachedAlerts.length}');

      return StationAlertFetchResult(
        success: true,
        alerts: _cachedAlerts,
        timestamp: serverTimestamp,
        stationName: stationInfo?['name'] as String?,
        stationCallsign: stationInfo?['callsign'] as String?,
      );
    } catch (e) {
      LogService().log('StationAlertService: Fetch error: $e');
      return StationAlertFetchResult(
        success: false,
        alerts: _cachedAlerts,
        timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        error: e.toString(),
      );
    }
  }

  /// Parse a single alert from JSON
  Report? _parseAlertFromJson(Map<String, dynamic> json) {
    try {
      final folderName = json['folderName'] as String? ?? '';
      final callsign = json['callsign'] as String? ?? '';

      if (folderName.isEmpty) return null;

      // Parse severity
      ReportSeverity severity;
      switch ((json['severity'] as String? ?? 'info').toLowerCase()) {
        case 'emergency':
          severity = ReportSeverity.emergency;
          break;
        case 'urgent':
          severity = ReportSeverity.urgent;
          break;
        case 'attention':
          severity = ReportSeverity.attention;
          break;
        default:
          severity = ReportSeverity.info;
      }

      // Parse status
      ReportStatus status;
      switch ((json['status'] as String? ?? 'open').toLowerCase()) {
        case 'in-progress':
          status = ReportStatus.inProgress;
          break;
        case 'resolved':
          status = ReportStatus.resolved;
          break;
        case 'closed':
          status = ReportStatus.closed;
          break;
        default:
          status = ReportStatus.open;
      }

      // Parse created string - format: "YYYY-MM-DD HH:MM_ss"
      String created;
      final createdStr = json['created'] as String? ?? '';
      if (createdStr.isNotEmpty) {
        created = createdStr;
      } else {
        // Generate created timestamp in expected format
        final now = DateTime.now();
        final seconds = now.second.toString().padLeft(2, '0');
        created = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
            '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}_$seconds';
      }

      // Parse feedback fields
      final pointedBy = (json['pointed_by'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList() ?? [];
      final verifiedBy = (json['verified_by'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList() ?? [];

      return Report(
        folderName: folderName,
        titles: {'EN': json['title'] as String? ?? folderName},
        descriptions: {'EN': json['description'] as String? ?? ''},
        latitude: (json['latitude'] as num?)?.toDouble() ?? 0.0,
        longitude: (json['longitude'] as num?)?.toDouble() ?? 0.0,
        type: json['type'] as String? ?? 'other',
        severity: severity,
        status: status,
        created: created,
        author: json['author'] as String? ?? callsign,
        address: json['address'] as String?,
        pointedBy: pointedBy,
        pointCount: json['point_count'] as int? ?? pointedBy.length,
        verifiedBy: verifiedBy,
        verificationCount: json['verification_count'] as int? ?? verifiedBy.length,
        lastModified: json['last_modified'] as String?,
        metadata: {
          'station_callsign': callsign,
          'from_station': 'true',
        },
      );
    } catch (e) {
      LogService().log('StationAlertService: Parse error: $e');
      return null;
    }
  }

  /// Merge new alerts into cache, using lastModified to determine which version is newer
  void _mergeAlerts(List<Report> newAlerts) {
    final existingFolders = _cachedAlerts.map((a) => a.folderName).toSet();

    for (final alert in newAlerts) {
      if (!existingFolders.contains(alert.folderName)) {
        // New alert - add to cache
        _cachedAlerts.add(alert);
        existingFolders.add(alert.folderName);
      } else {
        // Existing alert - compare lastModified timestamps
        final index = _cachedAlerts.indexWhere((a) => a.folderName == alert.folderName);
        if (index >= 0) {
          final existing = _cachedAlerts[index];
          final existingModified = existing.lastModifiedDateTime;
          final newModified = alert.lastModifiedDateTime;

          // Update if station version is newer or if we don't have lastModified info
          if (newModified != null) {
            if (existingModified == null || newModified.isAfter(existingModified)) {
              // Station version is newer - update cache with new feedback counts
              _cachedAlerts[index] = alert;
              LogService().log('StationAlertService: Updated alert ${alert.folderName} (station version newer)');
            }
          } else if (existingModified == null) {
            // Neither has lastModified, use station version
            _cachedAlerts[index] = alert;
          }
          // Otherwise keep existing (our version is newer)
        }
      }
    }

    // Sort by date (newest first)
    _cachedAlerts.sort((a, b) => b.dateTime.compareTo(a.dateTime));
  }

  /// Store alerts locally in devices/{callsign}/alerts/ and download photos
  /// Only updates report.txt if station version is newer (based on LAST_MODIFIED)
  /// Searches for existing alerts by folder name to avoid creating duplicates
  Future<void> _storeAlertsLocally(List<Report> alerts, String baseUrl) async {
    final storageConfig = StorageConfig();
    if (!storageConfig.isInitialized) return;

    final devicesDir = storageConfig.devicesDir;

    for (final alert in alerts) {
      try {
        final callsign = alert.metadata['station_callsign'] ?? 'unknown';

        // Search for existing alert folder (may be in active/{region}/ subfolder)
        String? existingAlertPath = await _findExistingAlertPath(devicesDir, callsign, alert.folderName);

        final String alertPath;
        if (existingAlertPath != null) {
          alertPath = existingAlertPath;
          LogService().log('StationAlertService: Found existing alert at $alertPath');
        } else {
          // Create new alert directory
          alertPath = '$devicesDir/$callsign/alerts/${alert.folderName}';
          final alertDir = Directory(alertPath);
          if (!await alertDir.exists()) {
            await alertDir.create(recursive: true);
          }
          LogService().log('StationAlertService: Creating new alert at $alertPath');
        }

        final reportFile = File('$alertPath/report.txt');
        bool shouldUpdate = true;

        // Check if local file exists and compare LAST_MODIFIED timestamps
        if (await reportFile.exists()) {
          final localContent = await reportFile.readAsString();
          final localLastModified = _extractLastModified(localContent);
          final stationLastModified = alert.lastModifiedDateTime;

          if (localLastModified != null && stationLastModified != null) {
            // Only update if station version is newer
            if (!stationLastModified.isAfter(localLastModified)) {
              LogService().log('StationAlertService: Local version is current for ${alert.folderName}, skipping update');
              shouldUpdate = false;
            } else {
              LogService().log('StationAlertService: Station has newer version for ${alert.folderName}');
            }
          } else if (localLastModified != null && stationLastModified == null) {
            // Local has LAST_MODIFIED but station doesn't - keep local
            LogService().log('StationAlertService: Keeping local version (has LAST_MODIFIED) for ${alert.folderName}');
            shouldUpdate = false;
          }
          // If neither has LAST_MODIFIED, or only station has it, update from station
        }

        if (shouldUpdate) {
          // Fetch full alert details from station (includes report content and comments)
          final alertDetails = await _fetchAlertDetails(alert.folderName, baseUrl, callsign);
          if (alertDetails != null) {
            final reportContent = alertDetails['report_content'] as String?;
            if (reportContent != null && reportContent.isNotEmpty) {
              await reportFile.writeAsString(reportContent);
              LogService().log('StationAlertService: Updated report.txt for ${alert.folderName}');
            }

            // Download comments from station
            final comments = alertDetails['comments'] as List<dynamic>?;
            if (comments != null && comments.isNotEmpty) {
              await _downloadAlertComments(comments, alertPath);
            }
          } else {
            // Fallback to creating from alert data
            await reportFile.writeAsString(alert.exportAsText());
            LogService().log('StationAlertService: Created report.txt for ${alert.folderName} (from alert data)');
          }
        }

        // Download photos for this alert (skips existing photos)
        await _downloadAlertPhotos(alert, alertPath, baseUrl, callsign);
      } catch (e) {
        LogService().log('StationAlertService: Error storing alert ${alert.folderName}: $e');
      }
    }
  }

  /// Search for an existing alert folder by name under the callsign's alerts directory
  /// This handles the case where alerts may be stored in active/{region}/ subfolders
  Future<String?> _findExistingAlertPath(String devicesDir, String callsign, String folderName) async {
    final alertsDir = Directory('$devicesDir/$callsign/alerts');
    if (!await alertsDir.exists()) return null;

    await for (final entity in alertsDir.list(recursive: true)) {
      if (entity is Directory && entity.path.endsWith('/$folderName')) {
        // Verify it has a report.txt
        final reportFile = File('${entity.path}/report.txt');
        if (await reportFile.exists()) {
          return entity.path;
        }
      }
    }
    return null;
  }

  /// Extract LAST_MODIFIED timestamp from report.txt content
  DateTime? _extractLastModified(String content) {
    final regex = RegExp(r'^LAST_MODIFIED: (.+)$', multiLine: true);
    final match = regex.firstMatch(content);
    if (match != null) {
      try {
        return DateTime.parse(match.group(1)!.trim());
      } catch (e) {
        LogService().log('StationAlertService: Error parsing LAST_MODIFIED: $e');
      }
    }
    return null;
  }

  /// Fetch full alert details from station (includes report_content, comments, etc.)
  Future<Map<String, dynamic>?> _fetchAlertDetails(String alertId, String baseUrl, String callsign) async {
    try {
      final uri = Uri.parse('$baseUrl/$callsign/api/alerts/$alertId');
      final response = await http.get(uri).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
    } catch (e) {
      LogService().log('StationAlertService: Error fetching alert details: $e');
    }
    return null;
  }

  /// Download and save comments from station to local comments/ folder
  Future<void> _downloadAlertComments(List<dynamic> comments, String alertPath) async {
    final commentsDir = Directory('$alertPath/comments');
    if (!await commentsDir.exists()) {
      await commentsDir.create(recursive: true);
    }

    for (final commentData in comments) {
      try {
        final comment = commentData as Map<String, dynamic>;
        final filename = comment['filename'] as String?;
        if (filename == null) continue;

        final commentFile = File('${commentsDir.path}/$filename');

        // Skip if comment already exists locally
        if (await commentFile.exists()) {
          continue;
        }

        // Reconstruct comment file content
        final buffer = StringBuffer();
        buffer.writeln('AUTHOR: ${comment['author'] ?? 'UNKNOWN'}');
        buffer.writeln('CREATED: ${comment['created'] ?? ''}');
        buffer.writeln();
        buffer.writeln(comment['content'] ?? '');

        final npub = comment['npub'] as String?;
        if (npub != null && npub.isNotEmpty) {
          buffer.writeln();
          buffer.writeln('--> npub: $npub');
        }

        final signature = comment['signature'] as String?;
        if (signature != null && signature.isNotEmpty) {
          buffer.writeln('--> signature: $signature');
        }

        await commentFile.writeAsString(buffer.toString());
        LogService().log('StationAlertService: Downloaded comment: $filename');
      } catch (e) {
        LogService().log('StationAlertService: Error saving comment: $e');
      }
    }
  }

  /// Fetch alert details including photos list from station
  Future<List<String>> _getAlertPhotosFromStation(
    String alertId,
    String baseUrl,
    String callsign,
  ) async {
    try {
      // Fetch detailed alert info which includes photos list
      final uri = Uri.parse('$baseUrl/$callsign/api/alerts/$alertId');
      final response = await http.get(uri).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final photos = json['photos'] as List<dynamic>?;
        if (photos != null) {
          return photos.map((p) => p as String).toList();
        }
      }
    } catch (e) {
      LogService().log('StationAlertService: Error getting alert photos: $e');
    }
    return [];
  }

  /// Download photos for an alert from station
  Future<void> _downloadAlertPhotos(
    Report alert,
    String alertPath,
    String baseUrl,
    String callsign,
  ) async {
    try {
      // Get list of photos from station
      final photos = await _getAlertPhotosFromStation(alert.folderName, baseUrl, callsign);

      if (photos.isEmpty) {
        LogService().log('StationAlertService: No photos to download for ${alert.folderName}');
        return;
      }

      LogService().log('StationAlertService: Downloading ${photos.length} photos for ${alert.folderName}');

      for (final photoName in photos) {
        try {
          final photoFile = File('$alertPath/$photoName');

          // Skip if already exists
          if (await photoFile.exists()) {
            LogService().log('StationAlertService: Photo $photoName already exists, skipping');
            continue;
          }

          // Download photo
          final photoUrl = Uri.parse('$baseUrl/$callsign/api/alerts/${alert.folderName}/files/$photoName');
          final response = await http.get(photoUrl).timeout(const Duration(seconds: 30));

          if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
            await photoFile.writeAsBytes(response.bodyBytes);
            LogService().log('StationAlertService: Downloaded photo $photoName (${response.bodyBytes.length} bytes)');
          } else {
            LogService().log('StationAlertService: Failed to download photo $photoName: ${response.statusCode}');
          }
        } catch (e) {
          LogService().log('StationAlertService: Error downloading photo $photoName: $e');
        }
      }
    } catch (e) {
      LogService().log('StationAlertService: Error downloading photos for ${alert.folderName}: $e');
    }
  }

  /// Load cached alerts from disk
  Future<void> loadCachedAlerts() async {
    try {
      final storageConfig = StorageConfig();
      if (!storageConfig.isInitialized) return;

      final devicesDir = Directory(storageConfig.devicesDir);

      if (!await devicesDir.exists()) return;

      _cachedAlerts.clear();

      await for (final deviceEntity in devicesDir.list()) {
        if (deviceEntity is! Directory) continue;

        final callsign = deviceEntity.path.split('/').last;
        // Skip our own callsign
        // TODO: Get current user's callsign and skip it

        final alertsDir = Directory('${deviceEntity.path}/alerts');
        if (!await alertsDir.exists()) continue;

        await for (final alertEntity in alertsDir.list()) {
          if (alertEntity is! Directory) continue;

          final reportFile = File('${alertEntity.path}/report.txt');
          if (!await reportFile.exists()) continue;

          try {
            final content = await reportFile.readAsString();
            final report = Report.fromText(content, alertEntity.path.split('/').last);

            // Mark as from station
            final metadata = Map<String, String>.from(report.metadata);
            metadata['station_callsign'] = callsign;
            metadata['from_station'] = 'true';

            _cachedAlerts.add(report.copyWith(metadata: metadata));
          } catch (e) {
            LogService().log('StationAlertService: Error loading alert: $e');
          }
        }
      }

      // Sort by date (newest first)
      _cachedAlerts.sort((a, b) => b.dateTime.compareTo(a.dateTime));

      // Load last fetch timestamp
      _loadLastFetchTimestamp();

      LogService().log('StationAlertService: Loaded ${_cachedAlerts.length} cached alerts');
    } catch (e) {
      LogService().log('StationAlertService: Error loading cached alerts: $e');
    }
  }

  /// Save last fetch timestamp to config
  void _saveLastFetchTimestamp() {
    try {
      _configService.set('station_alerts_last_fetch', _lastFetchTimestamp.toString());
    } catch (e) {
      LogService().log('StationAlertService: Error saving timestamp: $e');
    }
  }

  /// Load last fetch timestamp from config
  void _loadLastFetchTimestamp() {
    try {
      final value = _configService.get('station_alerts_last_fetch');
      if (value != null && value is String) {
        _lastFetchTimestamp = int.tryParse(value) ?? 0;
      }
    } catch (e) {
      LogService().log('StationAlertService: Error loading timestamp: $e');
    }
  }

  /// Clear cached alerts
  void clearCache() {
    _cachedAlerts.clear();
    _lastFetchTimestamp = 0;
    _saveLastFetchTimestamp();
    LogService().log('StationAlertService: Cache cleared');
  }

  /// Get time since last fetch as human-readable string
  String getTimeSinceLastFetch() {
    if (_lastFetchTimestamp == 0) return 'Never';

    final lastFetch = DateTime.fromMillisecondsSinceEpoch(_lastFetchTimestamp * 1000);
    final diff = DateTime.now().difference(lastFetch);

    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}
