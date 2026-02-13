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

  static const String _messageGroupKey = 'geogram_messages';
  static const int _summaryNotificationId = 900100;
  static const int _maxSummaryLines = 10;

  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();
  EventSubscription<DirectMessageReceivedEvent>? _dmEventSubscription;
  EventSubscription<ChatMessageEvent>? _chatEventSubscription;
  bool _initialized = false;
  bool _permissionRequested = false;
  final List<String> _recentMessageLines = [];
  int _totalMessageCount = 0;

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
    _chatEventSubscription = EventBus().on<ChatMessageEvent>((event) {
      _handleIncomingChatMessage(event);
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

    // Show notification
    await _showNotification(
      fromCallsign: event.fromCallsign,
      content: event.content,
      verified: event.verified,
    );

    LogService().log(
      'DMNotificationService: Showed notification for message from ${event.fromCallsign}',
    );
  }

  /// Handle incoming chat message (group/room)
  Future<void> _handleIncomingChatMessage(ChatMessageEvent event) async {
    await showChatRoomMessage(
      roomId: event.roomId,
      fromCallsign: event.callsign,
      content: event.content,
      verified: event.verified,
    );
  }

  /// Show a notification for a chat room message (public API for station updates)
  Future<void> showChatRoomMessage({
    required String roomId,
    required String fromCallsign,
    required String content,
    required bool verified,
    String? fileName,
    String? imagePath,
  }) async {
    if (!_initialized || !_isSupportedPlatform()) return;

    final settings = NotificationService().getSettings();
    if (!settings.enableNotifications || !settings.notifyNewMessages) {
      LogService().log(
        'DMNotificationService: Notifications disabled in settings',
      );
      return;
    }

    final myCallsign = ProfileService().getProfile().callsign;
    if (myCallsign.isEmpty || fromCallsign == myCallsign) {
      return;
    }

    await _showChatNotification(
      roomId: roomId,
      fromCallsign: fromCallsign,
      content: content,
      verified: verified,
      fileName: fileName,
      imagePath: imagePath,
    );
  }

  /// Show a notification for incoming email messages.
  Future<void> showEmailMessage({
    required String fromAddress,
    required String subject,
    required String preview,
  }) async {
    if (!_initialized || !_isSupportedPlatform()) return;

    final settings = NotificationService().getSettings();
    if (!settings.enableNotifications || !settings.notifyNewMessages) {
      LogService().log(
        'DMNotificationService: Notifications disabled in settings',
      );
      return;
    }

    final sender = _extractEmailSenderDisplay(fromAddress);
    final displaySubject = subject.trim().isEmpty
        ? '(No Subject)'
        : subject.trim();
    final body = _buildEmailNotificationBody(
      subject: displaySubject,
      preview: preview,
    );

    final androidDetails = AndroidNotificationDetails(
      'email_channel',
      'Email',
      channelDescription: 'Notifications for incoming email',
      importance: Importance.high,
      priority: Priority.high,
      enableVibration: settings.vibrationEnabled,
      playSound: settings.soundEnabled,
      groupKey: _messageGroupKey,
    );

    final iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: settings.soundEnabled,
    );

    const linuxDetails = LinuxNotificationDetails(
      urgency: LinuxNotificationUrgency.normal,
    );

    final notificationDetails = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
      linux: linuxDetails,
    );

    final notificationId =
        'email:$fromAddress:$displaySubject:${DateTime.now().millisecondsSinceEpoch}'
            .hashCode
            .abs();

    final title = 'Email from $sender';
    await _notificationsPlugin.show(
      notificationId,
      title,
      body,
      notificationDetails,
      payload: 'nav:devices',
    );

    LogService().log(
      'DMNotificationService: Showed email notification from $sender (subject: $displaySubject)',
    );

    _recordRecentMessage('$title: $displaySubject');
    await _showSummaryNotification();
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
      groupKey: _messageGroupKey,
    );

    // iOS notification details
    final iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: settings.soundEnabled,
    );

    // Linux notification details
    const linuxDetails = LinuxNotificationDetails(
      urgency: LinuxNotificationUrgency.normal,
    );

    final notificationDetails = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
      linux: linuxDetails,
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

    _recordRecentMessage('$title: $displayContent');
    await _showSummaryNotification();
  }

  /// Show a notification for a chat room message
  Future<void> _showChatNotification({
    required String roomId,
    required String fromCallsign,
    required String content,
    required bool verified,
    String? fileName,
    String? imagePath,
  }) async {
    final settings = NotificationService().getSettings();

    // Build display content: show text content, or file description if no text
    String displayContent;
    if (content.isNotEmpty) {
      displayContent = content.length > 100
          ? '${content.substring(0, 100)}...'
          : content;
      // Add file indicator if there's also a file
      if (fileName != null && fileName.isNotEmpty) {
        displayContent = '$displayContent 📎';
      }
    } else if (fileName != null && fileName.isNotEmpty) {
      // No text content, show file description
      final isImage = _isImageFile(fileName);
      final isVoice = _isVoiceFile(fileName);
      if (isImage) {
        displayContent = '📷 Image';
      } else if (isVoice) {
        displayContent = '🎤 Voice message';
      } else {
        displayContent = '📎 $fileName';
      }
    } else {
      displayContent = '';
    }

    final verifiedBadge = verified ? '✓ ' : '';
    final title = '$verifiedBadge$fromCallsign • $roomId';

    // Build Android notification details with optional BigPicture style
    StyleInformation? styleInfo;
    if (imagePath != null && imagePath.isNotEmpty) {
      styleInfo = BigPictureStyleInformation(
        FilePathAndroidBitmap(imagePath),
        contentTitle: title,
        summaryText: displayContent.isNotEmpty ? displayContent : null,
        hideExpandedLargeIcon: true,
      );
    }

    final androidDetails = AndroidNotificationDetails(
      'chat_channel',
      'Chat Rooms',
      channelDescription: 'Notifications for chat rooms',
      importance: Importance.high,
      priority: Priority.high,
      enableVibration: settings.vibrationEnabled,
      playSound: settings.soundEnabled,
      groupKey: _messageGroupKey,
      styleInformation: styleInfo,
      largeIcon: imagePath != null ? FilePathAndroidBitmap(imagePath) : null,
    );

    final iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: settings.soundEnabled,
    );

    const linuxDetails = LinuxNotificationDetails(
      urgency: LinuxNotificationUrgency.normal,
    );

    final notificationDetails = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
      linux: linuxDetails,
    );

    final notificationId = '$roomId:$fromCallsign'.hashCode.abs();

    await _notificationsPlugin.show(
      notificationId,
      title,
      displayContent,
      notificationDetails,
      payload: 'chat:$roomId',
    );

    _recordRecentMessage('$title: $displayContent');
    await _showSummaryNotification();
  }

  bool _isImageFile(String filename) {
    final lower = filename.toLowerCase();
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.bmp');
  }

  bool _isVoiceFile(String filename) {
    final lower = filename.toLowerCase();
    return lower.endsWith('.m4a') ||
        lower.endsWith('.aac') ||
        lower.endsWith('.mp3') ||
        lower.endsWith('.wav') ||
        lower.endsWith('.ogg');
  }

  String _extractEmailSenderDisplay(String fromAddress) {
    final normalized = fromAddress.trim();
    final atIndex = normalized.indexOf('@');
    if (atIndex > 0) {
      return normalized.substring(0, atIndex).toUpperCase();
    }
    return normalized.toUpperCase();
  }

  String _buildEmailNotificationBody({
    required String subject,
    required String preview,
  }) {
    final normalizedPreview = preview.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (normalizedPreview.isEmpty) {
      return _truncateNotificationText(subject, 160);
    }
    final combined = '$subject - $normalizedPreview';
    return _truncateNotificationText(combined, 160);
  }

  String _truncateNotificationText(String text, int maxChars) {
    if (text.length <= maxChars) return text;
    return '${text.substring(0, maxChars)}...';
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
      } else if (type == 'nav') {
        EventBus().fire(NavigateToDevicesEvent());
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
    _chatEventSubscription?.cancel();
  }

  void _recordRecentMessage(String line) {
    _totalMessageCount += 1;
    _recentMessageLines.insert(0, line);
    if (_recentMessageLines.length > _maxSummaryLines) {
      _recentMessageLines.removeRange(
        _maxSummaryLines,
        _recentMessageLines.length,
      );
    }
  }

  Future<void> _showSummaryNotification() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    if (_recentMessageLines.isEmpty) return;

    final settings = NotificationService().getSettings();
    if (!settings.enableNotifications || !settings.notifyNewMessages) {
      return;
    }

    final lines = _recentMessageLines.reversed.toList();
    final inboxStyle = InboxStyleInformation(
      lines,
      contentTitle: 'Messages ($_totalMessageCount)',
      summaryText: '$_totalMessageCount total',
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

    await _notificationsPlugin.show(
      _summaryNotificationId,
      'Geogram',
      '$_totalMessageCount new messages',
      notificationDetails,
      payload: 'nav:devices',
    );
  }
}
