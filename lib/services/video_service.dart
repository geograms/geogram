/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io';

import '../models/video.dart';
import '../models/blog_comment.dart';
import '../util/chat_format.dart';
import '../util/video_parser.dart';
import '../util/video_folder_utils.dart';
import '../util/video_metadata_extractor.dart';
import '../util/feedback_folder_utils.dart';
import '../util/feedback_comment_utils.dart';
import '../util/nostr_crypto.dart';
import '../util/nostr_event.dart';
import 'log_service.dart';
import 'profile_storage.dart';

/// Service for managing local video operations
///
/// Handles CRUD operations for videos, including:
/// - Loading videos from filesystem
/// - Creating new videos with metadata extraction
/// - Updating video metadata
/// - Deleting videos
/// - Managing feedback (likes, comments)
///
/// NOTE: Video operations currently require filesystem access due to:
/// - FFmpeg metadata extraction
/// - External utility classes (VideoFolderUtils, FeedbackFolderUtils)
/// Encrypted storage mode is not yet fully supported.
class VideoService {
  static final VideoService _instance = VideoService._internal();
  factory VideoService() => _instance;
  VideoService._internal();

  /// Profile storage for file operations (encrypted or filesystem)
  /// IMPORTANT: This MUST be set before using the service.
  late ProfileStorage _storage;

  String? _appPath;
  String? _callsign;
  String? _creatorNpub;

  /// Whether using encrypted storage
  bool get useEncryptedStorage => _storage.isEncrypted;

  /// Set the profile storage for file operations
  /// MUST be called before initializeApp
  void setStorage(ProfileStorage storage) {
    _storage = storage;
  }

  /// Initialize video service for a collection
  ///
  /// [appPath] - Path to videos collection root (e.g., .../devices/X1D808/videos)
  /// [callsign] - Current user's callsign
  /// [creatorNpub] - Current user's npub for admin checks
  Future<void> initializeApp(String appPath, {String? callsign, String? creatorNpub}) async {
    LogService().log('VideoService: Initializing with collection path: $appPath');
    _appPath = appPath;
    _callsign = callsign;
    _creatorNpub = creatorNpub;

    // Ensure videos directory exists using storage
    // Note: For actual video operations, we need filesystem access
    await _storage.createDirectory('');
    LogService().log('VideoService: Created videos directory');

    // Create callsign subdirectory if provided
    if (callsign != null && callsign.isNotEmpty) {
      await _storage.createDirectory(callsign);
      LogService().log('VideoService: Created callsign directory');
    }
  }

  /// Get path to user's videos folder
  String? get userVideosPath {
    if (_appPath == null || _callsign == null) return null;
    return '$_appPath/$_callsign';
  }

  /// Load all videos for a callsign
  ///
  /// [callsign] - Optional callsign (defaults to current user)
  /// [category] - Filter by category
  /// [visibility] - Filter by visibility
  /// [tag] - Filter by tag
  /// [folderPath] - Only load from specific folder path
  /// [recursive] - Whether to search subfolders
  /// [userNpub] - Current user's npub for feedback state
  Future<List<Video>> loadVideos({
    String? callsign,
    VideoCategory? category,
    VideoVisibility? visibility,
    String? tag,
    List<String>? folderPath,
    bool recursive = true,
    String? userNpub,
  }) async {
    if (_appPath == null) return [];

    final targetCallsign = callsign ?? _callsign;
    if (targetCallsign == null) return [];

    final videosPath = '$_appPath/$targetCallsign';
    final videos = <Video>[];

    // Determine search path
    String searchPath = videosPath;
    if (folderPath != null && folderPath.isNotEmpty) {
      searchPath = '$videosPath/${folderPath.join('/')}';
    }

    // Find all video folders
    List<String> videoPaths;
    if (recursive) {
      videoPaths = await VideoFolderUtils.findAllVideoPaths(searchPath);
    } else {
      // Non-recursive: only list videos in the immediate folder
      final videoIds = await VideoFolderUtils.listVideosInFolder(searchPath);
      videoPaths = videoIds.map((id) => '$searchPath/$id').toList();
    }

    // Load each video
    for (final videoFolderPath in videoPaths) {
      try {
        final video = await _loadVideoFromFolder(videoFolderPath, userNpub: userNpub);
        if (video != null) {
          // Apply filters
          if (category != null && video.category != category) continue;
          if (visibility != null && video.visibility != visibility) continue;
          if (tag != null && !video.tags.contains(tag)) continue;

          videos.add(video);
        }
      } catch (e) {
        LogService().log('VideoService: Error loading video from $videoFolderPath: $e');
      }
    }

    // Sort by creation date (newest first)
    videos.sort((a, b) => b.dateTime.compareTo(a.dateTime));

    return videos;
  }

  /// Load a single video by ID
  Future<Video?> loadVideo(String videoId, {String? callsign, String? userNpub}) async {
    if (_appPath == null) return null;

    final targetCallsign = callsign ?? _callsign;
    if (targetCallsign == null) return null;

    final videosPath = '$_appPath/$targetCallsign';
    final videoFolderPath = await VideoFolderUtils.findVideoPath(videosPath, videoId);

    if (videoFolderPath == null) return null;

    return _loadVideoFromFolder(videoFolderPath, userNpub: userNpub);
  }

  /// Load video with full details including feedback
  Future<Video?> loadFullVideoWithFeedback(
    String videoId, {
    String? callsign,
    String? userNpub,
  }) async {
    return loadVideo(videoId, callsign: callsign, userNpub: userNpub);
  }

  /// Load video from a folder path
  Future<Video?> _loadVideoFromFolder(String videoFolderPath, {String? userNpub}) async {
    final videoFilePath = VideoFolderUtils.buildVideoFilePath(videoFolderPath);
    final videoFile = File(videoFilePath);

    if (!await videoFile.exists()) return null;

    try {
      final content = await videoFile.readAsString();
      final videoId = videoFolderPath.split('/').last;

      // Parse video metadata
      var video = VideoParser.parseVideoContent(
        content: content,
        videoId: videoId,
        folderPath: videoFolderPath,
      );

      // Find video file first (needed for thumbnail generation)
      final videoMediaPath = await VideoFolderUtils.findVideoMediaPath(videoFolderPath);

      // Find thumbnail, generate if missing
      String? thumbnailPath = await VideoFolderUtils.findThumbnailPath(videoFolderPath);
      if (thumbnailPath == null && videoMediaPath != null) {
        // Auto-generate thumbnail for existing videos
        final thumbnailOutputPath = VideoFolderUtils.buildThumbnailPath(videoFolderPath);
        final thumbnailTime = VideoMetadataExtractor.getRecommendedThumbnailTime(video.duration);
        thumbnailPath = await VideoMetadataExtractor.generateThumbnail(
          videoMediaPath,
          thumbnailOutputPath,
          atSeconds: thumbnailTime,
        );
        if (thumbnailPath != null) {
          LogService().log('VideoService: Auto-generated thumbnail for $videoId');
        }
      }

      // Load feedback counts
      final feedbackCounts = await FeedbackFolderUtils.getAllFeedbackCounts(videoFolderPath, storage: _storage);

      // Get comment count
      final commentsPath = FeedbackFolderUtils.buildCommentsPath(videoFolderPath);
      int commentCount = 0;
      final commentsDir = Directory(commentsPath);
      if (await commentsDir.exists()) {
        final commentFiles = await commentsDir.list().where((e) => e is File).length;
        commentCount = commentFiles;
      }

      // Get user feedback state
      Map<String, bool> userFeedbackState = {};
      if (userNpub != null) {
        userFeedbackState = await FeedbackFolderUtils.getUserFeedbackState(videoFolderPath, userNpub, storage: _storage);
      }

      // Update video with additional info
      video = video.copyWith(
        folderPath: videoFolderPath,
        thumbnailPath: thumbnailPath,
        videoFilePath: videoMediaPath,
        isLocal: videoMediaPath != null,
        likesCount: feedbackCounts[FeedbackFolderUtils.feedbackTypeLikes] ?? 0,
        pointsCount: feedbackCounts[FeedbackFolderUtils.feedbackTypePoints] ?? 0,
        dislikesCount: feedbackCounts[FeedbackFolderUtils.feedbackTypeDislikes] ?? 0,
        subscribeCount: feedbackCounts[FeedbackFolderUtils.feedbackTypeSubscribe] ?? 0,
        verificationsCount: feedbackCounts[FeedbackFolderUtils.feedbackTypeVerifications] ?? 0,
        viewsCount: feedbackCounts[FeedbackFolderUtils.feedbackTypeViews] ?? 0,
        heartCount: feedbackCounts[FeedbackFolderUtils.reactionHeart] ?? 0,
        thumbsUpCount: feedbackCounts[FeedbackFolderUtils.reactionThumbsUp] ?? 0,
        fireCount: feedbackCounts[FeedbackFolderUtils.reactionFire] ?? 0,
        celebrateCount: feedbackCounts[FeedbackFolderUtils.reactionCelebrate] ?? 0,
        laughCount: feedbackCounts[FeedbackFolderUtils.reactionLaugh] ?? 0,
        sadCount: feedbackCounts[FeedbackFolderUtils.reactionSad] ?? 0,
        surpriseCount: feedbackCounts[FeedbackFolderUtils.reactionSurprise] ?? 0,
        commentCount: commentCount,
        hasLiked: userFeedbackState[FeedbackFolderUtils.feedbackTypeLikes] ?? false,
        hasPointed: userFeedbackState[FeedbackFolderUtils.feedbackTypePoints] ?? false,
        hasDisliked: userFeedbackState[FeedbackFolderUtils.feedbackTypeDislikes] ?? false,
        hasSubscribed: userFeedbackState[FeedbackFolderUtils.feedbackTypeSubscribe] ?? false,
        hasVerified: userFeedbackState[FeedbackFolderUtils.feedbackTypeVerifications] ?? false,
        hasHearted: userFeedbackState[FeedbackFolderUtils.reactionHeart] ?? false,
        hasThumbsUp: userFeedbackState[FeedbackFolderUtils.reactionThumbsUp] ?? false,
        hasFired: userFeedbackState[FeedbackFolderUtils.reactionFire] ?? false,
        hasCelebrated: userFeedbackState[FeedbackFolderUtils.reactionCelebrate] ?? false,
        hasLaughed: userFeedbackState[FeedbackFolderUtils.reactionLaugh] ?? false,
        hasSad: userFeedbackState[FeedbackFolderUtils.reactionSad] ?? false,
        hasSurprised: userFeedbackState[FeedbackFolderUtils.reactionSurprise] ?? false,
      );

      return video;
    } catch (e) {
      LogService().log('VideoService: Error loading video from folder: $e');
      return null;
    }
  }

  /// Create a new video
  ///
  /// [title] - Video title (single language)
  /// [titles] - Multilingual titles {langCode: title}
  /// [sourceVideoPath] - Path to source video file
  /// [category] - Video category
  /// [description] - Single language description
  /// [descriptions] - Multilingual descriptions {langCode: desc}
  /// [tags] - List of tags
  /// [visibility] - Video visibility
  /// [latitude]/[longitude] - Optional coordinates
  /// [folderPath] - Parent folder path segments
  /// [npub]/[nsec] - NOSTR keys for signing
  Future<Video?> createVideo({
    String? title,
    Map<String, String>? titles,
    required String sourceVideoPath,
    required VideoCategory category,
    String? description,
    Map<String, String>? descriptions,
    List<String>? tags,
    VideoVisibility visibility = VideoVisibility.public,
    double? latitude,
    double? longitude,
    List<String>? websites,
    List<String>? social,
    String? contact,
    List<String>? allowedGroups,
    List<String>? allowedUsers,
    List<String>? folderPath,
    String? npub,
    String? nsec,
  }) async {
    if (_appPath == null || _callsign == null) {
      LogService().log('VideoService: Not initialized');
      return null;
    }

    // Validate we have at least one title
    final finalTitles = titles ?? (title != null ? {'EN': title} : null);
    if (finalTitles == null || finalTitles.isEmpty) {
      LogService().log('VideoService: Title is required');
      return null;
    }

    // Validate folder depth
    if (folderPath != null && !VideoFolderUtils.isValidFolderDepth(folderPath)) {
      LogService().log('VideoService: Folder depth exceeds maximum (${VideoFolderUtils.maxFolderDepth})');
      return null;
    }

    // Extract video metadata
    final metadata = await VideoMetadataExtractor.extract(sourceVideoPath);
    if (metadata == null) {
      LogService().log('VideoService: Could not extract video metadata');
      // Try to get basic file info
      final basicMeta = await VideoMetadataExtractor.getBasicMetadata(sourceVideoPath);
      if (basicMeta == null) {
        return null;
      }
    }

    try {
      // Generate video folder name
      final baseName = finalTitles['EN'] ?? finalTitles.values.first;
      final parentPath = folderPath != null && folderPath.isNotEmpty
          ? '$_appPath/$_callsign/${folderPath.join('/')}'
          : '$_appPath/$_callsign';

      // Ensure parent folder exists
      await Directory(parentPath).create(recursive: true);

      final videoId = await VideoFolderUtils.generateUniqueFolderName(parentPath, baseName);
      final videoFolderPath = '$parentPath/$videoId';

      // Create video folder
      await VideoFolderUtils.createVideoFolder(videoFolderPath);

      // Copy video file
      final sourceFile = File(sourceVideoPath);
      final sourceExt = sourceVideoPath.split('.').last.toLowerCase();
      final destVideoPath = '$videoFolderPath/video.$sourceExt';
      await sourceFile.copy(destVideoPath);

      // Generate thumbnail
      String? thumbnailPath;
      final thumbnailOutputPath = VideoFolderUtils.buildThumbnailPath(videoFolderPath);
      if (metadata != null) {
        final thumbnailTime = VideoMetadataExtractor.getRecommendedThumbnailTime(metadata.duration);
        thumbnailPath = await VideoMetadataExtractor.generateThumbnail(
          destVideoPath,
          thumbnailOutputPath,
          atSeconds: thumbnailTime,
        );
      }

      // Build descriptions
      final finalDescriptions = descriptions ?? (description != null ? {'EN': description} : <String, String>{});

      // Create video object
      final now = DateTime.now();
      final timestamp = ChatFormat.formatTimestamp(now);

      var video = Video(
        id: videoId,
        author: _callsign!,
        created: timestamp,
        titles: finalTitles,
        descriptions: finalDescriptions,
        duration: metadata?.duration ?? 0,
        resolution: metadata?.resolution ?? '0x0',
        fileSize: metadata?.fileSize ?? (await sourceFile.length()),
        mimeType: metadata?.mimeType ?? VideoFolderUtils.getMimeType(sourceVideoPath),
        category: category,
        visibility: visibility,
        tags: tags ?? [],
        latitude: latitude,
        longitude: longitude,
        websites: websites ?? [],
        social: social ?? [],
        contact: contact,
        allowedGroups: allowedGroups ?? [],
        allowedUsers: allowedUsers ?? [],
        npub: npub,
        folderPath: videoFolderPath,
        thumbnailPath: thumbnailPath,
        videoFilePath: destVideoPath,
        isLocal: true,
      );

      // Sign with NOSTR if keys provided
      if (npub != null && nsec != null) {
        video = await _signVideo(video, npub, nsec);
      }

      // Write video.txt
      final videoContent = video.exportAsText();
      final videoFilePath = VideoFolderUtils.buildVideoFilePath(videoFolderPath);
      await File(videoFilePath).writeAsString(videoContent, flush: true);

      LogService().log('VideoService: Created video $videoId');
      return video;
    } catch (e) {
      LogService().log('VideoService: Error creating video: $e');
      return null;
    }
  }

  /// Update video metadata
  Future<bool> updateVideo({
    required String videoId,
    String? callsign,
    String? title,
    Map<String, String>? titles,
    String? description,
    Map<String, String>? descriptions,
    List<String>? tags,
    VideoCategory? category,
    VideoVisibility? visibility,
    double? latitude,
    double? longitude,
    List<String>? websites,
    List<String>? social,
    String? contact,
    List<String>? allowedGroups,
    List<String>? allowedUsers,
    String? npub,
    String? nsec,
  }) async {
    final targetCallsign = callsign ?? _callsign;
    if (_appPath == null || targetCallsign == null) return false;

    try {
      // Load existing video
      var video = await loadVideo(videoId, callsign: targetCallsign);
      if (video == null) return false;

      // Update fields
      final now = DateTime.now();
      final editedTimestamp = ChatFormat.formatTimestamp(now);

      // Handle title updates
      Map<String, String> finalTitles = video.titles;
      if (titles != null) {
        finalTitles = titles;
      } else if (title != null) {
        finalTitles = {'EN': title};
      }

      // Handle description updates
      Map<String, String> finalDescriptions = video.descriptions;
      if (descriptions != null) {
        finalDescriptions = descriptions;
      } else if (description != null) {
        finalDescriptions = {'EN': description};
      }

      video = video.copyWith(
        edited: editedTimestamp,
        titles: finalTitles,
        descriptions: finalDescriptions,
        tags: tags ?? video.tags,
        category: category ?? video.category,
        visibility: visibility ?? video.visibility,
        latitude: latitude ?? video.latitude,
        longitude: longitude ?? video.longitude,
        websites: websites ?? video.websites,
        social: social ?? video.social,
        contact: contact ?? video.contact,
        allowedGroups: allowedGroups ?? video.allowedGroups,
        allowedUsers: allowedUsers ?? video.allowedUsers,
        npub: npub ?? video.npub,
      );

      // Re-sign if keys provided
      if (npub != null && nsec != null) {
        video = await _signVideo(video, npub, nsec);
      }

      // Write updated video.txt
      final videoContent = video.exportAsText();
      final videoFilePath = VideoFolderUtils.buildVideoFilePath(video.folderPath!);
      await File(videoFilePath).writeAsString(videoContent, flush: true);

      LogService().log('VideoService: Updated video $videoId');
      return true;
    } catch (e) {
      LogService().log('VideoService: Error updating video: $e');
      return false;
    }
  }

  /// Delete a video
  Future<bool> deleteVideo(String videoId, {String? callsign}) async {
    final targetCallsign = callsign ?? _callsign;
    if (_appPath == null || targetCallsign == null) return false;

    try {
      final videosPath = '$_appPath/$targetCallsign';
      final videoFolderPath = await VideoFolderUtils.findVideoPath(videosPath, videoId);

      if (videoFolderPath == null) return false;

      // Delete the entire folder
      await Directory(videoFolderPath).delete(recursive: true);

      LogService().log('VideoService: Deleted video $videoId');
      return true;
    } catch (e) {
      LogService().log('VideoService: Error deleting video: $e');
      return false;
    }
  }

  /// Update video thumbnail by extracting frame at specified timestamp
  ///
  /// Returns the new thumbnail path on success, null on failure
  Future<String?> updateThumbnail(
    String videoId, {
    required int atSeconds,
    String? callsign,
  }) async {
    final targetCallsign = callsign ?? _callsign;
    if (_appPath == null || targetCallsign == null) return null;

    try {
      final videosPath = '$_appPath/$targetCallsign';
      final videoFolderPath = await VideoFolderUtils.findVideoPath(videosPath, videoId);

      if (videoFolderPath == null) {
        LogService().log('VideoService: Video folder not found for $videoId');
        return null;
      }

      // Find the video file
      final videoFilePath = await VideoFolderUtils.findVideoMediaPath(videoFolderPath);
      if (videoFilePath == null) {
        LogService().log('VideoService: Video file not found in $videoFolderPath');
        return null;
      }

      // Generate new thumbnail
      final thumbnailPath = VideoFolderUtils.buildThumbnailPath(videoFolderPath);
      final result = await VideoMetadataExtractor.generateThumbnail(
        videoFilePath,
        thumbnailPath,
        atSeconds: atSeconds,
      );

      if (result != null) {
        LogService().log('VideoService: Updated thumbnail for $videoId at ${atSeconds}s');
      }

      return result;
    } catch (e) {
      LogService().log('VideoService: Error updating thumbnail: $e');
      return null;
    }
  }

  /// Move video to a different folder
  Future<bool> moveVideo(
    String videoId, {
    required List<String> newFolderPath,
    String? callsign,
  }) async {
    final targetCallsign = callsign ?? _callsign;
    if (_appPath == null || targetCallsign == null) return false;

    // Validate folder depth
    if (!VideoFolderUtils.isValidFolderDepth(newFolderPath)) {
      LogService().log('VideoService: Target folder depth exceeds maximum');
      return false;
    }

    try {
      final videosPath = '$_appPath/$targetCallsign';
      final currentPath = await VideoFolderUtils.findVideoPath(videosPath, videoId);

      if (currentPath == null) return false;

      // Build new path
      final newParentPath = newFolderPath.isEmpty
          ? videosPath
          : '$videosPath/${newFolderPath.join('/')}';

      // Ensure new parent exists
      await Directory(newParentPath).create(recursive: true);

      // Generate unique name in new location
      final newVideoId = await VideoFolderUtils.generateUniqueFolderName(newParentPath, videoId);
      final newPath = '$newParentPath/$newVideoId';

      // Move the folder
      await Directory(currentPath).rename(newPath);

      LogService().log('VideoService: Moved video $videoId to ${newFolderPath.join('/')}');
      return true;
    } catch (e) {
      LogService().log('VideoService: Error moving video: $e');
      return false;
    }
  }

  /// Create a folder
  Future<bool> createFolder({
    required String name,
    String? description,
    List<String>? parentPath,
    String? callsign,
  }) async {
    final targetCallsign = callsign ?? _callsign;
    if (_appPath == null || targetCallsign == null) return false;

    // Validate folder depth
    final depth = (parentPath?.length ?? 0) + 1;
    if (depth > VideoFolderUtils.maxFolderDepth) {
      LogService().log('VideoService: Folder depth exceeds maximum');
      return false;
    }

    try {
      final basePath = parentPath != null && parentPath.isNotEmpty
          ? '$_appPath/$targetCallsign/${parentPath.join('/')}'
          : '$_appPath/$targetCallsign';

      final sanitizedName = VideoFolderUtils.sanitizeFolderName(name);
      final folderPath = '$basePath/$sanitizedName';

      // Create folder
      await Directory(folderPath).create(recursive: true);

      // Create folder.txt if description provided
      if (description != null && description.isNotEmpty) {
        final folderMetadata = '''
# FOLDER: $name

CREATED: ${ChatFormat.formatTimestamp(DateTime.now())}
AUTHOR: $targetCallsign

$description
''';
        await File('$folderPath/${VideoFolderUtils.folderMetadataFile}')
            .writeAsString(folderMetadata, flush: true);
      }

      LogService().log('VideoService: Created folder $sanitizedName');
      return true;
    } catch (e) {
      LogService().log('VideoService: Error creating folder: $e');
      return false;
    }
  }

  /// List folders at a path
  Future<List<Map<String, dynamic>>> listFolders({
    List<String>? folderPath,
    String? callsign,
  }) async {
    final targetCallsign = callsign ?? _callsign;
    if (_appPath == null || targetCallsign == null) return [];

    try {
      final basePath = folderPath != null && folderPath.isNotEmpty
          ? '$_appPath/$targetCallsign/${folderPath.join('/')}'
          : '$_appPath/$targetCallsign';

      final folderNames = await VideoFolderUtils.listSubfolders(basePath);
      final folders = <Map<String, dynamic>>[];

      for (final name in folderNames) {
        final folder = <String, dynamic>{'name': name};

        // Try to load folder metadata
        final metaFile = File('$basePath/$name/${VideoFolderUtils.folderMetadataFile}');
        if (await metaFile.exists()) {
          final content = await metaFile.readAsString();
          final meta = VideoParser.parseFolderMetadata(content);
          if (meta != null) {
            folder['displayName'] = meta['name'] ?? name;
            folder['description'] = meta['description'];
            folder['created'] = meta['created'];
          }
        }

        folders.add(folder);
      }

      return folders;
    } catch (e) {
      LogService().log('VideoService: Error listing folders: $e');
      return [];
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Feedback Operations (delegate to FeedbackFolderUtils)
  // ═══════════════════════════════════════════════════════════════════════════

  /// Toggle like on a video
  Future<bool?> toggleLike(String videoId, String npub, String nsec, {String? callsign}) async {
    return _toggleFeedback(videoId, FeedbackFolderUtils.feedbackTypeLikes, npub, nsec, callsign: callsign);
  }

  /// Toggle point on a video
  Future<bool?> togglePoint(String videoId, String npub, String nsec, {String? callsign}) async {
    return _toggleFeedback(videoId, FeedbackFolderUtils.feedbackTypePoints, npub, nsec, callsign: callsign);
  }

  /// Toggle dislike on a video
  Future<bool?> toggleDislike(String videoId, String npub, String nsec, {String? callsign}) async {
    return _toggleFeedback(videoId, FeedbackFolderUtils.feedbackTypeDislikes, npub, nsec, callsign: callsign);
  }

  /// Toggle emoji reaction
  Future<bool?> toggleReaction(String videoId, String reaction, String npub, String nsec, {String? callsign}) async {
    return _toggleFeedback(videoId, reaction, npub, nsec, callsign: callsign);
  }

  /// Record a view
  Future<bool> recordView(String videoId, String npub, String nsec, {String? callsign}) async {
    final targetCallsign = callsign ?? _callsign;
    if (_appPath == null || targetCallsign == null) return false;

    try {
      final videosPath = '$_appPath/$targetCallsign';
      final videoFolderPath = await VideoFolderUtils.findVideoPath(videosPath, videoId);

      if (videoFolderPath == null) return false;

      // Create view event
      final pubkeyHex = NostrCrypto.decodeNpub(npub);
      final event = NostrEvent(
        pubkey: pubkeyHex,
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        kind: 7,
        tags: [
          ['content_type', 'video'],
          ['content_id', videoId],
          ['action', 'view'],
        ],
        content: 'view',
      );
      event.calculateId();
      event.signWithNsec(nsec);

      return await FeedbackFolderUtils.recordViewEvent(videoFolderPath, event, storage: _storage);
    } catch (e) {
      LogService().log('VideoService: Error recording view: $e');
      return false;
    }
  }

  /// Internal toggle feedback method
  Future<bool?> _toggleFeedback(
    String videoId,
    String feedbackType,
    String npub,
    String nsec, {
    String? callsign,
  }) async {
    final targetCallsign = callsign ?? _callsign;
    if (_appPath == null || targetCallsign == null) return null;

    try {
      final videosPath = '$_appPath/$targetCallsign';
      final videoFolderPath = await VideoFolderUtils.findVideoPath(videosPath, videoId);

      if (videoFolderPath == null) return null;

      // Create feedback event
      final pubkeyHex = NostrCrypto.decodeNpub(npub);
      final event = NostrEvent(
        pubkey: pubkeyHex,
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        kind: 7,
        tags: [
          ['content_type', 'video'],
          ['content_id', videoId],
          ['action', feedbackType],
        ],
        content: feedbackType,
      );
      event.calculateId();
      event.signWithNsec(nsec);

      return await FeedbackFolderUtils.toggleFeedbackEvent(videoFolderPath, feedbackType, event, storage: _storage);
    } catch (e) {
      LogService().log('VideoService: Error toggling feedback: $e');
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Subscribe Operations
  // ═══════════════════════════════════════════════════════════════════════════

  /// Toggle subscribe on a video
  Future<bool?> toggleSubscribe(String videoId, String npub, String nsec, {String? callsign}) async {
    return _toggleFeedback(videoId, FeedbackFolderUtils.feedbackTypeSubscribe, npub, nsec, callsign: callsign);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Comment Operations
  // ═══════════════════════════════════════════════════════════════════════════

  /// Load comments for a video
  Future<List<BlogComment>> loadComments(String videoId, {String? callsign}) async {
    final targetCallsign = callsign ?? _callsign;
    if (_appPath == null || targetCallsign == null) return [];

    try {
      final videosPath = '$_appPath/$targetCallsign';
      final videoFolderPath = await VideoFolderUtils.findVideoPath(videosPath, videoId);

      if (videoFolderPath == null) return [];

      final comments = await FeedbackCommentUtils.loadComments(videoFolderPath, storage: _storage);
      return comments.map((fc) => BlogComment(
        id: fc.id,
        author: fc.author,
        timestamp: fc.created,
        content: fc.content,
        metadata: fc.npub != null ? {'npub': fc.npub!} : {},
      )).toList();
    } catch (e) {
      LogService().log('VideoService: Error loading comments: $e');
      return [];
    }
  }

  /// Add a comment to a video
  Future<String?> addComment({
    required String videoId,
    required String author,
    required String content,
    String? callsign,
    String? npub,
    String? nsec,
  }) async {
    final targetCallsign = callsign ?? _callsign;
    if (_appPath == null || targetCallsign == null) return null;

    try {
      final videosPath = '$_appPath/$targetCallsign';
      final videoFolderPath = await VideoFolderUtils.findVideoPath(videosPath, videoId);

      if (videoFolderPath == null) return null;

      // Sign comment if keys provided
      String? signature;
      if (npub != null && nsec != null) {
        try {
          final privateKeyHex = NostrCrypto.decodeNsec(nsec);
          final messageHash = NostrCrypto.sha256Hash(content);
          signature = NostrCrypto.schnorrSign(messageHash, privateKeyHex);
        } catch (e) {
          LogService().log('VideoService: Error signing comment: $e');
          return null;
        }
      }

      return await FeedbackCommentUtils.writeComment(
        contentPath: videoFolderPath,
        author: author,
        content: content,
        npub: npub,
        signature: signature,
        storage: _storage,
      );
    } catch (e) {
      LogService().log('VideoService: Error adding comment: $e');
      return null;
    }
  }

  /// Delete a comment from a video
  Future<bool> deleteComment({
    required String videoId,
    required String commentId,
    String? callsign,
    String? userNpub,
  }) async {
    final targetCallsign = callsign ?? _callsign;
    if (_appPath == null || targetCallsign == null) return false;

    try {
      final videosPath = '$_appPath/$targetCallsign';
      final videoFolderPath = await VideoFolderUtils.findVideoPath(videosPath, videoId);

      if (videoFolderPath == null) return false;

      // Check if user can delete (must be admin or comment owner)
      if (!isAdmin(userNpub)) {
        final comment = await FeedbackCommentUtils.getComment(videoFolderPath, commentId, storage: _storage);
        if (comment == null || comment.npub != userNpub) {
          return false;
        }
      }

      return await FeedbackCommentUtils.deleteComment(videoFolderPath, commentId, storage: _storage);
    } catch (e) {
      LogService().log('VideoService: Error deleting comment: $e');
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Admin/Permission Methods
  // ═══════════════════════════════════════════════════════════════════════════

  /// Check if user is admin (creator of the collection)
  bool isAdmin(String? userNpub) {
    if (userNpub == null || userNpub.isEmpty) return false;
    return userNpub == _creatorNpub;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // NOSTR Signing
  // ═══════════════════════════════════════════════════════════════════════════

  /// Sign video metadata with NOSTR
  Future<Video> _signVideo(Video video, String npub, String nsec) async {
    try {
      // Create content to sign (video.txt without signature)
      final contentToSign = video.copyWith(signature: null).exportAsText();

      // Sign with NOSTR
      final privateKeyHex = NostrCrypto.decodeNsec(nsec);
      final messageHash = NostrCrypto.sha256Hash(contentToSign);
      final signature = NostrCrypto.schnorrSign(messageHash, privateKeyHex);

      return video.copyWith(npub: npub, signature: signature);
    } catch (e) {
      LogService().log('VideoService: Error signing video: $e');
      return video;
    }
  }

  /// Verify video signature
  Future<bool> verifyVideoSignature(Video video) async {
    if (video.npub == null || video.signature == null) return false;

    try {
      // Create content to verify (without signature)
      final contentToVerify = video.copyWith(signature: null).exportAsText();

      // Verify with NOSTR
      final pubKeyHex = NostrCrypto.decodeNpub(video.npub!);
      final messageHash = NostrCrypto.sha256Hash(contentToVerify);

      return NostrCrypto.schnorrVerify(messageHash, video.signature!, pubKeyHex);
    } catch (e) {
      LogService().log('VideoService: Error verifying signature: $e');
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Utility Methods
  // ═══════════════════════════════════════════════════════════════════════════

  /// Get all unique tags from videos
  Future<List<String>> getAllTags({String? callsign}) async {
    final videos = await loadVideos(callsign: callsign);
    final tags = <String>{};
    for (final video in videos) {
      tags.addAll(video.tags);
    }
    final tagList = tags.toList();
    tagList.sort();
    return tagList;
  }

  /// Get video count by category
  Future<Map<VideoCategory, int>> getVideoCountByCategory({String? callsign}) async {
    final videos = await loadVideos(callsign: callsign);
    final counts = <VideoCategory, int>{};
    for (final video in videos) {
      counts[video.category] = (counts[video.category] ?? 0) + 1;
    }
    return counts;
  }

  /// Check if FFmpeg is available for metadata extraction
  Future<bool> isMetadataExtractionAvailable() async {
    return VideoMetadataExtractor.isFFmpegAvailable();
  }
}
