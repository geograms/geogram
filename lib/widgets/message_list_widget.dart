/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../models/chat_message.dart';
import '../services/chat_file_download_manager.dart';
import '../services/chat_file_upload_manager.dart';
import 'message_bubble_widget.dart';

/// Widget for displaying a scrollable list of chat messages
class MessageListWidget extends StatefulWidget {
  final List<ChatMessage> messages;
  final bool isGroupChat;
  final VoidCallback? onLoadMore;
  final bool isLoading;
  /// Loading progress text (e.g., "Loading messages..." or "Loading Jan 15...")
  final String? loadingText;
  final Function(ChatMessage)? onFileOpen;
  final Function(ChatMessage)? onMessageDelete;
  final bool Function(ChatMessage)? canDeleteMessage;
  final void Function(ChatMessage, String)? onMessageEdit;
  final bool Function(ChatMessage)? canEditMessage;
  final Function(ChatMessage)? onMessageQuote;
  final Function(ChatMessage)? onMessageHide;
  final bool Function(ChatMessage)? isMessageHidden;
  final Function(ChatMessage)? onMessageUnhide;
  /// Callback to get attachment data - returns (path, bytes) tuple
  /// For filesystem storage: returns (path, null)
  /// For encrypted storage: returns (null, bytes)
  final Future<(String?, Uint8List?)> Function(ChatMessage)? getAttachmentData;
  final Function(ChatMessage)? onImageOpen;
  final void Function(ChatMessage, String)? onMessageReact;
  /// Callback to get voice file path for a message
  final Future<String?> Function(ChatMessage)? getVoiceFilePath;
  /// Check if download button should be shown for a message
  final bool Function(ChatMessage)? shouldShowDownloadButton;
  /// Get file size in bytes for a message
  final int? Function(ChatMessage)? getFileSize;
  /// Get current download state for a message
  final ChatDownload? Function(ChatMessage)? getDownloadState;
  /// Callback when download button pressed
  final void Function(ChatMessage)? onDownloadPressed;
  /// Callback when download cancel pressed
  final void Function(ChatMessage)? onCancelDownload;
  /// Get current upload state for a message (sender side)
  final ChatUpload? Function(ChatMessage)? getUploadState;
  /// Callback when retry upload button pressed
  final void Function(ChatMessage)? onRetryUpload;
  /// Map of uppercase callsign -> display nickname (from contacts)
  final Map<String, String>? nicknameMap;

  const MessageListWidget({
    Key? key,
    required this.messages,
    this.isGroupChat = true,
    this.onLoadMore,
    this.isLoading = false,
    this.loadingText,
    this.onFileOpen,
    this.onMessageDelete,
    this.canDeleteMessage,
    this.onMessageEdit,
    this.canEditMessage,
    this.onMessageQuote,
    this.onMessageHide,
    this.isMessageHidden,
    this.onMessageUnhide,
    this.getAttachmentData,
    this.onImageOpen,
    this.onMessageReact,
    this.getVoiceFilePath,
    this.shouldShowDownloadButton,
    this.getFileSize,
    this.getDownloadState,
    this.onDownloadPressed,
    this.onCancelDownload,
    this.getUploadState,
    this.onRetryUpload,
    this.nicknameMap,
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
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// Listen for scroll events
  void _scrollListener() {
    if (_scrollController.hasClients) {
      // In reverse mode, position 0 is the bottom (newest messages)
      final atBottom = _scrollController.position.pixels <= 100;
      if (_autoScroll != atBottom) {
        setState(() {
          _autoScroll = atBottom;
        });
      }

      // Load more (older messages) when scrolling near the top
      // In reverse mode, top of screen is at maxScrollExtent
      if (_scrollController.position.pixels >=
              _scrollController.position.maxScrollExtent - 100 &&
          widget.onLoadMore != null &&
          !widget.isLoading) {
        widget.onLoadMore!();
      }
    }
  }

  /// Scroll to bottom of list (position 0 in reverse mode)
  void _scrollToBottom({bool animate = true}) {
    if (!_scrollController.hasClients) return;

    if (animate) {
      _scrollController.animateTo(
        0.0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    } else {
      _scrollController.jumpTo(0.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = _buildItems();

    return Stack(
      children: [
        // Message list
        widget.messages.isEmpty
            ? _buildEmptyState(theme)
            : ListView.builder(
                controller: _scrollController,
                reverse: true,
                padding: const EdgeInsets.symmetric(vertical: 12),
                itemCount: items.length + (widget.isLoading ? 1 : 0),
                itemBuilder: (context, index) {
                  // Loading indicator at top (last index in reverse mode)
                  if (widget.isLoading && index == items.length) {
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
                  final item = items[index];

                  if (item.isSeparator) {
                    return _buildDateSeparator(theme, item.label ?? '');
                  }

                  final message = item.message!;

                  return MessageBubbleWidget(
                    key: ValueKey(message.timestamp + message.author),
                    message: message,
                    isGroupChat: widget.isGroupChat,
                    contactNickname: widget.nicknameMap?[message.author.toUpperCase()],
                    onFileOpen: widget.onFileOpen != null
                        ? () => widget.onFileOpen!(message)
                        : null,
                    onDelete: widget.onMessageDelete != null
                        ? () => widget.onMessageDelete!(message)
                        : null,
                    canDelete: widget.canDeleteMessage != null
                        ? widget.canDeleteMessage!(message)
                        : false,
                    onEdit: widget.onMessageEdit != null
                        ? (newContent) => widget.onMessageEdit!(message, newContent)
                        : null,
                    canEdit: widget.canEditMessage != null
                        ? widget.canEditMessage!(message)
                        : false,
                    onQuote: widget.onMessageQuote != null
                        ? () => widget.onMessageQuote!(message)
                        : null,
                    onHide: widget.onMessageHide != null
                        ? () => widget.onMessageHide!(message)
                        : null,
                    isHidden: widget.isMessageHidden != null
                        ? widget.isMessageHidden!(message)
                        : false,
                    onUnhide: widget.onMessageUnhide != null
                        ? () => widget.onMessageUnhide!(message)
                        : null,
                    onAttachmentDataRequested: widget.getAttachmentData != null && message.hasFile
                        ? () => widget.getAttachmentData!(message)
                        : null,
                    onImageOpen: widget.onImageOpen != null
                        ? () => widget.onImageOpen!(message)
                        : null,
                    onReact: widget.onMessageReact != null
                        ? (reaction) => widget.onMessageReact!(message, reaction)
                        : null,
                    // Voice message support
                    onVoiceDownloadRequested: widget.getVoiceFilePath != null && message.hasVoice
                        ? () => widget.getVoiceFilePath!(message)
                        : null,
                    // Download manager integration
                    showDownloadButton: widget.shouldShowDownloadButton?.call(message) ?? false,
                    fileSize: widget.getFileSize?.call(message),
                    downloadState: widget.getDownloadState?.call(message),
                    onDownloadPressed: widget.onDownloadPressed != null
                        ? () => widget.onDownloadPressed!(message)
                        : null,
                    onCancelDownload: widget.onCancelDownload != null
                        ? () => widget.onCancelDownload!(message)
                        : null,
                    // Upload manager integration (sender side)
                    uploadState: widget.getUploadState?.call(message),
                    onRetryUpload: widget.onRetryUpload != null
                        ? () => widget.onRetryUpload!(message)
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
    if (widget.isLoading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 32,
              height: 32,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              widget.loadingText ?? 'Loading messages...',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }
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

  List<_MessageListItem> _buildItems() {
    final items = <_MessageListItem>[];
    String? lastDate;

    for (final message in widget.messages) {
      final date = message.datePortion;
      if (date != lastDate) {
        lastDate = date;
        items.add(_MessageListItem.separator(_formatDateLabel(message.dateTime)));
      }
      items.add(_MessageListItem.message(message));
    }

    return items.reversed.toList();
  }

  String _formatDateLabel(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final msgDate = DateTime(date.year, date.month, date.day);
    final difference = msgDate.difference(today).inDays;

    if (difference == 0) return 'Today';
    if (difference == -1) return 'Yesterday';
    const months = ['January', 'February', 'March', 'April', 'May', 'June',
        'July', 'August', 'September', 'October', 'November', 'December'];
    final monthName = months[date.month - 1];
    if (date.year == now.year) return '$monthName ${date.day}';
    return '$monthName ${date.day}, ${date.year}';
  }

  Widget _buildDateSeparator(ThemeData theme, String label) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 10),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0x2B525A6B),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _MessageListItem {
  final ChatMessage? message;
  final String? label;

  bool get isSeparator => label != null;

  _MessageListItem.message(this.message) : label = null;
  _MessageListItem.separator(this.label) : message = null;
}
