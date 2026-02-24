/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Shared Feedback API handlers for station servers.
 * Implements /api/feedback endpoints using FeedbackFolderUtils.
 */

import '../../services/profile_storage.dart';
import '../../util/blog_folder_utils.dart';
import '../../util/feedback_comment_utils.dart';
import '../../util/feedback_folder_utils.dart';
import '../../util/nostr_event.dart';
import '../../models/report.dart';

class FeedbackContentLocation {
  final String contentPath;
  final String callsign;

  FeedbackContentLocation({
    required this.contentPath,
    required this.callsign,
  });
}

class FeedbackHandler {
  final ProfileStorage storage;
  final void Function(String level, String message)? log;

  FeedbackHandler({
    required this.storage,
    this.log,
  });

  void _log(String level, String message) {
    log?.call(level, message);
  }

  Future<Map<String, dynamic>> getFeedback({
    required String contentType,
    required String contentId,
    String? npub,
    String? callsign,
    bool includeComments = false,
    int commentLimit = 20,
    int commentOffset = 0,
  }) async {
    try {
      final location = await _resolveContentPath(
        contentType: contentType,
        contentId: contentId,
        callsign: callsign,
      );
      if (location == null) {
        return {'error': 'Content not found', 'http_status': 404};
      }

      final counts = await FeedbackFolderUtils.getAllFeedbackCounts(location.contentPath, storage: storage);
      final commentCount = await FeedbackCommentUtils.getCommentCount(location.contentPath, storage: storage);

      final response = <String, dynamic>{
        'success': true,
        'content_id': contentId,
        'content_type': contentType,
        'owner': location.callsign,
        'counts': {
          'likes': counts[FeedbackFolderUtils.feedbackTypeLikes] ?? 0,
          'points': counts[FeedbackFolderUtils.feedbackTypePoints] ?? 0,
          'dislikes': counts[FeedbackFolderUtils.feedbackTypeDislikes] ?? 0,
          'subscribe': counts[FeedbackFolderUtils.feedbackTypeSubscribe] ?? 0,
          'verifications': counts[FeedbackFolderUtils.feedbackTypeVerifications] ?? 0,
          'views': counts[FeedbackFolderUtils.feedbackTypeViews] ?? 0,
          'thumbs-up': counts[FeedbackFolderUtils.reactionThumbsUp] ?? 0,
          'thumbs-down': counts[FeedbackFolderUtils.reactionThumbsDown] ?? 0,
          'heart': counts[FeedbackFolderUtils.reactionHeart] ?? 0,
          'fire': counts[FeedbackFolderUtils.reactionFire] ?? 0,
          'hundred': counts[FeedbackFolderUtils.reactionHundred] ?? 0,
          'curious': counts[FeedbackFolderUtils.reactionCurious] ?? 0,
          'celebrate': counts[FeedbackFolderUtils.reactionCelebrate] ?? 0,
          'laugh': counts[FeedbackFolderUtils.reactionLaugh] ?? 0,
          'sad': counts[FeedbackFolderUtils.reactionSad] ?? 0,
          'beer-cheers': counts[FeedbackFolderUtils.reactionBeerCheers] ?? 0,
          'surprise': counts[FeedbackFolderUtils.reactionSurprise] ?? 0,
          'comments': commentCount,
        },
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      };

      if (npub != null && npub.isNotEmpty) {
        final userState = await FeedbackFolderUtils.getUserFeedbackState(location.contentPath, npub, storage: storage);
        response['user_state'] = {
          'liked': userState[FeedbackFolderUtils.feedbackTypeLikes] ?? false,
          'pointed': userState[FeedbackFolderUtils.feedbackTypePoints] ?? false,
          'disliked': userState[FeedbackFolderUtils.feedbackTypeDislikes] ?? false,
          'subscribed': userState[FeedbackFolderUtils.feedbackTypeSubscribe] ?? false,
          'verified': userState[FeedbackFolderUtils.feedbackTypeVerifications] ?? false,
          'thumbs-up': userState[FeedbackFolderUtils.reactionThumbsUp] ?? false,
          'thumbs-down': userState[FeedbackFolderUtils.reactionThumbsDown] ?? false,
          'heart': userState[FeedbackFolderUtils.reactionHeart] ?? false,
          'fire': userState[FeedbackFolderUtils.reactionFire] ?? false,
          'hundred': userState[FeedbackFolderUtils.reactionHundred] ?? false,
          'curious': userState[FeedbackFolderUtils.reactionCurious] ?? false,
          'celebrate': userState[FeedbackFolderUtils.reactionCelebrate] ?? false,
          'laugh': userState[FeedbackFolderUtils.reactionLaugh] ?? false,
          'sad': userState[FeedbackFolderUtils.reactionSad] ?? false,
          'beer-cheers': userState[FeedbackFolderUtils.reactionBeerCheers] ?? false,
          'surprise': userState[FeedbackFolderUtils.reactionSurprise] ?? false,
        };
      }

      if (includeComments) {
        final comments = await FeedbackCommentUtils.loadComments(location.contentPath, storage: storage);
        final start = commentOffset < 0 ? 0 : commentOffset;
        final end = commentLimit <= 0
            ? comments.length
            : (start + commentLimit).clamp(0, comments.length);
        response['comments'] = comments
            .skip(start)
            .take(end - start)
            .map((comment) => comment.toJson())
            .toList();
      }

      return response;
    } catch (e) {
      _log('ERROR', 'Error getting feedback: $e');
      return {
        'error': 'Internal server error',
        'message': e.toString(),
        'http_status': 500,
      };
    }
  }

  Future<Map<String, dynamic>> getStats({
    required String contentType,
    required String contentId,
    String? callsign,
  }) async {
    try {
      final location = await _resolveContentPath(
        contentType: contentType,
        contentId: contentId,
        callsign: callsign,
      );
      if (location == null) {
        return {'error': 'Content not found', 'http_status': 404};
      }

      final viewStats = await FeedbackFolderUtils.getViewStats(location.contentPath, storage: storage);
      final counts = await FeedbackFolderUtils.getAllFeedbackCounts(location.contentPath, storage: storage);
      final commentCount = await FeedbackCommentUtils.getCommentCount(location.contentPath, storage: storage);

      return {
        'success': true,
        'content_id': contentId,
        'content_type': contentType,
        'owner': location.callsign,
        'total_views': viewStats['total_views'],
        'unique_viewers': viewStats['unique_viewers'],
        'first_view': viewStats['first_view'],
        'latest_view': viewStats['latest_view'],
        'likes': counts[FeedbackFolderUtils.feedbackTypeLikes] ?? 0,
        'points': counts[FeedbackFolderUtils.feedbackTypePoints] ?? 0,
        'dislikes': counts[FeedbackFolderUtils.feedbackTypeDislikes] ?? 0,
        'subscribe': counts[FeedbackFolderUtils.feedbackTypeSubscribe] ?? 0,
        'verifications': counts[FeedbackFolderUtils.feedbackTypeVerifications] ?? 0,
        'comments': commentCount,
        'reactions': {
          'thumbs-up': counts[FeedbackFolderUtils.reactionThumbsUp] ?? 0,
          'thumbs-down': counts[FeedbackFolderUtils.reactionThumbsDown] ?? 0,
          'heart': counts[FeedbackFolderUtils.reactionHeart] ?? 0,
          'fire': counts[FeedbackFolderUtils.reactionFire] ?? 0,
          'hundred': counts[FeedbackFolderUtils.reactionHundred] ?? 0,
          'curious': counts[FeedbackFolderUtils.reactionCurious] ?? 0,
          'celebrate': counts[FeedbackFolderUtils.reactionCelebrate] ?? 0,
          'laugh': counts[FeedbackFolderUtils.reactionLaugh] ?? 0,
          'sad': counts[FeedbackFolderUtils.reactionSad] ?? 0,
          'beer-cheers': counts[FeedbackFolderUtils.reactionBeerCheers] ?? 0,
          'surprise': counts[FeedbackFolderUtils.reactionSurprise] ?? 0,
        },
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      };
    } catch (e) {
      _log('ERROR', 'Error getting feedback stats: $e');
      return {
        'error': 'Internal server error',
        'message': e.toString(),
        'http_status': 500,
      };
    }
  }

  Future<Map<String, dynamic>> toggleFeedback({
    required String contentType,
    required String contentId,
    required String feedbackType,
    required String actionName,
    required Map<String, dynamic> eventJson,
    String? callsign,
  }) async {
    try {
      final location = await _resolveContentPath(
        contentType: contentType,
        contentId: contentId,
        callsign: callsign,
      );
      if (location == null) {
        return {'error': 'Content not found', 'http_status': 404};
      }

      final event = _parseEvent(eventJson);
      if (event == null) {
        return {
          'error': 'Invalid NOSTR event format',
          'http_status': 400,
        };
      }

      if (!event.verify()) {
        return {
          'error': 'Invalid signature',
          'message': 'NOSTR event signature verification failed',
          'http_status': 401,
        };
      }

      final isNowActive = await FeedbackFolderUtils.toggleFeedbackEvent(
        location.contentPath,
        feedbackType,
        event,
        storage: storage,
      );

      if (isNowActive == null) {
        return {
          'error': 'Feedback operation failed',
          'message': 'Could not update feedback',
          'http_status': 500,
        };
      }

      final count = await FeedbackFolderUtils.getFeedbackCount(location.contentPath, feedbackType, storage: storage);
      final action = isNowActive ? 'added' : 'removed';

      await _touchAlertLastModified(location.contentPath);

      return {
        'success': true,
        'action': action,
        _actionFlagKey(actionName): isNowActive,
        _countKey(actionName): count,
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      };
    } catch (e) {
      _log('ERROR', 'Error toggling feedback: $e');
      return {
        'error': 'Internal server error',
        'message': e.toString(),
        'http_status': 500,
      };
    }
  }

  Future<Map<String, dynamic>> verifyContent({
    required String contentType,
    required String contentId,
    required Map<String, dynamic> eventJson,
    String? callsign,
  }) async {
    try {
      final location = await _resolveContentPath(
        contentType: contentType,
        contentId: contentId,
        callsign: callsign,
      );
      if (location == null) {
        return {'error': 'Content not found', 'http_status': 404};
      }

      final event = _parseEvent(eventJson);
      if (event == null) {
        return {
          'error': 'Invalid NOSTR event format',
          'http_status': 400,
        };
      }

      if (!event.verify()) {
        return {
          'error': 'Invalid signature',
          'message': 'NOSTR event signature verification failed',
          'http_status': 401,
        };
      }

      await FeedbackFolderUtils.addFeedbackEvent(
        location.contentPath,
        FeedbackFolderUtils.feedbackTypeVerifications,
        event,
        storage: storage,
      );

      final count = await FeedbackFolderUtils.getFeedbackCount(
        location.contentPath,
        FeedbackFolderUtils.feedbackTypeVerifications,
        storage: storage,
      );

      await _touchAlertLastModified(location.contentPath, verifiedNpub: event.npub);

      return {
        'success': true,
        'verified': true,
        'verification_count': count,
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      };
    } catch (e) {
      _log('ERROR', 'Error verifying content: $e');
      return {
        'error': 'Internal server error',
        'message': e.toString(),
        'http_status': 500,
      };
    }
  }

  Future<Map<String, dynamic>> recordView({
    required String contentType,
    required String contentId,
    required Map<String, dynamic> eventJson,
    String? callsign,
  }) async {
    try {
      final location = await _resolveContentPath(
        contentType: contentType,
        contentId: contentId,
        callsign: callsign,
      );
      if (location == null) {
        return {'error': 'Content not found', 'http_status': 404};
      }

      final event = _parseEvent(eventJson);
      if (event == null) {
        return {
          'error': 'Invalid NOSTR event format',
          'http_status': 400,
        };
      }

      if (!event.verify()) {
        return {
          'error': 'Invalid signature',
          'message': 'NOSTR event signature verification failed',
          'http_status': 401,
        };
      }

      final recorded = await FeedbackFolderUtils.recordViewEvent(
        location.contentPath,
        event,
        storage: storage,
      );

      if (!recorded) {
        return {
          'error': 'Invalid signature',
          'message': 'NOSTR event signature verification failed',
          'http_status': 401,
        };
      }

      final stats = await FeedbackFolderUtils.getViewStats(location.contentPath, storage: storage);

      return {
        'success': true,
        'view_recorded': true,
        'total_views': stats['total_views'],
        'unique_viewers': stats['unique_viewers'],
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      };
    } catch (e) {
      _log('ERROR', 'Error recording view: $e');
      return {
        'error': 'Internal server error',
        'message': e.toString(),
        'http_status': 500,
      };
    }
  }

  Future<Map<String, dynamic>> addComment({
    required String contentType,
    required String contentId,
    required String author,
    required String content,
    String? npub,
    String? signature,
    String? callsign,
  }) async {
    try {
      final location = await _resolveContentPath(
        contentType: contentType,
        contentId: contentId,
        callsign: callsign,
      );
      if (location == null) {
        return {'error': 'Content not found', 'http_status': 404};
      }

      final commentId = await FeedbackCommentUtils.writeComment(
        contentPath: location.contentPath,
        author: author,
        content: content,
        npub: npub,
        signature: signature,
        storage: storage,
      );

      await _touchAlertLastModified(location.contentPath);

      return {
        'success': true,
        'comment_id': commentId,
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      };
    } catch (e) {
      _log('ERROR', 'Error adding comment: $e');
      return {
        'error': 'Internal server error',
        'message': e.toString(),
        'http_status': 500,
      };
    }
  }

  String _actionFlagKey(String actionName) {
    switch (actionName) {
      case 'like':
        return 'liked';
      case 'point':
        return 'pointed';
      case 'dislike':
        return 'disliked';
      case 'subscribe':
        return 'subscribed';
      case 'react':
        return 'reacted';
      default:
        return '${actionName}d';
    }
  }

  String _countKey(String actionName) {
    switch (actionName) {
      case 'like':
        return 'like_count';
      case 'point':
        return 'point_count';
      case 'dislike':
        return 'dislike_count';
      case 'subscribe':
        return 'subscriber_count';
      case 'react':
        return 'reaction_count';
      default:
        return '${actionName}_count';
    }
  }

  NostrEvent? _parseEvent(Map<String, dynamic> eventJson) {
    try {
      return NostrEvent.fromJson(eventJson);
    } catch (_) {
      return null;
    }
  }

  Future<FeedbackContentLocation?> _resolveContentPath({
    required String contentType,
    required String contentId,
    String? callsign,
  }) async {
    final type = contentType.toLowerCase();
    switch (type) {
      case 'alert':
        return _resolveAlertPath(contentId, callsign: callsign);
      case 'blog':
        return _resolveBlogPath(contentId, callsign: callsign);
      case 'event':
      case 'events':
        return _resolveEventPath(contentId, callsign: callsign);
      case 'place':
        return _resolvePlacePath(contentId, callsign: callsign);
      default:
        return null;
    }
  }

  Future<FeedbackContentLocation?> _resolveAlertPath(String alertId, {String? callsign}) async {
    // Search alerts recursively
    final entries = await storage.listDirectory('alerts', recursive: true);
    for (final entry in entries) {
      if (entry.isDirectory && entry.name == alertId) {
        if (await storage.exists('${entry.path}/report.txt')) {
          return FeedbackContentLocation(contentPath: entry.path, callsign: callsign ?? '');
        }
      }
      if (!entry.isDirectory && entry.name == 'report.txt') {
        final alertDir = entry.path.replaceFirst('/report.txt', '');
        final folderName = alertDir.split('/').last;
        if (folderName == alertId) {
          return FeedbackContentLocation(contentPath: alertDir, callsign: callsign ?? '');
        }
        // Also check apiId
        try {
          final content = await storage.readString(entry.path);
          if (content != null) {
            final report = Report.fromText(content, folderName);
            if (report.apiId == alertId) {
              return FeedbackContentLocation(contentPath: alertDir, callsign: callsign ?? '');
            }
          }
        } catch (_) {}
      }
    }
    return null;
  }

  Future<FeedbackContentLocation?> _resolveBlogPath(String postId, {String? callsign}) async {
    final postPath = await BlogFolderUtils.findPostPath('blog', postId, storage: storage);
    if (postPath != null) {
      return FeedbackContentLocation(contentPath: postPath, callsign: callsign ?? '');
    }
    return null;
  }

  Future<FeedbackContentLocation?> _resolvePlacePath(String folderName, {String? callsign}) async {
    final entries = await storage.listDirectory('places', recursive: true);
    for (final entry in entries) {
      if (!entry.isDirectory && entry.name == 'place.txt') {
        final placeDir = entry.path.replaceFirst('/place.txt', '');
        final placeFolderName = placeDir.split('/').last;
        if (placeFolderName == folderName) {
          return FeedbackContentLocation(contentPath: placeDir, callsign: callsign ?? '');
        }
      }
    }
    return null;
  }

  Future<FeedbackContentLocation?> _resolveEventPath(String eventId, {String? callsign}) async {
    // Try direct lookup with year extracted from eventId
    final year = _extractEventYear(eventId);
    if (year != null) {
      if (await storage.exists('events/$year/$eventId/event.txt')) {
        return FeedbackContentLocation(contentPath: 'events/$year/$eventId', callsign: callsign ?? '');
      }
    }

    // Fallback: search recursively
    final entries = await storage.listDirectory('events', recursive: true);
    for (final entry in entries) {
      if (!entry.isDirectory && entry.name == 'event.txt') {
        final eventDir = entry.path.replaceFirst('/event.txt', '');
        final eventFolderName = eventDir.split('/').last;
        if (eventFolderName == eventId) {
          return FeedbackContentLocation(contentPath: eventDir, callsign: callsign ?? '');
        }
      }
    }

    return null;
  }

  String? _extractEventYear(String eventId) {
    if (eventId.length < 4) return null;
    final yearStr = eventId.substring(0, 4);
    final year = int.tryParse(yearStr);
    if (year == null || year < 1970 || year > 3000) return null;
    return yearStr;
  }

  Future<void> _touchAlertLastModified(String contentPath, {String? verifiedNpub}) async {
    if (!await storage.exists('$contentPath/report.txt')) return;

    try {
      final content = await storage.readString('$contentPath/report.txt');
      if (content == null) return;
      final now = DateTime.now().toUtc().toIso8601String();

      List<String>? verifiedBy;
      if (verifiedNpub != null && verifiedNpub.isNotEmpty) {
        verifiedBy = _extractVerifiedBy(content);
        if (!verifiedBy.contains(verifiedNpub)) {
          verifiedBy.add(verifiedNpub);
        }
      }

      final updated = _updateAlertFeedback(content, verifiedBy: verifiedBy, lastModified: now);
      await storage.writeString('$contentPath/report.txt', updated);
    } catch (e) {
      _log('WARN', 'Failed to update alert last_modified: $e');
    }
  }

  List<String> _extractVerifiedBy(String content) {
    final lines = content.split('\n');
    for (final line in lines) {
      if (line.startsWith('VERIFIED_BY: ')) {
        final verifiedByStr = line.substring(13).trim();
        return verifiedByStr.isEmpty
            ? <String>[]
            : verifiedByStr
                .split(',')
                .map((e) => e.trim())
                .where((e) => e.isNotEmpty)
                .toList();
      }
    }
    return <String>[];
  }

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

    int insertIndex = newLines.length;
    int emptyLineCount = 0;
    for (int i = 0; i < newLines.length; i++) {
      if (newLines[i].trim().isEmpty && i > 0 && !newLines[i - 1].startsWith('-->')) {
        emptyLineCount++;
        if (emptyLineCount == 2) {
          insertIndex = i;
          break;
        }
      }
    }

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
}
