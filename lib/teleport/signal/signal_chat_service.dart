/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Signal conversation and message operations.
 * Key differences from TelegramChatService:
 *   - Conversations identified by UUID strings (not int64 IDs)
 *   - Users identified by UUID strings (not int user IDs)
 *   - No forum topics (Signal has no equivalent)
 *   - Message PK is (timestamp, senderUuid) composite key
 */

import 'dart:async';
import 'dart:io';

import '../../services/log_service.dart';
import 'models/signal_chat.dart';
import 'models/signal_message.dart';
import 'models/signal_user.dart';
import 'signal_cache_service.dart';
import 'signal_client.dart';
import 'signal_service.dart';

/// Callback for chat events (conversation list updates, new messages).
typedef SignalChatEventCallback = void Function(
    SignalEventType type, dynamic data);

/// Manages Signal conversation list and messaging.
class SignalChatService {
  final SignalClient _client;
  final SignalChatEventCallback _onEvent;
  final SignalCacheService? _cache;

  final Map<String, SignalChat> _conversations = {};
  final Map<String, SignalUser> _contacts = {};
  final Map<String, Future<SignalUser?>> _pendingContactRequests = {};

  /// All loaded conversations, sorted by last message date (newest first).
  List<SignalChat> get conversations {
    final list = _conversations.values.toList();
    list.sort((a, b) {
      final aDate = a.lastMessage?.timestamp ?? 0;
      final bDate = b.lastMessage?.timestamp ?? 0;
      return bDate.compareTo(aDate);
    });
    return list;
  }

  /// Get a cached conversation by ID (null if not loaded).
  SignalChat? getCachedConversation(String conversationId) =>
      _conversations[conversationId];

  SignalChatService(this._client, this._onEvent,
      {SignalCacheService? cacheService})
      : _cache = cacheService;

  /// Handle a Signal update related to conversations/messages.
  void handleUpdate(Map<String, dynamic> update) {
    final type = update['@type'] as String? ?? '';

    switch (type) {
      case 'updateNewMessage':
        _handleNewMessage(update);
        break;

      case 'updateMessageStatus':
        _handleMessageStatus(update);
        break;

      case 'updateTyping':
        _handleTyping(update);
        break;

      case 'updateContact':
        _handleContactUpdate(update);
        break;

      default:
        break;
    }
  }

  void _handleNewMessage(Map<String, dynamic> update) {
    final msgJson = update['message'] as Map<String, dynamic>?;
    if (msgJson == null) return;

    final msg = SignalMessage.fromJson(msgJson);

    // Determine conversation ID: groupKey for group messages, senderUuid for direct
    final conversationId = msg.groupKey ?? msg.senderUuid;

    // Cache the message
    _cache?.cacheMessage(conversationId, msg);

    // Update the conversation's last message
    if (_conversations.containsKey(conversationId)) {
      _conversations[conversationId] =
          _conversations[conversationId]!.copyWith(lastMessage: msg);
      _onEvent(SignalEventType.chatListUpdated, _conversations[conversationId]);
    }

    _onEvent(SignalEventType.newMessage, msg);
  }

  void _handleMessageStatus(Map<String, dynamic> update) {
    final conversationId = update['conversation_id'] as String?;
    final timestamp = update['timestamp'] as int?;
    final senderUuid = update['sender_uuid'] as String?;
    final status = update['status'] as String?;

    if (conversationId != null && timestamp != null && senderUuid != null) {
      _onEvent(SignalEventType.messageStatusUpdated, {
        'conversation_id': conversationId,
        'timestamp': timestamp,
        'sender_uuid': senderUuid,
        'status': status,
      });
    }
  }

  void _handleTyping(Map<String, dynamic> update) {
    final conversationId = update['conversation_id'] as String?;
    final senderUuid = update['sender_uuid'] as String?;
    final isTyping = update['is_typing'] as bool? ?? false;

    if (conversationId != null && senderUuid != null) {
      _onEvent(SignalEventType.typingUpdate, {
        'conversation_id': conversationId,
        'sender_uuid': senderUuid,
        'is_typing': isTyping,
      });
    }
  }

  void _handleContactUpdate(Map<String, dynamic> update) {
    final contactJson = update['contact'] as Map<String, dynamic>?;
    if (contactJson == null) return;

    final user = SignalUser.fromJson(contactJson);
    _contacts[user.uuid] = user;

    _onEvent(SignalEventType.contactUpdated, user);
  }

  /// Request the Signal bridge to load the conversation list.
  Future<List<SignalChat>> loadConversations({int limit = 50}) async {
    final result = await _client.sendRequest({
      '@type': 'getConversations',
      'limit': limit,
    });

    if (result['@type'] == 'error') {
      final msg = result['message'] ?? result['code'];
      stderr.writeln('Signal: getConversations ERROR: $msg');
      return [];
    }

    final rawConversations = result['conversations'] as List<dynamic>? ?? [];
    final conversations = rawConversations
        .whereType<Map<String, dynamic>>()
        .map(SignalChat.fromJson)
        .toList();

    for (final conv in conversations) {
      _conversations[conv.id] = conv;
    }

    _onEvent(SignalEventType.chatListUpdated, null);
    return conversations;
  }

  /// Get message history for a conversation.
  Future<List<SignalMessage>> getMessages(
    String conversationId, {
    int? beforeTimestamp,
    int limit = 50,
  }) async {
    stderr.writeln(
        'Signal: getMessages conv=$conversationId before=$beforeTimestamp limit=$limit');

    final request = <String, dynamic>{
      '@type': 'getMessages',
      'conversation_id': conversationId,
      'limit': limit,
    };
    if (beforeTimestamp != null) {
      request['before_timestamp'] = beforeTimestamp;
    }

    final result = await _client.sendRequest(request);

    final rtype = result['@type'];
    stderr.writeln('Signal: getMessages response @type=$rtype');

    if (rtype == 'error') {
      final msg = result['message'] ?? result['code'];
      stderr.writeln('Signal: getMessages ERROR: $msg');
      return [];
    }

    final rawMessages = result['messages'] as List<dynamic>? ?? [];
    stderr.writeln(
        'Signal: getMessages rawLength=${rawMessages.length}');

    final messages = rawMessages
        .whereType<Map<String, dynamic>>()
        .map(SignalMessage.fromJson)
        .toList();

    _cache?.cacheMessages(conversationId, messages);
    return messages;
  }

  /// Send a text message to a conversation.
  Future<SignalMessage?> sendMessage(
    String conversationId,
    String text, {
    int? quoteTimestamp,
  }) async {
    final request = <String, dynamic>{
      '@type': 'sendMessage',
      'conversation_id': conversationId,
      'text': text,
    };
    if (quoteTimestamp != null) {
      request['quote_timestamp'] = quoteTimestamp;
    }

    final result = await _client.sendRequest(request);

    if (result['@type'] == 'message') {
      final msg = SignalMessage.fromJson(result);
      _cache?.cacheMessage(conversationId, msg);
      return msg;
    }
    return null;
  }

  /// Send a file attachment to a conversation.
  Future<SignalMessage?> sendAttachment(
    String conversationId,
    String filePath, {
    String? caption,
    String? contentType,
  }) async {
    final request = <String, dynamic>{
      '@type': 'sendAttachment',
      'conversation_id': conversationId,
      'file_path': filePath,
    };
    if (caption != null) request['caption'] = caption;
    if (contentType != null) request['content_type'] = contentType;

    final result = await _client.sendRequest(request);

    if (result['@type'] == 'message') {
      return SignalMessage.fromJson(result);
    }
    return null;
  }

  /// Send an emoji reaction to a message.
  Future<bool> sendReaction(
    String conversationId,
    int targetTimestamp,
    String targetSenderUuid,
    String emoji, {
    bool remove = false,
  }) async {
    try {
      final result = await _client.sendRequest({
        '@type': 'sendReaction',
        'conversation_id': conversationId,
        'target_timestamp': targetTimestamp,
        'target_sender_uuid': targetSenderUuid,
        'emoji': emoji,
        'remove': remove,
      });
      if (result['@type'] != 'ok') {
        stderr.writeln(
            'Signal: sendReaction error: ${result['message'] ?? result}');
      }
      return result['@type'] == 'ok';
    } catch (e) {
      LogService().error('SignalChat: sendReaction failed: $e');
      return false;
    }
  }

  /// Get a contact/user by UUID, with in-memory cache.
  ///
  /// Returns cached contact immediately if available. Otherwise fetches from
  /// Signal bridge and caches the result. Concurrent requests for the same
  /// UUID are de-duplicated.
  Future<SignalUser?> getContact(String uuid) async {
    if (uuid.isEmpty) return null;
    final cached = _contacts[uuid];
    if (cached != null) return cached;

    // De-duplicate concurrent fetches
    if (_pendingContactRequests.containsKey(uuid)) {
      return _pendingContactRequests[uuid];
    }

    final future = _fetchContact(uuid);
    _pendingContactRequests[uuid] = future;
    try {
      return await future;
    } finally {
      _pendingContactRequests.remove(uuid);
    }
  }

  Future<SignalUser?> _fetchContact(String uuid) async {
    try {
      final result = await _client.sendRequest({
        '@type': 'getContact',
        'uuid': uuid,
      });
      if (result['@type'] == 'contact') {
        final user = SignalUser.fromJson(result);
        _contacts[uuid] = user;
        return user;
      }
    } catch (e) {
      LogService().debug('SignalChat: getContact($uuid) failed: $e');
    }
    return null;
  }

  /// Get a cached contact (synchronous, returns null if not fetched yet).
  SignalUser? getCachedContact(String uuid) => _contacts[uuid];

  /// Get a single conversation by ID.
  Future<SignalChat?> getConversation(String conversationId) async {
    final result = await _client.sendRequest({
      '@type': 'getConversations',
      'conversation_id': conversationId,
      'limit': 1,
    });

    if (result['@type'] == 'error') return null;

    final rawConversations = result['conversations'] as List<dynamic>? ?? [];
    if (rawConversations.isEmpty) return null;

    final conv = SignalChat.fromJson(
        rawConversations.first as Map<String, dynamic>);
    _conversations[conv.id] = conv;
    return conv;
  }
}
