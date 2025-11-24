/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'dart:convert';
import '../models/news_article.dart';
import '../models/blog_comment.dart';
import 'log_service.dart';

/// Model for chat security (reused for news)
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

/// Service for managing news articles and comments
class NewsService {
  static final NewsService _instance = NewsService._internal();
  factory NewsService() => _instance;
  NewsService._internal();

  String? _collectionPath;
  ChatSecurity _security = ChatSecurity();

  /// Initialize news service for a collection
  Future<void> initializeCollection(String collectionPath, {String? creatorNpub}) async {
    print('NewsService: Initializing with collection path: $collectionPath');
    _collectionPath = collectionPath;

    // Ensure news directory exists
    final newsDir = Directory('$collectionPath/news');
    if (!await newsDir.exists()) {
      await newsDir.create(recursive: true);
      print('NewsService: Created news directory');
    }

    // Load security
    await _loadSecurity();

    // If no admin set and creator provided, set as admin
    if (_security.adminNpub == null && creatorNpub != null && creatorNpub.isNotEmpty) {
      print('NewsService: Setting creator as admin: $creatorNpub');
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
        print('NewsService: Loaded security settings');
      } catch (e) {
        print('NewsService: Error loading security: $e');
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

    print('NewsService: Saved security settings');
  }

  /// Get available years (folders in news directory)
  Future<List<int>> getYears() async {
    if (_collectionPath == null) return [];

    final newsDir = Directory('$_collectionPath/news');
    if (!await newsDir.exists()) return [];

    final years = <int>[];
    final entities = await newsDir.list().toList();

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

  /// Load articles metadata for a specific year or all years
  Future<List<NewsArticle>> loadArticles({
    int? year,
    bool includeExpired = true,
    String? currentUserNpub,
  }) async {
    if (_collectionPath == null) return [];

    final articles = <NewsArticle>[];
    final years = year != null ? [year] : await getYears();

    for (var y in years) {
      final yearDir = Directory('$_collectionPath/news/$y');
      if (!await yearDir.exists()) continue;

      final entities = await yearDir.list().toList();


      for (var entity in entities) {
        if (entity is File && entity.path.endsWith('.md')) {
          try {
            final fileName = entity.path.split('/').last;
            final articleId = fileName.substring(0, fileName.length - 3); // Remove .md

            final content = await entity.readAsString();
            final article = NewsArticle.fromText(content, articleId);

            // Filter by expiry status
            if (!includeExpired && article.isExpired) {
              continue;
            }

            articles.add(article);
          } catch (e) {
            print('NewsService: Error loading article ${entity.path}: $e');
          }
        }
      }
    }

    // Sort by date (most recent first)
    articles.sort((a, b) => b.dateTime.compareTo(a.dateTime));

    return articles;
  }

  /// Load full article with comments
  Future<NewsArticle?> loadFullArticle(String articleId) async {
    if (_collectionPath == null) return null;

    // Extract year from articleId (format: YYYY-MM-DD_title)
    final year = articleId.substring(0, 4);
    final articleFile = File('$_collectionPath/news/$year/$articleId.md');

    if (!await articleFile.exists()) {
      print('NewsService: Article file not found: ${articleFile.path}');
      return null;
    }

    try {
      final content = await articleFile.readAsString();
      return NewsArticle.fromText(content, articleId);
    } catch (e) {
      print('NewsService: Error loading full article: $e');
      return null;
    }
  }

  /// Sanitize headline to create valid filename
  String sanitizeFilename(String headline, DateTime? date) {
    date ??= DateTime.now();

    // Convert to lowercase, replace spaces with hyphens
    String sanitized = headline.toLowerCase().trim();

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

    while (await File('$_collectionPath/news/$year/$filename.md').exists()) {
      filename = '$baseFilename-$suffix';
      suffix++;
    }

    return filename;
  }

  /// Format timestamp for storage
  String _formatTimestamp(DateTime dt) {
    final year = dt.year.toString().padLeft(4, '0');
    final month = dt.month.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    final second = dt.second.toString().padLeft(2, '0');
    return '$year-$month-$day $hour:$minute:$second';
  }

  /// Create new news article
  Future<NewsArticle?> createArticle({
    required String author,
    required Map<String, String> headlines,  // Language code -> headline
    required Map<String, String> contents,   // Language code -> content
    NewsClassification classification = NewsClassification.normal,
    double? latitude,
    double? longitude,
    String? address,
    double? radiusKm,
    DateTime? expiryDateTime,
    String? source,
    List<String>? tags,
    String? npub,
    Map<String, String>? metadata,
  }) async {
    if (_collectionPath == null) return null;

    try {
      // Validate headlines not empty
      if (headlines.isEmpty) {
        print('NewsService: At least one headline is required');
        return null;
      }

      // Validate contents not empty
      if (contents.isEmpty) {
        print('NewsService: At least one content version is required');
        return null;
      }

      // Validate content length for each language
      for (var entry in contents.entries) {
        if (entry.value.length > 500) {
          print('NewsService: Content for language ${entry.key} exceeds 500 character limit');
          return null;
        }
      }

      // Validate radius requires location
      if (radiusKm != null && (latitude == null || longitude == null)) {
        print('NewsService: Radius requires location coordinates');
        return null;
      }

      // Validate radius range
      if (radiusKm != null && (radiusKm < 0.1 || radiusKm > 100)) {
        print('NewsService: Radius must be between 0.1 and 100 km');
        return null;
      }

      final now = DateTime.now();
      final year = now.year;

      // Sanitize filename using first available headline
      final firstHeadline = headlines.values.first;
      final baseFilename = sanitizeFilename(firstHeadline, now);
      final filename = await _ensureUniqueFilename(baseFilename, year);

      // Ensure year directory exists
      final yearDir = Directory('$_collectionPath/news/$year');
      if (!await yearDir.exists()) {
        await yearDir.create(recursive: true);
      }

      // Create news article
      final article = NewsArticle(
        id: filename,
        author: author,
        timestamp: _formatTimestamp(now),
        headlines: headlines,
        contents: contents,
        classification: classification,
        latitude: latitude,
        longitude: longitude,
        address: address,
        radiusKm: radiusKm,
        expiry: expiryDateTime != null ? _formatTimestamp(expiryDateTime) : null,
        source: source,
        tags: tags ?? [],
        metadata: {
          ...?metadata,
          if (npub != null) 'npub': npub,
        },
      );

      // Write to file
      final articleFile = File('$_collectionPath/news/$year/$filename.md');
      await articleFile.writeAsString(article.exportAsText(), flush: true);

      print('NewsService: Created article: $filename');
      return article;
    } catch (e) {
      print('NewsService: Error creating article: $e');
      return null;
    }
  }

  /// Update existing news article
  Future<bool> updateArticle({
    required String articleId,
    Map<String, String>? headlines,
    Map<String, String>? contents,
    NewsClassification? classification,
    double? latitude,
    double? longitude,
    String? address,
    double? radiusKm,
    DateTime? expiryDateTime,
    String? source,
    List<String>? tags,
    Map<String, String>? metadata,
    required String? userNpub,
  }) async {
    if (_collectionPath == null) return false;

    // Load existing article
    final article = await loadFullArticle(articleId);
    if (article == null) return false;

    // Check permissions (author or admin)
    if (!_security.isAdmin(userNpub) && !article.isOwnArticle(userNpub)) {
      print('NewsService: User $userNpub cannot edit article by ${article.npub}');
      return false;
    }

    // Validate content length for each language if provided
    if (contents != null) {
      for (var entry in contents.entries) {
        if (entry.value.length > 500) {
          print('NewsService: Content for language ${entry.key} exceeds 500 character limit');
          return false;
        }
      }
    }

    try {
      // Update article
      final updatedArticle = article.copyWith(
        headlines: headlines ?? article.headlines,
        contents: contents ?? article.contents,
        classification: classification ?? article.classification,
        latitude: latitude ?? article.latitude,
        longitude: longitude ?? article.longitude,
        address: address ?? article.address,
        radiusKm: radiusKm ?? article.radiusKm,
        expiry: expiryDateTime != null ? _formatTimestamp(expiryDateTime) : article.expiry,
        source: source ?? article.source,
        tags: tags ?? article.tags,
        metadata: metadata ?? article.metadata,
      );

      // Write to file
      final year = article.year;
      final articleFile = File('$_collectionPath/news/$year/$articleId.md');
      await articleFile.writeAsString(updatedArticle.exportAsText(), flush: true);

      print('NewsService: Updated article: $articleId');
      return true;
    } catch (e) {
      print('NewsService: Error updating article: $e');
      return false;
    }
  }

  /// Delete news article
  Future<bool> deleteArticle(String articleId, String? userNpub) async {
    if (_collectionPath == null) return false;

    // Load article to check permissions
    final article = await loadFullArticle(articleId);
    if (article == null) return false;

    // Check permissions (author or admin)
    if (!_security.isAdmin(userNpub) && !article.isOwnArticle(userNpub)) {
      print('NewsService: User $userNpub cannot delete article by ${article.npub}');
      return false;
    }

    try {
      final year = article.year;
      final articleFile = File('$_collectionPath/news/$year/$articleId.md');

      if (await articleFile.exists()) {
        await articleFile.delete();
        print('NewsService: Deleted article: $articleId');
        return true;
      }

      return false;
    } catch (e) {
      print('NewsService: Error deleting article: $e');
      return false;
    }
  }

  /// Toggle like on an article
  Future<bool> toggleLike(String articleId, String callsign) async {
    if (_collectionPath == null) return false;

    // Load article
    final article = await loadFullArticle(articleId);
    if (article == null) return false;

    try {
      final likes = List<String>.from(article.likes);

      if (likes.contains(callsign)) {
        // Unlike
        likes.remove(callsign);
      } else {
        // Like
        likes.add(callsign);
      }

      // Update article with new likes
      final updatedArticle = article.copyWith(likes: likes);

      // Write to file
      final year = article.year;
      final articleFile = File('$_collectionPath/news/$year/$articleId.md');
      await articleFile.writeAsString(updatedArticle.exportAsText(), flush: true);

      print('NewsService: Toggled like for $callsign on article $articleId');
      return true;
    } catch (e) {
      print('NewsService: Error toggling like: $e');
      return false;
    }
  }

  /// Add comment to article
  Future<bool> addComment({
    required String articleId,
    required String author,
    required String content,
    String? npub,
    String? signature,
  }) async {
    if (_collectionPath == null) return false;

    // Load article
    final article = await loadFullArticle(articleId);
    if (article == null) return false;

    try {
      final now = DateTime.now();

      // Create comment
      final comment = BlogComment(
        author: author,
        timestamp: _formatTimestamp(now),
        content: content,
        metadata: {
          if (npub != null) 'npub': npub,
          if (signature != null) 'signature': signature,
        },
      );

      // Add to comments list
      final comments = List<BlogComment>.from(article.comments);
      comments.add(comment);

      // Update article
      final updatedArticle = article.copyWith(comments: comments);

      // Write to file
      final year = article.year;
      final articleFile = File('$_collectionPath/news/$year/$articleId.md');
      await articleFile.writeAsString(updatedArticle.exportAsText(), flush: true);

      print('NewsService: Added comment to article $articleId');
      return true;
    } catch (e) {
      print('NewsService: Error adding comment: $e');
      return false;
    }
  }

  /// Delete comment from article
  Future<bool> deleteComment({
    required String articleId,
    required int commentIndex,
    required String? userNpub,
  }) async {
    if (_collectionPath == null) return false;

    // Load article
    final article = await loadFullArticle(articleId);
    if (article == null) return false;

    if (commentIndex < 0 || commentIndex >= article.comments.length) {
      print('NewsService: Invalid comment index');
      return false;
    }

    final comment = article.comments[commentIndex];

    // Check permissions (comment author or admin)
    if (!_security.isAdmin(userNpub) && comment.npub != userNpub) {
      print('NewsService: User $userNpub cannot delete comment by ${comment.npub}');
      return false;
    }

    try {
      // Remove comment
      final comments = List<BlogComment>.from(article.comments);
      comments.removeAt(commentIndex);

      // Update article
      final updatedArticle = article.copyWith(comments: comments);

      // Write to file
      final year = article.year;
      final articleFile = File('$_collectionPath/news/$year/$articleId.md');
      await articleFile.writeAsString(updatedArticle.exportAsText(), flush: true);

      print('NewsService: Deleted comment from article $articleId');
      return true;
    } catch (e) {
      print('NewsService: Error deleting comment: $e');
      return false;
    }
  }

  /// Check if user is admin
  bool isAdmin(String? npub) {
    return _security.isAdmin(npub);
  }
}
