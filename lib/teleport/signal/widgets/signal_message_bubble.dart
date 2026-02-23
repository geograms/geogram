/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Message bubble widget for Signal chat view.
 * Same dark-mode styling as Telegram bubbles:
 *   - Outgoing: dark teal-blue #2B5278
 *   - Incoming: dark blue-gray #1E2D3D
 *   - White text, asymmetric rounded corners (4px on tail side)
 *   - Sender name with 7-color palette
 *   - Reply preview bar, reactions row, day separators
 */

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../services/file_launcher_service.dart';
import '../models/signal_message.dart';

class SignalMessageBubble extends StatefulWidget {
  final SignalMessage message;
  final String? senderName;

  /// Whether to show the avatar (first message in a visual group from same sender).
  final bool showAvatar;

  /// Called when the user selects "Reply" from the context menu.
  final void Function(SignalMessage)? onReply;

  /// Called when the user selects "Delete" from the context menu.
  final void Function(SignalMessage)? onDelete;

  /// Called when the user taps a reaction emoji.
  final void Function(SignalMessage, String emoji)? onReact;

  /// Called when the user taps the reply preview bar to scroll to the quoted message.
  final void Function(int quoteTimestamp)? onQuotePreviewTap;

  const SignalMessageBubble({
    super.key,
    required this.message,
    this.senderName,
    this.showAvatar = false,
    this.onReply,
    this.onDelete,
    this.onReact,
    this.onQuotePreviewTap,
  });

  static const _emojiFontFallback = [
    'Noto Color Emoji',
    'Apple Color Emoji',
    'Segoe UI Emoji',
    'sans-serif-emoji',
  ];

  static const _signalBlue = Color(0xFF3A76F0);
  static const _outgoingColor = Color(0xFF2B5278);
  static const _incomingColor = Color(0xFF1E2D3D);
  static const _avatarSize = 32.0;
  static const _avatarGutter = _avatarSize + 8;
  static const _maxBubbleWidth = 440.0;

  /// Deterministic color for a sender name (consistent across messages).
  static Color senderColor(String name) {
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

  @override
  State<SignalMessageBubble> createState() => _SignalMessageBubbleState();
}

class _SignalMessageBubbleState extends State<SignalMessageBubble> {
  static final _urlRegex = RegExp(
    r'(https?://[^\s<>\[\]{}|\\^`]+|www\.[^\s<>\[\]{}|\\^`]+)',
    caseSensitive: false,
  );

  static const _quickEmojis = ['\u{1F44D}', '\u{2764}\u{FE0F}', '\u{1F525}', '\u{1F602}', '\u{1F62E}', '\u{1F622}'];

  bool _isHovered = false;
  List<TapGestureRecognizer> _linkRecognizers = [];

  @override
  void dispose() {
    for (final r in _linkRecognizers) {
      r.dispose();
    }
    super.dispose();
  }

  String _formatTime(int timestampMs) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestampMs);
    final local = date.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  /// Build text with clickable URL links.
  Widget _buildLinkedText(String text, TextStyle? baseStyle) {
    for (final r in _linkRecognizers) {
      r.dispose();
    }
    _linkRecognizers = [];

    final matches = _urlRegex.allMatches(text).toList();
    if (matches.isEmpty) {
      return Text(text, style: baseStyle);
    }

    final spans = <InlineSpan>[];
    int lastEnd = 0;

    for (final match in matches) {
      if (match.start > lastEnd) {
        spans.add(TextSpan(text: text.substring(lastEnd, match.start)));
      }

      final urlText = match.group(0)!;
      final launchUrl =
          urlText.startsWith('http') ? urlText : 'https://$urlText';

      final recognizer = TapGestureRecognizer()
        ..onTap = () => FileLauncherService().openUrl(launchUrl);
      _linkRecognizers.add(recognizer);

      spans.add(TextSpan(
        text: urlText,
        style: baseStyle?.copyWith(
          decoration: TextDecoration.underline,
          decorationColor: baseStyle.color,
        ),
        recognizer: recognizer,
      ));

      lastEnd = match.end;
    }

    if (lastEnd < text.length) {
      spans.add(TextSpan(text: text.substring(lastEnd)));
    }

    return Text.rich(TextSpan(style: baseStyle, children: spans));
  }

  /// Show the context menu anchored to a widget's position.
  void _showContextMenu(BuildContext anchorContext) {
    final box = anchorContext.findRenderObject() as RenderBox;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final position = RelativeRect.fromRect(
      box.localToGlobal(Offset.zero, ancestor: overlay) & box.size,
      Offset.zero & overlay.size,
    );

    final items = <PopupMenuEntry<String>>[
      // Quick emoji reaction row
      PopupMenuItem<String>(
        enabled: false,
        padding: EdgeInsets.zero,
        height: 40,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: _quickEmojis
              .map((emoji) => InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () {
                      Navigator.of(context).pop();
                      widget.onReact?.call(widget.message, emoji);
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Text(
                        emoji,
                        style: const TextStyle(
                          fontSize: 20,
                          fontFamilyFallback:
                              SignalMessageBubble._emojiFontFallback,
                        ),
                      ),
                    ),
                  ))
              .toList(),
        ),
      ),
      const PopupMenuDivider(height: 1),
      const PopupMenuItem(value: 'reply', child: Text('Reply')),
      if (widget.message.text != null)
        const PopupMenuItem(value: 'copy', child: Text('Copy')),
      if (widget.message.isOutgoing)
        const PopupMenuItem(value: 'delete', child: Text('Delete')),
    ];

    showMenu<String>(
      context: context,
      position: position,
      items: items,
    ).then((value) {
      if (value == null) return;
      switch (value) {
        case 'reply':
          widget.onReply?.call(widget.message);
          break;
        case 'copy':
          if (widget.message.text != null) {
            Clipboard.setData(ClipboardData(text: widget.message.text!));
          }
          break;
        case 'delete':
          widget.onDelete?.call(widget.message);
          break;
      }
    });
  }

  /// Build the hover action bar (three-dot button).
  Widget _buildHoverActions() {
    if (!_isHovered) return const SizedBox.shrink();
    return Builder(
      builder: (btnContext) => Material(
        color: Colors.black45,
        borderRadius: BorderRadius.circular(16),
        elevation: 2,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _showContextMenu(btnContext),
          child: const Padding(
            padding: EdgeInsets.all(4),
            child: Icon(Icons.more_vert, size: 16, color: Colors.white70),
          ),
        ),
      ),
    );
  }

  /// Build the reactions row showing emoji + count chips below the bubble.
  Widget _buildReactionsRow() {
    final reactions = widget.message.reactions;
    if (reactions.isEmpty) return const SizedBox.shrink();

    // Group reactions by emoji
    final grouped = <String, int>{};
    for (final r in reactions) {
      grouped[r.emoji] = (grouped[r.emoji] ?? 0) + 1;
    }

    return Padding(
      padding: const EdgeInsets.only(left: 14, right: 14, bottom: 6),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: grouped.entries.map((entry) {
          return InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: widget.onReact != null
                ? () => widget.onReact!(widget.message, entry.key)
                : null,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: SignalMessageBubble._signalBlue.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: SignalMessageBubble._signalBlue.withValues(alpha: 0.4),
                  width: 0.5,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    entry.key,
                    style: const TextStyle(
                      fontSize: 14,
                      fontFamilyFallback:
                          SignalMessageBubble._emojiFontFallback,
                    ),
                  ),
                  if (entry.value > 1) ...[
                    const SizedBox(width: 3),
                    Text(
                      '${entry.value}',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  /// Build the reply/quote preview bar.
  Widget _buildQuotePreview() {
    final msg = widget.message;
    if (msg.quoteTimestamp == null) return const SizedBox.shrink();

    final previewText = msg.quoteText ?? '';
    final barColor = SignalMessageBubble._signalBlue;

    return GestureDetector(
      onTap: () => widget.onQuotePreviewTap?.call(msg.quoteTimestamp!),
      child: Padding(
        padding: const EdgeInsets.only(left: 14, right: 14, top: 6),
        child: Container(
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: barColor, width: 2)),
          ),
          padding: const EdgeInsets.only(left: 8, top: 2, bottom: 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Reply',
                style: TextStyle(
                  color: barColor,
                  fontWeight: FontWeight.w600,
                  fontSize: 11,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (previewText.isNotEmpty)
                Text(
                  previewText,
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 12,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Build the "Forwarded from X" header.
  Widget _buildForwardHeader() {
    final name = widget.message.forwardSenderName;
    if (name == null || name.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(left: 14, right: 14, top: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.reply, size: 14, color: Colors.white54),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              'Forwarded from $name',
              style: const TextStyle(
                fontStyle: FontStyle.italic,
                color: Colors.white54,
                fontSize: 11,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isOut = widget.message.isOutgoing;
    final text = widget.message.text ?? '';
    final hasText = text.isNotEmpty;

    // Skip reaction-only messages (contentType == 'reaction')
    if (widget.message.contentType == 'reaction' && !hasText) {
      return const SizedBox.shrink();
    }

    if (!hasText && widget.message.attachmentCount > 0) {
      // Attachment without text — show placeholder
    }

    if (isOut) {
      return _buildOutgoingBubble(context, text, hasText);
    }
    return _buildIncomingBubble(context, text, hasText);
  }

  Widget _buildOutgoingBubble(BuildContext context, String text, bool hasText) {
    final screenMax = MediaQuery.of(context).size.width * 0.75;
    final maxWidth = screenMax < SignalMessageBubble._maxBubbleWidth
        ? screenMax
        : SignalMessageBubble._maxBubbleWidth;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Align(
        alignment: Alignment.centerRight,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              constraints: BoxConstraints(maxWidth: maxWidth),
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
              decoration: const BoxDecoration(
                color: SignalMessageBubble._outgoingColor,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(16),
                  topRight: Radius.circular(16),
                  bottomLeft: Radius.circular(16),
                  bottomRight: Radius.circular(4),
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: IntrinsicWidth(
                child: _buildBubbleContent(text, hasText, true),
              ),
            ),
            Positioned(
              top: 0,
              left: -4,
              child: _buildHoverActions(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildIncomingBubble(BuildContext context, String text, bool hasText) {
    final screenMax = MediaQuery.of(context).size.width * 0.75 -
        SignalMessageBubble._avatarGutter;
    final maxWidth = screenMax < SignalMessageBubble._maxBubbleWidth
        ? screenMax
        : SignalMessageBubble._maxBubbleWidth;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Padding(
        padding:
            const EdgeInsets.only(left: 12, right: 12, top: 1, bottom: 1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Avatar or spacer
            if (widget.showAvatar)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _buildAvatar(),
              )
            else
              const SizedBox(width: SignalMessageBubble._avatarGutter),
            // Bubble with hover overlay
            Flexible(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    constraints: BoxConstraints(maxWidth: maxWidth),
                    margin: const EdgeInsets.symmetric(vertical: 2),
                    decoration: const BoxDecoration(
                      color: SignalMessageBubble._incomingColor,
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(16),
                        topRight: Radius.circular(16),
                        bottomLeft: Radius.circular(4),
                        bottomRight: Radius.circular(16),
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: IntrinsicWidth(
                      child: _buildBubbleContent(text, hasText, false),
                    ),
                  ),
                  Positioned(
                    top: 0,
                    right: -4,
                    child: _buildHoverActions(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBubbleContent(String text, bool hasText, bool isOut) {
    final hasForward = widget.message.forwardSenderName != null &&
        widget.message.forwardSenderName!.isNotEmpty;
    final hasQuote = widget.message.quoteTimestamp != null;
    final isEdited = widget.message.editTimestamp != null;
    final hasAttachment = widget.message.attachmentCount > 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Sender name
        if (widget.senderName != null && !isOut)
          Padding(
            padding: const EdgeInsets.only(left: 14, right: 14, top: 8),
            child: Text(
              widget.senderName!,
              style: TextStyle(
                color: SignalMessageBubble.senderColor(widget.senderName!),
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ),
        // Forward header
        if (hasForward) _buildForwardHeader(),
        // Reply/quote preview
        if (hasQuote) _buildQuotePreview(),
        // Attachment placeholder
        if (hasAttachment && !hasText)
          Padding(
            padding: const EdgeInsets.only(left: 14, right: 14, top: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.attach_file,
                    size: 16, color: Colors.white.withValues(alpha: 0.7)),
                const SizedBox(width: 4),
                Text(
                  widget.message.attachmentCount == 1
                      ? '[Attachment]'
                      : '[${widget.message.attachmentCount} attachments]',
                  style: TextStyle(
                    fontStyle: FontStyle.italic,
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        // Text + timestamp
        Padding(
          padding: EdgeInsets.only(
            left: 14,
            right: 14,
            top: (widget.senderName != null && !isOut) ? 2 : 8,
            bottom: widget.message.reactions.isEmpty ? 8 : 4,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (hasText)
                _buildLinkedText(
                  text,
                  const TextStyle(color: Colors.white, fontSize: 14),
                ),
              const SizedBox(height: 2),
              Align(
                alignment: Alignment.bottomRight,
                child: Text(
                  '${isEdited ? 'edited ' : ''}${_formatTime(widget.message.timestamp)}',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.45),
                    fontSize: 10,
                  ),
                ),
              ),
            ],
          ),
        ),
        // Reactions row
        _buildReactionsRow(),
      ],
    );
  }

  Widget _buildAvatar() {
    final name = widget.senderName ?? '?';
    final color = SignalMessageBubble.senderColor(name);
    return CircleAvatar(
      radius: SignalMessageBubble._avatarSize / 2,
      backgroundColor: color.withValues(alpha: 0.2),
      child: Text(
        name.isNotEmpty ? name[0].toUpperCase() : '?',
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
      ),
    );
  }
}

/// Day separator widget shown between messages from different dates.
class SignalDateSeparator extends StatelessWidget {
  final DateTime date;

  const SignalDateSeparator({super.key, required this.date});

  String _formatDate(DateTime utcDate) {
    final local = utcDate.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final msgDay = DateTime(local.year, local.month, local.day);

    final diff = today.difference(msgDay).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';

    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    if (local.year == now.year) {
      return '${months[local.month - 1]} ${local.day}';
    }
    return '${months[local.month - 1]} ${local.day}, ${local.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 12),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFF1A2733),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          _formatDate(date),
          style: const TextStyle(
            color: Colors.white54,
            fontWeight: FontWeight.w500,
            fontSize: 11,
          ),
        ),
      ),
    );
  }
}
