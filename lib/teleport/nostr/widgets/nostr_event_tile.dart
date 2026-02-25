/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * NOSTR feed post card — social feed style with avatar, display name,
 * NIP-05 verification, linkified content, and timestamp.
 */

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../services/file_launcher_service.dart';
import '../../../util/nostr_nip19.dart';
import '../../shared/teleport_chat_utils.dart';
import '../models/nostr_feed_item.dart';
import '../nostr_client_service.dart';
import '../pages/nostr_user_profile_page.dart';

class NostrEventTile extends StatefulWidget {
  final NostrFeedItem item;
  final bool isOwnPost;
  final VoidCallback? onLike;
  final VoidCallback? onTapAuthor;

  const NostrEventTile({
    super.key,
    required this.item,
    this.isOwnPost = false,
    this.onLike,
    this.onTapAuthor,
  });

  @override
  State<NostrEventTile> createState() => _NostrEventTileState();
}

class _NostrEventTileState extends State<NostrEventTile> {
  static final _linkRegex = RegExp(
    r'(https?://[^\s<>\[\]{}|\\^`]+|www\.[^\s<>\[\]{}|\\^`]+|nostr:[a-z0-9]+)',
    caseSensitive: false,
  );

  List<TapGestureRecognizer> _linkRecognizers = [];

  @override
  void dispose() {
    for (final r in _linkRecognizers) {
      r.dispose();
    }
    super.dispose();
  }

  Widget _buildAvatar() {
    final name = widget.item.displayName;
    final color = teleportSenderColor(widget.item.pubkey);
    final pictureUrl = widget.item.authorPicture;

    if (pictureUrl != null && pictureUrl.isNotEmpty) {
      return CircleAvatar(
        radius: 20,
        backgroundColor: color.withValues(alpha: 0.2),
        backgroundImage: NetworkImage(pictureUrl),
        onBackgroundImageError: (_, _) {},
        child: Text(
          name.isNotEmpty ? name[0].toUpperCase() : '?',
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.w600,
            fontSize: 16,
          ),
        ),
      );
    }

    return CircleAvatar(
      radius: 20,
      backgroundColor: color.withValues(alpha: 0.2),
      child: Text(
        name.isNotEmpty ? name[0].toUpperCase() : '?',
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w600,
          fontSize: 16,
        ),
      ),
    );
  }

  Widget _buildLinkedText(String text, TextStyle? baseStyle) {
    for (final r in _linkRecognizers) {
      r.dispose();
    }
    _linkRecognizers = [];

    final matches = _linkRegex.allMatches(text).toList();
    if (matches.isEmpty) {
      return SelectableText(text, style: baseStyle);
    }

    final spans = <InlineSpan>[];
    int lastEnd = 0;

    for (final match in matches) {
      if (match.start > lastEnd) {
        spans.add(TextSpan(text: text.substring(lastEnd, match.start)));
      }

      final urlText = match.group(0)!;
      final recognizer = TapGestureRecognizer()
        ..onTap = () {
          if (urlText.startsWith('nostr:')) {
            _handleNostrUri(urlText);
            return;
          }
          final launchUrl =
              urlText.startsWith('http') ? urlText : 'https://$urlText';
          FileLauncherService().openUrl(launchUrl);
        };
      _linkRecognizers.add(recognizer);

      spans.add(TextSpan(
        text: urlText,
        style: baseStyle?.copyWith(
          color: const Color(0xFF64B5F6),
          decoration: TextDecoration.underline,
          decorationColor: const Color(0xFF64B5F6),
        ),
        recognizer: recognizer,
      ));

      lastEnd = match.end;
    }

    if (lastEnd < text.length) {
      spans.add(TextSpan(text: text.substring(lastEnd)));
    }

    return Text.rich(TextSpan(style: baseStyle, children: spans));
  }

  void _handleNostrUri(String uri) {
    final decoded = NostrNip19.decode(uri);
    if (decoded == null) {
      _showSnack('Invalid NOSTR link');
      return;
    }

    final pubkeyHex = decoded.pubkeyHex;
    final eventId = decoded.eventIdHex;
    if (pubkeyHex != null) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => NostrUserProfilePage(pubkey: pubkeyHex),
        ),
      );
      return;
    }
    if (eventId != null) {
      _showEventPreview(eventId);
      return;
    }

    _showSnack('Unsupported NOSTR link');
  }

  Future<void> _showEventPreview(String eventId) async {
    final service = NostrClientService();
    service.requestEventById(eventId);

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StreamBuilder<NostrClientEvent>(
          stream: service.events,
          builder: (context, snapshot) {
            final item = service.findFeedItemById(eventId);
            if (item == null) {
              return Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 12),
                    const Text('Fetching event from relays...'),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: () => service.requestEventById(eventId),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              );
            }

            return SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: NostrEventTile(
                  item: item,
                  onLike: item.id == null
                      ? null
                      : () {
                          NostrClientService().likeEvent(
                            item.id!,
                            item.pubkey,
                          );
                        },
                  onTapAuthor: () {
                    Navigator.of(ctx).pop();
                    if (item.pubkey.isNotEmpty) {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              NostrUserProfilePage(pubkey: item.pubkey),
                        ),
                      );
                    }
                  },
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  String _formatTime(DateTime utcDate) {
    final local = utcDate.toLocal();
    final h = local.hour.toString().padLeft(2, '0');
    final m = local.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  String _formatRelativeTime(DateTime utcDate) {
    final now = DateTime.now().toUtc();
    final diff = now.difference(utcDate);

    if (diff.inSeconds < 60) return '${diff.inSeconds}s';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    return _formatTime(utcDate);
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: Colors.white.withValues(alpha: 0.06),
          ),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Avatar (tappable for profile)
          GestureDetector(
            onTap: widget.onTapAuthor,
            child: _buildAvatar(),
          ),
          const SizedBox(width: 12),
          // Content column
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header row: name + NIP-05 + time
                _buildHeader(item),
                const SizedBox(height: 4),
                // Post content with linkified URLs
                _buildLinkedText(
                  item.content,
                  const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 6),
                // Reaction bar
                _buildReactionBar(item),
                const SizedBox(height: 4),
                // Footer: relay source
                _buildFooter(item),
              ],
            ),
          ),
          // Copy button
          IconButton(
            icon: Icon(
              Icons.more_horiz,
              size: 16,
              color: Colors.white.withValues(alpha: 0.3),
            ),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            onPressed: () => _showMenu(context),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(NostrFeedItem item) {
    final nameColor = teleportSenderColor(item.pubkey);

    return Row(
      children: [
        // Display name (tappable for profile)
        Flexible(
          child: GestureDetector(
            onTap: widget.onTapAuthor,
            child: Text(
              item.displayName,
              style: TextStyle(
                color: nameColor,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        // NIP-05 verification
        if (item.authorNip05 != null && item.authorNip05!.isNotEmpty) ...[
          const SizedBox(width: 4),
          Icon(
            Icons.verified,
            size: 14,
            color: Colors.blue.shade300,
          ),
          const SizedBox(width: 2),
          Flexible(
            child: Text(
              item.authorNip05!,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.4),
                fontSize: 12,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
        const SizedBox(width: 6),
        // Relative timestamp
        Text(
          _formatRelativeTime(item.event.createdAtDateTime),
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.4),
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  Widget _buildFooter(NostrFeedItem item) {
    final relay = Uri.tryParse(item.relayUrl)?.host ?? item.relayUrl;
    return Row(
      children: [
        Icon(
          Icons.cell_tower,
          size: 12,
          color: Colors.white.withValues(alpha: 0.2),
        ),
        const SizedBox(width: 4),
        Text(
          relay,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.2),
            fontSize: 11,
          ),
        ),
        if (item.isFollowed) ...[
          const SizedBox(width: 8),
          Icon(
            Icons.person,
            size: 12,
            color: Colors.green.withValues(alpha: 0.5),
          ),
          const SizedBox(width: 2),
          Text(
            'Following',
            style: TextStyle(
              color: Colors.green.withValues(alpha: 0.5),
              fontSize: 11,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildReactionBar(NostrFeedItem item) {
    return Row(
      children: [
        GestureDetector(
          onTap: widget.onLike,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                item.isLikedByMe ? Icons.favorite : Icons.favorite_border,
                size: 16,
                color: item.isLikedByMe
                    ? Colors.red.shade400
                    : Colors.white.withValues(alpha: 0.3),
              ),
              if (item.reactionCount > 0) ...[
                const SizedBox(width: 4),
                Text(
                  '${item.reactionCount}',
                  style: TextStyle(
                    color: item.isLikedByMe
                        ? Colors.red.shade400
                        : Colors.white.withValues(alpha: 0.4),
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  void _showMenu(BuildContext context) {
    final box = context.findRenderObject() as RenderBox;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final position = RelativeRect.fromRect(
      box.localToGlobal(Offset.zero, ancestor: overlay) & box.size,
      Offset.zero & overlay.size,
    );

    showMenu<String>(
      context: context,
      position: position,
      items: [
        const PopupMenuItem(value: 'copy', child: Text('Copy text')),
        const PopupMenuItem(value: 'copy_id', child: Text('Copy event ID')),
        const PopupMenuItem(value: 'copy_npub', child: Text('Copy npub')),
        if (widget.onTapAuthor != null)
          const PopupMenuItem(value: 'profile', child: Text('View profile')),
      ],
    ).then((value) {
      if (value == null) return;
      switch (value) {
        case 'copy':
          Clipboard.setData(ClipboardData(text: widget.item.content));
          break;
        case 'copy_id':
          if (widget.item.id != null) {
            Clipboard.setData(ClipboardData(text: widget.item.id!));
          }
          break;
        case 'copy_npub':
          Clipboard.setData(ClipboardData(text: widget.item.event.npub));
          break;
        case 'profile':
          widget.onTapAuthor?.call();
          break;
      }
    });
  }
}
