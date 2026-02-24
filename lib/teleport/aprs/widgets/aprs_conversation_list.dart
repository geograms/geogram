/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Conversation list widget for APRS Messages tab.
 * Shows grouped conversations (direct 1:1 and tag rooms) with FAB for
 * composing new messages.
 */

import 'package:flutter/material.dart';

import '../../../services/user_location_service.dart';
import '../../shared/teleport_chat_utils.dart';
import '../aprs_service.dart';
import '../models/aprs_conversation.dart';
import '../pages/aprs_conversation_page.dart';
import '../pages/aprs_main_page.dart' show distanceKm, formatDistanceKm;

class AprsConversationList extends StatelessWidget {
  final UserLocation? myLocation;

  const AprsConversationList({super.key, this.myLocation});

  @override
  Widget build(BuildContext context) {
    final aprs = AprsService();
    final conversations = aprs.getConversations();

    if (conversations.isEmpty && aprs.messages.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.forum_outlined,
              size: 48,
              color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 12),
            Text(
              'No conversations yet',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Messages addressed to your callsign\nand subscribed #tags will appear here',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      );
    }

    return Stack(
      children: [
        ListView.builder(
          itemCount: conversations.length,
          itemBuilder: (context, index) {
            final conv = conversations[index];
            return _ConversationTile(
              conversation: conv,
              myLocation: myLocation,
              onTap: () => _openConversation(context, conv),
            );
          },
        ),
        // FAB for new message
        Positioned(
          right: 16,
          bottom: 16,
          child: FloatingActionButton(
            onPressed: () => _showNewMessageDialog(context),
            child: const Icon(Icons.edit),
          ),
        ),
      ],
    );
  }

  void _openConversation(BuildContext context, AprsConversation conv) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AprsConversationPage(
          conversationId: conv.id,
          conversationType: conv.type,
          partnerPosition: conv.partnerPosition,
          myLocation: myLocation,
        ),
      ),
    );
  }

  void _showNewMessageDialog(BuildContext context) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Message'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'Enter callsign (e.g., N0CALL-9)',
            border: OutlineInputBorder(),
          ),
          textCapitalization: TextCapitalization.characters,
          autofocus: true,
          onSubmitted: (value) {
            final callsign = value.trim().toUpperCase();
            if (callsign.isNotEmpty) {
              Navigator.of(ctx).pop();
              _openConversation(
                context,
                AprsConversation(
                  id: callsign,
                  type: AprsConversationType.direct,
                ),
              );
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final callsign = controller.text.trim().toUpperCase();
              if (callsign.isNotEmpty) {
                Navigator.of(ctx).pop();
                _openConversation(
                  context,
                  AprsConversation(
                    id: callsign,
                    type: AprsConversationType.direct,
                  ),
                );
              }
            },
            child: const Text('Open'),
          ),
        ],
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  final AprsConversation conversation;
  final UserLocation? myLocation;
  final VoidCallback onTap;

  const _ConversationTile({
    required this.conversation,
    this.myLocation,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDirect = conversation.type == AprsConversationType.direct;

    // Distance indicator for direct conversations
    String? distStr;
    if (isDirect && conversation.partnerPosition != null) {
      final dist = distanceKm(
        conversation.partnerPosition!.$1,
        conversation.partnerPosition!.$2,
        myLocation,
      );
      if (dist != null) distStr = formatDistanceKm(dist);
    }

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: isDirect
            ? teleportSenderColor(conversation.id).withValues(alpha: 0.2)
            : theme.colorScheme.primaryContainer,
        child: isDirect
            ? Text(
                conversation.id.isNotEmpty
                    ? conversation.id[0].toUpperCase()
                    : '?',
                style: TextStyle(
                  color: teleportSenderColor(conversation.id),
                  fontWeight: FontWeight.w600,
                ),
              )
            : Icon(
                Icons.tag,
                color: theme.colorScheme.onPrimaryContainer,
              ),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              conversation.displayName,
              style: const TextStyle(fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            _formatTime(conversation.lastMessageTime),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      subtitle: Row(
        children: [
          Expanded(
            child: Text(
              conversation.lastMessagePreview,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (distStr != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                distStr,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
        ],
      ),
      onTap: onTap,
    );
  }

  String _formatTime(DateTime? dt) {
    if (dt == null) return '';
    final local = dt.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final msgDay = DateTime(local.year, local.month, local.day);
    final diff = today.difference(msgDay).inDays;

    if (diff == 0) {
      return '${local.hour.toString().padLeft(2, '0')}:'
          '${local.minute.toString().padLeft(2, '0')}';
    }
    if (diff == 1) return 'Yesterday';
    if (diff < 7) {
      const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return days[local.weekday - 1];
    }
    return '${local.day}/${local.month}';
  }
}
