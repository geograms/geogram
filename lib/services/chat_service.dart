/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as path;
import '../models/chat_message.dart';
import '../models/chat_channel.dart';
import '../models/chat_security.dart';

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

  /// Load channels from channels.json
  Future<void> _loadChannels() async {
    if (_collectionPath == null) return;

    final channelsFile = File(path.join(_collectionPath!, 'extra', 'channels.json'));
    if (!await channelsFile.exists()) {
      // Create default main channel if file doesn't exist
      _channels = [ChatChannel.main()];
      await _saveChannels();
      return;
    }

    try {
      final content = await channelsFile.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      final channelsList = json['channels'] as List;

      _channels = channelsList
          .map((ch) => ChatChannel.fromJson(ch as Map<String, dynamic>))
          .toList();
    } catch (e) {
      print('Error loading channels: $e');
      _channels = [ChatChannel.main()];
    }
  }

  /// Save channels to channels.json
  Future<void> _saveChannels() async {
    if (_collectionPath == null) return;

    final extraDir = Directory(path.join(_collectionPath!, 'extra'));
    if (!await extraDir.exists()) {
      await extraDir.create(recursive: true);
    }

    final channelsFile = File(path.join(_collectionPath!, 'extra', 'channels.json'));
    final json = {
      'version': '1.0',
      'channels': _channels.map((ch) => ch.toJson()).toList(),
    };

    await channelsFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(json),
    );
  }

  /// Load participants from participants.json
  Future<void> _loadParticipants() async {
    if (_collectionPath == null) return;

    final participantsFile =
        File(path.join(_collectionPath!, 'extra', 'participants.json'));
    if (!await participantsFile.exists()) {
      _participants = {};
      return;
    }

    try {
      final content = await participantsFile.readAsString();
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

    final extraDir = Directory(path.join(_collectionPath!, 'extra'));
    if (!await extraDir.exists()) {
      await extraDir.create(recursive: true);
    }

    final participantsFile =
        File(path.join(_collectionPath!, 'extra', 'participants.json'));

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

    await participantsFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(json),
    );
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

    final securityFile =
        File(path.join(_collectionPath!, 'extra', 'security.json'));
    if (!await securityFile.exists()) {
      _security = ChatSecurity();
      return;
    }

    try {
      final content = await securityFile.readAsString();
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

    final extraDir = Directory(path.join(_collectionPath!, 'extra'));
    if (!await extraDir.exists()) {
      await extraDir.create(recursive: true);
    }

    final securityFile =
        File(path.join(_collectionPath!, 'extra', 'security.json'));
    final json = {
      'version': '1.0',
      ..._security.toJson(),
    };

    await securityFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(json),
    );
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

    // Create channel folder
    final channelDir = Directory(path.join(_collectionPath!, channel.folder));
    await channelDir.create(recursive: true);

    // Create files subfolder
    final filesDir = Directory(path.join(channelDir.path, 'files'));
    await filesDir.create();

    // Create config.json
    final config = channel.config ??
        ChatChannelConfig.defaults(
          id: channel.id,
          name: channel.name,
          description: channel.description,
        );

    final configFile = File(path.join(channelDir.path, 'config.json'));
    await configFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(config.toJson()),
    );

    // For main channel, create year folder structure
    if (channel.isMain) {
      final yearDir = Directory(path.join(channelDir.path, DateTime.now().year.toString()));
      await yearDir.create();
      final filesYearDir = Directory(path.join(yearDir.path, 'files'));
      await filesYearDir.create();
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
    final channelDir = Directory(path.join(_collectionPath!, channel.folder));
    if (await channelDir.exists()) {
      await channelDir.delete(recursive: true);
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

    final channelDir = Directory(path.join(_collectionPath!, channel.folder));
    if (!await channelDir.exists()) return [];

    List<ChatMessage> messages = [];

    if (channel.isMain) {
      // Load from daily files in year folders
      messages = await _loadMainChannelMessages(channelDir, startDate, endDate);
    } else {
      // Load from single messages.txt file
      messages = await _loadSingleFileMessages(channelDir);
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
    Directory channelDir,
    DateTime? startDate,
    DateTime? endDate,
  ) async {
    List<ChatMessage> messages = [];

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
        final filename = path.basename(file.path);
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

    return messages;
  }

  /// Load messages from single file (DM or group)
  Future<List<ChatMessage>> _loadSingleFileMessages(Directory channelDir) async {
    final messagesFile = File(path.join(channelDir.path, 'messages.txt'));
    if (!await messagesFile.exists()) return [];

    return await _parseMessageFile(messagesFile);
  }

  /// Parse message file according to specification
  Future<List<ChatMessage>> _parseMessageFile(File file) async {
    try {
      final content = await file.readAsString();
      return parseMessageText(content);
    } catch (e) {
      print('Error parsing message file ${file.path}: $e');
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

    final channelDir = Directory(path.join(_collectionPath!, channel.folder));

    File messageFile;

    if (channel.isMain) {
      // Append to daily file
      messageFile = await _getDailyMessageFile(channelDir, message.dateTime);
    } else {
      // Append to single messages.txt
      messageFile = File(path.join(channelDir.path, 'messages.txt'));
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

    // Add author to participants if not already present
    if (!_participants.containsKey(message.author)) {
      await addParticipant(message.author, npub: message.npub);
    }

    // Update channel last message time
    channel.lastMessageTime = message.dateTime;
    await _saveChannels();
  }

  /// Get daily message file for main channel
  Future<File> _getDailyMessageFile(Directory channelDir, DateTime date) async {
    final year = date.year.toString();
    final yearDir = Directory(path.join(channelDir.path, year));

    // Create year directory if doesn't exist
    if (!await yearDir.exists()) {
      await yearDir.create();
      // Create files subfolder
      await Directory(path.join(yearDir.path, 'files')).create();
    }

    final dateStr = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    return File(path.join(yearDir.path, '${dateStr}_chat.txt'));
  }

  /// Generate file header
  String _generateFileHeader(ChatChannel channel, DateTime date) {
    final dateStr = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    return '# ${channel.id.toUpperCase()}: ${channel.name} from $dateStr\n';
  }

  /// Check if path is a year folder (4 digits)
  bool _isYearFolder(String folderPath) {
    final name = path.basename(folderPath);
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
      final channelDir = Directory(path.join(_collectionPath!, channel.folder));
      final configFile = File(path.join(channelDir.path, 'config.json'));
      await configFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(channel.config!.toJson()),
      );
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

    final channelDir = Directory(path.join(_collectionPath!, channel.folder));

    if (channel.isMain) {
      // Delete from daily file
      await _deleteFromDailyFile(channelDir, message);
    } else {
      // Delete from single messages.txt
      await _deleteFromSingleFile(channelDir, message);
    }
  }

  /// Delete message from daily file (main channel)
  Future<void> _deleteFromDailyFile(
    Directory channelDir,
    ChatMessage message,
  ) async {
    final messageFile = await _getDailyMessageFile(channelDir, message.dateTime);
    if (!await messageFile.exists()) {
      throw Exception('Message file not found');
    }

    // Load all messages from file
    final messages = await _parseMessageFile(messageFile);

    // Remove the target message
    messages.removeWhere((msg) =>
        msg.timestamp == message.timestamp && msg.author == message.author);

    // Rewrite file
    await _rewriteMessageFile(messageFile, messages, message.dateTime);
  }

  /// Delete message from single file (DM or group)
  Future<void> _deleteFromSingleFile(
    Directory channelDir,
    ChatMessage message,
  ) async {
    final messageFile = File(path.join(channelDir.path, 'messages.txt'));
    if (!await messageFile.exists()) {
      throw Exception('Message file not found');
    }

    // Load all messages from file
    final messages = await _parseMessageFile(messageFile);

    // Remove the target message
    messages.removeWhere((msg) =>
        msg.timestamp == message.timestamp && msg.author == message.author);

    // Rewrite file
    await _rewriteMessageFile(messageFile, messages, message.dateTime);
  }

  /// Rewrite message file with updated messages
  Future<void> _rewriteMessageFile(
    File file,
    List<ChatMessage> messages,
    DateTime date,
  ) async {
    // Get channel from file path
    final channelFolder = path.basename(path.dirname(file.path));
    final channel = _channels.firstWhere(
      (ch) => ch.folder == channelFolder ||
              ch.folder.endsWith(channelFolder),
      orElse: () => ChatChannel.main(),
    );

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
}
