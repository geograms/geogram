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
  EventSubscription<ChatMessageEvent>? _chatEventSubscription;
  bool _initialized = false;
  bool _permissionRequested = false;

  /// Initialize the notification service
  /// Set [skipPermissionRequest] to true to defer permission request (e.g., for first launch onboarding)
  Future<void> initialize({bool skipPermissionRequest = false}) async {
    if (_initialized) return;

    // Only initialize on mobile platforms (Android/iOS)
    if (!_isMobilePlatform()) {
      LogService().log('DMNotificationService: Skipping initialization on non-mobile platform');
      _initialized = true;
      return;
    }

    try {
      await _initializeNotifications(skipPermissionRequest: skipPermissionRequest);
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
  Future<void> _initializeNotifications({bool skipPermissionRequest = false}) async {
    // Android initialization settings
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');

    // iOS initialization settings - don't request permission here if skipping
    final iosSettings = DarwinInitializationSettings(
      requestAlertPermission: !skipPermissionRequest,
      requestBadgePermission: !skipPermissionRequest,
      requestSoundPermission: !skipPermissionRequest,
    );

    final initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    // Initialize plugin
    await _notificationsPlugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );

    // Request permissions for iOS (unless skipping for onboarding)
    if (!skipPermissionRequest && defaultTargetPlatform == TargetPlatform.iOS) {
      await _notificationsPlugin
          .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(
            alert: true,
            badge: true,
            sound: true,
          );
      _permissionRequested = true;
    }

    // Request permissions for Android 13+ (unless skipping for onboarding)
    if (!skipPermissionRequest && defaultTargetPlatform == TargetPlatform.android) {
      await _notificationsPlugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      _permissionRequested = true;
    }

    LogService().log('DMNotificationService: Notifications initialized (skipPermissionRequest: $skipPermissionRequest)');
  }

  /// Request notification permission (call this after onboarding)
  Future<bool> requestNotificationPermission() async {
    if (_permissionRequested) {
      LogService().log('DMNotificationService: Permission already requested');
      return true;
    }

    // Ensure service is initialized before requesting permission
    if (!_initialized) {
      LogService().log('DMNotificationService: Service not initialized, cannot request permission');
      return false;
    }

    try {
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        final result = await _notificationsPlugin
            .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
            ?.requestPermissions(
              alert: true,
              badge: true,
              sound: true,
            );
        _permissionRequested = true;
        LogService().log('DMNotificationService: iOS permission result: $result');
        return result ?? false;
      }

      if (defaultTargetPlatform == TargetPlatform.android) {
        final result = await _notificationsPlugin
            .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
        _permissionRequested = true;
        LogService().log('DMNotificationService: Android permission result: $result');
        return result ?? false;
      }

      return false;
    } catch (e) {
      LogService().log('DMNotificationService: Error requesting permission: $e');
      return false;
    }
  }

  /// Subscribe to DirectMessageReceivedEvent
  void _subscribeToEvents() {
    _dmEventSubscription = EventBus().on<DirectMessageReceivedEvent>((event) {
      _handleIncomingDM(event);
    });
    _chatEventSubscription = EventBus().on<ChatMessageEvent>((event) {
      _handleIncomingChatMessage(event);
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

  /// Handle incoming chat message (group/room)
  Future<void> _handleIncomingChatMessage(ChatMessageEvent event) async {
    if (!_initialized) return;

    final settings = NotificationService().getSettings();
    if (!settings.enableNotifications || !settings.notifyNewMessages) {
      LogService().log('DMNotificationService: Notifications disabled in settings');
      return;
    }

    final myCallsign = ProfileService().getProfile().callsign;
    if (myCallsign.isEmpty || event.callsign == myCallsign) {
      return;
    }

    await _showChatNotification(
      roomId: event.roomId,
      fromCallsign: event.callsign,
      content: event.content,
      verified: event.verified,
    );
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

  /// Show a notification for a chat room message
  Future<void> _showChatNotification({
    required String roomId,
    required String fromCallsign,
    required String content,
    required bool verified,
  }) async {
    final settings = NotificationService().getSettings();

    final displayContent = content.length > 100
        ? '${content.substring(0, 100)}...'
        : content;

    final verifiedBadge = verified ? '✓ ' : '';
    final title = '$verifiedBadge$fromCallsign • $roomId';

    final androidDetails = AndroidNotificationDetails(
      'chat_channel',
      'Chat Rooms',
      channelDescription: 'Notifications for chat rooms',
      importance: Importance.high,
      priority: Priority.high,
      enableVibration: settings.vibrationEnabled,
      playSound: settings.soundEnabled,
      sound: settings.soundEnabled
          ? const RawResourceAndroidNotificationSound('notification_sound')
          : null,
    );

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

    final notificationId = '$roomId:$fromCallsign'.hashCode.abs();

    await _notificationsPlugin.show(
      notificationId,
      title,
      displayContent,
      notificationDetails,
      payload: 'chat:$roomId',
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
    _chatEventSubscription?.cancel();
  }
}
