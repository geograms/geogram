/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Content types for Telegram messages.
enum TelegramMessageContentType {
  text,
  photo,
  video,
  document,
  voiceNote,
  sticker,
  animation,
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

  const TelegramMediaInfo({
    required this.fileId,
    this.localPath,
    this.width,
    this.height,
    this.duration,
    this.fileName,
    this.mimeType,
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

    return TelegramMediaInfo(
      fileId: parsed.$1,
      localPath: parsed.$2,
      width: best['width'] as int? ?? 0,
      height: best['height'] as int? ?? 0,
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

    return TelegramMediaInfo(
      fileId: parsed.$1,
      localPath: parsed.$2,
      width: hasDimensions ? obj['width'] as int? : null,
      height: hasDimensions ? obj['height'] as int? : null,
      duration: hasDuration ? obj['duration'] as int? : null,
      mimeType: hasMimeType ? obj['mime_type'] as String? : null,
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
  });

  /// Create a copy with an updated media local path (after download).
  TelegramMessage withMediaPath(String path) {
    if (media == null) return this;
    return TelegramMessage(
      id: id,
      chatId: chatId,
      senderUserId: senderUserId,
      senderName: senderName,
      contentType: contentType,
      text: text,
      date: date,
      isOutgoing: isOutgoing,
      messageThreadId: messageThreadId,
      media: TelegramMediaInfo(
        fileId: media!.fileId,
        localPath: path,
        width: media!.width,
        height: media!.height,
        duration: media!.duration,
        fileName: media!.fileName,
        mimeType: media!.mimeType,
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
      default:
        return null;
    }
  }

  @override
  String toString() => 'TelegramMessage($id, chat=$chatId, $contentType)';
}
