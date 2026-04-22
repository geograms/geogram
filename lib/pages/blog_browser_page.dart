/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import '../models/blog_post.dart';
import '../models/blog_comment.dart';
import '../services/blog_service.dart';
import '../services/app_service.dart';
import '../services/config_service.dart';
import '../services/devices_service.dart';
import '../services/log_service.dart';
import '../services/profile_service.dart';
import '../services/profile_storage.dart';
import '../services/remote_content_client.dart';
import '../services/station_service.dart';
import '../services/i18n_service.dart';
import '../widgets/blog_post_tile_widget.dart';
import '../widgets/blog_post_detail_widget.dart';
import '../widgets/blog_comment_widget.dart';
import '../dialogs/new_blog_post_dialog.dart';
import 'remote_blog_browser_page.dart' show RemoteBlogPostDetailPage;

/// Blog browser page with 2-panel layout
class BlogBrowserPage extends StatefulWidget {
  final String appPath;
  final String appTitle;

  const BlogBrowserPage({
    Key? key,
    required this.appPath,
    required this.appTitle,
  }) : super(key: key);

  @override
  State<BlogBrowserPage> createState() => _BlogBrowserPageState();
}

class _BlogBrowserPageState extends State<BlogBrowserPage> {
  final BlogService _blogService = BlogService();
  final ProfileService _profileService = ProfileService();
  final StationService _stationService = StationService();
  final I18nService _i18n = I18nService();
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _commentController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  List<BlogPost> _allPosts = [];
  List<BlogPost> _filteredPosts = [];
  BlogPost? _selectedPost;
  bool _isLoading = true;
  bool _showDraftsOnly = false;
  String? _stationUrl;
  String? _profileIdentifier;
  Set<int> _expandedYears = {};
  String? _currentUserNpub;
  String? _currentCallsign;

  // Same scope-toggle pattern as the events browser: show events I
  // authored vs everyone else\'s. Globe icon when viewing mine
  // (telegraphs the next-tap state); person icon when viewing
  // global. Last choice persists in ConfigService so the page
  // re-opens on the same scope.
  bool _showMineOnly = true;
  static const String _scopePrefKey = 'blogBrowser.showMineOnly';
  // Posts fetched from every reachable device when the user
  // switches to global scope. Lazy-loaded once per session unless
  // the user toggles back and forth.
  List<BlogPost> _remotePosts = const [];
  bool _isLoadingRemote = false;
  bool _remoteLoadedOnce = false;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_filterPosts);
    _initialize();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _commentController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    // Get current user npub and profile info for shareable URL
    final profile = _profileService.getProfile();
    _currentUserNpub = profile.npub;
    _currentCallsign = profile.callsign;

    // Restore the last scope choice (mine vs global). New installs
    // default to "mine" — same as the previous behaviour.
    final savedScope =
        ConfigService().get(_scopePrefKey, true) as bool? ?? true;
    _showMineOnly = savedScope;

    // Get station URL and profile identifier for shareable blog URLs
    final preferredStation = _stationService.getPreferredStation();
    final connectedStation = _stationService.getConnectedStation();
    _stationUrl = preferredStation?.url.isNotEmpty == true
        ? preferredStation!.url
        : connectedStation?.url;
    // Use nickname if available, otherwise callsign
    _profileIdentifier = profile.nickname.isNotEmpty
        ? profile.nickname
        : profile.callsign;

    // Set profile storage for encrypted storage support
    // Use ScopedProfileStorage to scope operations to the collection path
    final profileStorage = AppService().profileStorage;
    if (profileStorage != null) {
      final scopedStorage = ScopedProfileStorage.fromAbsolutePath(
        profileStorage,
        widget.appPath,
      );
      _blogService.setStorage(scopedStorage);
    } else {
      // Fallback: create filesystem storage from collection path
      _blogService.setStorage(FilesystemProfileStorage(widget.appPath));
    }

    // Initialize blog service
    await _blogService.initializeApp(
      widget.appPath,
      creatorNpub: _currentUserNpub,
    );

    await _loadPosts();

    // If the user left the page on the global scope last time,
    // fetch remote posts now so it lands populated rather than
    // empty waiting for a manual toggle.
    if (!_showMineOnly) {
      // ignore: discarded_futures
      _loadGlobalPosts();
      _filterPosts();
    }

    // Expand most recent year by default
    if (_allPosts.isNotEmpty) {
      _expandedYears.add(_allPosts.first.year);
    }
  }

  Future<void> _loadPosts() async {
    setState(() => _isLoading = true);

    final posts = await _blogService.loadPosts(
      publishedOnly: !_showDraftsOnly,
      currentUserNpub: _currentUserNpub,
    );

    setState(() {
      _allPosts = posts;
      _filteredPosts = posts;
      _isLoading = false;

      // Expand most recent year by default
      if (_allPosts.isNotEmpty && _expandedYears.isEmpty) {
        _expandedYears.add(_allPosts.first.year);
      }
    });

    _filterPosts();
  }

  void _filterPosts() {
    final query = _searchController.text.toLowerCase();
    final myNpub = _currentUserNpub;
    final myCallsign = _currentCallsign?.toUpperCase();

    bool isMine(BlogPost post) {
      if (myNpub != null && myNpub.isNotEmpty && post.npub == myNpub) {
        return true;
      }
      if (myCallsign != null && myCallsign.isNotEmpty &&
          post.author.toUpperCase() == myCallsign) {
        return true;
      }
      return false;
    }

    setState(() {
      // Scope picks which source list to draw from:
      // - mine   → local posts filtered to "authored by me"
      // - global → posts fetched from every reachable device,
      //            already filtered to "not me" at fetch time
      Iterable<BlogPost> scoped = _showMineOnly
          ? _allPosts.where(isMine)
          : _remotePosts;
      if (query.isEmpty) {
        _filteredPosts = scoped.toList();
      } else {
        _filteredPosts = scoped.where((post) {
          return post.title.toLowerCase().contains(query) ||
                 post.tags.any((tag) => tag.toLowerCase().contains(query)) ||
                 (post.description?.toLowerCase().contains(query) ?? false);
        }).toList();
      }
    });
  }

  /// Fan out a /api/content/blog query to every device the local
  /// app knows about (via DevicesService), drop anything authored
  /// by the local user, then dedupe by author npub + post id.
  /// Same universal RemoteContent.listAcrossDevices the events
  /// browser uses — only the appType + model conversion differ.
  Future<void> _loadGlobalPosts() async {
    if (_isLoadingRemote) return;
    setState(() => _isLoadingRemote = true);
    try {
      final myCallsign = _currentCallsign?.toUpperCase();
      final myNpub = _currentUserNpub;
      final callsigns = DevicesService()
          .getAllDevices()
          .map((d) => d.callsign.toUpperCase())
          .where((cs) => cs.isNotEmpty && cs != myCallsign)
          .toSet();
      if (callsigns.isEmpty) {
        if (!mounted) return;
        setState(() {
          _remotePosts = const [];
          _remoteLoadedOnce = true;
          _isLoadingRemote = false;
        });
        _filterPosts();
        return;
      }
      final items = await RemoteContent.listAcrossDevices(
        callsigns: callsigns,
        appType: 'blog',
      );
      final out = <BlogPost>[];
      final dedup = <String>{};
      for (final entry in items) {
        try {
          final post = _postFromApiJson(entry.item, entry.sourceCallsign);
          // Skip posts authored by us (a mirror of our own data
          // sitting on someone else's device).
          if (myNpub != null && myNpub.isNotEmpty && post.npub == myNpub) {
            continue;
          }
          if (myCallsign != null &&
              myCallsign.isNotEmpty &&
              post.author.toUpperCase() == myCallsign) {
            continue;
          }
          // Author npub + post id is the strongest dedupe key —
          // catches the same post served by multiple mirrors of
          // the same user.
          final key = '${post.npub ?? post.author}|${post.id}';
          if (!dedup.add(key)) continue;
          out.add(post);
        } catch (_) {}
      }
      // Sort by timestamp descending (most recent first).
      out.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      if (!mounted) return;
      setState(() {
        _remotePosts = out;
        _remoteLoadedOnce = true;
        _isLoadingRemote = false;
      });
      _filterPosts();
    } catch (e) {
      LogService().log('BlogBrowserPage: remote load failed: $e');
      if (!mounted) return;
      setState(() => _isLoadingRemote = false);
    }
  }

  /// Build a [BlogPost] from one /api/content/blog list-row dict
  /// and tag it with the source-device callsign so [_selectPost]
  /// can route taps to the remote detail page. Mirrors the
  /// converter used in remote_blog_browser_page.dart.
  BlogPost _postFromApiJson(
      Map<String, dynamic> json, String sourceCallsign) {
    final metadata = <String, String>{};
    final npub = json['npub'];
    if (npub is String && npub.isNotEmpty) metadata['npub'] = npub;
    metadata['source_callsign'] = sourceCallsign;
    return BlogPost(
      id: json['id'] as String? ?? '',
      author: json['author'] as String? ?? 'Unknown',
      timestamp: json['timestamp'] as String? ?? '',
      edited: json['edited'] as String?,
      title: json['title'] as String? ?? 'Untitled',
      description: json['description'] as String?,
      location: json['location'] as String?,
      status: BlogStatus.fromString(
          json['status'] as String? ?? 'draft'),
      tags: (json['tags'] as List?)?.map((t) => t.toString()).toList() ??
          const [],
      content: json['content'] as String? ?? '',
      comments: const [],
      metadata: metadata,
    );
  }

  /// Search for posts with the given tag
  void _searchByTag(String tag) {
    _searchController.text = tag;
    _filterPosts();
  }

  Future<void> _selectPost(BlogPost post) async {
    // Remote posts (fetched via /api/content/blog from another
    // device) carry the source callsign in metadata. Open them in
    // the remote detail page rather than trying to load them from
    // local storage.
    if (await _maybeOpenRemote(post)) return;
    // Load full post with comments and feedback
    final fullPost = await _blogService.loadFullPostWithFeedback(post.id, userNpub: _currentUserNpub);
    setState(() {
      _selectedPost = fullPost;
    });
  }

  Future<bool> _maybeOpenRemote(BlogPost post) async {
    final source = post.metadata['source_callsign'];
    if (source == null || source.isEmpty) return false;
    final device = DevicesService().getDevice(source);
    if (device == null || !mounted) return true;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => RemoteBlogPostDetailPage(
        post: post,
        device: device,
      ),
    ));
    return true;
  }

  Future<void> _selectPostMobile(BlogPost post) async {
    if (await _maybeOpenRemote(post)) return;
    // Load full post with comments and feedback
    final fullPost = await _blogService.loadFullPostWithFeedback(post.id, userNpub: _currentUserNpub);

    if (!mounted || fullPost == null) return;

    // Navigate to full-screen detail view
    final result = await Navigator.of(context).push<dynamic>(
      MaterialPageRoute(
        builder: (context) => _BlogPostDetailPage(
          post: fullPost,
          appPath: widget.appPath,
          blogService: _blogService,
          profileService: _profileService,
          i18n: _i18n,
          currentUserNpub: _currentUserNpub,
          stationUrl: _stationUrl,
          profileIdentifier: _profileIdentifier,
          onTagTap: _searchByTag,
        ),
      ),
    );

    if (!mounted) return;

    // Handle tag search result
    if (result is Map && result['searchTag'] != null) {
      _searchByTag(result['searchTag'] as String);
      return;
    }

    // Reload posts if changes were made
    if (result == true) {
      await _loadPosts();
    }
  }

  void _toggleYear(int year) {
    setState(() {
      if (_expandedYears.contains(year)) {
        _expandedYears.remove(year);
      } else {
        _expandedYears.add(year);
      }
    });
  }

  Future<void> _createNewPost() async {
    try {
      LogService().log('BlogBrowserPage: Create new post button pressed');

      // Get existing tags for autocomplete
      final existingTags = await _blogService.getAllTags();

      if (!mounted) return;

      LogService().log('BlogBrowserPage: Opening new post dialog');
      final result = await Navigator.push<Map<String, dynamic>>(
        context,
        MaterialPageRoute(
          builder: (context) => NewBlogPostDialog(existingTags: existingTags),
          fullscreenDialog: true,
        ),
      );

      if (result != null && mounted) {
        LogService().log('BlogBrowserPage: Creating post from dialog result');
        final profile = _profileService.getProfile();
        final post = await _blogService.createPost(
          author: profile.callsign,
          title: result['title'] as String,
          description: result['description'] as String?,
          content: result['content'] as String,
          tags: result['tags'] as List<String>?,
          status: result['status'] as BlogStatus,
          npub: profile.npub,
          nsec: profile.nsec,
          imagePaths: result['imagePaths'] as List<String>?,
          latitude: result['latitude'] as double?,
          longitude: result['longitude'] as double?,
        );

        if (post != null && mounted) {
          LogService().log('BlogBrowserPage: Post created successfully: ${post.title}');
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                post.isPublished ? _i18n.t('post_published') : _i18n.t('draft_saved'),
              ),
              backgroundColor: Colors.green,
            ),
          );
          await _loadPosts();
          await _selectPost(post);
        } else {
          LogService().log('BlogBrowserPage: Post creation returned null');
        }
      } else {
        LogService().log('BlogBrowserPage: Dialog cancelled or returned null');
      }
    } catch (e, stack) {
      LogService().log('BlogBrowserPage: ERROR creating post: $e');
      LogService().log('BlogBrowserPage: Stack trace: $stack');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error creating post: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _editPost() async {
    if (_selectedPost == null) return;

    final existingTags = await _blogService.getAllTags();
    if (!mounted) return;

    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (context) => BlogPostPage(
          existingTags: existingTags,
          post: _selectedPost!,
        ),
        fullscreenDialog: true,
      ),
    );

    if (result != null && mounted) {
      final success = await _blogService.updatePost(
        postId: _selectedPost!.id,
        title: result['title'] as String,
        description: result['description'] as String?,
        content: result['content'] as String,
        tags: result['tags'] as List<String>?,
        status: result['status'] as BlogStatus?,
        latitude: result['latitude'] as double?,
        longitude: result['longitude'] as double?,
        userNpub: _currentUserNpub,
      );

      if (success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('post_updated')),
            backgroundColor: Colors.green,
          ),
        );
        await _loadPosts();

        // Reload selected post with feedback
        final updatedPost = await _blogService.loadFullPostWithFeedback(_selectedPost!.id, userNpub: _currentUserNpub);
        setState(() {
          _selectedPost = updatedPost;
        });
      }
    }
  }

  Future<void> _publishDraft() async {
    if (_selectedPost == null || !_selectedPost!.isDraft) return;

    final success = await _blogService.publishPost(
      _selectedPost!.id,
      _currentUserNpub,
    );

    if (success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_i18n.t('post_published')),
          backgroundColor: Colors.green,
        ),
      );
      await _loadPosts();

      // Reload selected post with feedback
      final updatedPost = await _blogService.loadFullPostWithFeedback(_selectedPost!.id, userNpub: _currentUserNpub);
      setState(() {
        _selectedPost = updatedPost;
      });
    }
  }

  Future<void> _deletePost() async {
    if (_selectedPost == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('delete_post')),
        content: Text(_i18n.t('delete_post_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(_i18n.t('delete')),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final success = await _blogService.deletePost(
        _selectedPost!.id,
        _currentUserNpub,
      );

      if (success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('post_deleted')),
            backgroundColor: Colors.green,
          ),
        );
        setState(() {
          _selectedPost = null;
        });
        await _loadPosts();
      }
    }
  }

  Future<void> _handleFeedback(String type) async {
    if (_selectedPost == null) return;

    final profile = _profileService.getProfile();
    if (profile.npub.isEmpty || profile.nsec.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('NOSTR key required for feedback')),
      );
      return;
    }

    LogService().log('BlogBrowserPage: Feedback $type on post ${_selectedPost!.id}');

    bool? result;
    switch (type) {
      case 'like':
        result = await _blogService.toggleLike(_selectedPost!.id, profile.npub, profile.nsec);
        break;
      case 'point':
        result = await _blogService.togglePoint(_selectedPost!.id, profile.npub, profile.nsec);
        break;
      case 'dislike':
        result = await _blogService.toggleDislike(_selectedPost!.id, profile.npub, profile.nsec);
        break;
      case 'subscribe':
        result = await _blogService.toggleSubscribe(_selectedPost!.id, profile.npub, profile.nsec);
        break;
    }

    if (result != null) {
      // Reload post to get updated counts
      final updatedPost = await _blogService.loadFullPostWithFeedback(_selectedPost!.id, userNpub: profile.npub);
      if (updatedPost != null && mounted) {
        setState(() {
          _selectedPost = updatedPost;
        });
      }
    } else {
      // Signature verification failed
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Feedback failed: signature verification error')),
        );
      }
    }
  }

  Future<void> _handleReaction(String emoji) async {
    if (_selectedPost == null) return;

    final profile = _profileService.getProfile();
    if (profile.npub.isEmpty || profile.nsec.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('NOSTR key required for reactions')),
      );
      return;
    }

    LogService().log('BlogBrowserPage: Reaction $emoji on post ${_selectedPost!.id}');

    final result = await _blogService.toggleReaction(_selectedPost!.id, profile.npub, profile.nsec, emoji);

    if (result != null) {
      // Reload post to get updated counts
      final updatedPost = await _blogService.loadFullPostWithFeedback(_selectedPost!.id, userNpub: profile.npub);
      if (updatedPost != null && mounted) {
        setState(() {
          _selectedPost = updatedPost;
        });
      }
    } else {
      // Signature verification failed
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Reaction failed: signature verification error')),
        );
      }
    }
  }

  Future<void> _addComment() async{
    if (_selectedPost == null || _commentController.text.trim().isEmpty) return;

    final profile = _profileService.getProfile();

    // Require NOSTR keys for comments
    if (profile.npub.isEmpty || profile.nsec.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('NOSTR key required to add comments')),
      );
      return;
    }

    final commentId = await _blogService.addComment(
      postId: _selectedPost!.id,
      author: profile.callsign,
      content: _commentController.text.trim(),
      npub: profile.npub,
      nsec: profile.nsec,
    );

    if (commentId != null && mounted) {
      _commentController.clear();

      // Reload post with new comment and feedback
      final updatedPost = await _blogService.loadFullPostWithFeedback(_selectedPost!.id, userNpub: _currentUserNpub);
      setState(() {
        _selectedPost = updatedPost;
      });

      // Scroll to bottom to show new comment
      Future.delayed(const Duration(milliseconds: 100), () {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    } else if (mounted) {
      // Comment failed to add
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to add comment: signature verification error')),
      );
    }
  }

  Future<void> _deleteComment(String commentId) async {
    if (_selectedPost == null) return;

    final success = await _blogService.deleteComment(
      postId: _selectedPost!.id,
      commentId: commentId,
      userNpub: _currentUserNpub,
    );

    if (success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_i18n.t('comment_deleted')),
          backgroundColor: Colors.green,
        ),
      );

      // Reload post with feedback
      final updatedPost = await _blogService.loadFullPostWithFeedback(_selectedPost!.id, userNpub: _currentUserNpub);
      setState(() {
        _selectedPost = updatedPost;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isAdmin = _blogService.isAdmin(_currentUserNpub);
    final canEdit = _selectedPost != null &&
        (isAdmin || _selectedPost!.isOwnPost(_currentUserNpub));

    return Scaffold(
      appBar: AppBar(
        title: Text(_i18n.t('blog')),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createNewPost,
        icon: const Icon(Icons.add),
        label: Text(_i18n.t('create')),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(
              builder: (context, constraints) {
                // Use two-panel layout for wide screens, single panel for narrow
                final isWideScreen = constraints.maxWidth >= 600;

                if (isWideScreen) {
                  // Desktop/landscape: Two-panel layout
                  return Row(
                    children: [
                      // Left panel: Post list
                      _buildPostList(theme),
                      const VerticalDivider(width: 1),
                      // Right panel: Post detail
                      Expanded(child: _buildPostDetail(theme, canEdit)),
                    ],
                  );
                } else {
                  // Mobile/portrait: Single panel
                  // Show post list, detail opens in full screen
                  return _buildPostList(theme, isMobileView: true);
                }
              },
            ),
    );
  }

  Widget _buildPostList(ThemeData theme, {bool isMobileView = false}) {
    return Container(
      width: isMobileView ? null : 350,
      color: theme.colorScheme.surface,
      child: Column(
        children: [
          // Search bar + scope toggle (mine vs everyone). Same
          // icon convention as the events browser — globe means
          // "tap to see everyone\'s", person means "tap to go back
          // to mine". Last choice persists in ConfigService.
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: _i18n.t('search_posts_tags'),
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _searchController.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                _searchController.clear();
                                _filterPosts();
                              },
                            )
                          : null,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      filled: true,
                      contentPadding:
                          const EdgeInsets.symmetric(vertical: 8),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: _showMineOnly
                      ? (_i18n.t('blog_show_global') ??
                          'Show posts from everyone')
                      : (_i18n.t('blog_show_mine') ?? 'Show my posts'),
                  icon: _isLoadingRemote
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(_showMineOnly ? Icons.public : Icons.person),
                  onPressed: () {
                    setState(() => _showMineOnly = !_showMineOnly);
                    ConfigService().set(_scopePrefKey, _showMineOnly);
                    if (!_showMineOnly && !_remoteLoadedOnce) {
                      _loadGlobalPosts();
                    }
                    _filterPosts();
                  },
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // Post list
          Expanded(
            child: _filteredPosts.isEmpty
                ? _buildEmptyState(theme)
                : _buildYearGroupedList(theme, isMobileView: isMobileView),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    final hasQuery = _searchController.text.isNotEmpty;
    final String titleKey;
    final String subtitleKey;
    final IconData icon;
    if (hasQuery) {
      titleKey = 'no_matching_posts';
      subtitleKey = 'try_different_search_term';
      icon = Icons.article_outlined;
    } else if (!_showMineOnly) {
      titleKey = 'no_global_posts_yet';
      subtitleKey = 'no_global_posts_help';
      icon = Icons.public;
    } else {
      titleKey = 'no_blog_posts_yet';
      subtitleKey = 'create_first_post';
      icon = Icons.article_outlined;
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 64,
              color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5),
            ),
            const SizedBox(height: 16),
            Text(
              _i18n.t(titleKey),
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _i18n.t(subtitleKey),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withOpacity(0.7),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildYearGroupedList(ThemeData theme, {bool isMobileView = false}) {
    // Group posts by year
    final Map<int, List<BlogPost>> postsByYear = {};
    for (var post in _filteredPosts) {
      postsByYear.putIfAbsent(post.year, () => []).add(post);
    }

    final years = postsByYear.keys.toList()..sort((a, b) => b.compareTo(a));

    return ListView.builder(
      itemCount: years.length,
      itemBuilder: (context, index) {
        final year = years[index];
        final posts = postsByYear[year]!;
        final isExpanded = _expandedYears.contains(year);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Year header
            Material(
              color: theme.colorScheme.surfaceVariant,
              child: InkWell(
                onTap: () => _toggleYear(year),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        isExpanded
                            ? Icons.expand_more
                            : Icons.chevron_right,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        year.toString(),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '${posts.length} ${posts.length == 1 ? _i18n.t('post') : _i18n.t('posts')}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // Posts for this year
            if (isExpanded)
              ...posts.map((post) => BlogPostTileWidget(
                    post: post,
                    isSelected: _selectedPost?.id == post.id,
                    onTap: () => isMobileView
                        ? _selectPostMobile(post)
                        : _selectPost(post),
                  )),
          ],
        );
      },
    );
  }

  Widget _buildPostDetail(ThemeData theme, bool canEdit) {
    if (_selectedPost == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.article_outlined,
              size: 64,
              color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5),
            ),
            const SizedBox(height: 16),
            Text(
              _i18n.t('select_post_to_view'),
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        // Post detail
        Expanded(
          child: ListView(
            controller: _scrollController,
            padding: const EdgeInsets.all(16),
            children: [
              BlogPostDetailWidget(
                post: _selectedPost!,
                appPath: widget.appPath,
                canEdit: canEdit,
                onEdit: _editPost,
                onDelete: _deletePost,
                onPublish: _selectedPost!.isDraft ? _publishDraft : null,
                stationUrl: _stationUrl,
                profileIdentifier: _profileIdentifier,
                onTagTap: _searchByTag,
                onLike: () => _handleFeedback('like'),
                onPoint: () => _handleFeedback('point'),
                onDislike: () => _handleFeedback('dislike'),
                onSubscribe: () => _handleFeedback('subscribe'),
                onReaction: (emoji) => _handleReaction(emoji),
              ),
              const SizedBox(height: 24),
              // Comments section
              _buildCommentsSection(theme),
            ],
          ),
        ),
        // Comment input (only for published posts)
        if (_selectedPost!.isPublished) _buildCommentInput(theme),
      ],
    );
  }

  Widget _buildCommentsSection(ThemeData theme) {
    if (_selectedPost!.comments.isEmpty) {
      return Column(
        children: [
          const Divider(),
          const SizedBox(height: 16),
          Text(
            _i18n.t('no_comments_yet'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _selectedPost!.isPublished
                ? _i18n.t('be_first_to_comment')
                : _i18n.t('comments_when_published'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant.withOpacity(0.7),
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(),
        const SizedBox(height: 16),
        Text(
          '${_i18n.t('comments')} (${_selectedPost!.comments.length})',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 16),
        ..._selectedPost!.comments.map((comment) {
          final canDelete = _blogService.isAdmin(_currentUserNpub) ||
              comment.npub == _currentUserNpub;

          return BlogCommentWidget(
            comment: comment,
            canDelete: canDelete,
            onDelete: (canDelete && comment.id != null) ? () => _deleteComment(comment.id!) : null,
          );
        }),
      ],
    );
  }

  Widget _buildCommentInput(ThemeData theme) {
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outlineVariant,
            width: 1,
          ),
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _commentController,
              decoration: InputDecoration(
                hintText: _i18n.t('write_comment'),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
                filled: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
              ),
              maxLines: null,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _addComment(),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.send),
            onPressed: _addComment,
            tooltip: _i18n.t('send_comment'),
            style: IconButton.styleFrom(
              backgroundColor: theme.colorScheme.primaryContainer,
            ),
          ),
        ],
      ),
    );
  }
}

/// Full-screen blog post detail page for mobile view
class _BlogPostDetailPage extends StatefulWidget {
  final BlogPost post;
  final String appPath;
  final BlogService blogService;
  final ProfileService profileService;
  final I18nService i18n;
  final String? currentUserNpub;
  final String? stationUrl;
  final String? profileIdentifier;
  final void Function(String tag)? onTagTap;

  const _BlogPostDetailPage({
    Key? key,
    required this.post,
    required this.appPath,
    required this.blogService,
    required this.profileService,
    required this.i18n,
    required this.currentUserNpub,
    this.stationUrl,
    this.profileIdentifier,
    this.onTagTap,
  }) : super(key: key);

  @override
  State<_BlogPostDetailPage> createState() => _BlogPostDetailPageState();
}

class _BlogPostDetailPageState extends State<_BlogPostDetailPage> {
  late BlogPost _post;
  final TextEditingController _commentController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _hasChanges = false;

  @override
  void initState() {
    super.initState();
    _post = widget.post;
  }

  @override
  void dispose() {
    _commentController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _editPost() async {
    final existingTags = await widget.blogService.getAllTags();
    if (!mounted) return;

    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (context) => BlogPostPage(
          existingTags: existingTags,
          post: _post,
        ),
        fullscreenDialog: true,
      ),
    );

    if (result != null && mounted) {
      final success = await widget.blogService.updatePost(
        postId: _post.id,
        title: result['title'] as String,
        description: result['description'] as String?,
        content: result['content'] as String,
        tags: result['tags'] as List<String>?,
        status: result['status'] as BlogStatus?,
        latitude: result['latitude'] as double?,
        longitude: result['longitude'] as double?,
        userNpub: widget.currentUserNpub,
      );

      if (success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(widget.i18n.t('post_updated')),
            backgroundColor: Colors.green,
          ),
        );
        _hasChanges = true;

        // Reload post with feedback
        final updatedPost = await widget.blogService.loadFullPostWithFeedback(_post.id, userNpub: widget.currentUserNpub);
        if (updatedPost != null) {
          final post = updatedPost; // Capture non-null value
          setState(() {
            _post = post;
          });
        }
      }
    }
  }

  Future<void> _publishDraft() async {
    if (!_post.isDraft) return;

    final success = await widget.blogService.publishPost(
      _post.id,
      widget.currentUserNpub,
    );

    if (success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(widget.i18n.t('post_published')),
          backgroundColor: Colors.green,
        ),
      );
      _hasChanges = true;

      // Reload post with feedback
      final updatedPost = await widget.blogService.loadFullPostWithFeedback(_post.id, userNpub: widget.currentUserNpub);
      if (updatedPost != null) {
        final post = updatedPost; // Capture non-null value
        setState(() {
          _post = post;
        });
      }
    }
  }

  Future<void> _deletePost() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.i18n.t('delete_post')),
        content: Text(widget.i18n.t('delete_post_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(widget.i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(widget.i18n.t('delete')),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final success = await widget.blogService.deletePost(
        _post.id,
        widget.currentUserNpub,
      );

      if (success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(widget.i18n.t('post_deleted')),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context, true); // Return true to indicate changes
      }
    }
  }

  Future<void> _handleFeedback(String type) async {
    final profile = widget.profileService.getProfile();
    if (profile.npub.isEmpty || profile.nsec.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('NOSTR key required for feedback')),
      );
      return;
    }

    LogService().log('BlogPostDetailPage: Feedback $type on post ${_post.id}');

    bool? result;
    switch (type) {
      case 'like':
        result = await widget.blogService.toggleLike(_post.id, profile.npub, profile.nsec);
        break;
      case 'point':
        result = await widget.blogService.togglePoint(_post.id, profile.npub, profile.nsec);
        break;
      case 'dislike':
        result = await widget.blogService.toggleDislike(_post.id, profile.npub, profile.nsec);
        break;
      case 'subscribe':
        result = await widget.blogService.toggleSubscribe(_post.id, profile.npub, profile.nsec);
        break;
    }

    if (result != null) {
      _hasChanges = true;
      // Reload post to get updated counts
      final updatedPost = await widget.blogService.loadFullPostWithFeedback(_post.id, userNpub: profile.npub);
      if (updatedPost != null && mounted) {
        setState(() {
          _post = updatedPost;
        });
      }
    } else {
      // Signature verification failed
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Feedback failed: signature verification error')),
        );
      }
    }
  }

  Future<void> _handleReaction(String emoji) async {
    final profile = widget.profileService.getProfile();
    if (profile.npub.isEmpty || profile.nsec.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('NOSTR key required for reactions')),
      );
      return;
    }

    LogService().log('BlogPostDetailPage: Reaction $emoji on post ${_post.id}');

    final result = await widget.blogService.toggleReaction(_post.id, profile.npub, profile.nsec, emoji);

    if (result != null) {
      _hasChanges = true;
      // Reload post to get updated counts
      final updatedPost = await widget.blogService.loadFullPostWithFeedback(_post.id, userNpub: profile.npub);
      if (updatedPost != null && mounted) {
        setState(() {
          _post = updatedPost;
        });
      }
    } else {
      // Signature verification failed
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Reaction failed: signature verification error')),
        );
      }
    }
  }

  Future<void> _addComment() async {
    if (_commentController.text.trim().isEmpty) return;

    final profile = widget.profileService.getProfile();

    // Require NOSTR keys for comments
    if (profile.npub.isEmpty || profile.nsec.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('NOSTR key required to add comments')),
      );
      return;
    }

    final commentId = await widget.blogService.addComment(
      postId: _post.id,
      author: profile.callsign,
      content: _commentController.text.trim(),
      npub: profile.npub,
      nsec: profile.nsec,
    );

    if (commentId != null && mounted) {
      _commentController.clear();
      _hasChanges = true;

      // Reload post with new comment and feedback
      final updatedPost = await widget.blogService.loadFullPostWithFeedback(_post.id, userNpub: widget.currentUserNpub);
      if (updatedPost != null) {
        final post = updatedPost; // Capture non-null value
        setState(() {
          _post = post;
        });

        // Scroll to bottom to show new comment
        Future.delayed(const Duration(milliseconds: 100), () {
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              _scrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
            );
          }
        });
      }
    } else if (mounted) {
      // Comment failed to add
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to add comment: signature verification error')),
      );
    }
  }

  Future<void> _deleteComment(String commentId) async {
    final success = await widget.blogService.deleteComment(
      postId: _post.id,
      commentId: commentId,
      userNpub: widget.currentUserNpub,
    );

    if (success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(widget.i18n.t('comment_deleted')),
          backgroundColor: Colors.green,
        ),
      );
      _hasChanges = true;

      // Reload post with feedback
      final updatedPost = await widget.blogService.loadFullPostWithFeedback(_post.id, userNpub: widget.currentUserNpub);
      if (updatedPost != null) {
        final post = updatedPost; // Capture non-null value
        setState(() {
          _post = post;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isAdmin = widget.blogService.isAdmin(widget.currentUserNpub);
    final canEdit = isAdmin || _post.isOwnPost(widget.currentUserNpub);

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop && _hasChanges) {
          // Return true to indicate changes were made
          Navigator.of(context).pop(true);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.i18n.t('blog_post')),
        ),
        body: Column(
          children: [
            Expanded(
              child: ListView(
                controller: _scrollController,
                padding: const EdgeInsets.all(16),
                children: [
                  BlogPostDetailWidget(
                    post: _post,
                    appPath: widget.appPath,
                    canEdit: canEdit,
                    onEdit: _editPost,
                    onDelete: _deletePost,
                    onPublish: _post.isDraft ? _publishDraft : null,
                    stationUrl: widget.stationUrl,
                    profileIdentifier: widget.profileIdentifier,
                    onTagTap: widget.onTagTap != null ? (tag) {
                      // Pop back to the list and trigger tag search
                      Navigator.pop(context, {'searchTag': tag});
                    } : null,
                    onLike: () => _handleFeedback('like'),
                    onPoint: () => _handleFeedback('point'),
                    onDislike: () => _handleFeedback('dislike'),
                    onSubscribe: () => _handleFeedback('subscribe'),
                    onReaction: (emoji) => _handleReaction(emoji),
                  ),
                  const SizedBox(height: 24),
                  _buildCommentsSection(theme),
                ],
              ),
            ),
            if (_post.isPublished) _buildCommentInput(theme),
          ],
        ),
      ),
    );
  }

  Widget _buildCommentsSection(ThemeData theme) {
    if (_post.comments.isEmpty) {
      return Column(
        children: [
          const Divider(),
          const SizedBox(height: 16),
          Text(
            widget.i18n.t('no_comments_yet'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _post.isPublished
                ? widget.i18n.t('be_first_to_comment')
                : widget.i18n.t('comments_when_published'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant.withOpacity(0.7),
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(),
        const SizedBox(height: 16),
        Text(
          '${widget.i18n.t('comments')} (${_post.comments.length})',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 16),
        ..._post.comments.map((comment) {
          final canDelete = widget.blogService.isAdmin(widget.currentUserNpub) ||
              comment.npub == widget.currentUserNpub;

          return BlogCommentWidget(
            comment: comment,
            canDelete: canDelete,
            onDelete: (canDelete && comment.id != null) ? () => _deleteComment(comment.id!) : null,
          );
        }),
      ],
    );
  }

  Widget _buildCommentInput(ThemeData theme) {
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outlineVariant,
            width: 1,
          ),
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _commentController,
              decoration: InputDecoration(
                hintText: widget.i18n.t('write_comment'),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
                filled: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
              ),
              maxLines: null,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _addComment(),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.send),
            onPressed: _addComment,
            tooltip: widget.i18n.t('send_comment'),
            style: IconButton.styleFrom(
              backgroundColor: theme.colorScheme.primaryContainer,
            ),
          ),
        ],
      ),
    );
  }
}
