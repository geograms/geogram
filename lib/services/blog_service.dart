/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import '../models/blog_post.dart';
import '../util/blog_folder_utils.dart';
import '../util/feedback_folder_utils.dart';
import '../util/nostr_crypto.dart';
import '../util/nostr_event.dart';
import '../util/event_bus.dart';
import 'log_service.dart';
import 'app_service.dart';
import 'profile_storage.dart';
import 'station_activity_publisher_service.dart';

/// Model for chat security (reused for blog)
class ChatSecurity {
  final String? adminNpub;
  final Map<String, List<String>> moderators;

  ChatSecurity({
    this.adminNpub,
    this.moderators = const {},
  });

  bool isAdmin(String? npub) {
    return npub != null && npub == adminNpub;
  }

  bool isModerator(String? npub, String sectionId) {
    if (npub == null) return false;
    return moderators[sectionId]?.contains(npub) ?? false;
  }

  bool canModerate(String? npub, String sectionId) {
    return isAdmin(npub) || isModerator(npub, sectionId);
  }

  factory ChatSecurity.fromJson(Map<String, dynamic> json) {
    final moderatorMap = <String, List<String>>{};
    if (json.containsKey('moderators')) {
      final mods = json['moderators'] as Map<String, dynamic>;
      for (var entry in mods.entries) {
        moderatorMap[entry.key] = List<String>.from(entry.value as List);
      }
    }

    return ChatSecurity(
      adminNpub: json['admin'] as String?,
      moderators: moderatorMap,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'version': '1.0',
      'admin': adminNpub,
      'moderators': moderators,
    };
  }
}

/// Service for managing blog posts and comments
///
/// IMPORTANT: All file operations go through the ProfileStorage abstraction.
/// Never use File() or Directory() directly in this service.
class BlogService {
  static final BlogService _instance = BlogService._internal();
  factory BlogService() => _instance;
  BlogService._internal();

  /// Profile storage for file operations (encrypted or filesystem)
  /// IMPORTANT: This MUST be set before using the service.
  /// All file operations go through this abstraction.
  late ProfileStorage _storage;

  String? _appPath;
  ChatSecurity _security = ChatSecurity();

  /// Whether using encrypted storage
  bool get useEncryptedStorage => _storage.isEncrypted;

  /// Set the profile storage for file operations
  /// MUST be called before initializeApp
  void setStorage(ProfileStorage storage) {
    _storage = storage;
  }

  /// Initialize blog service for a collection
  ///
  /// Note: appPath should be the blog collection root (e.g., .../devices/X1D808/blog)
  /// Year directories will be created directly under this path.
  Future<void> initializeApp(String appPath, {String? creatorNpub}) async {
    LogService().log('BlogService: Initializing with collection path: $appPath');
    _appPath = appPath;

    // Ensure blog directory exists (appPath is already the blog root)
    // ProfileStorage handles directory creation automatically
    await _storage.createDirectory('');
    LogService().log('BlogService: Initialized with ProfileStorage');

    // Load security
    await _loadSecurity();

    // If no admin set and creator provided, set as admin
    if (_security.adminNpub == null && creatorNpub != null && creatorNpub.isNotEmpty) {
      LogService().log('BlogService: Setting creator as admin: $creatorNpub');
      final newSecurity = ChatSecurity(adminNpub: creatorNpub);
      await saveSecurity(newSecurity);
    }
  }

  /// Load security settings
  Future<void> _loadSecurity() async {
    if (_appPath == null) return;

    try {
      final content = await _storage.readString('extra/security.json');

      if (content != null) {
        final json = jsonDecode(content) as Map<String, dynamic>;
        _security = ChatSecurity.fromJson(json);
        LogService().log('BlogService: Loaded security settings');
      } else {
        _security = ChatSecurity();
      }
    } catch (e) {
      LogService().log('BlogService: Error loading security: $e');
      _security = ChatSecurity();
    }
  }

  /// Save security settings
  Future<void> saveSecurity(ChatSecurity security) async {
    if (_appPath == null) return;

    _security = security;
    final content = jsonEncode(security.toJson());

    await _storage.createDirectory('extra');
    await _storage.writeString('extra/security.json', content);

    LogService().log('BlogService: Saved security settings');
  }

  /// Get available years (folders in blog directory)
  Future<List<int>> getYears() async {
    if (_appPath == null) return [];

    final years = <int>[];

    final entries = await _storage.listDirectory('');
    for (var entry in entries) {
      if (entry.isDirectory) {
        final year = int.tryParse(entry.name);
        if (year != null) {
          years.add(year);
        }
      }
    }

    years.sort((a, b) => b.compareTo(a)); // Most recent first
    return years;
  }

  /// Load posts metadata (without full content) for a specific year or all years
  ///
  /// Posts are stored in folders: blog/{year}/{postId}/post.md
  Future<List<BlogPost>> loadPosts({
    int? year,
    bool publishedOnly = false,
    String? currentUserNpub,
  }) async {
    if (_appPath == null) return [];

    final posts = <BlogPost>[];
    final years = year != null ? [year] : await getYears();

    for (var y in years) {
      final entries = await _storage.listDirectory('$y');
      for (var entry in entries) {
        if (entry.isDirectory) {
          final postId = entry.name;
          final content = await _storage.readString('$y/$postId/post.md');
          if (content == null) continue;

          try {
            final post = BlogPost.fromText(content, postId);

            // Filter by published status
            if (publishedOnly && !post.isPublished) {
              if (!post.isOwnPost(currentUserNpub)) {
                continue;
              }
            }

            posts.add(post);
          } catch (e) {
            LogService().log('BlogService: Error loading post $postId: $e');
          }
        }
      }
    }

    // Sort by date (most recent first)
    posts.sort((a, b) => b.dateTime.compareTo(a.dateTime));

    return posts;
  }

  /// Get all unique tags from existing posts
  Future<List<String>> getAllTags() async {
    final posts = await loadPosts();
    final tagsSet = <String>{};

    for (final post in posts) {
      tagsSet.addAll(post.tags);
    }

    final tagsList = tagsSet.toList();
    tagsList.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return tagsList;
  }

  /// Load full post with comments
  ///
  /// Post is stored at: blog/{year}/{postId}/post.md
  /// Comments are stored in: blog/{year}/{postId}/comments/
  Future<BlogPost?> loadFullPost(String postId) async {
    if (_appPath == null) return null;

    // Extract year from postId (format: YYYY-MM-DD_title)
    final year = postId.substring(0, 4);
    final postRelativePath = '$year/$postId';
    // Relative to the blog app's storage scope — BlogFolderUtils /
    // FeedbackFolderUtils only feed this path back into the same
    // ProfileStorage instance so an absolute path would double-prefix
    // inside ScopedProfileStorage and the reads would return null.
    final postFolderPath = '$year/$postId';

    try {
      final content = await _storage.readString('$postRelativePath/post.md');
      if (content == null) {
        LogService().log('BlogService: Post file not found: $postRelativePath/post.md');
        return null;
      }

      // Parse post (without comments, since they're in separate files)
      final post = BlogPost.fromText(content, postId);

      // Load comments from comments/ directory
      // Note: BlogFolderUtils still uses filesystem paths - needs future migration
      final comments = await BlogFolderUtils.loadComments(postFolderPath, storage: _storage);

      // Return post with comments
      return post.copyWith(comments: comments);
    } catch (e) {
      LogService().log('BlogService: Error loading full post: $e');
      return null;
    }
  }

  /// Sanitize title to create valid filename
  String sanitizeFilename(String title, DateTime? date) {
    date ??= DateTime.now();

    // Convert to lowercase, replace spaces with hyphens
    String sanitized = title.toLowerCase().trim();

    // Replace spaces and underscores with hyphens
    sanitized = sanitized.replaceAll(RegExp(r'[\s_]+'), '-');

    // Remove non-alphanumeric characters except hyphens
    sanitized = sanitized.replaceAll(RegExp(r'[^a-z0-9-]'), '');

    // Remove multiple consecutive hyphens
    sanitized = sanitized.replaceAll(RegExp(r'-+'), '-');

    // Remove leading/trailing hyphens
    sanitized = sanitized.replaceAll(RegExp(r'^-+|-+$'), '');

    // Truncate to 50 characters
    if (sanitized.length > 50) {
      sanitized = sanitized.substring(0, 50);
    }

    // Format date as YYYY-MM-DD
    final year = date.year.toString().padLeft(4, '0');
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');

    return '$year-$month-$day\_$sanitized';
  }

  /// Check if post folder already exists, add suffix if needed
  Future<String> _ensureUniqueFilename(String baseFilename, int year) async {
    String filename = baseFilename;
    int suffix = 1;

    // Check for folder existence via storage abstraction
    while (await _storage.directoryExists('$year/$filename')) {
      filename = '$baseFilename-$suffix';
      suffix++;
    }

    return filename;
  }

  /// Create new blog post
  ///
  /// Creates folder structure: blog/{year}/{postId}/post.md
  Future<BlogPost?> createPost({
    required String author,
    required String title,
    String? description,
    required String content,
    List<String>? tags,
    BlogStatus status = BlogStatus.draft,
    String? npub,
    String? nsec,
    List<String>? imagePaths,
    double? latitude,
    double? longitude,
    Map<String, String>? metadata,
  }) async {
    if (_appPath == null) return null;

    try {
      final now = DateTime.now();
      final year = now.year;

      // Sanitize filename (will be used as folder name)
      final baseFilename = sanitizeFilename(title, now);
      final postId = await _ensureUniqueFilename(baseFilename, year);

      // Create post folder structure
      final postRelativePath = '$year/$postId';
      await _storage.createDirectory(postRelativePath);

      // Build metadata
      final postMetadata = <String, String>{
        ...?metadata,
        if (npub != null) 'npub': npub,
      };

      // Copy images to post's files directory
      if (imagePaths != null && imagePaths.isNotEmpty) {
        final imageNames = <String>[];
        for (final imagePath in imagePaths) {
          final destFileName = await _copyFileToPostFolder(imagePath, postRelativePath);
          if (destFileName != null) {
            imageNames.add(destFileName);
          }
        }
        if (imageNames.isNotEmpty) {
          // Store all images (comma-separated for multiple)
          postMetadata['image'] = imageNames.join(',');
        }
      }

      // Build location string if coordinates provided
      String? locationString;
      if (latitude != null && longitude != null) {
        locationString = '${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)}';
      }

      // Generate NOSTR signature if nsec is provided
      if (nsec != null && nsec.isNotEmpty) {
        // Sign the content hash (title + content)
        final contentToSign = '$title\n$content';
        final contentHash = sha256.convert(utf8.encode(contentToSign)).toString();

        try {
          final privateKeyHex = NostrCrypto.decodeNsec(nsec);
          final signature = NostrCrypto.schnorrSign(contentHash, privateKeyHex);
          postMetadata['signature'] = signature;
        } catch (e) {
          LogService().log('BlogService: Error signing post: $e');
        }
      }

      // Create post with signature in metadata
      final signedPost = BlogPost(
        id: postId,
        author: author,
        timestamp: _formatTimestamp(now),
        title: title,
        description: description,
        location: locationString,
        status: status,
        tags: tags ?? [],
        content: content,
        metadata: postMetadata,
      );

      // Write to post.md inside folder
      final postContent = signedPost.exportAsText();
      await _storage.writeString('$postRelativePath/post.md', postContent);

      LogService().log('BlogService: Created post: $postId');

      // Notify Now feed
      EventBus().fire(BlogPostPublishedEvent(
        postId: postId,
        author: author,
        title: title,
      ));

      await StationActivityPublisherService().publishBlogPost(signedPost);

      // Regenerate blog cache
      if (_appPath != null) {
        await AppService().generateBlogCache(_appPath!);
        AppService().invalidateWwwIndex();
      }

      return signedPost;
    } catch (e) {
      LogService().log('BlogService: Error creating post: $e');
      return null;
    }
  }

  /// Copy file to post's files directory with SHA1-based naming
  ///
  /// [sourcePath] is the external file path
  /// [postRelativePath] is the relative path to the post folder (e.g., "2025/2025-01-15_title")
  Future<String?> _copyFileToPostFolder(String sourcePath, String postRelativePath) async {
    try {
      // Read source file to calculate hash
      final sourceFile = File(sourcePath);
      if (!await sourceFile.exists()) {
        LogService().log('BlogService: Source file does not exist: $sourcePath');
        return null;
      }

      // Calculate SHA1
      final bytes = await sourceFile.readAsBytes();
      final hash = sha1.convert(bytes).toString();

      // Get original filename
      final originalName = sourcePath.split('/').last;

      // Truncate filename if too long (keep extension)
      String truncatedName = originalName;
      if (originalName.length > 100) {
        final ext = originalName.contains('.')
            ? '.${originalName.split('.').last}'
            : '';
        final baseName = originalName.substring(
          0,
          100 - ext.length,
        );
        truncatedName = '$baseName$ext';
      }

      final destFileName = '${hash}_$truncatedName';

      // Ensure files directory exists inside post folder
      await _storage.createDirectory('$postRelativePath/files');

      // Copy file using storage abstraction
      await _storage.copyFromExternal(sourcePath, '$postRelativePath/files/$destFileName');

      LogService().log('BlogService: Copied file: $destFileName');
      return destFileName;
    } catch (e) {
      LogService().log('BlogService: Error copying file: $e');
      return null;
    }
  }

  /// Update existing blog post
  Future<bool> updatePost({
    required String postId,
    String? title,
    String? description,
    String? content,
    List<String>? tags,
    BlogStatus? status,
    Map<String, String>? metadata,
    double? latitude,
    double? longitude,
    required String? userNpub,
  }) async {
    if (_appPath == null) return false;

    // Load existing post
    final post = await loadFullPost(postId);
    if (post == null) return false;

    // Check permissions (author or admin)
    if (!_security.isAdmin(userNpub) && !post.isOwnPost(userNpub)) {
      LogService().log('BlogService: User $userNpub cannot edit post by ${post.npub}');
      return false;
    }

    try {
      // Generate EDITED timestamp (format: YYYY-MM-DD HH:MM)
      final now = DateTime.now();
      final editedTimestamp = _formatEditedTimestamp(now);

      // Build location string if coordinates provided
      String? locationString;
      if (latitude != null && longitude != null) {
        locationString = '${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)}';
      }

      // Update post with edited timestamp
      final updatedPost = post.copyWith(
        title: title ?? post.title,
        description: description ?? post.description,
        location: locationString ?? post.location,
        content: content ?? post.content,
        tags: tags ?? post.tags,
        status: status ?? post.status,
        metadata: metadata ?? post.metadata,
        edited: editedTimestamp,
      );

      // Write to post.md inside folder
      final year = post.year;
      final postContent = updatedPost.exportAsText();
      await _storage.writeString('$year/$postId/post.md', postContent);

      LogService().log('BlogService: Updated post: $postId');

      // Regenerate blog cache
      if (_appPath != null) {
        await AppService().generateBlogCache(_appPath!);
        AppService().invalidateWwwIndex();
      }

      return true;
    } catch (e) {
      LogService().log('BlogService: Error updating post: $e');
      return false;
    }
  }

  /// Publish a draft post
  Future<bool> publishPost(String postId, String? userNpub) async {
    return await updatePost(
      postId: postId,
      status: BlogStatus.published,
      userNpub: userNpub,
    );
  }

  /// Delete blog post (deletes entire folder including comments)
  Future<bool> deletePost(String postId, String? userNpub) async {
    if (_appPath == null) return false;

    // Load post to check permissions
    final post = await loadFullPost(postId);
    if (post == null) return false;

    // Check permissions (author or admin)
    if (!_security.isAdmin(userNpub) && !post.isOwnPost(userNpub)) {
      LogService().log('BlogService: User $userNpub cannot delete post by ${post.npub}');
      return false;
    }

    try {
      final year = post.year;
      final postRelativePath = '$year/$postId';

      await _storage.deleteDirectory(postRelativePath, recursive: true);
      LogService().log('BlogService: Deleted post folder: $postId');

      // Regenerate blog cache
      if (_appPath != null) {
        await AppService().generateBlogCache(_appPath!);
        AppService().invalidateWwwIndex();
      }

      return true;
    } catch (e) {
      LogService().log('BlogService: Error deleting post: $e');
      return false;
    }
  }

  /// Add comment to blog post with NOSTR signature
  ///
  /// Comments are stored as separate files in: {year}/{postId}/comments/
  /// Returns the comment ID if successful, null otherwise.
  Future<String?> addComment({
    required String postId,
    required String author,
    required String content,
    required String npub,
    required String nsec,
  }) async {
    if (_appPath == null) return null;

    // Validate npub and nsec format
    if (!npub.startsWith('npub1') || npub.length != 63) {
      LogService().log('BlogService: Invalid npub format for comment');
      return null;
    }

    if (!nsec.startsWith('nsec1') || nsec.length != 63) {
      LogService().log('BlogService: Invalid nsec format for comment');
      return null;
    }

    // Load post to verify it exists and is published
    final post = await loadFullPost(postId);
    if (post == null) return null;

    // Only allow comments on published posts
    if (!post.isPublished) {
      LogService().log('BlogService: Cannot comment on draft post');
      return null;
    }

    try {
      // Create and sign NOSTR event for comment
      final pubkeyHex = NostrCrypto.decodeNpub(npub);
      final event = NostrEvent(
        pubkey: pubkeyHex,
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        kind: 1, // Text note
        tags: [
          ['e', postId], // Reference to blog post
          ['t', 'blog-comment'],
          ['callsign', author],
        ],
        content: content,
      );

      // Calculate ID and sign
      event.calculateId();
      event.signWithNsec(nsec);

      final year = post.year;
      // Relative to the blog app's storage scope — BlogFolderUtils /
    // FeedbackFolderUtils only feed this path back into the same
    // ProfileStorage instance so an absolute path would double-prefix
    // inside ScopedProfileStorage and the reads would return null.
    final postFolderPath = '$year/$postId';

      // Write comment to separate file with signature
      final commentId = await BlogFolderUtils.writeComment(
        postFolderPath: postFolderPath,
        author: author,
        content: content,
        npub: npub,
        signature: event.sig!,
        storage: _storage,
      );

      LogService().log('BlogService: Added signed comment $commentId to post: $postId');
      return commentId;
    } catch (e) {
      LogService().log('BlogService: Error adding comment: $e');
      return null;
    }
  }

  /// Delete comment from blog post by comment ID
  ///
  /// commentId is the filename without .txt extension (e.g., "2025-01-15_10-30-45_X1ABC2")
  Future<bool> deleteComment({
    required String postId,
    required String commentId,
    required String? userNpub,
  }) async {
    if (_appPath == null) return false;

    // Load post to get year
    final post = await loadFullPost(postId);
    if (post == null) return false;

    final year = post.year;
    // Relative to the blog app's storage scope — BlogFolderUtils /
    // FeedbackFolderUtils only feed this path back into the same
    // ProfileStorage instance so an absolute path would double-prefix
    // inside ScopedProfileStorage and the reads would return null.
    final postFolderPath = '$year/$postId';

    // Load the comment to check permissions
    final comment = await BlogFolderUtils.getComment(postFolderPath, commentId, storage: _storage);
    if (comment == null) {
      LogService().log('BlogService: Comment not found: $commentId');
      return false;
    }

    // Check permissions (admin or comment author)
    final isCommentAuthor = comment.npub != null && comment.npub == userNpub;
    final isPostAuthor = post.npub != null && post.npub == userNpub;
    if (!_security.isAdmin(userNpub) && !isCommentAuthor && !isPostAuthor) {
      LogService().log('BlogService: User $userNpub cannot delete comment by ${comment.npub}');
      return false;
    }

    try {
      final deleted = await BlogFolderUtils.deleteComment(postFolderPath, commentId, storage: _storage);
      if (deleted) {
        LogService().log('BlogService: Deleted comment $commentId from post: $postId');
      }
      return deleted;
    } catch (e) {
      LogService().log('BlogService: Error deleting comment: $e');
      return false;
    }
  }

  /// Format DateTime to timestamp string (for CREATED field)
  static String _formatTimestamp(DateTime dt) {
    final year = dt.year.toString().padLeft(4, '0');
    final month = dt.month.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    final second = dt.second.toString().padLeft(2, '0');
    return '$year-$month-$day $hour:$minute\_$second';
  }

  /// Format DateTime to edited timestamp string (for EDITED field)
  static String _formatEditedTimestamp(DateTime dt) {
    final year = dt.year.toString().padLeft(4, '0');
    final month = dt.month.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$year-$month-$day $hour:$minute';
  }

  // ============================================================
  // Feedback Operations
  // ============================================================

  /// Load feedback counts for a blog post
  ///
  /// Returns feedback counts and user state for populating BlogPost model
  Future<Map<String, dynamic>> loadFeedback(String postId, {String? userNpub}) async {
    if (_appPath == null) {
      return {
        'counts': {},
        'userState': {},
      };
    }

    final postFolderPath = getPostFolderPath(postId);
    if (postFolderPath == null) {
      return {
        'counts': {},
        'userState': {},
      };
    }

    try {
      // Get all feedback counts
      final counts = await FeedbackFolderUtils.getAllFeedbackCounts(postFolderPath, storage: _storage);

      // Get user state if npub provided
      Map<String, bool>? userState;
      if (userNpub != null && userNpub.isNotEmpty) {
        userState = await FeedbackFolderUtils.getUserFeedbackState(postFolderPath, userNpub, storage: _storage);
      }

      return {
        'counts': counts,
        'userState': userState ?? {},
      };
    } catch (e) {
      LogService().log('BlogService: Error loading feedback: $e');
      return {
        'counts': {},
        'userState': {},
      };
    }
  }

  /// Load full post with comments and feedback
  ///
  /// Enhanced version of loadFullPost that includes feedback counts and user state
  Future<BlogPost?> loadFullPostWithFeedback(String postId, {String? userNpub}) async {
    final post = await loadFullPost(postId);
    if (post == null) return null;

    try {
      // Load feedback
      final feedback = await loadFeedback(postId, userNpub: userNpub);
      final counts = feedback['counts'] as Map<String, int>;
      final userState = feedback['userState'] as Map<String, bool>;

      // Return post with feedback counts and user state
      return post.copyWith(
        likesCount: counts[FeedbackFolderUtils.feedbackTypeLikes] ?? 0,
        pointsCount: counts[FeedbackFolderUtils.feedbackTypePoints] ?? 0,
        dislikesCount: counts[FeedbackFolderUtils.feedbackTypeDislikes] ?? 0,
        subscribeCount: counts[FeedbackFolderUtils.feedbackTypeSubscribe] ?? 0,
        verificationsCount: counts[FeedbackFolderUtils.feedbackTypeVerifications] ?? 0,
        heartCount: counts[FeedbackFolderUtils.reactionHeart] ?? 0,
        thumbsUpCount: counts[FeedbackFolderUtils.reactionThumbsUp] ?? 0,
        thumbsDownCount: counts[FeedbackFolderUtils.reactionThumbsDown] ?? 0,
        fireCount: counts[FeedbackFolderUtils.reactionFire] ?? 0,
        hundredCount: counts[FeedbackFolderUtils.reactionHundred] ?? 0,
        curiousCount: counts[FeedbackFolderUtils.reactionCurious] ?? 0,
        celebrateCount: counts[FeedbackFolderUtils.reactionCelebrate] ?? 0,
        laughCount: counts[FeedbackFolderUtils.reactionLaugh] ?? 0,
        sadCount: counts[FeedbackFolderUtils.reactionSad] ?? 0,
        beerCheersCount: counts[FeedbackFolderUtils.reactionBeerCheers] ?? 0,
        surpriseCount: counts[FeedbackFolderUtils.reactionSurprise] ?? 0,
        hasLiked: userState[FeedbackFolderUtils.feedbackTypeLikes] ?? false,
        hasPointed: userState[FeedbackFolderUtils.feedbackTypePoints] ?? false,
        hasDisliked: userState[FeedbackFolderUtils.feedbackTypeDislikes] ?? false,
        hasSubscribed: userState[FeedbackFolderUtils.feedbackTypeSubscribe] ?? false,
        hasVerified: userState[FeedbackFolderUtils.feedbackTypeVerifications] ?? false,
        hasHearted: userState[FeedbackFolderUtils.reactionHeart] ?? false,
        hasThumbsUp: userState[FeedbackFolderUtils.reactionThumbsUp] ?? false,
        hasThumbsDown: userState[FeedbackFolderUtils.reactionThumbsDown] ?? false,
        hasFired: userState[FeedbackFolderUtils.reactionFire] ?? false,
        hasHundred: userState[FeedbackFolderUtils.reactionHundred] ?? false,
        hasCurious: userState[FeedbackFolderUtils.reactionCurious] ?? false,
        hasCelebrated: userState[FeedbackFolderUtils.reactionCelebrate] ?? false,
        hasLaughed: userState[FeedbackFolderUtils.reactionLaugh] ?? false,
        hasSad: userState[FeedbackFolderUtils.reactionSad] ?? false,
        hasBeerCheers: userState[FeedbackFolderUtils.reactionBeerCheers] ?? false,
        hasSurprised: userState[FeedbackFolderUtils.reactionSurprise] ?? false,
      );
    } catch (e) {
      LogService().log('BlogService: Error loading feedback for post: $e');
      return post;
    }
  }

  /// Toggle like on a blog post with NOSTR signature
  ///
  /// Returns true if like was added, false if removed, null if error
  Future<bool?> toggleLike(String postId, String npub, String nsec) async {
    return _toggleFeedback(postId, npub, nsec, FeedbackFolderUtils.feedbackTypeLikes, 'like');
  }

  /// Toggle point on a blog post with NOSTR signature
  ///
  /// Returns true if point was added, false if removed, null if error
  Future<bool?> togglePoint(String postId, String npub, String nsec) async {
    return _toggleFeedback(postId, npub, nsec, FeedbackFolderUtils.feedbackTypePoints, 'point');
  }

  /// Toggle dislike on a blog post with NOSTR signature
  ///
  /// Returns true if dislike was added, false if removed, null if error
  Future<bool?> toggleDislike(String postId, String npub, String nsec) async {
    return _toggleFeedback(postId, npub, nsec, FeedbackFolderUtils.feedbackTypeDislikes, 'dislike');
  }

  /// Toggle subscription on a blog post with NOSTR signature
  ///
  /// Returns true if subscribed, false if unsubscribed, null if error
  Future<bool?> toggleSubscribe(String postId, String npub, String nsec) async {
    return _toggleFeedback(postId, npub, nsec, FeedbackFolderUtils.feedbackTypeSubscribe, 'subscribe');
  }

  /// Toggle emoji reaction on a blog post with NOSTR signature
  ///
  /// Returns true if reaction was added, false if removed, null if error
  /// Returns null if emoji is not supported
  Future<bool?> toggleReaction(String postId, String npub, String nsec, String emoji) async {
    // Validate emoji is supported
    if (!FeedbackFolderUtils.supportedReactions.contains(emoji)) {
      LogService().log('BlogService: Unsupported reaction: $emoji');
      return null;
    }

    return _toggleFeedback(postId, npub, nsec, emoji, 'reaction');
  }

  /// Generic method to toggle any feedback type with NOSTR signature
  ///
  /// Returns true if added, false if removed, null if error
  Future<bool?> _toggleFeedback(
    String postId,
    String npub,
    String nsec,
    String feedbackType,
    String actionName,
  ) async {
    if (_appPath == null) return null;

    // Validate npub format
    if (!npub.startsWith('npub1') || npub.length != 63) {
      LogService().log('BlogService: Invalid npub format');
      return null;
    }

    // Validate nsec format
    if (!nsec.startsWith('nsec1') || nsec.length != 63) {
      LogService().log('BlogService: Invalid nsec format');
      return null;
    }

    final postFolderPath = getPostFolderPath(postId);
    if (postFolderPath == null) {
      LogService().log('BlogService: Post folder not found: $postId');
      return null;
    }

    try {
      // Verify post exists and is published
      final post = await loadFullPost(postId);
      if (post == null) {
        LogService().log('BlogService: Post not found: $postId');
        return null;
      }

      if (!post.isPublished) {
        LogService().log('BlogService: Cannot interact with unpublished post');
        return null;
      }

      // Create and sign NOSTR event for feedback
      // Use kind 7 (reaction) for all feedback types per NIP-25
      final pubkeyHex = NostrCrypto.decodeNpub(npub);
      final event = NostrEvent(
        pubkey: pubkeyHex,
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        kind: NostrEventKind.reaction,
        tags: [
          ['p', post.npub ?? ''], // Tag the post author
          ['e', postId], // Reference the post ID
          ['type', feedbackType], // Feedback type (likes, points, etc.)
        ],
        content: actionName, // Content is the action name
      );

      // Calculate ID and sign
      event.calculateId();
      event.signWithNsec(nsec);

      // Toggle the feedback with signed event
      final isNowActive = await FeedbackFolderUtils.toggleFeedbackEvent(
        postFolderPath,
        feedbackType,
        event,
        storage: _storage,
      );

      if (isNowActive == null) {
        LogService().log('BlogService: Signature verification failed for $actionName');
        return null;
      }

      final action = isNowActive ? 'added' : 'removed';
      LogService().log('BlogService: $actionName $action for post $postId by $npub (verified)');

      return isNowActive;
    } catch (e) {
      LogService().log('BlogService: Error toggling $actionName: $e');
      return null;
    }
  }

  /// Get feedback count for a specific type
  Future<int> getFeedbackCount(String postId, String feedbackType) async {
    final postFolderPath = getPostFolderPath(postId);
    if (postFolderPath == null) return 0;

    try {
      return await FeedbackFolderUtils.getFeedbackCount(postFolderPath, feedbackType, storage: _storage);
    } catch (e) {
      LogService().log('BlogService: Error getting feedback count: $e');
      return 0;
    }
  }

  /// Check if user has provided specific feedback
  Future<bool> hasFeedback(String postId, String feedbackType, String npub) async {
    final postFolderPath = getPostFolderPath(postId);
    if (postFolderPath == null) return false;

    try {
      return await FeedbackFolderUtils.hasFeedback(postFolderPath, feedbackType, npub, storage: _storage);
    } catch (e) {
      LogService().log('BlogService: Error checking feedback: $e');
      return false;
    }
  }

  // ============================================================
  // Getters and utility methods
  // ============================================================

  /// Get current security settings
  ChatSecurity getSecurity() => _security;

  /// Check if user is admin
  bool isAdmin(String? npub) => _security.isAdmin(npub);

  /// Check if user can moderate
  bool canModerate(String? npub) => _security.isAdmin(npub);

  /// Get the collection path (for API use)
  String? get appPath => _appPath;

  /// Post folder path relative to the blog's ProfileStorage scope.
  /// All the feedback/comment helpers accept this relative form —
  /// an absolute path would fight the scoped storage and silently
  /// miss reads.
  String? getPostFolderPath(String postId) {
    if (_appPath == null) return null;
    final year = postId.substring(0, 4);
    return '$year/$postId';
  }
}
