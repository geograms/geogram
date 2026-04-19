/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Blog API handlers for device-hosted blog posts.
 * Enables remote devices to view posts and add/delete comments.
 */

import '../../models/blog_post.dart';
import '../../services/profile_storage.dart';
import '../../util/blog_folder_utils.dart';
import '../../util/feedback_folder_utils.dart';
import '../../util/nostr_event.dart';
import '../../util/nostr_crypto.dart';

/// Blog API handlers for device-hosted blogs
class BlogHandler {
  final ProfileStorage storage;
  final void Function(String level, String message)? log;

  BlogHandler({
    required this.storage,
    this.log,
  });

  void _log(String level, String message) {
    log?.call(level, message);
  }

  // ============================================================
  // GET /api/blog - List all blog posts
  // ============================================================

  /// Handle GET /api/blog - returns list of published blog posts
  Future<Map<String, dynamic>> getBlogPosts({
    int? year,
    String? tag,
    int? limit,
    int? offset,
  }) async {
    try {
      final posts = await _loadAllPosts(publishedOnly: true);

      // Filter by year if specified
      var filteredPosts = year != null
          ? posts.where((p) => p['year'] == year).toList()
          : posts;

      // Filter by tag if specified
      if (tag != null && tag.isNotEmpty) {
        filteredPosts = filteredPosts.where((p) {
          final tags = p['tags'] as List<String>? ?? [];
          return tags.any((t) => t.toLowerCase() == tag.toLowerCase());
        }).toList();
      }

      // Apply pagination
      final total = filteredPosts.length;
      if (offset != null && offset > 0) {
        filteredPosts = filteredPosts.skip(offset).toList();
      }
      if (limit != null && limit > 0) {
        filteredPosts = filteredPosts.take(limit).toList();
      }

      return {
        'success': true,
        'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'filters': {
          if (year != null) 'year': year,
          if (tag != null) 'tag': tag,
          if (limit != null) 'limit': limit,
          if (offset != null) 'offset': offset,
        },
        'total': total,
        'count': filteredPosts.length,
        'posts': filteredPosts,
      };
    } catch (e) {
      _log('ERROR', 'Error in blog posts API: $e');
      return {
        'success': false,
        'error': 'Internal server error',
        'message': e.toString(),
      };
    }
  }

  // ============================================================
  // GET /api/blog/{postId} - Get post details with comments
  // ============================================================

  /// Handle GET /api/blog/{postId} - returns post details with comments
  Future<Map<String, dynamic>> getPostDetails(String postId) async {
    try {
      // Find the post folder
      final postPath = await BlogFolderUtils.findPostPath('blog', postId, storage: storage);

      if (postPath == null) {
        _log('WARN', 'getPostDetails: post not found: $postId');
        return {'error': 'Post not found', 'http_status': 404};
      }

      // Read post content
      final postFilePath = BlogFolderUtils.buildPostFilePath(postPath);
      final postContent = await storage.readString(postFilePath);

      if (postContent == null) {
        return {'error': 'Post file not found', 'http_status': 404};
      }

      // Parse the post
      BlogPost? post;
      try {
        post = BlogPost.fromText(postContent, postId);
      } catch (e) {
        _log('WARN', 'getPostDetails: failed to parse post, returning raw content: $e');
      }

      // Only return published posts
      if (post != null && !post.isPublished) {
        return {'error': 'Post not available', 'http_status': 403};
      }

      // Load comments
      final comments = await BlogFolderUtils.loadComments(postPath, storage: storage);
      final commentsList = comments.map((c) => {
        'id': c.id,
        'author': c.author,
        'timestamp': c.timestamp,
        'content': c.content,
        if (c.npub != null) 'npub': c.npub,
        if (c.signature != null) 'signature': c.signature,
      }).toList();

      // Find attached files
      final files = <String>[];
      final filesPath = BlogFolderUtils.buildFilesPath(postPath);
      final fileEntries = await storage.listDirectory(filesPath);
      for (final entry in fileEntries) {
        if (!entry.isDirectory) {
          files.add(entry.name);
        }
      }

      _log('INFO', 'Post details: found ${comments.length} comments, ${files.length} files');

      return {
        'success': true,
        'id': postId,
        'title': post?.title ?? postId,
        'author': post?.author ?? '',
        'timestamp': post?.timestamp ?? '',
        'edited': post?.edited,
        'description': post?.description,
        'location': post?.location,
        'status': post?.status.name ?? 'draft',
        'tags': post?.tags ?? [],
        'content': post?.content ?? postContent,
        'files': files,
        'comments': commentsList,
        'comment_count': comments.length,
        if (post?.npub != null) 'npub': post!.npub,
        if (post?.signature != null) 'signature': post!.signature,
      };
    } catch (e) {
      _log('ERROR', 'Error handling post details: $e');
      return {
        'error': 'Internal server error',
        'message': e.toString(),
        'http_status': 500,
      };
    }
  }

  // ============================================================
  // POST /api/blog/{postId}/comment - Add comment
  // ============================================================

  /// Handle POST /api/blog/{postId}/comment
  /// Verifies NOSTR signature before accepting comment
  Future<Map<String, dynamic>> addComment(
    String postId,
    String author,
    String content, {
    String? npub,
    String? signature,
    int? createdAt,
  }) async {
    try {
      // Require signature for comments
      if (npub == null || signature == null) {
        return {
          'error': 'Signature required',
          'message': 'Comments must be signed with NOSTR keys',
          'http_status': 401,
        };
      }

      // Verify npub format
      if (!npub.startsWith('npub1') || npub.length != 63) {
        return {
          'error': 'Invalid npub format',
          'message': 'npub must start with "npub1" and be exactly 63 characters',
          'http_status': 400,
        };
      }

      // Find the post folder
      final postPath = await BlogFolderUtils.findPostPath('blog', postId, storage: storage);

      if (postPath == null) {
        return {'error': 'Post not found', 'http_status': 404};
      }

      // Verify post is published
      final postFilePath = BlogFolderUtils.buildPostFilePath(postPath);
      final postContent = await storage.readString(postFilePath);
      if (postContent != null) {
        try {
          final post = BlogPost.fromText(postContent, postId);
          if (!post.isPublished) {
            return {'error': 'Cannot comment on unpublished post', 'http_status': 403};
          }
        } catch (e) {
          _log('WARN', 'addComment: could not verify post status: $e');
        }
      }

      // Verify signature
      try {
        final pubkeyHex = NostrCrypto.decodeNpub(npub);
        final event = NostrEvent(
          pubkey: pubkeyHex,
          createdAt: createdAt ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000),
          kind: 1, // Text note
          tags: [
            ['e', postId], // Reference to blog post
            ['t', 'blog-comment'],
            ['callsign', author],
          ],
          content: content,
          sig: signature,
        );
        event.calculateId();

        if (!event.verify()) {
          _log('WARN', 'addComment: Signature verification failed for comment by $author');
          return {
            'error': 'Invalid signature',
            'message': 'Comment signature verification failed',
            'http_status': 401,
          };
        }
      } catch (e) {
        _log('ERROR', 'addComment: Error verifying signature: $e');
        return {
          'error': 'Signature verification error',
          'message': e.toString(),
          'http_status': 400,
        };
      }

      // Write comment
      final commentId = await BlogFolderUtils.writeComment(
        postFolderPath: postPath,
        author: author,
        content: content,
        npub: npub,
        signature: signature,
        storage: storage,
      );

      _log('INFO', 'Comment added to post $postId by $author (verified)');

      return {
        'success': true,
        'comment_id': commentId,
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      };
    } catch (e) {
      _log('ERROR', 'Error handling comment: $e');
      return {
        'error': 'Internal server error',
        'message': e.toString(),
        'http_status': 500,
      };
    }
  }

  // ============================================================
  // DELETE /api/blog/{postId}/comment/{commentId} - Delete comment
  // ============================================================

  /// Handle DELETE /api/blog/{postId}/comment/{commentId}
  ///
  /// Authorization: Post author or comment author (verified by npub)
  Future<Map<String, dynamic>> deleteComment(
    String postId,
    String commentId,
    String requesterNpub,
  ) async {
    try {
      // Find the post folder
      final postPath = await BlogFolderUtils.findPostPath('blog', postId, storage: storage);

      if (postPath == null) {
        return {'error': 'Post not found', 'http_status': 404};
      }

      // Load the comment to check permissions
      final comment = await BlogFolderUtils.getComment(postPath, commentId, storage: storage);
      if (comment == null) {
        return {'error': 'Comment not found', 'http_status': 404};
      }

      // Load post to check if requester is post author
      final postFilePath = BlogFolderUtils.buildPostFilePath(postPath);
      final postContent = await storage.readString(postFilePath);
      String? postNpub;
      if (postContent != null) {
        try {
          final post = BlogPost.fromText(postContent, postId);
          postNpub = post.npub;
        } catch (_) {}
      }

      // Check permissions: post author or comment author
      final isCommentAuthor = comment.npub != null && comment.npub == requesterNpub;
      final isPostAuthor = postNpub != null && postNpub == requesterNpub;

      if (!isCommentAuthor && !isPostAuthor) {
        _log('WARN', 'deleteComment: unauthorized - requester $requesterNpub, comment by ${comment.npub}, post by $postNpub');
        return {'error': 'Unauthorized', 'http_status': 403};
      }

      // Delete the comment
      final deleted = await BlogFolderUtils.deleteComment(postPath, commentId, storage: storage);

      if (deleted) {
        _log('INFO', 'Comment $commentId deleted from post $postId by $requesterNpub');
        return {
          'success': true,
          'deleted': true,
        };
      } else {
        return {'error': 'Failed to delete comment', 'http_status': 500};
      }
    } catch (e) {
      _log('ERROR', 'Error deleting comment: $e');
      return {
        'error': 'Internal server error',
        'message': e.toString(),
        'http_status': 500,
      };
    }
  }

  // ============================================================
  // GET /api/blog/{postId}/files/{filename} - Get attached file
  // ============================================================

  /// Get file path for attached file (returns null if not found)
  Future<String?> getFilePath(String postId, String filename) async {
    // Validate filename
    if (filename.contains('..') || filename.contains('/')) {
      return null;
    }

    final postPath = await BlogFolderUtils.findPostPath('blog', postId, storage: storage);
    if (postPath == null) return null;

    final filePath = '${BlogFolderUtils.buildFilesPath(postPath)}/$filename';
    if (await storage.exists(filePath)) {
      return filePath;
    }

    return null;
  }

  // ============================================================
  // GET /api/blog/{postId}/feedback - Get all feedback counts
  // ============================================================

  /// Handle GET /api/blog/{postId}/feedback - returns all feedback counts and user state
  Future<Map<String, dynamic>> getFeedback(String postId, {String? npub}) async {
    try {
      // Find the post folder
      final postPath = await BlogFolderUtils.findPostPath('blog', postId, storage: storage);

      if (postPath == null) {
        return {'error': 'Post not found', 'http_status': 404};
      }

      // Verify post is published
      final postFilePath = BlogFolderUtils.buildPostFilePath(postPath);
      final postContent = await storage.readString(postFilePath);
      if (postContent != null) {
        try {
          final post = BlogPost.fromText(postContent, postId);
          if (!post.isPublished) {
            return {'error': 'Post not available', 'http_status': 403};
          }
        } catch (e) {
          _log('WARN', 'getFeedback: could not verify post status: $e');
        }
      }

      // Get all feedback counts
      final counts = await FeedbackFolderUtils.getAllFeedbackCounts(postPath, storage: storage);

      final response = {
        'success': true,
        'post_id': postId,
        'feedback': {
          'likes': counts[FeedbackFolderUtils.feedbackTypeLikes] ?? 0,
          'points': counts[FeedbackFolderUtils.feedbackTypePoints] ?? 0,
          'dislikes': counts[FeedbackFolderUtils.feedbackTypeDislikes] ?? 0,
          'subscribe': counts[FeedbackFolderUtils.feedbackTypeSubscribe] ?? 0,
          'verifications': counts[FeedbackFolderUtils.feedbackTypeVerifications] ?? 0,
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
        },
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      };

      // Add user state if npub provided
      if (npub != null && npub.isNotEmpty) {
        final userState = await FeedbackFolderUtils.getUserFeedbackState(postPath, npub, storage: storage);
        response['user_state'] = {
          'has_liked': userState[FeedbackFolderUtils.feedbackTypeLikes] ?? false,
          'has_pointed': userState[FeedbackFolderUtils.feedbackTypePoints] ?? false,
          'has_disliked': userState[FeedbackFolderUtils.feedbackTypeDislikes] ?? false,
          'has_subscribed': userState[FeedbackFolderUtils.feedbackTypeSubscribe] ?? false,
          'has_verified': userState[FeedbackFolderUtils.feedbackTypeVerifications] ?? false,
          'reactions': {
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
          },
        };
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

  // ============================================================
  // POST /api/blog/{postId}/like - Toggle like
  // ============================================================

  /// Handle POST /api/blog/{postId}/like
  /// Expects a signed NOSTR event in the request body
  Future<Map<String, dynamic>> toggleLike(String postId, Map<String, dynamic> eventJson) async {
    return _toggleFeedback(
      postId,
      eventJson,
      FeedbackFolderUtils.feedbackTypeLikes,
      'like',
    );
  }

  // ============================================================
  // POST /api/blog/{postId}/point - Toggle point
  // ============================================================

  /// Handle POST /api/blog/{postId}/point
  /// Expects a signed NOSTR event in the request body
  Future<Map<String, dynamic>> togglePoint(String postId, Map<String, dynamic> eventJson) async {
    return _toggleFeedback(
      postId,
      eventJson,
      FeedbackFolderUtils.feedbackTypePoints,
      'point',
    );
  }

  // ============================================================
  // POST /api/blog/{postId}/dislike - Toggle dislike
  // ============================================================

  /// Handle POST /api/blog/{postId}/dislike
  /// Expects a signed NOSTR event in the request body
  Future<Map<String, dynamic>> toggleDislike(String postId, Map<String, dynamic> eventJson) async {
    return _toggleFeedback(
      postId,
      eventJson,
      FeedbackFolderUtils.feedbackTypeDislikes,
      'dislike',
    );
  }

  // ============================================================
  // POST /api/blog/{postId}/subscribe - Toggle subscription
  // ============================================================

  /// Handle POST /api/blog/{postId}/subscribe
  /// Expects a signed NOSTR event in the request body
  Future<Map<String, dynamic>> toggleSubscribe(String postId, Map<String, dynamic> eventJson) async {
    return _toggleFeedback(
      postId,
      eventJson,
      FeedbackFolderUtils.feedbackTypeSubscribe,
      'subscribe',
    );
  }

  // ============================================================
  // POST /api/blog/{postId}/react/{emoji} - Toggle emoji reaction
  // ============================================================

  /// Handle POST /api/blog/{postId}/react/{emoji}
  /// Expects a signed NOSTR event in the request body
  Future<Map<String, dynamic>> toggleReaction(
    String postId,
    Map<String, dynamic> eventJson,
    String emoji,
  ) async {
    // Validate emoji is supported
    if (!FeedbackFolderUtils.supportedReactions.contains(emoji)) {
      return {
        'error': 'Unsupported reaction',
        'message': 'Reaction "$emoji" is not supported',
        'supported_reactions': FeedbackFolderUtils.supportedReactions,
        'http_status': 400,
      };
    }

    return _toggleFeedback(postId, eventJson, emoji, 'reaction');
  }

  // ============================================================
  // Internal helper methods
  // ============================================================

  /// Generic method to toggle any feedback type with signature verification
  Future<Map<String, dynamic>> _toggleFeedback(
    String postId,
    Map<String, dynamic> eventJson,
    String feedbackType,
    String actionName,
  ) async {
    try {
      // Parse and verify the NOSTR event
      NostrEvent event;
      try {
        event = NostrEvent.fromJson(eventJson);
      } catch (e) {
        return {
          'error': 'Invalid NOSTR event format',
          'message': e.toString(),
          'http_status': 400,
        };
      }

      // Verify signature
      if (!event.verify()) {
        _log('WARN', '_toggleFeedback: Signature verification failed for $actionName');
        return {
          'error': 'Invalid signature',
          'message': 'NOSTR event signature verification failed',
          'http_status': 401,
        };
      }

      final npub = event.npub;

      // Find the post folder
      final postPath = await BlogFolderUtils.findPostPath('blog', postId, storage: storage);

      if (postPath == null) {
        return {'error': 'Post not found', 'http_status': 404};
      }

      // Verify post is published
      final postFilePath = BlogFolderUtils.buildPostFilePath(postPath);
      final postContent = await storage.readString(postFilePath);
      if (postContent != null) {
        try {
          final post = BlogPost.fromText(postContent, postId);
          if (!post.isPublished) {
            return {'error': 'Cannot interact with unpublished post', 'http_status': 403};
          }
        } catch (e) {
          _log('WARN', '_toggleFeedback: could not verify post status: $e');
        }
      }

      // Toggle the feedback with verified event
      final isNowActive = await FeedbackFolderUtils.toggleFeedbackEvent(
        postPath,
        feedbackType,
        event,
        storage: storage,
      );

      if (isNowActive == null) {
        return {
          'error': 'Signature verification failed',
          'message': 'Event signature could not be verified',
          'http_status': 401,
        };
      }

      // Get updated count
      final count = await FeedbackFolderUtils.getFeedbackCount(postPath, feedbackType, storage: storage);

      final action = isNowActive ? 'added' : 'removed';
      _log('INFO', '$actionName $action for post $postId by $npub (verified)');

      return {
        'success': true,
        'action': action,
        '${actionName}d': isNowActive, // e.g., "liked": true
        '${actionName}_count': count,
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      };
    } catch (e) {
      _log('ERROR', 'Error toggling $actionName: $e');
      return {
        'error': 'Internal server error',
        'message': e.toString(),
        'http_status': 500,
      };
    }
  }

  /// Load all posts from blog directory
  Future<List<Map<String, dynamic>>> _loadAllPosts({bool publishedOnly = false}) async {
    final posts = <Map<String, dynamic>>[];

    // List year directories under 'blog'
    final yearEntries = await storage.listDirectory('blog');

    for (final yearEntry in yearEntries) {
      if (!yearEntry.isDirectory) continue;

      final yearName = yearEntry.name;
      final year = int.tryParse(yearName);
      if (year == null) continue;

      // List post directories under this year
      final postEntries = await storage.listDirectory('blog/$yearName');

      for (final postEntry in postEntries) {
        if (!postEntry.isDirectory) continue;

        final postId = postEntry.name;
        final postContent = await storage.readString('blog/$yearName/$postId/post.md');

        if (postContent == null) continue;

        try {
          final post = BlogPost.fromText(postContent, postId);

          // Filter by published status
          if (publishedOnly && !post.isPublished) {
            continue;
          }

          // Count comments
          final postPath = 'blog/$yearName/$postId';
          final comments = await BlogFolderUtils.loadComments(postPath, storage: storage);

          // Feedback counts (likes/dislikes/points)
          final feedbackCounts = await FeedbackFolderUtils.getAllFeedbackCounts(
            postPath,
            storage: storage,
          );
          final likes = feedbackCounts[FeedbackFolderUtils.feedbackTypeLikes] ?? 0;
          final dislikes = feedbackCounts[FeedbackFolderUtils.feedbackTypeDislikes] ?? 0;
          final points = feedbackCounts[FeedbackFolderUtils.feedbackTypePoints] ?? 0;

          posts.add({
            'id': post.id,
            'title': post.title,
            'author': post.author,
            'timestamp': post.timestamp,
            'edited': post.edited,
            'description': post.description,
            'year': post.year,
            'status': post.status.name,
            'tags': post.tags,
            'comment_count': comments.length,
            'likes_count': likes,
            'dislikes_count': dislikes,
            'points_count': points,
            'has_file': post.hasFile,
            'has_image': post.hasImage,
            'has_location': post.hasLocation,
            if (post.npub != null) 'npub': post.npub,
          });
        } catch (e) {
          _log('WARN', 'Failed to parse post: blog/$yearName/$postId');
        }
      }
    }

    // Sort by date (most recent first)
    posts.sort((a, b) {
      final aTimestamp = a['timestamp'] as String? ?? '';
      final bTimestamp = b['timestamp'] as String? ?? '';
      return bTimestamp.compareTo(aTimestamp);
    });

    return posts;
  }
}
