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
import '../models/chat_channel.dart';
import '../models/chat_security.dart';
import '../platform/file_system_service.dart';
import '../util/chat_format.dart';
import '../util/event_bus.dart';
import '../util/reaction_utils.dart';
import 'profile_service.dart';
import 'signing_service.dart';

/// Notification when chat files change
class ChatFileChange {
  final String channelId;
  final DateTime timestamp;

  ChatFileChange(this.channelId, this.timestamp);
}

/// Service for managing chat collections and messages
class ChatService {
  static final ChatService _instance = ChatService._internal();
  factory ChatService() => _instance;
  ChatService._internal();

  /// Current collection path
  String? _collectionPath;

  /// Loaded channels
  List<ChatChannel> _channels = [];

  /// Participant npub mapping
  Map<String, String> _participants = {};

  /// Security settings (moderators)
  ChatSecurity _security = ChatSecurity();

  /// Hidden message IDs by channel (local-only)
  final Map<String, Set<String>> _hiddenMessageIds = {};

  /// File system watcher subscriptions
  final List<StreamSubscription<FileSystemEvent>> _watchSubscriptions = [];

  /// Stream controller for file change notifications
  final StreamController<ChatFileChange> _changeController =
      StreamController<ChatFileChange>.broadcast();

  /// Stream of file change notifications
  Stream<ChatFileChange> get onFileChange => _changeController.stream;

  /// Initialize chat service for a collection
  Future<void> initializeCollection(String collectionPath, {String? creatorNpub}) async {
    _collectionPath = collectionPath;
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
    if (_collectionPath == null) return;

    final hiddenPath = '$_collectionPath/extra/hidden_messages.json';

    try {
      String? content;

      if (kIsWeb) {
        final fs = FileSystemService.instance;
        if (!await fs.exists(hiddenPath)) return;
        content = await fs.readAsString(hiddenPath);
      } else {
        final hiddenFile = File(p.join(_collectionPath!, 'extra', 'hidden_messages.json'));
        if (!await hiddenFile.exists()) return;
        content = await hiddenFile.readAsString();
      }

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
    if (_collectionPath == null) return;

    final extraPath = '$_collectionPath/extra';
    final hiddenPath = '$extraPath/hidden_messages.json';

    final data = {
      'version': '1.0',
      'channels': _hiddenMessageIds.map((channelId, ids) {
        return MapEntry(channelId, ids.toList());
      }),
    };

    final content = const JsonEncoder.withIndent('  ').convert(data);

    if (kIsWeb) {
      final fs = FileSystemService.instance;
      if (!await fs.exists(extraPath)) {
        await fs.createDirectory(extraPath, recursive: true);
      }
      await fs.writeAsString(hiddenPath, content);
    } else {
      final extraDir = Directory(p.join(_collectionPath!, 'extra'));
      if (!await extraDir.exists()) {
        await extraDir.create(recursive: true);
      }
      final hiddenFile = File(p.join(_collectionPath!, 'extra', 'hidden_messages.json'));
      await hiddenFile.writeAsString(content);
    }
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
  String? get collectionPath => _collectionPath;

  /// Get loaded channels
  List<ChatChannel> get channels => List.unmodifiable(_channels);

  /// Get participants
  Map<String, String> get participants => Map.unmodifiable(_participants);

  /// Get security settings
  ChatSecurity get security => _security;

  /// Start watching chat files for changes
  void startWatching() {
    stopWatching(); // Clear any existing watchers

    if (_collectionPath == null) {
      if (!kIsWeb) stderr.writeln('ChatService: Cannot start watching - no collection path');
      return;
    }

    // File watching is not supported on web
    if (kIsWeb) {
      return;
    }

    stderr.writeln('ChatService: Starting file watchers for ${_channels.length} channels at $_collectionPath');

    // Watch main channel folder and subfolders
    for (final channel in _channels) {
      final channelDir = Directory(p.join(_collectionPath!, channel.folder));
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
    if (_collectionPath == null) return;

    final channelsPath = '$_collectionPath/extra/channels.json';

    try {
      String? content;

      if (kIsWeb) {
        final fs = FileSystemService.instance;
        if (!await fs.exists(channelsPath)) {
          _channels = [];
          return;
        }
        content = await fs.readAsString(channelsPath);
      } else {
        final channelsFile = File(p.join(_collectionPath!, 'extra', 'channels.json'));
        if (!await channelsFile.exists()) {
          _channels = [];
          return;
        }
        content = await channelsFile.readAsString();
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
    if (_collectionPath == null) return;

    final extraPath = '$_collectionPath/extra';
    final channelsPath = '$extraPath/channels.json';
    final json = {
      'version': '1.0',
      'channels': _channels.map((ch) => ch.toJson()).toList(),
    };
    final content = const JsonEncoder.withIndent('  ').convert(json);

    if (kIsWeb) {
      final fs = FileSystemService.instance;
      if (!await fs.exists(extraPath)) {
        await fs.createDirectory(extraPath, recursive: true);
      }
      await fs.writeAsString(channelsPath, content);
    } else {
      final extraDir = Directory(p.join(_collectionPath!, 'extra'));
      if (!await extraDir.exists()) {
        await extraDir.create(recursive: true);
      }
      final channelsFile = File(p.join(_collectionPath!, 'extra', 'channels.json'));
      await channelsFile.writeAsString(content);
    }
  }

  /// Load participants from participants.json
  Future<void> _loadParticipants() async {
    if (_collectionPath == null) return;

    final participantsPath = '$_collectionPath/extra/participants.json';

    try {
      String? content;

      if (kIsWeb) {
        final fs = FileSystemService.instance;
        if (!await fs.exists(participantsPath)) {
          _participants = {};
          return;
        }
        content = await fs.readAsString(participantsPath);
      } else {
        final participantsFile =
            File(p.join(_collectionPath!, 'extra', 'participants.json'));
        if (!await participantsFile.exists()) {
          _participants = {};
          return;
        }
        content = await participantsFile.readAsString();
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
    if (_collectionPath == null) return;

    final extraPath = '$_collectionPath/extra';
    final participantsPath = '$extraPath/participants.json';

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

    if (kIsWeb) {
      final fs = FileSystemService.instance;
      if (!await fs.exists(extraPath)) {
        await fs.createDirectory(extraPath, recursive: true);
      }
      await fs.writeAsString(participantsPath, content);
    } else {
      final extraDir = Directory(p.join(_collectionPath!, 'extra'));
      if (!await extraDir.exists()) {
        await extraDir.create(recursive: true);
      }
      final participantsFile =
          File(p.join(_collectionPath!, 'extra', 'participants.json'));
      await participantsFile.writeAsString(content);
    }
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
    if (_collectionPath == null) return;

    final securityPath = '$_collectionPath/extra/security.json';

    try {
      String? content;

      if (kIsWeb) {
        final fs = FileSystemService.instance;
        if (!await fs.exists(securityPath)) {
          _security = ChatSecurity();
          return;
        }
        content = await fs.readAsString(securityPath);
      } else {
        final securityFile =
            File(p.join(_collectionPath!, 'extra', 'security.json'));
        if (!await securityFile.exists()) {
          _security = ChatSecurity();
          return;
        }
        content = await securityFile.readAsString();
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
    if (_collectionPath == null) return;

    _security = security;

    final extraPath = '$_collectionPath/extra';
    final securityPath = '$extraPath/security.json';
    final json = {
      'version': '1.0',
      ..._security.toJson(),
    };
    final content = const JsonEncoder.withIndent('  ').convert(json);

    if (kIsWeb) {
      final fs = FileSystemService.instance;
      if (!await fs.exists(extraPath)) {
        await fs.createDirectory(extraPath, recursive: true);
      }
      await fs.writeAsString(securityPath, content);
    } else {
      final extraDir = Directory(p.join(_collectionPath!, 'extra'));
      if (!await extraDir.exists()) {
        await extraDir.create(recursive: true);
      }
      final securityFile =
          File(p.join(_collectionPath!, 'extra', 'security.json'));
      await securityFile.writeAsString(content);
    }
  }

  /// Create a new channel
  Future<ChatChannel> createChannel(ChatChannel channel) async {
    if (_collectionPath == null) {
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

    if (kIsWeb) {
      final fs = FileSystemService.instance;
      final channelPath = '$_collectionPath/${channel.folder}';
      final filesPath = '$channelPath/files';
      final configPath = '$channelPath/config.json';

      // Create channel folder and files subfolder
      await fs.createDirectory(channelPath, recursive: true);
      await fs.createDirectory(filesPath, recursive: true);

      // Create config.json
      await fs.writeAsString(configPath, configContent);

      // For main channel, create year folder structure
      if (channel.isMain) {
        final yearPath = '$channelPath/${DateTime.now().year}';
        final filesYearPath = '$yearPath/files';
        await fs.createDirectory(yearPath, recursive: true);
        await fs.createDirectory(filesYearPath, recursive: true);
      }
    } else {
      // Create channel folder
      final channelDir = Directory(p.join(_collectionPath!, channel.folder));
      await channelDir.create(recursive: true);

      // Create files subfolder
      final filesDir = Directory(p.join(channelDir.path, 'files'));
      await filesDir.create();

      // Create config.json
      final configFile = File(p.join(channelDir.path, 'config.json'));
      await configFile.writeAsString(configContent);

      // For main channel, create year folder structure
      if (channel.isMain) {
        final yearDir = Directory(p.join(channelDir.path, DateTime.now().year.toString()));
        await yearDir.create();
        final filesYearDir = Directory(p.join(yearDir.path, 'files'));
        await filesYearDir.create();
      }
    }

    // Add to channels list and save
    _channels.add(channel);
    await _saveChannels();

    return channel;
  }

  /// Delete a channel
  Future<void> deleteChannel(String channelId) async {
    if (_collectionPath == null) return;

    final channel = _channels.firstWhere(
      (ch) => ch.id == channelId,
      orElse: () => throw Exception('Channel not found: $channelId'),
    );

    // Don't allow deleting main channel
    if (channel.isMain) {
      throw Exception('Cannot delete main channel');
    }

    // Delete channel folder
    if (kIsWeb) {
      final fs = FileSystemService.instance;
      final channelPath = '$_collectionPath/${channel.folder}';
      if (await fs.exists(channelPath)) {
        await fs.delete(channelPath, recursive: true);
      }
    } else {
      final channelDir = Directory(p.join(_collectionPath!, channel.folder));
      if (await channelDir.exists()) {
        await channelDir.delete(recursive: true);
      }
    }

    // Remove from list and save
    _channels.removeWhere((ch) => ch.id == channelId);
    await _saveChannels();
  }

  /// Get channel by ID
  ChatChannel? getChannel(String channelId) {
    try {
      return _channels.firstWhere((ch) => ch.id == channelId);
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
    if (_collectionPath == null) return [];

    final channel = getChannel(channelId);
    if (channel == null) return [];

    final channelPath = '$_collectionPath/${channel.folder}';

    // Check if channel exists
    if (kIsWeb) {
      final fs = FileSystemService.instance;
      if (!await fs.exists(channelPath)) return [];
    } else {
      final channelDir = Directory(p.join(_collectionPath!, channel.folder));
      if (!await channelDir.exists()) return [];
    }

    List<ChatMessage> messages = [];

    if (channel.isMain) {
      // Load from daily files in year folders
      messages = await _loadMainChannelMessages(channelPath, startDate, endDate);
    } else {
      // Load from single messages.txt file
      messages = await _loadSingleFileMessages(channelPath);
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

  /// Load messages from main channel (daily files)
  Future<List<ChatMessage>> _loadMainChannelMessages(
    String channelPath,
    DateTime? startDate,
    DateTime? endDate,
  ) async {
    List<ChatMessage> messages = [];

    if (kIsWeb) {
      final fs = FileSystemService.instance;

      // Find all year folders
      final entities = await fs.list(channelPath);
      final yearFolders = entities
          .where((e) => e.type == FsEntityType.directory && _isYearFolder(e.path))
          .toList();

      for (var yearFolder in yearFolders) {
        // Find all chat files in year folder
        final yearEntities = await fs.list(yearFolder.path);
        final chatFiles = yearEntities
            .where((e) => e.type == FsEntityType.file && e.path.endsWith('_chat.txt'))
            .toList();

        for (var file in chatFiles) {
          // Parse file date from filename (YYYY-MM-DD_chat.txt)
          final filename = file.path.split('/').last;
          final dateStr = filename.substring(0, 10); // YYYY-MM-DD

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
          final fileMessages = await _parseMessageFilePath(file.path);
          messages.addAll(fileMessages);
        }
      }
    } else {
      final channelDir = Directory(channelPath);

      // Find all year folders
      final yearDirs = await channelDir
          .list()
          .where((entity) => entity is Directory && _isYearFolder(entity.path))
          .cast<Directory>()
          .toList();

      for (var yearDir in yearDirs) {
        // Find all chat files in year folder
        final chatFiles = await yearDir
            .list()
            .where((entity) =>
                entity is File && entity.path.endsWith('_chat.txt'))
            .cast<File>()
            .toList();

        for (var file in chatFiles) {
          // Parse file date from filename (YYYY-MM-DD_chat.txt)
          final filename = p.basename(file.path);
          final dateStr = filename.substring(0, 10); // YYYY-MM-DD

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
          final fileMessages = await _parseMessageFile(file);
          messages.addAll(fileMessages);
        }
      }
    }

    return messages;
  }

  /// Load messages from single file (DM or group)
  Future<List<ChatMessage>> _loadSingleFileMessages(String channelPath) async {
    final messagesPath = '$channelPath/messages.txt';

    if (kIsWeb) {
      final fs = FileSystemService.instance;
      if (!await fs.exists(messagesPath)) return [];
      return await _parseMessageFilePath(messagesPath);
    } else {
      final messagesFile = File(p.join(channelPath, 'messages.txt'));
      if (!await messagesFile.exists()) return [];
      return await _parseMessageFile(messagesFile);
    }
  }

  /// Parse message file according to specification (native)
  Future<List<ChatMessage>> _parseMessageFile(File file) async {
    try {
      final content = await file.readAsString();
      return parseMessageText(content);
    } catch (e) {
      print('Error parsing message file ${file.path}: $e');
      return [];
    }
  }

  /// Parse message file from path (web)
  Future<List<ChatMessage>> _parseMessageFilePath(String filePath) async {
    try {
      final fs = FileSystemService.instance;
      final content = await fs.readAsString(filePath);
      return parseMessageText(content);
    } catch (e) {
      print('Error parsing message file $filePath: $e');
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
    if (_collectionPath == null) {
      throw Exception('Collection not initialized');
    }

    final channel = getChannel(channelId);
    if (channel == null) {
      throw Exception('Channel not found: $channelId');
    }

    final channelPath = '$_collectionPath/${channel.folder}';

    if (kIsWeb) {
      final fs = FileSystemService.instance;
      String messageFilePath;

      if (channel.isMain) {
        // Get daily file path
        messageFilePath = await _getDailyMessageFilePath(channelPath, message.dateTime);
      } else {
        // Ensure channel directory exists for non-main channels
        if (!await fs.exists(channelPath)) {
          await fs.createDirectory(channelPath, recursive: true);
        }
        messageFilePath = '$channelPath/messages.txt';
      }

      // Check if file exists and needs header
      final needsHeader = !await fs.exists(messageFilePath);

      // Build content
      final buffer = StringBuffer();
      if (needsHeader) {
        buffer.write(_generateFileHeader(channel, message.dateTime));
      } else {
        // Read existing content
        final existing = await fs.readAsString(messageFilePath);
        buffer.write(existing);
      }
      buffer.write('\n');
      buffer.write(message.exportAsText());
      buffer.write('\n');

      await fs.writeAsString(messageFilePath, buffer.toString());
    } else {
      final channelDir = Directory(p.join(_collectionPath!, channel.folder));

      File messageFile;

      if (channel.isMain) {
        // Append to daily file
        messageFile = await _getDailyMessageFile(channelDir, message.dateTime);
      } else {
        // Ensure channel directory exists for non-main channels
        if (!await channelDir.exists()) {
          await channelDir.create(recursive: true);
        }
        // Append to single messages.txt
        messageFile = File(p.join(channelDir.path, 'messages.txt'));
      }

      // Check if file exists and needs header
      final needsHeader = !await messageFile.exists();

      // Open file for appending
      final sink = messageFile.openWrite(mode: FileMode.append);

      try {
        if (needsHeader) {
          // Write header
          final header = _generateFileHeader(channel, message.dateTime);
          sink.write(header);
        }

        // Write message
        sink.write('\n');
        sink.write(message.exportAsText());
        sink.write('\n');

        await sink.flush();
      } finally {
        await sink.close();
      }
    }

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

  /// Get daily message file path for main channel (web)
  Future<String> _getDailyMessageFilePath(String channelPath, DateTime date) async {
    final fs = FileSystemService.instance;
    final year = date.year.toString();
    final yearPath = '$channelPath/$year';

    // Create year directory if doesn't exist
    if (!await fs.exists(yearPath)) {
      await fs.createDirectory(yearPath, recursive: true);
      // Create files subfolder
      await fs.createDirectory('$yearPath/files', recursive: true);
    }

    final dateStr = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    return '$yearPath/${dateStr}_chat.txt';
  }

  /// Get daily message file for main channel (native)
  Future<File> _getDailyMessageFile(Directory channelDir, DateTime date) async {
    final year = date.year.toString();
    final yearDir = Directory(p.join(channelDir.path, year));

    // Create year directory if doesn't exist (recursive to handle missing channel dir)
    if (!await yearDir.exists()) {
      await yearDir.create(recursive: true);
      // Create files subfolder
      await Directory(p.join(yearDir.path, 'files')).create();
    }

    final dateStr = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    return File(p.join(yearDir.path, '${dateStr}_chat.txt'));
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
    if (channel.config != null && _collectionPath != null) {
      final configContent = const JsonEncoder.withIndent('  ').convert(channel.config!.toJson());

      if (kIsWeb) {
        final fs = FileSystemService.instance;
        final configPath = '$_collectionPath/${channel.folder}/config.json';
        await fs.writeAsString(configPath, configContent);
      } else {
        final channelDir = Directory(p.join(_collectionPath!, channel.folder));
        final configFile = File(p.join(channelDir.path, 'config.json'));
        await configFile.writeAsString(configContent);
      }
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
    if (_collectionPath == null) {
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

    final channelPath = '$_collectionPath/${channel.folder}';

    if (channel.isMain) {
      // Delete from daily file
      await _deleteFromDailyFile(channelPath, channel, message);
    } else {
      // Delete from single messages.txt
      await _deleteFromSingleFile(channelPath, channel, message);
    }
  }

  /// Delete message from daily file (main channel)
  Future<void> _deleteFromDailyFile(
    String channelPath,
    ChatChannel channel,
    ChatMessage message,
  ) async {
    List<ChatMessage> messages;

    if (kIsWeb) {
      final fs = FileSystemService.instance;
      final messageFilePath = await _getDailyMessageFilePath(channelPath, message.dateTime);
      if (!await fs.exists(messageFilePath)) {
        throw Exception('Message file not found');
      }
      messages = await _parseMessageFilePath(messageFilePath);

      // Remove the target message
      messages.removeWhere((msg) =>
          msg.timestamp == message.timestamp && msg.author == message.author);

      // Rewrite file
      await _rewriteMessageFilePath(messageFilePath, channel, messages, message.dateTime);
    } else {
      final channelDir = Directory(channelPath);
      final messageFile = await _getDailyMessageFile(channelDir, message.dateTime);
      if (!await messageFile.exists()) {
        throw Exception('Message file not found');
      }
      messages = await _parseMessageFile(messageFile);

      // Remove the target message
      messages.removeWhere((msg) =>
          msg.timestamp == message.timestamp && msg.author == message.author);

      // Rewrite file
      await _rewriteMessageFile(messageFile, channel, messages, message.dateTime);
    }
  }

  /// Delete message from single file (DM or group)
  Future<void> _deleteFromSingleFile(
    String channelPath,
    ChatChannel channel,
    ChatMessage message,
  ) async {
    List<ChatMessage> messages;

    if (kIsWeb) {
      final fs = FileSystemService.instance;
      final messageFilePath = '$channelPath/messages.txt';
      if (!await fs.exists(messageFilePath)) {
        throw Exception('Message file not found');
      }
      messages = await _parseMessageFilePath(messageFilePath);

      // Remove the target message
      messages.removeWhere((msg) =>
          msg.timestamp == message.timestamp && msg.author == message.author);

      // Rewrite file
      await _rewriteMessageFilePath(messageFilePath, channel, messages, message.dateTime);
    } else {
      final messageFile = File(p.join(channelPath, 'messages.txt'));
      if (!await messageFile.exists()) {
        throw Exception('Message file not found');
      }
      messages = await _parseMessageFile(messageFile);

      // Remove the target message
      messages.removeWhere((msg) =>
          msg.timestamp == message.timestamp && msg.author == message.author);

      // Rewrite file
      await _rewriteMessageFile(messageFile, channel, messages, message.dateTime);
    }
  }

  /// Rewrite message file with updated messages (native)
  Future<void> _rewriteMessageFile(
    File file,
    ChatChannel channel,
    List<ChatMessage> messages,
    DateTime date,
  ) async {
    // Write header and messages
    final sink = file.openWrite(mode: FileMode.write);
    try {
      // Write header
      final header = _generateFileHeader(channel, date);
      sink.write(header);

      // Write each message
      for (var message in messages) {
        sink.write('\n');
        sink.write(message.exportAsText());
        sink.write('\n');
      }

      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  /// Rewrite message file with updated messages (web)
  Future<void> _rewriteMessageFilePath(
    String filePath,
    ChatChannel channel,
    List<ChatMessage> messages,
    DateTime date,
  ) async {
    final fs = FileSystemService.instance;
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

    await fs.writeAsString(filePath, buffer.toString());
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
    if (_collectionPath == null) {
      return null;
    }

    final channel = getChannel(channelId);
    if (channel == null) {
      return null;
    }

    final channelPath = '$_collectionPath/${channel.folder}';

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
      if (kIsWeb) {
        final fs = FileSystemService.instance;
        final messageFilePath = await _getDailyMessageFilePath(channelPath, messageDate);
        if (!await fs.exists(messageFilePath)) {
          return null;
        }
        messages = await _parseMessageFilePath(messageFilePath);
      } else {
        final channelDir = Directory(channelPath);
        final messageFile = await _getDailyMessageFile(channelDir, messageDate);
        if (!await messageFile.exists()) {
          return null;
        }
        messages = await _parseMessageFile(messageFile);
      }
    } else if (!channel.isMain) {
      // Load from single messages.txt
      if (kIsWeb) {
        final fs = FileSystemService.instance;
        final messageFilePath = '$channelPath/messages.txt';
        if (!await fs.exists(messageFilePath)) {
          return null;
        }
        messages = await _parseMessageFilePath(messageFilePath);
      } else {
        final messageFile = File(p.join(channelPath, 'messages.txt'));
        if (!await messageFile.exists()) {
          return null;
        }
        messages = await _parseMessageFile(messageFile);
      }
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
    if (_collectionPath == null) {
      throw Exception('Collection not initialized');
    }

    final channel = getChannel(channelId);
    if (channel == null) {
      throw Exception('Channel not found: $channelId');
    }

    final channelPath = '$_collectionPath/${channel.folder}';

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

    if (channel.isMain) {
      // Load from daily file
      if (kIsWeb) {
        final fs = FileSystemService.instance;
        final messageFilePath = await _getDailyMessageFilePath(channelPath, messageDate);
        if (!await fs.exists(messageFilePath)) {
          throw Exception('Message file not found');
        }
        messages = await _parseMessageFilePath(messageFilePath);
      } else {
        final channelDir = Directory(channelPath);
        final messageFile = await _getDailyMessageFile(channelDir, messageDate);
        if (!await messageFile.exists()) {
          throw Exception('Message file not found');
        }
        messages = await _parseMessageFile(messageFile);
      }
    } else {
      // Load from single messages.txt
      if (kIsWeb) {
        final fs = FileSystemService.instance;
        final messageFilePath = '$channelPath/messages.txt';
        if (!await fs.exists(messageFilePath)) {
          throw Exception('Message file not found');
        }
        messages = await _parseMessageFilePath(messageFilePath);
      } else {
        final messageFile = File(p.join(channelPath, 'messages.txt'));
        if (!await messageFile.exists()) {
          throw Exception('Message file not found');
        }
        messages = await _parseMessageFile(messageFile);
      }
    }

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

    // Verify authorization: only the author can edit their own message
    final messageNpub = targetMessage.npub;
    if (messageNpub != actorNpub) {
      throw Exception('Only the author can edit this message');
    }

    // Create the edited_at timestamp
    final now = DateTime.now();
    final editedAt = ChatMessage.formatTimestamp(now);

    // Create updated message with new content, edited_at, and new signature
    final updatedMetadata = Map<String, String>.from(targetMessage.metadata);
    updatedMetadata['edited_at'] = editedAt;
    updatedMetadata['npub'] = actorNpub;
    updatedMetadata['signature'] = newSignature;
    updatedMetadata['created_at'] = newCreatedAt.toString();

    final updatedMessage = targetMessage.copyWith(
      content: newContent,
      metadata: updatedMetadata,
    );

    // Replace the message in the list
    messages[targetIndex] = updatedMessage;

    // Rewrite the file
    if (channel.isMain) {
      if (kIsWeb) {
        final messageFilePath = await _getDailyMessageFilePath(channelPath, messageDate);
        await _rewriteMessageFilePath(messageFilePath, channel, messages, messageDate);
      } else {
        final channelDir = Directory(channelPath);
        final messageFile = await _getDailyMessageFile(channelDir, messageDate);
        await _rewriteMessageFile(messageFile, channel, messages, messageDate);
      }
    } else {
      if (kIsWeb) {
        final messageFilePath = '$channelPath/messages.txt';
        await _rewriteMessageFilePath(messageFilePath, channel, messages, messageDate);
      } else {
        final messageFile = File(p.join(channelPath, 'messages.txt'));
        await _rewriteMessageFile(messageFile, channel, messages, messageDate);
      }
    }

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
    if (_collectionPath == null) {
      throw Exception('Collection not initialized');
    }

    final channel = getChannel(channelId);
    if (channel == null) {
      throw Exception('Channel not found: $channelId');
    }

    final channelPath = '$_collectionPath/${channel.folder}';

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

    if (channel.isMain) {
      // Load from daily file
      if (kIsWeb) {
        final fs = FileSystemService.instance;
        final messageFilePath = await _getDailyMessageFilePath(channelPath, messageDate);
        if (!await fs.exists(messageFilePath)) {
          throw Exception('Message file not found');
        }
        messages = await _parseMessageFilePath(messageFilePath);
      } else {
        final channelDir = Directory(channelPath);
        final messageFile = await _getDailyMessageFile(channelDir, messageDate);
        if (!await messageFile.exists()) {
          throw Exception('Message file not found');
        }
        messages = await _parseMessageFile(messageFile);
      }
    } else {
      // Load from single messages.txt
      if (kIsWeb) {
        final fs = FileSystemService.instance;
        final messageFilePath = '$channelPath/messages.txt';
        if (!await fs.exists(messageFilePath)) {
          throw Exception('Message file not found');
        }
        messages = await _parseMessageFilePath(messageFilePath);
      } else {
        final messageFile = File(p.join(channelPath, 'messages.txt'));
        if (!await messageFile.exists()) {
          throw Exception('Message file not found');
        }
        messages = await _parseMessageFile(messageFile);
      }
    }

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
    if (channel.isMain) {
      if (kIsWeb) {
        final messageFilePath = await _getDailyMessageFilePath(channelPath, messageDate);
        await _rewriteMessageFilePath(messageFilePath, channel, messages, messageDate);
      } else {
        final channelDir = Directory(channelPath);
        final messageFile = await _getDailyMessageFile(channelDir, messageDate);
        await _rewriteMessageFile(messageFile, channel, messages, messageDate);
      }
    } else {
      if (kIsWeb) {
        final messageFilePath = '$channelPath/messages.txt';
        await _rewriteMessageFilePath(messageFilePath, channel, messages, messageDate);
      } else {
        final messageFile = File(p.join(channelPath, 'messages.txt'));
        await _rewriteMessageFile(messageFile, channel, messages, messageDate);
      }
    }

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
    if (_collectionPath == null) {
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

    final channelPath = '$_collectionPath/${channel.folder}';

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

    if (channel.isMain) {
      if (kIsWeb) {
        final fs = FileSystemService.instance;
        final messageFilePath = await _getDailyMessageFilePath(channelPath, messageDate);
        if (!await fs.exists(messageFilePath)) {
          return null;
        }
        messages = await _parseMessageFilePath(messageFilePath);
      } else {
        final channelDir = Directory(channelPath);
        final messageFile = await _getDailyMessageFile(channelDir, messageDate);
        if (!await messageFile.exists()) {
          return null;
        }
        messages = await _parseMessageFile(messageFile);
      }
    } else {
      if (kIsWeb) {
        final fs = FileSystemService.instance;
        final messageFilePath = '$channelPath/messages.txt';
        if (!await fs.exists(messageFilePath)) {
          return null;
        }
        messages = await _parseMessageFilePath(messageFilePath);
      } else {
        final messageFile = File(p.join(channelPath, 'messages.txt'));
        if (!await messageFile.exists()) {
          return null;
        }
        messages = await _parseMessageFile(messageFile);
      }
    }

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

    if (channel.isMain) {
      if (kIsWeb) {
        final messageFilePath = await _getDailyMessageFilePath(channelPath, messageDate);
        await _rewriteMessageFilePath(messageFilePath, channel, messages, messageDate);
      } else {
        final channelDir = Directory(channelPath);
        final messageFile = await _getDailyMessageFile(channelDir, messageDate);
        await _rewriteMessageFile(messageFile, channel, messages, messageDate);
      }
    } else {
      if (kIsWeb) {
        final messageFilePath = '$channelPath/messages.txt';
        await _rewriteMessageFilePath(messageFilePath, channel, messages, messageDate);
      } else {
        final messageFile = File(p.join(channelPath, 'messages.txt'));
        await _rewriteMessageFile(messageFile, channel, messages, messageDate);
      }
    }

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
    if (_collectionPath == null) {
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
    if (_collectionPath == null) {
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
