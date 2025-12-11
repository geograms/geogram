/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'package:flutter/material.dart';
import '../models/chat_message.dart';
import 'message_bubble_widget.dart';

/// Widget for displaying a scrollable list of chat messages
class MessageListWidget extends StatefulWidget {
  final List<ChatMessage> messages;
  final bool isGroupChat;
  final VoidCallback? onLoadMore;
  final bool isLoading;
  final Function(ChatMessage)? onFileOpen;
  final Function(ChatMessage)? onMessageDelete;
  final bool Function(ChatMessage)? canDeleteMessage;
  /// Callback to get voice file path for a message
  final Future<String?> Function(ChatMessage)? getVoiceFilePath;

  const MessageListWidget({
    Key? key,
    required this.messages,
    this.isGroupChat = true,
    this.onLoadMore,
    this.isLoading = false,
    this.onFileOpen,
    this.onMessageDelete,
    this.canDeleteMessage,
    this.getVoiceFilePath,
  }) : super(key: key);

  @override
  State<MessageListWidget> createState() => _MessageListWidgetState();
}

class _MessageListWidgetState extends State<MessageListWidget> {
  final ScrollController _scrollController = ScrollController();
  bool _autoScroll = true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_scrollListener);

    // Auto-scroll to bottom on first load
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom(animate: false);
    });
  }

  @override
  void didUpdateWidget(MessageListWidget oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Auto-scroll to bottom when new messages arrive (if already at bottom)
    if (widget.messages.length > oldWidget.messages.length && _autoScroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToBottom();
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// Listen for scroll events
  void _scrollListener() {
    // Check if at bottom (within 100 pixels)
    if (_scrollController.hasClients) {
      final atBottom = _scrollController.position.pixels >=
          _scrollController.position.maxScrollExtent - 100;
      if (_autoScroll != atBottom) {
        setState(() {
          _autoScroll = atBottom;
        });
      }

      // Load more when scrolling near top
      if (_scrollController.position.pixels <= 100 &&
          widget.onLoadMore != null &&
          !widget.isLoading) {
        widget.onLoadMore!();
      }
    }
  }

  /// Scroll to bottom of list
  void _scrollToBottom({bool animate = true}) {
    if (!_scrollController.hasClients) return;

    if (animate) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    } else {
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Stack(
      children: [
        // Message list
        widget.messages.isEmpty
            ? _buildEmptyState(theme)
            : ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(vertical: 12),
                itemCount: widget.messages.length + (widget.isLoading ? 1 : 0),
                itemBuilder: (context, index) {
                  // Loading indicator at top
                  if (widget.isLoading && index == 0) {
                    return Padding(
                      padding: const EdgeInsets.all(16),
                      child: Center(
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ),
                    );
                  }

                  // Message bubble
                  final messageIndex =
                      widget.isLoading ? index - 1 : index;
                  final message = widget.messages[messageIndex];

                  return MessageBubbleWidget(
                    key: ValueKey(message.timestamp + message.author),
                    message: message,
                    isGroupChat: widget.isGroupChat,
                    onFileOpen: widget.onFileOpen != null
                        ? () => widget.onFileOpen!(message)
                        : null,
                    onDelete: widget.onMessageDelete != null
                        ? () => widget.onMessageDelete!(message)
                        : null,
                    canDelete: widget.canDeleteMessage != null
                        ? widget.canDeleteMessage!(message)
                        : false,
                    // Voice message support
                    onVoiceDownloadRequested: widget.getVoiceFilePath != null && message.hasVoice
                        ? () => widget.getVoiceFilePath!(message)
                        : null,
                  );
                },
              ),
        // Scroll to bottom button
        if (!_autoScroll)
          Positioned(
            bottom: 16,
            right: 16,
            child: FloatingActionButton.small(
              onPressed: () => _scrollToBottom(),
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Icon(
                Icons.arrow_downward,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
          ),
      ],
    );
  }

  /// Build empty state widget
  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: 64,
            color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5),
          ),
          const SizedBox(height: 16),
          Text(
            'No messages yet',
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Start the conversation!',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant.withOpacity(0.7),
            ),
          ),
        ],
      ),
    );
  }
}
