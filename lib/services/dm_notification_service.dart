/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/foundation.dart';
import '../util/event_bus.dart';
import '../services/notification_service.dart';
import '../services/profile_service.dart';
import '../services/log_service.dart';

/// Service for showing local push notifications for direct messages
class DMNotificationService {
  static final DMNotificationService _instance = DMNotificationService._internal();
  factory DMNotificationService() => _instance;
  DMNotificationService._internal();

  final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();
  EventSubscription<DirectMessageReceivedEvent>? _dmEventSubscription;
  bool _initialized = false;

  /// Initialize the notification service
  Future<void> initialize() async {
    if (_initialized) return;

    // Only initialize on mobile platforms (Android/iOS)
    if (!_isMobilePlatform()) {
      LogService().log('DMNotificationService: Skipping initialization on non-mobile platform');
      _initialized = true;
      return;
    }

    try {
      await _initializeNotifications();
      _subscribeToEvents();
      _initialized = true;
      LogService().log('DMNotificationService initialized');
    } catch (e) {
      LogService().log('Error initializing DMNotificationService: $e');
    }
  }

  /// Check if running on mobile platform (Android or iOS)
  bool _isMobilePlatform() {
    return defaultTargetPlatform == TargetPlatform.android ||
           defaultTargetPlatform == TargetPlatform.iOS;
  }

  /// Initialize flutter_local_notifications
  Future<void> _initializeNotifications() async {
    // Android initialization settings
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');

    // iOS initialization settings
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    // Initialize plugin
    await _notificationsPlugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );

    // Request permissions for iOS
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await _notificationsPlugin
          .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(
            alert: true,
            badge: true,
            sound: true,
          );
    }

    // Request permissions for Android 13+
    if (defaultTargetPlatform == TargetPlatform.android) {
      await _notificationsPlugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    }

    LogService().log('DMNotificationService: Notifications initialized');
  }

  /// Subscribe to DirectMessageReceivedEvent
  void _subscribeToEvents() {
    _dmEventSubscription = EventBus().on<DirectMessageReceivedEvent>((event) {
      _handleIncomingDM(event);
    });
    LogService().log('DMNotificationService: Subscribed to DirectMessageReceivedEvent');
  }

  /// Handle incoming direct message
  Future<void> _handleIncomingDM(DirectMessageReceivedEvent event) async {
    if (!_initialized) return;

    // Check notification settings
    final settings = NotificationService().getSettings();
    if (!settings.enableNotifications || !settings.notifyNewMessages) {
      LogService().log('DMNotificationService: Notifications disabled in settings');
      return;
    }

    // Don't notify for messages we sent
    final myCallsign = ProfileService().getProfile().callsign;
    if (myCallsign.isEmpty || event.fromCallsign == myCallsign) {
      return;
    }

    // Don't notify for sync messages (user preference may vary)
    // For now, only notify for fresh incoming messages
    if (event.fromSync) {
      LogService().log('DMNotificationService: Skipping notification for synced message');
      return;
    }

    // Show notification
    await _showNotification(
      fromCallsign: event.fromCallsign,
      content: event.content,
      verified: event.verified,
    );

    LogService().log('DMNotificationService: Showed notification for message from ${event.fromCallsign}');
  }

  /// Show a notification for a direct message
  Future<void> _showNotification({
    required String fromCallsign,
    required String content,
    required bool verified,
  }) async {
    // Get notification settings
    final settings = NotificationService().getSettings();

    // Truncate long messages for notification
    final displayContent = content.length > 100
        ? '${content.substring(0, 100)}...'
        : content;

    // Add verification indicator
    final verifiedBadge = verified ? '✓ ' : '';
    final title = '$verifiedBadge$fromCallsign';

    // Android notification details
    final androidDetails = AndroidNotificationDetails(
      'dm_channel', // Channel ID
      'Direct Messages', // Channel name
      channelDescription: 'Notifications for direct messages',
      importance: Importance.high,
      priority: Priority.high,
      enableVibration: settings.vibrationEnabled,
      playSound: settings.soundEnabled,
      sound: settings.soundEnabled
          ? const RawResourceAndroidNotificationSound('notification_sound')
          : null,
    );

    // iOS notification details
    final iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: settings.soundEnabled,
      sound: settings.soundEnabled ? 'notification_sound.aiff' : null,
    );

    final notificationDetails = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    // Use fromCallsign hash as notification ID to allow multiple notifications
    final notificationId = fromCallsign.hashCode.abs();

    await _notificationsPlugin.show(
      notificationId,
      title,
      displayContent,
      notificationDetails,
      payload: 'dm:$fromCallsign', // Store callsign for tap handling
    );
  }

  /// Handle notification tap
  void _onNotificationTapped(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null) return;

    LogService().log('DMNotificationService: Notification tapped with payload: $payload');

    // Parse payload (format: "dm:CALLSIGN")
    if (payload.startsWith('dm:')) {
      final fromCallsign = payload.substring(3);

      // Fire an event that the UI can listen to for navigation
      EventBus().fire(DMNotificationTappedEvent(
        targetCallsign: fromCallsign,
      ));
    }
  }

  /// Dispose resources
  void dispose() {
    _dmEventSubscription?.cancel();
  }
}
