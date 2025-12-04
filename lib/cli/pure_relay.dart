// Pure Dart relay server for CLI mode (no Flutter dependencies)
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import '../services/storage_config.dart';

/// App version constant
const String cliAppVersion = '1.5.1';

/// Relay server settings
class PureRelaySettings {
  int httpPort;
  bool enabled;
  bool tileServerEnabled;
  bool osmFallbackEnabled;
  int maxZoomLevel;
  int maxCacheSizeMB;
  String? description;
  String? location;
  double? latitude;
  double? longitude;
  String callsign;
  bool enableAprs;
  bool enableCors;
  int httpRequestTimeout;
  int maxConnectedDevices;

  // Relay role configuration
  String relayRole; // 'root' or 'node'
  String? networkId;
  String? parentRelayUrl; // For node relays

  // Setup flag
  bool setupComplete;

  // SSL/TLS configuration
  bool enableSsl;
  String? sslDomain;
  String? sslEmail;
  bool sslAutoRenew;
  String? sslCertPath;
  String? sslKeyPath;
  int httpsPort;

  PureRelaySettings({
    this.httpPort = 8080,
    this.enabled = false,
    this.tileServerEnabled = true,
    this.osmFallbackEnabled = true,
    this.maxZoomLevel = 15,
    this.maxCacheSizeMB = 500,
    this.description,
    this.location,
    this.latitude,
    this.longitude,
    this.callsign = 'X3DESK',
    this.enableAprs = false,
    this.enableCors = true,
    this.httpRequestTimeout = 30000,
    this.maxConnectedDevices = 100,
    this.relayRole = '',
    this.networkId,
    this.parentRelayUrl,
    this.setupComplete = false,
    this.enableSsl = false,
    this.sslDomain,
    this.sslEmail,
    this.sslAutoRenew = true,
    this.sslCertPath,
    this.sslKeyPath,
    this.httpsPort = 8443,
  });

  factory PureRelaySettings.fromJson(Map<String, dynamic> json) {
    return PureRelaySettings(
      // Support both old 'port' and new 'httpPort' keys for backward compatibility
      httpPort: json['httpPort'] as int? ?? json['port'] as int? ?? 8080,
      enabled: json['enabled'] as bool? ?? false,
      tileServerEnabled: json['tileServerEnabled'] as bool? ?? true,
      osmFallbackEnabled: json['osmFallbackEnabled'] as bool? ?? true,
      maxZoomLevel: json['maxZoomLevel'] as int? ?? 15,
      // Support both old 'maxCacheSize' and new 'maxCacheSizeMB' keys
      maxCacheSizeMB: json['maxCacheSizeMB'] as int? ?? json['maxCacheSize'] as int? ?? 500,
      description: json['description'] as String?,
      location: json['location'] as String?,
      latitude: json['latitude'] as double?,
      longitude: json['longitude'] as double?,
      callsign: json['callsign'] as String? ?? 'X3DESK',
      enableAprs: json['enableAprs'] as bool? ?? false,
      enableCors: json['enableCors'] as bool? ?? true,
      httpRequestTimeout: json['httpRequestTimeout'] as int? ?? 30000,
      maxConnectedDevices: json['maxConnectedDevices'] as int? ?? 100,
      relayRole: json['relayRole'] as String? ?? '',
      networkId: json['networkId'] as String?,
      parentRelayUrl: json['parentRelayUrl'] as String?,
      setupComplete: json['setupComplete'] as bool? ?? false,
      enableSsl: json['enableSsl'] as bool? ?? false,
      sslDomain: json['sslDomain'] as String?,
      sslEmail: json['sslEmail'] as String?,
      sslAutoRenew: json['sslAutoRenew'] as bool? ?? true,
      sslCertPath: json['sslCertPath'] as String?,
      sslKeyPath: json['sslKeyPath'] as String?,
      // Support both old 'sslPort' and new 'httpsPort' keys
      httpsPort: json['httpsPort'] as int? ?? json['sslPort'] as int? ?? 8443,
    );
  }

  Map<String, dynamic> toJson() => {
        'httpPort': httpPort,
        'enabled': enabled,
        'tileServerEnabled': tileServerEnabled,
        'osmFallbackEnabled': osmFallbackEnabled,
        'maxZoomLevel': maxZoomLevel,
        'maxCacheSizeMB': maxCacheSizeMB,
        'description': description,
        'location': location,
        'latitude': latitude,
        'longitude': longitude,
        'callsign': callsign,
        'enableAprs': enableAprs,
        'enableCors': enableCors,
        'httpRequestTimeout': httpRequestTimeout,
        'maxConnectedDevices': maxConnectedDevices,
        'relayRole': relayRole,
        'networkId': networkId,
        'parentRelayUrl': parentRelayUrl,
        'setupComplete': setupComplete,
        'enableSsl': enableSsl,
        'sslDomain': sslDomain,
        'sslEmail': sslEmail,
        'sslAutoRenew': sslAutoRenew,
        'sslCertPath': sslCertPath,
        'sslKeyPath': sslKeyPath,
        'httpsPort': httpsPort,
      };

  PureRelaySettings copyWith({
    int? httpPort,
    bool? enabled,
    bool? tileServerEnabled,
    bool? osmFallbackEnabled,
    int? maxZoomLevel,
    int? maxCacheSizeMB,
    String? description,
    String? location,
    double? latitude,
    double? longitude,
    String? callsign,
    bool? enableAprs,
    bool? enableCors,
    int? httpRequestTimeout,
    int? maxConnectedDevices,
    String? relayRole,
    String? networkId,
    String? parentRelayUrl,
    bool? setupComplete,
    bool? enableSsl,
    String? sslDomain,
    String? sslEmail,
    bool? sslAutoRenew,
    String? sslCertPath,
    String? sslKeyPath,
    int? httpsPort,
  }) {
    return PureRelaySettings(
      httpPort: httpPort ?? this.httpPort,
      enabled: enabled ?? this.enabled,
      tileServerEnabled: tileServerEnabled ?? this.tileServerEnabled,
      osmFallbackEnabled: osmFallbackEnabled ?? this.osmFallbackEnabled,
      maxZoomLevel: maxZoomLevel ?? this.maxZoomLevel,
      maxCacheSizeMB: maxCacheSizeMB ?? this.maxCacheSizeMB,
      description: description ?? this.description,
      location: location ?? this.location,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      callsign: callsign ?? this.callsign,
      enableAprs: enableAprs ?? this.enableAprs,
      enableCors: enableCors ?? this.enableCors,
      httpRequestTimeout: httpRequestTimeout ?? this.httpRequestTimeout,
      maxConnectedDevices: maxConnectedDevices ?? this.maxConnectedDevices,
      relayRole: relayRole ?? this.relayRole,
      networkId: networkId ?? this.networkId,
      parentRelayUrl: parentRelayUrl ?? this.parentRelayUrl,
      setupComplete: setupComplete ?? this.setupComplete,
      enableSsl: enableSsl ?? this.enableSsl,
      sslDomain: sslDomain ?? this.sslDomain,
      sslEmail: sslEmail ?? this.sslEmail,
      sslAutoRenew: sslAutoRenew ?? this.sslAutoRenew,
      sslCertPath: sslCertPath ?? this.sslCertPath,
      sslKeyPath: sslKeyPath ?? this.sslKeyPath,
      httpsPort: httpsPort ?? this.httpsPort,
    );
  }

  /// Check if setup needs to be run
  bool needsSetup() {
    return !setupComplete || callsign.isEmpty || relayRole.isEmpty;
  }
}

/// Log entry for CLI log history
class LogEntry {
  final DateTime timestamp;
  final String level;
  final String message;

  LogEntry(this.timestamp, this.level, this.message);

  @override
  String toString() =>
      '[${timestamp.toIso8601String()}] [$level] $message';
}

/// Chat room
class ChatRoom {
  final String id;
  String name;
  String description;
  final String creatorCallsign;
  final DateTime createdAt;
  DateTime lastActivity;
  final List<ChatMessage> messages = [];
  bool isPublic;

  ChatRoom({
    required this.id,
    required this.name,
    this.description = '',
    required this.creatorCallsign,
    DateTime? createdAt,
    this.isPublic = true,
  })  : createdAt = createdAt ?? DateTime.now(),
        lastActivity = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'creator': creatorCallsign,
        'created_at': createdAt.toIso8601String(),
        'last_activity': lastActivity.toIso8601String(),
        'message_count': messages.length,
        'is_public': isPublic,
      };
}

/// Chat message
class ChatMessage {
  final String id;
  final String roomId;
  final String senderCallsign;
  final String? senderNpub;
  final String? senderPubkey;
  final String? signature;
  final String content;
  final DateTime timestamp;

  ChatMessage({
    required this.id,
    required this.roomId,
    required this.senderCallsign,
    this.senderNpub,
    this.senderPubkey,
    this.signature,
    required this.content,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'room_id': roomId,
        'sender': senderCallsign,
        if (senderNpub != null) 'npub': senderNpub,
        if (senderPubkey != null) 'pubkey': senderPubkey,
        if (signature != null) 'signature': signature,
        'content': content,
        'timestamp': timestamp.toIso8601String(),
      };
}

/// Connected WebSocket client
class PureConnectedClient {
  final WebSocket socket;
  final String id;
  String? callsign;
  String? deviceType;
  String? version;
  String? address;
  DateTime connectedAt;
  DateTime lastActivity;

  PureConnectedClient({
    required this.socket,
    required this.id,
    this.callsign,
    this.deviceType,
    this.version,
    this.address,
  })  : connectedAt = DateTime.now(),
        lastActivity = DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'callsign': callsign ?? 'Unknown',
        'device_type': deviceType ?? 'Unknown',
        'version': version,
        'address': address,
        'connected_at': connectedAt.toIso8601String(),
        'last_activity': lastActivity.toIso8601String(),
      };
}

/// Server statistics
class ServerStats {
  int totalConnections = 0;
  int totalMessages = 0;
  int totalTileRequests = 0;
  int totalApiRequests = 0;
  int tilesCached = 0;
  int tilesServedFromCache = 0;
  int tilesDownloaded = 0;
  DateTime? lastConnection;
  DateTime? lastMessage;
  DateTime? lastTileRequest;

  Map<String, dynamic> toJson() => {
        'total_connections': totalConnections,
        'total_messages': totalMessages,
        'total_tile_requests': totalTileRequests,
        'total_api_requests': totalApiRequests,
        'tiles_cached': tilesCached,
        'tiles_served_from_cache': tilesServedFromCache,
        'tiles_downloaded': tilesDownloaded,
        'last_connection': lastConnection?.toIso8601String(),
        'last_message': lastMessage?.toIso8601String(),
        'last_tile_request': lastTileRequest?.toIso8601String(),
      };
}

/// Tile cache for relay server
class PureTileCache {
  final Map<String, Uint8List> _cache = {};
  final Map<String, DateTime> _timestamps = {};
  int _currentSize = 0;
  final int maxSizeBytes;

  PureTileCache({int maxSizeMB = 500}) : maxSizeBytes = maxSizeMB * 1024 * 1024;

  Uint8List? get(String key) {
    final data = _cache[key];
    if (data != null) {
      _timestamps[key] = DateTime.now();
    }
    return data;
  }

  void put(String key, Uint8List data) {
    if (_cache.containsKey(key)) {
      _currentSize -= _cache[key]!.length;
    }

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
    return data[0] == 0x89 &&
        data[1] == 0x50 &&
        data[2] == 0x4E &&
        data[3] == 0x47;
  }
}

/// Pure Dart relay server for CLI mode
class PureRelayServer {
  HttpServer? _httpServer;
  HttpServer? _httpsServer;
  PureRelaySettings _settings = PureRelaySettings();
  final Map<String, PureConnectedClient> _clients = {};
  final PureTileCache _tileCache = PureTileCache();
  final Map<String, ChatRoom> _chatRooms = {};
  final List<LogEntry> _logs = [];
  final ServerStats _stats = ServerStats();
  bool _running = false;
  bool _quietMode = false;
  DateTime? _startTime;
  String? _tilesDirectory;
  String? _configPath;
  String? _dataDir;

  static const int maxLogEntries = 1000;

  bool get isRunning => _running;
  int get connectedDevices => _clients.length;
  PureRelaySettings get settings => _settings;
  DateTime? get startTime => _startTime;
  List<LogEntry> get logs => List.unmodifiable(_logs);
  ServerStats get stats => _stats;
  Map<String, PureConnectedClient> get clients => Map.unmodifiable(_clients);
  Map<String, ChatRoom> get chatRooms => Map.unmodifiable(_chatRooms);
  bool get quietMode => _quietMode;
  set quietMode(bool value) => _quietMode = value;
  String? get dataDir => _dataDir;

  /// Initialize relay server
  ///
  /// Uses StorageConfig for path management. StorageConfig must be initialized
  /// before calling this method.
  Future<void> initialize() async {
    final storageConfig = StorageConfig();
    if (!storageConfig.isInitialized) {
      throw StateError(
        'StorageConfig must be initialized before PureRelayServer. '
        'Call StorageConfig().init() first.',
      );
    }

    _dataDir = storageConfig.baseDir;
    _configPath = storageConfig.relayConfigPath;
    _tilesDirectory = storageConfig.tilesDir;

    // StorageConfig already creates directories, but ensure tiles exists
    await Directory(_tilesDirectory!).create(recursive: true);

    await _loadSettings();

    // Create default chat room
    _chatRooms['general'] = ChatRoom(
      id: 'general',
      name: 'General',
      description: 'General discussion',
      creatorCallsign: _settings.callsign,
    );

    _log('INFO', 'Pure Relay Server initialized');
    _log('INFO', 'Data directory: $_dataDir');
  }

  Future<void> _loadSettings() async {
    try {
      final configFile = File(_configPath!);
      if (await configFile.exists()) {
        final content = await configFile.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        _settings = PureRelaySettings.fromJson(json);
      }
    } catch (e) {
      _log('ERROR', 'Failed to load settings: $e');
    }
  }

  Future<void> saveSettings() async {
    try {
      final configFile = File(_configPath!);
      await configFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(_settings.toJson()),
      );
      _log('INFO', 'Settings saved');
    } catch (e) {
      _log('ERROR', 'Failed to save settings: $e');
    }
  }

  Future<void> reloadSettings() async {
    await _loadSettings();
    _log('INFO', 'Settings reloaded');
  }

  Future<void> updateSettings(PureRelaySettings settings) async {
    final wasRunning = _running;
    final oldPort = _settings.httpPort;

    _settings = settings;
    await saveSettings();

    if (wasRunning && oldPort != settings.httpPort) {
      await stop();
      await start();
    }
  }

  void setSetting(String key, dynamic value) {
    switch (key) {
      case 'httpPort':
        _settings = _settings.copyWith(httpPort: value as int);
        break;
      case 'httpsPort':
        _settings = _settings.copyWith(httpsPort: value as int);
        break;
      case 'callsign':
        _settings = _settings.copyWith(callsign: value as String);
        break;
      case 'description':
        _settings = _settings.copyWith(description: value as String);
        break;
      case 'location':
        _settings = _settings.copyWith(location: value as String);
        break;
      case 'tileServerEnabled':
        _settings = _settings.copyWith(tileServerEnabled: value as bool);
        break;
      case 'osmFallbackEnabled':
        _settings = _settings.copyWith(osmFallbackEnabled: value as bool);
        break;
      case 'maxZoomLevel':
        _settings = _settings.copyWith(maxZoomLevel: value as int);
        break;
      case 'maxCacheSizeMB':
        _settings = _settings.copyWith(maxCacheSizeMB: value as int);
        break;
      case 'enableAprs':
        _settings = _settings.copyWith(enableAprs: value as bool);
        break;
      case 'enableCors':
        _settings = _settings.copyWith(enableCors: value as bool);
        break;
      case 'maxConnectedDevices':
        _settings = _settings.copyWith(maxConnectedDevices: value as int);
        break;
      default:
        throw ArgumentError('Unknown setting: $key');
    }
  }

  Future<bool> start() async {
    if (_running) {
      _log('WARN', 'Relay server already running');
      return true;
    }

    try {
      // Start HTTP server
      _httpServer = await HttpServer.bind(
        InternetAddress.anyIPv4,
        _settings.httpPort,
        shared: true,
      );

      _running = true;
      _startTime = DateTime.now();

      _log('INFO', 'HTTP server started on port ${_settings.httpPort}');

      _httpServer!.listen(_handleRequest, onError: (error) {
        _log('ERROR', 'HTTP server error: $error');
      });

      // Start HTTPS server if SSL is enabled
      if (_settings.enableSsl) {
        await _startHttpsServer();
      }

      return true;
    } catch (e) {
      _log('ERROR', 'Failed to start relay server: $e');
      return false;
    }
  }

  /// Start HTTPS server with SSL certificates
  Future<void> _startHttpsServer() async {
    final certPath = _settings.sslCertPath;
    final keyPath = _settings.sslKeyPath;

    if (certPath == null || keyPath == null) {
      _log('WARN', 'SSL enabled but certificate paths not configured');
      return;
    }

    final certFile = File(certPath);
    final keyFile = File(keyPath);

    // Also check for fullchain.pem in ssl directory
    final sslDir = _dataDir != null ? '$_dataDir/ssl' : null;
    final fullchainPath = sslDir != null ? '$sslDir/fullchain.pem' : null;
    final fullchainFile = fullchainPath != null ? File(fullchainPath) : null;

    // Try fullchain first, then fall back to individual cert
    String? certToUse;
    if (fullchainFile != null && await fullchainFile.exists()) {
      certToUse = fullchainPath;
    } else if (await certFile.exists()) {
      certToUse = certPath;
    }

    if (certToUse == null || !await keyFile.exists()) {
      _log('WARN', 'SSL certificate files not found:');
      _log('WARN', '  Certificate: ${certToUse ?? certPath} (${certToUse != null ? "found" : "not found"})');
      _log('WARN', '  Key: $keyPath (${await keyFile.exists() ? "found" : "not found"})');
      return;
    }

    try {
      final context = SecurityContext()
        ..useCertificateChain(certToUse)
        ..usePrivateKey(keyPath);

      _httpsServer = await HttpServer.bindSecure(
        InternetAddress.anyIPv4,
        _settings.httpsPort,
        context,
        shared: true,
      );

      _log('INFO', 'HTTPS server started on port ${_settings.httpsPort}');

      _httpsServer!.listen(_handleRequest, onError: (error) {
        _log('ERROR', 'HTTPS server error: $error');
      });
    } catch (e) {
      _log('ERROR', 'Failed to start HTTPS server: $e');
      _log('ERROR', 'Certificate: $certToUse');
      _log('ERROR', 'Key: $keyPath');
    }
  }

  Future<void> stop() async {
    if (!_running) return;

    for (final client in _clients.values) {
      await client.socket.close();
    }
    _clients.clear();

    await _httpServer?.close(force: true);
    _httpServer = null;

    await _httpsServer?.close(force: true);
    _httpsServer = null;

    _running = false;
    _startTime = null;

    _log('INFO', 'Relay server stopped');
  }

  Future<void> restart() async {
    _log('INFO', 'Restarting relay server...');
    await stop();
    await Future.delayed(const Duration(milliseconds: 500));
    await start();
  }

  /// Kick a device by callsign
  bool kickDevice(String callsign) {
    final clientEntry = _clients.entries.firstWhere(
      (e) => e.value.callsign?.toLowerCase() == callsign.toLowerCase(),
      orElse: () => MapEntry('', PureConnectedClient(
        socket: WebSocket.fromUpgradedSocket(Socket.connect('localhost', 0) as dynamic),
        id: '',
      )),
    );

    if (clientEntry.key.isNotEmpty) {
      clientEntry.value.socket.close();
      _clients.remove(clientEntry.key);
      _log('INFO', 'Kicked device: $callsign');
      return true;
    }
    return false;
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
      try {
        client.socket.add(payload);
      } catch (e) {
        _log('ERROR', 'Failed to broadcast to ${client.callsign}: $e');
      }
    }
    _log('INFO', 'Broadcast sent to ${_clients.length} clients');
  }

  /// Scan network for devices
  Future<List<Map<String, dynamic>>> scanNetwork({int timeout = 2000}) async {
    final results = <Map<String, dynamic>>[];
    final localIps = await _getLocalIPs();

    for (final localIp in localIps) {
      final prefix = localIp.substring(0, localIp.lastIndexOf('.'));
      final futures = <Future<Map<String, dynamic>?>>[];

      for (int i = 1; i <= 254; i++) {
        final ip = '$prefix.$i';
        if (ip == localIp) continue;

        futures.add(_pingDevice(ip, 8080, timeout));
      }

      final scanResults = await Future.wait(futures);
      results.addAll(scanResults.whereType<Map<String, dynamic>>());
    }

    return results;
  }

  Future<List<String>> _getLocalIPs() async {
    final interfaces = await NetworkInterface.list();
    return interfaces
        .expand((i) => i.addresses)
        .where((a) => a.type == InternetAddressType.IPv4 && !a.isLoopback)
        .map((a) => a.address)
        .toList();
  }

  Future<Map<String, dynamic>?> _pingDevice(String ip, int port, int timeout) async {
    try {
      final response = await http.get(
        Uri.parse('http://$ip:$port/api/status'),
      ).timeout(Duration(milliseconds: timeout));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return {
          'ip': ip,
          'port': port,
          'callsign': data['callsign'] ?? 'Unknown',
          'type': data['relay_mode'] == true ? 'relay' : 'device',
          'version': data['version'] ?? 'Unknown',
          'name': data['name'] ?? 'Unknown',
        };
      }
    } catch (_) {}
    return null;
  }

  /// Ping a specific device
  Future<Map<String, dynamic>?> pingDevice(String address) async {
    final parts = address.split(':');
    final ip = parts[0];
    final port = parts.length > 1 ? int.tryParse(parts[1]) ?? 8080 : 8080;
    return _pingDevice(ip, port, 5000);
  }

  // Chat room management
  ChatRoom? createChatRoom(String id, String name, {String? description}) {
    if (_chatRooms.containsKey(id)) return null;

    final room = ChatRoom(
      id: id,
      name: name,
      description: description ?? '',
      creatorCallsign: _settings.callsign,
    );
    _chatRooms[id] = room;
    _log('INFO', 'Chat room created: $name ($id)');
    return room;
  }

  bool deleteChatRoom(String id) {
    if (id == 'general') return false; // Can't delete general
    if (_chatRooms.remove(id) != null) {
      _log('INFO', 'Chat room deleted: $id');
      return true;
    }
    return false;
  }

  bool renameChatRoom(String oldId, String newName) {
    final room = _chatRooms[oldId];
    if (room == null) return false;
    room.name = newName;
    _log('INFO', 'Chat room renamed: $oldId -> $newName');
    return true;
  }

  void postMessage(String roomId, String content) {
    final room = _chatRooms[roomId];
    if (room == null) return;

    final message = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      roomId: roomId,
      senderCallsign: _settings.callsign,
      content: content,
    );
    room.messages.add(message);
    room.lastActivity = DateTime.now();
    _stats.totalMessages++;
    _stats.lastMessage = DateTime.now();

    // Broadcast to connected clients
    final payload = jsonEncode({
      'type': 'chat_message',
      'room': roomId,
      'message': message.toJson(),
    });
    for (final client in _clients.values) {
      try {
        client.socket.add(payload);
      } catch (_) {}
    }
  }

  List<ChatMessage> getChatHistory(String roomId, {int limit = 20}) {
    final room = _chatRooms[roomId];
    if (room == null) return [];
    final messages = room.messages;
    if (messages.length <= limit) return messages;
    return messages.sublist(messages.length - limit);
  }

  bool deleteMessage(String roomId, String messageId) {
    final room = _chatRooms[roomId];
    if (room == null) return false;
    final idx = room.messages.indexWhere((m) => m.id == messageId);
    if (idx >= 0) {
      room.messages.removeAt(idx);
      return true;
    }
    return false;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final path = request.uri.path;
    final method = request.method;
    _stats.totalApiRequests++;

    try {
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        await _handleWebSocket(request);
        return;
      }

      if (_settings.enableCors) {
        request.response.headers.add('Access-Control-Allow-Origin', '*');
        request.response.headers.add('Access-Control-Allow-Methods', 'GET, POST, DELETE, OPTIONS');
        request.response.headers.add('Access-Control-Allow-Headers', 'Content-Type');
      }

      if (method == 'OPTIONS') {
        request.response.statusCode = 200;
        await request.response.close();
        return;
      }

      if (path == '/api/status' || path == '/status') {
        await _handleStatus(request);
      } else if (path == '/relay/status') {
        await _handleRelayStatus(request);
      } else if (path == '/api/stats') {
        await _handleStats(request);
      } else if (path == '/api/devices') {
        await _handleDevices(request);
      } else if (path.startsWith('/device/')) {
        await _handleDeviceProxy(request);
      } else if (path == '/search') {
        await _handleSearch(request);
      } else if (path == '/api/chat/rooms') {
        await _handleChatRooms(request);
      } else if (path.startsWith('/api/chat/rooms/') && path.endsWith('/messages')) {
        await _handleRoomMessages(request);
      } else if (path == '/api/relay/send' && method == 'POST') {
        await _handleRelaySend(request);
      } else if (path == '/api/groups') {
        await _handleGroups(request);
      } else if (path.startsWith('/api/groups/')) {
        await _handleGroupDetails(request);
      } else if (path.startsWith('/.well-known/acme-challenge/')) {
        await _handleAcmeChallenge(request);
      } else if (path.startsWith('/tiles/')) {
        _stats.totalTileRequests++;
        _stats.lastTileRequest = DateTime.now();
        await _handleTileRequest(request);
      } else if (path == '/api/cli' && method == 'POST') {
        await _handleCliCommand(request);
      } else if (path == '/') {
        await _handleRoot(request);
      } else if (_isCallsignPath(path)) {
        await _handleCallsignWww(request);
      } else {
        request.response.statusCode = 404;
        request.response.write('Not Found');
      }
    } catch (e) {
      _log('ERROR', 'Request error: $e');
      request.response.statusCode = 500;
      request.response.write('Internal Server Error');
    }

    await request.response.close();
  }

  Future<void> _handleWebSocket(HttpRequest request) async {
    try {
      final socket = await WebSocketTransformer.upgrade(request);
      final clientId = DateTime.now().millisecondsSinceEpoch.toString();
      final client = PureConnectedClient(
        socket: socket,
        id: clientId,
        address: request.connectionInfo?.remoteAddress.address,
      );

      _clients[clientId] = client;
      _stats.totalConnections++;
      _stats.lastConnection = DateTime.now();
      _log('INFO', 'WebSocket client connected: $clientId from ${client.address}');

      socket.listen(
        (data) => _handleWebSocketMessage(client, data),
        onDone: () {
          _clients.remove(clientId);
          _log('INFO', 'WebSocket client disconnected: ${client.callsign ?? clientId}');
        },
        onError: (error) {
          _log('ERROR', 'WebSocket error: $error');
          _clients.remove(clientId);
        },
      );
    } catch (e) {
      _log('ERROR', 'WebSocket upgrade failed: $e');
    }
  }

  void _handleWebSocketMessage(PureConnectedClient client, dynamic data) {
    try {
      client.lastActivity = DateTime.now();

      if (data is String) {
        final message = jsonDecode(data) as Map<String, dynamic>;
        final type = message['type'] as String?;

        switch (type) {
          case 'hello':
            // Extract client info - support both direct fields and Nostr event format
            String? callsign = message['callsign'] as String?;
            String? deviceType = message['device_type'] as String?;
            String? version = message['version'] as String?;

            // Check for Nostr event format (used by desktop/mobile clients)
            final event = message['event'] as Map<String, dynamic>?;
            if (event != null) {
              // Extract callsign from event tags: [['callsign', 'VALUE'], ...]
              final tags = event['tags'] as List<dynamic>?;
              if (tags != null) {
                for (final tag in tags) {
                  if (tag is List && tag.length >= 2 && tag[0] == 'callsign') {
                    callsign = tag[1] as String?;
                  }
                }
              }
              // Detect device type from content
              final content = event['content'] as String? ?? '';
              if (content.contains('Desktop')) {
                deviceType = 'desktop';
              } else if (content.contains('Mobile') || content.contains('Android') || content.contains('iOS')) {
                deviceType = 'mobile';
              } else {
                deviceType = 'client';
              }
            }

            client.callsign = callsign;
            client.deviceType = deviceType;
            client.version = version;

            final response = {
              'type': 'hello_response',
              'server': 'geogram-desktop-relay',
              'version': cliAppVersion,
              'callsign': _settings.callsign,
            };
            client.socket.add(jsonEncode(response));
            _log('INFO', 'Hello from: ${client.callsign ?? "unknown"} (${client.deviceType ?? "unknown"})');
            break;

          case 'PING':
            // Respond to PING with PONG
            final response = {
              'type': 'PONG',
              'timestamp': DateTime.now().millisecondsSinceEpoch,
            };
            client.socket.add(jsonEncode(response));
            break;

          case 'PONG':
            // Client responded to our ping - just update activity time
            break;

          case 'REGISTER':
            // Device registration with capabilities
            client.callsign = message['callsign'] as String?;
            client.deviceType = message['device_type'] as String?;
            client.version = message['version'] as String?;

            // Capabilities and collections are provided but not stored yet
            // Future: store these for device capability discovery
            // message['capabilities'] as List<dynamic>?;
            // message['collections'] as List<dynamic>?;

            final response = {
              'type': 'REGISTER_ACK',
              'success': true,
              'relay_callsign': _settings.callsign,
              'relay_version': cliAppVersion,
              'timestamp': DateTime.now().millisecondsSinceEpoch,
            };
            client.socket.add(jsonEncode(response));
            _log('INFO', 'Device registered: ${client.callsign} (${client.deviceType})');
            break;

          case 'HTTP_RESPONSE':
            // Response from device for a proxied HTTP request
            final requestId = message['requestId'] as String?;
            if (requestId != null && _pendingProxyRequests.containsKey(requestId)) {
              final completer = _pendingProxyRequests[requestId]!;
              if (!completer.isCompleted) {
                completer.complete(message);
              }
            }
            break;

          case 'COLLECTIONS_REQUEST':
            // Request for device's collections
            final targetCallsign = message['callsign'] as String?;
            if (targetCallsign != null) {
              // Forward to the target device
              final targetClient = _clients.values.firstWhere(
                (c) => c.callsign?.toLowerCase() == targetCallsign.toLowerCase(),
                orElse: () => PureConnectedClient(socket: null as dynamic, id: ''),
              );

              if (targetClient.id.isNotEmpty) {
                final forwardMsg = {
                  'type': 'COLLECTIONS_REQUEST',
                  'from': client.callsign,
                  'requestId': message['requestId'],
                };
                targetClient.socket.add(jsonEncode(forwardMsg));
              } else {
                // Device not connected
                final errorResponse = {
                  'type': 'COLLECTIONS_RESPONSE',
                  'requestId': message['requestId'],
                  'error': 'Device not connected',
                  'callsign': targetCallsign,
                };
                client.socket.add(jsonEncode(errorResponse));
              }
            }
            break;

          case 'COLLECTIONS_RESPONSE':
            // Forward collection response to the requester
            final fromCallsign = message['from'] as String?;
            if (fromCallsign != null) {
              final requester = _clients.values.firstWhere(
                (c) => c.callsign?.toLowerCase() == fromCallsign.toLowerCase(),
                orElse: () => PureConnectedClient(socket: null as dynamic, id: ''),
              );
              if (requester.id.isNotEmpty) {
                requester.socket.add(data);
              }
            }
            break;

          case 'chat_message':
            final roomId = message['room'] as String? ?? 'general';
            final content = message['content'] as String?;
            if (content != null && client.callsign != null) {
              final room = _chatRooms[roomId];
              if (room != null) {
                final msg = ChatMessage(
                  id: message['event_id'] as String? ?? DateTime.now().millisecondsSinceEpoch.toString(),
                  roomId: roomId,
                  senderCallsign: client.callsign!,
                  senderNpub: message['npub'] as String?,
                  senderPubkey: message['pubkey'] as String?,
                  signature: message['signature'] as String?,
                  content: content,
                );
                room.messages.add(msg);
                room.lastActivity = DateTime.now();
                _stats.totalMessages++;
                _stats.lastMessage = DateTime.now();

                // Broadcast to other clients
                final payload = jsonEncode({
                  'type': 'chat_message',
                  'room': roomId,
                  'message': msg.toJson(),
                });
                for (final c in _clients.values) {
                  if (c.id != client.id) {
                    try {
                      c.socket.add(payload);
                    } catch (_) {}
                  }
                }
              }
            }
            break;
        }
      }
    } catch (e) {
      _log('ERROR', 'WebSocket message error: $e');
    }
  }

  Future<void> _handleStatus(HttpRequest request) async {
    final uptime = _startTime != null
        ? DateTime.now().difference(_startTime!).inSeconds
        : 0;

    final status = {
      'service': 'Geogram Relay Server',
      'name': 'Geogram Desktop Relay',
      'version': cliAppVersion,
      'callsign': _settings.callsign,
      'description': _settings.description ?? 'Geogram Desktop Relay Server',
      'connected_devices': _clients.length,
      'uptime': uptime,
      'relay_mode': true,
      'location': _settings.location,
      'latitude': _settings.latitude,
      'longitude': _settings.longitude,
      'tile_server': _settings.tileServerEnabled,
      'osm_fallback': _settings.osmFallbackEnabled,
      'cache_size': _tileCache.size,
      'cache_size_bytes': _tileCache.sizeBytes,
      'enable_aprs': _settings.enableAprs,
      'chat_rooms': _chatRooms.length,
      'http_port': _settings.httpPort,
      'https_enabled': _settings.enableSsl,
      'https_port': _settings.enableSsl ? _settings.httpsPort : null,
      'https_running': _httpsServer != null,
    };

    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(status));
  }

  Future<void> _handleStats(HttpRequest request) async {
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(_stats.toJson()));
  }

  Future<void> _handleDevices(HttpRequest request) async {
    final devices = _clients.values.map((c) => c.toJson()).toList();
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'devices': devices}));
  }

  /// GET /relay/status - List connected devices and relays
  Future<void> _handleRelayStatus(HttpRequest request) async {
    final devices = _clients.values
        .where((c) => c.deviceType != 'relay')
        .map((c) => {
              'callsign': c.callsign,
              'uptime_seconds': DateTime.now().difference(c.connectedAt).inSeconds,
              'idle_seconds': DateTime.now().difference(c.lastActivity).inSeconds,
              'connected_at': c.connectedAt.toIso8601String(),
            })
        .toList();

    final relays = _clients.values
        .where((c) => c.deviceType == 'relay')
        .map((c) => {
              'callsign': c.callsign,
              'uptime_seconds': DateTime.now().difference(c.connectedAt).inSeconds,
              'connected_at': c.connectedAt.toIso8601String(),
            })
        .toList();

    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({
      'connected_devices': devices.length,
      'connected_relays': relays.length,
      'devices': devices,
      'relays': relays,
    }));
  }

  /// Handle /device/{callsign} and /device/{callsign}/* requests
  Future<void> _handleDeviceProxy(HttpRequest request) async {
    final path = request.uri.path;
    final parts = path.substring('/device/'.length).split('/');
    final callsign = parts.first;
    final subPath = parts.length > 1 ? '/${parts.sublist(1).join('/')}' : '';

    // Find the client by callsign
    PureConnectedClient? foundClient;
    for (final c in _clients.values) {
      if (c.callsign?.toLowerCase() == callsign.toLowerCase()) {
        foundClient = c;
        break;
      }
    }

    if (foundClient == null) {
      request.response.statusCode = 404;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'callsign': callsign,
        'connected': false,
        'error': 'Device not connected',
      }));
      return;
    }

    final client = foundClient;

    // If just /device/{callsign} with no subpath, return device info
    if (subPath.isEmpty) {
      final uptime = DateTime.now().difference(client.connectedAt).inSeconds;
      final idleTime = DateTime.now().difference(client.lastActivity).inSeconds;

      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'callsign': client.callsign,
        'connected': true,
        'uptime': uptime,
        'idleTime': idleTime,
        'deviceType': client.deviceType,
        'version': client.version,
        'address': client.address,
      }));
      return;
    }

    // Proxy request to device via WebSocket
    final requestId = DateTime.now().millisecondsSinceEpoch.toString();
    final proxyRequest = {
      'type': 'HTTP_REQUEST',
      'requestId': requestId,
      'method': request.method,
      'path': subPath,
      'headers': request.headers.toString(),
      'body': '',
    };

    // Read request body if present
    if (request.contentLength > 0) {
      final body = await utf8.decodeStream(request);
      proxyRequest['body'] = body;
    }

    // Send request to device and wait for response
    final completer = Completer<Map<String, dynamic>>();
    _pendingProxyRequests[requestId] = completer;

    try {
      client.socket.add(jsonEncode(proxyRequest));

      // Wait for response with timeout
      final response = await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => {
          'type': 'HTTP_RESPONSE',
          'statusCode': 504,
          'responseBody': 'Gateway Timeout',
        },
      );

      request.response.statusCode = response['statusCode'] ?? 500;
      if (response['responseHeaders'] != null) {
        try {
          final headers = jsonDecode(response['responseHeaders'] as String) as Map<String, dynamic>;
          headers.forEach((key, value) {
            request.response.headers.add(key, value.toString());
          });
        } catch (_) {}
      }

      final body = response['responseBody'] ?? '';
      final isBase64 = response['isBase64'] == true;
      if (isBase64) {
        request.response.add(base64Decode(body));
      } else {
        request.response.write(body);
      }
    } catch (e) {
      request.response.statusCode = 502;
      request.response.write('Bad Gateway: $e');
    } finally {
      _pendingProxyRequests.remove(requestId);
    }
  }

  /// GET /search - Search across connected devices
  Future<void> _handleSearch(HttpRequest request) async {
    final query = request.uri.queryParameters['q'];
    final limitStr = request.uri.queryParameters['limit'];
    final limit = limitStr != null ? int.tryParse(limitStr) ?? 50 : 50;

    if (query == null || query.isEmpty) {
      request.response.statusCode = 400;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': "Missing query parameter 'q'"}));
      return;
    }

    // For now, return empty results - full implementation would search device collections
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({
      'query': query,
      'total_results': 0,
      'limit': limit,
      'results': [],
    }));
  }

  /// POST /api/relay/send - Send NOSTR-signed message from relay
  Future<void> _handleRelaySend(HttpRequest request) async {
    try {
      final body = await utf8.decodeStream(request);
      final data = jsonDecode(body) as Map<String, dynamic>;

      final room = data['room'] as String? ?? 'general';
      final content = data['content'] as String?;
      final callsign = data['callsign'] as String? ?? _settings.callsign;

      if (content == null || content.isEmpty) {
        request.response.statusCode = 400;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Missing content'}));
        return;
      }

      final chatRoom = _chatRooms[room];
      if (chatRoom == null) {
        request.response.statusCode = 404;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Room not found'}));
        return;
      }

      final msg = ChatMessage(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        roomId: room,
        senderCallsign: callsign,
        content: content,
      );
      chatRoom.messages.add(msg);
      chatRoom.lastActivity = DateTime.now();
      _stats.totalMessages++;

      // Broadcast to connected clients
      final payload = jsonEncode({
        'type': 'chat_message',
        'room': room,
        'message': msg.toJson(),
      });

      int notified = 0;
      for (final client in _clients.values) {
        try {
          client.socket.add(payload);
          notified++;
        } catch (_) {}
      }

      request.response.statusCode = 201;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'success': true,
        'message': 'Message sent',
        'room': room,
        'callsign': callsign,
        'content': content,
        'devices_notified': notified,
        'connected_devices': _clients.length,
      }));
    } catch (e) {
      request.response.statusCode = 400;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Invalid request: $e'}));
    }
  }

  /// GET /api/groups - List all groups
  Future<void> _handleGroups(HttpRequest request) async {
    // Groups are not yet implemented - return empty list
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({
      'relay': _settings.callsign,
      'groups': [],
      'count': 0,
    }));
  }

  /// GET /api/groups/{groupId} or /api/groups/{groupId}/members
  Future<void> _handleGroupDetails(HttpRequest request) async {
    final path = request.uri.path;
    final groupId = path.replaceFirst('/api/groups/', '').split('/').first;

    // Groups are not yet implemented
    request.response.statusCode = 404;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({
      'error': 'Group not found',
      'groupId': groupId,
    }));
  }

  /// ACME challenge tokens for Let's Encrypt
  final Map<String, String> _acmeChallenges = {};

  /// Set an ACME challenge token
  void setAcmeChallenge(String token, String response) {
    _acmeChallenges[token] = response;
  }

  /// Clear an ACME challenge token
  void clearAcmeChallenge(String token) {
    _acmeChallenges.remove(token);
  }

  /// GET /.well-known/acme-challenge/{token}
  Future<void> _handleAcmeChallenge(HttpRequest request) async {
    final token = request.uri.path.replaceFirst('/.well-known/acme-challenge/', '');
    final response = _acmeChallenges[token];

    if (response != null) {
      request.response.headers.contentType = ContentType.text;
      request.response.write(response);
    } else {
      request.response.statusCode = 404;
      request.response.write('Not Found');
    }
  }

  /// Check if path looks like a callsign for WWW serving
  bool _isCallsignPath(String path) {
    if (path.length < 2) return false;
    final firstPart = path.substring(1).split('/').first;
    // Callsigns are typically X followed by numbers/letters
    return RegExp(r'^X[0-9][A-Z0-9]{3,}$', caseSensitive: false).hasMatch(firstPart);
  }

  /// GET /{callsign} or /{callsign}/* - Serve WWW collection from device
  Future<void> _handleCallsignWww(HttpRequest request) async {
    final path = request.uri.path;
    final parts = path.substring(1).split('/');
    final callsign = parts.first;
    final filePath = parts.length > 1 ? parts.sublist(1).join('/') : 'index.html';

    // Find the client by callsign
    PureConnectedClient? foundClient;
    for (final c in _clients.values) {
      if (c.callsign?.toLowerCase() == callsign.toLowerCase()) {
        foundClient = c;
        break;
      }
    }

    if (foundClient == null) {
      request.response.statusCode = 404;
      request.response.write('Device not connected');
      return;
    }

    final client = foundClient;

    // Proxy to device's www collection
    final requestId = DateTime.now().millisecondsSinceEpoch.toString();
    final proxyRequest = {
      'type': 'HTTP_REQUEST',
      'requestId': requestId,
      'method': 'GET',
      'path': '/collections/www/$filePath',
      'headers': '',
      'body': '',
    };

    final completer = Completer<Map<String, dynamic>>();
    _pendingProxyRequests[requestId] = completer;

    try {
      client.socket.add(jsonEncode(proxyRequest));

      final response = await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => {'statusCode': 504, 'responseBody': 'Gateway Timeout'},
      );

      request.response.statusCode = response['statusCode'] ?? 500;
      final body = response['responseBody'] ?? '';
      final isBase64 = response['isBase64'] == true;

      // Set content type based on file extension
      final ext = filePath.split('.').last.toLowerCase();
      final contentTypes = {
        'html': 'text/html',
        'htm': 'text/html',
        'css': 'text/css',
        'js': 'application/javascript',
        'json': 'application/json',
        'png': 'image/png',
        'jpg': 'image/jpeg',
        'jpeg': 'image/jpeg',
        'gif': 'image/gif',
        'svg': 'image/svg+xml',
        'ico': 'image/x-icon',
        'txt': 'text/plain',
      };
      final contentType = contentTypes[ext] ?? 'application/octet-stream';
      request.response.headers.set('Content-Type', contentType);

      if (isBase64) {
        request.response.add(base64Decode(body));
      } else {
        request.response.write(body);
      }
    } catch (e) {
      request.response.statusCode = 502;
      request.response.write('Bad Gateway: $e');
    } finally {
      _pendingProxyRequests.remove(requestId);
    }
  }

  /// Pending proxy requests waiting for device response
  final Map<String, Completer<Map<String, dynamic>>> _pendingProxyRequests = {};

  Future<void> _handleRoot(HttpRequest request) async {
    final uptime = _startTime != null
        ? DateTime.now().difference(_startTime!).inSeconds
        : 0;

    request.response.headers.contentType = ContentType.html;
    request.response.write('''
<!DOCTYPE html>
<html>
<head>
  <title>Geogram Desktop Relay</title>
  <style>
    body { font-family: sans-serif; padding: 20px; max-width: 800px; margin: 0 auto; background: #1a1a2e; color: #eee; }
    h1 { color: #00d9ff; }
    .info { background: #16213e; padding: 15px; border-radius: 5px; margin: 10px 0; }
    .info p { margin: 5px 0; }
    a { color: #00d9ff; }
    .stat { display: inline-block; margin-right: 20px; }
    .stat-value { font-size: 24px; font-weight: bold; color: #00d9ff; }
    .stat-label { font-size: 12px; color: #888; }
  </style>
</head>
<body>
  <h1>Geogram Desktop Relay</h1>
  <div class="info">
    <p><strong>Callsign:</strong> ${_settings.callsign}</p>
    <p><strong>Version:</strong> $cliAppVersion</p>
    <p><strong>Description:</strong> ${_settings.description ?? 'Geogram Desktop Relay Server'}</p>
  </div>
  <div class="info">
    <div class="stat"><div class="stat-value">${_clients.length}</div><div class="stat-label">Connected Devices</div></div>
    <div class="stat"><div class="stat-value">${_chatRooms.length}</div><div class="stat-label">Chat Rooms</div></div>
    <div class="stat"><div class="stat-value">${_formatUptimeShort(uptime)}</div><div class="stat-label">Uptime</div></div>
    <div class="stat"><div class="stat-value">${_tileCache.size}</div><div class="stat-label">Cached Tiles</div></div>
  </div>
  <div class="info">
    <p><strong>API Endpoints:</strong></p>
    <p><a href="/api/status">/api/status</a> - Server status</p>
    <p><a href="/api/stats">/api/stats</a> - Server statistics</p>
    <p><a href="/api/devices">/api/devices</a> - Connected devices</p>
    <p><a href="/api/chat/rooms">/api/chat/rooms</a> - Chat rooms</p>
  </div>
</body>
</html>
''');
  }

  String _formatUptimeShort(int seconds) {
    if (seconds < 60) return '${seconds}s';
    if (seconds < 3600) return '${seconds ~/ 60}m';
    if (seconds < 86400) return '${seconds ~/ 3600}h';
    return '${seconds ~/ 86400}d';
  }

  Future<void> _handleChatRooms(HttpRequest request) async {
    if (request.method == 'GET') {
      final rooms = _chatRooms.values.map((r) => r.toJson()).toList();
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'relay': _settings.callsign,
        'rooms': rooms,
      }));
    } else if (request.method == 'POST') {
      final body = await utf8.decoder.bind(request).join();
      final data = jsonDecode(body) as Map<String, dynamic>;
      final id = data['id'] as String?;
      final name = data['name'] as String?;
      if (id != null && name != null) {
        final room = createChatRoom(id, name, description: data['description'] as String?);
        if (room != null) {
          request.response.statusCode = 201;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(room.toJson()));
        } else {
          request.response.statusCode = 409;
          request.response.write('Room already exists');
        }
      } else {
        request.response.statusCode = 400;
        request.response.write('Missing id or name');
      }
    }
  }

  Future<void> _handleRoomMessages(HttpRequest request) async {
    final path = request.uri.path;
    final parts = path.split('/');
    final roomId = parts.length > 4 ? parts[4] : 'general';

    final room = _chatRooms[roomId];
    if (room == null) {
      request.response.statusCode = 404;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Room not found'}));
      return;
    }

    if (request.method == 'GET') {
      final limit = int.tryParse(request.uri.queryParameters['limit'] ?? '50') ?? 50;
      final messages = getChatHistory(roomId, limit: limit).map((m) => m.toJson()).toList();
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'room_id': roomId,
        'room_name': room.name,
        'messages': messages,
        'count': messages.length,
      }));
    } else if (request.method == 'POST') {
      try {
        final body = await utf8.decoder.bind(request).join();
        final data = jsonDecode(body) as Map<String, dynamic>;

        final callsign = data['callsign'] as String?;
        final content = data['content'] as String?;

        if (callsign == null || callsign.isEmpty) {
          request.response.statusCode = 400;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'error': 'Missing callsign'}));
          return;
        }

        if (content == null || content.isEmpty) {
          request.response.statusCode = 400;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'error': 'Missing content'}));
          return;
        }

        // Optional NOSTR fields
        final npub = data['npub'] as String?;
        final pubkey = data['pubkey'] as String?;
        final eventId = data['event_id'] as String?;
        final signature = data['signature'] as String?;
        final createdAt = data['created_at'] as int?;

        // Create message
        final msg = ChatMessage(
          id: eventId ?? DateTime.now().millisecondsSinceEpoch.toString(),
          roomId: roomId,
          senderCallsign: callsign,
          senderNpub: npub,
          senderPubkey: pubkey,
          signature: signature,
          content: content,
          timestamp: createdAt != null
              ? DateTime.fromMillisecondsSinceEpoch(createdAt * 1000)
              : DateTime.now(),
        );

        room.messages.add(msg);
        room.lastActivity = DateTime.now();
        _stats.totalMessages++;
        _stats.lastMessage = DateTime.now();

        // Broadcast to connected WebSocket clients
        final payload = jsonEncode({
          'type': 'chat_message',
          'room': roomId,
          'message': msg.toJson(),
        });
        for (final client in _clients.values) {
          try {
            client.socket.add(payload);
          } catch (_) {}
        }

        request.response.statusCode = 201;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'success': true,
          'message': 'Message posted',
        }));
      } catch (e) {
        request.response.statusCode = 400;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Invalid request: $e'}));
      }
    }
  }

  Future<void> _handleCliCommand(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final command = data['command'] as String?;

    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({
      'status': 'ok',
      'command': command,
      'message': 'CLI commands not yet implemented via API',
    }));
  }

  Future<void> _handleTileRequest(HttpRequest request) async {
    if (!_settings.tileServerEnabled) {
      request.response.statusCode = 404;
      request.response.write('Tile server disabled');
      return;
    }

    final path = request.uri.path;
    final regex = RegExp(r'/tiles/([^/]+)/(\d+)/(\d+)/(\d+)\.png');
    final match = regex.firstMatch(path);

    if (match == null) {
      request.response.statusCode = 400;
      request.response.write('Invalid tile path');
      return;
    }

    final z = int.parse(match.group(2)!);
    final x = int.parse(match.group(3)!);
    final y = int.parse(match.group(4)!);

    final layer = request.uri.queryParameters['layer'] ?? 'standard';
    final isSatellite = layer.toLowerCase() == 'satellite';

    if (z < 0 || z > 18) {
      request.response.statusCode = 400;
      request.response.write('Invalid zoom level');
      return;
    }

    final cacheKey = '$layer/$z/$x/$y';
    var tileData = _tileCache.get(cacheKey);

    if (tileData != null) {
      _stats.tilesServedFromCache++;
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.add(tileData);
      return;
    }

    final diskPath = '$_tilesDirectory/$layer/$z/$x/$y.png';
    final diskFile = File(diskPath);
    if (await diskFile.exists()) {
      tileData = await diskFile.readAsBytes();
      _tileCache.put(cacheKey, tileData);
      _stats.tilesServedFromCache++;
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.add(tileData);
      return;
    }

    if (_settings.osmFallbackEnabled) {
      tileData = await _fetchTileFromInternet(z, x, y, isSatellite);

      if (tileData != null) {
        _stats.tilesDownloaded++;
        if (z <= _settings.maxZoomLevel) {
          _tileCache.put(cacheKey, tileData);
          _stats.tilesCached++;
        }
        await _saveTileToDisk(diskPath, tileData);

        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(tileData);
        return;
      }
    }

    request.response.statusCode = 404;
    request.response.write('Tile not found');
  }

  Future<Uint8List?> _fetchTileFromInternet(int z, int x, int y, bool satellite) async {
    try {
      final url = satellite
          ? 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/$z/$y/$x'
          : 'https://tile.openstreetmap.org/$z/$x/$y.png';

      final response = await http.get(
        Uri.parse(url),
        headers: {'User-Agent': 'Geogram-Desktop-Relay/$cliAppVersion'},
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = Uint8List.fromList(response.bodyBytes);
        if (PureTileCache.isValidImageData(data)) {
          return data;
        }
      }
    } catch (e) {
      _log('ERROR', 'Failed to fetch tile: $e');
    }
    return null;
  }

  Future<void> _saveTileToDisk(String path, Uint8List data) async {
    try {
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data);
    } catch (e) {
      _log('ERROR', 'Failed to save tile to disk: $e');
    }
  }

  Map<String, dynamic> getStatus() {
    final uptime = _startTime != null
        ? DateTime.now().difference(_startTime!).inSeconds
        : 0;

    return {
      'running': _running,
      'httpPort': _settings.httpPort,
      'httpsPort': _settings.httpsPort,
      'callsign': _settings.callsign,
      'connected_devices': _clients.length,
      'uptime': uptime,
      'cache_size': _tileCache.size,
      'cache_size_mb': (_tileCache.sizeBytes / (1024 * 1024)).toStringAsFixed(2),
      'chat_rooms': _chatRooms.length,
      'total_messages': _stats.totalMessages,
    };
  }

  void clearCache() {
    _tileCache.clear();
    _log('INFO', 'Tile cache cleared');
  }

  List<LogEntry> getLogs({int limit = 20}) {
    if (_logs.length <= limit) return _logs;
    return _logs.sublist(_logs.length - limit);
  }

  void _log(String level, String message) {
    final entry = LogEntry(DateTime.now(), level, message);
    _logs.add(entry);
    if (_logs.length > maxLogEntries) {
      _logs.removeAt(0);
    }
    if (!_quietMode) {
      stderr.writeln(entry.toString());
    }
  }
}

/// SSL Certificate Manager for Let's Encrypt
class SslCertificateManager {
  PureRelaySettings _settings;
  final String _sslDir;

  /// Update settings reference (called when relay settings change)
  void updateSettings(PureRelaySettings newSettings) {
    _settings = newSettings;
  }

  /// Get current settings
  PureRelaySettings get settings => _settings;
  Timer? _renewalTimer;
  final Map<String, String> _challengeResponses = {};

  // Certificate file paths
  String get accountKeyPath => '$_sslDir/account.key';
  String get domainKeyPath => '$_sslDir/domain.key';
  String get certPath => '$_sslDir/certificate.crt';
  String get chainPath => '$_sslDir/certificate-chain.crt';
  String get fullChainPath => '$_sslDir/fullchain.pem';

  // Let's Encrypt ACME endpoints
  static const String productionAcme = 'https://acme-v02.api.letsencrypt.org/directory';
  static const String stagingAcme = 'https://acme-staging-v02.api.letsencrypt.org/directory';

  SslCertificateManager(PureRelaySettings settings, String dataDir)
      : _settings = settings,
        _sslDir = '$dataDir/ssl';

  /// Initialize SSL directory
  Future<void> initialize() async {
    await Directory(_sslDir).create(recursive: true);
  }

  /// Start auto-renewal timer (check every 12 hours)
  void startAutoRenewal() {
    if (!settings.sslAutoRenew) return;

    _renewalTimer?.cancel();
    _renewalTimer = Timer.periodic(const Duration(hours: 12), (_) async {
      await checkAndRenew();
    });
  }

  /// Stop auto-renewal timer
  void stop() {
    _renewalTimer?.cancel();
    _renewalTimer = null;
  }

  /// Check if certificate exists and is valid
  bool hasCertificate() {
    final certFile = File(certPath);
    return certFile.existsSync();
  }

  /// Get certificate info
  Future<Map<String, dynamic>> getStatus() async {
    final status = <String, dynamic>{
      'domain': settings.sslDomain ?? '(not set)',
      'email': settings.sslEmail ?? '(not set)',
      'enabled': settings.enableSsl,
      'autoRenew': settings.sslAutoRenew,
      'hasCertificate': hasCertificate(),
    };

    if (hasCertificate()) {
      final certInfo = await _getCertificateInfo();
      status.addAll(certInfo);
    }

    return status;
  }

  /// Get certificate expiration info
  Future<Map<String, dynamic>> _getCertificateInfo() async {
    try {
      // Read certificate and parse expiration
      final certFile = File(certPath);
      if (!await certFile.exists()) {
        return {'error': 'Certificate file not found'};
      }

      final certPem = await certFile.readAsString();

      // Parse the certificate to extract expiration date
      // This is a simplified check - in production you'd use proper X509 parsing
      final expiry = _parseCertificateExpiry(certPem);

      if (expiry != null) {
        final now = DateTime.now();
        final daysUntilExpiry = expiry.difference(now).inDays;

        return {
          'expiresAt': expiry.toIso8601String(),
          'daysUntilExpiry': daysUntilExpiry,
          'isValid': daysUntilExpiry > 0,
          'certPath': certPath,
        };
      }

      return {
        'certPath': certPath,
        'status': 'Certificate exists but could not parse expiry',
      };
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  /// Parse certificate expiry from PEM (simplified)
  DateTime? _parseCertificateExpiry(String pemCert) {
    // This would need proper X509 parsing in production
    // For now, return null and rely on file existence
    return null;
  }

  /// Check and renew if needed (30 days before expiry)
  Future<bool> checkAndRenew() async {
    if (!hasCertificate()) return false;

    final info = await _getCertificateInfo();
    final daysUntilExpiry = info['daysUntilExpiry'] as int?;

    if (daysUntilExpiry != null && daysUntilExpiry <= 30) {
      return await renewCertificate(staging: false);
    }

    return true;
  }

  /// Request new certificate
  Future<bool> requestCertificate({bool staging = false}) async {
    if (settings.sslDomain == null || settings.sslDomain!.isEmpty) {
      throw Exception('Domain not configured. Use: ssl domain <domain>');
    }

    if (settings.sslEmail == null || settings.sslEmail!.isEmpty) {
      throw Exception('Email not configured. Use: ssl email <email>');
    }

    final acmeUrl = staging ? stagingAcme : productionAcme;

    try {
      // Step 1: Generate account key if not exists
      if (!File(accountKeyPath).existsSync()) {
        await _generateKey(accountKeyPath);
      }

      // Step 2: Generate domain key if not exists
      if (!File(domainKeyPath).existsSync()) {
        await _generateKey(domainKeyPath);
      }

      // Step 3: Request certificate using ACME protocol
      // Note: This is a simplified implementation
      // In production, you'd use a proper ACME client library

      final result = await _requestWithAcme(
        acmeUrl: acmeUrl,
        domain: settings.sslDomain!,
        email: settings.sslEmail!,
        staging: staging,
      );

      return result;
    } catch (e) {
      rethrow;
    }
  }

  /// Renew existing certificate
  Future<bool> renewCertificate({bool staging = false}) async {
    return await requestCertificate(staging: staging);
  }

  /// Generate RSA key using openssl
  Future<void> _generateKey(String keyPath) async {
    final result = await Process.run('openssl', [
      'genrsa',
      '-out', keyPath,
      '4096',
    ]);

    if (result.exitCode != 0) {
      throw Exception('Failed to generate key: ${result.stderr}');
    }
  }

  // Reference to relay server for challenge handling
  PureRelayServer? _relayServer;

  /// Set relay server reference for ACME challenge handling
  void setRelayServer(PureRelayServer server) {
    _relayServer = server;
  }

  /// Request certificate using native ACME protocol implementation
  /// Works on all platforms (Linux, Windows, macOS, Android)
  Future<bool> _requestWithAcme({
    required String acmeUrl,
    required String domain,
    required String email,
    required bool staging,
  }) async {
    stdout.writeln('Starting ACME certificate request...');
    stdout.writeln('Domain: $domain');
    stdout.writeln('Email: $email');
    stdout.writeln('Environment: ${staging ? "staging" : "production"}');
    stdout.writeln('');

    try {
      // Step 1: Get ACME directory
      stdout.writeln('[1/7] Fetching ACME directory...');
      final directory = await _fetchAcmeDirectory(acmeUrl);

      // Step 2: Generate or load account key
      stdout.writeln('[2/7] Loading/generating account key...');
      final accountKey = await _loadOrGenerateAccountKey();

      // Step 3: Create/fetch ACME account
      stdout.writeln('[3/7] Creating ACME account...');
      final accountUrl = await _createAcmeAccount(
        directory: directory,
        accountKey: accountKey,
        email: email,
      );

      // Step 4: Create new order
      stdout.writeln('[4/7] Creating certificate order...');
      final order = await _createOrder(
        directory: directory,
        accountKey: accountKey,
        accountUrl: accountUrl,
        domain: domain,
      );

      // Step 5: Complete HTTP-01 challenges
      stdout.writeln('[5/7] Completing HTTP-01 challenge...');
      await _completeHttpChallenge(
        directory: directory,
        accountKey: accountKey,
        accountUrl: accountUrl,
        order: order,
        domain: domain,
      );

      // Step 6: Finalize order with CSR
      stdout.writeln('[6/7] Finalizing order...');
      await _finalizeOrder(
        directory: directory,
        accountKey: accountKey,
        accountUrl: accountUrl,
        order: order,
        domain: domain,
      );

      // Step 7: Download certificate
      stdout.writeln('[7/7] Downloading certificate...');
      await _downloadCertificate(
        directory: directory,
        accountKey: accountKey,
        accountUrl: accountUrl,
        order: order,
      );

      stdout.writeln('');
      stdout.writeln('Certificate successfully obtained!');
      return true;
    } catch (e) {
      stdout.writeln('ACME request failed: $e');
      rethrow;
    }
  }

  /// Fetch ACME directory
  Future<Map<String, dynamic>> _fetchAcmeDirectory(String url) async {
    final response = await http.get(Uri.parse(url));
    if (response.statusCode != 200) {
      throw Exception('Failed to fetch ACME directory: ${response.statusCode}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// Load existing account key or generate new one
  Future<Map<String, dynamic>> _loadOrGenerateAccountKey() async {
    final keyFile = File(accountKeyPath);

    if (await keyFile.exists()) {
      // Parse existing PEM key
      final pem = await keyFile.readAsString();
      return _parsePrivateKeyPem(pem);
    }

    // Generate new key using openssl (more reliable cross-platform)
    await _generateKey(accountKeyPath);
    final pem = await keyFile.readAsString();
    return _parsePrivateKeyPem(pem);
  }

  /// Parse PEM private key and extract components for JWK
  Map<String, dynamic> _parsePrivateKeyPem(String pem) {
    // For ACME, we need the key in a format we can use for JWS signing
    // We'll use openssl to extract the public key components
    return {
      'pem': pem,
      'path': accountKeyPath,
    };
  }

  /// Create ACME account
  Future<String> _createAcmeAccount({
    required Map<String, dynamic> directory,
    required Map<String, dynamic> accountKey,
    required String email,
  }) async {
    final newAccountUrl = directory['newAccount'] as String;
    final newNonceUrl = directory['newNonce'] as String;

    // Get initial nonce
    final nonceResponse = await http.head(Uri.parse(newNonceUrl));
    var nonce = nonceResponse.headers['replay-nonce'] ?? '';

    // Create account request
    final payload = {
      'termsOfServiceAgreed': true,
      'contact': ['mailto:$email'],
    };

    final response = await _signedAcmeRequest(
      url: newAccountUrl,
      payload: payload,
      accountKey: accountKey,
      nonce: nonce,
      useJwk: true,
    );

    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception('Failed to create ACME account: ${response.statusCode} ${response.body}');
    }

    // Account URL is in Location header
    final accountUrl = response.headers['location'];
    if (accountUrl == null) {
      throw Exception('No account URL in response');
    }

    return accountUrl;
  }

  /// Create new certificate order
  Future<Map<String, dynamic>> _createOrder({
    required Map<String, dynamic> directory,
    required Map<String, dynamic> accountKey,
    required String accountUrl,
    required String domain,
  }) async {
    final newOrderUrl = directory['newOrder'] as String;
    final newNonceUrl = directory['newNonce'] as String;

    final nonceResponse = await http.head(Uri.parse(newNonceUrl));
    var nonce = nonceResponse.headers['replay-nonce'] ?? '';

    final payload = {
      'identifiers': [
        {'type': 'dns', 'value': domain}
      ],
    };

    final response = await _signedAcmeRequest(
      url: newOrderUrl,
      payload: payload,
      accountKey: accountKey,
      accountUrl: accountUrl,
      nonce: nonce,
    );

    if (response.statusCode != 201) {
      throw Exception('Failed to create order: ${response.statusCode} ${response.body}');
    }

    final order = jsonDecode(response.body) as Map<String, dynamic>;
    order['url'] = response.headers['location'];
    return order;
  }

  /// Complete HTTP-01 challenge
  Future<void> _completeHttpChallenge({
    required Map<String, dynamic> directory,
    required Map<String, dynamic> accountKey,
    required String accountUrl,
    required Map<String, dynamic> order,
    required String domain,
  }) async {
    final authorizations = order['authorizations'] as List;
    final newNonceUrl = directory['newNonce'] as String;

    for (final authzUrl in authorizations) {
      // Fetch authorization
      var nonceResponse = await http.head(Uri.parse(newNonceUrl));
      var nonce = nonceResponse.headers['replay-nonce'] ?? '';

      final authzResponse = await _signedAcmeRequest(
        url: authzUrl as String,
        payload: null, // POST-as-GET
        accountKey: accountKey,
        accountUrl: accountUrl,
        nonce: nonce,
      );

      final authz = jsonDecode(authzResponse.body) as Map<String, dynamic>;
      final challenges = authz['challenges'] as List;

      // Find HTTP-01 challenge
      final http01 = challenges.firstWhere(
        (c) => c['type'] == 'http-01',
        orElse: () => null,
      );

      if (http01 == null) {
        throw Exception('No HTTP-01 challenge available');
      }

      final token = http01['token'] as String;
      final challengeUrl = http01['url'] as String;

      // Compute key authorization
      final keyAuthz = await _computeKeyAuthorization(token, accountKey);

      // Set challenge response on relay server
      if (_relayServer != null) {
        _relayServer!.setAcmeChallenge(token, keyAuthz);
        stdout.writeln('  Challenge token set: $token');
      } else {
        throw Exception('Relay server not available for challenge');
      }

      // Tell ACME server to verify
      nonceResponse = await http.head(Uri.parse(newNonceUrl));
      nonce = nonceResponse.headers['replay-nonce'] ?? '';

      final challengeResponse = await _signedAcmeRequest(
        url: challengeUrl,
        payload: {},
        accountKey: accountKey,
        accountUrl: accountUrl,
        nonce: nonce,
      );

      if (challengeResponse.statusCode != 200) {
        throw Exception('Challenge request failed: ${challengeResponse.statusCode}');
      }

      // Poll for completion
      stdout.writeln('  Waiting for challenge verification...');
      for (var i = 0; i < 30; i++) {
        await Future.delayed(const Duration(seconds: 2));

        nonceResponse = await http.head(Uri.parse(newNonceUrl));
        nonce = nonceResponse.headers['replay-nonce'] ?? '';

        final statusResponse = await _signedAcmeRequest(
          url: authzUrl as String,
          payload: null,
          accountKey: accountKey,
          accountUrl: accountUrl,
          nonce: nonce,
        );

        final status = jsonDecode(statusResponse.body) as Map<String, dynamic>;
        final authzStatus = status['status'] as String?;

        if (authzStatus == 'valid') {
          stdout.writeln('  Challenge verified!');
          break;
        } else if (authzStatus == 'invalid') {
          throw Exception('Challenge validation failed: ${status['challenges']}');
        }
        stdout.write('.');
      }

      // Cleanup challenge
      _relayServer?.clearAcmeChallenge(token);
    }
  }

  /// Compute key authorization for challenge
  Future<String> _computeKeyAuthorization(String token, Map<String, dynamic> accountKey) async {
    // Key authorization = token.thumbprint
    // For now, use a simplified approach with openssl
    final thumbprint = await _computeJwkThumbprint(accountKey);
    return '$token.$thumbprint';
  }

  /// Compute JWK thumbprint (SHA-256 of canonical JWK)
  Future<String> _computeJwkThumbprint(Map<String, dynamic> accountKey) async {
    // Extract public key components using openssl
    final keyPath = accountKey['path'] as String;

    // Get modulus (n) and exponent (e)
    final nResult = await Process.run('openssl', [
      'rsa', '-in', keyPath, '-noout', '-modulus'
    ]);
    final eResult = await Process.run('openssl', [
      'rsa', '-in', keyPath, '-noout', '-text'
    ]);

    if (nResult.exitCode != 0) {
      throw Exception('Failed to extract key modulus');
    }

    // Parse modulus
    final modulusHex = (nResult.stdout as String).split('=')[1].trim();
    final modulusBytes = _hexToBytes(modulusHex);
    final n = base64Url.encode(modulusBytes).replaceAll('=', '');

    // Public exponent is typically 65537 (0x010001)
    final e = base64Url.encode([1, 0, 1]).replaceAll('=', '');

    // Canonical JWK for thumbprint
    final jwk = '{"e":"$e","kty":"RSA","n":"$n"}';

    // SHA-256 hash
    final hashResult = await Process.run('sh', ['-c', 'echo -n \'$jwk\' | openssl dgst -sha256 -binary | base64 | tr -d "=" | tr "/+" "_-"']);

    return (hashResult.stdout as String).trim();
  }

  List<int> _hexToBytes(String hex) {
    final result = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      result.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return result;
  }

  /// Finalize order with CSR
  Future<void> _finalizeOrder({
    required Map<String, dynamic> directory,
    required Map<String, dynamic> accountKey,
    required String accountUrl,
    required Map<String, dynamic> order,
    required String domain,
  }) async {
    final finalizeUrl = order['finalize'] as String;
    final newNonceUrl = directory['newNonce'] as String;

    // Generate domain key if needed
    if (!File(domainKeyPath).existsSync()) {
      await _generateKey(domainKeyPath);
    }

    // Generate CSR in DER format directly
    final csrDerPath = '$_sslDir/domain.csr.der';
    final csrResult = await Process.run('openssl', [
      'req', '-new',
      '-key', domainKeyPath,
      '-outform', 'DER',
      '-out', csrDerPath,
      '-subj', '/CN=$domain',
    ]);

    if (csrResult.exitCode != 0) {
      throw Exception('Failed to generate CSR: ${csrResult.stderr}');
    }

    // Read CSR binary file and encode as base64url
    final csrDer = await File(csrDerPath).readAsBytes();
    final csrB64 = base64Url.encode(csrDer).replaceAll('=', '');

    // Finalize
    final nonceResponse = await http.head(Uri.parse(newNonceUrl));
    final nonce = nonceResponse.headers['replay-nonce'] ?? '';

    final response = await _signedAcmeRequest(
      url: finalizeUrl,
      payload: {'csr': csrB64},
      accountKey: accountKey,
      accountUrl: accountUrl,
      nonce: nonce,
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to finalize order: ${response.statusCode} ${response.body}');
    }

    // Update order with response
    final updatedOrder = jsonDecode(response.body) as Map<String, dynamic>;
    order.addAll(updatedOrder);

    // Poll for ready status
    stdout.writeln('  Waiting for certificate issuance...');
    final orderUrl = order['url'] as String;

    for (var i = 0; i < 30; i++) {
      await Future.delayed(const Duration(seconds: 2));

      final checkNonceResponse = await http.head(Uri.parse(newNonceUrl));
      final checkNonce = checkNonceResponse.headers['replay-nonce'] ?? '';

      final statusResponse = await _signedAcmeRequest(
        url: orderUrl,
        payload: null,
        accountKey: accountKey,
        accountUrl: accountUrl,
        nonce: checkNonce,
      );

      final status = jsonDecode(statusResponse.body) as Map<String, dynamic>;
      final orderStatus = status['status'] as String?;

      if (orderStatus == 'valid') {
        order['certificate'] = status['certificate'];
        stdout.writeln('  Certificate ready!');
        return;
      } else if (orderStatus == 'invalid') {
        throw Exception('Order became invalid');
      }
    }

    throw Exception('Timeout waiting for certificate');
  }

  /// Download certificate
  Future<void> _downloadCertificate({
    required Map<String, dynamic> directory,
    required Map<String, dynamic> accountKey,
    required String accountUrl,
    required Map<String, dynamic> order,
  }) async {
    final certUrl = order['certificate'] as String?;
    if (certUrl == null) {
      throw Exception('No certificate URL in order');
    }

    final newNonceUrl = directory['newNonce'] as String;
    final nonceResponse = await http.head(Uri.parse(newNonceUrl));
    final nonce = nonceResponse.headers['replay-nonce'] ?? '';

    final response = await _signedAcmeRequest(
      url: certUrl,
      payload: null,
      accountKey: accountKey,
      accountUrl: accountUrl,
      nonce: nonce,
      accept: 'application/pem-certificate-chain',
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to download certificate: ${response.statusCode}');
    }

    // Save certificate chain
    final certChain = response.body;
    await File(fullChainPath).writeAsString(certChain);
    await File(certPath).writeAsString(certChain);

    stdout.writeln('  Certificate saved to: $fullChainPath');
  }

  /// Make signed ACME request using external openssl
  Future<http.Response> _signedAcmeRequest({
    required String url,
    required dynamic payload,
    required Map<String, dynamic> accountKey,
    required String nonce,
    String? accountUrl,
    bool useJwk = false,
    String accept = 'application/json',
  }) async {
    final keyPath = accountKey['path'] as String;

    // Create protected header
    final protected = <String, dynamic>{
      'alg': 'RS256',
      'nonce': nonce,
      'url': url,
    };

    if (useJwk) {
      // For new account, include JWK
      protected['jwk'] = await _getJwk(keyPath);
    } else {
      // For other requests, use kid
      protected['kid'] = accountUrl;
    }

    final protectedB64 = base64Url.encode(utf8.encode(jsonEncode(protected))).replaceAll('=', '');

    // Encode payload
    String payloadB64;
    if (payload == null) {
      payloadB64 = ''; // POST-as-GET
    } else {
      payloadB64 = base64Url.encode(utf8.encode(jsonEncode(payload))).replaceAll('=', '');
    }

    // Sign with openssl
    final signingInput = '$protectedB64.$payloadB64';
    final signResult = await Process.run('sh', [
      '-c',
      'echo -n "$signingInput" | openssl dgst -sha256 -sign "$keyPath" | base64 | tr -d "\\n" | tr "/+" "_-" | tr -d "="'
    ]);

    if (signResult.exitCode != 0) {
      throw Exception('Failed to sign request: ${signResult.stderr}');
    }

    final signature = (signResult.stdout as String).trim();

    final body = jsonEncode({
      'protected': protectedB64,
      'payload': payloadB64,
      'signature': signature,
    });

    return await http.post(
      Uri.parse(url),
      headers: {
        'Content-Type': 'application/jose+json',
        'Accept': accept,
      },
      body: body,
    );
  }

  /// Get JWK from key file
  Future<Map<String, dynamic>> _getJwk(String keyPath) async {
    // Extract public key components
    final nResult = await Process.run('openssl', [
      'rsa', '-in', keyPath, '-noout', '-modulus'
    ]);

    if (nResult.exitCode != 0) {
      throw Exception('Failed to extract modulus');
    }

    final modulusHex = (nResult.stdout as String).split('=')[1].trim();
    final modulusBytes = _hexToBytes(modulusHex);
    final n = base64Url.encode(modulusBytes).replaceAll('=', '');

    // Public exponent (65537)
    final e = base64Url.encode([1, 0, 1]).replaceAll('=', '');

    return {
      'kty': 'RSA',
      'n': n,
      'e': e,
    };
  }

  /// Get challenge response for ACME HTTP-01 validation
  String? getChallengeResponse(String token) {
    return _challengeResponses[token];
  }

  /// Set challenge response for ACME HTTP-01 validation
  void setChallengeResponse(String token, String response) {
    _challengeResponses[token] = response;
  }

  /// Clear challenge response
  void clearChallengeResponse(String token) {
    _challengeResponses.remove(token);
  }

  /// Generate self-signed certificate for testing
  Future<bool> generateSelfSigned(String domain) async {
    try {
      // Generate private key
      var result = await Process.run('openssl', [
        'genrsa',
        '-out', domainKeyPath,
        '2048',
      ]);

      if (result.exitCode != 0) {
        throw Exception('Failed to generate key: ${result.stderr}');
      }

      // Generate self-signed certificate
      result = await Process.run('openssl', [
        'req',
        '-new',
        '-x509',
        '-key', domainKeyPath,
        '-out', certPath,
        '-days', '365',
        '-subj', '/CN=$domain/O=Geogram/C=XX',
      ]);

      if (result.exitCode != 0) {
        throw Exception('Failed to generate certificate: ${result.stderr}');
      }

      // Copy to fullchain
      await File(certPath).copy(fullChainPath);

      return true;
    } catch (e) {
      rethrow;
    }
  }
}
