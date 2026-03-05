// CLI Station Server implementation
// Extends StationServerBase with CLI-specific functionality (pure Dart)

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../services/email_relay_service.dart';
import '../services/nip05_registry_service.dart';
import 'station_server_base.dart';
import 'station_settings.dart';
import 'station_stats.dart';
import 'mixins/ssl_mixin.dart';
import 'mixins/smtp_mixin.dart';
import 'mixins/rate_limit_mixin.dart';
import 'mixins/health_watchdog_mixin.dart';
import 'mixins/atproto_pds_mixin.dart';
import 'mixins/karma_mixin.dart';

/// CLI station server implementation
/// Extends the unified base class with CLI-specific features (SMTP, logging to file)
class CliStationServer extends StationServerBase
    with SslMixin, SmtpMixin, RateLimitMixin, HealthWatchdogMixin, AtprotoPdsMixin, KarmaMixin {

  // CLI-specific state
  String? _configDir;
  IOSink? _logSink;
  IOSink? _crashSink;
  final List<LogEntry> _logHistory = [];
  static const int _maxLogHistory = 1000;

  // Heartbeat timer for connection stability
  Timer? _heartbeatTimer;
  static const int _heartbeatIntervalSeconds = 30;
  static const int _staleClientTimeoutSeconds = 120;

  CliStationServer();

  // ============ Abstract Method Implementations ============

  @override
  void log(String level, String message) {
    final entry = LogEntry(DateTime.now(), level, message);
    _logHistory.add(entry);
    if (_logHistory.length > _maxLogHistory) {
      _logHistory.removeAt(0);
    }

    // Write to log file
    _logSink?.writeln(entry.toString());

    // Also print to console
    print(entry.toString());
  }

  @override
  Future<Uint8List?> loadAsset(String assetPath) async {
    // CLI loads from file system
    final paths = [
      if (dataDir != null) '$dataDir/$assetPath',
      assetPath,
      '/opt/geogram/$assetPath',
    ];

    for (final path in paths) {
      try {
        final file = File(path);
        if (await file.exists()) {
          return await file.readAsBytes();
        }
      } catch (_) {}
    }
    return null;
  }

  @override
  String getCurrentUserCallsign() {
    return settings.callsign;
  }

  @override
  String getCurrentUserNpub() {
    return settings.npub;
  }

  @override
  Future<void> saveSettingsToStorage() async {
    if (_configDir == null) return;

    final configFile = File('$_configDir/config.json');
    await configFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(settings.toJson()),
    );
  }

  @override
  Future<bool> loadSettingsFromStorage() async {
    if (_configDir == null) return false;

    final configFile = File('$_configDir/config.json');
    if (!await configFile.exists()) return false;

    try {
      final content = await configFile.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      final newSettings = StationSettings.fromJson(json);
      await updateSettings(newSettings);
      return true;
    } catch (e) {
      log('ERROR', 'Failed to load settings: $e');
      return false;
    }
  }

  @override
  String getChatDataPath([String? callsign]) {
    final targetCallsign = callsign ?? settings.callsign;
    return '$dataDir/devices/$targetCallsign/chat';
  }

  @override
  Future<void> onServerStart() async {
    // Setup signal handlers
    _setupSignalHandlers();

    // Start heartbeat timer
    _startHeartbeat();

    // Start health watchdog
    startHealthWatchdog();

    // Configure email relay
    configureEmailRelay();

    // Start SMTP server if enabled
    if (settings.smtpServerEnabled && settings.sslDomain != null) {
      await startSmtpServer(
        onMailReceived: _handleIncomingEmail,
        validateRecipient: _validateLocalRecipient,
      );
    }

    // Start HTTPS server if enabled
    if (settings.enableSsl) {
      await startHttpsServer();
    }

    // Start AT Proto PDS if enabled
    if (settings.atprotoEnabled) {
      await startAtprotoPds();
    }

    // Start karma service
    await startKarmaService();

    log('INFO', 'CLI station server started');
  }

  @override
  Future<void> onServerStop() async {
    // Stop heartbeat
    _stopHeartbeat();

    // Stop health watchdog
    stopHealthWatchdog();

    // Stop AT Proto PDS
    await stopAtprotoPds();

    // Stop karma service
    stopKarmaService();

    // Stop SMTP server
    await stopSmtpServer();

    // Stop HTTPS server
    await stopHttpsServer();

    // Close log files
    await _logSink?.flush();
    await _crashSink?.flush();

    log('INFO', 'CLI station server stopped');
  }

  @override
  Future<bool> handlePlatformRoute(HttpRequest request, String path, String method) async {
    // Handle CLI-specific routes here

    // ACME challenge for Let's Encrypt
    if (path.startsWith('/.well-known/acme-challenge/')) {
      await handleAcmeChallenge(request);
      return true;
    }

    // Logs endpoint
    if (path == '/api/logs') {
      await _handleLogs(request);
      return true;
    }

    // CLI command endpoint
    if (path == '/api/cli' && method == 'POST') {
      await _handleCliCommand(request);
      return true;
    }

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
    logCrash('AUTO-RECOVERY: Restarting server');
    await restartServer();
  }

  @override
  void logCrash(String reason) {
    final entry = '[${DateTime.now().toIso8601String()}] [CRASH] $reason';
    _crashSink?.writeln(entry);
    _crashSink?.flush();
    log('CRASH', reason);
  }

  // ============ SslMixin Implementation ============

  @override
  void Function(HttpRequest) get httpRequestHandler => _handleRequestWithRateLimit;

  void _handleRequestWithRateLimit(HttpRequest request) {
    final ip = request.connectionInfo?.remoteAddress.address ?? 'unknown';

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
  }

  // ============ CLI-Specific Methods ============

  /// Initialize the CLI station server
  Future<void> initialize({
    required String configDir,
  }) async {
    _configDir = configDir;

    // Migrate old data structure if needed
    await _migrateOldDataStructure(configDir);

    // Create directories (use configDir directly, no /data suffix)
    await Directory(configDir).create(recursive: true);

    // Setup logging
    await _setupLogging(configDir);

    await initializeBase(
      dataDir: configDir,
      tilesDirectory: '$configDir/tiles',
      updatesDirectory: '$configDir/updates',
    );

    // Load security lists for rate limiting
    await loadSecurityLists();

    log('INFO', 'CLI station server initialized');
    log('INFO', 'Data directory: $configDir');
  }

  /// Migrate old data structure from {configDir}/data to {configDir}
  Future<void> _migrateOldDataStructure(String configDir) async {
    final oldDataDir = Directory('$configDir/data');
    if (!await oldDataDir.exists()) return;

    log('INFO', 'Migrating data from $configDir/data to $configDir');

    // Move subdirectories from data/ to configDir/
    await for (final entity in oldDataDir.list()) {
      if (entity is Directory) {
        final name = entity.path.split(Platform.pathSeparator).last;
        final newPath = '$configDir/$name';
        if (!await Directory(newPath).exists()) {
          try {
            await entity.rename(newPath);
            log('INFO', 'Migrated: $name');
          } catch (e) {
            log('WARN', 'Failed to migrate $name: $e');
          }
        }
      } else if (entity is File) {
        final name = entity.path.split(Platform.pathSeparator).last;
        final newPath = '$configDir/$name';
        if (!await File(newPath).exists()) {
          try {
            await entity.rename(newPath);
            log('INFO', 'Migrated file: $name');
          } catch (e) {
            log('WARN', 'Failed to migrate file $name: $e');
          }
        }
      }
    }

    // Remove old data directory if empty
    try {
      if (await oldDataDir.list().isEmpty) {
        await oldDataDir.delete();
        log('INFO', 'Removed empty old data directory');
      }
    } catch (_) {
      // Ignore - directory might not be empty
    }
  }

  Future<void> _setupLogging(String configDir) async {
    final logsDir = Directory('$configDir/logs');
    await logsDir.create(recursive: true);

    final today = DateTime.now().toIso8601String().split('T')[0];
    final logFile = File('${logsDir.path}/$today.log');
    _logSink = logFile.openWrite(mode: FileMode.append);

    final crashFile = File('${logsDir.path}/crash.txt');
    _crashSink = crashFile.openWrite(mode: FileMode.append);
  }

  void _setupSignalHandlers() {
    if (!Platform.isLinux && !Platform.isMacOS) {
      log('INFO', 'Signal handlers not available on ${Platform.operatingSystem}');
      return;
    }

    // SIGTERM - graceful shutdown
    ProcessSignal.sigterm.watch().listen((_) {
      logCrash('SIGTERM received - graceful shutdown requested');
      _gracefulShutdown();
    });

    // SIGINT - interrupt (Ctrl+C)
    ProcessSignal.sigint.watch().listen((_) {
      logCrash('SIGINT received - interrupt signal');
      _gracefulShutdown();
    });

    // SIGHUP - reload configuration
    ProcessSignal.sighup.watch().listen((_) {
      log('INFO', 'SIGHUP received - reloading security lists');
      loadSecurityLists();
    });

    log('INFO', 'Signal handlers installed (SIGTERM, SIGINT, SIGHUP)');
  }

  Future<void> _gracefulShutdown() async {
    log('INFO', 'Initiating graceful shutdown...');
    await stopServer();
    exit(0);
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(
      Duration(seconds: _heartbeatIntervalSeconds),
      (_) => _performHeartbeat(),
    );
    log('INFO', 'Heartbeat started (interval: ${_heartbeatIntervalSeconds}s)');
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  void _performHeartbeat() {
    final now = DateTime.now();
    final staleThreshold = now.subtract(Duration(seconds: _staleClientTimeoutSeconds));
    final clientsToRemove = <String>[];

    for (final entry in clients.entries) {
      final client = entry.value;
      if (client.lastActivity.isBefore(staleThreshold)) {
        log('WARN', 'Stale client: ${client.callsign ?? entry.key}');
        clientsToRemove.add(entry.key);
        continue;
      }

      // Send PING
      safeSocketSend(client, jsonEncode({
        'type': 'PING',
        'timestamp': now.millisecondsSinceEpoch,
      }));
    }

    // Remove stale clients
    for (final clientId in clientsToRemove) {
      kickDevice(clients[clientId]?.callsign ?? clientId);
    }

    // Cleanup expired bans
    cleanupExpiredBans();
  }

  // ============ SMTP Handlers ============

  Future<bool> _handleIncomingEmail(String from, List<String> to, String data) async {
    log('INFO', 'Received external email from $from to ${to.join(", ")}');
    return EmailRelayService().handleIncomingEmail(
      from: from,
      to: to,
      rawMessage: data,
      sendToClient: (clientId, msg) {
        final target = clients[clientId];
        return target != null ? safeSocketSend(target, msg) : false;
      },
      findClientByCallsign: (callsign) {
        for (final entry in clients.entries) {
          if (entry.value.callsign?.toUpperCase() == callsign.toUpperCase()) {
            return entry.key;
          }
        }
        return null;
      },
      getStationDomain: () => settings.sslDomain ?? settings.callsign.toLowerCase(),
    );
  }

  bool _validateLocalRecipient(String email) {
    // Check if recipient is registered in NIP-05 registry
    if (email.isEmpty) return false;
    final atIndex = email.indexOf('@');
    if (atIndex <= 0) return false;
    final localPart = email.substring(0, atIndex).toUpperCase();
    final registration = Nip05RegistryService().getRegistration(localPart);
    return registration != null;
  }

  // ============ CLI Route Handlers ============

  Future<void> _handleLogs(HttpRequest request) async {
    final limit = int.tryParse(request.uri.queryParameters['limit'] ?? '100') ?? 100;
    final offset = int.tryParse(request.uri.queryParameters['offset'] ?? '0') ?? 0;

    final logs = _logHistory.skip(offset).take(limit).map((e) => e.toJson()).toList();

    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({
      'total': _logHistory.length,
      'offset': offset,
      'limit': limit,
      'logs': logs,
    }));
  }

  Future<void> _handleCliCommand(HttpRequest request) async {
    // Read command from body
    final chunks = <List<int>>[];
    await for (final chunk in request) {
      chunks.add(chunk);
    }
    final body = utf8.decode(chunks.expand((e) => e).toList());
    final json = jsonDecode(body) as Map<String, dynamic>;
    final command = json['command'] as String?;

    if (command == null) {
      request.response.statusCode = 400;
      request.response.write(jsonEncode({'error': 'Missing command'}));
      return;
    }

    // Execute command (limited set)
    String result;
    switch (command) {
      case 'status':
        result = 'Server running on port ${settings.httpPort}';
        break;
      case 'clients':
        result = 'Connected clients: ${clients.length}';
        break;
      case 'reload':
        await loadSettingsFromStorage();
        result = 'Settings reloaded';
        break;
      default:
        result = 'Unknown command: $command';
    }

    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'result': result}));
  }

  /// Get log history for console display
  List<LogEntry> getLogHistory({int limit = 100}) {
    if (_logHistory.length <= limit) return List.from(_logHistory);
    return _logHistory.sublist(_logHistory.length - limit);
  }
}
