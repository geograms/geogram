/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show kIsWeb;
import '../models/report.dart';
import '../models/report_update.dart';
import '../models/report_comment.dart';
import '../models/report_settings.dart';
import '../platform/file_system_service.dart';
import '../util/alert_folder_utils.dart';
import 'log_service.dart';
import 'alert_sharing_service.dart';

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

    if (kIsWeb) {
      // Use virtual file system for web
      final fs = FileSystemService.instance;
      if (!await fs.exists('$collectionPath/active')) {
        await fs.createDirectory('$collectionPath/active', recursive: true);
        LogService().log('ReportService: Created active directory (web)');
      }
      if (!await fs.exists('$collectionPath/expired')) {
        await fs.createDirectory('$collectionPath/expired', recursive: true);
        LogService().log('ReportService: Created expired directory (web)');
      }
    } else {
      // Native file system
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
    }

    // Load settings
    await _loadSettings();
  }

  /// Load settings
  Future<void> _loadSettings() async {
    if (_collectionPath == null) return;

    final settingsPath = '$_collectionPath/extra/settings.json';

    if (kIsWeb) {
      final fs = FileSystemService.instance;
      if (await fs.exists(settingsPath)) {
        try {
          final content = await fs.readAsString(settingsPath);
          final json = jsonDecode(content) as Map<String, dynamic>;
          _settings = ReportSettings.fromJson(json);
          LogService().log('ReportService: Loaded settings (web)');
        } catch (e) {
          LogService().log('ReportService: Error loading settings: $e');
        }
      }
    } else {
      final settingsFile = File(settingsPath);
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
  }

  /// Get current settings
  ReportSettings getSettings() => _settings;

  /// Save settings
  Future<void> saveSettings(ReportSettings settings) async {
    if (_collectionPath == null) return;

    _settings = settings;
    final extraPath = '$_collectionPath/extra';
    final settingsPath = '$extraPath/settings.json';
    final content = const JsonEncoder.withIndent('  ').convert(_settings.toJson());

    if (kIsWeb) {
      final fs = FileSystemService.instance;
      if (!await fs.exists(extraPath)) {
        await fs.createDirectory(extraPath, recursive: true);
      }
      await fs.writeAsString(settingsPath, content);
    } else {
      final extraDir = Directory(extraPath);
      if (!await extraDir.exists()) {
        await extraDir.create(recursive: true);
      }
      final settingsFile = File(settingsPath);
      await settingsFile.writeAsString(content, flush: true);
    }

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
    if (kIsWeb) {
      final fs = FileSystemService.instance;
      if (!await fs.exists(dirPath)) return;

      final entities = await fs.list(dirPath);
      for (var entity in entities) {
        if (entity.isDirectory) {
          final regionName = entity.path.split('/').last;
          if (RegExp(r'^-?\d+\.\d+_-?\d+\.\d+$').hasMatch(regionName)) {
            await _loadReportsFromRegion(entity.path, reports);
          }
        }
      }
    } else {
      final dir = Directory(dirPath);
      if (!await dir.exists()) return;

      final entities = await dir.list().toList();
      for (var entity in entities) {
        if (entity is Directory) {
          final regionName = entity.path.split('/').last;
          if (RegExp(r'^-?\d+\.\d+_-?\d+\.\d+$').hasMatch(regionName)) {
            await _loadReportsFromRegion(entity.path, reports);
          }
        }
      }
    }
  }

  /// Load reports from a region folder
  Future<void> _loadReportsFromRegion(String regionPath, List<Report> reports) async {
    if (kIsWeb) {
      final fs = FileSystemService.instance;
      final entities = await fs.list(regionPath);

      for (var entity in entities) {
        if (entity.isDirectory) {
          final folderName = entity.path.split('/').last;

          if (RegExp(r'^\d{3}$').hasMatch(folderName)) {
            await _loadReportsFromRegion(entity.path, reports);
          } else {
            final reportPath = '${entity.path}/report.txt';
            if (await fs.exists(reportPath)) {
              try {
                final content = await fs.readAsString(reportPath);
                final report = Report.fromText(content, folderName);
                reports.add(report);
              } catch (e) {
                LogService().log('ReportService: Error loading report from ${entity.path}: $e');
              }
            }
          }
        }
      }
    } else {
      final regionDir = Directory(regionPath);
      final entities = await regionDir.list().toList();

      for (var entity in entities) {
        if (entity is Directory) {
          final folderName = entity.path.split('/').last;

          if (RegExp(r'^\d{3}$').hasMatch(folderName)) {
            await _loadReportsFromRegion(entity.path, reports);
          } else {
            final reportFile = File('${entity.path}/report.txt');
            if (await reportFile.exists()) {
              try {
                final content = await reportFile.readAsString();
                var report = Report.fromText(content, folderName);

                // Read points from points.txt
                final pointedBy = await AlertFolderUtils.readPointsFile(entity.path);
                if (pointedBy.isNotEmpty) {
                  report = report.copyWith(
                    pointedBy: pointedBy,
                    pointCount: pointedBy.length,
                  );
                }

                reports.add(report);
              } catch (e) {
                LogService().log('ReportService: Error loading report from ${entity.path}: $e');
              }
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

  /// Find report in directory (searches recursively)
  Future<Report?> _findReport(String basePath, String folderName) async {
    if (kIsWeb) {
      final fs = FileSystemService.instance;
      if (!await fs.exists(basePath)) return null;

      // Search recursively for the folder
      final entities = await fs.list(basePath);
      for (var entity in entities) {
        if (entity.isDirectory) {
          final dirName = entity.path.split('/').last;
          // Check if this is a region folder
          if (RegExp(r'^-?\d+\.\d+_-?\d+\.\d+$').hasMatch(dirName)) {
            // Search within region folder
            final regionEntities = await fs.list(entity.path);
            for (var regionEntity in regionEntities) {
              if (regionEntity.isDirectory) {
                final alertDirName = regionEntity.path.split('/').last;
                if (alertDirName == folderName) {
                  final reportPath = '${regionEntity.path}/report.txt';
                  if (await fs.exists(reportPath)) {
                    try {
                      final content = await fs.readAsString(reportPath);
                      return Report.fromText(content, folderName);
                    } catch (e) {
                      LogService().log('ReportService: Error loading report: $e');
                    }
                  }
                }
              }
            }
          }
        }
      }
    } else {
      final baseDir = Directory(basePath);
      if (!await baseDir.exists()) return null;

      // Search recursively for the folder
      await for (final entity in baseDir.list(recursive: true)) {
        if (entity is Directory && entity.path.endsWith('/$folderName')) {
          final reportFile = File('${entity.path}/report.txt');
          if (await reportFile.exists()) {
            try {
              final content = await reportFile.readAsString();
              var report = Report.fromText(content, folderName);

              // Read points from points.txt
              final pointedBy = await AlertFolderUtils.readPointsFile(entity.path);
              if (pointedBy.isNotEmpty) {
                report = report.copyWith(
                  pointedBy: pointedBy,
                  pointCount: pointedBy.length,
                );
              }

              return report;
            } catch (e) {
              LogService().log('ReportService: Error loading report: $e');
            }
          }
        }
      }
    }

    return null;
  }

  /// Save report
  ///
  /// If [notifyRelays] is true and the report has already been shared,
  /// it will send an update to the stations (using the same d-tag for replacement).
  /// If [updateLastModified] is true (default), the lastModified timestamp is updated.
  Future<void> saveReport(
    Report report, {
    bool isExpired = false,
    bool notifyRelays = true,
    bool updateLastModified = true,
  }) async {
    if (_collectionPath == null) return;

    // Update lastModified timestamp if requested
    var reportToSave = report;
    if (updateLastModified) {
      reportToSave = report.copyWith(
        lastModified: DateTime.now().toUtc().toIso8601String(),
      );
    }

    final baseDir = isExpired ? 'expired' : 'active';
    final regionFolder = reportToSave.regionFolder;
    final reportPath = '$_collectionPath/$baseDir/$regionFolder/${reportToSave.folderName}';
    final reportFilePath = '$reportPath/report.txt';
    final content = reportToSave.exportAsText();

    if (kIsWeb) {
      final fs = FileSystemService.instance;
      if (!await fs.exists(reportPath)) {
        await fs.createDirectory(reportPath, recursive: true);
      }
      await fs.writeAsString(reportFilePath, content);
    } else {
      final reportDir = Directory(reportPath);
      if (!await reportDir.exists()) {
        await reportDir.create(recursive: true);
      }
      final reportFile = File(reportFilePath);
      await reportFile.writeAsString(content, flush: true);
    }

    LogService().log('ReportService: Saved report: ${reportToSave.folderName}');

    // Notify stations of update if this is an existing alert
    if (notifyRelays && reportToSave.nostrEventId != null) {
      try {
        final alertService = AlertSharingService();
        final result = await alertService.shareAlert(reportToSave);

        if (result.anySuccess) {
          LogService().log(
              'ReportService: Updated alert on ${result.confirmed} station(s)');
        }
      } catch (e) {
        LogService().log('ReportService: Error updating alert on stations: $e');
      }
    }
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
    // Use timestamp-based folder name: YYYY-MM-DD_HH-MM_sanitized-title
    final folderName = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}-${now.minute.toString().padLeft(2, '0')}_$sanitized';

    // Calculate expiration if TTL provided
    String? expires;
    final useTtl = ttl ?? _settings.defaultTtl;
    if (useTtl > 0) {
      final expDate = now.add(Duration(seconds: useTtl));
      expires = '${expDate.year}-${expDate.month.toString().padLeft(2, '0')}-${expDate.day.toString().padLeft(2, '0')} ${expDate.hour.toString().padLeft(2, '0')}:${expDate.minute.toString().padLeft(2, '0')}_${expDate.second.toString().padLeft(2, '0')}';
    }

    var report = Report(
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
      lastModified: now.toUtc().toIso8601String(),
    );

    // Sign the report and create NOSTR event BEFORE saving
    final alertService = AlertSharingService();
    final signResult = await alertService.signReportAndCreateEvent(report);

    if (signResult == null) {
      // Failed to sign - save unsigned report (should not happen in normal use)
      LogService().log('ReportService: WARNING - Failed to sign report, saving without NOSTR data');
      await saveReport(report, notifyRelays: false, updateLastModified: false);
      return report;
    }

    // Use the signed report (has npub + signature in metadata)
    report = signResult.report;

    // Save the signed report first (don't update lastModified, already set on creation)
    await saveReport(report, notifyRelays: false, updateLastModified: false);

    // Share to stations using the pre-created event
    try {
      final stationUrls = alertService.getRelayUrls();
      if (stationUrls.isNotEmpty) {
        final results = <AlertSendResult>[];
        int confirmed = 0;
        int failed = 0;

        for (final stationUrl in stationUrls) {
          final result = await alertService.sendEventToRelay(signResult.event, stationUrl);
          results.add(result);
          if (result.success) {
            confirmed++;
          } else {
            failed++;
          }
        }

        // Update report with station share status and event ID
        for (final sendResult in results) {
          report = alertService.updateStationShareStatus(
            report,
            sendResult.stationUrl,
            sendResult.success
                ? StationShareStatusType.confirmed
                : StationShareStatusType.failed,
            nostrEventId: signResult.event.id,
          );
        }

        // Re-save with station status (don't update lastModified)
        await saveReport(report, notifyRelays: false, updateLastModified: false);
        LogService().log('ReportService: Alert shared to $confirmed station(s), $failed failed');
      }
    } catch (e) {
      LogService().log('ReportService: Error sharing alert to stations: $e');
    }

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

    final updates = <ReportUpdate>[];

    if (kIsWeb) {
      final fs = FileSystemService.instance;
      if (!await fs.exists(updatesPath)) return [];

      final entities = await fs.list(updatesPath);
      for (var entity in entities) {
        if (entity.isFile && entity.path.endsWith('.txt')) {
          try {
            final content = await fs.readAsString(entity.path);
            final fileName = entity.path.split('/').last;
            final update = ReportUpdate.fromText(content, fileName);
            updates.add(update);
          } catch (e) {
            LogService().log('ReportService: Error loading update from ${entity.path}: $e');
          }
        }
      }
    } else {
      final updatesDir = Directory(updatesPath);
      if (!await updatesDir.exists()) return [];

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
    final updateFilePath = '$updatesPath/${update.fileName}';
    final content = update.exportAsText();

    if (kIsWeb) {
      final fs = FileSystemService.instance;
      if (!await fs.exists(updatesPath)) {
        await fs.createDirectory(updatesPath, recursive: true);
      }
      await fs.writeAsString(updateFilePath, content);
    } else {
      final updatesDir = Directory(updatesPath);
      if (!await updatesDir.exists()) {
        await updatesDir.create(recursive: true);
      }
      final updateFile = File(updateFilePath);
      await updateFile.writeAsString(content, flush: true);
    }

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

  /// Point a report (call attention to it)
  /// Points are stored in points.txt file (one npub per line)
  Future<void> pointReport(String folderName, String npub) async {
    if (npub.isEmpty || _collectionPath == null) return;

    final report = await loadReport(folderName);
    if (report == null) return;

    // Already pointed by this user
    if (report.pointedBy.contains(npub)) return;

    final isExpired = await _isReportExpired(folderName);
    final baseDir = isExpired ? 'expired' : 'active';
    final regionFolder = report.regionFolder;
    final alertPath = '$_collectionPath/$baseDir/$regionFolder/$folderName';

    if (kIsWeb) {
      // Web: Update report object and save (points stored in memory only)
      final updatedPointedBy = List<String>.from(report.pointedBy)..add(npub);
      final updated = report.copyWith(
        pointedBy: updatedPointedBy,
        pointCount: updatedPointedBy.length,
      );
      await saveReport(updated, isExpired: isExpired);
    } else {
      // Native: Write to points.txt
      final added = await AlertFolderUtils.addPointToFile(alertPath, npub);
      if (added) {
        // Update lastModified on the report
        await saveReport(report, isExpired: isExpired, notifyRelays: false);
        LogService().log('ReportService: Added point to $folderName');
      }
    }
  }

  /// Unpoint a report (remove attention call)
  /// Points are stored in points.txt file (one npub per line)
  Future<void> unpointReport(String folderName, String npub) async {
    if (npub.isEmpty || _collectionPath == null) return;

    final report = await loadReport(folderName);
    if (report == null) return;

    // Not pointed by this user
    if (!report.pointedBy.contains(npub)) return;

    final isExpired = await _isReportExpired(folderName);
    final baseDir = isExpired ? 'expired' : 'active';
    final regionFolder = report.regionFolder;
    final alertPath = '$_collectionPath/$baseDir/$regionFolder/$folderName';

    if (kIsWeb) {
      // Web: Update report object and save (points stored in memory only)
      final updatedPointedBy = List<String>.from(report.pointedBy)..remove(npub);
      final updated = report.copyWith(
        pointedBy: updatedPointedBy,
        pointCount: updatedPointedBy.length,
      );
      await saveReport(updated, isExpired: isExpired);
    } else {
      // Native: Remove from points.txt
      final removed = await AlertFolderUtils.removePointFromFile(alertPath, npub);
      if (removed) {
        // Update lastModified on the report
        await saveReport(report, isExpired: isExpired, notifyRelays: false);
        LogService().log('ReportService: Removed point from $folderName');
      }
    }
  }

  /// Load comments for a report
  Future<List<ReportComment>> loadComments(String folderName) async {
    if (_collectionPath == null) return [];

    final report = await loadReport(folderName);
    if (report == null) return [];

    final regionFolder = report.regionFolder;
    final isExpired = await _isReportExpired(folderName);
    final baseDir = isExpired ? 'expired' : 'active';
    final commentsPath = '$_collectionPath/$baseDir/$regionFolder/$folderName/comments';

    final comments = <ReportComment>[];

    if (kIsWeb) {
      final fs = FileSystemService.instance;
      if (!await fs.exists(commentsPath)) return [];

      final entities = await fs.list(commentsPath);
      for (var entity in entities) {
        if (entity.isFile && entity.path.endsWith('.txt')) {
          try {
            final content = await fs.readAsString(entity.path);
            final fileName = entity.path.split('/').last;
            final comment = ReportComment.fromText(content, fileName);
            comments.add(comment);
          } catch (e) {
            LogService().log('ReportService: Error loading comment from ${entity.path}: $e');
          }
        }
      }
    } else {
      final commentsDir = Directory(commentsPath);
      if (!await commentsDir.exists()) return [];

      final entities = await commentsDir.list().toList();
      for (var entity in entities) {
        if (entity is File && entity.path.endsWith('.txt')) {
          try {
            final content = await entity.readAsString();
            final fileName = entity.path.split('/').last;
            final comment = ReportComment.fromText(content, fileName);
            comments.add(comment);
          } catch (e) {
            LogService().log('ReportService: Error loading comment from ${entity.path}: $e');
          }
        }
      }
    }

    // Sort by timestamp (oldest first for comments)
    comments.sort((a, b) => a.dateTime.compareTo(b.dateTime));

    return comments;
  }

  /// Add a comment to a report
  Future<ReportComment> addComment(String folderName, String author, String commentContent, {String? npub}) async {
    if (_collectionPath == null) {
      throw Exception('Collection not initialized');
    }

    final report = await loadReport(folderName);
    if (report == null) {
      throw Exception('Report not found');
    }

    final now = DateTime.now();
    final created = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}_${now.second.toString().padLeft(2, '0')}';
    final id = '${now.millisecondsSinceEpoch}';

    final comment = ReportComment(
      id: id,
      author: author,
      content: commentContent,
      created: created,
      npub: npub,
    );

    final regionFolder = report.regionFolder;
    final isExpired = await _isReportExpired(folderName);
    final baseDir = isExpired ? 'expired' : 'active';
    final commentsPath = '$_collectionPath/$baseDir/$regionFolder/$folderName/comments';
    final commentFilePath = '$commentsPath/$id.txt';
    final fileContent = comment.exportAsText();

    if (kIsWeb) {
      final fs = FileSystemService.instance;
      if (!await fs.exists(commentsPath)) {
        await fs.createDirectory(commentsPath, recursive: true);
      }
      await fs.writeAsString(commentFilePath, fileContent);
    } else {
      final commentsDir = Directory(commentsPath);
      if (!await commentsDir.exists()) {
        await commentsDir.create(recursive: true);
      }
      final commentFile = File(commentFilePath);
      await commentFile.writeAsString(fileContent, flush: true);
    }

    // Update the report's lastModified timestamp
    await saveReport(report, isExpired: isExpired, notifyRelays: false);

    LogService().log('ReportService: Added comment to $folderName');

    return comment;
  }

  /// Move report to expired
  Future<void> expireReport(String folderName) async {
    final report = await loadReport(folderName, checkExpired: false);
    if (report == null) return;

    final regionFolder = report.regionFolder;
    final activePath = '$_collectionPath/active/$regionFolder/$folderName';
    final expiredPath = '$_collectionPath/expired/$regionFolder/$folderName';

    if (kIsWeb) {
      final fs = FileSystemService.instance;
      if (await fs.exists(activePath)) {
        if (await fs.exists(expiredPath)) {
          await fs.delete(expiredPath, recursive: true);
        }
        await fs.move(activePath, expiredPath);
        LogService().log('ReportService: Moved report to expired (web): $folderName');
      }
    } else {
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
  }

  /// Check if report is in expired folder (searches recursively)
  Future<bool> _isReportExpired(String folderName) async {
    if (_collectionPath == null) return false;

    final expiredBasePath = '$_collectionPath/expired';

    if (kIsWeb) {
      final fs = FileSystemService.instance;
      if (!await fs.exists(expiredBasePath)) return false;

      // Search recursively for the folder in expired
      final entities = await fs.list(expiredBasePath);
      for (var entity in entities) {
        if (entity.isDirectory) {
          final dirName = entity.path.split('/').last;
          if (RegExp(r'^-?\d+\.\d+_-?\d+\.\d+$').hasMatch(dirName)) {
            final regionEntities = await fs.list(entity.path);
            for (var regionEntity in regionEntities) {
              if (regionEntity.isDirectory) {
                final alertDirName = regionEntity.path.split('/').last;
                if (alertDirName == folderName) {
                  return true;
                }
              }
            }
          }
        }
      }
      return false;
    } else {
      final expiredDir = Directory(expiredBasePath);
      if (!await expiredDir.exists()) return false;

      await for (final entity in expiredDir.list(recursive: true)) {
        if (entity is Directory && entity.path.endsWith('/$folderName')) {
          return true;
        }
      }
      return false;
    }
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

    // Truncate to 100 characters
    if (sanitized.length > 100) {
      sanitized = sanitized.substring(0, 100);
      // Remove trailing hyphen if present
      sanitized = sanitized.replaceAll(RegExp(r'-+$'), '');
    }

    return sanitized;
  }
}
