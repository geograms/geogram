/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/devices_service.dart';
import '../services/i18n_service.dart';
import '../services/log_service.dart';
import '../services/station_service.dart';
import '../services/storage_config.dart';

/// Page for browsing blog posts from a remote device
class RemoteBlogBrowserPage extends StatefulWidget {
  final RemoteDevice device;

  const RemoteBlogBrowserPage({
    super.key,
    required this.device,
  });

  @override
  State<RemoteBlogBrowserPage> createState() => _RemoteBlogBrowserPageState();
}

class _RemoteBlogBrowserPageState extends State<RemoteBlogBrowserPage> {
  final DevicesService _devicesService = DevicesService();
  final I18nService _i18n = I18nService();

  List<BlogPost> _posts = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadPosts();
  }

  Future<void> _loadPosts() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // Try to load from cache first for instant response
      final cachedPosts = await _loadFromCache();
      if (cachedPosts.isNotEmpty) {
        setState(() {
          _posts = cachedPosts;
          _isLoading = false;
        });

        // Silently refresh from API in background
        _refreshFromApi();
        return;
      }

      // No cache - fetch from API
      await _fetchFromApi();
    } catch (e) {
      LogService().log('RemoteBlogBrowserPage: Error loading posts: $e');
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  /// Load posts from cached data on disk
  Future<List<BlogPost>> _loadFromCache() async {
    try {
      final dataDir = StorageConfig().baseDir;
      final blogPath = '$dataDir/devices/${widget.device.callsign}/blog';
      final blogDir = Directory(blogPath);

      if (!await blogDir.exists()) {
        return [];
      }

      final posts = <BlogPost>[];
      await for (final entity in blogDir.list()) {
        if (entity is File && entity.path.endsWith('.json')) {
          try {
            final content = await entity.readAsString();
            final data = json.decode(content) as Map<String, dynamic>;
            posts.add(BlogPost.fromJson(data));
          } catch (e) {
            LogService().log('Error reading blog post ${entity.path}: $e');
          }
        }
      }

      // Sort by timestamp descending
      posts.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      LogService().log('RemoteBlogBrowserPage: Loaded ${posts.length} cached posts');
      return posts;
    } catch (e) {
      LogService().log('RemoteBlogBrowserPage: Error loading cache: $e');
      return [];
    }
  }

  /// Fetch fresh posts from API
  Future<void> _fetchFromApi() async {
    try {
      final response = await _devicesService.makeDeviceApiRequest(
        callsign: widget.device.callsign,
        method: 'GET',
        path: '/api/blog',
      );

      if (response != null && response.statusCode == 200) {
        final data = json.decode(response.body);
        final List<dynamic> postsData = data is Map ? (data['posts'] ?? data) : data;

        setState(() {
          _posts = postsData.map((json) => BlogPost.fromJson(json)).toList();
          _isLoading = false;
        });
        LogService().log('RemoteBlogBrowserPage: Fetched ${_posts.length} posts from API');
      } else {
        throw Exception('HTTP ${response?.statusCode ?? "null"}: ${response?.body ?? "no response"}');
      }
    } catch (e) {
      throw e;
    }
  }

  /// Silently refresh from API in background
  void _refreshFromApi() {
    _fetchFromApi().catchError((e) {
      LogService().log('RemoteBlogBrowserPage: Background refresh failed: $e');
      // Don't update UI with error, keep showing cached data
    });
  }

  Future<void> _openPost(BlogPost post) async {
    // Get station URL - use device's station if available, otherwise use preferred station
    String? stationUrl = widget.device.url;

    if (stationUrl == null || stationUrl.isEmpty) {
      // Fall back to preferred station
      final preferredStation = StationService().getPreferredStation();
      stationUrl = preferredStation?.url;
    }

    if (stationUrl == null || stationUrl.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No station available to access blog')),
        );
      }
      return;
    }

    // Convert WebSocket URL to HTTP URL (wss:// -> https://, ws:// -> http://)
    final httpUrl = stationUrl
        .replaceFirst('wss://', 'https://')
        .replaceFirst('ws://', 'http://');

    // Build URL to the blog HTML page via station proxy
    final url = '$httpUrl/${widget.device.callsign}/blog/${post.id}.html';

    LogService().log('RemoteBlogBrowserPage: Opening blog post: $url');

    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open: $url')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.device.displayName} - Blog'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadPosts,
            tooltip: _i18n.t('refresh'),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.error_outline,
                        size: 64,
                        color: theme.colorScheme.error,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _i18n.t('error_loading_data'),
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Text(
                          _error!,
                          style: theme.textTheme.bodySmall,
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: _loadPosts,
                        child: Text(_i18n.t('retry')),
                      ),
                    ],
                  ),
                )
              : _posts.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.article_outlined,
                            size: 64,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'No blog posts',
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'This device has no published blog posts',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _posts.length,
                      itemBuilder: (context, index) {
                        final post = _posts[index];
                        return _buildPostCard(theme, post);
                      },
                    ),
    );
  }

  Widget _buildPostCard(ThemeData theme, BlogPost post) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: () => _openPost(post),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title
              Text(
                post.title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),

              // Author and timestamp
              Row(
                children: [
                  Icon(
                    Icons.person,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    post.author,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Icon(
                    Icons.schedule,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    post.timestamp,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),

              // Tags
              if (post.tags.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: post.tags.map((tag) {
                    return Chip(
                      label: Text(
                        tag,
                        style: theme.textTheme.bodySmall,
                      ),
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                    );
                  }).toList(),
                ),
              ],

              // Comments count
              if (post.commentCount > 0) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      Icons.comment,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${post.commentCount} ${post.commentCount == 1 ? 'comment' : 'comments'}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Blog post data model
class BlogPost {
  final String id;
  final String title;
  final String author;
  final String timestamp;
  final String status;
  final List<String> tags;
  final int commentCount;

  BlogPost({
    required this.id,
    required this.title,
    required this.author,
    required this.timestamp,
    required this.status,
    required this.tags,
    required this.commentCount,
  });

  factory BlogPost.fromJson(Map<String, dynamic> json) {
    return BlogPost(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? 'Untitled',
      author: json['author'] as String? ?? 'Unknown',
      timestamp: json['timestamp'] as String? ?? '',
      status: json['status'] as String? ?? 'draft',
      tags: (json['tags'] as List<dynamic>?)?.map((t) => t.toString()).toList() ?? [],
      commentCount: json['commentCount'] as int? ?? 0,
    );
  }
}
