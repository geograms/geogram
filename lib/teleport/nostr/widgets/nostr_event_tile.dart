/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * NOSTR feed event widget — dark-mode bubble style matching Telegram/IRC.
 * Outgoing: dark teal-blue #2B5278, incoming: dark blue-gray #1E2D3D.
 */

import 'package:flutter/material.dart';

import '../../shared/teleport_chat_utils.dart';
import '../models/nostr_feed_item.dart';

class NostrEventTile extends StatelessWidget {
  final NostrFeedItem item;
  final bool isOwnPost;

  const NostrEventTile({
    super.key,
    required this.item,
    this.isOwnPost = false,
  });

  static const _outgoingColor = Color(0xFF2B5278);
  static const _incomingColor = Color(0xFF1E2D3D);

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: isOwnPost ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 440),
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isOwnPost ? _outgoingColor : _incomingColor,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(12),
            topRight: const Radius.circular(12),
            bottomLeft: Radius.circular(isOwnPost ? 12 : 4),
            bottomRight: Radius.circular(isOwnPost ? 4 : 12),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Author name
            if (!isOwnPost)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  item.displayName,
                  style: TextStyle(
                    color: teleportSenderColor(item.pubkey),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            // Content text
            Text(
              item.content,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
              ),
            ),
            // Timestamp + relay info
            const SizedBox(height: 2),
            Text(
              _formatTime(item.event.createdAtDateTime),
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime utcDate) {
    final local = utcDate.toLocal();
    final h = local.hour.toString().padLeft(2, '0');
    final m = local.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}
