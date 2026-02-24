/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:typed_data';

/// Telegram chat types.
enum TelegramChatType {
  private_,
  group,
  supergroup,
  channel,
  unknown,
}

/// A Telegram chat (conversation, group, or channel).
class TelegramChat {
  final int id;
  final String title;
  final TelegramChatType type;
  final String? lastMessageText;
  final DateTime? lastMessageDate;
  final int unreadCount;
  final String? photoPath;
  final int? photoSmallFileId;
  final Uint8List? photoBytes;
  final int? supergroupId;
  final bool isForum;

  const TelegramChat({
    required this.id,
    required this.title,
    required this.type,
    this.lastMessageText,
    this.lastMessageDate,
    this.unreadCount = 0,
    this.photoPath,
    this.photoSmallFileId,
    this.photoBytes,
    this.supergroupId,
    this.isForum = false,
  });

  factory TelegramChat.fromTdlib(Map<String, dynamic> json) {
    final typeJson = json['type'] as Map<String, dynamic>?;
    final type = _parseChatType(typeJson);
    final lastMsg = json['last_message'] as Map<String, dynamic>?;
    String? lastMsgText;
    DateTime? lastMsgDate;

    if (lastMsg != null) {
      lastMsgText = extractMessageText(lastMsg);
      final date = lastMsg['date'] as int?;
      if (date != null) {
        lastMsgDate = DateTime.fromMillisecondsSinceEpoch(date * 1000, isUtc: true);
      }
    }

    int? supergroupId;
    if (typeJson != null && typeJson['@type'] == 'chatTypeSupergroup') {
      supergroupId = typeJson['supergroup_id'] as int?;
    }

    // Extract chat photo
    int? photoSmallFileId;
    String? photoPath;
    final photo = json['photo'] as Map<String, dynamic>?;
    if (photo != null) {
      final small = photo['small'] as Map<String, dynamic>?;
      final local = small?['local'] as Map<String, dynamic>?;
      final isDownloaded = local?['is_downloading_completed'] as bool? ?? false;
      final path = local?['path'] as String?;
      if (isDownloaded && path != null && path.isNotEmpty) {
        photoPath = path;
      }
      photoSmallFileId = small?['id'] as int?;
    }

    return TelegramChat(
      id: json['id'] as int,
      title: json['title'] as String? ?? '',
      type: type,
      lastMessageText: lastMsgText,
      lastMessageDate: lastMsgDate,
      unreadCount: json['unread_count'] as int? ?? 0,
      photoPath: photoPath,
      photoSmallFileId: photoSmallFileId,
      supergroupId: supergroupId,
    );
  }

  TelegramChat copyWith({
    String? title,
    String? lastMessageText,
    DateTime? lastMessageDate,
    int? unreadCount,
    String? photoPath,
    int? photoSmallFileId,
    Uint8List? photoBytes,
    bool? isForum,
  }) {
    return TelegramChat(
      id: id,
      title: title ?? this.title,
      type: type,
      lastMessageText: lastMessageText ?? this.lastMessageText,
      lastMessageDate: lastMessageDate ?? this.lastMessageDate,
      unreadCount: unreadCount ?? this.unreadCount,
      photoPath: photoPath ?? this.photoPath,
      photoSmallFileId: photoSmallFileId ?? this.photoSmallFileId,
      photoBytes: photoBytes ?? this.photoBytes,
      supergroupId: supergroupId,
      isForum: isForum ?? this.isForum,
    );
  }

  static TelegramChatType _parseChatType(Map<String, dynamic>? typeJson) {
    if (typeJson == null) return TelegramChatType.unknown;
    final typeStr = typeJson['@type'] as String? ?? '';
    switch (typeStr) {
      case 'chatTypePrivate':
        return TelegramChatType.private_;
      case 'chatTypeBasicGroup':
        return TelegramChatType.group;
      case 'chatTypeSupergroup':
        final isChannel = typeJson['is_channel'] as bool? ?? false;
        return isChannel ? TelegramChatType.channel : TelegramChatType.supergroup;
      default:
        return TelegramChatType.unknown;
    }
  }

  static String? extractMessageText(Map<String, dynamic> msg) {
    final content = msg['content'] as Map<String, dynamic>?;
    if (content == null) return null;
    final type = content['@type'] as String? ?? '';
    switch (type) {
      case 'messageText':
        final text = content['text'] as Map<String, dynamic>?;
        return text?['text'] as String?;
      case 'messagePhoto':
        return content['caption']?['text'] as String? ?? '[Photo]';
      case 'messageVideo':
        return '[Video]';
      case 'messageDocument':
        return '[Document]';
      case 'messageVoiceNote':
        return '[Voice message]';
      case 'messageSticker':
        return '[Sticker]';
      case 'messageAnimation':
        return '[GIF]';
      case 'messageLocation':
        final livePeriod = content['live_period'] as int? ?? 0;
        return livePeriod > 0 ? '[Live Location]' : '[Location]';
      case 'messageVenue':
        return '[Venue]';
      case 'messageVideoNote':
        return '[Video message]';
      case 'messageContact':
        return '[Contact]';
      case 'messageAudio':
        return '[Audio]';
      case 'messagePoll':
        final poll = content['poll'] as Map<String, dynamic>?;
        final question =
            (poll?['question'] as Map<String, dynamic>?)?['text'] as String?;
        return question != null ? '[Poll] $question' : '[Poll]';
      case 'messageCall':
        return '[Call]';
      case 'messagePinMessage':
        return 'pinned a message';
      default:
        return '[$type]';
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'type': type.name,
        'lastMessageText': lastMessageText,
        'lastMessageDate': lastMessageDate?.toIso8601String(),
        'unreadCount': unreadCount,
      };

  @override
  String toString() => 'TelegramChat($id, $title, $type)';
}
