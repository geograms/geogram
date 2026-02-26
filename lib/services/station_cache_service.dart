/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import '../models/station_chat_room.dart';
import '../models/chat_message.dart';
import '../util/chat_format.dart';
import '../services/chat_service.dart';
import 'log_service.dart';
import 'storage_config.dart';

/// Service for caching device data locally
/// Creates folders with device callsign for storing collections from each node
class RelayCacheService {
  static final RelayCacheService _instance = RelayCacheService._internal();
  factory RelayCacheService() => _instance;
  RelayCacheService._internal();

  String? _basePath;
  bool _initialized = false;

  /// Initialize the cache service
  Future<void> initialize() async {
    if (_initialized) return;

    if (kIsWeb) {
      // Web platform doesn't support file-based caching
      LogService().log('RelayCacheService: Web platform, file caching disabled');
      _initialized = true;
      return;
    }

    try {
      // Use StorageConfig to get the correct devices directory (respects --data-dir flag)
      _basePath = StorageConfig().devicesDir;

      final devicesDir = Directory(_basePath!);
      if (!await devicesDir.exists()) {
        await devicesDir.create(recursive: true);
      }

      _initialized = true;
      LogService().log('RelayCacheService initialized at: $_basePath');
      print('DEBUG RelayCacheService: initialized at $_basePath');
      unawaited(_cleanupDuplicateChatFiles());
    } catch (e) {
      LogService().log('Error initializing RelayCacheService: $e');
    }
  }

  Future<void> _cleanupDuplicateChatFiles() async {
    if (kIsWeb || _basePath == null) return;
    try {
      final devicesDir = Directory(_basePath!);
      if (!await devicesDir.exists()) return;
      final deviceEntities = await devicesDir.list().toList();
      final deviceDirs = deviceEntities.whereType<Directory>().toList();
      for (final device in deviceDirs) {
        final chatDir = Directory('${device.path}/chat');
        if (!await chatDir.exists()) continue;
        final roomEntities = await chatDir.list().toList();
        final roomDirs = roomEntities.whereType<Directory>().toList();
        for (final roomDir in roomDirs) {
          final yearEntities = await roomDir.list().toList();
          final yearDirs = yearEntities.whereType<Directory>().toList();
          for (final yearDir in yearDirs) {
            final yearEntities = await yearDir.list().toList();
            final files = yearEntities
                .whereType<File>()
                .where((f) => f.path.endsWith('_chat.txt'))
                .toList();
            for (final file in files) {
              final content = await file.readAsString();
              var messages = ChatService.parseMessageText(content);
              final dateStr = _extractDateFromFilename(file.path);
              if (dateStr == null) continue;
              final deduped = _dedupeChatMessages(messages);
              if (deduped.length != messages.length) {
                await _rewriteChatFile(file, roomDir.path.split('/').last, dateStr, deduped);
              }
            }
          }
        }
      }
    } catch (e) {
      LogService().log('RelayCacheService: Cleanup failed: $e');
    }
  }

  /// Get the cache directory for a device
  Future<Directory?> getDeviceCacheDir(String deviceCallsign) async {
    if (kIsWeb || _basePath == null) return null;

    // Sanitize callsign for use as folder name
    final safeName = deviceCallsign.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final path = '$_basePath/$safeName';

    final dir = Directory(path);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    return dir;
  }

  /// Save chat rooms for a device
  /// [stationUrl] is stored for offline retrieval when the device is unreachable
  Future<void> saveChatRooms(String deviceCallsign, List<StationChatRoom> rooms, {String? stationUrl}) async {
    if (kIsWeb || _basePath == null) return;

    try {
      final cacheDir = await getDeviceCacheDir(deviceCallsign);
      if (cacheDir == null) return;

      final chatDir = Directory('${cacheDir.path}/chat');
      if (!await chatDir.exists()) {
        await chatDir.create(recursive: true);
      }

      // Save rooms list with station URL for offline use
      final roomsFile = File('${chatDir.path}/rooms.json');
      final data = {
        'updated': DateTime.now().toIso8601String(),
        'device': deviceCallsign,
        'stationUrl': stationUrl ?? (rooms.isNotEmpty ? rooms.first.stationUrl : null),
        'rooms': rooms.map((r) => r.toJson()).toList(),
      };

      await roomsFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(data),
      );

      LogService().log('Cached ${rooms.length} chat rooms for $deviceCallsign');
    } catch (e) {
      LogService().log('Error saving chat rooms cache: $e');
    }
  }

  /// Load cached chat rooms for a device
  /// If [stationUrl] is empty, uses the stored stationUrl from the cache
  Future<List<StationChatRoom>> loadChatRooms(String deviceCallsign, String stationUrl) async {
    if (kIsWeb || _basePath == null) return [];

    try {
      final cacheDir = await getDeviceCacheDir(deviceCallsign);
      if (cacheDir == null) return [];

      final roomsFile = File('${cacheDir.path}/chat/rooms.json');
      if (!await roomsFile.exists()) return [];

      final content = await roomsFile.readAsString();
      final data = jsonDecode(content) as Map<String, dynamic>;
      final roomsData = data['rooms'] as List<dynamic>? ?? [];

      // Use stored stationUrl if provided stationUrl is empty
      final effectiveRelayUrl = stationUrl.isNotEmpty
          ? stationUrl
          : (data['stationUrl'] as String? ?? '');

      return roomsData.map((r) {
        final roomJson = r as Map<String, dynamic>;
        final savedName = roomJson['station_name'] as String? ?? '';
        return StationChatRoom.fromJson(
          roomJson,
          effectiveRelayUrl,
          savedName.isNotEmpty ? savedName : deviceCallsign,
        );
      }).toList();
    } catch (e) {
      LogService().log('Error loading cached chat rooms: $e');
      return [];
    }
  }

  /// Save messages for a chat room using year folders and daily files
  /// Structure: chat/roomId/2025/2025-11-29_chat.txt
  Future<void> saveMessages(
    String deviceCallsign,
    String roomId,
    List<StationChatMessage> messages,
  ) async {
    if (kIsWeb || _basePath == null) return;

    try {
      final cacheDir = await getDeviceCacheDir(deviceCallsign);
      if (cacheDir == null) return;

      final roomDir = Directory('${cacheDir.path}/chat/$roomId');
      if (!await roomDir.exists()) {
        await roomDir.create(recursive: true);
      }

      // Group messages by date
      final messagesByDate = <String, List<StationChatMessage>>{};
      for (final msg in messages) {
        final dt = msg.dateTime;
        if (dt == null) continue;

        final dateKey = '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
        messagesByDate.putIfAbsent(dateKey, () => []).add(msg);
      }

      // Save each day's messages to separate file
      int totalSaved = 0;
      for (final entry in messagesByDate.entries) {
        final dateStr = entry.key;
        final dayMessages = entry.value;
        final year = dateStr.substring(0, 4);

        // Create year directory with files subfolder
        final yearDir = Directory('${roomDir.path}/$year');
        if (!await yearDir.exists()) {
          await yearDir.create(recursive: true);
          await Directory('${yearDir.path}/files').create();
        }

        // Write daily file
        final dailyFile = File('${yearDir.path}/${dateStr}_chat.txt');
        final buffer = StringBuffer();

        // Header
        buffer.writeln('# ${roomId.toUpperCase()}: $roomId from $dateStr');

        // Messages (two empty lines between each for readability)
        for (final msg in dayMessages) {
          final chatMsg = _stationChatToChatMessage(msg);
          buffer.writeln();
          buffer.writeln();
          buffer.write(chatMsg.exportAsText());
        }

        await dailyFile.writeAsString(buffer.toString());
        totalSaved += dayMessages.length;
      }

      LogService().log('Cached $totalSaved messages for room $roomId (${messagesByDate.length} daily files)');
    } catch (e) {
      LogService().log('Error saving messages cache: $e');
    }
  }

  /// Save a raw chat file directly (preserves original format with all metadata)
  Future<void> saveRawChatFile(
    String deviceCallsign,
    String roomId,
    String year,
    String filename,
    String content,
  ) async {
    if (kIsWeb || _basePath == null) return;

    try {
      final cacheDir = await getDeviceCacheDir(deviceCallsign);
      if (cacheDir == null) return;

      final yearDir = Directory('${cacheDir.path}/chat/$roomId/$year');
      if (!await yearDir.exists()) {
        await yearDir.create(recursive: true);
        // Also create files directory for attachments
        await Directory('${yearDir.path}/files').create();
      }

      final file = File('${yearDir.path}/$filename');
      await file.writeAsString(content);

      LogService().log('Cached raw chat file: $deviceCallsign/$roomId/$year/$filename');
    } catch (e) {
      LogService().log('Error saving raw chat file: $e');
    }
  }

  /// Check if a chat file exists in cache
  /// If [expectedSize] is provided, returns false if file size doesn't match
  /// (this ensures we re-download if server file has been updated)
  Future<bool> hasCachedChatFile(
    String deviceCallsign,
    String roomId,
    String year,
    String filename, {
    int? expectedSize,
  }) async {
    if (kIsWeb || _basePath == null) return false;

    try {
      final cacheDir = await getDeviceCacheDir(deviceCallsign);
      if (cacheDir == null) return false;

      final file = File('${cacheDir.path}/chat/$roomId/$year/$filename');
      if (!await file.exists()) return false;

      // If expected size provided, compare with actual file size
      if (expectedSize != null) {
        final stat = await file.stat();
        if (stat.size != expectedSize) {
          LogService().log('Cache size mismatch for $filename: cached=${stat.size}, expected=$expectedSize');
          return false;
        }
      }

      return true;
    } catch (e) {
      return false;
    }
  }

  /// Get list of cached chat files for a room
  Future<List<Map<String, dynamic>>> getCachedChatFiles(
    String deviceCallsign,
    String roomId,
  ) async {
    if (kIsWeb || _basePath == null) return [];

    try {
      final cacheDir = await getDeviceCacheDir(deviceCallsign);
      if (cacheDir == null) return [];

      final roomDir = Directory('${cacheDir.path}/chat/$roomId');
      if (!await roomDir.exists()) return [];

      final List<Map<String, dynamic>> files = [];

      await for (final yearEntity in roomDir.list()) {
        if (yearEntity is Directory) {
          final year = yearEntity.path.split('/').last;
          if (RegExp(r'^\d{4}$').hasMatch(year)) {
            await for (final fileEntity in yearEntity.list()) {
              if (fileEntity is File && fileEntity.path.endsWith('_chat.txt')) {
                final filename = fileEntity.path.split('/').last;
                final stat = await fileEntity.stat();
                files.add({
                  'year': year,
                  'filename': filename,
                  'size': stat.size,
                  'modified': stat.modified.millisecondsSinceEpoch,
                });
              }
            }
          }
        }
      }

      // Sort by year and filename
      files.sort((a, b) {
        final yearCompare = (a['year'] as String).compareTo(b['year'] as String);
        if (yearCompare != 0) return yearCompare;
        return (a['filename'] as String).compareTo(b['filename'] as String);
      });

      return files;
    } catch (e) {
      LogService().log('Error getting cached chat files: $e');
      return [];
    }
  }

  /// Load cached messages for a chat room from year folders and daily files
  Future<List<StationChatMessage>> loadMessages(
    String deviceCallsign,
    String roomId, {
    int? limit,
  }) async {
    if (kIsWeb || _basePath == null) return [];

    try {
      final cacheDir = await getDeviceCacheDir(deviceCallsign);
      if (cacheDir == null) return [];

      final roomDir = Directory('${cacheDir.path}/chat/$roomId');
      if (!await roomDir.exists()) return [];

      final List<StationChatMessage> allMessages = [];
      final List<File> chatFiles = [];

      // Find all year folders, sort descending so we can break early
      final entities = await roomDir.list().toList();
      final yearDirs = entities
          .whereType<Directory>()
          .where((d) => _isYearFolder(d.path))
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path));

      // Collect daily files from year folders, newest years first
      for (final yearDir in yearDirs) {
        final yearEntities = await yearDir.list().toList();
        for (final yearEntity in yearEntities) {
          if (yearEntity is File && yearEntity.path.endsWith('_chat.txt')) {
            chatFiles.add(yearEntity);
          }
        }
      }

      // Sort files by filename (YYYY-MM-DD_chat.txt) descending for lazy loading
      chatFiles.sort((a, b) => b.path.compareTo(a.path));

      // Read files newest-first, stop when we have enough messages
      for (final file in chatFiles) {
        final content = await file.readAsString();
        var chatMessages = ChatService.parseMessageText(content);
        final dateStr = _extractDateFromFilename(file.path);
        if (dateStr != null) {
          final deduped = _dedupeChatMessages(chatMessages);
          if (deduped.length != chatMessages.length) {
            await _rewriteChatFile(file, roomId, dateStr, deduped);
          }
          chatMessages = deduped;
        }
        allMessages.addAll(
          chatMessages.map((msg) => _chatMessageToRelayChat(msg, roomId)),
        );

        if (limit != null && allMessages.length >= limit) {
          break;
        }
      }

      // Sort by timestamp
      allMessages.sort((a, b) => a.timestamp.compareTo(b.timestamp));

      if (limit != null && allMessages.length > limit) {
        return allMessages.sublist(allMessages.length - limit);
      }

      return allMessages;
    } catch (e) {
      LogService().log('Error loading cached messages: $e');
      return [];
    }
  }

  String? _extractDateFromFilename(String path) {
    final name = path.split('/').last;
    if (name.length < 10) return null;
    final dateStr = name.substring(0, 10);
    return RegExp(r'^\\d{4}-\\d{2}-\\d{2}$').hasMatch(dateStr) ? dateStr : null;
  }

  List<ChatMessage> _dedupeChatMessages(List<ChatMessage> messages) {
    final merged = <String, ChatMessage>{};
    for (final msg in messages) {
      final key = _messageDedupeKey(msg);
      final existing = merged[key];
      if (existing == null) {
        merged[key] = msg;
        continue;
      }
      final currentScore = _messageQualityScore(existing);
      final incomingScore = _messageQualityScore(msg);
      if (incomingScore > currentScore) {
        merged[key] = msg;
      }
    }

    var mergedMessages = merged.values.toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    mergedMessages = _removeUnsignedNearDuplicates(mergedMessages);
    return mergedMessages;
  }

  Future<void> _rewriteChatFile(File file, String roomId, String dateStr, List<ChatMessage> messages) async {
    final buffer = StringBuffer();
    buffer.writeln('# ${roomId.toUpperCase()}: $roomId from $dateStr');
    for (final msg in messages) {
      buffer.writeln();
      buffer.writeln();
      buffer.write(msg.exportAsText());
    }
    await file.writeAsString(buffer.toString());
  }

  /// Load the most recent cached chat message for a room
  Future<ChatMessage?> loadLatestMessage(
    String deviceCallsign,
    String roomId,
  ) async {
    if (kIsWeb || _basePath == null) return null;

    try {
      final cacheDir = await getDeviceCacheDir(deviceCallsign);
      if (cacheDir == null) return null;

      final files = await getCachedChatFiles(deviceCallsign, roomId);
      if (files.isEmpty) return null;

      final latest = files.last;
      final year = latest['year'] as String;
      final filename = latest['filename'] as String;
      final file = File('${cacheDir.path}/chat/$roomId/$year/$filename');
      if (!await file.exists()) return null;

      final content = await file.readAsString();
      final chatMessages = ChatService.parseMessageText(content);
      if (chatMessages.isEmpty) return null;

      return chatMessages.last;
    } catch (e) {
      LogService().log('Error loading latest cached message: $e');
      return null;
    }
  }

  /// Check if path is a year folder (4 digits)
  bool _isYearFolder(String folderPath) {
    final name = folderPath.split('/').last;
    return RegExp(r'^\d{4}$').hasMatch(name);
  }

  /// Normalize timestamp to chat format: YYYY-MM-DD HH:MM_ss
  String _normalizeToChatTimestamp(String timestamp) {
    return ChatFormat.normalizeTimestamp(timestamp);
  }

  /// Convert StationChatMessage to ChatMessage for export
  ChatMessage _stationChatToChatMessage(StationChatMessage msg) {
    // Normalize timestamp to chat format: YYYY-MM-DD HH:MM_ss
    final normalizedTimestamp = _normalizeToChatTimestamp(msg.timestamp);

    final metadata = <String, String>{};
    if (msg.metadata.isNotEmpty) {
      metadata.addAll(msg.metadata);
    }
    if (msg.createdAt != null) {
      metadata['created_at'] = msg.createdAt.toString();
    }
    if (msg.npub != null && msg.npub!.isNotEmpty) {
      metadata['npub'] = msg.npub!;
    }
    if (msg.signature != null && msg.signature!.isNotEmpty) {
      metadata['signature'] = msg.signature!;
      metadata['has_signature'] = 'true';
    }
    if (msg.eventId != null && msg.eventId!.isNotEmpty) {
      metadata['event_id'] = msg.eventId!;
    }
    if (msg.verified) {
      metadata['verified'] = 'true';
    }

    return ChatMessage(
      author: msg.callsign,
      timestamp: normalizedTimestamp,
      content: msg.content,
      metadata: metadata.isNotEmpty ? metadata : null,
      reactions: msg.reactions,
    );
  }

  /// Convert ChatMessage to StationChatMessage for loading
  /// Extracts NOSTR metadata (npub, signature, created_at) from ChatMessage.metadata
  StationChatMessage _chatMessageToRelayChat(ChatMessage msg, String roomId) {
    final metadata = msg.metadata;

    // Extract NOSTR fields from metadata
    final npub = metadata['npub'];
    final signature = metadata['signature'];
    final createdAtStr = metadata['created_at'];
    final eventId = metadata['event_id'];
    final createdAt = createdAtStr != null ? int.tryParse(createdAtStr) : null;

    // Determine if message has signature and is verified
    final hasSignature = signature != null && signature.isNotEmpty;
    // Messages with valid signature+npub are considered verified when loaded from trusted cache
    final verified = metadata['verified'] == 'true' || (hasSignature && npub != null && npub.isNotEmpty);

    return StationChatMessage(
      roomId: roomId,
      callsign: msg.author,
      content: msg.content,
      timestamp: msg.timestamp,
      metadata: metadata,
      reactions: msg.reactions,
      npub: npub,
      signature: signature,
      eventId: eventId,
      createdAt: createdAt,
      hasSignature: hasSignature,
      verified: verified,
    );
  }

  String _messageDedupeKey(ChatMessage msg) {
    final signature = msg.getMeta('signature');
    if (signature != null && signature.isNotEmpty) {
      return 'sig:$signature';
    }
    final eventId = msg.getMeta('event_id');
    if (eventId != null && eventId.isNotEmpty) {
      return 'event:$eventId';
    }
    final createdAt = msg.getMeta('created_at');
    if (createdAt != null && createdAt.isNotEmpty) {
      return 'created:$createdAt|${msg.author.toUpperCase()}';
    }
    return 'ts:${msg.timestamp}|${msg.author.toUpperCase()}|${msg.content}';
  }

  int _messageQualityScore(ChatMessage msg) {
    final verified = msg.getMeta('verified') == 'true';
    final hasSignature = msg.getMeta('signature')?.isNotEmpty == true ||
        msg.getMeta('has_signature') == 'true';
    final isPending = msg.getMeta('status') == 'pending';

    if (verified) return 3;
    if (hasSignature && !isPending) return 2;
    if (hasSignature && isPending) return 1;
    if (!hasSignature && !isPending) return 0;
    return -1; // unsigned + pending
  }

  bool _isUnsignedOrPending(ChatMessage msg) {
    final hasSignature = msg.getMeta('signature')?.isNotEmpty == true ||
        msg.getMeta('has_signature') == 'true';
    if (!hasSignature) return true;
    return msg.getMeta('status') == 'pending';
  }

  List<ChatMessage> _removeUnsignedNearDuplicates(List<ChatMessage> messages) {
    // Remove unsigned/pending duplicates when a signed version exists nearby
    final result = <ChatMessage>[];
    for (final msg in messages) {
      bool replaced = false;
      for (int i = 0; i < result.length; i++) {
        final existing = result[i];
        if (existing.author.toUpperCase() != msg.author.toUpperCase()) continue;
        if (existing.content != msg.content) continue;

        final dtA = ChatFormat.parseTimestamp(existing.timestamp);
        final dtB = ChatFormat.parseTimestamp(msg.timestamp);
        final seconds = dtA.difference(dtB).abs().inSeconds;
        if (seconds > 300) continue;

        final existingBetter = !_isUnsignedOrPending(existing);
        final msgBetter = !_isUnsignedOrPending(msg);
        if (existingBetter && !msgBetter) {
          replaced = true;
          break;
        }
        if (msgBetter && !existingBetter) {
          result[i] = msg;
          replaced = true;
          break;
        }
      }
      if (!replaced) {
        result.add(msg);
      }
    }
    return result;
  }

  /// Merge new messages into cached daily files without losing existing content
  Future<void> mergeMessages(
    String deviceCallsign,
    String roomId,
    List<StationChatMessage> newMessages,
  ) async {
    if (kIsWeb || _basePath == null) return;
    if (newMessages.isEmpty) return;

    try {
      final cacheDir = await getDeviceCacheDir(deviceCallsign);
      if (cacheDir == null) return;

      final roomDir = Directory('${cacheDir.path}/chat/$roomId');
      if (!await roomDir.exists()) {
        await roomDir.create(recursive: true);
      }

      final messagesByDate = <String, List<StationChatMessage>>{};
      for (final msg in newMessages) {
        if (msg.timestamp.length < 10) continue;
        final dateKey = msg.timestamp.substring(0, 10);
        messagesByDate.putIfAbsent(dateKey, () => []).add(msg);
      }

      for (final entry in messagesByDate.entries) {
        final dateStr = entry.key;
        final dayMessages = entry.value;
        final year = dateStr.substring(0, 4);

        final yearDir = Directory('${roomDir.path}/$year');
        if (!await yearDir.exists()) {
          await yearDir.create(recursive: true);
          await Directory('${yearDir.path}/files').create();
        }

        final dailyFile = File('${yearDir.path}/${dateStr}_chat.txt');
        final existing = <ChatMessage>[];
        if (await dailyFile.exists()) {
          final content = await dailyFile.readAsString();
          existing.addAll(ChatService.parseMessageText(content));
        }

        final merged = <String, ChatMessage>{};
        for (final msg in existing) {
          merged[_messageDedupeKey(msg)] = msg;
        }
        for (final msg in dayMessages) {
          final chatMsg = _stationChatToChatMessage(msg);
          final key = _messageDedupeKey(chatMsg);
          final existingMsg = merged[key];
          if (existingMsg == null) {
            merged[key] = chatMsg;
          } else {
            final currentScore = _messageQualityScore(existingMsg);
            final incomingScore = _messageQualityScore(chatMsg);
            if (incomingScore > currentScore) {
              merged[key] = chatMsg;
            }
          }
        }

        var mergedMessages = merged.values.toList()
          ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
        mergedMessages = _removeUnsignedNearDuplicates(mergedMessages);

        final buffer = StringBuffer();
        buffer.writeln('# ${roomId.toUpperCase()}: $roomId from $dateStr');
        for (final msg in mergedMessages) {
          buffer.writeln();
          buffer.writeln();
          buffer.write(msg.exportAsText());
        }

        await dailyFile.writeAsString(buffer.toString());
      }
    } catch (e) {
      LogService().log('Error merging cached messages: $e');
    }
  }

  /// Remove a message from cached daily files by timestamp and author
  Future<void> removeMessage(
    String deviceCallsign,
    String roomId,
    String timestamp,
    String author,
  ) async {
    if (kIsWeb || _basePath == null) return;
    if (timestamp.length < 10) return;

    try {
      final cacheDir = await getDeviceCacheDir(deviceCallsign);
      if (cacheDir == null) return;

      final dateStr = timestamp.substring(0, 10);
      final year = dateStr.substring(0, 4);
      final dailyFile = File('${cacheDir.path}/chat/$roomId/$year/${dateStr}_chat.txt');
      if (!await dailyFile.exists()) return;

      final content = await dailyFile.readAsString();
      final messages = ChatService.parseMessageText(content);
      final filtered = messages.where((msg) {
        if (msg.timestamp != timestamp) return true;
        return msg.author.toUpperCase() != author.toUpperCase();
      }).toList();

      final buffer = StringBuffer();
      buffer.writeln('# ${roomId.toUpperCase()}: $roomId from $dateStr');
      for (final msg in filtered) {
        buffer.writeln();
        buffer.writeln();
        buffer.write(msg.exportAsText());
      }

      await dailyFile.writeAsString(buffer.toString());
    } catch (e) {
      LogService().log('Error removing cached message: $e');
    }
  }

  /// Update a message's content in cached daily files (for edits)
  Future<void> updateMessage(
    String deviceCallsign,
    String roomId,
    String timestamp,
    String author,
    String newContent,
  ) async {
    if (kIsWeb || _basePath == null) return;
    if (timestamp.length < 10) return;

    try {
      final cacheDir = await getDeviceCacheDir(deviceCallsign);
      if (cacheDir == null) return;

      final dateStr = timestamp.substring(0, 10);
      final year = dateStr.substring(0, 4);
      final dailyFile = File('${cacheDir.path}/chat/$roomId/$year/${dateStr}_chat.txt');
      if (!await dailyFile.exists()) return;

      final content = await dailyFile.readAsString();
      final messages = ChatService.parseMessageText(content);

      // Find and update the message
      bool found = false;
      for (int i = 0; i < messages.length; i++) {
        if (messages[i].timestamp == timestamp &&
            messages[i].author.toUpperCase() == author.toUpperCase()) {
          final updatedMetadata = Map<String, String>.from(messages[i].metadata);
          updatedMetadata['edited_at'] = DateTime.now().toIso8601String();
          messages[i] = messages[i].copyWith(
            content: newContent,
            metadata: updatedMetadata,
          );
          found = true;
          break;
        }
      }

      if (!found) return;

      final buffer = StringBuffer();
      buffer.writeln('# ${roomId.toUpperCase()}: $roomId from $dateStr');
      for (final msg in messages) {
        buffer.writeln();
        buffer.writeln();
        buffer.write(msg.exportAsText());
      }

      await dailyFile.writeAsString(buffer.toString());
    } catch (e) {
      LogService().log('Error updating cached message: $e');
    }
  }

  /// Get list of cached device callsigns
  Future<List<String>> getCachedDevices() async {
    print('DEBUG getCachedDevices: kIsWeb=$kIsWeb, _basePath=$_basePath');
    if (kIsWeb || _basePath == null) return [];

    try {
      final devicesDir = Directory(_basePath!);
      final exists = await devicesDir.exists();
      print('DEBUG getCachedDevices: devicesDir=$_basePath exists=$exists');
      if (!exists) return [];

      final entities = await devicesDir.list().toList();
      final devices = entities
          .whereType<Directory>()
          .map((d) => d.path.split('/').last)
          .toList();
      print('DEBUG getCachedDevices: found devices=$devices');
      return devices;
    } catch (e) {
      LogService().log('Error listing cached devices: $e');
      print('DEBUG getCachedDevices: ERROR $e');
      return [];
    }
  }

  /// Check if a device has cached data
  Future<bool> hasCache(String deviceCallsign) async {
    if (kIsWeb || _basePath == null) return false;

    try {
      final cacheDir = await getDeviceCacheDir(deviceCallsign);
      if (cacheDir == null) return false;

      final roomsFile = File('${cacheDir.path}/chat/rooms.json');
      return await roomsFile.exists();
    } catch (e) {
      return false;
    }
  }

  /// Get cache timestamp for a device
  Future<DateTime?> getCacheTime(String deviceCallsign) async {
    if (kIsWeb || _basePath == null) return null;

    try {
      final cacheDir = await getDeviceCacheDir(deviceCallsign);
      if (cacheDir == null) return null;

      final roomsFile = File('${cacheDir.path}/chat/rooms.json');
      if (!await roomsFile.exists()) return null;

      final content = await roomsFile.readAsString();
      final data = jsonDecode(content) as Map<String, dynamic>;
      final updated = data['updated'] as String?;

      if (updated != null) {
        return DateTime.parse(updated);
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// Get cached station URL for a device
  Future<String?> getCachedRelayUrl(String deviceCallsign) async {
    if (kIsWeb || _basePath == null) return null;

    try {
      final cacheDir = await getDeviceCacheDir(deviceCallsign);
      if (cacheDir == null) return null;

      final roomsFile = File('${cacheDir.path}/chat/rooms.json');
      if (!await roomsFile.exists()) return null;

      final content = await roomsFile.readAsString();
      final data = jsonDecode(content) as Map<String, dynamic>;
      return data['stationUrl'] as String?;
    } catch (e) {
      return null;
    }
  }

  /// Clear cache for a device
  Future<void> clearCache(String deviceCallsign) async {
    if (kIsWeb || _basePath == null) return;

    try {
      final cacheDir = await getDeviceCacheDir(deviceCallsign);
      if (cacheDir != null && await cacheDir.exists()) {
        await cacheDir.delete(recursive: true);
        LogService().log('Cleared cache for $deviceCallsign');
      }
    } catch (e) {
      LogService().log('Error clearing cache: $e');
    }
  }

  /// Clear all device caches
  Future<void> clearAllCaches() async {
    if (kIsWeb || _basePath == null) return;

    try {
      final devicesDir = Directory(_basePath!);
      if (await devicesDir.exists()) {
        await devicesDir.delete(recursive: true);
        await devicesDir.create(recursive: true);
        LogService().log('Cleared all device caches');
      }
    } catch (e) {
      LogService().log('Error clearing all caches: $e');
    }
  }

  // ==========================================================================
  // Chat File Attachment Caching
  // ==========================================================================

  /// Save a chat file attachment to local cache
  /// Path: devices/{callsign}/chat/{roomId}/files/{filename}
  Future<void> saveChatFile(
    String deviceCallsign,
    String roomId,
    String filename,
    List<int> bytes,
  ) async {
    if (kIsWeb || _basePath == null) return;

    try {
      final cacheDir = await getDeviceCacheDir(deviceCallsign);
      if (cacheDir == null) return;

      final filesDir = Directory('${cacheDir.path}/chat/$roomId/files');
      if (!await filesDir.exists()) {
        await filesDir.create(recursive: true);
      }

      final file = File('${filesDir.path}/$filename');
      await file.writeAsBytes(bytes, flush: true);

      LogService().log('RelayCacheService: Cached chat file $filename (${bytes.length} bytes)');
    } catch (e) {
      LogService().log('RelayCacheService: Error saving chat file: $e');
    }
  }

  /// Get local path to a cached chat file
  /// Returns null if file not cached
  Future<String?> getChatFilePath(
    String deviceCallsign,
    String roomId,
    String filename,
  ) async {
    if (kIsWeb || _basePath == null) return null;

    try {
      final cacheDir = await getDeviceCacheDir(deviceCallsign);
      if (cacheDir == null) return null;

      final filePath = '${cacheDir.path}/chat/$roomId/files/$filename';
      final file = File(filePath);
      if (await file.exists()) {
        return filePath;
      }
      return null;
    } catch (e) {
      LogService().log('RelayCacheService: Error getting chat file path: $e');
      return null;
    }
  }

  /// Check if a chat file is cached
  Future<bool> hasCachedChatFileAttachment(
    String deviceCallsign,
    String roomId,
    String filename,
  ) async {
    if (kIsWeb || _basePath == null) return false;

    try {
      final path = await getChatFilePath(deviceCallsign, roomId, filename);
      return path != null;
    } catch (e) {
      return false;
    }
  }
}

/// Alias for backward compatibility
typedef StationCacheService = RelayCacheService;
