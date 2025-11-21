/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/forum_post.dart';
import '../services/profile_service.dart';

/// Widget for displaying a single forum post
class PostBubbleWidget extends StatelessWidget {
  final ForumPost post;
  final VoidCallback? onFileOpen;
  final VoidCallback? onLocationView;
  final VoidCallback? onDelete;
  final bool canDelete;

  const PostBubbleWidget({
    Key? key,
    required this.post,
    this.onFileOpen,
    this.onLocationView,
    this.onDelete,
    this.canDelete = false,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profileService = ProfileService();
    final currentCallsign = profileService.getProfile().callsign;
    final isOwnPost = post.author == currentCallsign;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: post.isOriginalPost
            ? theme.colorScheme.primaryContainer.withOpacity(0.3)
            : theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: post.isOriginalPost
              ? theme.colorScheme.primary.withOpacity(0.3)
              : theme.colorScheme.outlineVariant,
          width: post.isOriginalPost ? 2 : 1,
        ),
      ),
      child: InkWell(
        onLongPress: () => _showPostOptions(context),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Post header with author and timestamp
              _buildPostHeader(context, theme, isOwnPost),
              if (post.content.isNotEmpty) ...[
                const SizedBox(height: 12),
                // Post content
                SelectableText(
                  post.content,
                  style: theme.textTheme.bodyMedium,
                ),
              ],
              // Metadata chips
              if (post.metadata.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: _buildMetadataChips(context, theme),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Build post header with author and timestamp
  Widget _buildPostHeader(BuildContext context, ThemeData theme, bool isOwnPost) {
    return Row(
      children: [
        // Original post badge
        if (post.isOriginalPost)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withOpacity(0.2),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              'OP',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        if (post.isOriginalPost) const SizedBox(width: 8),
        // Author
        Text(
          post.author,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: isOwnPost ? theme.colorScheme.primary : null,
          ),
        ),
        const SizedBox(width: 8),
        // Timestamp
        Text(
          '${post.displayDate} ${post.displayTime}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant.withOpacity(0.7),
          ),
        ),
        const Spacer(),
        // Options menu button (moderator only)
        if (canDelete && onDelete != null)
          IconButton(
            icon: Icon(
              Icons.more_vert,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            onPressed: () => _showPostOptions(context),
            tooltip: 'Post options',
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(),
            visualDensity: VisualDensity.compact,
          ),
      ],
    );
  }

  /// Build metadata chips (file, location, etc.)
  Widget _buildMetadataChips(BuildContext context, ThemeData theme) {
    List<Widget> chips = [];

    // File attachment chip
    if (post.hasFile) {
      chips.add(
        ActionChip(
          avatar: Icon(
            Icons.attach_file,
            size: 16,
            color: theme.colorScheme.primary,
          ),
          label: Text(
            post.displayFileName ?? 'File',
            style: theme.textTheme.bodySmall,
          ),
          onPressed: onFileOpen,
          backgroundColor: theme.colorScheme.surfaceVariant,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      );
    }

    // Location chip
    if (post.hasLocation) {
      chips.add(
        ActionChip(
          avatar: Icon(
            Icons.location_on,
            size: 16,
            color: theme.colorScheme.primary,
          ),
          label: Text(
            '${post.latitude?.toStringAsFixed(4)}, ${post.longitude?.toStringAsFixed(4)}',
            style: theme.textTheme.bodySmall,
          ),
          onPressed: onLocationView,
          backgroundColor: theme.colorScheme.surfaceVariant,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      );
    }

    // Poll chip
    if (post.hasPoll) {
      chips.add(
        Chip(
          avatar: Icon(
            Icons.poll,
            size: 16,
            color: theme.colorScheme.primary,
          ),
          label: Text(
            post.pollQuestion ?? 'Poll',
            style: theme.textTheme.bodySmall,
          ),
          backgroundColor: theme.colorScheme.surfaceVariant,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      );
    }

    // Signed post indicator
    if (post.isSigned) {
      chips.add(
        Chip(
          avatar: Icon(
            Icons.verified,
            size: 16,
            color: theme.colorScheme.tertiary,
          ),
          label: Text(
            'Signed',
            style: theme.textTheme.bodySmall,
          ),
          backgroundColor: theme.colorScheme.surfaceVariant,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      );
    }

    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: chips,
    );
  }

  /// Show post options (copy, etc.)
  void _showPostOptions(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy post'),
              onTap: () {
                Clipboard.setData(ClipboardData(text: post.content));
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Post copied to clipboard'),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Post info'),
              onTap: () {
                Navigator.pop(context);
                _showPostInfo(context);
              },
            ),
            if (canDelete && onDelete != null)
              ListTile(
                leading: Icon(
                  Icons.delete,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: Text(
                  'Delete post',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _confirmDelete(context);
                },
              ),
          ],
        ),
      ),
    );
  }

  /// Confirm deletion
  void _confirmDelete(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Post'),
        content: const Text(
            'Are you sure you want to delete this post? This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              if (onDelete != null) {
                onDelete!();
              }
            },
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  /// Show detailed post information
  void _showPostInfo(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Post Information'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildInfoRow('Author', post.author),
              _buildInfoRow('Timestamp', post.timestamp),
              _buildInfoRow('Type',
                  post.isOriginalPost ? 'Original Post' : 'Reply'),
              if (post.npub != null) _buildInfoRow('npub', post.npub!),
              if (post.hasFile) _buildInfoRow('File', post.displayFileName ?? post.attachedFile!),
              if (post.hasLocation)
                _buildInfoRow('Location',
                    '${post.latitude}, ${post.longitude}'),
              if (post.hasPoll)
                _buildInfoRow('Poll', post.pollQuestion ?? ''),
              if (post.isSigned) _buildInfoRow('Signature', post.signature!),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// Build info row for dialog
  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 2),
          SelectableText(
            value,
            style: const TextStyle(fontSize: 12),
          ),
          const Divider(),
        ],
      ),
    );
  }
}
