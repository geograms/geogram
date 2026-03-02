/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * APRS conversation page — chat view with reversed ListView and compose bar.
 * Shows messages for a specific 1:1 conversation or tag room.
 */

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../services/i18n_service.dart';
import '../../../services/user_location_service.dart';
import '../../shared/teleport_chat_utils.dart';
import '../aprs_message_utils.dart';
import '../aprs_service.dart';
import '../models/aprs_conversation.dart';
import '../models/aprs_packet.dart';
import '../widgets/aprs_message_bubble.dart';
import 'aprs_main_page.dart' show distanceKm, formatDistanceKm;

class AprsConversationPage extends StatefulWidget {
  final String conversationId;
  final AprsConversationType conversationType;
  final (double, double)? partnerPosition;
  final UserLocation? myLocation;

  const AprsConversationPage({
    super.key,
    required this.conversationId,
    required this.conversationType,
    this.partnerPosition,
    this.myLocation,
  });

  @override
  State<AprsConversationPage> createState() => _AprsConversationPageState();
}

class _AprsConversationPageState extends State<AprsConversationPage> {
  final TextEditingController _textController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  StreamSubscription<AprsEvent>? _eventSub;

  bool get _isTag => widget.conversationType == AprsConversationType.tag;
  String get _myCallsign => AprsService().callsign?.toUpperCase() ?? '';

  /// Available characters per chunk — for tags, subtract tag prefix.
  int get _availableChars =>
      aprsAvailableChars(_isTag ? widget.conversationId : null);

  @override
  void initState() {
    super.initState();
    _eventSub = AprsService().events.listen((event) {
      if (event.type == AprsEventType.messageReceived && mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _textController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _sendMessage() {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    final aprs = AprsService();
    final sent = aprs.sendMessage(widget.conversationId, text);
    if (sent != null) {
      _textController.clear();
      setState(() {});
      // Keep focus on input
      _focusNode.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final aprs = AprsService();
    final messages = aprs.getConversationMessages(widget.conversationId);

    // Distance for direct conversations
    String? distStr;
    final pos = widget.partnerPosition ?? aprs.lastKnownPositions[widget.conversationId];
    if (!_isTag && pos != null) {
      final dist = distanceKm(pos.$1, pos.$2, widget.myLocation);
      if (dist != null) distStr = formatDistanceKm(dist);
    }

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Expanded(
              child: Text(
                widget.conversationId,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (distStr != null)
              Container(
                margin: const EdgeInsets.only(left: 8),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  distStr,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
      ),
      body: Column(
        children: [
          // Message list (reversed — newest at bottom)
          Expanded(
            child: messages.isEmpty
                ? Center(
                    child: Text(
                      I18nService().t('aprs_no_messages_in_conv', params: [widget.conversationId]),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : _buildMessageList(messages),
          ),
          // Compose bar
          _buildComposeBar(context),
        ],
      ),
    );
  }

  Widget _buildMessageList(List<AprsPacket> messages) {
    // Merge consecutive messages from the same sender within 30s
    final merged = mergeConsecutiveMessages(messages, myCallsign: _myCallsign);

    // Build items list with date separators
    final items = <Widget>[];
    DateTime? lastDate;

    for (final msg in merged) {
      final msgDate = msg.timestamp.toLocal();
      final msgDay = DateTime(msgDate.year, msgDate.month, msgDate.day);

      if (lastDate == null || lastDate != msgDay) {
        items.add(TeleportDateSeparator(date: msg.timestamp));
        lastDate = msgDay;
      }

      final isOut = msg.isOutgoing ||
          msg.fromCallsign.toUpperCase() == _myCallsign;

      items.add(AprsMessageBubble(
        message: msg,
        isOutgoing: isOut,
        showSender: _isTag && !isOut,
      ));
    }

    // Use a regular ListView scrolled to the bottom
    final scrollController = ScrollController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scrollController.hasClients) {
        scrollController.jumpTo(scrollController.position.maxScrollExtent);
      }
    });

    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: items,
    );
  }

  Widget _buildComposeBar(BuildContext context) {
    final theme = Theme.of(context);
    final isConnected = AprsService().isRunning;
    final textLen = _textController.text.length;
    final available = _availableChars;
    final remaining = available - textLen;
    final parts = aprsPartCount(_textController.text, available);
    final canSend = isConnected && textLen > 0;

    // Counter: remaining chars for single part, "N parts" for multi-part
    final counterText = parts <= 1 ? '$remaining' : '$parts parts';
    final counterColor = parts > 9
        ? theme.colorScheme.error
        : (parts <= 1 && remaining < 10)
            ? theme.colorScheme.error
            : theme.colorScheme.onSurfaceVariant;

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        border: Border(
          top: BorderSide(color: theme.dividerColor, width: 0.5),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _textController,
                focusNode: _focusNode,
                maxLines: 3,
                minLines: 1,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _sendMessage(),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: I18nService().t('aprs_message_hint', params: [widget.conversationId]),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                  fillColor: theme.colorScheme.surfaceContainerHigh,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  counterText: counterText,
                  counterStyle: TextStyle(
                    fontSize: 11,
                    color: counterColor,
                  ),
                  isDense: true,
                ),
                style: const TextStyle(fontSize: 14),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              onPressed: canSend ? _sendMessage : null,
              icon: Icon(
                Icons.send,
                color: canSend
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
