/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/blog_post.dart' as models;
import '../models/blog_comment.dart';
import '../services/devices_service.dart';
import '../services/i18n_service.dart';
import '../services/log_service.dart';
import '../services/profile_service.dart';
import '../services/remote_blog_actions.dart';
import '../services/station_service.dart';
import '../services/storage_config.dart';
import '../util/feedback_folder_utils.dart';
import '../widgets/blog_post_detail_widget.dart';

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
    // Try to load full post content from cache first
    models.BlogPost? fullPost = await _loadFullPostFromCache(post.id);

    // If not in cache, try to fetch from API
    if (fullPost == null) {
      fullPost = await _loadFullPostFromApi(post.id);
    }

    if (fullPost == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not load blog post')),
        );
      }
      return;
    }

    if (!mounted) return;

    // Capture non-null value for navigation
    final loadedPost = fullPost;

    // Navigate to detail page
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => _RemoteBlogPostDetailPage(
          post: loadedPost,
          device: widget.device,
        ),
      ),
    );
  }

  /// Load full post content from cached markdown file
  Future<models.BlogPost?> _loadFullPostFromCache(String postId) async {
    try {
      final dataDir = StorageConfig().baseDir;
      final devicePath = '$dataDir/devices/${widget.device.callsign}';
      final blogPath = '$devicePath/blog';

      // Check if blog directory exists
      final blogDir = Directory(blogPath);
      if (!await blogDir.exists()) return null;

      // Blog posts are stored in blog/YYYY/postId/post.md
      await for (final yearEntity in blogDir.list()) {
        if (yearEntity is Directory) {
          final postDir = Directory('${yearEntity.path}/$postId');
          final postFile = File('${postDir.path}/post.md');

          if (await postFile.exists()) {
            final content = await postFile.readAsString();
            return models.BlogPost.fromText(content, postId);
          }
        }
      }

      return null;
    } catch (e) {
      LogService().log('RemoteBlogBrowserPage: Error loading post from cache: $e');
      return null;
    }
  }

  /// Load full post content from API
  Future<models.BlogPost?> _loadFullPostFromApi(String postId) async {
    try {
      // Fetch the post details via JSON API
      final response = await _devicesService.makeDeviceApiRequest(
        callsign: widget.device.callsign,
        method: 'GET',
        path: '/api/blog/$postId',
      );

      if (response != null && response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;

        if (data['success'] != true) {
          LogService().log('RemoteBlogBrowserPage: API returned error: ${data['error']}');
          return null;
        }

        // Convert JSON to BlogPost model
        final commentsList = <BlogComment>[];
        if (data['comments'] != null) {
          for (final c in data['comments'] as List) {
            final commentData = c as Map<String, dynamic>;
            final commentMetadata = <String, String>{};
            if (commentData['npub'] != null) commentMetadata['npub'] = commentData['npub'] as String;
            if (commentData['signature'] != null) commentMetadata['signature'] = commentData['signature'] as String;

            commentsList.add(BlogComment(
              id: commentData['id'] as String?,
              author: commentData['author'] as String? ?? 'Unknown',
              timestamp: commentData['timestamp'] as String? ?? '',
              content: commentData['content'] as String? ?? '',
              metadata: commentMetadata,
            ));
          }
        }

        // Build metadata map
        final postMetadata = <String, String>{};
        if (data['npub'] != null) postMetadata['npub'] = data['npub'] as String;
        if (data['signature'] != null) postMetadata['signature'] = data['signature'] as String;

        // Engagement counts from the server's /api/blog/{postId} —
        // this lets the detail page show likes / views / comments
        // without a second round-trip.
        int asInt(dynamic v) {
          if (v is int) return v;
          if (v is num) return v.toInt();
          return 0;
        }

        return models.BlogPost(
          id: data['id'] as String? ?? postId,
          author: data['author'] as String? ?? 'Unknown',
          timestamp: data['timestamp'] as String? ?? '',
          edited: data['edited'] as String?,
          title: data['title'] as String? ?? 'Untitled',
          description: data['description'] as String?,
          location: data['location'] as String?,
          status: models.BlogStatus.fromString(data['status'] as String? ?? 'draft'),
          tags: (data['tags'] as List?)?.map((t) => t.toString()).toList() ?? [],
          content: data['content'] as String? ?? '',
          comments: commentsList,
          metadata: postMetadata,
          likesCount: asInt(data['likes_count']),
          dislikesCount: asInt(data['dislikes_count']),
          pointsCount: asInt(data['points_count']),
          subscribeCount: asInt(data['subscribe_count']),
        );
      }

      return null;
    } catch (e) {
      LogService().log('RemoteBlogBrowserPage: Error loading post from API: $e');
      return null;
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

/// Detail page for viewing a remote blog post. Full engagement is
/// enabled — Like / Dislike / Point / Subscribe / Reactions all sign
/// a NOSTR event with the visitor's own keys and POST it to the
/// selected device via the shared ConnectionManager. Comments are
/// signed and posted the same way.
/// Public route to a single remote blog post's detail page. Lets
/// callers outside this file (e.g. the blog browser's global scope)
/// jump straight to one post without going through the listing.
class RemoteBlogPostDetailPage extends StatefulWidget {
  final models.BlogPost post;
  final RemoteDevice device;

  const RemoteBlogPostDetailPage({
    super.key,
    required this.post,
    required this.device,
  });

  @override
  State<RemoteBlogPostDetailPage> createState() =>
      _RemoteBlogPostDetailPageState();
}

// In-file alias so existing private references compile unchanged.
typedef _RemoteBlogPostDetailPage = RemoteBlogPostDetailPage;

class _RemoteBlogPostDetailPageState extends State<_RemoteBlogPostDetailPage> {
  final DevicesService _devicesService = DevicesService();
  final ProfileService _profileService = ProfileService();
  final TextEditingController _commentController = TextEditingController();

  late models.BlogPost _post;
  int _viewCount = 0;
  bool _posting = false;
  bool _viewRecorded = false;

  @override
  void initState() {
    super.initState();
    _post = widget.post;
    // Always refresh on entry so counts reflect the latest state and
    // so view tracking hits an up-to-date server.
    _refreshPost();
    _recordView();
  }

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  // ───────────────── Remote fetch / refresh ─────────────────

  Future<void> _refreshPost() async {
    try {
      final resp = await _devicesService.makeDeviceApiRequest(
        callsign: widget.device.callsign,
        method: 'GET',
        path: '/api/blog/${widget.post.id}',
      );
      if (resp == null || resp.statusCode != 200) return;
      final data = json.decode(resp.body) as Map<String, dynamic>;
      if (data['success'] != true) return;

      int asInt(dynamic v) {
        if (v is int) return v;
        if (v is num) return v.toInt();
        return 0;
      }

      final commentsList = <BlogComment>[];
      for (final c in (data['comments'] as List? ?? [])) {
        final cm = c as Map<String, dynamic>;
        final meta = <String, String>{};
        if (cm['npub'] != null) meta['npub'] = cm['npub'] as String;
        if (cm['signature'] != null) meta['signature'] = cm['signature'] as String;
        commentsList.add(BlogComment(
          id: cm['id'] as String?,
          author: cm['author'] as String? ?? 'Unknown',
          timestamp: cm['timestamp'] as String? ?? '',
          content: cm['content'] as String? ?? '',
          metadata: meta,
        ));
      }

      if (!mounted) return;
      setState(() {
        _post = _post.copyWith(
          comments: commentsList,
          likesCount: asInt(data['likes_count']),
          dislikesCount: asInt(data['dislikes_count']),
          pointsCount: asInt(data['points_count']),
          subscribeCount: asInt(data['subscribe_count']),
        );
        _viewCount = asInt(data['view_count']);
      });
    } catch (e) {
      LogService().log('RemoteBlogDetail: refresh failed: $e');
    }
  }

  // ───────────────── Local signing helpers ──────────────────

  /// Checks the user has NOSTR keys; surfaces a snackbar if not.
  bool _requireNostrKeys() {
    final profile = _profileService.getProfile();
    if (profile.npub.isEmpty || profile.nsec.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('NOSTR key required for this action')),
      );
      return false;
    }
    return true;
  }

  /// Sign + post a feedback event through the shared
  /// [RemoteBlogActions] helper — same code the debug API exercises,
  /// so unit/integration tests that drive those endpoints prove this
  /// button works end-to-end.
  Future<void> _signAndPostFeedback(String feedbackType, String actionName) async {
    if (_posting || !_requireNostrKeys()) return;
    setState(() => _posting = true);
    try {
      final r = await RemoteBlogActions.sendFeedback(
        remoteCallsign: widget.device.callsign,
        postId: _post.id,
        feedbackType: feedbackType,
        actionName: actionName,
        authorNpub: _post.metadata['npub'],
      );
      if (!r.success) {
        _toast(r.error ?? 'Action failed');
      } else {
        await _refreshPost();
      }
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  /// Sign + post a comment via [RemoteBlogActions].
  Future<void> _postComment() async {
    final text = _commentController.text.trim();
    if (text.isEmpty || _posting || !_requireNostrKeys()) return;
    setState(() => _posting = true);
    try {
      final r = await RemoteBlogActions.sendComment(
        remoteCallsign: widget.device.callsign,
        postId: _post.id,
        content: text,
      );
      if (!r.success) {
        _toast(r.error ?? 'Comment rejected');
      } else {
        _commentController.clear();
        await _refreshPost();
      }
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  /// Record a signed view event. Fails silently (no-op) if the user
  /// has no NOSTR keys; the view simply isn't counted.
  Future<void> _recordView() async {
    if (_viewRecorded) return;
    _viewRecorded = true;
    final r = await RemoteBlogActions.recordView(
      remoteCallsign: widget.device.callsign,
      postId: _post.id,
    );
    if (r.success && mounted) {
      final total = r.body?['total_views'];
      if (total is num) {
        setState(() => _viewCount = total.toInt());
      }
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  // ───────────────── UI ─────────────────

  @override
  Widget build(BuildContext context) {
    final i18n = I18nService();
    final theme = Theme.of(context);

    String? stationUrl = widget.device.url;
    if (stationUrl == null || stationUrl.isEmpty) {
      final preferredStation = StationService().getPreferredStation();
      stationUrl = preferredStation?.url;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(i18n.t('blog_post')),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: i18n.t('refresh'),
            onPressed: _refreshPost,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          BlogPostDetailWidget(
            post: _post,
            appPath: '',
            canEdit: false,
            stationUrl: stationUrl,
            profileIdentifier: widget.device.callsign,
            onLike: _posting
                ? null
                : () => _signAndPostFeedback(
                      FeedbackFolderUtils.feedbackTypeLikes, 'like'),
            onPoint: _posting
                ? null
                : () => _signAndPostFeedback(
                      FeedbackFolderUtils.feedbackTypePoints, 'point'),
            onDislike: _posting
                ? null
                : () => _signAndPostFeedback(
                      FeedbackFolderUtils.feedbackTypeDislikes, 'dislike'),
            onSubscribe: _posting
                ? null
                : () => _signAndPostFeedback(
                      FeedbackFolderUtils.feedbackTypeSubscribe, 'subscribe'),
            onReaction: _posting
                ? null
                : (emoji) => _signAndPostFeedback(emoji, 'reaction'),
          ),
          const SizedBox(height: 12),
          // Engagement summary — views / likes / comments at a glance.
          _buildEngagementSummary(theme),
          const SizedBox(height: 16),
          const Divider(),
          const SizedBox(height: 16),
          Text(
            '${i18n.t('comments')} (${_post.comments.length})',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          _buildCommentCompose(theme, i18n),
          const SizedBox(height: 16),
          if (_post.comments.isEmpty)
            Text(
              i18n.t('no_comments_yet'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
              textAlign: TextAlign.center,
            )
          else
            ..._post.comments.map((c) => _buildCommentCard(theme, c)),
        ],
      ),
    );
  }

  Widget _buildEngagementSummary(ThemeData theme) {
    final stats = <Widget>[];
    Widget chip(IconData icon, int count, String label) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(
            '$count $label${count == 1 ? '' : 's'}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      );
    }

    stats.add(chip(Icons.visibility, _viewCount, 'view'));
    stats.add(chip(Icons.thumb_up_outlined, _post.likesCount, 'like'));
    stats.add(chip(Icons.chat_bubble_outline, _post.comments.length, 'comment'));

    return Wrap(
      spacing: 16,
      runSpacing: 8,
      children: stats,
    );
  }

  Widget _buildCommentCompose(ThemeData theme, I18nService i18n) {
    final profile = _profileService.getProfile();
    final hasKeys = profile.npub.isNotEmpty && profile.nsec.isNotEmpty;
    if (!hasKeys) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.4),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(Icons.key_off,
                size: 18, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'NOSTR key required to comment',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      );
    }
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _commentController,
            enabled: !_posting,
            minLines: 1,
            maxLines: 4,
            decoration: InputDecoration(
              hintText: i18n.t('write_a_comment'),
              border: const OutlineInputBorder(),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            onSubmitted: (_) => _postComment(),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          icon: _posting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.send),
          onPressed: _posting ? null : _postComment,
          tooltip: i18n.t('post_comment'),
        ),
      ],
    );
  }

  Widget _buildCommentCard(ThemeData theme, BlogComment comment) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.person,
                    size: 16, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 4),
                Text(
                  comment.author,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 12),
                Icon(Icons.schedule,
                    size: 16, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 4),
                Text(
                  comment.timestamp,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(comment.content, style: theme.textTheme.bodyMedium),
          ],
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
