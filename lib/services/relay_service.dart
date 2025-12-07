import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/relay.dart';
import '../models/relay_chat_room.dart';
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

/// Service for managing internet relays
class RelayService {
  static final RelayService _instance = RelayService._internal();
  factory RelayService() => _instance;
  RelayService._internal();

  List<Relay> _relays = [];
  bool _initialized = false;
  final WebSocketService _wsService = WebSocketService();

  /// Default relays
  static final List<Relay> _defaultRelays = [
    Relay(
      url: 'wss://p2p.radio',
      name: 'P2P Radio',
      description: 'Public relay for the geogram network',
      status: 'preferred',
    ),
  ];

  /// Initialize relay service
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      await _loadRelays();
      _initialized = true;
      LogService().log('RelayService initialized with ${_relays.length} relays');

      // Auto-connect to preferred relay
      final preferredRelay = getPreferredRelay();
      if (preferredRelay != null && preferredRelay.url.isNotEmpty) {
        LogService().log('Auto-connecting to preferred relay: ${preferredRelay.name}');
        connectRelay(preferredRelay.url);
      }
    } catch (e) {
      LogService().log('Error initializing RelayService: $e');
    }
  }

  /// Load relays from config
  Future<void> _loadRelays() async {
    final config = ConfigService().getAll();

    if (config.containsKey('relays')) {
      final relaysData = config['relays'] as List<dynamic>;
      _relays = relaysData.map((data) => Relay.fromJson(data as Map<String, dynamic>)).toList();

      // Reset connection state - connection status shouldn't persist across app restarts
      for (var i = 0; i < _relays.length; i++) {
        if (_relays[i].isConnected) {
          print('DEBUG RelayService: Resetting isConnected for ${_relays[i].name}');
          _relays[i] = _relays[i].copyWith(isConnected: false);
        }
      }

      // Deduplicate relays with same callsign (e.g., 127.0.0.1 vs LAN IP)
      final beforeCount = _relays.length;
      _relays = _deduplicateRelays(_relays);
      if (_relays.length < beforeCount) {
        LogService().log('Merged ${beforeCount - _relays.length} duplicate relay entries');
        _saveRelays(); // Save deduplicated list
      }

      print('DEBUG RelayService: After reset, relays=${_relays.map((r) => "${r.name}:${r.isConnected}").toList()}');
      LogService().log('Loaded ${_relays.length} relays from config');
    } else {
      // First time - use default relays
      _relays = _defaultRelays.map((r) => r.copyWith()).toList();

      // Set first as preferred
      if (_relays.isNotEmpty) {
        _relays[0] = _relays[0].copyWith(status: 'preferred');
      }

      _saveRelays();
      LogService().log('Created default relay configuration');
    }
  }

  /// Save relays to config
  void _saveRelays() {
    final relaysData = _relays.map((r) => r.toJson()).toList();
    ConfigService().set('relays', relaysData);
    LogService().log('Saved ${_relays.length} relays to config');
  }

  /// Deduplicate relays with same callsign (e.g., localhost vs LAN IP)
  /// Prefers non-localhost URLs and entries with more info
  List<Relay> _deduplicateRelays(List<Relay> relays) {
    if (relays.isEmpty) return relays;

    final Map<String, Relay> uniqueRelays = {};

    for (var relay in relays) {
      // Create a unique key based on callsign+port, or name+port if no callsign
      String key;
      final uri = Uri.tryParse(relay.url);
      final port = uri?.port ?? 8080;

      if (relay.callsign != null && relay.callsign!.isNotEmpty) {
        // Use callsign + port as key (same relay on different IPs has same callsign)
        key = '${relay.callsign}:$port';
      } else if (relay.name.isNotEmpty) {
        // Fallback to name + port
        key = '${relay.name}:$port';
      } else {
        // No way to identify, keep all entries (use URL as key)
        key = relay.url;
      }

      if (uniqueRelays.containsKey(key)) {
        final existing = uniqueRelays[key]!;
        // Prefer non-localhost entry (LAN IP is more useful for other devices)
        final existingIsLocalhost = existing.url.contains('127.0.0.1') || existing.url.contains('localhost');
        final newIsLocalhost = relay.url.contains('127.0.0.1') || relay.url.contains('localhost');

        if (existingIsLocalhost && !newIsLocalhost) {
          // Replace localhost with LAN IP, preserve status
          uniqueRelays[key] = relay.copyWith(status: existing.status);
        } else if (!existingIsLocalhost && newIsLocalhost) {
          // Keep the existing LAN IP
        } else if (_relayHasMoreInfo(relay, existing)) {
          // Keep the one with more info, preserve status
          uniqueRelays[key] = relay.copyWith(status: existing.status);
        }
        // Otherwise keep existing
      } else {
        uniqueRelays[key] = relay;
      }
    }

    return uniqueRelays.values.toList();
  }

  /// Check if relay a has more info than relay b
  bool _relayHasMoreInfo(Relay a, Relay b) {
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

  /// Get all relays
  List<Relay> getAllRelays() {
    if (!_initialized) {
      throw Exception('RelayService not initialized');
    }
    return List.unmodifiable(_relays);
  }

  /// Get preferred relay
  Relay? getPreferredRelay() {
    return _relays.firstWhere(
      (r) => r.status == 'preferred',
      orElse: () => _relays.isNotEmpty ? _relays[0] : Relay(url: '', name: ''),
    );
  }

  /// Get backup relays
  List<Relay> getBackupRelays() {
    return _relays.where((r) => r.status == 'backup').toList();
  }

  /// Get available relays (not selected)
  List<Relay> getAvailableRelays() {
    return _relays.where((r) => r.status == 'available').toList();
  }

  /// Add a new relay
  /// Returns true if relay was added, false if it already exists
  Future<bool> addRelay(Relay relay) async {
    // Check if URL already exists
    final existsByUrl = _relays.any((r) => r.url == relay.url);
    if (existsByUrl) {
      LogService().log('Relay URL already exists: ${relay.url}');
      return false;
    }

    // Check if callsign already exists (same relay on different IP)
    if (relay.callsign != null && relay.callsign!.isNotEmpty) {
      final existsByCallsign = _relays.indexWhere(
        (r) => r.callsign == relay.callsign && r.callsign != null,
      );
      if (existsByCallsign != -1) {
        final existing = _relays[existsByCallsign];
        // Update existing entry if new one has better URL (non-localhost)
        final existingIsLocalhost = existing.url.contains('127.0.0.1') || existing.url.contains('localhost');
        final newIsLocalhost = relay.url.contains('127.0.0.1') || relay.url.contains('localhost');

        if (existingIsLocalhost && !newIsLocalhost) {
          // Replace localhost with LAN IP
          _relays[existsByCallsign] = relay.copyWith(status: existing.status);
          _saveRelays();
          LogService().log('Updated relay URL from localhost to ${relay.url}');
          return true;
        } else {
          LogService().log('Relay with callsign ${relay.callsign} already exists at ${existing.url}');
          return false;
        }
      }
    }

    _relays.add(relay);
    _saveRelays();
    LogService().log('Added relay: ${relay.name}');
    return true;
  }

  /// Update relay
  Future<void> updateRelay(String url, Relay updatedRelay) async {
    final index = _relays.indexWhere((r) => r.url == url);
    if (index == -1) {
      throw Exception('Relay not found');
    }

    _relays[index] = updatedRelay;
    _saveRelays();
    LogService().log('Updated relay: ${updatedRelay.name}');
  }

  /// Set relay as preferred
  Future<void> setPreferred(String url) async {
    // Remove preferred status from all relays
    for (var i = 0; i < _relays.length; i++) {
      if (_relays[i].status == 'preferred') {
        _relays[i] = _relays[i].copyWith(status: 'available');
      }
    }

    // Set new preferred
    final index = _relays.indexWhere((r) => r.url == url);
    if (index != -1) {
      _relays[index] = _relays[index].copyWith(status: 'preferred');
      _saveRelays();
      LogService().log('Set preferred relay: ${_relays[index].name}');
    }
  }

  /// Set relay as backup
  /// Automatically switches preferred relay if current preferred is being set as backup
  Future<void> setBackup(String url) async {
    final index = _relays.indexWhere((r) => r.url == url);
    if (index == -1) return;

    final wasPreferred = _relays[index].status == 'preferred';

    // Set the relay as backup
    _relays[index] = _relays[index].copyWith(status: 'backup');

    // If this was the preferred relay, we need to select a new preferred
    if (wasPreferred) {
      LogService().log('Current preferred relay being set as backup, selecting new preferred...');

      // First, try to find another backup relay
      Relay? newPreferred;
      for (var relay in _relays) {
        if (relay.status == 'backup' && relay.url != url) {
          newPreferred = relay;
          break;
        }
      }

      // If no backup relay, find closest available relay
      if (newPreferred == null) {
        final profile = ProfileService().getProfile();
        final availableRelays = _relays.where((r) => r.status == 'available').toList();

        if (availableRelays.isNotEmpty) {
          if (profile.latitude != null && profile.longitude != null) {
            // Sort by distance
            availableRelays.sort((a, b) {
              final distA = a.calculateDistance(profile.latitude, profile.longitude) ?? double.infinity;
              final distB = b.calculateDistance(profile.latitude, profile.longitude) ?? double.infinity;
              return distA.compareTo(distB);
            });
            newPreferred = availableRelays.first;
            LogService().log('Selected closest available relay: ${newPreferred.name}');
          } else {
            // No location available, just pick the first available
            newPreferred = availableRelays.first;
            LogService().log('No location available, selected first available relay: ${newPreferred.name}');
          }
        }
      } else {
        LogService().log('Selected next backup relay as preferred: ${newPreferred.name}');
      }

      // Set the new preferred relay
      if (newPreferred != null) {
        final newIndex = _relays.indexWhere((r) => r.url == newPreferred!.url);
        if (newIndex != -1) {
          _relays[newIndex] = _relays[newIndex].copyWith(status: 'preferred');
        }
      } else {
        LogService().log('WARNING: No other relay available to set as preferred!');
      }
    }

    _saveRelays();
    LogService().log('Set backup relay: ${_relays[index].name}');
  }

  /// Set relay as available (unselect)
  Future<void> setAvailable(String url) async {
    final index = _relays.indexWhere((r) => r.url == url);
    if (index != -1) {
      _relays[index] = _relays[index].copyWith(status: 'available');
      _saveRelays();
      LogService().log('Set relay as available: ${_relays[index].name}');
    }
  }

  /// Delete relay
  Future<void> deleteRelay(String url) async {
    final index = _relays.indexWhere((r) => r.url == url);
    if (index != -1) {
      final relay = _relays[index];
      _relays.removeAt(index);
      _saveRelays();
      LogService().log('Deleted relay: ${relay.name}');
    }
  }

  /// Test relay connection (stub for now)
  Future<void> testConnection(String url) async {
    final index = _relays.indexWhere((r) => r.url == url);
    if (index != -1) {
      // Simulate connection test
      await Future.delayed(const Duration(seconds: 1));

      // For now, just update last checked time
      _relays[index] = _relays[index].copyWith(
        lastChecked: DateTime.now(),
        isConnected: true,
        latency: 50 + (url.hashCode % 100), // Simulated latency
      );

      _saveRelays();
      LogService().log('Tested relay: ${_relays[index].name}');
    }
  }

  /// Connect to relay with hello handshake
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

        // Fetch relay status to get connected devices count, callsign, name and description
        int? connectedDevices;
        String? relayCallsign;
        String? relayName;
        String? relayDescription;
        try {
          final httpUrl = url.replaceFirst('ws://', 'http://').replaceFirst('wss://', 'https://');
          final statusUrl = httpUrl.endsWith('/') ? '${httpUrl}api/status' : '$httpUrl/api/status';
          final response = await http.get(Uri.parse(statusUrl));
          if (response.statusCode == 200) {
            final data = jsonDecode(response.body);
            connectedDevices = data['connected_devices'] as int?;
            relayCallsign = data['callsign'] as String?;
            relayName = data['name'] as String?;
            relayDescription = data['description'] as String?;
            LogService().log('Fetched relay status: $connectedDevices devices connected');
            if (relayCallsign != null && relayCallsign.isNotEmpty) {
              LogService().log('Relay callsign: $relayCallsign');
            }
            if (relayName != null && relayName.isNotEmpty) {
              LogService().log('Relay name: $relayName');
            }
          }
        } catch (e) {
          LogService().log('Warning: Could not fetch relay status: $e');
        }

        // Update relay status
        final index = _relays.indexWhere((r) => r.url == url);
        if (index != -1) {
          _relays[index] = _relays[index].copyWith(
            lastChecked: DateTime.now(),
            isConnected: true,
            latency: latency,
            connectedDevices: connectedDevices,
            callsign: relayCallsign,
            name: relayName ?? _relays[index].name,
            description: relayDescription,
          );
          _saveRelays();

          LogService().log('');
          LogService().log('✓ CONNECTION SUCCESSFUL');
          LogService().log('Relay: ${_relays[index].name}');
          if (relayCallsign != null && relayCallsign.isNotEmpty) {
            LogService().log('Callsign: $relayCallsign');
          }
          if (_relays[index].description != null && _relays[index].description!.isNotEmpty) {
            LogService().log('Description: ${_relays[index].description}');
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

        // Update relay as disconnected
        final index = _relays.indexWhere((r) => r.url == url);
        if (index != -1) {
          _relays[index] = _relays[index].copyWith(
            lastChecked: DateTime.now(),
            isConnected: false,
          );
          _saveRelays();
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

  /// Disconnect from current relay
  void disconnect() {
    if (_wsService.isConnected) {
      LogService().log('Disconnecting from relay...');
      _wsService.disconnect();

      // Update all relays as disconnected
      for (var i = 0; i < _relays.length; i++) {
        if (_relays[i].isConnected) {
          _relays[i] = _relays[i].copyWith(isConnected: false);
        }
      }
      _saveRelays();
    }
  }

  /// Get currently connected relay
  Relay? getConnectedRelay() {
    try {
      return _relays.firstWhere((r) => r.isConnected);
    } catch (e) {
      return null;
    }
  }

  /// Get stream of update notifications from connected relay
  Stream<UpdateNotification> get updates => _wsService.updates;

  /// Get HTTP base URL for a relay
  String _getHttpBaseUrl(String wsUrl) {
    return wsUrl
        .replaceFirst('ws://', 'http://')
        .replaceFirst('wss://', 'https://');
  }

  /// Fetch public chat rooms from relay
  /// [relayCallsign] is the relay's X3 callsign used in the API path
  Future<List<RelayChatRoom>> fetchChatRooms(String relayUrl, {String? relayCallsign}) async {
    try {
      final httpUrl = _getHttpBaseUrl(relayUrl);

      // If no callsign provided, try to get it from status endpoint
      String? callsign = relayCallsign;
      if (callsign == null || callsign.isEmpty) {
        callsign = await _getRelayCallsign(httpUrl);
      }

      if (callsign == null || callsign.isEmpty) {
        LogService().log('Cannot fetch chat rooms: relay callsign not available');
        return [];
      }

      final apiUrl = ChatApi.roomsUrl(httpUrl, callsign);

      LogService().log('Fetching chat rooms from: $apiUrl');
      final response = await http.get(Uri.parse(apiUrl));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final relayName = data['callsign'] as String? ?? callsign;
        final roomsData = data['rooms'] as List<dynamic>? ?? [];

        final rooms = roomsData.map((room) {
          return RelayChatRoom.fromJson(
            room as Map<String, dynamic>,
            relayUrl,
            relayName,
          );
        }).toList();

        LogService().log('Fetched ${rooms.length} chat rooms from $relayName');
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

  /// Get relay callsign from status endpoint
  Future<String?> _getRelayCallsign(String httpUrl) async {
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
      LogService().log('Error fetching relay callsign: $e');
    }
    return null;
  }

  /// Fetch messages from a relay chat room
  /// [relayCallsign] is the relay's X3 callsign used in the API path
  Future<List<RelayChatMessage>> fetchRoomMessages(
    String relayUrl,
    String roomId, {
    int limit = 50,
    String? relayCallsign,
  }) async {
    try {
      final httpUrl = _getHttpBaseUrl(relayUrl);

      // If no callsign provided, try to get it from status endpoint
      String? callsign = relayCallsign;
      if (callsign == null || callsign.isEmpty) {
        callsign = await _getRelayCallsign(httpUrl);
      }

      if (callsign == null || callsign.isEmpty) {
        LogService().log('Cannot fetch messages: relay callsign not available');
        return [];
      }

      final apiUrl = ChatApi.messagesUrl(httpUrl, callsign, roomId, limit: limit);

      LogService().log('Fetching messages from room: $roomId');
      final response = await http.get(Uri.parse(apiUrl));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final messagesData = data['messages'] as List<dynamic>? ?? [];

        final messages = messagesData.map((msg) {
          return RelayChatMessage.fromJson(
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
    String relayUrl,
    String roomId,
  ) async {
    try {
      final httpUrl = _getHttpBaseUrl(relayUrl);
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
    String relayUrl,
    String roomId,
    String year,
    String filename,
  ) async {
    try {
      final httpUrl = _getHttpBaseUrl(relayUrl);
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

  /// Post a message to a relay chat room as a NOSTR event
  /// Creates a signed kind 1 text note and sends via WebSocket or HTTP
  Future<bool> postRoomMessage(
    String relayUrl,
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
        final httpUrl = _getHttpBaseUrl(relayUrl);

        // Get relay callsign for API path
        final relayCallsign = await _getRelayCallsign(httpUrl);
        if (relayCallsign == null || relayCallsign.isEmpty) {
          LogService().log('Cannot post message: relay callsign not available');
          return false;
        }

        final apiUrl = ChatApi.messagesUrl(httpUrl, relayCallsign, roomId);

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
      LogService().log('Cannot subscribe: not connected to relay');
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

  /// Fetch chat rooms from connected relay
  Future<List<RelayChatRoom>> fetchConnectedRelayChatRooms() async {
    final relay = getConnectedRelay();
    if (relay == null) {
      LogService().log('No relay connected');
      return [];
    }
    return fetchChatRooms(relay.url);
  }
}
