/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Chat list item tile: avatar, title, last message preview, unread badge.
 */

import 'dart:io';

import 'package:flutter/material.dart';

import '../models/telegram_chat.dart';

class TelegramChatTile extends StatelessWidget {
  final TelegramChat chat;
  final VoidCallback onTap;

  const TelegramChatTile({
    super.key,
    required this.chat,
    required this.onTap,
  });

  IconData _iconForChat() {
    if (chat.isForum) return Icons.forum;
    switch (chat.type) {
      case TelegramChatType.private_:
        return Icons.person;
      case TelegramChatType.group:
        return Icons.group;
      case TelegramChatType.supergroup:
        return Icons.group;
      case TelegramChatType.channel:
        return Icons.campaign;
      case TelegramChatType.unknown:
        return Icons.chat;
    }
  }

  String _formatTime(DateTime? date) {
    if (date == null) return '';
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListTile(
      leading: chat.photoPath != null
          ? CircleAvatar(
              backgroundImage: FileImage(File(chat.photoPath!)),
            )
          : chat.photoBytes != null
              ? CircleAvatar(
                  backgroundImage: MemoryImage(chat.photoBytes!),
                )
              : CircleAvatar(
                  backgroundColor:
                      const Color(0xFF0088CC).withValues(alpha: 0.15),
                  child: Icon(
                    _iconForChat(),
                    color: const Color(0xFF0088CC),
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
      subtitle: chat.lastMessageText != null
          ? Text(
              chat.lastMessageText!,
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
            _formatTime(chat.lastMessageDate),
            style: theme.textTheme.labelSmall?.copyWith(
              color: chat.unreadCount > 0
                  ? const Color(0xFF0088CC)
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (chat.unreadCount > 0) ...[
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF0088CC),
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
