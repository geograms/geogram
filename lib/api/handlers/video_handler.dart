/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Video API handlers for device-hosted videos.
 * Enables remote devices to view video metadata, thumbnails, and feedback.
 * Video files remain on the source device and are streamed via WebRTC.
 */

import 'dart:io';

import '../../models/video.dart';
import '../../services/profile_storage.dart';
import '../../util/video_parser.dart';
import '../../util/video_folder_utils.dart';
import '../../util/feedback_folder_utils.dart';
import '../../util/feedback_comment_utils.dart';
import '../../util/nostr_event.dart';

/// Video API handlers for device-hosted videos
class VideoHandler {
  final String dataDir;
  final String callsign;
  final ProfileStorage storage;
  final void Function(String level, String message)? log;

  VideoHandler({
    required this.dataDir,
    required this.callsign,
    required this.storage,
    this.log,
  });

  void _log(String level, String message) {
    log?.call(level, message);
  }

  /// Get the videos path for this device
  String get _videosPath => '$dataDir/devices/$callsign/videos/$callsign';

  // ============================================================
  // GET /api/videos - List all videos
  // ============================================================

  /// Handle GET /api/videos - returns list of public videos
  Future<Map<String, dynamic>> getVideos({
    String? category,
    String? tag,
    String? folder,
    VideoVisibility? visibility,
    int? limit,
    int? offset,
  }) async {
    try {
      // Load all videos
      var videos = await _loadAllVideos(publicOnly: visibility == null);

      // Filter by category
      if (category != null && category.isNotEmpty) {
        videos = videos.where((v) {
          return v['category'] == category;
        }).toList();
      }

      // Filter by tag
      if (tag != null && tag.isNotEmpty) {
        videos = videos.where((v) {
          final tags = v['tags'] as List<dynamic>? ?? [];
          return tags.any((t) => t.toString().toLowerCase() == tag.toLowerCase());
        }).toList();
      }

      // Filter by folder
      if (folder != null && folder.isNotEmpty) {
        final folderSegments = folder.split('/').where((s) => s.isNotEmpty).toList();
        videos = videos.where((v) {
          final videoPath = v['folderPath'] as String? ?? '';
          final videoSegments = VideoFolderUtils.extractPathSegments(_videosPath, videoPath);
          if (folderSegments.length > videoSegments.length) return false;
          for (int i = 0; i < folderSegments.length; i++) {
            if (videoSegments[i] != folderSegments[i]) return false;
          }
          return true;
        }).toList();
      }

      // Filter by visibility
      if (visibility != null) {
        videos = videos.where((v) => v['visibility'] == visibility.name).toList();
      }

      // Sort by creation date (newest first)
      videos.sort((a, b) {
        final aCreated = a['created'] as String? ?? '';
        final bCreated = b['created'] as String? ?? '';
        return bCreated.compareTo(aCreated);
      });

      // Apply pagination
      final total = videos.length;
      if (offset != null && offset > 0) {
        videos = videos.skip(offset).toList();
      }
      if (limit != null && limit > 0) {
        videos = videos.take(limit).toList();
      }

      return {
        'success': true,
        'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'filters': {
          if (category != null) 'category': category,
          if (tag != null) 'tag': tag,
          if (folder != null) 'folder': folder,
          if (visibility != null) 'visibility': visibility.name,
          if (limit != null) 'limit': limit,
          if (offset != null) 'offset': offset,
        },
        'total': total,
        'count': videos.length,
        'videos': videos,
      };
    } catch (e) {
      _log('ERROR', 'Error in videos API: $e');
      return {
        'success': false,
        'error': 'Internal server error',
        'message': e.toString(),
      };
    }
  }

  // ============================================================
  // GET /api/videos/{videoId} - Get video details
  // ============================================================

  /// Handle GET /api/videos/{videoId} - returns video details
  Future<Map<String, dynamic>> getVideoDetails(String videoId, {String? requesterNpub}) async {
    try {
      // Find the video folder
      final videoFolderPath = await VideoFolderUtils.findVideoPath(_videosPath, videoId);

      if (videoFolderPath == null) {
        _log('WARN', 'getVideoDetails: video not found: $videoId');
        return {'error': 'Video not found', 'http_status': 404};
      }

      // Read video.txt
      final videoFilePath = VideoFolderUtils.buildVideoFilePath(videoFolderPath);
      final videoFile = File(videoFilePath);
      if (!await videoFile.exists()) {
        return {'error': 'Video metadata not found', 'http_status': 404};
      }

      final content = await videoFile.readAsString();
      final video = VideoParser.parseVideoContent(
        content: content,
        videoId: videoId,
        folderPath: videoFolderPath,
      );

      // Check visibility
      if (video.isPrivate) {
        return {'error': 'Video not available', 'http_status': 403};
      }

      // Check restricted access
      if (video.isRestricted) {
        if (requesterNpub == null || !video.allowedUsers.contains(requesterNpub)) {
          // TODO: Check group membership
          return {'error': 'Access denied', 'http_status': 403};
        }
      }

      // Load feedback counts
      final feedbackCounts = await FeedbackFolderUtils.getAllFeedbackCounts(
        videoFolderPath,
        storage: storage,
      );

      // Get comment count
      final commentCount = await FeedbackCommentUtils.getCommentCount(
        videoFolderPath,
        storage: storage,
      );

      // Get requester's feedback state if npub provided
      Map<String, bool> userFeedbackState = {};
      if (requesterNpub != null) {
        userFeedbackState = await FeedbackFolderUtils.getUserFeedbackState(
          videoFolderPath,
          requesterNpub,
          storage: storage,
        );
      }

      // Find thumbnail
      final thumbnailPath = await VideoFolderUtils.findThumbnailPath(videoFolderPath);
      final hasThumbnail = thumbnailPath != null;

      return {
        'success': true,
        'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'video': {
          'id': video.id,
          'author': video.author,
          'created': video.created,
          if (video.edited != null) 'edited': video.edited,
          'titles': video.titles,
          'descriptions': video.descriptions,
          'duration': video.duration,
          'formattedDuration': video.formattedDuration,
          'resolution': video.resolution,
          'fileSize': video.fileSize,
          'formattedFileSize': video.formattedFileSize,
          'mimeType': video.mimeType,
          'category': video.category.name,
          'visibility': video.visibility.name,
          'tags': video.tags,
          if (video.hasLocation) 'coordinates': '${video.latitude},${video.longitude}',
          'websites': video.websites,
          'social': video.social,
          if (video.contact != null) 'contact': video.contact,
          if (video.npub != null) 'npub': video.npub,
          'hasThumbnail': hasThumbnail,
          // Feedback
          'likesCount': feedbackCounts[FeedbackFolderUtils.feedbackTypeLikes] ?? 0,
          'pointsCount': feedbackCounts[FeedbackFolderUtils.feedbackTypePoints] ?? 0,
          'dislikesCount': feedbackCounts[FeedbackFolderUtils.feedbackTypeDislikes] ?? 0,
          'viewsCount': feedbackCounts[FeedbackFolderUtils.feedbackTypeViews] ?? 0,
          'commentCount': commentCount,
          // Emoji reactions
          'heartCount': feedbackCounts[FeedbackFolderUtils.reactionHeart] ?? 0,
          'thumbsUpCount': feedbackCounts[FeedbackFolderUtils.reactionThumbsUp] ?? 0,
          'thumbsDownCount': feedbackCounts[FeedbackFolderUtils.reactionThumbsDown] ?? 0,
          'fireCount': feedbackCounts[FeedbackFolderUtils.reactionFire] ?? 0,
          'hundredCount': feedbackCounts[FeedbackFolderUtils.reactionHundred] ?? 0,
          'curiousCount': feedbackCounts[FeedbackFolderUtils.reactionCurious] ?? 0,
          'celebrateCount': feedbackCounts[FeedbackFolderUtils.reactionCelebrate] ?? 0,
          'laughCount': feedbackCounts[FeedbackFolderUtils.reactionLaugh] ?? 0,
          'sadCount': feedbackCounts[FeedbackFolderUtils.reactionSad] ?? 0,
          'beerCheersCount': feedbackCounts[FeedbackFolderUtils.reactionBeerCheers] ?? 0,
          'surpriseCount': feedbackCounts[FeedbackFolderUtils.reactionSurprise] ?? 0,
          // User state
          if (requesterNpub != null) ...{
            'hasLiked': userFeedbackState[FeedbackFolderUtils.feedbackTypeLikes] ?? false,
            'hasPointed': userFeedbackState[FeedbackFolderUtils.feedbackTypePoints] ?? false,
            'hasDisliked': userFeedbackState[FeedbackFolderUtils.feedbackTypeDislikes] ?? false,
            'hasHearted': userFeedbackState[FeedbackFolderUtils.reactionHeart] ?? false,
            'hasThumbsUp': userFeedbackState[FeedbackFolderUtils.reactionThumbsUp] ?? false,
            'hasThumbsDown': userFeedbackState[FeedbackFolderUtils.reactionThumbsDown] ?? false,
            'hasFired': userFeedbackState[FeedbackFolderUtils.reactionFire] ?? false,
            'hasHundred': userFeedbackState[FeedbackFolderUtils.reactionHundred] ?? false,
            'hasCurious': userFeedbackState[FeedbackFolderUtils.reactionCurious] ?? false,
            'hasCelebrated': userFeedbackState[FeedbackFolderUtils.reactionCelebrate] ?? false,
            'hasLaughed': userFeedbackState[FeedbackFolderUtils.reactionLaugh] ?? false,
            'hasSad': userFeedbackState[FeedbackFolderUtils.reactionSad] ?? false,
            'hasBeerCheers': userFeedbackState[FeedbackFolderUtils.reactionBeerCheers] ?? false,
            'hasSurprised': userFeedbackState[FeedbackFolderUtils.reactionSurprise] ?? false,
          },
        },
      };
    } catch (e) {
      _log('ERROR', 'Error in video details API: $e');
      return {
        'success': false,
        'error': 'Internal server error',
        'message': e.toString(),
      };
    }
  }

  // ============================================================
  // GET /api/videos/{videoId}/thumbnail - Get thumbnail image
  // ============================================================

  /// Handle GET /api/videos/{videoId}/thumbnail - returns thumbnail file path
  Future<Map<String, dynamic>> getThumbnail(String videoId) async {
    try {
      final videoFolderPath = await VideoFolderUtils.findVideoPath(_videosPath, videoId);

      if (videoFolderPath == null) {
        return {'error': 'Video not found', 'http_status': 404};
      }

      final thumbnailPath = await VideoFolderUtils.findThumbnailPath(videoFolderPath);

      if (thumbnailPath == null) {
        return {'error': 'Thumbnail not found', 'http_status': 404};
      }

      // Return the file path - caller should serve the file
      final ext = thumbnailPath.split('.').last.toLowerCase();
      String mimeType = 'image/jpeg';
      if (ext == 'png') mimeType = 'image/png';

      return {
        'success': true,
        'filePath': thumbnailPath,
        'mimeType': mimeType,
      };
    } catch (e) {
      _log('ERROR', 'Error in thumbnail API: $e');
      return {
        'success': false,
        'error': 'Internal server error',
        'message': e.toString(),
      };
    }
  }

  // ============================================================
  // GET /api/videos/{videoId}/feedback - Get feedback counts
  // ============================================================

  /// Handle GET /api/videos/{videoId}/feedback - returns feedback counts and state
  Future<Map<String, dynamic>> getFeedback(String videoId, {String? npub}) async {
    try {
      final videoFolderPath = await VideoFolderUtils.findVideoPath(_videosPath, videoId);

      if (videoFolderPath == null) {
        return {'error': 'Video not found', 'http_status': 404};
      }

      // Load feedback counts
      final counts = await FeedbackFolderUtils.getAllFeedbackCounts(
        videoFolderPath,
        storage: storage,
      );

      // Get comment count
      final commentCount = await FeedbackCommentUtils.getCommentCount(
        videoFolderPath,
        storage: storage,
      );

      // Get user state if npub provided
      Map<String, bool>? userState;
      if (npub != null) {
        userState = await FeedbackFolderUtils.getUserFeedbackState(
          videoFolderPath,
          npub,
          storage: storage,
        );
      }

      return {
        'success': true,
        'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'videoId': videoId,
        'counts': {
          'likes': counts[FeedbackFolderUtils.feedbackTypeLikes] ?? 0,
          'points': counts[FeedbackFolderUtils.feedbackTypePoints] ?? 0,
          'dislikes': counts[FeedbackFolderUtils.feedbackTypeDislikes] ?? 0,
          'views': counts[FeedbackFolderUtils.feedbackTypeViews] ?? 0,
          'comments': commentCount,
          'heart': counts[FeedbackFolderUtils.reactionHeart] ?? 0,
          'thumbsUp': counts[FeedbackFolderUtils.reactionThumbsUp] ?? 0,
          'fire': counts[FeedbackFolderUtils.reactionFire] ?? 0,
          'celebrate': counts[FeedbackFolderUtils.reactionCelebrate] ?? 0,
          'laugh': counts[FeedbackFolderUtils.reactionLaugh] ?? 0,
          'sad': counts[FeedbackFolderUtils.reactionSad] ?? 0,
          'surprise': counts[FeedbackFolderUtils.reactionSurprise] ?? 0,
        },
        if (userState != null) 'userState': userState,
      };
    } catch (e) {
      _log('ERROR', 'Error in feedback API: $e');
      return {
        'success': false,
        'error': 'Internal server error',
        'message': e.toString(),
      };
    }
  }

  // ============================================================
  // POST /api/videos/{videoId}/like - Toggle like
  // ============================================================

  /// Handle POST /api/videos/{videoId}/like - toggle like
  Future<Map<String, dynamic>> toggleLike(String videoId, Map<String, dynamic> eventJson) async {
    return _toggleFeedback(videoId, FeedbackFolderUtils.feedbackTypeLikes, eventJson);
  }

  // ============================================================
  // POST /api/videos/{videoId}/point - Toggle point
  // ============================================================

  /// Handle POST /api/videos/{videoId}/point - toggle point
  Future<Map<String, dynamic>> togglePoint(String videoId, Map<String, dynamic> eventJson) async {
    return _toggleFeedback(videoId, FeedbackFolderUtils.feedbackTypePoints, eventJson);
  }

  // ============================================================
  // POST /api/videos/{videoId}/dislike - Toggle dislike
  // ============================================================

  /// Handle POST /api/videos/{videoId}/dislike - toggle dislike
  Future<Map<String, dynamic>> toggleDislike(String videoId, Map<String, dynamic> eventJson) async {
    return _toggleFeedback(videoId, FeedbackFolderUtils.feedbackTypeDislikes, eventJson);
  }

  // ============================================================
  // POST /api/videos/{videoId}/react - Toggle emoji reaction
  // ============================================================

  /// Handle POST /api/videos/{videoId}/react - toggle emoji reaction
  Future<Map<String, dynamic>> toggleReaction(
    String videoId,
    String reaction,
    Map<String, dynamic> eventJson,
  ) async {
    // Validate reaction type
    if (!FeedbackFolderUtils.supportedReactions.contains(reaction)) {
      return {'error': 'Invalid reaction type', 'http_status': 400};
    }
    return _toggleFeedback(videoId, reaction, eventJson);
  }

  // ============================================================
  // POST /api/videos/{videoId}/view - Record view
  // ============================================================

  /// Handle POST /api/videos/{videoId}/view - record view
  Future<Map<String, dynamic>> recordView(String videoId, Map<String, dynamic> eventJson) async {
    try {
      final videoFolderPath = await VideoFolderUtils.findVideoPath(_videosPath, videoId);

      if (videoFolderPath == null) {
        return {'error': 'Video not found', 'http_status': 404};
      }

      // Parse and verify event
      final event = NostrEvent.fromJson(eventJson);
      if (!event.verify()) {
        return {'error': 'Invalid signature', 'http_status': 401};
      }

      // Record view
      final success = await FeedbackFolderUtils.recordViewEvent(
        videoFolderPath,
        event,
        storage: storage,
      );

      if (!success) {
        return {'error': 'Failed to record view', 'http_status': 500};
      }

      // Get updated count
      final viewCount = await FeedbackFolderUtils.getViewCount(
        videoFolderPath,
        storage: storage,
      );

      return {
        'success': true,
        'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'videoId': videoId,
        'viewsCount': viewCount,
      };
    } catch (e) {
      _log('ERROR', 'Error in view API: $e');
      return {
        'success': false,
        'error': 'Internal server error',
        'message': e.toString(),
      };
    }
  }

  // ============================================================
  // POST /api/videos/{videoId}/comment - Add comment
  // ============================================================

  /// Handle POST /api/videos/{videoId}/comment - add comment
  Future<Map<String, dynamic>> addComment(
    String videoId,
    String author,
    String content, {
    String? npub,
    String? signature,
  }) async {
    try {
      final videoFolderPath = await VideoFolderUtils.findVideoPath(_videosPath, videoId);

      if (videoFolderPath == null) {
        return {'error': 'Video not found', 'http_status': 404};
      }

      if (content.trim().isEmpty) {
        return {'error': 'Comment content is required', 'http_status': 400};
      }

      // Write comment
      final commentId = await FeedbackCommentUtils.writeComment(
        contentPath: videoFolderPath,
        author: author,
        content: content.trim(),
        npub: npub,
        signature: signature,
        storage: storage,
      );

      return {
        'success': true,
        'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'videoId': videoId,
        'commentId': commentId,
      };
    } catch (e) {
      _log('ERROR', 'Error in add comment API: $e');
      return {
        'success': false,
        'error': 'Internal server error',
        'message': e.toString(),
      };
    }
  }

  // ============================================================
  // DELETE /api/videos/{videoId}/comment/{commentId} - Delete comment
  // ============================================================

  /// Handle DELETE /api/videos/{videoId}/comment/{commentId} - delete comment
  Future<Map<String, dynamic>> deleteComment(
    String videoId,
    String commentId,
    String requesterNpub,
  ) async {
    try {
      final videoFolderPath = await VideoFolderUtils.findVideoPath(_videosPath, videoId);

      if (videoFolderPath == null) {
        return {'error': 'Video not found', 'http_status': 404};
      }

      // Load comment to check ownership
      final comment = await FeedbackCommentUtils.getComment(
        videoFolderPath,
        commentId,
        storage: storage,
      );
      if (comment == null) {
        return {'error': 'Comment not found', 'http_status': 404};
      }

      // Check if requester is the author (by npub)
      if (comment.npub != requesterNpub) {
        // TODO: Check if requester is video owner or moderator
        return {'error': 'Not authorized to delete this comment', 'http_status': 403};
      }

      // Delete comment
      final deleted = await FeedbackCommentUtils.deleteComment(
        videoFolderPath,
        commentId,
        storage: storage,
      );

      if (!deleted) {
        return {'error': 'Failed to delete comment', 'http_status': 500};
      }

      return {
        'success': true,
        'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'videoId': videoId,
        'commentId': commentId,
        'deleted': true,
      };
    } catch (e) {
      _log('ERROR', 'Error in delete comment API: $e');
      return {
        'success': false,
        'error': 'Internal server error',
        'message': e.toString(),
      };
    }
  }

  // ============================================================
  // GET /api/videos/{videoId}/comments - List comments
  // ============================================================

  /// Handle GET /api/videos/{videoId}/comments - list comments
  Future<Map<String, dynamic>> getComments(String videoId, {int? limit, int? offset}) async {
    try {
      final videoFolderPath = await VideoFolderUtils.findVideoPath(_videosPath, videoId);

      if (videoFolderPath == null) {
        return {'error': 'Video not found', 'http_status': 404};
      }

      // Load comments
      var comments = await FeedbackCommentUtils.loadComments(
        videoFolderPath,
        storage: storage,
      );

      // Sort newest first
      comments.sort((a, b) => b.created.compareTo(a.created));

      // Apply pagination
      final total = comments.length;
      if (offset != null && offset > 0) {
        comments = comments.skip(offset).toList();
      }
      if (limit != null && limit > 0) {
        comments = comments.take(limit).toList();
      }

      return {
        'success': true,
        'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'videoId': videoId,
        'total': total,
        'count': comments.length,
        'comments': comments.map((c) => {
          'id': c.id,
          'author': c.author,
          'created': c.created,
          'content': c.content,
          if (c.npub != null) 'npub': c.npub,
          if (c.signature != null) 'signature': c.signature,
        }).toList(),
      };
    } catch (e) {
      _log('ERROR', 'Error in comments API: $e');
      return {
        'success': false,
        'error': 'Internal server error',
        'message': e.toString(),
      };
    }
  }

  // ============================================================
  // GET /api/videos/folders - List folder structure
  // ============================================================

  /// Handle GET /api/videos/folders - list folder structure
  Future<Map<String, dynamic>> getFolders({String? path}) async {
    try {
      String basePath = _videosPath;
      if (path != null && path.isNotEmpty) {
        basePath = '$_videosPath/$path';
      }

      // List subfolders
      final subfolderNames = await VideoFolderUtils.listSubfolders(basePath);
      final subfolders = <Map<String, dynamic>>[];

      for (final name in subfolderNames) {
        final folderPath = '$basePath/$name';
        final folder = <String, dynamic>{'name': name};

        // Try to load folder metadata
        final metaFile = File('$folderPath/${VideoFolderUtils.folderMetadataFile}');
        if (await metaFile.exists()) {
          final content = await metaFile.readAsString();
          final meta = VideoParser.parseFolderMetadata(content);
          if (meta != null) {
            folder['displayName'] = meta['name'] ?? name;
            if (meta['description'] != null) folder['description'] = meta['description'];
            if (meta['created'] != null) folder['created'] = meta['created'];
          }
        }

        // Count videos in folder
        final videoCount = await _countVideosInFolder(folderPath);
        folder['videoCount'] = videoCount;

        subfolders.add(folder);
      }

      // List videos in current folder
      final videoIds = await VideoFolderUtils.listVideosInFolder(basePath);

      return {
        'success': true,
        'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'path': path ?? '',
        'folders': subfolders,
        'videos': videoIds,
      };
    } catch (e) {
      _log('ERROR', 'Error in folders API: $e');
      return {
        'success': false,
        'error': 'Internal server error',
        'message': e.toString(),
      };
    }
  }

  // ============================================================
  // GET /api/videos/categories - List available categories
  // ============================================================

  /// Handle GET /api/videos/categories - list available categories
  Future<Map<String, dynamic>> getCategories() async {
    try {
      final categories = VideoCategory.values.map((c) => {
        'name': c.name,
        'displayName': c.displayName,
      }).toList();

      return {
        'success': true,
        'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'categories': categories,
      };
    } catch (e) {
      _log('ERROR', 'Error in categories API: $e');
      return {
        'success': false,
        'error': 'Internal server error',
        'message': e.toString(),
      };
    }
  }

  // ============================================================
  // GET /api/videos/tags - List all tags
  // ============================================================

  /// Handle GET /api/videos/tags - list all unique tags
  Future<Map<String, dynamic>> getTags() async {
    try {
      final videos = await _loadAllVideos(publicOnly: true);
      final tags = <String>{};

      for (final video in videos) {
        final videoTags = video['tags'] as List<dynamic>? ?? [];
        for (final tag in videoTags) {
          tags.add(tag.toString());
        }
      }

      final tagList = tags.toList()..sort();

      return {
        'success': true,
        'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'count': tagList.length,
        'tags': tagList,
      };
    } catch (e) {
      _log('ERROR', 'Error in tags API: $e');
      return {
        'success': false,
        'error': 'Internal server error',
        'message': e.toString(),
      };
    }
  }

  // ============================================================
  // Internal Helper Methods
  // ============================================================

  /// Load all videos as maps (for API response)
  Future<List<Map<String, dynamic>>> _loadAllVideos({bool publicOnly = true}) async {
    final videos = <Map<String, dynamic>>[];

    final videoPaths = await VideoFolderUtils.findAllVideoPaths(_videosPath);

    for (final videoFolderPath in videoPaths) {
      try {
        final videoFilePath = VideoFolderUtils.buildVideoFilePath(videoFolderPath);
        final videoFile = File(videoFilePath);

        if (!await videoFile.exists()) continue;

        final content = await videoFile.readAsString();
        final videoId = videoFolderPath.split('/').last;

        final video = VideoParser.parseVideoContent(
          content: content,
          videoId: videoId,
          folderPath: videoFolderPath,
        );

        // Skip private videos for public listings
        if (publicOnly && video.isPrivate) continue;

        // Skip restricted videos for public listings
        if (publicOnly && video.isRestricted) continue;

        // Find thumbnail
        final thumbnailPath = await VideoFolderUtils.findThumbnailPath(videoFolderPath);

        videos.add({
          'id': video.id,
          'author': video.author,
          'created': video.created,
          'titles': video.titles,
          'duration': video.duration,
          'formattedDuration': video.formattedDuration,
          'resolution': video.resolution,
          'fileSize': video.fileSize,
          'formattedFileSize': video.formattedFileSize,
          'category': video.category.name,
          'visibility': video.visibility.name,
          'tags': video.tags,
          'hasThumbnail': thumbnailPath != null,
          'folderPath': videoFolderPath,
        });
      } catch (e) {
        _log('WARN', 'Error loading video from $videoFolderPath: $e');
      }
    }

    return videos;
  }

  /// Toggle feedback (like, point, dislike, reaction)
  Future<Map<String, dynamic>> _toggleFeedback(
    String videoId,
    String feedbackType,
    Map<String, dynamic> eventJson,
  ) async {
    try {
      final videoFolderPath = await VideoFolderUtils.findVideoPath(_videosPath, videoId);

      if (videoFolderPath == null) {
        return {'error': 'Video not found', 'http_status': 404};
      }

      // Parse and verify event
      final event = NostrEvent.fromJson(eventJson);
      if (!event.verify()) {
        return {'error': 'Invalid signature', 'http_status': 401};
      }

      // Toggle feedback
      final result = await FeedbackFolderUtils.toggleFeedbackEvent(
        videoFolderPath,
        feedbackType,
        event,
        storage: storage,
      );

      if (result == null) {
        return {'error': 'Failed to toggle feedback', 'http_status': 500};
      }

      // Get updated count
      final count = await FeedbackFolderUtils.getFeedbackCount(
        videoFolderPath,
        feedbackType,
        storage: storage,
      );

      return {
        'success': true,
        'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'videoId': videoId,
        'feedbackType': feedbackType,
        'isActive': result,
        'count': count,
      };
    } catch (e) {
      _log('ERROR', 'Error in toggle feedback API: $e');
      return {
        'success': false,
        'error': 'Internal server error',
        'message': e.toString(),
      };
    }
  }

  /// Count videos in a folder (recursive)
  Future<int> _countVideosInFolder(String folderPath) async {
    final videoPaths = await VideoFolderUtils.findAllVideoPaths(folderPath);
    return videoPaths.length;
  }
}
