/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import '../models/blog_post.dart';
import '../models/blog_comment.dart';
import '../services/blog_service.dart';
import '../services/profile_service.dart';
import '../services/i18n_service.dart';
import '../widgets/blog_post_tile_widget.dart';
import '../widgets/blog_post_detail_widget.dart';
import '../widgets/blog_comment_widget.dart';
import '../dialogs/new_blog_post_dialog.dart';
import '../dialogs/edit_blog_post_dialog.dart';

/// Blog browser page with 2-panel layout
class BlogBrowserPage extends StatefulWidget {
  final String collectionPath;
  final String collectionTitle;

  const BlogBrowserPage({
    Key? key,
    required this.collectionPath,
    required this.collectionTitle,
  }) : super(key: key);

  @override
  State<BlogBrowserPage> createState() => _BlogBrowserPageState();
}

class _BlogBrowserPageState extends State<BlogBrowserPage> {
  final BlogService _blogService = BlogService();
  final ProfileService _profileService = ProfileService();
  final I18nService _i18n = I18nService();
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _commentController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  List<BlogPost> _allPosts = [];
  List<BlogPost> _filteredPosts = [];
  BlogPost? _selectedPost;
  bool _isLoading = true;
  bool _showDraftsOnly = false;
  Set<int> _expandedYears = {};
  String? _currentUserNpub;

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
    // Get current user npub
    final profile = _profileService.getProfile();
    _currentUserNpub = profile.npub;

    // Initialize blog service
    await _blogService.initializeCollection(
      widget.collectionPath,
      creatorNpub: _currentUserNpub,
    );

    await _loadPosts();

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

    setState(() {
      if (query.isEmpty) {
        _filteredPosts = _allPosts;
      } else {
        _filteredPosts = _allPosts.where((post) {
          return post.title.toLowerCase().contains(query) ||
                 post.tags.any((tag) => tag.toLowerCase().contains(query)) ||
                 (post.description?.toLowerCase().contains(query) ?? false);
        }).toList();
      }
    });
  }

  Future<void> _selectPost(BlogPost post) async {
    // Load full post with comments
    final fullPost = await _blogService.loadFullPost(post.id);
    setState(() {
      _selectedPost = fullPost;
    });
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
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => const NewBlogPostDialog(),
    );

    if (result != null && mounted) {
      final profile = _profileService.getProfile();
      final post = await _blogService.createPost(
        author: profile.callsign,
        title: result['title'] as String,
        description: result['description'] as String?,
        content: result['content'] as String,
        tags: result['tags'] as List<String>?,
        status: result['status'] as BlogStatus,
        npub: profile.npub,
      );

      if (post != null && mounted) {
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
      }
    }
  }

  Future<void> _editPost() async {
    if (_selectedPost == null) return;

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => EditBlogPostDialog(post: _selectedPost!),
    );

    if (result != null && mounted) {
      final success = await _blogService.updatePost(
        postId: _selectedPost!.id,
        title: result['title'] as String,
        description: result['description'] as String?,
        content: result['content'] as String,
        tags: result['tags'] as List<String>?,
        status: result['status'] as BlogStatus?,
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

        // Reload selected post
        final updatedPost = await _blogService.loadFullPost(_selectedPost!.id);
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

      // Reload selected post
      final updatedPost = await _blogService.loadFullPost(_selectedPost!.id);
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

  Future<void> _addComment() async{
    if (_selectedPost == null || _commentController.text.trim().isEmpty) return;

    final profile = _profileService.getProfile();
    final success = await _blogService.addComment(
      postId: _selectedPost!.id,
      author: profile.callsign,
      content: _commentController.text.trim(),
      npub: profile.npub,
    );

    if (success && mounted) {
      _commentController.clear();

      // Reload post with new comment
      final updatedPost = await _blogService.loadFullPost(_selectedPost!.id);
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
    }
  }

  Future<void> _deleteComment(int commentIndex) async {
    if (_selectedPost == null) return;

    final success = await _blogService.deleteComment(
      postId: _selectedPost!.id,
      commentIndex: commentIndex,
      userNpub: _currentUserNpub,
    );

    if (success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_i18n.t('comment_deleted')),
          backgroundColor: Colors.green,
        ),
      );

      // Reload post
      final updatedPost = await _blogService.loadFullPost(_selectedPost!.id);
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
        actions: [
          // Show drafts toggle
          IconButton(
            icon: Icon(
              _showDraftsOnly ? Icons.visibility_off : Icons.visibility,
              color: _showDraftsOnly ? theme.colorScheme.primary : null,
            ),
            onPressed: () {
              setState(() {
                _showDraftsOnly = !_showDraftsOnly;
              });
              _loadPosts();
            },
            tooltip: _showDraftsOnly ? _i18n.t('show_all_posts') : _i18n.t('show_only_drafts'),
          ),
          // Refresh
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadPosts,
            tooltip: _i18n.t('refresh'),
          ),
          // New post
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _createNewPost,
            tooltip: _i18n.t('new_post'),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Row(
              children: [
                // Left panel: Post list
                _buildPostList(theme),
                const VerticalDivider(width: 1),
                // Right panel: Post detail
                Expanded(child: _buildPostDetail(theme, canEdit)),
              ],
            ),
    );
  }

  Widget _buildPostList(ThemeData theme) {
    return Container(
      width: 350,
      color: theme.colorScheme.surface,
      child: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.all(16),
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
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ),
          const Divider(height: 1),
          // Post list
          Expanded(
            child: _filteredPosts.isEmpty
                ? _buildEmptyState(theme)
                : _buildYearGroupedList(theme),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
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
              _searchController.text.isNotEmpty
                  ? _i18n.t('no_matching_posts')
                  : _i18n.t('no_blog_posts_yet'),
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _searchController.text.isNotEmpty
                  ? _i18n.t('try_different_search_term')
                  : _i18n.t('create_first_post'),
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

  Widget _buildYearGroupedList(ThemeData theme) {
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
                    onTap: () => _selectPost(post),
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
                collectionPath: widget.collectionPath,
                canEdit: canEdit,
                onEdit: _editPost,
                onDelete: _deletePost,
                onPublish: _selectedPost!.isDraft ? _publishDraft : null,
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
        ..._selectedPost!.comments.asMap().entries.map((entry) {
          final index = entry.key;
          final comment = entry.value;
          final canDelete = _blogService.isAdmin(_currentUserNpub) ||
              comment.npub == _currentUserNpub;

          return BlogCommentWidget(
            comment: comment,
            canDelete: canDelete,
            onDelete: canDelete ? () => _deleteComment(index) : null,
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
