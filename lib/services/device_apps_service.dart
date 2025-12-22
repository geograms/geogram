/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'package:http/http.dart' as http;
import '../services/log_service.dart';
import '../services/devices_service.dart';
import '../services/storage_config.dart';

/// Service for discovering what apps are available on a remote device
class DeviceAppsService {
  static final DeviceAppsService _instance = DeviceAppsService._internal();
  factory DeviceAppsService() => _instance;
  DeviceAppsService._internal();

  final DevicesService _devicesService = DevicesService();

  /// Discover what apps are available on a device
  /// First checks cached data from disk, returns immediately if found
  /// Then optionally fetches fresh data from API in background
  ///
  /// Set [useCache] to false to skip cache and only use API
  /// Set [refreshInBackground] to false to skip background refresh after cache
  Future<Map<String, DeviceAppInfo>> discoverApps(
    String callsign, {
    bool useCache = true,
    bool refreshInBackground = true,
  }) async {
    // Try to load from cache first for instant response
    if (useCache) {
      final cachedApps = await _loadFromCache(callsign);
      if (cachedApps.values.any((app) => app.isAvailable)) {
        LogService().log('DeviceAppsService: Loaded cached apps for $callsign');

        // If refresh is enabled, fetch fresh data in background (don't wait)
        if (refreshInBackground) {
          _refreshApps(callsign);
        }

        return cachedApps;
      }
    }

    // No cache or cache disabled - fetch from API
    return await _fetchFromApi(callsign);
  }

  /// Load apps from cached data on disk
  Future<Map<String, DeviceAppInfo>> _loadFromCache(String callsign) async {
    final Map<String, DeviceAppInfo> apps = {};

    try {
      final dataDir = StorageConfig().baseDir;
      final devicePath = '$dataDir/devices/$callsign';
      final deviceDir = Directory(devicePath);

      if (!await deviceDir.exists()) {
        return {
          'blog': DeviceAppInfo(type: 'blog', isAvailable: false),
          'chat': DeviceAppInfo(type: 'chat', isAvailable: false),
          'events': DeviceAppInfo(type: 'events', isAvailable: false),
          'alerts': DeviceAppInfo(type: 'alerts', isAvailable: false),
        };
      }

      // Check blog cache
      final blogDir = Directory('$devicePath/blog');
      if (await blogDir.exists()) {
        int blogCount = 0;
        await for (final entity in blogDir.list()) {
          if (entity is File && entity.path.endsWith('.json')) {
            blogCount++;
          }
        }
        apps['blog'] = DeviceAppInfo(type: 'blog', isAvailable: blogCount > 0, itemCount: blogCount);
      } else {
        apps['blog'] = DeviceAppInfo(type: 'blog', isAvailable: false);
      }

      // Check chat cache
      final chatDir = Directory('$devicePath/chat');
      if (await chatDir.exists()) {
        int roomCount = 0;
        await for (final entity in chatDir.list()) {
          if (entity is Directory) {
            roomCount++;
          }
        }
        apps['chat'] = DeviceAppInfo(type: 'chat', isAvailable: roomCount > 0, itemCount: roomCount);
      } else {
        apps['chat'] = DeviceAppInfo(type: 'chat', isAvailable: false);
      }

      // Events and alerts not commonly cached yet
      apps['events'] = DeviceAppInfo(type: 'events', isAvailable: false);
      apps['alerts'] = DeviceAppInfo(type: 'alerts', isAvailable: false);

    } catch (e) {
      LogService().log('DeviceAppsService: Error loading cache for $callsign: $e');
      return {
        'blog': DeviceAppInfo(type: 'blog', isAvailable: false),
        'chat': DeviceAppInfo(type: 'chat', isAvailable: false),
        'events': DeviceAppInfo(type: 'events', isAvailable: false),
        'alerts': DeviceAppInfo(type: 'alerts', isAvailable: false),
      };
    }

    return apps;
  }

  /// Fetch fresh data from API
  Future<Map<String, DeviceAppInfo>> _fetchFromApi(String callsign) async {
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

    LogService().log('DeviceAppsService: Fetched apps from API for $callsign: ${apps.entries.where((e) => e.value.isAvailable).map((e) => e.key).toList()}');

    return apps;
  }

  /// Refresh apps in background (fire and forget)
  void _refreshApps(String callsign) {
    _fetchFromApi(callsign).then((apps) {
      LogService().log('DeviceAppsService: Background refresh complete for $callsign');
      // Apps are now cached by the API responses, next load will be faster
    }).catchError((e) {
      LogService().log('DeviceAppsService: Background refresh failed for $callsign: $e');
    });
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
