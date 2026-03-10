/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * NowNotificationBridge — mirrors the Now activity feed to Android/iOS
 * notification tray.  Subscribes to NowService.itemsStream and diffs
 * against the previously-shown set:  new unread → show, removed/read → cancel.
 */

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../models/now_item.dart';
import '../services/dm_notification_service.dart';
import '../services/notification_service.dart';
import '../services/now_service.dart';
import '../services/log_service.dart';

class NowNotificationBridge {
  static final NowNotificationBridge _instance =
      NowNotificationBridge._internal();
  factory NowNotificationBridge() => _instance;
  NowNotificationBridge._internal();

  static const String _messageGroupKey = 'geogram_messages';
  static const int _summaryNotificationId = 900100;
  static const int _maxSummaryLines = 10;

  bool _initialized = false;
  StreamSubscription<List<NowItem>>? _subscription;

  /// IDs of items that were present at initialization (don't notify for these)
  final Set<String> _bootstrapIds = {};

  /// Map of currently-shown notification IDs → NowItem id
  final Map<int, String> _activeNotifications = {};

  /// Summary lines keyed by notification ID so removals stay in sync.
  final Map<int, String> _summaryLines = {};

  void initialize() {
    if (_initialized) return;

    // Snapshot current items so we don't show notifications for pre-existing items
    for (final item in NowService().items) {
      _bootstrapIds.add(item.id);
    }

    _subscription = NowService().itemsStream.listen(_onItemsChanged);
    _initialized = true;
    LogService().log('NowNotificationBridge initialized');
  }

  void _onItemsChanged(List<NowItem> currentItems) {
    final settings = NotificationService().getSettings();
    if (!settings.enableNotifications || !settings.notifyNewMessages) {
      // Notifications disabled — cancel all and return
      _cancelAll();
      return;
    }

    final currentIds = <String>{};
    for (final item in currentItems) {
      currentIds.add(item.id);
    }

    // --- Cancel notifications for removed or newly-read items ---
    final toCancel = <int>[];
    for (final entry in _activeNotifications.entries) {
      final itemId = entry.value;
      final item = currentItems.where((i) => i.id == itemId).firstOrNull;
      if (item == null || item.isRead) {
        toCancel.add(entry.key);
      }
    }
    for (final nid in toCancel) {
      DMNotificationService().cancelNotification(nid);
      _activeNotifications.remove(nid);
      _summaryLines.remove(nid);
    }

    // --- Show notifications for new unread items (priority <= 2 only) ---
    for (final item in currentItems) {
      if (item.isRead) continue;
      if (_bootstrapIds.contains(item.id)) continue;
      final effectivePriority = NowService().getEffectivePriority(item);
      if (effectivePriority > 2) continue; // Only popup for urgent/attention

      final nid = _notificationId(item.id);
      if (_activeNotifications.containsKey(nid)) continue;

      _showNotification(item, nid);
      _activeNotifications[nid] = item.id;
    }

    // Update summary
    if (_activeNotifications.isNotEmpty) {
      _showSummaryNotification();
    } else {
      DMNotificationService().cancelNotification(_summaryNotificationId);
    }
  }

  Future<void> _showNotification(NowItem item, int nid) async {
    final title = _titleFor(item);
    final body = _bodyFor(item);
    final payload = _payloadFor(item);
    final channelInfo = _channelFor(item);

    final androidDetails = AndroidNotificationDetails(
      channelInfo.id,
      channelInfo.name,
      channelDescription: channelInfo.description,
      importance: channelInfo.importance,
      priority: channelInfo.importance == Importance.max
          ? Priority.max
          : Priority.high,
      enableVibration: true,
      groupKey: _messageGroupKey,
    );

    final iosDetails = const DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    final notificationDetails = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await DMNotificationService().showNotification(
      nid,
      title,
      body,
      notificationDetails,
      payload: payload,
    );

    _summaryLines[nid] = '$title: $body';

    LogService().log(
      'NowNotificationBridge: Showed notification for ${item.appType}:${item.sourceId}',
    );
  }

  // ---- Title / body / payload per type ----

  String _titleFor(NowItem item) {
    switch (item.appType) {
      case 'dm':
        return item.callsign;
      case 'chat':
        return '${item.callsign} \u00b7 ${item.sourceName}';
      case 'irc':
        return 'IRC: ${item.sourceName}';
      case 'telegram':
        return 'Telegram: ${item.sourceName}';
      case 'aprs':
        return 'APRS: ${item.callsign}';
      case 'email':
        return 'Email from ${item.callsign}';
      case 'alert':
        return 'Alert: ${item.sourceName}';
      case 'blog':
        return 'Blog: ${item.sourceName}';
      case 'events':
        return 'Event: ${item.sourceName}';
      case 'places':
        return 'Place: ${item.sourceName}';
      default:
        return item.sourceName;
    }
  }

  String _bodyFor(NowItem item) => item.summary;

  String _payloadFor(NowItem item) {
    switch (item.appType) {
      case 'dm':
        return 'dm:${item.sourceId}';
      case 'email':
        return 'email:${item.sourceId}';
      case 'chat':
        return 'chat:${item.sourceId}';
      default:
        // Generic Now handler: "now:appType|sourceId|sourceName"
        return 'now:${item.appType}|${item.sourceId}|${item.sourceName}';
    }
  }

  // ---- Channel mapping ----

  _ChannelInfo _channelFor(NowItem item) {
    switch (item.appType) {
      case 'dm':
        return const _ChannelInfo(
          id: 'dm_channel',
          name: 'Direct Messages',
          description: 'Notifications for direct messages',
          importance: Importance.high,
        );
      case 'chat':
      case 'irc':
      case 'telegram':
      case 'aprs':
        return const _ChannelInfo(
          id: 'chat_channel',
          name: 'Chat Rooms',
          description: 'Notifications for chat rooms',
          importance: Importance.high,
        );
      case 'email':
        return const _ChannelInfo(
          id: 'email_channel',
          name: 'Email',
          description: 'Notifications for incoming email',
          importance: Importance.high,
        );
      case 'alert':
        return const _ChannelInfo(
          id: 'alert_channel',
          name: 'Alerts',
          description: 'Notifications for alerts',
          importance: Importance.max,
        );
      default:
        return const _ChannelInfo(
          id: 'activity_channel',
          name: 'Activity',
          description: 'Notifications for activity feed items',
          importance: Importance.defaultImportance,
        );
    }
  }

  // ---- Notification ID ----

  int _notificationId(String itemId) => 10000 + itemId.hashCode.abs() % 80000;

  // ---- Summary notification ----

  Future<void> _showSummaryNotification() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    if (_summaryLines.isEmpty) return;

    final lines = _summaryLines.values.toList();
    final visibleLines = lines.length > _maxSummaryLines
        ? lines.sublist(lines.length - _maxSummaryLines)
        : lines;
    final totalCount = _summaryLines.length;
    final inboxStyle = InboxStyleInformation(
      visibleLines,
      contentTitle: 'Messages ($totalCount)',
      summaryText: '$totalCount total',
    );

    final androidDetails = AndroidNotificationDetails(
      'messages_summary',
      'Messages',
      channelDescription: 'Summary of recent messages',
      importance: Importance.low,
      priority: Priority.low,
      enableVibration: false,
      playSound: false,
      styleInformation: inboxStyle,
      groupKey: _messageGroupKey,
      setAsGroupSummary: true,
      groupAlertBehavior: GroupAlertBehavior.summary,
    );

    final notificationDetails = NotificationDetails(android: androidDetails);

    await DMNotificationService().showNotification(
      _summaryNotificationId,
      'Geogram',
      '$totalCount new messages',
      notificationDetails,
      payload: 'nav:devices',
    );
  }

  void _cancelAll() {
    for (final nid in _activeNotifications.keys) {
      DMNotificationService().cancelNotification(nid);
    }
    DMNotificationService().cancelNotification(_summaryNotificationId);
    _activeNotifications.clear();
    _summaryLines.clear();
  }

  void dispose() {
    _subscription?.cancel();
    _cancelAll();
  }
}

class _ChannelInfo {
  final String id;
  final String name;
  final String description;
  final Importance importance;

  const _ChannelInfo({
    required this.id,
    required this.name,
    required this.description,
    required this.importance,
  });
}
