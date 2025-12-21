/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Service for posting and managing comments on remote blog posts.
 * Uses ConnectionManager for transport-agnostic device-to-device communication.
 */

import '../connection/connection_manager.dart';
import 'log_service.dart';

/// Result of a remote comment operation
class CommentResult {
  final bool success;
  final String? commentId;
  final String? error;
  final String? transportUsed;

  CommentResult({
    required this.success,
    this.commentId,
    this.error,
    this.transportUsed,
  });
}

/// Service for posting and managing comments on remote blog posts
class BlogCommentService {
  static final BlogCommentService _instance = BlogCommentService._internal();
  factory BlogCommentService() => _instance;
  BlogCommentService._internal();

  /// Post a comment to a remote device's blog post
  ///
  /// [targetCallsign] - The callsign of the device hosting the blog post
  /// [postId] - The ID of the blog post to comment on
  /// [author] - The commenter's callsign
  /// [content] - The comment text
  /// [npub] - Optional NOSTR public key for verification
  /// [signature] - Optional NOSTR signature for the comment
  Future<CommentResult> postRemoteComment({
    required String targetCallsign,
    required String postId,
    required String author,
    required String content,
    String? npub,
    String? signature,
  }) async {
    try {
      LogService().log(
        'BlogCommentService: Posting comment to $targetCallsign post $postId',
      );

      final body = {
        'author': author,
        'content': content,
        if (npub != null) 'npub': npub,
        if (signature != null) 'signature': signature,
      };

      final result = await ConnectionManager().apiRequest(
        callsign: targetCallsign,
        method: 'POST',
        path: '/api/blog/$postId/comment',
        body: body,
      );

      if (result.success && result.statusCode == 200) {
        final responseData = result.responseData;
        final commentId = responseData is Map ? responseData['comment_id'] as String? : null;

        LogService().log(
          'BlogCommentService: Comment posted successfully via ${result.transportUsed}',
        );

        return CommentResult(
          success: true,
          commentId: commentId,
          transportUsed: result.transportUsed,
        );
      } else {
        final error = result.error ?? 'Unknown error';
        LogService().log('BlogCommentService: Failed to post comment: $error');

        return CommentResult(
          success: false,
          error: error,
          transportUsed: result.transportUsed,
        );
      }
    } catch (e) {
      LogService().log('BlogCommentService: Error posting comment: $e');
      return CommentResult(
        success: false,
        error: e.toString(),
      );
    }
  }

  /// Delete own comment from a remote device's blog post
  ///
  /// [targetCallsign] - The callsign of the device hosting the blog post
  /// [postId] - The ID of the blog post
  /// [commentId] - The ID of the comment to delete
  /// [npub] - The requester's NOSTR public key for authorization
  Future<CommentResult> deleteRemoteComment({
    required String targetCallsign,
    required String postId,
    required String commentId,
    required String npub,
  }) async {
    try {
      LogService().log(
        'BlogCommentService: Deleting comment $commentId from $targetCallsign post $postId',
      );

      final result = await ConnectionManager().apiRequest(
        callsign: targetCallsign,
        method: 'DELETE',
        path: '/api/blog/$postId/comment/$commentId',
        headers: {'X-Npub': npub},
      );

      if (result.success && result.statusCode == 200) {
        LogService().log(
          'BlogCommentService: Comment deleted successfully via ${result.transportUsed}',
        );

        return CommentResult(
          success: true,
          transportUsed: result.transportUsed,
        );
      } else {
        final error = result.error ?? 'Unknown error';
        LogService().log('BlogCommentService: Failed to delete comment: $error');

        return CommentResult(
          success: false,
          error: error,
          transportUsed: result.transportUsed,
        );
      }
    } catch (e) {
      LogService().log('BlogCommentService: Error deleting comment: $e');
      return CommentResult(
        success: false,
        error: e.toString(),
      );
    }
  }

  /// Fetch a remote blog post with its comments
  ///
  /// [targetCallsign] - The callsign of the device hosting the blog post
  /// [postId] - The ID of the blog post to fetch
  Future<Map<String, dynamic>?> fetchRemotePost({
    required String targetCallsign,
    required String postId,
  }) async {
    try {
      LogService().log(
        'BlogCommentService: Fetching post $postId from $targetCallsign',
      );

      final result = await ConnectionManager().apiRequest(
        callsign: targetCallsign,
        method: 'GET',
        path: '/api/blog/$postId',
      );

      if (result.success && result.statusCode == 200) {
        LogService().log(
          'BlogCommentService: Post fetched successfully via ${result.transportUsed}',
        );
        return result.responseData as Map<String, dynamic>?;
      } else {
        LogService().log('BlogCommentService: Failed to fetch post: ${result.error}');
        return null;
      }
    } catch (e) {
      LogService().log('BlogCommentService: Error fetching post: $e');
      return null;
    }
  }

  /// List blog posts from a remote device
  ///
  /// [targetCallsign] - The callsign of the device to query
  /// [year] - Optional year filter
  /// [tag] - Optional tag filter
  /// [limit] - Optional limit on results
  /// [offset] - Optional offset for pagination
  Future<List<Map<String, dynamic>>?> listRemotePosts({
    required String targetCallsign,
    int? year,
    String? tag,
    int? limit,
    int? offset,
  }) async {
    try {
      LogService().log(
        'BlogCommentService: Listing posts from $targetCallsign',
      );

      // Build query parameters
      final queryParams = <String, String>{};
      if (year != null) queryParams['year'] = year.toString();
      if (tag != null) queryParams['tag'] = tag;
      if (limit != null) queryParams['limit'] = limit.toString();
      if (offset != null) queryParams['offset'] = offset.toString();

      String path = '/api/blog';
      if (queryParams.isNotEmpty) {
        final queryString = queryParams.entries
            .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
            .join('&');
        path = '$path?$queryString';
      }

      final result = await ConnectionManager().apiRequest(
        callsign: targetCallsign,
        method: 'GET',
        path: path,
      );

      if (result.success && result.statusCode == 200) {
        final responseData = result.responseData as Map<String, dynamic>?;
        final posts = responseData?['posts'] as List<dynamic>?;

        LogService().log(
          'BlogCommentService: Listed ${posts?.length ?? 0} posts via ${result.transportUsed}',
        );

        return posts?.cast<Map<String, dynamic>>();
      } else {
        LogService().log('BlogCommentService: Failed to list posts: ${result.error}');
        return null;
      }
    } catch (e) {
      LogService().log('BlogCommentService: Error listing posts: $e');
      return null;
    }
  }
}
