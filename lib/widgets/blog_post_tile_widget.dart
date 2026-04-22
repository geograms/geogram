/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import '../models/blog_post.dart';
import '../services/i18n_service.dart';

/// Widget for displaying a blog post in the list
class BlogPostTileWidget extends StatelessWidget {
  final BlogPost post;
  final bool isSelected;
  final VoidCallback onTap;
  /// Pin state for this post (parent owns the storage so it can
  /// re-sort the list after toggle). When [onTogglePin] is null
  /// the pin entry is hidden from the menu.
  final bool isPinned;
  final VoidCallback? onTogglePin;
  /// Follow state for this post's author. Null hides the icon —
  /// only meaningful for posts authored by someone other than the
  /// local user (parent decides).
  final bool isFollowing;
  final VoidCallback? onToggleFollow;
  /// Publish/unpublish + delete entries appear in the overflow
  /// menu only when the parent supplies the callbacks (i.e. this
  /// is a local post the current user owns). Remote posts get
  /// just the pin entry.
  final VoidCallback? onTogglePublish;
  final VoidCallback? onDelete;

  const BlogPostTileWidget({
    Key? key,
    required this.post,
    required this.isSelected,
    required this.onTap,
    this.isPinned = false,
    this.onTogglePin,
    this.isFollowing = false,
    this.onToggleFollow,
    this.onTogglePublish,
    this.onDelete,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final i18n = I18nService();

    return Material(
      color: isSelected
          ? theme.colorScheme.primaryContainer.withOpacity(0.5)
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title and status badge
              Row(
                children: [
                  Expanded(
                    child: Text(
                      post.title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: isSelected
                            ? FontWeight.bold
                            : FontWeight.w600,
                        color: isSelected
                            ? theme.colorScheme.onPrimaryContainer
                            : null,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 4),
                  // Follow / unfollow this author. Standalone icon
                  // (only on remote posts) — separate from the
                  // overflow menu because it acts on the AUTHOR,
                  // not the post.
                  if (onToggleFollow != null)
                    SizedBox(
                      width: 32,
                      height: 32,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        iconSize: 18,
                        tooltip: isFollowing
                            ? (i18n.t('unfollow_author') ??
                                'Unfollow this author')
                            : (i18n.t('follow_author') ??
                                'Follow this author'),
                        icon: Icon(
                          isFollowing
                              ? Icons.bookmark
                              : Icons.bookmark_outline,
                          color: isFollowing
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                        onPressed: onToggleFollow,
                      ),
                    ),
                  // Overflow menu: pin/unpin + (for local-author
                  // posts) publish/unpublish + delete. Hidden when
                  // none of the three callbacks are wired.
                  if (onTogglePin != null ||
                      onTogglePublish != null ||
                      onDelete != null)
                    _buildOverflowMenu(context, theme, i18n),
                  const SizedBox(width: 4),
                  // Draft badge
                  if (post.isDraft)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        i18n.t('draft'),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSecondaryContainer,
                          fontSize: 10,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              // Author and date
              Row(
                children: [
                  Icon(
                    Icons.person_outline,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    post.author,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.calendar_today,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    post.displayDate,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              // Description
              if (post.description != null && post.description!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  post.description!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant.withOpacity(0.8),
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              // Tags
              if (post.tags.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: post.tags.take(3).map((tag) {
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceVariant,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '#$tag',
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontSize: 10,
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
              // Comment count
              if (post.commentCount > 0) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(
                      Icons.comment_outlined,
                      size: 14,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${post.commentCount} ${post.commentCount == 1 ? i18n.t('comment') : i18n.t('comments_plural')}',
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

  Widget _buildOverflowMenu(
      BuildContext context, ThemeData theme, I18nService i18n) {
    final isPublished = post.status == BlogStatus.published;
    return SizedBox(
      width: 32,
      height: 32,
      child: PopupMenuButton<String>(
        padding: EdgeInsets.zero,
        iconSize: 20,
        tooltip: i18n.t('more_options') ?? 'More options',
        icon: Icon(
          Icons.more_vert,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        onSelected: (value) {
          switch (value) {
            case 'pin':
              onTogglePin?.call();
              break;
            case 'toggle_publish':
              onTogglePublish?.call();
              break;
            case 'delete':
              onDelete?.call();
              break;
          }
        },
        itemBuilder: (context) {
          final entries = <PopupMenuEntry<String>>[];
          if (onTogglePin != null) {
            entries.add(PopupMenuItem<String>(
              value: 'pin',
              child: Row(
                children: [
                  Icon(
                    isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                    size: 18,
                    color: isPinned
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurface,
                  ),
                  const SizedBox(width: 8),
                  Text(isPinned ? i18n.t('unpin') : i18n.t('pin')),
                ],
              ),
            ));
          }
          if (onTogglePublish != null) {
            entries.add(PopupMenuItem<String>(
              value: 'toggle_publish',
              child: Row(
                children: [
                  Icon(
                    isPublished
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: 18,
                    color: theme.colorScheme.onSurface,
                  ),
                  const SizedBox(width: 8),
                  Text(isPublished
                      ? (i18n.t('unpublish') ?? 'Unpublish')
                      : (i18n.t('publish') ?? 'Publish')),
                ],
              ),
            ));
          }
          if (onDelete != null) {
            if (entries.isNotEmpty) {
              entries.add(const PopupMenuDivider());
            }
            entries.add(PopupMenuItem<String>(
              value: 'delete',
              child: Row(
                children: [
                  Icon(
                    Icons.delete_outline,
                    size: 18,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    i18n.t('delete'),
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ],
              ),
            ));
          }
          return entries;
        },
      ),
    );
  }
}
