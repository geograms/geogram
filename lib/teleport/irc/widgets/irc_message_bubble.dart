/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * IRC message bubble widget — dark-mode style matching Telegram/Signal bubbles.
 * Outgoing: dark teal-blue #2B5278, incoming: dark blue-gray #1E2D3D.
 * Text is selectable (mouse on desktop, long-press on mobile).
 * URLs starting with http:// or https:// are rendered as clickable links.
 */

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../shared/teleport_chat_utils.dart';
import '../models/irc_message.dart';

/// Regex matching http:// and https:// URLs.
final _urlRegex = RegExp(
  r"https?://[^\s<>\[\]""')+]+",
  caseSensitive: false,
);

/// Build a list of TextSpans with clickable URL links.
List<TextSpan> _buildLinkedText(String text, TextStyle baseStyle) {
  final spans = <TextSpan>[];
  int lastEnd = 0;

  for (final match in _urlRegex.allMatches(text)) {
    // Text before the URL
    if (match.start > lastEnd) {
      spans.add(TextSpan(text: text.substring(lastEnd, match.start)));
    }
    // The URL itself — clickable, underlined, light blue
    final url = match.group(0)!;
    spans.add(TextSpan(
      text: url,
      style: baseStyle.copyWith(
        color: const Color(0xFF64B5F6),
        decoration: TextDecoration.underline,
        decorationColor: const Color(0xFF64B5F6),
      ),
      recognizer: TapGestureRecognizer()
        ..onTap = () {
          final uri = Uri.tryParse(url);
          if (uri != null) launchUrl(uri, mode: LaunchMode.externalApplication);
        },
    ));
    lastEnd = match.end;
  }

  // Remaining text after last URL
  if (lastEnd < text.length) {
    spans.add(TextSpan(text: text.substring(lastEnd)));
  }

  // No URLs found — return plain text span
  if (spans.isEmpty) {
    spans.add(TextSpan(text: text));
  }

  return spans;
}

class IrcMessageBubble extends StatelessWidget {
  final IrcMessage message;
  final bool showSender;

  const IrcMessageBubble({
    super.key,
    required this.message,
    this.showSender = true,
  });

  static const _outgoingColor = Color(0xFF2B5278);
  static const _incomingColor = Color(0xFF1E2D3D);

  @override
  Widget build(BuildContext context) {
    final isOut = message.isOutgoing;
    final isAction = message.type == IrcMessageType.action;
    final displayText = isAction
        ? '* ${message.sender} ${message.text}'
        : message.text;

    final textStyle = TextStyle(
      color: Colors.white,
      fontSize: 15,
      fontStyle: isAction ? FontStyle.italic : FontStyle.normal,
    );

    return Align(
      alignment: isOut ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isOut ? _outgoingColor : _incomingColor,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(12),
            topRight: const Radius.circular(12),
            bottomLeft: Radius.circular(isOut ? 12 : 4),
            bottomRight: Radius.circular(isOut ? 4 : 12),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Sender name
            if (showSender && !isOut)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  message.sender,
                  style: TextStyle(
                    color: teleportSenderColor(message.sender),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            // Message text — selectable with clickable URLs
            SelectableText.rich(
              TextSpan(
                style: textStyle,
                children: _buildLinkedText(displayText, textStyle),
              ),
            ),
            // Timestamp
            const SizedBox(height: 2),
            Text(
              _formatTime(message.timestamp),
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime utcDate) {
    final local = utcDate.toLocal();
    final h = local.hour.toString().padLeft(2, '0');
    final m = local.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

/// Centered system message (join/part/quit) — not a bubble.
class IrcSystemMessage extends StatelessWidget {
  final IrcMessage message;

  const IrcSystemMessage({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
        child: Text(
          message.text,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
            fontSize: 12,
            fontStyle: FontStyle.italic,
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
