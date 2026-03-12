// Health watchdog mixin for station server auto-recovery
import 'dart:async';
import 'dart:io';

/// Mixin providing server health monitoring and auto-recovery
mixin HealthWatchdogMixin {
  // Health check state
  Timer? _healthWatchdogTimer;
  HttpClient? _healthCheckClient;
  int _consecutiveFailures = 0;
  int _requestsThisMinute = 0;
  int _errorsThisMinute = 0;
  DateTime _lastMinuteReset = DateTime.now();

  // Configuration constants
  static const int healthCheckIntervalSeconds = 60;
  static const int healthCheckTimeoutSeconds = 10;
  static const int maxConsecutiveFailures = 3;
  static const int attackRequestThreshold = 10000;
  static const int attackErrorThreshold = 1000;
  static const int maxConnectionsThreshold = 500;

  // Abstract methods to be implemented by the using class
  void log(String level, String message);
  int get httpPort;
  bool get isServerRunning;
  int get connectedClientsCount;
  Future<void> autoRecover();
  void logCrash(String reason);

  /// Start the health watchdog timer
  void startHealthWatchdog() {
    _healthWatchdogTimer?.cancel();
    _healthWatchdogTimer = Timer.periodic(
      Duration(seconds: healthCheckIntervalSeconds),
      (_) => _runHealthWatchdog(),
    );
    log('INFO', 'Health watchdog started (interval: ${healthCheckIntervalSeconds}s)');
  }

  /// Stop the health watchdog timer
  void stopHealthWatchdog() {
    _healthWatchdogTimer?.cancel();
    _healthWatchdogTimer = null;
    _healthCheckClient?.close(force: true);
    _healthCheckClient = null;
  }

  /// Record a request for attack detection metrics
  void recordRequestForWatchdog() {
    _requestsThisMinute++;
  }

  /// Record an error for attack detection metrics
  void recordErrorForWatchdog() {
    _errorsThisMinute++;
  }

  /// Main watchdog check: verify server health and detect attacks
  Future<void> _runHealthWatchdog() async {
    if (!isServerRunning) return;

    // Log open file descriptor count for leak diagnostics
    try {
      final fdDir = Directory('/proc/self/fd');
      if (fdDir.existsSync()) {
        final count = fdDir.listSync().length;
        log('INFO', 'Watchdog: open FDs = $count');
      }
    } catch (_) {}

    // Reset counters every minute
    final now = DateTime.now();
    if (now.difference(_lastMinuteReset).inSeconds >= 60) {
      _requestsThisMinute = 0;
      _errorsThisMinute = 0;
      _lastMinuteReset = now;
    }

    // Check 1: Self-health check (is server responsive?)
    final healthy = await _performHealthCheck();
    if (!healthy) {
      _consecutiveFailures++;
      log('WARN', 'Health check failed ($_consecutiveFailures/$maxConsecutiveFailures)');

      if (_consecutiveFailures >= maxConsecutiveFailures) {
        log('ERROR', 'Server unresponsive - initiating auto-recovery');
        logCrash('AUTO-RECOVERY: Server unresponsive after $_consecutiveFailures failed health checks');
        _consecutiveFailures = 0;
        await autoRecover();
        return;
      }
    } else {
      _consecutiveFailures = 0;
    }

    // Check 2: Attack detection (DDoS indicators)
    final underAttack = _detectAttack();
    if (underAttack) {
      log('ERROR', 'Attack detected - initiating defensive restart');
      logCrash('AUTO-RECOVERY: Attack detected (requests: $_requestsThisMinute, errors: $_errorsThisMinute, connections: $connectedClientsCount)');
      await autoRecover();
    }
  }

  /// Perform self-health check by making request to own /api/status endpoint
  Future<bool> _performHealthCheck() async {
    _healthCheckClient ??= HttpClient()
      ..connectionTimeout = Duration(seconds: healthCheckTimeoutSeconds);
    try {
      final request = await _healthCheckClient!.getUrl(
        Uri.parse('http://127.0.0.1:$httpPort/api/status'),
      );
      final response = await request.close()
          .timeout(Duration(seconds: healthCheckTimeoutSeconds));

      return response.statusCode == 200;
    } catch (e) {
      log('WARN', 'Health check failed: $e');
      return false;
    }
  }

  /// Detect potential DDoS or abuse patterns
  bool _detectAttack() {
    // High request rate
    if (_requestsThisMinute > attackRequestThreshold) {
      log('WARN', 'High request rate detected: $_requestsThisMinute/min');
      return true;
    }

    // High error rate (lots of rate-limited or failed requests)
    if (_errorsThisMinute > attackErrorThreshold) {
      log('WARN', 'High error rate detected: $_errorsThisMinute/min');
      return true;
    }

    // Connection exhaustion
    if (connectedClientsCount > maxConnectionsThreshold) {
      log('WARN', 'Connection limit exceeded: $connectedClientsCount');
      return true;
    }

    return false;
  }

  /// Get current watchdog metrics
  Map<String, dynamic> getWatchdogMetrics() {
    return {
      'consecutive_failures': _consecutiveFailures,
      'requests_this_minute': _requestsThisMinute,
      'errors_this_minute': _errorsThisMinute,
      'last_minute_reset': _lastMinuteReset.toIso8601String(),
      'thresholds': {
        'max_failures': maxConsecutiveFailures,
        'attack_requests': attackRequestThreshold,
        'attack_errors': attackErrorThreshold,
        'max_connections': maxConnectionsThreshold,
      },
    };
  }

  /// Reset watchdog metrics (useful after manual recovery)
  void resetWatchdogMetrics() {
    _consecutiveFailures = 0;
    _requestsThisMinute = 0;
    _errorsThisMinute = 0;
    _lastMinuteReset = DateTime.now();
    log('INFO', 'Watchdog metrics reset');
  }
}
