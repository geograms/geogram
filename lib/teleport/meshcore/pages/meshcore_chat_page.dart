/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * MeshCore chat page — message view for a contact or channel conversation.
 * Reversed ListView, compose bar with 133-char limit, SNR badges, ACK checkmarks.
 */

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../services/i18n_service.dart';
import '../../shared/teleport_chat_utils.dart';
import '../meshcore_protocol.dart';
import '../meshcore_service.dart';
import '../models/meshcore_message.dart';
import '../widgets/meshcore_message_bubble.dart';

class MeshCoreChatPage extends StatefulWidget {
  final String conversationId;
  final String displayName;
  final MeshCoreConversationType conversationType;

  const MeshCoreChatPage({
    super.key,
    required this.conversationId,
    required this.displayName,
    required this.conversationType,
  });

  @override
  State<MeshCoreChatPage> createState() => _MeshCoreChatPageState();
}

class _MeshCoreChatPageState extends State<MeshCoreChatPage> {
  final _service = MeshCoreService();
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  StreamSubscription<MeshCoreEvent>? _eventSub;

  @override
  void initState() {
    super.initState();
    _eventSub = _service.events.listen((event) {
      if (event.type == MeshCoreEventType.messageReceived && mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    if (widget.conversationType == MeshCoreConversationType.channel) {
      // Extract channel index from "ch:N"
      final idx = int.tryParse(widget.conversationId.substring(3)) ?? 0;
      _service.sendChannelMessage(idx, text);
    } else {
      _service.sendContactMessage(widget.conversationId, text);
    }

    _controller.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final messages = _service.getMessages(widget.conversationId);
    final charCount = _controller.text.length;
    final isOverLimit = charCount > meshCoreMaxTextBytes;

    // Group messages by date for separators
    final items = <dynamic>[];
    DateTime? lastDate;
    for (final msg in messages) {
      final msgDate = DateTime(
        msg.timestamp.toLocal().year,
        msg.timestamp.toLocal().month,
        msg.timestamp.toLocal().day,
      );
      if (lastDate == null || lastDate != msgDate) {
        items.add(msg.timestamp);
        lastDate = msgDate;
      }
      items.add(msg);
    }

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.displayName),
            if (_service.isConnected)
              Text(
                I18nService().t('meshcore_connected_status'),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: const Color(0xFF00BCD4),
                ),
              )
            else
              Text(
                I18nService().t('meshcore_offline_status'),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
      body: Column(
        children: [
          // Messages list
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Text(
                      I18nService().t('meshcore_chat_no_messages'),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final item = items[index];
                      if (item is DateTime) {
                        return TeleportDateSeparator(date: item);
                      }
                      return MeshCoreMessageBubble(
                        message: item as MeshCoreMessage,
                      );
                    },
                  ),
          ),
          // Compose bar
          Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              border: Border(
                top: BorderSide(color: theme.dividerColor, width: 0.5),
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    maxLength: meshCoreMaxTextBytes,
                    maxLines: null,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: I18nService().t('meshcore_message_hint', params: ['$meshCoreMaxTextBytes']),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      fillColor: theme.colorScheme.surfaceContainerHighest,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      counterText: '$charCount/$meshCoreMaxTextBytes',
                      counterStyle: TextStyle(
                        color: isOverLimit
                            ? theme.colorScheme.error
                            : theme.colorScheme.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _controller.text.trim().isEmpty ||
                          isOverLimit ||
                          !_service.isConnected
                      ? null
                      : _send,
                  icon: const Icon(Icons.send),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
