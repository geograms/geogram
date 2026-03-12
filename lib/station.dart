// Unified station server for CLI and Android modes (no Flutter dependencies)
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:mime/mime.dart';
import 'package:path/path.dart' as path;
import 'cli/pure_storage_config.dart';
import 'bot/models/music_model_info.dart';
import 'bot/models/vision_model_info.dart';
import 'models/chat_security.dart';
import 'models/event.dart';
import 'models/report.dart';
import 'services/event_service.dart';
import 'util/app_constants.dart';
import 'services/profile_storage.dart';
import 'api/handlers/alert_handler.dart';
import 'api/handlers/place_handler.dart';
import 'api/handlers/feedback_handler.dart';
import 'services/nip05_registry_service.dart';
import 'services/email_relay_service.dart';
import 'services/smtp_server.dart';
import 'server/mixins/xmpp_server_mixin.dart';
import 'util/alert_folder_utils.dart';
import 'util/feedback_folder_utils.dart';
import 'util/nostr_key_generator.dart';
import 'util/nostr_event.dart';
import 'util/nostr_crypto.dart';
import 'api/endpoints/chat_api_paths.dart';
import 'util/chat_scripts.dart';
import 'util/nostr_login_scripts.dart';
import 'util/nostr_bundle.dart';
import 'util/web_navigation.dart';
import 'util/station_html_templates.dart';
import 'util/html_utils.dart';
import 'util/event_bus.dart';
import 'util/reaction_utils.dart';
import 'util/chat_format.dart';
import 'models/update_settings.dart' show UpdateAssetType;
import 'services/geoip_service.dart';
import 'services/contact_service.dart';
import 'services/nostr_blossom_service.dart';
import 'services/nostr_relay_service.dart';
import 'services/nostr_relay_storage.dart';
import 'services/nostr_storage_paths.dart';
import 'server/models/server_chat_room.dart';
import 'server/models/server_chat_message.dart';
import 'cli/commands/service_interfaces.dart';
import 'server/mixins/rate_limit_mixin.dart';
import 'server/mixins/health_watchdog_mixin.dart';
import 'server/mixins/email_handler_mixin.dart';
import 'server/mixins/blog_handler_mixin.dart';
import 'server/mixins/console_command_mixin.dart';
import 'server/mixins/chat_moderation_mixin.dart';
import 'server/mixins/chat_nip05_mixin.dart';
import 'server/mixins/conference_mixin.dart';
import 'server/mixins/heartbeat_mixin.dart';
import 'server/mixins/karma_mixin.dart';
import 'cli/themes_embedded.dart';

/// App version - use central version.dart for consistency
import 'version.dart' show appVersion;

// Type aliases for backward compatibility within this file
typedef ChatRoom = ServerChatRoom;
typedef ChatMessage = ServerChatMessage;
/// Alias for backward compatibility
String get cliAppVersion => appVersion;

/// Backward compatibility aliases
typedef PureRelayServer = StationServer;
typedef PureStationServer = StationServer;

/// Station server settings
class PureRelaySettings implements StationSettingsReadable {
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
  // Station identity (npub/nsec key pair)
  String npub;
  String nsec;
  // Callsign is derived from npub (X3 prefix for stations)
  String get callsign => NostrKeyGenerator.deriveStationCallsign(npub);
  bool enableAprs;
  bool enableCors;
  int httpRequestTimeout;
  int maxConnectedDevices;
  bool nostrRequireAuthForWrites;
  int blossomMaxStorageMb;
  int blossomMaxFileMb;

  // Station role configuration
  String stationRole; // 'root' or 'node'
  String? networkId;
  String? parentStationUrl; // For node stations

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

  // Update mirror configuration
  bool updateMirrorEnabled;
  int updateCheckIntervalSeconds;
  String? lastMirroredVersion;
  String updateMirrorUrl;

  // SMTP configuration
  bool smtpEnabled;
  bool smtpServerEnabled;
  int smtpPort;

  // SMTP relay configuration (for sending via external relay)
  String? smtpRelayHost;
  int smtpRelayPort;
  String? smtpRelayUsername;
  String? smtpRelayPassword;
  bool smtpRelayStartTls;

  // DKIM configuration (RSA private key in PEM format, base64 encoded)
  String? dkimPrivateKey;

  // XMPP Server configuration
  bool xmppServerEnabled;
  int xmppServerPort;

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
    this.nostrRequireAuthForWrites = true,
    this.blossomMaxStorageMb = 1024,
    this.blossomMaxFileMb = 10,
    this.stationRole = '',
    this.networkId,
    this.parentStationUrl,
    this.setupComplete = false,
    this.enableSsl = false,
    this.sslDomain,
    this.sslEmail,
    this.sslAutoRenew = true,
    this.sslCertPath,
    this.sslKeyPath,
    this.httpsPort = 8443,
    this.updateMirrorEnabled = true,
    this.updateCheckIntervalSeconds = 120,
    this.lastMirroredVersion,
    this.updateMirrorUrl = 'https://api.github.com/repos/geograms/geogram/releases/latest',
    this.smtpEnabled = false,
    this.smtpServerEnabled = false,
    this.smtpPort = 2525,
    this.smtpRelayHost,
    this.smtpRelayPort = 587,
    this.smtpRelayUsername,
    this.smtpRelayPassword,
    this.smtpRelayStartTls = true,
    this.dkimPrivateKey,
    this.xmppServerEnabled = false,
    this.xmppServerPort = 5222,
  }) : npub = npub ?? _defaultKeys.npub,
       nsec = nsec ?? _defaultKeys.nsec;

  // Generate default keys for station (only created once per app run if no keys provided)
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
      // Station identity keys (callsign is derived from npub with X3 prefix)
      // Treat empty strings as null to trigger default key generation
      npub: (json['npub'] as String?)?.isNotEmpty == true ? json['npub'] as String : null,
      nsec: (json['nsec'] as String?)?.isNotEmpty == true ? json['nsec'] as String : null,
      enableAprs: json['enableAprs'] as bool? ?? false,
      enableCors: json['enableCors'] as bool? ?? true,
      httpRequestTimeout: json['httpRequestTimeout'] as int? ?? 30000,
      maxConnectedDevices: json['maxConnectedDevices'] as int? ?? 100,
      nostrRequireAuthForWrites: json['nostrRequireAuthForWrites'] as bool? ?? true,
      blossomMaxStorageMb: json['blossomMaxStorageMb'] as int? ?? 1024,
      blossomMaxFileMb: json['blossomMaxFileMb'] as int? ?? 10,
      stationRole: json['stationRole'] as String? ?? '',
      networkId: json['networkId'] as String?,
      parentStationUrl: json['parentStationUrl'] as String?,
      setupComplete: json['setupComplete'] as bool? ?? false,
      enableSsl: json['enableSsl'] as bool? ?? false,
      sslDomain: json['sslDomain'] as String?,
      sslEmail: json['sslEmail'] as String?,
      sslAutoRenew: json['sslAutoRenew'] as bool? ?? true,
      sslCertPath: json['sslCertPath'] as String?,
      sslKeyPath: json['sslKeyPath'] as String?,
      // Support both old 'sslPort' and new 'httpsPort' keys
      httpsPort: json['httpsPort'] as int? ?? json['sslPort'] as int? ?? 8443,
      updateMirrorEnabled: json['updateMirrorEnabled'] as bool? ?? true,
      updateCheckIntervalSeconds: json['updateCheckIntervalSeconds'] as int? ?? 120,
      lastMirroredVersion: json['lastMirroredVersion'] as String?,
      updateMirrorUrl: json['updateMirrorUrl'] as String? ?? 'https://api.github.com/repos/geograms/geogram/releases/latest',
      smtpEnabled: json['smtpEnabled'] as bool? ?? false,
      smtpServerEnabled: json['smtpServerEnabled'] as bool? ?? false,
      smtpPort: json['smtpPort'] as int? ?? 2525,
      smtpRelayHost: json['smtpRelayHost'] as String?,
      smtpRelayPort: json['smtpRelayPort'] as int? ?? 587,
      smtpRelayUsername: json['smtpRelayUsername'] as String?,
      smtpRelayPassword: json['smtpRelayPassword'] as String?,
      smtpRelayStartTls: json['smtpRelayStartTls'] as bool? ?? true,
      dkimPrivateKey: json['dkimPrivateKey'] as String?,
      xmppServerEnabled: json['xmppServerEnabled'] as bool? ?? false,
      xmppServerPort: json['xmppServerPort'] as int? ?? 5222,
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
        // Station identity keys
        'npub': npub,
        'nsec': nsec,
        'callsign': callsign, // Derived from npub (read-only)
        'enableAprs': enableAprs,
        'enableCors': enableCors,
        'httpRequestTimeout': httpRequestTimeout,
        'maxConnectedDevices': maxConnectedDevices,
        'nostrRequireAuthForWrites': nostrRequireAuthForWrites,
        'blossomMaxStorageMb': blossomMaxStorageMb,
        'blossomMaxFileMb': blossomMaxFileMb,
        'stationRole': stationRole,
        'networkId': networkId,
        'parentStationUrl': parentStationUrl,
        'setupComplete': setupComplete,
        'enableSsl': enableSsl,
        'sslDomain': sslDomain,
        'sslEmail': sslEmail,
        'sslAutoRenew': sslAutoRenew,
        'sslCertPath': sslCertPath,
        'sslKeyPath': sslKeyPath,
        'httpsPort': httpsPort,
        'updateMirrorEnabled': updateMirrorEnabled,
        'updateCheckIntervalSeconds': updateCheckIntervalSeconds,
        'lastMirroredVersion': lastMirroredVersion,
        'updateMirrorUrl': updateMirrorUrl,
        'smtpEnabled': smtpEnabled,
        'smtpServerEnabled': smtpServerEnabled,
        'smtpPort': smtpPort,
        'smtpRelayHost': smtpRelayHost,
        'smtpRelayPort': smtpRelayPort,
        'smtpRelayUsername': smtpRelayUsername,
        'smtpRelayPassword': smtpRelayPassword,
        'smtpRelayStartTls': smtpRelayStartTls,
        'dkimPrivateKey': dkimPrivateKey,
        'xmppServerEnabled': xmppServerEnabled,
        'xmppServerPort': xmppServerPort,
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
    bool? nostrRequireAuthForWrites,
    int? blossomMaxStorageMb,
    int? blossomMaxFileMb,
    String? stationRole,
    String? networkId,
    String? parentStationUrl,
    bool? setupComplete,
    bool? enableSsl,
    String? sslDomain,
    String? sslEmail,
    bool? sslAutoRenew,
    String? sslCertPath,
    String? sslKeyPath,
    int? httpsPort,
    bool? updateMirrorEnabled,
    int? updateCheckIntervalSeconds,
    String? lastMirroredVersion,
    String? updateMirrorUrl,
    bool? smtpEnabled,
    bool? smtpServerEnabled,
    int? smtpPort,
    String? smtpRelayHost,
    int? smtpRelayPort,
    String? smtpRelayUsername,
    String? smtpRelayPassword,
    bool? smtpRelayStartTls,
    String? dkimPrivateKey,
    bool? xmppServerEnabled,
    int? xmppServerPort,
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
      nostrRequireAuthForWrites: nostrRequireAuthForWrites ?? this.nostrRequireAuthForWrites,
      blossomMaxStorageMb: blossomMaxStorageMb ?? this.blossomMaxStorageMb,
      blossomMaxFileMb: blossomMaxFileMb ?? this.blossomMaxFileMb,
      stationRole: stationRole ?? this.stationRole,
      networkId: networkId ?? this.networkId,
      parentStationUrl: parentStationUrl ?? this.parentStationUrl,
      setupComplete: setupComplete ?? this.setupComplete,
      enableSsl: enableSsl ?? this.enableSsl,
      sslDomain: sslDomain ?? this.sslDomain,
      sslEmail: sslEmail ?? this.sslEmail,
      sslAutoRenew: sslAutoRenew ?? this.sslAutoRenew,
      sslCertPath: sslCertPath ?? this.sslCertPath,
      sslKeyPath: sslKeyPath ?? this.sslKeyPath,
      httpsPort: httpsPort ?? this.httpsPort,
      updateMirrorEnabled: updateMirrorEnabled ?? this.updateMirrorEnabled,
      updateCheckIntervalSeconds: updateCheckIntervalSeconds ?? this.updateCheckIntervalSeconds,
      lastMirroredVersion: lastMirroredVersion ?? this.lastMirroredVersion,
      updateMirrorUrl: updateMirrorUrl ?? this.updateMirrorUrl,
      smtpEnabled: smtpEnabled ?? this.smtpEnabled,
      smtpServerEnabled: smtpServerEnabled ?? this.smtpServerEnabled,
      smtpPort: smtpPort ?? this.smtpPort,
      smtpRelayHost: smtpRelayHost ?? this.smtpRelayHost,
      smtpRelayPort: smtpRelayPort ?? this.smtpRelayPort,
      smtpRelayUsername: smtpRelayUsername ?? this.smtpRelayUsername,
      smtpRelayPassword: smtpRelayPassword ?? this.smtpRelayPassword,
      smtpRelayStartTls: smtpRelayStartTls ?? this.smtpRelayStartTls,
      dkimPrivateKey: dkimPrivateKey ?? this.dkimPrivateKey,
      xmppServerEnabled: xmppServerEnabled ?? this.xmppServerEnabled,
      xmppServerPort: xmppServerPort ?? this.xmppServerPort,
    );
  }

  /// Check if setup needs to be run
  bool needsSetup() {
    return !setupComplete || callsign.isEmpty || stationRole.isEmpty;
  }
}

/// Log entry for CLI log history
class LogEntry implements LogEntryReadable {
  @override
  final DateTime timestamp;
  @override
  final String level;
  @override
  final String message;

  LogEntry(this.timestamp, this.level, this.message);

  @override
  String toString() =>
      '[${timestamp.toIso8601String()}] [$level] $message';
}

/// Connected WebSocket client
class PureConnectedClient implements EmailClient, BlogClient, ConnectedClientReadable {
  final WebSocket socket;
  final String id;
  String? callsign;
  String? nickname;
  String? color;
  String? deviceType;
  String? platform;
  String? version;
  String? address;
  String? npub;
  double? latitude;
  double? longitude;
  DateTime connectedAt;
  DateTime lastActivity;

  // Challenge-response authentication (HELLO protocol v2)
  String? pendingChallenge;
  int helloProtocol = 1;
  bool verified = false;

  // Multi-device responsiveness tracking
  int successCount = 0;
  int failCount = 0;

  /// Success rate for adaptive device ordering (0.0 to 1.0)
  double get successRate {
    final total = successCount + failCount;
    if (total == 0) return 0.5;
    return successCount / total;
  }

  PureConnectedClient({
    required this.socket,
    required this.id,
    this.callsign,
    this.nickname,
    this.color,
    this.deviceType,
    this.platform,
    this.version,
    this.address,
    this.npub,
    this.latitude,
    this.longitude,
  })  : connectedAt = DateTime.now(),
        lastActivity = DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'callsign': callsign ?? 'Unknown',
        'nickname': nickname,
        'color': color,
        'npub': npub,
        'device_type': deviceType ?? 'Unknown',
        'platform': platform,
        'version': version,
        'address': address,
        'latitude': latitude,
        'longitude': longitude,
        'connected_at': connectedAt.toIso8601String(),
        'last_activity': lastActivity.toIso8601String(),
        'protocol': helloProtocol,
        'verified': verified,
        'success_count': successCount,
        'fail_count': failCount,
      };
}

/// Server statistics
class ServerStats implements StationStatsReadable {
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

/// Tile cache for station server
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

  /// Validate tile image data by checking header and basic structure
  /// This prevents caching corrupt tiles from bad network connections
  static bool isValidImageData(Uint8List data) {
    if (data.length < 8) return false;

    // Check for PNG signature
    final isPng = data[0] == 0x89 &&
        data[1] == 0x50 &&
        data[2] == 0x4E &&
        data[3] == 0x47;
    // Check for JPEG signature (used by satellite tiles)
    final isJpeg = data[0] == 0xFF &&
        data[1] == 0xD8 &&
        data[2] == 0xFF;

    if (!isPng && !isJpeg) return false;

    // For PNG, verify IEND chunk exists (basic integrity check)
    if (isPng) {
      // Look for IEND marker in last 12 bytes
      if (data.length < 12) return false;
      final end = data.sublist(data.length - 12);
      // IEND chunk: length(4) + 'IEND'(4) + CRC(4)
      final hasIend = end[4] == 0x49 && end[5] == 0x45 &&
                      end[6] == 0x4E && end[7] == 0x44;
      return hasIend;
    }

    // For JPEG, verify EOI marker exists
    if (isJpeg) {
      // JPEG should end with FFD9
      return data[data.length - 2] == 0xFF && data[data.length - 1] == 0xD9;
    }

    return true;
  }
}

/// Unified station server for CLI and Android modes
class StationServer with RateLimitMixin, HealthWatchdogMixin, HeartbeatMixin, EmailHandlerMixin, BlogHandlerMixin, ConsoleCommandMixin, ChatNip05Mixin, ChatModerationMixin, ConferenceMixin, XmppServerMixin, KarmaMixin
    implements StationCommandInterface {
  HttpServer? _httpServer;
  HttpServer? _httpsServer;
  SMTPServer? _smtpServer;
  PureRelaySettings _settings = PureRelaySettings();
  final Map<String, PureConnectedClient> _clients = {};

  // Connection tolerance: preserve uptime for reconnects within 5 minutes
  // Maps callsign -> (disconnectTime, originalConnectTime)
  final Map<String, ({DateTime disconnectTime, DateTime originalConnectTime})> _disconnectInfo = {};
  static const Duration _reconnectTolerance = Duration(minutes: 5);

  final PureTileCache _tileCache = PureTileCache();
  final Map<String, ChatRoom> _chatRooms = {};
  ChatSecurity _chatSecurityData = ChatSecurity();
  final List<LogEntry> _logs = [];
  final ServerStats _stats = ServerStats();
  final EventBus _eventBus = EventBus();
  bool _running = false;
  bool _quietMode = false;
  DateTime? _startTime;
  String? _tilesDirectory;
  String? _configPath;
  String? _dataDir;

  // Update mirror state
  Map<String, dynamic>? _cachedRelease;
  String? _updatesDirectory;
  bool _isDownloadingUpdates = false;
  Timer? _updatePollTimer;
  Map<String, String> _downloadedAssets = {};
  Map<String, String> _assetFilenames = {};
  String? _currentDownloadVersion;

  // Whisper model mirror state
  Set<String> _availableWhisperModels = {};

  // Supertonic TTS model mirror state
  Set<String> _availableSupertonicModels = {};

  // HeartbeatMixin bridge
  @override
  Map<String, dynamic> get heartbeatClients => _clients;
  @override
  void heartbeatLog(String level, String message) => _log(level, message);
  @override
  bool heartbeatSend(dynamic client, String data) => _safeSocketSend(client as PureConnectedClient, data);
  @override
  void heartbeatRemoveClient(String clientId, {String reason = 'disconnected'}) => _removeClient(clientId, reason: reason);
  @override
  void heartbeatCleanup() => cleanupExpiredBans();

  // Shared alert API handlers
  AlertHandler? _alertApi;
  PlaceHandler? _placeApi;
  FeedbackHandler? _feedbackApi;

  // ── EmailHandlerMixin interface ─────────────────────────────────
  @override
  void emailLog(String level, String message) => _log(level, message);
  @override
  String get stationDomain => _settings.sslDomain ?? _settings.callsign.toLowerCase();
  @override
  EmailClient? emailGetClientById(String clientId) => _clients[clientId];
  @override
  EmailClient? emailFindClientByCallsign(String callsign) {
    try {
      return _clients.values.firstWhere(
        (c) => c.callsign?.toUpperCase() == callsign.toUpperCase(),
      );
    } catch (_) {
      return null;
    }
  }
  @override
  List<EmailClient> emailFindAllClientsByCallsign(String callsign) {
    final upper = callsign.toUpperCase();
    final matches = _clients.values
        .where((c) => c.callsign?.toUpperCase() == upper)
        .toList();
    matches.sort((a, b) => b.successRate.compareTo(a.successRate));
    return matches;
  }
  @override
  bool emailSafeSocketSend(PureConnectedClient client, String data) => _safeSocketSend(client, data);

  // ── ConferenceMixin interface ───────────────────────────────────
  @override
  void conferenceLog(String level, String message) => _log(level, message);
  @override
  bool conferenceSendToClient(String clientId, String data) {
    final client = _clients[clientId];
    if (client == null) return false;
    return _safeSocketSend(client, data);
  }
  @override
  String? conferenceFindClientId(String callsign) {
    try {
      final client = _clients.values.firstWhere(
        (c) => c.callsign?.toUpperCase() == callsign.toUpperCase(),
      );
      return client.id;
    } catch (_) {
      return null;
    }
  }
  @override
  String? conferenceGetClientCallsign(String clientId) {
    return _clients[clientId]?.callsign;
  }

  // ── BlogHandlerMixin interface ──────────────────────────────────
  @override
  void blogLog(String level, String message) => _log(level, message);
  @override
  String get blogDevicesDir => PureStorageConfig().devicesDir;
  @override
  String get blogConfigPath => PureStorageConfig().configPath;
  @override
  BlogClient? blogFindConnectedClientByIdentifier(String identifier) =>
      _findConnectedClientByIdentifier(identifier);
  @override
  List<BlogClient> blogFindAllClientsByIdentifier(String identifier) =>
      _findAllClientsByIdentifier(identifier);
  @override
  Future<bool> blogProxyToClient(
      BlogClient client, HttpRequest request, String filename) async {
    if (client is! PureConnectedClient) return false;
    final targetCallsign = client.callsign ?? '';
    final blogApiPath = '/$targetCallsign/blog/$filename.html';
    final requestId = DateTime.now().millisecondsSinceEpoch.toString();
    final proxyRequest = {
      'type': 'HTTP_REQUEST',
      'requestId': requestId,
      'method': 'GET',
      'path': blogApiPath,
      'headers': jsonEncode({'X-Device-Callsign': targetCallsign}),
      'body': '',
    };
    final completer = Completer<Map<String, dynamic>>();
    _pendingProxyRequests[requestId] = completer;
    try {
      client.socket.add(jsonEncode(proxyRequest));
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
          final headers = jsonDecode(response['responseHeaders'] as String)
              as Map<String, dynamic>;
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
      return true;
    } catch (e) {
      _log('ERROR', 'Error proxying blog request: $e');
      request.response.statusCode = 502;
      request.response.write('Bad Gateway: $e');
      return true;
    } finally {
      _pendingProxyRequests.remove(requestId);
    }
  }

  // NOSTR relay + Blossom
  NostrRelayStorage? _nostrStorage;
  NostrRelayService? _nostrRelay;
  NostrBlossomService? _blossom;

  // File-based logging
  IOSink? _logSink;
  IOSink? _crashSink;
  IOSink? _accessLogSink;
  DateTime? _currentLogDay;
  DateTime? _currentAccessLogDay;

  // ============================================
  // Mixin Abstract Method Implementations
  // ============================================

  // RateLimitMixin requires: log(), dataDir
  // HealthWatchdogMixin requires: log(), httpPort, isServerRunning,
  //                               connectedClientsCount, autoRecover(), logCrash()

  @override
  void log(String level, String message) => _log(level, message);

  @override
  String? get dataDir => _dataDir;

  @override
  int get httpPort => _settings.httpPort;

  @override
  bool get isServerRunning => _running;

  @override
  int get connectedClientsCount => _clients.length;

  @override
  Future<void> autoRecover() => _autoRecover();

  @override
  void logCrash(String reason) => _logCrash(reason);

  // KarmaMixin requires: karmaBroadcastToCallsign()
  @override
  void karmaBroadcastToCallsign(String callsign, String payload) {
    final cs = callsign.toUpperCase();
    for (final client in _clients.values) {
      if (client.callsign?.toUpperCase() == cs) {
        try {
          client.socket.add(payload);
        } catch (_) {}
      }
    }
  }

  /// Get the shared alert API handlers (lazy initialization)
  /// Must only be called after init() has been called (when _dataDir is set)
  AlertHandler get alertApi {
    if (_alertApi == null) {
      if (_dataDir == null) {
        throw StateError('alertApi accessed before init() - _dataDir is null');
      }
      _alertApi = AlertHandler(
        storage: FilesystemProfileStorage('$_dataDir/devices/${_settings.callsign}'),
        stationInfo: StationInfo(
          name: _settings.name ?? 'Geogram Station',
          callsign: _settings.callsign,
          npub: _settings.npub,
        ),
        log: (level, message) => _log(level, message),
      );
    }
    return _alertApi!;
  }

  /// Get the shared places API handlers (lazy initialization)
  PlaceHandler get placeApi {
    if (_placeApi == null) {
      if (_dataDir == null) {
        throw StateError('placeApi accessed before init() - _dataDir is null');
      }
      _placeApi = PlaceHandler(
        dataDir: _dataDir!,
        stationInfo: StationInfo(
          name: _settings.name ?? 'Geogram Station',
          callsign: _settings.callsign,
          npub: _settings.npub,
        ),
        log: (level, message) => _log(level, message),
      );
    }
    return _placeApi!;
  }

  /// Get the shared feedback API handlers (lazy initialization)
  FeedbackHandler get feedbackApi {
    if (_feedbackApi == null) {
      if (_dataDir == null) {
        throw StateError('feedbackApi accessed before init() - _dataDir is null');
      }
      _feedbackApi = FeedbackHandler(
        storage: FilesystemProfileStorage('$_dataDir/devices/${_settings.callsign}'),
        log: (level, message) => _log(level, message),
      );
    }
    return _feedbackApi!;
  }

  static const int maxLogEntries = 1000;

  /// Access to the event bus for subscribing to station events
  EventBus get eventBus => _eventBus;

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

  // --- StationCommandInterface readable bridges ---

  @override
  Map<String, ChatRoomReadable> get chatRoomsReadable =>
      chatRooms.cast<String, ChatRoomReadable>();

  @override
  Map<String, ConnectedClientReadable> get clientsReadable =>
      clients.cast<String, ConnectedClientReadable>();

  @override
  List<LogEntryReadable> get logsReadable =>
      logs.cast<LogEntryReadable>();

  // --- ChatModerationMixin overrides ---
  @override
  ChatSecurity get chatSecurity => _chatSecurityData;

  @override
  Future<void> saveChatSecurity(ChatSecurity security) async {
    _chatSecurityData = security;
    final chatPath = _getChatDataPath();
    final extraDir = Directory('$chatPath/extra');
    if (!await extraDir.exists()) {
      await extraDir.create(recursive: true);
    }
    final file = File('$chatPath/extra/security.json');
    final json = {
      'version': '1.0',
      ...security.toJson(),
    };
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(json));
  }

  // --- ConsoleCommandMixin slot ---
  @override
  StationCommandInterface get consoleStationInterface => this;

  /// Initialize station server
  ///
  /// Uses PureStorageConfig for path management. PureStorageConfig must be initialized
  /// before calling this method.
  Future<void> initialize() async {
    final storageConfig = PureStorageConfig();
    if (!storageConfig.isInitialized) {
      throw StateError(
        'PureStorageConfig must be initialized before PureStationServer. '
        'Call PureStorageConfig().init() first.',
      );
    }

    _dataDir = storageConfig.baseDir;
    _configPath = storageConfig.stationConfigPath;
    _tilesDirectory = storageConfig.tilesDir;

    // PureStorageConfig already creates directories, but ensure tiles exists
    await Directory(_tilesDirectory!).create(recursive: true);

    // Prepare logging sinks based on the data directory
    await _prepareLogSinks(DateTime.now());

    // Initialize updates directory
    _updatesDirectory = '$_dataDir/updates';
    await Directory(_updatesDirectory!).create(recursive: true);

    final settingsExisted = await _loadSettings();

    await _initNostrServices();

    // Load cached release info if exists
    await _loadCachedRelease();

    // Scan for existing whisper models
    await _scanWhisperModels();

    // Scan for existing Supertonic TTS models
    await _scanSupertonicModels();

    // Only initialize chat data if settings already existed (not fresh install).
    // For fresh installs, chat will be initialized after identity is established
    // via reinitializeChatForCurrentIdentity().
    if (settingsExisted) {
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
    }

    _log('INFO', 'Pure Station Server initialized');
    _log('INFO', 'Data directory: $_dataDir');
  }

  /// Load settings from file. Returns true if settings file existed, false if fresh install.
  Future<bool> _loadSettings() async {
    try {
      final configFile = File(_configPath!);
      if (await configFile.exists()) {
        final content = await configFile.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        _settings = PureRelaySettings.fromJson(json);

        // Validate keys - if invalid, regenerate
        final validNpub = NostrKeyGenerator.isValidNpub(_settings.npub);
        final validNsec = NostrKeyGenerator.isValidNsec(_settings.nsec);

        if (!validNpub || !validNsec) {
          _log('WARN', 'Invalid station keys detected, regenerating...');
          // Generate new valid keys
          final newKeys = NostrKeys.forRelay();
          _settings = _settings.copyWith(
            npub: newKeys.npub,
            nsec: newKeys.nsec,
          );
          await saveSettings();
          _log('INFO', 'Generated and saved new station identity keys: npub=${_settings.npub.substring(0, 20)}...');
        }
        return true; // Settings existed
      }
      return false; // Fresh install
    } catch (e) {
      _log('ERROR', 'Failed to load settings: $e');
      return false;
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
  /// If no callsign provided, defaults to station's callsign
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

      // Load chat security (moderators, etc.)
      await _loadChatSecurity(chatPath);
    } catch (e) {
      _log('ERROR', 'Failed to load chat data: $e');
    }
  }

  /// Load chat security settings from {chatPath}/extra/security.json
  Future<void> _loadChatSecurity(String chatPath) async {
    try {
      final secFile = File('$chatPath/extra/security.json');
      if (await secFile.exists()) {
        final content = await secFile.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        _chatSecurityData = ChatSecurity.fromJson(json);
        _log('INFO', 'Loaded chat security: ${_chatSecurityData.getGlobalModerators().length} global moderators');
      }
    } catch (e) {
      _log('ERROR', 'Failed to load chat security: $e');
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
  /// Uses unified ChatFormat parser for consistency with client
  Future<void> _parseMessagesFromFile(ChatRoom room, File chatFile) async {
    try {
      final content = await chatFile.readAsString();
      final parsed = ChatFormat.parse(content);

      for (final p in parsed) {
        // Extract metadata fields
        final npub = p.getMeta('npub');
        final signature = p.getMeta('signature');
        final createdAtUnix = p.createdAt;
        final hasSig = signature != null && signature.isNotEmpty;

        // Parse timestamp from string or use created_at Unix timestamp
        final timestamp = createdAtUnix != null
            ? DateTime.fromMillisecondsSinceEpoch(createdAtUnix * 1000, isUtc: true)
            : ChatFormat.parseTimestamp(p.timestamp);

        // Reconstruct NOSTR event to get ID and verify signature
        String? eventId;
        bool verified = false;
        if (hasSig && npub != null) {
          final event = _reconstructNostrEvent(
            npub: npub,
            content: p.content,
            signature: signature,
            roomId: room.id,
            callsign: p.author,
            timestamp: timestamp,
            createdAtUnix: createdAtUnix,
          );
          if (event != null) {
            eventId = event.id;
            verified = event.verify();
          }
        }

        final msg = ChatMessage(
          id: eventId ?? DateTime.now().millisecondsSinceEpoch.toString(),
          roomId: room.id,
          senderCallsign: p.author,
          senderNpub: npub,
          signature: signature,
          content: p.content,
          timestamp: timestamp,
          verified: verified,
          hasSignature: hasSig,
          reactions: p.reactions,
          metadata: p.metadata,
        );
        _addChatMessage(room, msg);
      }
    } catch (e) {
      _log('ERROR', 'Failed to parse chat file ${chatFile.path}: $e');
    }
  }

  /// Add a chat message to a room with deduplication.
  /// Returns true if the message was added, false if it was a duplicate.
  /// Primary key: event ID (NOSTR event ID). Fallback: sender + timestamp within 2s window.
  bool _addChatMessage(ServerChatRoom room, ChatMessage msg) {
    // Check by event ID first (most reliable for signed messages)
    final msgId = msg.id;
    for (final existing in room.messages) {
      // Primary: exact event ID match (skip auto-generated millisecond IDs)
      if (msgId.length > 13 && existing.id == msgId) {
        return false;
      }
      // Fallback: same sender + timestamp within 2-second window
      if (existing.senderCallsign.toUpperCase() == msg.senderCallsign.toUpperCase() &&
          existing.content == msg.content &&
          (existing.timestamp.difference(msg.timestamp).abs().inSeconds <= 2)) {
        return false;
      }
    }
    room.messages.add(msg);
    return true;
  }

  /// Reconstruct a NOSTR event from stored message data
  /// Returns the event with calculated ID, or null if missing required data
  /// If createdAtUnix is provided, use it directly (from stored metadata)
  /// Otherwise fall back to calculating from timestamp DateTime
  NostrEvent? _reconstructNostrEvent({
    required String? npub,
    required String content,
    required String? signature,
    required String roomId,
    required String callsign,
    required DateTime timestamp,
    int? createdAtUnix,  // Direct Unix timestamp from client (preferred)
    bool debug = false,
  }) {
    if (npub == null || npub.isEmpty) return null;
    if (signature == null || signature.isEmpty) return null;

    try {
      final pubkey = NostrCrypto.decodeNpub(npub);
      // Prefer stored Unix timestamp (from client) over calculated from DateTime
      final createdAt = createdAtUnix ?? (timestamp.millisecondsSinceEpoch ~/ 1000);

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

      if (debug) {
        _log('DEBUG', 'Verify: npub=$npub');
        _log('DEBUG', 'Verify: pubkey=$pubkey');
        _log('DEBUG', 'Verify: timestamp=$timestamp createdAt=$createdAt');
        _log('DEBUG', 'Verify: content="$content" roomId=$roomId callsign=$callsign');
        _log('DEBUG', 'Verify: eventId=${event.id}');
        _log('DEBUG', 'Verify: sig=$signature');
      }

      return event;
    } catch (e) {
      if (debug) {
        _log('DEBUG', 'Verify reconstruction failed: $e');
      }
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

  /// Public method to verify a chat message
  bool verifyMessage(ChatMessage msg) {
    return _verifyStoredMessage(
      npub: msg.senderNpub,
      content: msg.content,
      signature: msg.signature,
      roomId: msg.roomId,
      callsign: msg.senderCallsign,
      timestamp: msg.timestamp,
    );
  }

  /// Parse timestamp from format YYYY-MM-DD HH:MM_ss
  /// Returns UTC DateTime to ensure consistent Unix timestamps for signature verification
  DateTime _parseTimestamp(String timestamp) {
    try {
      // Format: YYYY-MM-DD HH:MM_ss
      final parts = timestamp.split(' ');
      if (parts.length != 2) return DateTime.now().toUtc();

      final dateParts = parts[0].split('-');
      final timeParts = parts[1].replaceAll('_', ':').split(':');

      if (dateParts.length != 3 || timeParts.length != 3) return DateTime.now().toUtc();

      // Use UTC to ensure timestamps are consistent across timezones
      // This is critical for NOSTR signature verification
      return DateTime.utc(
        int.parse(dateParts[0]),
        int.parse(dateParts[1]),
        int.parse(dateParts[2]),
        int.parse(timeParts[0]),
        int.parse(timeParts[1]),
        int.parse(timeParts[2]),
      );
    } catch (e) {
      return DateTime.now().toUtc();
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

        // Write message metadata (file attachments, location, etc.)
        // Skip reserved keys that have special ordering
        const reservedKeys = {'created_at', 'npub', 'signature', 'verified', 'has_signature'};
        for (final entry in msg.metadata.entries) {
          if (reservedKeys.contains(entry.key)) continue;
          buffer.writeln('--> ${entry.key}: ${entry.value}');
        }

        // Write NOSTR metadata (order: created_at, npub, signature - signature MUST be last)
        if (msg.hasSignature) {
          buffer.writeln('--> created_at: ${msg.timestamp.millisecondsSinceEpoch ~/ 1000}');
        }
        if (msg.senderNpub != null && msg.senderNpub!.isNotEmpty) {
          buffer.writeln('--> npub: ${msg.senderNpub}');
        }
        if (msg.signature != null && msg.signature!.isNotEmpty) {
          buffer.writeln('--> signature: ${msg.signature}');
        }
        // Unsigned reactions (~~> prefix)
        final reactions = ReactionUtils.normalizeReactionMap(msg.reactions);
        if (reactions.isNotEmpty) {
          final entries = reactions.entries.toList()
            ..sort((a, b) => a.key.compareTo(b.key));
          for (final entry in entries) {
            final users = entry.value
                .map((u) => u.trim().toUpperCase())
                .where((u) => u.isNotEmpty)
                .toSet()
                .toList()
              ..sort();
            if (users.isEmpty) {
              continue;
            }
            buffer.writeln('~~> reaction: ${entry.key}=${users.join(',')}');
          }
        }
        // Two empty lines between messages for readability
        buffer.writeln();
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

  /// Reinitialize chat data for the current callsign.
  /// Call this after changing the station identity to ensure chat is stored
  /// under the correct callsign folder.
  Future<void> reinitializeChatForCurrentIdentity() async {
    // Clear existing chat rooms (they were created with the old callsign)
    _chatRooms.clear();

    // Load/create chat data with the new callsign
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

    _log('INFO', 'Chat reinitialized for callsign: ${_settings.callsign}');
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
        _settings = _settings.copyWith(description: value as String?);
        break;
      case 'location':
        _settings = _settings.copyWith(location: value as String?);
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
      case 'nostrRequireAuthForWrites':
        _settings = _settings.copyWith(nostrRequireAuthForWrites: value as bool);
        break;
      case 'blossomMaxStorageMb':
        _settings = _settings.copyWith(blossomMaxStorageMb: value as int);
        break;
      case 'blossomMaxFileMb':
        _settings = _settings.copyWith(blossomMaxFileMb: value as int);
        break;
      case 'latitude':
        _settings = _settings.copyWith(latitude: value as double?);
        break;
      case 'longitude':
        _settings = _settings.copyWith(longitude: value as double?);
        break;
      case 'stationRole':
        _settings = _settings.copyWith(stationRole: value as String);
        break;
      case 'networkId':
        _settings = _settings.copyWith(networkId: value as String?);
        break;
      case 'parentStationUrl':
        _settings = _settings.copyWith(parentStationUrl: value as String?);
        break;
      case 'setupComplete':
        _settings = _settings.copyWith(setupComplete: value as bool);
        break;
      case 'sslDomain':
        _settings = _settings.copyWith(sslDomain: value as String?);
        break;
      case 'sslEmail':
        _settings = _settings.copyWith(sslEmail: value as String?);
        break;
      case 'sslAutoRenew':
        _settings = _settings.copyWith(sslAutoRenew: value as bool);
        break;
      case 'enableSsl':
        _settings = _settings.copyWith(enableSsl: value as bool);
        break;
      case 'sslCertPath':
        _settings = _settings.copyWith(sslCertPath: value as String?);
        break;
      case 'sslKeyPath':
        _settings = _settings.copyWith(sslKeyPath: value as String?);
        break;
      default:
        throw ArgumentError('Unknown setting: $key');
    }
  }

  Future<bool> start() async {
    if (_running) {
      _log('WARN', 'Station server already running');
      return true;
    }

    // Sync embedded theme files to disk (overwrites outdated files)
    await _syncBundledThemes();

    // Reload settings to pick up any config changes
    await _loadSettings();
    await _initNostrServices();
    _nostrRelay?.requireAuthForWrites = _settings.nostrRequireAuthForWrites;
    if (_blossom != null) {
      _blossom!
        ..maxBytes = _settings.blossomMaxStorageMb * 1024 * 1024
        ..maxFileBytes = _settings.blossomMaxFileMb * 1024 * 1024;
    }

    // Load security lists (blacklist/whitelist)
    await loadSecurityLists();

    // Setup signal handlers for graceful shutdown (Linux/macOS only)
    _setupSignalHandlers();

    try {
      // Start HTTP server
      _httpServer = await HttpServer.bind(
        InternetAddress.anyIPv4,
        _settings.httpPort,
        shared: true,
      );

      _running = true;
      _startTime = DateTime.now();

      // Initialize NIP-05 registry for identity verification
      final nip05Registry = Nip05RegistryService();
      if (_dataDir != null) {
        nip05Registry.setProfileDirectory(_dataDir!);
      }
      await nip05Registry.init();
      // Set station owner for reserved nicknames
      if (_settings.npub != null) {
        nip05Registry.setStationOwner(_settings.npub!);
      }

      // Initialize GeoIP service for offline IP geolocation
      try {
        // Try to load from data directory first, then current directory
        final possiblePaths = [
          if (_dataDir != null) '$_dataDir/assets/dbip-city-lite.mmdb',
          'assets/dbip-city-lite.mmdb',
          '/opt/geogram/assets/dbip-city-lite.mmdb',
        ];

        for (final dbPath in possiblePaths) {
          if (await File(dbPath).exists()) {
            await GeoIpService().initFromFile(dbPath);
            _log('INFO', 'GeoIP database loaded from $dbPath');
            break;
          }
        }

        if (!GeoIpService().isInitialized) {
          _log('WARN', 'GeoIP database not found, IP geolocation will not be available');
        }
      } catch (e) {
        _log('WARN', 'GeoIP service initialization failed (non-critical): $e');
      }

      _log('INFO', 'HTTP server started on port ${_settings.httpPort}');

      _httpServer!.listen(_handleRequest, onError: (error) {
        _log('ERROR', 'HTTP server error: $error');
      });

      // Start update mirror polling
      _startUpdatePolling();

      // Start heartbeat timer for connection stability
      startHeartbeat();

      // Start health watchdog for auto-recovery
      startHealthWatchdog();

      // Download console VM files in background
      downloadAllConsoleVmFiles();

      // Configure email relay settings
      final emailRelay = EmailRelayService();
      emailRelay.settings.stationDomain = _settings.sslDomain ?? 'localhost';
      emailRelay.settings.smtpPort = _settings.smtpPort;
      emailRelay.settings.smtpEnabled = _settings.smtpEnabled;
      emailRelay.settings.dkimPrivateKey = _settings.dkimPrivateKey;
      emailRelay.settings.dkimSelector = 'geogram';
      // SMTP relay settings
      emailRelay.settings.smtpRelayHost = _settings.smtpRelayHost;
      emailRelay.settings.smtpRelayPort = _settings.smtpRelayPort;
      emailRelay.settings.smtpRelayUsername = _settings.smtpRelayUsername;
      emailRelay.settings.smtpRelayPassword = _settings.smtpRelayPassword;
      emailRelay.settings.smtpRelayStartTls = _settings.smtpRelayStartTls;

      _log('INFO', 'SMTP config: enabled=${_settings.smtpEnabled}, serverEnabled=${_settings.smtpServerEnabled}, port=${_settings.smtpPort}, domain=${_settings.sslDomain}, relay=${_settings.smtpRelayHost ?? "none"}');

      // Start SMTP server if enabled
      if (_settings.smtpServerEnabled && _settings.sslDomain != null) {
        _smtpServer = SMTPServer(
          port: _settings.smtpPort,
          domain: _settings.sslDomain!,
        );

        // Set up mail delivery callback
        _smtpServer!.onMailReceived = handleIncomingEmail;
        _smtpServer!.validateRecipient = validateLocalRecipient;

        final started = await _smtpServer!.start();
        if (started) {
          _log('INFO', 'SMTP server started on port ${_settings.smtpPort} for domain ${_settings.sslDomain}');
        } else {
          _log('WARN', 'Failed to start SMTP server on port ${_settings.smtpPort}');
          _smtpServer = null;
        }
      }

      // Start XMPP server if enabled (via XmppServerMixin)
      if (_settings.xmppServerEnabled && _settings.sslDomain != null) {
        await startXmppServer(
          dataDir: _dataDir ?? '.',
          domain: _settings.sslDomain!,
          callsign: _settings.callsign,
          port: _settings.xmppServerPort,
        );
      }

      // Start HTTPS server if SSL is enabled
      if (_settings.enableSsl) {
        // Check if we need to request certificates first
        final sslDir = _dataDir != null ? '$_dataDir/ssl' : null;
        final fullchainPath = sslDir != null ? '$sslDir/fullchain.pem' : null;
        // Check for both privkey.pem and domain.key (SslCertificateManager uses domain.key)
        final keyPath = sslDir != null ? '$sslDir/privkey.pem' : null;
        final altKeyPath = sslDir != null ? '$sslDir/domain.key' : null;

        bool certsExist = false;
        if (fullchainPath != null && await File(fullchainPath).exists()) {
          // Certificate exists, check for either key file
          if ((keyPath != null && await File(keyPath).exists()) ||
              (altKeyPath != null && await File(altKeyPath).exists())) {
            certsExist = true;
          }
        }

        if (!certsExist && _settings.sslDomain != null && _settings.sslEmail != null) {
          _log('INFO', 'SSL enabled but no certificates found. Requesting from Let\'s Encrypt...');
          try {
            final sslManager = SslCertificateManager(_settings, _dataDir ?? '.');
            sslManager.setStationServer(this);
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

      // Listen for content creation events and broadcast to connected clients
      EventBus().on<BlogPostPublishedEvent>((event) {
        _broadcastUpdate('UPDATE:${event.author}/blog/${event.postId}');
      });
      EventBus().on<EventCreatedEvent>((event) {
        _broadcastUpdate('UPDATE:${event.author}/events/${event.eventId}');
      });
      EventBus().on<PlaceCreatedEvent>((event) {
        _broadcastUpdate('UPDATE:${event.author}/places/${event.placeId}');
      });
      EventBus().on<AlertCreatedEvent>((event) {
        _broadcastUpdate('UPDATE:${event.author}/alerts/${event.alertId}');
      });

      // Start karma service
      await startKarmaService();

      return true;
    } catch (e) {
      _log('ERROR', 'Failed to start station server: $e');
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

    // Stop heartbeat timer
    stopHeartbeat();

    // Stop health watchdog
    stopHealthWatchdog();

    // Stop karma service
    stopKarmaService();

    // Close all client connections
    for (final client in _clients.values) {
      try {
        await client.socket.close();
      } catch (_) {
        // Socket may already be closed
      }
    }
    _clients.clear();

    // Clear pending proxy requests
    for (final completer in _pendingProxyRequests.values) {
      if (!completer.isCompleted) {
        completer.complete({
          'statusCode': 503,
          'responseBody': 'Server stopping',
        });
      }
    }
    _pendingProxyRequests.clear();

    await _httpServer?.close(force: true);
    _httpServer = null;

    await _httpsServer?.close(force: true);
    _httpsServer = null;

    // Stop SMTP server
    await _smtpServer?.stop();
    _smtpServer = null;

    // Stop XMPP server
    await stopXmppServer();

    _nostrRelay = null;
    _nostrStorage?.close();
    _nostrStorage = null;
    _blossom?.close();
    _blossom = null;

    _running = false;
    _startTime = null;

    _log('INFO', 'Station server stopped');
  }

  Future<void> restart() async {
    _log('INFO', 'Restarting station server...');
    await stop();
    await Future.delayed(const Duration(milliseconds: 500));
    await start();
  }

  /// Kick a device by callsign
  bool kickDevice(String callsign) {
    // Find client by callsign using safe null handling
    String? clientId;
    for (final entry in _clients.entries) {
      if (entry.value.callsign?.toLowerCase() == callsign.toLowerCase()) {
        clientId = entry.key;
        break;
      }
    }

    if (clientId != null) {
      _removeClient(clientId, reason: 'kicked');
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

  // Heartbeat methods provided by HeartbeatMixin

  // Health watchdog methods (startHealthWatchdog, stopHealthWatchdog, etc.) are now
  // provided by HealthWatchdogMixin - the mixin calls autoRecover() which delegates to _autoRecover()

  /// Perform auto-recovery: restart HTTP/HTTPS servers
  Future<void> _autoRecover() async {
    try {
      // Stop accepting new connections
      _running = false;

      // Close existing servers forcefully
      await _httpServer?.close(force: true);
      await _httpsServer?.close(force: true);
      _httpServer = null;
      _httpsServer = null;

      // Brief pause to let connections drain
      await Future.delayed(const Duration(seconds: 1));

      // Restart HTTP server
      _httpServer = await HttpServer.bind(
        InternetAddress.anyIPv4,
        _settings.httpPort,
        shared: true,
      );
      _httpServer!.listen(_handleRequest, onError: (error) {
        _log('ERROR', 'HTTP server error: $error');
      });
      _log('INFO', 'HTTP server restarted on port ${_settings.httpPort}');

      // Restart HTTPS server if enabled
      if (_settings.enableSsl) {
        await _startHttpsServer();
      }

      // Reset attack metrics
      resetWatchdogMetrics();

      _running = true;
      _log('INFO', 'Auto-recovery complete - server restarted');
    } catch (e) {
      _logCrash('AUTO-RECOVERY FAILED: $e');
      // If recovery fails, exit to let systemd restart the whole process
      exit(1);
    }
  }

  // ============ End Server Health Watchdog ============

  /// Safely send data to a WebSocket client, handling errors gracefully
  bool _safeSocketSend(PureConnectedClient client, String data) {
    try {
      client.socket.add(data);
      return true;
    } catch (e) {
      _log('ERROR', 'Failed to send to ${client.callsign ?? client.id}: $e');
      // Mark for removal on next heartbeat by setting lastActivity far in the past
      client.lastActivity = DateTime.fromMillisecondsSinceEpoch(0);
      return false;
    }
  }

  /// Generate a random 32-byte hex nonce for challenge-response
  String _generateChallengeNonce() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Remove a client and clean up associated resources
  void _removeClient(String clientId, {String reason = 'disconnected'}) {
    final client = _clients.remove(clientId);
    if (client == null) return;
    _log('INFO', 'Client removed: ${client.callsign ?? clientId} - reason: $reason (remaining clients: ${_clients.length})');

    // Store disconnect info for reconnection tolerance
    if (client.callsign != null) {
      final callsignKey = client.callsign!.toUpperCase();
      _disconnectInfo[callsignKey] = (
        disconnectTime: DateTime.now(),
        originalConnectTime: client.connectedAt,
      );
    }

    // Try to close the socket gracefully
    try {
      client.socket.close();
    } catch (_) {
      // Socket may already be closed
    }

    // Clean up any pending proxy requests for this client
    _cleanupPendingRequestsForClient(client);

    // Clean up conference rooms hosted by this client
    conferenceHandleClientDisconnect(clientId);

    _log('INFO', 'Client removed: ${client.callsign ?? clientId} ($reason)');
  }

  /// Clean up pending proxy requests that were waiting for a disconnected client
  void _cleanupPendingRequestsForClient(PureConnectedClient client) {
    // Find and complete any pending requests that might be waiting for this client
    // This prevents memory leaks and hanging requests
    final keysToRemove = <String>[];

    for (final entry in _pendingProxyRequests.entries) {
      // We can't easily determine which requests are for this client
      // but we can at least prevent memory buildup by timing out old requests
      // The timeout mechanism should handle this, but we log it for awareness
    }

    if (keysToRemove.isNotEmpty) {
      for (final key in keysToRemove) {
        final completer = _pendingProxyRequests.remove(key);
        if (completer != null && !completer.isCompleted) {
          completer.complete({
            'statusCode': 503,
            'responseBody': 'Client disconnected',
          });
        }
      }
    }
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
          'type': data['station_mode'] == true ? 'station' : 'device',
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

    // Use UTC for consistent timestamp handling across timezones
    // This is critical for NOSTR signature verification
    final now = DateTime.now().toUtc();
    String? signature;
    String? senderNpub;

    // Try to sign the message if we have valid keys
    if (_settings.npub.isNotEmpty && _settings.nsec.isNotEmpty) {
      try {
        final createdAt = now.millisecondsSinceEpoch ~/ 1000;

        // Get public key from npub
        final pubkeyHex = NostrCrypto.decodeNpub(_settings.npub);

        // Create NOSTR event with chat tags
        final event = NostrEvent(
          pubkey: pubkeyHex,
          createdAt: createdAt,
          kind: 1,
          tags: [['t', 'chat'], ['room', roomId], ['callsign', _settings.callsign]],
          content: content,
        );

        // Calculate ID and sign with nsec
        event.calculateId();
        event.signWithNsec(_settings.nsec);

        signature = event.sig;
        senderNpub = _settings.npub;

        // Self-verify the signature
        final selfVerified = event.verify();
        if (!selfVerified) {
          _log('WARN', 'Self-verification of message signature failed!');
        }
      } catch (e) {
        _log('WARN', 'Failed to sign message: $e');
      }
    }

    // Verify the message we just created
    bool verified = false;
    if (signature != null && senderNpub != null) {
      final verifyEvent = _reconstructNostrEvent(
        npub: senderNpub,
        content: content,
        signature: signature,
        roomId: roomId,
        callsign: _settings.callsign,
        timestamp: now,
        createdAtUnix: now.millisecondsSinceEpoch ~/ 1000,
      );
      verified = verifyEvent?.verify() ?? false;
    }

    final message = ChatMessage(
      id: now.millisecondsSinceEpoch.toString(),
      roomId: roomId,
      senderCallsign: _settings.callsign,
      senderNpub: senderNpub,
      signature: signature,
      content: content,
      timestamp: now,
      verified: verified,  // Set verification status
      hasSignature: signature != null,
    );
    if (!_addChatMessage(room, message)) return; // Duplicate, skip
    room.lastActivity = now;
    _stats.totalMessages++;
    _stats.lastMessage = now;

    // Fire event for subscribers
    _fireChatMessageEvent(message);

    // Persist to disk
    await _saveRoomMessages(roomId);

    // Broadcast to connected clients
    final payload = jsonEncode({
      'type': 'chat_message',
      'room': roomId,
      'message': message.toJson(),
    });
    final updateNotification = 'UPDATE:${_settings.callsign}/chat/$roomId';
    for (final client in _clients.values) {
      try {
        client.socket.add(payload);
        client.socket.add(updateNotification);
      } catch (_) {}
    }
  }

  /// Fire a ChatMessageEvent for a message
  void _fireChatMessageEvent(ChatMessage msg) {
    _eventBus.fire(ChatMessageEvent(
      roomId: msg.roomId,
      callsign: msg.senderCallsign,
      content: msg.content,
      npub: msg.senderNpub,
      signature: msg.signature,
      verified: msg.verified,
    ));

    // Record chat message karma (with anti-gaming validation)
    karmaRecordChatMessage(
      callsign: msg.senderCallsign,
      content: msg.content,
      roomId: msg.roomId,
    );
  }

  List<ChatMessage> getChatHistory(String roomId, {int limit = 20, String? before}) {
    final room = _chatRooms[roomId];
    if (room == null) return [];
    var messages = room.messages;
    if (before != null) {
      final beforeDt = DateTime.tryParse(before);
      if (beforeDt != null) {
        final idx = messages.lastIndexWhere((m) => m.timestamp.isBefore(beforeDt));
        if (idx < 0) return [];
        messages = messages.sublist(0, idx + 1);
      }
    }
    if (messages.length <= limit) return messages.toList();
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
    final ip = request.connectionInfo?.remoteAddress.address ?? 'unknown';
    final stopwatch = Stopwatch()..start();
    _stats.totalApiRequests++;
    recordRequestForWatchdog();  // Track for health watchdog

    try {
      // Exempt safe, high-traffic paths from rate limiting:
      // - Tile requests (map tiles, high volume by nature)
      // - Root page and static web assets
      // - Public API status/karma endpoints
      final isExemptPath = path.startsWith('/tiles/') ||
          path == '/' ||
          path.startsWith('/web/') ||
          path == '/api/status' ||
          path.startsWith('/api/karma/leaderboard') ||
          path == '/api/karma/stats' ||
          path == '/favicon.ico';

      // Check if IP is banned (only for non-exempt paths)
      if (!isExemptPath && isIpBanned(ip)) {
        recordErrorForWatchdog();  // Track for attack detection
        request.response.statusCode = 429;
        request.response.write('Too Many Requests');
        await request.response.close();
        stopwatch.stop();
        _logAccess(ip, method, path, 429, stopwatch.elapsedMilliseconds,
            request.headers.value('user-agent'));
        return;
      }

      // Check rate limits (only for non-exempt paths)
      if (!isExemptPath && !checkRateLimit(ip)) {
        recordErrorForWatchdog();  // Track for attack detection
        banIp(ip);
        request.response.statusCode = 429;
        request.response.write('Rate limit exceeded');
        await request.response.close();
        stopwatch.stop();
        _logAccess(ip, method, path, 429, stopwatch.elapsedMilliseconds,
            request.headers.value('user-agent'));
        return;
      }

      if (WebSocketTransformer.isUpgradeRequest(request)) {
        incrementConnection(ip);
        try {
          await _handleWebSocket(request);
        } finally {
          decrementConnection(ip);
        }
        return;
      }

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

      if (path == '/api/status' || path == '/status') {
        await _handleStatus(request);
      } else if (path.startsWith('/blossom')) {
        await _handleBlossomRequest(request);
      } else if (path == '/api/geoip') {
        await _handleGeoIp(request);
      } else if (path == '/station/status') {
        await _handleRelayStatus(request);
      } else if (path == '/api/stats') {
        await _handleStats(request);
      } else if (path == '/api/logs') {
        await _handleLogs(request);
      } else if (path == '/api/updates/latest') {
        await _handleUpdatesLatest(request);
      } else if (path.startsWith('/updates/')) {
        await _handleUpdateDownload(request);
      } else if (path == '/api/devices' || path == '/api/clients') {
        await _handleDevices(request);
      } else if (path.startsWith('/device/')) {
        await _handleDeviceProxy(request);
      } else if (path == '/search') {
        await _handleSearch(request);
      } else if (ChatApi.isRoomCrudPath(path)) {
        // DELETE/PUT /api/chat/rooms/{roomId}
        final callsign = ChatApi.extractCallsign(path) ?? _settings.callsign;
        await _handleChatRoomCrud(request, callsign);
      } else if (ChatApi.isRoomsPath(path)) {
        // /{callsign}/api/chat/rooms OR /api/chat/rooms
        final callsign = ChatApi.extractCallsign(path) ?? _settings.callsign;
        await _handleChatRooms(request, callsign);
      } else if (ChatApi.isMessagesPath(path)) {
        // Accepts both formats:
        // - /api/chat/{roomId}/messages (unified)
        // - /api/chat/rooms/{roomId}/messages (legacy)
        // - /{callsign}/api/chat/{roomId}/messages (remote unified)
        // - /{callsign}/api/chat/rooms/{roomId}/messages (remote legacy)
        final callsign = ChatApi.extractCallsign(path) ?? _settings.callsign;
        await _handleRoomMessages(request, callsign);
      } else if (_isChatReactionPath(path)) {
        final callsign = _parseCallsignFromPath(path) ?? _settings.callsign;
        await _handleRoomMessageReactions(request, callsign);
      } else if (_isChatFilesListPath(path) && method == 'POST') {
        // POST /{callsign}/api/chat/{roomId}/files - upload file to chat room
        final callsign = ChatApi.extractCallsign(path) ?? _settings.callsign;
        await _handleChatFileUpload(request, callsign);
      } else if (_isChatFilesListPath(path)) {
        // GET /{callsign}/api/chat/{roomId}/files - list chat files for caching
        final callsign = ChatApi.extractCallsign(path) ?? _settings.callsign;
        await _handleChatFilesList(request, callsign);
      } else if (_isChatFileDownloadPath(path)) {
        // GET /{callsign}/api/chat/{roomId}/files/{filename} - download chat file
        final callsign = ChatApi.extractCallsign(path) ?? _settings.callsign;
        await _handleChatFileDownload(request, callsign);
      } else if (_isChatFileContentPath(path)) {
        // /{callsign}/api/chat/{roomId}/file/{year}/{filename} - get raw chat file
        final callsign = ChatApi.extractCallsign(path) ?? _settings.callsign;
        await _handleChatFileContent(request, callsign);
      } else if (path == '/api/station/send' && method == 'POST') {
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
      } else if (path.startsWith('/bot/models/')) {
        await _handleBotModelRequest(request);
      } else if (path.startsWith('/console/vm/')) {
        await _handleConsoleVmRequest(request);
      } else if (path == '/api/cli' && method == 'POST') {
        await _handleCliCommand(request);
      } else if (path == '/alerts') {
        await _handleAlertsPage(request);
      } else if (path == '/api/alerts' || path == '/api/alerts/list') {
        await _handleAlertsApi(request);
      } else if (path == '/api/places' || path == '/api/places/list') {
        await _handlePlacesApi(request);
      } else if (path == '/api/events' || path == '/api/events/list' || path.startsWith('/api/events/')) {
        await _handleEventsRequest(request);
      } else if (path == '/api/email/queue') {
        await _handleEmailQueue(request);
      } else if (path.startsWith('/api/email/approve/')) {
        await _handleEmailApprove(request);
      } else if (path.startsWith('/api/email/reject/')) {
        await _handleEmailReject(request);
      } else if (path == '/api/email/allowlist') {
        await _handleEmailAllowlist(request);
      } else if (path.startsWith('/api/karma/')) {
        await handleKarmaRequest(request);
      } else if (path.startsWith('/api/feedback/')) {
        await _handleFeedbackApi(request);
      } else if (path.startsWith('/api/alerts/') && method == 'POST') {
        // Handle alert feedback: /api/alerts/{alertId}/{action}
        await _handleAlertFeedback(request);
      } else if (path == '/.well-known/nostr.json') {
        await _handleWellKnownNostr(request);
      } else if (path == '/') {
        await _handleRoot(request);
      } else if (path == '/download' || path == '/download/') {
        await _handleDownload(request);
      } else if (path == '/styles.css') {
        await _handleThemeFile('styles.css', request);
      } else if (path.endsWith('/styles.css') && path.split('/').length == 3) {
        // Serve app-specific CSS: /chat/styles.css, /blog/styles.css, etc.
        final app = path.split('/')[1];
        await _handleThemeFile('$app/styles.css', request);
      } else if (path == '/lib/nostr.bundle.js') {
        // Serve embedded nostr-tools bundle for client-side key generation
        request.response.headers.set('Content-Type', 'application/javascript');
        request.response.headers.set('Cache-Control', 'public, max-age=86400');
        request.response.write(getNostrBundleJs());
        await request.response.close();
      } else if (path == '/chat' || path == '/chat/') {
        await _handleChatPage(request);
      } else if (_isAlertFileUploadPath(path) && method == 'POST') {
        // /{callsign}/api/alerts/{alertId}/files/{filename} - upload alert photo
        await _handleAlertFileUpload(request);
      } else if (_isAlertFileUploadPath(path) && method == 'GET') {
        // /{callsign}/api/alerts/{alertId}/files/{filename} - serve alert photo
        await _handleAlertFileServe(request);
      } else if (placeApi.isFileUploadPath(path) && method == 'POST') {
        // /{callsign}/api/places/files/{path} - upload place file
        await placeApi.uploadFile(request);
      } else if (placeApi.isFileUploadPath(path) && method == 'GET') {
        // /{callsign}/api/places/files/{path} - serve place file
        await placeApi.serveFile(request);
      } else if (_isAlertDetailsPath(path) && method == 'GET') {
        // /{callsign}/api/alerts/{alertId} - serve local alert details with photos list
        await _handleAlertDetails(request);
      } else if (_isPlaceDetailsPath(path) && method == 'GET') {
        // /api/places/{callsign}/{folderName} - place details
        await _handlePlaceDetails(request);
      } else if (_isCallsignApiPath(path) || _isCallsignMeetPath(path)) {
        // /{callsign}/api/* or /{callsign}/meet/* - proxy to connected device
        await _handleCallsignApiProxy(request);
      } else if (isBlogPath(path)) {
        await handleBlogRequest(request);
      } else if (_isCallsignOrNicknamePath(path)) {
        await _handleCallsignOrNicknameWww(request);
      } else {
        request.response.statusCode = 404;
        request.response.write('Not Found');
      }
    } catch (e) {
      recordErrorForWatchdog();  // Track for attack detection
      _log('ERROR', 'Request error: $e');
      request.response.statusCode = 500;
      request.response.write('Internal Server Error');
    }

    await request.response.close();
    stopwatch.stop();
    _logAccess(ip, method, path, request.response.statusCode, stopwatch.elapsedMilliseconds,
        request.headers.value('user-agent'));
  }

  Future<void> _handleWebSocket(HttpRequest request) async {
    try {
      final socket = await WebSocketTransformer.upgrade(request);
      final clientId = DateTime.now().millisecondsSinceEpoch.toString();
      final isOpenRelay = _isOpenRelayPath(request.uri.path);
      final client = PureConnectedClient(
        socket: socket,
        id: clientId,
        address: request.connectionInfo?.remoteAddress.address,
      );

      // Generate challenge nonce for HELLO protocol v2
      final nonce = _generateChallengeNonce();
      client.pendingChallenge = nonce;

      _clients[clientId] = client;
      _stats.totalConnections++;
      _stats.lastConnection = DateTime.now();
      _log('INFO', 'WebSocket client connected: $clientId from ${client.address} (total clients: ${_clients.length})');

      // Send challenge to client
      final challenge = {
        'type': 'challenge',
        'nonce': nonce,
        'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      };
      socket.add(jsonEncode(challenge));

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
          _log('ERROR', 'WebSocket error for ${client.callsign ?? clientId}: $error');
          _removeClient(clientId, reason: 'error: $error');
        },
        cancelOnError: false, // Keep listening even after errors to handle graceful cleanup
      );
    } catch (e) {
      _log('ERROR', 'WebSocket upgrade failed: $e');
    }
  }

  void _handleWebSocketMessage(PureConnectedClient client, dynamic data) {
    try {
      client.lastActivity = DateTime.now();

      if (data is String) {
        final decoded = jsonDecode(data);
        if (decoded is List) {
          _nostrRelay?.handleFrame(client.id, decoded);
          return;
        }

        final message = decoded as Map<String, dynamic>;
        final type = message['type'] as String?;

        switch (type) {
          case 'hello':
            // Extract client info - support both direct fields and Nostr event format
            String? callsign = message['callsign'] as String?;
            String? nickname = message['nickname'] as String?;
            String? deviceType = message['device_type'] as String?;
            String? version = message['version'] as String?;

            // Check for Nostr event format (used by desktop/mobile clients)
            // Support both Map and JSON string formats (some clients may double-encode)
            Map<String, dynamic>? event;
            final eventRaw = message['event'];
            if (eventRaw is Map<String, dynamic>) {
              event = eventRaw;
            } else if (eventRaw is Map) {
              // Handle Map<dynamic, dynamic> from JSON parsing
              event = Map<String, dynamic>.from(eventRaw);
            } else if (eventRaw is String && eventRaw.isNotEmpty) {
              // Handle JSON string (client may have double-encoded)
              try {
                final parsed = jsonDecode(eventRaw);
                if (parsed is Map) {
                  event = Map<String, dynamic>.from(parsed);
                  _log('WARN', 'HELLO event was double-encoded as string, parsed successfully');
                }
              } catch (e) {
                _log('WARN', 'Failed to parse HELLO event string: $e');
              }
            }
            double? latitude;
            double? longitude;
            String? color;
            String? npub;
            if (event != null) {
              // Extract npub from event pubkey (hex -> npub format)
              final pubkey = event['pubkey'] as String?;
              if (pubkey != null && pubkey.isNotEmpty) {
                npub = NostrCrypto.encodeNpub(pubkey);
              }

              // Extract callsign, nickname, platform, color, and coordinates from event tags
              final tags = event['tags'] as List<dynamic>?;
              String? platform;
              if (tags != null) {
                for (final tag in tags) {
                  if (tag is List && tag.length >= 2) {
                    if (tag[0] == 'callsign') {
                      callsign = tag[1] as String?;
                    } else if (tag[0] == 'nickname') {
                      nickname = tag[1] as String?;
                    } else if (tag[0] == 'platform') {
                      platform = tag[1] as String?;
                    } else if (tag[0] == 'color') {
                      color = tag[1] as String?;
                    } else if (tag[0] == 'latitude') {
                      latitude = double.tryParse(tag[1].toString());
                    } else if (tag[0] == 'longitude') {
                      longitude = double.tryParse(tag[1].toString());
                    }
                  }
                }
              }
              // Set device type from platform tag or detect from content
              if (platform != null) {
                // Use platform tag directly (Android, iOS, Web, Linux, Windows, macOS)
                if (platform == 'Android' || platform == 'iOS') {
                  deviceType = 'mobile';
                } else if (platform == 'Web') {
                  deviceType = 'web';
                } else {
                  deviceType = 'desktop';
                }
                // Store the actual platform for more specific identification
                client.platform = platform;
              } else {
                // Fallback: detect device type from content
                final content = event['content'] as String? ?? '';
                if (content.contains('Android') || content.contains('iOS')) {
                  deviceType = 'mobile';
                } else if (content.contains('Web')) {
                  deviceType = 'web';
                } else {
                  deviceType = 'desktop';
                }
              }
            }

            // npub is mandatory - reject HELLO if missing
            if (npub == null || npub.isEmpty) {
              final response = {
                'type': 'hello_ack',
                'success': false,
                'error': 'npub is required for HELLO',
                'station_id': _settings.callsign,
              };
              client.socket.add(jsonEncode(response));
              _log('WARN', 'HELLO rejected: missing npub from ${callsign ?? "unknown"}');
              break;
            }

            // Protocol versioning and challenge-response verification
            final protocol = message['protocol'] as int? ?? 1;
            client.helloProtocol = protocol;

            if (protocol >= 2 && event != null) {
              // v2: Verify challenge-response
              final verifyError = NostrEvent.verifyHelloEvent(
                eventJson: event,
                expectedChallenge: client.pendingChallenge,
              );
              if (verifyError != null) {
                final response = {
                  'type': 'hello_ack',
                  'success': false,
                  'error': 'identity_verification_failed',
                  'message': verifyError,
                  'station_id': _settings.callsign,
                };
                client.socket.add(jsonEncode(response));
                _log('SECURITY', 'HELLO v2 rejected: $verifyError (client: ${client.id})');
                _removeClient(client.id, reason: 'identity_verification_failed');
                break;
              }
              client.verified = true;
              _log('INFO', 'HELLO v2 verified for ${callsign ?? npub}');
            } else {
              // v1 legacy: accept but log security warning
              _log('SECURITY', 'HELLO v1 (legacy, no challenge verification) from ${callsign ?? npub} (client: ${client.id})');
            }

            // Clear the pending challenge (consumed)
            client.pendingChallenge = null;

            // SECURITY: Check for NIP-05 callsign collision before proceeding
            // This prevents email impersonation and misdelivery
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
                _log('SECURITY', 'HELLO rejected: callsign "$callsign" collision - '
                    'attempting npub ${npub.substring(0, 20)}... but registered to '
                    '${conflictingNpub.substring(0, 20)}...');
                _removeClient(client.id, reason: 'callsign_npub_mismatch');
                break;
              }
            }

            // NIP-05: Log nickname collision but do NOT disconnect — nicknames are
            // display names, not identity anchors.  Multiple npubs may share one.
            if (nickname != null && nickname.toLowerCase() != callsign?.toLowerCase()) {
              final registry = Nip05RegistryService();
              final conflictingNpub = registry.checkCollision(nickname, npub);
              if (conflictingNpub != null) {
                _log('INFO', 'NIP-05: nickname "$nickname" already registered to '
                    '${conflictingNpub.substring(0, 20)}... — skipping nickname registration for ${npub.substring(0, 20)}...');
              }
            }

            // DEDUP: Only close connections from the SAME remote address (same device reconnecting).
            // Multiple devices with the same callsign+npub are now legitimate (multi-device support).
            if (callsign != null && npub != null && client.address != null) {
              final callsignUpper = callsign.toUpperCase();
              final zombies = _clients.values.where((c) =>
                c.id != client.id &&
                c.callsign != null &&
                c.callsign!.toUpperCase() == callsignUpper &&
                c.npub == npub &&
                c.address == client.address  // Same physical device reconnecting
              ).toList();

              for (final zombie in zombies) {
                _log('INFO', 'Closing zombie connection for $callsign from same address ${client.address} (id: ${zombie.id}, replacing with ${client.id})');
                _removeClient(zombie.id, reason: 'replaced_by_same_device');
              }
            }

            client.callsign = callsign;
            client.nickname = nickname;
            client.color = color;
            client.npub = npub;
            client.deviceType = deviceType;
            client.version = version;
            client.latitude = latitude;
            client.longitude = longitude;

            // Check for reconnection within tolerance period - restore original connect time
            if (callsign != null) {
              final callsignKey = callsign.toUpperCase();
              final info = _disconnectInfo[callsignKey];
              if (info != null) {
                final timeSinceDisconnect = DateTime.now().difference(info.disconnectTime);
                if (timeSinceDisconnect <= _reconnectTolerance) {
                  // Reconnected within tolerance - restore original connect time
                  client.connectedAt = info.originalConnectTime;
                  _log('INFO', 'Restored original connect time for $callsign (reconnected within ${timeSinceDisconnect.inSeconds}s)');
                }
                // Clean up the entry
                _disconnectInfo.remove(callsignKey);
              }
              // Clean up old entries (older than tolerance period)
              final now = DateTime.now();
              _disconnectInfo.removeWhere((_, v) => now.difference(v.disconnectTime) > _reconnectTolerance);
            }

            // Register for NIP-05 identity verification
            if (callsign != null && npub != null) {
              if (!Nip05RegistryService().registerIdentity(callsign, npub, nickname: nickname)) {
                _log('WARN', 'NIP-05: Identity $callsign/$nickname already registered to different npub');
              }
            }

            // Send hello_ack (expected by desktop/mobile clients)
            final response = {
              'type': 'hello_ack',
              'success': true,
              'station_id': _settings.callsign,
              'station_npub': _settings.npub,
              'message': 'Welcome to ${_settings.name}',
              'version': cliAppVersion,
            };
            client.socket.add(jsonEncode(response));
            final nicknameInfo = client.nickname != null ? ' [${client.nickname}]' : '';
            _log('INFO', 'Hello from: ${client.callsign ?? "unknown"}$nicknameInfo (${client.deviceType ?? "unknown"}) npub=${npub.substring(0, 20)}...');

            // Record daily login karma
            if (callsign != null) {
              karmaRecord(callsign: callsign, action: 'daily_login');
            }

            // Deliver any pending emails for this client
            if (callsign != null) {
              deliverPendingEmails(client, callsign);
            }
            break;

          case 'PING':
            // Respond to PING with PONG
            final response = {
              'type': 'PONG',
              'timestamp': DateTime.now().millisecondsSinceEpoch,
            };
            _safeSocketSend(client, jsonEncode(response));
            break;

          case 'PONG':
            // Client responded to our ping - just update activity time
            break;

          case 'REGISTER':
            // Device registration with capabilities
            final registerCallsign = message['callsign'] as String?;
            client.callsign = registerCallsign;
            client.deviceType = message['device_type'] as String?;
            client.version = message['version'] as String?;

            // Check for reconnection within tolerance period
            if (registerCallsign != null) {
              final callsignKey = registerCallsign.toUpperCase();
              final info = _disconnectInfo[callsignKey];
              if (info != null) {
                final timeSinceDisconnect = DateTime.now().difference(info.disconnectTime);
                if (timeSinceDisconnect <= _reconnectTolerance) {
                  client.connectedAt = info.originalConnectTime;
                  _log('INFO', 'Restored original connect time for $registerCallsign (reconnected within ${timeSinceDisconnect.inSeconds}s)');
                }
                _disconnectInfo.remove(callsignKey);
              }
              final now = DateTime.now();
              _disconnectInfo.removeWhere((_, v) => now.difference(v.disconnectTime) > _reconnectTolerance);
            }

            // Capabilities and collections are provided but not stored yet
            // Future: store these for device capability discovery
            // message['capabilities'] as List<dynamic>?;
            // message['collections'] as List<dynamic>?;

            final response = {
              'type': 'REGISTER_ACK',
              'success': true,
              'station_callsign': _settings.callsign,
              'station_version': cliAppVersion,
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

          case 'APPS_REQUEST':
            // Request for device's collections
            final targetCallsign = message['callsign'] as String?;
            if (targetCallsign != null) {
              // Forward to the target device
              PureConnectedClient? targetClient;
              try {
                targetClient = _clients.values.firstWhere(
                  (c) => c.callsign?.toLowerCase() == targetCallsign.toLowerCase(),
                );
              } catch (_) {
                // Not found
              }

              if (targetClient != null) {
                final forwardMsg = {
                  'type': 'APPS_REQUEST',
                  'from': client.callsign,
                  'requestId': message['requestId'],
                };
                try {
                  targetClient.socket.add(jsonEncode(forwardMsg));
                } catch (e) {
                  _log('ERROR', 'Failed to forward APPS_REQUEST: $e');
                }
              } else {
                // Device not connected
                final errorResponse = {
                  'type': 'APPS_RESPONSE',
                  'requestId': message['requestId'],
                  'error': 'Device not connected',
                  'callsign': targetCallsign,
                };
                client.socket.add(jsonEncode(errorResponse));
              }
            }
            break;

          case 'APPS_RESPONSE':
            // Forward collection response to the requester
            final fromCallsign = message['from'] as String?;
            if (fromCallsign != null) {
              PureConnectedClient? requester;
              try {
                requester = _clients.values.firstWhere(
                  (c) => c.callsign?.toLowerCase() == fromCallsign.toLowerCase(),
                );
              } catch (_) {
                // Not found
              }
              if (requester != null) {
                try {
                  requester.socket.add(data);
                } catch (e) {
                  _log('ERROR', 'Failed to forward APPS_RESPONSE: $e');
                }
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
                final createdAt = message['created_at'] as int?;
                final hasSig = signature != null && signature.isNotEmpty;

                // Derive npub from pubkey if not provided
                String? npub = message['npub'] as String?;
                if ((npub == null || npub.isEmpty) && pubkey != null && pubkey.isNotEmpty) {
                  try {
                    npub = NostrCrypto.encodeNpub(pubkey);
                  } catch (_) {}
                }

                // Use client's created_at for verification (they signed with this timestamp)
                // Fall back to current time if not provided
                final now = DateTime.now().toUtc();
                final msgTimestamp = createdAt != null
                    ? DateTime.fromMillisecondsSinceEpoch(createdAt * 1000, isUtc: true)
                    : now;
                final msgCreatedAt = createdAt ?? (now.millisecondsSinceEpoch ~/ 1000);

                // Verify signature if present
                bool isVerified = false;
                if (hasSig && pubkey != null && pubkey.isNotEmpty && eventId != null) {
                  try {
                    final event = NostrEvent(
                      id: eventId,
                      pubkey: pubkey,
                      createdAt: msgCreatedAt,
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
                  id: eventId ?? now.millisecondsSinceEpoch.toString(),
                  roomId: roomId,
                  senderCallsign: client.callsign!,
                  senderNpub: npub,
                  signature: signature,
                  content: content,
                  timestamp: msgTimestamp,
                  verified: isVerified,
                  hasSignature: hasSig,
                );
                if (!_addChatMessage(room, msg)) {
                  _log('DEBUG', 'Duplicate chat_message skipped from ${client.callsign}');
                  break;
                }
                room.lastActivity = now;
                _stats.totalMessages++;
                _stats.lastMessage = DateTime.now();

                // Fire event for subscribers
                _fireChatMessageEvent(msg);

                // Persist to disk
                _saveRoomMessages(roomId);

                // Broadcast to other clients
                final payload = jsonEncode({
                  'type': 'chat_message',
                  'room': roomId,
                  'message': msg.toJson(),
                });
                // Also send UPDATE notification for real-time refresh
                final updateNotification = 'UPDATE:${_settings.callsign}/chat/$roomId';
                for (final c in _clients.values) {
                  if (c.id != client.id) {
                    try {
                      c.socket.add(payload);
                      c.socket.add(updateNotification);
                    } catch (_) {}
                  }
                }
              }
            }
            break;

          // WebRTC signaling relay - forward offers, answers, and ICE candidates
          case 'webrtc_offer':
          case 'webrtc_answer':
          case 'webrtc_ice':
          case 'webrtc_bye':
            _handleWebRTCSignaling(client, message);
            break;

          // Conference signaling relay
          case 'conference_create':
          case 'conference_join':
          case 'conference_leave':
          case 'conference_end':
          case 'conference_signal':
          case 'conference_list':
          case 'conference_role_change':
          case 'conference_speaker_request':
          case 'conference_chat_message':
          case 'conference_chat_history':
          case 'conference_screen_share_request':
          case 'conference_screen_share_permission':
          case 'conference_screen_share_state':
          case 'conference_screen_share_stop':
            handleConferenceMessage(client.id, message);
            break;

          // Email relay - forward emails between connected clients
          case 'email_send':
            handleEmailSend(client, message);
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

  bool _isOpenRelayPath(String path) {
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) return true;
    final first = segments.first;
    if (_looksLikeCallsign(first)) return false;
    return true;
  }

  bool _looksLikeCallsign(String value) {
    return RegExp(r'^x[0-9a-z]{3,}$', caseSensitive: false).hasMatch(value);
  }

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
    if (_settings.npub.isNotEmpty) {
      allowed.add(NostrCrypto.decodeNpub(_settings.npub));
    }

    final contactsPath = path.join(PureStorageConfig().getCallsignDir(_settings.callsign), 'contacts');
    final contactService = ContactService();
    contactService.setStorage(FilesystemProfileStorage(contactsPath));
    await contactService.initializeApp(contactsPath);
    final contacts = await contactService.loadAllContactsRecursively();
    for (final contact in contacts) {
      final npub = contact.npub;
      if (npub != null && npub.isNotEmpty) {
        try {
          allowed.add(NostrCrypto.decodeNpub(npub));
        } catch (_) {}
      }
    }

    return allowed;
  }

  Future<void> _handleBlossomRequest(HttpRequest request) async {
    final path = request.uri.path;
    final method = request.method;

    if (_blossom == null) {
      request.response.statusCode = 503;
      request.response.write(jsonEncode({'error': 'Blossom not initialized'}));
      await request.response.close();
      return;
    }

    if (method == 'POST' && path == '/blossom/upload') {
      await _handleBlossomUpload(request);
      return;
    }

    if (path.startsWith('/blossom/')) {
      final hash = path.substring('/blossom/'.length);
      if (method == 'GET' || method == 'HEAD') {
        await _handleBlossomDownload(request, hash);
        return;
      }
      if (method == 'DELETE') {
        await _handleBlossomDelete(request, hash);
        return;
      }
    }

    request.response.statusCode = 404;
    request.response.write('Not Found');
    await request.response.close();
  }

  Future<void> _handleBlossomDelete(HttpRequest request, String hash) async {
    // Check blob exists
    if (!_blossom!.hasBlob(hash)) {
      request.response.statusCode = 404;
      request.response.write(jsonEncode({'error': 'Blob not found'}));
      await request.response.close();
      return;
    }

    // Verify Nostr auth header (kind 24242)
    final authEvent = _verifyNostrAuthHeader(request);
    if (authEvent == null || authEvent.kind != 24242) {
      request.response.statusCode = 401;
      request.response.write(jsonEncode({'error': 'Unauthorized'}));
      await request.response.close();
      return;
    }

    // Verify required tags: ["t", "delete"] and ["x", hash]
    final tTag = authEvent.getTagValue('t');
    final xTag = authEvent.getTagValue('x');
    if (tTag != 'delete' || xTag != hash) {
      request.response.statusCode = 403;
      request.response.write(jsonEncode({'error': 'Invalid authorization event'}));
      await request.response.close();
      return;
    }

    // Authorization: check ownership
    final ownerPubkey = _blossom!.getBlobOwner(hash);
    final stationOwnerHex = _settings.npub.isNotEmpty
        ? NostrCrypto.decodeNpub(_settings.npub)
        : null;
    final isStationOwner = stationOwnerHex != null && authEvent.pubkey == stationOwnerHex;

    if (ownerPubkey != null) {
      // Blob has an owner — allow if requester is the owner or station owner
      if (authEvent.pubkey != ownerPubkey && !isStationOwner) {
        request.response.statusCode = 403;
        request.response.write(jsonEncode({'error': 'Forbidden'}));
        await request.response.close();
        return;
      }
    } else {
      // No owner recorded — allow if requester is in the allowed set
      final allowed = await _loadAllowedPubkeys();
      if (!allowed.contains(authEvent.pubkey)) {
        request.response.statusCode = 403;
        request.response.write(jsonEncode({'error': 'Forbidden'}));
        await request.response.close();
        return;
      }
    }

    await _blossom!.deleteBlob(hash);
    request.response.statusCode = 200;
    await request.response.close();
  }

  NostrEvent? _verifyNostrAuthHeader(HttpRequest request) {
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
        _log('WARN', 'NOSTR auth failed - invalid signature');
        return null;
      }
      if (!_isFreshNostrEvent(event)) {
        _log('WARN', 'NOSTR auth failed - event too old');
        return null;
      }

      return event;
    } catch (e) {
      _log('WARN', 'NOSTR auth failed - parse error: $e');
      return null;
    }
  }

  bool _isFreshNostrEvent(NostrEvent event) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return (now - event.createdAt).abs() <= 300;
  }

  Future<void> _handleBlossomUpload(HttpRequest request) async {
    final isOpenRelay = _isOpenRelayPath(request.uri.path);
    NostrEvent? authEvent;
    if (!isOpenRelay && _settings.nostrRequireAuthForWrites) {
      authEvent = _verifyNostrAuthHeader(request);
      if (authEvent == null) {
        request.response.statusCode = 403;
        request.response.write(jsonEncode({'error': 'Unauthorized'}));
        await request.response.close();
        return;
      }
      final allowed = await _loadAllowedPubkeys();
      if (!allowed.contains(authEvent.pubkey)) {
        request.response.statusCode = 403;
        request.response.write(jsonEncode({'error': 'Forbidden'}));
        await request.response.close();
        return;
      }
    }

    try {
      final upload = await _readUploadBytes(request, _blossom!.maxFileBytes);
      final result = await _blossom!.ingestBytes(
        bytes: upload.bytes,
        mime: upload.mime,
        ownerPubkey: authEvent?.pubkey,
      );
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(result.toJson(baseUrl: _blossomBaseUrl(request))));
    } catch (e) {
      request.response.statusCode = 400;
      request.response.write(jsonEncode({'error': e.toString()}));
    }
    await request.response.close();
  }

  Future<void> _handleBlossomDownload(HttpRequest request, String hash) async {
    final file = _blossom!.getBlobFile(hash);
    if (file == null) {
      request.response.statusCode = 404;
      request.response.write('Not Found');
      await request.response.close();
      return;
    }

    if (request.method == 'HEAD') {
      request.response.contentLength = await file.length();
      await request.response.close();
      return;
    }

    request.response.headers.contentType = ContentType.binary;
    await file.openRead().pipe(request.response);
  }

  String _blossomBaseUrl(HttpRequest request) {
    final scheme = request.requestedUri.scheme;
    final host = request.requestedUri.authority;
    return '$scheme://$host/blossom';
  }

  Future<_UploadPayload> _readUploadBytes(HttpRequest request, int maxBytes) async {
    final contentType = request.headers.contentType;
    if (contentType != null && contentType.mimeType == 'multipart/form-data') {
      final boundary = contentType.parameters['boundary'];
      if (boundary == null) {
        throw BlossomStorageError('Missing multipart boundary');
      }
      final transformer = MimeMultipartTransformer(boundary);
      await for (final part in transformer.bind(request)) {
        final disposition = part.headers['content-disposition'];
        if (disposition == null || !disposition.contains('name="file"')) {
          continue;
        }
        final mime = part.headers['content-type'];
        final bytes = await _readStreamWithLimit(part, maxBytes);
        return _UploadPayload(bytes: bytes, mime: mime);
      }
      throw BlossomStorageError('No file part found');
    }

    final bytes = await _readStreamWithLimit(request, maxBytes);
    return _UploadPayload(bytes: bytes, mime: contentType?.mimeType);
  }

  Future<Uint8List> _readStreamWithLimit(Stream<List<int>> stream, int maxBytes) async {
    final builder = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in stream) {
      total += chunk.length;
      if (total > maxBytes) {
        throw BlossomStorageError('Upload exceeds max size (${maxBytes} bytes)');
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }


  /// Handle WebRTC signaling messages (offer, answer, ICE candidates)
  /// Simply forwards the message to the target device identified by to_callsign
  void _handleWebRTCSignaling(PureConnectedClient client, Map<String, dynamic> message) {
    final type = message['type'] as String?;
    final toCallsign = message['to_callsign'] as String?;
    final fromCallsign = message['from_callsign'] as String?;
    final sessionId = message['session_id'] as String?;

    if (toCallsign == null || toCallsign.isEmpty) {
      _log('WARN', 'WebRTC signal missing to_callsign');
      return;
    }

    // Prevent self-routing (device sending to itself)
    if (client.callsign?.toLowerCase() == toCallsign.toLowerCase()) {
      _log('WARN', 'WebRTC $type: ignoring self-routing from ${client.callsign}');
      return;
    }

    // Find target client by callsign
    PureConnectedClient? target;
    try {
      target = _clients.values.firstWhere(
        (c) => c.callsign?.toLowerCase() == toCallsign.toLowerCase(),
      );
    } catch (_) {
      // Not found
    }

    if (target == null) {
      // Target not connected - send error back to sender
      final errorResponse = {
        'type': 'webrtc_error',
        'error': 'target_not_connected',
        'to_callsign': toCallsign,
        'session_id': sessionId,
      };
      _safeSocketSend(client, jsonEncode(errorResponse));
      _log('WARN', 'WebRTC $type: target $toCallsign not connected');
      return;
    }

    // Forward the message to target
    if (_safeSocketSend(target, jsonEncode(message))) {
      _log('INFO', 'WebRTC $type: ${fromCallsign ?? client.callsign} -> $toCallsign (session: $sessionId)');
    } else {
      // Failed to send - notify sender
      _safeSocketSend(client, jsonEncode({
        'type': 'webrtc_error',
        'error': 'forward_failed',
        'to_callsign': toCallsign,
        'session_id': sessionId,
      }));
    }
  }

  /// Handle incoming NOSTR event from WebSocket
  /// Format: ["EVENT", {id, pubkey, created_at, kind, tags, content, sig}]
  Future<void> _handleNostrEvent(PureConnectedClient client, dynamic nostrEvent) async {
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
        _sendOkResponse(client, event.id, false, 'Invalid signature');
        return;
      }

      // Route based on event kind
      if (event.kind == NostrEventKind.applicationSpecificData) {
        // Check if this is an alert event
        final alertTag = event.getTagValue('t');
        if (alertTag == 'alert') {
          await _handleAlertEvent(client, event);
          return;
        }
      }

      // Default: handle as chat message (kind 1 or other text notes)
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
      // Use the event's createdAt timestamp (UTC) for consistent storage
      final msgTimestamp = DateTime.fromMillisecondsSinceEpoch(event.createdAt * 1000, isUtc: true);
      final msg = ChatMessage(
        id: event.id ?? DateTime.now().millisecondsSinceEpoch.toString(),
        roomId: roomId,
        senderCallsign: callsign,
        senderNpub: npub,  // Human-readable, pubkey derived when needed
        signature: event.sig,
        content: content,
        timestamp: msgTimestamp,
        verified: true,  // Signature was verified by event.verify() above
        hasSignature: true,
      );

      if (!_addChatMessage(room, msg)) {
        _log('DEBUG', 'Duplicate NOSTR relay message skipped for room $roomId');
        return;
      }
      room.lastActivity = DateTime.now().toUtc();
      _stats.totalMessages++;
      _stats.lastMessage = DateTime.now();

      // Fire event for subscribers
      _fireChatMessageEvent(msg);

      // Persist to disk
      _saveRoomMessages(roomId);

      // Broadcast to other clients
      final payload = jsonEncode({
        'type': 'chat_message',
        'room': roomId,
        'message': msg.toJson(),
      });
      // Also send UPDATE notification for real-time refresh
      final updateNotification = 'UPDATE:${_settings.callsign}/chat/$roomId';
      for (final c in _clients.values) {
        if (c.id != client.id) {
          try {
            c.socket.add(payload);
            c.socket.add(updateNotification);
          } catch (_) {}
        }
      }
    } catch (e) {
      _log('ERROR', 'Error handling NOSTR event: $e');
    }
  }

  /// Handle alert event (kind 30078 with t=alert tag)
  Future<void> _handleAlertEvent(PureConnectedClient client, NostrEvent event) async {
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
      final senderCallsign = client.callsign ?? event.callsign;

      _log('INFO', '═══════════════════════════════════════════════════');
      _log('INFO', 'ALERT RECEIVED');
      _log('INFO', '═══════════════════════════════════════════════════');
      _log('INFO', 'Event ID: $eventId');
      _log('INFO', 'From: $senderCallsign');
      _log('INFO', 'Folder: $folderName');
      _log('INFO', 'Coordinates: $latitude, $longitude');
      _log('INFO', 'Severity: $severity');
      _log('INFO', 'Status: $status');
      _log('INFO', 'Type: $alertType');
      _log('INFO', 'Content length: ${event.content.length} chars');
      _log('INFO', '═══════════════════════════════════════════════════');

      // Store alert
      await _storeAlert(senderCallsign, folderName, event.content);

      // Note: Photos are NOT fetched automatically to save bandwidth.
      // Photos are obtained via:
      // 1. Client uploads after sharing (AlertSharingService.uploadPhotosToStation)
      // 2. On-demand fetch when alert details are requested and author is online

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
      _log('ERROR', 'Error storing alert: $e');
      _sendOkResponse(client, eventId, false, 'Storage error: $e');
    }
  }

  /// Store alert in devices/{callsign}/alerts/active/{region}/{folderName}/report.txt
  Future<void> _storeAlert(String callsign, String folderName, String content) async {
    final devicesDir = PureStorageConfig().devicesDir;

    // Extract coordinates from content to determine region folder
    final regionFolder = AlertFolderUtils.extractRegionFromContent(content);

    // Use proper directory structure: active/{region}/{folderName}
    final alertPath = AlertFolderUtils.buildAlertPath(
      baseDir: devicesDir,
      callsign: callsign,
      regionFolder: regionFolder,
      folderName: folderName,
    );

    final alertDir = Directory(alertPath);
    if (!await alertDir.exists()) {
      await alertDir.create(recursive: true);
    }

    final reportFile = File(AlertFolderUtils.buildReportPath(alertPath));
    await reportFile.writeAsString(content, flush: true);

    _log('INFO', 'Alert stored at: $alertPath/report.txt');
  }

  /// Find alert path by folder name (searches recursively for backwards compatibility)
  Future<String?> _findAlertPath(String callsign, String folderName) async {
    final devicesDir = PureStorageConfig().devicesDir;
    final findStorage = FilesystemProfileStorage('$devicesDir/$callsign');
    return AlertFolderUtils.findAlertPath('$devicesDir/$callsign/alerts', folderName, storage: findStorage);
  }

  /// Fetch photos from the connected client for an alert
  /// This runs asynchronously (fire and forget) to not block the alert acknowledgment
  Future<void> _fetchAlertPhotosFromClient(PureConnectedClient client, String callsign, String folderName) async {
    try {
      _log('INFO', 'ALERT PHOTOS: Attempting to fetch photos from $callsign for alert $folderName');

      // Generate alert ID (same format as apiId in Report model)
      final alertId = folderName;

      // Create a unique request ID
      final requestId = 'photo-fetch-${DateTime.now().millisecondsSinceEpoch}';

      // First, request the alert details to get the photos list
      final detailsRequest = {
        'type': 'proxy_request',
        'request_id': requestId,
        'method': 'GET',
        'path': '/api/alerts/$alertId',
        'headers': jsonEncode({'Accept': 'application/json'}),
        'body': '',
      };

      // Set up a completer for the response
      final completer = Completer<Map<String, dynamic>>();
      _pendingProxyRequests[requestId] = completer;

      // Send the request to the client
      client.socket.add(jsonEncode(detailsRequest));

      // Wait for response with timeout
      final response = await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          _pendingProxyRequests.remove(requestId);
          return {'statusCode': 408, 'responseBody': 'Timeout'};
        },
      );

      _pendingProxyRequests.remove(requestId);

      if (response['statusCode'] != 200) {
        _log('WARN', 'ALERT PHOTOS: Failed to get alert details: ${response['statusCode']}');
        return;
      }

      // Parse the response to get photos list
      final bodyStr = response['responseBody'] as String? ?? '';
      if (bodyStr.isEmpty) {
        _log('WARN', 'ALERT PHOTOS: Empty response body');
        return;
      }

      Map<String, dynamic> alertDetails;
      try {
        alertDetails = jsonDecode(bodyStr) as Map<String, dynamic>;
      } catch (e) {
        _log('WARN', 'ALERT PHOTOS: Failed to parse alert details: $e');
        return;
      }

      final photos = (alertDetails['photos'] as List<dynamic>?)?.cast<String>() ?? [];

      if (photos.isEmpty) {
        _log('INFO', 'ALERT PHOTOS: No photos in alert $folderName');
        return;
      }

      _log('INFO', 'ALERT PHOTOS: Found ${photos.length} photos to fetch: $photos');

      // Find alert path (searches recursively)
      final alertPath = await _findAlertPath(callsign, folderName);
      if (alertPath == null) {
        _log('WARN', 'ALERT PHOTOS: Could not find alert folder for $folderName');
        return;
      }

      // Create images subfolder
      final imagesDir = Directory('$alertPath/images');
      if (!await imagesDir.exists()) {
        await imagesDir.create(recursive: true);
      }

      int downloadedCount = 0;

      for (final photoName in photos) {
        try {
          // Handle photos that may have images/ prefix
          final cleanPhotoName = photoName.startsWith('images/') ? photoName.substring(7) : photoName;

          // Check if photo already exists in images/ subfolder
          final photoFile = File('${imagesDir.path}/$cleanPhotoName');
          if (await photoFile.exists()) {
            _log('INFO', 'ALERT PHOTOS: $cleanPhotoName already exists, skipping');
            continue;
          }

          // Request the photo
          final photoRequestId = 'photo-$photoName-${DateTime.now().millisecondsSinceEpoch}';
          final photoRequest = {
            'type': 'proxy_request',
            'request_id': photoRequestId,
            'method': 'GET',
            'path': '/api/alerts/$alertId/files/$photoName',
            'headers': jsonEncode({'Accept': 'application/octet-stream'}),
            'body': '',
          };

          final photoCompleter = Completer<Map<String, dynamic>>();
          _pendingProxyRequests[photoRequestId] = photoCompleter;

          client.socket.add(jsonEncode(photoRequest));

          final photoResponse = await photoCompleter.future.timeout(
            const Duration(seconds: 60),
            onTimeout: () {
              _pendingProxyRequests.remove(photoRequestId);
              return {'statusCode': 408, 'responseBody': 'Timeout'};
            },
          );

          _pendingProxyRequests.remove(photoRequestId);

          if (photoResponse['statusCode'] == 200) {
            // Save the photo
            final isBase64 = photoResponse['isBase64'] == true;
            final body = photoResponse['responseBody'] ?? '';

            List<int> bytes;
            if (isBase64) {
              bytes = base64Decode(body);
            } else {
              bytes = utf8.encode(body);
            }

            if (bytes.isNotEmpty) {
              await photoFile.writeAsBytes(bytes, flush: true);
              downloadedCount++;
              _log('INFO', 'ALERT PHOTOS: Downloaded $photoName (${bytes.length} bytes)');
            }
          } else {
            _log('WARN', 'ALERT PHOTOS: Failed to download $photoName: ${photoResponse['statusCode']}');
          }
        } catch (e) {
          _log('ERROR', 'ALERT PHOTOS: Error downloading $photoName: $e');
        }
      }

      _log('INFO', 'ALERT PHOTOS: Completed - downloaded $downloadedCount/${photos.length} photos for $folderName');
    } catch (e) {
      _log('ERROR', 'ALERT PHOTOS: Error fetching photos: $e');
    }
  }

  /// Fetch a single photo from a connected client (on-demand)
  /// Returns true if the photo was successfully fetched and saved
  Future<bool> _fetchSinglePhotoFromClient(
    PureConnectedClient client,
    String callsign,
    String alertId,
    String filename,
  ) async {
    try {
      // Request the photo
      final photoRequestId = 'photo-ondemand-${DateTime.now().millisecondsSinceEpoch}';
      final photoRequest = {
        'type': 'proxy_request',
        'request_id': photoRequestId,
        'method': 'GET',
        'path': '/api/alerts/$alertId/files/$filename',
        'headers': jsonEncode({'Accept': 'application/octet-stream'}),
        'body': '',
      };

      final photoCompleter = Completer<Map<String, dynamic>>();
      _pendingProxyRequests[photoRequestId] = photoCompleter;

      client.socket.add(jsonEncode(photoRequest));

      final photoResponse = await photoCompleter.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          _pendingProxyRequests.remove(photoRequestId);
          return {'statusCode': 408, 'responseBody': 'Timeout'};
        },
      );

      _pendingProxyRequests.remove(photoRequestId);

      if (photoResponse['statusCode'] == 200) {
        // Save the photo
        final isBase64 = photoResponse['isBase64'] == true;
        final body = photoResponse['responseBody'] ?? '';

        List<int> bytes;
        if (isBase64) {
          bytes = base64Decode(body);
        } else {
          bytes = utf8.encode(body);
        }

        if (bytes.isNotEmpty) {
          // Find alert path (searches recursively)
          var alertPath = await _findAlertPath(callsign, alertId);
          if (alertPath == null) {
            _log('WARN', 'ALERT PHOTO: Could not find alert folder for $alertId');
            return false;
          }

          // Create images subfolder and store photo there
          final imagesDir = Directory('$alertPath/images');
          if (!await imagesDir.exists()) {
            await imagesDir.create(recursive: true);
          }

          // Handle photos that may have images/ prefix
          final cleanFilename = filename.startsWith('images/') ? filename.substring(7) : filename;
          final photoFile = File('${imagesDir.path}/$cleanFilename');
          await photoFile.writeAsBytes(bytes, flush: true);
          _log('INFO', 'ALERT PHOTO: On-demand fetch successful - images/$cleanFilename (${bytes.length} bytes)');
          return true;
        }
      }

      _log('WARN', 'ALERT PHOTO: On-demand fetch failed - status ${photoResponse['statusCode']}');
      return false;
    } catch (e) {
      _log('ERROR', 'ALERT PHOTO: On-demand fetch error: $e');
      return false;
    }
  }

  /// Handle GET /alerts - Display public alerts page
  Future<void> _handleAlertsPage(HttpRequest request) async {
    try {
      final alerts = await _loadAllAlerts();
      final html = _buildAlertsHtml(alerts);

      await _sendCompressedResponse(
        request,
        html,
        ContentType.html,
        cacheControl: 'public, max-age=60',
      );
    } catch (e) {
      _log('ERROR', 'Error loading alerts: $e');
      request.response.statusCode = 500;
      request.response.write('Error loading alerts');
    }
  }

  /// Handle GET /api/alerts - JSON API for fetching alerts
  /// Query parameters:
  ///   - since: Unix timestamp (seconds) - only return alerts updated after this time
  ///   - lat: latitude for distance filtering
  ///   - lon: longitude for distance filtering
  ///   - radius: radius in km for distance filtering (default: unlimited)
  ///   - status: filter by status (open, in-progress, resolved, closed)
  Future<void> _handleAlertsApi(HttpRequest request) async {
    try {
      final params = request.uri.queryParameters;

      // Parse query parameters
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
      final statusFilter = params['status'];

      // Load all alerts
      var alerts = await _loadAllAlerts(includeAllStatuses: statusFilter != null);

      // Filter by status if specified
      if (statusFilter != null) {
        alerts = alerts.where((a) => a['status'] == statusFilter).toList();
      }

      // Filter by since timestamp (compare with last_modified or created time)
      if (sinceTimestamp != null) {
        final sinceDate = DateTime.fromMillisecondsSinceEpoch(sinceTimestamp * 1000);
        alerts = alerts.where((alert) {
          // Prefer last_modified, fall back to created
          final lastModifiedStr = alert['last_modified'] as String?;
          final createdStr = alert['created'] as String?;

          try {
            // Try last_modified first (ISO 8601 format)
            if (lastModifiedStr != null && lastModifiedStr.isNotEmpty) {
              final lastModified = DateTime.parse(lastModifiedStr);
              return lastModified.isAfter(sinceDate);
            }
            // Fall back to created time
            if (createdStr != null && createdStr.isNotEmpty) {
              final created = _parseAlertDateTime(createdStr);
              return created.isAfter(sinceDate);
            }
            return true; // Include if no timestamps
          } catch (_) {
            return true; // Include if can't parse date
          }
        }).toList();
      }

      // Filter by distance if location provided
      if (lat != null && lon != null && radiusKm != null && radiusKm > 0) {
        alerts = alerts.where((alert) {
          final alertLat = alert['latitude'] as double?;
          final alertLon = alert['longitude'] as double?;
          if (alertLat == null || alertLon == null) return false;
          if (alertLat == 0.0 && alertLon == 0.0) return false;

          final distance = _calculateDistanceKm(lat, lon, alertLat, alertLon);
          return distance <= radiusKm;
        }).toList();
      }

      // Build response
      final response = {
        'success': true,
        'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'station': {
          'name': _settings.name ?? 'Geogram Station',
          'callsign': _settings.callsign,
          'npub': _settings.npub,
        },
        'filters': {
          if (sinceTimestamp != null) 'since': sinceTimestamp,
          if (lat != null) 'lat': lat,
          if (lon != null) 'lon': lon,
          if (radiusKm != null) 'radius_km': radiusKm,
          if (statusFilter != null) 'status': statusFilter,
        },
        'count': alerts.length,
        'alerts': alerts,
      };

      await _sendCompressedResponse(
        request,
        jsonEncode(response),
        ContentType.json,
        cacheControl: 'no-cache',
      );
    } catch (e) {
      _log('ERROR', 'Error in alerts API: $e');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'success': false,
        'error': 'Internal server error',
        'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      }));
    }
  }

  /// Handle GET /api/places - JSON API for fetching places
  /// Query parameters:
  ///   - since: Unix timestamp (seconds) - only return places updated after this time
  ///   - lat: latitude for distance filtering
  ///   - lon: longitude for distance filtering
  ///   - radius: radius in km for distance filtering (default: unlimited)
  Future<void> _handlePlacesApi(HttpRequest request) async {
    try {
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
    } catch (e) {
      _log('ERROR', 'Error in places API: $e');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'success': false,
        'error': 'Internal server error',
        'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      }));
    }
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
      _log('ERROR', 'Error handling events request: $e');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Internal server error', 'message': e.toString()}));
    }
  }

  /// Handle GET /api/events - list events
  Future<void> _handleEventsApi(HttpRequest request) async {
    try {
      if (_dataDir == null) {
        request.response.statusCode = 500;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Storage not initialized'}));
        return;
      }

      final yearParam = request.uri.queryParameters['year'];
      final year = yearParam != null ? int.tryParse(yearParam) : null;

      final eventService = EventService();
      final events = await eventService.getAllEventsGlobal(_dataDir!, year: year);
      final publicEvents = events
          .where((event) => event.visibility.toLowerCase() == 'public')
          .toList();
      final years = await eventService.getAvailableYearsGlobal(_dataDir!);

      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'events': publicEvents.map((e) => e.toApiJson(summary: true)).toList(),
        'years': years,
        'total': publicEvents.length,
        'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      }));
    } catch (e) {
      _log('ERROR', 'Error in events API: $e');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'success': false,
        'error': 'Internal server error',
        'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
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
      final appPath = path.dirname(path.dirname(path.dirname(eventDir)));
      await eventService.initializeApp(appPath);
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
      _log('ERROR', 'Error handling event details: $e');
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
      _log('ERROR', 'Error handling event items: $e');
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
      _log('ERROR', 'Error serving event file: $e');
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
      _log('ERROR', 'Error listing event media: $e');
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
      _log('ERROR', 'Error uploading event media: $e');
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
      _log('ERROR', 'Error serving event media: $e');
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
      _log('ERROR', 'Error updating event media status: $e');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Internal server error', 'message': e.toString()}));
    }
  }

  Future<String?> _resolveEventDir(String eventId) async {
    if (_dataDir == null) return null;
    final eventService = EventService();
    return eventService.getEventPath(eventId, _dataDir!);
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

  /// Parse alert datetime from format "YYYY-MM-DD HH:MM_ss"
  DateTime _parseAlertDateTime(String dateStr) {
    // Format: "2025-12-07 10:30_45" -> DateTime
    final parts = dateStr.split(' ');
    if (parts.length < 2) {
      return DateTime.parse(parts[0]); // Just date
    }

    final datePart = parts[0];
    final timePart = parts[1].replaceAll('_', ':'); // Convert HH:MM_ss to HH:MM:ss

    return DateTime.parse('${datePart}T$timePart');
  }

  /// Calculate distance between two coordinates in km (Haversine formula)
  double _calculateDistanceKm(double lat1, double lon1, double lat2, double lon2) {
    const earthRadiusKm = 6371.0;
    final dLat = _toRadians(lat2 - lat1);
    final dLon = _toRadians(lon2 - lon1);

    final a = _sin(dLat / 2) * _sin(dLat / 2) +
        _cos(_toRadians(lat1)) * _cos(_toRadians(lat2)) *
        _sin(dLon / 2) * _sin(dLon / 2);

    final c = 2 * _atan2(_sqrt(a), _sqrt(1 - a));
    return earthRadiusKm * c;
  }

  double _toRadians(double degrees) => degrees * 3.141592653589793 / 180.0;
  double _sin(double x) => _taylor_sin(x);
  double _cos(double x) => _taylor_sin(x + 1.5707963267948966);
  double _sqrt(double x) {
    if (x <= 0) return 0;
    double guess = x / 2;
    for (int i = 0; i < 20; i++) {
      guess = (guess + x / guess) / 2;
    }
    return guess;
  }
  double _atan2(double y, double x) {
    if (x > 0) return _atan(y / x);
    if (x < 0 && y >= 0) return _atan(y / x) + 3.141592653589793;
    if (x < 0 && y < 0) return _atan(y / x) - 3.141592653589793;
    if (x == 0 && y > 0) return 1.5707963267948966;
    if (x == 0 && y < 0) return -1.5707963267948966;
    return 0;
  }
  double _atan(double x) {
    if (x.abs() > 1) {
      return (x > 0 ? 1 : -1) * 1.5707963267948966 - _atan(1 / x);
    }
    double result = 0;
    double term = x;
    for (int n = 0; n < 50; n++) {
      result += term / (2 * n + 1);
      term *= -x * x;
    }
    return result;
  }
  double _taylor_sin(double x) {
    // Normalize to [-pi, pi]
    while (x > 3.141592653589793) x -= 6.283185307179586;
    while (x < -3.141592653589793) x += 6.283185307179586;
    double result = 0;
    double term = x;
    for (int n = 0; n < 20; n++) {
      result += term;
      term *= -x * x / ((2 * n + 2) * (2 * n + 3));
    }
    return result;
  }

  /// Load all alerts from all devices
  /// If includeAllStatuses is true, returns all alerts regardless of status
  Future<List<Map<String, dynamic>>> _loadAllAlerts({bool includeAllStatuses = false}) async {
    final alerts = <Map<String, dynamic>>[];
    final devicesDir = Directory(PureStorageConfig().devicesDir);

    if (!await devicesDir.exists()) {
      return alerts;
    }

    // Iterate through all device directories
    await for (final deviceEntity in devicesDir.list()) {
      if (deviceEntity is! Directory) continue;

      final callsign = deviceEntity.path.split('/').last;
      final alertsDir = Directory('${deviceEntity.path}/alerts');

      if (!await alertsDir.exists()) continue;

      // Iterate recursively through alert folders (supports active/{region}/ structure)
      await for (final entity in alertsDir.list(recursive: true)) {
        if (entity is! File) continue;
        if (!entity.path.endsWith('/report.txt')) continue;

        // Extract folder name from path
        final alertDirPath = entity.path.replaceFirst('/report.txt', '');
        final folderName = alertDirPath.split('/').last;

        try {
          final content = await entity.readAsString();
          final alert = _parseAlertContent(content, callsign, folderName);

          // Include based on status filter
          if (includeAllStatuses ||
              alert['status'] == 'open' ||
              alert['status'] == 'in-progress') {
            alerts.add(alert);
          }
        } catch (e) {
          _log('WARN', 'Failed to parse alert: ${entity.path}');
        }
      }
    }

    // Sort by severity (emergency first) then by date (newest first)
    alerts.sort((a, b) {
      final severityOrder = {'emergency': 0, 'urgent': 1, 'attention': 2, 'info': 3};
      final severityCompare = (severityOrder[a['severity']] ?? 3).compareTo(severityOrder[b['severity']] ?? 3);
      if (severityCompare != 0) return severityCompare;
      return (b['created'] as String).compareTo(a['created'] as String);
    });

    return alerts;
  }

  /// Parse alert content from report.txt
  Map<String, dynamic> _parseAlertContent(String content, String callsign, String folderName) {
    final lines = content.split('\n');
    final alert = <String, dynamic>{
      'callsign': callsign,
      'folderName': folderName,
      'title': folderName,
      'severity': 'info',
      'status': 'open',
      'type': 'other',
      'created': '',
      'latitude': 0.0,
      'longitude': 0.0,
      'description': '',
    };

    final descLines = <String>[];
    bool inDescription = false;

    for (final line in lines) {
      if (line.startsWith('# REPORT: ')) {
        alert['title'] = line.substring(10).trim();
      } else if (line.startsWith('# REPORT_EN: ')) {
        alert['title'] = line.substring(13).trim();
      } else if (line.startsWith('CREATED: ')) {
        alert['created'] = line.substring(9).trim();
      } else if (line.startsWith('AUTHOR: ')) {
        alert['author'] = line.substring(8).trim();
      } else if (line.startsWith('COORDINATES: ')) {
        final coords = line.substring(13).split(',');
        if (coords.length == 2) {
          alert['latitude'] = double.tryParse(coords[0].trim()) ?? 0.0;
          alert['longitude'] = double.tryParse(coords[1].trim()) ?? 0.0;
        }
      } else if (line.startsWith('SEVERITY: ')) {
        alert['severity'] = line.substring(10).trim().toLowerCase();
      } else if (line.startsWith('STATUS: ')) {
        alert['status'] = line.substring(8).trim().toLowerCase();
      } else if (line.startsWith('TYPE: ')) {
        alert['type'] = line.substring(6).trim();
      } else if (line.startsWith('ADDRESS: ')) {
        alert['address'] = line.substring(9).trim();
      // Note: POINTED_BY and POINT_COUNT are now derived from feedback/points.txt
      } else if (line.startsWith('VERIFIED_BY: ')) {
        final verifiedByStr = line.substring(13).trim();
        alert['verified_by'] = verifiedByStr.isEmpty ? <String>[] : verifiedByStr.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
        alert['verification_count'] = (alert['verified_by'] as List).length;
      } else if (line.startsWith('VERIFICATION_COUNT: ')) {
        alert['verification_count'] = int.tryParse(line.substring(20).trim()) ?? 0;
      } else if (line.startsWith('LAST_MODIFIED: ')) {
        alert['last_modified'] = line.substring(15).trim();
      } else if (line.startsWith('-->')) {
        // Metadata section, stop description
        inDescription = false;
      } else if (line.trim().isEmpty && !inDescription && alert['created'] != '') {
        // Empty line after header starts description
        inDescription = true;
      } else if (inDescription && !line.startsWith('[')) {
        descLines.add(line);
      }
    }

    alert['description'] = descLines.join('\n').trim();
    if (alert['description'].length > 300) {
      alert['description'] = alert['description'].substring(0, 300) + '...';
    }

    return alert;
  }

  /// Handle POST /api/alerts/{alertId}/{action} - legacy alert feedback (deprecated)
  Future<void> _handleAlertFeedback(HttpRequest request) async {
    try {
      final requestPath = request.uri.path;
      // Parse: /api/alerts/{alertId}/{action}
      final pathParts = requestPath.substring('/api/alerts/'.length).split('/');
      if (pathParts.length != 2) {
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
      _log('ERROR', 'Error handling alert feedback: $e');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Internal error', 'message': e.toString()}));
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
        final body = await utf8.decoder.bind(request).join();
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
        // Record karma for successful feedback actions
        if (result['success'] == true) {
          recordFeedbackKarma(action, contentType, contentId, jsonBody, callsign);
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
      _log('ERROR', 'Error in feedback API: $e');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'error': 'Internal server error',
        'message': e.toString(),
      }));
    }
  }

  /// Handle /api/email/queue - List pending external emails
  Future<void> _handleEmailQueue(HttpRequest request) async {
    try {
      if (request.method != 'GET') {
        request.response.statusCode = 405;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Method not allowed'}));
        return;
      }

      final emailRelay = EmailRelayService();
      final pending = emailRelay.getPendingExternalEmails();

      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'success': true,
        'pending_count': pending.length,
        'emails': pending.map((e) => {
          'id': e.id,
          'sender_callsign': e.senderCallsign,
          'recipients': e.externalRecipients,
          'subject': _extractSubject(e.message),
          'timestamp': e.timestamp.toIso8601String(),
          'status': e.status.toString().split('.').last,
        }).toList(),
        'allowlist': emailRelay.getAllowlist(),
        'blocklist': emailRelay.getBlocklist(),
      }));
    } catch (e) {
      _log('ERROR', 'Error in email queue API: $e');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': e.toString()}));
    }
  }

  /// Extract subject from email message
  String _extractSubject(Map<String, dynamic> message) {
    return message['subject'] as String? ?? '(No Subject)';
  }

  /// Handle /api/email/approve/{id} - Approve an external email
  Future<void> _handleEmailApprove(HttpRequest request) async {
    try {
      if (request.method != 'POST') {
        request.response.statusCode = 405;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Method not allowed'}));
        return;
      }

      final segments = request.uri.pathSegments;
      if (segments.length < 4) {
        request.response.statusCode = 400;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Missing email ID'}));
        return;
      }

      final emailId = segments[3];
      final emailRelay = EmailRelayService();
      final success = emailRelay.approveExternalEmail(
        emailId: emailId,
        reviewerCallsign: 'admin',
      );

      request.response.statusCode = success ? 200 : 404;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'success': success,
        'message': success ? 'Email approved and queued for delivery' : 'Email not found',
        'email_id': emailId,
      }));
    } catch (e) {
      _log('ERROR', 'Error approving email: $e');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': e.toString()}));
    }
  }

  /// Handle /api/email/reject/{id} - Reject an external email
  Future<void> _handleEmailReject(HttpRequest request) async {
    try {
      if (request.method != 'POST') {
        request.response.statusCode = 405;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Method not allowed'}));
        return;
      }

      final segments = request.uri.pathSegments;
      if (segments.length < 4) {
        request.response.statusCode = 400;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Missing email ID'}));
        return;
      }

      final emailId = segments[3];
      final body = await utf8.decoder.bind(request).join();
      String? reason;
      if (body.isNotEmpty) {
        try {
          final json = jsonDecode(body) as Map<String, dynamic>;
          reason = json['reason'] as String?;
        } catch (_) {}
      }

      final emailRelay = EmailRelayService();
      final success = emailRelay.rejectExternalEmail(
        emailId: emailId,
        reviewerCallsign: 'admin',
        reason: reason ?? 'Rejected by station operator',
      );

      request.response.statusCode = success ? 200 : 404;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'success': success,
        'message': success ? 'Email rejected' : 'Email not found',
        'email_id': emailId,
      }));
    } catch (e) {
      _log('ERROR', 'Error rejecting email: $e');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': e.toString()}));
    }
  }

  /// Handle /api/email/allowlist - Manage sender allowlist
  Future<void> _handleEmailAllowlist(HttpRequest request) async {
    try {
      final emailRelay = EmailRelayService();

      if (request.method == 'GET') {
        request.response.statusCode = 200;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'success': true,
          'allowlist': emailRelay.getAllowlist(),
          'blocklist': emailRelay.getBlocklist(),
        }));
        return;
      }

      if (request.method == 'POST') {
        final body = await utf8.decoder.bind(request).join();
        if (body.isEmpty) {
          request.response.statusCode = 400;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'error': 'Missing request body'}));
          return;
        }

        final json = jsonDecode(body) as Map<String, dynamic>;
        final action = json['action'] as String?;
        final callsign = json['callsign'] as String?;

        if (action == null || callsign == null) {
          request.response.statusCode = 400;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'error': 'Missing action or callsign'}));
          return;
        }

        switch (action) {
          case 'add_allowlist':
            emailRelay.addToAllowlist(callsign);
            break;
          case 'remove_allowlist':
            emailRelay.removeFromAllowlist(callsign);
            break;
          case 'add_blocklist':
            emailRelay.addToBlocklist(callsign);
            break;
          case 'remove_blocklist':
            emailRelay.removeFromBlocklist(callsign);
            break;
          default:
            request.response.statusCode = 400;
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode({'error': 'Unknown action: $action'}));
            return;
        }

        request.response.statusCode = 200;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'success': true,
          'action': action,
          'callsign': callsign,
          'allowlist': emailRelay.getAllowlist(),
          'blocklist': emailRelay.getBlocklist(),
        }));
        return;
      }

      request.response.statusCode = 405;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Method not allowed'}));
    } catch (e) {
      _log('ERROR', 'Error in allowlist API: $e');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': e.toString()}));
    }
  }

  /// Find alert by apiId (YYYY-MM-DD_title-slug)
  /// Searches recursively to support active/{region}/ folder structure
  Future<Map<String, dynamic>?> _findAlertById(String alertId) async {
    final devicesDir = Directory(PureStorageConfig().devicesDir);
    if (!await devicesDir.exists()) return null;

    await for (final deviceEntity in devicesDir.list()) {
      if (deviceEntity is! Directory) continue;

      final callsign = deviceEntity.path.split('/').last;
      final alertsDir = Directory('${deviceEntity.path}/alerts');
      if (!await alertsDir.exists()) continue;

      // Search recursively to support active/{region}/ folder structure
      await for (final entity in alertsDir.list(recursive: true)) {
        if (entity is! File) continue;
        if (!entity.path.endsWith('/report.txt')) continue;

        // Extract alert directory path and folder name
        final alertPath = entity.path.replaceFirst('/report.txt', '');
        final folderName = alertPath.split('/').last;

        try {
          final content = await entity.readAsString();
          final alert = _parseAlertContent(content, callsign, folderName);

          // Generate apiId and compare
          final apiId = _generateApiId(alert['created'] as String, alert['title'] as String);
          if (apiId == alertId) {
            return {
              'path': alertPath,
              'callsign': callsign,
              'folderName': folderName,
              'alert': alert,
            };
          }
        } catch (_) {}
      }
    }
    return null;
  }

  /// Generate API ID from created timestamp and title (matches Report.apiId)
  String _generateApiId(String created, String title) {
    final datePart = created.split(' ').first;
    final slug = title
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return '${datePart}_$slug';
  }

  /// Handle alert point/unpoint
  Future<void> _handleAlertPoint(
    HttpRequest request,
    String alertPath,
    File reportFile,
    Map<String, dynamic> json, {
    required bool isPoint,
  }) async {
    request.response.statusCode = 410;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({
      'error': 'Legacy alert feedback endpoint is deprecated',
      'message': 'Use /api/feedback/alert/{alertId}/point',
    }));
  }

  /// Handle alert verify
  Future<void> _handleAlertVerify(
    HttpRequest request,
    String alertPath,
    File reportFile,
    Map<String, dynamic> json,
  ) async {
    request.response.statusCode = 410;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({
      'error': 'Legacy alert feedback endpoint is deprecated',
      'message': 'Use /api/feedback/alert/{alertId}/verify',
    }));
  }

  /// Handle alert comment
  Future<void> _handleAlertComment(
    HttpRequest request,
    String alertPath,
    Map<String, dynamic> json,
  ) async {
    request.response.statusCode = 410;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({
      'error': 'Legacy alert feedback endpoint is deprecated',
      'message': 'Use /api/feedback/alert/{alertId}/comment',
    }));
  }

  /// Update alert file with new feedback data.
  /// Note: POINTED_BY and POINT_COUNT are derived from feedback/points.txt.
  String _updateAlertFeedback(
    String content, {
    List<String>? verifiedBy,
    String? lastModified,
  }) {
    final lines = content.split('\n');
    final newLines = <String>[];

    bool hasVerifiedBy = false;
    bool hasVerificationCount = false;
    bool hasLastModified = false;

    for (final line in lines) {
      // Skip old POINTED_BY and POINT_COUNT lines (derived from feedback/points.txt)
      if (line.startsWith('POINTED_BY: ') || line.startsWith('POINT_COUNT: ')) {
        continue;
      } else if (verifiedBy != null && line.startsWith('VERIFIED_BY: ')) {
        newLines.add('VERIFIED_BY: ${verifiedBy.join(', ')}');
        hasVerifiedBy = true;
      } else if (verifiedBy != null && line.startsWith('VERIFICATION_COUNT: ')) {
        newLines.add('VERIFICATION_COUNT: ${verifiedBy.length}');
        hasVerificationCount = true;
      } else if (lastModified != null && line.startsWith('LAST_MODIFIED: ')) {
        newLines.add('LAST_MODIFIED: $lastModified');
        hasLastModified = true;
      } else {
        newLines.add(line);
      }
    }

    // Find insertion point - should be after header fields, before description
    // Report format: Title, empty line, header fields, empty line, description
    // We want to insert just before the SECOND empty line (the one before description)
    int insertIndex = newLines.length;
    int emptyLineCount = 0;
    for (int i = 0; i < newLines.length; i++) {
      if (newLines[i].trim().isEmpty && i > 0 && !newLines[i - 1].startsWith('-->')) {
        emptyLineCount++;
        if (emptyLineCount == 2) {
          // Found the empty line before description - insert before it
          insertIndex = i;
          break;
        }
      }
    }

    // Add missing fields
    final toInsert = <String>[];
    if (verifiedBy != null && !hasVerifiedBy && verifiedBy.isNotEmpty) {
      toInsert.add('VERIFIED_BY: ${verifiedBy.join(', ')}');
    }
    if (verifiedBy != null && !hasVerificationCount && verifiedBy.isNotEmpty) {
      toInsert.add('VERIFICATION_COUNT: ${verifiedBy.length}');
    }
    if (lastModified != null && !hasLastModified) {
      toInsert.add('LAST_MODIFIED: $lastModified');
    }

    if (toInsert.isNotEmpty) {
      newLines.insertAll(insertIndex, toInsert);
    }

    return newLines.join('\n');
  }

  /// Build HTML page for alerts
  String _buildAlertsHtml(List<Map<String, dynamic>> alerts) {
    return StationHtmlTemplates.buildAlertsPage(
      stationName: _settings.name ?? 'geogram Station',
      alerts: alerts,
    );
  }

  /// Send NOSTR OK response
  void _sendOkResponse(PureConnectedClient client, String? eventId, bool success, String message) {
    // Send in object format to match what the desktop/mobile client expects
    final response = jsonEncode({
      'type': 'OK',
      'event_id': eventId ?? '',
      'success': success,
      'message': message,
    });
    try {
      client.socket.add(response);
    } catch (e) {
      _log('ERROR', 'Failed to send OK response: $e');
    }
    _log('INFO', 'Sent OK response: success=$success, message=$message');
  }

  /// Broadcast update to all connected clients
  void _broadcastUpdate(String updateMessage) {
    for (final c in _clients.values) {
      try {
        c.socket.add(updateMessage);
      } catch (e) {
        _log('ERROR', 'Error broadcasting to client ${c.id}: $e');
      }
    }
    _log('INFO', 'Broadcast update to ${_clients.length} clients: $updateMessage');
  }

  Future<void> _handleStatus(HttpRequest request) async {
    final uptime = _startTime != null
        ? DateTime.now().difference(_startTime!).inMinutes
        : 0;

    final status = {
      'service': 'Geogram Station Server',
      'name': _settings.name ?? 'Geogram Station',
      'version': cliAppVersion,
      'callsign': _settings.callsign,
      'description': _settings.description ?? 'Geogram Desktop Station Server',
      'connected_devices': _clients.length,
      'uptime': uptime,
      'station_mode': true,
      'location': _settings.location,
      'latitude': _settings.latitude,
      'longitude': _settings.longitude,
      'npub': _settings.npub,
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

    await _sendCompressedResponse(
      request,
      jsonEncode(status),
      ContentType.json,
      cacheControl: 'no-cache',
    );
  }

  /// Handle /api/geoip endpoint - returns client's IP geolocation using local MMDB database
  /// This enables privacy-preserving IP geolocation without external API calls
  Future<void> _handleGeoIp(HttpRequest request) async {
    final clientIp = request.connectionInfo?.remoteAddress.address;

    if (clientIp == null) {
      request.response.statusCode = 400;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Cannot determine client IP'}));
      return;
    }

    final geoip = GeoIpService();
    if (!geoip.isInitialized) {
      request.response.statusCode = 503;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'error': 'GeoIP service not initialized',
        'ip': clientIp,
      }));
      return;
    }

    final result = await geoip.lookup(clientIp);

    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({
      'ip': clientIp,
      'latitude': result?.latitude,
      'longitude': result?.longitude,
      'city': result?.city,
      'country': result?.country,
      'countryCode': result?.countryCode,
    }));
  }

  Future<void> _handleStats(HttpRequest request) async {
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(_stats.toJson()));
  }

  Future<void> _handleLogs(HttpRequest request) async {
    final limit = int.tryParse(request.uri.queryParameters['limit'] ?? '50') ?? 50;
    final filter = request.uri.queryParameters['filter']?.toLowerCase();

    var logs = _logs.toList();
    if (filter != null && filter.isNotEmpty) {
      logs = logs.where((l) => l.message.toLowerCase().contains(filter)).toList();
    }

    final recentLogs = logs.length > limit ? logs.sublist(logs.length - limit) : logs;

    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({
      'total': _logs.length,
      'showing': recentLogs.length,
      'logs': recentLogs.map((l) => {
        'timestamp': l.timestamp.toIso8601String(),
        'level': l.level,
        'message': l.message,
      }).toList(),
    }));
  }

  Future<void> _handleDevices(HttpRequest request) async {
    final path = request.uri.path;
    final clients = _clients.values.map((c) {
      final json = c.toJson();
      // Add is_online field
      json['is_online'] = true;
      // Remove IP address for privacy
      json.remove('address');
      return json;
    }).toList();

    // Return different format for /api/clients vs /api/devices
    final jsonData = path == '/api/clients'
        ? jsonEncode({
            'station': _settings.callsign,
            'count': clients.length,
            'clients': clients,
          })
        : jsonEncode({'devices': clients});

    await _sendCompressedResponse(
      request,
      jsonData,
      ContentType.json,
      cacheControl: 'no-cache',
    );
  }

  /// GET /station/status - List connected devices and stations
  Future<void> _handleRelayStatus(HttpRequest request) async {
    final devices = _clients.values
        .where((c) => c.deviceType != 'station')
        .map((c) => {
              'callsign': c.callsign,
              'uptime_seconds': DateTime.now().difference(c.connectedAt).inSeconds,
              'idle_seconds': DateTime.now().difference(c.lastActivity).inSeconds,
              'connected_at': c.connectedAt.toIso8601String(),
            })
        .toList();

    final stations = _clients.values
        .where((c) => c.deviceType == 'station')
        .map((c) => {
              'callsign': c.callsign,
              'uptime_seconds': DateTime.now().difference(c.connectedAt).inSeconds,
              'connected_at': c.connectedAt.toIso8601String(),
            })
        .toList();

    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({
      'connected_devices': devices.length,
      'connected_stations': stations.length,
      'devices': devices,
      'stations': stations,
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

  /// Check if path matches /{callsign}/api/alerts/{alertId}/files/{filename} pattern for photo uploads
  /// Also matches: /{callsign}/api/alerts/{alertId}/files/images/{filename}
  bool _isAlertFileUploadPath(String path) {
    // Pattern: /{callsign}/api/alerts/{alertId}/files/{filename}
    // Also supports: /{callsign}/api/alerts/{alertId}/files/images/{filename}
    final regex = RegExp(r'^/([A-Za-z0-9]+)/api/alerts/([^/]+)/files/.+$');
    return regex.hasMatch(path);
  }

  /// Check if path matches place file upload/download patterns.
  /// Patterns:

  /// Check if path matches /{callsign}/api/alerts/{alertId} pattern for alert details
  /// This should NOT match paths with /files/ (those are handled by _isAlertFileUploadPath)
  bool _isAlertDetailsPath(String path) {
    // Pattern: /{callsign}/api/alerts/{alertId} (but NOT with /files/ at the end)
    final regex = RegExp(r'^/([A-Za-z0-9]+)/api/alerts/([^/]+)$');
    return regex.hasMatch(path);
  }

  /// Check if path matches /api/places/{callsign}/{folderName}
  bool _isPlaceDetailsPath(String path) {
    return _parsePlaceDetailsRequest(path) != null;
  }

  /// Handle GET /{callsign}/api/alerts/{alertId} - serve local alert details with photos list
  /// Uses the shared alertApi.getAlertDetails() which includes comments
  Future<void> _handleAlertDetails(HttpRequest request) async {
    try {
      final requestPath = request.uri.path;

      // Parse path: /{callsign}/api/alerts/{alertId}
      final regex = RegExp(r'^/([A-Za-z0-9]+)/api/alerts/([^/]+)$');
      final match = regex.firstMatch(requestPath);

      if (match == null) {
        request.response.statusCode = 400;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Invalid path format'}));
        return;
      }

      final callsign = match.group(1)!.toUpperCase();
      final alertId = match.group(2)!;

      _log('INFO', 'Alert details request: callsign=$callsign, alertId=$alertId');

      // Use shared alert API handler (includes photos and comments)
      final result = await alertApi.getAlertDetails(callsign, alertId);

      // Handle HTTP status code (stored in 'http_status' to avoid conflict with alert 'status' field)
      final httpStatus = result.remove('http_status') as int?;
      if (httpStatus != null) {
        request.response.statusCode = httpStatus;
      } else if (result.containsKey('error')) {
        // If there's an error but no http_status, default to 404
        request.response.statusCode = 404;
      } else {
        request.response.statusCode = 200;
      }

      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(result));
    } catch (e) {
      _log('ERROR', 'Error handling alert details: $e');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Internal server error', 'message': e.toString()}));
    }
  }

  /// Handle GET /api/places/{callsign}/{folderName} - place details
  Future<void> _handlePlaceDetails(HttpRequest request) async {
    try {
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
    } catch (e) {
      _log('ERROR', 'Error handling place details: $e');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Internal server error', 'message': e.toString()}));
    }
  }

  /// Handle POST /{callsign}/api/alerts/{alertId}/files/{filename} - upload alert photo
  Future<void> _handleAlertFileUpload(HttpRequest request) async {
    try {
      final path = request.uri.path;

      // Parse path: /{callsign}/api/alerts/{alertId}/files/{filename}
      final regex = RegExp(r'^/([A-Za-z0-9]+)/api/alerts/([^/]+)/files/([^/]+)$');
      final match = regex.firstMatch(path);

      if (match == null) {
        request.response.statusCode = 400;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Invalid path format'}));
        return;
      }

      final callsign = match.group(1)!.toUpperCase();
      final alertId = match.group(2)!;
      final filename = match.group(3)!;

      // Validate filename (prevent directory traversal)
      if (filename.contains('..') || filename.contains('/') || filename.contains('\\')) {
        request.response.statusCode = 400;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Invalid filename'}));
        return;
      }

      // Validate it's an allowed file type
      final ext = filename.toLowerCase().split('.').last;
      final allowedExtensions = ['jpg', 'jpeg', 'png', 'gif', 'webp'];
      if (!allowedExtensions.contains(ext)) {
        request.response.statusCode = 400;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'error': 'Invalid file type',
          'allowed': allowedExtensions,
        }));
        return;
      }

      // Read the file content from request body
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

      // Limit file size (10MB max)
      if (bytes.length > 10 * 1024 * 1024) {
        request.response.statusCode = 413;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'File too large', 'max_size_mb': 10}));
        return;
      }

      _log('INFO', '═══════════════════════════════════════════════════════');
      _log('INFO', 'ALERT PHOTO UPLOAD: Receiving photo for alert');
      _log('INFO', '  Callsign: $callsign');
      _log('INFO', '  Alert ID: $alertId');
      _log('INFO', '  Filename: $filename');
      _log('INFO', '  Size: ${bytes.length} bytes');
      _log('INFO', '═══════════════════════════════════════════════════════');

      // Find alert path (searches recursively for backwards compatibility)
      var alertPath = await _findAlertPath(callsign, alertId);
      if (alertPath == null) {
        _log('WARN', 'Alert folder does not exist for: $alertId');
        request.response.statusCode = 404;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Alert not found', 'alert_id': alertId}));
        return;
      }

      // Create images subfolder and store photo there
      final imagesDir = Directory('$alertPath/images');
      if (!await imagesDir.exists()) {
        await imagesDir.create(recursive: true);
      }

      // Handle photos that may have images/ prefix
      final cleanFilename = filename.startsWith('images/') ? filename.substring(7) : filename;
      final filePath = '${imagesDir.path}/$cleanFilename';
      final file = File(filePath);
      await file.writeAsBytes(bytes, flush: true);

      _log('INFO', 'ALERT PHOTO UPLOAD: Saved to $filePath');

      // Send success response
      request.response.statusCode = 201;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'success': true,
        'message': 'Photo uploaded successfully',
        'callsign': callsign,
        'alert_id': alertId,
        'filename': filename,
        'size': bytes.length,
      }));
    } catch (e) {
      _log('ERROR', 'Error handling alert file upload: $e');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Internal server error', 'message': e.toString()}));
    }
  }

  /// Handle GET /{callsign}/api/alerts/{alertId}/files/{filename} - serve alert photo
  /// Also handles: /{callsign}/api/alerts/{alertId}/files/images/{filename}
  Future<void> _handleAlertFileServe(HttpRequest request) async {
    try {
      final requestPath = request.uri.path;

      // Parse path: /{callsign}/api/alerts/{alertId}/files/{filename}
      // Also supports: /{callsign}/api/alerts/{alertId}/files/images/{filename}
      final regex = RegExp(r'^/([A-Za-z0-9]+)/api/alerts/([^/]+)/files/(.+)$');
      final match = regex.firstMatch(requestPath);

      if (match == null) {
        request.response.statusCode = 400;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Invalid path format'}));
        return;
      }

      final callsign = match.group(1)!.toUpperCase();
      final alertId = match.group(2)!;
      final relativePath = match.group(3)!;

      // Validate path (prevent directory traversal)
      if (relativePath.contains('..') || relativePath.contains('\\') || relativePath.startsWith('/')) {
        request.response.statusCode = 400;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Invalid path'}));
        return;
      }

      // Find alert path (searches recursively for backwards compatibility)
      final alertPath = await _findAlertPath(callsign, alertId);

      File? file;
      final normalizedAlertPath = alertPath != null ? path.normalize(alertPath) : null;

      if (normalizedAlertPath != null) {
        final resolvedPath = path.normalize(path.join(normalizedAlertPath, relativePath));
        if (!resolvedPath.startsWith(normalizedAlertPath)) {
          request.response.statusCode = 400;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'error': 'Invalid path'}));
          return;
        }

        final resolvedFile = File(resolvedPath);
        if (await resolvedFile.exists()) {
          file = resolvedFile;
        }
      }

      final ext = path.extension(relativePath).toLowerCase();
      final isImageRequest = ext == '.jpg' || ext == '.jpeg' || ext == '.png' || ext == '.gif' || ext == '.webp';
      final cleanFilename = path.basename(relativePath);

      if (file == null || !await file.exists()) {
        if (!isImageRequest) {
          request.response.statusCode = 404;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({
            'error': 'File not found',
            'callsign': callsign,
            'alert_id': alertId,
            'filename': cleanFilename,
          }));
          return;
        }

        // Image not found on station - try to fetch from the author if they're online
        _log('INFO', 'ALERT PHOTO: $cleanFilename not found locally, checking if author $callsign is online');

        // Find the client by callsign
        PureConnectedClient? authorClient;
        for (final c in _clients.values) {
          if (c.callsign?.toUpperCase() == callsign) {
            authorClient = c;
            break;
          }
        }

        if (authorClient != null && alertPath != null) {
          // Author is online - try to fetch the photo (will store in images/)
          _log('INFO', 'ALERT PHOTO: Author $callsign is online, fetching $cleanFilename');
          final fetched = await _fetchSinglePhotoFromClient(authorClient, callsign, alertId, cleanFilename);
          if (fetched) {
            final imagesFilePath = '$alertPath/images/$cleanFilename';
            if (await File(imagesFilePath).exists()) {
              file = File(imagesFilePath);
            }
          } else {
            _log('WARN', 'ALERT PHOTO: Failed to fetch $cleanFilename from author');
          }
        } else {
          _log('INFO', 'ALERT PHOTO: Author $callsign is not online or alert not found');
        }

        // Check again if file exists after potential fetch
        if (file == null || !await file.exists()) {
          request.response.statusCode = 404;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({
            'error': 'File not found',
            'callsign': callsign,
            'alert_id': alertId,
            'filename': cleanFilename,
            'author_online': authorClient != null,
          }));
          return;
        }
      }

      // Determine content type
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

      // Read and serve the file
      final bytes = await file.readAsBytes();

      request.response.statusCode = 200;
      request.response.headers.set('Content-Type', contentType);
      request.response.headers.set('Content-Length', bytes.length.toString());
      request.response.headers.set('Cache-Control', 'public, max-age=86400');
      request.response.add(bytes);

      _log('INFO', 'ALERT FILE SERVE: Served $relativePath for alert $alertId (${bytes.length} bytes)');
    } catch (e) {
      _log('ERROR', 'Error serving alert file: $e');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Internal server error', 'message': e.toString()}));
    }
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

  /// Check if path matches /{callsign}/api/* pattern
  bool _isCallsignApiPath(String path) {
    // Pattern: /{callsign}/api/{endpoint}
    // Callsigns are alphanumeric (X1ABC, etc.) followed by /api/
    final regex = RegExp(r'^/([A-Za-z0-9]+)/api/');
    return regex.hasMatch(path);
  }

  bool _isCallsignMeetPath(String path) {
    final regex = RegExp(r'^/([A-Za-z0-9]+)/meet/');
    return regex.hasMatch(path);
  }

  /// Handle /{callsign}/api/* requests - proxy to connected device
  Future<void> _handleCallsignApiProxy(HttpRequest request) async {
    final path = request.uri.path;

    // Parse path: /{callsign}/api/{endpoint} or /{callsign}/meet/{endpoint}
    final regex = RegExp(r'^/([A-Za-z0-9]+)/(api|meet)/(.*)$');
    final match = regex.firstMatch(path);

    if (match == null) {
      request.response.statusCode = 400;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Invalid path format'}));
      return;
    }

    final callsign = match.group(1)!;
    final kind = match.group(2)!;
    final remainingPath = match.group(3)!;
    final query = request.uri.query;
    final basePath = kind == 'meet'
        ? '/meet/$remainingPath'
        : '/api/$remainingPath';
    final apiPath = query.isEmpty ? basePath : '$basePath?$query';

    // Find the client by callsign (case-insensitive)
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
        'error': 'Device not connected',
        'callsign': callsign.toUpperCase(),
        'message': 'The device ${callsign.toUpperCase()} is not currently connected to this station',
      }));
      return;
    }

    final client = foundClient;
    _log('INFO', 'Device proxy: ${request.method} $path -> ${client.callsign} $apiPath');

    // Proxy request to device via WebSocket
    final requestId = DateTime.now().millisecondsSinceEpoch.toString();
    final proxyRequest = {
      'type': 'HTTP_REQUEST',
      'requestId': requestId,
      'method': request.method,
      'path': apiPath,
      'headers': jsonEncode({}),
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
          'responseHeaders': '{"Content-Type": "application/json"}',
          'responseBody': jsonEncode({
            'error': 'Gateway Timeout',
            'message': 'Device ${callsign.toUpperCase()} did not respond in time',
          }),
          'isBase64': false,
        },
      );

      request.response.statusCode = response['statusCode'] ?? 500;
      if (response['responseHeaders'] != null) {
        try {
          final headers = jsonDecode(response['responseHeaders'] as String) as Map<String, dynamic>;
          const skipHeaders = {'transfer-encoding', 'content-length', 'connection'};
          headers.forEach((key, value) {
            final lk = key.toLowerCase();
            if (skipHeaders.contains(lk)) return;
            if (lk == 'content-type') {
              final ct = value.toString();
              final parts = ct.split(';');
              final mimeType = parts.first.trim();
              final mimeParts = mimeType.split('/');
              if (mimeParts.length == 2) {
                final charset = ct.contains('charset=')
                    ? ct.split('charset=').last.split(';').first.trim()
                    : null;
                request.response.headers.contentType = ContentType(
                  mimeParts[0], mimeParts[1], charset: charset,
                );
              }
            } else {
              try {
                request.response.headers.set(key, value.toString());
              } catch (_) {}
            }
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

      _log('INFO', 'Device proxy response: ${response['statusCode']} for ${client.callsign} $apiPath');
    } catch (e) {
      request.response.statusCode = 502;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'error': 'Bad Gateway',
        'message': e.toString(),
      }));
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

  /// POST /api/station/send - Send NOSTR-signed message from station
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

      // Use UTC for consistent timestamp handling
      final now = DateTime.now().toUtc();
      final msg = ChatMessage(
        id: now.millisecondsSinceEpoch.toString(),
        roomId: room,
        senderCallsign: callsign,
        content: content,
        timestamp: now,
      );
      chatRoom.messages.add(msg);
      chatRoom.lastActivity = now;
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
      'station': _settings.callsign,
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

  /// Check if path is a chat files list request
  /// Accepts both: /api/chat/{roomId}/files and /api/chat/rooms/{roomId}/files
  bool _isChatFilesListPath(String path) {
    return ChatApi.isFilesListPath(path);
  }

  /// Check if path is a chat file download request
  /// Accepts both: /api/chat/{roomId}/files/{filename} and /api/chat/rooms/{roomId}/files/{filename}
  bool _isChatFileDownloadPath(String path) {
    return ChatApi.isFileDownloadPath(path);
  }

  /// Check if path is a chat reactions request
  /// Accepts both: /api/chat/{roomId}/messages/{ts}/reactions and /api/chat/rooms/{roomId}/messages/{ts}/reactions
  bool _isChatReactionPath(String path) {
    return ChatApi.isReactionsPath(path);
  }

  /// Check if path is a chat file content request
  /// Accepts both: /api/chat/{roomId}/file/{year}/{filename} and /api/chat/rooms/{roomId}/file/{year}/{filename}
  bool _isChatFileContentPath(String path) {
    return RegExp(r'^(/[A-Z0-9]+)?/api/chat/(rooms/)?[^/]+/file/\d{4}/[^/]+$').hasMatch(path);
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

  /// GET /{identifier} or /{identifier}/* - Serve WWW collection from device
  /// Supports both callsign (e.g., X1QVM3) and nickname (e.g., brito) lookups
  Future<void> _handleCallsignOrNicknameWww(HttpRequest request) async {
    final path = request.uri.path;
    final parts = path.substring(1).split('/');
    final identifier = parts.first.toLowerCase();

    // Redirect /{identifier} to /{identifier}/ for proper relative path resolution
    // This ensures that relative links like ./blog/ work correctly in the browser
    if (parts.length == 1 && !path.endsWith('/')) {
      request.response.statusCode = 301;
      request.response.headers.add('Location', '$path/');
      return;
    }

    // Get file path - filter out empty parts from trailing slashes
    final subParts = parts.sublist(1).where((p) => p.isNotEmpty).toList();
    final filePath = subParts.isNotEmpty ? subParts.join('/') : 'index.html';

    // Check if any client matches this identifier
    final clients = _findAllClientsByIdentifier(identifier);
    if (clients.isEmpty) {
      request.response.statusCode = 404;
      request.response.write('Device not connected');
      return;
    }

    // Route to the appropriate collection based on the first path segment
    // Use centralized app types list from app_constants.dart
    // Path format: /{app}/{rest} (e.g., /blog/index.html, /www/index.html)
    String appPath;
    if (subParts.isNotEmpty && knownAppTypesConst.contains(subParts.first.toLowerCase())) {
      // Route to specific app collection: /{app}/{rest}
      final app = subParts.first.toLowerCase();
      final rest = subParts.length > 1 ? subParts.sublist(1).join('/') : '';
      appPath = '/$app/${rest.isEmpty ? "index.html" : rest}';
    } else {
      // Default to www collection
      appPath = '/www/$filePath';
    }

    // Try all devices sequentially (most responsive first)
    final response = await _proxyToAnyDevice(identifier, 'GET', appPath);

    if (response == null) {
      request.response.statusCode = 504;
      request.response.write('Gateway Timeout: No device responded');
      return;
    }

    request.response.statusCode = response['statusCode'] ?? 500;
    final body = response['responseBody'] ?? '';
    final isBase64 = response['isBase64'] == true;

    // Set content type based on file extension
    final ext = appPath.split('.').last.toLowerCase();
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
  }

  /// Pending proxy requests waiting for device response
  final Map<String, Completer<Map<String, dynamic>>> _pendingProxyRequests = {};

  /// Find ALL connected clients matching a callsign or nickname, sorted by responsiveness
  List<PureConnectedClient> _findAllClientsByIdentifier(String identifier) {
    final lower = identifier.toLowerCase();
    final matches = _clients.values.where((c) =>
      c.callsign?.toLowerCase() == lower ||
      (c.nickname != null && c.nickname!.toLowerCase() == lower)
    ).toList();
    matches.sort((a, b) => b.successRate.compareTo(a.successRate));
    return matches;
  }

  /// Proxy a request to a single device. Returns the response map without writing to HttpResponse.
  /// Updates successCount/failCount on the client.
  Future<Map<String, dynamic>?> _proxySingleDevice(
    PureConnectedClient client,
    String method,
    String path,
    String headers,
    String body,
  ) async {
    final requestId = '${DateTime.now().millisecondsSinceEpoch}_${client.id}';
    final proxyRequest = {
      'type': 'HTTP_REQUEST',
      'requestId': requestId,
      'method': method,
      'path': path,
      'headers': headers,
      'body': body,
    };

    final completer = Completer<Map<String, dynamic>>();
    _pendingProxyRequests[requestId] = completer;

    try {
      client.socket.add(jsonEncode(proxyRequest));
      final response = await completer.future.timeout(const Duration(seconds: 5));
      final statusCode = response['statusCode'] as int? ?? 500;
      if (statusCode >= 200 && statusCode < 400) {
        client.successCount++;
      } else if (statusCode == 404) {
        // 404 is not the device's fault, don't penalize
      } else {
        client.failCount++;
      }
      return response;
    } on TimeoutException {
      client.failCount++;
      return null;
    } catch (e) {
      client.failCount++;
      return null;
    } finally {
      _pendingProxyRequests.remove(requestId);
    }
  }

  /// Try all devices for a callsign/nickname sequentially (most responsive first).
  /// Returns the first 200 response, or last non-null response, or null.
  Future<Map<String, dynamic>?> _proxyToAnyDevice(
    String identifier,
    String method,
    String path, {
    String headers = '',
    String body = '',
  }) async {
    final clients = _findAllClientsByIdentifier(identifier);
    if (clients.isEmpty) return null;

    Map<String, dynamic>? lastResponse;
    for (final client in clients) {
      final response = await _proxySingleDevice(client, method, path, headers, body);
      if (response != null) {
        lastResponse = response;
        final statusCode = response['statusCode'] as int? ?? 500;
        if (statusCode >= 200 && statusCode < 400) {
          return response; // Success, return immediately
        }
      }
    }
    return lastResponse;
  }

  /// Proxy an HTTP request to a connected device via WebSocket (multi-device aware)
  Future<void> _proxyRequestToDevice(HttpRequest request, String callsign, String apiPath) async {
    final clients = _findAllClientsByIdentifier(callsign);
    if (clients.isEmpty) {
      request.response.statusCode = 404;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'error': 'Device not connected',
        'callsign': callsign.toUpperCase(),
        'message': 'The device ${callsign.toUpperCase()} is not currently connected to this station',
      }));
      return;
    }

    _log('INFO', 'Device proxy: ${request.method} -> $callsign $apiPath (${clients.length} device(s))');

    // Read request body first (can only be read once)
    String requestBody = '';
    if (request.contentLength > 0) {
      requestBody = await utf8.decodeStream(request);
    }

    // Try all devices sequentially
    final response = await _proxyToAnyDevice(
      callsign, request.method, apiPath,
      headers: jsonEncode({}),
      body: requestBody,
    );

    if (response == null) {
      request.response.statusCode = 504;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'error': 'Gateway Timeout',
        'message': 'No device responded for ${callsign.toUpperCase()}',
      }));
      return;
    }

    request.response.statusCode = response['statusCode'] ?? 500;
    if (response['responseHeaders'] != null) {
      try {
        final headers = jsonDecode(response['responseHeaders'] as String) as Map<String, dynamic>;
        headers.forEach((key, value) {
          if (key.toLowerCase() == 'content-type') {
            final ct = value.toString();
            if (ct.contains('json')) {
              request.response.headers.contentType = ContentType.json;
            } else if (ct.contains('html')) {
              request.response.headers.contentType = ContentType.html;
            } else if (ct.contains('text')) {
              request.response.headers.contentType = ContentType.text;
            }
          }
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

    _log('INFO', 'Device proxy response: ${response['statusCode']} for $callsign $apiPath');
  }

  /// Handle /.well-known/nostr.json endpoint for NIP-05 verification
  Future<void> _handleWellKnownNostr(HttpRequest request) async {
    request.response.headers.contentType = ContentType.json;
    request.response.headers.add('Access-Control-Allow-Origin', '*');

    try {
      final nameParam = request.uri.queryParameters['name']?.toLowerCase();
      final response = Nip05RegistryService()
          .buildNostrJsonResponse(nameParam, 'wss://p2p.radio');
      request.response.write(jsonEncode(response));
    } catch (e) {
      _log('ERROR', 'NIP-05 handler error: $e');
      request.response.statusCode = 500;
      request.response.write(jsonEncode({'error': 'Internal error'}));
    }
  }

  /// Handle /download endpoint - serve downloads page using shared template
  Future<void> _handleDownload(HttpRequest request) async {
    final stationName = _settings.name ?? 'geogram Station';

    // Generate menu items for station navigation
    final menuItems = WebNavigation.generateStationMenuItems(
      activeApp: 'download',
      hasChat: true,
      hasDownload: true,
    );

    request.response.headers.contentType = ContentType.html;
    request.response.write(StationHtmlTemplates.buildDownloadPage(
      stationName: stationName,
      menuItems: menuItems,
      availableAssets: _downloadedAssets,
      availableWhisperModels: getAvailableWhisperModels(),
      releaseVersion: _cachedRelease?['version'] as String?,
      releaseNotes: _cachedRelease?['body'] as String?,
    ));
  }

  Future<void> _handleRoot(HttpRequest request) async {
    final stationName = _settings.name ?? 'geogram Station';

    // Calculate uptime in minutes
    final uptime = _startTime != null
        ? DateTime.now().difference(_startTime!).inMinutes
        : 0;
    final uptimeStr = formatUptimeFromMinutes(uptime);

    // Generate menu items for station navigation
    final homeMenuItems = WebNavigation.generateStationMenuItems(
      activeApp: 'home',
      hasChat: true,
      hasDownload: true,
    );

    // Build devices list HTML and collect coordinates for map
    final devicesHtml = StringBuffer();
    final devicesWithLocation = <Map<String, dynamic>>[];

    for (final client in _clients.values) {
      final callsign = client.callsign ?? client.id;
      final nickname = client.nickname ?? callsign;
      final connectedAgo = formatTimeAgo(client.connectedAt);
      final location = (client.latitude != null && client.longitude != null)
          ? '${client.latitude!.toStringAsFixed(2)}, ${client.longitude!.toStringAsFixed(2)}'
          : '';

      // Determine device icon based on platform/deviceType
      final platform = (client.platform ?? '').toLowerCase();
      final deviceType = (client.deviceType ?? '').toLowerCase();
      String deviceIcon;
      if (platform.contains('android') || platform.contains('ios') || deviceType.contains('phone') || deviceType.contains('mobile')) {
        deviceIcon = 'phone';
      } else {
        deviceIcon = 'laptop';
      }

      // Collect devices with location for map
      if (client.latitude != null && client.longitude != null) {
        devicesWithLocation.add({
          'callsign': callsign,
          'nickname': nickname,
          'lat': client.latitude,
          'lng': client.longitude,
          'icon': deviceIcon,
        });
      }

      // Only show nickname if different from callsign
      final nicknameHtml = (nickname != callsign)
          ? '<div class="device-nickname">${escapeHtml(nickname)}</div>'
          : '';

      devicesHtml.writeln('''
        <a href="/$callsign/" class="device-card">
          <div class="device-header">
            <span class="device-callsign">$callsign</span>
            <span class="connection-badge internet">Internet</span>
          </div>
          $nicknameHtml
          <div class="device-meta">
            Connected since $connectedAgo${location.isNotEmpty ? ' · $location' : ''}
          </div>
        </a>
      ''');
    }

    // Build devices JSON for map (with icon type)
    final devicesJson = devicesWithLocation.map((d) =>
      '{"callsign":"${d['callsign']}","nickname":"${escapeHtml(d['nickname'] as String)}","lat":${d['lat']},"lng":${d['lng']},"icon":"${d['icon']}"}'
    ).join(',');

    final html = StationHtmlTemplates.buildStationHomepage(
      stationName: stationName,
      callsign: _settings.callsign,
      version: cliAppVersion,
      uptimeStr: uptimeStr,
      clientCount: _clients.length,
      devicesHtml: devicesHtml.toString(),
      devicesJson: devicesJson,
      menuItems: homeMenuItems,
      hasDevicesWithLocation: devicesWithLocation.isNotEmpty,
      globalStyles: StationHtmlTemplates.getBaseStyles(),
      stationStyles: '',
    );

    await _sendCompressedResponse(
      request,
      html,
      ContentType.html,
      cacheControl: 'public, max-age=30',
    );
  }

  /// Sync embedded theme files to disk, overwriting if content differs
  Future<void> _syncBundledThemes() async {
    final themesDir = '${PureStorageConfig().baseDir}/themes';
    var updated = 0;

    for (final entry in ThemesEmbedded.files.entries) {
      try {
        final targetPath = '$themesDir/${entry.key}';
        final file = File(targetPath);

        if (await file.exists()) {
          final existing = await file.readAsString();
          if (existing == entry.value) continue;
        }

        await file.parent.create(recursive: true);
        await file.writeAsString(entry.value);
        updated++;
        _log('INFO', 'Updated theme file: ${entry.key}');
      } catch (e) {
        _log('WARN', 'Could not extract theme ${entry.key}: $e');
      }
    }

    if (updated > 0) {
      _log('INFO', 'Theme sync: $updated files updated');
    }
  }

  /// Serve a CSS file from the themes directory
  Future<void> _handleThemeFile(String relativePath, HttpRequest request) async {
    final file = File('${PureStorageConfig().baseDir}/themes/default/$relativePath');
    if (await file.exists()) {
      request.response.headers.set('Content-Type', 'text/css');
      request.response.headers.set('Cache-Control', 'no-cache');
      request.response.write(await file.readAsString());
    } else {
      request.response.statusCode = 404;
      request.response.write('Not Found');
    }
  }

  /// Handle /chat page - shows station's chat rooms
  /// Reuses the same template pattern as remote device chat pages
  Future<void> _handleChatPage(HttpRequest request) async {
    final stationName = (_settings.name?.isNotEmpty == true) ? _settings.name! : _settings.callsign;

    // Read theme template from disk (CSS is served via /styles.css routes)
    final themesDir = '${PureStorageConfig().baseDir}/themes/default';
    String? template;

    try {
      final templateFile = File('$themesDir/chat/index.html');
      if (await templateFile.exists()) {
        template = await templateFile.readAsString();
      }
    } catch (e) {
      _log('WARN', 'Error reading theme files: $e');
    }

    // Build channel list HTML for sidebar (same pattern as collection_service)
    final channelsHtml = StringBuffer();
    final rooms = _chatRooms.values.toList();
    final defaultRoom = rooms.isNotEmpty ? rooms.first.id : 'general';

    if (rooms.isEmpty) {
      channelsHtml.writeln('<div class="empty-state">No rooms yet</div>');
    } else {
      for (final room in rooms) {
        final isActive = room.id == defaultRoom;
        final roomName = room.name.isNotEmpty ? room.name : room.id;
        channelsHtml.writeln('''
<div class="channel-item${isActive ? ' active' : ''}" data-room-id="${escapeHtml(room.id)}">
  <span class="channel-name">#${escapeHtml(roomName)}</span>
</div>''');
      }
    }

    // Build messages HTML for default room
    final messagesHtml = StringBuffer();
    if (rooms.isNotEmpty) {
      final messages = getChatHistory(defaultRoom, limit: 20);
      if (messages.isEmpty) {
        messagesHtml.writeln('<div class="empty-state">No messages yet</div>');
      } else {
        String? currentDate;
        for (final msg in messages) {
          // Format timestamp - DateTime to string
          final ts = msg.timestamp;
          final msgDate = '${ts.year}-${ts.month.toString().padLeft(2, '0')}-${ts.day.toString().padLeft(2, '0')}';
          final msgTime = '${ts.hour.toString().padLeft(2, '0')}:${ts.minute.toString().padLeft(2, '0')}';
          final timestampIso = ts.toUtc().toIso8601String();

          // Add date separator if date changed
          if (currentDate != msgDate) {
            currentDate = msgDate;
            messagesHtml.writeln('<div class="date-separator">$msgDate</div>');
          }

          final author = escapeHtml(msg.senderCallsign);
          final content = escapeHtml(msg.content);

          messagesHtml.writeln('''
<div class="message" data-timestamp="${escapeHtml(timestampIso)}">
  <div class="message-header">
    <span class="message-author">$author</span>
    <span class="message-time">$msgTime</span>
  </div>
  <div class="message-content">$content</div>
</div>''');
        }
      }
    } else {
      messagesHtml.writeln('<div class="empty-state">No messages yet</div>');
    }

    // Build data JSON for JavaScript
    final channelsList = rooms.map((r) => <String, dynamic>{
      'id': r.id,
      'name': r.name.isNotEmpty ? r.name : r.id,
    }).toList();
    final dataJson = jsonEncode({
      'channels': channelsList,
      'currentRoom': defaultRoom,
      'apiBasePath': '/api/chat/rooms',
    });

    // Process template with variables
    String html;
    final nostrScripts = getNostrLoginScripts();
    final chatScripts = getChatPageScripts();
    final combinedScripts = '$nostrScripts\n$chatScripts';

    // Generate menu items for station navigation
    final menuItems = WebNavigation.generateStationMenuItems(
      activeApp: 'chat',
      hasChat: true,
      hasDownload: true,
      // Station doesn't have blog, events, etc. by default
      hasBlog: false,
      hasEvents: false,
      hasPlaces: false,
      hasFiles: false,
      hasAlerts: false,
    );

    if (template != null) {
      // Process template with variable substitution
      final variables = {
        'TITLE': 'Chat - ${escapeHtml(stationName)}',
        'COLLECTION_NAME': stationName,
        'COLLECTION_DESCRIPTION': '${rooms.length} room${rooms.length != 1 ? 's' : ''}',
        'CONTENT': messagesHtml.toString(),
        'CHANNELS_LIST': channelsHtml.toString(),
        'DATA_JSON': dataJson,
        'SCRIPTS': combinedScripts,
        'NOSTR_HEADER': getNostrLoginHeaderHtml(),
        'NOSTR_STYLES': getNostrLoginStyles(),
        'MENU_ITEMS': menuItems,
        'HOME_URL': '/',
        'GENERATED_DATE': DateTime.now().toIso8601String().split('T').first,
      };
      html = template;
      for (final entry in variables.entries) {
        html = html.replaceAll('{{${entry.key}}}', entry.value);
      }
    } else {
      // Fallback if template not found
      html = '''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1">
  <title>Chat - ${escapeHtml(stationName)}</title>
  <link rel="stylesheet" href="/styles.css">
  <link rel="stylesheet" href="styles.css">
  ${getNostrLoginStyles()}
</head>
<body>
<div class="container">
  <header class="header">
    <div class="header__inner">
      <div class="header__logo">
        <a href="/" style="text-decoration: none;">
          <div class="logo">$stationName</div>
        </a>
      </div>
      ${getNostrLoginHeaderHtml()}
    </div>
    <nav class="menu">
      <ul class="menu__inner">
        $menuItems
      </ul>
    </nav>
  </header>

  <div class="content">
    <div class="chat-layout">
      <aside class="channels-sidebar" id="channels">
        <div class="channels-header">Channels</div>
        ${channelsHtml.toString()}
      </aside>

      <div class="messages-area">
        <div class="messages-header">
          <span class="room-name">#<span id="current-room">$defaultRoom</span></span>
        </div>
        <div class="messages-list" id="messages">
          ${messagesHtml.toString()}
        </div>
        <div class="chat-input-area" id="chat-input-area" style="display:none;">
          <input type="text" id="chat-input" placeholder="Type a message..." autocomplete="off">
          <button id="chat-send">Send</button>
        </div>
      </div>
    </div>
  </div>

  <footer class="footer">
    <div class="footer__inner">
      <div class="copyright">
        <span>powered by geogram</span>
      </div>
    </div>
  </footer>
</div>

<script>
  window.GEOGRAM_DATA = $dataJson;
  $combinedScripts
</script>
</body>
</html>
''';
    }

    await _sendCompressedResponse(
      request,
      html,
      ContentType.html,
      cacheControl: 'public, max-age=60',
    );
  }

  /// Send a compressed response if client accepts gzip
  Future<void> _sendCompressedResponse(
    HttpRequest request,
    String content,
    ContentType contentType, {
    String? cacheControl,
  }) async {
    final acceptEncoding = request.headers.value('accept-encoding') ?? '';
    final supportsGzip = acceptEncoding.contains('gzip');

    request.response.headers.contentType = contentType;
    if (cacheControl != null) {
      request.response.headers.set('Cache-Control', cacheControl);
    }

    if (supportsGzip && content.length > 1000) {
      // Compress responses larger than 1KB
      final bytes = utf8.encode(content);
      final compressed = gzip.encode(bytes);
      request.response.headers.set('Content-Encoding', 'gzip');
      request.response.headers.set('Content-Length', compressed.length.toString());
      request.response.add(compressed);
    } else {
      request.response.write(content);
    }
  }

  Future<void> _handleChatRooms(HttpRequest request, String targetCallsign) async {
    // If targeting a remote device, proxy the request
    if (targetCallsign.toUpperCase() != _settings.callsign.toUpperCase()) {
      await _proxyRequestToDevice(request, targetCallsign, '/api/chat/rooms');
      return;
    }

    if (request.method == 'GET') {
      final authEvent = _verifyNostrAuthHeader(request);
      final authNpub = authEvent?.npub;
      final rooms = _chatRooms.values.map((r) {
        final roomJson = r.toJson();
        injectModeratorFlag(roomJson, r.id, authNpub);
        return roomJson;
      }).toList();
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

  /// Handle DELETE/PUT for a single chat room (delete/rename)
  Future<void> _handleChatRoomCrud(HttpRequest request, String targetCallsign) async {
    final roomId = ChatApi.extractRoomCrudId(request.uri.path);
    if (roomId == null) {
      request.response.statusCode = 400;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Missing room ID'}));
      return;
    }

    // If targeting a remote device, proxy the request
    if (targetCallsign.toUpperCase() != _settings.callsign.toUpperCase()) {
      await _proxyRequestToDevice(request, targetCallsign, ChatApi.roomCrudPath(roomId));
      return;
    }

    // Require moderator auth for all room CRUD operations
    final authEvent = _verifyNostrAuthHeader(request);
    if (authEvent == null) {
      request.response.statusCode = 403;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Authentication required'}));
      return;
    }
    if (!chatSecurity.canModerate(authEvent.npub, roomId)) {
      request.response.statusCode = 403;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Moderator access required'}));
      return;
    }

    if (request.method == 'DELETE') {
      if (roomId == 'general') {
        request.response.statusCode = 400;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Cannot delete the general room'}));
        return;
      }
      if (deleteChatRoom(roomId)) {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'success': true, 'roomId': roomId}));
      } else {
        request.response.statusCode = 404;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Room not found'}));
      }
    } else if (request.method == 'PUT') {
      final body = await utf8.decoder.bind(request).join();
      final data = jsonDecode(body) as Map<String, dynamic>;
      final newName = data['name'] as String?;
      if (newName == null || newName.isEmpty) {
        request.response.statusCode = 400;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Missing name'}));
        return;
      }
      if (renameChatRoom(roomId, newName)) {
        final room = _chatRooms[roomId]!;
        await _saveRoomConfig(room, targetCallsign);
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(room.toJson()));
      } else {
        request.response.statusCode = 404;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Room not found'}));
      }
    } else {
      request.response.statusCode = 405;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Method not allowed'}));
    }
  }

  Future<void> _handleRoomMessages(HttpRequest request, String targetCallsign) async {
    final path = request.uri.path;
    final roomId = _extractRoomId(path) ?? 'general';

    // If targeting a remote device, proxy the request
    if (targetCallsign.toUpperCase() != _settings.callsign.toUpperCase()) {
      await _proxyRequestToDevice(request, targetCallsign, ChatApi.messagesPath(roomId));
      return;
    }

    final room = _chatRooms[roomId];
    if (room == null) {
      request.response.statusCode = 404;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Room not found'}));
      return;
    }

    if (request.method == 'GET') {
      final limit = int.tryParse(request.uri.queryParameters['limit'] ?? '50') ?? 50;
      final before = request.uri.queryParameters['before'];
      final messages = getChatHistory(roomId, limit: limit, before: before).map((m) => m.toJson()).toList();
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'room_id': roomId,
        'room_name': room.name,
        'callsign': targetCallsign,
        'messages': messages,
        'count': messages.length,
        'has_more': messages.length == limit,
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

        // Required NOSTR signature fields
        var npub = data['npub'] as String?;
        final pubkey = data['pubkey'] as String?;
        final eventId = data['event_id'] as String?;
        final signature = data['signature'] as String?;
        final createdAt = data['created_at'] as int?;

        if (pubkey == null || pubkey.isEmpty ||
            signature == null || signature.isEmpty ||
            eventId == null || eventId.isEmpty) {
          request.response
            ..statusCode = HttpStatus.forbidden
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({
              'error': 'Valid NOSTR signature required',
              'code': 'SIGNATURE_REQUIRED',
            }));
          return;
        }

        // Derive npub from pubkey if not provided
        if ((npub == null || npub.isEmpty) && pubkey != null && pubkey.isNotEmpty) {
          try {
            npub = NostrCrypto.encodeNpub(pubkey);
          } catch (e) {
            _log('WARN', 'Failed to derive npub from pubkey: $e');
          }
        }

        // Verify NOSTR signature (mandatory)
        bool isVerified = false;
        try {
          final event = NostrEvent(
            id: eventId!,
            pubkey: pubkey!,
            createdAt: createdAt ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000),
            kind: 1,
            tags: [['t', 'chat'], ['room', roomId], ['callsign', senderCallsign]],
            content: content,
            sig: signature!,
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

        if (!isVerified) {
          request.response
            ..statusCode = HttpStatus.forbidden
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({
              'error': 'Valid NOSTR signature required',
              'code': 'SIGNATURE_REQUIRED',
            }));
          return;
        }

        // Extract metadata (file attachments, etc.)
        final rawMetadata = data['metadata'] as Map?;
        final metadata = <String, String>{};
        if (rawMetadata != null) {
          rawMetadata.forEach((key, value) {
            metadata[key.toString()] = value.toString();
          });
        }

        // Create message
        final msg = ChatMessage(
          id: eventId ?? DateTime.now().millisecondsSinceEpoch.toString(),
          roomId: roomId,
          senderCallsign: senderCallsign,
          senderNpub: npub,
          senderPubkey: pubkey,
          signature: signature,
          content: content,
          timestamp: createdAt != null
              ? DateTime.fromMillisecondsSinceEpoch(createdAt * 1000, isUtc: true)
              : DateTime.now().toUtc(),
          verified: isVerified,
          hasSignature: true,
          metadata: metadata,
        );

        if (!_addChatMessage(room, msg)) {
          _log('DEBUG', 'Duplicate HTTP POST message skipped for room $roomId');
          request.response
            ..statusCode = HttpStatus.conflict
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'error': 'Duplicate message'}))
            ..close();
          return;
        }
        room.lastActivity = DateTime.now();
        _stats.totalMessages++;
        _stats.lastMessage = DateTime.now();

        // Register sender in NIP-05 registry
        registerChatSender(senderCallsign, npub);

        // Fire event for subscribers
        _fireChatMessageEvent(msg);

        // Persist to disk under the target callsign's folder
        await _saveRoomMessages(roomId, targetCallsign);

        // Broadcast to connected WebSocket clients
        final payload = jsonEncode({
          'type': 'chat_message',
          'room': roomId,
          'callsign': targetCallsign,
          'message': msg.toJson(),
        });
        final updateNotification = 'UPDATE:${_settings.callsign}/chat/$roomId';
        for (final client in _clients.values) {
          try {
            client.socket.add(payload);
            client.socket.add(updateNotification);
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

  Future<void> _handleRoomMessageReactions(HttpRequest request, String targetCallsign) async {
    if (request.method != 'POST') {
      request.response.statusCode = 405;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Method not allowed'}));
      return;
    }

    final apiPath = _getApiPathWithoutCallsign(request.uri.path);
    // Accept both: /api/chat/{roomId}/messages/{ts}/reactions and /api/chat/rooms/{roomId}/messages/{ts}/reactions
    final match = RegExp(r'^/api/chat/(rooms/)?([^/]+)/messages/(.+)/reactions$').firstMatch(apiPath);
    if (match == null) {
      request.response.statusCode = 400;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Invalid reaction path'}));
      return;
    }

    final roomId = Uri.decodeComponent(match.group(2)!);
    final timestampRaw = Uri.decodeComponent(match.group(3)!);

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
    if (timestampTag != null && timestampTag != timestampRaw) {
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
    if (reactionKey.isEmpty || !ReactionUtils.supportedReactions.contains(reactionKey)) {
      request.response.statusCode = 400;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'error': 'Unsupported reaction',
        'reaction': reactionKey,
        'supported_reactions': ReactionUtils.supportedReactions,
      }));
      return;
    }

    final room = _chatRooms[roomId];
    if (room == null) {
      request.response.statusCode = 404;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Room not found'}));
      return;
    }

    final targetTime = _parseApiTimestamp(timestampRaw);
    final index = room.messages.indexWhere((msg) =>
        _messageTimestampMatches(msg, timestampRaw, targetTime));
    if (index == -1) {
      request.response.statusCode = 404;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Message not found', 'code': 'NOT_FOUND'}));
      return;
    }

    final actorCallsign = callsignTag.trim().toUpperCase();
    final updated = _toggleMessageReaction(room.messages[index], reactionKey, actorCallsign);
    room.messages[index] = updated;

    await _saveRoomMessages(roomId, targetCallsign);

    // Record chat reaction karma
    karmaRecord(
        callsign: actorCallsign,
        action: 'chat_reaction',
        meta: {'room_id': roomId});

    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({
      'success': true,
      'room_id': roomId,
      'timestamp': timestampRaw,
      'reaction': reactionKey,
      'reactions': updated.reactions,
    }));
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
        _log('WARN', 'Chat reaction auth failed - invalid signature');
        return null;
      }

      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if ((now - event.createdAt).abs() > 300) {
        _log('WARN', 'Chat reaction auth failed - event expired');
        return null;
      }

      final actionTag = event.getTagValue('action');
      if (actionTag != expectedAction) {
        _log('WARN', 'Chat reaction auth failed - action mismatch: $actionTag');
        return null;
      }

      final roomTag = event.getTagValue('room');
      if (roomTag != expectedRoomId) {
        _log('WARN', 'Chat reaction auth failed - room mismatch: $roomTag');
        return null;
      }

      return event;
    } catch (e) {
      _log('WARN', 'Chat reaction auth failed - parse error: $e');
      return null;
    }
  }

  DateTime? _parseApiTimestamp(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.contains('T')) {
      final parsed = DateTime.tryParse(trimmed);
      return parsed?.toUtc();
    }
    if (trimmed.contains(' ')) {
      return _parseTimestamp(trimmed).toUtc();
    }
    final parsed = DateTime.tryParse(trimmed);
    return parsed?.toUtc();
  }

  bool _messageTimestampMatches(ChatMessage message, String raw, DateTime? targetTime) {
    final trimmed = raw.trim();
    if (targetTime != null) {
      final msgTime = message.timestamp.toUtc();
      if (msgTime.difference(targetTime).inSeconds == 0) {
        return true;
      }
    }

    final iso = message.timestamp.toUtc().toIso8601String();
    if (trimmed == iso) {
      return true;
    }

    final formatted = _formatChatTimestamp(message.timestamp.toUtc());
    return trimmed == formatted;
  }

  String _formatChatTimestamp(DateTime dt) {
    return '${_formatDate(dt)} ${_formatTime(dt)}';
  }

  ChatMessage _toggleMessageReaction(
    ChatMessage message,
    String reactionKey,
    String actorCallsign,
  ) {
    final updatedReactions = ReactionUtils.normalizeReactionMap(message.reactions);
    final normalizedKey = ReactionUtils.normalizeReactionKey(reactionKey);
    final normalizedActor = actorCallsign.trim().toUpperCase();

    final list = List<String>.from(updatedReactions[normalizedKey] ?? <String>[]);
    final existingIndex = list.indexWhere((u) => u.toUpperCase() == normalizedActor);
    if (existingIndex >= 0) {
      list.removeAt(existingIndex);
    } else {
      list.add(normalizedActor);
    }

    if (list.isEmpty) {
      updatedReactions.remove(normalizedKey);
    } else {
      updatedReactions[normalizedKey] = list.toSet().toList()..sort();
    }

    return ChatMessage(
      id: message.id,
      roomId: message.roomId,
      senderCallsign: message.senderCallsign,
      senderNpub: message.senderNpub,
      signature: message.signature,
      content: message.content,
      timestamp: message.timestamp,
      verified: message.verified,
      hasSignature: message.hasSignature,
      reactions: updatedReactions,
    );
  }

  /// Extract room ID from path - handles both formats:
  /// - /api/chat/{roomId}/... (unified)
  /// - /api/chat/rooms/{roomId}/... (legacy)
  String? _extractRoomId(String path) {
    return ChatApi.extractRoomId(path);
  }

  /// Handle GET /api/chat/{roomId}/files - list chat files for caching
  /// Accepts both formats: /api/chat/{roomId}/files and /api/chat/rooms/{roomId}/files
  /// Also supports callsign prefix: /{callsign}/api/chat/{roomId}/files
  Future<void> _handleChatFilesList(HttpRequest request, String targetCallsign) async {
    final path = request.uri.path;
    final roomId = ChatApi.extractRoomId(path);

    if (roomId == null) {
      request.response.statusCode = 400;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Invalid path'}));
      return;
    }

    // If targeting a remote device, proxy the request
    if (targetCallsign.toUpperCase() != _settings.callsign.toUpperCase()) {
      await _proxyRequestToDevice(request, targetCallsign, ChatApi.filesPath(roomId));
      return;
    }

    final room = _chatRooms[roomId];

    if (room == null) {
      request.response.statusCode = 404;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Room not found'}));
      return;
    }

    // Get the chat directory for this room under the target callsign
    final chatDir = Directory('${_getChatDataPath(targetCallsign)}/$roomId');

    final List<Map<String, dynamic>> files = [];

    if (await chatDir.exists()) {
      // List all year directories
      await for (final yearEntity in chatDir.list()) {
        if (yearEntity is Directory) {
          final yearName = yearEntity.path.split(Platform.pathSeparator).last;
          if (RegExp(r'^\d{4}$').hasMatch(yearName)) {
            // List all chat files in the year directory
            await for (final fileEntity in yearEntity.list()) {
              if (fileEntity is File && fileEntity.path.endsWith('_chat.txt')) {
                final filename = fileEntity.path.split(Platform.pathSeparator).last;
                final stat = await fileEntity.stat();
                files.add({
                  'year': yearName,
                  'filename': filename,
                  'size': stat.size,
                  'modified': stat.modified.millisecondsSinceEpoch,
                });
              }
            }
          }
        }
      }
    }

    // Sort by year and filename
    files.sort((a, b) {
      final yearCompare = (a['year'] as String).compareTo(b['year'] as String);
      if (yearCompare != 0) return yearCompare;
      return (a['filename'] as String).compareTo(b['filename'] as String);
    });

    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({
      'room_id': roomId,
      'station': _settings.callsign,
      'files': files,
      'count': files.length,
    }));
  }

  /// Handle POST /api/chat/{roomId}/files - upload file to chat room
  /// Accepts both formats: /api/chat/{roomId}/files and /api/chat/rooms/{roomId}/files
  /// Also supports callsign prefix: /{callsign}/api/chat/{roomId}/files
  Future<void> _handleChatFileUpload(HttpRequest request, String targetCallsign) async {
    final path = request.uri.path;
    final roomId = ChatApi.extractRoomId(path);

    if (roomId == null) {
      request.response.statusCode = 400;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Invalid path'}));
      return;
    }

    // If targeting a remote device, proxy the request
    if (targetCallsign.toUpperCase() != _settings.callsign.toUpperCase()) {
      await _proxyRequestToDevice(request, targetCallsign, ChatApi.filesPath(roomId));
      return;
    }

    final room = _chatRooms[roomId];

    if (room == null) {
      request.response.statusCode = 404;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Room not found'}));
      return;
    }

    // Verify NOSTR authentication
    final authEvent = _verifyNostrEventWithTags(request, 'upload', roomId);
    if (authEvent == null) {
      request.response.statusCode = 403;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'error': 'Authentication required',
        'code': 'AUTH_REQUIRED',
      }));
      return;
    }

    try {
      // Read the file content from request body
      var bytes = await request.fold<List<int>>(
        <int>[],
        (previous, element) => previous..addAll(element),
      );

      if (bytes.isEmpty) {
        request.response.statusCode = 400;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'Empty file'}));
        return;
      }

      // Enforce 10 MB file size limit
      final maxSize = 10 * 1024 * 1024;
      if (bytes.length > maxSize) {
        request.response.statusCode = 413;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
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
      final storedFilename = '${sha1Hash}_$originalFilename';

      // Create files directory for the room under the target callsign
      final filesDir = Directory('${_getChatDataPath(targetCallsign)}/$roomId/files');
      if (!await filesDir.exists()) {
        await filesDir.create(recursive: true);
      }

      // Save the file
      final filePath = '${filesDir.path}/$storedFilename';
      final file = File(filePath);
      await file.writeAsBytes(bytes, flush: true);

      _log('INFO', 'Chat file uploaded: $storedFilename (${bytes.length} bytes) to room $roomId');

      request.response.statusCode = 201;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'success': true,
        'filename': storedFilename,
        'size': bytes.length,
        'sha1': sha1Hash,
      }));
    } catch (e) {
      _log('ERROR', 'Error uploading chat file: $e');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': e.toString()}));
    }
  }

  /// Handle GET /api/chat/{roomId}/files/{filename} - download chat file
  /// Accepts both formats: /api/chat/{roomId}/files/{filename} and /api/chat/rooms/{roomId}/files/{filename}
  /// Also supports callsign prefix: /{callsign}/api/chat/{roomId}/files/{filename}
  Future<void> _handleChatFileDownload(HttpRequest request, String targetCallsign) async {
    final path = request.uri.path;
    final roomId = ChatApi.extractRoomId(path);
    final filename = ChatApi.extractFilename(path);

    if (roomId == null || filename == null) {
      request.response.statusCode = 400;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Invalid path'}));
      return;
    }

    // Validate filename to prevent path traversal
    if (filename.contains('..') || filename.contains('/') || filename.contains('\\')) {
      request.response.statusCode = 400;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Invalid filename'}));
      return;
    }

    // If targeting a remote device, proxy the request
    if (targetCallsign.toUpperCase() != _settings.callsign.toUpperCase()) {
      await _proxyRequestToDevice(request, targetCallsign, ChatApi.fileDownloadPath(roomId, filename));
      return;
    }

    final room = _chatRooms[roomId];
    if (room == null) {
      request.response.statusCode = 404;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Room not found'}));
      return;
    }

    // Look for file under the target callsign's directory
    final file = File('${_getChatDataPath(targetCallsign)}/$roomId/files/$filename');
    if (!await file.exists()) {
      request.response.statusCode = 404;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'File not found'}));
      return;
    }

    // Determine content type based on filename
    String contentType = 'application/octet-stream';
    final lower = filename.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      contentType = 'image/jpeg';
    } else if (lower.endsWith('.png')) {
      contentType = 'image/png';
    } else if (lower.endsWith('.gif')) {
      contentType = 'image/gif';
    } else if (lower.endsWith('.webp')) {
      contentType = 'image/webp';
    } else if (lower.endsWith('.pdf')) {
      contentType = 'application/pdf';
    } else if (lower.endsWith('.m4a')) {
      contentType = 'audio/m4a';
    } else if (lower.endsWith('.mp3')) {
      contentType = 'audio/mpeg';
    } else if (lower.endsWith('.wav')) {
      contentType = 'audio/wav';
    }

    try {
      final bytes = await file.readAsBytes();
      request.response.headers.contentType = ContentType.parse(contentType);
      request.response.headers.contentLength = bytes.length;
      request.response.add(bytes);
    } catch (e) {
      _log('ERROR', 'Error serving chat file: $e');
      request.response.statusCode = 500;
      request.response.write('Error reading file');
    }
  }

  /// Handle GET /api/chat/{roomId}/file/{year}/{filename} - get raw chat file
  /// Accepts both formats: /api/chat/{roomId}/file/... and /api/chat/rooms/{roomId}/file/...
  /// Also supports callsign prefix: /{callsign}/api/chat/{roomId}/file/...
  Future<void> _handleChatFileContent(HttpRequest request, String targetCallsign) async {
    final path = request.uri.path;
    // Accept all formats including callsign prefix
    // Strip callsign prefix if present for extraction
    final apiPath = _getApiPathWithoutCallsign(path);
    final match = RegExp(r'^/api/chat/(rooms/)?([^/]+)/file/(\d{4})/([^/]+)$').firstMatch(apiPath);

    if (match == null) {
      request.response.statusCode = 400;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Invalid path'}));
      return;
    }

    final roomId = match.group(2)!;
    final year = match.group(3)!;
    final filename = match.group(4)!;

    // Validate filename format to prevent path traversal
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}_chat\.txt$').hasMatch(filename)) {
      request.response.statusCode = 400;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Invalid filename format'}));
      return;
    }

    // If targeting a remote device, proxy the request
    if (targetCallsign.toUpperCase() != _settings.callsign.toUpperCase()) {
      await _proxyRequestToDevice(request, targetCallsign, '/api/chat/$roomId/file/$year/$filename');
      return;
    }

    final room = _chatRooms[roomId];
    if (room == null) {
      request.response.statusCode = 404;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'Room not found'}));
      return;
    }

    // Look for file under the target callsign's directory
    final chatFile = File('${_getChatDataPath(targetCallsign)}/$roomId/$year/$filename');

    if (!await chatFile.exists()) {
      request.response.statusCode = 404;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'File not found'}));
      return;
    }

    // Return raw file content
    final content = await chatFile.readAsString();
    request.response.headers.contentType = ContentType('text', 'plain', charset: 'utf-8');
    request.response.write(content);
  }

  Future<void> _handleCliCommand(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final command = data['command'] as String?;

    if (command == null || command.trim().isEmpty) {
      request.response.headers.contentType = ContentType.json;
      request.response.statusCode = 400;
      request.response.write(jsonEncode({'status': 'error', 'error': 'Missing command'}));
      return;
    }

    try {
      final result = await executeConsoleCommand(command);
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(result));
    } catch (e) {
      request.response.headers.contentType = ContentType.json;
      request.response.statusCode = 500;
      request.response.write(jsonEncode({'status': 'error', 'error': e.toString()}));
    }
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

    final layer = (request.uri.queryParameters['layer'] ?? 'standard').toLowerCase();

    if (z < 0 || z > 18) {
      request.response.statusCode = 400;
      request.response.write('Invalid zoom level');
      return;
    }

    final cacheKey = '$layer/$z/$x/$y';
    var tileData = _tileCache.get(cacheKey);

    if (tileData != null) {
      _stats.tilesServedFromCache++;
      request.response.headers.contentType = _getImageContentType(tileData);
      request.response.add(tileData);
      return;
    }

    final diskPath = '$_tilesDirectory/$layer/$z/$x/$y.png';
    final diskFile = File(diskPath);
    if (await diskFile.exists()) {
      tileData = await diskFile.readAsBytes();
      _tileCache.put(cacheKey, tileData);
      _stats.tilesServedFromCache++;
      request.response.headers.contentType = _getImageContentType(tileData);
      request.response.add(tileData);
      return;
    }

    // Tile not in cache - fetch from source if enabled
    if (_settings.osmFallbackEnabled) {
      tileData = await _fetchTileFromSource(z, x, y, layer);

      if (tileData != null) {
        _stats.tilesDownloaded++;
        // Cache in memory
        if (z <= _settings.maxZoomLevel) {
          _tileCache.put(cacheKey, tileData);
          _stats.tilesCached++;
        }
        // Cache to disk
        await _saveTileToDisk(diskPath, tileData);

        request.response.headers.contentType = _getImageContentType(tileData);
        request.response.add(tileData);
        return;
      }
    }

    request.response.statusCode = 404;
    request.response.write('Tile not found');
  }

  /// Fetch tile from upstream source
  /// Uses same URL patterns as MapTileService (lib/services/map_tile_service.dart)
  Future<Uint8List?> _fetchTileFromSource(int z, int x, int y, String layer) async {
    try {
      // URL templates match MapTileService constants
      // Note: Esri uses z/y/x order (y before x)
      String url;
      switch (layer) {
        case 'satellite':
          url = 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/$z/$y/$x';
          break;
        case 'labels':
          url = 'https://services.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/$z/$y/$x';
          break;
        case 'borders':
          url = 'https://services.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Light_Gray_Reference/MapServer/tile/$z/$y/$x';
          break;
        case 'transport':
          url = 'https://services.arcgisonline.com/ArcGIS/rest/services/Reference/World_Transportation/MapServer/tile/$z/$y/$x';
          break;
        default:
          url = 'https://tile.openstreetmap.org/$z/$x/$y.png';
      }

      final response = await http.get(
        Uri.parse(url),
        headers: {'User-Agent': 'Geogram-Station/$cliAppVersion'},
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        final data = Uint8List.fromList(response.bodyBytes);
        if (PureTileCache.isValidImageData(data)) {
          return data;
        }
      }
    } catch (e) {
      _log('ERROR', 'Failed to fetch tile $layer/$z/$x/$y: $e');
    }
    return null;
  }

  ContentType _getImageContentType(Uint8List data) {
    if (data.length >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF) {
      return ContentType('image', 'jpeg');
    }
    return ContentType('image', 'png');
  }

  // ============================================================
  // Bot Model Hosting (CLI Station)
  // ============================================================

  Future<void> _handleBotModelRequest(HttpRequest request) async {
    if (request.method != 'GET') {
      request.response.statusCode = 405;
      request.response.write('Method not allowed');
      return;
    }

    if (_dataDir == null) {
      request.response.statusCode = 500;
      request.response.write('Server not initialized');
      return;
    }

    final segments = request.uri.pathSegments;
    if (segments.length < 4 || segments[0] != 'bot' || segments[1] != 'models') {
      request.response.statusCode = 400;
      request.response.write('Invalid model path');
      return;
    }

    final modelType = segments[2]; // 'vision', 'music', 'whisper', or 'supertonic'
    if (modelType != 'vision' && modelType != 'music' && modelType != 'whisper' && modelType != 'supertonic') {
      request.response.statusCode = 400;
      request.response.write('Invalid model type');
      return;
    }

    final baseDir = path.join(_dataDir!, 'bot', 'models', modelType);
    String modelPath;
    String filename;
    String modelId;
    String? relativePath;

    if (segments.length == 4) {
      // Legacy single-file models: /bot/models/{type}/{filename}
      filename = segments[3];
      modelId = filename.split('.').first;
      relativePath = filename;
      modelPath = path.normalize(path.join(baseDir, filename));
      if (!path.isWithin(baseDir, modelPath)) {
        request.response.statusCode = 400;
        request.response.write('Invalid model path');
        return;
      }
    } else {
      // Multi-file models: /bot/models/{type}/{modelId}/{path...}
      modelId = segments[3];
      relativePath = segments.sublist(4).join('/');
      final modelDir = path.join(baseDir, modelId);
      modelPath = path.normalize(path.join(modelDir, relativePath));
      if (!path.isWithin(modelDir, modelPath)) {
        request.response.statusCode = 400;
        request.response.write('Invalid model path');
        return;
      }
      filename = path.basename(modelPath);
    }

    final file = File(modelPath);
    if (!await file.exists()) {
      final url = _resolveBotModelUrl(modelType, modelId, relativePath);
      if (url == null || url.isEmpty) {
        request.response.statusCode = 404;
        request.response.write('Model not found: $filename');
        return;
      }

      try {
        _log('INFO', 'Bot model cache miss: $modelType/$modelId/$filename');
        await _streamAndCacheModel(url, modelPath, filename, request.response);
        return;
      } catch (e) {
        _log('ERROR', 'Bot model download failed: $modelType/$modelId/$filename: $e');
        request.response.statusCode = 500;
        request.response.write('Error downloading model');
        return;
      }
    }

    try {
      final fileSize = await file.length();
      request.response.headers.contentType =
          ContentType('application', 'octet-stream');
      request.response.headers.contentLength = fileSize;
      request.response.headers.add(
          'Content-Disposition', 'attachment; filename="$filename"');
      await request.response.addStream(file.openRead());
      _log('INFO',
          'Served bot model $filename (${_formatBytes(fileSize)})');
    } catch (e) {
      _log('ERROR', 'Error serving bot model $filename: $e');
      request.response.statusCode = 500;
      request.response.write('Error serving model');
    }
  }

  String? _resolveBotModelUrl(
    String modelType,
    String modelId,
    String? relativePath,
  ) {
    if (modelType == 'vision') {
      final model = VisionModels.getById(modelId);
      return model?.url;
    }

    if (modelType == 'music') {
      final model = MusicModels.getById(modelId);
      if (model == null) return null;
      if (model.repoId != null && model.repoId!.isNotEmpty) {
        final resolvedPath = relativePath ?? '';
        if (resolvedPath.isEmpty) return null;
        return 'https://huggingface.co/${model.repoId}/resolve/main/$resolvedPath';
      }
      return model.url;
    }

    if (modelType == 'whisper') {
      // Look up whisper model by filename (modelId is the filename)
      final filename = modelId;
      final model = _whisperModels.where((m) => m['id'] == filename).firstOrNull;
      return model?['url'] as String?;
    }

    if (modelType == 'supertonic') {
      // Look up supertonic model by full path (modelId/relativePath format)
      // e.g., modelId='onnx', relativePath='text_encoder.onnx' -> 'onnx/text_encoder.onnx'
      final fullId = relativePath != null && relativePath.isNotEmpty
          ? '$modelId/$relativePath'
          : modelId;
      final model = _supertonicModels.where((m) => m['id'] == fullId).firstOrNull;
      return model?['url'] as String?;
    }

    return null;
  }

  Future<void> _streamAndCacheModel(
    String url,
    String targetPath,
    String filename,
    HttpResponse response,
  ) async {
    final tempPath = '$targetPath.tmp';
    final tempFile = File(tempPath);
    await tempFile.parent.create(recursive: true);

    final client = http.Client();
    try {
      final upstream = await client.send(http.Request('GET', Uri.parse(url)));
      if (upstream.statusCode < 200 || upstream.statusCode >= 300) {
        throw Exception('HTTP ${upstream.statusCode}');
      }

      response.headers.contentType =
          ContentType('application', 'octet-stream');
      if (upstream.contentLength != null && upstream.contentLength! > 0) {
        response.headers.contentLength = upstream.contentLength!;
      }
      response.headers.add(
          'Content-Disposition', 'attachment; filename="$filename"');

      final sink = tempFile.openWrite();
      var totalBytes = 0;
      await for (final chunk in upstream.stream) {
        response.add(chunk);
        sink.add(chunk);
        totalBytes += chunk.length;
      }

      await sink.close();
      await tempFile.rename(targetPath);
      _log('INFO',
          'Cached bot model $filename (${_formatBytes(totalBytes)})');
    } catch (e) {
      if (await tempFile.exists()) {
        try {
          await tempFile.delete();
        } catch (_) {}
      }
      rethrow;
    } finally {
      client.close();
    }
  }

  /// Handle Console VM file requests
  /// GET /console/vm/manifest.json - Returns VM files manifest
  /// GET /console/vm/{filename} - Returns individual VM file
  Future<void> _handleConsoleVmRequest(HttpRequest request) async {
    if (request.method != 'GET') {
      request.response.statusCode = 405;
      request.response.write('Method not allowed');
      return;
    }

    if (_dataDir == null) {
      request.response.statusCode = 500;
      request.response.write('Server not initialized');
      return;
    }

    final segments = request.uri.pathSegments;
    if (segments.length < 3 || segments[0] != 'console' || segments[1] != 'vm') {
      request.response.statusCode = 400;
      request.response.write('Invalid console VM path');
      return;
    }

    final filename = segments[2];
    final vmDir = path.join(_dataDir!, 'console', 'vm');
    final filePath = path.normalize(path.join(vmDir, filename));

    // Security: Ensure path is within vmDir
    if (!path.isWithin(vmDir, filePath)) {
      request.response.statusCode = 400;
      request.response.write('Invalid file path');
      return;
    }

    final file = File(filePath);

    if (!await file.exists()) {
      // If manifest.json doesn't exist, generate a placeholder
      if (filename == 'manifest.json') {
        final manifest = {
          'version': '1.0.0',
          'updated': DateTime.now().toIso8601String(),
          'files': <Map<String, dynamic>>[],
          'status': 'not_configured',
          'message': 'Console VM files not yet available on this station',
        };
        request.response.statusCode = 200;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(manifest));
        return;
      }

      request.response.statusCode = 404;
      request.response.write('VM file not found: $filename');
      return;
    }

    try {
      final fileSize = await file.length();

      // Set appropriate content type
      ContentType contentType;
      if (filename.endsWith('.json')) {
        contentType = ContentType.json;
      } else if (filename.endsWith('.js')) {
        contentType = ContentType('application', 'javascript');
      } else if (filename.endsWith('.wasm')) {
        contentType = ContentType('application', 'wasm');
      } else if (filename.endsWith('.tar.gz')) {
        contentType = ContentType('application', 'gzip');
      } else {
        contentType = ContentType('application', 'octet-stream');
      }

      request.response.headers.contentType = contentType;
      request.response.headers.contentLength = fileSize;
      request.response.headers.add('Content-Disposition', 'attachment; filename="$filename"');

      // Stream the file
      await request.response.addStream(file.openRead());
      _log('INFO', 'Served console VM file $filename (${_formatBytes(fileSize)})');
    } catch (e) {
      _log('ERROR', 'Error serving console VM file $filename: $e');
      request.response.statusCode = 500;
      request.response.write('Error serving file');
    }
  }

  /// Download all Console VM files at station startup (offline-first pattern)
  Future<void> downloadAllConsoleVmFiles() async {
    if (_dataDir == null) {
      _log('ERROR', 'Cannot download console VM files - not initialized');
      return;
    }

    final vmDir = path.join(_dataDir!, 'console', 'vm');
    await Directory(vmDir).create(recursive: true);

    // VM files to download from upstream
    final vmFiles = <Map<String, dynamic>>[
      {
        'name': 'jslinux.js',
        'url': 'https://bellard.org/jslinux/jslinux.js',
        'size': 20000,
      },
      {
        'name': 'term.js',
        'url': 'https://bellard.org/jslinux/term.js',
        'size': 45000,
      },
      {
        'name': 'kernel-x86.bin',
        'url': 'https://bellard.org/jslinux/kernel-x86.bin',
        'size': 5000000,
      },
      {
        'name': 'alpine-x86.cfg',
        'url': 'https://bellard.org/jslinux/alpine-x86.cfg',
        'size': 500,
      },
      {
        'name': 'alpine-x86-rootfs.tar.gz',
        'url': 'https://dl-cdn.alpinelinux.org/alpine/v3.12/releases/x86/alpine-minirootfs-3.12.0-x86.tar.gz',
        'size': 2800000,
      },
      {
        'name': 'alpine-x86-rootfs.cpio.gz',
        'url': 'https://bellard.org/jslinux/alpine-x86-rootfs.cpio.gz',
        'size': 3000000,
      },
      {
        // Android QEMU archive (arm64 host, x86 guest) for native console
        'name': 'qemu-android-aarch64.tar.gz',
        'url': 'https://p2p.radio/console/emu/qemu-android-aarch64.tar.gz',
        'size': 128, // placeholder minimum; actual size validated after download
      },
    ];

    _log('INFO', 'Checking console VM files for download...');

    var alreadyAvailable = 0;
    var downloadedCount = 0;
    var failedCount = 0;

    for (final fileInfo in vmFiles) {
      final filename = fileInfo['name'] as String;
      final url = fileInfo['url'] as String;
      final expectedSize = fileInfo['size'] as int;
      final filePath = path.join(vmDir, filename);
      final file = File(filePath);

      // Check if file exists and has reasonable size
      if (await file.exists()) {
        final actualSize = await file.length();
        if (actualSize > expectedSize * 0.8) {
          alreadyAvailable++;
          continue;
        }
        await file.delete();
      }

      // Download file
      _log('INFO', 'Downloading console VM file: $filename');
      try {
        final response = await http.get(Uri.parse(url)).timeout(const Duration(minutes: 5));
        if (response.statusCode == 200) {
          await file.writeAsBytes(response.bodyBytes);
          downloadedCount++;
          _log('INFO', 'Downloaded $filename successfully (${_formatBytes(response.bodyBytes.length)})');
        } else {
          throw Exception('HTTP ${response.statusCode}');
        }
      } catch (e) {
        failedCount++;
        _log('ERROR', 'Failed to download $filename: $e');
      }
    }

    // Generate manifest.json
    await _generateConsoleVmManifest(vmDir);

    if (alreadyAvailable > 0 || downloadedCount > 0 || failedCount > 0) {
      var summary = 'Console VM files - $alreadyAvailable available, $downloadedCount downloaded';
      if (failedCount > 0) {
        summary += ', $failedCount failed';
      }
      _log('INFO', summary);
    }
  }

  /// Generate manifest.json for console VM files
  Future<void> _generateConsoleVmManifest(String vmDir) async {
    final files = <Map<String, dynamic>>[];
    final vmFiles = [
      'jslinux.js',
      'term.js',
      'kernel-x86.bin',
      'alpine-x86.cfg',
      'alpine-x86-rootfs.tar.gz',
      'alpine-x86-rootfs.cpio.gz',
      'qemu-android-aarch64.tar.gz',
    ];

    for (final filename in vmFiles) {
      final file = File(path.join(vmDir, filename));
      if (await file.exists()) {
        final size = await file.length();
        files.add({
          'name': filename,
          'size': size,
          'sha256': '',
        });
      }
    }

    final manifest = {
      'version': '1.0.0',
      'updated': DateTime.now().toUtc().toIso8601String(),
      'files': files,
    };

    final manifestFile = File(path.join(vmDir, 'manifest.json'));
    await manifestFile.writeAsString(jsonEncode(manifest));
    _log('INFO', 'Generated console VM manifest with ${files.length} files');
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    } else if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    } else if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
    } else {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
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
        ? DateTime.now().difference(_startTime!).inMinutes
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

  /// Prepare logging sinks (async wrapper used during initialization)
  Future<void> _prepareLogSinks(DateTime now) async {
    _ensureLogSinks(now);
  }

  void _log(String level, String message) {
    final now = DateTime.now();
    _ensureLogSinks(now);

    final entry = LogEntry(now, level, message);
    _logs.add(entry);
    if (_logs.length > maxLogEntries) {
      _logs.removeAt(0);
    }
    if (!_quietMode) {
      stderr.writeln(entry.toString());
    }

    // Write to daily log file
    try {
      _logSink?.writeln(entry.toString());
      _logSink?.flush();
    } catch (_) {}

    // Write critical entries to crash log for easier forensics
    final lowerMessage = message.toLowerCase();
    final isCrashy = level == 'ERROR' ||
        lowerMessage.contains('exception') ||
        lowerMessage.contains('fatal') ||
        lowerMessage.contains('crash');
    if (isCrashy) {
      try {
        _crashSink?.writeln(entry.toString());
        _crashSink?.flush();
      } catch (_) {}
    }
  }

  /// Ensure daily log file and crash log sinks exist and rotate per day
  void _ensureLogSinks(DateTime now) {
    if (_dataDir == null) return;
    final logsRoot = Directory('$_dataDir/logs');
    if (!logsRoot.existsSync()) {
      logsRoot.createSync(recursive: true);
    }

    // Crash log (single file)
    _crashSink ??= File('${logsRoot.path}/crash.txt').openWrite(
      mode: FileMode.append,
    );

    // Daily log rotation per year/day
    final today = DateTime(now.year, now.month, now.day);
    if (_currentLogDay != null &&
        _currentLogDay!.year == today.year &&
        _currentLogDay!.month == today.month &&
        _currentLogDay!.day == today.day) {
      return; // already set for today
    }

    // Close previous sink
    try {
      _logSink?.flush();
      _logSink?.close();
    } catch (_) {}

    final yearDir = Directory('${logsRoot.path}/${now.year}');
    if (!yearDir.existsSync()) {
      yearDir.createSync(recursive: true);
    }
    final dateStr =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final logFile = File('${yearDir.path}/log-$dateStr.txt');
    _logSink = logFile.openWrite(mode: FileMode.append);
    _currentLogDay = today;
    _logSink!.writeln('=== Log start ${now.toIso8601String()} ===');
  }

  /// Ensure access log sink exists and rotates per day
  void _ensureAccessLogSink(DateTime now) {
    if (_dataDir == null) return;
    final logsRoot = Directory('$_dataDir/logs');
    if (!logsRoot.existsSync()) {
      logsRoot.createSync(recursive: true);
    }

    final today = DateTime(now.year, now.month, now.day);
    if (_currentAccessLogDay != null &&
        _currentAccessLogDay!.year == today.year &&
        _currentAccessLogDay!.month == today.month &&
        _currentAccessLogDay!.day == today.day) {
      return; // already set for today
    }

    // Close previous sink
    try {
      _accessLogSink?.flush();
      _accessLogSink?.close();
    } catch (_) {}

    final dateStr =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final accessLogFile = File('${logsRoot.path}/access-$dateStr.txt');
    _accessLogSink = accessLogFile.openWrite(mode: FileMode.append);
    _currentAccessLogDay = today;
  }

  /// Log HTTP access for forensics analysis
  void _logAccess(String ip, String method, String path, int status, int responseTimeMs, String? userAgent) {
    final now = DateTime.now();
    _ensureAccessLogSink(now);

    // Truncate user-agent to prevent log injection and keep logs manageable
    final ua = userAgent != null
        ? userAgent.substring(0, userAgent.length.clamp(0, 50)).replaceAll('"', "'")
        : '-';
    // Sanitize IP to prevent log injection
    final safeIp = ip.replaceAll(RegExp(r'[^\w.:]'), '');
    final safePath = path.replaceAll(RegExp(r'[\r\n]'), '');

    final entry = '${now.toIso8601String()} $safeIp $method $safePath $status ${responseTimeMs}ms "$ua"';
    try {
      _accessLogSink?.writeln(entry);
      _accessLogSink?.flush();
    } catch (_) {}
  }

  // Rate limiting and health watchdog methods are now provided by
  // RateLimitMixin and HealthWatchdogMixin - see mixin implementations above

  // ============================================
  // Signal Handlers (Crash Detection)
  // ============================================

  /// Setup signal handlers for graceful shutdown (Linux/macOS only)
  void _setupSignalHandlers() {
    // Only setup on Linux/macOS (not Windows)
    if (!Platform.isLinux && !Platform.isMacOS) {
      _log('INFO', 'Signal handlers not available on ${Platform.operatingSystem}');
      return;
    }

    // SIGTERM - graceful shutdown (e.g., systemctl stop)
    ProcessSignal.sigterm.watch().listen((_) {
      _logCrash('SIGTERM received - graceful shutdown requested');
      _gracefulShutdown();
    });

    // SIGINT - interrupt (Ctrl+C)
    ProcessSignal.sigint.watch().listen((_) {
      _logCrash('SIGINT received - interrupt signal');
      _gracefulShutdown();
    });

    // SIGHUP - reload configuration
    ProcessSignal.sighup.watch().listen((_) {
      _log('INFO', 'SIGHUP received - reloading security lists');
      loadSecurityLists();
    });

    _log('INFO', 'Signal handlers installed (SIGTERM, SIGINT, SIGHUP)');
  }

  /// Log a crash/shutdown event to crash.txt
  void _logCrash(String reason) {
    final entry = '[${DateTime.now().toIso8601String()}] [SHUTDOWN] $reason';
    try {
      _crashSink?.writeln(entry);
      _crashSink?.flush();
    } catch (_) {}
    _log('WARN', reason);
  }

  /// Perform graceful shutdown
  Future<void> _gracefulShutdown() async {
    _log('INFO', 'Initiating graceful shutdown...');

    // Stop accepting new connections
    _running = false;

    // Close heartbeat timer
    stopHeartbeat();

    // Close all client connections
    for (final client in _clients.values) {
      try {
        await client.socket.close();
      } catch (_) {}
    }
    _clients.clear();

    // Close HTTP servers
    try {
      await _httpServer?.close(force: true);
    } catch (_) {}
    try {
      await _httpsServer?.close(force: true);
    } catch (_) {}

    // Flush and close log sinks
    try {
      _logSink?.flush();
      _logSink?.close();
    } catch (_) {}
    try {
      _accessLogSink?.flush();
      _accessLogSink?.close();
    } catch (_) {}
    try {
      _crashSink?.flush();
      _crashSink?.close();
    } catch (_) {}

    _log('INFO', 'Shutdown complete');
    exit(0);
  }

  // ============================================
  // Update Mirror Methods
  // ============================================

  /// Load cached release info from file
  Future<void> _loadCachedRelease() async {
    if (_updatesDirectory == null) return;
    try {
      final releaseFile = File('$_updatesDirectory/release.json');
      if (await releaseFile.exists()) {
        final content = await releaseFile.readAsString();
        _cachedRelease = jsonDecode(content) as Map<String, dynamic>;

        // Restore _downloadedAssets from cached release
        final assets = _cachedRelease?['assets'];
        if (assets is Map<String, dynamic>) {
          _downloadedAssets = Map<String, String>.from(assets);
        }

        // Restore _assetFilenames from cached release
        final filenames = _cachedRelease?['assetFilenames'];
        if (filenames is Map<String, dynamic>) {
          _assetFilenames = Map<String, String>.from(filenames);
        }

        _log('INFO', 'Loaded cached release: ${_cachedRelease?['version']} with ${_downloadedAssets.length} assets');
      }
    } catch (e) {
      _log('ERROR', 'Error loading cached release: $e');
    }
  }

  /// Save cached release info to file
  Future<void> _saveCachedRelease() async {
    if (_updatesDirectory == null || _cachedRelease == null) return;
    try {
      final releaseFile = File('$_updatesDirectory/release.json');
      await releaseFile.writeAsString(jsonEncode(_cachedRelease));
      _log('INFO', 'Saved cached release: ${_cachedRelease?['version']}');
    } catch (e) {
      _log('ERROR', 'Error saving cached release: $e');
    }
  }

  /// Start polling for updates
  void _startUpdatePolling() {
    if (!_settings.updateMirrorEnabled) {
      _log('INFO', 'Update mirroring disabled');
      return;
    }

    _log('INFO', 'Starting update polling (interval: ${_settings.updateCheckIntervalSeconds}s)');

    // Poll immediately on start
    _pollAndDownloadUpdates();

    // Then poll periodically
    _updatePollTimer = Timer.periodic(
      Duration(seconds: _settings.updateCheckIntervalSeconds),
      (_) => _pollAndDownloadUpdates(),
    );
  }

  /// Poll GitHub and download new releases
  Future<void> _pollAndDownloadUpdates() async {
    if (_isDownloadingUpdates) return;

    try {
      _isDownloadingUpdates = true;
      _log('INFO', 'Checking for updates from: ${_settings.updateMirrorUrl}');

      final response = await http.get(
        Uri.parse(_settings.updateMirrorUrl),
        headers: {
          'Accept': 'application/vnd.github.v3+json',
          'User-Agent': 'Geogram-Station-Updater',
        },
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        _log('ERROR', 'GitHub API error: ${response.statusCode}');
        return;
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final tagName = json['tag_name'] as String? ?? '';
      final version = tagName.replaceFirst(RegExp(r'^v'), '');

      final isNewVersion = _settings.lastMirroredVersion != version;
      if (isNewVersion) {
        _log('INFO', 'New version available: $version (current: ${_settings.lastMirroredVersion})');
      } else {
        _log('INFO', 'Checking for missing binaries in version $version');
      }

      // Download all platform binaries (will skip existing files)
      // This ensures we eventually get all binaries even if GitHub Actions is still building
      final downloadedCount = await _downloadAllPlatformBinaries(json);

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
      await saveSettings();

      if (downloadedCount > 0) {
        _log('INFO', 'Update mirror complete: version $version ($downloadedCount new binaries)');
      } else if (isNewVersion) {
        _log('INFO', 'Update mirror complete: version $version (no binaries available yet)');
      }

      // Also sync whisper models
      await _downloadWhisperModels();

      // Also sync Supertonic TTS models
      await _downloadSupertonicModels();
    } catch (e) {
      _log('ERROR', 'Error polling for updates: $e');
    } finally {
      _isDownloadingUpdates = false;
    }
  }

  /// Download all assets from GitHub release
  /// Returns the number of newly downloaded binaries
  Future<int> _downloadAllPlatformBinaries(Map<String, dynamic> releaseJson) async {
    final assets = releaseJson['assets'] as List<dynamic>?;
    if (assets == null) return 0;

    final tagName = releaseJson['tag_name'] as String? ?? '';
    final version = tagName.replaceFirst(RegExp(r'^v'), '');
    _currentDownloadVersion = version;

    _downloadedAssets.clear();
    _assetFilenames.clear();

    int newlyDownloaded = 0;
    int alreadyExisted = 0;

    // Download all assets to version-specific folder
    for (final asset in assets) {
      final assetMap = asset as Map<String, dynamic>;
      final filename = assetMap['name'] as String? ?? '';
      final downloadUrl = assetMap['browser_download_url'] as String?;

      if (downloadUrl == null || filename.isEmpty) continue;

      final assetType = UpdateAssetType.fromFilename(filename);
      if (assetType != UpdateAssetType.unknown) {
        // Check if file already exists before downloading
        final versionDir = Directory('$_updatesDirectory/$version');
        final targetPath = '${versionDir.path}/$filename';
        final existingFile = File(targetPath);
        final existed = await existingFile.exists() && await existingFile.length() > 1000;

        final success = await _downloadBinary(version, filename, downloadUrl);
        if (success) {
          _downloadedAssets[assetType.name] = '/updates/$version/$filename';
          _assetFilenames[assetType.name] = filename;
          if (existed) {
            alreadyExisted++;
          } else {
            newlyDownloaded++;
          }
        }
      }
    }

    _log('INFO', 'Binary sync: $newlyDownloaded new, $alreadyExisted existing, ${_downloadedAssets.length} total');
    return newlyDownloaded;
  }

  /// Download a single binary file to version folder
  Future<bool> _downloadBinary(String version, String filename, String url) async {
    if (_updatesDirectory == null) return false;

    try {
      _log('INFO', 'Downloading $filename for v$version...');

      // Create version subdirectory: updates/{version}/
      final versionDir = Directory('$_updatesDirectory/$version');
      if (!await versionDir.exists()) {
        await versionDir.create(recursive: true);
      }

      final targetPath = '${versionDir.path}/$filename';

      // Check if file already exists
      final existingFile = File(targetPath);
      if (await existingFile.exists()) {
        final existingSize = await existingFile.length();
        if (existingSize > 1000) {
          _log('INFO', 'File already exists: $filename (${(existingSize / (1024 * 1024)).toStringAsFixed(1)}MB)');
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
        _log('INFO', 'Downloaded $filename: ${sizeMb}MB');
        return true;
      } else {
        _log('ERROR', 'Failed to download $filename: ${response.statusCode}');
        return false;
      }
    } catch (e) {
      _log('ERROR', 'Error downloading $filename: $e');
      return false;
    }
  }

  /// Build asset URLs pointing to this station
  Map<String, String> _buildAssetUrls() => _downloadedAssets;

  /// Build asset filenames map
  Map<String, String> _buildAssetFilenames() => _assetFilenames;

  // ============================================
  // Whisper Model Mirror Methods
  // ============================================

  /// Whisper model definitions for mirroring
  static const List<Map<String, dynamic>> _whisperModels = [
    {
      'id': 'ggml-tiny.bin',
      'name': 'Whisper Tiny',
      'size': 39 * 1024 * 1024,
      'url': 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin',
      'description': 'Fastest, lower accuracy',
    },
    {
      'id': 'ggml-base.bin',
      'name': 'Whisper Base',
      'size': 145 * 1024 * 1024,
      'url': 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin',
      'description': 'Good balance of speed and accuracy',
    },
    {
      'id': 'ggml-small.bin',
      'name': 'Whisper Small',
      'size': 465 * 1024 * 1024,
      'url': 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin',
      'description': 'Better accuracy, slower',
    },
    {
      'id': 'ggml-medium.bin',
      'name': 'Whisper Medium',
      'size': 1500 * 1024 * 1024,
      'url': 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin',
      'description': 'High accuracy',
    },
    {
      'id': 'ggml-large-v2.bin',
      'name': 'Whisper Large v2',
      'size': 3000 * 1024 * 1024,
      'url': 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v2.bin',
      'description': 'Best accuracy',
    },
  ];

  /// Download all whisper models from HuggingFace
  Future<void> _downloadWhisperModels() async {
    if (_dataDir == null) return;

    final whisperDir = Directory(path.join(_dataDir!, 'bot', 'models', 'whisper'));
    if (!await whisperDir.exists()) {
      await whisperDir.create(recursive: true);
    }

    _log('INFO', 'Checking whisper models for mirroring...');
    _availableWhisperModels.clear();

    int downloaded = 0;
    int existed = 0;

    for (final model in _whisperModels) {
      final filename = model['id'] as String;
      final url = model['url'] as String;
      final expectedSize = model['size'] as int;

      final filePath = path.join(whisperDir.path, filename);
      final file = File(filePath);

      // Check if file exists with reasonable size
      if (await file.exists()) {
        final fileSize = await file.length();
        if (fileSize > expectedSize * 0.9) {
          // File exists and is at least 90% of expected size
          _availableWhisperModels.add(filename);
          existed++;
          continue;
        }
      }

      // Download the model using streaming to avoid memory issues
      final client = http.Client();
      try {
        _log('INFO', 'Downloading whisper model: $filename...');
        final request = http.Request('GET', Uri.parse(url));
        request.headers['User-Agent'] = 'Geogram-Station-Updater';

        final streamedResponse = await client.send(request).timeout(const Duration(minutes: 60));

        if (streamedResponse.statusCode == 200) {
          final sink = file.openWrite();
          int bytesReceived = 0;

          await for (final chunk in streamedResponse.stream) {
            sink.add(chunk);
            bytesReceived += chunk.length;
          }

          await sink.flush();
          await sink.close();

          final sizeMb = (bytesReceived / (1024 * 1024)).toStringAsFixed(1);
          _log('INFO', 'Downloaded whisper model $filename: ${sizeMb}MB');
          _availableWhisperModels.add(filename);
          downloaded++;
        } else {
          _log('ERROR', 'Failed to download whisper model $filename: ${streamedResponse.statusCode}');
        }
      } catch (e) {
        _log('ERROR', 'Error downloading whisper model $filename: $e');
      } finally {
        client.close();
      }
    }

    _log('INFO', 'Whisper model sync: $downloaded new, $existed existing, ${_availableWhisperModels.length} total');
  }

  /// Scan for existing whisper models on disk
  Future<void> _scanWhisperModels() async {
    if (_dataDir == null) return;

    final whisperDir = Directory(path.join(_dataDir!, 'bot', 'models', 'whisper'));
    if (!await whisperDir.exists()) return;

    _availableWhisperModels.clear();

    for (final model in _whisperModels) {
      final filename = model['id'] as String;
      final expectedSize = model['size'] as int;
      final filePath = path.join(whisperDir.path, filename);
      final file = File(filePath);

      if (await file.exists()) {
        final fileSize = await file.length();
        if (fileSize > expectedSize * 0.9) {
          _availableWhisperModels.add(filename);
        }
      }
    }

    if (_availableWhisperModels.isNotEmpty) {
      _log('INFO', 'Found ${_availableWhisperModels.length} whisper models on disk');
    }
  }

  /// Get list of available whisper models for download page
  List<Map<String, dynamic>> getAvailableWhisperModels() {
    return _whisperModels
        .where((m) => _availableWhisperModels.contains(m['id']))
        .toList();
  }

  // ============================================
  // Supertonic TTS Model Mirror Methods
  // ============================================

  /// HuggingFace base URL for Supertonic models
  static const String _supertonicHuggingFaceUrl =
      'https://huggingface.co/Supertone/supertonic-2/resolve/main/onnx';

  /// HuggingFace base URL for Supertonic voice styles
  static const String _supertonicVoiceStylesUrl =
      'https://huggingface.co/Supertone/supertonic-2/resolve/main/voice_styles';

  /// Supertonic model files for mirroring (4 ONNX + 2 config + 10 voice styles)
  static const List<Map<String, dynamic>> _supertonicModels = [
    {
      'id': 'onnx/text_encoder.onnx',
      'name': 'Text Encoder',
      'size': 27 * 1024 * 1024, // ~27 MB
      'url': '$_supertonicHuggingFaceUrl/text_encoder.onnx',
      'description': 'Converts text to embeddings',
    },
    {
      'id': 'onnx/duration_predictor.onnx',
      'name': 'Duration Predictor',
      'size': 2 * 1024 * 1024, // ~1.5 MB
      'url': '$_supertonicHuggingFaceUrl/duration_predictor.onnx',
      'description': 'Predicts phoneme durations',
    },
    {
      'id': 'onnx/vector_estimator.onnx',
      'name': 'Vector Estimator',
      'size': 132 * 1024 * 1024, // ~132 MB
      'url': '$_supertonicHuggingFaceUrl/vector_estimator.onnx',
      'description': 'Generates acoustic features',
    },
    {
      'id': 'onnx/vocoder.onnx',
      'name': 'Vocoder',
      'size': 101 * 1024 * 1024, // ~101 MB
      'url': '$_supertonicHuggingFaceUrl/vocoder.onnx',
      'description': 'Converts features to audio waveform',
    },
    {
      'id': 'onnx/tts.json',
      'name': 'TTS Config',
      'size': 9 * 1024, // ~9 KB
      'url': '$_supertonicHuggingFaceUrl/tts.json',
      'description': 'TTS pipeline configuration',
    },
    {
      'id': 'onnx/unicode_indexer.json',
      'name': 'Unicode Indexer',
      'size': 262 * 1024, // ~262 KB
      'url': '$_supertonicHuggingFaceUrl/unicode_indexer.json',
      'description': 'Character to index mapping for tokenization',
    },
    // Voice styles (10 voices: M1-M5, F1-F5)
    {
      'id': 'voice_styles/M1.json',
      'name': 'Voice Male 1',
      'size': 420 * 1024, // ~420 KB
      'url': '$_supertonicVoiceStylesUrl/M1.json',
      'description': 'Male voice style 1',
    },
    {
      'id': 'voice_styles/M2.json',
      'name': 'Voice Male 2',
      'size': 420 * 1024,
      'url': '$_supertonicVoiceStylesUrl/M2.json',
      'description': 'Male voice style 2',
    },
    {
      'id': 'voice_styles/M3.json',
      'name': 'Voice Male 3',
      'size': 420 * 1024,
      'url': '$_supertonicVoiceStylesUrl/M3.json',
      'description': 'Male voice style 3',
    },
    {
      'id': 'voice_styles/M4.json',
      'name': 'Voice Male 4',
      'size': 420 * 1024,
      'url': '$_supertonicVoiceStylesUrl/M4.json',
      'description': 'Male voice style 4',
    },
    {
      'id': 'voice_styles/M5.json',
      'name': 'Voice Male 5',
      'size': 420 * 1024,
      'url': '$_supertonicVoiceStylesUrl/M5.json',
      'description': 'Male voice style 5',
    },
    {
      'id': 'voice_styles/F1.json',
      'name': 'Voice Female 1',
      'size': 420 * 1024,
      'url': '$_supertonicVoiceStylesUrl/F1.json',
      'description': 'Female voice style 1',
    },
    {
      'id': 'voice_styles/F2.json',
      'name': 'Voice Female 2',
      'size': 420 * 1024,
      'url': '$_supertonicVoiceStylesUrl/F2.json',
      'description': 'Female voice style 2',
    },
    {
      'id': 'voice_styles/F3.json',
      'name': 'Voice Female 3',
      'size': 420 * 1024,
      'url': '$_supertonicVoiceStylesUrl/F3.json',
      'description': 'Female voice style 3',
    },
    {
      'id': 'voice_styles/F4.json',
      'name': 'Voice Female 4',
      'size': 420 * 1024,
      'url': '$_supertonicVoiceStylesUrl/F4.json',
      'description': 'Female voice style 4',
    },
    {
      'id': 'voice_styles/F5.json',
      'name': 'Voice Female 5',
      'size': 420 * 1024,
      'url': '$_supertonicVoiceStylesUrl/F5.json',
      'description': 'Female voice style 5',
    },
  ];

  /// Download all Supertonic TTS models from HuggingFace
  Future<void> _downloadSupertonicModels() async {
    if (_dataDir == null) return;

    final supertonicDir = Directory(path.join(_dataDir!, 'bot', 'models', 'supertonic'));
    if (!await supertonicDir.exists()) {
      await supertonicDir.create(recursive: true);
    }

    _log('INFO', 'Checking Supertonic TTS models for mirroring...');
    _availableSupertonicModels.clear();

    int downloaded = 0;
    int existed = 0;

    for (final model in _supertonicModels) {
      final filename = model['id'] as String;
      final url = model['url'] as String;
      final expectedSize = model['size'] as int;

      final filePath = path.join(supertonicDir.path, filename);
      final file = File(filePath);

      // Check if file exists with reasonable size
      if (await file.exists()) {
        final fileSize = await file.length();
        if (fileSize > expectedSize * 0.9) {
          // File exists and is at least 90% of expected size
          _availableSupertonicModels.add(filename);
          existed++;
          continue;
        }
      }

      // Download the model using streaming to avoid memory issues
      // Ensure parent directory exists (for subdirs like onnx/ and voice_styles/)
      final parentDir = file.parent;
      if (!await parentDir.exists()) {
        await parentDir.create(recursive: true);
      }

      final client = http.Client();
      try {
        _log('INFO', 'Downloading Supertonic model: $filename...');
        final request = http.Request('GET', Uri.parse(url));
        request.headers['User-Agent'] = 'Geogram-Station-Updater';

        final streamedResponse = await client.send(request).timeout(const Duration(minutes: 60));

        if (streamedResponse.statusCode == 200) {
          final sink = file.openWrite();
          int bytesReceived = 0;

          await for (final chunk in streamedResponse.stream) {
            sink.add(chunk);
            bytesReceived += chunk.length;
          }

          await sink.flush();
          await sink.close();

          final sizeMb = (bytesReceived / (1024 * 1024)).toStringAsFixed(1);
          _log('INFO', 'Downloaded Supertonic model $filename: ${sizeMb}MB');
          _availableSupertonicModels.add(filename);
          downloaded++;
        } else {
          _log('ERROR', 'Failed to download Supertonic model $filename: ${streamedResponse.statusCode}');
        }
      } catch (e) {
        _log('ERROR', 'Error downloading Supertonic model $filename: $e');
      } finally {
        client.close();
      }
    }

    _log('INFO', 'Supertonic model sync: $downloaded new, $existed existing, ${_availableSupertonicModels.length} total');
  }

  /// Scan for existing Supertonic models on disk
  Future<void> _scanSupertonicModels() async {
    if (_dataDir == null) return;

    final supertonicDir = Directory(path.join(_dataDir!, 'bot', 'models', 'supertonic'));
    if (!await supertonicDir.exists()) return;

    _availableSupertonicModels.clear();

    for (final model in _supertonicModels) {
      final filename = model['id'] as String;
      final expectedSize = model['size'] as int;
      final filePath = path.join(supertonicDir.path, filename);
      final file = File(filePath);

      if (await file.exists()) {
        final fileSize = await file.length();
        if (fileSize > expectedSize * 0.9) {
          _availableSupertonicModels.add(filename);
        }
      }
    }

    if (_availableSupertonicModels.isNotEmpty) {
      _log('INFO', 'Found ${_availableSupertonicModels.length} Supertonic models on disk');
    }
  }

  /// Get list of available Supertonic models for download page
  List<Map<String, dynamic>> getAvailableSupertonicModels() {
    return _supertonicModels
        .where((m) => _availableSupertonicModels.contains(m['id']))
        .toList();
  }

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
      _log('WARN', 'Update file not found: $filePath');
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
      _log('INFO', 'Served update file: $filename (${(fileLength / (1024 * 1024)).toStringAsFixed(1)}MB)');
    } catch (e) {
      _log('ERROR', 'Error serving update file: $e');
      request.response.statusCode = 500;
      request.response.write('Error reading file');
    }
  }
}

/// SSL Certificate Manager for Let's Encrypt
class SslCertificateManager {
  PureRelaySettings _settings;
  final String _sslDir;

  /// Update settings reference (called when station settings change)
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

  /// Parse certificate expiry from PEM using openssl
  DateTime? _parseCertificateExpiry(String pemCert) {
    try {
      // Use -dateopt iso_8601 for unambiguous machine-readable output
      final result = Process.runSync('openssl', [
        'x509', '-noout', '-enddate', '-dateopt', 'iso_8601',
        '-in', certPath,
      ]);
      if (result.exitCode == 0) {
        // Output format: notAfter=2026-06-03T07:22:26Z
        final output = (result.stdout as String).trim();
        final match = RegExp(r'notAfter=(.+)').firstMatch(output);
        if (match != null) {
          return DateTime.parse(match.group(1)!.trim());
        }
      }
    } catch (_) {}
    return null;
  }

  /// Check and renew if needed (30 days before expiry)
  Future<bool> checkAndRenew() async {
    if (!hasCertificate()) return false;

    final info = await _getCertificateInfo();
    final daysUntilExpiry = info['daysUntilExpiry'] as int?;

    if (daysUntilExpiry == null) {
      stdout.writeln('[SSL] Could not determine certificate expiry — skipping auto-renewal check');
      return true;
    }

    stdout.writeln('[SSL] Certificate expires in $daysUntilExpiry days');

    if (daysUntilExpiry <= 30) {
      stdout.writeln('[SSL] Certificate expiring soon — starting auto-renewal...');
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

  // Reference to station server for challenge handling
  PureStationServer? _stationServer;

  /// Set station server reference for ACME challenge handling
  void setStationServer(PureStationServer server) {
    _stationServer = server;
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

      // Set challenge response on station server
      if (_stationServer != null) {
        _stationServer!.setAcmeChallenge(token, keyAuthz);
        stdout.writeln('  Challenge token set: $token');
      } else {
        throw Exception('Station server not available for challenge');
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
      _stationServer?.clearAcmeChallenge(token);
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

class _UploadPayload {
  final Uint8List bytes;
  final String? mime;

  _UploadPayload({required this.bytes, this.mime});
}

// Note: IpRateLimit class is now imported from lib/server/mixins/rate_limit_mixin.dart
// This enables code sharing between PureStationServer and CliStationServer
