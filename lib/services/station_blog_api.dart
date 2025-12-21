/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Blog API handlers for device-hosted blog posts.
 * Enables remote devices to view posts and add/delete comments.
 */

import 'dart:io';

import '../models/blog_post.dart';
import '../util/blog_folder_utils.dart';

/// Blog API handlers for device-hosted blogs
class StationBlogApi {
  final String dataDir;
  final String callsign;
  final void Function(String level, String message)? log;

  StationBlogApi({
    required this.dataDir,
    required this.callsign,
    this.log,
  });

  void _log(String level, String message) {
    log?.call(level, message);
  }

  /// Get the blog path for this device
  String get _blogPath => '$dataDir/devices/$callsign/blog';

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
      final postPath = await BlogFolderUtils.findPostPath(_blogPath, postId);

      if (postPath == null) {
        _log('WARN', 'getPostDetails: post not found: $postId');
        return {'error': 'Post not found', 'http_status': 404};
      }

      // Read post content
      final postFile = File(BlogFolderUtils.buildPostFilePath(postPath));
      if (!await postFile.exists()) {
        return {'error': 'Post file not found', 'http_status': 404};
      }

      final postContent = await postFile.readAsString();

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
      final comments = await BlogFolderUtils.loadComments(postPath);
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
      final filesDir = Directory(BlogFolderUtils.buildFilesPath(postPath));
      if (await filesDir.exists()) {
        await for (final entity in filesDir.list()) {
          if (entity is File) {
            final filename = entity.path.split('/').last;
            files.add(filename);
          }
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
  Future<Map<String, dynamic>> addComment(
    String postId,
    String author,
    String content, {
    String? npub,
    String? signature,
  }) async {
    try {
      // Find the post folder
      final postPath = await BlogFolderUtils.findPostPath(_blogPath, postId);

      if (postPath == null) {
        return {'error': 'Post not found', 'http_status': 404};
      }

      // Verify post is published
      final postFile = File(BlogFolderUtils.buildPostFilePath(postPath));
      if (await postFile.exists()) {
        final postContent = await postFile.readAsString();
        try {
          final post = BlogPost.fromText(postContent, postId);
          if (!post.isPublished) {
            return {'error': 'Cannot comment on unpublished post', 'http_status': 403};
          }
        } catch (e) {
          _log('WARN', 'addComment: could not verify post status: $e');
        }
      }

      // Write comment
      final commentId = await BlogFolderUtils.writeComment(
        postFolderPath: postPath,
        author: author,
        content: content,
        npub: npub,
        signature: signature,
      );

      _log('INFO', 'Comment added to post $postId by $author');

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
      final postPath = await BlogFolderUtils.findPostPath(_blogPath, postId);

      if (postPath == null) {
        return {'error': 'Post not found', 'http_status': 404};
      }

      // Load the comment to check permissions
      final comment = await BlogFolderUtils.getComment(postPath, commentId);
      if (comment == null) {
        return {'error': 'Comment not found', 'http_status': 404};
      }

      // Load post to check if requester is post author
      final postFile = File(BlogFolderUtils.buildPostFilePath(postPath));
      String? postNpub;
      if (await postFile.exists()) {
        final postContent = await postFile.readAsString();
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
      final deleted = await BlogFolderUtils.deleteComment(postPath, commentId);

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

    final postPath = await BlogFolderUtils.findPostPath(_blogPath, postId);
    if (postPath == null) return null;

    final filePath = '${BlogFolderUtils.buildFilesPath(postPath)}/$filename';
    final file = File(filePath);
    if (await file.exists()) {
      return filePath;
    }

    return null;
  }

  // ============================================================
  // Internal helper methods
  // ============================================================

  /// Load all posts from blog directory
  Future<List<Map<String, dynamic>>> _loadAllPosts({bool publishedOnly = false}) async {
    final posts = <Map<String, dynamic>>[];
    final blogDir = Directory(_blogPath);

    if (!await blogDir.exists()) {
      return posts;
    }

    // Iterate through year directories
    await for (final yearEntity in blogDir.list()) {
      if (yearEntity is! Directory) continue;

      final yearName = yearEntity.path.split('/').last;
      final year = int.tryParse(yearName);
      if (year == null) continue;

      // Iterate through post directories
      await for (final postEntity in yearEntity.list()) {
        if (postEntity is! Directory) continue;

        final postId = postEntity.path.split('/').last;
        final postFile = File('${postEntity.path}/post.md');

        if (!await postFile.exists()) continue;

        try {
          final content = await postFile.readAsString();
          final post = BlogPost.fromText(content, postId);

          // Filter by published status
          if (publishedOnly && !post.isPublished) {
            continue;
          }

          // Count comments
          final comments = await BlogFolderUtils.loadComments(postEntity.path);

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
            'has_file': post.hasFile,
            'has_image': post.hasImage,
            'has_location': post.hasLocation,
            if (post.npub != null) 'npub': post.npub,
          });
        } catch (e) {
          _log('WARN', 'Failed to parse post: ${postEntity.path}');
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
