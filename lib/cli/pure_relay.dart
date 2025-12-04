// Pure Dart relay server for CLI mode (no Flutter dependencies)
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:markdown/markdown.dart' as md;
import 'pure_storage_config.dart';
import '../models/blog_post.dart';
import '../util/nostr_key_generator.dart';
import '../util/nostr_event.dart';
import '../util/nostr_crypto.dart';
import '../util/chat_api.dart';

/// App version - use central version.dart for consistency
import '../version.dart' show appVersion;
/// Alias for backward compatibility
String get cliAppVersion => appVersion;

/// Relay server settings
class PureRelaySettings {
  int httpPort;
  bool enabled;
  bool tileServerEnabled;
  bool osmFallbackEnabled;
  int maxZoomLevel;
  int maxCacheSizeMB;
  String? name;
  String? description;
  String? location;
  double? latitude;
  double? longitude;
  // Relay identity (npub/nsec key pair)
  String npub;
  String nsec;
  // Callsign is derived from npub (X3 prefix for relays)
  String get callsign => NostrKeyGenerator.deriveRelayCallsign(npub);
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
    this.name,
    this.description,
    this.location,
    this.latitude,
    this.longitude,
    String? npub,
    String? nsec,
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
  }) : npub = npub ?? _defaultKeys.npub,
       nsec = nsec ?? _defaultKeys.nsec;

  // Generate default keys for relay (only created once per app run if no keys provided)
  static final NostrKeys _defaultKeys = NostrKeys.forRelay();

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
      name: json['name'] as String?,
      description: json['description'] as String?,
      location: json['location'] as String?,
      latitude: json['latitude'] as double?,
      longitude: json['longitude'] as double?,
      // Relay identity keys (callsign is derived from npub with X3 prefix)
      npub: json['npub'] as String?,
      nsec: json['nsec'] as String?,
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
        'name': name,
        'description': description,
        'location': location,
        'latitude': latitude,
        'longitude': longitude,
        // Relay identity keys
        'npub': npub,
        'nsec': nsec,
        'callsign': callsign, // Derived from npub (read-only)
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
    String? name,
    String? description,
    String? location,
    double? latitude,
    double? longitude,
    String? npub,
    String? nsec,
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
      name: name ?? this.name,
      description: description ?? this.description,
      location: location ?? this.location,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      npub: npub ?? this.npub,
      nsec: nsec ?? this.nsec,
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

  factory ChatRoom.fromJson(Map<String, dynamic> json) {
    final room = ChatRoom(
      id: json['id'] as String,
      name: json['name'] as String? ?? json['id'] as String,
      description: json['description'] as String? ?? '',
      creatorCallsign: json['creator'] as String? ?? 'Unknown',
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String)
          : null,
      isPublic: json['is_public'] as bool? ?? true,
    );
    if (json['last_activity'] != null) {
      room.lastActivity = DateTime.tryParse(json['last_activity'] as String) ?? DateTime.now();
    }
    return room;
  }

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

  /// Full JSON including messages (for persistence)
  Map<String, dynamic> toJsonWithMessages() => {
        'id': id,
        'name': name,
        'description': description,
        'creator': creatorCallsign,
        'created_at': createdAt.toIso8601String(),
        'last_activity': lastActivity.toIso8601String(),
        'is_public': isPublic,
        'messages': messages.map((m) => m.toJson()).toList(),
      };
}

/// Chat message
/// Storage format only requires: timestamp, callsign, content, npub, signature
/// Event ID and verification status are recalculated from these fields
class ChatMessage {
  final String id;           // NOSTR event ID (calculated from content)
  final String roomId;
  final String senderCallsign;
  final String? senderNpub;  // NOSTR public key (bech32) - human readable
  final String? signature;   // BIP-340 Schnorr signature
  final String content;
  final DateTime timestamp;
  final bool verified;       // Signature verified (runtime, not stored)
  final bool hasSignature;   // Has valid signature

  ChatMessage({
    required this.id,
    required this.roomId,
    required this.senderCallsign,
    this.senderNpub,
    this.signature,
    required this.content,
    DateTime? timestamp,
    this.verified = false,
    bool? hasSignature,
  }) : timestamp = timestamp ?? DateTime.now(),
       hasSignature = hasSignature ?? (signature != null && signature.isNotEmpty);

  factory ChatMessage.fromJson(Map<String, dynamic> json, String roomId) {
    final sig = json['signature'] as String?;
    return ChatMessage(
      id: json['id'] as String? ?? DateTime.now().millisecondsSinceEpoch.toString(),
      roomId: json['room_id'] as String? ?? roomId,
      senderCallsign: json['sender'] as String? ?? json['callsign'] as String? ?? 'Unknown',
      senderNpub: json['npub'] as String?,
      signature: sig,
      content: json['content'] as String? ?? '',
      timestamp: json['timestamp'] != null
          ? DateTime.tryParse(json['timestamp'] as String) ?? DateTime.now()
          : DateTime.now(),
      verified: json['verified'] as bool? ?? false,
      hasSignature: json['has_signature'] as bool? ?? (sig != null && sig.isNotEmpty),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'room_id': roomId,
        'callsign': senderCallsign,
        if (senderNpub != null) 'npub': senderNpub,
        if (signature != null) 'signature': signature,
        'content': content,
        'timestamp': timestamp.toIso8601String(),
        'verified': verified,
        'has_signature': hasSignature,
      };
}

/// Connected WebSocket client
class PureConnectedClient {
  final WebSocket socket;
  final String id;
  String? callsign;
  String? nickname;
  String? deviceType;
  String? version;
  String? address;
  DateTime connectedAt;
  DateTime lastActivity;

  PureConnectedClient({
    required this.socket,
    required this.id,
    this.callsign,
    this.nickname,
    this.deviceType,
    this.version,
    this.address,
  })  : connectedAt = DateTime.now(),
        lastActivity = DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'callsign': callsign ?? 'Unknown',
        'nickname': nickname,
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
  /// Uses PureStorageConfig for path management. PureStorageConfig must be initialized
  /// before calling this method.
  Future<void> initialize() async {
    final storageConfig = PureStorageConfig();
    if (!storageConfig.isInitialized) {
      throw StateError(
        'PureStorageConfig must be initialized before PureRelayServer. '
        'Call PureStorageConfig().init() first.',
      );
    }

    _dataDir = storageConfig.baseDir;
    _configPath = storageConfig.relayConfigPath;
    _tilesDirectory = storageConfig.tilesDir;

    // PureStorageConfig already creates directories, but ensure tiles exists
    await Directory(_tilesDirectory!).create(recursive: true);

    await _loadSettings();

    // Load persisted chat data
    await _loadChatData();

    // Create default chat room if it doesn't exist
    if (!_chatRooms.containsKey('general')) {
      _chatRooms['general'] = ChatRoom(
        id: 'general',
        name: 'General',
        description: 'General discussion',
        creatorCallsign: _settings.callsign,
      );
      await _saveChatData();
    }

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

  /// Get chat data directory path for a specific callsign: {devicesDir}/{callsign}/chat
  /// This matches the Java implementation structure
  /// If no callsign provided, defaults to relay's callsign
  String _getChatDataPath([String? callsign]) {
    final storageConfig = PureStorageConfig();
    final targetCallsign = callsign ?? _settings.callsign;
    return '${storageConfig.devicesDir}/$targetCallsign/chat';
  }

  /// Parse callsign from URL path: /{callsign}/api/... returns callsign
  /// Returns null if path doesn't match the pattern
  String? _parseCallsignFromPath(String path) {
    // Match pattern: /{callsign}/api/...
    final regex = RegExp(r'^/([A-Z0-9]+)/api/');
    final match = regex.firstMatch(path);
    if (match != null) {
      return match.group(1);
    }
    return null;
  }

  /// Get the API path without callsign prefix
  /// /X1ABC/api/chat/rooms -> /api/chat/rooms
  String _getApiPathWithoutCallsign(String path) {
    final regex = RegExp(r'^/[A-Z0-9]+(/api/.*)$');
    final match = regex.firstMatch(path);
    if (match != null) {
      return match.group(1)!;
    }
    return path;
  }


  /// Load chat rooms from disk ({callsign}/chat/{room_id}/config.json)
  Future<void> _loadChatData([String? callsign]) async {
    final chatPath = _getChatDataPath(callsign);
    try {
      final chatDir = Directory(chatPath);
      if (!await chatDir.exists()) {
        await chatDir.create(recursive: true);
        _log('INFO', 'Created chat directory at ${chatDir.path}');
        return;
      }

      // List room directories
      final roomDirs = await chatDir.list().where((e) => e is Directory).toList();
      if (roomDirs.isEmpty) {
        _log('INFO', 'No chat rooms found in $chatPath');
        return;
      }

      int loadedCount = 0;
      for (final entity in roomDirs) {
        final roomDir = entity as Directory;
        final roomId = roomDir.path.split('/').last;
        final configFile = File('${roomDir.path}/config.json');

        if (!await configFile.exists()) {
          _log('WARN', 'Chat room directory $roomId has no config.json, skipping');
          continue;
        }

        try {
          final content = await configFile.readAsString();
          final roomConfig = jsonDecode(content) as Map<String, dynamic>;

          final room = ChatRoom(
            id: roomConfig['id'] as String? ?? roomId,
            name: roomConfig['name'] as String? ?? roomId,
            description: roomConfig['description'] as String? ?? '',
            creatorCallsign: _settings.callsign,
          );
          _chatRooms[room.id] = room;

          // Load messages from text files
          await _loadRoomMessages(room);
          loadedCount++;
        } catch (e) {
          _log('ERROR', 'Failed to load chat room from ${configFile.path}: $e');
        }
      }

      _log('INFO', 'Loaded $loadedCount chat rooms from $chatPath');
    } catch (e) {
      _log('ERROR', 'Failed to load chat data: $e');
    }
  }

  /// Load messages for a room from text files ({room_id}/{year}/{date}_chat.txt)
  Future<void> _loadRoomMessages(ChatRoom room, [String? callsign]) async {
    final chatPath = _getChatDataPath(callsign);
    final roomDir = Directory('$chatPath/${room.id}');
    if (!await roomDir.exists()) return;

    // Get all year directories
    final yearDirs = await roomDir.list()
        .where((e) => e is Directory && RegExp(r'^\d{4}$').hasMatch(e.path.split('/').last))
        .toList();

    if (yearDirs.isEmpty) return;

    // Sort by year ascending
    yearDirs.sort((a, b) => a.path.compareTo(b.path));

    for (final yearEntity in yearDirs) {
      final yearDir = yearEntity as Directory;
      final chatFiles = await yearDir.list()
          .where((e) => e is File && e.path.endsWith('_chat.txt'))
          .toList();

      if (chatFiles.isEmpty) continue;

      // Sort files ascending (oldest first)
      chatFiles.sort((a, b) => a.path.compareTo(b.path));

      for (final fileEntity in chatFiles) {
        final chatFile = fileEntity as File;
        await _parseMessagesFromFile(room, chatFile);
      }
    }
  }

  /// Parse messages from a chat file (text format per specification)
  Future<void> _parseMessagesFromFile(ChatRoom room, File chatFile) async {
    try {
      final lines = await chatFile.readAsLines();
      String? currentTimestamp;
      String? currentCallsign;
      String? currentNpub;
      String? currentSignature;
      final contentBuffer = StringBuffer();

      for (final line in lines) {
        // Message header: > YYYY-MM-DD HH:MM_ss -- CALLSIGN
        if (line.startsWith('> ') && line.contains(' -- ')) {
          // Save previous message
          if (currentTimestamp != null && currentCallsign != null) {
            final content = contentBuffer.toString().trim();
            final timestamp = _parseTimestamp(currentTimestamp);
            final hasSig = currentSignature != null && currentSignature!.isNotEmpty;

            // Reconstruct NOSTR event to get ID and verify signature
            String? eventId;
            bool verified = false;
            if (hasSig && currentNpub != null) {
              final event = _reconstructNostrEvent(
                npub: currentNpub,
                content: content,
                signature: currentSignature,
                roomId: room.id,
                callsign: currentCallsign,
                timestamp: timestamp,
              );
              if (event != null) {
                eventId = event.id;
                verified = event.verify();
              }
            }

            final msg = ChatMessage(
              id: eventId ?? DateTime.now().millisecondsSinceEpoch.toString(),
              roomId: room.id,
              senderCallsign: currentCallsign,
              senderNpub: currentNpub,
              signature: currentSignature,
              content: content,
              timestamp: timestamp,
              verified: verified,
              hasSignature: hasSig,
            );
            room.messages.add(msg);
          }

          // Parse new header
          final separatorIdx = line.indexOf(' -- ');
          if (separatorIdx > 2) {
            currentTimestamp = line.substring(2, separatorIdx);
            currentCallsign = line.substring(separatorIdx + 4).trim();
            contentBuffer.clear();
            currentNpub = null;
            currentSignature = null;
          }
        }
        // Skip file header (# CALLSIGN: Title)
        else if (line.startsWith('# ')) {
          continue;
        }
        // Metadata line (--> key: value)
        else if (line.startsWith('--> ')) {
          final metadata = line.substring(4);
          final colonIdx = metadata.indexOf(': ');
          if (colonIdx > 0) {
            final key = metadata.substring(0, colonIdx).trim();
            final value = metadata.substring(colonIdx + 2).trim();
            switch (key) {
              case 'npub':
                currentNpub = value;
                break;
              case 'signature':
                currentSignature = value;
                break;
              // Legacy fields (ignored, recalculated from npub + signature)
              case 'pubkey':
              case 'event_id':
              case 'verified':
                break;
            }
          }
        }
        // Content line
        else if (currentTimestamp != null) {
          if (contentBuffer.isNotEmpty) {
            contentBuffer.write('\n');
          }
          contentBuffer.write(line);
        }
      }

      // Save last message
      if (currentTimestamp != null && currentCallsign != null) {
        final content = contentBuffer.toString().trim();
        final timestamp = _parseTimestamp(currentTimestamp);
        final hasSig = currentSignature != null && currentSignature!.isNotEmpty;

        // Reconstruct NOSTR event to get ID and verify signature
        String? eventId;
        bool verified = false;
        if (hasSig && currentNpub != null) {
          final event = _reconstructNostrEvent(
            npub: currentNpub,
            content: content,
            signature: currentSignature,
            roomId: room.id,
            callsign: currentCallsign,
            timestamp: timestamp,
          );
          if (event != null) {
            eventId = event.id;
            verified = event.verify();
          }
        }

        final msg = ChatMessage(
          id: eventId ?? DateTime.now().millisecondsSinceEpoch.toString(),
          roomId: room.id,
          senderCallsign: currentCallsign,
          senderNpub: currentNpub,
          signature: currentSignature,
          content: content,
          timestamp: timestamp,
          verified: verified,
          hasSignature: hasSig,
        );
        room.messages.add(msg);
      }
    } catch (e) {
      _log('ERROR', 'Failed to parse chat file ${chatFile.path}: $e');
    }
  }

  /// Reconstruct a NOSTR event from stored message data
  /// Returns the event with calculated ID, or null if missing required data
  NostrEvent? _reconstructNostrEvent({
    required String? npub,
    required String content,
    required String? signature,
    required String roomId,
    required String callsign,
    required DateTime timestamp,
  }) {
    if (npub == null || npub.isEmpty) return null;
    if (signature == null || signature.isEmpty) return null;

    try {
      final pubkey = NostrCrypto.decodeNpub(npub);
      final createdAt = timestamp.millisecondsSinceEpoch ~/ 1000;

      final event = NostrEvent(
        pubkey: pubkey,
        createdAt: createdAt,
        kind: 1,
        tags: [['t', 'chat'], ['room', roomId], ['callsign', callsign]],
        content: content,
        sig: signature,
      );

      // Calculate the event ID
      event.calculateId();

      return event;
    } catch (e) {
      return null;
    }
  }

  /// Verify a message by reconstructing and verifying the NOSTR event
  bool _verifyStoredMessage({
    required String? npub,
    required String content,
    required String? signature,
    required String roomId,
    required String callsign,
    required DateTime timestamp,
  }) {
    final event = _reconstructNostrEvent(
      npub: npub,
      content: content,
      signature: signature,
      roomId: roomId,
      callsign: callsign,
      timestamp: timestamp,
    );

    if (event == null) return false;
    return event.verify();
  }

  /// Parse timestamp from format YYYY-MM-DD HH:MM_ss
  DateTime _parseTimestamp(String timestamp) {
    try {
      // Format: YYYY-MM-DD HH:MM_ss
      final parts = timestamp.split(' ');
      if (parts.length != 2) return DateTime.now();

      final dateParts = parts[0].split('-');
      final timeParts = parts[1].replaceAll('_', ':').split(':');

      if (dateParts.length != 3 || timeParts.length != 3) return DateTime.now();

      return DateTime(
        int.parse(dateParts[0]),
        int.parse(dateParts[1]),
        int.parse(dateParts[2]),
        int.parse(timeParts[0]),
        int.parse(timeParts[1]),
        int.parse(timeParts[2]),
      );
    } catch (e) {
      return DateTime.now();
    }
  }

  /// Save room config to {room_id}/config.json
  Future<void> _saveRoomConfig(ChatRoom room, [String? callsign]) async {
    final chatPath = _getChatDataPath(callsign);
    final roomDir = Directory('$chatPath/${room.id}');
    if (!await roomDir.exists()) {
      await roomDir.create(recursive: true);
      _log('INFO', 'Created chat room directory: ${roomDir.path}');
    }

    final configFile = File('${roomDir.path}/config.json');
    final config = {
      'id': room.id,
      'name': room.name,
      'description': room.description,
      'visibility': 'PUBLIC',
      'readonly': false,
      'file_upload': true,
      'files_per_post': 3,
      'max_file_size': 500,
      'max_size_text': 500,
      'moderators': <String>[],
    };
    await configFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(config),
    );
    _log('INFO', 'Saved chat room config to ${configFile.path}');
  }

  /// Save all chat rooms (configs only)
  Future<void> _saveChatData([String? callsign]) async {
    for (final room in _chatRooms.values) {
      await _saveRoomConfig(room, callsign);
    }
  }

  /// Save a message to the chat file ({room_id}/{year}/{date}_chat.txt)
  Future<void> _saveRoomMessages(String roomId, [String? callsign]) async {
    final room = _chatRooms[roomId];
    if (room == null) return;

    final chatPath = _getChatDataPath(callsign);
    final targetCallsign = callsign ?? _settings.callsign;

    // Ensure room config exists
    await _saveRoomConfig(room, callsign);

    // Group messages by date
    final messagesByDate = <String, List<ChatMessage>>{};
    for (final msg in room.messages) {
      final dateStr = _formatDate(msg.timestamp);
      messagesByDate.putIfAbsent(dateStr, () => []).add(msg);
    }

    // Write each date's messages to its file
    for (final entry in messagesByDate.entries) {
      final dateStr = entry.key;
      final messages = entry.value;
      final year = dateStr.substring(0, 4);

      // Create year directory
      final yearDir = Directory('$chatPath/${room.id}/$year');
      if (!await yearDir.exists()) {
        await yearDir.create(recursive: true);
        _log('INFO', 'Created year directory: ${yearDir.path}');
      }

      // Write chat file
      final fileName = '${dateStr}_chat.txt';
      final chatFile = File('${yearDir.path}/$fileName');

      final buffer = StringBuffer();
      // Use room.id in header (not callsign) - this is part of the NOSTR event tags
      // and changing it would invalidate signatures
      buffer.writeln('# ${room.id}: Chat from $dateStr');
      buffer.writeln();

      for (final msg in messages) {
        final timeStr = _formatTime(msg.timestamp);
        final timestamp = '$dateStr $timeStr';

        buffer.writeln('> $timestamp -- ${msg.senderCallsign}');
        buffer.writeln(msg.content);

        // Write NOSTR metadata (minimal: npub + signature only)
        // event_id and verified can be recalculated from these fields
        if (msg.senderNpub != null && msg.senderNpub!.isNotEmpty) {
          buffer.writeln('--> npub: ${msg.senderNpub}');
        }
        if (msg.signature != null && msg.signature!.isNotEmpty) {
          buffer.writeln('--> signature: ${msg.signature}');
        }
        buffer.writeln();
      }

      await chatFile.writeAsString(buffer.toString());
    }
  }

  /// Format date as YYYY-MM-DD
  String _formatDate(DateTime dt) {
    return '${dt.year.toString().padLeft(4, '0')}-'
        '${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')}';
  }

  /// Format time as HH:MM_ss
  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}_'
        '${dt.second.toString().padLeft(2, '0')}';
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
      // callsign is derived from npub and cannot be set directly
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
        // Check if we need to request certificates first
        final sslDir = _dataDir != null ? '$_dataDir/ssl' : null;
        final fullchainPath = sslDir != null ? '$sslDir/fullchain.pem' : null;
        final keyPath = sslDir != null ? '$sslDir/privkey.pem' : null;

        bool certsExist = false;
        if (fullchainPath != null && keyPath != null) {
          certsExist = await File(fullchainPath).exists() && await File(keyPath).exists();
        }

        if (!certsExist && _settings.sslDomain != null && _settings.sslEmail != null) {
          _log('INFO', 'SSL enabled but no certificates found. Requesting from Let\'s Encrypt...');
          try {
            final sslManager = SslCertificateManager(_settings, _dataDir ?? '.');
            sslManager.setRelayServer(this);
            final success = await sslManager.requestCertificate(staging: false);
            if (success) {
              _log('INFO', 'SSL certificate obtained successfully');
              // Update paths
              _settings = _settings.copyWith(
                sslCertPath: fullchainPath,
                sslKeyPath: keyPath,
              );
              await saveSettings();
            } else {
              _log('ERROR', 'Failed to obtain SSL certificate');
            }
          } catch (e) {
            _log('ERROR', 'Failed to request SSL certificate: $e');
          }
        }

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
    // Check for certificates in ssl directory first (default location)
    final sslDir = _dataDir != null ? '$_dataDir/ssl' : null;
    final defaultCertPath = sslDir != null ? '$sslDir/fullchain.pem' : null;
    // Check for both privkey.pem and domain.key (SslCertificateManager uses domain.key)
    final defaultKeyPath = sslDir != null ? '$sslDir/domain.key' : null;
    final altKeyPath = sslDir != null ? '$sslDir/privkey.pem' : null;

    // Determine which certificate and key to use
    String? certToUse;
    String? keyToUse;

    // Priority 1: Check default ssl directory
    if (defaultCertPath != null) {
      final defaultCertFile = File(defaultCertPath);
      if (await defaultCertFile.exists()) {
        // Check for domain.key first, then privkey.pem
        if (defaultKeyPath != null && await File(defaultKeyPath).exists()) {
          certToUse = defaultCertPath;
          keyToUse = defaultKeyPath;
          _log('INFO', 'Using certificates from ssl directory (domain.key)');
        } else if (altKeyPath != null && await File(altKeyPath).exists()) {
          certToUse = defaultCertPath;
          keyToUse = altKeyPath;
          _log('INFO', 'Using certificates from ssl directory (privkey.pem)');
        }
      }
    }

    // Priority 2: Check configured paths
    if (certToUse == null && _settings.sslCertPath != null && _settings.sslKeyPath != null) {
      final configCertFile = File(_settings.sslCertPath!);
      final configKeyFile = File(_settings.sslKeyPath!);
      if (await configCertFile.exists() && await configKeyFile.exists()) {
        certToUse = _settings.sslCertPath;
        keyToUse = _settings.sslKeyPath;
        _log('INFO', 'Using certificates from configured paths');
      }
    }

    if (certToUse == null || keyToUse == null) {
      _log('WARN', 'SSL enabled but no certificates found');
      _log('WARN', '  Checked: ${defaultCertPath ?? "N/A"}');
      _log('WARN', '  Checked: ${_settings.sslCertPath ?? "N/A"}');
      return;
    }

    try {
      final context = SecurityContext()
        ..useCertificateChain(certToUse)
        ..usePrivateKey(keyToUse);

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
      _log('ERROR', 'Key: $keyToUse');
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

    // Persist room config to disk
    _saveRoomConfig(room);

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

  Future<void> postMessage(String roomId, String content) async {
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

    // Persist to disk
    await _saveRoomMessages(roomId);

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
      } else if (ChatApi.isRoomsPath(path)) {
        // /{callsign}/api/chat/rooms
        final callsign = ChatApi.extractCallsign(path)!;
        await _handleChatRooms(request, callsign);
      } else if (ChatApi.isMessagesPath(path)) {
        // /{callsign}/api/chat/rooms/{roomId}/messages
        final callsign = ChatApi.extractCallsign(path)!;
        await _handleRoomMessages(request, callsign);
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
      } else if (_isBlogPath(path)) {
        await _handleBlogRequest(request);
      } else if (_isCallsignOrNicknamePath(path)) {
        await _handleCallsignOrNicknameWww(request);
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
            String? nickname = message['nickname'] as String?;
            String? deviceType = message['device_type'] as String?;
            String? version = message['version'] as String?;

            // Check for Nostr event format (used by desktop/mobile clients)
            final event = message['event'] as Map<String, dynamic>?;
            if (event != null) {
              // Extract callsign and nickname from event tags: [['callsign', 'VALUE'], ['nickname', 'VALUE'], ...]
              final tags = event['tags'] as List<dynamic>?;
              if (tags != null) {
                for (final tag in tags) {
                  if (tag is List && tag.length >= 2) {
                    if (tag[0] == 'callsign') {
                      callsign = tag[1] as String?;
                    } else if (tag[0] == 'nickname') {
                      nickname = tag[1] as String?;
                    }
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
            client.nickname = nickname;
            client.deviceType = deviceType;
            client.version = version;

            final response = {
              'type': 'hello_response',
              'server': 'geogram-desktop-relay',
              'version': cliAppVersion,
              'callsign': _settings.callsign,
            };
            client.socket.add(jsonEncode(response));
            final nicknameInfo = client.nickname != null ? ' [${client.nickname}]' : '';
            _log('INFO', 'Hello from: ${client.callsign ?? "unknown"}$nicknameInfo (${client.deviceType ?? "unknown"})');
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
                final signature = message['signature'] as String?;
                final pubkey = message['pubkey'] as String?;
                final eventId = message['event_id'] as String?;
                final hasSig = signature != null && signature.isNotEmpty;

                // Derive npub from pubkey if not provided
                String? npub = message['npub'] as String?;
                if ((npub == null || npub.isEmpty) && pubkey != null && pubkey.isNotEmpty) {
                  try {
                    npub = NostrCrypto.encodeNpub(pubkey);
                  } catch (_) {}
                }

                // Verify signature if present
                bool isVerified = false;
                if (hasSig && pubkey != null && pubkey.isNotEmpty && eventId != null) {
                  try {
                    final event = NostrEvent(
                      id: eventId,
                      pubkey: pubkey,
                      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
                      kind: 1,
                      tags: [['t', 'chat'], ['room', roomId], ['callsign', client.callsign!]],
                      content: content,
                      sig: signature,
                    );
                    isVerified = event.verify();
                  } catch (e) {
                    _log('WARN', 'Error verifying chat_message signature: $e');
                  }
                }

                final msg = ChatMessage(
                  id: eventId ?? DateTime.now().millisecondsSinceEpoch.toString(),
                  roomId: roomId,
                  senderCallsign: client.callsign!,
                  senderNpub: npub,
                  signature: signature,
                  content: content,
                  verified: isVerified,
                  hasSignature: hasSig,
                );
                room.messages.add(msg);
                room.lastActivity = DateTime.now();
                _stats.totalMessages++;
                _stats.lastMessage = DateTime.now();

                // Persist to disk
                _saveRoomMessages(roomId);

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

          default:
            // Check for NOSTR event format (used by desktop/mobile clients)
            // Format: {"nostr_event": ["EVENT", {...event object...}]}
            final nostrEvent = message['nostr_event'];
            if (nostrEvent != null) {
              _handleNostrEvent(client, nostrEvent);
            }
            break;
        }
      }
    } catch (e) {
      _log('ERROR', 'WebSocket message error: $e');
    }
  }

  /// Handle incoming NOSTR event from WebSocket
  /// Format: ["EVENT", {id, pubkey, created_at, kind, tags, content, sig}]
  void _handleNostrEvent(PureConnectedClient client, dynamic nostrEvent) {
    try {
      // Parse NOSTR message format: ["EVENT", {...}]
      if (nostrEvent is! List || nostrEvent.length < 2) {
        _log('WARN', 'Invalid NOSTR event format');
        return;
      }

      final messageType = nostrEvent[0] as String?;
      if (messageType != 'EVENT') {
        _log('WARN', 'Unsupported NOSTR message type: $messageType');
        return;
      }

      final eventJson = nostrEvent[1] as Map<String, dynamic>;

      // Parse as NostrEvent for proper verification
      NostrEvent event;
      try {
        event = NostrEvent.fromJson(eventJson);
      } catch (e) {
        _log('WARN', 'Failed to parse NOSTR event: $e');
        return;
      }

      // Verify the signature (BIP-340 Schnorr)
      if (!event.verify()) {
        _log('WARN', 'NOSTR event signature verification failed');
        return;
      }

      final content = event.content;
      if (content.isEmpty) {
        _log('WARN', 'NOSTR event has no content');
        return;
      }

      // Extract room from tags, default to 'general'
      String roomId = event.getTagValue('room') ?? 'general';

      // Use the callsign derived from the pubkey (cryptographically verified)
      // This ensures the callsign matches the signing key
      final callsign = event.callsign;
      final npub = event.npub;

      _log('INFO', 'Received verified NOSTR chat message from $callsign to room $roomId');

      // Find or create the room
      var room = _chatRooms[roomId];
      if (room == null) {
        // Create the room if it doesn't exist
        room = ChatRoom(
          id: roomId,
          name: roomId == 'general' ? 'General' : roomId,
          description: 'Chat room',
          creatorCallsign: _settings.callsign,
        );
        _chatRooms[roomId] = room;
        _log('INFO', 'Created chat room: $roomId');
      }

      // Create chat message - mark as verified since we verified the signature above
      final msg = ChatMessage(
        id: event.id ?? DateTime.now().millisecondsSinceEpoch.toString(),
        roomId: roomId,
        senderCallsign: callsign,
        senderNpub: npub,  // Human-readable, pubkey derived when needed
        signature: event.sig,
        content: content,
        verified: true,  // Signature was verified by event.verify() above
        hasSignature: true,
      );

      room.messages.add(msg);
      room.lastActivity = DateTime.now();
      _stats.totalMessages++;
      _stats.lastMessage = DateTime.now();

      // Persist to disk
      _saveRoomMessages(roomId);

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
    } catch (e) {
      _log('ERROR', 'Error handling NOSTR event: $e');
    }
  }

  Future<void> _handleStatus(HttpRequest request) async {
    final uptime = _startTime != null
        ? DateTime.now().difference(_startTime!).inSeconds
        : 0;

    final status = {
      'service': 'Geogram Relay Server',
      'name': _settings.name ?? 'Geogram Relay',
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

      // Persist to disk
      await _saveRoomMessages(room);

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

  /// Check if path looks like a callsign or nickname for WWW serving
  /// Callsigns: X followed by numbers/letters (e.g., X1QVM3)
  /// Nicknames: alphanumeric with - and _ (e.g., brito, my-site, user_123)
  bool _isCallsignOrNicknamePath(String path) {
    if (path.length < 2) return false;
    final firstPart = path.substring(1).split('/').first;
    if (firstPart.isEmpty) return false;

    // Check if it's a callsign (X followed by alphanumeric)
    final isCallsign = RegExp(r'^X[0-9][A-Z0-9]{3,}$', caseSensitive: false).hasMatch(firstPart);
    if (isCallsign) return true;

    // Check if it's a valid nickname (alphanumeric with - and _, 2+ chars)
    // Must not conflict with reserved paths like /api, /ws, /tiles, /cli, /ssl, /acme
    final reservedPaths = {'api', 'ws', 'tiles', 'cli', 'ssl', 'acme', '.well-known'};
    if (reservedPaths.contains(firstPart.toLowerCase())) return false;

    // Valid nickname: alphanumeric, -, _, at least 2 chars
    return RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_-]+$').hasMatch(firstPart);
  }

  /// Check if path is a blog URL (/{identifier}/blog/{filename}.html)
  bool _isBlogPath(String path) {
    final regex = RegExp(r'^/([^/]+)/blog/([^/]+)\.html$');
    return regex.hasMatch(path);
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
      // First, try to find a connected WebSocket client with this nickname/callsign
      final client = _findConnectedClientByIdentifier(identifier);

      if (client != null) {
        // Proxy the blog request to the connected client via WebSocket
        _log('INFO', 'Proxying blog request to connected client: ${client.callsign} (${client.nickname ?? "no nickname"})');

        // Build the internal blog API path for the client
        final blogApiPath = '/api/blog/$filename.html';

        final requestId = DateTime.now().millisecondsSinceEpoch.toString();
        final proxyRequest = {
          'type': 'HTTP_REQUEST',
          'requestId': requestId,
          'method': 'GET',
          'path': blogApiPath,
          'headers': request.headers.toString(),
          'body': '',
        };

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
              'responseBody': 'Gateway Timeout - client did not respond',
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
          return;
        } catch (e) {
          _log('ERROR', 'Error proxying blog request: $e');
          request.response.statusCode = 502;
          request.response.write('Bad Gateway: $e');
          return;
        } finally {
          _pendingProxyRequests.remove(requestId);
        }
      }

      // Fallback: Try to find the blog locally on the relay server
      // (for relays that also host their own content)
      final callsign = await _findCallsignByIdentifier(identifier);
      if (callsign == null) {
        request.response.statusCode = 404;
        request.response.write('User not found (not connected and no local data)');
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
      final devicesDir = PureStorageConfig().devicesDir;
      final blogDir = Directory('$devicesDir/$callsign');

      // Find blog post in any collection
      BlogPost? foundPost;

      if (await blogDir.exists()) {
        await for (final entity in blogDir.list()) {
          if (entity is Directory) {
            final blogPath = '${entity.path}/blog/$year/$filename.md';
            final blogFile = File(blogPath);
            if (await blogFile.exists()) {
              try {
                final content = await blogFile.readAsString();
                foundPost = BlogPost.fromText(content, filename);
                break;
              } catch (e) {
                _log('ERROR', 'Error parsing blog file: $e');
              }
            }
          }
        }
      }

      if (foundPost == null) {
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
      _log('ERROR', 'Error serving blog post: $e');
      request.response.statusCode = 500;
      request.response.write('Internal server error');
    }
  }

  /// Find a connected WebSocket client by nickname or callsign
  PureConnectedClient? _findConnectedClientByIdentifier(String identifier) {
    final lowerIdentifier = identifier.toLowerCase();

    // First try to find by callsign
    for (final client in _clients.values) {
      if (client.callsign?.toLowerCase() == lowerIdentifier) {
        return client;
      }
    }

    // Then try to find by nickname
    for (final client in _clients.values) {
      if (client.nickname?.toLowerCase() == lowerIdentifier) {
        return client;
      }
    }

    return null;
  }

  /// Find callsign by identifier (nickname or callsign)
  Future<String?> _findCallsignByIdentifier(String identifier) async {
    final storageConfig = PureStorageConfig();
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
        _log('ERROR', 'Error reading config.json: $e');
      }
    }

    return null;
  }

  /// Build HTML page for blog post
  String _buildBlogHtmlPage(BlogPost post, String htmlContent, String author) {
    final tagsHtml = post.tags.isNotEmpty
        ? '<div class="tags">${post.tags.map((t) => '<span class="tag">#$t</span>').join(' ')}</div>'
        : '';

    return '''<!DOCTYPE html>
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
      --text: #eee;
      --text-secondary: #aaa;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      background: var(--bg);
      color: var(--text);
      line-height: 1.7;
      padding: 2rem;
      max-width: 800px;
      margin: 0 auto;
    }
    header {
      margin-bottom: 2rem;
      padding-bottom: 1rem;
      border-bottom: 1px solid var(--surface);
    }
    h1 { color: var(--primary); margin-bottom: 0.5rem; }
    .meta { color: var(--text-secondary); font-size: 0.9rem; }
    .description {
      font-style: italic;
      color: var(--text-secondary);
      padding: 1rem;
      background: var(--surface);
      border-radius: 8px;
      margin: 1rem 0;
    }
    .tags { margin: 1rem 0; }
    .tag {
      display: inline-block;
      background: var(--surface);
      padding: 0.25rem 0.75rem;
      border-radius: 1rem;
      font-size: 0.85rem;
      margin-right: 0.5rem;
      color: var(--primary);
    }
    article { margin-top: 2rem; }
    article h1, article h2, article h3 { margin: 1.5rem 0 1rem; color: var(--primary); }
    article p { margin: 1rem 0; }
    article a { color: var(--primary); }
    article code {
      background: var(--surface);
      padding: 0.2rem 0.4rem;
      border-radius: 4px;
      font-size: 0.9em;
    }
    article pre {
      background: var(--surface);
      padding: 1rem;
      border-radius: 8px;
      overflow-x: auto;
      margin: 1rem 0;
    }
    article pre code { background: none; padding: 0; }
    article blockquote {
      border-left: 3px solid var(--primary);
      padding-left: 1rem;
      margin: 1rem 0;
      color: var(--text-secondary);
    }
    article ul, article ol { margin: 1rem 0; padding-left: 2rem; }
    article li { margin: 0.5rem 0; }
    article img { max-width: 100%; height: auto; border-radius: 8px; }
    footer {
      margin-top: 3rem;
      padding-top: 1rem;
      border-top: 1px solid var(--surface);
      color: var(--text-secondary);
      font-size: 0.85rem;
      text-align: center;
    }
  </style>
</head>
<body>
  <header>
    <h1>${_escapeHtml(post.title)}</h1>
    <div class="meta">
      <span>By <strong>$author</strong></span> ·
      <span>${post.displayDate}</span>
    </div>
    ${post.description != null && post.description!.isNotEmpty ? '<div class="description">${_escapeHtml(post.description!)}</div>' : ''}
    $tagsHtml
  </header>
  <article>
    $htmlContent
  </article>
  <footer>
    <p>Powered by <a href="https://geogram.radio" target="_blank">geogram</a></p>
  </footer>
</body>
</html>''';
  }

  /// Escape HTML entities
  String _escapeHtml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }

  /// GET /{identifier} or /{identifier}/* - Serve WWW collection from device
  /// Supports both callsign (e.g., X1QVM3) and nickname (e.g., brito) lookups
  Future<void> _handleCallsignOrNicknameWww(HttpRequest request) async {
    final path = request.uri.path;
    final parts = path.substring(1).split('/');
    final identifier = parts.first.toLowerCase();
    final filePath = parts.length > 1 ? parts.sublist(1).join('/') : 'index.html';

    // Find the client by callsign or nickname (case-insensitive)
    PureConnectedClient? foundClient;
    for (final c in _clients.values) {
      // Check callsign first (primary identifier)
      if (c.callsign?.toLowerCase() == identifier) {
        foundClient = c;
        break;
      }
      // Check nickname (friendly URL)
      if (c.nickname != null && c.nickname!.toLowerCase() == identifier) {
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
  <title>${_settings.name ?? 'Geogram Relay'}</title>
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
  <h1>${_settings.name ?? 'Geogram Relay'}</h1>
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
    <p><a href="/${_settings.callsign}/api/chat/rooms">/${_settings.callsign}/api/chat/rooms</a> - Chat rooms</p>
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

  Future<void> _handleChatRooms(HttpRequest request, String targetCallsign) async {
    if (request.method == 'GET') {
      final rooms = _chatRooms.values.map((r) => r.toJson()).toList();
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'callsign': targetCallsign,
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
          await _saveRoomConfig(room, targetCallsign);
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

  Future<void> _handleRoomMessages(HttpRequest request, String targetCallsign) async {
    final path = request.uri.path;
    final roomId = ChatApi.extractRoomId(path) ?? 'general';

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
        'callsign': targetCallsign,
        'messages': messages,
        'count': messages.length,
      }));
    } else if (request.method == 'POST') {
      try {
        final body = await utf8.decoder.bind(request).join();
        final data = jsonDecode(body) as Map<String, dynamic>;

        final senderCallsign = data['callsign'] as String?;
        final content = data['content'] as String?;

        if (senderCallsign == null || senderCallsign.isEmpty) {
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
        var npub = data['npub'] as String?;
        final pubkey = data['pubkey'] as String?;
        final eventId = data['event_id'] as String?;
        final signature = data['signature'] as String?;
        final createdAt = data['created_at'] as int?;

        // Derive npub from pubkey if not provided
        if ((npub == null || npub.isEmpty) && pubkey != null && pubkey.isNotEmpty) {
          try {
            npub = NostrCrypto.encodeNpub(pubkey);
          } catch (e) {
            _log('WARN', 'Failed to derive npub from pubkey: $e');
          }
        }

        // Verify signature if present
        bool isVerified = false;
        final hasSig = signature != null && signature.isNotEmpty;
        if (hasSig && pubkey != null && pubkey.isNotEmpty && eventId != null) {
          try {
            // Reconstruct and verify the NOSTR event
            final event = NostrEvent(
              id: eventId,
              pubkey: pubkey,
              createdAt: createdAt ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000),
              kind: 1,
              tags: [['t', 'chat'], ['room', roomId], ['callsign', senderCallsign]],
              content: content,
              sig: signature,
            );
            isVerified = event.verify();
            if (isVerified) {
              _log('INFO', 'HTTP POST message signature verified for $senderCallsign');
            } else {
              _log('WARN', 'HTTP POST message signature verification failed for $senderCallsign');
            }
          } catch (e) {
            _log('WARN', 'Error verifying HTTP POST message signature: $e');
          }
        }

        // Create message
        final msg = ChatMessage(
          id: eventId ?? DateTime.now().millisecondsSinceEpoch.toString(),
          roomId: roomId,
          senderCallsign: senderCallsign,
          senderNpub: npub,
          signature: signature,
          content: content,
          timestamp: createdAt != null
              ? DateTime.fromMillisecondsSinceEpoch(createdAt * 1000)
              : DateTime.now(),
          verified: isVerified,
          hasSignature: hasSig,
        );

        room.messages.add(msg);
        room.lastActivity = DateTime.now();
        _stats.totalMessages++;
        _stats.lastMessage = DateTime.now();

        // Persist to disk under the target callsign's folder
        await _saveRoomMessages(roomId, targetCallsign);

        // Broadcast to connected WebSocket clients
        final payload = jsonEncode({
          'type': 'chat_message',
          'room': roomId,
          'callsign': targetCallsign,
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
