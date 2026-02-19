// Abstract base class for station server implementations
// Both PureStationServer (CLI) and StationServerService (App) extend this class

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:mime/mime.dart';

import 'station_settings.dart';
import 'station_client.dart';
import 'station_tile_cache.dart';
import 'station_stats.dart';
import '../util/event_bus.dart';
import '../services/email_relay_service.dart';
import '../services/nostr_blossom_service.dart';
import '../services/nostr_relay_service.dart';
import '../services/nostr_relay_storage.dart';
import '../services/nostr_storage_paths.dart';
import '../services/nip05_registry_service.dart';
import '../services/geoip_service.dart';
import '../util/nostr_crypto.dart';
import '../services/profile_storage.dart';
import '../api/handlers/alert_handler.dart';
import '../api/handlers/place_handler.dart';
import '../api/handlers/feedback_handler.dart';
import '../version.dart';

/// Abstract base class for station servers
/// Provides shared functionality for HTTP server, WebSocket, tile caching, NOSTR services
abstract class StationServerBase {
  // ============ Core State ============
  HttpServer? _httpServer;
  StationSettings _settings = StationSettings();
  final Map<String, StationClient> _clients = {};
  final StationTileCache _tileCache = StationTileCache();
  final StationStats _stats = StationStats();
  final EventBus _eventBus = EventBus();
  bool _running = false;
  DateTime? _startTime;
  String? _dataDir;
  String? _tilesDirectory;
  String? _updatesDirectory;

  // Connection tolerance: preserve uptime for reconnects within 5 minutes
  final Map<String, DisconnectInfo> _disconnectInfo = {};
  static const Duration _reconnectTolerance = Duration(minutes: 5);

  // Backup providers registry
  final Map<String, BackupProviderEntry> _backupProviders = {};
  static const Duration _backupProviderTtl = Duration(seconds: 90);

  // Pending HTTP proxy requests (requestId -> completer)
  final Map<String, Completer<Map<String, dynamic>>> _pendingProxyRequests = {};

  // Update mirror state
  Timer? _updatePollTimer;
  Map<String, dynamic>? _cachedRelease;

  // Shared API handlers
  AlertHandler? _alertApi;
  PlaceHandler? _placeApi;
  FeedbackHandler? _feedbackApi;

  // NOSTR relay + Blossom
  NostrRelayStorage? _nostrStorage;
  NostrRelayService? _nostrRelay;
  NostrBlossomService? _blossom;

  // ============ Public Getters ============
  bool get isRunning => _running;
  int get connectedDevices => _clients.length;
  StationSettings get settings => _settings;
  DateTime? get startTime => _startTime;
  StationStats get stats => _stats;
  EventBus get eventBus => _eventBus;
  Map<String, StationClient> get clients => Map.unmodifiable(_clients);
  String? get dataDir => _dataDir;

  // ============ Abstract Methods (Platform-Specific) ============

  /// Log a message (implementation varies by platform)
  void log(String level, String message);

  /// Load an asset file (Flutter assets or file system)
  Future<Uint8List?> loadAsset(String assetPath);

  /// Get the current user callsign (for App) or station callsign (for CLI)
  String getCurrentUserCallsign();

  /// Get the current user npub
  String getCurrentUserNpub();

  /// Save settings to persistent storage
  Future<void> saveSettingsToStorage();

  /// Load settings from persistent storage
  Future<bool> loadSettingsFromStorage();

  /// Get path for chat data directory
  String getChatDataPath([String? callsign]);

  /// Called when the server starts (for platform-specific initialization)
  Future<void> onServerStart();

  /// Called when the server stops (for platform-specific cleanup)
  Future<void> onServerStop();

  /// Handle additional platform-specific routes
  /// Return true if the route was handled, false to continue to default handling
  Future<bool> handlePlatformRoute(HttpRequest request, String path, String method);

  // ============ Shared API Handlers ============

  /// Get the shared alert API handlers (lazy initialization)
  AlertHandler get alertApi {
    if (_alertApi == null) {
      if (_dataDir == null) {
        throw StateError('alertApi accessed before initialization');
      }
      _alertApi = AlertHandler(
        storage: FilesystemProfileStorage('$_dataDir/devices/${_settings.callsign}'),
        stationInfo: StationInfo(
          name: _settings.name ?? 'Geogram Station',
          callsign: _settings.callsign,
          npub: _settings.npub,
        ),
        log: (level, message) => log(level, message),
      );
    }
    return _alertApi!;
  }

  /// Get the shared places API handlers (lazy initialization)
  PlaceHandler get placeApi {
    if (_placeApi == null) {
      if (_dataDir == null) {
        throw StateError('placeApi accessed before initialization');
      }
      _placeApi = PlaceHandler(
        dataDir: _dataDir!,
        stationInfo: StationInfo(
          name: _settings.name ?? 'Geogram Station',
          callsign: _settings.callsign,
          npub: _settings.npub,
        ),
        log: (level, message) => log(level, message),
      );
    }
    return _placeApi!;
  }

  /// Get the shared feedback API handlers (lazy initialization)
  FeedbackHandler get feedbackApi {
    if (_feedbackApi == null) {
      if (_dataDir == null) {
        throw StateError('feedbackApi accessed before initialization');
      }
      _feedbackApi = FeedbackHandler(
        storage: FilesystemProfileStorage('$_dataDir/devices/${_settings.callsign}'),
        log: (level, message) => log(level, message),
      );
    }
    return _feedbackApi!;
  }

  // ============ Server Lifecycle ============

  /// Initialize the server with required paths
  Future<void> initializeBase({
    required String dataDir,
    required String tilesDirectory,
    required String updatesDirectory,
  }) async {
    _dataDir = dataDir;
    _tilesDirectory = tilesDirectory;
    _updatesDirectory = updatesDirectory;

    // Create directories
    await Directory(tilesDirectory).create(recursive: true);
    await Directory(updatesDirectory).create(recursive: true);

    // Load settings
    await loadSettingsFromStorage();

    // Initialize NOSTR services
    await _initNostrServices();

    // Load cached release info
    await _loadCachedRelease();

    // Configure encrypted offline email cache directory.
    EmailRelayService().setCacheDirectory('$dataDir/email-cache');

    log('INFO', 'Station server base initialized');
    log('INFO', 'Data directory: $_dataDir');
  }

  /// Start the HTTP server
  Future<bool> startServer() async {
    if (_running) {
      log('WARN', 'Station server already running');
      return true;
    }

    try {
      // Reload settings
      await loadSettingsFromStorage();

      // Initialize NOSTR services
      await _initNostrServices();
      _nostrRelay?.requireAuthForWrites = _settings.nostrRequireAuthForWrites;
      if (_blossom != null) {
        _blossom!
          ..maxBytes = _settings.blossomMaxStorageMb * 1024 * 1024
          ..maxFileBytes = _settings.blossomMaxFileMb * 1024 * 1024;
      }

      // Start HTTP server
      _httpServer = await HttpServer.bind(
        InternetAddress.anyIPv4,
        _settings.httpPort,
        shared: true,
      );

      _running = true;
      _startTime = DateTime.now();

      // Initialize NIP-05 registry
      final nip05Registry = Nip05RegistryService();
      await nip05Registry.init();
      if (_settings.npub.isNotEmpty) {
        nip05Registry.setStationOwner(_settings.npub);
      }

      // Initialize GeoIP service
      await _initGeoIp();

      log('INFO', 'HTTP server started on port ${_settings.httpPort}');

      // Handle requests
      _httpServer!.listen(_handleRequest, onError: (error) {
        log('ERROR', 'HTTP server error: $error');
      });

      // Start update polling
      _startUpdatePolling();

      // Call platform-specific start hook
      await onServerStart();

      return true;
    } catch (e) {
      log('ERROR', 'Failed to start station server: $e');
      return false;
    }
  }

  /// Stop the HTTP server
  Future<void> stopServer() async {
    if (!_running) return;

    // Stop update polling
    _updatePollTimer?.cancel();
    _updatePollTimer = null;

    // Close all client connections
    for (final client in _clients.values) {
      try {
        await client.socket.close();
      } catch (_) {}
    }
    _clients.clear();

    // Complete pending proxy requests
    for (final completer in _pendingProxyRequests.values) {
      if (!completer.isCompleted) {
        completer.complete({
          'statusCode': 503,
          'responseBody': 'Server stopping',
        });
      }
    }
    _pendingProxyRequests.clear();

    // Close HTTP server
    await _httpServer?.close(force: true);
    _httpServer = null;

    // Cleanup NOSTR services
    _nostrRelay = null;
    _nostrStorage?.close();
    _nostrStorage = null;
    _blossom?.close();
    _blossom = null;

    _running = false;
    _startTime = null;

    // Call platform-specific stop hook
    await onServerStop();

    log('INFO', 'Station server stopped');
  }

  /// Restart the server
  Future<void> restartServer() async {
    log('INFO', 'Restarting station server...');
    await stopServer();
    await Future.delayed(const Duration(milliseconds: 500));
    await startServer();
  }

  // ============ NOSTR Services ============

  Future<void> _initNostrServices() async {
    final baseDir = NostrStoragePaths.baseDir();
    await Directory(baseDir).create(recursive: true);

    _nostrStorage ??= NostrRelayStorage.open();
    _blossom ??= NostrBlossomService.open(
      maxBytes: _settings.blossomMaxStorageMb * 1024 * 1024,
      maxFileBytes: _settings.blossomMaxFileMb * 1024 * 1024,
    );

    final allowed = await _loadAllowedPubkeys();
    _nostrRelay ??= NostrRelayService(
      storage: _nostrStorage!,
      blossom: _blossom,
      requireAuthForWrites: _settings.nostrRequireAuthForWrites,
      allowedPubkeysHex: allowed,
    );
  }

  Future<Set<String>> _loadAllowedPubkeys() async {
    final allowed = <String>{};

    // Add station's own pubkey
    if (_settings.npub.isNotEmpty) {
      try {
        allowed.add(NostrCrypto.decodeNpub(_settings.npub));
      } catch (_) {}
    }

    // Subclasses can override to add contacts
    return allowed;
  }

  Future<void> _initGeoIp() async {
    // Try to load GeoIP database from various locations
    final possiblePaths = [
      if (_dataDir != null) '$_dataDir/assets/dbip-city-lite.mmdb',
      'assets/dbip-city-lite.mmdb',
      '/opt/geogram/assets/dbip-city-lite.mmdb',
    ];

    for (final dbPath in possiblePaths) {
      try {
        if (await File(dbPath).exists()) {
          await GeoIpService().initFromFile(dbPath);
          log('INFO', 'GeoIP database loaded from $dbPath');
          return;
        }
      } catch (_) {}
    }

    // Try loading from asset
    final assetData = await loadAsset('assets/dbip-city-lite.mmdb');
    if (assetData != null) {
      await GeoIpService().initFromBytes(assetData);
      log('INFO', 'GeoIP database loaded from assets');
    } else {
      log('WARN', 'GeoIP database not found');
    }
  }

  // ============ HTTP Request Handling ============

  Future<void> _handleRequest(HttpRequest request) async {
    final path = request.uri.path;
    final method = request.method;
    _stats.recordApiRequest();

    try {
      // WebSocket upgrade
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        await _handleWebSocket(request);
        return;
      }

      // CORS headers
      if (_settings.enableCors) {
        request.response.headers.add('Access-Control-Allow-Origin', '*');
        request.response.headers.add('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS');
        request.response.headers.add(
            'Access-Control-Allow-Headers',
            'Content-Type, Authorization, X-Device-Callsign, X-Filename');
      }

      if (method == 'OPTIONS') {
        request.response.statusCode = 200;
        await request.response.close();
        return;
      }

      // Try platform-specific routes first
      if (await handlePlatformRoute(request, path, method)) {
        await request.response.close();
        return;
      }

      // Common routes
      await _routeRequest(request, path, method);
    } catch (e) {
      log('ERROR', 'Request error: $e');
      request.response.statusCode = 500;
      request.response.write('Internal Server Error');
    }

    await request.response.close();
  }

  Future<void> _routeRequest(HttpRequest request, String path, String method) async {
    // Status endpoints
    if (path == '/api/status' || path == '/status') {
      await _handleStatus(request);
    }
    // GeoIP endpoint
    else if (path == '/api/geoip') {
      await _handleGeoIp(request);
    }
    // Clients/devices endpoint
    else if (path == '/api/clients' || path == '/api/devices') {
      await _handleClients(request);
    }
    // Blossom endpoints
    else if (path.startsWith('/blossom')) {
      await _handleBlossomRequest(request);
    }
    // Tile server
    else if (path.startsWith('/tiles/')) {
      _stats.recordTileRequest();
      await _handleTileRequest(request);
    }
    // Updates
    else if (path == '/api/updates/latest') {
      await _handleUpdatesLatest(request);
    }
    else if (path.startsWith('/updates/')) {
      await _handleUpdateDownload(request);
    }
    // NIP-05 well-known
    else if (path == '/.well-known/nostr.json') {
      await _handleWellKnownNostr(request);
    }
    // Root
    else if (path == '/') {
      await _handleRoot(request);
    }
    // Not found
    else {
      request.response.statusCode = 404;
      request.response.write('Not Found');
    }
  }

  // ============ WebSocket Handling ============

  Future<void> _handleWebSocket(HttpRequest request) async {
    try {
      final socket = await WebSocketTransformer.upgrade(request);
      final clientId = DateTime.now().millisecondsSinceEpoch.toString();
      final isOpenRelay = _isOpenRelayPath(request.uri.path);

      // Get remote address for connection type detection
      final remoteAddress = request.connectionInfo?.remoteAddress.address;
      final connectionType = StationClient.detectConnectionType(remoteAddress);

      final client = StationClient(
        socket: socket,
        id: clientId,
        remoteAddress: remoteAddress,
        connectionType: connectionType,
      );

      _clients[clientId] = client;
      _stats.recordConnection();
      log('INFO', 'WebSocket client connected: $clientId from $remoteAddress');

      // Register with NOSTR relay
      _nostrRelay?.registerConnection(
        clientId,
        (message) => socket.add(message),
        openRelay: isOpenRelay,
      );

      socket.listen(
        (data) => _handleWebSocketMessage(client, data),
        onDone: () {
          _nostrRelay?.unregisterConnection(clientId);
          _removeClient(clientId, reason: 'connection closed');
        },
        onError: (error) {
          _nostrRelay?.unregisterConnection(clientId);
          log('ERROR', 'WebSocket error: $error');
          _removeClient(clientId, reason: 'error');
        },
      );
    } catch (e) {
      log('ERROR', 'WebSocket upgrade failed: $e');
    }
  }

  void _handleWebSocketMessage(StationClient client, dynamic data) {
    try {
      client.lastActivity = DateTime.now();

      if (data is String) {
        final decoded = jsonDecode(data);

        // NOSTR relay frame (array)
        if (decoded is List) {
          _nostrRelay?.handleFrame(client.id, decoded);
          return;
        }

        // Station protocol message (object)
        final message = decoded as Map<String, dynamic>;
        final type = message['type'] as String?;

        switch (type) {
          case 'hello':
            _handleHelloMessage(client, message);
            break;
          case 'PING':
            client.socket.add(jsonEncode({'type': 'PONG'}));
            break;
          case 'PONG':
            // Activity already updated
            break;
          case 'HTTP_RESPONSE':
            _handleHttpResponse(message);
            break;
          case 'email_send':
            _handleEmailSend(client, message);
            break;
          case 'backup_provider_announce':
            _handleBackupProviderAnnounce(client, message);
            break;
          default:
            // Let subclass handle other message types
            handlePlatformWebSocketMessage(client, message);
        }
      }
    } catch (e) {
      log('ERROR', 'WebSocket message error: $e');
    }
  }

  /// Override in subclass to handle platform-specific WebSocket messages
  void handlePlatformWebSocketMessage(StationClient client, Map<String, dynamic> message) {
    // Default: ignore unknown messages
  }

  void _handleHelloMessage(StationClient client, Map<String, dynamic> message) {
    // Extract client info
    String? callsign = message['callsign'] as String?;
    String? nickname = message['nickname'] as String?;
    String? deviceType = message['device_type'] as String?;
    String? version = message['version'] as String?;
    String? npub;
    double? latitude;
    double? longitude;
    String? color;

    // Check for NOSTR event format
    final event = message['event'] as Map<String, dynamic>?;
    if (event != null) {
      final pubkey = event['pubkey'] as String?;
      if (pubkey != null && pubkey.isNotEmpty) {
        npub = NostrCrypto.encodeNpub(pubkey);
      }

      final tags = event['tags'] as List<dynamic>?;
      if (tags != null) {
        for (final tag in tags) {
          if (tag is List && tag.length >= 2) {
            switch (tag[0]) {
              case 'callsign':
                callsign = tag[1] as String?;
                break;
              case 'nickname':
                nickname = tag[1] as String?;
                break;
              case 'color':
                color = tag[1] as String?;
                break;
              case 'latitude':
                latitude = double.tryParse(tag[1].toString());
                break;
              case 'longitude':
                longitude = double.tryParse(tag[1].toString());
                break;
              case 'platform':
                final platform = tag[1] as String?;
                client.platform = platform;
                if (platform == 'Android' || platform == 'iOS') {
                  deviceType = 'mobile';
                } else if (platform == 'Web') {
                  deviceType = 'web';
                } else {
                  deviceType = 'desktop';
                }
                break;
            }
          }
        }
      }
    }

    // npub is mandatory
    if (npub == null || npub.isEmpty) {
      final response = {
        'type': 'hello_ack',
        'success': false,
        'error': 'npub is required for HELLO',
        'station_id': _settings.callsign,
      };
      client.socket.add(jsonEncode(response));
      log('WARN', 'HELLO rejected: missing npub');
      return;
    }

    // Check NIP-05 collision
    if (callsign != null) {
      final registry = Nip05RegistryService();
      final conflictingNpub = registry.checkCollision(callsign, npub);
      if (conflictingNpub != null) {
        final response = {
          'type': 'hello_ack',
          'success': false,
          'error': 'callsign_npub_mismatch',
          'message': 'Callsign "$callsign" is registered to a different identity',
          'station_id': _settings.callsign,
        };
        client.socket.add(jsonEncode(response));
        log('SECURITY', 'HELLO rejected: callsign collision');
        _removeClient(client.id, reason: 'callsign_npub_mismatch');
        return;
      }
    }

    // Update client info
    client.callsign = callsign;
    client.nickname = nickname;
    client.color = color;
    client.npub = npub;
    client.deviceType = deviceType;
    client.version = version;
    client.latitude = latitude;
    client.longitude = longitude;

    // Check reconnection tolerance
    if (callsign != null) {
      final callsignKey = callsign.toUpperCase();
      final info = _disconnectInfo[callsignKey];
      if (info != null) {
        final timeSinceDisconnect = DateTime.now().difference(info.disconnectTime);
        if (timeSinceDisconnect <= _reconnectTolerance) {
          client.connectedAt = info.originalConnectTime;
          log('INFO', 'Restored connect time for $callsign');
        }
        _disconnectInfo.remove(callsignKey);
      }
    }

    // Register for NIP-05
    if (callsign != null) {
      Nip05RegistryService().registerIdentity(callsign, npub, nickname: nickname);
    }

    // Send acknowledgment
    final response = {
      'type': 'hello_ack',
      'success': true,
      'station_id': _settings.callsign,
      'station_npub': _settings.npub,
      'message': 'Welcome to ${_settings.name ?? "Geogram Station"}',
      'version': appVersion,
    };
    client.socket.add(jsonEncode(response));
    log('INFO', 'Hello from: ${client.callsign ?? "unknown"} (${client.deviceType ?? "unknown"})');

    // Deliver pending internal emails
    if (callsign != null) {
      EmailRelayService().deliverPendingEmails(
        clientId: client.id,
        callsign: callsign,
        sendToClient: (targetId, msg) {
          final target = _clients[targetId];
          return target != null ? safeSocketSend(target, msg) : false;
        },
        getStationDomain: () => _settings.sslDomain ?? _settings.callsign.toLowerCase(),
      );

    }
  }

  void _handleHttpResponse(Map<String, dynamic> message) {
    final requestId = message['requestId'] as String?;
    if (requestId != null && _pendingProxyRequests.containsKey(requestId)) {
      final completer = _pendingProxyRequests[requestId]!;
      if (!completer.isCompleted) {
        completer.complete(message);
      }
    }
  }

  void _handleBackupProviderAnnounce(StationClient client, Map<String, dynamic> message) {
    final callsign = client.callsign;
    final npub = client.npub;
    if (callsign == null || npub == null) return;

    final entry = BackupProviderEntry(
      callsign: callsign,
      npub: npub,
      maxTotalStorageBytes: message['max_total_storage_bytes'] as int? ?? 0,
      defaultMaxClientStorageBytes: message['default_max_client_storage_bytes'] as int? ?? 0,
      defaultMaxSnapshots: message['default_max_snapshots'] as int? ?? 0,
      lastSeen: DateTime.now(),
    );
    _backupProviders[callsign.toUpperCase()] = entry;
    log('INFO', 'Backup provider registered: $callsign');
  }

  /// Handle email_send WebSocket message
  void _handleEmailSend(StationClient client, Map<String, dynamic> message) {
    if (client.callsign == null) {
      log('WARN', 'email_send from unauthenticated client ${client.id}');
      return;
    }

    EmailRelayService().handleEmailSend(
      message: message,
      senderCallsign: client.callsign!,
      senderId: client.id,
      sendToClient: (clientId, msg) {
        final target = _clients[clientId];
        return target != null ? safeSocketSend(target, msg) : false;
      },
      findClientByCallsign: _findClientByCallsign,
      getStationDomain: () => _settings.sslDomain ?? _settings.callsign.toLowerCase(),
    );
  }

  /// Find a connected client by callsign
  String? _findClientByCallsign(String callsign) {
    for (final entry in _clients.entries) {
      if (entry.value.callsign?.toUpperCase() == callsign.toUpperCase()) {
        return entry.key;
      }
    }
    return null;
  }

  void _removeClient(String clientId, {String reason = 'disconnected'}) {
    final client = _clients.remove(clientId);
    if (client == null) return;

    // Store disconnect info for reconnection tolerance
    if (client.callsign != null) {
      final callsignKey = client.callsign!.toUpperCase();
      _disconnectInfo[callsignKey] = DisconnectInfo(
        disconnectTime: DateTime.now(),
        originalConnectTime: client.connectedAt,
      );
      _backupProviders.remove(callsignKey);
    }

    try {
      client.socket.close();
    } catch (_) {}

    log('INFO', 'Client removed: ${client.callsign ?? clientId} ($reason)');
  }

  bool _isOpenRelayPath(String path) {
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) return true;
    final first = segments.first;
    // If it looks like a callsign, it's a private relay path
    return !RegExp(r'^x[0-9a-z]{3,}$', caseSensitive: false).hasMatch(first);
  }

  // ============ HTTP Handlers ============

  Future<void> _handleStatus(HttpRequest request) async {
    final status = {
      'station_mode': true,
      'callsign': _settings.callsign,
      'npub': _settings.npub,
      'name': _settings.name,
      'description': _settings.description,
      'location': _settings.location,
      'latitude': _settings.latitude,
      'longitude': _settings.longitude,
      'version': appVersion,
      'uptime': _startTime != null
          ? DateTime.now().difference(_startTime!).inSeconds
          : 0,
      'connected_devices': _clients.length,
      'tile_server_enabled': _settings.tileServerEnabled,
      'update_mirror_enabled': _settings.updateMirrorEnabled,
    };

    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(status));
  }

  Future<void> _handleGeoIp(HttpRequest request) async {
    final ip = request.uri.queryParameters['ip'] ??
        request.connectionInfo?.remoteAddress.address;

    if (ip == null) {
      request.response.statusCode = 400;
      request.response.write(jsonEncode({'error': 'No IP provided'}));
      return;
    }

    final geoip = GeoIpService();
    if (!geoip.isInitialized) {
      request.response.statusCode = 503;
      request.response.write(jsonEncode({'error': 'GeoIP service not available'}));
      return;
    }

    final result = await geoip.lookup(ip);
    request.response.headers.contentType = ContentType.json;
    if (result != null) {
      request.response.write(jsonEncode({
        'ip': result.ip,
        'latitude': result.latitude,
        'longitude': result.longitude,
        'city': result.city,
        'country': result.country,
        'country_code': result.countryCode,
      }));
    } else {
      request.response.write(jsonEncode({'error': 'IP not found'}));
    }
  }

  Future<void> _handleClients(HttpRequest request) async {
    final clientList = _clients.values.map((c) => c.toJson()).toList();
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({
      'count': clientList.length,
      'clients': clientList,
    }));
  }

  Future<void> _handleBlossomRequest(HttpRequest request) async {
    final path = request.uri.path;
    final method = request.method;

    if (_blossom == null) {
      request.response.statusCode = 503;
      request.response.write(jsonEncode({'error': 'Blossom not initialized'}));
      return;
    }

    if (method == 'POST' && path == '/blossom/upload') {
      await _handleBlossomUpload(request);
    } else if (method == 'GET' && path.startsWith('/blossom/')) {
      final hash = path.substring('/blossom/'.length);
      final file = _blossom!.getBlobFile(hash);
      if (file != null) {
        final data = await file.readAsBytes();
        final mime = lookupMimeType('', headerBytes: data) ?? 'application/octet-stream';
        request.response.headers.contentType = ContentType.parse(mime);
        request.response.add(data);
      } else {
        request.response.statusCode = 404;
        request.response.write('Not found');
      }
    } else if (method == 'HEAD' && path.startsWith('/blossom/')) {
      final hash = path.substring('/blossom/'.length);
      final file = _blossom!.getBlobFile(hash);
      if (file != null) {
        request.response.statusCode = 200;
      } else {
        request.response.statusCode = 404;
      }
    } else if (method == 'DELETE' && path.startsWith('/blossom/')) {
      // Requires authentication - subclass handles
      request.response.statusCode = 403;
      request.response.write('Unauthorized');
    } else {
      request.response.statusCode = 404;
      request.response.write('Not found');
    }
  }

  Future<void> _handleBlossomUpload(HttpRequest request) async {
    try {
      final bytes = await _readRequestBody(request);
      final mimeType = lookupMimeType('', headerBytes: Uint8List.fromList(bytes)) ?? 'application/octet-stream';
      final result = await _blossom!.ingestBytes(bytes: Uint8List.fromList(bytes), mime: mimeType);

      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'hash': result.hash,
        'size': result.size,
        'url': '/blossom/${result.hash}',
      }));
    } catch (e) {
      request.response.statusCode = 500;
      request.response.write(jsonEncode({'error': e.toString()}));
    }
  }

  Future<void> _handleTileRequest(HttpRequest request) async {
    if (!_settings.tileServerEnabled) {
      request.response.statusCode = 503;
      request.response.write('Tile server disabled');
      return;
    }

    final path = request.uri.path;
    final parts = path.split('/');
    // /tiles/{z}/{x}/{y}.png
    if (parts.length < 5) {
      request.response.statusCode = 400;
      request.response.write('Invalid tile path');
      return;
    }

    final z = int.tryParse(parts[2]);
    final x = int.tryParse(parts[3]);
    final yPart = parts[4].replaceAll('.png', '');
    final y = int.tryParse(yPart);

    if (z == null || x == null || y == null) {
      request.response.statusCode = 400;
      request.response.write('Invalid tile coordinates');
      return;
    }

    if (z > _settings.maxZoomLevel) {
      request.response.statusCode = 400;
      request.response.write('Zoom level exceeds maximum');
      return;
    }

    final cacheKey = '$z/$x/$y';

    // Check cache first
    final cached = _tileCache.get(cacheKey);
    if (cached != null) {
      _stats.recordTileRequest(fromCache: true);
      request.response.headers.contentType = ContentType.parse('image/png');
      request.response.add(cached);
      return;
    }

    // Try to load from disk
    final tilePath = '$_tilesDirectory/$z/$x/$y.png';
    final tileFile = File(tilePath);
    if (await tileFile.exists()) {
      final data = await tileFile.readAsBytes();
      if (StationTileCache.isValidImageData(data)) {
        _tileCache.put(cacheKey, data);
        _stats.recordTileRequest(fromCache: true);
        request.response.headers.contentType = ContentType.parse('image/png');
        request.response.add(data);
        return;
      }
    }

    // Fetch from OSM if fallback is enabled
    if (_settings.osmFallbackEnabled) {
      try {
        final osmUrl = 'https://tile.openstreetmap.org/$z/$x/$y.png';
        final response = await http.get(
          Uri.parse(osmUrl),
          headers: {'User-Agent': 'Geogram/$appVersion'},
        ).timeout(Duration(milliseconds: _settings.httpRequestTimeout));

        if (response.statusCode == 200 && StationTileCache.isValidImageData(response.bodyBytes)) {
          final data = Uint8List.fromList(response.bodyBytes);
          _tileCache.put(cacheKey, data);
          _stats.recordTileCached();

          // Save to disk
          final dir = Directory('$_tilesDirectory/$z/$x');
          await dir.create(recursive: true);
          await tileFile.writeAsBytes(data);

          request.response.headers.contentType = ContentType.parse('image/png');
          request.response.add(data);
          return;
        }
      } catch (e) {
        log('WARN', 'Failed to fetch tile from OSM: $e');
      }
    }

    request.response.statusCode = 404;
    request.response.write('Tile not found');
  }

  Future<void> _handleUpdatesLatest(HttpRequest request) async {
    if (!_settings.updateMirrorEnabled) {
      request.response.statusCode = 503;
      request.response.write(jsonEncode({'error': 'Update mirror disabled'}));
      return;
    }

    if (_cachedRelease != null) {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(_cachedRelease));
    } else {
      request.response.statusCode = 503;
      request.response.write(jsonEncode({'error': 'No release info cached'}));
    }
  }

  Future<void> _handleUpdateDownload(HttpRequest request) async {
    final path = request.uri.path;
    final filename = path.substring('/updates/'.length);
    final filePath = '$_updatesDirectory/$filename';
    final file = File(filePath);

    if (await file.exists()) {
      final bytes = await file.readAsBytes();
      final mime = lookupMimeType(filename) ?? 'application/octet-stream';
      request.response.headers.contentType = ContentType.parse(mime);
      request.response.headers.add('Content-Disposition', 'attachment; filename="$filename"');
      request.response.add(bytes);
    } else {
      request.response.statusCode = 404;
      request.response.write('File not found');
    }
  }

  Future<void> _handleWellKnownNostr(HttpRequest request) async {
    final name = request.uri.queryParameters['name'];
    if (name == null || name.isEmpty) {
      request.response.statusCode = 400;
      request.response.write(jsonEncode({'error': 'name parameter required'}));
      return;
    }

    final registry = Nip05RegistryService();
    final registration = registry.getRegistration(name);

    if (registration != null) {
      String? pubkeyHex;
      try {
        pubkeyHex = NostrCrypto.decodeNpub(registration.npub);
      } catch (_) {}

      if (pubkeyHex != null) {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'names': {name.toLowerCase(): pubkeyHex},
        }));
        return;
      }
    }

    request.response.statusCode = 404;
    request.response.write(jsonEncode({'error': 'Name not found'}));
  }

  Future<void> _handleRoot(HttpRequest request) async {
    request.response.headers.contentType = ContentType.html;
    request.response.write('''
<!DOCTYPE html>
<html>
<head>
  <title>${_settings.name ?? 'Geogram Station'}</title>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
</head>
<body>
  <h1>${_settings.name ?? 'Geogram Station'}</h1>
  <p>Callsign: ${_settings.callsign}</p>
  <p>Version: $appVersion</p>
  <p>Connected devices: ${_clients.length}</p>
  <p><a href="/api/status">API Status</a></p>
</body>
</html>
''');
  }

  // ============ Update Mirror ============

  void _startUpdatePolling() {
    if (!_settings.updateMirrorEnabled) return;

    _updatePollTimer?.cancel();
    _updatePollTimer = Timer.periodic(
      Duration(seconds: _settings.updateCheckIntervalSeconds),
      (_) => _pollForUpdates(),
    );

    // Initial poll
    _pollForUpdates();
  }

  Future<void> _pollForUpdates() async {
    try {
      final response = await http.get(
        Uri.parse(_settings.updateMirrorUrl),
        headers: {'Accept': 'application/vnd.github.v3+json'},
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final release = jsonDecode(response.body) as Map<String, dynamic>;
        _cachedRelease = release;
        await _saveCachedRelease();
      }
    } catch (e) {
      log('WARN', 'Update poll failed: $e');
    }
  }

  Future<void> _loadCachedRelease() async {
    try {
      final file = File('$_updatesDirectory/release.json');
      if (await file.exists()) {
        final content = await file.readAsString();
        _cachedRelease = jsonDecode(content) as Map<String, dynamic>?;
      }
    } catch (e) {
      log('WARN', 'Failed to load cached release: $e');
    }
  }

  Future<void> _saveCachedRelease() async {
    if (_cachedRelease == null) return;
    try {
      final file = File('$_updatesDirectory/release.json');
      await file.writeAsString(jsonEncode(_cachedRelease));
    } catch (e) {
      log('WARN', 'Failed to save cached release: $e');
    }
  }

  // ============ Utility Methods ============

  Future<List<int>> _readRequestBody(HttpRequest request) async {
    final chunks = <List<int>>[];
    await for (final chunk in request) {
      chunks.add(chunk);
    }
    return chunks.expand((e) => e).toList();
  }

  /// Safely send data to a client
  bool safeSocketSend(StationClient client, String data) {
    try {
      client.socket.add(data);
      return true;
    } catch (e) {
      log('ERROR', 'Failed to send to ${client.callsign ?? client.id}: $e');
      client.lastActivity = DateTime.fromMillisecondsSinceEpoch(0);
      return false;
    }
  }

  /// Broadcast message to all connected clients
  void broadcast(String message) {
    final payload = jsonEncode({
      'type': 'broadcast',
      'message': message,
      'from': _settings.callsign,
      'timestamp': DateTime.now().toIso8601String(),
    });

    for (final client in _clients.values) {
      safeSocketSend(client, payload);
    }
    log('INFO', 'Broadcast sent to ${_clients.length} clients');
  }

  /// Kick a device by callsign
  bool kickDevice(String callsign) {
    String? clientId;
    for (final entry in _clients.entries) {
      if (entry.value.callsign?.toLowerCase() == callsign.toLowerCase()) {
        clientId = entry.key;
        break;
      }
    }

    if (clientId != null) {
      _removeClient(clientId, reason: 'kicked');
      log('INFO', 'Kicked device: $callsign');
      return true;
    }
    return false;
  }

  /// Get available backup providers
  List<Map<String, dynamic>> getAvailableBackupProviders() {
    final now = DateTime.now();
    final available = <Map<String, dynamic>>[];

    _backupProviders.removeWhere((_, entry) =>
        now.difference(entry.lastSeen) > _backupProviderTtl);

    for (final entry in _backupProviders.values) {
      available.add(entry.toJson());
    }

    return available;
  }

  /// Update settings
  Future<void> updateSettings(StationSettings settings) async {
    final wasRunning = _running;
    final oldPort = _settings.httpPort;

    _settings = settings;
    await saveSettingsToStorage();

    // Restart if port changed and was running
    if (wasRunning && oldPort != settings.httpPort) {
      await stopServer();
      await startServer();
    }
  }
}
