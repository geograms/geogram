import 'dart:async';
import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import '../connection/connection_manager.dart';
import 'station_cache_service.dart';
import '../models/station.dart';
import '../models/station_chat_room.dart';
import '../models/update_notification.dart';
import '../services/config_service.dart';
import '../services/log_service.dart';
import '../services/websocket_service.dart';
import '../services/profile_service.dart';
import '../services/chat_notification_service.dart';
import '../services/signing_service.dart';
import '../services/station_chat_queue_service.dart';
import '../util/nostr_event.dart';
import '../util/nostr_crypto.dart';
import '../util/reaction_utils.dart';

class _StationApiResponse {
  final int statusCode;
  final String body;
  final String? transportUsed;

  const _StationApiResponse({
    required this.statusCode,
    required this.body,
    this.transportUsed,
  });
}

class StationSendResult {
  final bool sent;
  final int? createdAt;
  final String? eventId;
  final String? signature;
  final String? pubkey;
  final String? npub;

  StationSendResult({
    required this.sent,
    this.createdAt,
    this.eventId,
    this.signature,
    this.pubkey,
    this.npub,
  });
}

/// Service for managing internet stations
class StationService {
  static final StationService _instance = StationService._internal();
  factory StationService() => _instance;
  StationService._internal();

  List<Station> _stations = [];
  bool _initialized = false;
  final WebSocketService _wsService = WebSocketService();

  /// Shared HTTP client for connection pooling (avoids creating a new socket per request)
  final http.Client _httpClient = http.Client();

  /// Default stations
  static final List<Station> _defaultStations = [
    Station(
      url: 'wss://p2p.radio',
      name: 'P2P Radio',
      description: 'Public station for the geogram network',
      status: 'preferred',
    ),
  ];

  /// Initialize station service
  Future<void> initialize() async {
    if (_initialized) {
      // Already initialized, but check if we need to reconnect
      await _ensureConnected();
      return;
    }

    try {
      await _loadStations();
      _initialized = true;
      LogService().log('StationService initialized with ${_stations.length} stations');

      // Auto-connect to preferred station
      await _ensureConnected();
    } catch (e) {
      LogService().log('Error initializing StationService: $e');
    }
  }

  /// Check if the station service is initialized.
  bool get isInitialized => _initialized;

  /// Ensure connection to preferred station
  Future<void> _ensureConnected() async {
    // Check if WebSocket is actually connected
    if (_wsService.isConnected) {
      LogService().log('StationService: WebSocket already connected');
      return;
    }

    // Auto-connect to preferred station
    final preferredStation = getPreferredStation();
    if (preferredStation != null && preferredStation.url.isNotEmpty) {
      LogService().log('Auto-connecting to preferred station: ${preferredStation.name}');
      connectStation(preferredStation.url);
    }
  }

  /// Load stations from config
  Future<void> _loadStations() async {
    final config = ConfigService().getAll();

    if (config.containsKey('stations')) {
      final stationsData = config['stations'] as List<dynamic>;
      _stations = stationsData.map((data) => Station.fromJson(data as Map<String, dynamic>)).toList();

      // Filter out client devices (X1 callsigns) - only stations (X3) should be listed
      final beforeFilterCount = _stations.length;
      _stations = _stations.where((s) => !_isClientCallsign(s.callsign)).toList();
      if (_stations.length < beforeFilterCount) {
        LogService().log('Removed ${beforeFilterCount - _stations.length} client device(s) from station list');
      }

      // Reset connection state - connection status shouldn't persist across app restarts
      for (var i = 0; i < _stations.length; i++) {
        if (_stations[i].isConnected) {
          print('DEBUG StationService: Resetting isConnected for ${_stations[i].name}');
          _stations[i] = _stations[i].copyWith(isConnected: false);
        }
      }

      // Deduplicate stations with same callsign (e.g., 127.0.0.1 vs LAN IP)
      final beforeCount = _stations.length;
      _stations = _deduplicateStations(_stations);
      if (_stations.length < beforeCount) {
        LogService().log('Merged ${beforeCount - _stations.length} duplicate station entries');
      }

      // Save if we filtered or deduplicated
      if (_stations.length < beforeFilterCount) {
        _saveStations();
      }

      print('DEBUG StationService: After reset, stations=${_stations.map((r) => "${r.name}:${r.isConnected}").toList()}');
      LogService().log('Loaded ${_stations.length} stations from config');
    } else {
      // First time - use default stations
      _stations = _defaultStations.map((r) => r.copyWith()).toList();

      // Set first as preferred
      if (_stations.isNotEmpty) {
        _stations[0] = _stations[0].copyWith(status: 'preferred');
      }

      _saveStations();
      LogService().log('Created default station configuration');
    }
  }

  /// Save stations to config
  void _saveStations() {
    final stationsData = _stations.map((r) => r.toJson()).toList();
    ConfigService().set('stations', stationsData);
    LogService().log('Saved ${_stations.length} stations to config');
  }

  /// Deduplicate stations with same callsign (e.g., localhost vs LAN IP)
  /// Prefers non-localhost URLs and entries with more info
  List<Station> _deduplicateStations(List<Station> stations) {
    if (stations.isEmpty) return stations;

    final Map<String, Station> uniqueRelays = {};

    for (var station in stations) {
      // Create a unique key based on callsign+port, or name+port if no callsign
      String key;
      final uri = Uri.tryParse(station.url);
      final port = uri?.port ?? 8080;

      if (station.callsign != null && station.callsign!.isNotEmpty) {
        // Use callsign + port as key (same station on different IPs has same callsign)
        key = '${station.callsign}:$port';
      } else if (station.name.isNotEmpty) {
        // Fallback to name + port
        key = '${station.name}:$port';
      } else {
        // No way to identify, keep all entries (use URL as key)
        key = station.url;
      }

      if (uniqueRelays.containsKey(key)) {
        final existing = uniqueRelays[key]!;
        // Prefer non-localhost entry (LAN IP is more useful for other devices)
        final existingIsLocalhost = existing.url.contains('127.0.0.1') || existing.url.contains('localhost');
        final newIsLocalhost = station.url.contains('127.0.0.1') || station.url.contains('localhost');

        if (existingIsLocalhost && !newIsLocalhost) {
          // Replace localhost with LAN IP, preserve status
          uniqueRelays[key] = station.copyWith(status: existing.status);
        } else if (!existingIsLocalhost && newIsLocalhost) {
          // Keep the existing LAN IP
        } else if (_stationHasMoreInfo(station, existing)) {
          // Keep the one with more info, preserve status
          uniqueRelays[key] = station.copyWith(status: existing.status);
        }
        // Otherwise keep existing
      } else {
        uniqueRelays[key] = station;
      }
    }

    return uniqueRelays.values.toList();
  }

  /// Check if station a has more info than station b
  bool _stationHasMoreInfo(Station a, Station b) {
    int scoreA = 0;
    int scoreB = 0;

    if (a.callsign != null && a.callsign!.isNotEmpty) scoreA++;
    if (b.callsign != null && b.callsign!.isNotEmpty) scoreB++;

    if (a.location != null && a.location!.isNotEmpty) scoreA++;
    if (b.location != null && b.location!.isNotEmpty) scoreB++;

    if (a.latitude != null) scoreA++;
    if (b.latitude != null) scoreB++;

    if (a.connectedDevices != null) scoreA++;
    if (b.connectedDevices != null) scoreB++;

    return scoreA > scoreB;
  }

  /// Get all stations
  List<Station> getAllStations() {
    if (!_initialized) {
      throw Exception('StationService not initialized');
    }
    return List.unmodifiable(_stations);
  }

  /// Get preferred station
  Station? getPreferredStation() {
    return _stations.firstWhere(
      (r) => r.status == 'preferred',
      orElse: () => _stations.isNotEmpty ? _stations[0] : Station(url: '', name: ''),
    );
  }

  /// Get backup stations
  List<Station> getBackupStations() {
    return _stations.where((r) => r.status == 'backup').toList();
  }

  /// Get available stations (not selected)
  List<Station> getAvailableStations() {
    return _stations.where((r) => r.status == 'available').toList();
  }

  /// Add a new station
  /// Returns true if station was added, false if it already exists or is a client
  Future<bool> addStation(Station station) async {
    // Reject client devices (X1 callsigns) - only stations (X3) can be added
    if (_isClientCallsign(station.callsign)) {
      LogService().log('Rejected client device: ${station.callsign} (only stations allowed)');
      return false;
    }

    // Check if URL already exists
    final existsByUrl = _stations.any((r) => r.url == station.url);
    if (existsByUrl) {
      LogService().log('Station URL already exists: ${station.url}');
      return false;
    }

    // Check if callsign already exists (same station on different IP)
    if (station.callsign != null && station.callsign!.isNotEmpty) {
      final existsByCallsign = _stations.indexWhere(
        (r) => r.callsign == station.callsign && r.callsign != null,
      );
      if (existsByCallsign != -1) {
        final existing = _stations[existsByCallsign];
        // Update existing entry if new one has better URL (non-localhost)
        final existingIsLocalhost = existing.url.contains('127.0.0.1') || existing.url.contains('localhost');
        final newIsLocalhost = station.url.contains('127.0.0.1') || station.url.contains('localhost');

        if (existingIsLocalhost && !newIsLocalhost) {
          // Replace localhost with LAN IP
          _stations[existsByCallsign] = station.copyWith(status: existing.status);
          _saveStations();
          LogService().log('Updated station URL from localhost to ${station.url}');
          return true;
        } else {
          LogService().log('Station with callsign ${station.callsign} already exists at ${existing.url}');
          return false;
        }
      }
    }

    _stations.add(station);
    _saveStations();
    LogService().log('Added station: ${station.name}');
    return true;
  }

  /// Update station
  Future<void> updateStation(String url, Station updatedRelay) async {
    final index = _stations.indexWhere((r) => r.url == url);
    if (index == -1) {
      throw Exception('Station not found');
    }

    _stations[index] = updatedRelay;
    _saveStations();
    LogService().log('Updated station: ${updatedRelay.name}');
  }

  /// Set station as preferred
  Future<void> setPreferred(String url) async {
    // Remove preferred status from all stations
    for (var i = 0; i < _stations.length; i++) {
      if (_stations[i].status == 'preferred') {
        _stations[i] = _stations[i].copyWith(status: 'available');
      }
    }

    // Set new preferred
    final index = _stations.indexWhere((r) => r.url == url);
    if (index != -1) {
      _stations[index] = _stations[index].copyWith(status: 'preferred');
      _saveStations();
      LogService().log('Set preferred station: ${_stations[index].name}');
    }
  }

  /// Set station as backup
  /// Automatically switches preferred station if current preferred is being set as backup
  Future<void> setBackup(String url) async {
    final index = _stations.indexWhere((r) => r.url == url);
    if (index == -1) return;

    final wasPreferred = _stations[index].status == 'preferred';

    // Set the station as backup
    _stations[index] = _stations[index].copyWith(status: 'backup');

    // If this was the preferred station, we need to select a new preferred
    if (wasPreferred) {
      LogService().log('Current preferred station being set as backup, selecting new preferred...');

      // First, try to find another backup station
      Station? newPreferred;
      for (var station in _stations) {
        if (station.status == 'backup' && station.url != url) {
          newPreferred = station;
          break;
        }
      }

      // If no backup station, find closest available station
      if (newPreferred == null) {
        final profile = ProfileService().getProfile();
        final availableRelays = _stations.where((r) => r.status == 'available').toList();

        if (availableRelays.isNotEmpty) {
          if (profile.latitude != null && profile.longitude != null) {
            // Sort by distance
            availableRelays.sort((a, b) {
              final distA = a.calculateDistance(profile.latitude, profile.longitude) ?? double.infinity;
              final distB = b.calculateDistance(profile.latitude, profile.longitude) ?? double.infinity;
              return distA.compareTo(distB);
            });
            newPreferred = availableRelays.first;
            LogService().log('Selected closest available station: ${newPreferred.name}');
          } else {
            // No location available, just pick the first available
            newPreferred = availableRelays.first;
            LogService().log('No location available, selected first available station: ${newPreferred.name}');
          }
        }
      } else {
        LogService().log('Selected next backup station as preferred: ${newPreferred.name}');
      }

      // Set the new preferred station
      if (newPreferred != null) {
        final newIndex = _stations.indexWhere((r) => r.url == newPreferred!.url);
        if (newIndex != -1) {
          _stations[newIndex] = _stations[newIndex].copyWith(status: 'preferred');
        }
      } else {
        LogService().log('WARNING: No other station available to set as preferred!');
      }
    }

    _saveStations();
    LogService().log('Set backup station: ${_stations[index].name}');
  }

  /// Set station as available (unselect)
  Future<void> setAvailable(String url) async {
    final index = _stations.indexWhere((r) => r.url == url);
    if (index != -1) {
      _stations[index] = _stations[index].copyWith(status: 'available');
      _saveStations();
      LogService().log('Set station as available: ${_stations[index].name}');
    }
  }

  /// Delete station
  Future<void> deleteStation(String url) async {
    final index = _stations.indexWhere((r) => r.url == url);
    if (index != -1) {
      final station = _stations[index];
      _stations.removeAt(index);
      _saveStations();
      LogService().log('Deleted station: ${station.name}');
    }
  }

  /// Test station connection (stub for now)
  Future<void> testConnection(String url) async {
    final index = _stations.indexWhere((r) => r.url == url);
    if (index != -1) {
      // Simulate connection test
      await Future.delayed(const Duration(seconds: 1));

      // For now, just update last checked time
      _stations[index] = _stations[index].copyWith(
        lastChecked: DateTime.now(),
        isConnected: true,
        latency: 50 + (url.hashCode % 100), // Simulated latency
      );

      _saveStations();
      LogService().log('Tested station: ${_stations[index].name}');
    }
  }

  /// Connect to station with hello handshake
  Future<bool> connectStation(String url) async {
    try {
      LogService().log('');
      LogService().log('══════════════════════════════════════');
      LogService().log('STATION CONNECTION REQUEST');
      LogService().log('══════════════════════════════════════');
      LogService().log('URL: $url');

      // Disconnect existing connection if any
      if (_wsService.isConnected) {
        LogService().log('Disconnecting previous connection...');
        _wsService.disconnect();
      }

      // Attempt connection with hello handshake
      final startTime = DateTime.now();
      final success = await _wsService.connectAndHello(url);

      if (success) {
        final latency = DateTime.now().difference(startTime).inMilliseconds;

        // Fetch station status to get connected devices count, callsign, name and description
        int? connectedDevices;
        String? stationCallsign;
        String? stationName;
        String? stationDescription;
        double? stationLatitude;
        double? stationLongitude;
        try {
          final station = _resolveStation(url);
          final response = await _stationApiRequest(
            stationUrl: url,
            method: 'GET',
            path: '/api/status',
            stationCallsign: station.callsign,
          );
          if (response != null && response.statusCode == 200) {
            final data = jsonDecode(response.body);
            connectedDevices = data['connected_devices'] as int?;
            stationCallsign = data['callsign'] as String?;
            stationName = data['name'] as String?;
            stationDescription = data['description'] as String?;

            // Extract location from response (can be Map or String)
            final locationData = data['location'];
            if (locationData is Map<String, dynamic>) {
              stationLatitude = (locationData['latitude'] as num?)?.toDouble();
              stationLongitude = (locationData['longitude'] as num?)?.toDouble();
            }
            // Also check top-level latitude/longitude (used by p2p.radio)
            stationLatitude ??= (data['latitude'] as num?)?.toDouble();
            stationLongitude ??= (data['longitude'] as num?)?.toDouble();

            LogService().log('Fetched station status: $connectedDevices devices connected');
            if (stationCallsign != null && stationCallsign.isNotEmpty) {
              LogService().log('Station callsign: $stationCallsign');
            }
            if (stationName != null && stationName.isNotEmpty) {
              LogService().log('Station name: $stationName');
            }
          }
        } catch (e) {
          LogService().log('Warning: Could not fetch station status: $e');
        }

        // Update station status
        final index = _stations.indexWhere((r) => r.url == url);
        if (index != -1) {
          _stations[index] = _stations[index].copyWith(
            lastChecked: DateTime.now(),
            isConnected: true,
            latency: latency,
            connectedDevices: connectedDevices,
            callsign: stationCallsign,
            name: stationName ?? _stations[index].name,
            description: stationDescription,
            latitude: stationLatitude,
            longitude: stationLongitude,
          );
          _saveStations();

          LogService().log('');
          LogService().log('✓ CONNECTION SUCCESSFUL');
          LogService().log('Station: ${_stations[index].name}');
          if (stationCallsign != null && stationCallsign.isNotEmpty) {
            LogService().log('Callsign: $stationCallsign');
          }
          if (_stations[index].description != null && _stations[index].description!.isNotEmpty) {
            LogService().log('Description: ${_stations[index].description}');
          }
          LogService().log('Latency: ${latency}ms');
          if (connectedDevices != null) {
            LogService().log('Connected devices: $connectedDevices');
          }
          LogService().log('══════════════════════════════════════');
        }

        // Notify ChatNotificationService to reconnect to the updates stream
        ChatNotificationService().reconnect();

        // Sync all chat rooms in background so UI opens instantly
        unawaited(ChatNotificationService().syncAllRooms());

        // Process any queued station chat messages
        final queueService = StationChatQueueService();
        unawaited(queueService.initialize());
        final queueKey = stationCallsign ?? _stations[index].callsign ?? '';
        if (queueKey.isNotEmpty) {
          unawaited(queueService.processQueue(stationCallsign: queueKey));
        }

        return true;
      } else {
        LogService().log('');
        LogService().log('✗ CONNECTION FAILED');
        LogService().log('══════════════════════════════════════');

        // Update station as disconnected
        final index = _stations.indexWhere((r) => r.url == url);
        if (index != -1) {
          _stations[index] = _stations[index].copyWith(
            lastChecked: DateTime.now(),
            isConnected: false,
          );
          _saveStations();
        }

        return false;
      }
    } catch (e) {
      LogService().log('');
      LogService().log('CONNECTION ERROR');
      LogService().log('══════════════════════════════════════');
      LogService().log('Error: $e');
      LogService().log('══════════════════════════════════════');
      return false;
    }
  }

  /// Disconnect from current station
  void disconnect() {
    if (_wsService.isConnected) {
      LogService().log('Disconnecting from station...');
      _wsService.disconnect();

      // Update all stations as disconnected
      for (var i = 0; i < _stations.length; i++) {
        if (_stations[i].isConnected) {
          _stations[i] = _stations[i].copyWith(isConnected: false);
        }
      }
      _saveStations();
    }
  }

  /// Get currently connected station
  /// First checks Station model's isConnected flag, then falls back to checking
  /// actual WebSocket connection state (handles auto-connect scenarios)
  Station? getConnectedStation() {
    // First try to find a station marked as connected
    try {
      return _stations.firstWhere((r) => r.isConnected);
    } catch (e) {
      // No station marked as connected, check actual WebSocket state
    }

    // Fallback: Check if WebSocket is actually connected and return matching station
    final connectedUrl = _wsService.connectedUrl;
    if (connectedUrl != null && _wsService.isConnected) {
      try {
        return _stations.firstWhere((r) => r.url == connectedUrl);
      } catch (e) {
        // WebSocket is connected but URL not in stations list
        // Return a temporary Station object for the connected URL
        return Station(
          url: connectedUrl,
          name: 'Connected Station',
          isConnected: true,
        );
      }
    }

    return null;
  }

  /// Get stream of update notifications from connected station
  Stream<UpdateNotification> get updates => _wsService.updates;

  /// Returns true if [url] points to a public internet host (not LAN/localhost).
  /// Used to skip ConnectionManager P2P transport probing for internet stations.
  bool _isInternetUrl(String url) {
    final normalized = url
        .replaceFirst('wss://', 'https://')
        .replaceFirst('ws://', 'http://');
    final host = Uri.tryParse(normalized)?.host ?? '';
    if (host.isEmpty || host == 'localhost' || host == '127.0.0.1') return false;
    final parts = host.split('.');
    if (parts.length == 4 && parts.every((p) => int.tryParse(p) != null)) {
      final first = int.parse(parts[0]);
      if (first == 10) return false;
      if (first == 172 && int.parse(parts[1]) >= 16 && int.parse(parts[1]) <= 31) return false;
      if (first == 192 && parts[1] == '168') return false;
    }
    return true; // Domain name or public IP → internet station
  }

  /// Get HTTP base URL for a station
  String _getHttpBaseUrl(String wsUrl) {
    return wsUrl
        .replaceFirst('ws://', 'http://')
        .replaceFirst('wss://', 'https://');
  }

  Station _resolveStation(String stationUrl, {String? stationCallsign}) {
    final existing = _stations.firstWhere(
      (station) => station.url == stationUrl,
      orElse: () => Station(url: stationUrl, name: stationUrl),
    );
    if (stationCallsign != null &&
        stationCallsign.isNotEmpty &&
        (existing.callsign == null || existing.callsign!.isEmpty)) {
      return existing.copyWith(callsign: stationCallsign);
    }
    return existing;
  }

  String _buildStationHttpUrl(String baseUrl, String path) {
    final normalizedBase = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    return '$normalizedBase$normalizedPath';
  }

  String _responseBodyFromResult(dynamic responseData) {
    if (responseData == null) return '';
    if (responseData is String) return responseData;
    if (responseData is List<int>) return utf8.decode(responseData);
    try {
      return jsonEncode(responseData);
    } catch (_) {
      return responseData.toString();
    }
  }

  Future<_StationApiResponse?> _stationApiRequest({
    required String stationUrl,
    required String method,
    required String path,
    String? stationCallsign,
    Map<String, String>? headers,
    dynamic body,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final station = _resolveStation(stationUrl, stationCallsign: stationCallsign);

    // Skip ConnectionManager P2P probing for internet stations — LAN/WebRTC
    // transports will never reach a public server, so the 2-4s timeout is waste.
    final isInternet = _isInternetUrl(stationUrl);

    if (!isInternet &&
        station.callsign != null &&
        station.callsign!.isNotEmpty &&
        ConnectionManager().isInitialized) {
      try {
        final result = await ConnectionManager().apiRequest(
          callsign: station.callsign!,
          method: method,
          path: path,
          headers: headers,
          body: body,
          timeout: timeout,
          excludeTransports: {'station'},
        );
        if (result.statusCode != null) {
          return _StationApiResponse(
            statusCode: result.statusCode!,
            body: _responseBodyFromResult(result.responseData),
            transportUsed: result.transportUsed,
          );
        }
        if (result.success) {
          return _StationApiResponse(
            statusCode: 200,
            body: _responseBodyFromResult(result.responseData),
            transportUsed: result.transportUsed,
          );
        }
      } catch (e) {
        LogService().log('StationService: ConnectionManager request failed: $e');
      }
    }

    try {
      final encodedBody = body == null ? null : (body is String ? body : jsonEncode(body));
      final httpUrl = _getHttpBaseUrl(stationUrl);
      final uri = Uri.parse(_buildStationHttpUrl(httpUrl, path));
      http.Response response;
      switch (method.toUpperCase()) {
        case 'POST':
          response = await _httpClient
              .post(uri, headers: headers, body: encodedBody)
              .timeout(timeout);
          break;
        case 'PUT':
          response = await _httpClient
              .put(uri, headers: headers, body: encodedBody)
              .timeout(timeout);
          break;
        case 'DELETE':
          response = await _httpClient
              .delete(uri, headers: headers, body: encodedBody)
              .timeout(timeout);
          break;
        default:
          response = await _httpClient.get(uri, headers: headers).timeout(timeout);
      }
      return _StationApiResponse(
        statusCode: response.statusCode,
        body: response.body,
        transportUsed: 'http',
      );
    } catch (e) {
      LogService().log('StationService: HTTP request failed: $e');
      return null;
    }
  }

  /// Fetch public chat rooms from station
  /// [stationCallsign] is the station's X3 callsign used in the API path
  Future<List<StationChatRoom>> fetchChatRooms(String stationUrl, {String? stationCallsign}) async {
    try {
      // Build NOSTR auth header so the server can identify the user
      // and return moderator flags in the response.
      Map<String, String>? authHeaders;
      try {
        final profile = ProfileService().getProfile();
        final signingService = SigningService();
        await signingService.initialize();
        if (signingService.canSign(profile) && profile.npub.isNotEmpty) {
          final pubkeyHex = NostrCrypto.decodeNpub(profile.npub);
          final event = NostrEvent.textNote(
            pubkeyHex: pubkeyHex,
            content: 'rooms',
            tags: [
              ['action', 'list_rooms'],
              ['callsign', profile.callsign],
            ],
          );
          event.calculateId();
          final signed = await signingService.signEvent(event, profile);
          if (signed != null) {
            final encoded = base64Encode(utf8.encode(jsonEncode(signed.toJson())));
            authHeaders = {'Authorization': 'Nostr $encoded'};
          }
        }
      } catch (_) {
        // Auth is optional — continue without it
      }

      final response = await _stationApiRequest(
        stationUrl: stationUrl,
        method: 'GET',
        path: '/api/chat/rooms',
        stationCallsign: stationCallsign,
        headers: authHeaders,
      );

      if (response == null) {
        LogService().log('Failed to fetch chat rooms: no response');
        return [];
      }

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final stationName = data['name'] as String? ?? stationCallsign ?? stationUrl;
        final roomsData = data['rooms'] as List<dynamic>? ?? [];

        final rooms = roomsData.map((room) {
          return StationChatRoom.fromJson(
            room as Map<String, dynamic>,
            stationUrl,
            stationName,
          );
        }).toList();

        LogService().log('Fetched ${rooms.length} chat rooms from $stationName');
        return rooms;
      } else {
        LogService().log('Failed to fetch chat rooms: ${response.statusCode}');
        return [];
      }
    } catch (e) {
      LogService().log('Error fetching chat rooms: $e');
      rethrow; // Rethrow so caller can fall back to cache
    }
  }

  /// Fetch messages from a station chat room
  /// [stationCallsign] is the station's X3 callsign used in the API path
  Future<List<StationChatMessage>> fetchRoomMessages(
    String stationUrl,
    String roomId, {
    int limit = 50,
    DateTime? after,
    String? stationCallsign,
  }) async {
    try {
      final query = <String, String>{
        'limit': limit.toString(),
      };
      if (after != null) {
        query['after'] = after.toIso8601String();
      }
      final queryString = Uri(queryParameters: query).query;
      final response = await _stationApiRequest(
        stationUrl: stationUrl,
        method: 'GET',
        path: '/api/chat/rooms/$roomId/messages?$queryString',
        stationCallsign: stationCallsign,
      );

      if (response == null) {
        LogService().log('Failed to fetch messages: no response');
        return [];
      }

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final messagesData = data['messages'] as List<dynamic>? ?? [];

        final messages = messagesData.map((msg) {
          return StationChatMessage.fromJson(
            msg as Map<String, dynamic>,
            roomId,
          );
        }).toList();

        LogService().log('Fetched ${messages.length} messages from room $roomId');
        return messages;
      } else {
        LogService().log('Failed to fetch messages: ${response.statusCode}');
        return [];
      }
    } catch (e) {
      LogService().log('Error fetching messages: $e');
      rethrow; // Rethrow so caller can fall back to cache
    }
  }

  /// Fetch list of chat files available for a room (for caching)
  /// Returns list of {year, filename, size, modified}
  Future<List<Map<String, dynamic>>> fetchRoomChatFiles(
    String stationUrl,
    String roomId,
  ) async {
    try {
      LogService().log('Fetching chat file list for room: $roomId');
      final response = await _stationApiRequest(
        stationUrl: stationUrl,
        method: 'GET',
        path: '/api/chat/rooms/$roomId/files',
      );

      if (response == null) {
        LogService().log('Failed to fetch chat files: no response');
        return [];
      }

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final files = (data['files'] as List<dynamic>? ?? [])
            .map((f) => f as Map<String, dynamic>)
            .toList();
        LogService().log('Found ${files.length} chat files for room $roomId');
        return files;
      } else {
        LogService().log('Failed to fetch chat files: ${response.statusCode}');
        return [];
      }
    } catch (e) {
      LogService().log('Error fetching chat files: $e');
      rethrow;
    }
  }

  /// Fetch raw content of a chat file
  /// Returns the raw text content of the file
  Future<String?> fetchRoomChatFile(
    String stationUrl,
    String roomId,
    String year,
    String filename,
  ) async {
    try {
      LogService().log('Fetching chat file: $roomId/$year/$filename');
      final response = await _stationApiRequest(
        stationUrl: stationUrl,
        method: 'GET',
        path: '/api/chat/rooms/$roomId/file/$year/$filename',
      );

      if (response == null) {
        LogService().log('Failed to fetch chat file: no response');
        return null;
      }

      if (response.statusCode == 200) {
        return response.body;
      } else {
        LogService().log('Failed to fetch chat file: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      LogService().log('Error fetching chat file: $e');
      rethrow;
    }
  }

  /// Upload a file to a station chat room
  /// Returns the uploaded filename on success, null on failure
  Future<String?> uploadRoomFile(
    String stationUrl,
    String roomId,
    String filePath,
  ) async {
    try {
      LogService().log('Uploading file to room: $roomId');

      final file = File(filePath);
      if (!await file.exists()) {
        LogService().log('Upload file not found: $filePath');
        return null;
      }

      // Get authentication
      final profile = ProfileService().getProfile();
      final signingService = SigningService();
      await signingService.initialize();

      if (!signingService.canSign(profile)) {
        LogService().log('Cannot upload: NOSTR keys not configured');
        return null;
      }

      // Create signed event for authentication
      final pubkeyHex = NostrCrypto.decodeNpub(profile.npub);
      final event = NostrEvent.textNote(
        pubkeyHex: pubkeyHex,
        content: 'upload',
        tags: [
          ['action', 'upload'],
          ['room', roomId],
          ['callsign', profile.callsign],
        ],
      );
      event.calculateId();

      final signedEvent = await signingService.signEvent(event, profile);
      if (signedEvent == null) {
        LogService().log('Failed to sign upload event');
        return null;
      }

      final authEvent = base64Encode(utf8.encode(jsonEncode(signedEvent.toJson())));

      final bytes = await file.readAsBytes();
      final filename = p.basename(filePath);

      // Construct the URL
      final baseUrl = stationUrl.replaceFirst('wss://', 'https://').replaceFirst('ws://', 'http://');
      final uri = Uri.parse('$baseUrl/api/chat/rooms/$roomId/files');

      final response = await _httpClient.post(
        uri,
        body: bytes,
        headers: {
          'Content-Type': 'application/octet-stream',
          'X-Filename': filename,
          'Authorization': 'Nostr $authEvent',
        },
      ).timeout(const Duration(seconds: 60));

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body);
        final uploadedFilename = data['filename'] as String?;
        LogService().log('File uploaded successfully: $uploadedFilename');
        return uploadedFilename;
      } else {
        LogService().log('Failed to upload file: ${response.statusCode} - ${response.body}');
        return null;
      }
    } catch (e) {
      LogService().log('Error uploading file: $e');
      return null;
    }
  }

  /// Download a file from a station chat room
  /// Returns the local cached file path on success, null on failure
  /// [cacheKey] is the device callsign to use for caching (e.g., "X3WFE4")
  Future<String?> downloadRoomFile(
    String stationUrl,
    String roomId,
    String filename, {
    String? cacheKey,
  }) async {
    try {
      LogService().log('Downloading room file: $roomId/$filename');

      // Construct the URL
      final baseUrl = stationUrl.replaceFirst('wss://', 'https://').replaceFirst('ws://', 'http://');
      final uri = Uri.parse('$baseUrl/api/chat/rooms/$roomId/files/$filename');

      final response = await _httpClient.get(uri).timeout(const Duration(seconds: 60));

      if (response.statusCode == 200) {
        // Cache the file using provided key or fallback to station callsign from URL
        final cacheService = RelayCacheService();
        final effectiveCacheKey = cacheKey ?? _extractCallsignFromUrl(stationUrl) ?? stationUrl;
        await cacheService.saveChatFile(
          effectiveCacheKey,
          roomId,
          filename,
          response.bodyBytes,
        );

        // Return the cached path
        return await cacheService.getChatFilePath(effectiveCacheKey, roomId, filename);
      } else {
        LogService().log('Failed to download file: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      LogService().log('Error downloading file: $e');
      return null;
    }
  }

  /// Extract station callsign from URL path (e.g., "wss://p2p.radio/X3WFE4" → "X3WFE4")
  String? _extractCallsignFromUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final pathSegments = uri.pathSegments;
    if (pathSegments.isNotEmpty) {
      final firstSegment = pathSegments.first;
      // Callsign pattern: X followed by alphanumeric
      if (RegExp(r'^X[A-Z0-9]+$').hasMatch(firstSegment)) {
        return firstSegment;
      }
    }
    return null;
  }

  /// Create a signed NOSTR event for a chat message
  Future<NostrEvent?> createSignedChatEvent(
    String roomId,
    String callsign,
    String content,
  ) async {
    try {
      final profile = ProfileService().getProfile();
      final pubkeyHex = NostrCrypto.decodeNpub(profile.npub);

      final event = NostrEvent.textNote(
        pubkeyHex: pubkeyHex,
        content: content,
        tags: [
          ['t', 'chat'],
          ['room', roomId],
          ['callsign', callsign],
        ],
      );
      event.calculateId();

      final signingService = SigningService();
      await signingService.initialize();
      final signedEvent = await signingService.signEvent(event, profile);
      return signedEvent;
    } catch (e) {
      LogService().log('Error creating signed chat event: $e');
      return null;
    }
  }

  /// Send a signed chat event via WebSocket or HTTP
  Future<bool> sendSignedChatEvent(
    String stationUrl,
    String roomId,
    String callsign,
    NostrEvent signedEvent, {
    Map<String, String>? metadata,
    bool preferWebSocket = true,
  }) async {
    final hasMetadata = metadata != null && metadata.isNotEmpty;

    // Try WebSocket when no metadata is needed
    if (preferWebSocket && !hasMetadata) {
      final isConnected = await _wsService.ensureConnected();
      if (isConnected) {
        final nostrMessage = NostrRelayMessage.event(signedEvent);
        final sent = await _wsService.sendWithVerification({'nostr_event': nostrMessage});
        if (sent) {
          return true;
        }
      }
    }

    // HTTP fallback (supports metadata)
    final pubkeyHex = signedEvent.pubkey;
    final body = <String, dynamic>{
      'callsign': callsign,
      'content': signedEvent.content,
      'npub': NostrCrypto.encodeNpub(pubkeyHex),
      'pubkey': pubkeyHex,
      'event_id': signedEvent.id,
      'signature': signedEvent.sig,
      'created_at': signedEvent.createdAt,
    };
    if (hasMetadata) {
      body['metadata'] = metadata;
    }

    final response = await _stationApiRequest(
      stationUrl: stationUrl,
      method: 'POST',
      path: '/api/chat/rooms/$roomId/messages',
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );

    return response != null && response.statusCode == 201;
  }

  /// Post a message to a station chat room as a NOSTR event
  /// Creates a signed kind 1 text note and sends via WebSocket or HTTP
  /// Returns send result on success or failure
  Future<StationSendResult> postRoomMessage(
    String stationUrl,
    String roomId,
    String callsign,
    String content, {
    bool useNostrProtocol = true,
    Map<String, String>? metadata,
  }) async {
    try {
      final hasMetadata = metadata != null && metadata.isNotEmpty;
      final signedEvent = await createSignedChatEvent(roomId, callsign, content);
      if (signedEvent == null) {
        LogService().log('Failed to sign message event');
        return StationSendResult(sent: false);
      }

      final useNostr = useNostrProtocol && !hasMetadata;
      if (useNostr) {
        print('');
        print('╔══════════════════════════════════════════════════════════════╗');
        print('║  SENDING MESSAGE (WebSocket/NOSTR)                           ║');
        print('╠══════════════════════════════════════════════════════════════╣');
        print('║  Room: $roomId');
        print('║  Callsign: $callsign');
        print('║  Content: $content');
        print('║  Event ID: ${signedEvent.id?.substring(0, 32)}...');
        print('║  Kind: ${signedEvent.kind}');
        print('╚══════════════════════════════════════════════════════════════╝');
        print('');
      }

      final sent = await sendSignedChatEvent(
        stationUrl,
        roomId,
        callsign,
        signedEvent,
        metadata: metadata,
        preferWebSocket: useNostrProtocol,
      );

      if (sent) {
        return StationSendResult(
          sent: true,
          createdAt: signedEvent.createdAt,
          eventId: signedEvent.id,
          signature: signedEvent.sig,
          pubkey: signedEvent.pubkey,
          npub: NostrCrypto.encodeNpub(signedEvent.pubkey),
        );
      }

      LogService().log('Failed to post message');
      return StationSendResult(sent: false);
    } catch (e) {
      LogService().log('Error posting message: $e');
      return StationSendResult(sent: false);
    }
  }

  /// Delete a message from a station chat room (author only)
  ///
  /// When [eventId] is provided, sends a NIP-09 kind 5 deletion event.
  /// Otherwise falls back to legacy kind 1 deletion for backwards compatibility.
  Future<bool> deleteRoomMessage(
    String stationUrl,
    String roomId,
    String timestamp, {
    String? eventId,
  }) async {
    try {
      final profile = ProfileService().getProfile();
      final signingService = SigningService();
      await signingService.initialize();

      if (!signingService.canSign(profile)) {
        LogService().log('Cannot delete message: NOSTR keys not configured');
        return false;
      }

      final pubkeyHex = NostrCrypto.decodeNpub(profile.npub);
      final additionalTags = <List<String>>[
        ['action', 'delete'],
        ['room', roomId],
        ['timestamp', timestamp],
        ['callsign', profile.callsign],
      ];

      NostrEvent event;
      if (eventId != null && eventId.isNotEmpty) {
        // NIP-09: kind 5 deletion event
        event = NostrEvent.deletion(
          pubkeyHex: pubkeyHex,
          eventIds: [eventId],
          additionalTags: additionalTags,
          content: 'delete',
        );
      } else {
        // Legacy: kind 1 text note
        event = NostrEvent.textNote(
          pubkeyHex: pubkeyHex,
          content: 'delete',
          tags: additionalTags,
        );
      }
      event.calculateId();

      final signedEvent = await signingService.signEvent(event, profile);
      if (signedEvent == null) {
        LogService().log('Failed to sign delete event');
        return false;
      }

      final authEvent = base64Encode(utf8.encode(jsonEncode(signedEvent.toJson())));
      final response = await _stationApiRequest(
        stationUrl: stationUrl,
        method: 'DELETE',
        path: '/api/chat/rooms/$roomId/messages/${Uri.encodeComponent(timestamp)}',
        headers: {'Authorization': 'Nostr $authEvent'},
      );

      if (response == null) {
        LogService().log('StationService: Delete message: no response from server');
      } else {
        LogService().log('StationService: Delete message response: ${response.statusCode} - ${response.body}');
      }
      return response != null && response.statusCode == 200;
    } catch (e) {
      LogService().log('Error deleting message: $e');
      return false;
    }
  }

  /// Edit a message in a station chat room (author only)
  ///
  /// Sends a kind 1 NOSTR event with action:edit tag and the new content.
  Future<bool> editRoomMessage(
    String stationUrl,
    String roomId,
    String timestamp,
    String newContent, {
    String? eventId,
  }) async {
    try {
      final profile = ProfileService().getProfile();
      final signingService = SigningService();
      await signingService.initialize();

      if (!signingService.canSign(profile)) {
        LogService().log('Cannot edit message: NOSTR keys not configured');
        return false;
      }

      final pubkeyHex = NostrCrypto.decodeNpub(profile.npub);
      final event = NostrEvent.textNote(
        pubkeyHex: pubkeyHex,
        content: newContent,
        tags: [
          ['action', 'edit'],
          ['room', roomId],
          ['timestamp', timestamp],
          ['callsign', profile.callsign],
        ],
      );
      event.calculateId();

      final signedEvent = await signingService.signEvent(event, profile);
      if (signedEvent == null) {
        LogService().log('Failed to sign edit event');
        return false;
      }

      final authEvent = base64Encode(utf8.encode(jsonEncode(signedEvent.toJson())));
      final response = await _stationApiRequest(
        stationUrl: stationUrl,
        method: 'PUT',
        path: '/api/chat/rooms/$roomId/messages/${Uri.encodeComponent(timestamp)}',
        headers: {'Authorization': 'Nostr $authEvent'},
      );

      return response != null && response.statusCode == 200;
    } catch (e) {
      LogService().log('Error editing message: $e');
      return false;
    }
  }

  /// Fetch modification log for a room since a given timestamp.
  /// Returns list of modification entries from the server.
  Future<List<Map<String, dynamic>>> fetchRoomModifications(
    String stationUrl,
    String roomId, {
    DateTime? since,
  }) async {
    try {
      var path = '/api/chat/$roomId/modifications';
      if (since != null) {
        path += '?since=${Uri.encodeComponent(since.toUtc().toIso8601String())}';
      }

      final response = await _stationApiRequest(
        stationUrl: stationUrl,
        method: 'GET',
        path: path,
      );

      if (response == null || response.statusCode != 200) return [];

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final mods = data['modifications'] as List?;
      if (mods == null) return [];

      return mods.map((m) => Map<String, dynamic>.from(m as Map)).toList();
    } catch (e) {
      LogService().log('Error fetching room modifications: $e');
      return [];
    }
  }

  /// Toggle a reaction on a station chat message
  /// Returns updated reactions map or null on failure
  Future<Map<String, List<String>>?> toggleRoomReaction(
    String stationUrl,
    String roomId,
    String timestamp,
    String reaction,
  ) async {
    try {
      final profile = ProfileService().getProfile();
      final signingService = SigningService();
      await signingService.initialize();

      if (!signingService.canSign(profile)) {
        LogService().log('Cannot react: NOSTR keys not configured');
        return null;
      }

      final reactionKey = ReactionUtils.normalizeReactionKey(reaction);
      if (reactionKey.isEmpty) {
        LogService().log('Cannot react: empty reaction');
        return null;
      }

      final pubkeyHex = NostrCrypto.decodeNpub(profile.npub);
      final event = NostrEvent.textNote(
        pubkeyHex: pubkeyHex,
        content: 'react',
        tags: [
          ['action', 'react'],
          ['room', roomId],
          ['timestamp', timestamp],
          ['reaction', reactionKey],
          ['callsign', profile.callsign],
        ],
      );
      event.calculateId();

      final signedEvent = await signingService.signEvent(event, profile);
      if (signedEvent == null) {
        LogService().log('Failed to sign reaction event');
        return null;
      }

      final authEvent = base64Encode(utf8.encode(jsonEncode(signedEvent.toJson())));
      Future<_StationApiResponse?> sendReaction(String path) {
        return _stationApiRequest(
          stationUrl: stationUrl,
          method: 'POST',
          path: path,
          headers: {'Authorization': 'Nostr $authEvent'},
        );
      }

      var response = await sendReaction(
        '/api/chat/rooms/$roomId/messages/${Uri.encodeComponent(timestamp)}/reactions',
      );

      if (response != null && response.statusCode != 200) {
        response = await sendReaction(
          '/api/chat/$roomId/messages/${Uri.encodeComponent(timestamp)}/reactions',
        );
      }

      if (response != null && response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final rawReactions = data['reactions'] as Map?;
        final reactions = <String, List<String>>{};
        if (rawReactions != null) {
          rawReactions.forEach((key, value) {
            if (value is List) {
              reactions[key.toString()] =
                  value.map((entry) => entry.toString()).toList();
            }
          });
        }
        return ReactionUtils.normalizeReactionMap(reactions);
      }

      LogService().log('Failed to toggle reaction: ${response?.statusCode}');
      return null;
    } catch (e) {
      LogService().log('Error toggling reaction: $e');
      return null;
    }
  }

  /// Subscribe to a chat room for real-time NOSTR events
  void subscribeToRoom(String roomId) {
    if (!_wsService.isConnected) {
      LogService().log('Cannot subscribe: not connected to station');
      return;
    }

    final subscriptionId = 'room_$roomId';
    final filter = {
      'kinds': [1], // Text notes
      '#room': [roomId], // Filter by room tag
      'limit': 50,
    };

    final reqMessage = NostrRelayMessage.req(subscriptionId, filter);
    _wsService.send({'nostr_req': reqMessage});
    LogService().log('Subscribed to room: $roomId');
  }

  /// Unsubscribe from a chat room
  void unsubscribeFromRoom(String roomId) {
    if (!_wsService.isConnected) {
      return;
    }

    final subscriptionId = 'room_$roomId';
    final closeMessage = NostrRelayMessage.close(subscriptionId);
    _wsService.send({'nostr_close': closeMessage});
    LogService().log('Unsubscribed from room: $roomId');
  }

  /// Fetch chat rooms from connected station
  Future<List<StationChatRoom>> fetchConnectedStationChatRooms() async {
    final station = getConnectedStation();
    if (station == null) {
      LogService().log('No station connected');
      return [];
    }
    return fetchChatRooms(station.url);
  }

  /// Build NOSTR auth headers for station API requests.
  /// Returns null if signing is not available.
  Future<Map<String, String>?> _buildNostrAuthHeaders({
    required String action,
    List<List<String>>? extraTags,
  }) async {
    try {
      final profile = ProfileService().getProfile();
      final signingService = SigningService();
      await signingService.initialize();

      if (!signingService.canSign(profile) || profile.npub.isEmpty) {
        return null;
      }

      final pubkeyHex = NostrCrypto.decodeNpub(profile.npub);
      final tags = <List<String>>[
        ['action', action],
        ['callsign', profile.callsign],
        ...?extraTags,
      ];

      final event = NostrEvent.textNote(
        pubkeyHex: pubkeyHex,
        content: action,
        tags: tags,
      );
      event.calculateId();

      final signed = await signingService.signEvent(event, profile);
      if (signed == null) return null;

      final encoded = base64Encode(utf8.encode(jsonEncode(signed.toJson())));
      return {'Authorization': 'Nostr $encoded'};
    } catch (e) {
      LogService().log('Failed to build NOSTR auth headers: $e');
      return null;
    }
  }

  /// Create a new room on a station
  Future<bool> createStationRoom(String stationUrl, String id, String name, {String? description}) async {
    try {
      final headers = await _buildNostrAuthHeaders(action: 'create_room');
      final body = jsonEncode({
        'id': id,
        'name': name,
        if (description != null) 'description': description,
      });

      final response = await _stationApiRequest(
        stationUrl: stationUrl,
        method: 'POST',
        path: '/api/chat/rooms',
        headers: {
          ...?headers,
          'Content-Type': 'application/json',
        },
        body: body,
      );

      if (response == null) {
        LogService().log('StationService: Create room: no response');
        return false;
      }
      LogService().log('StationService: Create room response: ${response.statusCode}');
      return response.statusCode == 201;
    } catch (e) {
      LogService().log('Error creating room: $e');
      return false;
    }
  }

  /// Delete a room on a station (moderator only)
  Future<bool> deleteStationRoom(String stationUrl, String roomId) async {
    try {
      final headers = await _buildNostrAuthHeaders(
        action: 'delete_room',
        extraTags: [['room', roomId]],
      );
      if (headers == null) {
        LogService().log('Cannot delete room: NOSTR keys not configured');
        return false;
      }

      final response = await _stationApiRequest(
        stationUrl: stationUrl,
        method: 'DELETE',
        path: '/api/chat/rooms/$roomId',
        headers: headers,
      );

      if (response == null) {
        LogService().log('StationService: Delete room: no response');
        return false;
      }
      LogService().log('StationService: Delete room response: ${response.statusCode} - ${response.body}');
      return response.statusCode == 200;
    } catch (e) {
      LogService().log('Error deleting room: $e');
      return false;
    }
  }

  /// Rename a room on a station (moderator only)
  Future<bool> renameStationRoom(String stationUrl, String roomId, String newName) async {
    try {
      final headers = await _buildNostrAuthHeaders(
        action: 'rename_room',
        extraTags: [['room', roomId]],
      );
      if (headers == null) {
        LogService().log('Cannot rename room: NOSTR keys not configured');
        return false;
      }

      final response = await _stationApiRequest(
        stationUrl: stationUrl,
        method: 'PUT',
        path: '/api/chat/rooms/$roomId',
        headers: {
          ...headers,
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'name': newName}),
      );

      if (response == null) {
        LogService().log('StationService: Rename room: no response');
        return false;
      }
      LogService().log('StationService: Rename room response: ${response.statusCode}');
      return response.statusCode == 200;
    } catch (e) {
      LogService().log('Error renaming room: $e');
      return false;
    }
  }

  /// Check if a callsign indicates a client device (X1 prefix)
  /// X1 = client (reject), X3 = station (allow)
  bool _isClientCallsign(String? callsign) {
    if (callsign == null || callsign.isEmpty) return false;
    return callsign.toUpperCase().startsWith('X1');
  }
}
