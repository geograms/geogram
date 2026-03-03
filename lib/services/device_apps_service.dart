/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import '../services/log_service.dart';
import '../services/devices_service.dart';
import '../services/storage_config.dart';

/// All app types discovered on remote devices
const List<String> _allAppTypes = ['blog', 'chat', 'events', 'alerts', 'shared'];

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
    LogService().log(
      'DeviceAppsService.discoverApps: START for $callsign, useCache=$useCache',
    );
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
      LogService().log(
        'DeviceAppsService: No usable cache for $callsign, fetching from API',
      );
    }

    // No cache or cache disabled - fetch from API
    LogService().log('DeviceAppsService: Calling _fetchFromApi for $callsign');
    return await _fetchFromApi(callsign);
  }

  /// Load apps from cached metadata or content on disk
  Future<Map<String, DeviceAppInfo>> _loadFromCache(String callsign) async {
    final Map<String, DeviceAppInfo> apps = {};

    try {
      final dataDir = StorageConfig().baseDir;
      final devicePath = '$dataDir/devices/$callsign';
      final deviceDir = Directory(devicePath);

      if (!await deviceDir.exists()) {
        return _emptyApps();
      }

      // First try to load from apps_meta.json (cached API response)
      final metaFile = File('$devicePath/apps_meta.json');
      if (await metaFile.exists()) {
        try {
          final metaJson = await metaFile.readAsString();
          final meta = json.decode(metaJson) as Map<String, dynamic>;
          LogService().log(
            'DeviceAppsService: Loaded apps_meta.json for $callsign',
          );

          for (final appType in _allAppTypes) {
            if (meta.containsKey(appType)) {
              final appMeta = meta[appType] as Map<String, dynamic>;
              apps[appType] = DeviceAppInfo(
                type: appType,
                isAvailable: appMeta['isAvailable'] as bool? ?? false,
                itemCount: appMeta['itemCount'] as int? ?? 0,
              );
            } else {
              apps[appType] = DeviceAppInfo(type: appType, isAvailable: false);
            }
          }

          return apps;
        } catch (e) {
          LogService().log(
            'DeviceAppsService: Error reading apps_meta.json: $e',
          );
        }
      }

      // Fallback: check actual content directories
      // Check blog cache
      final blogDir = Directory('$devicePath/blog');
      if (await blogDir.exists()) {
        int blogCount = 0;
        await for (final entity in blogDir.list()) {
          if (entity is File && entity.path.endsWith('.json')) {
            blogCount++;
          }
        }
        apps['blog'] = DeviceAppInfo(
          type: 'blog',
          isAvailable: blogCount > 0,
          itemCount: blogCount,
        );
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
        apps['chat'] = DeviceAppInfo(
          type: 'chat',
          isAvailable: roomCount > 0,
          itemCount: roomCount,
        );
      } else {
        apps['chat'] = DeviceAppInfo(type: 'chat', isAvailable: false);
      }

      // Events, alerts, and shared not commonly cached yet
      apps['events'] = DeviceAppInfo(type: 'events', isAvailable: false);
      apps['alerts'] = DeviceAppInfo(type: 'alerts', isAvailable: false);
      apps['shared'] = DeviceAppInfo(type: 'shared', isAvailable: false);
    } catch (e) {
      LogService().log(
        'DeviceAppsService: Error loading cache for $callsign: $e',
      );
      return _emptyApps();
    }

    return apps;
  }

  /// Save app availability metadata to disk
  Future<void> _saveToCache(
    String callsign,
    Map<String, DeviceAppInfo> apps,
  ) async {
    try {
      final dataDir = StorageConfig().baseDir;
      final devicePath = '$dataDir/devices/$callsign';
      final deviceDir = Directory(devicePath);

      if (!await deviceDir.exists()) {
        await deviceDir.create(recursive: true);
      }

      final meta = <String, dynamic>{};
      for (final entry in apps.entries) {
        meta[entry.key] = {
          'isAvailable': entry.value.isAvailable,
          'itemCount': entry.value.itemCount,
          'cachedAt': DateTime.now().toIso8601String(),
        };
      }

      final metaFile = File('$devicePath/apps_meta.json');
      await metaFile.writeAsString(json.encode(meta));
      LogService().log('DeviceAppsService: Saved apps_meta.json for $callsign');
    } catch (e) {
      LogService().log(
        'DeviceAppsService: Error saving cache for $callsign: $e',
      );
    }
  }

  /// Fetch fresh data from API — fast path via /api/apps, fallback to individual calls
  Future<Map<String, DeviceAppInfo>> _fetchFromApi(String callsign) async {
    // Fast path: single /api/apps call
    final fastResult = await _tryFastPath(callsign);
    if (fastResult != null) {
      LogService().log(
        'DeviceAppsService: Fast path (/api/apps) succeeded for $callsign: ${fastResult.entries.where((e) => e.value.isAvailable).map((e) => e.key).toList()}',
      );
      if (fastResult.values.any((app) => app.isAvailable)) {
        await _saveToCache(callsign, fastResult);
      }
      return fastResult;
    }

    // Fallback: individual calls in parallel
    LogService().log(
      'DeviceAppsService: Fast path failed for $callsign, falling back to parallel individual calls',
    );
    final results = await Future.wait([
      _checkBlogAvailable(callsign),
      _checkChatAvailable(callsign),
      _checkEventsAvailable(callsign),
      _checkAlertsAvailable(callsign),
    ]);

    final apps = <String, DeviceAppInfo>{
      'blog': results[0],
      'chat': results[1],
      'events': results[2],
      'alerts': results[3],
      // Shared not available via individual legacy calls
      'shared': DeviceAppInfo(type: 'shared', isAvailable: false),
    };

    LogService().log(
      'DeviceAppsService: Fetched apps from API for $callsign: ${apps.entries.where((e) => e.value.isAvailable).map((e) => e.key).toList()}',
    );

    // Cache the result if any app is available
    if (apps.values.any((app) => app.isAvailable)) {
      await _saveToCache(callsign, apps);
    }

    return apps;
  }

  /// Try the fast /api/apps endpoint (returns null if not supported)
  Future<Map<String, DeviceAppInfo>?> _tryFastPath(String callsign) async {
    try {
      final response = await _devicesService.makeDeviceApiRequest(
        callsign: callsign,
        method: 'GET',
        path: '/api/apps',
      );

      if (response == null || response.statusCode == 404) {
        return null; // Endpoint not supported by this device
      }

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final appsData = data['apps'] as Map<String, dynamic>?;
        if (appsData == null) return null;

        final apps = <String, DeviceAppInfo>{};
        for (final appType in _allAppTypes) {
          if (appsData.containsKey(appType)) {
            final appInfo = appsData[appType] as Map<String, dynamic>;
            apps[appType] = DeviceAppInfo(
              type: appType,
              isAvailable: appInfo['available'] as bool? ?? false,
              itemCount: appInfo['count'] as int? ?? 0,
            );
          } else {
            apps[appType] = DeviceAppInfo(type: appType, isAvailable: false);
          }
        }
        return apps;
      }
    } catch (e) {
      LogService().log(
        'DeviceAppsService._tryFastPath: ERROR for $callsign: $e',
      );
    }
    return null;
  }

  /// Refresh apps in background (fire and forget)
  void _refreshApps(String callsign) {
    _fetchFromApi(callsign)
        .then((apps) {
          LogService().log(
            'DeviceAppsService: Background refresh complete for $callsign',
          );
        })
        .catchError((e) {
          LogService().log(
            'DeviceAppsService: Background refresh failed for $callsign: $e',
          );
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
        final data = json.decode(response.body) as Map<String, dynamic>;
        final posts = data['posts'] as List? ?? [];
        return DeviceAppInfo(
          type: 'blog',
          isAvailable: posts.isNotEmpty,
          itemCount: posts.length,
        );
      }
    } catch (e) {
      LogService().log(
        'DeviceAppsService._checkBlogAvailable: ERROR for $callsign: $e',
      );
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
        final data = json.decode(response.body);
        List<dynamic> rooms;

        if (data is List) {
          rooms = data;
        } else if (data is Map<String, dynamic> && data['rooms'] != null) {
          rooms = data['rooms'] as List;
        } else {
          rooms = [];
        }

        return DeviceAppInfo(
          type: 'chat',
          isAvailable: rooms.isNotEmpty,
          itemCount: rooms.length,
        );
      }
    } catch (e) {
      LogService().log(
        'DeviceAppsService._checkChatAvailable: ERROR for $callsign: $e',
      );
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
        final data = json.decode(response.body);
        List<dynamic> events;

        if (data is List) {
          events = data;
        } else if (data is Map<String, dynamic> && data['events'] != null) {
          events = data['events'] as List;
        } else {
          events = [];
        }

        return DeviceAppInfo(
          type: 'events',
          isAvailable: events.isNotEmpty,
          itemCount: events.length,
        );
      }
    } catch (e) {
      LogService().log(
        'DeviceAppsService._checkEventsAvailable: ERROR for $callsign: $e',
      );
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
        final data = json.decode(response.body);
        List<dynamic> alerts;

        if (data is List) {
          alerts = data;
        } else if (data is Map<String, dynamic> && data['alerts'] != null) {
          alerts = data['alerts'] as List;
        } else {
          alerts = [];
        }

        return DeviceAppInfo(
          type: 'alerts',
          isAvailable: alerts.isNotEmpty,
          itemCount: alerts.length,
        );
      }
    } catch (e) {
      LogService().log(
        'DeviceAppsService._checkAlertsAvailable: ERROR for $callsign: $e',
      );
    }
    return DeviceAppInfo(type: 'alerts', isAvailable: false);
  }

  /// Return empty (all unavailable) apps map
  static Map<String, DeviceAppInfo> _emptyApps() {
    return {
      for (final type in _allAppTypes)
        type: DeviceAppInfo(type: type, isAvailable: false),
    };
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
      case 'shared':
        return 'Shared';
      default:
        return type;
    }
  }
}
