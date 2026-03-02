/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Chat bubble for MeshCore messages with SNR badge and ACK checkmark.
 */

import 'package:flutter/material.dart';

import '../../shared/teleport_chat_utils.dart';
import '../models/meshcore_message.dart';

class MeshCoreMessageBubble extends StatelessWidget {
  final MeshCoreMessage message;

  const MeshCoreMessageBubble({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isOutgoing = message.isOutgoing;

    return Align(
      alignment: isOutgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: EdgeInsets.only(
          left: isOutgoing ? 64 : 8,
          right: isOutgoing ? 8 : 64,
          top: 2,
          bottom: 2,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isOutgoing
              ? theme.colorScheme.primary.withValues(alpha: 0.15)
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isOutgoing ? 16 : 4),
            bottomRight: Radius.circular(isOutgoing ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment:
              isOutgoing ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            // Sender name for incoming channel messages
            if (!isOutgoing && message.senderName != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  message.senderName!,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: teleportSenderColor(message.senderName!),
                  ),
                ),
              ),
            // Message text
            Text(
              message.text,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 4),
            // Footer: time + SNR + ACK
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // SNR badge for incoming
                if (!isOutgoing && message.snr != null) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: _snrColor(message.snr!).withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '${message.snr!.toStringAsFixed(1)} dB',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                        color: _snrColor(message.snr!),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                // Timestamp
                Text(
                  _formatTime(message.timestamp),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                // ACK checkmark for outgoing
                if (isOutgoing) ...[
                  const SizedBox(width: 4),
                  Icon(
                    message.isAcknowledged
                        ? Icons.done_all
                        : Icons.done,
                    size: 14,
                    color: message.isAcknowledged
                        ? const Color(0xFF00BCD4)
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  static Color _snrColor(double snr) {
    if (snr > 5) return Colors.green;
    if (snr > 0) return Colors.orange;
    return Colors.red;
  }

  static String _formatTime(DateTime dt) {
    final local = dt.toLocal();
    final h = local.hour.toString().padLeft(2, '0');
    final m = local.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}
