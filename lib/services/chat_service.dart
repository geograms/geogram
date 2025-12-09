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
import 'profile_service.dart';

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

    // If this is a new collection (no admin set) and creator npub provided, set as admin
    if (_security.adminNpub == null && creatorNpub != null && creatorNpub.isNotEmpty) {
      final newSecurity = ChatSecurity(adminNpub: creatorNpub);
      await saveSecurity(newSecurity);
    }
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
    final config = channel.config ??
        ChatChannelConfig.defaults(
          id: channel.id,
          name: channel.name,
          description: channel.description,
        );
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
  static List<ChatMessage> parseMessageText(String content) {
    // Split by message start pattern: "> 2" (messages start with year 2xxx)
    final sections = content.split('> 2');
    List<ChatMessage> messages = [];

    // Skip first section (header)
    for (int i = 1; i < sections.length; i++) {
      try {
        final section = '2${sections[i]}'; // Restore the "2" prefix
        final message = _parseMessageSection(section);
        if (message != null) {
          messages.add(message);
        }
      } catch (e) {
        print('Error parsing message section: $e');
        continue; // Skip malformed messages
      }
    }

    return messages;
  }

  /// Parse a single message section
  static ChatMessage? _parseMessageSection(String section) {
    final lines = section.split('\n');
    if (lines.isEmpty) return null;

    // Parse header: "2025-11-20 19:10_12 -- CR7BBQ"
    final header = lines[0].trim();
    if (header.length < 23) return null; // Min length check

    final timestamp = header.substring(0, 19).trim(); // YYYY-MM-DD HH:MM_ss
    final author = header.substring(23).trim(); // After " -- "

    if (timestamp.isEmpty || author.isEmpty) return null;

    // Parse content and metadata
    StringBuffer contentBuffer = StringBuffer();
    Map<String, String> metadata = {};
    bool inContent = true;

    for (int i = 1; i < lines.length; i++) {
      final line = lines[i];

      if (line.trim().startsWith('--> ')) {
        inContent = false;
        // Parse metadata: "--> key: value"
        final metaLine = line.trim().substring(4); // Remove "--> "
        final colonIndex = metaLine.indexOf(': ');
        if (colonIndex > 0) {
          final key = metaLine.substring(0, colonIndex);
          final value = metaLine.substring(colonIndex + 2);
          metadata[key] = value;
        }
      } else if (inContent && line.trim().isNotEmpty) {
        // Content line
        if (contentBuffer.isNotEmpty) {
          contentBuffer.writeln();
        }
        contentBuffer.write(line);
      }
    }

    return ChatMessage(
      author: author,
      timestamp: timestamp,
      content: contentBuffer.toString().trim(),
      metadata: metadata,
    );
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
}
