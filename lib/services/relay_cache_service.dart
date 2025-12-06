/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';
import '../models/relay_chat_room.dart';
import '../models/chat_message.dart';
import '../services/chat_service.dart';
import 'log_service.dart';

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
      final appDir = await getApplicationDocumentsDirectory();
      _basePath = '${appDir.path}/geogram/devices';

      final devicesDir = Directory(_basePath!);
      if (!await devicesDir.exists()) {
        await devicesDir.create(recursive: true);
      }

      _initialized = true;
      LogService().log('RelayCacheService initialized at: $_basePath');
      print('DEBUG RelayCacheService: initialized at $_basePath');
    } catch (e) {
      LogService().log('Error initializing RelayCacheService: $e');
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
  /// [relayUrl] is stored for offline retrieval when the device is unreachable
  Future<void> saveChatRooms(String deviceCallsign, List<RelayChatRoom> rooms, {String? relayUrl}) async {
    if (kIsWeb || _basePath == null) return;

    try {
      final cacheDir = await getDeviceCacheDir(deviceCallsign);
      if (cacheDir == null) return;

      final chatDir = Directory('${cacheDir.path}/chat');
      if (!await chatDir.exists()) {
        await chatDir.create(recursive: true);
      }

      // Save rooms list with relay URL for offline use
      final roomsFile = File('${chatDir.path}/rooms.json');
      final data = {
        'updated': DateTime.now().toIso8601String(),
        'device': deviceCallsign,
        'relayUrl': relayUrl ?? (rooms.isNotEmpty ? rooms.first.relayUrl : null),
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
  /// If [relayUrl] is empty, uses the stored relayUrl from the cache
  Future<List<RelayChatRoom>> loadChatRooms(String deviceCallsign, String relayUrl) async {
    if (kIsWeb || _basePath == null) return [];

    try {
      final cacheDir = await getDeviceCacheDir(deviceCallsign);
      if (cacheDir == null) return [];

      final roomsFile = File('${cacheDir.path}/chat/rooms.json');
      if (!await roomsFile.exists()) return [];

      final content = await roomsFile.readAsString();
      final data = jsonDecode(content) as Map<String, dynamic>;
      final roomsData = data['rooms'] as List<dynamic>? ?? [];

      // Use stored relayUrl if provided relayUrl is empty
      final effectiveRelayUrl = relayUrl.isNotEmpty
          ? relayUrl
          : (data['relayUrl'] as String? ?? '');

      return roomsData.map((r) {
        return RelayChatRoom.fromJson(
          r as Map<String, dynamic>,
          effectiveRelayUrl,
          deviceCallsign,
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
    List<RelayChatMessage> messages,
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
      final messagesByDate = <String, List<RelayChatMessage>>{};
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

        // Messages
        for (final msg in dayMessages) {
          final chatMsg = _relayChatToChatMessage(msg);
          buffer.writeln();
          buffer.write(chatMsg.exportAsText());
        }
        buffer.writeln();

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
  Future<List<RelayChatMessage>> loadMessages(
    String deviceCallsign,
    String roomId,
  ) async {
    if (kIsWeb || _basePath == null) return [];

    try {
      final cacheDir = await getDeviceCacheDir(deviceCallsign);
      if (cacheDir == null) return [];

      final roomDir = Directory('${cacheDir.path}/chat/$roomId');
      if (!await roomDir.exists()) return [];

      List<RelayChatMessage> allMessages = [];

      // Find all year folders
      final entities = await roomDir.list().toList();
      for (final entity in entities) {
        if (entity is Directory && _isYearFolder(entity.path)) {
          // Find all daily chat files in year folder
          final yearEntities = await entity.list().toList();
          for (final yearEntity in yearEntities) {
            if (yearEntity is File && yearEntity.path.endsWith('_chat.txt')) {
              // Parse messages from daily file
              final content = await yearEntity.readAsString();
              final chatMessages = ChatService.parseMessageText(content);
              allMessages.addAll(
                chatMessages.map((msg) => _chatMessageToRelayChat(msg, roomId)),
              );
            }
          }
        }
      }


      // Sort by timestamp
      allMessages.sort((a, b) => a.timestamp.compareTo(b.timestamp));

      return allMessages;
    } catch (e) {
      LogService().log('Error loading cached messages: $e');
      return [];
    }
  }

  /// Check if path is a year folder (4 digits)
  bool _isYearFolder(String folderPath) {
    final name = folderPath.split('/').last;
    return RegExp(r'^\d{4}$').hasMatch(name);
  }

  /// Convert RelayChatMessage to ChatMessage for export
  ChatMessage _relayChatToChatMessage(RelayChatMessage msg) {
    // RelayChatMessage timestamp is already in chat format: YYYY-MM-DD HH:MM_ss
    return ChatMessage(
      author: msg.callsign,
      timestamp: msg.timestamp,
      content: msg.content,
    );
  }

  /// Convert ChatMessage to RelayChatMessage for loading
  /// Extracts NOSTR metadata (npub, signature, created_at) from ChatMessage.metadata
  RelayChatMessage _chatMessageToRelayChat(ChatMessage msg, String roomId) {
    final metadata = msg.metadata ?? {};

    // Extract NOSTR fields from metadata
    final npub = metadata['npub'];
    final signature = metadata['signature'];
    final createdAtStr = metadata['created_at'];
    final createdAt = createdAtStr != null ? int.tryParse(createdAtStr) : null;

    // Determine if message has signature and is verified
    final hasSignature = signature != null && signature.isNotEmpty;
    // Messages with valid signature+npub are considered verified when loaded from trusted cache
    final verified = hasSignature && npub != null && npub.isNotEmpty;

    return RelayChatMessage(
      roomId: roomId,
      callsign: msg.author,
      content: msg.content,
      timestamp: msg.timestamp,
      npub: npub,
      signature: signature,
      createdAt: createdAt,
      hasSignature: hasSignature,
      verified: verified,
    );
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

  /// Get cached relay URL for a device
  Future<String?> getCachedRelayUrl(String deviceCallsign) async {
    if (kIsWeb || _basePath == null) return null;

    try {
      final cacheDir = await getDeviceCacheDir(deviceCallsign);
      if (cacheDir == null) return null;

      final roomsFile = File('${cacheDir.path}/chat/rooms.json');
      if (!await roomsFile.exists()) return null;

      final content = await roomsFile.readAsString();
      final data = jsonDecode(content) as Map<String, dynamic>;
      return data['relayUrl'] as String?;
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
}
