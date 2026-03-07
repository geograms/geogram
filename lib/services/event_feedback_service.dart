/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Service for syncing event feedback (likes, comments) to station.
 */

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../util/nostr_crypto.dart';
import '../util/nostr_event.dart';
import '../util/feedback_folder_utils.dart';
import 'log_service.dart';
import 'profile_service.dart';
import 'signing_service.dart';
import 'station_server_service.dart';
import 'station_service.dart';

class FeedbackToggleResult {
  final bool success;
  final bool? isActive;
  final int? count;
  final String? error;

  FeedbackToggleResult({
    required this.success,
    this.isActive,
    this.count,
    this.error,
  });
}

class EventFeedbackService {
  static final EventFeedbackService _instance = EventFeedbackService._internal();
  factory EventFeedbackService() => _instance;
  EventFeedbackService._internal();

  final StationService _stationService = StationService();
  final ProfileService _profileService = ProfileService();
  final SigningService _signingService = SigningService();
  bool _signingInitialized = false;

  Future<String?> _getStationHttpUrl() async {
    await _stationService.initialize();
    final preferred = _stationService.getPreferredStation();
    final station = (preferred != null && preferred.url.isNotEmpty)
        ? preferred
        : _stationService.getConnectedStation();
    if (station == null || station.url.isEmpty) return null;

    var baseUrl = station.url;
    if (baseUrl.startsWith('wss://')) {
      baseUrl = baseUrl.replaceFirst('wss://', 'https://');
    } else if (baseUrl.startsWith('ws://')) {
      baseUrl = baseUrl.replaceFirst('ws://', 'http://');
    }

    return baseUrl;
  }

  Future<NostrEvent?> buildLikeEvent(String eventId) {
    return _buildReactionEvent(eventId, 'like', FeedbackFolderUtils.feedbackTypeLikes);
  }

  Future<String?> signComment(String eventId, String comment) {
    return _signComment(eventId, comment);
  }

  Future<FeedbackToggleResult> toggleLikeOnStation(String eventId, NostrEvent event) async {
    try {
      final result = await _postFeedbackEvent(eventId, 'like', event);
      if (result.success && result.isActive == true) {
        StationServerService().karmaRecord(
          callsign: _profileService.getProfile().callsign,
          action: 'like_given',
          meta: {'content_type': 'event', 'content_id': eventId},
        );
      }
      return result;
    } catch (e) {
      LogService().log('EventFeedbackService: Error liking event on station: $e');
      return FeedbackToggleResult(
        success: false,
        error: e.toString(),
      );
    }
  }

  Future<bool> commentOnStation(
    String eventId,
    String author,
    String content, {
    String? npub,
    String? signature,
  }) async {
    try {
      final commentSignature = signature ?? await _signComment(eventId, content);
      final profile = _profileService.getProfile();
      final success = await _postFeedbackComment(
        eventId,
        author,
        content,
        npub ?? profile.npub,
        commentSignature,
      );
      if (success) {
        StationServerService().karmaRecord(
          callsign: profile.callsign,
          action: 'comment_given',
          meta: {'content_type': 'event', 'content_id': eventId},
        );
      }
      return success;
    } catch (e) {
      LogService().log('EventFeedbackService: Error commenting on event: $e');
      return false;
    }
  }

  Future<FeedbackToggleResult> _postFeedbackEvent(String eventId, String action, NostrEvent event) async {
    final baseUrl = await _getStationHttpUrl();
    if (baseUrl == null) {
      LogService().log('EventFeedbackService: No station configured');
      return FeedbackToggleResult(
        success: false,
        error: 'No station configured',
      );
    }

    try {
      final baseUri = Uri.parse(baseUrl);
      final uri = baseUri.replace(
        pathSegments: [
          ...baseUri.pathSegments,
          'api',
          'feedback',
          'event',
          eventId,
          action,
        ],
      );
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
          bool? isActive;
          if (json['liked'] is bool) {
            isActive = json['liked'] as bool;
          } else if (json['action'] == 'added') {
            isActive = true;
          } else if (json['action'] == 'removed') {
            isActive = false;
          }

          final count = json['like_count'] is int ? json['like_count'] as int : null;

          LogService().log('EventFeedbackService: Feedback $action for $eventId via API');
          return FeedbackToggleResult(
            success: true,
            isActive: isActive,
            count: count,
          );
        }
        return FeedbackToggleResult(
          success: false,
          error: json['error'] as String? ?? 'Station rejected feedback',
        );
      }
      LogService().log('EventFeedbackService: Feedback $action failed: ${response.statusCode}');
      return FeedbackToggleResult(
        success: false,
        error: 'HTTP ${response.statusCode}',
      );
    } catch (e) {
      LogService().log('EventFeedbackService: Feedback $action error: $e');
      return FeedbackToggleResult(
        success: false,
        error: e.toString(),
      );
    }
  }

  Future<bool> _postFeedbackComment(
    String eventId,
    String author,
    String content,
    String? npub,
    String? signature,
  ) async {
    final baseUrl = await _getStationHttpUrl();
    if (baseUrl == null) return false;

    try {
      final baseUri = Uri.parse(baseUrl);
      final uri = baseUri.replace(
        pathSegments: [
          ...baseUri.pathSegments,
          'api',
          'feedback',
          'event',
          eventId,
          'comment',
        ],
      );
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
          LogService().log('EventFeedbackService: Commented on event $eventId via API');
          return true;
        }
      }
      LogService().log('EventFeedbackService: Comment failed: ${response.statusCode}');
      return false;
    } catch (e) {
      LogService().log('EventFeedbackService: Comment error: $e');
      return false;
    }
  }

  Future<NostrEvent?> _buildReactionEvent(
    String eventId,
    String actionName,
    String feedbackType,
  ) async {
    final profile = _profileService.getProfile();
    if (profile.callsign.isEmpty || profile.npub.isEmpty) return null;

    if (!await _ensureSigningInitialized()) return null;
    if (!_signingService.canSign(profile)) return null;

    final pubkeyHex = NostrCrypto.decodeNpub(profile.npub);
    final event = NostrEvent(
      pubkey: pubkeyHex,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      kind: NostrEventKind.reaction,
      tags: [
        ['content_type', 'event'],
        ['content_id', eventId],
        ['action', actionName],
        ['owner', profile.callsign],
        ['type', feedbackType],
      ],
      content: actionName,
    );

    final signed = await _signingService.signEvent(event, profile);
    return signed;
  }

  Future<String?> _signComment(String eventId, String comment) async {
    final profile = _profileService.getProfile();
    if (profile.callsign.isEmpty || profile.npub.isEmpty) return null;

    if (!await _ensureSigningInitialized()) return null;
    if (!_signingService.canSign(profile)) return null;

    final pubkeyHex = NostrCrypto.decodeNpub(profile.npub);
    final event = NostrEvent(
      pubkey: pubkeyHex,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      kind: NostrEventKind.textNote,
      tags: [
        ['content_type', 'event'],
        ['content_id', eventId],
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
      LogService().log('EventFeedbackService: Signing init failed: $e');
      return false;
    }
  }
}
