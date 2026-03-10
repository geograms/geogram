/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Abstract base class for relay cache services.
 * Contains all shared caching logic used by both Desktop and CLI stations.
 * Uses dart:io for file operations (not web-compatible by design).
 */

import 'dart:convert';
import 'dart:io';
import '../models/station_chat_room.dart';
import '../models/chat_message.dart';
import '../util/chat_format.dart';

/// Base class with shared cache logic for Desktop and CLI relay cache services.
/// Subclasses provide platform-specific initialization, logging, and message parsing.
abstract class CacheServiceBase {
  String? get basePath;
  bool get isWeb;

  /// Log a message using the platform-appropriate logger.
  void log(String message);

  /// Parse message text content into ChatMessage list.
  /// Desktop delegates to ChatService.parseMessageText, CLI uses its own parser.
  List<ChatMessage> parseMessageText(String content);

  /// Get the cache directory for a device
  Future<Directory?> getDeviceCacheDir(String deviceCallsign) async {
    if (isWeb || basePath == null) return null;

    final safeName = deviceCallsign.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final path = '$basePath/$safeName';

    final dir = Directory(path);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    return dir;
  }

  /// Save chat rooms for a device
  Future<void> saveChatRooms(String deviceCallsign, List<StationChatRoom> rooms, {String? stationUrl}) async {
    if (isWeb || basePath == null) return;

    try {
      final cacheDir = await getDeviceCacheDir(deviceCallsign);
      if (cacheDir == null) return;

      final chatDir = Directory('${cacheDir.path}/chat');
      if (!await chatDir.exists()) {
        await chatDir.create(recursive: true);
      }

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

      log('Cached ${rooms.length} chat rooms for $deviceCallsign');
    } catch (e) {
      log('Error saving chat rooms cache: $e');
    }
  }

  /// Load cached chat rooms for a device
  Future<List<StationChatRoom>> loadChatRooms(String deviceCallsign, String stationUrl) async {
    if (isWeb || basePath == null) return [];

    try {
      final cacheDir = await getDeviceCacheDir(deviceCallsign);
      if (cacheDir == null) return [];

      final roomsFile = File('${cacheDir.path}/chat/rooms.json');
      if (!await roomsFile.exists()) return [];

      final content = await roomsFile.readAsString();
      final data = jsonDecode(content) as Map<String, dynamic>;
      final roomsData = data['rooms'] as List<dynamic>? ?? [];

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
      log('Error loading cached chat rooms: $e');
      return [];
    }
  }

  /// Save messages for a chat room using year folders and daily files
  Future<void> saveMessages(
    String deviceCallsign,
    String roomId,
    List<StationChatMessage> messages,
  ) async {
    if (isWeb || basePath == null) return;

    try {
      final cacheDir = await getDeviceCacheDir(deviceCallsign);
      if (cacheDir == null) return;

      final roomDir = Directory('${cacheDir.path}/chat/$roomId');
      if (!await roomDir.exists()) {
        await roomDir.create(recursive: true);
      }

      final messagesByDate = <String, List<StationChatMessage>>{};
      for (final msg in messages) {
        final dt = msg.dateTime;
        if (dt == null) continue;

        final dateKey = '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
        messagesByDate.putIfAbsent(dateKey, () => []).add(msg);
      }

      int totalSaved = 0;
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
        final buffer = StringBuffer();
        buffer.writeln('# ${roomId.toUpperCase()}: $roomId from $dateStr');

        for (final msg in dayMessages) {
          final chatMsg = stationChatToChatMessage(msg);
          buffer.writeln();
          buffer.writeln();
          buffer.write(chatMsg.exportAsText());
        }

        await dailyFile.writeAsString(buffer.toString());
        totalSaved += dayMessages.length;
      }

      log('Cached $totalSaved messages for room $roomId (${messagesByDate.length} daily files)');
    } catch (e) {
      log('Error saving messages cache: $e');
    }
  }

  /// Save a raw chat file directly
  Future<void> saveRawChatFile(
    String deviceCallsign,
    String roomId,
    String year,
    String filename,
    String content,
  ) async {
    if (isWeb || basePath == null) return;

    try {
      final cacheDir = await getDeviceCacheDir(deviceCallsign);
      if (cacheDir == null) return;

      final yearDir = Directory('${cacheDir.path}/chat/$roomId/$year');
      if (!await yearDir.exists()) {
        await yearDir.create(recursive: true);
        await Directory('${yearDir.path}/files').create();
      }

      final file = File('${yearDir.path}/$filename');
      await file.writeAsString(content);

      log('Cached raw chat file: $deviceCallsign/$roomId/$year/$filename');
    } catch (e) {
      log('Error saving raw chat file: $e');
    }
  }

  /// Check if a chat file exists in cache
  Future<bool> hasCachedChatFile(
    String deviceCallsign,
    String roomId,
    String year,
    String filename, {
    int? expectedSize,
  }) async {
    if (isWeb || basePath == null) return false;

    try {
      final cacheDir = await getDeviceCacheDir(deviceCallsign);
      if (cacheDir == null) return false;

      final file = File('${cacheDir.path}/chat/$roomId/$year/$filename');
      if (!await file.exists()) return false;

      if (expectedSize != null) {
        final stat = await file.stat();
        if (stat.size != expectedSize) {
          log('Cache size mismatch for $filename: cached=${stat.size}, expected=$expectedSize');
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
    if (isWeb || basePath == null) return [];

    try {
      final cacheDir = await getDeviceCacheDir(deviceCallsign);
      if (cacheDir == null) return [];

      final roomDir = Directory('${cacheDir.path}/chat/$roomId');
      if (!await roomDir.exists()) return [];

      final List<Map<String, dynamic>> files = [];

      await for (final yearEntity in roomDir.list()) {
        if (yearEntity is Directory) {
          final year = _extractName(yearEntity.path);
          if (RegExp(r'^\d{4}$').hasMatch(year)) {
            await for (final fileEntity in yearEntity.list()) {
              if (fileEntity is File && fileEntity.path.endsWith('_chat.txt')) {
                final filename = _extractName(fileEntity.path);
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

      files.sort((a, b) {
        final yearCompare = (a['year'] as String).compareTo(b['year'] as String);
        if (yearCompare != 0) return yearCompare;
        return (a['filename'] as String).compareTo(b['filename'] as String);
      });

      return files;
    } catch (e) {
      log('Error getting cached chat files: $e');
      return [];
    }
  }

  /// Load cached messages for a chat room from year folders and daily files
  Future<List<StationChatMessage>> loadMessages(
    String deviceCallsign,
    String roomId, {
    int? limit,
  }) async {
    if (isWeb || basePath == null) return [];

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
        final chatMessages = parseMessageText(content);
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
      log('Error loading cached messages: $e');
      return [];
    }
  }

  /// Get list of cached device callsigns
  Future<List<String>> getCachedDevices() async {
    if (isWeb || basePath == null) return [];

    try {
      final devicesDir = Directory(basePath!);
      if (!await devicesDir.exists()) return [];

      final entities = await devicesDir.list().toList();
      return entities
          .whereType<Directory>()
          .map((d) => _extractName(d.path))
          .toList();
    } catch (e) {
      log('Error listing cached devices: $e');
      return [];
    }
  }

  /// Check if a device has cached data
  Future<bool> hasCache(String deviceCallsign) async {
    if (isWeb || basePath == null) return false;

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
    if (isWeb || basePath == null) return null;

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
    if (isWeb || basePath == null) return null;

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
    if (isWeb || basePath == null) return;

    try {
      final cacheDir = await getDeviceCacheDir(deviceCallsign);
      if (cacheDir != null && await cacheDir.exists()) {
        await cacheDir.delete(recursive: true);
        log('Cleared cache for $deviceCallsign');
      }
    } catch (e) {
      log('Error clearing cache: $e');
    }
  }

  /// Clear all device caches
  Future<void> clearAllCaches() async {
    if (isWeb || basePath == null) return;

    try {
      final devicesDir = Directory(basePath!);
      if (await devicesDir.exists()) {
        await devicesDir.delete(recursive: true);
        await devicesDir.create(recursive: true);
        log('Cleared all device caches');
      }
    } catch (e) {
      log('Error clearing all caches: $e');
    }
  }

  // ---- Shared helpers ----

  /// Check if path is a year folder (4 digits)
  bool isYearFolder(String folderPath) {
    final name = _extractName(folderPath);
    return RegExp(r'^\d{4}$').hasMatch(name);
  }

  /// Extract file/directory name from path, handling both `/` and `\`
  String _extractName(String path) {
    final lastFwd = path.lastIndexOf('/');
    final lastBack = path.lastIndexOf('\\');
    final idx = lastFwd > lastBack ? lastFwd : lastBack;
    return idx < 0 ? path : path.substring(idx + 1);
  }

  /// Convert StationChatMessage to ChatMessage for export
  ChatMessage stationChatToChatMessage(StationChatMessage msg) {
    final normalizedTimestamp = ChatFormat.normalizeTimestamp(msg.timestamp);

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
  StationChatMessage chatMessageToRelayChat(ChatMessage msg, String roomId) {
    final metadata = msg.metadata;

    final npub = metadata['npub'];
    final signature = metadata['signature'];
    final createdAtStr = metadata['created_at'];
    final eventId = metadata['event_id'];
    final createdAt = createdAtStr != null ? int.tryParse(createdAtStr) : null;

    final hasSignature = signature != null && signature.isNotEmpty;
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

  /// Extract date string from a chat filename
  String? extractDateFromFilename(String path) {
    final name = _extractName(path);
    if (name.length < 10) return null;
    final dateStr = name.substring(0, 10);
    return RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(dateStr) ? dateStr : null;
  }
}
