/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import '../models/blog_post.dart';
import '../models/blog_comment.dart';
import 'log_service.dart';

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
class BlogService {
  static final BlogService _instance = BlogService._internal();
  factory BlogService() => _instance;
  BlogService._internal();

  String? _collectionPath;
  ChatSecurity _security = ChatSecurity();

  /// Initialize blog service for a collection
  Future<void> initializeCollection(String collectionPath, {String? creatorNpub}) async {
    print('BlogService: Initializing with collection path: $collectionPath');
    _collectionPath = collectionPath;

    // Ensure blog directory exists
    final blogDir = Directory('$collectionPath/blog');
    if (!await blogDir.exists()) {
      await blogDir.create(recursive: true);
      print('BlogService: Created blog directory');
    }

    // Load security
    await _loadSecurity();

    // If no admin set and creator provided, set as admin
    if (_security.adminNpub == null && creatorNpub != null && creatorNpub.isNotEmpty) {
      print('BlogService: Setting creator as admin: $creatorNpub');
      final newSecurity = ChatSecurity(adminNpub: creatorNpub);
      await saveSecurity(newSecurity);
    }
  }

  /// Load security settings
  Future<void> _loadSecurity() async {
    if (_collectionPath == null) return;

    final securityFile = File('$_collectionPath/extra/security.json');
    if (await securityFile.exists()) {
      try {
        final content = await securityFile.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        _security = ChatSecurity.fromJson(json);
        print('BlogService: Loaded security settings');
      } catch (e) {
        print('BlogService: Error loading security: $e');
        _security = ChatSecurity();
      }
    } else {
      _security = ChatSecurity();
    }
  }

  /// Save security settings
  Future<void> saveSecurity(ChatSecurity security) async {
    if (_collectionPath == null) return;

    _security = security;

    final extraDir = Directory('$_collectionPath/extra');
    if (!await extraDir.exists()) {
      await extraDir.create(recursive: true);
    }

    final securityFile = File('$_collectionPath/extra/security.json');
    await securityFile.writeAsString(
      jsonEncode(security.toJson()),
      flush: true,
    );

    print('BlogService: Saved security settings');
  }

  /// Get available years (folders in blog directory)
  Future<List<int>> getYears() async {
    if (_collectionPath == null) return [];

    final blogDir = Directory('$_collectionPath/blog');
    if (!await blogDir.exists()) return [];

    final years = <int>[];
    final entities = await blogDir.list().toList();

    for (var entity in entities) {
      if (entity is Directory) {
        final name = entity.path.split('/').last;
        final year = int.tryParse(name);
        if (year != null) {
          years.add(year);
        }
      }
    }

    years.sort((a, b) => b.compareTo(a)); // Most recent first
    return years;
  }

  /// Load posts metadata (without full content) for a specific year or all years
  Future<List<BlogPost>> loadPosts({
    int? year,
    bool publishedOnly = false,
    String? currentUserNpub,
  }) async {
    if (_collectionPath == null) return [];

    final posts = <BlogPost>[];
    final years = year != null ? [year] : await getYears();

    for (var y in years) {
      final yearDir = Directory('$_collectionPath/blog/$y');
      if (!await yearDir.exists()) continue;

      final entities = await yearDir.list().toList();


      for (var entity in entities) {
        if (entity is File && entity.path.endsWith('.md')) {
          try {
            final fileName = entity.path.split('/').last;
            final postId = fileName.substring(0, fileName.length - 3); // Remove .md

            final content = await entity.readAsString();
            final post = BlogPost.fromText(content, postId);

            // Filter by published status
            if (publishedOnly && !post.isPublished) {
              // Skip drafts unless user is the author
              if (!post.isOwnPost(currentUserNpub)) {
                continue;
              }
            }

            posts.add(post);
          } catch (e) {
            print('BlogService: Error loading post ${entity.path}: $e');
          }
        }
      }
    }

    // Sort by date (most recent first)
    posts.sort((a, b) => b.dateTime.compareTo(a.dateTime));

    return posts;
  }

  /// Load full post with comments
  Future<BlogPost?> loadFullPost(String postId) async {
    if (_collectionPath == null) return null;

    // Extract year from postId (format: YYYY-MM-DD_title)
    final year = postId.substring(0, 4);
    final postFile = File('$_collectionPath/blog/$year/$postId.md');

    if (!await postFile.exists()) {
      print('BlogService: Post file not found: ${postFile.path}');
      return null;
    }

    try {
      final content = await postFile.readAsString();
      return BlogPost.fromText(content, postId);
    } catch (e) {
      print('BlogService: Error loading full post: $e');
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

  /// Check if filename already exists, add suffix if needed
  Future<String> _ensureUniqueFilename(String baseFilename, int year) async {
    String filename = baseFilename;
    int suffix = 1;

    while (await File('$_collectionPath/blog/$year/$filename.md').exists()) {
      filename = '$baseFilename-$suffix';
      suffix++;
    }

    return filename;
  }

  /// Create new blog post
  Future<BlogPost?> createPost({
    required String author,
    required String title,
    String? description,
    required String content,
    List<String>? tags,
    BlogStatus status = BlogStatus.draft,
    String? npub,
    Map<String, String>? metadata,
  }) async {
    if (_collectionPath == null) return null;

    try {
      final now = DateTime.now();
      final year = now.year;

      // Sanitize filename
      final baseFilename = sanitizeFilename(title, now);
      final filename = await _ensureUniqueFilename(baseFilename, year);

      // Ensure year directory exists
      final yearDir = Directory('$_collectionPath/blog/$year');
      if (!await yearDir.exists()) {
        await yearDir.create(recursive: true);
      }

      // Create blog post
      final post = BlogPost(
        id: filename,
        author: author,
        timestamp: _formatTimestamp(now),
        title: title,
        description: description,
        status: status,
        tags: tags ?? [],
        content: content,
        metadata: {
          ...?metadata,
          if (npub != null) 'npub': npub,
        },
      );

      // Write to file
      final postFile = File('$_collectionPath/blog/$year/$filename.md');
      await postFile.writeAsString(post.exportAsText(), flush: true);

      print('BlogService: Created post: $filename');
      return post;
    } catch (e) {
      print('BlogService: Error creating post: $e');
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
    required String? userNpub,
  }) async {
    if (_collectionPath == null) return false;

    // Load existing post
    final post = await loadFullPost(postId);
    if (post == null) return false;

    // Check permissions (author or admin)
    if (!_security.isAdmin(userNpub) && !post.isOwnPost(userNpub)) {
      print('BlogService: User $userNpub cannot edit post by ${post.npub}');
      return false;
    }

    try {
      // Update post
      final updatedPost = post.copyWith(
        title: title ?? post.title,
        description: description ?? post.description,
        content: content ?? post.content,
        tags: tags ?? post.tags,
        status: status ?? post.status,
        metadata: metadata ?? post.metadata,
      );

      // Write to file
      final year = post.year;
      final postFile = File('$_collectionPath/blog/$year/$postId.md');
      await postFile.writeAsString(updatedPost.exportAsText(), flush: true);

      print('BlogService: Updated post: $postId');
      return true;
    } catch (e) {
      print('BlogService: Error updating post: $e');
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

  /// Delete blog post
  Future<bool> deletePost(String postId, String? userNpub) async {
    if (_collectionPath == null) return false;

    // Load post to check permissions
    final post = await loadFullPost(postId);
    if (post == null) return false;

    // Check permissions (author or admin)
    if (!_security.isAdmin(userNpub) && !post.isOwnPost(userNpub)) {
      print('BlogService: User $userNpub cannot delete post by ${post.npub}');
      return false;
    }

    try {
      final year = post.year;
      final postFile = File('$_collectionPath/blog/$year/$postId.md');

      if (await postFile.exists()) {
        await postFile.delete();
        print('BlogService: Deleted post: $postId');
        return true;
      }

      return false;
    } catch (e) {
      print('BlogService: Error deleting post: $e');
      return false;
    }
  }

  /// Add comment to blog post
  Future<bool> addComment({
    required String postId,
    required String author,
    required String content,
    String? npub,
    Map<String, String>? metadata,
  }) async {
    if (_collectionPath == null) return false;

    // Load post
    final post = await loadFullPost(postId);
    if (post == null) return false;

    // Only allow comments on published posts
    if (!post.isPublished) {
      print('BlogService: Cannot comment on draft post');
      return false;
    }

    try {
      // Create comment
      final comment = BlogComment.now(
        author: author,
        content: content,
        metadata: {
          ...?metadata,
          if (npub != null) 'npub': npub,
        },
      );

      // Append to post file
      final year = post.year;
      final postFile = File('$_collectionPath/blog/$year/$postId.md');
      await postFile.writeAsString(
        '\n${comment.exportAsText()}',
        mode: FileMode.append,
        flush: true,
      );

      print('BlogService: Added comment to post: $postId');
      return true;
    } catch (e) {
      print('BlogService: Error adding comment: $e');
      return false;
    }
  }

  /// Delete comment from blog post
  Future<bool> deleteComment({
    required String postId,
    required int commentIndex,
    required String? userNpub,
  }) async {
    if (_collectionPath == null) return false;

    // Load post
    final post = await loadFullPost(postId);
    if (post == null) return false;

    if (commentIndex < 0 || commentIndex >= post.comments.length) {
      return false;
    }

    final comment = post.comments[commentIndex];

    // Check permissions (admin, moderator, or comment author)
    final isCommentAuthor = comment.npub != null && comment.npub == userNpub;
    if (!_security.isAdmin(userNpub) && !isCommentAuthor) {
      print('BlogService: User $userNpub cannot delete comment by ${comment.npub}');
      return false;
    }

    try {
      // Remove comment and rewrite file
      final updatedComments = List<BlogComment>.from(post.comments);
      updatedComments.removeAt(commentIndex);

      final updatedPost = post.copyWith(comments: updatedComments);

      final year = post.year;
      final postFile = File('$_collectionPath/blog/$year/$postId.md');
      await postFile.writeAsString(updatedPost.exportAsText(), flush: true);

      print('BlogService: Deleted comment from post: $postId');
      return true;
    } catch (e) {
      print('BlogService: Error deleting comment: $e');
      return false;
    }
  }

  /// Copy file to blog files directory with SHA1-based naming
  Future<String?> copyFileToBlog(String sourcePath, int year) async {
    if (_collectionPath == null) return null;

    try {
      final sourceFile = File(sourcePath);
      if (!await sourceFile.exists()) {
        print('BlogService: Source file does not exist: $sourcePath');
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

      // Ensure files directory exists
      final filesDir = Directory('$_collectionPath/blog/$year/files');
      if (!await filesDir.exists()) {
        await filesDir.create(recursive: true);
      }

      // Copy file
      final destFile = File('$_collectionPath/blog/$year/files/$destFileName');
      await sourceFile.copy(destFile.path);

      print('BlogService: Copied file: $destFileName');
      return destFileName;
    } catch (e) {
      print('BlogService: Error copying file: $e');
      return null;
    }
  }

  /// Format DateTime to timestamp string
  static String _formatTimestamp(DateTime dt) {
    final year = dt.year.toString().padLeft(4, '0');
    final month = dt.month.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    final second = dt.second.toString().padLeft(2, '0');
    return '$year-$month-$day $hour:$minute\_$second';
  }

  /// Get current security settings
  ChatSecurity getSecurity() => _security;

  /// Check if user is admin
  bool isAdmin(String? npub) => _security.isAdmin(npub);

  /// Check if user can moderate
  bool canModerate(String? npub) => _security.isAdmin(npub);
}
