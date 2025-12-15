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
import '../util/alert_folder_utils.dart';
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

  /// Store alerts locally in devices/{callsign}/alerts/ using file tree sync.
  /// Uses mtime comparison to download only files that have changed.
  /// Searches for existing alerts by folder name to avoid creating duplicates.
  Future<void> _storeAlertsLocally(List<Report> alerts, String baseUrl) async {
    final storageConfig = StorageConfig();
    if (!storageConfig.isInitialized) return;

    final devicesDir = storageConfig.devicesDir;

    for (final alert in alerts) {
      try {
        final callsign = alert.metadata['station_callsign'] ?? 'unknown';

        // Search for existing alert folder (may be in active/{region}/ subfolder)
        String? existingAlertPath = await AlertFolderUtils.findAlertPath(
          '$devicesDir/$callsign/alerts',
          alert.folderName,
        );

        final String alertPath;
        if (existingAlertPath != null) {
          alertPath = existingAlertPath;
          LogService().log('StationAlertService: Found existing alert at $alertPath');
        } else {
          // Create new alert directory with proper structure: active/{regionFolder}/{folderName}
          alertPath = AlertFolderUtils.buildAlertPathFromCoords(
            baseDir: devicesDir,
            callsign: callsign,
            latitude: alert.latitude,
            longitude: alert.longitude,
            folderName: alert.folderName,
          );
          final alertDir = Directory(alertPath);
          if (!await alertDir.exists()) {
            await alertDir.create(recursive: true);
          }
          LogService().log('StationAlertService: Creating new alert at $alertPath');
        }

        // Load cached alert details to compare with server
        final cachedDetails = await _loadCachedAlertDetails(alertPath);

        // Fetch alert details from station and sync files
        final alertDetails = await _fetchAlertDetails(alert.folderName, baseUrl, callsign);

        if (alertDetails != null) {
          // Compare last_modified to detect changes
          final serverLastModified = alertDetails['last_modified'] as String?;
          final cachedLastModified = cachedDetails?['last_modified'] as String?;

          if (serverLastModified != null &&
              cachedLastModified != null &&
              serverLastModified == cachedLastModified) {
            // Alert hasn't changed, skip sync
            LogService().log('StationAlertService: Alert ${alert.folderName} unchanged, skipping sync');
            continue;
          }

          // Cache server response for future comparison
          await _cacheAlertDetails(alertPath, alertDetails);

          // Sync all files from server using file tree and mtime comparison
          final serverFiles = alertDetails['files'] as Map<String, dynamic>?;
          if (serverFiles != null) {
            await _syncAlertFiles(
              alertId: alert.folderName,
              alertPath: alertPath,
              serverFiles: serverFiles,
              baseUrl: baseUrl,
              callsign: callsign,
            );
          }
        } else {
          // Unable to fetch details - create report.txt from alert data
          final reportFile = File('$alertPath/report.txt');
          if (!await reportFile.exists()) {
            await reportFile.writeAsString(alert.exportAsText());
            LogService().log('StationAlertService: Created report.txt for ${alert.folderName} (from alert data)');
          }
          await _downloadAlertPoints(alert.pointedBy, alertPath);
        }
      } catch (e) {
        LogService().log('StationAlertService: Error storing alert ${alert.folderName}: $e');
      }
    }
  }

  /// Fetch full alert details from station (includes report_content, comments, files tree, etc.)
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

  /// Cache alert details from server to local file for future comparison.
  /// Saves the full server response including file tree to .cache.json
  Future<void> _cacheAlertDetails(String alertPath, Map<String, dynamic> details) async {
    try {
      final cacheFile = File('$alertPath/.cache.json');
      final cacheData = {
        'cached_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        ...details,
      };
      await cacheFile.writeAsString(jsonEncode(cacheData));
    } catch (e) {
      LogService().log('StationAlertService: Error caching alert details: $e');
    }
  }

  /// Load cached alert details from local file.
  /// Returns null if cache doesn't exist or is invalid.
  Future<Map<String, dynamic>?> _loadCachedAlertDetails(String alertPath) async {
    try {
      final cacheFile = File('$alertPath/.cache.json');
      if (await cacheFile.exists()) {
        final content = await cacheFile.readAsString();
        return jsonDecode(content) as Map<String, dynamic>;
      }
    } catch (e) {
      LogService().log('StationAlertService: Error loading cached alert details: $e');
    }
    return null;
  }

  /// Sync alert files using the file tree from server.
  /// Compares mtime to determine which files need downloading.
  Future<void> _syncAlertFiles({
    required String alertId,
    required String alertPath,
    required Map<String, dynamic> serverFiles,
    required String baseUrl,
    required String callsign,
    String relativePath = '',
  }) async {
    for (final entry in serverFiles.entries) {
      final name = entry.key;
      final meta = entry.value;

      if (name.endsWith('/')) {
        // Directory - create and recurse
        final dirName = name.substring(0, name.length - 1);
        final localDirPath = relativePath.isEmpty
            ? '$alertPath/$dirName'
            : '$alertPath/$relativePath/$dirName';
        await Directory(localDirPath).create(recursive: true);

        if (meta is Map<String, dynamic>) {
          await _syncAlertFiles(
            alertId: alertId,
            alertPath: alertPath,
            serverFiles: meta,
            baseUrl: baseUrl,
            callsign: callsign,
            relativePath: relativePath.isEmpty ? dirName : '$relativePath/$dirName',
          );
        }
      } else {
        // File - check if we need to download based on mtime
        if (meta is! Map<String, dynamic>) continue;
        final serverMtime = meta['mtime'] as int? ?? 0;
        if (serverMtime == 0) continue; // Skip non-existent files

        final localFilePath = relativePath.isEmpty
            ? '$alertPath/$name'
            : '$alertPath/$relativePath/$name';
        final fileRelPath = relativePath.isEmpty ? name : '$relativePath/$name';

        // Check local file mtime
        final localFile = File(localFilePath);
        int localMtime = 0;
        if (await localFile.exists()) {
          localMtime = (await localFile.stat()).modified.millisecondsSinceEpoch ~/ 1000;
        }

        // Only download if server version is newer
        if (serverMtime > localMtime) {
          await _downloadFile(
            alertId: alertId,
            filePath: fileRelPath,
            localFile: localFile,
            baseUrl: baseUrl,
            callsign: callsign,
          );
        }
      }
    }
  }

  /// Download a single file from the station
  Future<bool> _downloadFile({
    required String alertId,
    required String filePath,
    required File localFile,
    required String baseUrl,
    required String callsign,
  }) async {
    try {
      final uri = Uri.parse('$baseUrl/$callsign/api/alerts/$alertId/files/$filePath');
      final response = await http.get(uri).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        // Ensure parent directory exists
        final parent = localFile.parent;
        if (!await parent.exists()) {
          await parent.create(recursive: true);
        }

        await localFile.writeAsBytes(response.bodyBytes);
        LogService().log('StationAlertService: Downloaded $filePath (${response.bodyBytes.length} bytes)');
        return true;
      } else {
        LogService().log('StationAlertService: Failed to download $filePath: HTTP ${response.statusCode}');
      }
    } catch (e) {
      LogService().log('StationAlertService: Error downloading $filePath: $e');
    }
    return false;
  }

  /// Download and save points from station to local points.txt file
  Future<void> _downloadAlertPoints(List<String> pointedBy, String alertPath) async {
    try {
      await AlertFolderUtils.writePointsFile(alertPath, pointedBy);
      if (pointedBy.isNotEmpty) {
        LogService().log('StationAlertService: Saved ${pointedBy.length} points to points.txt');
      }
    } catch (e) {
      LogService().log('StationAlertService: Error saving points: $e');
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
      final seenFolderNames = <String>{};

      await for (final deviceEntity in devicesDir.list()) {
        if (deviceEntity is! Directory) continue;

        final callsign = deviceEntity.path.split('/').last;
        // Skip our own callsign
        // TODO: Get current user's callsign and skip it

        final alertsDir = Directory('${deviceEntity.path}/alerts');
        if (!await alertsDir.exists()) continue;

        await for (final alertEntity in alertsDir.list(recursive: true)) {
          if (alertEntity is! Directory) continue;

          final reportFile = File('${alertEntity.path}/report.txt');
          if (!await reportFile.exists()) continue;

          try {
            final folderName = alertEntity.path.split('/').last;

            // Skip if we've already loaded this alert (handles duplicates in different paths)
            if (seenFolderNames.contains(folderName)) continue;
            seenFolderNames.add(folderName);

            final content = await reportFile.readAsString();
            final report = Report.fromText(content, folderName);

            // Read points from points.txt
            final pointedBy = await AlertFolderUtils.readPointsFile(alertEntity.path);

            // Mark as from station
            final metadata = Map<String, String>.from(report.metadata);
            metadata['station_callsign'] = callsign;
            metadata['from_station'] = 'true';

            _cachedAlerts.add(report.copyWith(
              metadata: metadata,
              pointedBy: pointedBy,
              pointCount: pointedBy.length,
            ));
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

  /// Download fresh alert from station and update cache using file tree sync.
  Future<void> refreshAlert(String folderName, String stationCallsign) async {
    try {
      final station = _stationService.getPreferredStation();
      if (station == null) return;

      var baseUrl = station.url;
      if (baseUrl.startsWith('wss://')) baseUrl = baseUrl.replaceFirst('wss://', 'https://');
      else if (baseUrl.startsWith('ws://')) baseUrl = baseUrl.replaceFirst('ws://', 'http://');

      final storageConfig = StorageConfig();
      if (!storageConfig.isInitialized) return;

      final devicesDir = storageConfig.devicesDir;
      final alertPath = await AlertFolderUtils.findAlertPath(
        '$devicesDir/$stationCallsign/alerts',
        folderName,
      );
      if (alertPath == null) return;

      final alertDetails = await _fetchAlertDetails(folderName, baseUrl, stationCallsign);

      if (alertDetails != null) {
        // Use file tree sync if available (new approach)
        final serverFiles = alertDetails['files'] as Map<String, dynamic>?;
        if (serverFiles != null && serverFiles.isNotEmpty) {
          LogService().log('StationAlertService: Refreshing $folderName using file tree sync');
          await _syncAlertFiles(
            alertId: folderName,
            alertPath: alertPath,
            serverFiles: serverFiles,
            baseUrl: baseUrl,
            callsign: stationCallsign,
          );

          // Also update points.txt from the pointed_by list
          final pointedBy = (alertDetails['pointed_by'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ?? [];
          await _downloadAlertPoints(pointedBy, alertPath);
        } else {
          // Fallback: no file tree, download report.txt directly
          final reportContent = alertDetails['report_content'] as String?;
          if (reportContent != null && reportContent.isNotEmpty) {
            await File('$alertPath/report.txt').writeAsString(reportContent);

            // Also update points.txt
            final pointedBy = (alertDetails['pointed_by'] as List<dynamic>?)
                ?.map((e) => e as String)
                .toList() ?? [];
            await _downloadAlertPoints(pointedBy, alertPath);
          }
        }

        await loadCachedAlerts();  // Refresh the in-memory cache
      }
    } catch (e) {
      LogService().log('StationAlertService: Error refreshing alert: $e');
    }
  }
}
