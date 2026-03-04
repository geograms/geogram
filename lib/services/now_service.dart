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
  bool _initialized = false;

  final _itemsController = StreamController<List<NowItem>>.broadcast();
  final _unreadCountController = StreamController<int>.broadcast();

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

  /// Current unread count
  int get unreadCount => _items.where((i) => !i.isRead).length;

  /// Initialize the service
  void initialize() {
    if (_initialized) return;
    _loadReadState();
    _loadMutedSources();
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

    _initialized = true;
    LogService().log('NowService initialized');
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

    // Check read state
    final readIds = _getReadIds();
    if (readIds.contains(item.id)) {
      item.isRead = true;
    }

    _items.insert(0, item);

    // Cap at max items (remove oldest)
    while (_items.length > _maxItems) {
      _items.removeLast();
    }

    _broadcast();
    LogService().log(
      'NowService: Added ${event.appType} item from ${event.callsign} (priority ${event.priority})',
    );
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
    _itemsController.close();
    _unreadCountController.close();
  }
}
