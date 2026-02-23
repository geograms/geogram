/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:latlong2/latlong.dart';
import '../models/blog_post.dart';
import '../services/i18n_service.dart';
import '../pages/location_picker_page.dart';

/// Widget for displaying blog post detail
class BlogPostDetailWidget extends StatelessWidget {
  final BlogPost post;
  final String appPath;
  final bool canEdit;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onPublish;
  final String? stationUrl;
  final String? profileIdentifier; // nickname or callsign for URL
  final void Function(String tag)? onTagTap; // Callback when a tag is tapped

  // Feedback callbacks
  final VoidCallback? onLike;
  final VoidCallback? onPoint;
  final VoidCallback? onDislike;
  final VoidCallback? onSubscribe;
  final void Function(String emoji)? onReaction;

  const BlogPostDetailWidget({
    Key? key,
    required this.post,
    required this.appPath,
    this.canEdit = false,
    this.onEdit,
    this.onDelete,
    this.onPublish,
    this.stationUrl,
    this.profileIdentifier,
    this.onTagTap,
    this.onLike,
    this.onPoint,
    this.onDislike,
    this.onSubscribe,
    this.onReaction,
  }) : super(key: key);

  /// Get shareable URL for this blog post
  String? get shareableUrl {
    if (stationUrl == null || profileIdentifier == null || post.isDraft) {
      return null;
    }
    // Convert ws:// or wss:// to http:// or https://
    final httpUrl = stationUrl!
        .replaceFirst('ws://', 'http://')
        .replaceFirst('wss://', 'https://');
    return '$httpUrl/$profileIdentifier/blog/${post.id}.html';
  }

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
                      // Location (clickable to view on map)
                      if (post.hasLocation)
                        InkWell(
                          onTap: () => _openLocationOnMap(context),
                          borderRadius: BorderRadius.circular(4),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.location_on,
                                  size: 16,
                                  color: theme.colorScheme.primary,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  post.location!,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: theme.colorScheme.primary,
                                    decoration: TextDecoration.underline,
                                  ),
                                ),
                              ],
                            ),
                          ),
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
              return ActionChip(
                label: Text('#$tag'),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                backgroundColor: theme.colorScheme.surfaceVariant,
                onPressed: onTagTap != null ? () => onTagTap!(tag) : null,
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
        // Feedback bar (likes, points, reactions)
        if (!post.isDraft) ...[
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 12),
          _buildFeedbackBar(context, theme),
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
        // Shareable URL (only for published posts)
        if (shareableUrl != null) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.5),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: theme.colorScheme.outline.withOpacity(0.2),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.link,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: GestureDetector(
                    onTap: () => _openUrl(context, shareableUrl!),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: Text(
                        shareableUrl!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontFamily: 'monospace',
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.open_in_browser, size: 18),
                  onPressed: () => _openUrl(context, shareableUrl!),
                  tooltip: i18n.t('open_in_browser'),
                  visualDensity: VisualDensity.compact,
                ),
                IconButton(
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: shareableUrl!));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(i18n.t('url_copied')),
                        duration: const Duration(seconds: 2),
                      ),
                    );
                  },
                  tooltip: i18n.t('copy_url'),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// Build feedback bar with likes, points, dislikes, subscribe, and emoji reactions
  Widget _buildFeedbackBar(BuildContext context, ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Primary feedback actions
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            // Like button
            _buildFeedbackButton(
              theme: theme,
              icon: Icons.thumb_up,
              label: 'Like',
              count: post.likesCount,
              isActive: post.hasLiked,
              onPressed: onLike,
              activeColor: Colors.blue,
            ),
            // Point button
            _buildFeedbackButton(
              theme: theme,
              icon: Icons.push_pin,
              label: 'Point',
              count: post.pointsCount,
              isActive: post.hasPointed,
              onPressed: onPoint,
              activeColor: Colors.orange,
            ),
            // Dislike button
            _buildFeedbackButton(
              theme: theme,
              icon: Icons.thumb_down,
              label: 'Dislike',
              count: post.dislikesCount,
              isActive: post.hasDisliked,
              onPressed: onDislike,
              activeColor: Colors.red,
            ),
            // Subscribe button
            _buildFeedbackButton(
              theme: theme,
              icon: Icons.notifications,
              label: 'Subscribe',
              count: post.subscribeCount,
              isActive: post.hasSubscribed,
              onPressed: onSubscribe,
              activeColor: Colors.green,
            ),
          ],
        ),
        // Emoji reactions
        const SizedBox(height: 12),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            _buildEmojiReactionButton(
              theme: theme,
              emoji: '👍',
              count: post.thumbsUpCount,
              isActive: post.hasThumbsUp,
              onPressed: () => onReaction?.call('thumbs-up'),
            ),
            _buildEmojiReactionButton(
              theme: theme,
              emoji: '👎',
              count: post.thumbsDownCount,
              isActive: post.hasThumbsDown,
              onPressed: () => onReaction?.call('thumbs-down'),
            ),
            _buildEmojiReactionButton(
              theme: theme,
              emoji: '❤️',
              count: post.heartCount,
              isActive: post.hasHearted,
              onPressed: () => onReaction?.call('heart'),
            ),
            _buildEmojiReactionButton(
              theme: theme,
              emoji: '🔥',
              count: post.fireCount,
              isActive: post.hasFired,
              onPressed: () => onReaction?.call('fire'),
            ),
            _buildEmojiReactionButton(
              theme: theme,
              emoji: '💯',
              count: post.hundredCount,
              isActive: post.hasHundred,
              onPressed: () => onReaction?.call('hundred'),
            ),
            _buildEmojiReactionButton(
              theme: theme,
              emoji: '🤔',
              count: post.curiousCount,
              isActive: post.hasCurious,
              onPressed: () => onReaction?.call('curious'),
            ),
            _buildEmojiReactionButton(
              theme: theme,
              emoji: '🥳',
              count: post.celebrateCount,
              isActive: post.hasCelebrated,
              onPressed: () => onReaction?.call('celebrate'),
            ),
            _buildEmojiReactionButton(
              theme: theme,
              emoji: '😂',
              count: post.laughCount,
              isActive: post.hasLaughed,
              onPressed: () => onReaction?.call('laugh'),
            ),
            _buildEmojiReactionButton(
              theme: theme,
              emoji: '😢',
              count: post.sadCount,
              isActive: post.hasSad,
              onPressed: () => onReaction?.call('sad'),
            ),
            _buildEmojiReactionButton(
              theme: theme,
              emoji: '🍻',
              count: post.beerCheersCount,
              isActive: post.hasBeerCheers,
              onPressed: () => onReaction?.call('beer-cheers'),
            ),
            _buildEmojiReactionButton(
              theme: theme,
              emoji: '😱',
              count: post.surpriseCount,
              isActive: post.hasSurprised,
              onPressed: () => onReaction?.call('surprise'),
            ),
          ],
        ),
      ],
    );
  }

  /// Build a feedback button (like, point, dislike, subscribe)
  Widget _buildFeedbackButton({
    required ThemeData theme,
    required IconData icon,
    required String label,
    required int count,
    required bool isActive,
    required VoidCallback? onPressed,
    required Color activeColor,
  }) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(
        icon,
        size: 18,
        color: isActive ? activeColor : theme.colorScheme.onSurfaceVariant,
      ),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              color: isActive ? activeColor : theme.colorScheme.onSurface,
              fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          if (count > 0) ...[
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: isActive ? activeColor.withOpacity(0.2) : theme.colorScheme.surfaceVariant,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                count.toString(),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: isActive ? activeColor : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ],
      ),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        side: BorderSide(
          color: isActive ? activeColor : theme.colorScheme.outline,
          width: isActive ? 2 : 1,
        ),
        backgroundColor: isActive ? activeColor.withOpacity(0.1) : null,
      ),
    );
  }

  /// Build an emoji reaction button
  Widget _buildEmojiReactionButton({
    required ThemeData theme,
    required String emoji,
    required int count,
    required bool isActive,
    required VoidCallback? onPressed,
  }) {
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isActive ? theme.colorScheme.primaryContainer : theme.colorScheme.surfaceVariant,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isActive ? theme.colorScheme.primary : Colors.transparent,
            width: isActive ? 2 : 0,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              emoji,
              style: const TextStyle(fontSize: 18, fontFamilyFallback: ['Noto Color Emoji', 'Apple Color Emoji', 'Segoe UI Emoji', 'sans-serif-emoji']),
            ),
            if (count > 0) ...[
              const SizedBox(width: 4),
              Text(
                count.toString(),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: isActive ? theme.colorScheme.onPrimaryContainer : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
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
    final filePath = '$appPath/blog/$year/files/$filename';
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

  /// Open the location on the map viewer
  void _openLocationOnMap(BuildContext context) {
    final lat = post.latitude;
    final lon = post.longitude;

    if (lat == null || lon == null) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => LocationPickerPage(
          initialPosition: LatLng(lat, lon),
          viewOnly: true, // View-only mode: no selection controls
        ),
      ),
    );
  }
}
