/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Message bubble widget for Telegram chat view.
 * Supports text, photos, videos, documents, GIFs, stickers, and voice notes.
 */

import 'dart:io';

import 'package:flutter/material.dart';

import '../../../util/file_icon_helper.dart';
import '../models/telegram_message.dart';

class TelegramMessageBubble extends StatelessWidget {
  final TelegramMessage message;
  final String? senderName;
  final String? senderPhotoPath;

  /// Whether to show the avatar (first message in a group from the same sender).
  final bool showAvatar;

  /// Called when the user taps on media content (photo, video, document, etc.).
  final VoidCallback? onMediaTap;

  const TelegramMessageBubble({
    super.key,
    required this.message,
    this.senderName,
    this.senderPhotoPath,
    this.showAvatar = false,
    this.onMediaTap,
  });

  static const _telegramBlue = Color(0xFF0088CC);
  static const _avatarSize = 32.0;
  static const _avatarGutter = _avatarSize + 8;
  /// Absolute cap so bubbles stay narrow on wide screens.
  static const _maxBubbleWidth = 440.0;

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
    switch (message.contentType) {
      case TelegramMessageContentType.photo:
        return '';
      case TelegramMessageContentType.video:
        return '';
      case TelegramMessageContentType.document:
        return '';
      case TelegramMessageContentType.voiceNote:
        return '';
      case TelegramMessageContentType.sticker:
        return '';
      case TelegramMessageContentType.animation:
        return '';
      case TelegramMessageContentType.other:
        return '[Unsupported message]';
      case TelegramMessageContentType.text:
        return '';
    }
  }

  /// Whether this message has downloadable media with a local path.
  bool get _hasMedia => message.media?.localPath != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isOut = message.isOutgoing;

    final text = message.text ?? _contentLabel();
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
    switch (message.contentType) {
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
    final maxWidth = screenMax < _maxBubbleWidth ? screenMax : _maxBubbleWidth;

    // Stickers: no bubble background
    if (message.contentType == TelegramMessageContentType.sticker && hasMedia) {
      return Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
          child: _buildSticker(theme),
        ),
      );
    }

    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        constraints: BoxConstraints(maxWidth: maxWidth),
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        decoration: BoxDecoration(
          color: _telegramBlue.withValues(alpha: 0.15),
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
    );
  }

  Widget _buildIncomingBubble(
    BuildContext context,
    ThemeData theme,
    String text,
    bool hasText,
    bool hasMedia,
  ) {
    final screenMax = MediaQuery.of(context).size.width * 0.75 - _avatarGutter;
    final maxWidth =
        screenMax < _maxBubbleWidth ? screenMax : _maxBubbleWidth;

    // Stickers: no bubble background
    if (message.contentType == TelegramMessageContentType.sticker && hasMedia) {
      return Padding(
        padding: const EdgeInsets.only(left: 12, right: 12, top: 1, bottom: 1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (showAvatar)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _buildAvatar(theme),
              )
            else
              SizedBox(width: _avatarGutter),
            _buildSticker(theme),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(left: 12, right: 12, top: 1, bottom: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // Avatar or spacer
          if (showAvatar)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _buildAvatar(theme),
            )
          else
            SizedBox(width: _avatarGutter),
          // Bubble
          Flexible(
            child: Container(
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
          ),
        ],
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Sender name
        if (senderName != null && !isOut)
          Padding(
            padding: const EdgeInsets.only(left: 14, right: 14, top: 8),
            child: Text(
              senderName!,
              style: theme.textTheme.labelSmall?.copyWith(
                color: _senderColor(senderName!),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        // Media content
        if (hasMedia) _buildMediaContent(theme),
        // Fallback label when media not yet downloaded
        if (!hasMedia && !hasText && _fallbackLabel() != null)
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
            top: hasMedia ? 4 : (senderName != null && !isOut ? 2 : 8),
            bottom: 8,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (hasText) Text(text, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 2),
              Align(
                alignment: Alignment.bottomRight,
                child: Text(
                  _formatTime(message.date),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 10,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Dispatch to the correct inline media renderer based on content type.
  Widget _buildMediaContent(ThemeData theme) {
    final type = message.contentType;
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
      default:
        return const SizedBox.shrink();
    }

    if (onMediaTap != null) {
      return GestureDetector(onTap: onMediaTap, child: media);
    }
    return media;
  }

  Widget _buildPhoto(ThemeData theme) {
    final path = message.media!.localPath!;
    final file = File(path);

    return ConstrainedBox(
      constraints: const BoxConstraints(
        maxWidth: 280,
        maxHeight: 300,
      ),
      child: Image.file(
        file,
        fit: BoxFit.cover,
        width: 280,
        errorBuilder: (_, error, stackTrace) => Container(
          width: 280,
          height: 150,
          color: theme.colorScheme.surfaceContainerHighest,
          child: Icon(Icons.broken_image,
              color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }

  Widget _buildVideo(ThemeData theme) {
    final duration = message.media?.duration;

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
            // Play icon
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.85),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.play_arrow, color: Colors.black87, size: 32),
            ),
            // Duration badge
            if (duration != null)
              Positioned(
                bottom: 8,
                right: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
    final path = message.media!.localPath!;
    final file = File(path);

    return ConstrainedBox(
      constraints: const BoxConstraints(
        maxWidth: 280,
        maxHeight: 300,
      ),
      child: Stack(
        children: [
          Image.file(
            file,
            fit: BoxFit.cover,
            width: 280,
            errorBuilder: (_, e, st) => Container(
              width: 280,
              height: 150,
              color: theme.colorScheme.surfaceContainerHighest,
              child: Icon(Icons.gif, color: theme.colorScheme.onSurfaceVariant,
                  size: 48),
            ),
          ),
          // GIF badge
          Positioned(
            bottom: 8,
            left: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
    final fileName = message.media?.fileName ?? 'Document';
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
              color: _telegramBlue.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: _telegramBlue, size: 22),
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
    final duration = message.media?.duration;

    return Padding(
      padding: const EdgeInsets.only(left: 14, right: 14, top: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: _telegramBlue.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.mic, color: _telegramBlue, size: 20),
          ),
          const SizedBox(width: 10),
          Text(
            duration != null ? _formatDuration(duration) : '--:--',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSticker(ThemeData theme) {
    final path = message.media!.localPath!;
    final file = File(path);

    return ConstrainedBox(
      constraints: const BoxConstraints(
        maxWidth: 160,
        maxHeight: 160,
      ),
      child: Image.file(
        file,
        fit: BoxFit.contain,
        errorBuilder: (_, e, st) => Icon(
          Icons.emoji_emotions_outlined,
          color: theme.colorScheme.onSurfaceVariant,
          size: 64,
        ),
      ),
    );
  }

  Widget _buildAvatar(ThemeData theme) {
    if (senderPhotoPath != null) {
      final file = File(senderPhotoPath!);
      if (file.existsSync()) {
        return CircleAvatar(
          radius: _avatarSize / 2,
          backgroundImage: FileImage(file),
        );
      }
    }

    // Fallback: colored circle with initial
    final name = senderName ?? '?';
    return CircleAvatar(
      radius: _avatarSize / 2,
      backgroundColor: _senderColor(name).withValues(alpha: 0.2),
      child: Text(
        name.isNotEmpty ? name[0].toUpperCase() : '?',
        style: TextStyle(
          color: _senderColor(name),
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
      ),
    );
  }

  /// Deterministic color for a sender name (consistent across messages).
  static Color _senderColor(String name) {
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
}

/// Day separator widget shown between messages from different dates.
class TelegramDateSeparator extends StatelessWidget {
  final DateTime date;

  const TelegramDateSeparator({super.key, required this.date});

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
    final theme = Theme.of(context);
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 12),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest
              .withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          _formatDate(date),
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
