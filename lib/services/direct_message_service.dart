/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import '../models/chat_message.dart';
import '../models/dm_conversation.dart';
import '../models/profile.dart';
import '../util/event_bus.dart';
import '../util/nostr_crypto.dart';
import '../util/nostr_event.dart';
import '../util/reaction_utils.dart';
import 'log_service.dart';
import 'message_retention_service.dart';
import 'profile_service.dart';
import 'signing_service.dart';
import 'chat_service.dart';
import 'storage_config.dart';
import 'devices_service.dart';
import 'station_service.dart';
import '../connection/connection_manager.dart';
import 'profile_storage.dart';

/// Exception thrown when trying to send a DM to an unreachable device
class DMMustBeReachableException implements Exception {
  final String message;
  DMMustBeReachableException(this.message);

  @override
  String toString() => message;
}

/// Exception thrown when DM delivery fails
class DMDeliveryFailedException implements Exception {
  final String message;
  DMDeliveryFailedException(this.message);

  @override
  String toString() => message;
}

/// Cache entry for DM messages
/// Used to avoid repeated file I/O for message loading
class _MessageCache {
  List<ChatMessage> messages;
  DateTime lastLoaded;
  String? newestTimestamp;
  bool isComplete; // true if all messages loaded (reached end of conversation)

  _MessageCache({
    required this.messages,
    required this.lastLoaded,
    this.newestTimestamp,
    this.isComplete = false,
  });

  /// Check if cache is still fresh (less than 5 seconds old)
  bool get isFresh => DateTime.now().difference(lastLoaded).inSeconds < 5;

  /// Check if cache has enough messages for the requested limit
  bool hasEnoughMessages(int limit) => messages.length >= limit || isComplete;
}

/// Service for managing 1:1 direct message conversations
///
/// NOTE: DirectMessageService operates on cross-profile data (chat/ directory)
/// that is separate from per-profile encrypted storage. Full encrypted storage
/// support requires architectural changes to handle shared DM data.
class DirectMessageService {
  static final DirectMessageService _instance = DirectMessageService._internal();
  factory DirectMessageService() => _instance;
  DirectMessageService._internal();

  /// Profile storage for file operations (encrypted or filesystem)
  /// NOTE: DMs use cross-profile chat/ directory, not profile-specific storage.
  /// This field is set for consistency but DM operations use _chatBasePath directly.
  ProfileStorage? _storage;

  /// Base path for device storage (legacy: devices/)
  String? _basePath;

  /// Base path for chat storage (new: chat/)
  String? _chatBasePath;

  /// Cached conversations
  final Map<String, DMConversation> _conversations = {};

  /// Whether using encrypted storage
  bool get useEncryptedStorage => _storage?.isEncrypted ?? false;

  /// Expose storage for use by MessageRetentionService
  ProfileStorage? get storage => _storage;

  /// Expose chat base path for retention service
  String? get chatBasePath => _chatBasePath;

  /// Set the profile storage for file operations
  /// NOTE: DMs currently use filesystem directly due to cross-profile nature.
  void setStorage(ProfileStorage storage) {
    _storage = storage;
  }

  /// Invalidate the message cache for a conversation (e.g. after retention purge)
  void invalidateCache(String callsign) {
    _messageCache.remove(callsign.toUpperCase());
  }

  /// Message cache: callsign -> cached messages
  /// Used to avoid repeated file I/O for message loading
  final Map<String, _MessageCache> _messageCache = {};

  /// Stream controller for conversation updates
  final _conversationsController = StreamController<List<DMConversation>>.broadcast();
  Stream<List<DMConversation>> get conversationsStream => _conversationsController.stream;

  /// Stream controller for unread count changes (callsign -> count)
  final _unreadController = StreamController<Map<String, int>>.broadcast();
  Stream<Map<String, int>> get unreadCountsStream => _unreadController.stream;

  /// Callback to trigger background queue processing
  /// Set by DMQueueService to avoid circular import
  Future<void> Function()? onTriggerBackgroundDelivery;

  /// Currently viewed conversation callsign (messages here are marked as read)
  String? _currentConversationCallsign;

  /// Initialize the service
  Future<void> initialize() async {
    if (_basePath != null) return;

    // Use StorageConfig to get the correct directories
    // This respects --data-dir and other configuration options
    final storageConfig = StorageConfig();
    if (!storageConfig.isInitialized) {
      // StorageConfig should be initialized by main.dart, but fallback just in case
      await storageConfig.init();
    }
    _basePath = storageConfig.devicesDir;
    _chatBasePath = storageConfig.chatDir;

    // Initialize default storage if not already set
    // DMs use cross-profile chat/ directory with filesystem storage
    _storage ??= FilesystemProfileStorage(_chatBasePath!);

    // Ensure directories exist using storage
    await _storage!.createDirectory('');

    LogService().log('DirectMessageService initialized at: $_basePath');
    LogService().log('DirectMessageService chat path: $_chatBasePath');

    // Migrate old DM paths from devices/ to chat/
    // Note: Migration requires filesystem access
    if (!_storage!.isEncrypted) {
      await _migrateOldDMPaths();
    }

    await _loadConversations();
  }

  /// Reset the service state (useful when StorageConfig changes or for testing)
  void reset() {
    _basePath = null;
    _chatBasePath = null;
    _conversations.clear();
    _messageCache.clear();
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
    final relativePath = normalizedCallsign;

    // Create directory structure if needed using storage
    if (!await _storage!.directoryExists(relativePath)) {
      await _storage!.createDirectory(relativePath);
      await _storage!.createDirectory('$relativePath/files');
      await _createConfig(relativePath, normalizedCallsign);
    }

    // Load retention period from config.json
    RetentionPeriod? retentionPeriod;
    try {
      final configContent = await _storage!.readString('$relativePath/config.json');
      if (configContent != null) {
        final config = json.decode(configContent) as Map<String, dynamic>;
        final retKey = config['message_retention'] as String?;
        if (retKey != null) {
          retentionPeriod = keyToRetention(retKey);
        }
      }
    } catch (_) {}

    final conversation = DMConversation(
      otherCallsign: normalizedCallsign,
      myCallsign: _myCallsign,
      path: path,
      retentionPeriod: retentionPeriod,
    );

    _conversations[normalizedCallsign] = conversation;
    _notifyListeners();

    return conversation;
  }

  /// Create config.json for a DM conversation
  /// [relativePath] is relative to the chat base path (e.g., "CALLSIGN")
  Future<void> _createConfig(String relativePath, String otherCallsign, {String? otherNpub}) async {
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
    await _storage!.writeString('$relativePath/config.json', content);
  }

  /// Update the stored npub for a conversation (called when first signed message is received)
  /// [relativePath] is relative to the chat base path (e.g., "CALLSIGN")
  Future<void> _updateConversationNpub(String relativePath, String otherNpub) async {
    final configPath = '$relativePath/config.json';

    try {
      final configContent = await _storage!.readString(configPath);
      if (configContent == null) return;

      final config = json.decode(configContent) as Map<String, dynamic>;

      // Only set if not already set (trust first seen npub)
      if (config['otherNpub'] == null) {
        config['otherNpub'] = otherNpub;
        final content = const JsonEncoder.withIndent('  ').convert(config);
        await _storage!.writeString(configPath, content);

        LogService().log('DirectMessageService: Bound conversation to npub ${otherNpub.substring(0, 20)}...');
      }
    } catch (e) {
      LogService().log('DirectMessageService: Error updating conversation npub: $e');
    }
  }

  /// Load the stored npub for a conversation from config.json
  /// [relativePath] is relative to the chat base path (e.g., "CALLSIGN")
  Future<String?> _loadConversationNpub(String relativePath) async {
    final configPath = '$relativePath/config.json';

    try {
      final content = await _storage!.readString(configPath);
      if (content != null) {
        final config = json.decode(content) as Map<String, dynamic>;
        return config['otherNpub'] as String?;
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
      if (!await _storage!.directoryExists('')) return;

      final entries = await _storage!.listDirectory('');
      for (final entry in entries) {
        if (entry.isDirectory) {
          await _loadConversationFromPath(entry.name);
        }
      }
    } catch (e) {
      LogService().log('Error loading DM conversations: $e');
    }

    // Notify listeners that conversations have been loaded
    if (_conversations.isNotEmpty) {
      _notifyListeners();
    }
  }

  /// Load a single conversation from its relative path
  /// Path format: {otherCallsign}/ (relative to chat base path)
  /// Optimized to avoid full message loading during conversation list build
  Future<void> _loadConversationFromPath(String relativePath) async {
    final otherCallsign = relativePath.toUpperCase();

    // Skip non-DM directories (like 'main', 'extra', etc.)
    // DM directories are named after callsigns (typically uppercase alphanumeric)
    if (otherCallsign == 'MAIN' || otherCallsign == 'EXTRA') return;

    // Check if this is a direct message channel by looking for config.json with type=direct
    bool isDMChannel = false;
    final configPath = '$relativePath/config.json';
    Map<String, dynamic>? config;

    try {
      final configContent = await _storage!.readString(configPath);
      if (configContent != null) {
        config = json.decode(configContent) as Map<String, dynamic>;
        isDMChannel = config['type'] == 'direct';
      }
    } catch (e) {
      // If no config or error, check if there are messages files
      isDMChannel = true; // Assume it's a DM if we can't determine
    }

    if (!isDMChannel) return;

    // Load stored npub from config.json for identity binding
    final storedNpub = config?['otherNpub'] as String?;

    // Load retention period from config.json
    final retKey = config?['message_retention'] as String?;
    final retentionPeriod = retKey != null ? keyToRetention(retKey) : null;

    // Build absolute path for DMConversation
    final absolutePath = getDMPath(otherCallsign);

    final conversation = DMConversation(
      otherCallsign: otherCallsign,
      myCallsign: _myCallsign,
      path: absolutePath,
      otherNpub: storedNpub,
      retentionPeriod: retentionPeriod,
    );

    // Try to get cached metadata from config.json first (fast path)
    if (config != null) {
      final lastMsgTime = config['lastMessageTime'] as String?;
      final lastMsgPreview = config['lastMessagePreview'] as String?;
      final lastMsgAuthor = config['lastMessageAuthor'] as String?;
      if (lastMsgTime != null) {
        conversation.lastMessageTime = DateTime.tryParse(lastMsgTime);
        conversation.lastMessagePreview = lastMsgPreview;
        conversation.lastMessageAuthor = lastMsgAuthor;
      }
    }

    // If no cached metadata, load last message from file (slow path, but only happens once)
    if (conversation.lastMessageTime == null) {
      final lastMsg = await _loadLastMessageQuick(relativePath);
      if (lastMsg != null) {
        conversation.lastMessageTime = lastMsg.dateTime;
        conversation.lastMessagePreview = lastMsg.content;
        conversation.lastMessageAuthor = lastMsg.author;
      }
    }

    _conversations[otherCallsign] = conversation;
  }

  /// Quickly load just the last message from a conversation (no signature verification)
  /// Used during conversation list loading to avoid expensive full message parsing
  /// [relativePath] is relative to the chat base path (e.g., "CALLSIGN")
  Future<ChatMessage?> _loadLastMessageQuick(String relativePath) async {
    try {
      // Find message files
      final messagesPath = '$relativePath/messages.txt';
      final content = await _storage!.readString(messagesPath);

      if (content == null || content.isEmpty) return null;

      // Parse only the last message block (look for last occurrence of timestamp pattern)
      // Message blocks start with a blank line followed by timestamp
      final lines = content.split('\n');
      int lastMsgStart = -1;

      // Find the last message block by looking for timestamp pattern from the end
      for (int i = lines.length - 1; i >= 0; i--) {
        final line = lines[i].trim();
        // Timestamp format: YYYY-MM-DDTHH:MM:SS or YYYY-MM-DD HH:MM:SS
        if (RegExp(r'^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}').hasMatch(line)) {
          lastMsgStart = i;
          break;
        }
      }

      if (lastMsgStart == -1) return null;

      // Extract just the last message block
      final msgLines = lines.sublist(lastMsgStart);
      final msgText = msgLines.join('\n');

      // Parse the single message (without signature verification for speed)
      final messages = ChatService.parseMessageText(msgText);
      return messages.isNotEmpty ? messages.first : null;
    } catch (e) {
      LogService().log('Error loading last message quick: $e');
      return null;
    }
  }

  Future<bool> _canReachDevice(String callsign) async {
    final normalizedCallsign = callsign.toUpperCase();
    final connectionManager = ConnectionManager();
    if (connectionManager.isInitialized) {
      try {
        final reachable = await connectionManager.isReachable(normalizedCallsign);
        if (reachable) return true;
      } catch (_) {
        // Fall back to legacy checks
      }
    }

    final devicesService = DevicesService();
    final device = devicesService.getDevice(normalizedCallsign);
    final station = StationService().getConnectedStation();
    final hasStationProxy = station != null;
    final hasDirectConnection = device != null && device.isOnline && device.url != null;
    final hasBleConnection = device != null &&
        device.isOnline &&
        (device.connectionMethods.contains('bluetooth') ||
            device.connectionMethods.contains('bluetooth_plus'));

    return hasDirectConnection || hasStationProxy || hasBleConnection;
  }

  /// Send a message in a DM conversation
  ///
  /// Implements optimistic UI: message appears immediately with 'pending' status,
  /// then delivery happens in background via DMQueueService.
  /// No longer throws [DMMustBeReachableException] - messages are always queued.
  Future<void> sendMessage(
    String otherCallsign,
    String content, {
    Map<String, String>? metadata,
  }) async {
    await initialize();

    final normalizedCallsign = otherCallsign.toUpperCase();
    final profile = _myProfile;

    // 1. Get or create conversation
    final conversation = await getOrCreateConversation(normalizedCallsign);

    // 2. Create the message with 'pending' status (optimistic UI)
    final messageMetadata = <String, String>{};
    if (metadata != null) {
      messageMetadata.addAll(metadata);
    }
    messageMetadata['status'] = 'pending'; // Mark as pending for background delivery

    final message = ChatMessage.now(
      author: profile.callsign,
      content: content,
      metadata: messageMetadata,
    );

    // 3. Sign the message per chat-format-specification.md
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
        // Mark as verified - we signed it ourselves
        message.setMeta('verified', 'true');
      }
    }

    // 4. Save to queue for background delivery (includes signed event data)
    await _saveToQueue(normalizedCallsign, message);

    // 5. Add to cache for immediate UI display
    _addMessageToCache(normalizedCallsign, message);

    // Update conversation metadata
    conversation.lastMessageTime = message.dateTime;
    conversation.lastMessagePreview = content;
    conversation.lastMessageAuthor = profile.callsign;

    // 6. Fire event for immediate UI display
    _fireMessageEvent(message, normalizedCallsign, fromSync: false);
    _notifyListeners();

    // 7. Trigger background delivery via DMQueueService (immediate kick)
    _triggerBackgroundDelivery();

    LogService().log('DM: Message queued for $normalizedCallsign (optimistic UI)');
  }

  /// Set message retention period for a DM conversation.
  /// Updates local config, sends a control event to the other device,
  /// and immediately purges expired messages if applicable.
  Future<void> setRetention(String otherCallsign, RetentionPeriod period) async {
    await initialize();
    final normalizedCallsign = otherCallsign.toUpperCase();
    final relativePath = normalizedCallsign;

    // 1. Update local config.json
    final configPath = '$relativePath/config.json';
    Map<String, dynamic> config;
    try {
      final content = await _storage!.readString(configPath);
      config = content != null
          ? json.decode(content) as Map<String, dynamic>
          : <String, dynamic>{};
    } catch (_) {
      config = <String, dynamic>{};
    }
    MessageRetentionService().setRetentionInConfig(config, period);
    await _storage!.writeString(
        configPath, const JsonEncoder.withIndent('  ').convert(config));

    // 2. Update in-memory conversation
    final conversation = await getOrCreateConversation(normalizedCallsign);
    conversation.retentionPeriod = period;

    // 3. Send retention-change control event to the other device
    final profile = _myProfile;
    final periodKey = retentionToKey(period) ?? 'forever';
    final humanLabel = retentionLabel(period);
    final controlContent = period == RetentionPeriod.forever
        ? 'Disappearing messages turned off'
        : 'Messages set to delete after $humanLabel';

    // Build a signed NOSTR event with retention tags
    final signingService = SigningService();
    await signingService.initialize();

    if (signingService.canSign(profile)) {
      final createdAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final signedEvent = await signingService.generateSignedEvent(
        controlContent,
        {
          'room': normalizedCallsign,
          'callsign': profile.callsign,
        },
        profile,
        createdAt: createdAt,
        extraTags: [
          ['t', 'dm_retention'],
          ['retention', periodKey],
        ],
      );

      if (signedEvent != null && signedEvent.sig != null) {
        // Create a system message locally
        final systemMsg = ChatMessage.now(
          author: profile.callsign,
          content: controlContent,
          metadata: {
            'system': 'true',
            'created_at': signedEvent.createdAt.toString(),
            'npub': profile.npub,
            'eventId': signedEvent.id!,
            'signature': signedEvent.sig!,
            'verified': 'true',
            'status': 'pending',
          },
        );

        // Save locally and queue for delivery
        await _saveToQueue(normalizedCallsign, systemMsg);
        _addMessageToCache(normalizedCallsign, systemMsg);
        _fireMessageEvent(systemMsg, normalizedCallsign, fromSync: false);
        _triggerBackgroundDelivery();
      }
    }

    // 4. Fire retention changed event
    EventBus().fire(DMRetentionChangedEvent(
      callsign: normalizedCallsign,
      periodKey: periodKey,
    ));

    // 5. Immediately purge expired messages
    if (period != RetentionPeriod.forever) {
      final purged = await MessageRetentionService()
          .purgeConversation(_storage!, relativePath, period);
      if (purged) {
        invalidateCache(normalizedCallsign);
      }
    }

    _notifyListeners();
    LogService().log('DM: Retention set to $periodKey for $normalizedCallsign');
  }

  /// Handle an incoming retention-change control event.
  /// Called from station server when a dm_retention tagged event arrives.
  Future<void> handleIncomingRetentionChange(
      String otherCallsign, String periodKey, ChatMessage systemMessage) async {
    await initialize();
    final normalizedCallsign = otherCallsign.toUpperCase();
    final relativePath = normalizedCallsign;
    final period = keyToRetention(periodKey);

    // Update local config.json
    final configPath = '$relativePath/config.json';
    Map<String, dynamic> config;
    try {
      final content = await _storage!.readString(configPath);
      config = content != null
          ? json.decode(content) as Map<String, dynamic>
          : <String, dynamic>{};
    } catch (_) {
      config = <String, dynamic>{};
    }
    MessageRetentionService().setRetentionInConfig(config, period);
    await _storage!.writeString(
        configPath, const JsonEncoder.withIndent('  ').convert(config));

    // Update in-memory conversation
    final conversation = await getOrCreateConversation(normalizedCallsign);
    conversation.retentionPeriod = period;

    // Save system message
    await saveIncomingMessage(normalizedCallsign, systemMessage);

    // Fire retention changed event
    EventBus().fire(DMRetentionChangedEvent(
      callsign: normalizedCallsign,
      periodKey: periodKey,
    ));

    // Purge expired messages if applicable
    if (period != RetentionPeriod.forever) {
      final purged = await MessageRetentionService()
          .purgeConversation(_storage!, relativePath, period);
      if (purged) {
        invalidateCache(normalizedCallsign);
      }
    }

    LogService().log('DM: Remote retention change to $periodKey for $normalizedCallsign');
  }

  /// Get retention period for a conversation
  Future<RetentionPeriod> getRetention(String otherCallsign) async {
    await initialize();
    final relativePath = otherCallsign.toUpperCase();
    final configPath = '$relativePath/config.json';
    try {
      final content = await _storage!.readString(configPath);
      if (content != null) {
        final config = json.decode(content) as Map<String, dynamic>;
        return MessageRetentionService().getRetentionForConfig(config);
      }
    } catch (_) {}
    return RetentionPeriod.forever;
  }

  /// Trigger background delivery via DMQueueService
  /// This is fire-and-forget - errors are handled by the queue service
  void _triggerBackgroundDelivery() {
    if (onTriggerBackgroundDelivery == null) {
      LogService().log('DM: Background delivery not configured (DMQueueService not initialized)');
      return;
    }

    // Fire and forget - use microtask to not block the sender
    Future.microtask(() async {
      try {
        await onTriggerBackgroundDelivery!();
      } catch (e) {
        LogService().log('DM: Background delivery trigger failed: $e');
      }
    });
  }

  /// Send a message synchronously (old behavior for backwards compatibility)
  /// Use this when you need to wait for delivery confirmation
  /// Throws [DMMustBeReachableException] if the remote device is not reachable
  /// Throws [DMDeliveryFailedException] if delivery fails
  Future<void> sendMessageSync(
    String otherCallsign,
    String content, {
    Map<String, String>? metadata,
  }) async {
    await initialize();

    final normalizedCallsign = otherCallsign.toUpperCase();
    final profile = _myProfile;

    // 1. Check reachability FIRST - must be reachable to send
    final canReach = await _canReachDevice(normalizedCallsign);
    if (!canReach) {
      throw DMMustBeReachableException(
        'Cannot send message: device $normalizedCallsign is not reachable',
      );
    }

    // 2. Get or create conversation
    final conversation = await getOrCreateConversation(normalizedCallsign);

    // 3. Create the message
    final messageMetadata = <String, String>{};
    if (metadata != null) {
      messageMetadata.addAll(metadata);
    }
    final message = ChatMessage.now(
      author: profile.callsign,
      content: content,
      metadata: messageMetadata.isNotEmpty ? messageMetadata : null,
    );

    // 4. Sign the message per chat-format-specification.md
    final signingService = SigningService();
    await signingService.initialize();

    NostrEvent? signedEvent;
    if (signingService.canSign(profile)) {
      final createdAt = message.dateTime.millisecondsSinceEpoch ~/ 1000;
      signedEvent = await signingService.generateSignedEvent(
        content,
        {
          'room': normalizedCallsign,
          'callsign': profile.callsign,
        },
        profile,
        createdAt: createdAt,
      );
      if (signedEvent != null && signedEvent.sig != null && signedEvent.id != null) {
        message.setMeta('created_at', signedEvent.createdAt.toString());
        message.setMeta('npub', profile.npub);
        message.setMeta('eventId', signedEvent.id!);
        message.setMeta('signature', signedEvent.sig!);
        message.setMeta('verified', 'true');
      }
    }

    // 5. Push to remote device's chat API FIRST
    final delivered = await _pushToRemoteChatAPI(
      normalizedCallsign,
      signedEvent,
      profile.callsign,
      metadata: metadata,
    );

    // 6. Only save locally if delivered successfully
    if (!delivered) {
      throw DMDeliveryFailedException(
        'Failed to deliver message to $normalizedCallsign',
      );
    }

    // 7. Save locally (message was delivered)
    await _saveMessage(conversation.path, message, otherNpub: conversation.otherNpub);

    // 8. Add to cache
    _addMessageToCache(normalizedCallsign, message);

    // Update conversation metadata
    conversation.lastMessageTime = message.dateTime;
    conversation.lastMessagePreview = content;
    conversation.lastMessageAuthor = profile.callsign;

    // 9. Fire event and notify listeners
    _fireMessageEvent(message, normalizedCallsign, fromSync: false);
    _notifyListeners();
  }

  /// Send a voice message in a DM conversation
  /// [voiceFilePath] - Path to the recorded voice file (will be copied to DM files folder)
  /// [durationSeconds] - Duration of the voice message in seconds
  /// Throws [DMMustBeReachableException] if the remote device is not reachable
  Future<void> sendVoiceMessage(String otherCallsign, String voiceFilePath, int durationSeconds) async {
    await initialize();

    final normalizedCallsign = otherCallsign.toUpperCase();
    final profile = _myProfile;

    // 1. Check reachability FIRST - must be reachable to send
    final canReach = await _canReachDevice(normalizedCallsign);
    if (!canReach) {
      throw DMMustBeReachableException(
        'Cannot send voice message: device $normalizedCallsign is not reachable',
      );
    }

    // 2. Get or create conversation
    final conversation = await getOrCreateConversation(normalizedCallsign);

    // 3. Copy voice file to conversation files folder (also calculates SHA1)
    final copyResult = await _copyVoiceFile(voiceFilePath, conversation.path);
    if (copyResult == null) {
      throw DMDeliveryFailedException('Failed to copy voice file');
    }
    final voiceFileName = copyResult.fileName;
    final voiceSha1 = copyResult.sha1Hash;

    // 4. Create the message with voice metadata (empty content for voice-only messages)
    // SHA1 hash is included in metadata for integrity verification
    final message = ChatMessage.now(
      author: profile.callsign,
      content: '',
      metadata: {
        'voice': voiceFileName,
        'duration': durationSeconds.toString(),
        'sha1': voiceSha1,
      },
    );

    // 5. Sign the message per chat-format-specification.md
    // The SHA1 hash is included in the signed content to prevent file tampering
    final signingService = SigningService();
    await signingService.initialize();

    NostrEvent? signedEvent;
    if (signingService.canSign(profile)) {
      final createdAt = message.dateTime.millisecondsSinceEpoch ~/ 1000;
      // For voice messages, we sign a descriptor string including SHA1 for integrity
      final contentToSign = '[voice:$voiceFileName:${durationSeconds}s:sha1=$voiceSha1]';
      signedEvent = await signingService.generateSignedEvent(
        contentToSign,
        {
          'room': normalizedCallsign,
          'callsign': profile.callsign,
          'voice': voiceFileName,
          'duration': durationSeconds.toString(),
          'sha1': voiceSha1,
        },
        profile,
        createdAt: createdAt,
      );
      if (signedEvent != null && signedEvent.sig != null && signedEvent.id != null) {
        message.setMeta('created_at', signedEvent.createdAt.toString());
        message.setMeta('npub', profile.npub);
        message.setMeta('eventId', signedEvent.id!);
        message.setMeta('signature', signedEvent.sig!);
        // Mark as verified - we signed it ourselves
        message.setMeta('verified', 'true');
      }
    }

    // 6. Push to remote device's chat API FIRST
    final delivered = await _pushToRemoteChatAPI(
      normalizedCallsign,
      signedEvent,
      profile.callsign,
    );

    // 7. Only save locally if delivered successfully
    if (!delivered) {
      // Clean up copied file on failure
      await _deleteVoiceFile(conversation.path, voiceFileName);
      throw DMDeliveryFailedException(
        'Failed to deliver voice message to $normalizedCallsign',
      );
    }

    // 8. Save locally (message was delivered)
    await _saveMessage(conversation.path, message, otherNpub: conversation.otherNpub);

    // 9. Add to cache (incremental update - avoids full reload)
    _addMessageToCache(normalizedCallsign, message);

    // Update conversation metadata
    conversation.lastMessageTime = message.dateTime;
    conversation.lastMessagePreview = '🎤 Voice message (${durationSeconds}s)';
    conversation.lastMessageAuthor = profile.callsign;

    // 10. Fire event and notify listeners
    _fireMessageEvent(message, otherCallsign, fromSync: false);
    _notifyListeners();

    LogService().log('DM: Sent voice message to $normalizedCallsign (${durationSeconds}s)');
  }

  /// Send a file attachment to another user
  /// Follows the same P2P pattern as voice messages
  Future<void> sendFileMessage(String otherCallsign, String filePath, String? caption) async {
    await initialize();

    final normalizedCallsign = otherCallsign.toUpperCase();
    final profile = _myProfile;

    LogService().log('DM FILE SEND: Starting file transfer to $normalizedCallsign: $filePath');

    // 1. Check reachability FIRST - must be reachable to send
    final canReach = await _canReachDevice(normalizedCallsign);
    if (!canReach) {
      throw DMMustBeReachableException(
        'Cannot send file: device $normalizedCallsign is not reachable',
      );
    }

    // 2. Check file size (10 MB limit)
    final file = File(filePath);
    final fileSize = await file.length();
    if (fileSize > 10 * 1024 * 1024) {
      throw Exception('File too large (max 10 MB)');
    }

    // 3. Get or create conversation
    final conversation = await getOrCreateConversation(normalizedCallsign);

    // 4. Copy file to conversation files folder (also calculates SHA1)
    final copyResult = await _copyFile(filePath, conversation.path);
    if (copyResult == null) {
      throw DMDeliveryFailedException('Failed to copy file');
    }
    final storedFileName = copyResult.fileName;
    final fileSha1 = copyResult.sha1Hash;
    final originalName = copyResult.originalName;

    // 5. File stays on sender's device - receiver will fetch on demand (pull model)
    // The GET /api/dm/{callsign}/files/{filename} endpoint serves the file
    // No upload - receiver pulls when they click Download button

    // 6. Create the message with file metadata
    // SHA1 hash is included in metadata for integrity verification
    final message = ChatMessage.now(
      author: profile.callsign,
      content: caption ?? '',
      metadata: {
        'file': storedFileName,
        'file_size': fileSize.toString(),
        'file_name': originalName,
        'sha1': fileSha1,
      },
    );

    // 7. Sign the message (same pattern as sendMessage - sign the caption, file info in tags)
    final signingService = SigningService();
    await signingService.initialize();

    NostrEvent? signedEvent;
    if (signingService.canSign(profile)) {
      final createdAt = message.dateTime.millisecondsSinceEpoch ~/ 1000;
      // Sign the caption content (empty for file-only), file info goes in tags
      signedEvent = await signingService.generateSignedEvent(
        caption ?? '',
        {
          'room': normalizedCallsign,
          'callsign': profile.callsign,
          'file': storedFileName,
          'file_size': fileSize.toString(),
          'file_name': originalName,
          'sha1': fileSha1,
        },
        profile,
        createdAt: createdAt,
      );
      if (signedEvent != null && signedEvent.sig != null && signedEvent.id != null) {
        message.setMeta('created_at', signedEvent.createdAt.toString());
        message.setMeta('npub', profile.npub);
        message.setMeta('eventId', signedEvent.id!);
        message.setMeta('signature', signedEvent.sig!);
        message.setMeta('verified', 'true');
      }
    }

    // 8. Push message to remote device's chat API (include file metadata)
    final delivered = await _pushToRemoteChatAPI(
      normalizedCallsign,
      signedEvent,
      profile.callsign,
      metadata: message.metadata,
    );

    // 9. Only save locally if message delivered successfully
    if (!delivered) {
      // Clean up copied file on failure
      await _deleteFile(conversation.path, storedFileName);
      LogService().log('DM FILE SEND FAILED: Message delivery failed to $normalizedCallsign');
      throw DMDeliveryFailedException(
        'Failed to deliver file to $normalizedCallsign',
      );
    }

    // 10. Save locally (message was delivered)
    await _saveMessage(conversation.path, message, otherNpub: conversation.otherNpub);

    // 11. Add to cache (incremental update - avoids full reload)
    _addMessageToCache(normalizedCallsign, message);

    // Update conversation metadata
    conversation.lastMessageTime = message.dateTime;
    conversation.lastMessagePreview = '📎 $originalName';
    conversation.lastMessageAuthor = profile.callsign;

    // 12. Fire event and notify listeners
    _fireMessageEvent(message, otherCallsign, fromSync: false);
    _notifyListeners();

    LogService().log('DM FILE SEND SUCCESS: Sent $originalName to $normalizedCallsign (${fileSize} bytes)');
  }

  /// Copy a file to the conversation files folder with SHA1 naming
  Future<({String fileName, String sha1Hash, String originalName})?> _copyFile(String sourcePath, String conversationPath) async {
    try {
      final sourceFile = File(sourcePath);
      if (!await sourceFile.exists()) {
        LogService().log('DM: Source file not found: $sourcePath');
        return null;
      }

      final bytes = await sourceFile.readAsBytes();
      final sha1Hash = sha1.convert(bytes).toString();
      final originalName = p.basename(sourcePath);
      final storedFileName = '${sha1Hash}_$originalName';

      // Convert conversation path to relative path and create files directory
      final relativePath = _pathToRelative(conversationPath);
      final filesRelativePath = '$relativePath/files';
      await _storage!.createDirectory(filesRelativePath);

      // Write file using storage
      await _storage!.writeBytes('$filesRelativePath/$storedFileName', bytes);

      LogService().log('DM: Copied file to $filesRelativePath/$storedFileName');
      return (
        fileName: storedFileName,
        sha1Hash: sha1Hash,
        originalName: originalName,
      );
    } catch (e) {
      LogService().log('DM: Error copying file: $e');
      return null;
    }
  }

  /// Delete a file from conversation storage
  Future<void> _deleteFile(String conversationPath, String fileName) async {
    try {
      final relativePath = _pathToRelative(conversationPath);
      final filePath = '$relativePath/files/$fileName';
      if (await _storage!.exists(filePath)) {
        await _storage!.delete(filePath);
      }
    } catch (e) {
      LogService().log('DM: Error deleting file: $e');
    }
  }

  /// Get local path to a DM file attachment
  /// Returns null if file doesn't exist
  Future<String?> getFilePath(String otherCallsign, String fileName) async {
    await initialize();

    final normalizedCallsign = otherCallsign.toUpperCase();
    final relativePath = '$normalizedCallsign/files/$fileName';

    if (await _storage!.exists(relativePath)) {
      return await _storage!.getAbsolutePath(relativePath);
    }
    return null;
  }

  /// Queue a message for later delivery when recipient becomes reachable
  /// Used when the recipient device is offline
  /// Returns the queued ChatMessage with pending status
  Future<ChatMessage> queueMessage(
    String otherCallsign,
    String content, {
    Map<String, String>? metadata,
  }) async {
    await initialize();

    final normalizedCallsign = otherCallsign.toUpperCase();
    final profile = _myProfile;
    final conversation = await getOrCreateConversation(normalizedCallsign);

    // Create message with current timestamp (composition time - this is preserved)
    final messageMetadata = <String, String>{};
    if (metadata != null) {
      messageMetadata.addAll(metadata);
    }
    messageMetadata['status'] = 'pending'; // Mark as pending

    final message = ChatMessage.now(
      author: profile.callsign,
      content: content,
      metadata: messageMetadata,
    );

    // Sign the message (signature includes composition timestamp)
    final signingService = SigningService();
    await signingService.initialize();

    if (signingService.canSign(profile)) {
      // Convert message timestamp to Unix seconds for signing
      final createdAt = message.dateTime.millisecondsSinceEpoch ~/ 1000;
      final signedEvent = await signingService.generateSignedEvent(
        content,
        {
          'room': normalizedCallsign,
          'callsign': profile.callsign,
        },
        profile,
        createdAt: createdAt,
      );
      if (signedEvent != null && signedEvent.sig != null && signedEvent.id != null) {
        message.setMeta('created_at', signedEvent.createdAt.toString());
        message.setMeta('npub', profile.npub);
        message.setMeta('eventId', signedEvent.id!);
        message.setMeta('signature', signedEvent.sig!);
        message.setMeta('verified', 'true');
      }
    }

    // Save to queue file (separate from delivered messages)
    await _saveToQueue(normalizedCallsign, message);

    // Add to cache (incremental update - avoids full reload)
    _addMessageToCache(normalizedCallsign, message);

    // Update conversation metadata
    conversation.lastMessageTime = message.dateTime;
    conversation.lastMessagePreview = content.length > 50 ? '${content.substring(0, 50)}...' : content;
    conversation.lastMessageAuthor = profile.callsign;

    // Fire event and notify listeners
    _fireMessageEvent(message, normalizedCallsign, fromSync: false);
    _notifyListeners();

    LogService().log('DM: Queued message for $normalizedCallsign (offline)');
    return message;
  }

  /// Attempt to deliver all queued messages for a callsign
  /// Called when device becomes reachable
  /// Returns the number of messages successfully delivered
  Future<int> flushQueue(String callsign) async {
    await initialize();

    final normalizedCallsign = callsign.toUpperCase();
    final queuedMessages = await loadQueuedMessages(normalizedCallsign);

    if (queuedMessages.isEmpty) return 0;

    LogService().log('DM Queue: Flushing ${queuedMessages.length} messages to $normalizedCallsign');

    final conversation = await getOrCreateConversation(normalizedCallsign);
    final profile = _myProfile;

    int delivered = 0;

    for (final message in queuedMessages) {
      try {
        // Rebuild signed event from stored metadata
        final signedEvent = _rebuildSignedEventFromMessage(message, normalizedCallsign);

        if (signedEvent == null) {
          LogService().log('DM Queue: Cannot rebuild signed event for ${message.timestamp}');
          continue;
        }

        // Attempt delivery using makeDeviceApiRequest directly
        final success = await _pushQueuedMessage(
          normalizedCallsign,
          signedEvent,
          profile.callsign,
          metadata: message.metadata,
        );

        if (success) {
          // Update status to delivered
          message.setMeta('status', 'delivered');

          // Move from queue to delivered messages file
          await _saveMessage(conversation.path, message, otherNpub: conversation.otherNpub);
          await _removeFromQueue(normalizedCallsign, message.timestamp);
          invalidateMessageCache(normalizedCallsign);
          delivered++;

          // Fire delivery event for UI updates
          EventBus().fire(DMMessageDeliveredEvent(
            callsign: normalizedCallsign,
            messageTimestamp: message.timestamp,
          ));

          LogService().log('DM Queue: Delivered message ${message.timestamp} to $normalizedCallsign');
        } else {
          // Mark as failed but keep in queue for retry
          message.setMeta('status', 'failed');
          LogService().log('DM Queue: Failed to deliver message ${message.timestamp} to $normalizedCallsign');
        }
      } catch (e) {
        LogService().log('DM Queue: Error delivering message ${message.timestamp}: $e');
        message.setMeta('status', 'failed');
      }
    }

    LogService().log('DM Queue: Delivered $delivered/${queuedMessages.length} messages to $normalizedCallsign');
    _notifyListeners();
    return delivered;
  }

  /// Push a queued message to remote device
  /// Similar to _pushToRemoteChatAPI but uses callsign directly instead of device object
  Future<bool> _pushQueuedMessage(
    String targetCallsign,
    NostrEvent signedEvent,
    String myCallsign, {
    Map<String, String>? metadata,
  }) async {
    if (kIsWeb) return false;

    try {
      final path = '/api/chat/$myCallsign/messages';
      final extraMetadata = _filterOutboundMetadata(metadata);
      final body = jsonEncode({
        'event': signedEvent.toJson(),
        if (extraMetadata.isNotEmpty) 'metadata': extraMetadata,
      });

      final device = DevicesService().getDevice(targetCallsign);
      LogService().log('DM Queue: Pushing to $targetCallsign - device=${device?.callsign}, online=${device?.isOnline}, methods=${device?.connectionMethods}');

      final response = await DevicesService().makeDeviceApiRequest(
        callsign: targetCallsign,
        method: 'POST',
        path: path,
        headers: {'Content-Type': 'application/json'},
        body: body,
      );

      if (response == null) {
        LogService().log('DM Queue: No route to $targetCallsign');
        return false;
      }

      if (response.statusCode == 200 || response.statusCode == 201) {
        LogService().log('DM Queue: Message delivered successfully to $targetCallsign');
        return true;
      } else {
        LogService().log('DM Queue: Delivery failed: ${response.statusCode} - ${response.body}');
        return false;
      }
    } catch (e) {
      LogService().log('DM Queue: Delivery error: $e');
      return false;
    }
  }

  /// Rebuild a NostrEvent from stored message metadata
  /// Used when flushing queued messages
  NostrEvent? _rebuildSignedEventFromMessage(ChatMessage message, String roomId) {
    final npub = message.npub;
    final signature = message.signature;
    final eventId = message.getMeta('eventId');
    final createdAtStr = message.getMeta('created_at');

    if (npub == null || signature == null || eventId == null || createdAtStr == null) {
      LogService().log('DM Queue: Cannot rebuild event - missing metadata');
      return null;
    }

    final pubkeyHex = NostrCrypto.decodeNpub(npub);
    final createdAt = int.parse(createdAtStr);

    return NostrEvent(
      id: eventId,
      pubkey: pubkeyHex,
      createdAt: createdAt,
      kind: 1,
      tags: [
        ['t', 'chat'],
        ['room', roomId],
        ['callsign', message.author],
      ],
      content: message.content,
      sig: signature,
    );
  }

  /// Copy voice file to conversation files folder
  /// Returns (filename, sha1Hash) or null on failure
  Future<({String fileName, String sha1Hash})?> _copyVoiceFile(String sourcePath, String conversationPath) async {
    try {
      final sourceFile = File(sourcePath);
      if (!await sourceFile.exists()) {
        LogService().log('DM: Voice source file not found: $sourcePath');
        return null;
      }

      // Read file bytes for copying and hashing
      final bytes = await sourceFile.readAsBytes();

      // Calculate SHA1 hash for integrity verification
      final sha1Hash = sha1.convert(bytes).toString();

      // Convert conversation path to relative path and create files directory
      final relativePath = _pathToRelative(conversationPath);
      final filesRelativePath = '$relativePath/files';
      await _storage!.createDirectory(filesRelativePath);

      // Generate unique filename: voice_YYYYMMDD_HHMMSS.webm
      final now = DateTime.now();
      final timestamp = '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_'
          '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
      final extension = p.extension(sourcePath);
      final fileName = 'voice_$timestamp$extension';

      // Write file using storage
      await _storage!.writeBytes('$filesRelativePath/$fileName', bytes);

      LogService().log('DM: Copied voice file to $filesRelativePath/$fileName (sha1: $sha1Hash)');
      return (fileName: fileName, sha1Hash: sha1Hash);
    } catch (e) {
      LogService().log('DM: Failed to copy voice file: $e');
      return null;
    }
  }

  /// Delete a voice file from conversation files folder
  Future<void> _deleteVoiceFile(String conversationPath, String fileName) async {
    try {
      final relativePath = _pathToRelative(conversationPath);
      final filePath = '$relativePath/files/$fileName';
      if (await _storage!.exists(filePath)) {
        await _storage!.delete(filePath);
        LogService().log('DM: Deleted voice file: $filePath');
      }
    } catch (e) {
      LogService().log('DM: Failed to delete voice file: $e');
    }
  }

  /// Get the full path to a voice file in a conversation
  Future<String?> getVoiceFilePath(String otherCallsign, String voiceFileName) async {
    final normalizedCallsign = otherCallsign.toUpperCase();
    final relativePath = '$normalizedCallsign/files/$voiceFileName';

    if (await _storage!.exists(relativePath)) {
      return await _storage!.getAbsolutePath(relativePath);
    }
    return null;
  }

  /// Download a voice file from a remote device
  /// Returns the local file path on success, null on failure
  Future<String?> downloadVoiceFile(String otherCallsign, String voiceFileName) async {
    if (_storage!.isEncrypted) return null; // Downloads require filesystem access

    final normalizedCallsign = otherCallsign.toUpperCase();

    // Check if already exists locally
    final existingPath = await getVoiceFilePath(normalizedCallsign, voiceFileName);
    if (existingPath != null) {
      return existingPath;
    }

    // Security: prevent path traversal
    if (voiceFileName.contains('..') || voiceFileName.contains('/') || voiceFileName.contains('\\')) {
      LogService().log('DM: Invalid voice filename: $voiceFileName');
      return null;
    }

    try {
      // Request file from the sender's device
      // The sender stored it in their chat/{myCallsign}/files/ folder
      // Path: /{senderCallsign}/api/dm/{myCallsign}/files/{filename}
      final myCallsign = _myCallsign;
      final path = '/$normalizedCallsign/api/dm/$myCallsign/files/$voiceFileName';

      LogService().log('DM: Downloading voice file from $normalizedCallsign: $voiceFileName');

      final response = await DevicesService().makeDeviceApiRequest(
        callsign: normalizedCallsign,
        method: 'GET',
        path: path,
      );

      if (response == null) {
        LogService().log('DM: No route to $normalizedCallsign for voice download');
        return null;
      }

      if (response.statusCode != 200) {
        LogService().log('DM: Voice download failed: ${response.statusCode}');
        return null;
      }

      // Create local files directory and save file using storage
      final filesRelativePath = '$normalizedCallsign/files';
      await _storage!.createDirectory(filesRelativePath);
      await _storage!.writeBytes('$filesRelativePath/$voiceFileName', response.bodyBytes);

      LogService().log('DM: Voice file downloaded: $filesRelativePath/$voiceFileName');
      return await _storage!.getAbsolutePath('$filesRelativePath/$voiceFileName');
    } catch (e) {
      LogService().log('DM: Voice download error: $e');
      return null;
    }
  }

  /// Download a file attachment from a remote device
  /// Returns local file path on success, null on failure
  Future<String?> downloadFile(String otherCallsign, String fileName) async {
    if (_storage!.isEncrypted) return null; // Downloads require filesystem access

    final normalizedCallsign = otherCallsign.toUpperCase();

    // Check if already exists locally
    final existingPath = await getFilePath(normalizedCallsign, fileName);
    if (existingPath != null) {
      return existingPath;
    }

    // Security: prevent path traversal
    if (fileName.contains('..') || fileName.contains('/') || fileName.contains('\\')) {
      LogService().log('DM: Invalid file name: $fileName');
      return null;
    }

    try {
      // Request file from the sender's device
      // The sender stored it in their chat/{myCallsign}/files/ folder
      // Path: /api/dm/{myCallsign}/files/{filename}
      final myCallsign = _myCallsign;
      final apiPath = '/api/dm/$myCallsign/files/$fileName';

      LogService().log('DM: Downloading file from $normalizedCallsign: $fileName');

      final response = await DevicesService().makeDeviceApiRequest(
        callsign: normalizedCallsign,
        method: 'GET',
        path: apiPath,
      );

      if (response == null) {
        LogService().log('DM: No route to $normalizedCallsign for file download');
        return null;
      }

      if (response.statusCode != 200) {
        LogService().log('DM: File download failed: ${response.statusCode}');
        return null;
      }

      // Create local files directory and save file using storage
      final filesRelativePath = '$normalizedCallsign/files';
      await _storage!.createDirectory(filesRelativePath);
      await _storage!.writeBytes('$filesRelativePath/$fileName', response.bodyBytes);

      LogService().log('DM: File downloaded: $filesRelativePath/$fileName');
      return await _storage!.getAbsolutePath('$filesRelativePath/$fileName');
    } catch (e) {
      LogService().log('DM: File download error: $e');
      return null;
    }
  }

  /// Download a file attachment with progress tracking
  /// Used by ChatFileDownloadManager for large file downloads with progress UI
  /// [resumeFrom] - Number of bytes already downloaded (for resume capability)
  /// [onProgress] - Callback to report download progress (bytes received so far)
  /// Returns local file path on success, null on failure
  Future<String?> downloadFileWithProgress(
    String otherCallsign,
    String fileName, {
    int resumeFrom = 0,
    void Function(int bytesReceived)? onProgress,
  }) async {
    if (_storage!.isEncrypted) return null; // Downloads require filesystem access

    final normalizedCallsign = otherCallsign.toUpperCase();

    // Check if already exists locally and is complete
    if (resumeFrom == 0) {
      final existingPath = await getFilePath(normalizedCallsign, fileName);
      if (existingPath != null) {
        return existingPath;
      }
    }

    // Security: prevent path traversal
    if (fileName.contains('..') || fileName.contains('/') || fileName.contains('\\')) {
      LogService().log('DM: Invalid file name: $fileName');
      return null;
    }

    try {
      // Request file from the sender's device
      // The sender stored it in their chat/{myCallsign}/files/ folder
      // Path: /{senderCallsign}/api/dm/{myCallsign}/files/{filename}
      final myCallsign = _myCallsign;
      final apiPath = '/api/dm/$myCallsign/files/$fileName';

      LogService().log('DM: Downloading file with progress from $normalizedCallsign: $fileName (resume from $resumeFrom)');

      // TODO: When the underlying HTTP client supports range requests,
      // add Range header for resume capability:
      // headers: resumeFrom > 0 ? {'Range': 'bytes=$resumeFrom-'} : null

      final response = await DevicesService().makeDeviceApiRequest(
        callsign: normalizedCallsign,
        method: 'GET',
        path: apiPath,
      );

      if (response == null) {
        LogService().log('DM: No route to $normalizedCallsign for file download');
        return null;
      }

      if (response.statusCode != 200) {
        LogService().log('DM: File download failed: ${response.statusCode}');
        return null;
      }

      final bytes = response.bodyBytes;
      final totalBytes = bytes.length;

      // Create local files directory using storage
      final filesRelativePath = '$normalizedCallsign/files';
      await _storage!.createDirectory(filesRelativePath);

      // Report progress in chunks (simulated since we receive all at once)
      const chunkSize = 32 * 1024; // 32 KB chunks
      int bytesReported = 0;
      for (var offset = 0; offset < totalBytes; offset += chunkSize) {
        final end = (offset + chunkSize < totalBytes) ? offset + chunkSize : totalBytes;
        bytesReported = end;
        onProgress?.call(bytesReported);

        // Small delay to allow UI to update (prevents blocking)
        if (bytesReported < totalBytes) {
          await Future.delayed(const Duration(milliseconds: 10));
        }
      }

      // Write the complete file using storage
      await _storage!.writeBytes('$filesRelativePath/$fileName', bytes);

      // Final progress callback
      onProgress?.call(totalBytes);

      final resultPath = await _storage!.getAbsolutePath('$filesRelativePath/$fileName');
      LogService().log('DM: File downloaded with progress: $resultPath ($totalBytes bytes)');
      return resultPath;
    } catch (e) {
      LogService().log('DM: File download with progress error: $e');
      return null;
    }
  }

  /// Push message to remote device using POST /api/chat/{myCallsign}/messages
  /// Sends the full signed NostrEvent (id, pubkey, created_at, kind, tags, content, sig)
  /// Uses station proxy if direct connection is not available
  /// Returns true if HTTP 200/201 (delivered), false otherwise
  Future<bool> _pushToRemoteChatAPI(
    String targetCallsign,
    NostrEvent? signedEvent,
    String myCallsign, {
    Map<String, String>? metadata,
  }) async {
    if (kIsWeb) return false; // Web doesn't support direct push
    if (signedEvent == null) {
      LogService().log('DM: Cannot push - no signed event');
      return false;
    }

    try {
      // POST to remote: /api/chat/{myCallsign}/messages
      // The roomId on the remote is OUR callsign (symmetry: we write to their room named after us)
      final path = '/api/chat/$myCallsign/messages';
      final extraMetadata = _filterOutboundMetadata(metadata);
      final body = jsonEncode({
        'event': signedEvent.toJson(),
        if (extraMetadata.isNotEmpty) 'metadata': extraMetadata,
      });

      LogService().log('DM: Pushing signed event via chat API to $targetCallsign path: $path');

      // Check if device is reachable via BLE and use proper DM channel instead of API path
      final isReachable = await ConnectionManager().isReachable(targetCallsign);
      if (isReachable) {
        LogService().log('DM: Device $targetCallsign is BLE-reachable, using sendDM()');
        final result = await ConnectionManager().sendDM(
          callsign: targetCallsign,
          signedEvent: signedEvent.toJson(),
          ttl: const Duration(minutes: 5),
        );
        if (result.success) {
          LogService().log('DM: Message delivered successfully via BLE DM channel');
          return true;
        }
        LogService().log('DM: BLE DM failed, falling back to API path: ${result.error}');
        // Fall through to API request if BLE fails
      }

      // Use DevicesService helper which tries direct connection first, then falls back to station proxy
      final response = await DevicesService().makeDeviceApiRequest(
        callsign: targetCallsign,
        method: 'POST',
        path: path,
        headers: {'Content-Type': 'application/json'},
        body: body,
      );

      if (response == null) {
        LogService().log('DM: No route to device $targetCallsign (no direct or station proxy)');
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

  Map<String, String> _filterOutboundMetadata(Map<String, String>? metadata) {
    if (metadata == null || metadata.isEmpty) return {};
    const reserved = {
      'created_at',
      'npub',
      'event_id',
      'signature',
      'verified',
      'status',
    };
    final filtered = <String, String>{};
    metadata.forEach((key, value) {
      if (reserved.contains(key)) return;
      filtered[key] = value;
    });
    return filtered;
  }

  /// Save an incoming/synced message without re-signing
  /// Used for DM sync to preserve the original author's signature
  Future<void> saveIncomingMessage(String otherCallsign, ChatMessage message) async {
    await initialize();

    final normalizedCallsign = otherCallsign.toUpperCase();
    final conversation = await getOrCreateConversation(normalizedCallsign);

    // Use the message's npub for the filename (the sender's identity)
    await _saveMessage(conversation.path, message, otherNpub: message.npub);

    // Add to cache (incremental update - avoids full reload)
    _addMessageToCache(normalizedCallsign, message);

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
  /// [path] is the absolute path for DMConversation compatibility
  Future<void> _saveMessage(String path, ChatMessage message, {String? otherNpub}) async {
    // For outgoing messages, use the other party's npub for the filename
    // For incoming messages, the npub comes from the message itself
    final npubForFilename = otherNpub ?? message.npub;
    final filename = _getMessagesFilename(npubForFilename);

    // Convert absolute path to relative path for storage
    final relativePath = _pathToRelative(path);
    final messagesPath = '$relativePath/$filename';

    final exists = await _storage!.exists(messagesPath);
    if (!exists) {
      // New file: write header + message
      final buffer = StringBuffer();
      buffer.write('# DM: Direct Chat from ${message.datePortion}\n');
      buffer.write('\n');
      buffer.write(message.exportAsText());
      buffer.write('\n');
      await _storage!.writeString(messagesPath, buffer.toString());
    } else {
      // Deduplicate by eventId before appending
      final eventId = message.getMeta('eventId');
      if (eventId != null && eventId.isNotEmpty) {
        final existingContent = await _storage!.readString(messagesPath);
        if (existingContent != null && existingContent.contains(eventId)) {
          LogService().log('DM: Skipping duplicate message (eventId: ${eventId.substring(0, 8)}...)');
          return;
        }
      }
      // Existing file: APPEND only (no truncation, no race)
      await _storage!.appendString(messagesPath, '\n${message.exportAsText()}\n');
    }
  }

  /// Convert absolute path to relative path for storage
  String _pathToRelative(String absolutePath) {
    if (_chatBasePath == null) return absolutePath;
    if (absolutePath.startsWith(_chatBasePath!)) {
      final relative = absolutePath.substring(_chatBasePath!.length);
      if (relative.startsWith('/')) {
        return relative.substring(1);
      }
      return relative;
    }
    return absolutePath;
  }

  // ============================================================
  // MESSAGE QUEUE METHODS (for offline message queuing)
  // ============================================================

  /// Get path for message queue file
  String _getQueuePath(String callsign) {
    return '$_chatBasePath/${callsign.toUpperCase()}/queue.txt';
  }

  /// Save message to queue file for later delivery
  Future<void> _saveToQueue(String callsign, ChatMessage message) async {
    final queueRelativePath = _getQueueRelativePath(callsign);

    final existingContent = await _storage!.readString(queueRelativePath);
    final existing = existingContent ?? '';
    await _storage!.writeString(queueRelativePath, '$existing\n${message.exportAsText()}\n');
  }

  /// Load queued messages for a callsign
  Future<List<ChatMessage>> loadQueuedMessages(String callsign) async {
    final queueRelativePath = _getQueueRelativePath(callsign.toUpperCase());

    try {
      final content = await _storage!.readString(queueRelativePath);
      if (content == null || content.isEmpty) return [];
      return ChatService.parseMessageText(content);
    } catch (e) {
      LogService().log('Error loading queued messages for $callsign: $e');
      return [];
    }
  }

  /// Remove a message from queue after successful delivery
  Future<void> _removeFromQueue(String callsign, String timestamp) async {
    final queuedMessages = await loadQueuedMessages(callsign);
    final remaining = queuedMessages.where((m) => m.timestamp != timestamp).toList();

    if (remaining.isEmpty) {
      // Delete queue file if empty
      await _deleteQueueFile(callsign);
    } else {
      // Rewrite queue with remaining messages
      await _rewriteQueue(callsign, remaining);
    }
  }

  /// Delete the queue file for a callsign
  Future<void> _deleteQueueFile(String callsign) async {
    final queueRelativePath = _getQueueRelativePath(callsign.toUpperCase());

    if (await _storage!.exists(queueRelativePath)) {
      await _storage!.delete(queueRelativePath);
    }
  }

  /// Rewrite queue file with remaining messages
  Future<void> _rewriteQueue(String callsign, List<ChatMessage> messages) async {
    final queueRelativePath = _getQueueRelativePath(callsign.toUpperCase());

    final buffer = StringBuffer();
    for (final message in messages) {
      buffer.write('\n');
      buffer.write(message.exportAsText());
      buffer.write('\n');
    }

    await _storage!.writeString(queueRelativePath, buffer.toString());
  }

  /// Get relative path for message queue file
  String _getQueueRelativePath(String callsign) {
    return '${callsign.toUpperCase()}/queue.txt';
  }

  /// Load messages from a DM conversation
  /// Uses in-memory cache to avoid repeated file I/O
  /// Loads from all messages-{npub}.txt files and legacy messages.txt
  /// Each file is tied to a specific cryptographic identity
  Future<List<ChatMessage>> loadMessages(String otherCallsign, {int limit = 100, String? filterNpub}) async {
    await initialize();

    final normalizedCallsign = otherCallsign.toUpperCase();

    // Check cache first (skip for npub filtering as it's rare)
    if (filterNpub == null) {
      final cache = _messageCache[normalizedCallsign];
      if (cache != null && cache.isFresh && cache.hasEnoughMessages(limit)) {
        // Return cached messages (most recent `limit` messages)
        final cached = cache.messages;
        if (cached.length <= limit) {
          return List.from(cached);
        }
        return cached.sublist(cached.length - limit);
      }
    }

    // Cache miss or stale - load from disk
    final messages = await _loadMessagesFromDisk(normalizedCallsign, filterNpub: filterNpub);

    // Update cache (only for non-filtered queries)
    if (filterNpub == null) {
      _messageCache[normalizedCallsign] = _MessageCache(
        messages: messages,
        lastLoaded: DateTime.now(),
        newestTimestamp: messages.isNotEmpty ? messages.last.timestamp : null,
        isComplete: true, // We loaded all messages
      );
    }

    // Apply limit
    if (messages.length > limit) {
      return messages.sublist(messages.length - limit);
    }

    return messages;
  }

  /// Load messages from disk (without cache)
  /// This is the expensive operation that reads files and verifies signatures
  Future<List<ChatMessage>> _loadMessagesFromDisk(String normalizedCallsign, {String? filterNpub}) async {
    final relativePath = normalizedCallsign;

    try {
      final List<ChatMessage> allMessages = [];

      // Find all message files (messages.txt and messages-{npub}.txt)
      List<String> messageFiles = [];

      if (await _storage!.directoryExists(relativePath)) {
        final entries = await _storage!.listDirectory(relativePath);
        for (final entry in entries) {
          if (!entry.isDirectory) {
            if (entry.name == 'messages.txt' || entry.name.startsWith('messages-')) {
              messageFiles.add(entry.path);
            }
          }
        }
      }

      // Note: Don't return early if messageFiles is empty - we still need to load queued messages

      // Load and parse each file
      for (final filePath in messageFiles) {
        final content = await _storage!.readString(filePath);
        if (content == null) continue;

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
            verifySignature(msg, roomId: roomIdForVerification);

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

      // Also include queued messages (pending delivery)
      final queuedMessages = await loadQueuedMessages(normalizedCallsign);
      allMessages.addAll(queuedMessages);

      // Sort by timestamp
      allMessages.sort();

      return allMessages;
    } catch (e) {
      LogService().log('Error loading DM messages: $e');
      return [];
    }
  }

  Future<ChatMessage?> toggleReaction(
    String otherCallsign,
    String timestamp,
    String actorCallsign,
    String reaction,
  ) async {
    await initialize();

    final normalizedCallsign = otherCallsign.toUpperCase();
    final relativePath = normalizedCallsign;
    final reactionKey = ReactionUtils.normalizeReactionKey(reaction);
    final actorKey = actorCallsign.trim().toUpperCase();
    if (reactionKey.isEmpty || actorKey.isEmpty) {
      throw Exception('Invalid reaction or callsign');
    }

    final messageFiles = await _listMessageFiles(relativePath);
    for (final filePath in messageFiles) {
      final content = await _storage!.readString(filePath);
      if (content == null) continue;

      final messages = ChatService.parseMessageText(content);
      final index = messages.indexWhere((msg) => msg.timestamp == timestamp);
      if (index == -1) continue;

      final updated = _toggleMessageReaction(messages[index], reactionKey, actorKey);
      messages[index] = updated;

      final header = _extractMessageHeader(content, updated);
      await _rewriteMessagesFile(filePath, header, messages);
      return updated;
    }

    return null;
  }

  Future<List<String>> _listMessageFiles(String relativePath) async {
    final messageFiles = <String>[];

    if (await _storage!.directoryExists(relativePath)) {
      final entries = await _storage!.listDirectory(relativePath);
      for (final entry in entries) {
        if (!entry.isDirectory) {
          if (entry.name == 'messages.txt' || entry.name.startsWith('messages-')) {
            messageFiles.add(entry.path);
          }
        }
      }
    }

    return messageFiles;
  }

  String _extractMessageHeader(String content, ChatMessage message) {
    if (content.isNotEmpty) {
      final firstLine = content.split('\n').first.trim();
      if (firstLine.startsWith('#')) {
        return firstLine;
      }
    }
    return '# DM: Direct Chat from ${message.datePortion}';
  }

  Future<void> _rewriteMessagesFile(
    String filePath,
    String header,
    List<ChatMessage> messages,
  ) async {
    final buffer = StringBuffer();
    buffer.writeln(header);
    for (final message in messages) {
      buffer.writeln();
      buffer.write(message.exportAsText());
    }
    buffer.writeln();

    await _storage!.writeString(filePath, buffer.toString());
  }

  ChatMessage _toggleMessageReaction(
    ChatMessage message,
    String reactionKey,
    String actorCallsign,
  ) {
    final updatedReactions = <String, List<String>>{};

    message.reactions.forEach((key, users) {
      final normalizedUsers = users
          .map((u) => u.trim().toUpperCase())
          .where((u) => u.isNotEmpty)
          .toSet()
          .toList();
      if (normalizedUsers.isNotEmpty) {
        updatedReactions[ReactionUtils.normalizeReactionKey(key)] = normalizedUsers;
      }
    });

    final normalizedKey = ReactionUtils.normalizeReactionKey(reactionKey);
    final list = updatedReactions[normalizedKey] ?? <String>[];
    final existingIndex = list.indexWhere((u) => u.toUpperCase() == actorCallsign);
    if (existingIndex >= 0) {
      list.removeAt(existingIndex);
    } else {
      list.add(actorCallsign);
    }

    if (list.isEmpty) {
      updatedReactions.remove(normalizedKey);
    } else {
      updatedReactions[normalizedKey] = list;
    }

    return message.copyWith(reactions: updatedReactions);
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
  /// Optimized to use message cache when available
  Future<int> _mergeMessages(String otherCallsign, List<ChatMessage> incoming) async {
    // Use cache if available, otherwise load from disk
    final cache = _messageCache[otherCallsign];
    final List<ChatMessage> local;
    if (cache != null && cache.isComplete) {
      local = cache.messages;
    } else {
      // Load all messages from disk (will populate cache)
      local = await loadMessages(otherCallsign, limit: 99999);
    }

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

        // Add to cache if available
        _addMessageToCache(otherCallsign, msg);

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

  /// Add a single message to the cache (incremental update)
  /// Used when sending/receiving individual messages to avoid full reload
  void _addMessageToCache(String callsign, ChatMessage message) {
    final key = callsign.toUpperCase();
    final cache = _messageCache[key];
    if (cache != null) {
      // Dedup by eventId to prevent duplicate display
      final eventId = message.getMeta('eventId');
      if (eventId != null && eventId.isNotEmpty) {
        final existingIdx = cache.messages.indexWhere(
          (m) => m.getMeta('eventId') == eventId,
        );
        if (existingIdx >= 0) {
          cache.messages[existingIdx] = message; // Update in-place
          cache.lastLoaded = DateTime.now();
          return;
        }
      }
      cache.messages.add(message);
      cache.messages.sort();
      cache.newestTimestamp = cache.messages.last.timestamp;
      cache.lastLoaded = DateTime.now(); // Refresh cache timestamp
    }
  }

  /// Invalidate message cache for a conversation
  /// Call this when messages are deleted or history is cleared
  void invalidateMessageCache(String callsign) {
    _messageCache.remove(callsign.toUpperCase());
  }

  /// Verify a message signature per chat-format-specification.md
  ///
  /// For DMs, roomId should be the RECIPIENT's callsign.
  /// Delegates to SigningService.verifyMessageSignature() for the actual verification.
  bool verifySignature(ChatMessage message, {String? roomId}) {
    return SigningService().verifyMessageSignature(message, roomId: roomId);
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

  /// Get all conversation callsigns (for showing chat icon on devices with history)
  Set<String> get conversationCallsigns {
    return _conversations.keys.toSet();
  }

  /// Check if a conversation exists with a specific callsign
  bool hasConversation(String callsign) {
    return _conversations.containsKey(callsign.toUpperCase());
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
    final relativePath = normalizedCallsign;

    try {
      if (await _storage!.directoryExists(relativePath)) {
        await _storage!.deleteDirectory(relativePath);
      }

      _conversations.remove(normalizedCallsign);
      _messageCache.remove(normalizedCallsign); // Invalidate cache
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
