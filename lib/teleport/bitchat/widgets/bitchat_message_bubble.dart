/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * BitChat message bubble — sender, text, timestamp, status, hop count.
 * Uses teleportSenderColor() from shared utilities.
 */

import 'package:flutter/material.dart';

import '../../shared/teleport_chat_utils.dart';
import '../models/bitchat_message.dart';

class BitchatMessageBubble extends StatelessWidget {
  final BitchatMessage message;

  const BitchatMessageBubble({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isOutgoing = message.isOutgoing;

    return Align(
      alignment: isOutgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        decoration: BoxDecoration(
          color: isOutgoing
              ? const Color(0xFF2B5278)
              : theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isOutgoing ? 16 : 4),
            bottomRight: Radius.circular(isOutgoing ? 4 : 16),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Sender name (for incoming channel messages)
            if (!isOutgoing && message.senderNickname.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  message.senderNickname,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: teleportSenderColor(message.senderNickname),
                  ),
                ),
              ),

            // Message text
            Text(
              message.content,
              style: TextStyle(
                fontSize: 14,
                color: isOutgoing ? Colors.white : theme.colorScheme.onSurface,
              ),
            ),

            const SizedBox(height: 4),

            // Metadata row: time, hops, delivery status
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Timestamp
                Text(
                  _formatTime(message.timestamp),
                  style: TextStyle(
                    fontSize: 10,
                    color: isOutgoing
                        ? Colors.white70
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),

                // Hop count badge (if > 0)
                if (message.hopCount > 0) ...[
                  const SizedBox(width: 4),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFF9100).withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '${message.hopCount}h',
                      style: const TextStyle(
                        fontSize: 9,
                        color: Color(0xFFFF9100),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],

                // Delivery status (outgoing only)
                if (isOutgoing) ...[
                  const SizedBox(width: 4),
                  _statusIcon(message.status),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusIcon(BitchatMessageStatus status) {
    switch (status) {
      case BitchatMessageStatus.pending:
        return const Icon(Icons.access_time, size: 12, color: Colors.white38);
      case BitchatMessageStatus.sent:
        return const Icon(Icons.check, size: 12, color: Colors.white54);
      case BitchatMessageStatus.delivered:
        return const Icon(Icons.done_all, size: 12, color: Colors.white70);
      case BitchatMessageStatus.failed:
        return const Icon(Icons.error_outline, size: 12, color: Colors.red);
    }
  }

  static String _formatTime(DateTime dt) {
    final local = dt.toLocal();
    final h = local.hour.toString().padLeft(2, '0');
    final m = local.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}
