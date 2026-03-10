/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import '../models/chat_message.dart';
import '../models/station_chat_room.dart';
import '../util/chat_format.dart';
import '../services/chat_service.dart';
import 'cache_service_base.dart';
import 'log_service.dart';
import 'storage_config.dart';

/// Desktop relay cache service.
/// Extends CacheServiceBase with dedup logic, merge/remove/update, and file attachments.
class RelayCacheService extends CacheServiceBase {
  static final RelayCacheService _instance = RelayCacheService._internal();
  factory RelayCacheService() => _instance;
  RelayCacheService._internal();

  String? _basePath;
  bool _initialized = false;

  @override
  String? get basePath => _basePath;

  @override
  bool get isWeb => kIsWeb;

  @override
  void log(String message) => LogService().log(message);

  @override
  List<ChatMessage> parseMessageText(String content) =>
      ChatService.parseMessageText(content);

  /// Initialize the cache service
  Future<void> initialize() async {
    if (_initialized) return;

    if (kIsWeb) {
      LogService().log('RelayCacheService: Web platform, file caching disabled');
      _initialized = true;
      return;
    }

    try {
      _basePath = StorageConfig().devicesDir;

      final devicesDir = Directory(_basePath!);
      if (!await devicesDir.exists()) {
        await devicesDir.create(recursive: true);
      }

      _initialized = true;
      LogService().log('RelayCacheService initialized at: $_basePath');
      unawaited(_cleanupDuplicateChatFiles());
    } catch (e) {
      LogService().log('Error initializing RelayCacheService: $e');
    }
  }

  // ==========================================================================
  // Desktop-only: Dedup logic
  // ==========================================================================

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
              final dateStr = extractDateFromFilename(file.path);
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

  /// Override loadMessages to add dedup during load
  @override
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

      final entities = await roomDir.list().toList();
      final yearDirs = entities
          .whereType<Directory>()
          .where((d) => isYearFolder(d.path))
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path));

      for (final yearDir in yearDirs) {
        final yearEntities = await yearDir.list().toList();
        for (final yearEntity in yearEntities) {
          if (yearEntity is File && yearEntity.path.endsWith('_chat.txt')) {
            chatFiles.add(yearEntity);
          }
        }
      }

      chatFiles.sort((a, b) => b.path.compareTo(a.path));

      for (final file in chatFiles) {
        final content = await file.readAsString();
        var chatMessages = ChatService.parseMessageText(content);
        final dateStr = extractDateFromFilename(file.path);
        if (dateStr != null) {
          final deduped = _dedupeChatMessages(chatMessages);
          if (deduped.length != chatMessages.length) {
            await _rewriteChatFile(file, roomId, dateStr, deduped);
          }
          chatMessages = deduped;
        }
        allMessages.addAll(
          chatMessages.map((msg) => chatMessageToRelayChat(msg, roomId)),
        );

        if (limit != null && allMessages.length >= limit) {
          break;
        }
      }

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
    return -1;
  }

  bool _isUnsignedOrPending(ChatMessage msg) {
    final hasSignature = msg.getMeta('signature')?.isNotEmpty == true ||
        msg.getMeta('has_signature') == 'true';
    if (!hasSignature) return true;
    return msg.getMeta('status') == 'pending';
  }

  List<ChatMessage> _removeUnsignedNearDuplicates(List<ChatMessage> messages) {
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

  // ==========================================================================
  // Desktop-only: Merge, remove, update, latest message
  // ==========================================================================

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
          final chatMsg = stationChatToChatMessage(msg);
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

  // ==========================================================================
  // Desktop-only: Chat File Attachment Caching
  // ==========================================================================

  /// Save a chat file attachment to local cache
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
