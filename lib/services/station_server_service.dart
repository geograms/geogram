import 'dart:async';
import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:path/path.dart' as path;

import '../services/log_service.dart';
import '../services/config_service.dart';
import '../services/profile_service.dart';
import '../services/callsign_generator.dart';
import '../services/storage_config.dart';
import '../services/collection_service.dart';
import '../services/direct_message_service.dart';
import '../services/chat_service.dart';
import '../services/app_args.dart';
import '../services/event_service.dart';
import '../services/station_alert_api.dart';
import '../services/station_place_api.dart';
import '../services/station_feedback_api.dart';
import '../models/blog_post.dart';
import '../models/chat_channel.dart';
import '../models/chat_message.dart';
import '../models/event.dart';
import '../models/update_settings.dart';
import '../util/nostr_event.dart';
import '../util/nostr_crypto.dart';
import '../util/alert_folder_utils.dart';
import '../util/feedback_folder_utils.dart';
import '../util/reaction_utils.dart';
import '../util/event_bus.dart';
import '../version.dart';

/// Station server settings
class RelayServerSettings {
  int port;
  bool enabled;
  bool tileServerEnabled;
  bool osmFallbackEnabled;
  int maxZoomLevel;
  int maxCacheSize; // in MB
  String? description;
  String? location;
  double? latitude;
  double? longitude;
  // Update mirror settings
  bool updateMirrorEnabled;      // Enable/disable update mirroring from GitHub
  int updateCheckInterval;       // Polling interval in seconds (default: 120 = 2 min)
  String? lastMirroredVersion;   // Track what version has been downloaded
  String updateMirrorUrl;        // GitHub API URL for releases (can be changed for different repos)

  RelayServerSettings({
    this.port = 8080,
    this.enabled = false,
    this.tileServerEnabled = true,
    this.osmFallbackEnabled = true,
    this.maxZoomLevel = 15,
    this.maxCacheSize = 500,
    this.description,
    this.location,
    this.latitude,
    this.longitude,
    this.updateMirrorEnabled = true,
    this.updateCheckInterval = 120,
    this.lastMirroredVersion,
    this.updateMirrorUrl = 'https://api.github.com/repos/geograms/geogram/releases/latest',
  });

  factory RelayServerSettings.fromJson(Map<String, dynamic> json) {
    return RelayServerSettings(
      port: json['port'] as int? ?? 8080,
      enabled: json['enabled'] as bool? ?? false,
      tileServerEnabled: json['tileServerEnabled'] as bool? ?? true,
      osmFallbackEnabled: json['osmFallbackEnabled'] as bool? ?? true,
      maxZoomLevel: json['maxZoomLevel'] as int? ?? 15,
      maxCacheSize: json['maxCacheSize'] as int? ?? 500,
      description: json['description'] as String?,
      location: json['location'] as String?,
      latitude: json['latitude'] as double?,
      longitude: json['longitude'] as double?,
      updateMirrorEnabled: json['updateMirrorEnabled'] as bool? ?? true,
      updateCheckInterval: json['updateCheckInterval'] as int? ?? 120,
      lastMirroredVersion: json['lastMirroredVersion'] as String?,
      updateMirrorUrl: json['updateMirrorUrl'] as String? ?? 'https://api.github.com/repos/geograms/geogram/releases/latest',
    );
  }

  Map<String, dynamic> toJson() => {
        'port': port,
        'enabled': enabled,
        'tileServerEnabled': tileServerEnabled,
        'osmFallbackEnabled': osmFallbackEnabled,
        'maxZoomLevel': maxZoomLevel,
        'maxCacheSize': maxCacheSize,
        'description': description,
        'location': location,
        'latitude': latitude,
        'longitude': longitude,
        'updateMirrorEnabled': updateMirrorEnabled,
        'updateCheckInterval': updateCheckInterval,
        'lastMirroredVersion': lastMirroredVersion,
        'updateMirrorUrl': updateMirrorUrl,
      };

  RelayServerSettings copyWith({
    int? port,
    bool? enabled,
    bool? tileServerEnabled,
    bool? osmFallbackEnabled,
    int? maxZoomLevel,
    int? maxCacheSize,
    String? description,
    String? location,
    double? latitude,
    double? longitude,
    bool? updateMirrorEnabled,
    int? updateCheckInterval,
    String? lastMirroredVersion,
    String? updateMirrorUrl,
  }) {
    return RelayServerSettings(
      port: port ?? this.port,
      enabled: enabled ?? this.enabled,
      tileServerEnabled: tileServerEnabled ?? this.tileServerEnabled,
      osmFallbackEnabled: osmFallbackEnabled ?? this.osmFallbackEnabled,
      maxZoomLevel: maxZoomLevel ?? this.maxZoomLevel,
      maxCacheSize: maxCacheSize ?? this.maxCacheSize,
      description: description ?? this.description,
      location: location ?? this.location,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      updateMirrorEnabled: updateMirrorEnabled ?? this.updateMirrorEnabled,
      updateCheckInterval: updateCheckInterval ?? this.updateCheckInterval,
      lastMirroredVersion: lastMirroredVersion ?? this.lastMirroredVersion,
      updateMirrorUrl: updateMirrorUrl ?? this.updateMirrorUrl,
    );
  }
}

/// Connection type enum
enum ConnectionType {
  localWifi,
  internet,
  bluetooth,
  lora,
  radio,
  other;

  String get displayName {
    switch (this) {
      case ConnectionType.localWifi:
        return 'Local Wi-Fi';
      case ConnectionType.internet:
        return 'Internet';
      case ConnectionType.bluetooth:
        return 'Bluetooth';
      case ConnectionType.lora:
        return 'LoRa';
      case ConnectionType.radio:
        return 'Radio';
      case ConnectionType.other:
        return 'Other';
    }
  }

  String get code {
    switch (this) {
      case ConnectionType.localWifi:
        return 'wifi';
      case ConnectionType.internet:
        return 'internet';
      case ConnectionType.bluetooth:
        return 'bluetooth';
      case ConnectionType.lora:
        return 'lora';
      case ConnectionType.radio:
        return 'radio';
      case ConnectionType.other:
        return 'other';
    }
  }

  static ConnectionType fromCode(String code) {
    switch (code) {
      case 'wifi':
        return ConnectionType.localWifi;
      case 'internet':
        return ConnectionType.internet;
      case 'bluetooth':
        return ConnectionType.bluetooth;
      case 'lora':
        return ConnectionType.lora;
      case 'radio':
        return ConnectionType.radio;
      default:
        return ConnectionType.other;
    }
  }
}

/// Connected WebSocket client
class ConnectedClient {
  final WebSocket socket;
  final String id;
  String? callsign;
  String? nickname;
  String? npub;
  String? remoteAddress;
  ConnectionType connectionType;
  double? latitude;
  double? longitude;
  DateTime connectedAt;
  DateTime lastActivity;

  ConnectedClient({
    required this.socket,
    required this.id,
    this.callsign,
    this.nickname,
    this.npub,
    this.remoteAddress,
    this.connectionType = ConnectionType.other,
    this.latitude,
    this.longitude,
  })  : connectedAt = DateTime.now(),
        lastActivity = DateTime.now();

  /// Detect connection type from remote address
  static ConnectionType detectConnectionType(String? address) {
    if (address == null) return ConnectionType.other;

    // Local network addresses (Wi-Fi)
    if (address.startsWith('192.168.') ||
        address.startsWith('10.') ||
        address.startsWith('172.16.') ||
        address.startsWith('172.17.') ||
        address.startsWith('172.18.') ||
        address.startsWith('172.19.') ||
        address.startsWith('172.2') ||
        address.startsWith('172.30.') ||
        address.startsWith('172.31.') ||
        address == '127.0.0.1' ||
        address == 'localhost') {
      return ConnectionType.localWifi;
    }

    // Public IPs are likely internet
    return ConnectionType.internet;
  }

  /// Convert to JSON for API response
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'callsign': callsign,
      'nickname': nickname ?? callsign,
      'npub': npub,
      'connection_type': connectionType.code,
      'latitude': latitude,
      'longitude': longitude,
      'connected_at': connectedAt.toIso8601String(),
      'last_activity': lastActivity.toIso8601String(),
    };
  }
}

/// Tile cache for station server
class TileCache {
  final Map<String, Uint8List> _cache = {};
  final Map<String, DateTime> _timestamps = {};
  int _currentSize = 0;
  final int maxSizeBytes;

  TileCache({int maxSizeMB = 500}) : maxSizeBytes = maxSizeMB * 1024 * 1024;

  Uint8List? get(String key) {
    final data = _cache[key];
    if (data != null) {
      _timestamps[key] = DateTime.now();
    }
    return data;
  }

  void put(String key, Uint8List data) {
    // Remove if already exists
    if (_cache.containsKey(key)) {
      _currentSize -= _cache[key]!.length;
    }

    // Evict old entries if needed
    while (_currentSize + data.length > maxSizeBytes && _cache.isNotEmpty) {
      _evictOldest();
    }

    _cache[key] = data;
    _timestamps[key] = DateTime.now();
    _currentSize += data.length;
  }

  void _evictOldest() {
    if (_timestamps.isEmpty) return;

    String? oldestKey;
    DateTime? oldestTime;

    for (final entry in _timestamps.entries) {
      if (oldestTime == null || entry.value.isBefore(oldestTime)) {
        oldestTime = entry.value;
        oldestKey = entry.key;
      }
    }

    if (oldestKey != null && _cache.containsKey(oldestKey)) {
      _currentSize -= _cache[oldestKey]!.length;
      _cache.remove(oldestKey);
      _timestamps.remove(oldestKey);
    }
  }

  int get size => _cache.length;
  int get sizeBytes => _currentSize;

  void clear() {
    _cache.clear();
    _timestamps.clear();
    _currentSize = 0;
  }

  static bool isValidImageData(Uint8List data) {
    if (data.length < 8) return false;
    // Check PNG signature
    return data[0] == 0x89 &&
        data[1] == 0x50 &&
        data[2] == 0x4E &&
        data[3] == 0x47;
  }
}

/// Station server service for CLI mode
class StationServerService {
  static final StationServerService _instance = StationServerService._internal();
  factory StationServerService() => _instance;
  StationServerService._internal();

  HttpServer? _httpServer;
  RelayServerSettings _settings = RelayServerSettings();
  final Map<String, ConnectedClient> _clients = {};
  final TileCache _tileCache = TileCache();
  bool _running = false;
  DateTime? _startTime;
  String? _tilesDirectory;
  int? _runningPort; // Actual port the server is running on

  // Pending HTTP proxy requests (requestId -> completer)
  final Map<String, Completer<Map<String, dynamic>>> _pendingHttpRequests = {};

  // Update mirror state
  Timer? _updatePollTimer;
  Map<String, dynamic>? _cachedRelease;
  String? _updatesDirectory;
  bool _isDownloadingUpdates = false;

  // Shared alert API handlers
  StationAlertApi? _alertApi;
  StationPlaceApi? _placeApi;
  StationFeedbackApi? _feedbackApi;

  /// Get the shared alert API handlers (lazy initialization)
  StationAlertApi get alertApi {
    if (_alertApi == null) {
      final profile = ProfileService().getProfile();
      _alertApi = StationAlertApi(
        dataDir: StorageConfig().baseDir,
        stationInfo: StationInfo(
          name: _settings.description ?? 'Geogram Station',
          callsign: profile.callsign,
          npub: profile.npub,
        ),
        log: (level, message) => LogService().log('StationAlertApi: [$level] $message'),
      );
    }
    return _alertApi!;
  }

  /// Get the shared places API handlers (lazy initialization)
  StationPlaceApi get placeApi {
    if (_placeApi == null) {
      final profile = ProfileService().getProfile();
      _placeApi = StationPlaceApi(
        dataDir: StorageConfig().baseDir,
        stationName: _settings.description ?? 'Geogram Station',
        stationCallsign: profile.callsign,
        stationNpub: profile.npub,
        log: (level, message) => LogService().log('StationPlaceApi: [$level] $message'),
      );
    }
    return _placeApi!;
  }

  /// Get the shared feedback API handlers (lazy initialization)
  StationFeedbackApi get feedbackApi {
    if (_feedbackApi == null) {
      _feedbackApi = StationFeedbackApi(
        dataDir: StorageConfig().baseDir,
        log: (level, message) => LogService().log('StationFeedbackApi: [$level] $message'),
      );
    }
    return _feedbackApi!;
  }

  bool get isRunning => _running;
  int get connectedDevices => _clients.length;
  RelayServerSettings get settings => _settings;
  DateTime? get startTime => _startTime;

  /// Get the actual port the station server is running on
  /// Returns null if server is not running
  int? get runningPort => _runningPort;

  /// Initialize station server service
  Future<void> initialize() async {
    await _loadSettings();

    // Create tiles directory
    final appDir = await getApplicationSupportDirectory();
    _tilesDirectory = '${appDir.path}/tiles';
    await Directory(_tilesDirectory!).create(recursive: true);

    // Create updates directory in current working directory (for server deployments)
    _updatesDirectory = '${Directory.current.path}/updates';
    await Directory(_updatesDirectory!).create(recursive: true);

    // Load cached release info if exists
    await _loadCachedRelease();

    LogService().log('StationServerService initialized');
  }

  /// Load settings from config
  Future<void> _loadSettings() async {
    final config = ConfigService().getAll();
    if (config.containsKey('stationServer')) {
      _settings = RelayServerSettings.fromJson(
          config['stationServer'] as Map<String, dynamic>);
    }
  }

  /// Save settings to config
  void _saveSettings() {
    ConfigService().set('stationServer', _settings.toJson());
  }

  /// Update settings
  Future<void> updateSettings(RelayServerSettings settings) async {
    final wasRunning = _running;
    final oldPort = _settings.port;

    _settings = settings;
    _saveSettings();

    // Restart if port changed and was running
    if (wasRunning && oldPort != settings.port) {
      await stop();
      await start();
    }
  }

  /// Start the station server
  Future<bool> start() async {
    if (_running) {
      LogService().log('Station server already running');
      return true;
    }

    try {
      // Determine the port to use:
      // - If custom port set in settings (not default 8080), use that
      // - Otherwise, use AppArgs().port + 1 to avoid conflicts
      int serverPort = _settings.port;
      if (_settings.port == 8080 && AppArgs().isInitialized) {
        // Use the main API port + 1 to keep station server on predictable port
        serverPort = AppArgs().port + 1;
      }

      _httpServer = await HttpServer.bind(
        InternetAddress.anyIPv4,
        serverPort,
        shared: true,
      );

      _running = true;
      _startTime = DateTime.now();
      _runningPort = serverPort;

      LogService().log('Station server started on port $serverPort');

      // Handle incoming connections
      _httpServer!.listen(_handleRequest, onError: (error) {
        LogService().log('Server error: $error');
      });

      // Start update polling if enabled
      _startUpdatePolling();

      return true;
    } catch (e) {
      LogService().log('Failed to start station server: $e');
      return false;
    }
  }

  /// Stop the station server
  Future<void> stop() async {
    if (!_running) return;

    // Stop update polling
    _updatePollTimer?.cancel();
    _updatePollTimer = null;

    // Close all WebSocket connections
    for (final client in _clients.values) {
      await client.socket.close();
    }
    _clients.clear();

    // Close HTTP server
    await _httpServer?.close(force: true);
    _httpServer = null;
    _running = false;
    _startTime = null;
    _runningPort = null;

    LogService().log('Station server stopped');
  }

  /// Handle incoming HTTP request
  Future<void> _handleRequest(HttpRequest request) async {
    final path = request.uri.path;
    final method = request.method;

    try {
      // Log all blog-related requests for debugging
      if (path.contains('/blog/')) {
        LogService().log('Incoming request: $method $path');
      }

      // WebSocket upgrade
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        await _handleWebSocket(request);
        return;
      }

      // CORS headers
      request.response.headers.add('Access-Control-Allow-Origin', '*');
      request.response.headers.add('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS');
      request.response.headers.add(
          'Access-Control-Allow-Headers',
          'Content-Type, Authorization, X-Device-Callsign, X-Filename');

      if (method == 'OPTIONS') {
        request.response.statusCode = 200;
        await request.response.close();
        return;
      }

      // Route requests
      if (path == '/api/status' || path == '/status') {
        await _handleStatus(request);
      } else if (path == '/api/clients') {
        await _handleClients(request);
      } else if (path == '/api/alerts' || path == '/api/alerts/list') {
        // GET /api/alerts - list alerts (using shared handler)
        await _handleAlertsApi(request);
      } else if (path == '/api/places' || path == '/api/places/list') {
        // GET /api/places - list places (using shared handler)
        await _handlePlacesApi(request);
      } else if (path == '/api/events' || path == '/api/events/list' || path.startsWith('/api/events/')) {
        await _handleEventsRequest(request);
      } else if (path.startsWith('/api/feedback/')) {
        // /api/feedback/{contentType}/{contentId}/...
        await _handleFeedbackApi(request);
      } else if (path.startsWith('/api/alerts/') && method == 'POST') {
        // POST /api/alerts/{alertId}/{action} - alert feedback (using shared handler)
        await _handleAlertFeedback(request);
      } else if (path.startsWith('/api/chat/') &&
          path.contains('/messages/') &&
          path.endsWith('/reactions')) {
        await _handleRoomMessageReactions(request);
      } else if (path == '/api/chat/rooms') {
        await _handleChatRooms(request);
      } else if (path.startsWith('/api/chat/rooms/') && path.endsWith('/messages')) {
        await _handleRoomMessages(request);
      } else if (_isChatFileUploadPath(path, method)) {
        // Handle chat file uploads: POST /api/chat/rooms/{roomId}/files
        await _handleChatFileUpload(request);
      } else if (_isChatFileFetchPath(path, method)) {
        // Handle chat file downloads: GET /api/chat/rooms/{roomId}/files/{filename}
        await _handleChatFileFetch(request);
      } else if (path == '/api/updates/latest') {
        await _handleUpdatesLatest(request);
      } else if (path.startsWith('/updates/')) {
        await _handleUpdateDownload(request);
      } else if (path.startsWith('/tiles/')) {
        await _handleTileRequest(request);
      } else if (_isBlogPath(path)) {
        await _handleBlogRequest(request);
      } else if (path.contains('/api/dm/')) {
        await _handleDMRequest(request);
      } else if (_isAlertFileUploadPath(path, request.method)) {
        // Handle alert file uploads - store locally instead of proxying
        await _handleAlertFileUpload(request);
      } else if (_isAlertFileFetchPath(path, request.method)) {
        // Handle alert file downloads - serve from local storage
        await _handleAlertFileFetch(request);
      } else if (_isPlaceFileUploadPath(path, request.method)) {
        // Handle place file uploads - store locally instead of proxying
        await _handlePlaceFileUpload(request);
      } else if (_isPlaceFileFetchPath(path, request.method)) {
        // Handle place file downloads - serve from local storage
        await _handlePlaceFileFetch(request);
      } else if (_isAlertDetailsPath(path) && method == 'GET') {
        // GET /{callsign}/api/alerts/{alertId} - alert details (using shared handler)
        await _handleAlertDetails(request);
      } else if (_isPlaceDetailsPath(path) && method == 'GET') {
        // GET /api/places/{callsign}/{folderName} - place details (using shared handler)
        await _handlePlaceDetails(request);
      } else if (_isDeviceProxyPath(path)) {
        // Proxy API requests to connected devices: /{callsign}/api/*
        await _handleDeviceProxyRequest(request);
      } else if (path == '/') {
        await _handleRoot(request);
      } else {
        request.response.statusCode = 404;
        request.response.write('Not Found');
      }
    } catch (e) {
      LogService().log('Request error: $e');
      request.response.statusCode = 500;
      request.response.write('Internal Server Error');
    }

    await request.response.close();
  }

  /// Handle WebSocket connection
  Future<void> _handleWebSocket(HttpRequest request) async {
    try {
      final socket = await WebSocketTransformer.upgrade(request);
      final clientId = DateTime.now().millisecondsSinceEpoch.toString();

      // Get remote address for connection type detection
      final remoteAddress = request.connectionInfo?.remoteAddress.address;
      final connectionType = ConnectedClient.detectConnectionType(remoteAddress);

      final client = ConnectedClient(
        socket: socket,
        id: clientId,
        remoteAddress: remoteAddress,
        connectionType: connectionType,
      );

      _clients[clientId] = client;
      LogService().log('WebSocket client connected: $clientId from $remoteAddress ($connectionType)');

      socket.listen(
        (data) => _handleWebSocketMessage(client, data),
        onDone: () {
          _clients.remove(clientId);
          LogService().log('WebSocket client disconnected: $clientId');
        },
        onError: (error) {
          LogService().log('WebSocket error: $error');
          _clients.remove(clientId);
        },
      );
    } catch (e) {
      LogService().log('WebSocket upgrade failed: $e');
    }
  }

  /// Handle WebSocket message
  void _handleWebSocketMessage(ConnectedClient client, dynamic data) {
    try {
      client.lastActivity = DateTime.now();

      if (data is String) {
        final message = jsonDecode(data) as Map<String, dynamic>;
        final type = message['type'] as String?;

        if (type == 'hello') {
          // Client hello handshake
          _handleHelloMessage(client, message);
        } else if (type == 'EVENT') {
          // NOSTR EVENT message
          _handleNostrEvent(client, message);
        } else if (type == 'PING') {
          // Heartbeat ping
          client.socket.add(jsonEncode({'type': 'PONG'}));
        } else if (type == 'HTTP_RESPONSE') {
          // Response from client for proxied HTTP request
          _handleHttpResponse(message);
        }
      }
    } catch (e) {
      LogService().log('WebSocket message error: $e');
    }
  }

  /// Handle hello message from client
  void _handleHelloMessage(ConnectedClient client, Map<String, dynamic> message) {
    final event = message['event'] as Map<String, dynamic>?;
    String? callsign;
    String? npub;
    String? nickname;
    double? latitude;
    double? longitude;

    if (event != null) {
      // Extract data from hello event tags
      final tags = event['tags'] as List<dynamic>?;
      if (tags != null) {
        for (final tag in tags) {
          if (tag is List && tag.isNotEmpty) {
            final tagName = tag[0] as String;
            if (tagName == 'callsign' && tag.length > 1) {
              callsign = tag[1] as String;
            } else if (tagName == 'nickname' && tag.length > 1) {
              nickname = tag[1] as String;
            } else if ((tagName == 'latitude' || tagName == 'lat') && tag.length > 1) {
              latitude = double.tryParse(tag[1].toString());
            } else if ((tagName == 'longitude' || tagName == 'lon') && tag.length > 1) {
              longitude = double.tryParse(tag[1].toString());
            }
          }
        }
      }
      // Get npub from pubkey
      final pubkey = event['pubkey'] as String?;
      if (pubkey != null) {
        npub = NostrCrypto.encodeNpub(pubkey);
      }
    } else {
      // Legacy format without event wrapper
      callsign = message['callsign'] as String?;
      nickname = message['nickname'] as String?;
      latitude = message['latitude'] as double?;
      longitude = message['longitude'] as double?;
    }

    // Update client info
    client.callsign = callsign;
    client.nickname = nickname ?? callsign;
    client.npub = npub;
    client.latitude = latitude;
    client.longitude = longitude;

    // Send hello acknowledgment
    final response = {
      'type': 'hello_ack',
      'success': true,
      'message': 'Welcome to Geogram Station',
      'server': 'geogram-station',
      'version': appVersion,
      'station_id': ProfileService().getProfile().callsign,
    };
    client.socket.add(jsonEncode(response));

    LogService().log('Hello from client: $callsign (npub: ${npub?.substring(0, 20)}...)');

    // Fire client connected event
    EventBus().fire(ClientConnectedEvent(
      clientId: client.id,
      callsign: callsign,
      npub: npub,
    ));
  }

  /// Handle NOSTR EVENT message
  Future<void> _handleNostrEvent(ConnectedClient client, Map<String, dynamic> message) async {
    try {
      final eventData = message['event'] as Map<String, dynamic>?;
      if (eventData == null) {
        _sendOkResponse(client, null, false, 'Missing event data');
        return;
      }

      final event = NostrEvent.fromJson(eventData);
      final eventId = event.id ?? '';

      // Verify signature
      if (!event.verify()) {
        LogService().log('Alert event signature verification failed');
        _sendOkResponse(client, eventId, false, 'Invalid signature');
        return;
      }

      // Handle based on event kind
      if (event.kind == NostrEventKind.applicationSpecificData) {
        // Check for alert tag
        final alertTag = event.getTagValue('t');
        if (alertTag == 'alert') {
          await _handleAlertEvent(client, event);
          return;
        }
      }

      // Unknown event kind - accept but don't process
      LogService().log('Received event kind ${event.kind} - ignoring');
      _sendOkResponse(client, eventId, true, 'Event received but not processed');
    } catch (e) {
      LogService().log('Error handling NOSTR event: $e');
      _sendOkResponse(client, null, false, 'Error: $e');
    }
  }

  /// Handle alert event (kind 30078 with t=alert tag)
  Future<void> _handleAlertEvent(ConnectedClient client, NostrEvent event) async {
    final eventId = event.id ?? '';

    try {
      // Extract alert metadata from tags
      final folderName = event.getTagValue('d') ?? '';
      final coordsStr = event.getTagValue('g') ?? '';
      final severity = event.getTagValue('severity') ?? 'info';
      final status = event.getTagValue('status') ?? 'open';
      final alertType = event.getTagValue('type') ?? 'other';

      // Parse coordinates
      double latitude = 0;
      double longitude = 0;
      if (coordsStr.contains(',')) {
        final parts = coordsStr.split(',');
        latitude = double.tryParse(parts[0]) ?? 0;
        longitude = double.tryParse(parts[1]) ?? 0;
      }

      // Get sender info
      final senderNpub = NostrCrypto.encodeNpub(event.pubkey);
      final senderCallsign = client.callsign ?? 'X1${NostrCrypto.deriveCallsign(event.pubkey)}';

      LogService().log('═══════════════════════════════════════════════════');
      LogService().log('ALERT RECEIVED');
      LogService().log('═══════════════════════════════════════════════════');
      LogService().log('Event ID: $eventId');
      LogService().log('From: $senderCallsign');
      LogService().log('Folder: $folderName');
      LogService().log('Coordinates: $latitude, $longitude');
      LogService().log('Severity: $severity');
      LogService().log('Status: $status');
      LogService().log('Type: $alertType');
      LogService().log('Content length: ${event.content.length} chars');
      LogService().log('═══════════════════════════════════════════════════');

      // Store alert
      await _storeAlert(senderCallsign, folderName, event.content);

      // Fire event for subscribers
      EventBus().fire(AlertReceivedEvent(
        eventId: eventId,
        senderCallsign: senderCallsign,
        senderNpub: senderNpub,
        folderName: folderName,
        latitude: latitude,
        longitude: longitude,
        severity: severity,
        status: status,
        type: alertType,
        content: event.content,
        verified: true,
      ));

      // Send OK acknowledgment
      _sendOkResponse(client, eventId, true, 'Alert stored successfully');

      // Notify all connected clients about the new alert
      _broadcastUpdate('UPDATE:$senderCallsign/alerts/$folderName');
    } catch (e) {
      LogService().log('Error storing alert: $e');
      _sendOkResponse(client, eventId, false, 'Storage error: $e');
    }
  }

  /// Store alert in devices/{callsign}/alerts/{folderName}/report.txt
  Future<void> _storeAlert(String callsign, String folderName, String content) async {
    final storageConfig = StorageConfig();
    final devicesDir = storageConfig.devicesDir;
    final alertPath = '$devicesDir/$callsign/alerts/$folderName';

    final alertDir = Directory(alertPath);
    if (!await alertDir.exists()) {
      await alertDir.create(recursive: true);
    }

    final reportFile = File('$alertPath/report.txt');
    await reportFile.writeAsString(content, flush: true);

    LogService().log('Alert stored at: $alertPath/report.txt');
  }

  /// Send NOSTR OK response
  void _sendOkResponse(ConnectedClient client, String? eventId, bool success, String message) {
    final response = jsonEncode(['OK', eventId ?? '', success, message]);
    client.socket.add(response);
    LogService().log('Sent OK response: success=$success, message=$message');
  }

  /// Broadcast update to all connected clients
  void _broadcastUpdate(String updateMessage) {
    for (final client in _clients.values) {
      try {
        client.socket.add(updateMessage);
      } catch (e) {
        LogService().log('Error broadcasting to client ${client.id}: $e');
      }
    }
    LogService().log('Broadcast update to ${_clients.length} clients: $updateMessage');
  }

  /// Handle /api/status endpoint
  Future<void> _handleStatus(HttpRequest request) async {
    final profile = ProfileService().getProfile();
    final isRelay = CallsignGenerator.isStationCallsign(profile.callsign);

    final uptime = _startTime != null
        ? DateTime.now().difference(_startTime!).inSeconds
        : 0;

    final status = {
      'name': 'Geogram Desktop Station',
      'version': appVersion,
      'callsign': profile.callsign,
      'description': _settings.description ?? 'Geogram Desktop Station Server',
      'connected_devices': _clients.length,
      'uptime': uptime,
      'station_mode': isRelay,
      'location': _settings.location,
      'latitude': _settings.latitude,
      'longitude': _settings.longitude,
      'tile_server': _settings.tileServerEnabled,
      'osm_fallback': _settings.osmFallbackEnabled,
      'cache_size': _tileCache.size,
      'cache_size_bytes': _tileCache.sizeBytes,
    };

    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(status));
  }

  /// Handle /api/clients endpoint - returns list of connected clients
  Future<void> _handleClients(HttpRequest request) async {
    final profile = ProfileService().getProfile();

    // Group clients by callsign and aggregate connection types
    final clientsByCallsign = <String, Map<String, dynamic>>{};

    for (final client in _clients.values) {
      final callsign = client.callsign ?? 'unknown';

      if (clientsByCallsign.containsKey(callsign)) {
        // Add connection type to existing entry if not already present
        final existing = clientsByCallsign[callsign]!;
        final connectionTypes = existing['connection_types'] as List<String>;
        if (!connectionTypes.contains(client.connectionType.code)) {
          connectionTypes.add(client.connectionType.code);
        }
        // Update last activity if more recent
        final existingActivity = DateTime.parse(existing['last_activity'] as String);
        if (client.lastActivity.isAfter(existingActivity)) {
          existing['last_activity'] = client.lastActivity.toIso8601String();
        }
      } else {
        // Create new entry
        clientsByCallsign[callsign] = {
          'callsign': client.callsign,
          'nickname': client.nickname ?? client.callsign,
          'npub': client.npub,
          'connection_types': [client.connectionType.code],
          'latitude': client.latitude,
          'longitude': client.longitude,
          'connected_at': client.connectedAt.toIso8601String(),
          'last_activity': client.lastActivity.toIso8601String(),
          'is_online': true,
        };
      }
    }

    final response = {
      'station': profile.callsign,
      'count': clientsByCallsign.length,
      'clients': clientsByCallsign.values.toList(),
    };

    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(response));
  }

  /// Handle / root endpoint
  Future<void> _handleRoot(HttpRequest request) async {
    final profile = ProfileService().getProfile();

    request.response.headers.contentType = ContentType.html;
    request.response.write('''
<!DOCTYPE html>
<html>
<head>
  <title>Geogram Desktop Station</title>
  <style>
    body { font-family: sans-serif; padding: 20px; max-width: 800px; margin: 0 auto; }
    h1 { color: #333; }
    .info { background: #f5f5f5; padding: 15px; border-radius: 5px; }
    .info p { margin: 5px 0; }
  </style>
</head>
<body>
  <h1>Geogram Desktop Station</h1>
  <div class="info">
    <p><strong>Version:</strong> $appVersion</p>
    <p><strong>Callsign:</strong> ${profile.callsign}</p>
    <p><strong>Connected Devices:</strong> ${_clients.length}</p>
    <p><strong>Status:</strong> Running</p>
  </div>
  <p>API endpoint: <a href="/api/status">/api/status</a></p>
</body>
</html>
''');
  }

  Future<bool> _initializeChatServiceIfNeeded({bool createIfMissing = false}) async {
    try {
      final chatService = ChatService();
      if (chatService.collectionPath != null) {
        return true;
      }

      final collectionsDir = CollectionService().collectionsDirectory;
      final chatDir = Directory(path.join(collectionsDir.path, 'chat'));
      if (!await chatDir.exists()) {
        if (createIfMissing) {
          await chatDir.create(recursive: true);
          LogService().log('StationServerService: Created chat directory at ${chatDir.path}');
        } else {
          return false;
        }
      }

      final profile = ProfileService().getProfile();
      await chatService.initializeCollection(chatDir.path, creatorNpub: profile.npub);
      LogService().log('StationServerService: ChatService initialized with ${chatService.channels.length} channels');
      return true;
    } catch (e) {
      LogService().log('StationServerService: Error initializing ChatService: $e');
      return false;
    }
  }

  String? _verifyNostrAuth(HttpRequest request) {
    final authHeader = request.headers.value('authorization');
    if (authHeader == null || !authHeader.startsWith('Nostr ')) {
      return null;
    }

    try {
      final base64Event = authHeader.substring(6);
      final eventJson = utf8.decode(base64Decode(base64Event));
      final eventData = jsonDecode(eventJson) as Map<String, dynamic>;
      final event = NostrEvent.fromJson(eventData);

      if (!event.verify()) {
        LogService().log('StationServerService: NOSTR auth failed - invalid signature');
        return null;
      }

      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if ((now - event.createdAt).abs() > 300) {
        LogService().log('StationServerService: NOSTR auth failed - event too old');
        return null;
      }

      return event.npub;
    } catch (e) {
      LogService().log('StationServerService: NOSTR auth failed - parse error: $e');
      return null;
    }
  }

  NostrEvent? _verifyNostrEventWithTags(
    HttpRequest request,
    String expectedAction,
    String expectedRoomId,
  ) {
    final authHeader = request.headers.value('authorization');
    if (authHeader == null || !authHeader.startsWith('Nostr ')) {
      return null;
    }

    try {
      final base64Event = authHeader.substring(6);
      final eventJson = utf8.decode(base64Decode(base64Event));
      final eventData = jsonDecode(eventJson) as Map<String, dynamic>;
      final event = NostrEvent.fromJson(eventData);

      if (!event.verify()) {
        LogService().log('StationServerService: NOSTR event verification failed - invalid signature');
        return null;
      }

      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if ((now - event.createdAt).abs() > 300) {
        LogService().log('StationServerService: NOSTR event verification failed - expired');
        return null;
      }

      final actionTag = event.getTagValue('action');
      if (actionTag != expectedAction) {
        LogService().log(
          'StationServerService: NOSTR event verification failed - action mismatch: $actionTag != $expectedAction',
        );
        return null;
      }

      final roomTag = event.getTagValue('room');
      if (roomTag != expectedRoomId) {
        LogService().log(
          'StationServerService: NOSTR event verification failed - room mismatch: $roomTag != $expectedRoomId',
        );
        return null;
      }

      return event;
    } catch (e) {
      LogService().log('StationServerService: NOSTR event verification failed - parse error: $e');
      return null;
    }
  }

  Future<bool> _canAccessChatRoom(String roomId, String? npub, {String? callsign}) async {
    final chatService = ChatService();
    final channel = chatService.getChannel(roomId);
    if (channel == null) {
      return false;
    }

    final config = channel.config;
    final visibility = config?.visibility ?? 'PUBLIC';

    if (visibility == 'PUBLIC') {
      return true;
    }

    if (npub == null && callsign == null) {
      return false;
    }

    final security = chatService.security;
    if (npub != null && security.isAdmin(npub)) {
      return true;
    }

    if (visibility == 'RESTRICTED' && config != null) {
      if (config.isBanned(npub)) {
        return false;
      }
      if (config.canAccess(npub)) {
        return true;
      }
    }

    if (channel.participants.contains('*')) {
      return true;
    }

    if (channel.isDirect && callsign != null) {
      if (channel.participants.any((p) => p.toUpperCase() == callsign.toUpperCase())) {
        return true;
      }
      if (roomId.toUpperCase() == callsign.toUpperCase()) {
        return true;
      }
    }

    if (npub != null) {
      final participants = chatService.participants;
      for (final entry in participants.entries) {
        if (entry.value == npub && channel.participants.contains(entry.key)) {
          return true;
        }
      }
    }

    return false;
  }

  Future<void> _ensureDefaultChatChannel(ChatService chatService) async {
    if (chatService.channels.isNotEmpty) {
      return;
    }

    final collectionPath = chatService.collectionPath;
    if (collectionPath == null) {
      return;
    }

    final generalDir = Directory(path.join(collectionPath, 'general'));
    final mainDir = Directory(path.join(collectionPath, 'main'));
    final useGeneral = await generalDir.exists() && !await mainDir.exists();

    final channel = useGeneral
        ? ChatChannel(
            id: 'general',
            type: ChatChannelType.group,
            name: 'General',
            folder: 'general',
            participants: ['*'],
            description: 'General discussion',
            created: DateTime.now(),
          )
        : ChatChannel.main(
            name: 'Main',
            description: 'Public group chat',
          );

    try {
      await chatService.createChannel(channel);
    } catch (e) {
      LogService().log('StationServerService: Error creating default chat channel: $e');
    }
  }

  /// Handle /api/chat/rooms endpoint
  Future<void> _handleChatRooms(HttpRequest request) async {
    try {
      final profile = ProfileService().getProfile();
      final initialized = await _initializeChatServiceIfNeeded(createIfMissing: true);
      final chatService = ChatService();

      if (!initialized || chatService.collectionPath == null) {
        final response = {
          'callsign': profile.callsign,
          'station': profile.callsign,
          'rooms': <Map<String, dynamic>>[],
          'total': 0,
          'authenticated': false,
          'message': 'Chat service not available',
        };
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(response));
        return;
      }

      await _ensureDefaultChatChannel(chatService);

      final authNpub = _verifyNostrAuth(request);
      final rooms = <Map<String, dynamic>>[];

      for (final channel in chatService.channels) {
        final visibility = channel.config?.visibility ?? 'PUBLIC';

        if (visibility == 'RESTRICTED') {
          final config = channel.config;
          if (config == null) {
            continue;
          }
          if (authNpub == null || !config.canAccess(authNpub)) {
            continue;
          }
        }

        final canAccess = await _canAccessChatRoom(channel.id, authNpub);
        if (!canAccess && visibility != 'PUBLIC') {
          continue;
        }

        final roomInfo = <String, dynamic>{
          'id': channel.id,
          'name': channel.name,
          'description': channel.description,
          'type': channel.isMain ? 'main' : (channel.isDirect ? 'direct' : 'group'),
          'visibility': visibility,
          'participants': channel.participants,
          'lastMessage': channel.lastMessageTime?.toIso8601String(),
        };

        if (visibility == 'RESTRICTED' && channel.config != null) {
          final config = channel.config!;
          roomInfo['role'] = config.isOwner(authNpub)
              ? 'owner'
              : config.isAdmin(authNpub)
                  ? 'admin'
                  : config.isModerator(authNpub)
                      ? 'moderator'
                      : 'member';
          roomInfo['memberCount'] = config.members.length +
              config.moderatorNpubs.length +
              config.admins.length + 1;
        }

        rooms.add(roomInfo);
      }

      final response = {
        'callsign': profile.callsign,
        'station': profile.callsign,
        'rooms': rooms,
        'total': rooms.length,
        'authenticated': authNpub != null,
      };

      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(response));
    } catch (e) {
      LogService().log('StationServerService: Error handling chat rooms request: $e');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': e.toString()}));
    }
  }

  /// Handle /api/chat/rooms/{roomId}/messages endpoint
  Future<void> _handleRoomMessages(HttpRequest request) async {
    final segments = request.uri.pathSegments;
    final roomId = segments.length > 3 ? segments[3] : 'general';

    if (request.method == 'GET') {
      try {
        await _initializeChatServiceIfNeeded();
        final chatService = ChatService();
        await _ensureDefaultChatChannel(chatService);

        final channel = chatService.getChannel(roomId);
        final isCallsignLike = RegExp(r'^[A-Z0-9]{3,}$').hasMatch(roomId.toUpperCase());

        if (channel == null && isCallsignLike) {
          final dmService = DirectMessageService();
          await dmService.initialize();

          final queryParams = request.uri.queryParameters;
          final limitParam = queryParams['limit'];
          int limit = 50;
          if (limitParam != null) {
            limit = int.tryParse(limitParam) ?? 50;
            limit = limit.clamp(1, 500);
          }

          final messages = await dmService.loadMessages(roomId.toUpperCase(), limit: limit);
          final messageList = messages.map((msg) {
            return {
              'author': msg.author,
              'timestamp': msg.timestamp,
              'content': msg.content,
              'npub': msg.npub,
              'signature': msg.signature,
              'verified': msg.isVerified,
              'reactions': msg.reactions,
            };
          }).toList();

          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({
            'roomId': roomId.toUpperCase(),
            'messages': messageList,
            'count': messageList.length,
            'hasMore': false,
            'limit': limit,
          }));
          return;
        }

        if (chatService.collectionPath == null) {
          request.response.statusCode = 404;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'error': 'No chat collection loaded'}));
          return;
        }

        if (channel == null) {
          request.response.statusCode = 404;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'error': 'Room not found', 'roomId': roomId}));
          return;
        }

        final authNpub = _verifyNostrAuth(request);
        final canAccess = await _canAccessChatRoom(roomId, authNpub);
        if (!canAccess) {
          request.response.statusCode = 403;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({
            'error': 'Access denied',
            'code': 'ROOM_ACCESS_DENIED',
          }));
          return;
        }

        final queryParams = request.uri.queryParameters;
        final limitParam = queryParams['limit'];
        final beforeParam = queryParams['before'];
        final afterParam = queryParams['after'];

        int limit = 50;
        if (limitParam != null) {
          limit = int.tryParse(limitParam) ?? 50;
          limit = limit.clamp(1, 500);
        }

        DateTime? startDate;
        DateTime? endDate;
        if (afterParam != null) {
          startDate = DateTime.tryParse(afterParam);
        }
        if (beforeParam != null) {
          endDate = DateTime.tryParse(beforeParam);
        }

        final messages = await chatService.loadMessages(
          roomId,
          startDate: startDate,
          endDate: endDate,
          limit: limit + 1,
        );

        final hasMore = messages.length > limit;
        final returnMessages = hasMore ? messages.sublist(0, limit) : messages;
        final messageList = returnMessages.map((msg) {
          return {
            'author': msg.author,
            'timestamp': msg.timestamp,
            'content': msg.content,
            'npub': msg.npub,
            'signature': msg.signature,
            'verified': msg.isVerified,
            'hasFile': msg.hasFile,
            'file': msg.attachedFile,
            'hasLocation': msg.hasLocation,
            'latitude': msg.latitude,
            'longitude': msg.longitude,
            'metadata': msg.metadata,
            'reactions': msg.reactions,
          };
        }).toList();

        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'roomId': roomId,
          'messages': messageList,
          'count': messageList.length,
          'hasMore': hasMore,
          'limit': limit,
        }));
      } catch (e) {
        LogService().log('StationServerService: Error handling chat messages request: $e');
        request.response.statusCode = 500;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': e.toString()}));
      }
      return;
    }

    if (request.method == 'POST') {
      try {
        await _initializeChatServiceIfNeeded(createIfMissing: true);
        final chatService = ChatService();
        await _ensureDefaultChatChannel(chatService);

        final channel = chatService.getChannel(roomId);
        final isCallsignLike = RegExp(r'^[A-Z0-9]{3,}$').hasMatch(roomId.toUpperCase());

        // Handle DM messages - when roomId is a callsign (the sender's callsign)
        if (channel == null && isCallsignLike) {
          await _handleIncomingDMMessage(request, roomId.toUpperCase());
          return;
        }

        if (chatService.collectionPath == null) {
          request.response.statusCode = 404;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'error': 'No chat collection loaded'}));
          return;
        }

        if (channel == null) {
          request.response.statusCode = 404;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'error': 'Room not found', 'roomId': roomId}));
          return;
        }

        if (channel.config?.readonly == true) {
          request.response.statusCode = 403;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'error': 'Room is read-only', 'code': 'ROOM_READ_ONLY'}));
          return;
        }

        final bodyStr = await utf8.decodeStream(request);
        if (bodyStr.isEmpty) {
          request.response.statusCode = 400;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'error': 'Missing request body'}));
          return;
        }

        final body = jsonDecode(bodyStr) as Map<String, dynamic>;

        String author;
        String content;
        int? createdAt;
        String? npub;
        String? signature;
        String? eventId;
        final extraMetadata = <String, String>{};

        final rawMetadata = body['metadata'] ?? body['meta'];
        if (rawMetadata is Map) {
          rawMetadata.forEach((key, value) {
            if (value == null) return;
            extraMetadata[key.toString()] = value.toString();
          });
        }

        if (body.containsKey('event')) {
          final eventData = body['event'] as Map<String, dynamic>;
          final event = NostrEvent.fromJson(eventData);

          if (!event.verify()) {
            request.response.statusCode = 403;
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode({'error': 'Invalid event signature', 'code': 'INVALID_SIGNATURE'}));
            return;
          }

          if (event.kind != NostrEventKind.textNote) {
            request.response.statusCode = 400;
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode({
              'error': 'Invalid event kind',
              'expected': NostrEventKind.textNote,
              'received': event.kind,
            }));
            return;
          }

          final roomTag = event.getTagValue('room');
          if (roomTag != null && roomTag != roomId) {
            request.response.statusCode = 400;
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode({
              'error': 'Room tag mismatch',
              'expected': roomId,
              'received': roomTag,
            }));
            return;
          }

          author = event.getTagValue('callsign') ?? event.callsign;
          final canAccess = await _canAccessChatRoom(roomId, event.npub, callsign: author);
          if (!canAccess) {
            request.response.statusCode = 403;
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode({
              'error': 'Event author not authorized for this room',
              'code': 'AUTHOR_ACCESS_DENIED',
            }));
            return;
          }

          content = event.content;
          createdAt = event.createdAt;
          npub = event.npub;
          signature = event.sig;
          eventId = event.id;
        } else if (body.containsKey('content')) {
          content = body['content'] as String;
          author = body['callsign'] as String? ?? ProfileService().getProfile().callsign;
          npub = body['npub'] as String?;
          signature = body['signature'] as String?;
          eventId = body['event_id'] as String?;
          createdAt = body['created_at'] as int?;
        } else {
          request.response.statusCode = 400;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({
            'error': 'Missing content or event field',
            'hint': 'Provide either \"content\" or \"event\"',
          }));
          return;
        }

        final maxLength = channel.config?.maxSizeText ?? 10000;
        if (content.length > maxLength) {
          request.response.statusCode = 400;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({
            'error': 'Content too long',
            'maxLength': maxLength,
            'received': content.length,
          }));
          return;
        }

        final metadata = <String, String>{};
        if (createdAt != null) metadata['created_at'] = createdAt.toString();
        if (npub != null) metadata['npub'] = npub;
        if (eventId != null) metadata['event_id'] = eventId;
        if (signature != null) metadata['signature'] = signature;
        if (extraMetadata.isNotEmpty) {
          const reserved = {
            'created_at',
            'npub',
            'event_id',
            'signature',
            'verified',
            'status',
          };
          extraMetadata.forEach((key, value) {
            if (reserved.contains(key)) return;
            metadata[key] = value;
          });
        }

        final message = ChatMessage.now(
          author: author,
          content: content,
          metadata: metadata,
        );

        await chatService.saveMessage(roomId, message);

        request.response.statusCode = 201;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'success': true,
          'timestamp': message.timestamp,
          'author': author,
          'eventId': eventId,
        }));
      } catch (e) {
        LogService().log('StationServerService: Error posting chat message: $e');
        request.response.statusCode = 500;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': e.toString()}));
      }
      return;
    }

    request.response.statusCode = 405;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'error': 'Method not allowed'}));
  }

  /// Handle incoming DM message POST
  /// When roomId is a callsign, this is a 1:1 DM from that callsign to us
  /// The sender posts to our /api/chat/{theirCallsign}/messages endpoint
  Future<void> _handleIncomingDMMessage(HttpRequest request, String senderCallsign) async {
    try {
      final bodyStr = await utf8.decodeStream(request);
      if (bodyStr.isEmpty) {
        request.response.statusCode = 400;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Missing request body'}));
        return;
      }

      final body = jsonDecode(bodyStr) as Map<String, dynamic>;

      String author;
      String content;
      int? createdAt;
      String? npub;
      String? signature;
      String? eventId;
      final extraMetadata = <String, String>{};

      // Parse optional metadata
      final rawMetadata = body['metadata'] ?? body['meta'];
      if (rawMetadata is Map) {
        rawMetadata.forEach((key, value) {
          if (value == null) return;
          extraMetadata[key.toString()] = value.toString();
        });
      }

      // Parse event or content
      String? voiceFile;
      String? voiceDuration;
      String? voiceSha1;

      if (body.containsKey('event')) {
        final eventData = body['event'] as Map<String, dynamic>;
        final event = NostrEvent.fromJson(eventData);

        // Verify signature
        if (!event.verify()) {
          request.response.statusCode = 403;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'error': 'Invalid event signature', 'code': 'INVALID_SIGNATURE'}));
          return;
        }

        if (event.kind != NostrEventKind.textNote) {
          request.response.statusCode = 400;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({
            'error': 'Invalid event kind',
            'expected': NostrEventKind.textNote,
            'received': event.kind,
          }));
          return;
        }

        author = event.getTagValue('callsign') ?? event.callsign;
        content = event.content;
        createdAt = event.createdAt;
        npub = event.npub;
        signature = event.sig;
        eventId = event.id;

        // Extract voice message tags if present
        voiceFile = event.getTagValue('voice');
        voiceDuration = event.getTagValue('duration');
        voiceSha1 = event.getTagValue('sha1');

        // For voice messages, the content is a descriptor string - clear it for display
        // The actual voice info comes from the tags
        if (voiceFile != null) {
          content = ''; // Voice messages have empty display content
        }
      } else if (body.containsKey('content')) {
        content = body['content'] as String;
        author = body['callsign'] as String? ?? senderCallsign;
        npub = body['npub'] as String?;
        signature = body['signature'] as String?;
        eventId = body['event_id'] as String?;
        createdAt = body['created_at'] as int?;
      } else {
        request.response.statusCode = 400;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'error': 'Missing content or event field',
          'hint': 'Provide either \"content\" or \"event\"',
        }));
        return;
      }

      // Build message metadata
      final metadata = <String, String>{};
      if (createdAt != null) metadata['created_at'] = createdAt.toString();
      if (npub != null) metadata['npub'] = npub;
      if (eventId != null) metadata['eventId'] = eventId;
      if (signature != null) metadata['signature'] = signature;
      metadata['verified'] = 'true'; // Signature was verified above

      // Add voice message metadata if present
      if (voiceFile != null) metadata['voice'] = voiceFile;
      if (voiceDuration != null) metadata['duration'] = voiceDuration;
      if (voiceSha1 != null) metadata['sha1'] = voiceSha1;

      // Add extra metadata (excluding reserved fields)
      const reserved = {'created_at', 'npub', 'event_id', 'eventId', 'signature', 'verified', 'status'};
      extraMetadata.forEach((key, value) {
        if (!reserved.contains(key)) {
          metadata[key] = value;
        }
      });

      // Create the message with the original timestamp from created_at
      ChatMessage message;
      if (createdAt != null) {
        final dt = DateTime.fromMillisecondsSinceEpoch(createdAt * 1000);
        final timestampStr = ChatMessage.formatTimestamp(dt);
        message = ChatMessage(
          author: author,
          timestamp: timestampStr,
          content: content,
          metadata: metadata,
        );
      } else {
        message = ChatMessage.now(
          author: author,
          content: content,
          metadata: metadata,
        );
      }

      // Save to DM service - this fires DirectMessageReceivedEvent for notifications
      final dmService = DirectMessageService();
      await dmService.initialize();
      await dmService.saveIncomingMessage(senderCallsign, message);

      final msgType = voiceFile != null ? 'voice message' : 'text message';
      LogService().log('StationServerService: Received DM $msgType from $author (via $senderCallsign)');

      request.response.statusCode = 201;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'success': true,
        'timestamp': message.timestamp,
        'author': author,
        'eventId': eventId,
      }));
    } catch (e) {
      LogService().log('StationServerService: Error handling incoming DM: $e');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': e.toString()}));
    }
  }

  /// Handle /api/chat/rooms/{roomId}/messages/{timestamp}/reactions endpoint
  Future<void> _handleRoomMessageReactions(HttpRequest request) async {
    if (request.method != 'POST') {
      request.response.statusCode = 405;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Method not allowed'}));
      return;
    }

    final path = request.uri.path;
    final regex = RegExp(r'^/api/chat/(?:rooms/)?([^/]+)/messages/(.+)/reactions$');
    final match = regex.firstMatch(path);
    if (match == null) {
      request.response.statusCode = 400;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Invalid path format'}));
      return;
    }

    final roomId = Uri.decodeComponent(match.group(1)!);
    final timestamp = Uri.decodeComponent(match.group(2)!);

    final event = _verifyNostrEventWithTags(request, 'react', roomId);
    if (event == null) {
      request.response.statusCode = 403;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'error': 'Invalid or missing NOSTR authentication',
        'code': 'AUTH_REQUIRED',
      }));
      return;
    }

    final timestampTag = event.getTagValue('timestamp');
    if (timestampTag != null && timestampTag != timestamp) {
      request.response.statusCode = 403;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'error': 'Timestamp mismatch between URL and event',
        'code': 'TIMESTAMP_MISMATCH',
      }));
      return;
    }

    final reactionTag = event.getTagValue('reaction');
    if (reactionTag == null || reactionTag.trim().isEmpty) {
      request.response.statusCode = 400;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Missing reaction tag'}));
      return;
    }

    final callsignTag = event.getTagValue('callsign');
    if (callsignTag == null || callsignTag.trim().isEmpty) {
      request.response.statusCode = 400;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Missing callsign tag'}));
      return;
    }

    final reactionKey = ReactionUtils.normalizeReactionKey(reactionTag);
    if (reactionKey.isEmpty) {
      request.response.statusCode = 400;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Invalid reaction key'}));
      return;
    }
    final actorCallsign = callsignTag.trim();

    try {
      await _initializeChatServiceIfNeeded();
      final chatService = ChatService();
      final channel = chatService.getChannel(roomId);
      final isCallsignLike = RegExp(r'^[A-Z0-9]{3,}$').hasMatch(roomId.toUpperCase());

      if (channel == null && isCallsignLike) {
        final dmService = DirectMessageService();
        await dmService.initialize();
        final updated = await dmService.toggleReaction(
          roomId.toUpperCase(),
          timestamp,
          actorCallsign,
          reactionKey,
        );

        if (updated == null) {
          request.response.statusCode = 404;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'error': 'Message not found', 'code': 'NOT_FOUND'}));
          return;
        }

        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'success': true,
          'roomId': roomId.toUpperCase(),
          'timestamp': timestamp,
          'reaction': reactionKey,
          'reactions': updated.reactions,
        }));
        return;
      }

      if (chatService.collectionPath == null) {
        request.response.statusCode = 404;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'No chat collection loaded'}));
        return;
      }

      final canAccess = await _canAccessChatRoom(roomId, event.npub);
      if (!canAccess) {
        request.response.statusCode = 403;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'error': 'Access denied',
          'code': 'ROOM_ACCESS_DENIED',
        }));
        return;
      }

      final updated = await chatService.toggleReaction(
        channelId: roomId,
        timestamp: timestamp,
        actorCallsign: actorCallsign,
        reaction: reactionKey,
      );

      if (updated == null) {
        request.response.statusCode = 404;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Message not found', 'code': 'NOT_FOUND'}));
        return;
      }

      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'success': true,
        'roomId': roomId,
        'timestamp': timestamp,
        'reaction': reactionKey,
        'reactions': updated.reactions,
      }));
    } catch (e) {
      LogService().log('StationServerService: Error handling reaction toggle: $e');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': e.toString()}));
    }
  }

  /// Handle /tiles/{callsign}/{z}/{x}/{y}.png endpoint
  Future<void> _handleTileRequest(HttpRequest request) async {
    if (!_settings.tileServerEnabled) {
      request.response.statusCode = 404;
      request.response.write('Tile server disabled');
      return;
    }

    final path = request.uri.path;
    // Parse: /tiles/{callsign}/{z}/{x}/{y}.png
    final regex = RegExp(r'/tiles/([^/]+)/(\d+)/(\d+)/(\d+)\.png');
    final match = regex.firstMatch(path);

    if (match == null) {
      request.response.statusCode = 400;
      request.response.write('Invalid tile path');
      return;
    }

    final callsign = match.group(1)!;
    final z = int.parse(match.group(2)!);
    final x = int.parse(match.group(3)!);
    final y = int.parse(match.group(4)!);

    final layer = request.uri.queryParameters['layer'] ?? 'standard';
    final isSatellite = layer.toLowerCase() == 'satellite';

    // Validate zoom level
    if (z < 0 || z > 18) {
      request.response.statusCode = 400;
      request.response.write('Invalid zoom level');
      return;
    }

    // Check cache
    final cacheKey = '$layer/$z/$x/$y';
    var tileData = _tileCache.get(cacheKey);

    if (tileData != null) {
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.add(tileData);
      return;
    }

    // Try to load from disk cache
    final diskPath = '$_tilesDirectory/$layer/$z/$x/$y.png';
    final diskFile = File(diskPath);
    if (await diskFile.exists()) {
      tileData = await diskFile.readAsBytes();
      _tileCache.put(cacheKey, tileData);
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.add(tileData);
      return;
    }

    // Fetch from internet if OSM fallback is enabled
    if (_settings.osmFallbackEnabled) {
      tileData = await _fetchTileFromInternet(z, x, y, isSatellite);

      if (tileData != null) {
        // Cache in memory
        if (z <= _settings.maxZoomLevel) {
          _tileCache.put(cacheKey, tileData);
        }

        // Cache to disk
        await _saveTileToDisk(diskPath, tileData);

        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(tileData);
        return;
      }
    }

    request.response.statusCode = 404;
    request.response.write('Tile not found');
  }

  /// Fetch tile from internet (OSM or Esri)
  Future<Uint8List?> _fetchTileFromInternet(int z, int x, int y, bool satellite) async {
    try {
      final url = satellite
          ? 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/$z/$y/$x'
          : 'https://tile.openstreetmap.org/$z/$x/$y.png';

      final response = await http.get(
        Uri.parse(url),
        headers: {
          'User-Agent': 'Geogram-Desktop-Station/$appVersion',
        },
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = Uint8List.fromList(response.bodyBytes);
        if (TileCache.isValidImageData(data)) {
          return data;
        }
      }
    } catch (e) {
      LogService().log('Failed to fetch tile: $e');
    }
    return null;
  }

  /// Save tile to disk cache
  Future<void> _saveTileToDisk(String path, Uint8List data) async {
    try {
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data);
    } catch (e) {
      LogService().log('Failed to save tile to disk: $e');
    }
  }

  /// Check if path is a blog URL (/{callsign}/blog/{filename}.html)
  bool _isBlogPath(String path) {
    // Pattern: /{identifier}/blog/{filename}.html
    final regex = RegExp(r'^/([^/]+)/blog/([^/]+)\.html$');
    final matches = regex.hasMatch(path);
    if (path.contains('/blog/')) {
      LogService().log('_isBlogPath check: path="$path", matches=$matches');
    }
    return matches;
  }

  /// Check if path is a device proxy path (/{callsign}/api/*)
  bool _isDeviceProxyPath(String path) {
    // Pattern: /{callsign}/api/{endpoint}
    // Must have at least 3 segments: /{callsign}/api/{something}
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    return parts.length >= 3 && parts[1] == 'api';
  }

  /// Check if path is a chat file upload path
  /// Pattern: POST /api/chat/rooms/{roomId}/files
  bool _isChatFileUploadPath(String path, String method) {
    if (method != 'POST') return false;
    // Pattern: /api/chat/rooms/{roomId}/files
    final regex = RegExp(r'^/api/chat/rooms/[^/]+/files$');
    return regex.hasMatch(path);
  }

  /// Check if path is a chat file fetch path
  /// Pattern: GET /api/chat/rooms/{roomId}/files/{filename}
  bool _isChatFileFetchPath(String path, String method) {
    if (method != 'GET') return false;
    // Pattern: /api/chat/rooms/{roomId}/files/{filename}
    final regex = RegExp(r'^/api/chat/rooms/[^/]+/files/.+$');
    return regex.hasMatch(path);
  }

  /// Handle chat file upload - store file locally in chat collection
  /// POST /api/chat/rooms/{roomId}/files
  Future<void> _handleChatFileUpload(HttpRequest request) async {
    final requestPath = request.uri.path;
    // Parse: /api/chat/rooms/{roomId}/files
    final regex = RegExp(r'^/api/chat/rooms/([^/]+)/files$');
    final match = regex.firstMatch(requestPath);

    if (match == null) {
      request.response.statusCode = 400;
      request.response.write('Invalid path');
      return;
    }

    final roomId = match.group(1)!;

    // Verify NOSTR authentication
    final authNpub = _verifyNostrAuth(request);
    final canAccess = await _canAccessChatRoom(roomId, authNpub);
    if (!canAccess) {
      request.response.statusCode = 403;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'error': 'Access denied',
        'code': 'ROOM_ACCESS_DENIED',
      }));
      return;
    }

    LogService().log('Chat file upload: room=$roomId');

    try {
      // Read the file content from request body
      var bytes = await request.fold<List<int>>(
        <int>[],
        (previous, element) => previous..addAll(element),
      );

      // Handle base64 encoding if specified
      final transferEncoding = request.headers.value('Content-Transfer-Encoding') ??
          request.headers.value('content-transfer-encoding');
      if (transferEncoding != null && transferEncoding.toLowerCase().contains('base64')) {
        try {
          bytes = base64Decode(utf8.decode(bytes));
        } catch (e) {
          request.response.statusCode = 400;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'error': 'Invalid base64 payload'}));
          return;
        }
      }

      if (bytes.isEmpty) {
        request.response.statusCode = 400;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'success': false,
          'error': 'Empty file',
        }));
        return;
      }

      // Enforce 10 MB file size limit
      final maxSize = 10 * 1024 * 1024; // 10 MB
      if (bytes.length > maxSize) {
        request.response.statusCode = 413;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'success': false,
          'error': 'File too large (max 10 MB)',
          'maxSize': maxSize,
          'actualSize': bytes.length,
        }));
        return;
      }

      // Get original filename from header or generate one
      final originalFilename = request.headers.value('X-Filename') ??
          request.headers.value('x-filename') ??
          'file_${DateTime.now().millisecondsSinceEpoch}';

      // Calculate SHA1 for unique filename
      final sha1Hash = sha1.convert(bytes).toString();
      final extension = originalFilename.contains('.')
          ? originalFilename.substring(originalFilename.lastIndexOf('.'))
          : '';
      final storedFilename = '${sha1Hash}_$originalFilename';

      // Get the chat collection directory
      await _initializeChatServiceIfNeeded();
      final chatService = ChatService();
      final collectionPath = chatService.collectionPath;

      if (collectionPath == null) {
        request.response.statusCode = 500;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'success': false,
          'error': 'Chat collection not initialized',
        }));
        return;
      }

      // Create files directory for the room
      final filesPath = '$collectionPath/$roomId/files';
      final filesDir = Directory(filesPath);
      if (!await filesDir.exists()) {
        await filesDir.create(recursive: true);
      }

      // Save the file
      final filePath = '$filesPath/$storedFilename';
      final file = File(filePath);
      await file.writeAsBytes(bytes, flush: true);

      LogService().log('Chat file saved: $filePath (${bytes.length} bytes)');

      request.response.statusCode = 201;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'success': true,
        'filename': storedFilename,
        'size': bytes.length,
        'sha1': sha1Hash,
      }));
    } catch (e) {
      LogService().log('Error saving chat file: $e');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'success': false,
        'error': e.toString(),
      }));
    }
  }

  /// Handle chat file fetch - serve file from chat collection
  /// GET /api/chat/rooms/{roomId}/files/{filename}
  Future<void> _handleChatFileFetch(HttpRequest request) async {
    final requestPath = request.uri.path;
    // Parse: /api/chat/rooms/{roomId}/files/{filename}
    final regex = RegExp(r'^/api/chat/rooms/([^/]+)/files/(.+)$');
    final match = regex.firstMatch(requestPath);

    if (match == null) {
      request.response.statusCode = 400;
      request.response.write('Invalid path');
      return;
    }

    final roomId = match.group(1)!;
    final filename = Uri.decodeComponent(match.group(2)!);

    LogService().log('Chat file fetch: room=$roomId, file=$filename');

    try {
      // Get the chat collection directory
      await _initializeChatServiceIfNeeded();
      final chatService = ChatService();
      final collectionPath = chatService.collectionPath;

      if (collectionPath == null) {
        request.response.statusCode = 404;
        request.response.write('Chat collection not found');
        return;
      }

      // Construct file path
      final filePath = '$collectionPath/$roomId/files/$filename';
      final file = File(filePath);

      if (!await file.exists()) {
        request.response.statusCode = 404;
        request.response.write('File not found');
        return;
      }

      // Determine content type based on extension
      String contentType = 'application/octet-stream';
      final lowerFilename = filename.toLowerCase();
      if (lowerFilename.endsWith('.jpg') || lowerFilename.endsWith('.jpeg')) {
        contentType = 'image/jpeg';
      } else if (lowerFilename.endsWith('.png')) {
        contentType = 'image/png';
      } else if (lowerFilename.endsWith('.gif')) {
        contentType = 'image/gif';
      } else if (lowerFilename.endsWith('.webp')) {
        contentType = 'image/webp';
      } else if (lowerFilename.endsWith('.pdf')) {
        contentType = 'application/pdf';
      } else if (lowerFilename.endsWith('.mp3')) {
        contentType = 'audio/mpeg';
      } else if (lowerFilename.endsWith('.mp4')) {
        contentType = 'video/mp4';
      } else if (lowerFilename.endsWith('.webm')) {
        contentType = 'video/webm';
      } else if (lowerFilename.endsWith('.txt')) {
        contentType = 'text/plain';
      } else if (lowerFilename.endsWith('.json')) {
        contentType = 'application/json';
      }

      // Stream file to response
      final bytes = await file.readAsBytes();
      request.response.headers.contentType = ContentType.parse(contentType);
      request.response.headers.contentLength = bytes.length;

      // Extract display filename from stored name (remove SHA1 prefix)
      final displayName = _extractDisplayFilename(filename);
      request.response.headers.set(
        'Content-Disposition',
        'inline; filename="$displayName"',
      );

      request.response.add(bytes);
    } catch (e) {
      LogService().log('Error serving chat file: $e');
      request.response.statusCode = 500;
      request.response.write('Internal server error');
    }
  }

  /// Extract display filename from stored filename (removes SHA1 prefix)
  String _extractDisplayFilename(String storedFilename) {
    // Format: {sha1}_{original_filename}
    final underscoreIndex = storedFilename.indexOf('_');
    if (underscoreIndex > 0 && underscoreIndex == 40) {
      // SHA1 is 40 characters
      return storedFilename.substring(41);
    }
    return storedFilename;
  }

  /// Check if path is an alert file upload path
  /// Pattern: POST /{callsign}/api/alerts/{folderName}/files/{filename}
  bool _isAlertFileUploadPath(String path, String method) {
    if (method != 'POST') return false;
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    // Should be: [callsign, api, alerts, folderName, files, filename]
    return parts.length >= 6 &&
        parts[1] == 'api' &&
        parts[2] == 'alerts' &&
        parts[4] == 'files';
  }

  /// Check if path is an alert file fetch path
  /// Pattern: GET /{callsign}/api/alerts/{folderName}/files/{filename}
  bool _isAlertFileFetchPath(String path, String method) {
    if (method != 'GET') return false;
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    // Should be: [callsign, api, alerts, folderName, files, filename]
    return parts.length >= 6 &&
        parts[1] == 'api' &&
        parts[2] == 'alerts' &&
        parts[4] == 'files';
  }

  /// Handle alert file upload - store file locally on station
  Future<void> _handleAlertFileUpload(HttpRequest request) async {
    final requestPath = request.uri.path;
    final parts = requestPath.split('/').where((p) => p.isNotEmpty).toList();

    // Parse: /{callsign}/api/alerts/{folderName}/files/{filename}
    if (parts.length < 6) {
      request.response.statusCode = 400;
      request.response.write('Invalid path');
      return;
    }

    final callsign = parts[0].toUpperCase();
    final folderName = parts[3];
    final filename = parts.sublist(5).join('/'); // Handle nested paths

    LogService().log('Alert file upload: $callsign / $folderName / $filename');

    try {
      // Get the alert storage directory
      final storageConfig = StorageConfig();
      final devicesDir = storageConfig.devicesDir;
      final alertPath = '$devicesDir/$callsign/alerts/$folderName';

      // Create directory if it doesn't exist
      final alertDir = Directory(alertPath);
      if (!await alertDir.exists()) {
        await alertDir.create(recursive: true);
      }

      // Read the file content from request body
      var bytes = await request.fold<List<int>>(
        <int>[],
        (previous, element) => previous..addAll(element),
      );

      final transferEncoding = request.headers.value('Content-Transfer-Encoding') ??
          request.headers.value('content-transfer-encoding');
      if (transferEncoding != null && transferEncoding.toLowerCase().contains('base64')) {
        try {
          bytes = base64Decode(utf8.decode(bytes));
        } catch (e) {
          request.response.statusCode = 400;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'error': 'Invalid base64 payload'}));
          return;
        }
      }

      if (bytes.isEmpty) {
        request.response.statusCode = 400;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'success': false,
          'error': 'Empty file',
        }));
        return;
      }

      // Save the file
      final filePath = '$alertPath/$filename';
      final file = File(filePath);
      await file.writeAsBytes(bytes, flush: true);

      LogService().log('Alert file saved: $filePath (${bytes.length} bytes)');

      request.response.statusCode = 201;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'success': true,
        'path': '/$callsign/alerts/$folderName/$filename',
        'size': bytes.length,
      }));
    } catch (e) {
      LogService().log('Error saving alert file: $e');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'success': false,
        'error': e.toString(),
      }));
    }
  }

  /// Handle alert file fetch - serve file from local storage
  Future<void> _handleAlertFileFetch(HttpRequest request) async {
    final requestPath = request.uri.path;
    final parts = requestPath.split('/').where((p) => p.isNotEmpty).toList();

    // Parse: /{callsign}/api/alerts/{folderName}/files/{filename}
    if (parts.length < 6) {
      request.response.statusCode = 400;
      request.response.write('Invalid path');
      return;
    }

    final callsign = parts[0].toUpperCase();
    final folderName = parts[3];
    final relativePath = parts.sublist(5).join('/');

    if (relativePath.contains('..') || relativePath.contains('\\') || relativePath.startsWith('/')) {
      request.response.statusCode = 400;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'error': 'Invalid path',
      }));
      return;
    }

    LogService().log('Alert file fetch: $callsign / $folderName / $relativePath');

    try {
      // Get the alert storage directory
      final storageConfig = StorageConfig();
      final devicesDir = storageConfig.devicesDir;
      final alertsRoot = '$devicesDir/$callsign/alerts';
      final alertPath = await AlertFolderUtils.findAlertPath(alertsRoot, folderName);
      if (alertPath == null) {
        request.response.statusCode = 404;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'error': 'Alert not found',
          'path': '$alertsRoot/$folderName',
        }));
        return;
      }

      final normalizedAlertPath = path.normalize(alertPath);
      final resolvedPath = path.normalize(path.join(normalizedAlertPath, relativePath));
      if (!resolvedPath.startsWith(normalizedAlertPath)) {
        request.response.statusCode = 400;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Invalid path'}));
        return;
      }

      final file = File(resolvedPath);
      if (!await file.exists()) {
        request.response.statusCode = 404;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'error': 'File not found',
          'path': resolvedPath,
        }));
        return;
      }

      // Determine content type
      final ext = path.extension(relativePath).toLowerCase();
      String contentType = 'application/octet-stream';
      if (ext == '.jpg' || ext == '.jpeg') {
        contentType = 'image/jpeg';
      } else if (ext == '.png') {
        contentType = 'image/png';
      } else if (ext == '.gif') {
        contentType = 'image/gif';
      } else if (ext == '.webp') {
        contentType = 'image/webp';
      } else if (ext == '.txt') {
        contentType = 'text/plain';
      } else if (ext == '.json') {
        contentType = 'application/json';
      }

      final bytes = await file.readAsBytes();
      request.response.headers.set('Content-Type', contentType);
      request.response.headers.set('Content-Length', bytes.length.toString());
      request.response.add(bytes);

      LogService().log('Alert file served: $resolvedPath (${bytes.length} bytes)');
    } catch (e) {
      LogService().log('Error serving alert file: $e');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'error': e.toString(),
      }));
    }
  }

  /// Check if path is a place file upload path
  /// Patterns:
  /// - POST /{callsign}/api/places/files/{path}
  /// - POST /{callsign}/api/places/{placePath}/files/{path}
  bool _isPlaceFileUploadPath(String path, String method) {
    if (method != 'POST') return false;
    return _parsePlaceFileRequest(path) != null;
  }

  /// Check if path is a place file fetch path
  /// Patterns:
  /// - GET /{callsign}/api/places/files/{path}
  /// - GET /{callsign}/api/places/{placePath}/files/{path}
  bool _isPlaceFileFetchPath(String path, String method) {
    if (method != 'GET') return false;
    return _parsePlaceFileRequest(path) != null;
  }

  /// Handle place file upload - store file locally on station
  Future<void> _handlePlaceFileUpload(HttpRequest request) async {
    final pathValue = request.uri.path;
    final parsed = _parsePlaceFileRequest(pathValue);
    if (parsed == null) {
      request.response.statusCode = 400;
      request.response.write('Invalid path');
      return;
    }

    final callsign = parsed.callsign;
    final relativePath = _normalizePlaceRelativePath(parsed.relativePath);

    if (_isInvalidRelativePath(relativePath)) {
      request.response.statusCode = 400;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'success': false,
        'error': 'Invalid path',
      }));
      return;
    }

    LogService().log('Place file upload: $callsign / $relativePath');

    try {
      final storageConfig = StorageConfig();
      final placesRoot = path.join(storageConfig.devicesDir, callsign, 'places');
      final filePath = path.join(placesRoot, relativePath);
      final parentDir = Directory(path.dirname(filePath));
      if (!await parentDir.exists()) {
        await parentDir.create(recursive: true);
      }

      final bytes = await request.fold<List<int>>(
        <int>[],
        (previous, element) => previous..addAll(element),
      );

      if (bytes.isEmpty) {
        request.response.statusCode = 400;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'success': false,
          'error': 'Empty file',
        }));
        return;
      }

      final file = File(filePath);
      await file.writeAsBytes(bytes, flush: true);

      request.response.statusCode = 201;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'success': true,
        'path': '/$callsign/places/$relativePath',
        'size': bytes.length,
      }));
    } catch (e) {
      LogService().log('Error saving place file: $e');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'success': false,
        'error': e.toString(),
      }));
    }
  }

  /// Handle place file fetch - serve file from local storage
  Future<void> _handlePlaceFileFetch(HttpRequest request) async {
    final pathValue = request.uri.path;
    final parsed = _parsePlaceFileRequest(pathValue);
    if (parsed == null) {
      request.response.statusCode = 400;
      request.response.write('Invalid path');
      return;
    }

    final callsign = parsed.callsign;
    final relativePath = parsed.relativePath;

    if (_isInvalidRelativePath(relativePath)) {
      request.response.statusCode = 400;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'error': 'Invalid path',
      }));
      return;
    }

    try {
      final storageConfig = StorageConfig();
      final placesRoot = path.join(storageConfig.devicesDir, callsign, 'places');
      final filePath = path.join(placesRoot, relativePath);
      final file = File(filePath);

      if (!await file.exists()) {
        request.response.statusCode = 404;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'error': 'File not found',
          'path': filePath,
        }));
        return;
      }

      final ext = path.extension(filePath).toLowerCase();
      String contentType = 'application/octet-stream';
      if (ext == '.jpg' || ext == '.jpeg') {
        contentType = 'image/jpeg';
      } else if (ext == '.png') {
        contentType = 'image/png';
      } else if (ext == '.gif') {
        contentType = 'image/gif';
      } else if (ext == '.webp') {
        contentType = 'image/webp';
      } else if (ext == '.txt') {
        contentType = 'text/plain';
      }

      final bytes = await file.readAsBytes();
      request.response.headers.set('Content-Type', contentType);
      request.response.headers.set('Content-Length', bytes.length.toString());
      request.response.add(bytes);
    } catch (e) {
      LogService().log('Error serving place file: $e');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'error': e.toString(),
      }));
    }
  }

  /// Check if path matches /{callsign}/api/alerts/{alertId} pattern for alert details
  bool _isAlertDetailsPath(String path) {
    // Pattern: /{callsign}/api/alerts/{alertId} (but NOT with /files/ at the end)
    final regex = RegExp(r'^/([A-Za-z0-9]+)/api/alerts/([^/]+)$');
    return regex.hasMatch(path);
  }

  /// Check if path matches /api/places/{callsign}/{folderName} for place details
  bool _isPlaceDetailsPath(String path) {
    return _parsePlaceDetailsRequest(path) != null;
  }

  ({String callsign, String relativePath})? _parsePlaceFileRequest(String path) {
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.length < 5) return null;
    if (parts[1] != 'api' || parts[2] != 'places') return null;

    final callsign = parts[0].toUpperCase();

    // Legacy: /{callsign}/api/places/files/{path}
    if (parts[3] == 'files') {
      if (parts.length < 5) return null;
      return (callsign: callsign, relativePath: parts.sublist(4).join('/'));
    }

    // New: /{callsign}/api/places/{placePath}/files/{path}
    final filesIndex = parts.indexOf('files');
    if (filesIndex <= 3 || filesIndex == parts.length - 1) return null;
    final placePath = parts.sublist(3, filesIndex).join('/');
    final filePath = parts.sublist(filesIndex + 1).join('/');
    if (placePath.isEmpty || filePath.isEmpty) return null;

    return (callsign: callsign, relativePath: '$placePath/$filePath');
  }

  String _normalizePlaceRelativePath(String relativePath) {
    final segments = relativePath
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .toList();
    if (segments.length > 1 && segments.first == 'places') {
      return segments.sublist(1).join('/');
    }
    return relativePath;
  }

  ({String callsign, String folderName})? _parsePlaceDetailsRequest(String path) {
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.length < 3) return null;

    // /api/places/{callsign}/{folderName}
    if (parts.length == 4 && parts[0] == 'api' && parts[1] == 'places') {
      return (callsign: parts[2].toUpperCase(), folderName: parts[3]);
    }

    // /{callsign}/api/places/{folderName}
    if (parts.length == 4 && parts[1] == 'api' && parts[2] == 'places') {
      return (callsign: parts[0].toUpperCase(), folderName: parts[3]);
    }

    return null;
  }

  /// Handle GET /api/places - list places using shared handler
  Future<void> _handlePlacesApi(HttpRequest request) async {
    final params = request.uri.queryParameters;

    final sinceTimestamp = params['since'] != null
        ? int.tryParse(params['since']!)
        : null;
    final lat = params['lat'] != null
        ? double.tryParse(params['lat']!)
        : null;
    final lon = params['lon'] != null
        ? double.tryParse(params['lon']!)
        : null;
    final radiusKm = params['radius'] != null
        ? double.tryParse(params['radius']!)
        : null;

    final result = await placeApi.getPlaces(
      sinceTimestamp: sinceTimestamp,
      lat: lat,
      lon: lon,
      radiusKm: radiusKm,
    );

    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(result));
  }

  /// Handle /api/events/* requests (list, details, files, and media)
  Future<void> _handleEventsRequest(HttpRequest request) async {
    try {
      final segments = request.uri.pathSegments;
      if (segments.length < 2 || segments[0] != 'api' || segments[1] != 'events') {
        request.response.statusCode = 404;
        request.response.write('Not Found');
        return;
      }

      final method = request.method;
      if (segments.length == 2 || (segments.length == 3 && segments[2] == 'list')) {
        if (method != 'GET') {
          request.response.statusCode = 405;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'error': 'Method not allowed'}));
          return;
        }
        await _handleEventsApi(request);
        return;
      }

      if (segments.length < 3) {
        request.response.statusCode = 404;
        request.response.write('Not Found');
        return;
      }

      final eventId = segments[2];
      if (_isInvalidEventId(eventId)) {
        request.response.statusCode = 400;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Invalid event ID'}));
        return;
      }

      if (segments.length == 3) {
        if (method != 'GET') {
          request.response.statusCode = 405;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'error': 'Method not allowed'}));
          return;
        }
        await _handleEventDetails(request, eventId);
        return;
      }

      final section = segments[3];
      if (section == 'items') {
        if (method != 'GET') {
          request.response.statusCode = 405;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'error': 'Method not allowed'}));
          return;
        }
        final itemPath = request.uri.queryParameters['path'] ?? '';
        await _handleEventItems(request, eventId, itemPath);
        return;
      }

      if (section == 'files') {
        if (method != 'GET') {
          request.response.statusCode = 405;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'error': 'Method not allowed'}));
          return;
        }
        if (segments.length < 5) {
          request.response.statusCode = 400;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'error': 'Missing file path'}));
          return;
        }
        final filePath = segments.sublist(4).join('/');
        await _handleEventFileServe(request, eventId, filePath);
        return;
      }

      if (section == 'media') {
        await _handleEventMediaRequest(request, eventId, segments);
        return;
      }

      request.response.statusCode = 404;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Events endpoint not found'}));
    } catch (e) {
      LogService().log('Error handling events request: $e');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Internal server error', 'message': e.toString()}));
    }
  }

  /// Handle GET /api/events - list events
  Future<void> _handleEventsApi(HttpRequest request) async {
    try {
      final dataDir = _getStationDataDir();
      if (dataDir == null) {
        request.response.statusCode = 500;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Storage not initialized'}));
        return;
      }

      final yearParam = request.uri.queryParameters['year'];
      final year = yearParam != null ? int.tryParse(yearParam) : null;

      final eventService = EventService();
      final events = await eventService.getAllEventsGlobal(dataDir, year: year);
      final publicEvents = events
          .where((event) => event.visibility.toLowerCase() == 'public')
          .toList();
      final years = await eventService.getAvailableYearsGlobal(dataDir);

      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'events': publicEvents.map((e) => e.toApiJson(summary: true)).toList(),
        'years': years,
        'total': publicEvents.length,
        'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      }));
    } catch (e) {
      LogService().log('Error in events API: $e');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'success': false,
        'error': 'Internal server error',
        'message': e.toString(),
      }));
    }
  }

  /// Handle GET /api/events/{eventId} - event details
  Future<void> _handleEventDetails(HttpRequest request, String eventId) async {
    try {
      final eventDir = await _resolveEventDir(eventId);
      if (eventDir == null) {
        request.response.statusCode = 404;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Event not found', 'eventId': eventId}));
        return;
      }

      final eventService = EventService();
      final collectionPath = path.dirname(path.dirname(path.dirname(eventDir)));
      await eventService.initializeCollection(collectionPath);
      final event = await eventService.loadEvent(eventId);

      if (event == null) {
        request.response.statusCode = 404;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Event not found', 'eventId': eventId}));
        return;
      }

      if (event.visibility.toLowerCase() != 'public') {
        request.response.statusCode = 403;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Event not public'}));
        return;
      }

      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(event.toApiJson(summary: false)));
    } catch (e) {
      LogService().log('Error handling event details: $e');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Internal server error', 'message': e.toString()}));
    }
  }

  /// Handle GET /api/events/{eventId}/items - list event files and folders
  Future<void> _handleEventItems(HttpRequest request, String eventId, String itemPath) async {
    try {
      final eventDirPath = await _resolveEventDir(eventId);
      if (eventDirPath == null) {
        request.response.statusCode = 404;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Event not found', 'eventId': eventId}));
        return;
      }

      if (itemPath.contains('..')) {
        request.response.statusCode = 403;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Invalid path'}));
        return;
      }

      String targetPath = eventDirPath;
      if (itemPath.isNotEmpty) {
        targetPath = '$eventDirPath/$itemPath';
      }

      final targetDir = Directory(targetPath);
      if (!await targetDir.exists()) {
        request.response.statusCode = 404;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Path not found', 'path': itemPath}));
        return;
      }

      final items = <Map<String, dynamic>>[];
      await for (final entity in targetDir.list()) {
        final name = path.basename(entity.path);
        if (name.startsWith('.') || name == 'event.txt') continue;

        if (entity is Directory) {
          final isDayFolder = RegExp(r'^day\\d+$', caseSensitive: false).hasMatch(name);
          final subItems = await entity.list().length;
          items.add({
            'name': name,
            'type': isDayFolder ? 'dayFolder' : 'folder',
            'item_count': subItems,
          });
        } else if (entity is File) {
          final stat = await entity.stat();
          final ext = path.extension(name).toLowerCase();
          String fileType = 'file';
          if (['.jpg', '.jpeg', '.png', '.gif', '.webp'].contains(ext)) {
            fileType = 'image';
          } else if (['.mp4', '.mov', '.avi', '.webm'].contains(ext)) {
            fileType = 'video';
          } else if (['.mp3', '.m4a', '.wav', '.ogg'].contains(ext)) {
            fileType = 'audio';
          } else if (['.pdf'].contains(ext)) {
            fileType = 'document';
          }
          items.add({
            'name': name,
            'type': fileType,
            'size': stat.size,
          });
        }
      }

      items.sort((a, b) {
        final aIsFolder = a['type'] == 'folder' || a['type'] == 'dayFolder';
        final bIsFolder = b['type'] == 'folder' || b['type'] == 'dayFolder';
        if (aIsFolder && !bIsFolder) return -1;
        if (!aIsFolder && bIsFolder) return 1;
        return (a['name'] as String).compareTo(b['name'] as String);
      });

      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'event_id': eventId,
        'path': itemPath,
        'items': items,
      }));
    } catch (e) {
      LogService().log('Error handling event items: $e');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Internal server error', 'message': e.toString()}));
    }
  }

  /// Handle GET /api/events/{eventId}/files/{path} - serve event file content
  Future<void> _handleEventFileServe(HttpRequest request, String eventId, String filePath) async {
    try {
      final eventDirPath = await _resolveEventDir(eventId);
      if (eventDirPath == null) {
        request.response.statusCode = 404;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Event not found', 'eventId': eventId}));
        return;
      }

      if (_isInvalidEventFilePath(filePath)) {
        request.response.statusCode = 403;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Invalid path'}));
        return;
      }

      final fullPath = path.join(eventDirPath, filePath);
      final file = File(fullPath);
      if (!await file.exists()) {
        request.response.statusCode = 404;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'File not found', 'path': filePath}));
        return;
      }

      final ext = path.extension(filePath).toLowerCase();
      String contentType = 'application/octet-stream';
      final mimeTypes = {
        '.jpg': 'image/jpeg',
        '.jpeg': 'image/jpeg',
        '.png': 'image/png',
        '.gif': 'image/gif',
        '.webp': 'image/webp',
        '.mp4': 'video/mp4',
        '.mov': 'video/quicktime',
        '.avi': 'video/x-msvideo',
        '.webm': 'video/webm',
        '.mp3': 'audio/mpeg',
        '.m4a': 'audio/mp4',
        '.wav': 'audio/wav',
        '.ogg': 'audio/ogg',
        '.pdf': 'application/pdf',
        '.txt': 'text/plain',
        '.json': 'application/json',
        '.html': 'text/html',
        '.css': 'text/css',
        '.js': 'application/javascript',
      };
      if (mimeTypes.containsKey(ext)) {
        contentType = mimeTypes[ext]!;
      }

      final bytes = await file.readAsBytes();
      request.response.headers.set('Content-Type', contentType);
      request.response.headers.set('Content-Length', bytes.length.toString());
      request.response.headers.set('Cache-Control', 'public, max-age=86400');
      request.response.add(bytes);
    } catch (e) {
      LogService().log('Error serving event file: $e');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Internal server error', 'message': e.toString()}));
    }
  }

  Future<void> _handleEventMediaRequest(
    HttpRequest request,
    String eventId,
    List<String> segments,
  ) async {
    final method = request.method;
    if (segments.length == 4) {
      if (method != 'GET') {
        request.response.statusCode = 405;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Method not allowed'}));
        return;
      }
      await _handleEventMediaList(request, eventId);
      return;
    }

    if (segments.length < 6) {
      request.response.statusCode = 404;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Event media endpoint not found'}));
      return;
    }

    final callsign = segments[4];
    if (segments.length >= 7 && segments[5] == 'files') {
      final filename = segments.sublist(6).join('/');
      if (method == 'POST') {
        await _handleEventMediaFileUpload(request, eventId, callsign, filename);
      } else if (method == 'GET') {
        await _handleEventMediaFileServe(request, eventId, callsign, filename);
      } else {
        request.response.statusCode = 405;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Method not allowed'}));
      }
      return;
    }

    if (segments.length == 6) {
      final action = segments[5];
      if (method != 'POST') {
        request.response.statusCode = 405;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Method not allowed'}));
        return;
      }
      await _handleEventMediaAction(request, eventId, callsign, action);
      return;
    }

    request.response.statusCode = 404;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'error': 'Event media endpoint not found'}));
  }

  Future<void> _handleEventMediaList(HttpRequest request, String eventId) async {
    try {
      final eventDir = await _resolveEventDir(eventId);
      if (eventDir == null) {
        request.response.statusCode = 404;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Event not found', 'eventId': eventId}));
        return;
      }

      final event = await _loadEventFromDir(eventId, eventDir);
      if (event == null) {
        request.response.statusCode = 404;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Event not found', 'eventId': eventId}));
        return;
      }

      if (event.visibility.toLowerCase() != 'public') {
        request.response.statusCode = 403;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Event not public'}));
        return;
      }

      final includePending = request.uri.queryParameters['include_pending'] == 'true';
      final includeBanned = request.uri.queryParameters['include_banned'] == 'true';

      final mediaRoot = Directory(path.join(eventDir, 'media'));
      final approvedFile = path.join(mediaRoot.path, 'approved.txt');
      final bannedFile = path.join(mediaRoot.path, 'banned.txt');
      final approved = await _readCallsignList(approvedFile);
      final banned = await _readCallsignList(bannedFile);

      final contributors = <Map<String, dynamic>>[];
      if (await mediaRoot.exists()) {
        await for (final entity in mediaRoot.list()) {
          if (entity is! Directory) continue;
          final callsign = path.basename(entity.path);
          if (callsign.isEmpty) continue;

          final files = <Map<String, dynamic>>[];
          await for (final entry in entity.list()) {
            if (entry is! File) continue;
            final name = path.basename(entry.path);
            if (name.startsWith('.')) continue;
            final stat = await entry.stat();
            final ext = path.extension(name).toLowerCase();
            String fileType = 'file';
            if (['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp'].contains(ext)) {
              fileType = 'image';
            } else if (['.mp4', '.mov', '.avi', '.webm'].contains(ext)) {
              fileType = 'video';
            } else if (['.mp3', '.m4a', '.wav', '.ogg'].contains(ext)) {
              fileType = 'audio';
            } else if (['.pdf'].contains(ext)) {
              fileType = 'document';
            }
            files.add({
              'name': name,
              'type': fileType,
              'size': stat.size,
              'path': '/api/events/$eventId/media/$callsign/files/$name',
            });
          }

          if (files.isEmpty) continue;
          files.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));

          final isApproved = approved.contains(callsign);
          final isBanned = banned.contains(callsign);

          if (!includePending) {
            if (!isApproved || isBanned) continue;
          } else if (!includeBanned && isBanned) {
            continue;
          }

          contributors.add({
            'callsign': callsign,
            'is_approved': isApproved,
            'is_banned': isBanned,
            'files': files,
          });
        }
      }

      contributors.sort((a, b) => (a['callsign'] as String).compareTo(b['callsign'] as String));

      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'success': true,
        'event_id': eventId,
        'contributors': contributors,
        'approved': approved.toList()..sort(),
        'banned': banned.toList()..sort(),
      }));
    } catch (e) {
      LogService().log('Error listing event media: $e');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Internal server error', 'message': e.toString()}));
    }
  }

  Future<void> _handleEventMediaFileUpload(
    HttpRequest request,
    String eventId,
    String callsign,
    String filename,
  ) async {
    try {
      final eventDir = await _resolveEventDir(eventId);
      if (eventDir == null) {
        request.response.statusCode = 404;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Event not found', 'eventId': eventId}));
        return;
      }

      final event = await _loadEventFromDir(eventId, eventDir);
      if (event == null) {
        request.response.statusCode = 404;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Event not found', 'eventId': eventId}));
        return;
      }

      if (event.visibility.toLowerCase() != 'public') {
        request.response.statusCode = 403;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Event not public'}));
        return;
      }

      final sanitizedCallsign = _sanitizeMediaCallsign(callsign);
      if (sanitizedCallsign.isEmpty) {
        request.response.statusCode = 400;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Invalid callsign'}));
        return;
      }

      if (_isInvalidMediaFilename(filename)) {
        request.response.statusCode = 400;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Invalid filename'}));
        return;
      }

      final bytes = await request.fold<List<int>>(
        <int>[],
        (previous, element) => previous..addAll(element),
      );

      if (bytes.isEmpty) {
        request.response.statusCode = 400;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Empty file'}));
        return;
      }

      const maxSizeBytes = 25 * 1024 * 1024;
      if (bytes.length > maxSizeBytes) {
        request.response.statusCode = 413;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'File too large', 'max_size_mb': 25}));
        return;
      }

      final mediaRoot = Directory(path.join(eventDir, 'media'));
      final bannedFile = path.join(mediaRoot.path, 'banned.txt');
      final banned = await _readCallsignList(bannedFile);
      if (banned.contains(sanitizedCallsign)) {
        request.response.statusCode = 403;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Contributor banned'}));
        return;
      }

      final contributorDir = Directory(path.join(mediaRoot.path, sanitizedCallsign));
      await contributorDir.create(recursive: true);

      final nextIndex = await _nextMediaIndex(contributorDir);
      final ext = _normalizeMediaExtension(filename);
      final targetName = 'media$nextIndex.$ext';
      final filePath = path.join(contributorDir.path, targetName);
      final file = File(filePath);
      await file.writeAsBytes(bytes, flush: true);

      request.response.statusCode = 201;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'success': true,
        'callsign': sanitizedCallsign,
        'filename': targetName,
        'size': bytes.length,
        'path': '/api/events/$eventId/media/$sanitizedCallsign/files/$targetName',
      }));
    } catch (e) {
      LogService().log('Error uploading event media: $e');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Internal server error', 'message': e.toString()}));
    }
  }

  Future<void> _handleEventMediaFileServe(
    HttpRequest request,
    String eventId,
    String callsign,
    String filename,
  ) async {
    try {
      final eventDir = await _resolveEventDir(eventId);
      if (eventDir == null) {
        request.response.statusCode = 404;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Event not found', 'eventId': eventId}));
        return;
      }

      final sanitizedCallsign = _sanitizeMediaCallsign(callsign);
      if (sanitizedCallsign.isEmpty || _isInvalidMediaFilename(filename)) {
        request.response.statusCode = 400;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Invalid path'}));
        return;
      }

      final filePath = path.join(eventDir, 'media', sanitizedCallsign, filename);
      final file = File(filePath);
      if (!await file.exists()) {
        request.response.statusCode = 404;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'File not found', 'filename': filename}));
        return;
      }

      final ext = path.extension(filename).toLowerCase();
      String contentType = 'application/octet-stream';
      if (ext == '.jpg' || ext == '.jpeg') {
        contentType = 'image/jpeg';
      } else if (ext == '.png') {
        contentType = 'image/png';
      } else if (ext == '.gif') {
        contentType = 'image/gif';
      } else if (ext == '.webp') {
        contentType = 'image/webp';
      } else if (ext == '.bmp') {
        contentType = 'image/bmp';
      } else if (ext == '.mp4') {
        contentType = 'video/mp4';
      } else if (ext == '.mov') {
        contentType = 'video/quicktime';
      } else if (ext == '.avi') {
        contentType = 'video/x-msvideo';
      } else if (ext == '.webm') {
        contentType = 'video/webm';
      } else if (ext == '.mp3') {
        contentType = 'audio/mpeg';
      } else if (ext == '.m4a') {
        contentType = 'audio/mp4';
      } else if (ext == '.wav') {
        contentType = 'audio/wav';
      } else if (ext == '.ogg') {
        contentType = 'audio/ogg';
      }

      final bytes = await file.readAsBytes();
      request.response.headers.set('Content-Type', contentType);
      request.response.headers.set('Content-Length', bytes.length.toString());
      request.response.headers.set('Cache-Control', 'public, max-age=86400');
      request.response.add(bytes);
    } catch (e) {
      LogService().log('Error serving event media: $e');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Internal server error', 'message': e.toString()}));
    }
  }

  Future<void> _handleEventMediaAction(
    HttpRequest request,
    String eventId,
    String callsign,
    String action,
  ) async {
    try {
      final eventDir = await _resolveEventDir(eventId);
      if (eventDir == null) {
        request.response.statusCode = 404;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Event not found', 'eventId': eventId}));
        return;
      }

      final event = await _loadEventFromDir(eventId, eventDir);
      if (event == null) {
        request.response.statusCode = 404;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Event not found', 'eventId': eventId}));
        return;
      }

      if (event.visibility.toLowerCase() != 'public') {
        request.response.statusCode = 403;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Event not public'}));
        return;
      }

      final sanitizedCallsign = _sanitizeMediaCallsign(callsign);
      if (sanitizedCallsign.isEmpty) {
        request.response.statusCode = 400;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Invalid callsign'}));
        return;
      }

      final mediaRoot = Directory(path.join(eventDir, 'media'));
      final approvedFile = path.join(mediaRoot.path, 'approved.txt');
      final bannedFile = path.join(mediaRoot.path, 'banned.txt');

      final approved = await _readCallsignList(approvedFile);
      final banned = await _readCallsignList(bannedFile);

      switch (action) {
        case 'approve':
          approved.add(sanitizedCallsign);
          banned.remove(sanitizedCallsign);
          await _writeCallsignList(approvedFile, approved);
          await _writeCallsignList(bannedFile, banned);
          break;
        case 'suspend':
          approved.remove(sanitizedCallsign);
          await _writeCallsignList(approvedFile, approved);
          break;
        case 'ban':
          approved.remove(sanitizedCallsign);
          banned.add(sanitizedCallsign);
          await _writeCallsignList(approvedFile, approved);
          await _writeCallsignList(bannedFile, banned);
          final contributorDir = Directory(path.join(mediaRoot.path, sanitizedCallsign));
          if (await contributorDir.exists()) {
            await contributorDir.delete(recursive: true);
          }
          break;
        default:
          request.response.statusCode = 400;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'error': 'Invalid action'}));
          return;
      }

      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'success': true,
        'action': action,
        'callsign': sanitizedCallsign,
      }));
    } catch (e) {
      LogService().log('Error updating event media status: $e');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Internal server error', 'message': e.toString()}));
    }
  }

  String? _getStationDataDir() {
    try {
      return StorageConfig().baseDir;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _resolveEventDir(String eventId) async {
    final dataDir = _getStationDataDir();
    if (dataDir == null) return null;
    final eventService = EventService();
    return eventService.getEventPath(eventId, dataDir);
  }

  Future<Event?> _loadEventFromDir(String eventId, String eventDir) async {
    try {
      final eventFile = File(path.join(eventDir, 'event.txt'));
      if (!await eventFile.exists()) return null;
      final content = await eventFile.readAsString();
      return Event.fromText(content, eventId);
    } catch (_) {
      return null;
    }
  }

  bool _isInvalidEventId(String eventId) {
    return eventId.contains('..') || eventId.contains('/') || eventId.contains('\\');
  }

  bool _isInvalidEventFilePath(String filePath) {
    if (filePath.isEmpty) return true;
    if (filePath.contains('..')) return true;
    if (filePath.contains('\\')) return true;
    return filePath.startsWith('/');
  }

  bool _isInvalidMediaFilename(String filename) {
    if (filename.isEmpty) return true;
    if (filename.contains('..')) return true;
    if (filename.contains('/') || filename.contains('\\')) return true;
    return false;
  }

  String _sanitizeMediaCallsign(String callsign) {
    return callsign
        .trim()
        .toUpperCase()
        .replaceAll(RegExp(r'[^A-Z0-9_-]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
  }

  String _normalizeMediaExtension(String filename) {
    var ext = path.extension(filename).toLowerCase();
    if (ext.startsWith('.')) ext = ext.substring(1);
    if (ext.isEmpty) ext = 'bin';
    if (ext.length > 8) {
      ext = ext.substring(0, 8);
    }
    return ext;
  }

  Future<int> _nextMediaIndex(Directory contributorDir) async {
    int maxIndex = 0;
    if (await contributorDir.exists()) {
      await for (final entry in contributorDir.list()) {
        if (entry is! File) continue;
        final name = path.basename(entry.path);
        final match = RegExp(r'^media(\\d+)\\.', caseSensitive: false).firstMatch(name);
        if (match == null) continue;
        final parsed = int.tryParse(match.group(1) ?? '');
        if (parsed != null && parsed > maxIndex) {
          maxIndex = parsed;
        }
      }
    }
    return maxIndex + 1;
  }

  Future<Set<String>> _readCallsignList(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) return <String>{};
    final content = await file.readAsString();
    return content
        .split('\\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toSet();
  }

  Future<void> _writeCallsignList(String filePath, Set<String> values) async {
    final file = File(filePath);
    await file.parent.create(recursive: true);
    final sorted = values.toList()..sort();
    await file.writeAsString(sorted.join('\\n'), flush: true);
  }

  /// Handle GET /api/places/{callsign}/{folderName} - place details
  Future<void> _handlePlaceDetails(HttpRequest request) async {
    final pathValue = request.uri.path;
    final parsed = _parsePlaceDetailsRequest(pathValue);
    if (parsed == null) {
      request.response.statusCode = 400;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Invalid path format'}));
      return;
    }

    final callsign = parsed.callsign;
    final folderName = parsed.folderName;

    final result = await placeApi.getPlaceDetails(callsign, folderName);
    final httpStatus = result.remove('http_status') as int?;

    if (httpStatus != null) {
      request.response.statusCode = httpStatus;
    } else if (result.containsKey('error')) {
      request.response.statusCode = 404;
    } else {
      request.response.statusCode = 200;
    }

    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(result));
  }

  bool _isInvalidRelativePath(String relativePath) {
    if (relativePath.isEmpty) return true;
    if (relativePath.contains('\\')) return true;
    final normalized = path.normalize(relativePath);
    if (path.isAbsolute(normalized)) return true;
    final segments = normalized.split(path.separator);
    return segments.any((segment) => segment == '..');
  }

  /// Handle GET /api/alerts - list alerts using shared handler
  Future<void> _handleAlertsApi(HttpRequest request) async {
    try {
      final params = request.uri.queryParameters;

      final result = await alertApi.getAlerts(
        sinceTimestamp: params['since'] != null ? int.tryParse(params['since']!) : null,
        lat: params['lat'] != null ? double.tryParse(params['lat']!) : null,
        lon: params['lon'] != null ? double.tryParse(params['lon']!) : null,
        radiusKm: params['radius'] != null ? double.tryParse(params['radius']!) : null,
        statusFilter: params['status'],
      );

      request.response.headers.contentType = ContentType.json;
      if (result['success'] == false) {
        request.response.statusCode = 500;
      }
      request.response.write(jsonEncode(result));
    } catch (e) {
      LogService().log('Error in alerts API: $e');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'success': false,
        'error': 'Internal server error',
        'message': e.toString(),
      }));
    }
  }

  /// Handle POST /api/alerts/{alertId}/{action} - legacy alert feedback (deprecated)
  Future<void> _handleAlertFeedback(HttpRequest request) async {
    try {
      final path = request.uri.path;

      // Parse: /api/alerts/{alertId}/{action}
      final pathParts = path.substring('/api/alerts/'.length).split('/');
      if (pathParts.length < 2) {
        request.response.statusCode = 400;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Invalid path format'}));
        return;
      }

      final action = pathParts[1].toLowerCase();
      request.response.statusCode = 410;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'error': 'Legacy alert feedback endpoint is deprecated',
        'message': 'Use /api/feedback/alert/{alertId}/{action}',
        'action': action,
      }));
    } catch (e) {
      LogService().log('Error in alert feedback: $e');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'error': 'Internal server error',
        'message': e.toString(),
      }));
    }
  }

  /// Handle /api/feedback/{contentType}/{contentId}/... using shared handler
  Future<void> _handleFeedbackApi(HttpRequest request) async {
    try {
      final segments = request.uri.pathSegments;
      if (segments.length < 4) {
        request.response.statusCode = 400;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Invalid feedback path'}));
        return;
      }

      final contentType = segments[2];
      final contentId = segments[3];
      final callsign = request.uri.queryParameters['callsign'];

      Map<String, dynamic> result;

      if (request.method == 'GET') {
        if (segments.length == 4) {
          final params = request.uri.queryParameters;
          final includeComments = params['include_comments'] == 'true';
          final commentLimit = int.tryParse(params['comment_limit'] ?? '') ?? 20;
          final commentOffset = int.tryParse(params['comment_offset'] ?? '') ?? 0;
          result = await feedbackApi.getFeedback(
            contentType: contentType,
            contentId: contentId,
            npub: params['npub'],
            callsign: callsign,
            includeComments: includeComments,
            commentLimit: commentLimit,
            commentOffset: commentOffset,
          );
        } else if (segments.length == 5 && segments[4] == 'stats') {
          result = await feedbackApi.getStats(
            contentType: contentType,
            contentId: contentId,
            callsign: callsign,
          );
        } else {
          request.response.statusCode = 400;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'error': 'Invalid feedback path'}));
          return;
        }
      } else if (request.method == 'POST') {
        if (segments.length < 5) {
          request.response.statusCode = 400;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'error': 'Missing feedback action'}));
          return;
        }

        final action = segments[4];
        final body = await utf8.decodeStream(request);
        Map<String, dynamic> jsonBody = <String, dynamic>{};
        if (body.isNotEmpty) {
          try {
            jsonBody = jsonDecode(body) as Map<String, dynamic>;
          } catch (_) {
            request.response.statusCode = 400;
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode({'error': 'Invalid JSON body'}));
            return;
          }
        }

        switch (action) {
          case 'like':
            result = await feedbackApi.toggleFeedback(
              contentType: contentType,
              contentId: contentId,
              feedbackType: FeedbackFolderUtils.feedbackTypeLikes,
              actionName: 'like',
              eventJson: jsonBody,
              callsign: callsign,
            );
            break;
          case 'point':
            result = await feedbackApi.toggleFeedback(
              contentType: contentType,
              contentId: contentId,
              feedbackType: FeedbackFolderUtils.feedbackTypePoints,
              actionName: 'point',
              eventJson: jsonBody,
              callsign: callsign,
            );
            break;
          case 'dislike':
            result = await feedbackApi.toggleFeedback(
              contentType: contentType,
              contentId: contentId,
              feedbackType: FeedbackFolderUtils.feedbackTypeDislikes,
              actionName: 'dislike',
              eventJson: jsonBody,
              callsign: callsign,
            );
            break;
          case 'subscribe':
            result = await feedbackApi.toggleFeedback(
              contentType: contentType,
              contentId: contentId,
              feedbackType: FeedbackFolderUtils.feedbackTypeSubscribe,
              actionName: 'subscribe',
              eventJson: jsonBody,
              callsign: callsign,
            );
            break;
          case 'verify':
            result = await feedbackApi.verifyContent(
              contentType: contentType,
              contentId: contentId,
              eventJson: jsonBody,
              callsign: callsign,
            );
            break;
          case 'view':
            result = await feedbackApi.recordView(
              contentType: contentType,
              contentId: contentId,
              eventJson: jsonBody,
              callsign: callsign,
            );
            break;
          case 'comment':
            final author = jsonBody['author'] as String?;
            final content = jsonBody['content'] as String?;
            if (author == null || author.isEmpty || content == null || content.isEmpty) {
              request.response.statusCode = 400;
              request.response.headers.contentType = ContentType.json;
              request.response.write(jsonEncode({'error': 'Missing author or content'}));
              return;
            }
            result = await feedbackApi.addComment(
              contentType: contentType,
              contentId: contentId,
              author: author,
              content: content,
              npub: jsonBody['npub'] as String?,
              signature: jsonBody['signature'] as String?,
              callsign: callsign,
            );
            break;
          case 'react':
            if (segments.length < 6) {
              request.response.statusCode = 400;
              request.response.headers.contentType = ContentType.json;
              request.response.write(jsonEncode({'error': 'Missing reaction emoji'}));
              return;
            }
            final emoji = segments[5];
            if (!FeedbackFolderUtils.supportedReactions.contains(emoji)) {
              request.response.statusCode = 400;
              request.response.headers.contentType = ContentType.json;
              request.response.write(jsonEncode({
                'error': 'Unsupported reaction',
                'supported_reactions': FeedbackFolderUtils.supportedReactions,
              }));
              return;
            }
            result = await feedbackApi.toggleFeedback(
              contentType: contentType,
              contentId: contentId,
              feedbackType: emoji,
              actionName: 'react',
              eventJson: jsonBody,
              callsign: callsign,
            );
            if (result['success'] == true) {
              result['reaction'] = emoji;
            }
            break;
          default:
            request.response.statusCode = 400;
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode({'error': 'Unknown feedback action'}));
            return;
        }
      } else {
        request.response.statusCode = 405;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Method not allowed'}));
        return;
      }

      final httpStatus = result.remove('http_status') as int?;
      if (httpStatus != null) {
        request.response.statusCode = httpStatus;
      } else if (result.containsKey('error')) {
        request.response.statusCode = 404;
      } else {
        request.response.statusCode = 200;
      }

      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(result));
    } catch (e) {
      LogService().log('Error in feedback API: $e');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'error': 'Internal server error',
        'message': e.toString(),
      }));
    }
  }

  /// Handle GET /{callsign}/api/alerts/{alertId} - alert details using shared handler
  Future<void> _handleAlertDetails(HttpRequest request) async {
    try {
      final path = request.uri.path;

      // Parse path: /{callsign}/api/alerts/{alertId}
      final regex = RegExp(r'^/([A-Za-z0-9]+)/api/alerts/([^/]+)$');
      final match = regex.firstMatch(path);

      if (match == null) {
        request.response.statusCode = 400;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Invalid path format'}));
        return;
      }

      final callsign = match.group(1)!.toUpperCase();
      final alertId = match.group(2)!;

      final result = await alertApi.getAlertDetails(callsign, alertId);

      // Handle HTTP status code (stored in 'http_status' to avoid conflict with alert 'status' field)
      final httpStatus = result.remove('http_status') as int?;
      if (httpStatus != null) {
        request.response.statusCode = httpStatus;
      } else if (result.containsKey('error')) {
        request.response.statusCode = 404;
      } else {
        request.response.statusCode = 200;
      }

      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(result));
    } catch (e) {
      LogService().log('Error in alert details: $e');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'error': 'Internal server error',
        'message': e.toString(),
      }));
    }
  }

  /// Handle device proxy request - forwards API requests to connected devices via WebSocket
  Future<void> _handleDeviceProxyRequest(HttpRequest request) async {
    final path = request.uri.path;
    final method = request.method;

    // Parse path: /{callsign}/api/{endpoint}
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.length < 3 || parts[1] != 'api') {
      request.response.statusCode = 400;
      request.response.write('Invalid device proxy path');
      return;
    }

    final targetCallsign = parts[0].toUpperCase();
    final apiPath = '/${parts.sublist(1).join('/')}'; // /api/{endpoint}

    LogService().log('Device proxy request: $method $path -> $targetCallsign $apiPath');

    // Find connected client by callsign
    ConnectedClient? targetClient;
    for (final client in _clients.values) {
      if (client.callsign?.toUpperCase() == targetCallsign) {
        targetClient = client;
        break;
      }
    }

    if (targetClient == null) {
      request.response.statusCode = 404;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'error': 'Device not connected',
        'callsign': targetCallsign,
        'message': 'The device $targetCallsign is not currently connected to this station',
      }));
      return;
    }

    // Read request body if POST/PUT
    String? bodyContent;
    if (method == 'POST' || method == 'PUT') {
      bodyContent = await utf8.decoder.bind(request).join();
    }

    // Generate unique request ID
    final requestId = '${DateTime.now().millisecondsSinceEpoch}-${targetCallsign.hashCode}';

    // Create completer for the response
    final completer = Completer<Map<String, dynamic>>();
    _pendingHttpRequests[requestId] = completer;

    try {
      // Send HTTP_REQUEST to the target client via WebSocket
      final httpRequestMessage = {
        'type': 'HTTP_REQUEST',
        'requestId': requestId,
        'method': method,
        'path': apiPath,
        'headers': jsonEncode({}),
        'body': bodyContent,
      };

      targetClient.socket.add(jsonEncode(httpRequestMessage));
      LogService().log('Sent HTTP_REQUEST to $targetCallsign: $method $apiPath (requestId: $requestId)');

      // Wait for response with timeout
      final response = await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          LogService().log('HTTP proxy timeout for $targetCallsign $apiPath');
          return {
            'statusCode': 504,
            'responseHeaders': '{"Content-Type": "application/json"}',
            'responseBody': jsonEncode({
              'error': 'Gateway Timeout',
              'message': 'Device $targetCallsign did not respond in time',
            }),
            'isBase64': false,
          };
        },
      );

      // Forward the response to the HTTP caller
      final statusCode = response['statusCode'] as int? ?? 500;
      final responseHeadersJson = response['responseHeaders'] as String? ?? '{}';
      final responseBody = response['responseBody'] as String? ?? '';
      final isBase64 = response['isBase64'] as bool? ?? false;

      request.response.statusCode = statusCode;

      // Parse and apply response headers
      try {
        final responseHeaders = jsonDecode(responseHeadersJson) as Map<String, dynamic>;
        for (final entry in responseHeaders.entries) {
          if (entry.key.toLowerCase() == 'content-type') {
            final ct = entry.value.toString();
            if (ct.contains('json')) {
              request.response.headers.contentType = ContentType.json;
            } else if (ct.contains('html')) {
              request.response.headers.contentType = ContentType.html;
            } else if (ct.contains('text')) {
              request.response.headers.contentType = ContentType.text;
            }
          }
        }
      } catch (_) {}

      // Write response body
      if (isBase64) {
        request.response.add(base64Decode(responseBody));
      } else {
        request.response.write(responseBody);
      }

      LogService().log('Device proxy response: $statusCode for $targetCallsign $apiPath');
    } finally {
      _pendingHttpRequests.remove(requestId);
    }
  }

  /// Handle HTTP_RESPONSE from a connected client
  void _handleHttpResponse(Map<String, dynamic> message) {
    final requestId = message['requestId'] as String?;
    if (requestId == null) {
      LogService().log('HTTP_RESPONSE missing requestId');
      return;
    }

    final completer = _pendingHttpRequests[requestId];
    if (completer == null) {
      LogService().log('HTTP_RESPONSE for unknown requestId: $requestId');
      return;
    }

    LogService().log('Received HTTP_RESPONSE for requestId: $requestId');
    completer.complete(message);
  }

  /// Handle blog post request - serves markdown as HTML
  Future<void> _handleBlogRequest(HttpRequest request) async {
    final path = request.uri.path;
    LogService().log('Blog handler: Processing request for path: $path');
    final regex = RegExp(r'^/([^/]+)/blog/([^/]+)\.html$');
    final match = regex.firstMatch(path);

    if (match == null) {
      request.response.statusCode = 400;
      request.response.write('Invalid blog URL');
      return;
    }

    final identifier = match.group(1)!; // nickname or callsign
    final filename = match.group(2)!;   // blog filename without .html

    try {
      // Check if identifier matches a connected client first - if so, proxy immediately
      // This ensures we serve live content from connected devices rather than stale cache
      LogService().log('Blog handler: Looking for connected client matching: $identifier');
      LogService().log('Blog handler: Currently connected clients: ${_clients.length}');
      for (final client in _clients.values) {
        LogService().log('Blog handler: Checking client ${client.callsign}/${client.nickname}');
        if ((client.callsign != null && client.callsign!.toLowerCase() == identifier.toLowerCase()) ||
            (client.nickname != null && client.nickname!.toLowerCase() == identifier.toLowerCase())) {
          LogService().log('Blog handler: Found matching client, proxying to ${client.callsign}');
          final proxyResult = await _proxyBlogRequest(request, identifier, filename);
          LogService().log('Blog handler: Proxy result: $proxyResult');
          if (proxyResult) {
            return; // Proxy handled the response
          }
          // If proxy failed, fall through to local search as fallback
          break;
        }
      }
      LogService().log('Blog handler: No matching connected client found');

      // Find the callsign for this identifier (could be nickname or callsign)
      final callsign = await _findCallsignByIdentifier(identifier);
      if (callsign == null) {
        // No local user found and no connected client - 404
        request.response.statusCode = 404;
        request.response.write('User not found');
        return;
      }

      // Extract year from filename (format: YYYY-MM-DD_title)
      final yearMatch = RegExp(r'^(\d{4})-').firstMatch(filename);
      if (yearMatch == null) {
        request.response.statusCode = 400;
        request.response.write('Invalid blog filename format');
        return;
      }
      final year = yearMatch.group(1)!;

      // Build path to the blog markdown file
      final devicesDir = StorageConfig().devicesDir;
      final blogDir = Directory('$devicesDir/$callsign');

      // Find collection with blog posts
      BlogPost? foundPost;
      String? collectionName;

      if (await blogDir.exists()) {
        await for (final entity in blogDir.list()) {
          if (entity is Directory) {
            final blogPath = '${entity.path}/blog/$year/$filename.md';
            final blogFile = File(blogPath);
            if (await blogFile.exists()) {
              try {
                final content = await blogFile.readAsString();
                foundPost = BlogPost.fromText(content, filename);
                collectionName = entity.path.split('/').last;
                break;
              } catch (e) {
                LogService().log('Error parsing blog file: $e');
              }
            }
          }
        }
      }

      if (foundPost == null) {
        // Blog not found locally - try to proxy to connected client
        final proxyResult = await _proxyBlogRequest(request, identifier, filename);
        if (proxyResult) {
          return; // Proxy handled the response
        }
        request.response.statusCode = 404;
        request.response.write('Blog post not found');
        return;
      }

      // Only serve published posts
      if (foundPost.isDraft) {
        request.response.statusCode = 403;
        request.response.write('This post is not published');
        return;
      }

      // Convert markdown content to HTML
      final htmlContent = md.markdownToHtml(
        foundPost.content,
        extensionSet: md.ExtensionSet.gitHubWeb,
      );

      // Build full HTML page
      final html = _buildBlogHtmlPage(foundPost, htmlContent, identifier);

      request.response.headers.contentType = ContentType.html;
      request.response.write(html);
    } catch (e) {
      LogService().log('Error serving blog post: $e');
      request.response.statusCode = 500;
      request.response.write('Internal server error');
    }
  }

  /// Find callsign by identifier (nickname or callsign)
  Future<String?> _findCallsignByIdentifier(String identifier) async {
    final storageConfig = StorageConfig();
    final devicesDir = storageConfig.devicesDir;
    final dir = Directory(devicesDir);

    if (!await dir.exists()) return null;

    // First check if it's a direct callsign match (case-insensitive)
    await for (final entity in dir.list()) {
      if (entity is Directory) {
        final callsign = entity.path.split('/').last;
        if (callsign.toLowerCase() == identifier.toLowerCase()) {
          return callsign;
        }
      }
    }

    // Search for nickname in config.json profiles
    final configPath = storageConfig.configPath;
    final configFile = File(configPath);
    if (await configFile.exists()) {
      try {
        final content = await configFile.readAsString();
        final config = jsonDecode(content) as Map<String, dynamic>;
        final profiles = config['profiles'] as List<dynamic>?;
        if (profiles != null) {
          for (final profile in profiles) {
            if (profile is Map<String, dynamic>) {
              final nickname = profile['nickname'] as String?;
              final callsign = profile['callsign'] as String?;
              if (nickname != null &&
                  callsign != null &&
                  nickname.toLowerCase() == identifier.toLowerCase()) {
                // Verify the callsign directory exists
                final callsignDir = Directory('$devicesDir/$callsign');
                if (await callsignDir.exists()) {
                  return callsign;
                }
              }
            }
          }
        }
      } catch (e) {
        LogService().log('Error reading config.json: $e');
      }
    }

    return null;
  }

  /// Proxy blog request to a connected client
  /// Returns true if the request was handled (success or error), false if no client found
  Future<bool> _proxyBlogRequest(HttpRequest request, String identifier, String filename) async {
    LogService().log('_proxyBlogRequest: Called with identifier=$identifier, filename=$filename');
    LogService().log('_proxyBlogRequest: Connected clients count: ${_clients.length}');

    // Find connected client by callsign or nickname
    ConnectedClient? targetClient;

    for (final client in _clients.values) {
      LogService().log('_proxyBlogRequest: Checking client callsign=${client.callsign}, nickname=${client.nickname}');
      // Check callsign match (case-insensitive)
      if (client.callsign != null &&
          client.callsign!.toLowerCase() == identifier.toLowerCase()) {
        targetClient = client;
        LogService().log('_proxyBlogRequest: Found match by callsign!');
        break;
      }
      // Check nickname match (case-insensitive)
      if (client.nickname != null &&
          client.nickname!.toLowerCase() == identifier.toLowerCase()) {
        targetClient = client;
        LogService().log('_proxyBlogRequest: Found match by nickname!');
        break;
      }
    }

    if (targetClient == null) {
      LogService().log('Blog proxy: No connected client found for identifier: $identifier');
      return false;
    }

    final targetCallsign = targetClient.callsign ?? identifier;
    LogService().log('Blog proxy: Forwarding request to $targetCallsign for $filename');

    // Generate unique request ID
    final requestId = '${DateTime.now().millisecondsSinceEpoch}-blog-${targetCallsign.hashCode}';

    // Create completer for the response
    final completer = Completer<Map<String, dynamic>>();
    _pendingHttpRequests[requestId] = completer;

    try {
      // Send HTTP_REQUEST to the target client via WebSocket
      // Request the blog as HTML from the client's local API
      // Use the full path format that routes to LogApiService _handleBlogHtmlRequest
      final blogApiPath = '/$targetCallsign/blog/$filename.html';
      final httpRequestMessage = {
        'type': 'HTTP_REQUEST',
        'requestId': requestId,
        'method': 'GET',
        'path': blogApiPath,
        'headers': jsonEncode({
          'X-Device-Callsign': targetCallsign,
        }),
        'body': null,
      };

      targetClient.socket.add(jsonEncode(httpRequestMessage));
      LogService().log('Blog proxy: Sent HTTP_REQUEST to $targetCallsign (requestId: $requestId)');

      // Wait for response with timeout
      final response = await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          LogService().log('Blog proxy: Timeout for $targetCallsign $filename');
          return {
            'statusCode': 504,
            'responseHeaders': '{"Content-Type": "text/plain"}',
            'responseBody': 'Gateway Timeout - Device did not respond',
            'isBase64': false,
          };
        },
      );

      // Forward the response to the HTTP caller
      final statusCode = response['statusCode'] as int? ?? 500;
      final responseBody = response['responseBody'] as String? ?? '';

      request.response.statusCode = statusCode;
      request.response.headers.contentType = ContentType.html;
      request.response.write(responseBody);

      LogService().log('Blog proxy: Response from $targetCallsign: $statusCode');
      return true;
    } catch (e) {
      LogService().log('Blog proxy error: $e');
      request.response.statusCode = 500;
      request.response.write('Proxy error: $e');
      return true;
    } finally {
      _pendingHttpRequests.remove(requestId);
    }
  }

  /// Build HTML page for blog post
  String _buildBlogHtmlPage(BlogPost post, String htmlContent, String author) {
    final tagsHtml = post.tags.isNotEmpty
        ? post.tags.map((t) => '<span class="tag">#$t</span>').join(' ')
        : '';

    final signedBadge = post.isSigned
        ? '<div class="signed"><span class="icon">✓</span> Signed with NOSTR</div>'
        : '';

    return '''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${_escapeHtml(post.title)} - $author</title>
  <style>
    :root {
      --bg: #1a1a2e;
      --surface: #16213e;
      --primary: #e94560;
      --text: #eaeaea;
      --text-muted: #a0a0a0;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      background: var(--bg);
      color: var(--text);
      line-height: 1.6;
      padding: 2rem;
    }
    .container {
      max-width: 800px;
      margin: 0 auto;
      background: var(--surface);
      border-radius: 12px;
      padding: 2rem;
      box-shadow: 0 4px 20px rgba(0,0,0,0.3);
    }
    h1 {
      font-size: 2rem;
      margin-bottom: 1rem;
      color: var(--text);
    }
    .meta {
      color: var(--text-muted);
      font-size: 0.9rem;
      margin-bottom: 1rem;
      display: flex;
      flex-wrap: wrap;
      gap: 1rem;
    }
    .meta span { display: flex; align-items: center; gap: 0.3rem; }
    .description {
      background: rgba(255,255,255,0.05);
      padding: 1rem;
      border-radius: 8px;
      margin-bottom: 1.5rem;
      font-style: italic;
      color: var(--text-muted);
    }
    .tags { margin-bottom: 1.5rem; }
    .tag {
      display: inline-block;
      background: rgba(233, 69, 96, 0.2);
      color: var(--primary);
      padding: 0.2rem 0.6rem;
      border-radius: 4px;
      font-size: 0.85rem;
      margin-right: 0.5rem;
    }
    hr { border: none; border-top: 1px solid rgba(255,255,255,0.1); margin: 1.5rem 0; }
    .content { font-size: 1.1rem; }
    .content p { margin-bottom: 1rem; }
    .content h1, .content h2, .content h3 { margin: 1.5rem 0 1rem; }
    .content a { color: var(--primary); }
    .content code {
      background: rgba(255,255,255,0.1);
      padding: 0.2rem 0.4rem;
      border-radius: 4px;
      font-family: monospace;
    }
    .content pre {
      background: rgba(0,0,0,0.3);
      padding: 1rem;
      border-radius: 8px;
      overflow-x: auto;
      margin: 1rem 0;
    }
    .content pre code { background: none; padding: 0; }
    .content img { max-width: 100%; border-radius: 8px; }
    .content blockquote {
      border-left: 3px solid var(--primary);
      padding-left: 1rem;
      margin: 1rem 0;
      color: var(--text-muted);
    }
    .signed {
      margin-top: 1.5rem;
      color: #4ade80;
      font-size: 0.9rem;
      display: flex;
      align-items: center;
      gap: 0.3rem;
    }
    .footer {
      margin-top: 2rem;
      padding-top: 1rem;
      border-top: 1px solid rgba(255,255,255,0.1);
      color: var(--text-muted);
      font-size: 0.85rem;
      text-align: center;
    }
    .footer a { color: var(--primary); text-decoration: none; }
  </style>
</head>
<body>
  <div class="container">
    <h1>${_escapeHtml(post.title)}</h1>
    <div class="meta">
      <span>👤 ${_escapeHtml(post.author)}</span>
      <span>📅 ${post.displayDate} ${post.displayTime}</span>
    </div>
    ${post.description != null && post.description!.isNotEmpty ? '<div class="description">${_escapeHtml(post.description!)}</div>' : ''}
    ${tagsHtml.isNotEmpty ? '<div class="tags">$tagsHtml</div>' : ''}
    <hr>
    <div class="content">
      $htmlContent
    </div>
    $signedBadge
    <div class="footer">
      Published via <a href="https://geogram.io">Geogram</a>
    </div>
  </div>
</body>
</html>
''';
  }

  /// Escape HTML special characters
  String _escapeHtml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }

  /// Handle DM sync API requests
  /// Routes:
  ///   GET /{callsign}/api/dm/conversations - List DM conversations
  ///   GET /{callsign}/api/dm/sync/{otherCallsign}?since=timestamp - Get messages since timestamp
  ///   POST /{callsign}/api/dm/sync/{otherCallsign} - Receive and merge messages
  Future<void> _handleDMRequest(HttpRequest request) async {
    final path = request.uri.path;
    final method = request.method;

    // Parse path: /{callsign}/api/dm/...
    final pathParts = path.split('/').where((p) => p.isNotEmpty).toList();
    if (pathParts.length < 3 || pathParts[1] != 'api' || pathParts[2] != 'dm') {
      request.response.statusCode = 400;
      request.response.write('Invalid DM API path');
      return;
    }

    final requestedCallsign = pathParts[0].toUpperCase();
    final myCallsign = ProfileService().getProfile().callsign.toUpperCase();

    // Verify the request is for this station's callsign
    if (requestedCallsign != myCallsign) {
      request.response.statusCode = 404;
      request.response.write('Callsign not found on this station');
      return;
    }

    final dmService = DirectMessageService();
    await dmService.initialize();

    try {
      if (pathParts.length == 4 && pathParts[3] == 'conversations') {
        // GET /{callsign}/api/dm/conversations
        if (method == 'GET') {
          final conversations = await dmService.listConversations();
          final response = {
            'conversations': conversations.map((c) => {
              'callsign': c.otherCallsign,
              'lastMessage': c.lastMessageTime?.toIso8601String(),
              'unread': c.unreadCount,
            }).toList(),
          };
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(response));
        } else {
          request.response.statusCode = 405;
          request.response.write('Method not allowed');
        }
      } else if (pathParts.length == 5 && pathParts[3] == 'sync') {
        // GET/POST /{callsign}/api/dm/sync/{otherCallsign}
        final otherCallsign = pathParts[4].toUpperCase();

        if (method == 'GET') {
          // Get messages since timestamp
          final sinceParam = request.uri.queryParameters['since'] ?? '';
          final messages = sinceParam.isNotEmpty
              ? await dmService.loadMessagesSince(otherCallsign, sinceParam)
              : await dmService.loadMessages(otherCallsign, limit: 100);

          final response = {
            'messages': messages.map((m) => m.toJson()).toList(),
            'timestamp': DateTime.now().toIso8601String(),
          };
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(response));
        } else if (method == 'POST') {
          // Receive and merge messages from remote
          final body = await utf8.decoder.bind(request).join();
          final data = jsonDecode(body) as Map<String, dynamic>;
          final incomingMessages = <ChatMessage>[];

          if (data['messages'] is List) {
            for (final msgJson in data['messages']) {
              incomingMessages.add(ChatMessage.fromJson(msgJson));
            }
          }

          // Ensure conversation exists
          await dmService.getOrCreateConversation(otherCallsign);

          // Merge messages (this uses the internal merge which fires events)
          int accepted = 0;
          if (incomingMessages.isNotEmpty) {
            final local = await dmService.loadMessages(otherCallsign, limit: 99999);
            final existing = <String>{};
            for (final msg in local) {
              existing.add('${msg.timestamp}|${msg.author}');
            }

            for (final msg in incomingMessages) {
              final id = '${msg.timestamp}|${msg.author}';
              if (!existing.contains(id)) {
                // Save directly to conversation
                await dmService.sendMessage(otherCallsign, msg.content);
                accepted++;
              }
            }
          }

          final response = {
            'success': true,
            'accepted': accepted,
            'timestamp': DateTime.now().toIso8601String(),
          };
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(response));
        } else {
          request.response.statusCode = 405;
          request.response.write('Method not allowed');
        }
      } else if (pathParts.length == 6 && pathParts[4] == 'files') {
        // /{callsign}/api/dm/{otherCallsign}/files/{filename}
        // GET: Serve voice files and other DM attachments
        // POST: Receive file uploads from remote DMs
        final otherCallsign = pathParts[3].toUpperCase();
        final filename = pathParts[5];

        // Security: prevent path traversal
        if (filename.contains('..') || filename.contains('/') || filename.contains('\\')) {
          request.response.statusCode = 400;
          request.response.write('Invalid filename');
          return;
        }

        if (method == 'GET') {
          // Try voice file first, then general file attachments
          var filePath = await dmService.getVoiceFilePath(otherCallsign, filename);
          filePath ??= await dmService.getFilePath(otherCallsign, filename);

          if (filePath == null) {
            request.response.statusCode = 404;
            request.response.write('File not found');
            return;
          }

          final file = File(filePath);
          if (!await file.exists()) {
            request.response.statusCode = 404;
            request.response.write('File not found');
            return;
          }

          // Determine content type from file extension
          final lowerName = filename.toLowerCase();
          String contentType = 'application/octet-stream';
          if (lowerName.endsWith('.webm')) {
            contentType = 'audio/webm';
          } else if (lowerName.endsWith('.ogg')) {
            contentType = 'audio/ogg';
          } else if (lowerName.endsWith('.mp3')) {
            contentType = 'audio/mpeg';
          } else if (lowerName.endsWith('.wav')) {
            contentType = 'audio/wav';
          } else if (lowerName.endsWith('.jpg') || lowerName.endsWith('.jpeg')) {
            contentType = 'image/jpeg';
          } else if (lowerName.endsWith('.png')) {
            contentType = 'image/png';
          } else if (lowerName.endsWith('.gif')) {
            contentType = 'image/gif';
          } else if (lowerName.endsWith('.webp')) {
            contentType = 'image/webp';
          } else if (lowerName.endsWith('.pdf')) {
            contentType = 'application/pdf';
          }

          request.response.headers.set('Content-Type', contentType);
          request.response.headers.set('Content-Length', await file.length());
          await file.openRead().pipe(request.response);

        } else if (method == 'POST') {
          // Receive file upload from remote DM sender
          // The sender uploads file to our device before sending the message
          try {
            // Read file bytes from request body
            var bytes = await request.fold<List<int>>(
              <int>[],
              (previous, element) => previous..addAll(element),
            );

            // Handle base64 encoding if specified (same as station chat uploads)
            final transferEncoding = request.headers.value('Content-Transfer-Encoding') ??
                request.headers.value('content-transfer-encoding');
            if (transferEncoding != null && transferEncoding.toLowerCase().contains('base64')) {
              try {
                bytes = base64Decode(utf8.decode(bytes));
              } catch (e) {
                request.response.statusCode = 400;
                request.response.headers.contentType = ContentType.json;
                request.response.write(jsonEncode({'error': 'Invalid base64 payload'}));
                return;
              }
            }

            if (bytes.isEmpty) {
              request.response.statusCode = 400;
              request.response.headers.contentType = ContentType.json;
              request.response.write(jsonEncode({'error': 'Empty file'}));
              return;
            }

            // 10 MB limit
            if (bytes.length > 10 * 1024 * 1024) {
              request.response.statusCode = 413;
              request.response.headers.contentType = ContentType.json;
              request.response.write(jsonEncode({'error': 'File too large (max 10 MB)'}));
              return;
            }

            // Ensure DM files directory exists
            final storagePath = StorageConfig().baseDir;
            final filesDir = Directory('$storagePath/chat/$otherCallsign/files');
            if (!await filesDir.exists()) {
              await filesDir.create(recursive: true);
            }

            // Save file
            final filePath = '${filesDir.path}/$filename';
            final file = File(filePath);
            await file.writeAsBytes(bytes);

            LogService().log('DM: Received file from $otherCallsign: $filename (${bytes.length} bytes)');

            request.response.statusCode = 201;
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode({
              'success': true,
              'filename': filename,
              'size': bytes.length,
            }));
          } catch (e) {
            LogService().log('DM: File upload error: $e');
            request.response.statusCode = 500;
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode({'error': e.toString()}));
          }
        } else {
          request.response.statusCode = 405;
          request.response.write('Method not allowed');
        }
      } else {
        request.response.statusCode = 404;
        request.response.write('DM endpoint not found');
      }
    } catch (e) {
      LogService().log('DM API error: $e');
      request.response.statusCode = 500;
      request.response.write('Internal server error: $e');
    }
  }

  /// Get server status
  Map<String, dynamic> getStatus() {
    final profile = ProfileService().getProfile();
    final uptime = _startTime != null
        ? DateTime.now().difference(_startTime!).inSeconds
        : 0;

    return {
      'running': _running,
      'port': _runningPort ?? _settings.port,
      'callsign': profile.callsign,
      'connected_devices': _clients.length,
      'uptime': uptime,
      'cache_size': _tileCache.size,
      'cache_size_mb': (_tileCache.sizeBytes / (1024 * 1024)).toStringAsFixed(2),
    };
  }

  /// Clear tile cache
  void clearCache() {
    _tileCache.clear();
    LogService().log('Tile cache cleared');
  }

  // ========== Update Mirror Methods ==========

  /// Load cached release info from disk
  Future<void> _loadCachedRelease() async {
    if (_updatesDirectory == null) return;

    try {
      final releaseFile = File('$_updatesDirectory/release.json');
      if (await releaseFile.exists()) {
        final content = await releaseFile.readAsString();
        _cachedRelease = jsonDecode(content) as Map<String, dynamic>;
        LogService().log('Loaded cached release: ${_cachedRelease?['version']}');
      }
    } catch (e) {
      LogService().log('Error loading cached release: $e');
    }
  }

  /// Save release info to disk
  Future<void> _saveCachedRelease() async {
    if (_updatesDirectory == null || _cachedRelease == null) return;

    try {
      final releaseFile = File('$_updatesDirectory/release.json');
      await releaseFile.writeAsString(jsonEncode(_cachedRelease));
    } catch (e) {
      LogService().log('Error saving cached release: $e');
    }
  }

  /// Start polling GitHub for updates
  void _startUpdatePolling() {
    if (!_settings.updateMirrorEnabled) {
      LogService().log('Update mirroring disabled');
      return;
    }

    LogService().log('Starting update polling (interval: ${_settings.updateCheckInterval}s)');

    // Poll immediately on start
    _pollAndDownloadUpdates();

    // Then poll periodically
    _updatePollTimer = Timer.periodic(
      Duration(seconds: _settings.updateCheckInterval),
      (_) => _pollAndDownloadUpdates(),
    );
  }

  /// Poll GitHub and download new releases
  Future<void> _pollAndDownloadUpdates() async {
    if (_isDownloadingUpdates) return;

    try {
      _isDownloadingUpdates = true;
      LogService().log('Checking for updates from: ${_settings.updateMirrorUrl}');

      final response = await http.get(
        Uri.parse(_settings.updateMirrorUrl),
        headers: {
          'Accept': 'application/vnd.github.v3+json',
          'User-Agent': 'Geogram-Station-Updater',
        },
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        LogService().log('GitHub API error: ${response.statusCode}');
        return;
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final tagName = json['tag_name'] as String? ?? '';
      final version = tagName.replaceFirst(RegExp(r'^v'), '');

      // Check if we already have this version
      if (_settings.lastMirroredVersion == version) {
        LogService().log('Already have version $version cached');
        return;
      }

      LogService().log('New version available: $version (current: ${_settings.lastMirroredVersion})');

      // Download all platform binaries
      await _downloadAllPlatformBinaries(json);

      // Update cached release info
      _cachedRelease = {
        'status': 'available',
        'version': version,
        'tagName': tagName,
        'name': json['name'] as String?,
        'body': json['body'] as String?,
        'publishedAt': json['published_at'] as String?,
        'htmlUrl': json['html_url'] as String?,
        'assets': _buildAssetUrls(),
        'assetFilenames': _buildAssetFilenames(),
      };
      await _saveCachedRelease();

      // Update settings with new version
      _settings = _settings.copyWith(lastMirroredVersion: version);
      _saveSettings();

      LogService().log('Update mirror complete: version $version');
    } catch (e) {
      LogService().log('Error polling for updates: $e');
    } finally {
      _isDownloadingUpdates = false;
    }
  }

  /// Store downloaded asset filenames for API responses
  Map<String, String> _downloadedAssets = {};
  Map<String, String> _assetFilenames = {};
  String? _currentDownloadVersion;

  /// Download all assets from GitHub release
  Future<void> _downloadAllPlatformBinaries(Map<String, dynamic> releaseJson) async {
    final assets = releaseJson['assets'] as List<dynamic>?;
    if (assets == null) return;

    final tagName = releaseJson['tag_name'] as String? ?? '';
    final version = tagName.replaceFirst(RegExp(r'^v'), '');
    _currentDownloadVersion = version;

    _downloadedAssets.clear();
    _assetFilenames.clear();

    // Download all assets to version-specific folder
    for (final asset in assets) {
      final assetMap = asset as Map<String, dynamic>;
      final filename = assetMap['name'] as String? ?? '';
      final downloadUrl = assetMap['browser_download_url'] as String?;

      if (downloadUrl == null || filename.isEmpty) continue;

      final assetType = UpdateAssetType.fromFilename(filename);
      if (assetType != UpdateAssetType.unknown) {
        final success = await _downloadBinary(version, filename, downloadUrl);
        if (success) {
          _downloadedAssets[assetType.name] = '/updates/$version/$filename';
          _assetFilenames[assetType.name] = filename;
        }
      }
    }
  }

  /// Download a single binary file to version folder
  Future<bool> _downloadBinary(String version, String filename, String url) async {
    if (_updatesDirectory == null) return false;

    try {
      LogService().log('Downloading $filename for v$version...');

      // Create version subdirectory: updates/{version}/
      final versionDir = Directory('$_updatesDirectory/$version');
      if (!await versionDir.exists()) {
        await versionDir.create(recursive: true);
      }

      final targetPath = '${versionDir.path}/$filename';

      // Check if file already exists (for resume/archive)
      final existingFile = File(targetPath);
      if (await existingFile.exists()) {
        final existingSize = await existingFile.length();
        if (existingSize > 1000) {
          LogService().log('File already exists: $filename (${(existingSize / (1024 * 1024)).toStringAsFixed(1)}MB)');
          return true;
        }
      }

      final response = await http.get(
        Uri.parse(url),
        headers: {'User-Agent': 'Geogram-Station-Updater'},
      ).timeout(const Duration(minutes: 10));

      if (response.statusCode == 200) {
        await File(targetPath).writeAsBytes(response.bodyBytes);
        final sizeMb = (response.bodyBytes.length / (1024 * 1024)).toStringAsFixed(1);
        LogService().log('Downloaded $filename: ${sizeMb}MB');
        return true;
      } else {
        LogService().log('Failed to download $filename: ${response.statusCode}');
        return false;
      }
    } catch (e) {
      LogService().log('Error downloading $filename: $e');
      return false;
    }
  }

  /// Build asset URLs pointing to this station (version-based paths)
  Map<String, String> _buildAssetUrls() => _downloadedAssets;

  /// Build asset filenames map
  Map<String, String> _buildAssetFilenames() => _assetFilenames;

  /// Handle GET /api/updates/latest - Return latest release info
  Future<void> _handleUpdatesLatest(HttpRequest request) async {
    if (request.method != 'GET') {
      request.response.statusCode = 405;
      request.response.write('Method Not Allowed');
      return;
    }

    request.response.headers.contentType = ContentType.json;

    if (_cachedRelease == null) {
      // No updates cached yet
      request.response.write(jsonEncode({
        'status': 'no_updates_cached',
        'message': 'Station has not downloaded any updates yet',
      }));
    } else {
      request.response.write(jsonEncode(_cachedRelease));
    }
  }

  /// Handle GET /updates/{version}/{filename} - Serve binary file
  Future<void> _handleUpdateDownload(HttpRequest request) async {
    if (request.method != 'GET') {
      request.response.statusCode = 405;
      request.response.write('Method Not Allowed');
      return;
    }

    final path = request.uri.path;
    // Expected format: /updates/{version}/{filename}
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();

    if (parts.length < 3) {
      request.response.statusCode = 400;
      request.response.write('Invalid path format. Expected: /updates/{version}/{filename}');
      return;
    }

    final version = parts[1];
    final filename = parts.sublist(2).join('/');

    if (_updatesDirectory == null) {
      request.response.statusCode = 503;
      request.response.write('Updates directory not initialized');
      return;
    }

    final filePath = '$_updatesDirectory/$version/$filename';
    final file = File(filePath);

    if (!await file.exists()) {
      request.response.statusCode = 404;
      request.response.write('File not found: $filename');
      LogService().log('Update file not found: $filePath');
      return;
    }

    try {
      final fileLength = await file.length();

      // Set appropriate content type based on file extension
      String contentType = 'application/octet-stream';
      if (filename.endsWith('.apk')) {
        contentType = 'application/vnd.android.package-archive';
      } else if (filename.endsWith('.aab')) {
        contentType = 'application/x-authorware-bin';
      } else if (filename.endsWith('.zip')) {
        contentType = 'application/zip';
      } else if (filename.endsWith('.tar.gz') || filename.endsWith('.tgz')) {
        contentType = 'application/gzip';
      } else if (filename.endsWith('.ipa')) {
        contentType = 'application/octet-stream';
      }

      request.response.headers.set('Content-Type', contentType);
      request.response.headers.set('Content-Length', fileLength.toString());
      request.response.headers.set('Content-Disposition', 'attachment; filename="$filename"');

      // Stream the file to the response
      await request.response.addStream(file.openRead());
      LogService().log('Served update file: $filename (${(fileLength / (1024 * 1024)).toStringAsFixed(1)}MB)');
    } catch (e) {
      LogService().log('Error serving update file: $e');
      request.response.statusCode = 500;
      request.response.write('Error reading file');
    }
  }

  /// Get cached release info for API response
  Map<String, dynamic>? getCachedRelease() => _cachedRelease;
}
