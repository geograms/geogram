/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../models/device_source.dart';
import '../models/relay.dart';
import '../util/chat_api.dart';
import 'relay_cache_service.dart';
import 'relay_service.dart';
import 'relay_discovery_service.dart';
import 'log_service.dart';

/// Service for managing remote devices we've contacted
class DevicesService {
  static final DevicesService _instance = DevicesService._internal();
  factory DevicesService() => _instance;
  DevicesService._internal();

  final RelayCacheService _cacheService = RelayCacheService();
  final RelayService _relayService = RelayService();
  final RelayDiscoveryService _discoveryService = RelayDiscoveryService();

  /// Cache of known devices with their status
  final Map<String, RemoteDevice> _devices = {};

  /// Stream controller for device updates
  final _devicesController = StreamController<List<RemoteDevice>>.broadcast();
  Stream<List<RemoteDevice>> get devicesStream => _devicesController.stream;

  /// Initialize the service
  Future<void> initialize() async {
    await _cacheService.initialize();
    await _loadCachedDevices();
  }

  /// Load devices from cache
  Future<void> _loadCachedDevices() async {
    try {
      final cachedCallsigns = await _cacheService.getCachedDevices();

      for (final callsign in cachedCallsigns) {
        final cacheTime = await _cacheService.getCacheTime(callsign);

        // Try to find matching relay
        Relay? matchingRelay;
        try {
          for (final relay in _relayService.getAllRelays()) {
            if (relay.callsign?.toUpperCase() == callsign.toUpperCase()) {
              matchingRelay = relay;
              break;
            }
          }
        } catch (e) {
          // RelayService might not be initialized
        }

        _devices[callsign] = RemoteDevice(
          callsign: callsign,
          name: matchingRelay?.name ?? callsign,
          url: matchingRelay?.url,
          isOnline: false,
          lastSeen: cacheTime,
          hasCachedData: true,
          collections: [],
        );
      }

      // Also add known relays that might not have cache
      try {
        for (final relay in _relayService.getAllRelays()) {
          if (relay.callsign != null && !_devices.containsKey(relay.callsign!.toUpperCase())) {
            _devices[relay.callsign!.toUpperCase()] = RemoteDevice(
              callsign: relay.callsign!,
              name: relay.name,
              url: relay.url,
              isOnline: relay.isConnected,
              lastSeen: relay.lastChecked,
              hasCachedData: false,
              collections: [],
            );
          }
        }
      } catch (e) {
        // RelayService might not be initialized
      }

      _notifyListeners();
    } catch (e) {
      LogService().log('DevicesService: Error loading cached devices: $e');
    }
  }

  /// Get all known devices
  List<RemoteDevice> getAllDevices() {
    return _devices.values.toList()
      ..sort((a, b) {
        // Online devices first, then by name
        if (a.isOnline != b.isOnline) {
          return a.isOnline ? -1 : 1;
        }
        return a.name.compareTo(b.name);
      });
  }

  /// Get a specific device by callsign
  RemoteDevice? getDevice(String callsign) {
    return _devices[callsign.toUpperCase()];
  }

  /// Check reachability of a device
  Future<bool> checkReachability(String callsign) async {
    final device = _devices[callsign.toUpperCase()];
    if (device == null) return false;

    if (device.url == null) {
      // Try to find via relay proxy
      return await _checkViaRelayProxy(device);
    }

    return await _checkDirectConnection(device);
  }

  /// Check device via relay proxy
  Future<bool> _checkViaRelayProxy(RemoteDevice device) async {
    // Get connected relay
    final relay = _relayService.getConnectedRelay();
    if (relay == null) return false;

    try {
      final baseUrl = relay.url.replaceFirst('ws://', 'http://').replaceFirst('wss://', 'https://');
      final response = await http.get(
        Uri.parse('$baseUrl/device/${device.callsign}'),
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final isConnected = data['connected'] == true;

        device.isOnline = isConnected;
        device.lastChecked = DateTime.now();
        _notifyListeners();

        return isConnected;
      }
    } catch (e) {
      LogService().log('DevicesService: Error checking device ${device.callsign}: $e');
    }

    device.isOnline = false;
    device.lastChecked = DateTime.now();
    _notifyListeners();
    return false;
  }

  /// Check device via direct connection
  Future<bool> _checkDirectConnection(RemoteDevice device) async {
    if (device.url == null) return false;

    try {
      final baseUrl = device.url!.replaceFirst('ws://', 'http://').replaceFirst('wss://', 'https://');
      final stopwatch = Stopwatch()..start();

      final response = await http.get(
        Uri.parse('$baseUrl/api/status'),
      ).timeout(const Duration(seconds: 5));

      stopwatch.stop();

      if (response.statusCode == 200) {
        device.isOnline = true;
        device.latency = stopwatch.elapsedMilliseconds;
        device.lastChecked = DateTime.now();
        _notifyListeners();
        return true;
      }
    } catch (e) {
      LogService().log('DevicesService: Error checking device ${device.callsign}: $e');
    }

    device.isOnline = false;
    device.lastChecked = DateTime.now();
    _notifyListeners();
    return false;
  }

  /// Check all devices reachability
  Future<void> refreshAllDevices() async {
    for (final device in _devices.values) {
      await checkReachability(device.callsign);
    }
  }

  /// Fetch collections from a remote device
  Future<List<RemoteCollection>> fetchCollections(String callsign) async {
    final device = _devices[callsign.toUpperCase()];
    if (device == null) return [];

    // First check if device is reachable
    final isOnline = await checkReachability(callsign);

    if (isOnline) {
      return await _fetchCollectionsOnline(device);
    } else {
      return await _loadCachedCollections(callsign);
    }
  }

  /// Fetch collections from online device
  Future<List<RemoteCollection>> _fetchCollectionsOnline(RemoteDevice device) async {
    final collections = <RemoteCollection>[];

    try {
      String baseUrl;

      if (device.url != null) {
        // Direct connection to device or relay
        baseUrl = device.url!.replaceFirst('ws://', 'http://').replaceFirst('wss://', 'https://');
      } else {
        // Via relay proxy
        final relay = _relayService.getConnectedRelay();
        if (relay == null) return [];
        baseUrl = '${relay.url.replaceFirst('ws://', 'http://').replaceFirst('wss://', 'https://')}/device/${device.callsign}';
      }

      LogService().log('DevicesService: Fetching collections from $baseUrl');

      // Fetch collection folders from /files endpoint
      try {
        final filesResponse = await http.get(
          Uri.parse('$baseUrl/files'),
        ).timeout(const Duration(seconds: 10));

        LogService().log('DevicesService: Files response: ${filesResponse.statusCode}');

        if (filesResponse.statusCode == 200) {
          final data = json.decode(filesResponse.body);
          LogService().log('DevicesService: Files data: $data');

          if (data['entries'] is List) {
            for (final entry in data['entries']) {
              if (entry['isDirectory'] == true || entry['type'] == 'directory') {
                final name = entry['name'] as String;
                final lowerName = name.toLowerCase();

                // Only include known collection types (same as local collections)
                if (_isKnownCollectionType(lowerName)) {
                  collections.add(RemoteCollection(
                    name: name,
                    deviceCallsign: device.callsign,
                    type: lowerName,
                    fileCount: entry['size'] is int ? entry['size'] : null,
                  ));
                }
              }
            }
          }
        }
      } catch (e) {
        LogService().log('DevicesService: Error fetching files: $e');
      }

      // If no collections found via /files, check if it's a relay with chat
      if (collections.isEmpty) {
        try {
          // Use callsign-scoped API: /{callsign}/api/chat/rooms
          final chatUrl = ChatApi.roomsUrl(baseUrl, device.callsign);
          final chatResponse = await http.get(
            Uri.parse(chatUrl),
          ).timeout(const Duration(seconds: 10));

          if (chatResponse.statusCode == 200) {
            final data = json.decode(chatResponse.body);
            if (data['rooms'] is List && (data['rooms'] as List).isNotEmpty) {
              // This relay has chat rooms, add a chat collection
              collections.add(RemoteCollection(
                name: 'Chat',
                deviceCallsign: device.callsign,
                type: 'chat',
                description: '${(data['rooms'] as List).length} rooms',
                fileCount: (data['rooms'] as List).length,
              ));
            }
          }
        } catch (e) {
          LogService().log('DevicesService: Error fetching chat rooms: $e');
        }
      }

      // Update device
      device.collections = collections;
      device.lastFetched = DateTime.now();

      // Cache the collections if we got any
      if (collections.isNotEmpty) {
        await _cacheCollections(device.callsign, collections);
      }

      _notifyListeners();
      return collections;
    } catch (e) {
      LogService().log('DevicesService: Error fetching collections from ${device.callsign}: $e');
    }

    return await _loadCachedCollections(device.callsign);
  }

  /// Check if folder name is a known collection type
  bool _isKnownCollectionType(String name) {
    const knownTypes = {
      'chat', 'forum', 'blog', 'events', 'news',
      'www', 'postcards', 'contacts', 'places',
      'market', 'alerts', 'groups',
    };
    return knownTypes.contains(name.toLowerCase());
  }

  /// Load cached collections for offline browsing
  Future<List<RemoteCollection>> _loadCachedCollections(String callsign) async {
    try {
      final cacheDir = await _cacheService.getDeviceCacheDir(callsign);
      if (cacheDir == null) return [];

      final collectionsFile = File('${cacheDir.path}/collections.json');

      if (await collectionsFile.exists()) {
        final content = await collectionsFile.readAsString();
        final data = json.decode(content) as List;

        return data.map((item) => RemoteCollection.fromJson(item, callsign)).toList();
      }
    } catch (e) {
      LogService().log('DevicesService: Error loading cached collections: $e');
    }

    return [];
  }

  /// Cache collections for offline access
  Future<void> _cacheCollections(String callsign, List<RemoteCollection> collections) async {
    try {
      final cacheDir = await _cacheService.getDeviceCacheDir(callsign);
      if (cacheDir == null) return;

      final collectionsFile = File('${cacheDir.path}/collections.json');

      final data = collections.map((c) => c.toJson()).toList();
      await collectionsFile.writeAsString(json.encode(data));
    } catch (e) {
      LogService().log('DevicesService: Error caching collections: $e');
    }
  }

  /// Add a device from discovery or manual entry
  Future<void> addDevice(String callsign, {String? name, String? url}) async {
    final normalizedCallsign = callsign.toUpperCase();

    if (!_devices.containsKey(normalizedCallsign)) {
      _devices[normalizedCallsign] = RemoteDevice(
        callsign: normalizedCallsign,
        name: name ?? normalizedCallsign,
        url: url,
        isOnline: false,
        hasCachedData: false,
        collections: [],
      );

      _notifyListeners();
    }
  }

  /// Remove a device
  Future<void> removeDevice(String callsign) async {
    final normalizedCallsign = callsign.toUpperCase();
    _devices.remove(normalizedCallsign);
    await _cacheService.clearCache(normalizedCallsign);
    _notifyListeners();
  }

  /// Notify listeners of changes
  void _notifyListeners() {
    _devicesController.add(getAllDevices());
  }

  /// Dispose resources
  void dispose() {
    _devicesController.close();
  }
}

/// Represents a remote device
class RemoteDevice {
  final String callsign;
  String name;
  String? url;
  bool isOnline;
  int? latency;
  DateTime? lastChecked;
  DateTime? lastSeen;
  DateTime? lastFetched;
  bool hasCachedData;
  List<RemoteCollection> collections;

  RemoteDevice({
    required this.callsign,
    required this.name,
    this.url,
    this.isOnline = false,
    this.latency,
    this.lastChecked,
    this.lastSeen,
    this.lastFetched,
    this.hasCachedData = false,
    required this.collections,
  });

  /// Get status string
  String get statusText {
    if (isOnline) {
      if (latency != null) {
        return 'Online (${latency}ms)';
      }
      return 'Online';
    }
    return 'Offline';
  }

  /// Get last activity time
  String get lastActivityText {
    final time = lastSeen ?? lastFetched ?? lastChecked;
    if (time == null) return 'Never';

    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${time.day}/${time.month}/${time.year}';
  }
}

/// Represents a collection on a remote device
class RemoteCollection {
  final String name;
  final String deviceCallsign;
  final String type;
  final String? description;
  final int? fileCount;
  final String? visibility;

  RemoteCollection({
    required this.name,
    required this.deviceCallsign,
    required this.type,
    this.description,
    this.fileCount,
    this.visibility,
  });

  factory RemoteCollection.fromJson(Map<String, dynamic> json, String deviceCallsign) {
    return RemoteCollection(
      name: json['name'] ?? json['id'] ?? 'Unknown',
      deviceCallsign: deviceCallsign,
      type: json['type'] ?? 'files',
      description: json['description'],
      fileCount: json['fileCount'] ?? json['file_count'],
      visibility: json['visibility'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'type': type,
      'description': description,
      'fileCount': fileCount,
      'visibility': visibility,
    };
  }

  /// Get icon for collection type
  String get iconName {
    switch (type) {
      case 'chat': return 'chat';
      case 'blog': return 'article';
      case 'forum': return 'forum';
      case 'contacts': return 'contacts';
      case 'events': return 'event';
      case 'places': return 'place';
      case 'news': return 'newspaper';
      case 'www': return 'language';
      case 'documents': return 'description';
      case 'photos': return 'photo_library';
      default: return 'folder';
    }
  }
}
