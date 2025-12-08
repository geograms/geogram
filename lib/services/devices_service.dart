/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'dart:async';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'dart:math';
import 'package:http/http.dart' as http;
import '../models/device_source.dart';
import '../models/station.dart';
import '../util/chat_api.dart';
import 'station_cache_service.dart';
import 'station_service.dart';
import 'station_discovery_service.dart';
import 'direct_message_service.dart';
import 'log_service.dart';

/// Service for managing remote devices we've contacted
class DevicesService {
  static final DevicesService _instance = DevicesService._internal();
  factory DevicesService() => _instance;
  DevicesService._internal();

  final RelayCacheService _cacheService = RelayCacheService();
  final StationService _stationService = StationService();
  final StationDiscoveryService _discoveryService = StationDiscoveryService();

  /// Cache of known devices with their status
  final Map<String, RemoteDevice> _devices = {};

  /// Stream controller for device updates
  final _devicesController = StreamController<List<RemoteDevice>>.broadcast();
  Stream<List<RemoteDevice>> get devicesStream => _devicesController.stream;

  /// Track when last local network scan was performed
  DateTime? _lastLocalScanTime;
  static const _localScanInterval = Duration(minutes: 5);

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
        final cachedRelayUrl = await _cacheService.getCachedRelayUrl(callsign);

        // Try to find matching station
        Station? matchingRelay;
        try {
          for (final station in _stationService.getAllStations()) {
            if (station.callsign?.toUpperCase() == callsign.toUpperCase()) {
              matchingRelay = station;
              break;
            }
          }
        } catch (e) {
          // StationService might not be initialized
        }

        // Use station URL if available, otherwise use cached station URL
        final deviceUrl = matchingRelay?.url ?? cachedRelayUrl;

        _devices[callsign] = RemoteDevice(
          callsign: callsign,
          name: matchingRelay?.name ?? callsign,
          url: deviceUrl,
          isOnline: false,
          lastSeen: cacheTime,
          hasCachedData: true,
          collections: [],
          latitude: matchingRelay?.latitude,
          longitude: matchingRelay?.longitude,
        );
      }

      // Also add known stations that might not have cache
      try {
        for (final station in _stationService.getAllStations()) {
          if (station.callsign != null && !_devices.containsKey(station.callsign!.toUpperCase())) {
            _devices[station.callsign!.toUpperCase()] = RemoteDevice(
              callsign: station.callsign!,
              name: station.name,
              url: station.url,
              isOnline: station.isConnected,
              lastSeen: station.lastChecked,
              hasCachedData: false,
              collections: [],
              latitude: station.latitude,
              longitude: station.longitude,
              connectionMethods: station.isConnected ? ['internet'] : [],
              source: DeviceSourceType.station,
            );
          }
        }
      } catch (e) {
        // StationService might not be initialized
      }

      _notifyListeners();
    } catch (e) {
      LogService().log('DevicesService: Error loading cached devices: $e');
    }
  }

  /// Get all known devices
  /// Sorted: Online first, then by name, unreachable at bottom
  List<RemoteDevice> getAllDevices() {
    return _devices.values.toList()
      ..sort((a, b) {
        // Online devices first, then by name
        if (a.isOnline != b.isOnline) {
          return a.isOnline ? -1 : 1;
        }
        // Then sort by display name
        return a.displayName.compareTo(b.displayName);
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

    // Store previous online state to detect transitions
    final wasOnline = device.isOnline;

    bool directOk = false;
    bool proxyOk = false;

    // Try direct connection first (local WiFi) if device has a URL
    if (device.url != null) {
      directOk = await _checkDirectConnection(device);
    }

    // Always check via station proxy for internet connectivity
    proxyOk = await _checkViaRelayProxy(device);

    // Device is online if ANY connection method works
    final isNowOnline = directOk || proxyOk;
    device.isOnline = isNowOnline;
    _notifyListeners();

    // Trigger DM sync when device becomes reachable
    if (!wasOnline && isNowOnline && device.url != null) {
      _triggerDMSync(device.callsign, device.url!);
    }

    return isNowOnline;
  }

  /// Trigger DM sync with a device that just came online
  void _triggerDMSync(String callsign, String deviceUrl) {
    LogService().log('DevicesService: Device $callsign came online, triggering DM sync');

    // Run sync in background (don't await)
    DirectMessageService().syncWithDevice(callsign, deviceUrl: deviceUrl).then((result) {
      if (result.success) {
        LogService().log('DevicesService: DM sync with $callsign completed - received: ${result.messagesReceived}, sent: ${result.messagesSent}');
      } else {
        LogService().log('DevicesService: DM sync with $callsign failed: ${result.error}');
      }
    }).catchError((e) {
      LogService().log('DevicesService: DM sync with $callsign error: $e');
    });
  }

  /// Check device via station proxy
  Future<bool> _checkViaRelayProxy(RemoteDevice device) async {
    // Get connected station
    final station = _stationService.getConnectedRelay();
    if (station == null) {
      // No station connection - remove 'internet' from connectionMethods
      device.connectionMethods = device.connectionMethods
          .where((m) => m != 'internet')
          .toList();
      return false;
    }

    try {
      final baseUrl = station.url.replaceFirst('ws://', 'http://').replaceFirst('wss://', 'https://');
      final response = await http.get(
        Uri.parse('$baseUrl/device/${device.callsign}'),
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final isConnected = data['connected'] == true;

        device.isOnline = isConnected;
        device.lastChecked = DateTime.now();

        // Update connectionMethods based on result
        if (isConnected) {
          if (!device.connectionMethods.contains('internet')) {
            device.connectionMethods = [...device.connectionMethods, 'internet'];
          }
        } else {
          // Device not connected via station - remove 'internet' tag
          device.connectionMethods = device.connectionMethods
              .where((m) => m != 'internet')
              .toList();
        }

        _notifyListeners();
        return isConnected;
      }
    } catch (e) {
      LogService().log('DevicesService: Error checking device ${device.callsign}: $e');
    }

    // Failed to check - remove 'internet' from connectionMethods
    device.connectionMethods = device.connectionMethods
        .where((m) => m != 'internet')
        .toList();
    device.isOnline = device.connectionMethods.isNotEmpty; // Online if other methods exist
    device.lastChecked = DateTime.now();
    _notifyListeners();
    return false;
  }

  /// Check device via direct connection (local WiFi)
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

        // Add local connection method if not present
        if (!device.connectionMethods.contains('wifi_local') &&
            !device.connectionMethods.contains('lan')) {
          device.connectionMethods = [...device.connectionMethods, 'wifi_local'];
        }

        _notifyListeners();
        return true;
      }
    } catch (e) {
      LogService().log('DevicesService: Direct connection to ${device.callsign} failed: $e');
    }

    // Direct connection failed - remove local connection methods
    device.connectionMethods = device.connectionMethods
        .where((m) => m != 'wifi_local' && m != 'lan')
        .toList();
    // Don't set isOnline = false here - let the caller try other methods
    device.lastChecked = DateTime.now();
    _notifyListeners();
    return false;
  }

  /// Check all devices reachability
  Future<void> refreshAllDevices() async {
    // First, ensure connected station is in device list with 'internet' tag
    await _updateConnectedStation();

    // Then, fetch connected clients from connected station (internet)
    await _fetchStationClients();

    // Then discover devices on local WiFi network
    await _discoverLocalDevices();

    // Finally check reachability for all known devices
    for (final device in _devices.values) {
      await checkReachability(device.callsign);
    }
  }

  /// Update the connected station as a device with 'internet' connection
  Future<void> _updateConnectedStation() async {
    try {
      final station = _stationService.getConnectedRelay();
      if (station == null || station.callsign == null) return;

      final normalizedCallsign = station.callsign!.toUpperCase();

      if (_devices.containsKey(normalizedCallsign)) {
        // Update existing device
        final device = _devices[normalizedCallsign]!;
        device.isOnline = true;
        device.url = station.url;
        device.latitude = station.latitude;
        device.longitude = station.longitude;
        device.lastSeen = DateTime.now();
        // Ensure 'internet' tag is present
        if (!device.connectionMethods.contains('internet')) {
          device.connectionMethods = [...device.connectionMethods, 'internet'];
        }
        device.source = DeviceSourceType.station;
        LogService().log('DevicesService: Updated connected station: $normalizedCallsign');
      } else {
        // Add new device for the station
        _devices[normalizedCallsign] = RemoteDevice(
          callsign: normalizedCallsign,
          name: station.name,
          url: station.url,
          isOnline: true,
          hasCachedData: false,
          collections: [],
          latitude: station.latitude,
          longitude: station.longitude,
          connectionMethods: ['internet'],
          source: DeviceSourceType.station,
          lastSeen: DateTime.now(),
        );
        LogService().log('DevicesService: Added connected station as device: $normalizedCallsign');
      }

      _notifyListeners();
    } catch (e) {
      LogService().log('DevicesService: Error updating connected station: $e');
    }
  }

  /// Discover devices on local WiFi network (both clients and stations)
  Future<void> _discoverLocalDevices({bool force = false}) async {
    try {
      final now = DateTime.now();
      final shouldFullScan = force ||
          _lastLocalScanTime == null ||
          now.difference(_lastLocalScanTime!) > _localScanInterval;

      if (shouldFullScan) {
        // Full network scan
        LogService().log('DevicesService: Full local network scan (last: $_lastLocalScanTime)');
        _lastLocalScanTime = now;
        await _performFullLocalScan();
      } else {
        // Just check reachability of known local devices (fast)
        LogService().log('DevicesService: Quick reachability check for known local devices');
        await _checkLocalDevicesReachability();
      }
    } catch (e) {
      LogService().log('DevicesService: Error discovering local devices: $e');
    }
  }

  /// Force a full local network scan (resets the scan timer)
  Future<void> forceLocalScan() async {
    await _discoverLocalDevices(force: true);
  }

  /// Perform a full network scan for local devices
  Future<void> _performFullLocalScan() async {
    LogService().log('DevicesService: Scanning local network for devices...');

    // Use quick scan (500ms timeout) for faster discovery
    final results = await _discoveryService.scanWithProgress(
      timeoutMs: 500,
    );

    LogService().log('DevicesService: Found ${results.length} devices on local network');

    for (final result in results) {
      // Skip if no callsign
      if (result.callsign == null || result.callsign!.isEmpty) continue;

      final normalizedCallsign = result.callsign!.toUpperCase();

      // Build local URL for direct connection
      final localUrl = 'http://${result.ip}:${result.port}';

      // Determine connection type based on discovery type
      final connectionType = result.type == 'station' ? 'lan' : 'wifi_local';

      // Update existing device or create new one
      if (_devices.containsKey(normalizedCallsign)) {
        final device = _devices[normalizedCallsign]!;

        // Add connection type if not already present
        if (!device.connectionMethods.contains(connectionType)) {
          device.connectionMethods = [...device.connectionMethods, connectionType];
        }

        // Store local URL for direct connection (prefer local over internet)
        device.url = localUrl;
        device.isOnline = true;
        device.lastSeen = DateTime.now();

        LogService().log('DevicesService: Updated ${result.type} $normalizedCallsign with local network ($localUrl)');
      } else {
        // Create new device discovered on local network
        _devices[normalizedCallsign] = RemoteDevice(
          callsign: normalizedCallsign,
          name: result.name ?? normalizedCallsign,
          nickname: result.name,
          url: localUrl,
          isOnline: true,
          hasCachedData: false,
          collections: [],
          latitude: result.latitude,
          longitude: result.longitude,
          connectionMethods: [connectionType],
          source: DeviceSourceType.local,
          lastSeen: DateTime.now(),
        );
        LogService().log('DevicesService: Added new ${result.type} from local network: $normalizedCallsign at $localUrl');
      }
    }

    _notifyListeners();
  }

  /// Check reachability of previously discovered local devices (fast)
  Future<void> _checkLocalDevicesReachability() async {
    final localDevices = _devices.values.where((d) =>
        d.connectionMethods.contains('wifi_local') ||
        d.connectionMethods.contains('lan')).toList();

    LogService().log('DevicesService: Checking ${localDevices.length} known local devices');

    for (final device in localDevices) {
      if (device.url != null) {
        await _checkDirectConnection(device);
      }
    }

    _notifyListeners();
  }

  /// Fetch connected devices from the connected station
  Future<void> _fetchStationClients() async {
    try {
      final station = _stationService.getConnectedRelay();
      if (station == null) {
        LogService().log('DevicesService: No connected station to fetch devices from');
        return;
      }

      // Convert WebSocket URL to HTTP and extract base (remove path like /ws)
      var baseUrl = station.url
          .replaceFirst('ws://', 'http://')
          .replaceFirst('wss://', 'https://');

      // Remove any path component (e.g., /ws) to get the base URL
      final uri = Uri.parse(baseUrl);
      baseUrl = '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';

      final url = '$baseUrl/api/devices';
      LogService().log('DevicesService: Fetching devices from: $url');

      List<dynamic>? devices;

      try {
        final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));

        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          devices = data['devices'] as List<dynamic>?;
        }
      } catch (e) {
        LogService().log('DevicesService: Failed to fetch devices: $e');
      }

      if (devices == null) {
        LogService().log('DevicesService: No devices endpoint available on station');
        return;
      }

      LogService().log('DevicesService: Received ${devices.length} devices from /api/devices');

      for (final deviceData in devices) {
        final callsign = deviceData['callsign'] as String?;
        if (callsign == null || callsign.isEmpty || callsign == 'Unknown') {
          LogService().log('DevicesService: Skipping device with no callsign');
          continue;
        }

        final normalizedCallsign = callsign.toUpperCase();

        // Parse connection types - default to 'internet' if connected via station
        final connectionTypes = <String>[];
        final rawTypes = deviceData['connection_types'] as List<dynamic>?;
        if (rawTypes != null && rawTypes.isNotEmpty) {
          for (final t in rawTypes) {
            connectionTypes.add(t.toString());
          }
        } else {
          // Default to internet since device is connected via station
          connectionTypes.add('internet');
        }

        // Update existing device or create new one
        if (_devices.containsKey(normalizedCallsign)) {
          final device = _devices[normalizedCallsign]!;
          device.isOnline = true;
          device.nickname = deviceData['nickname'] as String?;
          device.npub = deviceData['npub'] as String?;
          device.latitude = deviceData['latitude'] as double?;
          device.longitude = deviceData['longitude'] as double?;
          // Merge connection methods - ensure at least 'internet' is present
          for (final method in connectionTypes) {
            if (!device.connectionMethods.contains(method)) {
              device.connectionMethods = [...device.connectionMethods, method];
            }
          }
          // Ensure 'internet' tag if no connection methods
          if (device.connectionMethods.isEmpty) {
            device.connectionMethods = ['internet'];
          }
          device.source = DeviceSourceType.station;
          device.lastSeen = DateTime.now();
          LogService().log('DevicesService: Updated device: $normalizedCallsign');
        } else {
          // Create new device from station
          _devices[normalizedCallsign] = RemoteDevice(
            callsign: normalizedCallsign,
            name: deviceData['nickname'] as String? ?? normalizedCallsign,
            nickname: deviceData['nickname'] as String?,
            npub: deviceData['npub'] as String?,
            isOnline: true,
            hasCachedData: false,
            collections: [],
            latitude: deviceData['latitude'] as double?,
            longitude: deviceData['longitude'] as double?,
            connectionMethods: connectionTypes,
            source: DeviceSourceType.station,
            lastSeen: DateTime.now(),
          );
          LogService().log('DevicesService: Added new device from station: $normalizedCallsign');
        }
      }

      _notifyListeners();
      LogService().log('DevicesService: Fetched ${devices.length} devices from station ${station.name}');
    } catch (e) {
      LogService().log('DevicesService: Error fetching station clients: $e');
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
    List<RemoteCollection> collections = [];

    // Try direct connection first if URL is set
    if (device.url != null) {
      final directUrl = device.url!.replaceFirst('ws://', 'http://').replaceFirst('wss://', 'https://');
      collections = await _fetchCollectionsFromUrl(device, directUrl);
    }

    // Fallback to station proxy if direct failed or no URL
    if (collections.isEmpty) {
      final station = _stationService.getConnectedRelay();
      if (station != null) {
        final proxyUrl = '${station.url.replaceFirst('ws://', 'http://').replaceFirst('wss://', 'https://')}/device/${device.callsign}';
        collections = await _fetchCollectionsFromUrl(device, proxyUrl);
      }
    }

    // Update device and cache if we got collections
    if (collections.isNotEmpty) {
      await _updateDeviceCollections(device, collections);
      return collections;
    }

    // Fall back to cached collections
    return await _loadCachedCollections(device.callsign);
  }

  /// Fetch collections from a specific URL
  Future<List<RemoteCollection>> _fetchCollectionsFromUrl(RemoteDevice device, String baseUrl) async {
    final collections = <RemoteCollection>[];

    try {
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

      // If no collections found via /files, check if it's a station with chat
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
              // This station has chat rooms, add a chat collection
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

      return collections;
    } catch (e) {
      LogService().log('DevicesService: Error fetching collections from $baseUrl: $e');
    }

    return [];
  }

  /// Update device with fetched collections and cache them
  Future<void> _updateDeviceCollections(RemoteDevice device, List<RemoteCollection> collections) async {
    device.collections = collections;
    device.lastFetched = DateTime.now();

    // Cache the collections if we got any
    if (collections.isNotEmpty) {
      await _cacheCollections(device.callsign, collections);
    }

    _notifyListeners();
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
  String? nickname;
  String? url;
  String? npub;
  bool isOnline;
  int? latency;
  DateTime? lastChecked;
  DateTime? lastSeen;
  DateTime? lastFetched;
  bool hasCachedData;
  List<RemoteCollection> collections;
  double? latitude;
  double? longitude;
  List<String> connectionMethods;
  DeviceSourceType source;

  RemoteDevice({
    required this.callsign,
    required this.name,
    this.nickname,
    this.url,
    this.npub,
    this.isOnline = false,
    this.latency,
    this.lastChecked,
    this.lastSeen,
    this.lastFetched,
    this.hasCachedData = false,
    required this.collections,
    this.latitude,
    this.longitude,
    this.connectionMethods = const [],
    this.source = DeviceSourceType.local,
  });

  /// Get display name (nickname or callsign)
  String get displayName => nickname ?? name;

  /// Get connection method display label
  static String getConnectionMethodLabel(String method) {
    switch (method.toLowerCase()) {
      case 'wifi':
      case 'wifi_local':
      case 'wifi-local':
        return 'Wi-Fi Local';
      case 'internet':
        return 'Internet';
      case 'bluetooth':
        return 'Bluetooth';
      case 'lora':
        return 'LoRa';
      case 'radio':
        return 'Radio';
      case 'esp32mesh':
      case 'esp32_mesh':
        return 'ESP32 Mesh';
      case 'wifi_halow':
      case 'wifi-halow':
      case 'halow':
        return 'Wi-Fi HaLow';
      case 'lan':
        return 'LAN';
      default:
        return method;
    }
  }

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

  /// Calculate distance from given coordinates using Haversine formula
  /// Returns distance in kilometers, or null if location is unavailable
  double? calculateDistance(double? userLat, double? userLon) {
    if (latitude == null || longitude == null || userLat == null || userLon == null) {
      return null;
    }

    const double earthRadiusKm = 6371.0;

    final dLat = _degreesToRadians(userLat - latitude!);
    final dLon = _degreesToRadians(userLon - longitude!);

    final lat1 = _degreesToRadians(latitude!);
    final lat2 = _degreesToRadians(userLat);

    final a = (sin(dLat / 2) * sin(dLat / 2)) +
              (sin(dLon / 2) * sin(dLon / 2)) * cos(lat1) * cos(lat2);

    final c = 2 * atan2(sqrt(a), sqrt(1 - a));

    return earthRadiusKm * c;
  }

  static double _degreesToRadians(double degrees) {
    return degrees * pi / 180;
  }

  /// Get human-readable distance string
  String? getDistanceString(double? userLat, double? userLon) {
    final distance = calculateDistance(userLat, userLon);
    if (distance == null) return null;

    if (distance < 1) {
      return '${(distance * 1000).round()} m away';
    } else {
      return '${distance.round()} km away';
    }
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
