/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Shared Alert API handlers for station servers.
 * This module provides the core logic for alert-related API endpoints,
 * used by both PureStationServer (CLI) and StationServerService (GUI).
 */

import 'dart:io';
import 'dart:math' as math;

import '../models/report.dart';
import '../util/alert_folder_utils.dart';

/// Station info for API responses
class StationInfo {
  final String? name;
  final String? callsign;
  final String? npub;

  StationInfo({this.name, this.callsign, this.npub});

  Map<String, dynamic> toJson() => {
    'name': name ?? 'Geogram Station',
    'callsign': callsign,
    'npub': npub,
  };
}

/// Shared Alert API handlers for station servers
class StationAlertApi {
  final String dataDir;
  final StationInfo stationInfo;
  final void Function(String level, String message)? log;

  StationAlertApi({
    required this.dataDir,
    required this.stationInfo,
    this.log,
  });

  void _log(String level, String message) {
    log?.call(level, message);
  }

  // ============================================================
  // GET /api/alerts - List all alerts
  // ============================================================

  /// Handle GET /api/alerts - returns list of alerts with optional filtering
  Future<Map<String, dynamic>> getAlerts({
    int? sinceTimestamp,
    double? lat,
    double? lon,
    double? radiusKm,
    String? statusFilter,
  }) async {
    try {
      // Load all alerts
      var alerts = await _loadAllAlerts(includeAllStatuses: statusFilter != null);

      // Filter by status if specified
      if (statusFilter != null) {
        alerts = alerts.where((a) => a['status'] == statusFilter).toList();
      }

      // Filter by since timestamp
      if (sinceTimestamp != null) {
        final sinceDate = DateTime.fromMillisecondsSinceEpoch(sinceTimestamp * 1000);
        alerts = alerts.where((alert) {
          final lastModifiedStr = alert['last_modified'] as String?;
          final createdStr = alert['created'] as String?;

          try {
            if (lastModifiedStr != null && lastModifiedStr.isNotEmpty) {
              final lastModified = DateTime.parse(lastModifiedStr);
              return lastModified.isAfter(sinceDate);
            }
            if (createdStr != null && createdStr.isNotEmpty) {
              final created = _parseAlertDateTime(createdStr);
              return created.isAfter(sinceDate);
            }
            return true;
          } catch (_) {
            return true;
          }
        }).toList();
      }

      // Filter by distance
      if (lat != null && lon != null && radiusKm != null && radiusKm > 0) {
        alerts = alerts.where((alert) {
          final alertLat = alert['latitude'] as double?;
          final alertLon = alert['longitude'] as double?;
          if (alertLat == null || alertLon == null) return false;
          if (alertLat == 0.0 && alertLon == 0.0) return false;

          final distance = _calculateDistanceKm(lat, lon, alertLat, alertLon);
          return distance <= radiusKm;
        }).toList();
      }

      return {
        'success': true,
        'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'station': stationInfo.toJson(),
        'filters': {
          if (sinceTimestamp != null) 'since': sinceTimestamp,
          if (lat != null) 'lat': lat,
          if (lon != null) 'lon': lon,
          if (radiusKm != null) 'radius_km': radiusKm,
          if (statusFilter != null) 'status': statusFilter,
        },
        'count': alerts.length,
        'alerts': alerts,
      };
    } catch (e) {
      _log('ERROR', 'Error in alerts API: $e');
      return {
        'success': false,
        'error': 'Internal server error',
        'message': e.toString(),
      };
    }
  }

  // ============================================================
  // GET /{callsign}/api/alerts/{alertId} - Alert details
  // ============================================================

  /// Handle GET /{callsign}/api/alerts/{alertId} - returns alert details with photos list
  Future<Map<String, dynamic>> getAlertDetails(String callsign, String alertId) async {
    try {
      // Search recursively for the alert folder
      final alertPath = await AlertFolderUtils.findAlertPath(
        '$dataDir/devices/$callsign/alerts',
        alertId,
      );

      _log('INFO', 'getAlertDetails: looking for alert $alertId under callsign $callsign');

      if (alertPath == null) {
        _log('WARN', 'getAlertDetails: alert not found: $alertId');
        return {'error': 'Alert not found', 'http_status': 404};
      }

      final alertDir = Directory(alertPath);

      final reportFile = File('${alertDir.path}/report.txt');
      if (!await reportFile.exists()) {
        return {'error': 'Alert report not found', 'http_status': 404};
      }

      // Read the report content
      final reportContent = await reportFile.readAsString();

      // Try to parse the report, but don't fail if parsing fails
      // The raw report_content will still be returned for clients to download
      Report? report;
      try {
        report = Report.fromText(reportContent, alertId);
      } catch (e) {
        _log('WARN', 'getAlertDetails: failed to parse report, returning raw content: $e');
      }

      // Find all photos (check both root and images/ subfolder)
      final photoExtensions = ['.jpg', '.jpeg', '.png', '.gif', '.webp'];
      final photos = <String>[];

      // Check images/ subfolder first (new structure)
      final imagesDir = Directory('${alertDir.path}/images');
      if (await imagesDir.exists()) {
        await for (final entity in imagesDir.list()) {
          if (entity is File) {
            final filename = entity.path.split('/').last;
            final ext = filename.toLowerCase();
            if (photoExtensions.any((e) => ext.endsWith(e))) {
              photos.add('images/$filename');
            }
          }
        }
      }

      // Also check root folder for backwards compatibility
      await for (final entity in alertDir.list()) {
        if (entity is File) {
          final filename = entity.path.split('/').last;
          final ext = filename.toLowerCase();
          if (photoExtensions.any((e) => ext.endsWith(e))) {
            photos.add(filename);
          }
        }
      }

      // Find all comments
      final comments = <Map<String, dynamic>>[];
      final commentsDir = Directory('${alertDir.path}/comments');
      if (await commentsDir.exists()) {
        await for (final entity in commentsDir.list()) {
          if (entity is File && entity.path.endsWith('.txt')) {
            try {
              final content = await entity.readAsString();
              final filename = entity.path.split('/').last;
              final comment = _parseComment(content, filename);
              if (comment != null) {
                comments.add(comment);
              }
            } catch (e) {
              _log('WARN', 'Failed to parse comment: ${entity.path}');
            }
          }
        }
        // Sort comments by created time (oldest first)
        comments.sort((a, b) => (a['created'] as String).compareTo(b['created'] as String));
      }

      // Read points from points.txt
      final pointedBy = await AlertFolderUtils.readPointsFile(alertDir.path);

      // Build file tree for sync
      final fileTree = await _buildFileTree(alertDir.path);

      _log('INFO', 'Alert details: found ${photos.length} photos, ${comments.length} comments, ${pointedBy.length} points');

      return {
        'id': alertId,
        'folder_name': report?.folderName ?? alertId,
        'title': report?.titles['EN'] ?? alertId,
        'description': report?.descriptions['EN'] ?? '',
        'latitude': report?.latitude ?? 0.0,
        'longitude': report?.longitude ?? 0.0,
        'severity': report?.severity.name ?? 'info',
        'status': report?.status.name ?? 'open',
        'type': report?.type ?? 'other',
        'point_count': pointedBy.length,
        'verification_count': report?.verificationCount ?? 0,
        'pointed_by': pointedBy,
        'verified_by': report?.verifiedBy ?? [],
        'last_modified': report?.lastModified,
        'files': fileTree,
        'photos': photos,
        'comments': comments,
        'comment_count': comments.length,
        'callsign': callsign,
        'report_content': reportContent,
      };
    } catch (e) {
      _log('ERROR', 'Error handling alert details: $e');
      return {
        'error': 'Internal server error',
        'message': e.toString(),
        'http_status': 500,
      };
    }
  }

  // ============================================================
  // POST /api/alerts/{alertId}/point - Point/unpoint alert
  // ============================================================

  /// Handle POST /api/alerts/{alertId}/point
  Future<Map<String, dynamic>> pointAlert(String alertId, String npub, {bool isPoint = true}) async {
    try {
      // Find the alert
      final alertPath = await _findAlertById(alertId);
      if (alertPath == null) {
        return {'error': 'Alert not found', 'http_status': 404};
      }

      final reportFile = File('$alertPath/report.txt');
      if (!await reportFile.exists()) {
        return {'error': 'Alert report not found', 'http_status': 404};
      }

      // Read points from points.txt
      var pointedBy = await AlertFolderUtils.readPointsFile(alertPath);

      // Update pointedBy
      bool changed = false;
      if (isPoint && !pointedBy.contains(npub)) {
        pointedBy.add(npub);
        changed = true;
      } else if (!isPoint && pointedBy.contains(npub)) {
        pointedBy.remove(npub);
        changed = true;
      }

      final lastModified = DateTime.now().toUtc().toIso8601String();

      if (changed) {
        // Write points to points.txt
        await AlertFolderUtils.writePointsFile(alertPath, pointedBy);

        // Update LAST_MODIFIED in report.txt
        final content = await reportFile.readAsString();
        final newContent = _updateAlertFeedback(content, lastModified: lastModified);
        await reportFile.writeAsString(newContent, flush: true);
        _log('INFO', 'Alert ${isPoint ? "pointed" : "unpointed"} by $npub');
      }

      return {
        'success': true,
        'pointed': isPoint ? pointedBy.contains(npub) : !pointedBy.contains(npub),
        'point_count': pointedBy.length,
        'last_modified': lastModified,
      };
    } catch (e) {
      _log('ERROR', 'Error handling point: $e');
      return {
        'error': 'Internal server error',
        'message': e.toString(),
        'http_status': 500,
      };
    }
  }

  // ============================================================
  // POST /api/alerts/{alertId}/verify - Verify alert
  // ============================================================

  /// Handle POST /api/alerts/{alertId}/verify
  Future<Map<String, dynamic>> verifyAlert(String alertId, String npub) async {
    try {
      final alertPath = await _findAlertById(alertId);
      if (alertPath == null) {
        return {'error': 'Alert not found', 'http_status': 404};
      }

      final reportFile = File('$alertPath/report.txt');
      if (!await reportFile.exists()) {
        return {'error': 'Alert report not found', 'http_status': 404};
      }

      final content = await reportFile.readAsString();
      final lines = content.split('\n');

      // Parse current verifiedBy
      var verifiedBy = <String>[];
      for (final line in lines) {
        if (line.startsWith('VERIFIED_BY: ')) {
          final verifiedByStr = line.substring(13).trim();
          verifiedBy = verifiedByStr.isEmpty ? [] : verifiedByStr.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
          break;
        }
      }

      bool changed = false;
      if (!verifiedBy.contains(npub)) {
        verifiedBy.add(npub);
        changed = true;
      }

      final lastModified = DateTime.now().toUtc().toIso8601String();

      if (changed) {
        final newContent = _updateAlertFeedback(content, verifiedBy: verifiedBy, lastModified: lastModified);
        await reportFile.writeAsString(newContent, flush: true);
        _log('INFO', 'Alert verified by $npub');
      }

      return {
        'success': true,
        'verified': true,
        'verification_count': verifiedBy.length,
        'last_modified': lastModified,
      };
    } catch (e) {
      _log('ERROR', 'Error handling verify: $e');
      return {
        'error': 'Internal server error',
        'message': e.toString(),
        'http_status': 500,
      };
    }
  }

  // ============================================================
  // POST /api/alerts/{alertId}/comment - Add comment
  // ============================================================

  /// Handle POST /api/alerts/{alertId}/comment
  Future<Map<String, dynamic>> addComment(
    String alertId,
    String author,
    String content, {
    String? npub,
    String? signature,
  }) async {
    try {
      final alertPath = await _findAlertById(alertId);
      if (alertPath == null) {
        return {'error': 'Alert not found', 'http_status': 404};
      }

      // Create comments directory
      final commentsDir = Directory('$alertPath/comments');
      if (!await commentsDir.exists()) {
        await commentsDir.create(recursive: true);
      }

      // Generate comment ID and filename: YYYY-MM-DD_HH-MM-SS_XXXXXX.txt
      final now = DateTime.now();
      final randomId = _generateRandomId(6);
      final id = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}_'
          '${now.hour.toString().padLeft(2, '0')}-${now.minute.toString().padLeft(2, '0')}-${now.second.toString().padLeft(2, '0')}_$randomId';
      final createdStr = '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}_${now.second.toString().padLeft(2, '0')}';

      // Build comment content
      final buffer = StringBuffer();
      buffer.writeln('AUTHOR: $author');
      buffer.writeln('CREATED: $createdStr');
      buffer.writeln();
      buffer.writeln(content);
      if (npub != null && npub.isNotEmpty) {
        buffer.writeln('--> npub: $npub');
      }
      if (signature != null && signature.isNotEmpty) {
        buffer.writeln('--> signature: $signature');
      }

      // Save comment file
      final commentFile = File('${commentsDir.path}/$id.txt');
      await commentFile.writeAsString(buffer.toString(), flush: true);

      // Update report last_modified
      final reportFile = File('$alertPath/report.txt');
      if (await reportFile.exists()) {
        final alertContent = await reportFile.readAsString();
        final newContent = _updateAlertFeedback(alertContent, lastModified: DateTime.now().toUtc().toIso8601String());
        await reportFile.writeAsString(newContent, flush: true);
      }

      _log('INFO', 'Comment added to alert by $author');

      return {
        'success': true,
        'comment_id': id,
        'last_modified': DateTime.now().toUtc().toIso8601String(),
      };
    } catch (e) {
      _log('ERROR', 'Error handling comment: $e');
      return {
        'error': 'Internal server error',
        'message': e.toString(),
        'http_status': 500,
      };
    }
  }

  // ============================================================
  // File handling: Upload and serve photos
  // ============================================================

  /// Handle alert photo upload
  Future<Map<String, dynamic>> uploadAlertPhoto(
    String callsign,
    String alertId,
    String filename,
    List<int> bytes, {
    double? latitude,
    double? longitude,
  }) async {
    try {
      // Validate filename (allow images/ prefix)
      final cleanFilename = filename.replaceFirst('images/', '');
      if (cleanFilename.contains('..') || cleanFilename.contains('/')) {
        return {'error': 'Invalid filename', 'http_status': 400};
      }

      // Try to find existing alert folder
      var alertPath = await AlertFolderUtils.findAlertPath(
        '$dataDir/devices/$callsign/alerts',
        alertId,
      );

      if (alertPath == null) {
        // Create new alert directory with proper structure
        // If coordinates provided, use region folder; otherwise use flat structure
        if (latitude != null && longitude != null) {
          alertPath = AlertFolderUtils.buildAlertPathFromCoords(
            baseDir: '$dataDir/devices',
            callsign: callsign,
            latitude: latitude,
            longitude: longitude,
            folderName: alertId,
          );
        } else {
          // Fallback: flat structure without region folder
          alertPath = '$dataDir/devices/$callsign/alerts/active/$alertId';
        }
        final alertDir = Directory(alertPath);
        if (!await alertDir.exists()) {
          await alertDir.create(recursive: true);
        }
      }

      // Create images subfolder and use sequential naming
      final imagesDir = Directory('$alertPath/images');
      if (!await imagesDir.exists()) {
        await imagesDir.create(recursive: true);
      }

      // Get next sequential photo number
      final nextPhotoNum = await _getNextPhotoNumber(alertPath);

      // Determine file extension from provided filename
      final ext = cleanFilename.contains('.')
          ? cleanFilename.substring(cleanFilename.lastIndexOf('.'))
          : '.png';

      // Use sequential naming: photo{number}.{ext}
      final sequentialFilename = 'photo$nextPhotoNum$ext';
      final photoFile = File('${imagesDir.path}/$sequentialFilename');
      await photoFile.writeAsBytes(bytes);

      _log('INFO', 'Uploaded alert photo: images/$sequentialFilename (${bytes.length} bytes)');

      return {
        'success': true,
        'filename': 'images/$sequentialFilename',
        'size': bytes.length,
        'path': '/api/alerts/$alertId/files/images/$sequentialFilename',
      };
    } catch (e) {
      _log('ERROR', 'Error uploading alert photo: $e');
      return {
        'error': 'Internal server error',
        'message': e.toString(),
        'http_status': 500,
      };
    }
  }

  /// Get the next sequential photo number in an alert's images folder
  Future<int> _getNextPhotoNumber(String alertPath) async {
    int maxNumber = 0;
    final imagesDir = Directory('$alertPath/images');
    if (await imagesDir.exists()) {
      await for (final entity in imagesDir.list()) {
        if (entity is File) {
          final filename = entity.path.split('/').last;
          final baseName = filename.contains('.')
              ? filename.substring(0, filename.lastIndexOf('.'))
              : filename;
          final match = RegExp(r'^photo(\d+)$').firstMatch(baseName);
          if (match != null) {
            final num = int.tryParse(match.group(1)!) ?? 0;
            if (num > maxNumber) maxNumber = num;
          }
        }
      }
    }
    return maxNumber + 1;
  }

  /// Get alert photo file path (returns null if not found)
  /// Supports both new structure (images/filename) and legacy (filename in root)
  Future<String?> getAlertPhotoPath(String callsign, String alertId, String filename) async {
    // Handle images/ prefix
    final isInImagesFolder = filename.startsWith('images/');
    final cleanFilename = isInImagesFolder ? filename.substring(7) : filename;

    // Validate filename
    if (cleanFilename.contains('..') || cleanFilename.contains('/')) {
      return null;
    }

    // Find the alert folder first
    final alertPath = await AlertFolderUtils.findAlertPath(
      '$dataDir/devices/$callsign/alerts',
      alertId,
    );
    if (alertPath == null) return null;

    // Check images/ subfolder first (new structure)
    final imagesPhotoFile = File('$alertPath/images/$cleanFilename');
    if (await imagesPhotoFile.exists()) {
      return imagesPhotoFile.path;
    }

    // Check root folder for backwards compatibility
    final rootPhotoFile = File('$alertPath/$cleanFilename');
    if (await rootPhotoFile.exists()) {
      return rootPhotoFile.path;
    }

    return null;
  }

  // ============================================================
  // Internal helper methods
  // ============================================================

  /// Generate a random alphanumeric ID
  String _generateRandomId(int length) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final random = math.Random();
    return String.fromCharCodes(
      Iterable.generate(length, (_) => chars.codeUnitAt(random.nextInt(chars.length))),
    );
  }

  /// Load all alerts from devices directory
  Future<List<Map<String, dynamic>>> _loadAllAlerts({bool includeAllStatuses = false}) async {
    final alerts = <Map<String, dynamic>>[];
    final devicesDir = Directory('$dataDir/devices');

    if (!await devicesDir.exists()) {
      return alerts;
    }

    await for (final deviceEntity in devicesDir.list()) {
      if (deviceEntity is! Directory) continue;

      final callsign = deviceEntity.path.split('/').last;
      final alertsDir = Directory('${deviceEntity.path}/alerts');

      if (!await alertsDir.exists()) continue;

      // Search recursively for report.txt files
      await for (final alertEntity in alertsDir.list(recursive: true)) {
        if (alertEntity is! File) continue;
        if (!alertEntity.path.endsWith('/report.txt')) continue;

        try {
          final content = await alertEntity.readAsString();
          final alertDir = Directory(alertEntity.parent.path);
          final folderName = alertDir.path.split('/').last;
          final alert = _parseAlertContent(content, callsign, folderName);

          // Include based on status filter
          if (includeAllStatuses ||
              alert['status'] == 'open' ||
              alert['status'] == 'in-progress') {
            alerts.add(alert);
          }
        } catch (e) {
          _log('WARN', 'Failed to parse alert: ${alertEntity.path}');
        }
      }
    }

    // Sort by severity then by date
    alerts.sort((a, b) {
      final severityOrder = {'emergency': 0, 'urgent': 1, 'attention': 2, 'info': 3};
      final severityCompare = (severityOrder[a['severity']] ?? 3).compareTo(severityOrder[b['severity']] ?? 3);
      if (severityCompare != 0) return severityCompare;
      return (b['created'] as String).compareTo(a['created'] as String);
    });

    return alerts;
  }

  /// Find alert by ID (folder name or API ID)
  Future<String?> _findAlertById(String alertId) async {
    final devicesDir = Directory('$dataDir/devices');
    if (!await devicesDir.exists()) return null;

    await for (final deviceEntity in devicesDir.list()) {
      if (deviceEntity is! Directory) continue;

      final alertsDir = Directory('${deviceEntity.path}/alerts');
      if (!await alertsDir.exists()) continue;

      // Search recursively
      await for (final alertEntity in alertsDir.list(recursive: true)) {
        if (alertEntity is! File) continue;
        if (!alertEntity.path.endsWith('/report.txt')) continue;

        final alertDir = alertEntity.parent;
        final folderName = alertDir.path.split('/').last;

        // Match by folder name
        if (folderName == alertId) {
          return alertDir.path;
        }

        // Also match by API_ID in report.txt
        try {
          final content = await alertEntity.readAsString();
          final apiIdMatch = RegExp(r'--> apiId: (.+)').firstMatch(content);
          if (apiIdMatch != null && apiIdMatch.group(1)?.trim() == alertId) {
            return alertDir.path;
          }
        } catch (_) {}
      }
    }
    return null;
  }

  /// Parse alert content from report.txt
  Map<String, dynamic> _parseAlertContent(String content, String callsign, String folderName) {
    final lines = content.split('\n');
    final alert = <String, dynamic>{
      'callsign': callsign,
      'folderName': folderName,
      'title': folderName,
      'severity': 'info',
      'status': 'open',
      'type': 'other',
      'created': '',
      'latitude': 0.0,
      'longitude': 0.0,
      'description': '',
    };

    final descLines = <String>[];
    bool inDescription = false;

    for (final line in lines) {
      if (line.startsWith('# REPORT: ')) {
        alert['title'] = line.substring(10).trim();
      } else if (line.startsWith('# REPORT_EN: ')) {
        alert['title'] = line.substring(13).trim();
      } else if (line.startsWith('CREATED: ')) {
        alert['created'] = line.substring(9).trim();
      } else if (line.startsWith('AUTHOR: ')) {
        alert['author'] = line.substring(8).trim();
      } else if (line.startsWith('COORDINATES: ')) {
        final coords = line.substring(13).split(',');
        if (coords.length == 2) {
          alert['latitude'] = double.tryParse(coords[0].trim()) ?? 0.0;
          alert['longitude'] = double.tryParse(coords[1].trim()) ?? 0.0;
        }
      } else if (line.startsWith('SEVERITY: ')) {
        alert['severity'] = line.substring(10).trim().toLowerCase();
      } else if (line.startsWith('STATUS: ')) {
        alert['status'] = line.substring(8).trim().toLowerCase();
      } else if (line.startsWith('TYPE: ')) {
        alert['type'] = line.substring(6).trim();
      } else if (line.startsWith('ADDRESS: ')) {
        alert['address'] = line.substring(9).trim();
      // Note: POINTED_BY and POINT_COUNT are now stored in points.txt file
      } else if (line.startsWith('VERIFIED_BY: ')) {
        final verifiedByStr = line.substring(13).trim();
        alert['verified_by'] = verifiedByStr.isEmpty ? <String>[] : verifiedByStr.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
        alert['verification_count'] = (alert['verified_by'] as List).length;
      } else if (line.startsWith('VERIFICATION_COUNT: ')) {
        alert['verification_count'] = int.tryParse(line.substring(20).trim()) ?? 0;
      } else if (line.startsWith('LAST_MODIFIED: ')) {
        alert['last_modified'] = line.substring(15).trim();
      } else if (line.startsWith('-->')) {
        inDescription = false;
      } else if (line.trim().isEmpty && !inDescription && alert['created'] != '') {
        inDescription = true;
      } else if (inDescription && !line.startsWith('[')) {
        descLines.add(line);
      }
    }

    alert['description'] = descLines.join('\n').trim();
    if ((alert['description'] as String).length > 300) {
      alert['description'] = (alert['description'] as String).substring(0, 300) + '...';
    }

    return alert;
  }

  /// Update alert feedback fields in report.txt content
  /// Note: pointedBy is now stored in points.txt, not in report.txt
  String _updateAlertFeedback(
    String content, {
    List<String>? verifiedBy,
    String? lastModified,
  }) {
    final lines = content.split('\n');
    final newLines = <String>[];

    bool hasVerifiedBy = false;
    bool hasVerificationCount = false;
    bool hasLastModified = false;

    for (final line in lines) {
      // Skip old POINTED_BY and POINT_COUNT fields (now in points.txt)
      if (line.startsWith('POINTED_BY: ') || line.startsWith('POINT_COUNT: ')) {
        continue;
      } else if (verifiedBy != null && line.startsWith('VERIFIED_BY: ')) {
        newLines.add('VERIFIED_BY: ${verifiedBy.join(', ')}');
        hasVerifiedBy = true;
      } else if (verifiedBy != null && line.startsWith('VERIFICATION_COUNT: ')) {
        newLines.add('VERIFICATION_COUNT: ${verifiedBy.length}');
        hasVerificationCount = true;
      } else if (lastModified != null && line.startsWith('LAST_MODIFIED: ')) {
        newLines.add('LAST_MODIFIED: $lastModified');
        hasLastModified = true;
      } else {
        newLines.add(line);
      }
    }

    // Find insertion point - should be after header fields, before description
    // Report format: Title, empty line, header fields, empty line, description
    // We want to insert just before the SECOND empty line (the one before description)
    int insertIndex = newLines.length;
    int emptyLineCount = 0;
    for (int i = 0; i < newLines.length; i++) {
      if (newLines[i].trim().isEmpty && i > 0 && !newLines[i - 1].startsWith('-->')) {
        emptyLineCount++;
        if (emptyLineCount == 2) {
          // Found the empty line before description - insert before it
          insertIndex = i;
          break;
        }
      }
    }

    // Add missing fields
    final toInsert = <String>[];
    if (verifiedBy != null && !hasVerifiedBy && verifiedBy.isNotEmpty) {
      toInsert.add('VERIFIED_BY: ${verifiedBy.join(', ')}');
    }
    if (verifiedBy != null && !hasVerificationCount && verifiedBy.isNotEmpty) {
      toInsert.add('VERIFICATION_COUNT: ${verifiedBy.length}');
    }
    if (lastModified != null && !hasLastModified) {
      toInsert.add('LAST_MODIFIED: $lastModified');
    }

    if (toInsert.isNotEmpty) {
      newLines.insertAll(insertIndex, toInsert);
    }

    return newLines.join('\n');
  }

  /// Parse alert datetime from CREATED field
  DateTime _parseAlertDateTime(String dateStr) {
    // Format: "YYYY-MM-DD HH:MM_ss" or "YYYY-MM-DD HH:MM:ss"
    try {
      final normalized = dateStr.replaceFirst('_', ':');
      final parts = normalized.split(' ');
      if (parts.length >= 2) {
        final dateParts = parts[0].split('-');
        final timeParts = parts[1].split(':');
        if (dateParts.length >= 3 && timeParts.length >= 2) {
          return DateTime(
            int.parse(dateParts[0]),
            int.parse(dateParts[1]),
            int.parse(dateParts[2]),
            int.parse(timeParts[0]),
            int.parse(timeParts[1]),
            timeParts.length > 2 ? int.parse(timeParts[2]) : 0,
          );
        }
      }
    } catch (_) {}
    return DateTime(2000);
  }

  /// Calculate distance between two coordinates in km
  double _calculateDistanceKm(double lat1, double lon1, double lat2, double lon2) {
    const earthRadiusKm = 6371.0;
    final dLat = _degreesToRadians(lat2 - lat1);
    final dLon = _degreesToRadians(lon2 - lon1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_degreesToRadians(lat1)) *
            math.cos(_degreesToRadians(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadiusKm * c;
  }

  double _degreesToRadians(double degrees) {
    return degrees * math.pi / 180;
  }

  /// Parse comment file content
  /// Format:
  /// AUTHOR: callsign
  /// CREATED: YYYY-MM-DD HH:MM_ss
  ///
  /// Comment content here
  /// --> npub: npub1...
  /// --> signature: hex_sig
  Map<String, dynamic>? _parseComment(String content, String filename) {
    final lines = content.split('\n');
    String? author;
    String? created;
    String? npub;
    String? signature;
    final contentLines = <String>[];
    bool inContent = false;

    for (final line in lines) {
      if (line.startsWith('AUTHOR: ')) {
        author = line.substring(8).trim();
      } else if (line.startsWith('CREATED: ')) {
        created = line.substring(9).trim();
      } else if (line.startsWith('--> npub: ')) {
        npub = line.substring(10).trim();
      } else if (line.startsWith('--> signature: ')) {
        signature = line.substring(15).trim();
      } else if (line.startsWith('-->')) {
        // Other metadata, skip
      } else if (line.trim().isEmpty && author != null && created != null && !inContent) {
        inContent = true;
      } else if (inContent) {
        contentLines.add(line);
      }
    }

    if (author == null || created == null) {
      return null;
    }

    // Remove trailing empty lines from content
    while (contentLines.isNotEmpty && contentLines.last.trim().isEmpty) {
      contentLines.removeLast();
    }

    return {
      'filename': filename,
      'author': author,
      'created': created,
      'content': contentLines.join('\n').trim(),
      if (npub != null) 'npub': npub,
      if (signature != null) 'signature': signature,
    };
  }

  /// Build a file tree structure for an alert folder.
  /// Returns a nested map with file/directory names as keys.
  /// Files have {size: int, mtime: int} values.
  /// Directories end with '/' and contain nested file maps.
  Future<Map<String, dynamic>> _buildFileTree(String alertPath) async {
    final tree = <String, dynamic>{};
    final alertDir = Directory(alertPath);

    if (!await alertDir.exists()) return tree;

    await for (final entity in alertDir.list(recursive: false)) {
      final name = entity.path.split('/').last;

      if (entity is File) {
        final stat = await entity.stat();
        tree[name] = {
          'size': stat.size,
          'mtime': stat.modified.millisecondsSinceEpoch ~/ 1000,
        };
      } else if (entity is Directory) {
        // Recurse into subdirectory
        tree['$name/'] = await _buildFileTree(entity.path);
      }
    }

    return tree;
  }
}
