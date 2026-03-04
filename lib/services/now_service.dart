/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import '../models/now_item.dart';
import '../util/event_bus.dart';
import 'config_service.dart';
import 'log_service.dart';

/// Singleton service for the "Now" activity feed.
/// Subscribes only to NowItemEvent via EventBus — any app/service that
/// wants to appear in the Now panel simply fires a NowItemEvent.
class NowService {
  static final NowService _instance = NowService._internal();
  factory NowService() => _instance;
  NowService._internal();

  static const int _maxItems = 200;
  static const int _maxReadIds = 500;

  final List<NowItem> _items = [];
  EventSubscription<NowItemEvent>? _subscription;
  EventSubscription<AlertReceivedEvent>? _alertSubscription;
  EventSubscription<EmailNotificationEvent>? _emailSubscription;
  EventSubscription<NowGroupRemoveEvent>? _removeSubscription;
  EventSubscription<BlogPostPublishedEvent>? _blogSubscription;
  EventSubscription<EventCreatedEvent>? _eventSubscription;
  EventSubscription<PlaceCreatedEvent>? _placeSubscription;
  bool _initialized = false;
  Timer? _expiryTimer;

  final _itemsController = StreamController<List<NowItem>>.broadcast();
  final _unreadCountController = StreamController<int>.broadcast();

  /// Whether the Now feed is currently visible to the user.
  /// When true, new items are auto-marked as read and unreadCount reports 0.
  bool _feedVisible = false;
  bool get feedVisible => _feedVisible;
  set feedVisible(bool value) {
    if (_feedVisible == value) return;
    _feedVisible = value;
    if (value) markAllAsRead();
    _broadcast();
  }

  /// Stream of feed items (sorted by priority then timestamp)
  Stream<List<NowItem>> get itemsStream => _itemsController.stream;

  /// Stream of unread count (for badge)
  Stream<int> get unreadCountStream => _unreadCountController.stream;

  /// Current items sorted by priority then newest first
  List<NowItem> get items {
    final sorted = List<NowItem>.from(_items);
    sorted.sort((a, b) {
      final p = a.priority.compareTo(b.priority);
      if (p != 0) return p;
      return b.timestamp.compareTo(a.timestamp);
    });
    return sorted;
  }

  /// Current unread count (0 when feed is visible)
  int get unreadCount =>
      _feedVisible ? 0 : _items.where((i) => !i.isRead).length;

  // ---- Group settings ----

  Map<String, NowGroupSettings> _groupSettings = {};

  void _loadGroupSettings() {
    final raw = ConfigService()
        .getNestedValue('now.groupSettings', <String, dynamic>{});
    if (raw is Map) {
      _groupSettings = {};
      for (final entry in raw.entries) {
        try {
          _groupSettings[entry.key as String] =
              NowGroupSettings.fromJson(Map<String, dynamic>.from(entry.value as Map));
        } catch (_) {}
      }
    }
  }

  void _saveGroupSettings() {
    final map = <String, dynamic>{};
    for (final entry in _groupSettings.entries) {
      map[entry.key] = entry.value.toJson();
    }
    ConfigService().setNestedValue('now.groupSettings', map);
  }

  /// Resolve group settings: "appType:sourceId" → "appType" → "_default" → hardcoded
  NowGroupSettings getGroupSettings(String appType, String sourceId) {
    final specific = _groupSettings['$appType:$sourceId'];
    if (specific != null) return specific;
    final byType = _groupSettings[appType];
    if (byType != null) return byType;
    final defaults = _groupSettings['_default'];
    if (defaults != null) return defaults;
    return const NowGroupSettings();
  }

  /// Set group settings for a key (e.g. "chat", "chat:general", "_default")
  void setGroupSettings(String key, NowGroupSettings settings) {
    _groupSettings[key] = settings;
    _saveGroupSettings();
    _enforceGroupLimits();
    _broadcast();
  }

  /// Remove override for a key, falling back to parent
  void resetGroupSettings(String key) {
    _groupSettings.remove(key);
    _saveGroupSettings();
    _broadcast();
  }

  /// All group settings (for debug API)
  Map<String, NowGroupSettings> get allGroupSettings =>
      Map.unmodifiable(_groupSettings);

  // ---- Two-level grouped items ----

  /// Returns items grouped as {appType: {sourceId: [items]}}
  /// Each sub-list is capped to maxItems, expired items removed, sorted newest first
  Map<String, Map<String, List<NowItem>>> get groupedItems {
    final now = DateTime.now();
    final result = <String, Map<String, List<NowItem>>>{};

    // Build the two-level map
    for (final item in _items) {
      final settings = getGroupSettings(item.appType, item.sourceId);

      // Skip expired
      if (settings.expiryMinutes > 0) {
        if (now.difference(item.timestamp).inMinutes > settings.expiryMinutes) {
          continue;
        }
      }

      result
          .putIfAbsent(item.appType, () => <String, List<NowItem>>{})
          .putIfAbsent(item.sourceId, () => <NowItem>[])
          .add(item);
    }

    // Cap at maxItems (keep newest), then sort chronologically (oldest first)
    for (final appType in result.keys) {
      for (final sourceId in result[appType]!.keys) {
        final list = result[appType]![sourceId]!;
        // Sort newest first to pick the most recent N items
        list.sort((a, b) => b.timestamp.compareTo(a.timestamp));
        final settings = getGroupSettings(appType, sourceId);
        final capped = list.length > settings.maxItems
            ? list.sublist(0, settings.maxItems)
            : list;
        // Now sort chronologically (oldest first) for display
        capped.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        result[appType]![sourceId] = capped;
      }
    }

    return result;
  }

  /// Initialize the service
  void initialize() {
    if (_initialized) return;
    _loadReadState();
    _loadMutedSources();
    _loadGroupSettings();
    _subscription = EventBus().on<NowItemEvent>(_handleEvent);

    // Also subscribe to alert and email events to convert them to NowItemEvents
    _alertSubscription = EventBus().on<AlertReceivedEvent>((event) {
      final severity = event.severity.toLowerCase();
      final priority = (severity == 'emergency' || severity == 'urgent')
          ? NowPriority.alertUrgent
          : NowPriority.alertAttention;
      _handleEvent(NowItemEvent(
        id: 'alert:${event.eventId}',
        appType: 'alert',
        sourceId: event.folderName,
        sourceName: event.folderName,
        callsign: event.senderCallsign,
        summary: event.content.length > 100
            ? '${event.content.substring(0, 100)}...'
            : event.content,
        priority: priority,
      ));
    });

    _emailSubscription = EventBus().on<EmailNotificationEvent>((event) {
      _handleEvent(NowItemEvent(
        id: 'email:${event.threadId ?? DateTime.now().toIso8601String()}',
        appType: 'email',
        sourceId: event.threadId ?? '',
        sourceName: event.recipient ?? 'Email',
        callsign: event.recipient ?? '',
        summary: event.message,
        priority: NowPriority.email,
      ));
    });

    // Subscribe to blog post events
    _blogSubscription = EventBus().on<BlogPostPublishedEvent>((event) {
      _handleEvent(NowItemEvent(
        id: 'blog:${event.postId}',
        appType: 'blog',
        sourceId: event.postId,
        sourceName: event.author,
        callsign: event.author,
        summary: event.title,
        priority: NowPriority.blog,
      ));
    });

    // Subscribe to event creation events
    _eventSubscription = EventBus().on<EventCreatedEvent>((event) {
      _handleEvent(NowItemEvent(
        id: 'event:${event.eventId}',
        appType: 'events',
        sourceId: event.eventId,
        sourceName: event.title,
        callsign: event.author,
        summary: event.title,
        priority: NowPriority.event,
      ));
    });

    // Subscribe to place creation events
    _placeSubscription = EventBus().on<PlaceCreatedEvent>((event) {
      _handleEvent(NowItemEvent(
        id: 'place:${event.placeId}',
        appType: 'places',
        sourceId: event.placeId,
        sourceName: event.name,
        callsign: event.author,
        summary: event.name,
        priority: NowPriority.routine,
      ));
    });

    // Subscribe to group removal events (e.g. leaving an IRC channel)
    _removeSubscription = EventBus().on<NowGroupRemoveEvent>((event) {
      removeGroup(event.appType, event.sourceId);
    });

    // Periodic expiry pruning every 60 seconds
    _expiryTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      _pruneExpired();
    });

    _initialized = true;
    LogService().log('NowService initialized');
  }

  /// Remove all items for a given appType:sourceId group
  void removeGroup(String appType, String sourceId) {
    final before = _items.length;
    _items.removeWhere((i) => i.appType == appType && i.sourceId == sourceId);
    if (_items.length != before) {
      _broadcast();
      LogService().log('NowService: Removed group $appType:$sourceId');
    }
  }

  void _handleEvent(NowItemEvent event) {
    // Skip if source is muted
    if (isSourceMuted(event.appType, event.sourceId)) {
      return;
    }

    // Skip duplicates
    if (_items.any((i) => i.id == event.id)) {
      return;
    }

    final item = NowItem.fromEvent(event);

    // Auto-read if feed is visible, otherwise check persisted read state
    if (_feedVisible) {
      item.isRead = true;
      final readIds = _getReadIds()..add(item.id);
      _saveReadIds(readIds);
    } else {
      final readIds = _getReadIds();
      if (readIds.contains(item.id)) {
        item.isRead = true;
      }
    }

    _items.insert(0, item);

    // Enforce per-group limits for this item's group
    _enforceGroupLimit(event.appType, event.sourceId);

    // Cap at global max items (remove oldest)
    while (_items.length > _maxItems) {
      _items.removeLast();
    }

    _broadcast();
    LogService().log(
      'NowService: Added ${event.appType} item from ${event.callsign} (priority ${event.priority})',
    );
  }

  /// Enforce maxItems for a specific appType:sourceId group
  void _enforceGroupLimit(String appType, String sourceId) {
    final settings = getGroupSettings(appType, sourceId);
    final groupItems = _items
        .where((i) => i.appType == appType && i.sourceId == sourceId)
        .toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

    if (groupItems.length > settings.maxItems) {
      final toRemove = groupItems.sublist(settings.maxItems);
      for (final item in toRemove) {
        _items.remove(item);
      }
    }
  }

  /// Enforce maxItems for all groups (called when settings change)
  void _enforceGroupLimits() {
    final groups = <String, List<NowItem>>{};
    for (final item in _items) {
      final key = '${item.appType}:${item.sourceId}';
      groups.putIfAbsent(key, () => []).add(item);
    }
    for (final entry in groups.entries) {
      final parts = entry.key.split(':');
      final appType = parts[0];
      final sourceId = parts.sublist(1).join(':');
      _enforceGroupLimit(appType, sourceId);
    }
  }

  /// Remove expired items based on per-group expiryMinutes
  void _pruneExpired() {
    final now = DateTime.now();
    final before = _items.length;
    _items.removeWhere((item) {
      final settings = getGroupSettings(item.appType, item.sourceId);
      if (settings.expiryMinutes <= 0) return false;
      return now.difference(item.timestamp).inMinutes > settings.expiryMinutes;
    });
    if (_items.length != before) {
      _broadcast();
      LogService().log(
        'NowService: Pruned ${before - _items.length} expired items',
      );
    }
  }

  // ---- Muting ----

  Set<String> _mutedSources = {};

  void _loadMutedSources() {
    final list =
        ConfigService().getNestedValue('now.mutedSources', <dynamic>[]) as List;
    _mutedSources = Set<String>.from(list);
  }

  void _saveMutedSources() {
    ConfigService()
        .setNestedValue('now.mutedSources', _mutedSources.toList());
  }

  bool isSourceMuted(String appType, String sourceId) {
    return _mutedSources.contains('$appType:$sourceId');
  }

  void toggleSourceMute(String appType, String sourceId) {
    final key = '$appType:$sourceId';
    if (_mutedSources.contains(key)) {
      _mutedSources.remove(key);
      LogService().log('NowService: Unmuted $key');
    } else {
      _mutedSources.add(key);
      // Remove existing items from this source
      _items.removeWhere((i) => i.appType == appType && i.sourceId == sourceId);
      LogService().log('NowService: Muted $key');
    }
    _saveMutedSources();
    _broadcast();
  }

  // ---- Read state ----

  Set<String> _getReadIds() {
    final list =
        ConfigService().getNestedValue('now.readItems', <dynamic>[]) as List;
    return Set<String>.from(list);
  }

  void _loadReadState() {
    final readIds = _getReadIds();
    for (final item in _items) {
      if (readIds.contains(item.id)) {
        item.isRead = true;
      }
    }
  }

  void _saveReadIds(Set<String> readIds) {
    // Cap at max
    final list = readIds.toList();
    if (list.length > _maxReadIds) {
      list.removeRange(0, list.length - _maxReadIds);
    }
    ConfigService().setNestedValue('now.readItems', list);
  }

  void markAsRead(String itemId) {
    final item = _items.where((i) => i.id == itemId).firstOrNull;
    if (item != null && !item.isRead) {
      item.isRead = true;
      final readIds = _getReadIds()..add(itemId);
      _saveReadIds(readIds);
      _broadcast();
    }
  }

  void markAllAsRead() {
    bool changed = false;
    final readIds = _getReadIds();
    for (final item in _items) {
      if (!item.isRead) {
        item.isRead = true;
        readIds.add(item.id);
        changed = true;
      }
    }
    if (changed) {
      _saveReadIds(readIds);
      _broadcast();
    }
  }

  // ---- Clear (for debug) ----

  void clearAll() {
    _items.clear();
    _broadcast();
    LogService().log('NowService: Cleared all items');
  }

  // ---- Internal ----

  void _broadcast() {
    _itemsController.add(items);
    _unreadCountController.add(unreadCount);
  }

  void dispose() {
    _subscription?.cancel();
    _alertSubscription?.cancel();
    _emailSubscription?.cancel();
    _blogSubscription?.cancel();
    _eventSubscription?.cancel();
    _placeSubscription?.cancel();
    _removeSubscription?.cancel();
    _expiryTimer?.cancel();
    _itemsController.close();
    _unreadCountController.close();
  }
}
