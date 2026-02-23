/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Message bubble widget for Telegram chat view.
 * Supports text, photos, videos, documents, GIFs, stickers, and voice notes.
 */

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:latlong2/latlong.dart';

import '../../../pages/location_picker_page.dart';
import '../../../services/file_launcher_service.dart';
import '../../../util/file_icon_helper.dart';
import '../../../widgets/voice_player_widget.dart';
import '../../shared/teleport_chat_utils.dart';
import '../models/telegram_message.dart';

class TelegramMessageBubble extends StatefulWidget {
  final TelegramMessage message;
  final String? senderName;
  final String? senderPhotoPath;

  /// Whether to show the avatar (first message in a group from the same sender).
  final bool showAvatar;

  /// Called when the user taps on media content (photo, video, document, etc.).
  final VoidCallback? onMediaTap;

  /// Called when the user selects "Reply" from the context menu.
  final void Function(TelegramMessage)? onReply;

  /// Called when the user selects "Delete" from the context menu.
  final void Function(TelegramMessage)? onDelete;

  /// Called when the user taps a reaction emoji.
  final void Function(TelegramMessage, String emoji)? onReact;

  /// Called to download a voice note file; returns the local path on success.
  final Future<String?> Function(TelegramMessage)? onDownloadVoice;

  /// Called when the user taps the reply preview bar to scroll to the original message.
  final void Function(int messageId)? onReplyPreviewTap;

  const TelegramMessageBubble({
    super.key,
    required this.message,
    this.senderName,
    this.senderPhotoPath,
    this.showAvatar = false,
    this.onMediaTap,
    this.onReply,
    this.onDelete,
    this.onReact,
    this.onDownloadVoice,
    this.onReplyPreviewTap,
  });

  static const _emojiFontFallback = [
    'Noto Color Emoji',
    'Apple Color Emoji',
    'Segoe UI Emoji',
    'sans-serif-emoji',
  ];
  static const _telegramBlue = Color(0xFF0088CC);
  static const _avatarSize = 32.0;
  static const _avatarGutter = _avatarSize + 8;
  /// Absolute cap so bubbles stay narrow on wide screens.
  static const _maxBubbleWidth = 440.0;

  /// Deterministic color for a sender name (consistent across messages).
  static Color _senderColor(String name) => teleportSenderColor(name);

  @override
  State<TelegramMessageBubble> createState() => _TelegramMessageBubbleState();
}

class _TelegramMessageBubbleState extends State<TelegramMessageBubble> {
  static final _urlRegex = RegExp(
    r'(https?://[^\s<>\[\]{}|\\^`]+|www\.[^\s<>\[\]{}|\\^`]+)',
    caseSensitive: false,
  );

  static const _quickEmojis = ['👍', '❤️', '🔥', '😂', '😮', '😢'];

  bool _isHovered = false;
  List<TapGestureRecognizer> _linkRecognizers = [];

  @override
  void dispose() {
    for (final r in _linkRecognizers) {
      r.dispose();
    }
    super.dispose();
  }

  String _formatTime(DateTime date) {
    final local = date.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  String _formatDuration(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  String _contentLabel() {
    switch (widget.message.contentType) {
      case TelegramMessageContentType.photo:
      case TelegramMessageContentType.video:
      case TelegramMessageContentType.document:
      case TelegramMessageContentType.voiceNote:
      case TelegramMessageContentType.sticker:
      case TelegramMessageContentType.animation:
      case TelegramMessageContentType.location:
      case TelegramMessageContentType.venue:
      case TelegramMessageContentType.videoNote:
      case TelegramMessageContentType.contact:
      case TelegramMessageContentType.audio:
      case TelegramMessageContentType.poll:
      case TelegramMessageContentType.call:
      case TelegramMessageContentType.pinMessage:
      case TelegramMessageContentType.text:
        return '';
      case TelegramMessageContentType.other:
        return '[Unsupported message]';
    }
  }

  /// Whether this message has renderable media (from memory bytes or local path).
  bool get _hasMedia =>
      widget.message.media?.localPath != null ||
      widget.message.media?.mediaBytes != null;

  /// Whether this is a voice note with media metadata (may not have localPath yet).
  bool get _isVoiceWithMedia =>
      widget.message.contentType == TelegramMessageContentType.voiceNote &&
      widget.message.media != null &&
      widget.message.media!.localPath == null;

  /// Build text with clickable URL links.
  Widget _buildLinkedText(String text, TextStyle? baseStyle) {
    // Dispose previous recognizers
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
      // Add plain text before this URL
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

    // Add remaining plain text
    if (lastEnd < text.length) {
      spans.add(TextSpan(text: text.substring(lastEnd)));
    }

    return Text.rich(
      TextSpan(style: baseStyle, children: spans),
    );
  }

  /// Show the three-dot context menu anchored to a widget's position.
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
                              TelegramMessageBubble._emojiFontFallback,
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

  /// Build the hover action bar (three-dot button) shown on mouse hover.
  Widget _buildHoverActions(ThemeData theme) {
    if (!_isHovered) return const SizedBox.shrink();
    return Builder(
      builder: (btnContext) => Material(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
        elevation: 2,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _showContextMenu(btnContext),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(
              Icons.more_vert,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  /// Build the reactions row showing emoji + count chips below the bubble.
  Widget _buildReactionsRow(ThemeData theme) {
    final reactions = widget.message.reactions;
    if (reactions.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(left: 14, right: 14, bottom: 6),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: reactions.map((r) {
          return InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: widget.onReact != null
                ? () => widget.onReact!(widget.message, r.emoji)
                : null,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: r.isChosen
                    ? TelegramMessageBubble._telegramBlue.withValues(alpha: 0.2)
                    : theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: r.isChosen
                      ? TelegramMessageBubble._telegramBlue
                      : theme.colorScheme.outlineVariant,
                  width: 0.5,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    r.emoji,
                    style: const TextStyle(
                      fontSize: 14,
                      fontFamilyFallback:
                          TelegramMessageBubble._emojiFontFallback,
                    ),
                  ),
                  const SizedBox(width: 3),
                  Text(
                    '${r.count}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: r.isChosen
                          ? TelegramMessageBubble._telegramBlue
                          : theme.colorScheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  /// Build the reply preview bar (colored left border + sender + text).
  Widget _buildReplyPreview(ThemeData theme) {
    final msg = widget.message;
    if (msg.replyToMessageId == null) return const SizedBox.shrink();

    final senderName = msg.replyToSenderName ?? 'Unknown';
    final previewText = msg.replyToText ?? '';
    final senderColor = TelegramMessageBubble._senderColor(senderName);

    return GestureDetector(
      onTap: () => widget.onReplyPreviewTap?.call(msg.replyToMessageId!),
      child: Padding(
        padding: const EdgeInsets.only(left: 14, right: 14, top: 6),
        child: Container(
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: senderColor, width: 2)),
          ),
          padding: const EdgeInsets.only(left: 8, top: 2, bottom: 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                senderName,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: senderColor,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (previewText.isNotEmpty)
                Text(
                  previewText,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
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
  Widget _buildForwardHeader(ThemeData theme) {
    final name = widget.message.forwardSenderName;
    if (name == null || name.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(left: 14, right: 14, top: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.reply, size: 14,
              color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              'Forwarded from $name',
              style: theme.textTheme.labelSmall?.copyWith(
                fontStyle: FontStyle.italic,
                color: theme.colorScheme.onSurfaceVariant,
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
    final theme = Theme.of(context);
    final isOut = widget.message.isOutgoing;

    final text = widget.message.text ?? _contentLabel();
    final hasText = text.isNotEmpty;
    final hasMedia = _hasMedia;

    // Show placeholder labels for media types without a local path yet
    if (!hasText && !hasMedia) {
      final fallback = _fallbackLabel();
      if (fallback == null) return const SizedBox.shrink();
    }

    if (isOut) {
      return _buildOutgoingBubble(context, theme, text, hasText, hasMedia);
    }

    return _buildIncomingBubble(context, theme, text, hasText, hasMedia);
  }

  /// Fallback label when media hasn't downloaded yet.
  String? _fallbackLabel() {
    switch (widget.message.contentType) {
      case TelegramMessageContentType.video:
        return '[Video]';
      case TelegramMessageContentType.document:
        return '[Document]';
      case TelegramMessageContentType.voiceNote:
        return '[Voice message]';
      case TelegramMessageContentType.sticker:
        return '[Sticker]';
      case TelegramMessageContentType.animation:
        return '[GIF]';
      case TelegramMessageContentType.videoNote:
        return '[Video message]';
      case TelegramMessageContentType.audio:
        return '[Audio]';
      case TelegramMessageContentType.location:
        return '[Location]';
      case TelegramMessageContentType.venue:
        return '[Venue]';
      case TelegramMessageContentType.contact:
        return '[Contact]';
      case TelegramMessageContentType.poll:
        return '[Poll]';
      case TelegramMessageContentType.call:
        return '[Call]';
      case TelegramMessageContentType.pinMessage:
        return null;
      case TelegramMessageContentType.other:
        return '[Unsupported message]';
      default:
        return null;
    }
  }

  Widget _buildOutgoingBubble(
    BuildContext context,
    ThemeData theme,
    String text,
    bool hasText,
    bool hasMedia,
  ) {
    final screenMax = MediaQuery.of(context).size.width * 0.75;
    final maxWidth = screenMax < TelegramMessageBubble._maxBubbleWidth
        ? screenMax
        : TelegramMessageBubble._maxBubbleWidth;

    // Stickers: no bubble background
    if (widget.message.contentType == TelegramMessageContentType.sticker &&
        hasMedia) {
      return Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
          child: _buildSticker(theme),
        ),
      );
    }

    // Video notes: circular clip without bubble background
    if (widget.message.contentType == TelegramMessageContentType.videoNote &&
        hasMedia) {
      return Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
          child: GestureDetector(
            onTap: widget.onMediaTap,
            child: _buildVideoNote(theme),
          ),
        ),
      );
    }

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
              decoration: BoxDecoration(
                color: TelegramMessageBubble._telegramBlue.withValues(alpha: 0.15),
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: const Radius.circular(16),
                  bottomRight: Radius.zero,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: IntrinsicWidth(
                child: _buildBubbleContent(theme, text, hasText, hasMedia, true),
              ),
            ),
            // Hover action bar — positioned top-left of outgoing bubble
            Positioned(
              top: 0,
              left: -4,
              child: _buildHoverActions(theme),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildIncomingBubble(
    BuildContext context,
    ThemeData theme,
    String text,
    bool hasText,
    bool hasMedia,
  ) {
    final screenMax = MediaQuery.of(context).size.width * 0.75 -
        TelegramMessageBubble._avatarGutter;
    final maxWidth = screenMax < TelegramMessageBubble._maxBubbleWidth
        ? screenMax
        : TelegramMessageBubble._maxBubbleWidth;

    // Stickers: no bubble background
    if (widget.message.contentType == TelegramMessageContentType.sticker &&
        hasMedia) {
      return Padding(
        padding:
            const EdgeInsets.only(left: 12, right: 12, top: 1, bottom: 1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (widget.showAvatar)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _buildAvatar(theme),
              )
            else
              SizedBox(width: TelegramMessageBubble._avatarGutter),
            _buildSticker(theme),
          ],
        ),
      );
    }

    // Video notes: circular clip without bubble background
    if (widget.message.contentType == TelegramMessageContentType.videoNote &&
        hasMedia) {
      return Padding(
        padding:
            const EdgeInsets.only(left: 12, right: 12, top: 1, bottom: 1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (widget.showAvatar)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _buildAvatar(theme),
              )
            else
              SizedBox(width: TelegramMessageBubble._avatarGutter),
            GestureDetector(
              onTap: widget.onMediaTap,
              child: _buildVideoNote(theme),
            ),
          ],
        ),
      );
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Padding(
        padding: const EdgeInsets.only(left: 12, right: 12, top: 1, bottom: 1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Avatar or spacer
            if (widget.showAvatar)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _buildAvatar(theme),
              )
            else
              SizedBox(width: TelegramMessageBubble._avatarGutter),
            // Bubble with hover overlay
            Flexible(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    constraints: BoxConstraints(maxWidth: maxWidth),
                    margin: const EdgeInsets.symmetric(vertical: 2),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(16),
                        topRight: const Radius.circular(16),
                        bottomLeft: Radius.zero,
                        bottomRight: const Radius.circular(16),
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: IntrinsicWidth(
                      child: _buildBubbleContent(
                          theme, text, hasText, hasMedia, false),
                    ),
                  ),
                  // Hover action bar — positioned top-right of incoming bubble
                  Positioned(
                    top: 0,
                    right: -4,
                    child: _buildHoverActions(theme),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBubbleContent(
    ThemeData theme,
    String text,
    bool hasText,
    bool hasMedia,
    bool isOut,
  ) {
    final hasForward = widget.message.forwardSenderName != null &&
        widget.message.forwardSenderName!.isNotEmpty;
    final hasReply = widget.message.replyToMessageId != null;
    final isEdited = widget.message.editDate != null;

    // Card types store structured data in text — suppress raw text display
    const cardTypes = {
      TelegramMessageContentType.location,
      TelegramMessageContentType.venue,
      TelegramMessageContentType.contact,
      TelegramMessageContentType.poll,
    };
    final isCardType = cardTypes.contains(widget.message.contentType);
    final showText = hasText && !isCardType;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Sender name
        if (widget.senderName != null && !isOut)
          Padding(
            padding: const EdgeInsets.only(left: 14, right: 14, top: 8),
            child: Text(
              widget.senderName!,
              style: theme.textTheme.labelSmall?.copyWith(
                color: TelegramMessageBubble._senderColor(widget.senderName!),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        // Forward header
        if (hasForward) _buildForwardHeader(theme),
        // Reply preview
        if (hasReply) _buildReplyPreview(theme),
        // Card renderers for structured content types
        if (widget.message.contentType == TelegramMessageContentType.location)
          _buildLocationCard(theme),
        if (widget.message.contentType == TelegramMessageContentType.venue)
          _buildVenueCard(theme),
        if (widget.message.contentType == TelegramMessageContentType.contact)
          _buildContactCard(theme),
        if (widget.message.contentType == TelegramMessageContentType.poll)
          _buildPollCard(theme),
        // Media content (voice notes render even without localPath for download)
        if (hasMedia || _isVoiceWithMedia) _buildMediaContent(theme),
        // Fallback label when media not yet downloaded
        if (!hasMedia && !_isVoiceWithMedia && !hasText && _fallbackLabel() != null)
          Padding(
            padding: const EdgeInsets.only(left: 14, right: 14, top: 8),
            child: Text(
              _fallbackLabel()!,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontStyle: FontStyle.italic,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        // Text + timestamp
        Padding(
          padding: EdgeInsets.only(
            left: 14,
            right: 14,
            top: hasMedia
                ? 4
                : (widget.senderName != null && !isOut ? 2 : 8),
            bottom: widget.message.reactions.isEmpty ? 8 : 4,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (showText)
                _buildLinkedText(text, theme.textTheme.bodyMedium),
              const SizedBox(height: 2),
              Align(
                alignment: Alignment.bottomRight,
                child: Text(
                  '${isEdited ? 'edited ' : ''}${_formatTime(widget.message.date)}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 10,
                  ),
                ),
              ),
            ],
          ),
        ),
        // Reactions row
        _buildReactionsRow(theme),
      ],
    );
  }

  /// Dispatch to the correct inline media renderer based on content type.
  Widget _buildMediaContent(ThemeData theme) {
    final type = widget.message.contentType;
    Widget media;

    switch (type) {
      case TelegramMessageContentType.photo:
        media = _buildPhoto(theme);
        break;
      case TelegramMessageContentType.video:
        media = _buildVideo(theme);
        break;
      case TelegramMessageContentType.animation:
        media = _buildAnimation(theme);
        break;
      case TelegramMessageContentType.document:
        media = _buildDocument(theme);
        break;
      case TelegramMessageContentType.voiceNote:
        media = _buildVoiceNote(theme);
        break;
      case TelegramMessageContentType.videoNote:
        media = _buildVideoNote(theme);
        break;
      case TelegramMessageContentType.audio:
        media = _buildAudioCard(theme);
        break;
      default:
        return const SizedBox.shrink();
    }

    // Voice notes handle their own tap (play/pause); skip wrapping in onMediaTap
    if (widget.onMediaTap != null &&
        type != TelegramMessageContentType.voiceNote &&
        type != TelegramMessageContentType.audio) {
      return GestureDetector(onTap: widget.onMediaTap, child: media);
    }
    return media;
  }

  Widget _buildPhoto(ThemeData theme) {
    final media = widget.message.media!;
    final bytes = media.mediaBytes;

    final errorWidget = Container(
      width: 280,
      height: 150,
      color: theme.colorScheme.surfaceContainerHighest,
      child: Icon(Icons.broken_image,
          color: theme.colorScheme.onSurfaceVariant),
    );

    return ConstrainedBox(
      constraints: const BoxConstraints(
        maxWidth: 280,
        maxHeight: 300,
      ),
      child: bytes != null
          ? Image.memory(
              bytes,
              fit: BoxFit.cover,
              width: 280,
              errorBuilder: (_, __, ___) => errorWidget,
            )
          : Image.file(
              File(media.localPath!),
              fit: BoxFit.cover,
              width: 280,
              errorBuilder: (_, __, ___) => errorWidget,
            ),
    );
  }

  Widget _buildVideo(ThemeData theme) {
    final duration = widget.message.media?.duration;
    final thumbnail = widget.message.media?.thumbnail;
    final miniData = widget.message.media?.minithumbnailData;

    return ConstrainedBox(
      constraints: const BoxConstraints(
        maxWidth: 280,
        maxHeight: 300,
      ),
      child: Container(
        width: 280,
        height: 160,
        color: Colors.black87,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Thumbnail preview (prefer high-quality thumbnail, fall back to minithumbnail)
            if (thumbnail != null)
              Positioned.fill(
                child: Image.memory(
                  thumbnail,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              )
            else if (miniData != null)
              Positioned.fill(
                child: Image.memory(
                  base64Decode(miniData),
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            // Play icon
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.85),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.play_arrow,
                  color: Colors.black87, size: 32),
            ),
            // Duration badge
            if (duration != null)
              Positioned(
                bottom: 8,
                right: 8,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    _formatDuration(duration),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildAnimation(ThemeData theme) {
    final media = widget.message.media!;
    final bytes = media.mediaBytes;

    final errorWidget = Container(
      width: 280,
      height: 150,
      color: theme.colorScheme.surfaceContainerHighest,
      child: Icon(Icons.gif,
          color: theme.colorScheme.onSurfaceVariant, size: 48),
    );

    return ConstrainedBox(
      constraints: const BoxConstraints(
        maxWidth: 280,
        maxHeight: 300,
      ),
      child: Stack(
        children: [
          bytes != null
              ? Image.memory(
                  bytes,
                  fit: BoxFit.cover,
                  width: 280,
                  errorBuilder: (_, __, ___) => errorWidget,
                )
              : Image.file(
                  File(media.localPath!),
                  fit: BoxFit.cover,
                  width: 280,
                  errorBuilder: (_, __, ___) => errorWidget,
                ),
          // GIF badge
          Positioned(
            bottom: 8,
            left: 8,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                'GIF',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDocument(ThemeData theme) {
    final fileName = widget.message.media?.fileName ?? 'Document';
    final icon = FileIconHelper.getIconForFile(fileName);

    return Padding(
      padding: const EdgeInsets.only(left: 14, right: 14, top: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: TelegramMessageBubble._telegramBlue
                  .withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon,
                color: TelegramMessageBubble._telegramBlue, size: 22),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              fileName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVoiceNote(ThemeData theme) {
    final media = widget.message.media!;
    final localPath = media.localPath;
    final hasLocal = localPath != null;

    return Padding(
      padding: const EdgeInsets.only(left: 6, right: 6, top: 6),
      child: VoicePlayerWidget(
        filePath: localPath ?? '',
        durationSeconds: media.duration,
        isLocal: hasLocal,
        onDownloadRequested: hasLocal
            ? null
            : () async {
                return widget.onDownloadVoice?.call(widget.message);
              },
      ),
    );
  }

  Widget _buildVideoNote(ThemeData theme) {
    final media = widget.message.media!;
    final localPath = media.localPath;
    final thumbnail = media.thumbnail;
    final miniData = media.minithumbnailData;
    final duration = media.duration;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipOval(
          child: SizedBox(
            width: 200,
            height: 200,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Thumbnail or placeholder — prefer high-quality thumbnail
                if (localPath != null)
                  Image.file(
                    File(localPath),
                    fit: BoxFit.cover,
                    width: 200,
                    height: 200,
                    errorBuilder: (_, __, ___) => Container(
                      color: Colors.black54,
                      child: const Icon(Icons.videocam, color: Colors.white54, size: 48),
                    ),
                  )
                else if (thumbnail != null)
                  Image.memory(
                    thumbnail,
                    fit: BoxFit.cover,
                    width: 200,
                    height: 200,
                    errorBuilder: (_, __, ___) => Container(
                      color: Colors.black54,
                    ),
                  )
                else if (miniData != null)
                  Image.memory(
                    base64Decode(miniData),
                    fit: BoxFit.cover,
                    width: 200,
                    height: 200,
                    errorBuilder: (_, __, ___) => Container(
                      color: Colors.black54,
                    ),
                  )
                else
                  Container(
                    color: Colors.black54,
                    child: const Icon(Icons.videocam, color: Colors.white54, size: 48),
                  ),
                // Play icon overlay
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.85),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.play_arrow,
                      color: Colors.black87, size: 28),
                ),
                // Duration badge
                if (duration != null)
                  Positioned(
                    bottom: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        _formatDuration(duration),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAudioCard(ThemeData theme) {
    final media = widget.message.media!;
    final fileName = media.fileName ?? 'Audio';
    final duration = media.duration;

    return Padding(
      padding: const EdgeInsets.only(left: 14, right: 14, top: 8),
      child: GestureDetector(
        onTap: () {
          if (media.localPath != null) {
            FileLauncherService().openFile(media.localPath!);
          } else {
            widget.onMediaTap?.call();
          }
        },
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: TelegramMessageBubble._telegramBlue
                    .withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.music_note,
                  color: TelegramMessageBubble._telegramBlue, size: 22),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    fileName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (duration != null)
                    Text(
                      _formatDuration(duration),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Parse "lat, lng" coordinate string into LatLng, or null.
  LatLng? _parseCoords(String coords) {
    final parts = coords.split(',').map((s) => s.trim()).toList();
    if (parts.length != 2) return null;
    final lat = double.tryParse(parts[0]);
    final lng = double.tryParse(parts[1]);
    if (lat == null || lng == null) return null;
    return LatLng(lat, lng);
  }

  /// Open the internal map viewer at the given coordinates.
  void _openLocationViewer(LatLng position) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LocationPickerPage(
          initialPosition: position,
          viewOnly: true,
        ),
      ),
    );
  }

  Widget _buildLocationCard(ThemeData theme) {
    final text = widget.message.text ?? '';
    final isLive = text.endsWith('|live');
    final coords = isLive ? text.replaceAll('|live', '') : text;
    final thumbnail = widget.message.media?.thumbnail;

    return GestureDetector(
      onTap: () {
        final position = _parseCoords(coords);
        if (position != null) _openLocationViewer(position);
      },
      child: thumbnail != null
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(12),
                    topRight: Radius.circular(12),
                  ),
                  child: Image.memory(
                    thumbnail,
                    width: 300,
                    height: 200,
                    fit: BoxFit.cover,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(
                      left: 14, right: 14, top: 6, bottom: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.location_on,
                          color: TelegramMessageBubble._telegramBlue,
                          size: 16),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          isLive ? 'Live location' : coords,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            )
          : Padding(
              padding: const EdgeInsets.only(left: 14, right: 14, top: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: TelegramMessageBubble._telegramBlue
                          .withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(Icons.location_on,
                        color: TelegramMessageBubble._telegramBlue, size: 22),
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isLive ? 'Live location' : 'Location shared',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Text(
                          coords,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildVenueCard(ThemeData theme) {
    final text = widget.message.text ?? '';
    final lines = text.split('\n');
    final title = lines.isNotEmpty ? lines[0] : '';
    final address = lines.length > 1 ? lines[1] : '';
    final coords = lines.length > 2 ? lines[2] : '';
    final thumbnail = widget.message.media?.thumbnail;

    return GestureDetector(
      onTap: () {
        final position = _parseCoords(coords);
        if (position != null) _openLocationViewer(position);
      },
      child: thumbnail != null
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(12),
                    topRight: Radius.circular(12),
                  ),
                  child: Image.memory(
                    thumbnail,
                    width: 300,
                    height: 200,
                    fit: BoxFit.cover,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(
                      left: 14, right: 14, top: 6, bottom: 2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (address.isNotEmpty)
                        Text(
                          address,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
              ],
            )
          : Padding(
              padding: const EdgeInsets.only(left: 14, right: 14, top: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: TelegramMessageBubble._telegramBlue
                          .withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(Icons.location_on,
                        color: TelegramMessageBubble._telegramBlue, size: 22),
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (address.isNotEmpty)
                          Text(
                            address,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        Text(
                          coords,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildContactCard(ThemeData theme) {
    final text = widget.message.text ?? '';
    final lines = text.split('\n');
    final name = lines.isNotEmpty ? lines[0] : '';
    final phone = lines.length > 1 ? lines[1] : '';

    return Padding(
      padding: const EdgeInsets.only(left: 14, right: 14, top: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: TelegramMessageBubble._telegramBlue
                  .withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(Icons.person,
                color: TelegramMessageBubble._telegramBlue, size: 22),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (phone.isNotEmpty)
                  Text(
                    phone,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPollCard(ThemeData theme) {
    final text = widget.message.text ?? '';
    final lines = text.split('\n');
    final question = lines.isNotEmpty ? lines[0] : '';
    final options = lines.length > 1 ? lines.sublist(1) : <String>[];

    // Parse max votes for proportion bars
    int maxVotes = 0;
    final parsedOptions = <(String, int)>[];
    for (final opt in options) {
      final colonIdx = opt.lastIndexOf(':');
      if (colonIdx > 0) {
        final label = opt.substring(0, colonIdx).trim();
        final count = int.tryParse(opt.substring(colonIdx + 1).trim()) ?? 0;
        parsedOptions.add((label, count));
        if (count > maxVotes) maxVotes = count;
      } else {
        parsedOptions.add((opt.trim(), 0));
      }
    }

    return Padding(
      padding: const EdgeInsets.only(left: 14, right: 14, top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.poll,
                  color: TelegramMessageBubble._telegramBlue, size: 20),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  question,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ...parsedOptions.map((opt) {
            final proportion = maxVotes > 0 ? opt.$2 / maxVotes : 0.0;
            return Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          opt.$1,
                          style: theme.textTheme.bodySmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${opt.$2}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: proportion,
                      minHeight: 4,
                      backgroundColor: theme.colorScheme.surfaceContainerHighest,
                      valueColor: AlwaysStoppedAnimation<Color>(
                          TelegramMessageBubble._telegramBlue),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildSticker(ThemeData theme) {
    final media = widget.message.media!;
    final bytes = media.mediaBytes;

    final errorWidget = Icon(
      Icons.emoji_emotions_outlined,
      color: theme.colorScheme.onSurfaceVariant,
      size: 64,
    );

    return ConstrainedBox(
      constraints: const BoxConstraints(
        maxWidth: 160,
        maxHeight: 160,
      ),
      child: bytes != null
          ? Image.memory(
              bytes,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => errorWidget,
            )
          : Image.file(
              File(media.localPath!),
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => errorWidget,
            ),
    );
  }

  Widget _buildAvatar(ThemeData theme) {
    if (widget.senderPhotoPath != null) {
      final file = File(widget.senderPhotoPath!);
      if (file.existsSync()) {
        return CircleAvatar(
          radius: TelegramMessageBubble._avatarSize / 2,
          backgroundImage: FileImage(file),
        );
      }
    }

    // Fallback: colored circle with initial
    final name = widget.senderName ?? '?';
    return CircleAvatar(
      radius: TelegramMessageBubble._avatarSize / 2,
      backgroundColor:
          TelegramMessageBubble._senderColor(name).withValues(alpha: 0.2),
      child: Text(
        name.isNotEmpty ? name[0].toUpperCase() : '?',
        style: TextStyle(
          color: TelegramMessageBubble._senderColor(name),
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
      ),
    );
  }
}

/// Day separator — delegates to the shared TeleportDateSeparator.
typedef TelegramDateSeparator = TeleportDateSeparator;

/// Service message widget for calls and pinned messages.
/// Rendered as a centered pill (like date separators) with an icon + text.
class TelegramServiceMessage extends StatelessWidget {
  final TelegramMessage message;
  final String? senderName;

  const TelegramServiceMessage({
    super.key,
    required this.message,
    this.senderName,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isCall = message.contentType == TelegramMessageContentType.call;

    final IconData icon;
    final String label;

    if (isCall) {
      final text = message.text ?? 'Call';
      final isMissed = text.startsWith('Missed');
      icon = isMissed ? Icons.phone_missed : Icons.phone;
      label = text;
    } else {
      // pinMessage
      icon = Icons.push_pin;
      final name = senderName ?? 'Someone';
      label = '$name pinned a message';
    }

    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest
              .withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 14,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
