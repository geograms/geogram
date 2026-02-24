/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Lightweight conversation model for APRS messages.
 * Groups directed messages by callsign (1:1) or hashtag channel.
 */

import 'aprs_packet.dart';

enum AprsConversationType { direct, tag }

class AprsConversation {
  /// Conversation identifier: callsign for direct, '#tag' for tag rooms.
  final String id;

  final AprsConversationType type;

  /// Most recent message in this conversation.
  final AprsPacket? lastMessage;

  /// Total message count.
  final int messageCount;

  /// Last known position of the conversation partner (direct only).
  final (double, double)? partnerPosition;

  const AprsConversation({
    required this.id,
    required this.type,
    this.lastMessage,
    this.messageCount = 0,
    this.partnerPosition,
  });

  /// Display name: callsign or '#tag'.
  String get displayName => id;

  /// Preview text from the last message.
  String get lastMessagePreview {
    if (lastMessage == null) return 'No messages';
    if (type == AprsConversationType.tag) {
      // Show "CALLSIGN: body" for tag rooms
      final body = lastMessage!.messageBody ?? lastMessage!.messageText ?? '';
      return '${lastMessage!.fromCallsign}: $body';
    }
    return lastMessage!.messageText ?? '';
  }

  /// Timestamp of the last message, or null.
  DateTime? get lastMessageTime => lastMessage?.timestamp;
}
