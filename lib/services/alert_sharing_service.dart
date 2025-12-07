/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Service for sharing alerts to relays using signed NOSTR events.
 * Uses NIP-78 (kind 30078) for application-specific data.
 */

import 'dart:async';
import '../models/report.dart';
import '../util/nostr_event.dart';
import '../util/nostr_crypto.dart';
import 'log_service.dart';
import 'profile_service.dart';
import 'signing_service.dart';
import 'websocket_service.dart';
import 'relay_service.dart';

/// Result of sending an alert to a relay
class AlertSendResult {
  final String relayUrl;
  final bool success;
  final String? eventId;
  final String? message;

  AlertSendResult({
    required this.relayUrl,
    required this.success,
    this.eventId,
    this.message,
  });

  @override
  String toString() =>
      'AlertSendResult($relayUrl, success: $success, eventId: ${eventId?.substring(0, 8)}...)';
}

/// Summary of multi-relay alert sharing
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
  final RelayService _relayService = RelayService();

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

  /// Share alert to all configured relays
  ///
  /// Returns a summary with confirmed/failed/skipped counts.
  /// Confirmed relays are skipped on subsequent calls.
  Future<AlertShareSummary> shareAlert(Report report) async {
    final relayUrls = getRelayUrls();
    if (relayUrls.isEmpty) {
      LogService().log('AlertSharingService: No relays configured');
      return AlertShareSummary(
        confirmed: 0,
        failed: 0,
        skipped: 0,
        results: [],
      );
    }

    return await shareAlertToRelays(report, relayUrls);
  }

  /// Share alert to specific relays
  ///
  /// Creates one signed NOSTR event and sends it to all relays.
  /// Tracks status per relay in the report.
  Future<AlertShareSummary> shareAlertToRelays(
    Report report,
    List<String> relayUrls,
  ) async {
    if (relayUrls.isEmpty) {
      return AlertShareSummary(
        confirmed: 0,
        failed: 0,
        skipped: 0,
        results: [],
      );
    }

    // Create signed event once (same event for all relays)
    final event = await createAlertEvent(report);
    if (event == null) {
      LogService().log('AlertSharingService: Failed to create alert event');
      return AlertShareSummary(
        confirmed: 0,
        failed: relayUrls.length,
        skipped: 0,
        results: relayUrls
            .map((url) => AlertSendResult(
                  relayUrl: url,
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

    // Send to each relay
    for (final relayUrl in relayUrls) {
      // Check if already confirmed for this relay
      if (!report.needsSharingToRelay(relayUrl)) {
        LogService().log('AlertSharingService: Skipping $relayUrl (already confirmed)');
        skipped++;
        results.add(AlertSendResult(
          relayUrl: relayUrl,
          success: true,
          eventId: event.id,
          message: 'Already confirmed',
        ));
        continue;
      }

      // Send to relay
      final result = await sendEventToRelay(event, relayUrl);
      results.add(result);

      if (result.success) {
        confirmed++;
      } else {
        failed++;
      }
    }

    LogService().log(
        'AlertSharingService: Shared alert to relays - confirmed: $confirmed, failed: $failed, skipped: $skipped');

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

  /// Send a NOSTR event to a specific relay and wait for acknowledgment
  Future<AlertSendResult> sendEventToRelay(
    NostrEvent event,
    String relayUrl, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    try {
      LogService().log('═══════════════════════════════════════════════════════');
      LogService().log('ALERT SEND: Attempting to send alert to $relayUrl');
      LogService().log('  Event ID: ${event.id}');
      LogService().log('  Event Kind: ${event.kind}');
      LogService().log('═══════════════════════════════════════════════════════');

      final eventId = event.id;
      if (eventId == null) {
        LogService().log('ALERT SEND FAILED: Event has no ID');
        return AlertSendResult(
          relayUrl: relayUrl,
          success: false,
          eventId: null,
          message: 'Event has no ID',
        );
      }

      // Create the NOSTR EVENT message in the format the relay expects
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
        LogService().log('ALERT SEND SUCCESS: Relay confirmed receipt');
        LogService().log('  Event ID: $eventId');
        return AlertSendResult(
          relayUrl: relayUrl,
          success: true,
          eventId: eventId,
          message: result.message ?? 'Confirmed by relay',
        );
      } else {
        LogService().log('ALERT SEND FAILED: Relay rejected or no response');
        LogService().log('  Reason: ${result.message}');
        return AlertSendResult(
          relayUrl: relayUrl,
          success: false,
          eventId: eventId,
          message: result.message ?? 'Relay rejected event',
        );
      }
    } catch (e) {
      LogService().log('ALERT SEND ERROR: Failed to send to $relayUrl');
      LogService().log('  Error: $e');
      return AlertSendResult(
        relayUrl: relayUrl,
        success: false,
        eventId: event.id,
        message: e.toString(),
      );
    }
  }

  /// Get configured relay URLs
  List<String> getRelayUrls() {
    // Get the preferred relay from RelayService
    final preferredRelay = _relayService.getPreferredRelay();

    if (preferredRelay != null && preferredRelay.url.isNotEmpty) {
      LogService().log('AlertSharingService: Using preferred relay: ${preferredRelay.url}');
      return [preferredRelay.url];
    }

    // Fall back to default relay
    LogService().log('AlertSharingService: No preferred relay, using default wss://p2p.radio');
    return ['wss://p2p.radio'];
  }

  /// Update relay share status in a report
  ///
  /// Returns a new Report with updated relayShares list.
  Report updateRelayShareStatus(
    Report report,
    String relayUrl,
    RelayShareStatusType status, {
    String? nostrEventId,
  }) {
    final now = DateTime.now();
    final shares = List<RelayShareStatus>.from(report.relayShares);

    // Find existing share for this relay
    final existingIndex = shares.indexWhere((s) => s.relayUrl == relayUrl);

    if (existingIndex >= 0) {
      // Update existing
      shares[existingIndex] = shares[existingIndex].copyWith(
        sentAt: now,
        status: status,
      );
    } else {
      // Add new
      shares.add(RelayShareStatus(
        relayUrl: relayUrl,
        sentAt: now,
        status: status,
      ));
    }

    return report.copyWith(
      relayShares: shares,
      nostrEventId: nostrEventId ?? report.nostrEventId,
    );
  }
}
