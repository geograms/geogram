/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import '../models/station_chat_room.dart';
import '../models/update_notification.dart';
import '../util/event_bus.dart';
import 'config_service.dart';
import 'station_cache_service.dart';
import 'station_service.dart';
import 'log_service.dart';

/// Service for tracking unread chat message notifications
class ChatNotificationService {
  static final ChatNotificationService _instance = ChatNotificationService._internal();
  factory ChatNotificationService() => _instance;
  ChatNotificationService._internal();

  final StationService _stationService = StationService();
  final RelayCacheService _cacheService = RelayCacheService();

  // Unread counts per room (roomId -> count)
  final Map<String, int> _unreadCounts = {};

  // Currently viewed room (messages here are marked as read)
  String? _currentRoomId;

  // Stream controller for notifying UI of changes
  final _notificationController = StreamController<Map<String, int>>.broadcast();

  // Subscription to update notifications
  StreamSubscription<UpdateNotification>? _updateSubscription;

  /// Stream of unread counts (roomId -> count)
  Stream<Map<String, int>> get unreadCountsStream => _notificationController.stream;

  /// Get current unread counts
  Map<String, int> get unreadCounts => Map.unmodifiable(_unreadCounts);

  /// Get total unread count across all rooms
  int get totalUnreadCount => _unreadCounts.values.fold(0, (sum, count) => sum + count);

  /// Get unread count for a specific room
  int getUnreadCount(String roomId) => _unreadCounts[roomId] ?? 0;

  /// Check if a room is muted
  bool isRoomMuted(String roomId) {
    final list = ConfigService().getNestedValue('chat.mutedRooms', <dynamic>[]) as List;
    return list.contains(roomId);
  }

  /// Get all muted room IDs
  Set<String> get mutedRooms {
    final list = ConfigService().getNestedValue('chat.mutedRooms', <dynamic>[]) as List;
    return Set<String>.from(list);
  }

  /// Toggle mute state for a room
  void toggleRoomMute(String roomId) {
    final list = ConfigService().getNestedValue('chat.mutedRooms', <dynamic>[]) as List;
    final muted = List<String>.from(list);
    if (muted.contains(roomId)) {
      muted.remove(roomId);
      LogService().log('ChatNotificationService: Unmuted room $roomId');
    } else {
      muted.add(roomId);
      // Clear any existing unread count for the newly muted room
      if (_unreadCounts.containsKey(roomId)) {
        _unreadCounts.remove(roomId);
        _notificationController.add(Map.from(_unreadCounts));
      }
      LogService().log('ChatNotificationService: Muted room $roomId');
    }
    ConfigService().setNestedValue('chat.mutedRooms', muted);
  }

  /// Initialize the service and start listening
  void initialize() {
    _setupUpdateListener();
    LogService().log('ChatNotificationService initialized');
  }

  /// Set up listener for UPDATE notifications
  void _setupUpdateListener() {
    _updateSubscription?.cancel();

    final updates = _stationService.updates;
    if (updates != null) {
      _updateSubscription = updates.listen(_handleUpdateNotification);
      LogService().log('ChatNotificationService: Listening for update notifications');
    }
  }

  /// Handle incoming UPDATE notification
  void _handleUpdateNotification(UpdateNotification update) {
    // Only handle chat updates
    if (update.appType != 'chat') {
      return;
    }

    final roomId = update.path;

    // If user is currently viewing this room, don't increment
    if (_currentRoomId == roomId) {
      LogService().log('ChatNotificationService: Update for current room $roomId (ignored)');
      return;
    }

    // If room is muted, skip notification and unread count
    if (isRoomMuted(roomId)) {
      LogService().log('ChatNotificationService: Update for muted room $roomId (skipped)');
      return;
    }

    // Increment unread count for this room
    _unreadCounts[roomId] = (_unreadCounts[roomId] ?? 0) + 1;
    LogService().log('ChatNotificationService: New message in $roomId (unread: ${_unreadCounts[roomId]})');

    unawaited(_notifyChatUpdate(update));

    // Notify listeners
    _notificationController.add(Map.from(_unreadCounts));
  }

  /// Sync all cached rooms in the background (called after station connects)
  Future<void> syncAllRooms() async {
    final station = _stationService.getPreferredStation();
    if (station == null || station.url.isEmpty) return;
    if (station.callsign == null || station.callsign!.isEmpty) return;

    final cacheKey = station.callsign!;
    final stationUrl = station.url;

    try {
      await _cacheService.initialize();
      final rooms = await _cacheService.loadChatRooms(cacheKey, stationUrl);
      if (rooms.isEmpty) {
        LogService().log('ChatNotificationService: No cached rooms to sync');
        return;
      }

      LogService().log('ChatNotificationService: Syncing ${rooms.length} rooms in background');
      for (final room in rooms) {
        await _syncRoomMessages(cacheKey, stationUrl, room.id);
        await _syncRoomModifications(cacheKey, stationUrl, room.id);
      }
      LogService().log('ChatNotificationService: Background sync complete');
    } catch (e) {
      LogService().log('ChatNotificationService: Background sync error: $e');
    }
  }

  /// Sync messages for a single room (fetch only new messages since last cached)
  Future<void> _syncRoomMessages(String cacheKey, String stationUrl, String roomId) async {
    try {
      final latestCached = await _cacheService.loadLatestMessage(cacheKey, roomId);
      DateTime? after;
      if (latestCached != null) {
        final parsed = DateTime.tryParse(latestCached.timestamp.replaceAll('_', ':'));
        if (parsed != null) {
          after = DateTime(parsed.year, parsed.month, parsed.day);
        }
      }

      final newMessages = await _stationService.fetchRoomMessages(
        stationUrl,
        roomId,
        limit: after == null ? 50 : 200,
        after: after,
      );

      if (newMessages.isNotEmpty) {
        await _cacheService.mergeMessages(cacheKey, roomId, newMessages);
        LogService().log('ChatNotificationService: Synced ${newMessages.length} messages for $roomId');
      }
    } catch (e) {
      LogService().log('ChatNotificationService: Failed to sync room $roomId: $e');
    }
  }

  /// Sync modifications (edits/deletes) for a room since last sync
  Future<void> _syncRoomModifications(String cacheKey, String stationUrl, String roomId) async {
    try {
      // Load last sync timestamp from config
      final configService = ConfigService();
      final configKey = 'chat_mod_sync_${cacheKey}_$roomId';
      final lastSyncStr = configService.get(configKey) as String?;
      DateTime? since;
      if (lastSyncStr != null && lastSyncStr.isNotEmpty) {
        since = DateTime.tryParse(lastSyncStr);
      }

      final modifications = await _stationService.fetchRoomModifications(
        stationUrl,
        roomId,
        since: since,
      );

      if (modifications.isEmpty) return;

      for (final mod in modifications) {
        final action = mod['action'] as String?;
        final timestamp = mod['timestamp'] as String?;
        final author = mod['author'] as String?;

        if (action == null || timestamp == null || author == null) continue;

        if (action == 'delete') {
          await _cacheService.removeMessage(cacheKey, roomId, timestamp, author);
        } else if (action == 'edit') {
          final newContent = mod['content'] as String?;
          if (newContent != null) {
            await _cacheService.updateMessage(cacheKey, roomId, timestamp, author, newContent);
          }
        }
      }

      // Store the current time as last sync
      configService.set(configKey, DateTime.now().toUtc().toIso8601String());
      LogService().log('ChatNotificationService: Applied ${modifications.length} modifications for $roomId');
    } catch (e) {
      LogService().log('ChatNotificationService: Failed to sync modifications for $roomId: $e');
    }
  }

  Future<void> _notifyChatUpdate(UpdateNotification update) async {
    final roomId = update.path;
    if (roomId.isEmpty) return;

    final resolved = await _resolveChatMessage(update);
    if (resolved == null) {
      LogService().log('ChatNotificationService: Unable to resolve message for $roomId');
      // Fire fallback NowItemEvent with generic content so the event isn't lost
      EventBus().fire(NowItemEvent(
        id: 'chat:$roomId:${DateTime.now().toIso8601String()}',
        appType: 'chat',
        sourceId: roomId,
        sourceName: roomId,
        callsign: update.callsign,
        summary: 'New message in $roomId',
        priority: NowPriority.chat,
      ));
      return;
    }

    // Fire NowItemEvent with resolved sender and content
    final roomName = await _getRoomName(roomId);
    EventBus().fire(NowItemEvent(
      id: 'chat:$roomId:${DateTime.now().toIso8601String()}',
      appType: 'chat',
      sourceId: roomId,
      sourceName: roomName ?? roomId,
      callsign: resolved.callsign,
      summary: resolved.content,
      priority: NowPriority.chat,
    ));

    // Cache the message so it's immediately available when the UI opens
    _cacheResolvedMessage(update, resolved);
  }

  /// Cache a resolved message from a notification so the UI has it immediately
  void _cacheResolvedMessage(
    UpdateNotification update,
    StationChatMessage resolved,
  ) {
    final station = _stationService.getPreferredStation();
    if (station == null || station.callsign == null || station.callsign!.isEmpty) return;

    final roomId = update.path;
    // Only cache when message has a signature to avoid unsigned duplicates
    if (!resolved.hasSignature) return;

    unawaited(_cacheService.mergeMessages(station.callsign!, roomId, [resolved]));
  }

  /// Try to get a friendly room name from cached rooms
  Future<String?> _getRoomName(String roomId) async {
    try {
      final station = _stationService.getPreferredStation();
      if (station == null || station.callsign == null || station.callsign!.isEmpty) return null;
      await _cacheService.initialize();
      final rooms = await _cacheService.loadChatRooms(station.callsign!, station.url);
      for (final room in rooms) {
        if (room.id == roomId) return room.name;
      }
    } catch (_) {}
    return null;
  }

  Future<StationChatMessage?> _resolveChatMessage(
    UpdateNotification update,
  ) async {
    final roomId = update.path;
    if (roomId.isEmpty) return null;

    final station = _stationService.getPreferredStation();
    if (station != null && station.url.isNotEmpty) {
      try {
        final messages = await _stationService.fetchRoomMessages(
          station.url,
          roomId,
          limit: 1,
          stationCallsign: station.callsign,
        );
        if (messages.isNotEmpty) {
          messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
          return messages.last;
        }
      } catch (e) {
        LogService().log('ChatNotificationService: Failed to fetch latest message: $e');
      }
    }

    try {
      await _cacheService.initialize();
      final candidateKeys = <String?>[
        update.callsign,
        station?.callsign,
        station?.name,
      ];
      for (final cacheKey in candidateKeys) {
        if (cacheKey == null || cacheKey.isEmpty) continue;
        final cached = await _cacheService.loadLatestMessage(cacheKey, roomId);
        if (cached != null && cached.hasSignature) {
          return StationChatMessage(
            roomId: roomId,
            callsign: cached.author,
            content: cached.content,
            timestamp: cached.timestamp,
            metadata: cached.metadata,
            reactions: cached.reactions,
            npub: cached.npub,
            signature: cached.signature,
            verified: cached.isVerified,
            hasSignature: cached.hasSignature,
          );
        }
      }
    } catch (e) {
      LogService().log('ChatNotificationService: Failed to load cached message: $e');
    }

    return null;
  }

  /// Set the currently viewed room (clears its unread count)
  void setCurrentRoom(String? roomId) {
    _currentRoomId = roomId;

    if (roomId != null && _unreadCounts.containsKey(roomId)) {
      _unreadCounts.remove(roomId);
      LogService().log('ChatNotificationService: Marked $roomId as read');
      _notificationController.add(Map.from(_unreadCounts));
    }
  }

  /// Mark a specific room as read
  void markAsRead(String roomId) {
    if (_unreadCounts.containsKey(roomId)) {
      _unreadCounts.remove(roomId);
      LogService().log('ChatNotificationService: Marked $roomId as read');
      _notificationController.add(Map.from(_unreadCounts));
    }
  }

  /// Mark all rooms as read
  void markAllAsRead() {
    if (_unreadCounts.isNotEmpty) {
      _unreadCounts.clear();
      LogService().log('ChatNotificationService: Marked all rooms as read');
      _notificationController.add(Map.from(_unreadCounts));
    }
  }

  /// Re-connect to station updates (call after station reconnection)
  void reconnect() {
    _setupUpdateListener();
  }

  /// Dispose resources
  void dispose() {
    _updateSubscription?.cancel();
    _notificationController.close();
  }
}
