/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import '../models/chat_message.dart';
import '../models/chat_channel.dart';
import '../models/chat_security.dart';
import '../util/chat_format.dart';
import '../util/event_bus.dart';
import '../util/reaction_utils.dart';
import 'profile_service.dart';
import 'nip05_registry_service.dart';
import 'profile_storage.dart';
import 'signing_service.dart';

// NOTE: All file operations now use ProfileStorage abstraction.
// File watching (startWatching/stopWatching) still requires direct filesystem access
// for Directory.watch() functionality - this is intentional as ProfileStorage
// doesn't support file system event streams.

/// Notification when chat files change
class ChatFileChange {
  final String channelId;
  final DateTime timestamp;

  ChatFileChange(this.channelId, this.timestamp);
}

/// Service for managing chat collections and messages
///
/// IMPORTANT: All file operations go through the ProfileStorage abstraction.
/// Never use File() or Directory() directly in this service except for
/// file watching functionality which requires direct filesystem access.
class ChatService {
  static final ChatService _instance = ChatService._internal();
  factory ChatService() => _instance;
  ChatService._internal();

  /// Profile storage for file operations (encrypted or filesystem)
  /// IMPORTANT: This MUST be set before using the service.
  /// All file operations go through this abstraction.
  late ProfileStorage _storage;

  /// Current collection path
  String? _appPath;

  /// Loaded channels
  List<ChatChannel> _channels = [];

  /// Participant npub mapping
  Map<String, String> _participants = {};

  /// Security settings (moderators)
  ChatSecurity _security = ChatSecurity();

  /// Hidden message IDs by channel (local-only)
  final Map<String, Set<String>> _hiddenMessageIds = {};

  /// File system watcher subscriptions (requires direct filesystem access)
  final List<StreamSubscription<FileSystemEvent>> _watchSubscriptions = [];

  /// Stream controller for file change notifications
  final StreamController<ChatFileChange> _changeController =
      StreamController<ChatFileChange>.broadcast();

  /// Stream of file change notifications
  Stream<ChatFileChange> get onFileChange => _changeController.stream;

  /// Whether using encrypted storage
  bool get useEncryptedStorage => _storage.isEncrypted;

  /// Set the profile storage for file operations
  /// MUST be called before initializeApp
  void setStorage(ProfileStorage storage) {
    _storage = storage;
  }

  /// Get attachment file bytes for display.
  ///
  /// This method reads attachment files through ProfileStorage, enabling
  /// transparent access to files in both filesystem and encrypted storage.
  ///
  /// [channelFolder] is the channel's folder name (e.g., "main/2025" or "GROUP1")
  /// [filename] is the attachment filename
  ///
  /// Returns the file bytes, or null if not found.
  Future<Uint8List?> getAttachmentBytes(String channelFolder, String filename) async {
    final relativePath = '$channelFolder/files/$filename';
    return await _storage.readBytes(relativePath);
  }

  /// Get the relative path from collection path
  String _getRelativePath(String fullPath) {
    if (_appPath == null) return fullPath;
    if (fullPath.startsWith(_appPath!)) {
      final rel = fullPath.substring(_appPath!.length);
      return rel.startsWith('/') ? rel.substring(1) : rel;
    }
    return fullPath;
  }

  /// Initialize chat service for a collection
  Future<void> initializeApp(String appPath, {String? creatorNpub}) async {
    _appPath = appPath;
    await _loadChannels();
    await _loadParticipants();
    await _loadSecurity();
    await _loadHiddenMessages();

    // If this is a new collection (no admin set) and creator npub provided, set as admin
    if (_security.adminNpub == null && creatorNpub != null && creatorNpub.isNotEmpty) {
      final newSecurity = ChatSecurity(adminNpub: creatorNpub);
      await saveSecurity(newSecurity);
    }
  }

  String _hiddenMessageKey(ChatMessage message) {
    return '${message.timestamp}|${message.author}';
  }

  Future<void> _loadHiddenMessages() async {
    if (_appPath == null) return;

    try {
      final content = await _storage.readString('extra/hidden_messages.json');
      if (content == null) return;

      final json = jsonDecode(content) as Map<String, dynamic>;
      final channels = json['channels'] as Map<String, dynamic>? ?? {};

      _hiddenMessageIds.clear();
      channels.forEach((channelId, entries) {
        final ids = (entries as List<dynamic>).map((e) => e.toString()).toSet();
        _hiddenMessageIds[channelId] = ids;
      });
    } catch (e) {
      print('Error loading hidden messages: $e');
    }
  }

  Future<void> _saveHiddenMessages() async {
    if (_appPath == null) return;

    final data = {
      'version': '1.0',
      'channels': _hiddenMessageIds.map((channelId, ids) {
        return MapEntry(channelId, ids.toList());
      }),
    };

    final content = const JsonEncoder.withIndent('  ').convert(data);

    await _storage.createDirectory('extra');
    await _storage.writeString('extra/hidden_messages.json', content);
  }

  bool isMessageHidden(String channelId, ChatMessage message) {
    final ids = _hiddenMessageIds[channelId];
    if (ids == null) return false;
    return ids.contains(_hiddenMessageKey(message));
  }

  Future<void> hideMessage(String channelId, ChatMessage message) async {
    final ids = _hiddenMessageIds.putIfAbsent(channelId, () => <String>{});
    ids.add(_hiddenMessageKey(message));
    await _saveHiddenMessages();
  }

  Future<void> unhideMessage(String channelId, ChatMessage message) async {
    final ids = _hiddenMessageIds[channelId];
    if (ids == null) return;
    ids.remove(_hiddenMessageKey(message));
    await _saveHiddenMessages();
  }

  /// Get collection path
  String? get appPath => _appPath;

  /// Get loaded channels
  List<ChatChannel> get channels => List.unmodifiable(_channels);

  /// Get participants
  Map<String, String> get participants => Map.unmodifiable(_participants);

  /// Get security settings
  ChatSecurity get security => _security;

  /// Start watching chat files for changes
  void startWatching() {
    stopWatching(); // Clear any existing watchers

    if (_appPath == null) {
      if (!kIsWeb) stderr.writeln('ChatService: Cannot start watching - no collection path');
      return;
    }

    // File watching is not supported on web
    if (kIsWeb) {
      return;
    }

    // File watching requires real filesystem - not supported with encrypted storage
    // Other mechanisms handle updates: Station WebSocket, polling, and EventBus
    if (_storage.isEncrypted) {
      return;
    }

    stderr.writeln('ChatService: Starting file watchers for ${_channels.length} channels at $_appPath');

    // Watch main channel folder and subfolders
    for (final channel in _channels) {
      final channelDir = Directory(p.join(_appPath!, channel.folder));
      stderr.writeln('ChatService: Checking channel ${channel.id} at ${channelDir.path}');
      if (channelDir.existsSync()) {
        try {
          final subscription = channelDir
              .watch(events: FileSystemEvent.modify | FileSystemEvent.create, recursive: true)
              .listen((event) {
            stderr.writeln('ChatService: File change detected: ${event.path}');
            // Only notify for chat files
            if (event.path.endsWith('_chat.txt') || event.path.endsWith('messages.txt')) {
              stderr.writeln('ChatService: Notifying change for channel ${channel.id}');
              _changeController.add(ChatFileChange(channel.id, DateTime.now()));
            }
          });
          _watchSubscriptions.add(subscription);
          stderr.writeln('ChatService: Started watching ${channelDir.path}');
        } catch (e) {
          stderr.writeln('ChatService: Failed to watch ${channelDir.path}: $e');
        }
      } else {
        stderr.writeln('ChatService: Channel dir does not exist: ${channelDir.path}');
      }
    }
  }

  /// Stop watching chat files
  void stopWatching() {
    for (final sub in _watchSubscriptions) {
      sub.cancel();
    }
    _watchSubscriptions.clear();
  }

  /// Load channels from channels.json
  Future<void> _loadChannels() async {
    if (_appPath == null) return;

    try {
      final content = await _storage.readString('extra/channels.json');

      if (content == null) {
        _channels = [];
        return;
      }

      final json = jsonDecode(content) as Map<String, dynamic>;
      final channelsList = json['channels'] as List;

      _channels = channelsList
          .map((ch) => ChatChannel.fromJson(ch as Map<String, dynamic>))
          .toList();
    } catch (e) {
      print('Error loading channels: $e');
      _channels = [];
    }
  }

  /// Save channels to channels.json
  Future<void> _saveChannels() async {
    if (_appPath == null) return;

    final json = {
      'version': '1.0',
      'channels': _channels.map((ch) => ch.toJson()).toList(),
    };
    final content = const JsonEncoder.withIndent('  ').convert(json);

    await _storage.createDirectory('extra');
    await _storage.writeString('extra/channels.json', content);
  }

  /// Load participants from participants.json
  Future<void> _loadParticipants() async {
    if (_appPath == null) return;

    try {
      final content = await _storage.readString('extra/participants.json');

      if (content == null) {
        _participants = {};
        return;
      }

      final json = jsonDecode(content) as Map<String, dynamic>;
      final participantsMap = json['participants'] as Map<String, dynamic>?;

      if (participantsMap != null) {
        _participants = {};
        participantsMap.forEach((callsign, data) {
          final participantData = data as Map<String, dynamic>;
          _participants[callsign] = participantData['npub'] as String? ?? '';
        });
      }
    } catch (e) {
      print('Error loading participants: $e');
      _participants = {};
    }
  }

  /// Save participants to participants.json
  Future<void> _saveParticipants() async {
    if (_appPath == null) return;

    final Map<String, dynamic> participantsMap = {};
    _participants.forEach((callsign, npub) {
      participantsMap[callsign] = {
        'callsign': callsign,
        'npub': npub,
        'lastSeen': DateTime.now().toIso8601String(),
      };
    });

    final json = {
      'version': '1.0',
      'participants': participantsMap,
    };
    final content = const JsonEncoder.withIndent('  ').convert(json);

    await _storage.createDirectory('extra');
    await _storage.writeString('extra/participants.json', content);
  }

  /// Add a new participant
  Future<void> addParticipant(String callsign, {String? npub}) async {
    if (!_participants.containsKey(callsign)) {
      _participants[callsign] = npub ?? '';
      await _saveParticipants();
    }
  }

  /// Load security settings from security.json
  Future<void> _loadSecurity() async {
    if (_appPath == null) return;

    try {
      final content = await _storage.readString('extra/security.json');

      if (content == null) {
        _security = ChatSecurity();
        return;
      }

      final json = jsonDecode(content) as Map<String, dynamic>;
      _security = ChatSecurity.fromJson(json);
    } catch (e) {
      print('Error loading security: $e');
      _security = ChatSecurity();
    }
  }

  /// Save security settings to security.json
  Future<void> saveSecurity(ChatSecurity security) async {
    if (_appPath == null) return;

    _security = security;

    final json = {
      'version': '1.0',
      ..._security.toJson(),
    };
    final content = const JsonEncoder.withIndent('  ').convert(json);

    await _storage.createDirectory('extra');
    await _storage.writeString('extra/security.json', content);
  }

  /// Create a new channel
  Future<ChatChannel> createChannel(ChatChannel channel) async {
    if (_appPath == null) {
      throw Exception('Collection not initialized');
    }

    // Check if channel already exists
    if (_channels.any((ch) => ch.id == channel.id)) {
      throw Exception('Channel already exists: ${channel.id}');
    }

    // Create config.json content
    var config = channel.config ??
        ChatChannelConfig.defaults(
          id: channel.id,
          name: channel.name,
          description: channel.description,
        );

    if (channel.isGroup && config.owner == null && _security.adminNpub != null) {
      config = config.copyWith(owner: _security.adminNpub);
    }

    final configContent = const JsonEncoder.withIndent('  ').convert(config.toJson());

    // Use ProfileStorage abstraction for all channel creation
    final channelFolder = channel.folder;

    // Create channel folder and files subfolder
    await _storage.createDirectory(channelFolder);
    await _storage.createDirectory('$channelFolder/files');

    // Create config.json
    await _storage.writeString('$channelFolder/config.json', configContent);

    // For main channel, create year folder structure
    if (channel.isMain) {
      final year = DateTime.now().year.toString();
      await _storage.createDirectory('$channelFolder/$year');
      await _storage.createDirectory('$channelFolder/$year/files');
    }

    // Add to channels list and save
    _channels.add(channel);
    await _saveChannels();

    return channel;
  }

  /// Delete a channel
  Future<void> deleteChannel(String channelId) async {
    if (_appPath == null) return;

    final channel = _channels.firstWhere(
      (ch) => ch.id == channelId,
      orElse: () => throw Exception('Channel not found: $channelId'),
    );

    // Don't allow deleting main channel
    if (channel.isMain) {
      throw Exception('Cannot delete main channel');
    }

    // Delete channel folder via storage abstraction
    await _storage.deleteDirectory(channel.folder, recursive: true);

    // Remove from list and save
    _channels.removeWhere((ch) => ch.id == channelId);
    await _saveChannels();
  }

  /// Get channel by ID
  /// Treats 'general' as an alias for 'main' (the default main channel)
  ChatChannel? getChannel(String channelId) {
    try {
      // Treat 'general' as an alias for 'main' (common naming convention)
      final normalizedId = channelId.toLowerCase() == 'general' ? 'main' : channelId;
      return _channels.firstWhere((ch) => ch.id == normalizedId);
    } catch (e) {
      return null;
    }
  }

  /// Get or create a direct message channel with another device
  /// Room ID = other device's callsign (uppercase)
  /// Creates a RESTRICTED chat room where only the two participants can access
  Future<ChatChannel> getOrCreateDirectChannel(String otherCallsign) async {
    final roomId = otherCallsign.toUpperCase();
    final myCallsign = ProfileService().getProfile().callsign.toUpperCase();

    // Check if channel already exists
    final existing = getChannel(roomId);
    if (existing != null) {
      return existing;
    }

    // Create new RESTRICTED direct channel
    // Both participants are added: myCallsign and otherCallsign
    final config = ChatChannelConfig(
      id: roomId,
      name: 'Chat with $roomId',
      description: 'Direct message with $roomId',
      visibility: 'RESTRICTED',
    );

    final channel = ChatChannel(
      id: roomId,
      type: ChatChannelType.direct,
      name: 'Chat with $roomId',
      folder: roomId,
      participants: [myCallsign, roomId],
      description: 'Direct message with $roomId',
      created: DateTime.now(),
      config: config,
    );

    await createChannel(channel);
    return channel;
  }

  /// Load messages for a channel
  Future<List<ChatMessage>> loadMessages(
    String channelId, {
    DateTime? startDate,
    DateTime? endDate,
    int limit = 100,
  }) async {
    if (_appPath == null) return [];

    final channel = getChannel(channelId);
    if (channel == null) return [];

    // Check if channel exists via storage abstraction
    if (!await _storage.directoryExists(channel.folder)) return [];

    List<ChatMessage> messages = [];

    if (channel.isMain) {
      // Load from daily files in year folders
      messages = await _loadMainChannelMessagesStorage(channel.folder, startDate, endDate);
    } else {
      // Load from single messages.txt file
      messages = await _loadSingleFileMessagesStorage(channel.folder);
    }

    // Sort by timestamp
    messages.sort();

    // Apply limit
    if (messages.length > limit) {
      messages = messages.sublist(messages.length - limit);
    }

    // Verify signatures for loaded messages (like DirectMessageService does)
    for (final msg in messages) {
      if (msg.isSigned) {
        SigningService().verifyMessageSignature(msg, roomId: channelId);
      }
    }

    return messages;
  }

  /// Load messages from single file (ProfileStorage)
  Future<List<ChatMessage>> _loadSingleFileMessagesStorage(String channelFolder) async {
    final messagesPath = '$channelFolder/messages.txt';
    final content = await _storage.readString(messagesPath);
    if (content == null) return [];
    return parseMessageText(content);
  }

  /// Load messages from main channel (ProfileStorage)
  Future<List<ChatMessage>> _loadMainChannelMessagesStorage(
    String channelFolder,
    DateTime? startDate,
    DateTime? endDate,
  ) async {
    List<ChatMessage> messages = [];

    // Find all year folders
    final entries = await _storage.listDirectory(channelFolder);
    final yearFolders = entries
        .where((e) => e.isDirectory && _isYearFolder(e.name))
        .toList();

    for (var yearFolder in yearFolders) {
      // Find all chat files in year folder
      final yearEntries = await _storage.listDirectory('$channelFolder/${yearFolder.name}');
      final chatFiles = yearEntries
          .where((e) => !e.isDirectory && e.name.endsWith('_chat.txt'))
          .toList();

      for (var file in chatFiles) {
        // Parse file date from filename (YYYY-MM-DD_chat.txt)
        final dateStr = file.name.substring(0, 10); // YYYY-MM-DD

        // Skip if outside date range
        if (startDate != null || endDate != null) {
          try {
            final fileDate = DateTime.parse(dateStr);
            if (startDate != null && fileDate.isBefore(startDate)) continue;
            if (endDate != null && fileDate.isAfter(endDate)) continue;
          } catch (e) {
            continue; // Skip files with invalid dates
          }
        }

        // Parse messages from file
        final content = await _storage.readString('$channelFolder/${yearFolder.name}/${file.name}');
        if (content != null) {
          messages.addAll(parseMessageText(content));
        }
      }
    }

    return messages;
  }

  // ============================================================
  // Modification Log (for offline client sync)
  // ============================================================

  /// Append a modification entry to the room's modification log.
  /// File: extra/chat/{roomId}/modifications.jsonl
  Future<void> _appendModificationLog(
    String roomId,
    Map<String, dynamic> entry,
  ) async {
    try {
      final logPath = 'extra/chat/$roomId/modifications.jsonl';
      final existing = await _storage.readString(logPath);
      final line = jsonEncode(entry);
      final newContent = existing != null ? '$existing\n$line' : line;
      await _storage.createDirectory('extra/chat/$roomId');
      await _storage.writeString(logPath, newContent);
    } catch (e) {
      // Non-critical: don't fail the operation if logging fails
      stderr.writeln('ChatService: Failed to write modification log: $e');
    }
  }

  /// Get modifications for a room since a given timestamp.
  /// Returns list of modification entries as maps.
  Future<List<Map<String, dynamic>>> getModifications(
    String roomId, {
    DateTime? since,
  }) async {
    try {
      final logPath = 'extra/chat/$roomId/modifications.jsonl';
      final content = await _storage.readString(logPath);
      if (content == null || content.trim().isEmpty) return [];

      final entries = <Map<String, dynamic>>[];
      for (final line in content.split('\n')) {
        if (line.trim().isEmpty) continue;
        try {
          final entry = jsonDecode(line.trim()) as Map<String, dynamic>;
          if (since != null) {
            final at = entry['at'] as String?;
            if (at != null) {
              final entryTime = DateTime.tryParse(at);
              if (entryTime != null && entryTime.isBefore(since)) continue;
            }
          }
          entries.add(entry);
        } catch (_) {
          // Skip malformed lines
        }
      }
      return entries;
    } catch (e) {
      return [];
    }
  }

  /// Parse message text content (static for testing)
  /// Uses unified ChatFormat parser for consistency with server
  static List<ChatMessage> parseMessageText(String content) {
    final parsed = ChatFormat.parse(content);
    return parsed.map((p) => ChatMessage(
      author: p.author,
      timestamp: p.timestamp,
      content: p.content,
      metadata: p.metadata,
      reactions: p.reactions,
    )).toList();
  }

  /// Save a message to appropriate file
  Future<void> saveMessage(String channelId, ChatMessage message) async {
    if (_appPath == null) {
      throw Exception('Collection not initialized');
    }

    final channel = getChannel(channelId);
    if (channel == null) {
      throw Exception('Channel not found: $channelId');
    }

    // Use ProfileStorage abstraction for message saving
    String messageFilePath;

    if (channel.isMain) {
      // Get daily file path
      messageFilePath = await _getDailyMessageFilePathStorage(channel.folder, message.dateTime);
    } else {
      // Ensure channel directory exists for non-main channels
      await _storage.createDirectory(channel.folder);
      messageFilePath = '${channel.folder}/messages.txt';
    }

    // Read existing content (for append simulation - ProfileStorage doesn't have native append)
    final existing = await _storage.readString(messageFilePath);
    final needsHeader = existing == null;

    // Build content
    final buffer = StringBuffer();
    if (needsHeader) {
      buffer.write(_generateFileHeader(channel, message.dateTime));
    } else {
      buffer.write(existing);
    }
    buffer.write('\n');
    buffer.write(message.exportAsText());
    buffer.write('\n');

    await _storage.writeString(messageFilePath, buffer.toString());

    // Add author to participants if not already present
    if (!_participants.containsKey(message.author)) {
      await addParticipant(message.author, npub: message.npub);
    }

    // Update channel last message time
    channel.lastMessageTime = message.dateTime;
    await _saveChannels();

    if (EventBus().hasSubscribers<ChatMessageEvent>()) {
      EventBus().fire(ChatMessageEvent(
        roomId: channelId,
        callsign: message.author,
        content: message.content,
        npub: message.npub,
        signature: message.signature,
        verified: message.isVerified,
      ));
    }
  }

  /// Get daily message file path for main channel (ProfileStorage)
  Future<String> _getDailyMessageFilePathStorage(String channelFolder, DateTime date) async {
    final year = date.year.toString();
    final yearPath = '$channelFolder/$year';

    // Create year directory if doesn't exist
    await _storage.createDirectory(yearPath);
    await _storage.createDirectory('$yearPath/files');

    final dateStr = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    return '$yearPath/${dateStr}_chat.txt';
  }

  /// Generate file header
  String _generateFileHeader(ChatChannel channel, DateTime date) {
    final dateStr = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    return '# ${channel.id.toUpperCase()}: ${channel.name} from $dateStr\n';
  }

  /// Check if path is a year folder (4 digits)
  bool _isYearFolder(String folderPath) {
    final name = folderPath.split('/').last;
    return RegExp(r'^\d{4}$').hasMatch(name);
  }

  /// Refresh channels list
  Future<void> refreshChannels() async {
    await _loadChannels();
    await _loadParticipants();
  }

  /// Update channel
  Future<void> updateChannel(ChatChannel channel) async {
    final index = _channels.indexWhere((ch) => ch.id == channel.id);
    if (index == -1) {
      throw Exception('Channel not found: ${channel.id}');
    }

    _channels[index] = channel;
    await _saveChannels();

    // Update config.json if config changed
    if (channel.config != null && _appPath != null) {
      final configContent = const JsonEncoder.withIndent('  ').convert(channel.config!.toJson());
      await _storage.writeString('${channel.folder}/config.json', configContent);
    }
  }

  /// Get message count for a channel
  Future<int> getMessageCount(String channelId) async {
    final messages = await loadMessages(channelId, limit: 999999);
    return messages.length;
  }

  /// Search messages in a channel
  Future<List<ChatMessage>> searchMessages(
    String channelId,
    String query, {
    int limit = 50,
  }) async {
    if (query.trim().isEmpty) return [];

    final allMessages = await loadMessages(channelId, limit: 999999);
    final lowerQuery = query.toLowerCase();

    return allMessages
        .where((msg) =>
            msg.content.toLowerCase().contains(lowerQuery) ||
            msg.author.toLowerCase().contains(lowerQuery))
        .take(limit)
        .toList();
  }

  /// Delete a message (admin/moderator only)
  Future<void> deleteMessage(
    String channelId,
    ChatMessage message,
    String? userNpub,
  ) async {
    if (_appPath == null) {
      throw Exception('Collection not initialized');
    }

    // Check permissions
    if (!_security.canModerate(userNpub, channelId)) {
      throw Exception('Insufficient permissions to delete message');
    }

    final channel = getChannel(channelId);
    if (channel == null) {
      throw Exception('Channel not found: $channelId');
    }

    if (channel.isMain) {
      // Delete from daily file
      await _deleteFromDailyFileStorage(channel, message);
    } else {
      // Delete from single messages.txt
      await _deleteFromSingleFileStorage(channel, message);
    }
  }

  /// Delete message from daily file using storage (main channel)
  Future<void> _deleteFromDailyFileStorage(
    ChatChannel channel,
    ChatMessage message,
  ) async {
    final messageFilePath = await _getDailyMessageFilePathStorage(channel.folder, message.dateTime);
    final content = await _storage.readString(messageFilePath);
    if (content == null) {
      throw Exception('Message file not found');
    }

    var messages = parseMessageText(content);

    // Remove the target message
    messages.removeWhere((msg) =>
        msg.timestamp == message.timestamp && msg.author == message.author);

    // Rewrite file
    await _rewriteMessageFileStorage(messageFilePath, channel, messages, message.dateTime);
  }

  /// Delete message from single file using storage (DM or group)
  Future<void> _deleteFromSingleFileStorage(
    ChatChannel channel,
    ChatMessage message,
  ) async {
    final messageFilePath = '${channel.folder}/messages.txt';
    final content = await _storage.readString(messageFilePath);
    if (content == null) {
      throw Exception('Message file not found');
    }

    var messages = parseMessageText(content);

    // Remove the target message
    messages.removeWhere((msg) =>
        msg.timestamp == message.timestamp && msg.author == message.author);

    // Rewrite file
    await _rewriteMessageFileStorage(messageFilePath, channel, messages, message.dateTime);
  }

  /// Rewrite message file with updated messages using storage
  Future<void> _rewriteMessageFileStorage(
    String filePath,
    ChatChannel channel,
    List<ChatMessage> messages,
    DateTime date,
  ) async {
    final buffer = StringBuffer();

    // Write header
    final header = _generateFileHeader(channel, date);
    buffer.write(header);

    // Write each message
    for (var message in messages) {
      buffer.write('\n');
      buffer.write(message.exportAsText());
      buffer.write('\n');
    }

    await _storage.writeString(filePath, buffer.toString());
  }

  // ============================================================
  // Message Find and Edit Methods
  // ============================================================

  /// Find a message by timestamp (and optionally author)
  /// Returns null if message not found
  Future<ChatMessage?> findMessage(
    String channelId,
    String timestamp, {
    String? author,
  }) async {
    if (_appPath == null) {
      return null;
    }

    final channel = getChannel(channelId);
    if (channel == null) {
      return null;
    }

    // Parse the timestamp to get the date for daily files
    DateTime? messageDate;
    try {
      // Format: YYYY-MM-DD HH:MM_ss
      final datePart = timestamp.substring(0, 10);
      final parts = datePart.split('-');
      messageDate = DateTime(
        int.parse(parts[0]),
        int.parse(parts[1]),
        int.parse(parts[2]),
      );
    } catch (e) {
      // If we can't parse the timestamp, we'll need to search all files
      messageDate = null;
    }

    List<ChatMessage> messages;

    if (channel.isMain && messageDate != null) {
      // Load from specific daily file
      final messageFilePath = await _getDailyMessageFilePathStorage(channel.folder, messageDate);
      final content = await _storage.readString(messageFilePath);
      if (content == null) {
        return null;
      }
      messages = parseMessageText(content);
    } else if (!channel.isMain) {
      // Load from single messages.txt
      final messageFilePath = '${channel.folder}/messages.txt';
      final content = await _storage.readString(messageFilePath);
      if (content == null) {
        return null;
      }
      messages = parseMessageText(content);
    } else {
      // Main channel but couldn't parse date - load all messages
      messages = await loadMessages(channelId, limit: 10000);
    }

    // Find the message by timestamp (and optionally author)
    for (final msg in messages) {
      if (msg.timestamp == timestamp) {
        if (author == null || msg.author == author) {
          return msg;
        }
      }
    }

    return null;
  }

  /// Edit a message - only the original author can edit
  /// Returns the updated message, or null if not found/not authorized
  Future<ChatMessage?> editMessage({
    required String channelId,
    required String timestamp,
    required String authorCallsign,
    required String newContent,
    required String actorNpub,
    required String newSignature,
    required int newCreatedAt,
  }) async {
    if (_appPath == null) {
      throw Exception('Collection not initialized');
    }

    final channel = getChannel(channelId);
    if (channel == null) {
      throw Exception('Channel not found: $channelId');
    }

    // Parse the timestamp to get the date for daily files
    DateTime messageDate;
    try {
      final datePart = timestamp.substring(0, 10);
      final parts = datePart.split('-');
      messageDate = DateTime(
        int.parse(parts[0]),
        int.parse(parts[1]),
        int.parse(parts[2]),
      );
    } catch (e) {
      throw Exception('Invalid timestamp format: $timestamp');
    }

    List<ChatMessage> messages;
    ChatMessage? targetMessage;
    int targetIndex = -1;
    String messageFilePath;

    if (channel.isMain) {
      // Load from daily file
      messageFilePath = await _getDailyMessageFilePathStorage(channel.folder, messageDate);
    } else {
      // Load from single messages.txt
      messageFilePath = '${channel.folder}/messages.txt';
    }

    final content = await _storage.readString(messageFilePath);
    if (content == null) {
      throw Exception('Message file not found');
    }
    messages = parseMessageText(content);

    // Find the target message
    for (int i = 0; i < messages.length; i++) {
      if (messages[i].timestamp == timestamp && messages[i].author == authorCallsign) {
        targetMessage = messages[i];
        targetIndex = i;
        break;
      }
    }

    if (targetMessage == null) {
      throw Exception('Message not found');
    }

    // Verify authorization: author can edit own, moderators can edit any
    final messageNpub = targetMessage.npub;
    final isAuthor = messageNpub == actorNpub;
    final isModerator = _security.canModerate(actorNpub, channelId);
    if (!isAuthor && !isModerator) {
      throw Exception('Not authorized to edit this message');
    }

    // Create the edited_at timestamp
    final now = DateTime.now();
    final editedAt = ChatFormat.formatTimestamp(now);

    // Create updated message with new content, edited_at, and new signature
    final updatedMetadata = Map<String, String>.from(targetMessage.metadata);
    updatedMetadata['edited_at'] = editedAt;
    updatedMetadata['npub'] = actorNpub;
    updatedMetadata['signature'] = newSignature;
    updatedMetadata['created_at'] = newCreatedAt.toString();

    // Add mod attribution when a moderator edits someone else's message
    if (!isAuthor && isModerator) {
      updatedMetadata['edited_by_mod'] = actorNpub;
      final reg = Nip05RegistryService().getRegistrationByNpub(actorNpub);
      if (reg != null) {
        updatedMetadata['mod_callsign'] = reg.callsign;
        if (reg.nickname != null) {
          updatedMetadata['mod_nickname'] = reg.nickname!;
        }
      }
    }

    final updatedMessage = targetMessage.copyWith(
      content: newContent,
      metadata: updatedMetadata,
    );

    // Replace the message in the list
    messages[targetIndex] = updatedMessage;

    // Rewrite the file
    await _rewriteMessageFileStorage(messageFilePath, channel, messages, messageDate);

    // Append to modification log for offline client sync
    await _appendModificationLog(channelId, {
      'action': 'edit',
      'timestamp': timestamp,
      'author': authorCallsign,
      'content': newContent,
      'at': DateTime.now().toUtc().toIso8601String(),
    });

    return updatedMessage;
  }

  /// Delete a message - author can delete own, moderators can delete any
  /// Returns true if deleted, throws exception on error
  Future<bool> deleteMessageByTimestamp({
    required String channelId,
    required String timestamp,
    required String authorCallsign,
    required String actorNpub,
  }) async {
    if (_appPath == null) {
      throw Exception('Collection not initialized');
    }

    final channel = getChannel(channelId);
    if (channel == null) {
      throw Exception('Channel not found: $channelId');
    }

    // Parse the timestamp to get the date for daily files
    DateTime messageDate;
    try {
      final datePart = timestamp.substring(0, 10);
      final parts = datePart.split('-');
      messageDate = DateTime(
        int.parse(parts[0]),
        int.parse(parts[1]),
        int.parse(parts[2]),
      );
    } catch (e) {
      throw Exception('Invalid timestamp format: $timestamp');
    }

    List<ChatMessage> messages;
    ChatMessage? targetMessage;
    String messageFilePath;

    if (channel.isMain) {
      // Load from daily file
      messageFilePath = await _getDailyMessageFilePathStorage(channel.folder, messageDate);
    } else {
      // Load from single messages.txt
      messageFilePath = '${channel.folder}/messages.txt';
    }

    final content = await _storage.readString(messageFilePath);
    if (content == null) {
      throw Exception('Message file not found');
    }
    messages = parseMessageText(content);

    // Find the target message
    for (final msg in messages) {
      if (msg.timestamp == timestamp && msg.author == authorCallsign) {
        targetMessage = msg;
        break;
      }
    }

    if (targetMessage == null) {
      throw Exception('Message not found');
    }

    // Verify authorization: author can delete own, moderators can delete any
    final messageNpub = targetMessage.npub;
    final isAuthor = messageNpub == actorNpub;
    final isModerator = _security.canModerate(actorNpub, channelId);

    if (!isAuthor && !isModerator) {
      throw Exception('Not authorized to delete this message');
    }

    // Remove the message from the list
    messages.removeWhere((msg) =>
        msg.timestamp == timestamp && msg.author == authorCallsign);

    // Rewrite the file
    await _rewriteMessageFileStorage(messageFilePath, channel, messages, messageDate);

    // Append to modification log for offline client sync
    await _appendModificationLog(channelId, {
      'action': 'delete',
      'timestamp': timestamp,
      'author': authorCallsign,
      'at': DateTime.now().toUtc().toIso8601String(),
    });

    return true;
  }

  /// Toggle a reaction for a message by timestamp
  /// Returns updated message or null if not found
  Future<ChatMessage?> toggleReaction({
    required String channelId,
    required String timestamp,
    required String actorCallsign,
    required String reaction,
  }) async {
    if (_appPath == null) {
      throw Exception('Collection not initialized');
    }

    final channel = getChannel(channelId);
    if (channel == null) {
      throw Exception('Channel not found: $channelId');
    }

    final reactionKey = ReactionUtils.normalizeReactionKey(reaction);
    final actorKey = actorCallsign.trim().toUpperCase();
    if (reactionKey.isEmpty || actorKey.isEmpty) {
      throw Exception('Invalid reaction or callsign');
    }

    // Parse the timestamp to get the date for daily files
    DateTime messageDate;
    try {
      final datePart = timestamp.substring(0, 10);
      final parts = datePart.split('-');
      messageDate = DateTime(
        int.parse(parts[0]),
        int.parse(parts[1]),
        int.parse(parts[2]),
      );
    } catch (e) {
      throw Exception('Invalid timestamp format: $timestamp');
    }

    List<ChatMessage> messages;
    int targetIndex = -1;
    String messageFilePath;

    if (channel.isMain) {
      messageFilePath = await _getDailyMessageFilePathStorage(channel.folder, messageDate);
    } else {
      messageFilePath = '${channel.folder}/messages.txt';
    }

    final content = await _storage.readString(messageFilePath);
    if (content == null) {
      return null;
    }
    messages = parseMessageText(content);

    for (int i = 0; i < messages.length; i++) {
      if (messages[i].timestamp == timestamp) {
        targetIndex = i;
        break;
      }
    }

    if (targetIndex == -1) {
      return null;
    }

    final updatedMessage = _toggleMessageReaction(messages[targetIndex], reactionKey, actorKey);
    messages[targetIndex] = updatedMessage;

    await _rewriteMessageFileStorage(messageFilePath, channel, messages, messageDate);

    return updatedMessage;
  }

  ChatMessage _toggleMessageReaction(
    ChatMessage message,
    String reactionKey,
    String actorCallsign,
  ) {
    final updatedReactions = <String, List<String>>{};
    final normalizedActor = actorCallsign.trim().toUpperCase();

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

    // Check if user already has this specific reaction (for toggle-off)
    final currentList = updatedReactions[normalizedKey] ?? <String>[];
    final alreadyHasThisReaction = currentList.any((u) => u.toUpperCase() == normalizedActor);

    // Remove user from ALL reaction types first (enforce one reaction per user)
    for (final key in updatedReactions.keys.toList()) {
      updatedReactions[key]?.removeWhere((u) => u.toUpperCase() == normalizedActor);
      if (updatedReactions[key]?.isEmpty ?? true) {
        updatedReactions.remove(key);
      }
    }

    // If clicking the same reaction they had, just remove it (toggle off)
    // Otherwise, add the new reaction
    if (!alreadyHasThisReaction) {
      final list = updatedReactions[normalizedKey] ?? <String>[];
      list.add(normalizedActor);
      updatedReactions[normalizedKey] = list;
    }

    return message.copyWith(reactions: updatedReactions);
  }

  // ============================================================
  // Role-Based Access Control Methods for Restricted Chat Rooms
  // ============================================================

  /// Create a restricted chat room with the caller as owner
  Future<ChatChannel> createRestrictedRoom({
    required String id,
    required String name,
    required String ownerNpub,
    String? description,
  }) async {
    if (_appPath == null) {
      throw Exception('Collection not initialized');
    }

    // Check if channel already exists
    if (_channels.any((ch) => ch.id == id)) {
      throw Exception('Channel already exists: $id');
    }

    // Create config with owner set
    final config = ChatChannelConfig(
      id: id,
      name: name,
      description: description,
      visibility: 'RESTRICTED',
      owner: ownerNpub,
      admins: [],
      moderatorNpubs: [],
      members: [ownerNpub], // Owner is automatically a member
      banned: [],
      pendingApplicants: [],
    );

    final channel = ChatChannel(
      id: id,
      type: ChatChannelType.group,
      name: name,
      folder: id,
      participants: [], // Will be managed through config.members
      description: description,
      created: DateTime.now(),
      config: config,
    );

    return await createChannel(channel);
  }

  /// Create a chat room linked to a group for dynamic membership
  /// The room's membership is resolved dynamically from GroupsService
  Future<ChatChannel> createGroupLinkedRoom({
    required String groupId,
    required String name,
    required String ownerNpub,
    String? description,
  }) async {
    if (_appPath == null) {
      throw Exception('Collection not initialized');
    }

    // Check if channel already exists
    if (_channels.any((ch) => ch.id == groupId)) {
      throw Exception('Channel already exists: $groupId');
    }

    // Create config with groupId for dynamic membership lookup
    final config = ChatChannelConfig(
      id: groupId,
      name: name,
      description: description,
      visibility: 'RESTRICTED',
      owner: ownerNpub,
      groupId: groupId, // Link to group for dynamic membership
      admins: [],
      moderatorNpubs: [],
      members: [ownerNpub], // Owner is initially a member, will be resolved dynamically
      banned: [],
      pendingApplicants: [],
    );

    final channel = ChatChannel(
      id: groupId,
      type: ChatChannelType.group,
      name: name,
      folder: groupId,
      participants: [], // Will be resolved dynamically from group
      description: description,
      created: DateTime.now(),
      config: config,
    );

    return await createChannel(channel);
  }

  /// Add a member to a restricted room (moderator+ required)
  Future<void> addMember(String roomId, String actorNpub, String memberNpub) async {
    final channel = getChannel(roomId);
    if (channel == null) {
      throw Exception('Room not found: $roomId');
    }

    final config = channel.config;
    if (config == null) {
      throw Exception('Room has no configuration: $roomId');
    }

    // Check permissions
    if (!config.canManageMembers(actorNpub)) {
      throw PermissionDeniedException('Only moderators and above can add members');
    }

    // Check if user is banned
    if (config.isBanned(memberNpub)) {
      throw PermissionDeniedException('User is banned from this room');
    }

    // Check if already a member
    if (config.isMember(memberNpub)) {
      return; // Already a member, no-op
    }

    // Add to members list
    final updatedMembers = List<String>.from(config.members)..add(memberNpub);

    // Remove from pending applicants if present
    final updatedApplicants = config.pendingApplicants
        .where((a) => a.npub != memberNpub)
        .toList();

    final updatedConfig = config.copyWith(
      members: updatedMembers,
      pendingApplicants: updatedApplicants,
    );

    await updateChannel(channel.copyWith(config: updatedConfig));
  }

  /// Remove a member from a restricted room (moderator+ required)
  Future<void> removeMember(String roomId, String actorNpub, String targetNpub) async {
    final channel = getChannel(roomId);
    if (channel == null) {
      throw Exception('Room not found: $roomId');
    }

    final config = channel.config;
    if (config == null) {
      throw Exception('Room has no configuration: $roomId');
    }

    // Cannot remove the owner
    if (config.isOwner(targetNpub)) {
      throw PermissionDeniedException('Cannot remove the room owner');
    }

    // Check permissions - need to be higher rank than target
    if (config.isAdmin(targetNpub)) {
      // Only owner can remove admins
      if (!config.isOwner(actorNpub)) {
        throw PermissionDeniedException('Only the owner can remove admins');
      }
    } else if (config.isModerator(targetNpub)) {
      // Only admin+ can remove moderators
      if (!config.isAdmin(actorNpub)) {
        throw PermissionDeniedException('Only admins can remove moderators');
      }
    } else {
      // Moderator+ can remove regular members
      if (!config.canManageMembers(actorNpub)) {
        throw PermissionDeniedException('Only moderators and above can remove members');
      }
    }

    // Remove from all role lists
    final updatedAdmins = List<String>.from(config.admins)..remove(targetNpub);
    final updatedModerators = List<String>.from(config.moderatorNpubs)..remove(targetNpub);
    final updatedMembers = List<String>.from(config.members)..remove(targetNpub);

    final updatedConfig = config.copyWith(
      admins: updatedAdmins,
      moderatorNpubs: updatedModerators,
      members: updatedMembers,
    );

    await updateChannel(channel.copyWith(config: updatedConfig));
  }

  /// Ban a user from a restricted room (moderator+ required)
  Future<void> banMember(String roomId, String actorNpub, String targetNpub) async {
    final channel = getChannel(roomId);
    if (channel == null) {
      throw Exception('Room not found: $roomId');
    }

    final config = channel.config;
    if (config == null) {
      throw Exception('Room has no configuration: $roomId');
    }

    // Cannot ban the owner
    if (config.isOwner(targetNpub)) {
      throw PermissionDeniedException('Cannot ban the room owner');
    }

    // Check permissions
    if (!config.canBan(actorNpub)) {
      throw PermissionDeniedException('Only moderators and above can ban users');
    }

    // Cannot ban someone of equal or higher rank
    if (config.isAdmin(targetNpub) && !config.isOwner(actorNpub)) {
      throw PermissionDeniedException('Only the owner can ban admins');
    }
    if (config.isModerator(targetNpub) && !config.isAdmin(actorNpub)) {
      throw PermissionDeniedException('Only admins can ban moderators');
    }

    // Remove from all role lists and add to banned
    final updatedAdmins = List<String>.from(config.admins)..remove(targetNpub);
    final updatedModerators = List<String>.from(config.moderatorNpubs)..remove(targetNpub);
    final updatedMembers = List<String>.from(config.members)..remove(targetNpub);
    final updatedBanned = List<String>.from(config.banned);
    if (!updatedBanned.contains(targetNpub)) {
      updatedBanned.add(targetNpub);
    }

    // Also remove from pending applicants
    final updatedApplicants = config.pendingApplicants
        .where((a) => a.npub != targetNpub)
        .toList();

    final updatedConfig = config.copyWith(
      admins: updatedAdmins,
      moderatorNpubs: updatedModerators,
      members: updatedMembers,
      banned: updatedBanned,
      pendingApplicants: updatedApplicants,
    );

    await updateChannel(channel.copyWith(config: updatedConfig));
  }

  /// Unban a user from a restricted room (moderator+ required)
  Future<void> unbanMember(String roomId, String actorNpub, String targetNpub) async {
    final channel = getChannel(roomId);
    if (channel == null) {
      throw Exception('Room not found: $roomId');
    }

    final config = channel.config;
    if (config == null) {
      throw Exception('Room has no configuration: $roomId');
    }

    // Check permissions
    if (!config.canBan(actorNpub)) {
      throw PermissionDeniedException('Only moderators and above can unban users');
    }

    // Remove from banned list
    final updatedBanned = List<String>.from(config.banned)..remove(targetNpub);

    final updatedConfig = config.copyWith(banned: updatedBanned);

    await updateChannel(channel.copyWith(config: updatedConfig));
  }

  /// Promote a member to moderator (admin+ required)
  Future<void> promoteToModerator(String roomId, String actorNpub, String targetNpub) async {
    final channel = getChannel(roomId);
    if (channel == null) {
      throw Exception('Room not found: $roomId');
    }

    final config = channel.config;
    if (config == null) {
      throw Exception('Room has no configuration: $roomId');
    }

    // Check permissions
    if (!config.canManageRoles(actorNpub)) {
      throw PermissionDeniedException('Only admins and above can promote to moderator');
    }

    // Target must be a member
    if (!config.isMember(targetNpub)) {
      throw PermissionDeniedException('User must be a member before promotion');
    }

    // Already a moderator or higher?
    if (config.isModerator(targetNpub)) {
      return; // Already at or above moderator level
    }

    // Add to moderators
    final updatedModerators = List<String>.from(config.moderatorNpubs)..add(targetNpub);

    final updatedConfig = config.copyWith(moderatorNpubs: updatedModerators);

    await updateChannel(channel.copyWith(config: updatedConfig));
  }

  /// Promote a member/moderator to admin (owner only)
  Future<void> promoteToAdmin(String roomId, String actorNpub, String targetNpub) async {
    final channel = getChannel(roomId);
    if (channel == null) {
      throw Exception('Room not found: $roomId');
    }

    final config = channel.config;
    if (config == null) {
      throw Exception('Room has no configuration: $roomId');
    }

    // Check permissions - only owner can promote to admin
    if (!config.canManageAdmins(actorNpub)) {
      throw PermissionDeniedException('Only the owner can promote to admin');
    }

    // Target must be a member
    if (!config.isMember(targetNpub)) {
      throw PermissionDeniedException('User must be a member before promotion');
    }

    // Already an admin?
    if (config.isAdmin(targetNpub)) {
      return; // Already admin or owner
    }

    // Remove from moderators if present, add to admins
    final updatedModerators = List<String>.from(config.moderatorNpubs)..remove(targetNpub);
    final updatedAdmins = List<String>.from(config.admins)..add(targetNpub);

    final updatedConfig = config.copyWith(
      admins: updatedAdmins,
      moderatorNpubs: updatedModerators,
    );

    await updateChannel(channel.copyWith(config: updatedConfig));
  }

  /// Demote an admin/moderator (admin+ required, owner for demoting admins)
  Future<void> demote(String roomId, String actorNpub, String targetNpub) async {
    final channel = getChannel(roomId);
    if (channel == null) {
      throw Exception('Room not found: $roomId');
    }

    final config = channel.config;
    if (config == null) {
      throw Exception('Room has no configuration: $roomId');
    }

    // Cannot demote the owner
    if (config.isOwner(targetNpub)) {
      throw PermissionDeniedException('Cannot demote the room owner');
    }

    // Check permissions based on target's current role
    if (config.isAdmin(targetNpub)) {
      // Only owner can demote admins
      if (!config.isOwner(actorNpub)) {
        throw PermissionDeniedException('Only the owner can demote admins');
      }
      // Remove from admins
      final updatedAdmins = List<String>.from(config.admins)..remove(targetNpub);
      final updatedConfig = config.copyWith(admins: updatedAdmins);
      await updateChannel(channel.copyWith(config: updatedConfig));
    } else if (config.isModerator(targetNpub)) {
      // Admin+ can demote moderators
      if (!config.isAdmin(actorNpub)) {
        throw PermissionDeniedException('Only admins can demote moderators');
      }
      // Remove from moderators
      final updatedModerators = List<String>.from(config.moderatorNpubs)..remove(targetNpub);
      final updatedConfig = config.copyWith(moderatorNpubs: updatedModerators);
      await updateChannel(channel.copyWith(config: updatedConfig));
    }
    // Regular members can't be demoted further
  }

  /// Apply for membership in a restricted room
  Future<void> applyForMembership(String roomId, String applicantNpub, String? callsign, String? message) async {
    final channel = getChannel(roomId);
    if (channel == null) {
      throw Exception('Room not found: $roomId');
    }

    final config = channel.config;
    if (config == null) {
      throw Exception('Room has no configuration: $roomId');
    }

    // Check if already a member
    if (config.isMember(applicantNpub)) {
      throw PermissionDeniedException('Already a member of this room');
    }

    // Check if banned
    if (config.isBanned(applicantNpub)) {
      throw PermissionDeniedException('You are banned from this room');
    }

    // Check if already applied
    if (config.hasApplied(applicantNpub)) {
      throw PermissionDeniedException('Application already pending');
    }

    // Add application
    final application = MembershipApplication(
      npub: applicantNpub,
      callsign: callsign,
      appliedAt: DateTime.now(),
      message: message,
    );

    final updatedApplicants = List<MembershipApplication>.from(config.pendingApplicants)
      ..add(application);

    final updatedConfig = config.copyWith(pendingApplicants: updatedApplicants);

    await updateChannel(channel.copyWith(config: updatedConfig));
  }

  /// Approve a membership application (moderator+ required)
  Future<void> approveApplication(String roomId, String actorNpub, String applicantNpub) async {
    final channel = getChannel(roomId);
    if (channel == null) {
      throw Exception('Room not found: $roomId');
    }

    final config = channel.config;
    if (config == null) {
      throw Exception('Room has no configuration: $roomId');
    }

    // Check permissions
    if (!config.canManageApplications(actorNpub)) {
      throw PermissionDeniedException('Only moderators and above can approve applications');
    }

    // Check if application exists
    if (!config.hasApplied(applicantNpub)) {
      throw Exception('No pending application from this user');
    }

    // Add to members and remove from applicants
    final updatedMembers = List<String>.from(config.members)..add(applicantNpub);
    final updatedApplicants = config.pendingApplicants
        .where((a) => a.npub != applicantNpub)
        .toList();

    final updatedConfig = config.copyWith(
      members: updatedMembers,
      pendingApplicants: updatedApplicants,
    );

    await updateChannel(channel.copyWith(config: updatedConfig));
  }

  /// Reject a membership application (moderator+ required)
  Future<void> rejectApplication(String roomId, String actorNpub, String applicantNpub) async {
    final channel = getChannel(roomId);
    if (channel == null) {
      throw Exception('Room not found: $roomId');
    }

    final config = channel.config;
    if (config == null) {
      throw Exception('Room has no configuration: $roomId');
    }

    // Check permissions
    if (!config.canManageApplications(actorNpub)) {
      throw PermissionDeniedException('Only moderators and above can reject applications');
    }

    // Remove from applicants
    final updatedApplicants = config.pendingApplicants
        .where((a) => a.npub != applicantNpub)
        .toList();

    final updatedConfig = config.copyWith(pendingApplicants: updatedApplicants);

    await updateChannel(channel.copyWith(config: updatedConfig));
  }

  /// Get list of pending applications for a room (moderator+ required)
  List<MembershipApplication> getPendingApplications(String roomId, String actorNpub) {
    final channel = getChannel(roomId);
    if (channel == null) {
      throw Exception('Room not found: $roomId');
    }

    final config = channel.config;
    if (config == null) {
      return [];
    }

    // Check permissions
    if (!config.canManageApplications(actorNpub)) {
      throw PermissionDeniedException('Only moderators and above can view applications');
    }

    return List<MembershipApplication>.from(config.pendingApplicants);
  }

  /// Get room roles information (members can view)
  Map<String, dynamic> getRoomRoles(String roomId, String actorNpub) {
    final channel = getChannel(roomId);
    if (channel == null) {
      throw Exception('Room not found: $roomId');
    }

    final config = channel.config;
    if (config == null) {
      return {};
    }

    // Only members can view roles
    if (!config.canAccess(actorNpub)) {
      throw PermissionDeniedException('Only members can view room roles');
    }

    return {
      'owner': config.owner,
      'admins': config.admins,
      'moderators': config.moderatorNpubs,
      'members': config.members,
      'banned': config.isModerator(actorNpub) ? config.banned : [], // Only mods see banned list
      'pendingCount': config.isModerator(actorNpub) ? config.pendingApplicants.length : 0,
    };
  }

  /// Check if a user can access a room
  bool canAccessRoom(String roomId, String? npub) {
    final channel = getChannel(roomId);
    if (channel == null) return false;

    final config = channel.config;
    if (config == null) {
      // No config means PUBLIC by default
      return true;
    }

    // PUBLIC rooms - anyone can access
    if (config.visibility == 'PUBLIC') return true;

    // RESTRICTED rooms - check membership
    if (config.visibility == 'RESTRICTED') {
      if (npub == null) return false;
      return config.canAccess(npub);
    }

    // PRIVATE rooms - only device admin (handled elsewhere)
    return false;
  }

  /// Get list of rooms visible to a user
  List<ChatChannel> getVisibleChannels(String? npub) {
    return _channels.where((channel) {
      final config = channel.config;
      if (config == null) return true; // No config = visible

      // PUBLIC rooms always visible
      if (config.visibility == 'PUBLIC') return true;

      // RESTRICTED rooms only visible to members
      if (config.visibility == 'RESTRICTED') {
        return npub != null && config.canAccess(npub);
      }

      return false;
    }).toList();
  }
}

/// Exception for permission denied errors
class PermissionDeniedException implements Exception {
  final String message;
  PermissionDeniedException(this.message);

  @override
  String toString() => 'PermissionDeniedException: $message';
}
