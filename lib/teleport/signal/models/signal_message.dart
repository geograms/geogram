/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Signal message model.
 * Primary key: (timestamp, senderUuid) — matches Signal's identity model.
 * No integer message IDs like Telegram.
 */

class SignalMessage {
  /// Timestamp in milliseconds — part of the composite primary key.
  final int timestamp;

  /// UUID of the sender — part of the composite primary key.
  final String senderUuid;

  /// Sender display name (resolved from contacts).
  final String? senderName;

  /// Text content of the message.
  final String? text;

  /// Content type: text, attachment, reaction, etc.
  final String contentType;

  /// Whether this message was sent by the local user.
  final bool isOutgoing;

  /// Media attachment info (if any).
  final SignalMediaInfo? media;

  /// Number of attachments (for multi-attachment messages).
  final int attachmentCount;

  /// Quote/reply: timestamp of the quoted message.
  final int? quoteTimestamp;

  /// Quote/reply: text preview of the quoted message.
  final String? quoteText;

  /// Reaction emoji (if contentType == 'reaction').
  final String? reactionEmoji;

  /// Reaction target timestamp.
  final int? reactionTargetTimestamp;

  /// Reactions on this message from other users.
  final List<SignalReaction> reactions;

  /// Group master key (base64) if this is a group message.
  final String? groupKey;

  /// Forward sender name (if forwarded).
  final String? forwardSenderName;

  /// Edit timestamp (if edited).
  final int? editTimestamp;

  const SignalMessage({
    required this.timestamp,
    required this.senderUuid,
    this.senderName,
    this.text,
    this.contentType = 'text',
    this.isOutgoing = false,
    this.media,
    this.attachmentCount = 0,
    this.quoteTimestamp,
    this.quoteText,
    this.reactionEmoji,
    this.reactionTargetTimestamp,
    this.reactions = const [],
    this.groupKey,
    this.forwardSenderName,
    this.editTimestamp,
  });

  factory SignalMessage.fromJson(Map<String, dynamic> json) {
    return SignalMessage(
      timestamp: json['timestamp'] as int? ?? 0,
      senderUuid: json['sender_uuid'] as String? ?? '',
      senderName: json['sender_name'] as String?,
      text: json['text'] as String?,
      contentType: json['content_type'] as String? ?? 'text',
      isOutgoing: json['is_outgoing'] as bool? ?? false,
      attachmentCount: json['attachment_count'] as int? ?? 0,
      quoteTimestamp: json['quote_timestamp'] as int?,
      quoteText: json['quote_text'] as String?,
      reactionEmoji: json['reaction_emoji'] as String?,
      reactionTargetTimestamp: json['reaction_target_timestamp'] as int?,
      groupKey: json['group_key'] as String?,
      forwardSenderName: json['forward_sender_name'] as String?,
      editTimestamp: json['edit_timestamp'] as int?,
    );
  }

  /// Composite primary key for deduplication.
  String get primaryKey => '$timestamp|$senderUuid';

  /// DateTime from the timestamp.
  DateTime get dateTime => DateTime.fromMillisecondsSinceEpoch(timestamp);

  SignalMessage copyWith({
    String? senderName,
    String? text,
    bool? isOutgoing,
    List<SignalReaction>? reactions,
  }) {
    return SignalMessage(
      timestamp: timestamp,
      senderUuid: senderUuid,
      senderName: senderName ?? this.senderName,
      text: text ?? this.text,
      contentType: contentType,
      isOutgoing: isOutgoing ?? this.isOutgoing,
      media: media,
      attachmentCount: attachmentCount,
      quoteTimestamp: quoteTimestamp,
      quoteText: quoteText,
      reactionEmoji: reactionEmoji,
      reactionTargetTimestamp: reactionTargetTimestamp,
      reactions: reactions ?? this.reactions,
      groupKey: groupKey,
      forwardSenderName: forwardSenderName,
      editTimestamp: editTimestamp,
    );
  }

  @override
  String toString() =>
      'SignalMessage($timestamp, $senderUuid, ${text?.substring(0, text!.length.clamp(0, 30))})';
}

/// Media attachment info for a Signal message.
/// Unlike Telegram, Signal doesn't use file IDs — media is stored as local paths.
class SignalMediaInfo {
  final String? localPath;
  final String? contentType;
  final String? fileName;
  final int? width;
  final int? height;
  final int? duration;
  final int? size;

  const SignalMediaInfo({
    this.localPath,
    this.contentType,
    this.fileName,
    this.width,
    this.height,
    this.duration,
    this.size,
  });
}

/// A reaction on a Signal message.
class SignalReaction {
  final String emoji;
  final String senderUuid;
  final int timestamp;

  const SignalReaction({
    required this.emoji,
    required this.senderUuid,
    required this.timestamp,
  });
}
