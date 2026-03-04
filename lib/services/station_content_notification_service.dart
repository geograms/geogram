/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import '../models/update_notification.dart';
import '../util/event_bus.dart';
import 'log_service.dart';
import 'station_service.dart';

/// Listens for station UPDATE notifications for blog, events, and places,
/// and fires NowItemEvents so they appear in the Now activity feed.
class StationContentNotificationService {
  static final StationContentNotificationService _instance =
      StationContentNotificationService._internal();
  factory StationContentNotificationService() => _instance;
  StationContentNotificationService._internal();

  final StationService _stationService = StationService();
  StreamSubscription<UpdateNotification>? _updateSubscription;

  /// Initialize the service and start listening
  void initialize() {
    _setupUpdateListener();
    LogService().log('StationContentNotificationService initialized');
  }

  /// Set up listener for UPDATE notifications
  void _setupUpdateListener() {
    _updateSubscription?.cancel();

    final updates = _stationService.updates;
    if (updates != null) {
      _updateSubscription = updates.listen(_handleUpdateNotification);
      LogService()
          .log('StationContentNotificationService: Listening for updates');
    }
  }

  /// Reconnect to the update stream (e.g. after station reconnection)
  void reconnect() {
    _setupUpdateListener();
  }

  /// Handle incoming UPDATE notification
  void _handleUpdateNotification(UpdateNotification update) {
    switch (update.appType) {
      case 'blog':
        _handleBlogUpdate(update);
        break;
      case 'events':
        _handleEventUpdate(update);
        break;
      case 'places':
        _handlePlaceUpdate(update);
        break;
    }
  }

  void _handleBlogUpdate(UpdateNotification update) {
    final postId = update.path;
    EventBus().fire(NowItemEvent(
      id: 'blog:$postId:${DateTime.now().toIso8601String()}',
      appType: 'blog',
      sourceId: postId,
      sourceName: update.callsign,
      callsign: update.callsign,
      summary: 'New blog post',
      priority: NowPriority.blog,
    ));
    LogService().log(
        'StationContentNotificationService: Blog update ${update.callsign}/$postId');
  }

  void _handleEventUpdate(UpdateNotification update) {
    final eventId = update.path;
    EventBus().fire(NowItemEvent(
      id: 'event:$eventId:${DateTime.now().toIso8601String()}',
      appType: 'events',
      sourceId: eventId,
      sourceName: eventId,
      callsign: update.callsign,
      summary: 'Event update',
      priority: NowPriority.event,
    ));
    LogService().log(
        'StationContentNotificationService: Event update ${update.callsign}/$eventId');
  }

  void _handlePlaceUpdate(UpdateNotification update) {
    final placeId = update.path;
    EventBus().fire(NowItemEvent(
      id: 'place:$placeId:${DateTime.now().toIso8601String()}',
      appType: 'places',
      sourceId: placeId,
      sourceName: placeId,
      callsign: update.callsign,
      summary: 'New place',
      priority: NowPriority.routine,
    ));
    LogService().log(
        'StationContentNotificationService: Place update ${update.callsign}/$placeId');
  }

  void dispose() {
    _updateSubscription?.cancel();
  }
}
