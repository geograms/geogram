/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:io';
import 'dart:typed_data';
import '../telegram_log.dart';

/// Content types for Telegram messages.
enum TelegramMessageContentType {
  text,
  photo,
  video,
  document,
  voiceNote,
  sticker,
  animation,
  location,
  venue,
  videoNote,
  contact,
  audio,
  poll,
  call,
  pinMessage,
  other,
}

/// Media metadata extracted from a TDLib message (photo, video, document, etc.).
class TelegramMediaInfo {
  /// TDLib file ID for downloading.
  final int fileId;

  /// Local file path (non-null if already downloaded).
  final String? localPath;

  /// Width in pixels (photos, videos, stickers, animations).
  final int? width;

  /// Height in pixels (photos, videos, stickers, animations).
  final int? height;

  /// Duration in seconds (videos, animations, voice notes).
  final int? duration;

  /// Original file name (documents).
  final String? fileName;

  /// MIME type (documents, voice notes).
  final String? mimeType;

  /// Base64-encoded JPEG minithumbnail from TDLib (for preview before download).
  final String? minithumbnailData;

  /// Raw media bytes from the SQLite BLOB (for in-memory rendering of photos,
  /// stickers, and animations without extracting to disk).
  final Uint8List? mediaBytes;

  /// Resolved file extension (e.g. ".jpg", ".mp4", ".ogg"), persisted at
  /// ingestion time so the media type is instantly recognizable.
  final String? extension;

  /// Thumbnail image bytes (e.g. a frame from a video, a downscaled photo).
  final Uint8List? thumbnail;

  const TelegramMediaInfo({
    required this.fileId,
    this.localPath,
    this.width,
    this.height,
    this.duration,
    this.fileName,
    this.mimeType,
    this.minithumbnailData,
    this.mediaBytes,
    this.extension,
    this.thumbnail,
  });

  /// Extract media info from TDLib message content, dispatching by type.
  static TelegramMediaInfo? fromTdlibContent(
    TelegramMessageContentType type,
    Map<String, dynamic>? content,
  ) {
    if (content == null) return null;
    switch (type) {
      case TelegramMessageContentType.photo:
        return _fromPhoto(content);
      case TelegramMessageContentType.video:
        return _fromFileObject(content, 'video',
            hasDimensions: true, hasDuration: true);
      case TelegramMessageContentType.document:
        return _fromDocument(content);
      case TelegramMessageContentType.animation:
        return _fromFileObject(content, 'animation',
            hasDimensions: true, hasDuration: true);
      case TelegramMessageContentType.voiceNote:
        return _fromFileObject(content, 'voice_note',
            hasDuration: true, hasMimeType: true);
      case TelegramMessageContentType.sticker:
        return _fromFileObject(content, 'sticker', hasDimensions: true);
      case TelegramMessageContentType.videoNote:
        return _fromVideoNote(content);
      case TelegramMessageContentType.audio:
        return _fromAudio(content);
      default:
        return null;
    }
  }

  /// Pick the best photo size from TDLib's sizes array.
  static TelegramMediaInfo? _fromPhoto(Map<String, dynamic> content) {
    final photo = content['photo'] as Map<String, dynamic>?;
    if (photo == null) return null;

    final sizes = photo['sizes'] as List<dynamic>?;
    if (sizes == null || sizes.isEmpty) return null;

    // Pick the best size — prefer 'x' or 'y' (large), fall back to last
    Map<String, dynamic>? best;
    for (final size in sizes) {
      if (size is! Map<String, dynamic>) continue;
      final sizeType = size['type'] as String? ?? '';
      if (best == null ||
          sizeType == 'y' ||
          sizeType == 'x' ||
          (sizeType == 'm' && (best['type'] as String? ?? '') == 's')) {
        best = size;
        if (sizeType == 'y') break; // 'y' is the biggest we want
      }
    }

    if (best == null) return null;

    final file = best['photo'] as Map<String, dynamic>?;
    if (file == null) return null;

    final parsed = _parseFileObject(file);
    if (parsed == null) return null;

    // Extract minithumbnail base64 data if present
    final miniThumb = photo['minithumbnail'] as Map<String, dynamic>?;
    final miniData = miniThumb?['data'] as String?;

    return TelegramMediaInfo(
      fileId: parsed.$1,
      localPath: parsed.$2,
      width: best['width'] as int? ?? 0,
      height: best['height'] as int? ?? 0,
      minithumbnailData: miniData,
    );
  }

  /// Extract media from content types that have a direct file object
  /// (video, animation, voice_note, sticker).
  static TelegramMediaInfo? _fromFileObject(
    Map<String, dynamic> content,
    String key, {
    bool hasDimensions = false,
    bool hasDuration = false,
    bool hasMimeType = false,
  }) {
    final obj = content[key] as Map<String, dynamic>?;
    if (obj == null) return null;

    // The file object key varies: 'video' for video, 'animation' for animation,
    // 'voice' for voice_note, 'sticker' for sticker.
    final fileKey = key == 'voice_note' ? 'voice' : key;
    final file = obj[fileKey] as Map<String, dynamic>?;
    if (file == null) return null;

    final parsed = _parseFileObject(file);
    if (parsed == null) return null;

    // Extract minithumbnail base64 data if present
    final miniThumb = obj['minithumbnail'] as Map<String, dynamic>?;
    final miniData = miniThumb?['data'] as String?;

    return TelegramMediaInfo(
      fileId: parsed.$1,
      localPath: parsed.$2,
      width: hasDimensions ? obj['width'] as int? : null,
      height: hasDimensions ? obj['height'] as int? : null,
      duration: hasDuration ? obj['duration'] as int? : null,
      mimeType: hasMimeType ? obj['mime_type'] as String? : null,
      minithumbnailData: miniData,
    );
  }

  /// Extract document with file_name and mime_type.
  static TelegramMediaInfo? _fromDocument(Map<String, dynamic> content) {
    final doc = content['document'] as Map<String, dynamic>?;
    if (doc == null) return null;

    final file = doc['document'] as Map<String, dynamic>?;
    if (file == null) return null;

    final parsed = _parseFileObject(file);
    if (parsed == null) return null;

    return TelegramMediaInfo(
      fileId: parsed.$1,
      localPath: parsed.$2,
      fileName: doc['file_name'] as String?,
      mimeType: doc['mime_type'] as String?,
    );
  }

  /// Extract video note (round video) media info.
  static TelegramMediaInfo? _fromVideoNote(Map<String, dynamic> content) {
    final vn = content['video_note'] as Map<String, dynamic>?;
    if (vn == null) return null;

    final file = vn['video'] as Map<String, dynamic>?;
    if (file == null) return null;

    final parsed = _parseFileObject(file);
    if (parsed == null) return null;

    final length = vn['length'] as int? ?? 240;
    final miniThumb = vn['minithumbnail'] as Map<String, dynamic>?;
    final miniData = miniThumb?['data'] as String?;

    return TelegramMediaInfo(
      fileId: parsed.$1,
      localPath: parsed.$2,
      width: length,
      height: length,
      duration: vn['duration'] as int?,
      minithumbnailData: miniData,
    );
  }

  /// Extract audio file media info.
  static TelegramMediaInfo? _fromAudio(Map<String, dynamic> content) {
    final audio = content['audio'] as Map<String, dynamic>?;
    if (audio == null) return null;

    final file = audio['audio'] as Map<String, dynamic>?;
    if (file == null) return null;

    final parsed = _parseFileObject(file);
    if (parsed == null) return null;

    final performer = audio['performer'] as String? ?? '';
    final title = audio['title'] as String? ?? '';
    String? fileName;
    if (performer.isNotEmpty && title.isNotEmpty) {
      fileName = '$performer - $title';
    } else if (title.isNotEmpty) {
      fileName = title;
    } else if (performer.isNotEmpty) {
      fileName = performer;
    } else {
      fileName = audio['file_name'] as String?;
    }

    return TelegramMediaInfo(
      fileId: parsed.$1,
      localPath: parsed.$2,
      duration: audio['duration'] as int?,
      fileName: fileName,
      mimeType: audio['mime_type'] as String?,
    );
  }

  /// Parse a TDLib file object, returning (fileId, localPath?).
  static (int, String?)? _parseFileObject(Map<String, dynamic> file) {
    final fileId = file['id'] as int? ?? 0;
    if (fileId == 0) return null;

    final local = file['local'] as Map<String, dynamic>?;
    final localPath = local?['path'] as String?;
    final isDownloaded =
        local?['is_downloading_completed'] as bool? ?? false;

    final path = (isDownloaded && localPath != null && localPath.isNotEmpty)
        ? localPath
        : null;
    return (fileId, path);
  }
}

/// A single reaction on a Telegram message (emoji + count + chosen flag).
class TelegramReaction {
  final String emoji;
  final int count;
  final bool isChosen;

  const TelegramReaction({
    required this.emoji,
    required this.count,
    this.isChosen = false,
  });

  Map<String, dynamic> toJson() => {
        'emoji': emoji,
        'count': count,
        'is_chosen': isChosen,
      };

  factory TelegramReaction.fromJson(Map<String, dynamic> json) =>
      TelegramReaction(
        emoji: json['emoji'] as String,
        count: json['count'] as int? ?? 1,
        isChosen: json['is_chosen'] as bool? ?? false,
      );

  /// Parse a list of reactions from TDLib interaction_info.reactions.reactions.
  ///
  /// Supports both older TDLib (reactionEmoji/emoticon/reactionCount) and
  /// newer TDLib (reactionTypeEmoji/emoji/messageReaction) schemas.
  static List<TelegramReaction> fromTdlibReactions(
      List<dynamic>? reactions) {
    if (reactions == null || reactions.isEmpty) return const [];
    final result = <TelegramReaction>[];
    for (final r in reactions) {
      if (r is! Map<String, dynamic>) continue;

      // Try newer schema: "type" → reactionTypeEmoji → "emoji"
      // Try older schema: "reaction" → reactionEmoji → "emoticon"
      String? emoji;
      final typeObj = r['type'] as Map<String, dynamic>?;
      final reactionObj = r['reaction'] as Map<String, dynamic>?;
      if (typeObj != null) {
        emoji = typeObj['emoji'] as String? ?? typeObj['emoticon'] as String?;
      } else if (reactionObj != null) {
        emoji = reactionObj['emoji'] as String? ??
            reactionObj['emoticon'] as String?;
      }
      if (emoji == null || emoji.isEmpty) continue;

      result.add(TelegramReaction(
        emoji: emoji,
        count: r['total_count'] as int? ?? r['count'] as int? ?? 1,
        isChosen: r['is_chosen'] as bool? ?? r['chosen_order'] != null,
      ));
    }
    return result;
  }
}

/// A Telegram message.
class TelegramMessage {
  final int id;
  final int chatId;
  final int senderUserId;
  final String? senderName;
  final TelegramMessageContentType contentType;
  final String? text;
  final DateTime date;
  final bool isOutgoing;
  final int? messageThreadId;

  /// Media metadata (non-null for photo, video, document, animation,
  /// voiceNote, sticker messages).
  final TelegramMediaInfo? media;

  /// ID of the message this is replying to (null if not a reply).
  final int? replyToMessageId;

  /// Denormalized sender name of the replied-to message (for display).
  final String? replyToSenderName;

  /// Denormalized text preview of the replied-to message (first ~100 chars).
  final String? replyToText;

  /// Unix seconds when last edited (null if never edited).
  final int? editDate;

  /// Original sender name for forwarded messages.
  final String? forwardSenderName;

  /// Reactions on this message (emoji + count + chosen).
  final List<TelegramReaction> reactions;

  const TelegramMessage({
    required this.id,
    required this.chatId,
    required this.senderUserId,
    this.senderName,
    required this.contentType,
    this.text,
    required this.date,
    required this.isOutgoing,
    this.messageThreadId,
    this.media,
    this.replyToMessageId,
    this.replyToSenderName,
    this.replyToText,
    this.editDate,
    this.forwardSenderName,
    this.reactions = const [],
  });

  /// Create a copy with optional field overrides.
  TelegramMessage copyWith({
    int? id,
    int? chatId,
    int? senderUserId,
    String? senderName,
    TelegramMessageContentType? contentType,
    String? text,
    DateTime? date,
    bool? isOutgoing,
    int? messageThreadId,
    TelegramMediaInfo? media,
    int? replyToMessageId,
    String? replyToSenderName,
    String? replyToText,
    int? editDate,
    String? forwardSenderName,
    List<TelegramReaction>? reactions,
  }) {
    return TelegramMessage(
      id: id ?? this.id,
      chatId: chatId ?? this.chatId,
      senderUserId: senderUserId ?? this.senderUserId,
      senderName: senderName ?? this.senderName,
      contentType: contentType ?? this.contentType,
      text: text ?? this.text,
      date: date ?? this.date,
      isOutgoing: isOutgoing ?? this.isOutgoing,
      messageThreadId: messageThreadId ?? this.messageThreadId,
      media: media ?? this.media,
      replyToMessageId: replyToMessageId ?? this.replyToMessageId,
      replyToSenderName: replyToSenderName ?? this.replyToSenderName,
      replyToText: replyToText ?? this.replyToText,
      editDate: editDate ?? this.editDate,
      forwardSenderName: forwardSenderName ?? this.forwardSenderName,
      reactions: reactions ?? this.reactions,
    );
  }

  /// Create a copy with an updated media local path (after download).
  TelegramMessage withMediaPath(String path) {
    if (media == null) return this;
    return copyWith(
      media: TelegramMediaInfo(
        fileId: media!.fileId,
        localPath: path,
        width: media!.width,
        height: media!.height,
        duration: media!.duration,
        fileName: media!.fileName,
        mimeType: media!.mimeType,
        minithumbnailData: media!.minithumbnailData,
        mediaBytes: media!.mediaBytes,
        extension: media!.extension,
        thumbnail: media!.thumbnail,
      ),
    );
  }

  factory TelegramMessage.fromTdlib(Map<String, dynamic> json) {
    final senderId = json['sender_id'] as Map<String, dynamic>?;
    int senderUserId = 0;
    if (senderId != null && senderId['@type'] == 'messageSenderUser') {
      senderUserId = senderId['user_id'] as int? ?? 0;
    }

    final content = json['content'] as Map<String, dynamic>?;
    final contentType = _parseContentType(content);
    final text = _extractText(content);

    final date = json['date'] as int? ?? 0;
    final threadId = json['message_thread_id'] as int?;

    // Extract media info for all supported content types
    final mediaInfo =
        TelegramMediaInfo.fromTdlibContent(contentType, content);

    // Extract reply-to message ID
    final replyTo = json['reply_to'] as Map<String, dynamic>?;
    int? replyToMessageId;
    if (replyTo != null && replyTo['@type'] == 'messageReplyToMessage') {
      replyToMessageId = replyTo['message_id'] as int?;
      if (replyToMessageId == 0) replyToMessageId = null;
    }

    // Extract edit date (non-zero means edited)
    final rawEditDate = json['edit_date'] as int? ?? 0;
    final editDate = rawEditDate != 0 ? rawEditDate : null;

    // Extract forward info → sender name
    String? forwardSenderName;
    final fwdInfo = json['forward_info'] as Map<String, dynamic>?;
    if (fwdInfo != null) {
      final origin = fwdInfo['origin'] as Map<String, dynamic>?;
      if (origin != null) {
        final originType = origin['@type'] as String? ?? '';
        switch (originType) {
          case 'messageOriginHiddenUser':
            forwardSenderName = origin['sender_name'] as String?;
            break;
          case 'messageOriginChannel':
            forwardSenderName = origin['author_signature'] as String?;
            // Fall back to chat title if no author signature
            if (forwardSenderName == null || forwardSenderName.isEmpty) {
              forwardSenderName = 'Channel';
            }
            break;
          case 'messageOriginUser':
            // Will be resolved later via user ID lookup
            break;
          case 'messageOriginChat':
            forwardSenderName = origin['author_signature'] as String?;
            break;
        }
      }
    }

    // Extract reactions from interaction_info
    final interactionInfo =
        json['interaction_info'] as Map<String, dynamic>?;
    final reactionsObj =
        interactionInfo?['reactions'] as Map<String, dynamic>?;
    final reactionsList =
        reactionsObj?['reactions'] as List<dynamic>?;
    if (interactionInfo != null && reactionsObj != null) {
      telegramDebug('TelegramMessage.fromTdlib: msg ${json['id']} '
          'interaction_info.reactions=$reactionsObj');
    }
    final reactions = TelegramReaction.fromTdlibReactions(reactionsList);
    if (reactions.isNotEmpty) {
      telegramDebug('TelegramMessage.fromTdlib: msg ${json['id']} has '
          '${reactions.length} reactions: ${reactions.map((r) => '${r.emoji}x${r.count}').join(', ')}');
    }

    return TelegramMessage(
      id: json['id'] as int,
      chatId: json['chat_id'] as int,
      senderUserId: senderUserId,
      contentType: contentType,
      text: text,
      date: DateTime.fromMillisecondsSinceEpoch(date * 1000, isUtc: true),
      isOutgoing: json['is_outgoing'] as bool? ?? false,
      messageThreadId: threadId != null && threadId != 0 ? threadId : null,
      media: mediaInfo,
      replyToMessageId: replyToMessageId,
      editDate: editDate,
      forwardSenderName: forwardSenderName,
      reactions: reactions,
    );
  }

  static TelegramMessageContentType _parseContentType(Map<String, dynamic>? content) {
    if (content == null) return TelegramMessageContentType.other;
    final type = content['@type'] as String? ?? '';
    switch (type) {
      case 'messageText':
        return TelegramMessageContentType.text;
      case 'messagePhoto':
        return TelegramMessageContentType.photo;
      case 'messageVideo':
        return TelegramMessageContentType.video;
      case 'messageDocument':
        return TelegramMessageContentType.document;
      case 'messageVoiceNote':
        return TelegramMessageContentType.voiceNote;
      case 'messageSticker':
        return TelegramMessageContentType.sticker;
      case 'messageAnimation':
        return TelegramMessageContentType.animation;
      case 'messageLocation':
        return TelegramMessageContentType.location;
      case 'messageVenue':
        return TelegramMessageContentType.venue;
      case 'messageVideoNote':
        return TelegramMessageContentType.videoNote;
      case 'messageContact':
        return TelegramMessageContentType.contact;
      case 'messageAudio':
        return TelegramMessageContentType.audio;
      case 'messagePoll':
        return TelegramMessageContentType.poll;
      case 'messageCall':
        return TelegramMessageContentType.call;
      case 'messagePinMessage':
        return TelegramMessageContentType.pinMessage;
      default:
        return TelegramMessageContentType.other;
    }
  }

  static String? _extractText(Map<String, dynamic>? content) {
    if (content == null) return null;
    final type = content['@type'] as String? ?? '';
    switch (type) {
      case 'messageText':
        final text = content['text'] as Map<String, dynamic>?;
        return text?['text'] as String?;
      case 'messagePhoto':
        return content['caption']?['text'] as String?;
      case 'messageVideo':
        return content['caption']?['text'] as String?;
      case 'messageDocument':
        return content['caption']?['text'] as String?;
      case 'messageAnimation':
        return content['caption']?['text'] as String?;
      case 'messageLocation':
        final loc = content['location'] as Map<String, dynamic>?;
        if (loc == null) return null;
        final lat = (loc['latitude'] as num?)?.toStringAsFixed(6) ?? '0';
        final lng = (loc['longitude'] as num?)?.toStringAsFixed(6) ?? '0';
        final livePeriod = content['live_period'] as int? ?? 0;
        return livePeriod > 0 ? '$lat, $lng|live' : '$lat, $lng';
      case 'messageVenue':
        final venue = content['venue'] as Map<String, dynamic>?;
        if (venue == null) return null;
        final title = venue['title'] as String? ?? '';
        final address = venue['address'] as String? ?? '';
        final loc = venue['location'] as Map<String, dynamic>?;
        final lat = (loc?['latitude'] as num?)?.toStringAsFixed(6) ?? '0';
        final lng = (loc?['longitude'] as num?)?.toStringAsFixed(6) ?? '0';
        return '$title\n$address\n$lat, $lng';
      case 'messageContact':
        final contact = content['contact'] as Map<String, dynamic>?;
        if (contact == null) return null;
        final first = contact['first_name'] as String? ?? '';
        final last = contact['last_name'] as String? ?? '';
        final phone = contact['phone_number'] as String? ?? '';
        final name = '$first $last'.trim();
        return phone.isNotEmpty ? '$name\n+$phone' : name;
      case 'messagePoll':
        final poll = content['poll'] as Map<String, dynamic>?;
        if (poll == null) return null;
        final question =
            (poll['question'] as Map<String, dynamic>?)?['text'] as String? ??
            '';
        final options = poll['options'] as List<dynamic>? ?? [];
        final buf = StringBuffer(question);
        for (final opt in options) {
          if (opt is! Map<String, dynamic>) continue;
          final optText =
              (opt['text'] as Map<String, dynamic>?)?['text'] as String? ?? '';
          final votes = opt['voter_count'] as int? ?? 0;
          buf.write('\n$optText: $votes');
        }
        return buf.toString();
      case 'messageAudio':
        return content['caption']?['text'] as String?;
      case 'messageCall':
        final discardReason = content['discard_reason'] as Map<String, dynamic>?;
        final reasonType = discardReason?['@type'] as String? ?? '';
        final duration = content['duration'] as int? ?? 0;
        if (reasonType == 'callDiscardReasonMissed' ||
            reasonType == 'callDiscardReasonDeclined') {
          return 'Missed call';
        }
        if (duration > 0) {
          final m = duration ~/ 60;
          final s = duration % 60;
          return 'Call (${m}m ${s.toString().padLeft(2, '0')}s)';
        }
        return 'Call';
      case 'messagePinMessage':
        return 'pinned a message';
      case 'messageVideoNote':
        return null;
      default:
        return null;
    }
  }

  @override
  String toString() => 'TelegramMessage($id, chat=$chatId, $contentType)';
}
