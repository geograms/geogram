/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import '../models/forum_post.dart';
import 'post_bubble_widget.dart';

/// Widget for displaying a scrollable list of forum posts
class PostListWidget extends StatefulWidget {
  final List<ForumPost> posts;
  final Function(ForumPost)? onFileOpen;
  final Function(ForumPost)? onPostDelete;
  final bool Function(ForumPost)? canDeletePost;
  final String? threadTitle;

  const PostListWidget({
    Key? key,
    required this.posts,
    this.onFileOpen,
    this.onPostDelete,
    this.canDeletePost,
    this.threadTitle,
  }) : super(key: key);

  @override
  State<PostListWidget> createState() => _PostListWidgetState();
}

class _PostListWidgetState extends State<PostListWidget> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();

    // Scroll to bottom on first load
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom(animate: false);
    });
  }

  @override
  void didUpdateWidget(PostListWidget oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Scroll to bottom when new posts arrive
    if (widget.posts.length > oldWidget.posts.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToBottom();
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// Scroll to bottom of list
  void _scrollToBottom({bool animate = true}) {
    if (!_scrollController.hasClients) return;

    if (animate) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    } else {
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        // Thread title header
        if (widget.threadTitle != null) _buildThreadHeader(theme),
        // Post list
        Expanded(
          child: widget.posts.isEmpty
              ? _buildEmptyState(theme)
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  itemCount: widget.posts.length,
                  itemBuilder: (context, index) {
                    final post = widget.posts[index];

                    return PostBubbleWidget(
                      key: ValueKey(post.timestamp + post.author),
                      post: post,
                      onFileOpen: widget.onFileOpen != null
                          ? () => widget.onFileOpen!(post)
                          : null,
                      onDelete: widget.onPostDelete != null
                          ? () => widget.onPostDelete!(post)
                          : null,
                      canDelete: widget.canDeletePost != null
                          ? widget.canDeletePost!(post)
                          : false,
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// Build thread title header
  Widget _buildThreadHeader(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceVariant.withOpacity(0.5),
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outlineVariant,
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.topic,
            color: theme.colorScheme.primary,
            size: 24,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              widget.threadTitle!,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// Build empty state widget
  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.forum_outlined,
            size: 64,
            color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5),
          ),
          const SizedBox(height: 16),
          Text(
            'No posts yet',
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Be the first to post!',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant.withOpacity(0.7),
            ),
          ),
        ],
      ),
    );
  }
}
