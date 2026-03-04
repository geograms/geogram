/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../util/event_bus.dart';
import '../services/notification_service.dart';
import '../services/profile_service.dart';
import '../services/log_service.dart';
import '../services/tray_service.dart';

/// Key for storing pending notification action in SharedPreferences
const String _pendingActionKey = 'pending_notification_action';

/// Notification action from tap - stored statically to persist across isolates
class NotificationAction {
  final String type;
  final String data;
  NotificationAction({required this.type, required this.data});
}

/// Top-level callback for handling notification taps when app is in background
/// MUST be top-level (not a class method) for Android isolate compatibility
/// NOTE: This runs in a SEPARATE isolate - static variables are NOT shared!
/// We use SharedPreferences to persist the action across isolates.
@pragma('vm:entry-point')
void onBackgroundNotificationResponse(NotificationResponse response) {
  print('NOTIFICATION_DEBUG: onBackgroundNotificationResponse called');
  final payload = response.payload;
  print('NOTIFICATION_DEBUG: payload=$payload');
  if (payload == null) return;

  // Save to SharedPreferences for cross-isolate communication
  // This is async but we can't await in a top-level callback
  SharedPreferences.getInstance().then((prefs) {
    prefs.setString(_pendingActionKey, payload);
    print(
      'NOTIFICATION_DEBUG: Saved pending action to SharedPreferences: $payload',
    );
  });
}

/// Service for showing local push notifications for direct messages
class DMNotificationService {
  static final DMNotificationService _instance =
      DMNotificationService._internal();
  factory DMNotificationService() => _instance;
  DMNotificationService._internal();

  /// Pending action from notification tap - checked on app resume
  static NotificationAction? pendingAction;

  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  /// Expose the plugin so NowNotificationBridge can show/cancel notifications
  FlutterLocalNotificationsPlugin get notificationsPlugin => _notificationsPlugin;

  EventSubscription<DirectMessageReceivedEvent>? _dmEventSubscription;
  bool _initialized = false;
  bool _permissionRequested = false;

  /// Initialize the notification service
  /// Set [skipPermissionRequest] to true to defer permission request (e.g., for first launch onboarding)
  Future<void> initialize({bool skipPermissionRequest = false}) async {
    if (_initialized) return;

    // Only initialize on supported platforms (Android/iOS/Linux/Windows/macOS)
    if (!_isSupportedPlatform()) {
      LogService().log(
        'DMNotificationService: Skipping initialization on unsupported platform',
      );
      _initialized = true;
      return;
    }

    try {
      await _initializeNotifications(
        skipPermissionRequest: skipPermissionRequest,
      );
      _subscribeToEvents();
      _initialized = true;
      LogService().log('DMNotificationService initialized');
    } catch (e) {
      LogService().log('Error initializing DMNotificationService: $e');
    }
  }

  /// Check if running on a supported platform (mobile + desktop)
  bool _isSupportedPlatform() {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  /// Check if running on a desktop platform
  bool _isDesktopPlatform() {
    return defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  /// Initialize flutter_local_notifications
  Future<void> _initializeNotifications({
    bool skipPermissionRequest = false,
  }) async {
    // Android initialization settings
    const androidSettings = AndroidInitializationSettings(
      '@drawable/ic_notification',
    );

    // iOS initialization settings - don't request permission here if skipping
    final iosSettings = DarwinInitializationSettings(
      requestAlertPermission: !skipPermissionRequest,
      requestBadgePermission: !skipPermissionRequest,
      requestSoundPermission: !skipPermissionRequest,
    );

    // Linux initialization settings (D-Bus notifications)
    const linuxSettings = LinuxInitializationSettings(
      defaultActionName: 'Open Geogram',
    );

    final initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
      linux: linuxSettings,
    );

    // Initialize plugin
    await _notificationsPlugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
      onDidReceiveBackgroundNotificationResponse:
          onBackgroundNotificationResponse,
    );

    // Request permissions for iOS (unless skipping for onboarding)
    if (!skipPermissionRequest && defaultTargetPlatform == TargetPlatform.iOS) {
      await _notificationsPlugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: true, sound: true);
      _permissionRequested = true;
    }

    // Request permissions for Android 13+ (unless skipping for onboarding)
    if (!skipPermissionRequest &&
        defaultTargetPlatform == TargetPlatform.android) {
      await _notificationsPlugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
      _permissionRequested = true;
    }

    // Desktop platforms (Linux/Windows/macOS) don't require explicit permission
    if (_isDesktopPlatform()) {
      _permissionRequested = true;
    }

    LogService().log(
      'DMNotificationService: Notifications initialized (skipPermissionRequest: $skipPermissionRequest)',
    );

    // Check if app was launched from notification (cold start)
    try {
      final launchDetails = await _notificationsPlugin
          .getNotificationAppLaunchDetails();
      if (launchDetails?.didNotificationLaunchApp == true) {
        final payload = launchDetails?.notificationResponse?.payload;
        LogService().log(
          'DMNotificationService: App launched from notification with payload: $payload',
        );
        if (payload != null && payload.startsWith('dm:')) {
          final fromCallsign = payload.substring(3);
          // Clear SharedPreferences to prevent double handling by _checkPendingNotification
          final prefs = await SharedPreferences.getInstance();
          await prefs.remove(_pendingActionKey);
          // Fire event after a short delay to ensure app UI is ready
          Future.delayed(const Duration(milliseconds: 500), () {
            EventBus().fire(
              DMNotificationTappedEvent(targetCallsign: fromCallsign),
            );
          });
        } else if (payload != null && payload.startsWith('email:')) {
          final threadId = payload.substring('email:'.length);
          if (threadId.isNotEmpty) {
            final prefs = await SharedPreferences.getInstance();
            await prefs.remove(_pendingActionKey);
            Future.delayed(const Duration(milliseconds: 500), () {
              EventBus().fire(EmailNotificationTappedEvent(threadId: threadId));
            });
          }
        } else if (payload != null && payload.startsWith('chat:')) {
          final roomId = payload.substring('chat:'.length);
          if (roomId.isNotEmpty) {
            final prefs = await SharedPreferences.getInstance();
            await prefs.remove(_pendingActionKey);
            Future.delayed(const Duration(milliseconds: 500), () {
              EventBus().fire(ChatNotificationTappedEvent(roomId: roomId));
            });
          }
        } else if (payload != null && payload.startsWith('now:')) {
          final data = payload.substring('now:'.length);
          final parts = data.split(':');
          if (parts.length >= 2) {
            final prefs = await SharedPreferences.getInstance();
            await prefs.remove(_pendingActionKey);
            final appType = parts[0];
            final sourceId = parts[1];
            final sourceName = parts.length >= 3 ? parts.sublist(2).join(':') : '';
            Future.delayed(const Duration(milliseconds: 500), () {
              EventBus().fire(NowNotificationTappedEvent(
                appType: appType,
                sourceId: sourceId,
                sourceName: sourceName,
              ));
            });
          }
        }
      }
    } catch (e) {
      // Not all desktop implementations support launch-details retrieval.
      LogService().log(
        'DMNotificationService: Launch details unavailable on this platform: $e',
      );
    }
  }

  /// Request notification permission (call this after onboarding)
  Future<bool> requestNotificationPermission() async {
    if (_permissionRequested) {
      LogService().log('DMNotificationService: Permission already requested');
      return true;
    }

    // Ensure service is initialized before requesting permission
    if (!_initialized) {
      LogService().log(
        'DMNotificationService: Service not initialized, cannot request permission',
      );
      return false;
    }

    try {
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        final result = await _notificationsPlugin
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >()
            ?.requestPermissions(alert: true, badge: true, sound: true);
        _permissionRequested = true;
        LogService().log(
          'DMNotificationService: iOS permission result: $result',
        );
        return result ?? false;
      }

      if (defaultTargetPlatform == TargetPlatform.android) {
        final result = await _notificationsPlugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >()
            ?.requestNotificationsPermission();
        _permissionRequested = true;
        LogService().log(
          'DMNotificationService: Android permission result: $result',
        );
        return result ?? false;
      }

      return false;
    } catch (e) {
      LogService().log(
        'DMNotificationService: Error requesting permission: $e',
      );
      return false;
    }
  }

  /// Subscribe to DirectMessageReceivedEvent
  void _subscribeToEvents() {
    _dmEventSubscription = EventBus().on<DirectMessageReceivedEvent>((event) {
      _handleIncomingDM(event);
    });
    LogService().log(
      'DMNotificationService: Subscribed to DirectMessageReceivedEvent',
    );
  }

  /// Handle incoming direct message
  Future<void> _handleIncomingDM(DirectMessageReceivedEvent event) async {
    if (!_initialized) return;

    // Check notification settings
    final settings = NotificationService().getSettings();
    if (!settings.enableNotifications || !settings.notifyNewMessages) {
      LogService().log(
        'DMNotificationService: Notifications disabled in settings',
      );
      return;
    }

    // Don't notify for messages we sent
    final myCallsign = ProfileService().getProfile().callsign;
    if (myCallsign.isEmpty || event.fromCallsign == myCallsign) {
      return;
    }

    // Fire NowItemEvent for the activity feed (bridge handles notification)
    final summary = event.content.length > 100
        ? '${event.content.substring(0, 100)}...'
        : event.content;
    EventBus().fire(NowItemEvent(
      id: 'dm:${event.fromCallsign}:${DateTime.now().toIso8601String()}',
      appType: 'dm',
      sourceId: event.fromCallsign,
      sourceName: event.fromCallsign,
      callsign: event.fromCallsign,
      summary: summary,
      priority: NowPriority.directMessage,
    ));

    LogService().log(
      'DMNotificationService: Showed notification for message from ${event.fromCallsign}',
    );
  }


  /// Handle notification tap
  void _onNotificationTapped(NotificationResponse response) {
    // This callback is called when notification is tapped:
    // - App in foreground: called immediately
    // - App in background: called when app resumes
    print('NOTIFICATION_DEBUG: *** _onNotificationTapped CALLED ***');
    print(
      'NOTIFICATION_DEBUG: actionId=${response.actionId}, id=${response.id}',
    );
    final payload = response.payload;
    print('NOTIFICATION_DEBUG: payload=$payload');
    if (payload == null) {
      print('NOTIFICATION_DEBUG: payload is null, returning');
      return;
    }

    LogService().log(
      'DMNotificationService: Notification tapped with payload: $payload',
    );

    // Parse payload (format: "type:data", e.g., "dm:CALLSIGN")
    final colonIndex = payload.indexOf(':');
    if (colonIndex > 0) {
      final type = payload.substring(0, colonIndex);
      final data = payload.substring(colonIndex + 1);
      print('NOTIFICATION_DEBUG: parsed type=$type, data=$data');

      // Restore window from tray if hidden (desktop)
      if (_isDesktopPlatform() && TrayService().isWindowHidden) {
        TrayService().restoreFromTray();
      }

      // Fire event for immediate navigation (foreground + background resume)
      if (type == 'dm') {
        print('NOTIFICATION_DEBUG: Firing DMNotificationTappedEvent for $data');
        EventBus().fire(DMNotificationTappedEvent(targetCallsign: data));
      } else if (type == 'email') {
        if (data.isNotEmpty) {
          EventBus().fire(EmailNotificationTappedEvent(threadId: data));
        }
      } else if (type == 'chat') {
        if (data.isNotEmpty) {
          EventBus().fire(ChatNotificationTappedEvent(roomId: data));
        }
      } else if (type == 'nav') {
        EventBus().fire(NavigateToDevicesEvent());
      } else if (type == 'now') {
        // Generic Now item tap: payload = "now:appType:sourceId:sourceName"
        final parts = data.split(':');
        if (parts.length >= 2) {
          final appType = parts[0];
          final sourceId = parts.length >= 2 ? parts[1] : '';
          final sourceName = parts.length >= 3 ? parts.sublist(2).join(':') : '';
          EventBus().fire(NowNotificationTappedEvent(
            appType: appType,
            sourceId: sourceId,
            sourceName: sourceName,
          ));
        }
      }
      // Don't set pendingAction — the event handles immediate cases,
      // SharedPreferences handles cold-start via _checkPendingNotification()
    } else {
      print('NOTIFICATION_DEBUG: No colon in payload, cannot parse');
    }
  }

  /// Check for pending notification action from SharedPreferences (cross-isolate)
  /// Returns the action and clears it from storage
  Future<NotificationAction?> consumePendingAction() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final payload = prefs.getString(_pendingActionKey);
      print(
        'NOTIFICATION_DEBUG: consumePendingAction - payload from SharedPreferences: $payload',
      );

      if (payload == null) {
        // Also check static variable for foreground case
        final action = pendingAction;
        if (action != null) {
          pendingAction = null;
          print(
            'NOTIFICATION_DEBUG: consumePendingAction - returning static pendingAction: ${action.type}:${action.data}',
          );
          return action;
        }
        return null;
      }

      // Clear from storage
      await prefs.remove(_pendingActionKey);
      print(
        'NOTIFICATION_DEBUG: consumePendingAction - cleared from SharedPreferences',
      );

      // Parse payload
      final colonIndex = payload.indexOf(':');
      if (colonIndex > 0) {
        final action = NotificationAction(
          type: payload.substring(0, colonIndex),
          data: payload.substring(colonIndex + 1),
        );
        print(
          'NOTIFICATION_DEBUG: consumePendingAction - returning: ${action.type}:${action.data}',
        );
        return action;
      }
    } catch (e) {
      print('NOTIFICATION_DEBUG: consumePendingAction error: $e');
    }
    return null;
  }

  /// Dispose resources
  void dispose() {
    _dmEventSubscription?.cancel();
  }

}
