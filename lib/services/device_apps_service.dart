/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'package:http/http.dart' as http;
import '../services/log_service.dart';
import '../services/devices_service.dart';

/// Service for discovering what apps are available on a remote device
class DeviceAppsService {
  static final DeviceAppsService _instance = DeviceAppsService._internal();
  factory DeviceAppsService() => _instance;
  DeviceAppsService._internal();

  final DevicesService _devicesService = DevicesService();

  /// Discover what apps are available on a device
  /// Returns map of app types to availability status
  Future<Map<String, DeviceAppInfo>> discoverApps(String callsign) async {
    final Map<String, DeviceAppInfo> apps = {};

    // Check each app type in parallel
    final futures = await Future.wait([
      _checkBlogAvailable(callsign),
      _checkChatAvailable(callsign),
      _checkEventsAvailable(callsign),
      _checkAlertsAvailable(callsign),
    ]);

    apps['blog'] = futures[0];
    apps['chat'] = futures[1];
    apps['events'] = futures[2];
    apps['alerts'] = futures[3];

    LogService().log('DeviceAppsService: Discovered apps for $callsign: ${apps.entries.where((e) => e.value.isAvailable).map((e) => e.key).toList()}');

    return apps;
  }

  /// Check if blog app is available
  Future<DeviceAppInfo> _checkBlogAvailable(String callsign) async {
    try {
      final response = await _devicesService.makeDeviceApiRequest(
        callsign: callsign,
        method: 'GET',
        path: '/api/blog',
      );

      if (response != null && response.statusCode == 200) {
        final List<dynamic> posts = json.decode(response.body);
        return DeviceAppInfo(
          type: 'blog',
          isAvailable: true,
          itemCount: posts.length,
        );
      }
    } catch (e) {
      LogService().log('DeviceAppsService: Blog not available for $callsign: $e');
    }

    return DeviceAppInfo(type: 'blog', isAvailable: false);
  }

  /// Check if chat app is available
  Future<DeviceAppInfo> _checkChatAvailable(String callsign) async {
    try {
      final response = await _devicesService.makeDeviceApiRequest(
        callsign: callsign,
        method: 'GET',
        path: '/api/chat/rooms',
      );

      if (response != null && response.statusCode == 200) {
        final List<dynamic> rooms = json.decode(response.body);
        return DeviceAppInfo(
          type: 'chat',
          isAvailable: true,
          itemCount: rooms.length,
        );
      }
    } catch (e) {
      LogService().log('DeviceAppsService: Chat not available for $callsign: $e');
    }

    return DeviceAppInfo(type: 'chat', isAvailable: false);
  }

  /// Check if events app is available
  Future<DeviceAppInfo> _checkEventsAvailable(String callsign) async {
    try {
      final response = await _devicesService.makeDeviceApiRequest(
        callsign: callsign,
        method: 'GET',
        path: '/api/events',
      );

      if (response != null && response.statusCode == 200) {
        final List<dynamic> events = json.decode(response.body);
        return DeviceAppInfo(
          type: 'events',
          isAvailable: true,
          itemCount: events.length,
        );
      }
    } catch (e) {
      LogService().log('DeviceAppsService: Events not available for $callsign: $e');
    }

    return DeviceAppInfo(type: 'events', isAvailable: false);
  }

  /// Check if alerts/reports app is available
  Future<DeviceAppInfo> _checkAlertsAvailable(String callsign) async {
    try {
      final response = await _devicesService.makeDeviceApiRequest(
        callsign: callsign,
        method: 'GET',
        path: '/api/alerts',
      );

      if (response != null && response.statusCode == 200) {
        final List<dynamic> alerts = json.decode(response.body);
        return DeviceAppInfo(
          type: 'alerts',
          isAvailable: true,
          itemCount: alerts.length,
        );
      }
    } catch (e) {
      LogService().log('DeviceAppsService: Alerts not available for $callsign: $e');
    }

    return DeviceAppInfo(type: 'alerts', isAvailable: false);
  }
}

/// Information about an app on a device
class DeviceAppInfo {
  final String type;
  final bool isAvailable;
  final int itemCount;

  DeviceAppInfo({
    required this.type,
    required this.isAvailable,
    this.itemCount = 0,
  });

  String get displayName {
    switch (type) {
      case 'blog':
        return 'Blog';
      case 'chat':
        return 'Chat';
      case 'events':
        return 'Events';
      case 'alerts':
        return 'Reports';
      default:
        return type;
    }
  }
}
