/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Service for syncing alert feedback (points, verifications, comments) to station.
 * Uses best-effort pattern: local changes are saved first, station sync is fire-and-forget.
 */

import 'dart:convert';

import '../util/nostr_crypto.dart';
import '../util/nostr_event.dart';
import 'package:http/http.dart' as http;
import 'log_service.dart';
import 'profile_service.dart';
import 'signing_service.dart';
import 'station_service.dart';
import '../util/feedback_folder_utils.dart';

/// Service for syncing alert feedback to station
class AlertFeedbackService {
  static final AlertFeedbackService _instance = AlertFeedbackService._internal();
  factory AlertFeedbackService() => _instance;
  AlertFeedbackService._internal();

  final StationService _stationService = StationService();
  final ProfileService _profileService = ProfileService();
  final SigningService _signingService = SigningService();
  bool _signingInitialized = false;

  /// Get the station base URL (converts wss:// to https://)
  Future<String?> _getStationHttpUrl() async {
    await _stationService.initialize();
    final preferred = _stationService.getPreferredStation();
    final station = (preferred != null && preferred.url.isNotEmpty)
        ? preferred
        : _stationService.getConnectedRelay();
    if (station == null || station.url.isEmpty) return null;

    var baseUrl = station.url;
    if (baseUrl.startsWith('wss://')) {
      baseUrl = baseUrl.replaceFirst('wss://', 'https://');
    } else if (baseUrl.startsWith('ws://')) {
      baseUrl = baseUrl.replaceFirst('ws://', 'http://');
    }

    return baseUrl;
  }

  /// Point an alert on the station (best-effort)
  ///
  /// Returns true if successful, false otherwise.
  /// Failures are logged but do not throw.
  Future<bool> pointAlertOnStation(String alertId) async {
    try {
      return await _sendPointFeedback(alertId, 'point');
    } catch (e) {
      LogService().log('AlertFeedbackService: Error pointing alert on station: $e');
      return false;
    }
  }

  /// Unpoint an alert on the station (best-effort)
  Future<bool> unpointAlertOnStation(String alertId) async {
    try {
      return await _sendPointFeedback(alertId, 'unpoint');
    } catch (e) {
      LogService().log('AlertFeedbackService: Error unpointing alert on station: $e');
      return false;
    }
  }

  /// Verify an alert on the station (best-effort)
  Future<bool> verifyAlertOnStation(String alertId) async {
    try {
      return await _sendVerification(alertId);
    } catch (e) {
      LogService().log('AlertFeedbackService: Error verifying alert on station: $e');
      return false;
    }
  }

  /// Add a signed comment to an alert on the station (best-effort)
  Future<bool> commentOnStation(
    String alertId,
    String author,
    String content, {
    String? npub,
    String? signature,
  }) async {
    try {
      final commentSignature = await _signComment(alertId, content);
      final profile = _profileService.getProfile();
      return await _postFeedbackComment(
        alertId,
        author,
        content,
        npub ?? profile.npub,
        signature ?? commentSignature,
      );
    } catch (e) {
      LogService().log('AlertFeedbackService: Error adding comment on station: $e');
      return false;
    }
  }

  Future<NostrEvent?> buildReactionEvent(
    String alertId,
    String actionName,
    String feedbackType,
  ) {
    return _buildReactionEvent(alertId, actionName, feedbackType);
  }

  Future<NostrEvent?> buildVerificationEvent(String alertId) {
    return _buildVerificationEvent(alertId);
  }

  Future<String?> signComment(String alertId, String comment) {
    return _signComment(alertId, comment);
  }

  Future<bool> _sendPointFeedback(String alertId, String actionName) async {
    final event = await _buildReactionEvent(alertId, actionName, FeedbackFolderUtils.feedbackTypePoints);
    if (event == null) return false;
    return await _postFeedbackEvent(alertId, 'point', event);
  }

  Future<bool> _sendVerification(String alertId) async {
    final event = await _buildVerificationEvent(alertId);
    if (event == null) return false;
    return await _postFeedbackEvent(alertId, 'verify', event);
  }

  Future<bool> _postFeedbackEvent(String alertId, String action, NostrEvent event) async {
    final baseUrl = await _getStationHttpUrl();
    if (baseUrl == null) {
      LogService().log('AlertFeedbackService: No station configured');
      return false;
    }

    try {
      final uri = Uri.parse('$baseUrl/api/feedback/alert/$alertId/$action');
      final response = await http.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode(event.toJson()),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        if (json['success'] == true) {
          LogService().log('AlertFeedbackService: Feedback $action for $alertId via new API');
          return true;
        }
      }
      LogService().log('AlertFeedbackService: New API $action failed: ${response.statusCode}');
      return false;
    } catch (e) {
      LogService().log('AlertFeedbackService: New API $action error: $e');
      return false;
    }
  }

  Future<bool> _postFeedbackComment(
    String alertId,
    String author,
    String content,
    String? npub,
    String? signature,
  ) async {
    final baseUrl = await _getStationHttpUrl();
    if (baseUrl == null) return false;

    try {
      final uri = Uri.parse('$baseUrl/api/feedback/alert/$alertId/comment');
      final body = <String, dynamic>{
        'author': author,
        'content': content,
      };
      if (npub != null && npub.isNotEmpty) {
        body['npub'] = npub;
      }
      if (signature != null && signature.isNotEmpty) {
        body['signature'] = signature;
      }

      final response = await http.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        if (json['success'] == true) {
          LogService().log('AlertFeedbackService: Commented on alert $alertId via new API');
          return true;
        }
      }
      LogService().log('AlertFeedbackService: New API comment failed: ${response.statusCode}');
      return false;
    } catch (e) {
      LogService().log('AlertFeedbackService: New API comment error: $e');
      return false;
    }
  }

  Future<NostrEvent?> _buildReactionEvent(String alertId, String actionName, String feedbackType) async {
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

    final signed = await _signingService.signEvent(event, profile);
    return signed;
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

    final signed = await _signingService.signEvent(event, profile);
    return signed;
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

  Future<bool> _ensureSigningInitialized() async {
    if (_signingInitialized) return true;
    try {
      await _signingService.initialize();
      _signingInitialized = true;
      return true;
    } catch (e) {
      LogService().log('AlertFeedbackService: Signing initialization failed: $e');
      return false;
    }
  }

}
