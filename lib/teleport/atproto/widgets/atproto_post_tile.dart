/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../atproto_link_parser.dart';
import '../models/atproto_feed_item.dart';

class AtprotoPostTile extends StatefulWidget {
  final AtprotoFeedItem item;
  final VoidCallback? onLike;
  final VoidCallback? onRepost;
  final VoidCallback? onReply;
  final VoidCallback? onOpenThread;
  final VoidCallback? onTapAuthor;
  final ValueChanged<String>? onOpenProfileActor;
  final ValueChanged<String>? onOpenPostUri;
  final bool compact;

  const AtprotoPostTile({
    super.key,
    required this.item,
    this.onLike,
    this.onRepost,
    this.onReply,
    this.onOpenThread,
    this.onTapAuthor,
    this.onOpenProfileActor,
    this.onOpenPostUri,
    this.compact = false,
  });

  @override
  State<AtprotoPostTile> createState() => _AtprotoPostTileState();
}

class _AtprotoPostTileState extends State<AtprotoPostTile> {
  static final RegExp _tokenRegex = RegExp(
    r'(https?://[^\s]+|www\.[^\s]+|@[A-Za-z0-9_](?:[A-Za-z0-9_.-]*[A-Za-z0-9_])?)',
    caseSensitive: false,
  );
  final List<TapGestureRecognizer> _recognizers = [];
  int _imagePage = 0;

  @override
  void dispose() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant AtprotoPostTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.uri != widget.item.uri) {
      _imagePage = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(14, widget.compact ? 10 : 12, 14, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _withCursor(
              onTap: item.avatarUrl?.isNotEmpty == true
                  ? () => _openImagePreviewFromUrl(item.avatarUrl!)
                  : null,
              child: GestureDetector(
                onTap: item.avatarUrl?.isNotEmpty == true
                    ? () => _openImagePreviewFromUrl(item.avatarUrl!)
                    : null,
                child: MouseRegion(
                  cursor: item.avatarUrl?.isNotEmpty == true
                      ? SystemMouseCursors.click
                      : MouseCursor.defer,
                  child: CircleAvatar(
                    radius: widget.compact ? 18 : 21,
                    backgroundImage: item.avatarUrl != null
                        ? NetworkImage(item.avatarUrl!)
                        : null,
                    child: item.avatarUrl == null
                        ? Text(
                            _initial(item),
                            style: const TextStyle(fontSize: 13),
                          )
                        : null,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHeader(theme, item),
                  const SizedBox(height: 6),
                  _buildBody(theme, item),
                  if (_imageCount(item) > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: _buildImageGallery(theme, item),
                    ),
                  if (item.externalUrl != null && item.externalUrl!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: _buildExternalPreview(theme, item),
                    ),
                  if (item.externalUrl == null && item.links.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: _buildLinkList(theme, item.links),
                    ),
                  const SizedBox(height: 8),
                  _buildActionBar(theme, item),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, AtprotoFeedItem item) {
    return Row(
      children: [
        Expanded(
          child: _withCursor(
            onTap: widget.onTapAuthor,
            child: GestureDetector(
              onTap: widget.onTapAuthor,
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      item.displayName.isNotEmpty
                          ? item.displayName
                          : item.authorHandle,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      '@${item.authorHandle}',
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          _formatRelative(item.createdAt),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildBody(ThemeData theme, AtprotoFeedItem item) {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
    final spans = <InlineSpan>[];
    final text = item.text;
    var cursor = 0;

    for (final match in _tokenRegex.allMatches(text)) {
      if (match.start > cursor) {
        spans.add(
          TextSpan(
            text: text.substring(cursor, match.start),
            style: theme.textTheme.bodyMedium,
          ),
        );
      }
      final raw = match.group(0)!;
      final recognizer = TapGestureRecognizer()
        ..onTap = () {
          if (raw.startsWith('@')) {
            _openMention(raw);
            return;
          }
          final url = raw.startsWith('http') ? raw : 'https://$raw';
          _openLink(url);
        };
      _recognizers.add(recognizer);
      spans.add(
        TextSpan(
          text: raw,
          recognizer: recognizer,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.primary,
            decoration: TextDecoration.underline,
            decorationColor: theme.colorScheme.primary.withValues(alpha: 0.6),
          ),
        ),
      );
      cursor = match.end;
    }

    if (cursor < text.length) {
      spans.add(
        TextSpan(
          text: text.substring(cursor),
          style: theme.textTheme.bodyMedium,
        ),
      );
    }

    if (spans.isEmpty) {
      spans.add(TextSpan(text: text, style: theme.textTheme.bodyMedium));
    }

    final content = Text.rich(TextSpan(children: spans));
    if (widget.onOpenThread == null) return content;
    return _withCursor(
      onTap: widget.onOpenThread,
      child: GestureDetector(onTap: widget.onOpenThread, child: content),
    );
  }

  Widget _buildExternalPreview(ThemeData theme, AtprotoFeedItem item) {
    final uri = Uri.tryParse(item.externalUrl!);
    final host = uri?.host.isNotEmpty == true ? uri!.host : item.externalUrl!;
    return InkWell(
      onTap: () => _openLink(item.externalUrl!),
      mouseCursor: SystemMouseCursors.click,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: theme.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(14),
          color: theme.colorScheme.surfaceContainerLowest,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (item.externalThumbUrl != null &&
                item.externalThumbUrl!.isNotEmpty)
              ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(13),
                ),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Image.network(
                    item.externalThumbUrl!,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) => Container(
                      color: theme.colorScheme.surfaceContainer,
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.image_not_supported,
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    host,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    item.externalTitle?.trim().isNotEmpty == true
                        ? item.externalTitle!
                        : item.externalUrl!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (item.externalDescription?.trim().isNotEmpty == true) ...[
                    const SizedBox(height: 2),
                    Text(
                      item.externalDescription!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImageGallery(ThemeData theme, AtprotoFeedItem item) {
    final count = _imageCount(item);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            height: 220,
            child: PageView.builder(
              itemCount: count,
              onPageChanged: (index) => setState(() => _imagePage = index),
              itemBuilder: (context, index) {
                final thumb = _imageThumb(item, index);
                final full = _imageFull(item, index);
                final alt = _imageAlt(item, index);
                return Material(
                  color: theme.colorScheme.surfaceContainerLowest,
                  child: InkWell(
                    onTap: () => _openImagePreview(item, initialIndex: index),
                    mouseCursor: SystemMouseCursors.click,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (thumb != null)
                          Image.network(
                            thumb,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) {
                              if (full != null && full != thumb) {
                                return Image.network(
                                  full,
                                  fit: BoxFit.cover,
                                  errorBuilder: (context, error, stackTrace) =>
                                      _imageFallback(theme),
                                );
                              }
                              return _imageFallback(theme);
                            },
                          )
                        else if (full != null)
                          Image.network(
                            full,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) =>
                                _imageFallback(theme),
                          )
                        else
                          _imageFallback(theme),
                        if (alt != null && alt.isNotEmpty)
                          Positioned(
                            left: 8,
                            right: 8,
                            bottom: 8,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.55),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                alt,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        if (count > 1) ...[
          const SizedBox(height: 6),
          Row(
            children: List.generate(count, (index) {
              final active = index == _imagePage;
              return Container(
                width: active ? 14 : 7,
                height: 7,
                margin: const EdgeInsets.only(right: 5),
                decoration: BoxDecoration(
                  color: active
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(7),
                ),
              );
            }),
          ),
        ],
      ],
    );
  }

  Widget _imageFallback(ThemeData theme) {
    return Container(
      color: theme.colorScheme.surfaceContainer,
      alignment: Alignment.center,
      child: Icon(Icons.image, color: theme.colorScheme.outline, size: 28),
    );
  }

  Widget _buildLinkList(ThemeData theme, List<String> links) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: links.take(3).map((link) {
        final display = link.length > 46 ? '${link.substring(0, 46)}...' : link;
        return ActionChip(
          avatar: const Icon(Icons.link, size: 14),
          label: Text(display, overflow: TextOverflow.ellipsis),
          onPressed: () => _openLink(link),
          mouseCursor: SystemMouseCursors.click,
          side: BorderSide(color: theme.colorScheme.outlineVariant),
          backgroundColor: theme.colorScheme.surfaceContainerLowest,
        );
      }).toList(),
    );
  }

  Widget _buildActionBar(ThemeData theme, AtprotoFeedItem item) {
    return Row(
      children: [
        _actionButton(
          icon: Icons.chat_bubble_outline,
          activeIcon: Icons.chat_bubble,
          active: false,
          count: item.replyCount,
          tooltip: 'Replies',
          onTap: widget.onOpenThread ?? widget.onReply,
          activeColor: theme.colorScheme.primary,
        ),
        if (widget.onReply != null) ...[
          const SizedBox(width: 12),
          _iconButton(
            icon: Icons.reply,
            tooltip: 'Write reply',
            onTap: widget.onReply,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ],
        const SizedBox(width: 12),
        _actionButton(
          icon: Icons.repeat,
          activeIcon: Icons.repeat,
          active: item.isRepostedByMe,
          count: item.repostCount,
          tooltip: 'Repost',
          onTap: widget.onRepost,
          activeColor: Colors.green.shade600,
        ),
        const SizedBox(width: 12),
        _actionButton(
          icon: Icons.favorite_border,
          activeIcon: Icons.favorite,
          active: item.isLikedByMe,
          count: item.likeCount,
          tooltip: 'Like',
          onTap: widget.onLike,
          activeColor: Colors.red.shade500,
        ),
        const SizedBox(width: 12),
        _iconButton(
          icon: Icons.copy,
          tooltip: 'Copy text',
          onTap: () => _copyPostText(item.text),
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ],
    );
  }

  Widget _actionButton({
    required IconData icon,
    required IconData activeIcon,
    required bool active,
    required int count,
    required String tooltip,
    required VoidCallback? onTap,
    required Color activeColor,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      mouseCursor: onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
      child: Tooltip(
        message: tooltip,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                active ? activeIcon : icon,
                size: 18,
                color: active
                    ? activeColor
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Text(
                '$count',
                style: TextStyle(
                  color: active
                      ? activeColor
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _iconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onTap,
    required Color color,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      mouseCursor: onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
      child: Tooltip(
        message: tooltip,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
          child: Icon(icon, size: 18, color: color),
        ),
      ),
    );
  }

  String _formatRelative(DateTime timestampUtc) {
    final now = DateTime.now().toUtc();
    final diff = now.difference(timestampUtc);
    if (diff.inSeconds < 60) return '${diff.inSeconds}s';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    final local = timestampUtc.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    return '$month/$day';
  }

  String _initial(AtprotoFeedItem item) {
    final source = item.displayName.trim().isNotEmpty
        ? item.displayName.trim()
        : item.authorHandle.trim();
    if (source.isEmpty) return '?';
    return source.substring(0, 1).toUpperCase();
  }

  Future<void> _openLink(String raw) async {
    final internal = AtprotoLinkParser.parse(raw);
    if (internal.postUri != null && widget.onOpenPostUri != null) {
      widget.onOpenPostUri!(internal.postUri!);
      return;
    }
    if (internal.profileActor != null && widget.onOpenProfileActor != null) {
      widget.onOpenProfileActor!(internal.profileActor!);
      return;
    }
    final normalized = raw.startsWith('www.') ? 'https://$raw' : raw;
    final uri = Uri.tryParse(normalized);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  void _openMention(String raw) {
    final mention = raw.trim();
    if (mention.length <= 1) return;
    final handle = mention.substring(1);
    final actor = handle.contains('.') ? handle : '$handle.bsky.social';
    if (widget.onOpenProfileActor != null) {
      widget.onOpenProfileActor!(actor);
      return;
    }
    _openLink('https://bsky.app/profile/$actor');
  }

  Future<void> _copyPostText(String text) async {
    final value = text.trim();
    if (value.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Post text copied')));
  }

  Widget _withCursor({required Widget child, VoidCallback? onTap}) {
    if (onTap == null) return child;
    return MouseRegion(cursor: SystemMouseCursors.click, child: child);
  }

  int _imageCount(AtprotoFeedItem item) {
    final thumbCount = item.imageThumbUrls.length;
    final fullCount = item.imageFullUrls.length;
    return thumbCount > fullCount ? thumbCount : fullCount;
  }

  String? _imageThumb(AtprotoFeedItem item, int index) {
    if (index >= 0 && index < item.imageThumbUrls.length) {
      return item.imageThumbUrls[index];
    }
    return null;
  }

  String? _imageFull(AtprotoFeedItem item, int index) {
    if (index >= 0 && index < item.imageFullUrls.length) {
      return item.imageFullUrls[index];
    }
    return null;
  }

  String? _imageAlt(AtprotoFeedItem item, int index) {
    if (index >= 0 && index < item.imageAlts.length) {
      return item.imageAlts[index];
    }
    return null;
  }

  Future<void> _openImagePreview(
    AtprotoFeedItem item, {
    required int initialIndex,
  }) async {
    final count = _imageCount(item);
    if (count == 0 || !mounted) return;

    final controller = PageController(initialPage: initialIndex);
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.92),
      builder: (context) {
        var current = initialIndex;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return Stack(
              children: [
                Positioned.fill(
                  child: PageView.builder(
                    controller: controller,
                    itemCount: count,
                    onPageChanged: (index) =>
                        setDialogState(() => current = index),
                    itemBuilder: (context, index) {
                      final full = _imageFull(item, index);
                      final thumb = _imageThumb(item, index);
                      final target = full ?? thumb;
                      if (target == null) {
                        return const Center(
                          child: Icon(
                            Icons.broken_image,
                            color: Colors.white70,
                            size: 42,
                          ),
                        );
                      }
                      return InteractiveViewer(
                        minScale: 1,
                        maxScale: 4,
                        child: Center(
                          child: Image.network(
                            target,
                            fit: BoxFit.contain,
                            errorBuilder: (context, error, stackTrace) =>
                                const Icon(
                                  Icons.broken_image,
                                  color: Colors.white70,
                                  size: 42,
                                ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                Positioned(
                  top: 16,
                  right: 16,
                  child: IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, color: Colors.white),
                  ),
                ),
                if (count > 1)
                  Positioned(
                    bottom: 22,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '${current + 1}/$count',
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
    controller.dispose();
  }

  Future<void> _openImagePreviewFromUrl(String imageUrl) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.92),
      builder: (context) {
        return Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                minScale: 1,
                maxScale: 4,
                child: Center(
                  child: Image.network(
                    imageUrl,
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) => const Icon(
                      Icons.broken_image,
                      color: Colors.white70,
                      size: 42,
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 16,
              right: 16,
              child: IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close, color: Colors.white),
              ),
            ),
          ],
        );
      },
    );
  }
}
