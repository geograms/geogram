/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Meshtastic chat page — message view for a channel or DM conversation.
 */

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../services/i18n_service.dart';
import '../../shared/teleport_chat_utils.dart';
import '../meshtastic_service.dart';
import '../models/meshtastic_message.dart';
import '../widgets/meshtastic_message_bubble.dart';

class MeshtasticChatPage extends StatefulWidget {
  final String conversationId;
  final String displayName;
  final bool isChannel;

  const MeshtasticChatPage({
    super.key,
    required this.conversationId,
    required this.displayName,
    required this.isChannel,
  });

  @override
  State<MeshtasticChatPage> createState() => _MeshtasticChatPageState();
}

class _MeshtasticChatPageState extends State<MeshtasticChatPage> {
  final _service = MeshtasticService();
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  StreamSubscription<MeshtasticEvent>? _eventSub;

  static const _brandColor = Color(0xFF67EA94);

  @override
  void initState() {
    super.initState();
    _eventSub = _service.events.listen((event) {
      if (event.type == MeshtasticEventType.messageReceived && mounted) {
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

    if (widget.isChannel) {
      final chIdx =
          int.tryParse(widget.conversationId.substring(3)) ?? 0;
      _service.sendMessage(text, channelIndex: chIdx);
    } else {
      final nodeHex = widget.conversationId.substring(3);
      final nodeNum = int.tryParse(nodeHex, radix: 16) ?? 0;
      _service.sendMessage(text, toNode: nodeNum, channelIndex: 0);
    }

    _controller.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final messages = _service.getMessages(widget.conversationId);

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
                I18nService().t('meshtastic_connected_status'),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: _brandColor,
                ),
              )
            else
              Text(
                I18nService().t('meshtastic_offline_status'),
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
                      I18nService().t('meshtastic_chat_no_messages'),
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
                      return MeshtasticMessageBubble(
                        message: item as MeshtasticMessage,
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
                    maxLines: null,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: I18nService().t('meshtastic_message_hint'),
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
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _controller.text.trim().isEmpty ||
                          !_service.isConnected
                      ? null
                      : _send,
                  icon: const Icon(Icons.send),
                  style: IconButton.styleFrom(
                    backgroundColor: _brandColor,
                    foregroundColor: Colors.black,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
