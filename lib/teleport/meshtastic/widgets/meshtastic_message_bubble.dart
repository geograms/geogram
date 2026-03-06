/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Meshtastic message bubble — sender, text, timestamp, SNR, RSSI, hop count.
 * Uses teleportSenderColor() from shared utilities.
 */

import 'package:flutter/material.dart';

import '../../shared/teleport_chat_utils.dart';
import '../models/meshtastic_message.dart';

class MeshtasticMessageBubble extends StatelessWidget {
  final MeshtasticMessage message;

  const MeshtasticMessageBubble({super.key, required this.message});

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
              ? const Color(0xFF1B5E20)
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
            // Sender name (incoming only)
            if (!isOutgoing && _senderName.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  _senderName,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: teleportSenderColor(_senderName),
                  ),
                ),
              ),

            // Message text
            Text(
              message.text,
              style: TextStyle(
                fontSize: 14,
                color: isOutgoing ? Colors.white : theme.colorScheme.onSurface,
              ),
            ),

            const SizedBox(height: 4),

            // Metadata row: time, SNR, RSSI, hops, delivery status
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

                // SNR badge
                if (message.rxSnr != null) ...[
                  const SizedBox(width: 4),
                  _metaBadge(
                    '${message.rxSnr!.toStringAsFixed(1)}dB',
                    const Color(0xFF67EA94),
                  ),
                ],

                // RSSI badge
                if (message.rxRssi != null) ...[
                  const SizedBox(width: 3),
                  _metaBadge(
                    '${message.rxRssi}',
                    const Color(0xFF64B5F6),
                  ),
                ],

                // Hop count badge
                if (message.hopStart > 0 &&
                    message.hopStart > message.hopLimit) ...[
                  const SizedBox(width: 3),
                  _metaBadge(
                    '${message.hopStart - message.hopLimit}h',
                    const Color(0xFF67EA94),
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

  String get _senderName {
    if (message.senderLongName.isNotEmpty) return message.senderLongName;
    if (message.senderShortName.isNotEmpty) return message.senderShortName;
    return '!${message.fromNode.toRadixString(16)}';
  }

  Widget _metaBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 9,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _statusIcon(MeshtasticMessageStatus status) {
    switch (status) {
      case MeshtasticMessageStatus.pending:
        return const Icon(Icons.access_time, size: 12, color: Colors.white38);
      case MeshtasticMessageStatus.sent:
        return const Icon(Icons.check, size: 12, color: Colors.white54);
      case MeshtasticMessageStatus.delivered:
        return const Icon(Icons.done_all, size: 12, color: Colors.white70);
      case MeshtasticMessageStatus.failed:
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
