/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/blog_comment.dart';
import '../services/i18n_service.dart';

/// Widget for displaying a single blog comment
class BlogCommentWidget extends StatelessWidget {
  final BlogComment comment;
  final bool canDelete;
  final VoidCallback? onDelete;

  const BlogCommentWidget({
    Key? key,
    required this.comment,
    this.canDelete = false,
    this.onDelete,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final i18n = I18nService();

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.outlineVariant,
          width: 1,
        ),
      ),
      child: InkWell(
        onLongPress: () => _showCommentOptions(context),
        borderRadius: BorderRadius.circular(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header with author and timestamp
            Row(
              children: [
                // Author
                Text(
                  comment.author,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 8),
                // Timestamp
                Text(
                  '${comment.displayDate} ${comment.displayTime}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant.withOpacity(0.7),
                  ),
                ),
                const Spacer(),
                // Options menu button
                if (canDelete && onDelete != null)
                  IconButton(
                    icon: Icon(
                      Icons.more_vert,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    onPressed: () => _showCommentOptions(context),
                    tooltip: i18n.t('comment_options'),
                    padding: const EdgeInsets.all(4),
                    constraints: const BoxConstraints(),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            // Content
            SelectableText(
              comment.content,
              style: theme.textTheme.bodyMedium,
            ),
            // Signed indicator
            if (comment.isSigned) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    Icons.verified,
                    size: 14,
                    color: theme.colorScheme.tertiary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    i18n.t('signed'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.tertiary,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Show comment options (copy, delete)
  void _showCommentOptions(BuildContext context) {
    final i18n = I18nService();
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy),
              title: Text(i18n.t('copy_comment')),
              onTap: () {
                Clipboard.setData(ClipboardData(text: comment.content));
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(i18n.t('comment_copied')),
                    duration: const Duration(seconds: 2),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(i18n.t('comment_info')),
              onTap: () {
                Navigator.pop(context);
                _showCommentInfo(context);
              },
            ),
            if (canDelete && onDelete != null)
              ListTile(
                leading: Icon(
                  Icons.delete,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: Text(
                  i18n.t('delete_comment'),
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
    final i18n = I18nService();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(i18n.t('delete_comment_title')),
        content: Text(i18n.t('delete_comment_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(i18n.t('cancel')),
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
            child: Text(i18n.t('delete')),
          ),
        ],
      ),
    );
  }

  /// Show detailed comment information
  void _showCommentInfo(BuildContext context) {
    final i18n = I18nService();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(i18n.t('comment_information')),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildInfoRow(i18n.t('author'), comment.author),
              _buildInfoRow(i18n.t('timestamp'), comment.timestamp),
              if (comment.npub != null) _buildInfoRow(i18n.t('npub'), comment.npub!),
              if (comment.isSigned)
                _buildInfoRow(i18n.t('signature'), comment.signature!),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(i18n.t('close')),
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
