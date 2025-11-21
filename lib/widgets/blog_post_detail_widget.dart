/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../models/blog_post.dart';
import '../services/i18n_service.dart';

/// Widget for displaying blog post detail
class BlogPostDetailWidget extends StatelessWidget {
  final BlogPost post;
  final String collectionPath;
  final bool canEdit;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onPublish;

  const BlogPostDetailWidget({
    Key? key,
    required this.post,
    required this.collectionPath,
    this.canEdit = false,
    this.onEdit,
    this.onDelete,
    this.onPublish,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final i18n = I18nService();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header with title and actions
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Title
                  Text(
                    post.title,
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Author, date, status
                  Wrap(
                    spacing: 12,
                    runSpacing: 4,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.person,
                            size: 16,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            post.author,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.calendar_today,
                            size: 16,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '${post.displayDate} ${post.displayTime}',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      // Status badge
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: post.isDraft
                              ? theme.colorScheme.secondaryContainer
                              : theme.colorScheme.tertiaryContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          post.isDraft ? i18n.t('draft') : i18n.t('published'),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: post.isDraft
                                ? theme.colorScheme.onSecondaryContainer
                                : theme.colorScheme.onTertiaryContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // Action buttons
            if (canEdit) ...[
              if (onPublish != null && post.isDraft)
                FilledButton.icon(
                  onPressed: onPublish,
                  icon: const Icon(Icons.publish, size: 18),
                  label: Text(i18n.t('publish')),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.edit),
                onPressed: onEdit,
                tooltip: i18n.t('edit_post'),
              ),
              IconButton(
                icon: const Icon(Icons.delete),
                onPressed: onDelete,
                tooltip: i18n.t('delete_post_action'),
                color: theme.colorScheme.error,
              ),
            ],
          ],
        ),
        const SizedBox(height: 16),
        // Description
        if (post.description != null && post.description!.isNotEmpty) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceVariant.withOpacity(0.5),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              post.description!,
              style: theme.textTheme.bodyLarge?.copyWith(
                fontStyle: FontStyle.italic,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        // Tags
        if (post.tags.isNotEmpty) ...[
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: post.tags.map((tag) {
              return Chip(
                label: Text('#$tag'),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                backgroundColor: theme.colorScheme.surfaceVariant,
              );
            }).toList(),
          ),
          const SizedBox(height: 16),
        ],
        const Divider(),
        const SizedBox(height: 16),
        // Content with markdown formatting
        MarkdownBody(
          data: post.content,
          selectable: true,
          styleSheet: MarkdownStyleSheet(
            p: theme.textTheme.bodyLarge?.copyWith(height: 1.6),
            h1: theme.textTheme.headlineLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
            h2: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
            h3: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
            strong: theme.textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.bold,
              height: 1.6,
            ),
            em: theme.textTheme.bodyLarge?.copyWith(
              fontStyle: FontStyle.italic,
              height: 1.6,
            ),
            listBullet: theme.textTheme.bodyLarge?.copyWith(height: 1.6),
            a: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.primary,
              decoration: TextDecoration.underline,
              height: 1.6,
            ),
            code: theme.textTheme.bodyMedium?.copyWith(
              fontFamily: 'monospace',
              backgroundColor: theme.colorScheme.surfaceVariant,
            ),
          ),
          onTapLink: (text, href, title) {
            if (href != null) {
              _openUrl(context, href);
            }
          },
        ),
        // Metadata (files, images, URLs)
        if (post.metadata.isNotEmpty) ...[
          const SizedBox(height: 16),
          _buildMetadataChips(context, theme),
        ],
        // Signature indicator
        if (post.isSigned) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(
                Icons.verified,
                size: 16,
                color: theme.colorScheme.tertiary,
              ),
              const SizedBox(width: 4),
              Text(
                i18n.t('signed_with_nostr'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.tertiary,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildMetadataChips(BuildContext context, ThemeData theme) {
    final i18n = I18nService();
    List<Widget> chips = [];

    // File attachment
    if (post.hasFile) {
      chips.add(
        ActionChip(
          avatar: Icon(
            Icons.attach_file,
            size: 16,
            color: theme.colorScheme.primary,
          ),
          label: Text(
            post.displayFileName ?? i18n.t('file'),
            style: theme.textTheme.bodySmall,
          ),
          onPressed: () => _openFile(context, post.attachedFile!),
          backgroundColor: theme.colorScheme.surfaceVariant,
        ),
      );
    }

    // Image attachment
    if (post.hasImage) {
      chips.add(
        ActionChip(
          avatar: Icon(
            Icons.image,
            size: 16,
            color: theme.colorScheme.primary,
          ),
          label: Text(
            post.displayImageName ?? i18n.t('image'),
            style: theme.textTheme.bodySmall,
          ),
          onPressed: () => _openFile(context, post.imageFile!),
          backgroundColor: theme.colorScheme.surfaceVariant,
        ),
      );
    }

    // URL
    if (post.hasUrl) {
      chips.add(
        ActionChip(
          avatar: Icon(
            Icons.link,
            size: 16,
            color: theme.colorScheme.primary,
          ),
          label: Text(
            post.url!.length > 30
                ? '${post.url!.substring(0, 30)}...'
                : post.url!,
            style: theme.textTheme.bodySmall,
          ),
          onPressed: () => _openUrl(context, post.url!),
          backgroundColor: theme.colorScheme.surfaceVariant,
        ),
      );
    }

    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: chips,
    );
  }

  Future<void> _openFile(BuildContext context, String filename) async {
    final i18n = I18nService();
    final year = post.year;
    final filePath = '$collectionPath/blog/$year/files/$filename';
    final file = File(filePath);

    if (!await file.exists()) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(i18n.t('file_not_found')),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    try {
      final uri = Uri.file(filePath);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      } else {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(i18n.t('cannot_open_file_type')),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(i18n.t('error_opening_file', params: [e.toString()])),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _openUrl(BuildContext context, String urlString) async {
    final i18n = I18nService();
    try {
      final uri = Uri.parse(urlString);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(i18n.t('cannot_open_url')),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(i18n.t('invalid_url', params: [e.toString()])),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}
