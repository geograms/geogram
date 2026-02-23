/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Telegram chat and message operations.
 */

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../services/log_service.dart';
import 'models/telegram_chat.dart';
import 'models/telegram_forum_topic.dart';
import 'models/telegram_message.dart';
import 'models/telegram_user.dart';
import 'tdlib_client.dart';
import 'telegram_cache_service.dart';
import 'telegram_service.dart';

/// Callback for chat events (chat list updates, new messages).
typedef ChatEventCallback = void Function(TelegramEventType type, dynamic data);

/// Manages Telegram chat list and messaging.
class TelegramChatService {
  final TdlibClient _client;
  final ChatEventCallback _onEvent;
  final TelegramCacheService? _cache;

  final Map<int, TelegramChat> _chats = {};
  final Map<int, TelegramUser> _users = {};
  final Map<int, Future<TelegramUser?>> _pendingUserRequests = {};

  /// All loaded chats, sorted by last message date (newest first).
  List<TelegramChat> get chats {
    final list = _chats.values.toList();
    list.sort((a, b) {
      final aDate = a.lastMessageDate ?? DateTime(1970);
      final bDate = b.lastMessageDate ?? DateTime(1970);
      return bDate.compareTo(aDate);
    });
    return list;
  }

  /// Get a cached chat by ID (null if not loaded).
  TelegramChat? getCachedChat(int chatId) => _chats[chatId];

  TelegramChatService(this._client, this._onEvent, {TelegramCacheService? cacheService})
      : _cache = cacheService;

  /// Handle a TDLib update related to chats/messages.
  void handleUpdate(Map<String, dynamic> update) {
    final type = update['@type'] as String? ?? '';

    switch (type) {
      case 'updateNewChat':
        final chatJson = update['chat'] as Map<String, dynamic>?;
        if (chatJson != null) {
          final chat = TelegramChat.fromTdlib(chatJson);
          _chats[chat.id] = chat;
          // If it's a supergroup, check forum status
          if (chat.supergroupId != null) {
            _checkForumStatus(chat);
          }
          _onEvent(TelegramEventType.chatListUpdated, chat);
        }
        break;

      case 'updateChatLastMessage':
        final chatId = update['chat_id'] as int?;
        if (chatId != null && _chats.containsKey(chatId)) {
          final existing = _chats[chatId]!;
          final lastMsg = update['last_message'] as Map<String, dynamic>?;
          String? lastMsgText;
          DateTime? lastMsgDate;
          if (lastMsg != null) {
            lastMsgText = TelegramChat.extractMessageText(lastMsg);
            final date = lastMsg['date'] as int?;
            if (date != null) {
              lastMsgDate =
                  DateTime.fromMillisecondsSinceEpoch(date * 1000, isUtc: true);
            }
          }
          _chats[chatId] = existing.copyWith(
            lastMessageText: lastMsgText ?? existing.lastMessageText,
            lastMessageDate: lastMsgDate ?? existing.lastMessageDate,
          );
          _onEvent(TelegramEventType.chatListUpdated, _chats[chatId]);
        }
        break;

      case 'updateNewMessage':
        final msgJson = update['message'] as Map<String, dynamic>?;
        if (msgJson != null) {
          final msg = TelegramMessage.fromTdlib(msgJson);
          _cache?.cacheMessage(msg.chatId, msg);
          _onEvent(TelegramEventType.newMessage, msg);
        }
        break;

      case 'updateChatReadInbox':
        final chatId = update['chat_id'] as int?;
        final unread = update['unread_count'] as int?;
        if (chatId != null && _chats.containsKey(chatId) && unread != null) {
          _chats[chatId] = _chats[chatId]!.copyWith(unreadCount: unread);
        }
        break;

      case 'updateSupergroup':
        _handleSupergroupUpdate(update);
        break;

      case 'updateMessageEdited':
        final chatId = update['chat_id'] as int?;
        final messageId = update['message_id'] as int?;
        final editDate = update['edit_date'] as int? ?? 0;
        if (chatId != null && messageId != null && editDate != 0) {
          _onEvent(TelegramEventType.messageEdited, {
            'chat_id': chatId,
            'message_id': messageId,
            'edit_date': editDate,
          });
        }
        break;

      case 'updateMessageContent':
        // Message content changed (e.g. edited text) — treat as edit event
        final chatId = update['chat_id'] as int?;
        final messageId = update['message_id'] as int?;
        if (chatId != null && messageId != null) {
          _onEvent(TelegramEventType.messageEdited, {
            'chat_id': chatId,
            'message_id': messageId,
            'edit_date': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          });
        }
        break;

      case 'updateDeleteMessages':
        final isPermanent = update['is_permanent'] as bool? ?? false;
        if (!isPermanent) break;
        final chatId = update['chat_id'] as int?;
        final messageIds = (update['message_ids'] as List<dynamic>?)
            ?.whereType<int>()
            .toList();
        if (chatId != null && messageIds != null && messageIds.isNotEmpty) {
          _cache?.deleteMessages(chatId, messageIds);
          _onEvent(TelegramEventType.messagesDeleted, {
            'chat_id': chatId,
            'message_ids': messageIds,
          });
        }
        break;

      case 'updateMessageInteractionInfo':
        final chatId = update['chat_id'] as int?;
        final messageId = update['message_id'] as int?;
        final interactionInfo =
            update['interaction_info'] as Map<String, dynamic>?;
        if (chatId != null && messageId != null) {
          final reactionsObj =
              interactionInfo?['reactions'] as Map<String, dynamic>?;
          if (reactionsObj != null) {
            stderr.writeln('TDLib: updateMessageInteractionInfo chat=$chatId '
                'msg=$messageId reactions=$reactionsObj');
          }
          final reactionsList =
              reactionsObj?['reactions'] as List<dynamic>?;
          final reactions =
              TelegramReaction.fromTdlibReactions(reactionsList);
          if (reactions.isNotEmpty) {
            stderr.writeln('TDLib: parsed ${reactions.length} reactions '
                'for msg $messageId: ${reactions.map((r) => '${r.emoji}x${r.count}').join(', ')}');
          }
          _onEvent(TelegramEventType.reactionsUpdated, {
            'chat_id': chatId,
            'message_id': messageId,
            'reactions': reactions,
          });
        }
        break;

      case 'updateUserChatAction':
        final chatId = update['chat_id'] as int?;
        final senderId = update['sender_id'] as Map<String, dynamic>?;
        int userId = 0;
        if (senderId != null && senderId['@type'] == 'messageSenderUser') {
          userId = senderId['user_id'] as int? ?? 0;
        }
        final action = update['action'] as Map<String, dynamic>?;
        final actionType = action?['@type'] as String? ?? '';
        if (chatId != null && userId != 0) {
          _onEvent(TelegramEventType.typingUpdate, {
            'chat_id': chatId,
            'user_id': userId,
            'action': actionType,
          });
        }
        break;

      default:
        break;
    }
  }

  void _handleSupergroupUpdate(Map<String, dynamic> update) {
    final sg = update['supergroup'] as Map<String, dynamic>?;
    if (sg == null) return;
    final sgId = sg['id'] as int?;
    final isForum = sg['is_forum'] as bool? ?? false;
    if (sgId == null) return;

    // Find the chat that uses this supergroup and update its forum status
    for (final entry in _chats.entries) {
      if (entry.value.supergroupId == sgId &&
          entry.value.isForum != isForum) {
        _chats[entry.key] = entry.value.copyWith(isForum: isForum);
        _onEvent(TelegramEventType.chatListUpdated, _chats[entry.key]);
        break;
      }
    }
  }

  /// Async check whether a supergroup chat is a forum.
  Future<void> _checkForumStatus(TelegramChat chat) async {
    if (chat.supergroupId == null) return;
    try {
      final result = await _client.sendRequest({
        '@type': 'getSupergroup',
        'supergroup_id': chat.supergroupId,
      });
      if (result['@type'] == 'supergroup') {
        final isForum = result['is_forum'] as bool? ?? false;
        if (isForum && _chats.containsKey(chat.id)) {
          _chats[chat.id] = _chats[chat.id]!.copyWith(isForum: true);
          _onEvent(TelegramEventType.chatListUpdated, _chats[chat.id]);
        }
      }
    } catch (e) {
      LogService().debug('TelegramChat: getSupergroup failed: $e');
    }
  }

  /// Request TDLib to load the main chat list.
  Future<void> loadChats({int limit = 50}) async {
    await _client.sendRequest({
      '@type': 'loadChats',
      'chat_list': {'@type': 'chatListMain'},
      'limit': limit,
    });
  }

  /// Tell TDLib a chat is being viewed (required before getChatHistory).
  Future<void> openChat(int chatId) async {
    final result = await _client.sendRequest({
      '@type': 'openChat',
      'chat_id': chatId,
    });
    stderr.writeln('TDLib: openChat($chatId) -> ${result['@type']}');
  }

  /// Mark messages as read in TDLib — clears unread count for the chat.
  ///
  /// [messageIds] should contain the IDs of messages the user has seen.
  /// Passing the most recent message ID is sufficient to mark everything
  /// up to (and including) that message as read.
  Future<void> viewMessages(int chatId, List<int> messageIds, {
    int? messageThreadId,
    bool forceRead = true,
  }) async {
    if (messageIds.isEmpty) return;
    try {
      final request = <String, dynamic>{
        '@type': 'viewMessages',
        'chat_id': chatId,
        'message_ids': messageIds,
        'force_read': forceRead,
      };
      if (messageThreadId != null) {
        request['message_thread_id'] = messageThreadId;
      }
      await _client.sendRequest(request);
    } catch (e) {
      stderr.writeln('TDLib: viewMessages error: $e');
    }
  }

  /// Tell TDLib a chat is no longer being viewed.
  Future<void> closeChat(int chatId) async {
    await _client.sendRequest({
      '@type': 'closeChat',
      'chat_id': chatId,
    });
  }

  /// Check if a supergroup is a forum.
  Future<bool> isChatForum(int chatId) async {
    final chat = _chats[chatId];
    if (chat == null) return false;
    if (chat.isForum) return true;
    if (chat.supergroupId == null) return false;

    try {
      final result = await _client.sendRequest({
        '@type': 'getSupergroup',
        'supergroup_id': chat.supergroupId,
      });
      if (result['@type'] == 'supergroup') {
        final isForum = result['is_forum'] as bool? ?? false;
        if (isForum) {
          _chats[chatId] = chat.copyWith(isForum: true);
        }
        return isForum;
      }
    } catch (e) {
      LogService().debug('TelegramChat: isChatForum check failed: $e');
    }
    return false;
  }

  /// Get forum topics for a forum supergroup.
  Future<List<TelegramForumTopic>> getForumTopics(
    int chatId, {
    int limit = 50,
  }) async {
    final result = await _client.sendRequest({
      '@type': 'getForumTopics',
      'chat_id': chatId,
      'query': '',
      'offset_date': 0,
      'offset_message_id': 0,
      'offset_message_thread_id': 0,
      'limit': limit,
    });

    if (result['@type'] == 'error') {
      LogService().error(
          'TelegramChat: getForumTopics error: ${result['message']}');
      return [];
    }

    final topics = result['topics'] as List<dynamic>? ?? [];
    return topics
        .whereType<Map<String, dynamic>>()
        .map(TelegramForumTopic.fromTdlib)
        .where((t) => !t.isHidden)
        .toList();
  }

  /// Get message history for a chat.
  Future<List<TelegramMessage>> getChatHistory(
    int chatId, {
    int fromMessageId = 0,
    int limit = 50,
  }) async {
    stderr.writeln('TDLib: getChatHistory chatId=$chatId fromMsg=$fromMessageId limit=$limit');

    final result = await _client.sendRequest({
      '@type': 'getChatHistory',
      'chat_id': chatId,
      'from_message_id': fromMessageId,
      'offset': 0,
      'limit': limit,
      'only_local': false,
    });

    final rtype = result['@type'];
    stderr.writeln('TDLib: getChatHistory response @type=$rtype');

    if (rtype == 'error') {
      final msg = result['message'] ?? result['code'];
      stderr.writeln('TDLib: getChatHistory ERROR: $msg');
      return [];
    }

    final rawMessages = result['messages'] as List<dynamic>? ?? [];
    final nonNull = rawMessages.where((m) => m != null).length;
    final totalCount = result['total_count'] ?? '?';
    stderr.writeln('TDLib: getChatHistory total_count=$totalCount '
        'rawLength=${rawMessages.length} nonNull=$nonNull');

    if (rawMessages.isNotEmpty) {
      // Log the first message content type for debugging
      final first = rawMessages.firstWhere((m) => m != null, orElse: () => null);
      if (first is Map<String, dynamic>) {
        final content = first['content'] as Map<String, dynamic>?;
        stderr.writeln('TDLib: first message content @type=${content?['@type']}');
      }
    }

    final messages = rawMessages
        .whereType<Map<String, dynamic>>()
        .map(TelegramMessage.fromTdlib)
        .toList();
    _cache?.cacheMessages(chatId, messages);
    return messages;
  }

  /// Get message history for a specific forum topic thread.
  Future<List<TelegramMessage>> getTopicHistory(
    int chatId,
    int messageThreadId, {
    int fromMessageId = 0,
    int limit = 50,
  }) async {
    stderr.writeln('TDLib: getTopicHistory chatId=$chatId thread=$messageThreadId');

    final result = await _client.sendRequest({
      '@type': 'getMessageThreadHistory',
      'chat_id': chatId,
      'message_id': messageThreadId,
      'from_message_id': fromMessageId,
      'offset': 0,
      'limit': limit,
    });

    final rtype = result['@type'];
    stderr.writeln('TDLib: getTopicHistory response @type=$rtype');

    if (rtype == 'error') {
      final msg = result['message'] ?? result['code'];
      stderr.writeln('TDLib: getTopicHistory ERROR: $msg');
      return [];
    }

    final rawMessages = result['messages'] as List<dynamic>? ?? [];
    final nonNull = rawMessages.where((m) => m != null).length;
    stderr.writeln('TDLib: getTopicHistory rawLength=${rawMessages.length} nonNull=$nonNull');

    final messages = rawMessages
        .whereType<Map<String, dynamic>>()
        .map(TelegramMessage.fromTdlib)
        .toList();
    _cache?.cacheMessages(chatId, messages);
    return messages;
  }

  /// Get a single message by chat ID and message ID.
  Future<TelegramMessage?> getMessage(int chatId, int messageId) async {
    try {
      final result = await _client.sendRequest({
        '@type': 'getMessage',
        'chat_id': chatId,
        'message_id': messageId,
      });
      if (result['@type'] == 'message') {
        return TelegramMessage.fromTdlib(result);
      }
    } catch (e) {
      LogService().debug('TelegramChat: getMessage($chatId, $messageId) failed: $e');
    }
    return null;
  }

  /// Send a text message to a chat (optionally within a forum topic thread).
  Future<TelegramMessage?> sendMessage(
    int chatId,
    String text, {
    int? messageThreadId,
    int? replyToMessageId,
  }) async {
    final request = <String, dynamic>{
      '@type': 'sendMessage',
      'chat_id': chatId,
      'input_message_content': {
        '@type': 'inputMessageText',
        'text': {
          '@type': 'formattedText',
          'text': text,
        },
      },
    };
    if (messageThreadId != null) {
      request['message_thread_id'] = messageThreadId;
    }
    if (replyToMessageId != null) {
      request['reply_to'] = {
        '@type': 'inputMessageReplyToMessage',
        'message_id': replyToMessageId,
      };
    }

    final result = await _client.sendRequest(request);

    if (result['@type'] == 'message') {
      return TelegramMessage.fromTdlib(result);
    }
    return null;
  }

  /// Add an emoji reaction to a message.
  Future<bool> addMessageReaction(
    int chatId,
    int messageId,
    String emoji, {
    bool isBig = false,
  }) async {
    try {
      final result = await _client.sendRequest({
        '@type': 'addMessageReaction',
        'chat_id': chatId,
        'message_id': messageId,
        'reaction_type': {
          '@type': 'reactionTypeEmoji',
          'emoji': emoji,
        },
        'is_big': isBig,
        'update_recent_reactions': true,
      });
      if (result['@type'] != 'ok') {
        stderr.writeln('TDLib: addMessageReaction error: ${result['message'] ?? result}');
      }
      return result['@type'] == 'ok';
    } catch (e) {
      LogService().error('TelegramChat: addMessageReaction failed: $e');
      return false;
    }
  }

  /// Delete messages from a chat.
  Future<bool> deleteMessages(
    int chatId,
    List<int> messageIds, {
    bool revoke = true,
  }) async {
    try {
      final result = await _client.sendRequest({
        '@type': 'deleteMessages',
        'chat_id': chatId,
        'message_ids': messageIds,
        'revoke': revoke,
      });
      return result['@type'] == 'ok';
    } catch (e) {
      LogService().error('TelegramChat: deleteMessages failed: $e');
      return false;
    }
  }

  /// Get a user by ID, with in-memory cache.
  ///
  /// Returns cached user immediately if available. Otherwise fetches from
  /// TDLib and caches the result. Concurrent requests for the same user
  /// are de-duplicated.
  Future<TelegramUser?> getUser(int userId) async {
    if (userId == 0) return null;
    final cached = _users[userId];
    if (cached != null) return cached;

    // De-duplicate concurrent fetches
    if (_pendingUserRequests.containsKey(userId)) {
      return _pendingUserRequests[userId];
    }

    final future = _fetchUser(userId);
    _pendingUserRequests[userId] = future;
    try {
      return await future;
    } finally {
      _pendingUserRequests.remove(userId);
    }
  }

  Future<TelegramUser?> _fetchUser(int userId) async {
    try {
      final result = await _client.sendRequest({
        '@type': 'getUser',
        'user_id': userId,
      });
      if (result['@type'] == 'user') {
        // Extract profile photo path — download if needed
        String? profilePhotoPath;
        final profilePhoto = result['profile_photo'] as Map<String, dynamic>?;
        if (profilePhoto != null) {
          final small = profilePhoto['small'] as Map<String, dynamic>?;
          final local = small?['local'] as Map<String, dynamic>?;
          final isDownloaded =
              local?['is_downloading_completed'] as bool? ?? false;
          final path = local?['path'] as String?;
          if (isDownloaded && path != null && path.isNotEmpty) {
            profilePhotoPath = path;
          } else if (small != null) {
            // Download the profile photo before returning
            final fileId = small['id'] as int? ?? 0;
            if (fileId != 0) {
              profilePhotoPath = await _downloadFile(fileId);
            }
          }
        }
        final user = TelegramUser(
          id: result['id'] as int,
          firstName: result['first_name'] as String? ?? '',
          lastName: result['last_name'] as String?,
          username: (result['usernames']
              as Map<String, dynamic>?)?['editable_username'] as String?,
          phoneNumber: result['phone_number'] as String?,
          profilePhotoPath: profilePhotoPath,
        );
        _users[userId] = user;
        return user;
      }
    } catch (e) {
      LogService().debug('TelegramChat: getUser($userId) failed: $e');
    }
    return null;
  }

  /// Get a cached user (synchronous, returns null if not fetched yet).
  TelegramUser? getCachedUser(int userId) => _users[userId];

  /// Download a TDLib file by its file ID. Returns the local path on success.
  Future<String?> downloadFile(int fileId, {int priority = 5}) =>
      _downloadFile(fileId, priority: priority);

  Future<String?> _downloadFile(int fileId, {int priority = 5}) async {
    if (fileId == 0) return null;
    try {
      final result = await _client.sendRequest({
        '@type': 'downloadFile',
        'file_id': fileId,
        'priority': priority,
        'offset': 0,
        'limit': 0,
        'synchronous': true,
      });
      if (result['@type'] == 'file') {
        final local = result['local'] as Map<String, dynamic>?;
        final isDownloaded =
            local?['is_downloading_completed'] as bool? ?? false;
        final path = local?['path'] as String?;
        if (isDownloaded && path != null && path.isNotEmpty) {
          return path;
        }
      }
    } catch (e) {
      LogService().debug('TelegramChat: downloadFile($fileId) failed: $e');
    }
    return null;
  }

  /// Download the chat photo (small variant) for a given chat ID.
  /// Returns the local file path on success, or null.
  /// Also caches the photo bytes in SQLite for offline access.
  Future<String?> downloadChatPhoto(int chatId) async {
    final chat = _chats[chatId];
    if (chat == null || chat.photoSmallFileId == null || chat.photoSmallFileId == 0) return null;
    if (chat.photoPath != null) return chat.photoPath;
    final path = await _downloadFile(chat.photoSmallFileId!);
    if (path != null) {
      _chats[chatId] = chat.copyWith(photoPath: path);
      // Cache photo blob for offline access
      try {
        final bytes = File(path).readAsBytesSync();
        if (bytes.isNotEmpty) {
          _cache?.storeChatPhoto(chatId, bytes);
        }
      } catch (_) {}
    }
    return path;
  }

  /// Download custom emoji icons for forum topics.
  ///
  /// Resolves custom emoji IDs via TDLib's `getCustomEmojiStickers`,
  /// downloads each sticker file, and caches the bytes in the per-chat DB.
  /// Returns a map of messageThreadId → icon bytes.
  Future<Map<int, Uint8List>> downloadTopicIcons(
    int chatId,
    List<TelegramForumTopic> topics,
  ) async {
    final result = <int, Uint8List>{};

    // Build a map of customEmojiId → list of messageThreadIds that use it
    final emojiToThreads = <int, List<int>>{};
    for (final t in topics) {
      if (t.iconCustomEmojiId != 0) {
        emojiToThreads.putIfAbsent(t.iconCustomEmojiId, () => []).add(t.messageThreadId);
      }
    }
    if (emojiToThreads.isEmpty) return result;

    try {
      final emojiIds = emojiToThreads.keys.toList();
      stderr.writeln('TDLib: getCustomEmojiStickers for ${emojiIds.length} IDs');

      final response = await _client.sendRequest({
        '@type': 'getCustomEmojiStickers',
        'custom_emoji_ids': emojiIds,
      });

      if (response['@type'] != 'stickers') {
        stderr.writeln('TDLib: getCustomEmojiStickers unexpected: ${response['@type']}');
        return result;
      }

      final stickers = response['stickers'] as List<dynamic>? ?? [];
      stderr.writeln('TDLib: got ${stickers.length} stickers for topic icons');

      for (final s in stickers) {
        final sticker = s as Map<String, dynamic>?;
        if (sticker == null) continue;

        // Extract custom_emoji_id from full_type to match back to topics
        final fullType = sticker['full_type'] as Map<String, dynamic>?;
        final emojiId = fullType?['custom_emoji_id'] as int? ?? 0;
        final threadIds = emojiToThreads[emojiId];
        if (threadIds == null || threadIds.isEmpty) continue;

        final stickerFile = sticker['sticker'] as Map<String, dynamic>?;
        final fileId = stickerFile?['id'] as int? ?? 0;
        if (fileId == 0) continue;

        final path = await _downloadFile(fileId);
        if (path == null) continue;

        try {
          final bytes = File(path).readAsBytesSync();
          if (bytes.isEmpty) continue;

          for (final threadId in threadIds) {
            result[threadId] = bytes;
            _cache?.storeTopicPhoto(chatId, threadId, bytes);
          }
        } catch (e) {
          stderr.writeln('TDLib: downloadTopicIcons read error: $e');
        }
      }
    } catch (e) {
      stderr.writeln('TDLib: downloadTopicIcons error: $e');
      LogService().error('TelegramChat: downloadTopicIcons failed: $e');
    }

    return result;
  }

  /// Get a single chat by ID.
  Future<TelegramChat?> getChat(int chatId) async {
    final result = await _client.sendRequest({
      '@type': 'getChat',
      'chat_id': chatId,
    });

    if (result['@type'] == 'chat') {
      final chat = TelegramChat.fromTdlib(result);
      _chats[chat.id] = chat;
      return chat;
    }
    return null;
  }
}
