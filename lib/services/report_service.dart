/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'dart:convert';
import 'dart:math' as math;
import '../models/report.dart';
import '../models/report_update.dart';
import '../models/report_comment.dart';
import '../models/report_settings.dart';
import '../util/alert_folder_utils.dart';
import '../util/feedback_comment_utils.dart';
import '../util/feedback_folder_utils.dart';
import '../util/nostr_crypto.dart';
import '../util/nostr_event.dart';
import '../util/event_bus.dart';
import 'log_service.dart';
import 'profile_service.dart';
import 'signing_service.dart';
import 'alert_sharing_service.dart';
import 'profile_storage.dart';

/// Service for managing reports
class ReportService {
  static final ReportService _instance = ReportService._internal();
  factory ReportService() => _instance;
  ReportService._internal();

  /// Profile storage for file operations (encrypted or filesystem)
  /// IMPORTANT: This MUST be set before using the service.
  late ProfileStorage _storage;

  String? _appPath;
  ReportSettings _settings = ReportSettings();
  final ProfileService _profileService = ProfileService();
  final SigningService _signingService = SigningService();
  bool _signingInitialized = false;

  /// Whether using encrypted storage
  bool get useEncryptedStorage => _storage.isEncrypted;

  /// Set the profile storage for file operations
  /// MUST be called before initializeApp
  void setStorage(ProfileStorage storage) {
    _storage = storage;
  }

  /// Initialize report service for a collection
  Future<void> initializeApp(String appPath) async {
    LogService().log('ReportService: Initializing with collection path: $appPath');
    _appPath = appPath;

    // Ensure directories exist using storage
    await _storage.createDirectory('active');
    LogService().log('ReportService: Created active directory');

    await _storage.createDirectory('expired');
    LogService().log('ReportService: Created expired directory');

    // Load settings
    await _loadSettings();
  }

  /// Load settings
  Future<void> _loadSettings() async {
    if (_appPath == null) return;

    final content = await _storage.readString('extra/settings.json');
    if (content != null) {
      try {
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
    if (_appPath == null) return;

    _settings = settings;
    final content = const JsonEncoder.withIndent('  ').convert(_settings.toJson());

    await _storage.createDirectory('extra');
    await _storage.writeString('extra/settings.json', content);

    LogService().log('ReportService: Saved settings');
  }

  /// Load all reports
  Future<List<Report>> loadReports({bool includeExpired = false}) async {
    if (_appPath == null) return [];

    final reports = <Report>[];

    // Load active reports
    await _loadReportsFromDirectory('active', reports);

    // Load expired reports if requested
    if (includeExpired || _settings.showExpired) {
      await _loadReportsFromDirectory('expired', reports);
    }

    // Sort by creation date (most recent first)
    reports.sort((a, b) => b.dateTime.compareTo(a.dateTime));

    return reports;
  }

  /// Load reports from a directory (relative path from collection root)
  Future<void> _loadReportsFromDirectory(String dirPath, List<Report> reports) async {
    if (!await _storage.exists(dirPath)) return;

    final entries = await _storage.listDirectory(dirPath);
    for (var entry in entries) {
      if (entry.isDirectory) {
        if (RegExp(r'^-?\d+\.\d+_-?\d+\.\d+$').hasMatch(entry.name)) {
          await _loadReportsFromRegion(entry.path, reports);
        }
      }
    }
  }

  /// Load reports from a region folder (relative path from collection root)
  Future<void> _loadReportsFromRegion(String regionPath, List<Report> reports) async {
    final entries = await _storage.listDirectory(regionPath);

    for (var entry in entries) {
      if (entry.isDirectory) {
        if (RegExp(r'^\d{3}$').hasMatch(entry.name)) {
          await _loadReportsFromRegion(entry.path, reports);
        } else {
          final reportFilePath = '${entry.path}/report.txt';
          final content = await _storage.readString(reportFilePath);
          if (content != null) {
            try {
              var report = Report.fromText(content, entry.name);

              // Load feedback data if not using encrypted storage (feedback files require filesystem access)
              if (!_storage.isEncrypted) {
                final absolutePath = await _storage.getAbsolutePath(entry.path);
                if (absolutePath != null) {
                  final pointedBy = await AlertFolderUtils.readPointsFile(absolutePath, storage: _storage);
                  final verifiedByFeedback = await AlertFolderUtils.readVerificationsFile(absolutePath, storage: _storage);
                  final mergedVerifiedBy = {
                    ...report.verifiedBy,
                    ...verifiedByFeedback,
                  }.toList();

                  report = report.copyWith(
                    pointedBy: pointedBy,
                    pointCount: pointedBy.length,
                    verifiedBy: mergedVerifiedBy,
                    verificationCount: mergedVerifiedBy.length,
                  );
                }
              }

              reports.add(report);
            } catch (e) {
              LogService().log('ReportService: Error loading report from ${entry.path}: $e');
            }
          }
        }
      }
    }
  }

  /// Load single report by folder name
  Future<Report?> loadReport(String folderName, {bool checkExpired = true}) async {
    if (_appPath == null) return null;

    // Try active first
    var report = await _findReport('active', folderName);
    if (report != null) return report;

    // Try expired if requested
    if (checkExpired) {
      report = await _findReport('expired', folderName);
      if (report != null) return report;
    }

    return null;
  }

  /// Find report in directory (searches recursively, uses relative path from collection root)
  Future<Report?> _findReport(String basePath, String folderName) async {
    if (!await _storage.exists(basePath)) return null;

    // Search recursively for the folder
    final entries = await _storage.listDirectory(basePath);
    for (var entry in entries) {
      if (entry.isDirectory) {
        // Check if this is a region folder
        if (RegExp(r'^-?\d+\.\d+_-?\d+\.\d+$').hasMatch(entry.name)) {
          // Search within region folder recursively
          final regionReport = await _findReportInRegion(entry.path, folderName);
          if (regionReport != null) return regionReport;
        }
      }
    }

    return null;
  }

  /// Find report within a region folder (recursive search)
  Future<Report?> _findReportInRegion(String regionPath, String folderName) async {
    final entries = await _storage.listDirectory(regionPath);

    for (var entry in entries) {
      if (entry.isDirectory) {
        if (entry.name == folderName) {
          // Found the target folder
          final reportPath = '${entry.path}/report.txt';
          final content = await _storage.readString(reportPath);
          if (content != null) {
            try {
              var report = Report.fromText(content, folderName);

              // Load feedback data if not using encrypted storage
              if (!_storage.isEncrypted) {
                final absolutePath = await _storage.getAbsolutePath(entry.path);
                if (absolutePath != null) {
                  final pointedBy = await AlertFolderUtils.readPointsFile(absolutePath, storage: _storage);
                  final verifiedByFeedback = await AlertFolderUtils.readVerificationsFile(absolutePath, storage: _storage);
                  final mergedVerifiedBy = {
                    ...report.verifiedBy,
                    ...verifiedByFeedback,
                  }.toList();

                  report = report.copyWith(
                    pointedBy: pointedBy,
                    pointCount: pointedBy.length,
                    verifiedBy: mergedVerifiedBy,
                    verificationCount: mergedVerifiedBy.length,
                  );
                }
              }

              return report;
            } catch (e) {
              LogService().log('ReportService: Error loading report: $e');
            }
          }
        } else if (RegExp(r'^\d{3}$').hasMatch(entry.name)) {
          // Nested region subfolder - search recursively
          final nestedReport = await _findReportInRegion(entry.path, folderName);
          if (nestedReport != null) return nestedReport;
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
    if (_appPath == null) return;

    // Update lastModified timestamp if requested
    var reportToSave = report;
    if (updateLastModified) {
      reportToSave = report.copyWith(
        lastModified: DateTime.now().toUtc().toIso8601String(),
      );
    }

    final baseDir = isExpired ? 'expired' : 'active';
    final regionFolder = reportToSave.regionFolder;
    final reportPath = '$baseDir/$regionFolder/${reportToSave.folderName}';
    final reportFilePath = '$reportPath/report.txt';
    final content = reportToSave.exportAsText();

    await _storage.createDirectory(reportPath);
    await _storage.writeString(reportFilePath, content);

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

    EventBus().fire(AlertCreatedEvent(
      alertId: report.folderName,
      author: author,
      title: title,
    ));

    return report;
  }

  /// Load updates for a report
  Future<List<ReportUpdate>> loadUpdates(String folderName) async {
    if (_appPath == null) return [];

    final report = await loadReport(folderName);
    if (report == null) return [];

    final regionFolder = report.regionFolder;
    final isExpired = await _isReportExpired(folderName);
    final baseDir = isExpired ? 'expired' : 'active';
    final updatesPath = '$baseDir/$regionFolder/$folderName/updates';

    final updates = <ReportUpdate>[];

    if (!await _storage.exists(updatesPath)) return [];

    final entries = await _storage.listDirectory(updatesPath);
    for (var entry in entries) {
      if (!entry.isDirectory && entry.name.endsWith('.txt')) {
        try {
          final content = await _storage.readString(entry.path);
          if (content != null) {
            final update = ReportUpdate.fromText(content, entry.name);
            updates.add(update);
          }
        } catch (e) {
          LogService().log('ReportService: Error loading update from ${entry.path}: $e');
        }
      }
    }

    // Sort by timestamp (most recent first)
    updates.sort((a, b) => b.dateTime.compareTo(a.dateTime));

    return updates;
  }

  /// Save update for a report
  Future<void> saveUpdate(String folderName, ReportUpdate update) async {
    if (_appPath == null) return;

    final report = await loadReport(folderName);
    if (report == null) return;

    final regionFolder = report.regionFolder;
    final isExpired = await _isReportExpired(folderName);
    final baseDir = isExpired ? 'expired' : 'active';
    final updatesPath = '$baseDir/$regionFolder/$folderName/updates';
    final updateFilePath = '$updatesPath/${update.fileName}';
    final content = update.exportAsText();

    await _storage.createDirectory(updatesPath);
    await _storage.writeString(updateFilePath, content);

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
    if (npub.isEmpty || _appPath == null) return;

    final report = await loadReport(folderName);
    if (report == null) return;

    if (report.verifiedBy.contains(npub)) return;

    final isExpired = await _isReportExpired(folderName);
    final baseDir = isExpired ? 'expired' : 'active';
    final regionFolder = report.regionFolder;
    final alertRelativePath = '$baseDir/$regionFolder/$folderName';

    // For encrypted storage, just update the report directly
    if (_storage.isEncrypted) {
      final updatedVerifiedBy = List<String>.from(report.verifiedBy)..add(npub);
      final updated = report.copyWith(
        verifiedBy: updatedVerifiedBy,
        verificationCount: updatedVerifiedBy.length,
      );
      await saveReport(updated, isExpired: isExpired);
      return;
    }

    // For filesystem storage, use feedback folder utils
    final alertPath = await _storage.getAbsolutePath(alertRelativePath);
    if (alertPath == null) return;

    final event = await _buildVerificationEvent(report.apiId);
    if (event == null) {
      throw Exception('ReportService: Unable to sign verification');
    }

    final added = await FeedbackFolderUtils.addFeedbackEvent(
      alertPath,
      FeedbackFolderUtils.feedbackTypeVerifications,
      event,
      storage: _storage,
    );

    if (added) {
      final updatedVerifiedBy = List<String>.from(report.verifiedBy);
      if (!updatedVerifiedBy.contains(event.npub)) {
        updatedVerifiedBy.add(event.npub);
      }
      final updated = report.copyWith(
        verifiedBy: updatedVerifiedBy,
        verificationCount: updatedVerifiedBy.length,
      );
      await saveReport(updated, isExpired: isExpired, notifyRelays: false);
      LogService().log('ReportService: Added verification to $folderName');
    } else {
      LogService().log('ReportService: Verification not applied for $folderName');
    }
  }

  /// Point a report (call attention to it)
  /// Points are stored under feedback/points.txt (signed events).
  Future<void> pointReport(String folderName, String npub) async {
    if (npub.isEmpty || _appPath == null) return;

    final report = await loadReport(folderName);
    if (report == null) return;

    // Already pointed by this user
    if (report.pointedBy.contains(npub)) return;

    final isExpired = await _isReportExpired(folderName);
    final baseDir = isExpired ? 'expired' : 'active';
    final regionFolder = report.regionFolder;
    final alertRelativePath = '$baseDir/$regionFolder/$folderName';

    // For encrypted storage, update report directly
    if (_storage.isEncrypted) {
      final updatedPointedBy = List<String>.from(report.pointedBy)..add(npub);
      final updated = report.copyWith(
        pointedBy: updatedPointedBy,
        pointCount: updatedPointedBy.length,
      );
      await saveReport(updated, isExpired: isExpired);
      return;
    }

    // For filesystem storage, use feedback folder utils
    final alertPath = await _storage.getAbsolutePath(alertRelativePath);
    if (alertPath == null) return;

    final event = await _buildReactionEvent(
      report.apiId,
      'point',
      FeedbackFolderUtils.feedbackTypePoints,
    );

    if (event == null) {
      throw Exception('ReportService: Unable to sign point feedback');
    }

    final added = await FeedbackFolderUtils.addFeedbackEvent(
      alertPath,
      FeedbackFolderUtils.feedbackTypePoints,
      event,
      storage: _storage,
    );

    if (added) {
      final updatedPointedBy = List<String>.from(report.pointedBy);
      if (!updatedPointedBy.contains(event.npub)) {
        updatedPointedBy.add(event.npub);
      }
      final updated = report.copyWith(
        pointedBy: updatedPointedBy,
        pointCount: updatedPointedBy.length,
      );
      await saveReport(updated, isExpired: isExpired, notifyRelays: false);
      LogService().log('ReportService: Added point to $folderName');
    } else {
      LogService().log('ReportService: Point not applied for $folderName');
    }
  }

  /// Unpoint a report (remove attention call)
  /// Points are stored under feedback/points.txt (signed events).
  Future<void> unpointReport(String folderName, String npub) async {
    if (npub.isEmpty || _appPath == null) return;

    final report = await loadReport(folderName);
    if (report == null) return;

    // Not pointed by this user
    if (!report.pointedBy.contains(npub)) return;

    final isExpired = await _isReportExpired(folderName);
    final baseDir = isExpired ? 'expired' : 'active';
    final regionFolder = report.regionFolder;
    final alertRelativePath = '$baseDir/$regionFolder/$folderName';

    // For encrypted storage, update report directly
    if (_storage.isEncrypted) {
      final updatedPointedBy = List<String>.from(report.pointedBy)..remove(npub);
      final updated = report.copyWith(
        pointedBy: updatedPointedBy,
        pointCount: updatedPointedBy.length,
      );
      await saveReport(updated, isExpired: isExpired);
      return;
    }

    // For filesystem storage, use feedback folder utils
    final alertPath = await _storage.getAbsolutePath(alertRelativePath);
    if (alertPath == null) return;

    final removed = await FeedbackFolderUtils.removeFeedbackEvent(
      alertPath,
      FeedbackFolderUtils.feedbackTypePoints,
      npub,
      storage: _storage,
    );

    if (removed) {
      final updatedPointedBy = List<String>.from(report.pointedBy)..remove(npub);
      final updated = report.copyWith(
        pointedBy: updatedPointedBy,
        pointCount: updatedPointedBy.length,
      );
      await saveReport(updated, isExpired: isExpired, notifyRelays: false);
      LogService().log('ReportService: Removed point from $folderName');
    } else {
      LogService().log('ReportService: Point removal not applied for $folderName');
    }
  }

  /// Load comments for a report
  Future<List<ReportComment>> loadComments(String folderName) async {
    if (_appPath == null) return [];

    final report = await loadReport(folderName);
    if (report == null) return [];

    final regionFolder = report.regionFolder;
    final isExpired = await _isReportExpired(folderName);
    final baseDir = isExpired ? 'expired' : 'active';
    final alertRelativePath = '$baseDir/$regionFolder/$folderName';

    final comments = <ReportComment>[];

    // For encrypted storage, load comments directly
    if (_storage.isEncrypted) {
      final commentsPath = '$alertRelativePath/feedback/comments';
      if (await _storage.exists(commentsPath)) {
        final entries = await _storage.listDirectory(commentsPath);
        for (var entry in entries) {
          if (!entry.isDirectory && entry.name.endsWith('.txt')) {
            try {
              final content = await _storage.readString(entry.path);
              if (content != null) {
                final comment = ReportComment.fromText(content, entry.name);
                comments.add(comment);
              }
            } catch (e) {
              LogService().log('ReportService: Error loading comment from ${entry.path}: $e');
            }
          }
        }
      }
    } else {
      // For filesystem storage, use feedback comment utils
      final alertPath = await _storage.getAbsolutePath(alertRelativePath);
      if (alertPath != null) {
        final feedbackComments = await FeedbackCommentUtils.loadComments(alertPath, storage: _storage);
        comments.addAll(feedbackComments.map((comment) {
          return ReportComment(
            id: comment.id,
            author: comment.author,
            content: comment.content,
            created: comment.created,
            npub: comment.npub,
          );
        }));
      }
    }

    // Sort by timestamp (oldest first for comments)
    comments.sort((a, b) => a.dateTime.compareTo(b.dateTime));

    return comments;
  }

  /// Add a comment to a report
  Future<ReportComment> addComment(String folderName, String author, String commentContent, {String? npub}) async {
    if (_appPath == null) {
      throw Exception('Collection not initialized');
    }

    final report = await loadReport(folderName);
    if (report == null) {
      throw Exception('Report not found');
    }

    final regionFolder = report.regionFolder;
    final isExpired = await _isReportExpired(folderName);
    final baseDir = isExpired ? 'expired' : 'active';
    final alertRelativePath = '$baseDir/$regionFolder/$folderName';
    final profile = _profileService.getProfile();
    final resolvedNpub = (npub != null && npub.isNotEmpty) ? npub : profile.npub;
    final signature = await _signComment(report.apiId, commentContent);

    ReportComment comment;

    // For encrypted storage, write comments directly
    if (_storage.isEncrypted) {
      final now = DateTime.now();
      final created = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}_${now.second.toString().padLeft(2, '0')}';
      final fileName = FeedbackCommentUtils.generateCommentFilename(now, author);
      final commentContentText = FeedbackCommentUtils.formatCommentFile(
        author: author,
        timestamp: created,
        content: commentContent,
        npub: resolvedNpub,
        signature: signature,
      );

      final commentsPath = '$alertRelativePath/feedback/comments';
      await _storage.createDirectory(commentsPath);
      await _storage.writeString('$commentsPath/$fileName', commentContentText);

      comment = ReportComment(
        id: fileName.replaceAll('.txt', ''),
        author: author,
        content: commentContent,
        created: created,
        npub: resolvedNpub,
      );
    } else {
      // For filesystem storage, use feedback comment utils
      final alertPath = await _storage.getAbsolutePath(alertRelativePath);
      if (alertPath == null) {
        throw Exception('Unable to resolve alert path');
      }

      final commentId = await FeedbackCommentUtils.writeComment(
        contentPath: alertPath,
        author: author,
        content: commentContent,
        npub: resolvedNpub,
        signature: signature,
        storage: _storage,
      );

      final commentFilePath = '${FeedbackFolderUtils.buildCommentsPath(alertPath)}/$commentId.txt';
      final fileContent = await File(commentFilePath).readAsString();
      comment = ReportComment.fromText(fileContent, '$commentId.txt');
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
    final activePath = 'active/$regionFolder/$folderName';
    final expiredPath = 'expired/$regionFolder/$folderName';

    if (await _storage.exists(activePath)) {
      // Copy contents from active to expired, then delete active
      // ProfileStorage doesn't support rename/move, so we copy and delete
      await _copyDirectoryContents(activePath, expiredPath);
      await _storage.deleteDirectory(activePath);
      LogService().log('ReportService: Moved report to expired: $folderName');
    }
  }

  /// Copy directory contents recursively (for moving reports)
  Future<void> _copyDirectoryContents(String sourcePath, String destPath) async {
    await _storage.createDirectory(destPath);

    final entries = await _storage.listDirectory(sourcePath);
    for (var entry in entries) {
      final destEntryPath = '$destPath/${entry.name}';
      if (entry.isDirectory) {
        await _copyDirectoryContents(entry.path, destEntryPath);
      } else {
        final content = await _storage.readBytes(entry.path);
        if (content != null) {
          await _storage.writeBytes(destEntryPath, content);
        }
      }
    }
  }

  /// Check if report is in expired folder (searches recursively)
  Future<bool> _isReportExpired(String folderName) async {
    if (_appPath == null) return false;

    if (!await _storage.exists('expired')) return false;

    // Search recursively for the folder in expired
    final entries = await _storage.listDirectory('expired');
    for (var entry in entries) {
      if (entry.isDirectory) {
        if (RegExp(r'^-?\d+\.\d+_-?\d+\.\d+$').hasMatch(entry.name)) {
          final regionEntries = await _storage.listDirectory(entry.path);
          for (var regionEntry in regionEntries) {
            if (regionEntry.isDirectory && regionEntry.name == folderName) {
              return true;
            }
          }
        }
      }
    }
    return false;
  }

  Future<bool> _ensureSigningInitialized() async {
    if (_signingInitialized) return true;
    try {
      await _signingService.initialize();
      _signingInitialized = true;
      return true;
    } catch (e) {
      LogService().log('ReportService: Signing initialization failed: $e');
      return false;
    }
  }

  Future<NostrEvent?> _buildReactionEvent(
    String alertId,
    String actionName,
    String feedbackType,
  ) async {
    final profile = _profileService.getProfile();
    if (profile.callsign.isEmpty) return null;

    if (!await _ensureSigningInitialized()) return null;
    if (!_signingService.canSign(profile)) return null;

    final pubkeyHex = NostrCrypto.decodeNpub(profile.npub);
    final event = NostrEvent(
      pubkey: pubkeyHex,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      kind: NostrEventKind.reaction,
      tags: [
        ['content_type', 'alert'],
        ['content_id', alertId],
        ['action', actionName],
        ['owner', profile.callsign],
        ['type', feedbackType],
      ],
      content: actionName,
    );

    return _signingService.signEvent(event, profile);
  }

  Future<NostrEvent?> _buildVerificationEvent(String alertId) async {
    final profile = _profileService.getProfile();
    if (profile.callsign.isEmpty) return null;

    if (!await _ensureSigningInitialized()) return null;
    if (!_signingService.canSign(profile)) return null;

    final pubkeyHex = NostrCrypto.decodeNpub(profile.npub);
    final event = NostrEvent(
      pubkey: pubkeyHex,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      kind: NostrEventKind.applicationSpecificData,
      tags: [
        ['content_type', 'alert'],
        ['content_id', alertId],
        ['action', 'verify'],
        ['owner', profile.callsign],
      ],
      content: 'verify',
    );

    return _signingService.signEvent(event, profile);
  }

  Future<String?> _signComment(String alertId, String comment) async {
    final profile = _profileService.getProfile();
    if (profile.callsign.isEmpty) return null;

    if (!await _ensureSigningInitialized()) return null;
    if (!_signingService.canSign(profile)) return null;

    final pubkeyHex = NostrCrypto.decodeNpub(profile.npub);
    final event = NostrEvent(
      pubkey: pubkeyHex,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      kind: NostrEventKind.textNote,
      tags: [
        ['content_type', 'alert'],
        ['content_id', alertId],
        ['action', 'comment'],
        ['owner', profile.callsign],
      ],
      content: comment,
    );

    final signed = await _signingService.signEvent(event, profile);
    return signed?.sig;
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
