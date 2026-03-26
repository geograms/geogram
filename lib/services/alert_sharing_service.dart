/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Service for sharing alerts to relays using signed NOSTR events.
 * Uses NIP-78 (kind 30078) for application-specific data.
 */

import 'dart:async';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import '../models/report.dart';
import '../util/nostr_event.dart';
import '../util/nostr_crypto.dart';
import 'log_service.dart';
import 'profile_service.dart';
import 'signing_service.dart';
import 'websocket_service.dart';
import 'station_service.dart';
import 'storage_config.dart';

/// Result of sending an alert to a station
class AlertSendResult {
  final String stationUrl;
  final bool success;
  final String? eventId;
  final String? message;

  AlertSendResult({
    required this.stationUrl,
    required this.success,
    this.eventId,
    this.message,
  });

  @override
  String toString() =>
      'AlertSendResult($stationUrl, success: $success, eventId: ${eventId?.substring(0, 8)}...)';
}

/// Summary of multi-station alert sharing
class AlertShareSummary {
  final int confirmed;
  final int failed;
  final int skipped;
  final String? eventId;
  final List<AlertSendResult> results;

  AlertShareSummary({
    required this.confirmed,
    required this.failed,
    required this.skipped,
    this.eventId,
    required this.results,
  });

  bool get anySuccess => confirmed > 0;
  bool get allSuccess => failed == 0 && skipped == 0;

  @override
  String toString() =>
      'AlertShareSummary(confirmed: $confirmed, failed: $failed, skipped: $skipped)';
}

/// Service for sharing alerts to relays using signed NOSTR events
class AlertSharingService {
  static final AlertSharingService _instance = AlertSharingService._internal();
  factory AlertSharingService() => _instance;
  AlertSharingService._internal();

  final ProfileService _profileService = ProfileService();
  final SigningService _signingService = SigningService();
  final WebSocketService _webSocketService = WebSocketService();
  final StationService _stationService = StationService();

  /// Sign a report and create a NOSTR alert event
  ///
  /// Returns a tuple of (signedReport, nostrEvent) where:
  /// - signedReport has npub and signature in metadata
  /// - nostrEvent is the signed NOSTR event ready to send
  ///
  /// Returns null if signing fails.
  Future<({Report report, NostrEvent event})?> signReportAndCreateEvent(Report report) async {
    try {
      // Get profile
      final profile = _profileService.getProfile();
      if (profile.npub.isEmpty) {
        LogService().log('AlertSharingService: No npub in profile');
        return null;
      }

      // Initialize signing service
      await _signingService.initialize();
      if (!_signingService.canSign(profile)) {
        LogService().log('AlertSharingService: Cannot sign (no nsec or extension)');
        return null;
      }

      // Get current Unix timestamp for signing
      final signedAtUnix = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      // First, add npub and signed_at to the report metadata (before creating event)
      final updatedMetadata = Map<String, String>.from(report.metadata);
      updatedMetadata['npub'] = profile.npub;
      updatedMetadata['signed_at'] = signedAtUnix.toString();
      var signedReport = report.copyWith(metadata: updatedMetadata);

      // Create the NOSTR alert event with the report content
      final pubkeyHex = NostrCrypto.decodeNpub(profile.npub);
      final event = NostrEvent.alert(
        pubkeyHex: pubkeyHex,
        report: signedReport,
        createdAt: signedAtUnix,  // Use same timestamp for NOSTR event
      );

      // Calculate ID and sign the event
      event.calculateId();
      final signedEvent = await _signingService.signEvent(event, profile);

      if (signedEvent == null || signedEvent.sig == null) {
        LogService().log('AlertSharingService: Failed to sign NOSTR event');
        return null;
      }

      // Add the event signature to report metadata
      updatedMetadata['signature'] = signedEvent.sig!;
      signedReport = signedReport.copyWith(metadata: updatedMetadata);

      LogService().log('AlertSharingService: Report signed with npub ${profile.npub.substring(0, 16)}...');

      return (report: signedReport, event: signedEvent);
    } catch (e) {
      LogService().log('AlertSharingService: Error signing report: $e');
      return null;
    }
  }

  /// Share alert to all configured stations
  ///
  /// Returns a summary with confirmed/failed/skipped counts.
  /// Confirmed stations are skipped on subsequent calls.
  Future<AlertShareSummary> shareAlert(Report report) async {
    final stationUrls = getRelayUrls();
    if (stationUrls.isEmpty) {
      LogService().log('AlertSharingService: No stations configured');
      return AlertShareSummary(
        confirmed: 0,
        failed: 0,
        skipped: 0,
        results: [],
      );
    }

    return await shareAlertToRelays(report, stationUrls);
  }

  /// Share alert to specific stations
  ///
  /// Creates one signed NOSTR event and sends it to all stations.
  /// Tracks status per station in the report.
  Future<AlertShareSummary> shareAlertToRelays(
    Report report,
    List<String> stationUrls,
  ) async {
    if (stationUrls.isEmpty) {
      return AlertShareSummary(
        confirmed: 0,
        failed: 0,
        skipped: 0,
        results: [],
      );
    }

    // Create signed event once (same event for all stations)
    final event = await createAlertEvent(report);
    if (event == null) {
      LogService().log('AlertSharingService: Failed to create alert event');
      return AlertShareSummary(
        confirmed: 0,
        failed: stationUrls.length,
        skipped: 0,
        results: stationUrls
            .map((url) => AlertSendResult(
                  stationUrl: url,
                  success: false,
                  message: 'Failed to create event',
                ))
            .toList(),
      );
    }

    final results = <AlertSendResult>[];
    int confirmed = 0;
    int failed = 0;
    int skipped = 0;

    // Send to each station
    for (final stationUrl in stationUrls) {
      // Check if already confirmed for this station
      if (!report.needsSharingToRelay(stationUrl)) {
        LogService().log('AlertSharingService: Skipping $stationUrl (already confirmed)');
        skipped++;
        results.add(AlertSendResult(
          stationUrl: stationUrl,
          success: true,
          eventId: event.id,
          message: 'Already confirmed',
        ));
        continue;
      }

      // Send to station
      final result = await sendEventToRelay(event, stationUrl);
      results.add(result);

      if (result.success) {
        confirmed++;

        // Upload photos after successful alert share
        final photosUploaded = await uploadPhotosToStation(report, stationUrl);
        if (photosUploaded > 0) {
          LogService().log('AlertSharingService: Uploaded $photosUploaded photos to $stationUrl');
        }
      } else {
        failed++;
      }
    }

    LogService().log(
        'AlertSharingService: Shared alert to stations - confirmed: $confirmed, failed: $failed, skipped: $skipped');

    return AlertShareSummary(
      confirmed: confirmed,
      failed: failed,
      skipped: skipped,
      eventId: event.id,
      results: results,
    );
  }

  /// Create a signed NOSTR alert event from a report
  ///
  /// Returns null if signing fails.
  Future<NostrEvent?> createAlertEvent(Report report) async {
    try {
      // Get profile
      final profile = _profileService.getProfile();
      if (profile.npub.isEmpty) {
        LogService().log('AlertSharingService: No npub in profile');
        return null;
      }

      // Initialize signing service
      await _signingService.initialize();
      if (!_signingService.canSign(profile)) {
        LogService().log('AlertSharingService: Cannot sign (no nsec or extension)');
        return null;
      }

      // Decode npub to hex public key
      final pubkeyHex = NostrCrypto.decodeNpub(profile.npub);

      // Create alert event
      final event = NostrEvent.alert(
        pubkeyHex: pubkeyHex,
        report: report,
      );

      // Calculate ID and sign
      event.calculateId();
      final signedEvent = await _signingService.signEvent(event, profile);

      if (signedEvent == null || signedEvent.sig == null) {
        LogService().log('AlertSharingService: Signing failed');
        return null;
      }

      LogService().log(
          'AlertSharingService: Created alert event ${signedEvent.id?.substring(0, 16)}...');

      return signedEvent;
    } catch (e) {
      LogService().log('AlertSharingService: Error creating alert event: $e');
      return null;
    }
  }

  /// Send a NOSTR event to a specific station and wait for acknowledgment
  Future<AlertSendResult> sendEventToRelay(
    NostrEvent event,
    String stationUrl, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    try {
      LogService().log('═══════════════════════════════════════════════════════');
      LogService().log('ALERT SEND: Attempting to send alert to $stationUrl');
      LogService().log('  Event ID: ${event.id}');
      LogService().log('  Event Kind: ${event.kind}');
      LogService().log('═══════════════════════════════════════════════════════');

      final eventId = event.id;
      if (eventId == null) {
        LogService().log('ALERT SEND FAILED: Event has no ID');
        return AlertSendResult(
          stationUrl: stationUrl,
          success: false,
          eventId: null,
          message: 'Event has no ID',
        );
      }

      // Create the NOSTR EVENT message in the format the station expects
      // Format: {"nostr_event": ["EVENT", {...event object...}]}
      final eventMessage = {
        'nostr_event': ['EVENT', event.toJson()],
      };

      // Send via WebSocket and wait for OK response
      final result = await _webSocketService.sendEventAndWaitForOk(
        eventMessage,
        eventId,
        timeout: timeout,
      );

      if (result.success) {
        LogService().log('ALERT SEND SUCCESS: Station confirmed receipt');
        LogService().log('  Event ID: $eventId');
        return AlertSendResult(
          stationUrl: stationUrl,
          success: true,
          eventId: eventId,
          message: result.message ?? 'Confirmed by station',
        );
      } else {
        LogService().log('ALERT SEND FAILED: Station rejected or no response');
        LogService().log('  Reason: ${result.message}');
        return AlertSendResult(
          stationUrl: stationUrl,
          success: false,
          eventId: eventId,
          message: result.message ?? 'Station rejected event',
        );
      }
    } catch (e) {
      LogService().log('ALERT SEND ERROR: Failed to send to $stationUrl');
      LogService().log('  Error: $e');
      return AlertSendResult(
        stationUrl: stationUrl,
        success: false,
        eventId: event.id,
        message: e.toString(),
      );
    }
  }

  /// Get configured station URLs
  List<String> getRelayUrls() {
    // Get the preferred station from StationService
    final preferredStation = _stationService.getPreferredStation();

    if (preferredStation != null && preferredStation.url.isNotEmpty) {
      LogService().log('AlertSharingService: Using preferred station: ${preferredStation.url}');
      return [preferredStation.url];
    }

    // No preferred station configured
    LogService().log('AlertSharingService: No preferred station configured');
    return [];
  }

  /// Update station share status in a report
  ///
  /// Returns a new Report with updated stationShares list.
  Report updateStationShareStatus(
    Report report,
    String stationUrl,
    StationShareStatusType status, {
    String? nostrEventId,
  }) {
    final now = DateTime.now();
    final shares = List<StationShareStatus>.from(report.stationShares);

    // Find existing share for this station
    final existingIndex = shares.indexWhere((s) => s.stationUrl == stationUrl);

    if (existingIndex >= 0) {
      // Update existing
      shares[existingIndex] = shares[existingIndex].copyWith(
        sentAt: now,
        status: status,
      );
    } else {
      // Add new
      shares.add(StationShareStatus(
        stationUrl: stationUrl,
        sentAt: now,
        status: status,
      ));
    }

    return report.copyWith(
      stationShares: shares,
      nostrEventId: nostrEventId ?? report.nostrEventId,
    );
  }

  /// Upload photos from an alert folder to the station
  ///
  /// This uploads all photos from the alert's local folder to the station
  /// so they're available for other clients to download.
  Future<int> uploadPhotosToStation(Report report, String stationUrl) async {
    if (kIsWeb) return 0;

    try {
      // Get the alert folder path using StorageConfig and profile
      final storageConfig = StorageConfig();
      if (!storageConfig.isInitialized) {
        LogService().log('AlertSharingService: StorageConfig not initialized');
        return 0;
      }

      final profile = _profileService.getProfile();
      final callsign = profile.callsign;
      if (callsign.isEmpty) {
        LogService().log('AlertSharingService: No callsign');
        return 0;
      }

      // Alerts are stored in: {devicesDir}/{callsign}/alerts/active/{regionFolder}/{folderName}
      final alertPath = '${storageConfig.devicesDir}/$callsign/alerts/active/${report.regionFolder}/${report.folderName}';
      final alertDir = Directory(alertPath);

      if (!await alertDir.exists()) {
        LogService().log('AlertSharingService: Alert folder not found: $alertPath');
        return 0;
      }

      // Find all photos in the folder (with relative paths)
      final photoExtensions = ['.jpg', '.jpeg', '.png', '.gif', '.webp'];
      final photosWithPath = <(File, String)>[]; // (file, relativePath)

      // Check images subdirectory first (new structure)
      final imagesDir = Directory('$alertPath/images');
      if (await imagesDir.exists()) {
        await for (final entity in imagesDir.list()) {
          if (entity is File) {
            final ext = path.extension(entity.path).toLowerCase();
            if (photoExtensions.contains(ext)) {
              photosWithPath.add((entity, 'images/${path.basename(entity.path)}'));
            }
          }
        }
      }

      // Also check root folder for backwards compatibility
      await for (final entity in alertDir.list()) {
        if (entity is File) {
          final ext = path.extension(entity.path).toLowerCase();
          if (photoExtensions.contains(ext)) {
            photosWithPath.add((entity, path.basename(entity.path)));
          }
        }
      }

      if (photosWithPath.isEmpty) {
        LogService().log('AlertSharingService: No photos to upload for ${report.folderName}');
        return 0;
      }

      LogService().log('AlertSharingService: Found ${photosWithPath.length} photos to upload');

      // Convert WebSocket URL to HTTP URL
      var baseUrl = stationUrl;
      if (baseUrl.startsWith('wss://')) {
        baseUrl = baseUrl.replaceFirst('wss://', 'https://');
      } else if (baseUrl.startsWith('ws://')) {
        baseUrl = baseUrl.replaceFirst('ws://', 'http://');
      }

      // Upload endpoint: POST /{callsign}/api/alerts/{folderName}/files
      // Use folderName (coordinate-based) to match where the station stores the alert
      final alertFolderName = report.folderName;
      final uploadUrl = '$baseUrl/$callsign/api/alerts/$alertFolderName/files';

      int uploadedCount = 0;

      for (final (photo, relativePath) in photosWithPath) {
        try {
          final bytes = await photo.readAsBytes();

          // Determine content type
          final ext = path.extension(relativePath).toLowerCase();
          String contentType = 'application/octet-stream';
          if (ext == '.jpg' || ext == '.jpeg') {
            contentType = 'image/jpeg';
          } else if (ext == '.png') {
            contentType = 'image/png';
          } else if (ext == '.gif') {
            contentType = 'image/gif';
          } else if (ext == '.webp') {
            contentType = 'image/webp';
          }

          // Use the filename (not the full relative path) for the upload URL
          // The station will handle creating the images/ subfolder and sequential naming
          final filename = path.basename(relativePath);
          LogService().log('AlertSharingService: Uploading $relativePath to $uploadUrl');

          final response = await http.post(
            Uri.parse('$uploadUrl/$filename'),
            headers: {
              'Content-Type': contentType,
              'X-Callsign': callsign,
            },
            body: bytes,
          ).timeout(const Duration(seconds: 60));

          if (response.statusCode == 200 || response.statusCode == 201) {
            uploadedCount++;
            LogService().log('AlertSharingService: Uploaded $relativePath successfully');
          } else {
            LogService().log('AlertSharingService: Failed to upload $relativePath: ${response.statusCode}');
          }
        } catch (e) {
          LogService().log('AlertSharingService: Error uploading photo: $e');
        }
      }

      LogService().log('AlertSharingService: Uploaded $uploadedCount/${photosWithPath.length} photos');
      return uploadedCount;
    } catch (e) {
      LogService().log('AlertSharingService: Error in uploadPhotosToStation: $e');
      return 0;
    }
  }
}
