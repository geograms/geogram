import 'dart:async';
import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:markdown/markdown.dart' as md;

import '../services/log_service.dart';
import '../services/config_service.dart';
import '../services/profile_service.dart';
import '../services/callsign_generator.dart';
import '../services/storage_config.dart';
import '../services/direct_message_service.dart';
import '../services/app_args.dart';
import '../services/station_alert_api.dart';
import '../models/blog_post.dart';
import '../models/chat_message.dart';
import '../models/update_settings.dart';
import '../util/nostr_event.dart';
import '../util/nostr_crypto.dart';
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
    this.updateMirrorUrl = 'https://api.github.com/repos/geograms/geogram-desktop/releases/latest',
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
      updateMirrorUrl: json['updateMirrorUrl'] as String? ?? 'https://api.github.com/repos/geograms/geogram-desktop/releases/latest',
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
      // WebSocket upgrade
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        await _handleWebSocket(request);
        return;
      }

      // CORS headers
      request.response.headers.add('Access-Control-Allow-Origin', '*');
      request.response.headers.add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
      request.response.headers.add('Access-Control-Allow-Headers', 'Content-Type');

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
      } else if (path.startsWith('/api/alerts/') && method == 'POST') {
        // POST /api/alerts/{alertId}/{action} - alert feedback (using shared handler)
        await _handleAlertFeedback(request);
      } else if (path == '/api/chat/rooms') {
        await _handleChatRooms(request);
      } else if (path.startsWith('/api/chat/rooms/') && path.endsWith('/messages')) {
        await _handleRoomMessages(request);
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
      } else if (_isAlertDetailsPath(path) && method == 'GET') {
        // GET /{callsign}/api/alerts/{alertId} - alert details (using shared handler)
        await _handleAlertDetails(request);
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
      'server': 'geogram-desktop-station',
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

  /// Handle /api/chat/rooms endpoint
  Future<void> _handleChatRooms(HttpRequest request) async {
    final profile = ProfileService().getProfile();

    final response = {
      'station': profile.callsign,
      'rooms': [
        {
          'id': 'general',
          'name': 'General',
          'description': 'General discussion',
          'member_count': _clients.length,
          'is_public': true,
        }
      ],
    };

    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(response));
  }

  /// Handle /api/chat/rooms/{roomId}/messages endpoint
  Future<void> _handleRoomMessages(HttpRequest request) async {
    final path = request.uri.path;
    // Extract room ID from path
    final parts = path.split('/');
    final roomId = parts.length > 4 ? parts[4] : 'general';

    if (request.method == 'GET') {
      // Return empty messages for now
      final response = {
        'room': roomId,
        'messages': <Map<String, dynamic>>[],
      };
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(response));
    } else if (request.method == 'POST') {
      // Handle message posting
      request.response.statusCode = 201;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'status': 'ok'}));
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
    return regex.hasMatch(path);
  }

  /// Check if path is a device proxy path (/{callsign}/api/*)
  bool _isDeviceProxyPath(String path) {
    // Pattern: /{callsign}/api/{endpoint}
    // Must have at least 3 segments: /{callsign}/api/{something}
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    return parts.length >= 3 && parts[1] == 'api';
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
    final path = request.uri.path;
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();

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
    final path = request.uri.path;
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();

    // Parse: /{callsign}/api/alerts/{folderName}/files/{filename}
    if (parts.length < 6) {
      request.response.statusCode = 400;
      request.response.write('Invalid path');
      return;
    }

    final callsign = parts[0].toUpperCase();
    final folderName = parts[3];
    final filename = parts.sublist(5).join('/');

    LogService().log('Alert file fetch: $callsign / $folderName / $filename');

    try {
      // Get the alert storage directory
      final storageConfig = StorageConfig();
      final devicesDir = storageConfig.devicesDir;
      final filePath = '$devicesDir/$callsign/alerts/$folderName/$filename';

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

      // Determine content type
      final ext = filename.toLowerCase().split('.').last;
      String contentType = 'application/octet-stream';
      if (ext == 'jpg' || ext == 'jpeg') {
        contentType = 'image/jpeg';
      } else if (ext == 'png') {
        contentType = 'image/png';
      } else if (ext == 'gif') {
        contentType = 'image/gif';
      } else if (ext == 'webp') {
        contentType = 'image/webp';
      } else if (ext == 'txt') {
        contentType = 'text/plain';
      }

      final bytes = await file.readAsBytes();
      request.response.headers.set('Content-Type', contentType);
      request.response.headers.set('Content-Length', bytes.length.toString());
      request.response.add(bytes);

      LogService().log('Alert file served: $filePath (${bytes.length} bytes)');
    } catch (e) {
      LogService().log('Error serving alert file: $e');
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

  /// Handle POST /api/alerts/{alertId}/{action} - alert feedback using shared handler
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

      final alertId = pathParts[0];
      final action = pathParts[1].toLowerCase();

      // Read request body
      final body = await utf8.decodeStream(request);
      final json = body.isNotEmpty ? jsonDecode(body) as Map<String, dynamic> : <String, dynamic>{};

      Map<String, dynamic> result;

      switch (action) {
        case 'point':
          final npub = json['npub'] as String?;
          if (npub == null || npub.isEmpty) {
            request.response.statusCode = 400;
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode({'error': 'Missing npub'}));
            return;
          }
          result = await alertApi.pointAlert(alertId, npub, isPoint: true);
          break;

        case 'unpoint':
          final npub = json['npub'] as String?;
          if (npub == null || npub.isEmpty) {
            request.response.statusCode = 400;
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode({'error': 'Missing npub'}));
            return;
          }
          result = await alertApi.pointAlert(alertId, npub, isPoint: false);
          break;

        case 'verify':
          final npub = json['npub'] as String?;
          if (npub == null || npub.isEmpty) {
            request.response.statusCode = 400;
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode({'error': 'Missing npub'}));
            return;
          }
          result = await alertApi.verifyAlert(alertId, npub);
          break;

        case 'comment':
          final author = json['author'] as String?;
          final content = json['content'] as String?;
          if (author == null || author.isEmpty || content == null || content.isEmpty) {
            request.response.statusCode = 400;
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode({'error': 'Missing author or content'}));
            return;
          }
          result = await alertApi.addComment(
            alertId,
            author,
            content,
            npub: json['npub'] as String?,
            signature: json['signature'] as String?,
          );
          break;

        default:
          request.response.statusCode = 400;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({
            'error': 'Unknown action: $action',
            'supported': ['point', 'unpoint', 'verify', 'comment'],
          }));
          return;
      }

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
      LogService().log('Error in alert feedback: $e');
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
      // Find the callsign for this identifier (could be nickname or callsign)
      final callsign = await _findCallsignByIdentifier(identifier);
      if (callsign == null) {
        // No local user found - try to proxy to connected client
        final proxyResult = await _proxyBlogRequest(request, identifier, filename);
        if (proxyResult) {
          return; // Proxy handled the response
        }
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
    // Find connected client by callsign or nickname
    ConnectedClient? targetClient;

    for (final client in _clients.values) {
      // Check callsign match (case-insensitive)
      if (client.callsign != null &&
          client.callsign!.toLowerCase() == identifier.toLowerCase()) {
        targetClient = client;
        break;
      }
      // Check nickname match (case-insensitive)
      if (client.nickname != null &&
          client.nickname!.toLowerCase() == identifier.toLowerCase()) {
        targetClient = client;
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
      // The client expects path format: /api/blog/{filename}.html
      final blogApiPath = '/api/blog/$filename.html';
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
