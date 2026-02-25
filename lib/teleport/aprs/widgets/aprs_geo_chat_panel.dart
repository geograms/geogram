/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Floating geo-chat panel overlaid on the APRS Map tab.
 * Shows position reports that carry comment text, allowing
 * users to send and receive geo-located messages on the map.
 */

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../services/user_location_service.dart';
import '../../shared/teleport_chat_utils.dart';
import '../aprs_service.dart';
import '../models/aprs_packet.dart';
import '../pages/aprs_main_page.dart' show distanceKm, formatDistanceKm, linkifiedText;

class AprsGeoChatPanel extends StatefulWidget {
  final List<AprsPacket> messages;
  final UserLocation? myLocation;
  final void Function(double lat, double lon) onMessageTap;
  final VoidCallback onClose;

  const AprsGeoChatPanel({
    super.key,
    required this.messages,
    this.myLocation,
    required this.onMessageTap,
    required this.onClose,
  });

  @override
  State<AprsGeoChatPanel> createState() => _AprsGeoChatPanelState();
}

class _AprsGeoChatPanelState extends State<AprsGeoChatPanel> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  static const int _maxCommentLength = 107;

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _send() {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    AprsService().sendGeoChat(text);
    _textController.clear();
    // Scroll to bottom after sending
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  String _formatTime(DateTime dt) {
    final local = dt.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width > 600;

    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.85),
        borderRadius: isWide
            ? const BorderRadius.only(
                topLeft: Radius.circular(12),
                bottomLeft: Radius.circular(12),
              )
            : const BorderRadius.vertical(top: Radius.circular(12)),
      ),
      child: Column(
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.chat_bubble_outline, color: Colors.white70, size: 18),
                const SizedBox(width: 8),
                const Text(
                  'Geo Chat',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '${widget.messages.length}',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 12,
                  ),
                ),
                const Spacer(),
                if (!isWide)
                  GestureDetector(
                    onTap: widget.onClose,
                    child: const Icon(Icons.close, color: Colors.white70, size: 20),
                  ),
              ],
            ),
          ),
          const Divider(color: Colors.white24, height: 1),
          // Message list
          Expanded(
            child: widget.messages.isEmpty
                ? Center(
                    child: Text(
                      'No geo-chat messages yet',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.4),
                        fontSize: 13,
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    itemCount: widget.messages.length,
                    itemBuilder: (context, index) {
                      final msg = widget.messages[index];
                      return _buildMessageTile(msg);
                    },
                  ),
          ),
          // Compose bar
          const Divider(color: Colors.white24, height: 1),
          _buildComposeBar(),
        ],
      ),
    );
  }

  Widget _buildMessageTile(AprsPacket msg) {
    final isOutgoing = msg.isOutgoing;
    final dist = distanceKm(msg.latitude, msg.longitude, widget.myLocation);
    final distStr = dist != null ? formatDistanceKm(dist) : null;

    return GestureDetector(
      onTap: () {
        if (msg.hasPosition) {
          widget.onMessageTap(msg.latitude!, msg.longitude!);
        }
      },
      onLongPress: () {
        final text = msg.comment ?? '';
        if (text.isNotEmpty) {
          Clipboard.setData(ClipboardData(text: text));
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Copied to clipboard'),
              duration: Duration(seconds: 1),
            ),
          );
        }
      },
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isOutgoing
              ? const Color(0xFF2B5278).withValues(alpha: 0.7)
              : const Color(0xFF1E2D3D).withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment:
              isOutgoing ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            // Sender + distance
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!isOutgoing)
                  Text(
                    msg.fromCallsign,
                    style: TextStyle(
                      color: teleportSenderColor(msg.fromCallsign),
                      fontWeight: FontWeight.w600,
                      fontSize: 11,
                    ),
                  ),
                if (!isOutgoing && distStr != null) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      distStr,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                        fontSize: 9,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            if (!isOutgoing) const SizedBox(height: 2),
            // Comment text
            linkifiedText(
              msg.comment ?? '',
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
            const SizedBox(height: 2),
            // Timestamp
            Text(
              _formatTime(msg.timestamp),
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.4),
                fontSize: 10,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildComposeBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _textController,
              maxLength: _maxCommentLength,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Message...',
                hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.3)),
                counterStyle: TextStyle(
                  color: Colors.white.withValues(alpha: 0.3),
                  fontSize: 10,
                ),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.08),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide.none,
                ),
              ),
              onSubmitted: (_) => _send(),
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: _send,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xFF2B5278),
              ),
              child: const Icon(Icons.send, color: Colors.white, size: 18),
            ),
          ),
        ],
      ),
    );
  }
}
