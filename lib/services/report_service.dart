/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import '../models/report.dart';
import '../models/report_update.dart';
import '../models/report_settings.dart';
import 'log_service.dart';

/// Service for managing reports
class ReportService {
  static final ReportService _instance = ReportService._internal();
  factory ReportService() => _instance;
  ReportService._internal();

  String? _collectionPath;
  ReportSettings _settings = ReportSettings();

  /// Initialize report service for a collection
  Future<void> initializeCollection(String collectionPath) async {
    LogService().log('ReportService: Initializing with collection path: $collectionPath');
    _collectionPath = collectionPath;

    // Ensure directories exist
    final activeDir = Directory('$collectionPath/active');
    if (!await activeDir.exists()) {
      await activeDir.create(recursive: true);
      LogService().log('ReportService: Created active directory');
    }

    final expiredDir = Directory('$collectionPath/expired');
    if (!await expiredDir.exists()) {
      await expiredDir.create(recursive: true);
      LogService().log('ReportService: Created expired directory');
    }

    // Load settings
    await _loadSettings();
  }

  /// Load settings
  Future<void> _loadSettings() async {
    if (_collectionPath == null) return;

    final settingsFile = File('$_collectionPath/extra/settings.json');
    if (await settingsFile.exists()) {
      try {
        final content = await settingsFile.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        _settings = ReportSettings.fromJson(json);
        LogService().log('ReportService: Loaded settings');
      } catch (e) {
        LogService().log('ReportService: Error loading settings: $e');
      }
    }
  }

  /// Get current settings
  ReportSettings getSettings() => _settings;

  /// Save settings
  Future<void> saveSettings(ReportSettings settings) async {
    if (_collectionPath == null) return;

    _settings = settings;

    final extraDir = Directory('$_collectionPath/extra');
    if (!await extraDir.exists()) {
      await extraDir.create(recursive: true);
    }

    final settingsFile = File('$_collectionPath/extra/settings.json');
    await settingsFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(_settings.toJson()),
      flush: true,
    );

    LogService().log('ReportService: Saved settings');
  }

  /// Load all reports
  Future<List<Report>> loadReports({bool includeExpired = false}) async {
    if (_collectionPath == null) return [];

    final reports = <Report>[];

    // Load active reports
    await _loadReportsFromDirectory('$_collectionPath/active', reports);

    // Load expired reports if requested
    if (includeExpired || _settings.showExpired) {
      await _loadReportsFromDirectory('$_collectionPath/expired', reports);
    }

    // Sort by creation date (most recent first)
    reports.sort((a, b) => b.dateTime.compareTo(a.dateTime));

    return reports;
  }

  /// Load reports from a directory
  Future<void> _loadReportsFromDirectory(String dirPath, List<Report> reports) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return;

    // Scan region folders
    final entities = await dir.list().toList();
    for (var entity in entities) {
      if (entity is Directory) {
        // Check if it's a region folder (format: 38.7_-9.1)
        final regionName = entity.path.split('/').last;
        if (RegExp(r'^-?\d+\.\d+_-?\d+\.\d+$').hasMatch(regionName)) {
          await _loadReportsFromRegion(entity.path, reports);
        }
      }
    }
  }

  /// Load reports from a region folder
  Future<void> _loadReportsFromRegion(String regionPath, List<Report> reports) async {
    final regionDir = Directory(regionPath);
    final entities = await regionDir.list().toList();

    for (var entity in entities) {
      if (entity is Directory) {
        final folderName = entity.path.split('/').last;

        // Check if it's a numbered subfolder (001, 002, etc.)
        if (RegExp(r'^\d{3}$').hasMatch(folderName)) {
          // Recursively load from subfolder
          await _loadReportsFromRegion(entity.path, reports);
        } else {
          // Load report from this folder
          final reportFile = File('${entity.path}/report.txt');
          if (await reportFile.exists()) {
            try {
              final content = await reportFile.readAsString();
              final report = Report.fromText(content, folderName);
              reports.add(report);
            } catch (e) {
              LogService().log('ReportService: Error loading report from ${entity.path}: $e');
            }
          }
        }
      }
    }
  }

  /// Load single report by folder name
  Future<Report?> loadReport(String folderName, {bool checkExpired = true}) async {
    if (_collectionPath == null) return null;

    // Try active first
    var report = await _findReport('$_collectionPath/active', folderName);
    if (report != null) return report;

    // Try expired if requested
    if (checkExpired) {
      report = await _findReport('$_collectionPath/expired', folderName);
      if (report != null) return report;
    }

    return null;
  }

  /// Find report in directory
  Future<Report?> _findReport(String basePath, String folderName) async {
    final baseDir = Directory(basePath);
    if (!await baseDir.exists()) return null;

    // Extract coordinates from folder name
    final coords = _extractCoordinates(folderName);
    if (coords == null) return null;

    final regionFolder = _getRegionFolder(coords[0], coords[1]);
    final reportPath = '$basePath/$regionFolder/$folderName';

    final reportFile = File('$reportPath/report.txt');
    if (await reportFile.exists()) {
      try {
        final content = await reportFile.readAsString();
        return Report.fromText(content, folderName);
      } catch (e) {
        LogService().log('ReportService: Error loading report: $e');
      }
    }

    return null;
  }

  /// Save report
  Future<void> saveReport(Report report, {bool isExpired = false}) async {
    if (_collectionPath == null) return;

    final baseDir = isExpired ? 'expired' : 'active';
    final regionFolder = report.regionFolder;
    final reportPath = '$_collectionPath/$baseDir/$regionFolder/${report.folderName}';

    final reportDir = Directory(reportPath);
    if (!await reportDir.exists()) {
      await reportDir.create(recursive: true);
    }

    final reportFile = File('$reportPath/report.txt');
    await reportFile.writeAsString(report.exportAsText(), flush: true);

    LogService().log('ReportService: Saved report: ${report.folderName}');
  }

  /// Create new report
  Future<Report> createReport({
    required String title,
    required String description,
    required String author,
    required double latitude,
    required double longitude,
    required ReportSeverity severity,
    required String type,
    String? address,
    String? contact,
    int? ttl,
  }) async {
    final now = DateTime.now();
    final created = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}_${now.second.toString().padLeft(2, '0')}';

    // Sanitize title for folder name
    final sanitized = _sanitizeFolderName(title);
    final folderName = '${latitude}_${longitude}_$sanitized';

    // Calculate expiration if TTL provided
    String? expires;
    final useTtl = ttl ?? _settings.defaultTtl;
    if (useTtl > 0) {
      final expDate = now.add(Duration(seconds: useTtl));
      expires = '${expDate.year}-${expDate.month.toString().padLeft(2, '0')}-${expDate.day.toString().padLeft(2, '0')} ${expDate.hour.toString().padLeft(2, '0')}:${expDate.minute.toString().padLeft(2, '0')}_${expDate.second.toString().padLeft(2, '0')}';
    }

    final report = Report(
      folderName: folderName,
      created: created,
      author: author,
      latitude: latitude,
      longitude: longitude,
      severity: severity,
      type: type,
      status: ReportStatus.open,
      address: address,
      contact: contact,
      ttl: useTtl,
      expires: expires,
      titles: {'EN': title},
      descriptions: {'EN': description},
    );

    await saveReport(report);
    return report;
  }

  /// Load updates for a report
  Future<List<ReportUpdate>> loadUpdates(String folderName) async {
    if (_collectionPath == null) return [];

    final report = await loadReport(folderName);
    if (report == null) return [];

    final regionFolder = report.regionFolder;
    final isExpired = await _isReportExpired(folderName);
    final baseDir = isExpired ? 'expired' : 'active';
    final updatesPath = '$_collectionPath/$baseDir/$regionFolder/$folderName/updates';

    final updatesDir = Directory(updatesPath);
    if (!await updatesDir.exists()) return [];

    final updates = <ReportUpdate>[];
    final entities = await updatesDir.list().toList();

    for (var entity in entities) {
      if (entity is File && entity.path.endsWith('.txt')) {
        try {
          final content = await entity.readAsString();
          final fileName = entity.path.split('/').last;
          final update = ReportUpdate.fromText(content, fileName);
          updates.add(update);
        } catch (e) {
          LogService().log('ReportService: Error loading update from ${entity.path}: $e');
        }
      }
    }

    // Sort by timestamp (most recent first)
    updates.sort((a, b) => b.dateTime.compareTo(a.dateTime));

    return updates;
  }

  /// Save update for a report
  Future<void> saveUpdate(String folderName, ReportUpdate update) async {
    if (_collectionPath == null) return;

    final report = await loadReport(folderName);
    if (report == null) return;

    final regionFolder = report.regionFolder;
    final isExpired = await _isReportExpired(folderName);
    final baseDir = isExpired ? 'expired' : 'active';
    final updatesPath = '$_collectionPath/$baseDir/$regionFolder/$folderName/updates';

    final updatesDir = Directory(updatesPath);
    if (!await updatesDir.exists()) {
      await updatesDir.create(recursive: true);
    }

    final updateFile = File('$updatesPath/${update.fileName}');
    await updateFile.writeAsString(update.exportAsText(), flush: true);

    LogService().log('ReportService: Saved update: ${update.fileName}');
  }

  /// Find nearby reports for duplicate detection
  Future<List<Report>> findNearbyReports(double latitude, double longitude, {double radiusMeters = 100}) async {
    final allReports = await loadReports();
    final nearby = <Report>[];

    for (var report in allReports) {
      final distance = _calculateDistance(latitude, longitude, report.latitude, report.longitude);
      if (distance <= radiusMeters) {
        nearby.add(report);
      }
    }

    // Sort by distance
    nearby.sort((a, b) {
      final distA = _calculateDistance(latitude, longitude, a.latitude, a.longitude);
      final distB = _calculateDistance(latitude, longitude, b.latitude, b.longitude);
      return distA.compareTo(distB);
    });

    return nearby;
  }

  /// Subscribe to a report
  Future<void> subscribe(String folderName, String npub) async {
    if (npub.isEmpty) return;

    final report = await loadReport(folderName);
    if (report == null) return;

    if (!report.subscribers.contains(npub)) {
      final updatedSubscribers = List<String>.from(report.subscribers)..add(npub);
      final updated = report.copyWith(
        subscribers: updatedSubscribers,
        subscriberCount: updatedSubscribers.length,
      );
      await saveReport(updated, isExpired: await _isReportExpired(folderName));
    }
  }

  /// Unsubscribe from a report
  Future<void> unsubscribe(String folderName, String npub) async {
    if (npub.isEmpty) return;

    final report = await loadReport(folderName);
    if (report == null) return;

    if (report.subscribers.contains(npub)) {
      final updatedSubscribers = List<String>.from(report.subscribers)..remove(npub);
      final updated = report.copyWith(
        subscribers: updatedSubscribers,
        subscriberCount: updatedSubscribers.length,
      );
      await saveReport(updated, isExpired: await _isReportExpired(folderName));
    }
  }

  /// Verify a report
  Future<void> verify(String folderName, String npub) async {
    if (npub.isEmpty) return;

    final report = await loadReport(folderName);
    if (report == null) return;

    if (!report.verifiedBy.contains(npub)) {
      final updatedVerifiedBy = List<String>.from(report.verifiedBy)..add(npub);
      final updated = report.copyWith(
        verifiedBy: updatedVerifiedBy,
        verificationCount: updatedVerifiedBy.length,
      );
      await saveReport(updated, isExpired: await _isReportExpired(folderName));
    }
  }

  /// Move report to expired
  Future<void> expireReport(String folderName) async {
    final report = await loadReport(folderName, checkExpired: false);
    if (report == null) return;

    final regionFolder = report.regionFolder;
    final activePath = '$_collectionPath/active/$regionFolder/$folderName';
    final expiredPath = '$_collectionPath/expired/$regionFolder/$folderName';

    final activeDir = Directory(activePath);
    if (await activeDir.exists()) {
      final expiredDir = Directory(expiredPath);
      if (await expiredDir.exists()) {
        await expiredDir.delete(recursive: true);
      }

      await activeDir.rename(expiredPath);
      LogService().log('ReportService: Moved report to expired: $folderName');
    }
  }

  /// Check if report is in expired folder
  Future<bool> _isReportExpired(String folderName) async {
    if (_collectionPath == null) return false;

    final coords = _extractCoordinates(folderName);
    if (coords == null) return false;

    final regionFolder = _getRegionFolder(coords[0], coords[1]);
    final expiredPath = '$_collectionPath/expired/$regionFolder/$folderName';

    return await Directory(expiredPath).exists();
  }

  /// Calculate distance between two coordinates (Haversine formula)
  double _calculateDistance(double lat1, double lon1, double lat2, double lon2) {
    const earthRadius = 6371000; // meters
    final dLat = _degreesToRadians(lat2 - lat1);
    final dLon = _degreesToRadians(lon2 - lon1);

    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_degreesToRadians(lat1)) *
            math.cos(_degreesToRadians(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);

    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadius * c;
  }

  double _degreesToRadians(double degrees) {
    return degrees * math.pi / 180;
  }

  /// Get region folder from coordinates
  String _getRegionFolder(double lat, double lon) {
    final roundedLat = (lat * 10).round() / 10;
    final roundedLon = (lon * 10).round() / 10;
    return '${roundedLat}_$roundedLon';
  }

  /// Extract coordinates from folder name
  List<double>? _extractCoordinates(String folderName) {
    final regex = RegExp(r'^(-?\d+\.\d+)_(-?\d+\.\d+)_');
    final match = regex.firstMatch(folderName);
    if (match != null) {
      final lat = double.tryParse(match.group(1)!);
      final lon = double.tryParse(match.group(2)!);
      if (lat != null && lon != null) {
        return [lat, lon];
      }
    }
    return null;
  }

  /// Sanitize text for folder name
  String _sanitizeFolderName(String text) {
    // Convert to lowercase
    var sanitized = text.toLowerCase();

    // Replace spaces and underscores with hyphens
    sanitized = sanitized.replaceAll(RegExp(r'[\s_]+'), '-');

    // Remove all non-alphanumeric characters except hyphens
    sanitized = sanitized.replaceAll(RegExp(r'[^a-z0-9-]'), '');

    // Collapse multiple consecutive hyphens
    sanitized = sanitized.replaceAll(RegExp(r'-+'), '-');

    // Remove leading/trailing hyphens
    sanitized = sanitized.replaceAll(RegExp(r'^-+|-+$'), '');

    // Truncate to 50 characters
    if (sanitized.length > 50) {
      sanitized = sanitized.substring(0, 50);
      // Remove trailing hyphen if present
      sanitized = sanitized.replaceAll(RegExp(r'-+$'), '');
    }

    return sanitized;
  }
}
