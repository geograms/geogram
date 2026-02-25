/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';

import '../models/atproto_feed_item.dart';

class AtprotoPostTile extends StatelessWidget {
  final AtprotoFeedItem item;
  final VoidCallback? onLike;
  final VoidCallback? onRepost;
  final VoidCallback? onReply;

  const AtprotoPostTile({
    super.key,
    required this.item,
    this.onLike,
    this.onRepost,
    this.onReply,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              item.displayName.isNotEmpty
                  ? item.displayName
                  : item.authorHandle,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '@${item.authorHandle}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(item.text),
            const SizedBox(height: 10),
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.reply, size: 18),
                  tooltip: 'Reply',
                  onPressed: onReply,
                ),
                Text('${item.replyCount}'),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.repeat, size: 18),
                  tooltip: 'Repost',
                  onPressed: onRepost,
                ),
                Text('${item.repostCount}'),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.favorite_border, size: 18),
                  tooltip: 'Like',
                  onPressed: onLike,
                ),
                Text('${item.likeCount}'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
