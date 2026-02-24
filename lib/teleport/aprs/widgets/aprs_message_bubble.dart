/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * APRS message bubble widget — simplified dark-mode chat bubble.
 * Same color scheme as Signal/Telegram teleport bubbles:
 *   - Outgoing: dark teal-blue #2B5278
 *   - Incoming: dark blue-gray #1E2D3D
 *   - Asymmetric rounded corners (4px on tail side)
 *   - Sender callsign colored via teleportSenderColor (incoming only)
 */

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../shared/teleport_chat_utils.dart';
import '../models/aprs_packet.dart';
import '../pages/aprs_main_page.dart' show linkifiedText;

class AprsMessageBubble extends StatelessWidget {
  final AprsPacket message;
  final bool isOutgoing;
  final bool showSender;

  static const _outgoingColor = Color(0xFF2B5278);
  static const _incomingColor = Color(0xFF1E2D3D);
  static const _maxBubbleWidth = 440.0;

  const AprsMessageBubble({
    super.key,
    required this.message,
    required this.isOutgoing,
    this.showSender = true,
  });

  String _formatTime(DateTime dt) {
    final local = dt.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final screenMax = MediaQuery.of(context).size.width * 0.75;
    final maxWidth =
        screenMax < _maxBubbleWidth ? screenMax : _maxBubbleWidth;

    final borderRadius = isOutgoing
        ? const BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
            bottomLeft: Radius.circular(16),
            bottomRight: Radius.circular(4),
          )
        : const BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
            bottomLeft: Radius.circular(4),
            bottomRight: Radius.circular(16),
          );

    final bubbleColor = isOutgoing ? _outgoingColor : _incomingColor;
    final displayText = message.isTagMessage
        ? (message.messageBody ?? '')
        : (message.messageText ?? '');

    return Align(
      alignment: isOutgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () {
          if (displayText.isNotEmpty) {
            Clipboard.setData(ClipboardData(text: displayText));
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Copied to clipboard'),
                duration: Duration(seconds: 1),
              ),
            );
          }
        },
        child: Container(
          constraints: BoxConstraints(maxWidth: maxWidth),
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
          decoration: BoxDecoration(
            color: bubbleColor,
            borderRadius: borderRadius,
          ),
          child: Padding(
            padding: const EdgeInsets.only(
              left: 14,
              right: 14,
              top: 8,
              bottom: 8,
            ),
            child: IntrinsicWidth(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Sender callsign (incoming only, in tag rooms always show)
                  if (!isOutgoing && showSender)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        message.fromCallsign,
                        style: TextStyle(
                          color: teleportSenderColor(message.fromCallsign),
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  // Message text
                  if (displayText.isNotEmpty)
                    linkifiedText(
                      displayText,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                    ),
                  const SizedBox(height: 2),
                  // Timestamp + ACK status
                  Align(
                    alignment: Alignment.bottomRight,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _formatTime(message.timestamp),
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.45),
                            fontSize: 10,
                          ),
                        ),
                        if (isOutgoing && message.messageId != null) ...[
                          const SizedBox(width: 3),
                          Icon(
                            message.isAcked ? Icons.done_all : Icons.done,
                            size: 14,
                            color: message.isAcked
                                ? const Color(0xFF4FC3F7)
                                : Colors.white.withValues(alpha: 0.45),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
