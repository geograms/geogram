/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Chat list item tile for Signal conversations.
 * Shows initials-based avatar, title, last message preview, unread badge.
 */

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/signal_chat.dart';
import '../models/signal_message.dart';

class SignalChatTile extends StatelessWidget {
  final SignalChat chat;
  final VoidCallback onTap;

  /// Optional cached photo bytes for the conversation avatar.
  final Uint8List? photoBytes;

  const SignalChatTile({
    super.key,
    required this.chat,
    required this.onTap,
    this.photoBytes,
  });

  static const _signalBlue = Color(0xFF3A76F0);

  IconData _iconForChat() {
    switch (chat.type) {
      case SignalChatType.direct:
        return Icons.person;
      case SignalChatType.group:
        return Icons.group;
    }
  }

  /// Deterministic color from a string (consistent across renders).
  static Color _avatarColor(String name) {
    const colors = [
      Color(0xFFE53935), // red
      Color(0xFF8E24AA), // purple
      Color(0xFF3949AB), // indigo
      Color(0xFF039BE5), // light blue
      Color(0xFF00897B), // teal
      Color(0xFF7CB342), // light green
      Color(0xFFFB8C00), // orange
    ];
    final hash = name.hashCode.abs();
    return colors[hash % colors.length];
  }

  String _formatTime(int? timestampMs) {
    if (timestampMs == null || timestampMs == 0) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(timestampMs);
    final local = date.toLocal();
    final now = DateTime.now();
    if (local.year == now.year &&
        local.month == now.month &&
        local.day == now.day) {
      return '${local.hour.toString().padLeft(2, '0')}:'
          '${local.minute.toString().padLeft(2, '0')}';
    }
    return '${local.month}/${local.day}';
  }

  String _lastMessagePreview(SignalMessage? msg) {
    if (msg == null) return '';
    if (msg.text != null && msg.text!.isNotEmpty) return msg.text!;
    if (msg.attachmentCount > 0) return '[Attachment]';
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lastMsg = chat.lastMessage;
    final lastTimestamp = lastMsg?.timestamp;

    return ListTile(
      leading: photoBytes != null
          ? CircleAvatar(backgroundImage: MemoryImage(photoBytes!))
          : CircleAvatar(
              backgroundColor:
                  _avatarColor(chat.title).withValues(alpha: 0.15),
              child: chat.title.isNotEmpty
                  ? Text(
                      chat.title[0].toUpperCase(),
                      style: TextStyle(
                        color: _avatarColor(chat.title),
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    )
                  : Icon(
                      _iconForChat(),
                      color: _signalBlue,
                      size: 20,
                    ),
            ),
      title: Text(
        chat.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyLarge?.copyWith(
          fontWeight:
              chat.unreadCount > 0 ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      subtitle: lastMsg != null
          ? Text(
              _lastMessagePreview(lastMsg),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          : null,
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            _formatTime(lastTimestamp),
            style: theme.textTheme.labelSmall?.copyWith(
              color: chat.unreadCount > 0
                  ? _signalBlue
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (chat.unreadCount > 0) ...[
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: _signalBlue,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                chat.unreadCount > 99 ? '99+' : '${chat.unreadCount}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
      onTap: onTap,
    );
  }
}
