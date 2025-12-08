/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;

import '../models/chat_message.dart';
import '../models/dm_conversation.dart';
import '../models/profile.dart';
import '../platform/file_system_service.dart';
import '../util/event_bus.dart';
import 'log_service.dart';
import 'profile_service.dart';
import 'signing_service.dart';
import 'chat_service.dart';

/// Service for managing 1:1 direct message conversations
class DirectMessageService {
  static final DirectMessageService _instance = DirectMessageService._internal();
  factory DirectMessageService() => _instance;
  DirectMessageService._internal();

  /// Base path for device storage
  String? _basePath;

  /// Cached conversations
  final Map<String, DMConversation> _conversations = {};

  /// Stream controller for conversation updates
  final _conversationsController = StreamController<List<DMConversation>>.broadcast();
  Stream<List<DMConversation>> get conversationsStream => _conversationsController.stream;

  /// Initialize the service
  Future<void> initialize() async {
    if (_basePath != null) return;

    if (kIsWeb) {
      _basePath = '/geogram/devices';
    } else {
      final appDir = await getApplicationDocumentsDirectory();
      _basePath = '${appDir.path}/geogram/devices';

      final devicesDir = Directory(_basePath!);
      if (!await devicesDir.exists()) {
        await devicesDir.create(recursive: true);
      }
    }

    LogService().log('DirectMessageService initialized at: $_basePath');
    await _loadConversations();
  }

  /// Get the current user's callsign
  String get _myCallsign => ProfileService().getProfile().callsign;

  /// Get the current user's profile
  Profile get _myProfile => ProfileService().getProfile();

  /// Get DM path for a conversation with another callsign
  /// Returns: devices/{otherCallsign}/chat/{myCallsign}
  String getDMPath(String otherCallsign) {
    return '$_basePath/${otherCallsign.toUpperCase()}/chat/${_myCallsign.toUpperCase()}';
  }

  /// Get or create a DM conversation with another device
  Future<DMConversation> getOrCreateConversation(String otherCallsign) async {
    await initialize();

    final normalizedCallsign = otherCallsign.toUpperCase();

    // Check cache first
    if (_conversations.containsKey(normalizedCallsign)) {
      return _conversations[normalizedCallsign]!;
    }

    final path = getDMPath(normalizedCallsign);

    // Create directory structure if needed
    if (kIsWeb) {
      final fs = FileSystemService.instance;
      if (!await fs.exists(path)) {
        await fs.createDirectory(path, recursive: true);
        await fs.createDirectory('$path/files', recursive: true);
        await _createConfig(path, normalizedCallsign);
      }
    } else {
      final dir = Directory(path);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
        await Directory('$path/files').create();
        await _createConfig(path, normalizedCallsign);
      }
    }

    final conversation = DMConversation(
      otherCallsign: normalizedCallsign,
      myCallsign: _myCallsign,
      path: path,
    );

    _conversations[normalizedCallsign] = conversation;
    _notifyListeners();

    return conversation;
  }

  /// Create config.json for a DM conversation
  Future<void> _createConfig(String path, String otherCallsign) async {
    final config = {
      'id': otherCallsign,
      'name': 'Chat with $otherCallsign',
      'type': 'direct',
      'visibility': 'PRIVATE',
      'participants': [_myCallsign, otherCallsign],
      'created': DateTime.now().toIso8601String(),
    };

    final content = const JsonEncoder.withIndent('  ').convert(config);

    if (kIsWeb) {
      final fs = FileSystemService.instance;
      await fs.writeAsString('$path/config.json', content);
    } else {
      final file = File(p.join(path, 'config.json'));
      await file.writeAsString(content);
    }
  }

  /// List all DM conversations
  Future<List<DMConversation>> listConversations() async {
    await initialize();
    await _loadConversations();

    final list = _conversations.values.toList();
    // Sort by last message time, most recent first
    list.sort((a, b) {
      if (a.lastMessageTime == null && b.lastMessageTime == null) return 0;
      if (a.lastMessageTime == null) return 1;
      if (b.lastMessageTime == null) return -1;
      return b.lastMessageTime!.compareTo(a.lastMessageTime!);
    });

    return list;
  }

  /// Load existing conversations from disk
  Future<void> _loadConversations() async {
    if (_basePath == null) return;

    try {
      if (kIsWeb) {
        final fs = FileSystemService.instance;
        if (!await fs.exists(_basePath!)) return;

        final entities = await fs.list(_basePath!);
        for (final entity in entities) {
          if (entity.type == FsEntityType.directory) {
            await _loadConversationFromPath(entity.path);
          }
        }
      } else {
        final devicesDir = Directory(_basePath!);
        if (!await devicesDir.exists()) return;

        await for (final entity in devicesDir.list()) {
          if (entity is Directory) {
            await _loadConversationFromPath(entity.path);
          }
        }
      }
    } catch (e) {
      LogService().log('Error loading DM conversations: $e');
    }
  }

  /// Load a single conversation from its path
  Future<void> _loadConversationFromPath(String devicePath) async {
    final otherCallsign = p.basename(devicePath).toUpperCase();
    final chatPath = '$devicePath/chat/${_myCallsign.toUpperCase()}';

    bool exists;
    if (kIsWeb) {
      exists = await FileSystemService.instance.exists(chatPath);
    } else {
      exists = await Directory(chatPath).exists();
    }

    if (!exists) return;

    final conversation = DMConversation(
      otherCallsign: otherCallsign,
      myCallsign: _myCallsign,
      path: chatPath,
    );

    // Load messages to update conversation metadata
    final messages = await loadMessages(otherCallsign, limit: 1);
    if (messages.isNotEmpty) {
      conversation.updateFromMessages(messages);
    }

    _conversations[otherCallsign] = conversation;
  }

  /// Send a message in a DM conversation
  Future<void> sendMessage(String otherCallsign, String content) async {
    await initialize();

    final conversation = await getOrCreateConversation(otherCallsign);
    final profile = _myProfile;

    // Create the message
    final message = ChatMessage.now(
      author: profile.callsign,
      content: content,
    );

    // Sign the message
    final signingService = SigningService();
    await signingService.initialize();

    if (signingService.canSign(profile)) {
      final signature = await signingService.generateSignature(
        content,
        {'channel': otherCallsign, 'type': 'dm'},
        profile,
      );
      if (signature != null) {
        message.setMeta('npub', profile.npub);
        message.setMeta('signature', signature);
      }
    }

    // Save the message
    await _saveMessage(conversation.path, message);

    // Update conversation metadata
    conversation.lastMessageTime = message.dateTime;
    conversation.lastMessagePreview = content;
    conversation.lastMessageAuthor = profile.callsign;

    // Fire event
    _fireMessageEvent(message, otherCallsign, fromSync: false);

    _notifyListeners();
  }

  /// Save a message to the messages.txt file
  Future<void> _saveMessage(String path, ChatMessage message) async {
    final messagesPath = '$path/messages.txt';

    if (kIsWeb) {
      final fs = FileSystemService.instance;

      // Check if file exists and needs header
      final needsHeader = !await fs.exists(messagesPath);

      final buffer = StringBuffer();
      if (needsHeader) {
        buffer.write('# DM: Direct Chat from ${message.datePortion}\n');
      } else {
        final existing = await fs.readAsString(messagesPath);
        buffer.write(existing);
      }
      buffer.write('\n');
      buffer.write(message.exportAsText());
      buffer.write('\n');

      await fs.writeAsString(messagesPath, buffer.toString());
    } else {
      final messagesFile = File(p.join(path, 'messages.txt'));

      final needsHeader = !await messagesFile.exists();
      final sink = messagesFile.openWrite(mode: FileMode.append);

      try {
        if (needsHeader) {
          sink.write('# DM: Direct Chat from ${message.datePortion}\n');
        }
        sink.write('\n');
        sink.write(message.exportAsText());
        sink.write('\n');
        await sink.flush();
      } finally {
        await sink.close();
      }
    }
  }

  /// Load messages from a DM conversation
  Future<List<ChatMessage>> loadMessages(String otherCallsign, {int limit = 100}) async {
    await initialize();

    final normalizedCallsign = otherCallsign.toUpperCase();
    final path = getDMPath(normalizedCallsign);
    final messagesPath = '$path/messages.txt';

    try {
      String? content;

      if (kIsWeb) {
        final fs = FileSystemService.instance;
        if (!await fs.exists(messagesPath)) return [];
        content = await fs.readAsString(messagesPath);
      } else {
        final file = File(p.join(path, 'messages.txt'));
        if (!await file.exists()) return [];
        content = await file.readAsString();
      }

      final messages = ChatService.parseMessageText(content);

      // Sort by timestamp
      messages.sort();

      // Apply limit
      if (messages.length > limit) {
        return messages.sublist(messages.length - limit);
      }

      return messages;
    } catch (e) {
      LogService().log('Error loading DM messages: $e');
      return [];
    }
  }

  /// Load messages since a specific timestamp
  Future<List<ChatMessage>> loadMessagesSince(String otherCallsign, String sinceTimestamp) async {
    final allMessages = await loadMessages(otherCallsign, limit: 99999);
    return allMessages.where((msg) => msg.timestamp.compareTo(sinceTimestamp) > 0).toList();
  }

  /// Sync messages with a remote device
  Future<DMSyncResult> syncWithDevice(String callsign, {String? deviceUrl}) async {
    await initialize();

    final normalizedCallsign = callsign.toUpperCase();
    final conversation = _conversations[normalizedCallsign];
    final lastSync = conversation?.lastSyncTime?.toIso8601String() ?? '';

    try {
      // Determine the URL to use
      String? baseUrl = deviceUrl;
      if (baseUrl == null) {
        // Try to find the device URL from DevicesService
        // For now, we'll return a failed result if no URL provided
        return DMSyncResult(
          otherCallsign: normalizedCallsign,
          messagesReceived: 0,
          messagesSent: 0,
          success: false,
          error: 'No device URL available',
        );
      }

      baseUrl = baseUrl.replaceFirst('ws://', 'http://').replaceFirst('wss://', 'https://');

      // Step 1: Fetch remote messages
      final fetchUrl = '$baseUrl/$_myCallsign/api/dm/sync/$normalizedCallsign?since=$lastSync';
      final fetchResponse = await http.get(Uri.parse(fetchUrl)).timeout(const Duration(seconds: 10));

      List<ChatMessage> remoteMessages = [];
      if (fetchResponse.statusCode == 200) {
        final data = json.decode(fetchResponse.body);
        if (data['messages'] is List) {
          for (final msgJson in data['messages']) {
            remoteMessages.add(ChatMessage.fromJson(msgJson));
          }
        }
      }

      // Step 2: Merge remote messages into local
      int received = 0;
      if (remoteMessages.isNotEmpty) {
        received = await _mergeMessages(normalizedCallsign, remoteMessages);
      }

      // Step 3: Send local messages to remote
      final localMessages = await loadMessagesSince(normalizedCallsign, lastSync);
      int sent = 0;

      if (localMessages.isNotEmpty) {
        final pushUrl = '$baseUrl/$_myCallsign/api/dm/sync/$normalizedCallsign';
        final pushResponse = await http.post(
          Uri.parse(pushUrl),
          headers: {'Content-Type': 'application/json'},
          body: json.encode({
            'messages': localMessages.map((m) => m.toJson()).toList(),
          }),
        ).timeout(const Duration(seconds: 10));

        if (pushResponse.statusCode == 200) {
          final data = json.decode(pushResponse.body);
          sent = data['accepted'] as int? ?? localMessages.length;
        }
      }

      // Update conversation sync time
      if (conversation != null) {
        conversation.lastSyncTime = DateTime.now();
      }

      // Fire sync event
      _fireSyncEvent(normalizedCallsign, received, sent, true);

      _notifyListeners();

      return DMSyncResult(
        otherCallsign: normalizedCallsign,
        messagesReceived: received,
        messagesSent: sent,
        success: true,
      );
    } catch (e) {
      LogService().log('Error syncing with $callsign: $e');

      _fireSyncEvent(normalizedCallsign, 0, 0, false, e.toString());

      return DMSyncResult(
        otherCallsign: normalizedCallsign,
        messagesReceived: 0,
        messagesSent: 0,
        success: false,
        error: e.toString(),
      );
    }
  }

  /// Merge incoming messages using timestamp-based deduplication
  Future<int> _mergeMessages(String otherCallsign, List<ChatMessage> incoming) async {
    final local = await loadMessages(otherCallsign, limit: 99999);

    // Create set of existing message identifiers (timestamp + author)
    final existing = <String>{};
    for (final msg in local) {
      existing.add('${msg.timestamp}|${msg.author}');
    }

    // Find new messages that don't exist locally
    final newMessages = <ChatMessage>[];
    for (final msg in incoming) {
      final id = '${msg.timestamp}|${msg.author}';
      if (!existing.contains(id)) {
        // Verify signature if present
        if (_verifySignature(msg)) {
          newMessages.add(msg);
        }
      }
    }

    // Append new messages
    if (newMessages.isNotEmpty) {
      final path = getDMPath(otherCallsign);
      for (final msg in newMessages) {
        await _saveMessage(path, msg);

        // Fire event for each new message
        _fireMessageEvent(msg, otherCallsign, fromSync: true);
      }

      // Update conversation metadata
      final conversation = _conversations[otherCallsign];
      if (conversation != null) {
        newMessages.sort((a, b) => b.timestamp.compareTo(a.timestamp));
        final latest = newMessages.first;
        if (conversation.lastMessageTime == null ||
            latest.dateTime.isAfter(conversation.lastMessageTime!)) {
          conversation.lastMessageTime = latest.dateTime;
          conversation.lastMessagePreview = latest.content;
          conversation.lastMessageAuthor = latest.author;
        }
        conversation.unreadCount += newMessages.length;
      }
    }

    return newMessages.length;
  }

  /// Verify a message signature
  bool _verifySignature(ChatMessage message) {
    // If no signature, accept the message
    if (!message.isSigned) return true;

    // TODO: Implement actual signature verification using NostrCrypto
    // For now, accept signed messages (verification will be added)
    return true;
  }

  /// Fire DirectMessageReceivedEvent
  void _fireMessageEvent(ChatMessage msg, String otherCallsign, {required bool fromSync}) {
    EventBus().fire(DirectMessageReceivedEvent(
      fromCallsign: msg.author,
      toCallsign: msg.author == _myCallsign ? otherCallsign : _myCallsign,
      content: msg.content,
      messageTimestamp: msg.timestamp,
      npub: msg.npub,
      signature: msg.signature,
      verified: msg.isVerified,
      fromSync: fromSync,
    ));
  }

  /// Fire DirectMessageSyncEvent
  void _fireSyncEvent(String callsign, int received, int sent, bool success, [String? error]) {
    EventBus().fire(DirectMessageSyncEvent(
      otherCallsign: callsign,
      newMessages: received,
      sentMessages: sent,
      success: success,
      error: error,
    ));
  }

  /// Mark conversation as read
  Future<void> markAsRead(String otherCallsign) async {
    final conversation = _conversations[otherCallsign.toUpperCase()];
    if (conversation != null) {
      conversation.unreadCount = 0;
      _notifyListeners();
    }
  }

  /// Delete a conversation
  Future<void> deleteConversation(String otherCallsign) async {
    await initialize();

    final normalizedCallsign = otherCallsign.toUpperCase();
    final path = getDMPath(normalizedCallsign);

    try {
      if (kIsWeb) {
        final fs = FileSystemService.instance;
        if (await fs.exists(path)) {
          await fs.delete(path, recursive: true);
        }
      } else {
        final dir = Directory(path);
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      }

      _conversations.remove(normalizedCallsign);
      _notifyListeners();
    } catch (e) {
      LogService().log('Error deleting conversation: $e');
    }
  }

  /// Get a specific conversation
  DMConversation? getConversation(String otherCallsign) {
    return _conversations[otherCallsign.toUpperCase()];
  }

  /// Update online status for a conversation
  void updateOnlineStatus(String otherCallsign, bool isOnline) {
    final conversation = _conversations[otherCallsign.toUpperCase()];
    if (conversation != null) {
      conversation.isOnline = isOnline;
      _notifyListeners();
    }
  }

  /// Notify listeners of changes
  void _notifyListeners() {
    final list = _conversations.values.toList();
    list.sort((a, b) {
      if (a.lastMessageTime == null && b.lastMessageTime == null) return 0;
      if (a.lastMessageTime == null) return 1;
      if (b.lastMessageTime == null) return -1;
      return b.lastMessageTime!.compareTo(a.lastMessageTime!);
    });
    _conversationsController.add(list);
  }

  /// Dispose resources
  void dispose() {
    _conversationsController.close();
  }
}
