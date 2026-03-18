/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;

import '../models/blog_post.dart';
import '../models/chat_channel.dart';
import '../models/chat_message.dart';
import '../models/event.dart';
import '../models/place.dart';
import '../models/report.dart';
import '../models/station_activity_event.dart';
import '../models/monitored_task.dart';
import '../util/event_bus.dart';
import '../util/task_monitor_helpers.dart';
import 'app_service.dart';
import 'log_service.dart';
import 'profile_storage.dart';
import 'station_service.dart';

class QueuedStationActivity {
  final StationActivityEvent event;
  final String? stationUrl;
  final String? stationCallsign;
  final int retryCount;
  final DateTime queuedAt;
  final DateTime? nextAttemptAt;

  const QueuedStationActivity({
    required this.event,
    this.stationUrl,
    this.stationCallsign,
    this.retryCount = 0,
    required this.queuedAt,
    this.nextAttemptAt,
  });

  factory QueuedStationActivity.fromJson(Map<String, dynamic> json) {
    return QueuedStationActivity(
      event: StationActivityEvent.fromJson(
        (json['event'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
      stationUrl: json['station_url'] as String?,
      stationCallsign: json['station_callsign'] as String?,
      retryCount: json['retry_count'] as int? ?? 0,
      queuedAt:
          DateTime.tryParse(json['queued_at'] as String? ?? '') ??
          DateTime.now().toUtc(),
      nextAttemptAt: json['next_attempt_at'] != null
          ? DateTime.tryParse(json['next_attempt_at'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'event': event.toJson(),
    if (stationUrl != null) 'station_url': stationUrl,
    if (stationCallsign != null) 'station_callsign': stationCallsign,
    'retry_count': retryCount,
    'queued_at': queuedAt.toUtc().toIso8601String(),
    if (nextAttemptAt != null)
      'next_attempt_at': nextAttemptAt!.toUtc().toIso8601String(),
  };

  QueuedStationActivity copyWith({
    StationActivityEvent? event,
    String? stationUrl,
    String? stationCallsign,
    int? retryCount,
    DateTime? queuedAt,
    DateTime? nextAttemptAt,
    bool clearNextAttemptAt = false,
  }) {
    return QueuedStationActivity(
      event: event ?? this.event,
      stationUrl: stationUrl ?? this.stationUrl,
      stationCallsign: stationCallsign ?? this.stationCallsign,
      retryCount: retryCount ?? this.retryCount,
      queuedAt: queuedAt ?? this.queuedAt,
      nextAttemptAt: clearNextAttemptAt
          ? null
          : (nextAttemptAt ?? this.nextAttemptAt),
    );
  }
}

/// Publishes local creation activity to the preferred station and retries offline.
class StationActivityPublisherService {
  static final StationActivityPublisherService _instance =
      StationActivityPublisherService._internal();
  factory StationActivityPublisherService() => _instance;
  StationActivityPublisherService._internal();

  static const Duration _processInterval = Duration(seconds: 10);
  static const int _maxRetries = 10;
  static const int _baseBackoffSeconds = 3;
  static const int _maxBackoffSeconds = 120;

  final StationService _stationService = StationService();

  EventSubscription<ConnectionStateChangedEvent>? _connectionSubscription;
  EventSubscription<EventCreatedEvent>? _eventCreatedSubscription;
  MonitoredAsyncPeriodicTimer? _processingTimer;
  bool _initialized = false;
  bool _isProcessing = false;

  Future<void> initialize() async {
    if (_initialized || kIsWeb) {
      return;
    }

    _connectionSubscription ??= EventBus().on<ConnectionStateChangedEvent>((
      event,
    ) {
      if (event.connectionType == ConnectionType.station && event.isConnected) {
        unawaited(processQueue());
      }
    });
    _eventCreatedSubscription ??= EventBus().on<EventCreatedEvent>((event) {
      if (event.eventRecord is Event) {
        unawaited(publishEventRecord(event.eventRecord as Event));
      }
    });
    _processingTimer ??= MonitoredAsyncPeriodicTimer(
      id: 'activity_publisher.queue',
      name: 'Activity Queue',
      description: 'Processes station activity event queue',
      serviceName: 'StationActivityPublisherService',
      interval: _processInterval,
      priority: TaskPriority.normal,
      callback: (_) async => await processQueue(),
    );
    _initialized = true;
    LogService().log('StationActivityPublisherService initialized');
  }

  Future<void> dispose() async {
    _connectionSubscription?.cancel();
    _connectionSubscription = null;
    _eventCreatedSubscription?.cancel();
    _eventCreatedSubscription = null;
    _processingTimer?.cancel();
    _processingTimer = null;
    _initialized = false;
  }

  Future<void> publish(StationActivityEvent event) async {
    if (kIsWeb) {
      return;
    }

    await initialize();
    final targetStation =
        _stationService.getPreferredStation() ??
        _stationService.getConnectedStation();
    final queueEntry = QueuedStationActivity(
      event: event,
      stationUrl: targetStation?.url,
      stationCallsign: targetStation?.callsign,
      queuedAt: DateTime.now().toUtc(),
    );

    final queue = await _loadQueue();
    queue.removeWhere((queued) => queued.event.id == event.id);
    queue.add(queueEntry);
    await _saveQueue(queue);

    final connectedUrl = _stationService.getConnectedStation()?.url;
    if (connectedUrl != null &&
        (queueEntry.stationUrl == null ||
            queueEntry.stationUrl == connectedUrl)) {
      unawaited(processQueue());
    }
  }

  Future<void> processQueue() async {
    if (kIsWeb || _isProcessing) {
      return;
    }

    final storage = _rootStorage;
    if (storage == null) {
      return;
    }

    _isProcessing = true;
    try {
      final queue = await _loadQueue();
      if (queue.isEmpty) {
        return;
      }

      final connectedStation = _stationService.getConnectedStation();
      final preferredStation = _stationService.getPreferredStation();
      final fallbackStation = preferredStation ?? connectedStation;
      final now = DateTime.now().toUtc();
      final updatedQueue = <QueuedStationActivity>[];

      for (final item in queue) {
        if (item.nextAttemptAt != null && item.nextAttemptAt!.isAfter(now)) {
          updatedQueue.add(item);
          continue;
        }

        final targetUrl = item.stationUrl ?? fallbackStation?.url;
        if (targetUrl == null || targetUrl.isEmpty) {
          updatedQueue.add(item.copyWith(stationUrl: fallbackStation?.url));
          continue;
        }

        final sent = await _stationService.postActivityEvent(
          targetUrl,
          item.event,
        );
        if (sent) {
          continue;
        }

        final nextRetryCount = item.retryCount + 1;
        if (nextRetryCount > _maxRetries) {
          LogService().log(
            'StationActivityPublisherService: Dropping ${item.event.id} after $nextRetryCount attempts',
          );
          continue;
        }

        final backoffSeconds =
            (_baseBackoffSeconds * (1 << (nextRetryCount - 1))).clamp(
              1,
              _maxBackoffSeconds,
            );
        updatedQueue.add(
          item.copyWith(
            stationUrl: targetUrl,
            retryCount: nextRetryCount,
            nextAttemptAt: now.add(Duration(seconds: backoffSeconds)),
          ),
        );
      }

      await _saveQueue(updatedQueue);
    } finally {
      _isProcessing = false;
    }
  }

  Future<void> publishBlogPost(BlogPost post) async {
    if (!post.isPublished) {
      return;
    }

    try {
      await publish(
        StationActivityEvent.create(
          appType: 'blog',
          action: 'published',
          sourceId: post.id,
          sourceName: post.title,
          authorCallsign: post.author,
          authorNpub: _trimToNull(post.npub),
          summary: _summarizeText(
            post.description?.trim().isNotEmpty == true
                ? post.description!
                : post.title,
          ),
          date: post.timestamp,
          visibility: 'public',
          metadata: {
            if (post.tags.isNotEmpty) 'tags': post.tags,
            if (post.location != null && post.location!.isNotEmpty)
              'location': post.location,
          },
        ),
      );
    } catch (e) {
      LogService().log(
        'StationActivityPublisherService: Failed to publish blog activity: $e',
      );
    }
  }

  Future<void> publishEventRecord(Event event) async {
    final visibility = StationActivityEvent.normalizeVisibility(
      event.visibility,
    );
    if (visibility == 'private') {
      return;
    }

    try {
      await publish(
        StationActivityEvent.create(
          appType: 'events',
          action: 'created',
          sourceId: event.id,
          sourceName: event.title,
          authorCallsign: event.author,
          authorNpub: _trimToNull(event.npub),
          summary: _summarizeText(event.title),
          date: event.timestamp,
          visibility: visibility,
          allowedGroups: visibility == 'group' ? event.groupAccess : null,
          metadata: {
            if (event.locationName != null && event.locationName!.isNotEmpty)
              'location_name': event.locationName,
            if (event.startDate != null && event.startDate!.isNotEmpty)
              'start_date': event.startDate,
            if (event.endDate != null && event.endDate!.isNotEmpty)
              'end_date': event.endDate,
          },
        ),
      );
    } catch (e) {
      LogService().log(
        'StationActivityPublisherService: Failed to publish event activity: $e',
      );
    }
  }

  Future<void> publishPlace(Place place) async {
    final visibility = StationActivityEvent.normalizeVisibility(
      place.visibility,
    );
    if (visibility == 'private') {
      return;
    }

    try {
      await publish(
        StationActivityEvent.create(
          appType: 'places',
          action: 'created',
          sourceId: place.placeFolderName,
          sourceName: place.name,
          authorCallsign: place.author,
          authorNpub: _trimToNull(place.metadataNpub),
          summary: _summarizeText(
            place.description.trim().isNotEmpty
                ? place.description
                : place.name,
          ),
          date: place.created,
          visibility: visibility,
          allowedGroups: visibility == 'restricted'
              ? place.allowedGroups
              : null,
          metadata: {
            'latitude': place.latitude,
            'longitude': place.longitude,
            if (place.type != null && place.type!.isNotEmpty)
              'type': place.type,
          },
        ),
      );
    } catch (e) {
      LogService().log(
        'StationActivityPublisherService: Failed to publish place activity: $e',
      );
    }
  }

  Future<void> publishReport(Report report) async {
    try {
      final title = report.getTitle('EN');
      await publish(
        StationActivityEvent.create(
          appType: 'alerts',
          action: 'posted',
          sourceId: report.folderName,
          sourceName: title,
          authorCallsign: report.author,
          authorNpub: _trimToNull(report.npub),
          summary: _summarizeText(title),
          date: report.created,
          visibility: 'public',
          metadata: {
            'severity': report.severity.name,
            'type': report.type,
            'latitude': report.latitude,
            'longitude': report.longitude,
          },
        ),
      );
    } catch (e) {
      LogService().log(
        'StationActivityPublisherService: Failed to publish alert activity: $e',
      );
    }
  }

  Future<void> publishChatMessage(
    ChatChannel channel,
    ChatMessage message, {
    required String currentCallsign,
    String? currentNpub,
    List<String>? allowedNpubs,
  }) async {
    if (channel.isDirect) {
      return;
    }

    final normalizedCurrentCallsign = currentCallsign.trim().toUpperCase();
    final normalizedCurrentNpub = _trimToNull(currentNpub);
    final authorNpub = _trimToNull(message.npub) ?? normalizedCurrentNpub;
    final isOwnMessage =
        message.author.trim().toUpperCase() == normalizedCurrentCallsign ||
        (authorNpub != null && authorNpub == normalizedCurrentNpub);
    if (!isOwnMessage) {
      return;
    }

    final config = channel.config;
    final allowedGroups = <String>[
      if (_trimToNull(config?.groupId) != null) config!.groupId!.trim(),
    ];
    final resolvedAllowedNpubs = _mergeAllowedNpubs([
      ...?allowedNpubs,
      ..._collectChannelNpubs(config),
    ]);

    String visibility;
    if ((config?.visibility ?? '').toUpperCase() == 'PUBLIC' ||
        channel.isPublic) {
      visibility = 'public';
    } else if (allowedGroups.isNotEmpty) {
      visibility = 'group';
    } else if (resolvedAllowedNpubs.isNotEmpty) {
      visibility = 'restricted';
    } else {
      return;
    }

    try {
      await publish(
        StationActivityEvent.create(
          appType: 'chat',
          action: 'message',
          sourceId: '${channel.id}:${message.timestamp}:${message.author}',
          sourceName: channel.name,
          authorCallsign: message.author,
          authorNpub: authorNpub,
          summary: _summarizeChatMessage(message),
          date: message.timestamp,
          visibility: visibility,
          allowedGroups: allowedGroups,
          allowedNpubs: visibility == 'public' ? null : resolvedAllowedNpubs,
          metadata: {
            'channel_id': channel.id,
            'channel_name': channel.name,
            'channel_visibility':
                config?.visibility ??
                (channel.isPublic ? 'PUBLIC' : 'RESTRICTED'),
          },
        ),
      );
    } catch (e) {
      LogService().log(
        'StationActivityPublisherService: Failed to publish chat activity: $e',
      );
    }
  }

  ProfileStorage? get _rootStorage => AppService().profileStorage;

  Future<List<QueuedStationActivity>> _loadQueue() async {
    final storage = _rootStorage;
    if (storage == null) {
      return const [];
    }

    try {
      final content = await storage.readString('extra/activity/pending.json');
      if (content == null || content.trim().isEmpty) {
        return <QueuedStationActivity>[];
      }
      final decoded = jsonDecode(content) as List<dynamic>;
      return decoded
          .map(
            (item) => QueuedStationActivity.fromJson(
              (item as Map).cast<String, dynamic>(),
            ),
          )
          .toList();
    } catch (e) {
      LogService().log(
        'StationActivityPublisherService: Failed to load queue: $e',
      );
      return <QueuedStationActivity>[];
    }
  }

  Future<void> _saveQueue(List<QueuedStationActivity> queue) async {
    final storage = _rootStorage;
    if (storage == null) {
      return;
    }

    try {
      await storage.createDirectory('extra/activity');
      final content = const JsonEncoder.withIndent(
        '  ',
      ).convert(queue.map((item) => item.toJson()).toList());
      await storage.writeString('extra/activity/pending.json', content);
    } catch (e) {
      LogService().log(
        'StationActivityPublisherService: Failed to save queue: $e',
      );
    }
  }

  static String _summarizeText(String text, {int maxLength = 160}) {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) {
      return '';
    }
    if (normalized.length <= maxLength) {
      return normalized;
    }
    return '${normalized.substring(0, maxLength - 3).trimRight()}...';
  }

  static String _summarizeChatMessage(ChatMessage message) {
    final text = _summarizeText(message.content);
    if (text.isNotEmpty) {
      return text;
    }
    if (message.hasFile) {
      final filename =
          message.displayFileName ?? message.attachedFile ?? 'file';
      return _summarizeText('Shared file $filename');
    }
    if (message.hasVoice) {
      return 'Shared voice message';
    }
    if (message.hasLocation) {
      return 'Shared location';
    }
    return 'New chat message';
  }

  static String? _trimToNull(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    return trimmed;
  }

  static List<String> _collectChannelNpubs(ChatChannelConfig? config) {
    if (config == null) {
      return const [];
    }
    return _mergeAllowedNpubs([
      if (_trimToNull(config.owner) != null) config.owner!,
      ...config.admins,
      ...config.moderatorNpubs,
      ...config.members,
    ]);
  }

  static List<String> _mergeAllowedNpubs(List<String> npubs) {
    final merged = <String>[];
    final seen = <String>{};
    for (final npub in npubs) {
      final normalized = _trimToNull(npub);
      if (normalized == null || seen.contains(normalized)) {
        continue;
      }
      seen.add(normalized);
      merged.add(normalized);
    }
    return merged;
  }
}
