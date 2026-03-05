// App Station Server implementation
// Extends StationServerBase with App-specific functionality (Flutter integration)

import 'dart:io';
import 'dart:typed_data';

import 'station_server_base.dart';
import 'station_settings.dart';
import 'mixins/ssl_mixin.dart';
import 'mixins/stun_mixin.dart';
import 'mixins/rate_limit_mixin.dart';
import 'mixins/health_watchdog_mixin.dart';
import 'mixins/atproto_pds_mixin.dart';
import 'mixins/karma_mixin.dart';
import '../services/log_service.dart';
import '../services/config_service.dart';
import '../services/storage_config.dart';
import '../services/profile_service.dart';

/// App station server implementation
/// Extends the unified base class with Flutter/App-specific features
class AppStationServer extends StationServerBase
    with SslMixin, StunMixin, RateLimitMixin, HealthWatchdogMixin, AtprotoPdsMixin, KarmaMixin {

  // Singleton
  static final AppStationServer _instance = AppStationServer._internal();
  factory AppStationServer() => _instance;
  AppStationServer._internal();

  // App-specific state
  String? _appDir;

  // ============ Abstract Method Implementations ============

  @override
  void log(String level, String message) {
    LogService().log('[$level] $message');
  }

  @override
  Future<Uint8List?> loadAsset(String assetPath) async {
    // Try loading from Flutter assets via rootBundle
    // This will be overridden by the actual Flutter implementation
    try {
      final file = File('$_appDir/$assetPath');
      if (await file.exists()) {
        return await file.readAsBytes();
      }
    } catch (_) {}
    return null;
  }

  @override
  String getCurrentUserCallsign() {
    return ProfileService().getProfile().callsign;
  }

  @override
  String getCurrentUserNpub() {
    return ProfileService().getProfile().npub;
  }

  @override
  Future<void> saveSettingsToStorage() async {
    ConfigService().set('stationServer', settings.toJson());
  }

  @override
  Future<bool> loadSettingsFromStorage() async {
    final config = ConfigService().getAll();
    if (config.containsKey('stationServer')) {
      final json = config['stationServer'] as Map<String, dynamic>;
      // Get profile for npub/nsec
      final profile = ProfileService().getProfile();
      // Merge profile keys into settings
      final merged = Map<String, dynamic>.from(json);
      merged['npub'] = profile.npub;
      merged['nsec'] = profile.nsec;
      updateSettingsFromJson(merged);
      return true;
    }
    return false;
  }

  @override
  String getChatDataPath([String? callsign]) {
    final baseDir = _appDir ?? StorageConfig().baseDir;
    final targetCallsign = callsign ?? settings.callsign;
    return '$baseDir/devices/$targetCallsign/chat';
  }

  @override
  Future<void> onServerStart() async {
    // Start STUN server if enabled
    if (settings.stunServerEnabled) {
      await startStunServer();
    }

    // Start HTTPS if enabled
    if (settings.enableSsl) {
      await startHttpsServer();
    }

    // Start health watchdog
    startHealthWatchdog();

    // Start AT Proto PDS if enabled
    if (settings.atprotoEnabled) {
      await startAtprotoPds();
    }

    // Start karma service
    await startKarmaService();

    log('INFO', 'App station server started');
  }

  @override
  Future<void> onServerStop() async {
    // Stop STUN server
    await stopStunServer();

    // Stop HTTPS server
    await stopHttpsServer();

    // Stop AT Proto PDS
    await stopAtprotoPds();

    // Stop health watchdog
    stopHealthWatchdog();

    // Stop karma service
    stopKarmaService();

    log('INFO', 'App station server stopped');
  }

  @override
  Future<bool> handlePlatformRoute(HttpRequest request, String path, String method) async {
    // AT Proto PDS routes
    if (isAtprotoRunning) {
      if (await handleAtprotoRequest(request, path, method)) return true;
    }

    return false;
  }

  // ============ HealthWatchdogMixin Implementation ============

  @override
  int get httpPort => settings.httpPort;

  @override
  bool get isServerRunning => isRunning;

  @override
  int get connectedClientsCount => clients.length;

  @override
  Future<void> autoRecover() async {
    log('INFO', 'Auto-recovery triggered');
    await restartServer();
  }

  @override
  void logCrash(String reason) {
    log('CRASH', reason);
  }

  // ============ SslMixin Implementation ============

  @override
  void Function(HttpRequest) get httpRequestHandler => _handleRequestWithRateLimit;

  void _handleRequestWithRateLimit(HttpRequest request) {
    final ip = request.connectionInfo?.remoteAddress.address ?? 'unknown';

    // Check rate limiting
    if (isIpBanned(ip)) {
      recordErrorForWatchdog();
      request.response.statusCode = 429;
      request.response.write('Too Many Requests');
      request.response.close();
      return;
    }

    if (!checkRateLimit(ip)) {
      recordErrorForWatchdog();
      banIp(ip);
      request.response.statusCode = 429;
      request.response.write('Rate limit exceeded');
      request.response.close();
      return;
    }

    recordRequestForWatchdog();
    // Delegate to base class handler (will be called via startServer)
  }

  // ============ App-Specific Methods ============

  /// Initialize the app station server
  Future<void> initialize() async {
    final storageConfig = StorageConfig();
    _appDir = storageConfig.baseDir;

    await initializeBase(
      dataDir: storageConfig.baseDir,
      tilesDirectory: storageConfig.tilesDir,
      updatesDirectory: '${storageConfig.baseDir}/updates',
    );

    // Load security lists for rate limiting
    await loadSecurityLists();

    log('INFO', 'App station server initialized');
  }

  /// Update settings from JSON (used by config UI)
  void updateSettingsFromJson(Map<String, dynamic> json) {
    final newSettings = StationSettings.fromJson(json);
    updateSettings(newSettings);
  }

  /// Get server status for UI display
  Map<String, dynamic> getServerStatus() {
    return {
      'running': isRunning,
      'port': settings.httpPort,
      'connected_devices': clients.length,
      'uptime': startTime != null
          ? DateTime.now().difference(startTime!).inSeconds
          : 0,
      'tile_server_enabled': settings.tileServerEnabled,
      'stun_server_enabled': settings.stunServerEnabled,
      'stun_server_running': isStunRunning,
      'ssl_enabled': settings.enableSsl,
      'ssl_running': isHttpsRunning,
      'atproto_enabled': settings.atprotoEnabled,
      'atproto_running': isAtprotoRunning,
      'atproto_did': atprotoDid,
    };
  }
}
