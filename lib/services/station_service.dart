import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/station.dart';
import '../models/station_chat_room.dart';
import '../models/update_notification.dart';
import '../services/config_service.dart';
import '../services/log_service.dart';
import '../services/websocket_service.dart';
import '../services/profile_service.dart';
import '../services/chat_notification_service.dart';
import '../services/signing_service.dart';
import '../util/nostr_event.dart';
import '../util/nostr_crypto.dart';
import '../util/chat_api.dart';

/// Service for managing internet stations
class StationService {
  static final StationService _instance = StationService._internal();
  factory StationService() => _instance;
  StationService._internal();

  List<Station> _stations = [];
  bool _initialized = false;
  final WebSocketService _wsService = WebSocketService();

  /// Default stations
  static final List<Station> _defaultRelays = [
    Station(
      url: 'wss://p2p.radio',
      name: 'P2P Radio',
      description: 'Public station for the geogram network',
      status: 'preferred',
    ),
  ];

  /// Initialize station service
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      await _loadStations();
      _initialized = true;
      LogService().log('StationService initialized with ${_stations.length} stations');

      // Auto-connect to preferred station
      final preferredStation = getPreferredStation();
      if (preferredStation != null && preferredStation.url.isNotEmpty) {
        LogService().log('Auto-connecting to preferred station: ${preferredStation.name}');
        connectRelay(preferredStation.url);
      }
    } catch (e) {
      LogService().log('Error initializing StationService: $e');
    }
  }

  /// Load stations from config
  Future<void> _loadStations() async {
    final config = ConfigService().getAll();

    if (config.containsKey('stations')) {
      final stationsData = config['stations'] as List<dynamic>;
      _stations = stationsData.map((data) => Station.fromJson(data as Map<String, dynamic>)).toList();

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
        _saveStations(); // Save deduplicated list
      }

      print('DEBUG StationService: After reset, stations=${_stations.map((r) => "${r.name}:${r.isConnected}").toList()}');
      LogService().log('Loaded ${_stations.length} stations from config');
    } else {
      // First time - use default stations
      _stations = _defaultRelays.map((r) => r.copyWith()).toList();

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
  /// Returns true if station was added, false if it already exists
  Future<bool> addStation(Station station) async {
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
  Future<bool> connectRelay(String url) async {
    try {
      LogService().log('');
      LogService().log('══════════════════════════════════════');
      LogService().log('RELAY CONNECTION REQUEST');
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
        try {
          final httpUrl = url.replaceFirst('ws://', 'http://').replaceFirst('wss://', 'https://');
          final statusUrl = httpUrl.endsWith('/') ? '${httpUrl}api/status' : '$httpUrl/api/status';
          final response = await http.get(Uri.parse(statusUrl));
          if (response.statusCode == 200) {
            final data = jsonDecode(response.body);
            connectedDevices = data['connected_devices'] as int?;
            stationCallsign = data['callsign'] as String?;
            stationName = data['name'] as String?;
            stationDescription = data['description'] as String?;
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
  Station? getConnectedRelay() {
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

  /// Get HTTP base URL for a station
  String _getHttpBaseUrl(String wsUrl) {
    return wsUrl
        .replaceFirst('ws://', 'http://')
        .replaceFirst('wss://', 'https://');
  }

  /// Fetch public chat rooms from station
  /// [stationCallsign] is the station's X3 callsign used in the API path
  Future<List<StationChatRoom>> fetchChatRooms(String stationUrl, {String? stationCallsign}) async {
    try {
      final httpUrl = _getHttpBaseUrl(stationUrl);

      // If no callsign provided, try to get it from status endpoint
      String? callsign = stationCallsign;
      if (callsign == null || callsign.isEmpty) {
        callsign = await _getStationCallsign(httpUrl);
      }

      if (callsign == null || callsign.isEmpty) {
        LogService().log('Cannot fetch chat rooms: station callsign not available');
        return [];
      }

      final apiUrl = ChatApi.roomsUrl(httpUrl, callsign);

      LogService().log('Fetching chat rooms from: $apiUrl');
      final response = await http.get(Uri.parse(apiUrl));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final stationName = data['callsign'] as String? ?? callsign;
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

  /// Get station callsign from status endpoint
  Future<String?> _getStationCallsign(String httpUrl) async {
    try {
      final statusUrl = httpUrl.endsWith('/')
          ? '${httpUrl}api/status'
          : '$httpUrl/api/status';
      final response = await http.get(Uri.parse(statusUrl));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['callsign'] as String?;
      }
    } catch (e) {
      LogService().log('Error fetching station callsign: $e');
    }
    return null;
  }

  /// Fetch messages from a station chat room
  /// [stationCallsign] is the station's X3 callsign used in the API path
  Future<List<StationChatMessage>> fetchRoomMessages(
    String stationUrl,
    String roomId, {
    int limit = 50,
    String? stationCallsign,
  }) async {
    try {
      final httpUrl = _getHttpBaseUrl(stationUrl);

      // If no callsign provided, try to get it from status endpoint
      String? callsign = stationCallsign;
      if (callsign == null || callsign.isEmpty) {
        callsign = await _getStationCallsign(httpUrl);
      }

      if (callsign == null || callsign.isEmpty) {
        LogService().log('Cannot fetch messages: station callsign not available');
        return [];
      }

      final apiUrl = ChatApi.messagesUrl(httpUrl, callsign, roomId, limit: limit);

      LogService().log('Fetching messages from room: $roomId');
      final response = await http.get(Uri.parse(apiUrl));

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
      final httpUrl = _getHttpBaseUrl(stationUrl);
      final apiUrl = '$httpUrl/api/chat/rooms/$roomId/files';

      LogService().log('Fetching chat file list for room: $roomId');
      final response = await http.get(Uri.parse(apiUrl));

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
      final httpUrl = _getHttpBaseUrl(stationUrl);
      final apiUrl = '$httpUrl/api/chat/rooms/$roomId/file/$year/$filename';

      LogService().log('Fetching chat file: $roomId/$year/$filename');
      final response = await http.get(Uri.parse(apiUrl));

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

  /// Post a message to a station chat room as a NOSTR event
  /// Creates a signed kind 1 text note and sends via WebSocket or HTTP
  Future<bool> postRoomMessage(
    String stationUrl,
    String roomId,
    String callsign,
    String content, {
    bool useNostrProtocol = true,
  }) async {
    try {
      final profile = ProfileService().getProfile();

      if (useNostrProtocol) {
        // Verify WebSocket connection is alive before attempting to send
        final isConnected = await _wsService.ensureConnected();
        if (!isConnected) {
          LogService().log('WebSocket not connected, falling back to HTTP');
          // Fall through to HTTP fallback below
        } else {
          // Create NOSTR event (kind 1 text note)
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

          // Calculate ID and sign with SigningService (handles both extension and nsec)
          event.calculateId();
          final signingService = SigningService();
          await signingService.initialize();
          final signedEvent = await signingService.signEvent(event, profile);
          if (signedEvent == null) {
            LogService().log('Failed to sign message event');
            return false;
          }

          // Send via NOSTR protocol: ["EVENT", {...}]
          final nostrMessage = NostrRelayMessage.event(signedEvent);

          // Console output for debugging
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

          // Use sendWithVerification for reliable delivery
          final sent = await _wsService.sendWithVerification({'nostr_event': nostrMessage});
          if (sent) {
            return true;
          } else {
            LogService().log('WebSocket send failed, falling back to HTTP');
            // Fall through to HTTP fallback below
          }
        }
      }

      // HTTP fallback (when WebSocket is unavailable or send failed)
      {
        // Fallback to HTTP API with NOSTR signature
        final httpUrl = _getHttpBaseUrl(stationUrl);

        // Get station callsign for API path
        final stationCallsign = await _getStationCallsign(httpUrl);
        if (stationCallsign == null || stationCallsign.isEmpty) {
          LogService().log('Cannot post message: station callsign not available');
          return false;
        }

        final apiUrl = ChatApi.messagesUrl(httpUrl, stationCallsign, roomId);

        LogService().log('Posting message via HTTP to room: $roomId');

        // Create NOSTR event for signature
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

        // Sign with SigningService (handles both extension and nsec)
        final signingService = SigningService();
        await signingService.initialize();
        final signedEvent = await signingService.signEvent(event, profile);
        if (signedEvent == null) {
          LogService().log('Failed to sign HTTP message event');
          return false;
        }

        // Console output for debugging
        print('');
        print('╔══════════════════════════════════════════════════════════════╗');
        print('║  SENDING MESSAGE (HTTP)                                      ║');
        print('╠══════════════════════════════════════════════════════════════╣');
        print('║  Room: $roomId');
        print('║  Callsign: $callsign');
        print('║  Content: $content');
        print('║  Event ID: ${signedEvent.id?.substring(0, 32)}...');
        print('║  Pubkey: ${pubkeyHex.substring(0, 16)}...');
        print('╚══════════════════════════════════════════════════════════════╝');
        print('');

        // Self-verify the signature before sending
        final selfVerify = NostrCrypto.schnorrVerify(signedEvent.id!, signedEvent.sig!, pubkeyHex);
        if (!selfVerify) {
          print('⚠ WARNING: Desktop cannot verify its own signature!');
        }

        // Build request body with NOSTR event data
        final body = <String, dynamic>{
          'callsign': callsign,
          'content': content,
          'npub': profile.npub,
          'pubkey': pubkeyHex,
          'event_id': signedEvent.id,
          'signature': signedEvent.sig,
          'created_at': signedEvent.createdAt,
        };

        final response = await http.post(
          Uri.parse(apiUrl),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        );

        if (response.statusCode == 201) {
          LogService().log('Message posted successfully (HTTP)');
          return true;
        } else {
          LogService().log('Failed to post message: ${response.statusCode} - ${response.body}');
          return false;
        }
      }
    } catch (e) {
      LogService().log('Error posting message: $e');
      return false;
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
  Future<List<StationChatRoom>> fetchConnectedRelayChatRooms() async {
    final station = getConnectedRelay();
    if (station == null) {
      LogService().log('No station connected');
      return [];
    }
    return fetchChatRooms(station.url);
  }
}
