/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import '../util/event_bus.dart';

/// Per-group settings for the Now activity feed (max items & expiry)
class NowGroupSettings {
  final int maxItems;
  final int expiryMinutes; // 0 = never expire
  final int? priorityOverride; // null = use item's own priority, 1-10 = override
  final bool pinned; // true = card always sorts to top

  static const int defaultMaxItems = 5;
  static const int defaultExpiryMinutes = 1440; // 24h

  const NowGroupSettings({
    this.maxItems = defaultMaxItems,
    this.expiryMinutes = defaultExpiryMinutes,
    this.priorityOverride,
    this.pinned = false,
  });

  Map<String, dynamic> toJson() => {
        'maxItems': maxItems,
        'expiryMinutes': expiryMinutes,
        if (priorityOverride != null) 'priorityOverride': priorityOverride,
        'pinned': pinned,
      };

  factory NowGroupSettings.fromJson(Map<String, dynamic> json) =>
      NowGroupSettings(
        maxItems: json['maxItems'] as int? ?? defaultMaxItems,
        expiryMinutes: json['expiryMinutes'] as int? ?? defaultExpiryMinutes,
        priorityOverride: json['priorityOverride'] as int?,
        pinned: json['pinned'] as bool? ?? false,
      );
}

/// A stored activity feed item, created from a NowItemEvent
class NowItem {
  final String id;
  final String appType;
  final String sourceId;
  final String sourceName;
  final String callsign;
  final String summary;
  final int priority;
  final DateTime timestamp;
  bool isRead;

  NowItem({
    required this.id,
    required this.appType,
    required this.sourceId,
    required this.sourceName,
    required this.callsign,
    required this.summary,
    required this.priority,
    required this.timestamp,
    this.isRead = false,
  });

  NowItem.fromEvent(NowItemEvent event)
      : id = event.id,
        appType = event.appType,
        sourceId = event.sourceId,
        sourceName = event.sourceName,
        callsign = event.callsign,
        summary = event.summary,
        priority = event.priority,
        timestamp = event.timestamp,
        isRead = false;

  Map<String, dynamic> toJson() => {
        'id': id,
        'appType': appType,
        'sourceId': sourceId,
        'sourceName': sourceName,
        'callsign': callsign,
        'summary': summary,
        'priority': priority,
        'timestamp': timestamp.toIso8601String(),
        'isRead': isRead,
      };

  factory NowItem.fromJson(Map<String, dynamic> json) => NowItem(
        id: json['id'] as String,
        appType: json['appType'] as String,
        sourceId: json['sourceId'] as String,
        sourceName: json['sourceName'] as String? ?? '',
        callsign: json['callsign'] as String,
        summary: json['summary'] as String,
        priority: json['priority'] as int? ?? NowPriority.routine,
        timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ??
            DateTime.now(),
        isRead: json['isRead'] as bool? ?? false,
      );
}
