/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import '../models/chat_message.dart';
import '../models/dm_conversation.dart';
import '../models/profile.dart';
import '../platform/file_system_service.dart';
import '../util/event_bus.dart';
import '../util/nostr_crypto.dart';
import '../util/nostr_event.dart';
import 'log_service.dart';
import 'profile_service.dart';
import 'signing_service.dart';
import 'chat_service.dart';
import 'storage_config.dart';
import 'devices_service.dart';
import 'station_service.dart';

/// Exception thrown when trying to send a DM to an unreachable device
class DMMustBeReachableException implements Exception {
  final String message;
  DMMustBeReachableException(this.message);

  @override
  String toString() => message;
}

/// Service for managing 1:1 direct message conversations
class DirectMessageService {
  static final DirectMessageService _instance = DirectMessageService._internal();
  factory DirectMessageService() => _instance;
  DirectMessageService._internal();

  /// Base path for device storage (legacy: devices/)
  String? _basePath;

  /// Base path for chat storage (new: chat/)
  String? _chatBasePath;

  /// Cached conversations
  final Map<String, DMConversation> _conversations = {};

  /// Stream controller for conversation updates
  final _conversationsController = StreamController<List<DMConversation>>.broadcast();
  Stream<List<DMConversation>> get conversationsStream => _conversationsController.stream;

  /// Stream controller for unread count changes (callsign -> count)
  final _unreadController = StreamController<Map<String, int>>.broadcast();
  Stream<Map<String, int>> get unreadCountsStream => _unreadController.stream;

  /// Currently viewed conversation callsign (messages here are marked as read)
  String? _currentConversationCallsign;

  /// Initialize the service
  Future<void> initialize() async {
    if (_basePath != null) return;

    if (kIsWeb) {
      _basePath = '/geogram/devices';
      _chatBasePath = '/geogram/chat';
    } else {
      // Use StorageConfig to get the correct directories
      // This respects --data-dir and other configuration options
      final storageConfig = StorageConfig();
      if (!storageConfig.isInitialized) {
        // StorageConfig should be initialized by main.dart, but fallback just in case
        await storageConfig.init();
      }
      _basePath = storageConfig.devicesDir;
      _chatBasePath = storageConfig.chatDir;

      final devicesDir = Directory(_basePath!);
      if (!await devicesDir.exists()) {
        await devicesDir.create(recursive: true);
      }
    }

    LogService().log('DirectMessageService initialized at: $_basePath');
    LogService().log('DirectMessageService chat path: $_chatBasePath');

    // Migrate old DM paths from devices/ to chat/
    await _migrateOldDMPaths();

    await _loadConversations();
  }

  /// Reset the service state (useful when StorageConfig changes or for testing)
  void reset() {
    _basePath = null;
    _chatBasePath = null;
    _conversations.clear();
  }

  /// Get the current user's callsign
  String get _myCallsign => ProfileService().getProfile().callsign;

  /// Get the current user's profile
  Profile get _myProfile => ProfileService().getProfile();

  /// Get DM path for a conversation with another callsign
  /// Returns: chat/{otherCallsign}/ (new unified chat room path)
  String getDMPath(String otherCallsign) {
    return '$_chatBasePath/${otherCallsign.toUpperCase()}';
  }

  /// Migrate old DM paths from devices/{callsign}/chat/{myCallsign}/ to chat/{callsign}/
  Future<void> _migrateOldDMPaths() async {
    if (kIsWeb || _basePath == null || _chatBasePath == null) return;

    try {
      final devicesDir = Directory(_basePath!);
      if (!await devicesDir.exists()) return;

      await for (final deviceDir in devicesDir.list()) {
        if (deviceDir is! Directory) continue;

        final callsign = p.basename(deviceDir.path).toUpperCase();
        final oldChatDir = Directory('${deviceDir.path}/chat/${_myCallsign.toUpperCase()}');

        if (!await oldChatDir.exists()) continue;

        // Check for messages in old path
        final oldMessagesFile = File('${oldChatDir.path}/messages.txt');
        final hasOldMessages = await oldMessagesFile.exists();

        if (!hasOldMessages) {
          // Check for npub-specific message files
          final oldFiles = await oldChatDir.list().toList();
          final hasMessageFiles = oldFiles.any((f) =>
            f is File && p.basename(f.path).startsWith('messages'));
          if (!hasMessageFiles) continue;
        }

        // New path: chat/{callsign}/
        final newChatDir = Directory('$_chatBasePath/$callsign');

        LogService().log('DM Migration: Migrating $callsign from ${oldChatDir.path} to ${newChatDir.path}');

        // Create new directory if doesn't exist
        if (!await newChatDir.exists()) {
          await newChatDir.create(recursive: true);
          await Directory('${newChatDir.path}/files').create();
        }

        // Copy all files from old to new (merge if new exists)
        await for (final entity in oldChatDir.list()) {
          if (entity is File) {
            final filename = p.basename(entity.path);
            final newFilePath = '${newChatDir.path}/$filename';
            final newFile = File(newFilePath);

            if (await newFile.exists()) {
              // Merge message files if both exist - keep new file (more recent)
              LogService().log('DM Migration: Skipping merge of $filename (new file exists)');
            } else {
              // Copy file to new location
              await entity.copy(newFilePath);
              LogService().log('DM Migration: Copied $filename');
            }
          }
        }

        // After migration, remove old directory
        await oldChatDir.delete(recursive: true);

        // Clean up empty chat parent directory if needed
        final oldChatParent = Directory('${deviceDir.path}/chat');
        if (await oldChatParent.exists()) {
          final remaining = await oldChatParent.list().toList();
          if (remaining.isEmpty) {
            await oldChatParent.delete();
          }
        }

        LogService().log('DM Migration: Completed migration for $callsign');
      }
    } catch (e) {
      LogService().log('DM Migration: Error during migration: $e');
    }
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
  Future<void> _createConfig(String path, String otherCallsign, {String? otherNpub}) async {
    final config = {
      'id': otherCallsign,
      'name': 'Chat with $otherCallsign',
      'type': 'direct',
      'visibility': 'RESTRICTED',
      'participants': [_myCallsign, otherCallsign],
      'created': DateTime.now().toIso8601String(),
      // Store npub to cryptographically bind the conversation to a specific identity.
      // This prevents someone with a different npub from impersonating this callsign.
      if (otherNpub != null) 'otherNpub': otherNpub,
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

  /// Update the stored npub for a conversation (called when first signed message is received)
  Future<void> _updateConversationNpub(String path, String otherNpub) async {
    final configPath = '$path/config.json';

    try {
      Map<String, dynamic> config;

      if (kIsWeb) {
        final fs = FileSystemService.instance;
        if (await fs.exists(configPath)) {
          final content = await fs.readAsString(configPath);
          config = json.decode(content) as Map<String, dynamic>;
        } else {
          return;
        }
      } else {
        final file = File(configPath);
        if (await file.exists()) {
          final content = await file.readAsString();
          config = json.decode(content) as Map<String, dynamic>;
        } else {
          return;
        }
      }

      // Only set if not already set (trust first seen npub)
      if (config['otherNpub'] == null) {
        config['otherNpub'] = otherNpub;
        final content = const JsonEncoder.withIndent('  ').convert(config);

        if (kIsWeb) {
          await FileSystemService.instance.writeAsString(configPath, content);
        } else {
          await File(configPath).writeAsString(content);
        }

        LogService().log('DirectMessageService: Bound conversation to npub ${otherNpub.substring(0, 20)}...');
      }
    } catch (e) {
      LogService().log('DirectMessageService: Error updating conversation npub: $e');
    }
  }

  /// Load the stored npub for a conversation from config.json
  Future<String?> _loadConversationNpub(String path) async {
    final configPath = '$path/config.json';

    try {
      if (kIsWeb) {
        final fs = FileSystemService.instance;
        if (await fs.exists(configPath)) {
          final content = await fs.readAsString(configPath);
          final config = json.decode(content) as Map<String, dynamic>;
          return config['otherNpub'] as String?;
        }
      } else {
        final file = File(configPath);
        if (await file.exists()) {
          final content = await file.readAsString();
          final config = json.decode(content) as Map<String, dynamic>;
          return config['otherNpub'] as String?;
        }
      }
    } catch (e) {
      LogService().log('DirectMessageService: Error loading conversation npub: $e');
    }
    return null;
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
  /// Looks in chat/{callsign}/ directories for direct message channels
  Future<void> _loadConversations() async {
    if (_chatBasePath == null) return;

    try {
      if (kIsWeb) {
        final fs = FileSystemService.instance;
        if (!await fs.exists(_chatBasePath!)) return;

        final entities = await fs.list(_chatBasePath!);
        for (final entity in entities) {
          if (entity.type == FsEntityType.directory) {
            await _loadConversationFromPath(entity.path);
          }
        }
      } else {
        final chatDir = Directory(_chatBasePath!);
        if (!await chatDir.exists()) return;

        await for (final entity in chatDir.list()) {
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
  /// Path format: chat/{otherCallsign}/
  Future<void> _loadConversationFromPath(String chatPath) async {
    final otherCallsign = p.basename(chatPath).toUpperCase();

    // Skip non-DM directories (like 'main', 'extra', etc.)
    // DM directories are named after callsigns (typically uppercase alphanumeric)
    if (otherCallsign == 'MAIN' || otherCallsign == 'EXTRA') return;

    // Check if this is a direct message channel by looking for config.json with type=direct
    bool isDMChannel = false;
    final configPath = '$chatPath/config.json';

    try {
      String? configContent;
      if (kIsWeb) {
        final fs = FileSystemService.instance;
        if (await fs.exists(configPath)) {
          configContent = await fs.readAsString(configPath);
        }
      } else {
        final configFile = File(configPath);
        if (await configFile.exists()) {
          configContent = await configFile.readAsString();
        }
      }

      if (configContent != null) {
        final config = json.decode(configContent) as Map<String, dynamic>;
        isDMChannel = config['type'] == 'direct';
      }
    } catch (e) {
      // If no config or error, check if there are messages files
      isDMChannel = true; // Assume it's a DM if we can't determine
    }

    if (!isDMChannel) return;

    // Load stored npub from config.json for identity binding
    final storedNpub = await _loadConversationNpub(chatPath);

    final conversation = DMConversation(
      otherCallsign: otherCallsign,
      myCallsign: _myCallsign,
      path: chatPath,
      otherNpub: storedNpub,
    );

    // Load messages to update conversation metadata
    final messages = await loadMessages(otherCallsign, limit: 1);
    if (messages.isNotEmpty) {
      conversation.updateFromMessages(messages);
    }

    _conversations[otherCallsign] = conversation;
  }

  /// Send a message in a DM conversation
  /// Throws [DMMustBeReachableException] if the remote device is not reachable
  Future<void> sendMessage(String otherCallsign, String content) async {
    await initialize();

    final normalizedCallsign = otherCallsign.toUpperCase();
    final profile = _myProfile;

    // 1. Check reachability FIRST - must be reachable to send
    // Device is reachable if:
    // a) It's online with a direct URL, OR
    // b) We're connected to a station (can use station proxy)
    final devicesService = DevicesService();
    final device = devicesService.getDevice(normalizedCallsign);
    final station = StationService().getConnectedRelay();
    final hasStationProxy = station != null;
    final hasDirectConnection = device != null && device.isOnline && device.url != null;

    if (!hasDirectConnection && !hasStationProxy) {
      throw DMMustBeReachableException(
        'Cannot send message: device $normalizedCallsign is not reachable',
      );
    }

    // 2. Get or create conversation
    final conversation = await getOrCreateConversation(normalizedCallsign);

    // 3. Create the message with PENDING status
    final message = ChatMessage.now(
      author: profile.callsign,
      content: content,
    );
    message.setDeliveryStatus(MessageStatus.pending);

    // 4. Sign the message per chat-format-specification.md
    // Tags: [['t', 'chat'], ['room', roomId], ['callsign', callsign]]
    // For DMs, roomId is the other device's callsign (the conversation identifier)
    // IMPORTANT: Use the message's timestamp for signing so verification works
    final signingService = SigningService();
    await signingService.initialize();

    NostrEvent? signedEvent;
    if (signingService.canSign(profile)) {
      // Convert message timestamp to Unix seconds for signing
      // IMPORTANT: Must use the exact same createdAt during verification
      final createdAt = message.dateTime.millisecondsSinceEpoch ~/ 1000;
      signedEvent = await signingService.generateSignedEvent(
        content,
        {
          'room': normalizedCallsign, // The conversation room is the other device's callsign
          'callsign': profile.callsign,
        },
        profile,
        createdAt: createdAt,
      );
      if (signedEvent != null && signedEvent.sig != null && signedEvent.id != null) {
        // Store created_at first - receivers need this to reconstruct the exact NOSTR event for verification
        message.setMeta('created_at', signedEvent.createdAt.toString());
        message.setMeta('npub', profile.npub);
        message.setMeta('eventId', signedEvent.id!);
        message.setMeta('signature', signedEvent.sig!);
      }
    }

    // 5. Save locally with pending status
    await _saveMessage(conversation.path, message, otherNpub: conversation.otherNpub);

    // Update conversation metadata
    conversation.lastMessageTime = message.dateTime;
    conversation.lastMessagePreview = content;
    conversation.lastMessageAuthor = profile.callsign;

    // 6. Fire event (UI shows pending status)
    _fireMessageEvent(message, otherCallsign, fromSync: false);
    _notifyListeners();

    // 7. Push to remote device's chat API and get delivery status
    // Send the full signed event (id, pubkey, created_at, kind, tags, content, sig)
    final delivered = await _pushToRemoteChatAPI(device, signedEvent, profile.callsign);

    // 8. Update status based on result
    if (delivered) {
      message.setDeliveryStatus(MessageStatus.delivered);
    } else {
      message.setDeliveryStatus(MessageStatus.failed);
    }

    // 9. Update status in file and fire status change event
    await _updateMessageStatus(conversation.path, message);
    _fireMessageEvent(message, otherCallsign, fromSync: false);
    _notifyListeners();
  }

  /// Push message to remote device using POST /api/chat/{myCallsign}/messages
  /// Sends the full signed NostrEvent (id, pubkey, created_at, kind, tags, content, sig)
  /// Uses station proxy if direct connection is not available
  /// Returns true if HTTP 200/201 (delivered), false otherwise
  Future<bool> _pushToRemoteChatAPI(dynamic device, NostrEvent? signedEvent, String myCallsign) async {
    if (kIsWeb) return false; // Web doesn't support direct push
    if (signedEvent == null) {
      LogService().log('DM: Cannot push - no signed event');
      return false;
    }

    try {
      // POST to remote: /api/chat/{myCallsign}/messages
      // The roomId on the remote is OUR callsign (symmetry: we write to their room named after us)
      final path = '/api/chat/$myCallsign/messages';
      final body = jsonEncode({
        'event': signedEvent.toJson(),
      });

      LogService().log('DM: Pushing signed event via chat API to ${device.callsign} path: $path');

      // Use DevicesService helper which tries direct connection first, then falls back to station proxy
      final response = await DevicesService().makeDeviceApiRequest(
        callsign: device.callsign,
        method: 'POST',
        path: path,
        headers: {'Content-Type': 'application/json'},
        body: body,
      );

      if (response == null) {
        LogService().log('DM: No route to device ${device.callsign} (no direct or station proxy)');
        return false;
      }

      if (response.statusCode == 200 || response.statusCode == 201) {
        LogService().log('DM: Message delivered successfully via chat API');
        return true;
      } else {
        LogService().log('DM: Chat API push failed: ${response.statusCode} - ${response.body}');
        return false;
      }
    } catch (e) {
      LogService().log('DM: Chat API push error: $e');
      return false;
    }
  }

  /// Update message status in the messages file
  Future<void> _updateMessageStatus(String conversationPath, ChatMessage message) async {
    // For simplicity, we don't rewrite the file to update status.
    // Status is tracked in memory and in newly written messages.
    // A more complete implementation would read the file, find the message by timestamp+author,
    // update the status line, and write back. For now, new messages get status on write.
    LogService().log('DM: Message status updated to ${message.deliveryStatus?.name ?? "unknown"}');
  }

  /// Save an incoming/synced message without re-signing
  /// Used for DM sync to preserve the original author's signature
  Future<void> saveIncomingMessage(String otherCallsign, ChatMessage message) async {
    await initialize();

    final normalizedCallsign = otherCallsign.toUpperCase();
    final conversation = await getOrCreateConversation(normalizedCallsign);

    // Use the message's npub for the filename (the sender's identity)
    await _saveMessage(conversation.path, message, otherNpub: message.npub);

    // Update conversation metadata
    if (conversation.lastMessageTime == null ||
        message.dateTime.isAfter(conversation.lastMessageTime!)) {
      conversation.lastMessageTime = message.dateTime;
      conversation.lastMessagePreview = message.content;
      conversation.lastMessageAuthor = message.author;
    }

    // Increment unread count if the message is from the other party (not from us)
    if (message.author.toUpperCase() == normalizedCallsign) {
      _incrementUnread(normalizedCallsign);
    }

    // Fire event
    _fireMessageEvent(message, normalizedCallsign, fromSync: true);

    _notifyListeners();
  }

  /// Get the messages filename for a DM conversation
  /// Always use messages.txt for consistency with the chat system
  String _getMessagesFilename(String? npub) {
    // Use single messages.txt file like regular chat system
    // The npub is stored in message metadata for verification
    return 'messages.txt';
  }

  /// Save a message to the appropriate messages file based on npub
  Future<void> _saveMessage(String path, ChatMessage message, {String? otherNpub}) async {
    // For outgoing messages, use the other party's npub for the filename
    // For incoming messages, the npub comes from the message itself
    final npubForFilename = otherNpub ?? message.npub;
    final filename = _getMessagesFilename(npubForFilename);
    final messagesPath = '$path/$filename';

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
      final messagesFile = File(p.join(path, filename));

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
  /// Loads from all messages-{npub}.txt files and legacy messages.txt
  /// Each file is tied to a specific cryptographic identity
  Future<List<ChatMessage>> loadMessages(String otherCallsign, {int limit = 100, String? filterNpub}) async {
    await initialize();

    final normalizedCallsign = otherCallsign.toUpperCase();
    final path = getDMPath(normalizedCallsign);

    try {
      final List<ChatMessage> allMessages = [];

      // Find all message files (messages.txt and messages-{npub}.txt)
      List<String> messageFiles = [];

      if (kIsWeb) {
        final fs = FileSystemService.instance;
        if (await fs.exists(path)) {
          final entities = await fs.list(path);
          for (final entity in entities) {
            final filename = p.basename(entity.path);
            if (filename == 'messages.txt' || filename.startsWith('messages-')) {
              messageFiles.add(entity.path);
            }
          }
        }
      } else {
        final dir = Directory(path);
        if (await dir.exists()) {
          await for (final entity in dir.list()) {
            if (entity is File) {
              final filename = p.basename(entity.path);
              if (filename == 'messages.txt' || filename.startsWith('messages-')) {
                messageFiles.add(entity.path);
              }
            }
          }
        }
      }

      if (messageFiles.isEmpty) return [];

      // Load and parse each file
      for (final filePath in messageFiles) {
        String? content;

        if (kIsWeb) {
          content = await FileSystemService.instance.readAsString(filePath);
        } else {
          content = await File(filePath).readAsString();
        }

        final messages = ChatService.parseMessageText(content);

        // Extract npub from filename if present (messages-{npub}.txt)
        final filename = p.basename(filePath);
        String? fileNpub;
        if (filename.startsWith('messages-') && filename.endsWith('.txt')) {
          fileNpub = filename.substring('messages-'.length, filename.length - '.txt'.length);
        }

        // Apply filter if specified (load only messages from a specific npub)
        if (filterNpub != null && fileNpub != null && fileNpub != filterNpub) {
          continue;
        }

        // Verify signatures and check npub matches file identity
        for (final msg in messages) {
          if (msg.isSigned) {
            // For DMs: roomId used in signing is the RECIPIENT's callsign
            // If message is FROM me, recipient was other party (normalizedCallsign)
            // If message is FROM them, recipient was me (_myCallsign)
            final isFromMe = msg.author.toUpperCase() == _myCallsign.toUpperCase();
            final roomIdForVerification = isFromMe ? normalizedCallsign : _myCallsign;
            final verified = verifySignature(msg, roomId: roomIdForVerification);

            // For messages from the other party in npub-specific files,
            // verify the message's npub matches the file's npub
            if (fileNpub != null &&
                msg.author.toUpperCase() == normalizedCallsign &&
                msg.npub != null) {
              if (msg.npub != fileNpub) {
                // SECURITY: Message npub doesn't match file npub - possible tampering
                msg.setMeta('verified', 'false');
                msg.setMeta('identity_mismatch', 'true');
                LogService().log('DirectMessageService: SECURITY WARNING - Message in $filename has mismatched npub');
                continue; // Skip this message
              }
            }

            // Mark which npub this message belongs to (for UI display)
            if (fileNpub != null) {
              msg.setMeta('identity_npub', fileNpub);
            }
          }

          allMessages.add(msg);
        }
      }

      // Sort by timestamp
      allMessages.sort();

      // Apply limit
      if (allMessages.length > limit) {
        return allMessages.sublist(allMessages.length - limit);
      }

      return allMessages;
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
  /// Uses station proxy if direct connection is not available
  Future<DMSyncResult> syncWithDevice(String callsign, {String? deviceUrl}) async {
    await initialize();

    final normalizedCallsign = callsign.toUpperCase();
    final conversation = _conversations[normalizedCallsign];
    final lastSync = conversation?.lastSyncTime?.toIso8601String() ?? '';

    try {
      // Step 1: Fetch remote messages using DevicesService (supports station proxy)
      final fetchPath = '/$_myCallsign/api/dm/sync/$normalizedCallsign?since=$lastSync';
      LogService().log('DM Sync: Fetching from $normalizedCallsign path: $fetchPath');

      final fetchResponse = await DevicesService().makeDeviceApiRequest(
        callsign: normalizedCallsign,
        method: 'GET',
        path: fetchPath,
      );

      List<ChatMessage> remoteMessages = [];
      if (fetchResponse != null && fetchResponse.statusCode == 200) {
        final data = json.decode(fetchResponse.body);
        if (data['messages'] is List) {
          for (final msgJson in data['messages']) {
            remoteMessages.add(ChatMessage.fromJson(msgJson));
          }
        }
      } else if (fetchResponse == null) {
        LogService().log('DM Sync: No route to $normalizedCallsign');
        return DMSyncResult(
          otherCallsign: normalizedCallsign,
          messagesReceived: 0,
          messagesSent: 0,
          success: false,
          error: 'No route to device (no direct or station proxy)',
        );
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
        final pushPath = '/$_myCallsign/api/dm/sync/$normalizedCallsign';
        final pushResponse = await DevicesService().makeDeviceApiRequest(
          callsign: normalizedCallsign,
          method: 'POST',
          path: pushPath,
          headers: {'Content-Type': 'application/json'},
          body: json.encode({
            'messages': localMessages.map((m) => m.toJson()).toList(),
          }),
        );

        if (pushResponse != null && pushResponse.statusCode == 200) {
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
        // For DMs: roomId used in signing is the RECIPIENT's callsign
        // If message is FROM me, recipient was other party (otherCallsign)
        // If message is FROM them, recipient was me (_myCallsign)
        final isFromMe = msg.author.toUpperCase() == _myCallsign.toUpperCase();
        final roomIdForVerification = isFromMe ? otherCallsign : _myCallsign;
        if (verifySignature(msg, roomId: roomIdForVerification)) {
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

  /// Verify a message signature per chat-format-specification.md
  ///
  /// Reconstructs the NOSTR event and verifies the signature:
  /// 1. Extract npub and signature from metadata
  /// 2. Derive pubkey from npub
  /// 3. Reconstruct tags: [['t', 'chat'], ['room', roomId], ['callsign', callsign]]
  /// 4. Create NOSTR event and verify signature
  bool verifySignature(ChatMessage message, {String? roomId}) {
    // If no signature, accept the message (unsigned messages are valid)
    if (!message.isSigned) {
      LogService().log('verifySignature: Message not signed, accepting');
      return true;
    }

    try {
      final npub = message.npub;
      final signature = message.signature;

      if (npub == null || signature == null) {
        LogService().log('verifySignature: Missing npub or signature, accepting');
        return true; // Can't verify without both, accept it
      }

      // Derive hex pubkey from npub
      final pubkeyHex = NostrCrypto.decodeNpub(npub);

      // Use stored created_at for verification (same value used during signing)
      // Fall back to calculating from timestamp if not available
      final createdAtStr = message.getMeta('created_at');
      final createdAt = createdAtStr != null
          ? int.parse(createdAtStr)
          : message.dateTime.millisecondsSinceEpoch ~/ 1000;

      // For DMs, roomId is the conversation partner's callsign
      final effectiveRoomId = roomId ?? 'dm';

      LogService().log('verifySignature: Reconstructing event with:');
      LogService().log('  pubkey: ${pubkeyHex.substring(0, 20)}...');
      LogService().log('  createdAt: $createdAt (from ${message.timestamp})');
      LogService().log('  roomId: $effectiveRoomId');
      LogService().log('  callsign: ${message.author}');
      LogService().log('  content: ${message.content.substring(0, message.content.length.clamp(0, 50))}...');
      LogService().log('  signature: ${signature.substring(0, 20)}...');

      // Reconstruct the NOSTR event per chat-format-specification.md
      final event = NostrEvent(
        pubkey: pubkeyHex,
        createdAt: createdAt,
        kind: 1,
        tags: [
          ['t', 'chat'],
          ['room', effectiveRoomId],
          ['callsign', message.author],
        ],
        content: message.content,
        sig: signature,
      );

      // Calculate event ID and verify
      event.calculateId();
      LogService().log('verifySignature: Calculated eventId: ${event.id?.substring(0, 20)}...');

      final verified = event.verify();
      LogService().log('verifySignature: Verification result: $verified');

      // Update message metadata with verification result
      if (verified) {
        message.setMeta('verified', 'true');
      }

      return verified;
    } catch (e) {
      LogService().log('DirectMessageService: Error verifying signature: $e');
      return true; // On error, accept the message but don't mark as verified
    }
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
    final normalizedCallsign = otherCallsign.toUpperCase();
    final conversation = _conversations[normalizedCallsign];
    if (conversation != null && conversation.unreadCount > 0) {
      conversation.unreadCount = 0;
      _notifyListeners();
      _notifyUnreadChanged();
    }
  }

  /// Set the currently viewed conversation (clears its unread count)
  void setCurrentConversation(String? callsign) {
    _currentConversationCallsign = callsign?.toUpperCase();
    if (_currentConversationCallsign != null) {
      markAsRead(_currentConversationCallsign!);
    }
  }

  /// Get total unread count across all conversations
  int get totalUnreadCount {
    return _conversations.values.fold(0, (sum, conv) => sum + conv.unreadCount);
  }

  /// Get unread counts as a map (callsign -> count)
  Map<String, int> get unreadCounts {
    final counts = <String, int>{};
    for (final conv in _conversations.values) {
      if (conv.unreadCount > 0) {
        counts[conv.otherCallsign] = conv.unreadCount;
      }
    }
    return counts;
  }

  /// Get unread count for a specific conversation
  int getUnreadCount(String callsign) {
    return _conversations[callsign.toUpperCase()]?.unreadCount ?? 0;
  }

  /// Notify listeners of unread count changes
  void _notifyUnreadChanged() {
    _unreadController.add(unreadCounts);
  }

  /// Increment unread count for a conversation (when receiving a new message)
  void _incrementUnread(String otherCallsign) {
    final normalizedCallsign = otherCallsign.toUpperCase();

    // Don't increment if user is currently viewing this conversation
    if (_currentConversationCallsign == normalizedCallsign) {
      return;
    }

    final conversation = _conversations[normalizedCallsign];
    if (conversation != null) {
      conversation.unreadCount++;
      _notifyUnreadChanged();
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
    _unreadController.close();
  }
}
