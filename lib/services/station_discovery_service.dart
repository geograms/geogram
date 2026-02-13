import 'dart:async';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../models/station.dart';
import '../services/station_service.dart';
import '../services/log_service.dart';
import '../services/app_args.dart';
import '../services/devices_service.dart';

/// Result of a network scan for a geogram device
class NetworkScanResult {
  final String ip;
  final int port;
  final String type; // 'station', 'desktop', 'client', 'unknown'
  final String? callsign;
  final String? name;
  final String? version;
  final String? description;
  final String? location;
  final double? latitude;
  final double? longitude;
  final int? connectedDevices;

  NetworkScanResult({
    required this.ip,
    required this.port,
    required this.type,
    this.callsign,
    this.name,
    this.version,
    this.description,
    this.location,
    this.latitude,
    this.longitude,
    this.connectedDevices,
  });

  String get wsUrl => 'ws://$ip:$port';
  String get httpUrl => 'http://$ip:$port';

  /// Get display name (callsign, name, or fallback)
  String get displayName {
    if (callsign != null && callsign!.isNotEmpty) return callsign!;
    if (name != null && name!.isNotEmpty) return name!;
    return '$type at $ip';
  }

  @override
  String toString() =>
      'NetworkScanResult($ip:$port, type=$type, callsign=$callsign)';
}

/// Callback for scan progress updates
typedef ScanProgressCallback =
    void Function(
      String message,
      int scannedHosts,
      int totalHosts,
      List<NetworkScanResult> results,
    );

/// Callback to check if scan should be cancelled
typedef ScanCancelCheck = bool Function();

/// Service for automatic discovery of stations on local network
class StationDiscoveryService {
  static final StationDiscoveryService _instance =
      StationDiscoveryService._internal();
  factory StationDiscoveryService() => _instance;
  StationDiscoveryService._internal();

  Timer? _discoveryTimer;
  bool _isScanning = false;
  DateTime? _scanStartedAt;
  // Primary ports scanned first (most common station ports)
  final List<int> _primaryPorts = [3456, 8080];
  // Secondary ports scanned after primary phase
  final List<int> _secondaryPorts = [80, 8081, 3000, 5000];
  final Duration _scanInterval = const Duration(minutes: 5);
  final Duration _requestTimeout = const Duration(
    milliseconds: 400,
  ); // Fast timeout for LAN
  final Duration _startupDelay = const Duration(seconds: 5);
  final Duration _localhostScanDelay = const Duration(
    seconds: 10,
  ); // Longer delay when scanning localhost for other instances
  static const Duration _staleScanTimeout = Duration(minutes: 2);
  static const int _maxConcurrentConnections =
      50; // Increased for faster scanning

  /// Start automatic discovery
  void start() {
    // Network interface scanning not supported on web
    if (kIsWeb) {
      LogService().log('Station auto-discovery not supported on web platform');
      return;
    }

    // Use longer delay when --scan-localhost is enabled to allow other instances to start
    final localhostScanEnabled = AppArgs().scanLocalhostEnabled;
    final initialDelay = localhostScanEnabled
        ? _localhostScanDelay
        : _startupDelay;

    if (localhostScanEnabled) {
      final range = AppArgs().scanLocalhostRange;
      LogService().log(
        'StationDiscovery: Localhost port scanning enabled (range: $range)',
      );
      LogService().log(
        'StationDiscovery: Will scan localhost ports in ${initialDelay.inSeconds}s to allow other instances to start',
      );
    }

    LogService().log(
      'Starting station auto-discovery service (delayed ${initialDelay.inSeconds}s)',
    );

    // Delay initial scan to let the app initialize fully
    // This prevents "too many open files" errors on startup
    // Use longer delay when scanning localhost to allow other instances to start first
    Timer(initialDelay, () {
      LogService().log('StationDiscovery: Initial scan starting now');
      discover();

      // Schedule periodic scans every 5 minutes
      _discoveryTimer = Timer.periodic(_scanInterval, (_) {
        LogService().log('StationDiscovery: Periodic scan starting');
        discover();
      });
    });
  }

  /// Stop automatic discovery
  void stop() {
    LogService().log('Stopping station auto-discovery service');
    _discoveryTimer?.cancel();
    _discoveryTimer = null;
  }

  /// Reset scanning state (useful if a previous scan crashed)
  void resetScanState() {
    _isScanning = false;
    _scanStartedAt = null;
  }

  /// Manual scan with progress callback - returns list of found stations
  /// Uses phased scanning: primary ports (3456, 8080) first, then secondary ports
  Future<List<NetworkScanResult>> scanWithProgress({
    ScanProgressCallback? onProgress,
    ScanCancelCheck? shouldCancel,
    int timeoutMs = 400,
  }) async {
    if (kIsWeb) {
      onProgress?.call('Network scanning not supported on web', 0, 0, []);
      return [];
    }

    if (_isScanning) {
      final startedAt = _scanStartedAt;
      final isStale =
          startedAt != null &&
          DateTime.now().difference(startedAt) > _staleScanTimeout;
      if (isStale) {
        LogService().log('StationDiscovery: Resetting stale in-progress scan');
        _isScanning = false;
        _scanStartedAt = null;
      } else {
        LogService().log(
          'StationDiscovery: Scan already in progress, skipping request',
        );
        onProgress?.call('Scan already in progress', 0, 0, []);
        return [];
      }
    }

    _isScanning = true;
    _scanStartedAt = DateTime.now();
    final results = <NetworkScanResult>[];
    final seenKeys = <String, int>{}; // Maps key -> index in results

    // Helper to add result with real-time deduplication (stations only)
    void addResult(NetworkScanResult result) {
      // Only add stations, ignore clients/desktops
      if (result.type != 'station') return;

      String key;
      if (result.callsign != null && result.callsign!.isNotEmpty) {
        key = '${result.callsign}:${result.port}';
      } else if (result.description != null && result.description!.isNotEmpty) {
        key = '${result.description}:${result.port}';
      } else {
        key = '${result.ip}:${result.port}';
      }

      if (seenKeys.containsKey(key)) {
        // Replace if new result is better (non-localhost or more info)
        final existingIdx = seenKeys[key]!;
        final existing = results[existingIdx];
        if ((existing.ip == '127.0.0.1' && result.ip != '127.0.0.1') ||
            _hasMoreInfo(result, existing)) {
          results[existingIdx] = result;
        }
      } else {
        seenKeys[key] = results.length;
        results.add(result);
      }
    }

    try {
      // Get local network interfaces
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );

      // Collect network ranges to scan
      final ranges = <String>{};
      for (var interface in interfaces) {
        LogService().log('ScanWithProgress: Interface: ${interface.name}');
        for (var addr in interface.addresses) {
          LogService().log('ScanWithProgress:   Address: ${addr.address}');
          final subnet = _getSubnet(addr.address);
          if (subnet != null) {
            ranges.add(subnet);
          }
        }
      }

      // Fallback: if no interfaces detected (common on Android), try to detect subnet
      if (ranges.isEmpty) {
        LogService().log(
          'ScanWithProgress: No network interfaces detected, trying fallback detection',
        );
        onProgress?.call('Detecting network...', 0, 0, results);

        final fallbackSubnet = await _detectSubnetFromConnectivity();
        if (fallbackSubnet != null) {
          ranges.add(fallbackSubnet);
          LogService().log(
            'ScanWithProgress: Detected subnet from connectivity: $fallbackSubnet',
          );
        } else {
          // Add common home network ranges as last resort
          ranges.add('192.168.1');
          ranges.add('192.168.0');
          ranges.add('192.168.178'); // Common Fritz!Box range
          ranges.add('10.0.0');
          LogService().log(
            'ScanWithProgress: Using common fallback ranges: ${ranges.join(", ")}',
          );
        }
      }

      // Calculate total hosts for progress
      // Primary phase: localhost (2 hosts × 2 ports) + LAN (254 × 2 ports per range)
      // Secondary phase: LAN (254 × 4 ports per range)
      final primaryHosts = 4 + (ranges.length * 254 * _primaryPorts.length);
      final secondaryHosts = ranges.length * 254 * _secondaryPorts.length;
      final totalHosts = primaryHosts + secondaryHosts;
      int scannedHosts = 0;

      LogService().log(
        'StationDiscovery: === PHASE 1: PRIMARY PORTS (${_primaryPorts.join(", ")}) ===',
      );

      // PHASE 1: Localhost on primary ports first (fastest check)
      onProgress?.call(
        'Scanning localhost...',
        scannedHosts,
        totalHosts,
        results,
      );
      for (var host in ['localhost', '127.0.0.1']) {
        for (var port in _primaryPorts) {
          if (shouldCancel?.call() == true) break;
          final result = await _checkGeogramDevice(host, port, timeoutMs);
          if (result != null && result.type == 'station') {
            LogService().log(
              'StationDiscovery: Found station at $host:$port - ${result.callsign ?? result.displayName}',
            );
            addResult(result);
            onProgress?.call(
              'Found: ${result.displayName}',
              scannedHosts,
              totalHosts,
              results,
            );
          }
          scannedHosts++;
        }
      }

      // PHASE 2: LAN on primary ports (fast parallel scan)
      for (var range in ranges) {
        if (shouldCancel?.call() == true) break;
        onProgress?.call(
          'Scanning $range.x (ports ${_primaryPorts.join(", ")})...',
          scannedHosts,
          totalHosts,
          results,
        );

        // Build targets: all IPs on primary ports
        final targets = <MapEntry<String, int>>[];
        for (int i = 1; i < 255; i++) {
          for (var port in _primaryPorts) {
            targets.add(MapEntry('$range.$i', port));
          }
        }

        // Process in batches of 50 for faster scanning
        for (
          int batchStart = 0;
          batchStart < targets.length;
          batchStart += _maxConcurrentConnections
        ) {
          if (shouldCancel?.call() == true) break;

          final batchEnd = (batchStart + _maxConcurrentConnections).clamp(
            0,
            targets.length,
          );
          final batch = targets.sublist(batchStart, batchEnd);

          final futures = batch.map((target) async {
            final result = await _checkGeogramDevice(
              target.key,
              target.value,
              timeoutMs,
            );
            if (result != null && result.type == 'station') {
              LogService().log(
                'StationDiscovery: Found station at ${target.key}:${target.value}',
              );
              addResult(result);
              onProgress?.call(
                'Found: ${result.displayName}',
                scannedHosts,
                totalHosts,
                results,
              );
            }
          }).toList();

          await Future.wait(
            futures,
          ).timeout(Duration(milliseconds: timeoutMs * 2), onTimeout: () => []);

          scannedHosts += batch.length;
          final stationCount = results.length;
          onProgress?.call(
            'Scanning... ($stationCount station${stationCount == 1 ? "" : "s"} found)',
            scannedHosts,
            totalHosts,
            results,
          );
        }
      }

      LogService().log(
        'StationDiscovery: Primary phase complete: ${results.length} station(s) found',
      );

      // PHASE 3: Secondary ports (only if not cancelled)
      if (shouldCancel?.call() != true) {
        LogService().log(
          'StationDiscovery: === PHASE 2: SECONDARY PORTS (${_secondaryPorts.join(", ")}) ===',
        );

        for (var range in ranges) {
          if (shouldCancel?.call() == true) break;
          onProgress?.call(
            'Scanning $range.x (secondary ports)...',
            scannedHosts,
            totalHosts,
            results,
          );

          // Build targets: all IPs on secondary ports
          final targets = <MapEntry<String, int>>[];
          for (int i = 1; i < 255; i++) {
            for (var port in _secondaryPorts) {
              targets.add(MapEntry('$range.$i', port));
            }
          }

          // Process in batches
          for (
            int batchStart = 0;
            batchStart < targets.length;
            batchStart += _maxConcurrentConnections
          ) {
            if (shouldCancel?.call() == true) break;

            final batchEnd = (batchStart + _maxConcurrentConnections).clamp(
              0,
              targets.length,
            );
            final batch = targets.sublist(batchStart, batchEnd);

            final futures = batch.map((target) async {
              final result = await _checkGeogramDevice(
                target.key,
                target.value,
                timeoutMs,
              );
              if (result != null && result.type == 'station') {
                LogService().log(
                  'StationDiscovery: Found station at ${target.key}:${target.value}',
                );
                addResult(result);
                onProgress?.call(
                  'Found: ${result.displayName}',
                  scannedHosts,
                  totalHosts,
                  results,
                );
              }
            }).toList();

            await Future.wait(futures).timeout(
              Duration(milliseconds: timeoutMs * 2),
              onTimeout: () => [],
            );

            scannedHosts += batch.length;
            onProgress?.call(
              'Scanning secondary ports...',
              scannedHosts,
              totalHosts,
              results,
            );
          }
        }
      }

      // Final status
      final wasCancelled = shouldCancel?.call() == true;
      final stationCount = results.length;
      final message = wasCancelled
          ? 'Scan stopped: $stationCount station${stationCount == 1 ? "" : "s"} found'
          : 'Scan complete: $stationCount station${stationCount == 1 ? "" : "s"} found';
      onProgress?.call(message, totalHosts, totalHosts, results);

      LogService().log(
        'StationDiscovery: === SCAN COMPLETE: ${results.length} station(s) ===',
      );
      return results;
    } catch (e) {
      LogService().log('Error during scan: $e');
      onProgress?.call('Error: $e', 0, 0, results);
    } finally {
      _isScanning = false;
      _scanStartedAt = null;
    }

    return results;
  }

  /// Deduplicate scan results - merge localhost and local IP entries for same device
  List<NetworkScanResult> _deduplicateResults(List<NetworkScanResult> results) {
    if (results.isEmpty) return results;

    final Map<String, NetworkScanResult> uniqueDevices = {};

    for (var result in results) {
      // Create a unique key based on callsign+port, or type+port if no callsign
      String key;
      if (result.callsign != null && result.callsign!.isNotEmpty) {
        // Use callsign + port as key (same station on different IPs has same callsign)
        key = '${result.callsign}:${result.port}';
      } else if (result.description != null && result.description!.isNotEmpty) {
        // Fallback to description + port
        key = '${result.description}:${result.port}';
      } else {
        // No way to identify, keep all entries (use IP as key)
        key = '${result.ip}:${result.port}';
      }

      if (uniqueDevices.containsKey(key)) {
        // Prefer non-localhost entry (real IP is more useful)
        final existing = uniqueDevices[key]!;
        if (existing.ip == '127.0.0.1' && result.ip != '127.0.0.1') {
          uniqueDevices[key] = result;
        }
        // Keep the entry with more info
        else if (_hasMoreInfo(result, existing)) {
          uniqueDevices[key] = result;
        }
      } else {
        uniqueDevices[key] = result;
      }
    }

    return uniqueDevices.values.toList();
  }

  /// Check if result a has more info than result b
  bool _hasMoreInfo(NetworkScanResult a, NetworkScanResult b) {
    int scoreA = 0;
    int scoreB = 0;

    if (a.callsign != null && a.callsign!.isNotEmpty) scoreA++;
    if (b.callsign != null && b.callsign!.isNotEmpty) scoreB++;

    if (a.description != null && a.description!.isNotEmpty) scoreA++;
    if (b.description != null && b.description!.isNotEmpty) scoreB++;

    if (a.location != null && a.location!.isNotEmpty) scoreA++;
    if (b.location != null && b.location!.isNotEmpty) scoreB++;

    if (a.version != null && a.version!.isNotEmpty) scoreA++;
    if (b.version != null && b.version!.isNotEmpty) scoreB++;

    // Prefer non-localhost
    if (a.ip != '127.0.0.1') scoreA++;
    if (b.ip != '127.0.0.1') scoreB++;

    return scoreA > scoreB;
  }

  /// Check if a host:port is a geogram station (only returns stations, ignores clients/desktops)
  /// Stations have X3 callsigns, clients have X1 callsigns
  Future<NetworkScanResult?> _checkGeogramDevice(
    String ip,
    int port,
    int timeoutMs,
  ) async {
    final client = http.Client();
    try {
      final timeout = Duration(milliseconds: timeoutMs);

      try {
        // Try /api/status endpoint first (preferred)
        final statusUrl = Uri.parse('http://$ip:$port/api/status');
        final response = await client.get(statusUrl).timeout(timeout);

        if (response.statusCode == 200) {
          final body = response.body;
          final data = jsonDecode(body) as Map<String, dynamic>;
          final callsign =
              data['callsign'] as String? ?? data['stationCallsign'] as String?;

          // Only return if it's a station (X3 callsign or station service)
          final isStation =
              _isStationCallsign(callsign) ||
              body.contains('Geogram Station Server') ||
              data['service'] == 'Geogram Station Server';

          if (isStation) {
            return NetworkScanResult(
              ip: ip,
              port: port,
              type: 'station',
              callsign: callsign,
              name: data['name'] as String?,
              version: data['version'] as String?,
              description: data['description'] as String?,
              location: _buildLocation(data),
              latitude: _getDouble(data, 'location.latitude'),
              longitude: _getDouble(data, 'location.longitude'),
              connectedDevices: data['connected_devices'] as int?,
            );
          }
          // Ignore clients (X1 callsigns) - return null
        }
      } catch (_) {
        // Try next endpoint
      }

      try {
        // Try /station/status endpoint (legacy - only stations have this)
        final stationStatusUrl = Uri.parse('http://$ip:$port/station/status');
        final response = await client.get(stationStatusUrl).timeout(timeout);

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          final callsign = data['callsign'] as String?;

          // Verify it's a station callsign
          if (_isStationCallsign(callsign)) {
            return NetworkScanResult(
              ip: ip,
              port: port,
              type: 'station',
              callsign: callsign,
              name: data['name'] as String?,
              description: data['description'] as String?,
              connectedDevices: data['connected_devices'] as int?,
            );
          }
        }
      } catch (_) {
        // Try next endpoint
      }

      try {
        // Try root endpoint
        final rootUrl = Uri.parse('http://$ip:$port/');
        final response = await client.get(rootUrl).timeout(timeout);

        if (response.statusCode == 200) {
          final body = response.body;

          // Only check if it looks like a Geogram service
          if (body.contains('Geogram') || body.contains('geogram')) {
            try {
              final data = jsonDecode(body) as Map<String, dynamic>;
              final callsign = data['callsign'] as String?;

              // Only return if it's a station (X3 callsign)
              if (_isStationCallsign(callsign)) {
                return NetworkScanResult(
                  ip: ip,
                  port: port,
                  type: 'station',
                  callsign: callsign,
                  name: data['name'] as String?,
                  version: data['version'] as String?,
                  description: data['description'] as String?,
                  location: _buildLocation(data),
                  latitude: _getDouble(data, 'location.latitude'),
                  longitude: _getDouble(data, 'location.longitude'),
                  connectedDevices: data['connected_devices'] as int?,
                );
              }
            } catch (_) {
              // JSON parse failed
            }
          }
        }
      } catch (_) {
        // Not a geogram device
      }
    } catch (_) {
      // Connection failed
    } finally {
      client.close();
    }

    return null;
  }

  /// Check if a callsign indicates a station (X3 prefix)
  /// X1 = client, X3 = station
  bool _isStationCallsign(String? callsign) {
    if (callsign == null || callsign.isEmpty) return false;
    return callsign.toUpperCase().startsWith('X3');
  }

  /// Discover stations on local network
  Future<void> discover() async {
    // Network interface scanning not supported on web
    if (kIsWeb) return;

    if (_isScanning) {
      LogService().log('Discovery scan already in progress, skipping');
      return;
    }

    _isScanning = true;
    LogService().log('');
    LogService().log('══════════════════════════════════════');
    LogService().log('STATION AUTO-DISCOVERY');
    LogService().log('══════════════════════════════════════');

    try {
      // Get local network interfaces
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );

      // Get local IP ranges to scan
      final ranges = <String>{};
      for (var interface in interfaces) {
        LogService().log('  Interface: ${interface.name}');
        for (var addr in interface.addresses) {
          LogService().log('    Address: ${addr.address}');
          final subnet = _getSubnet(addr.address);
          if (subnet != null) {
            ranges.add(subnet);
          }
        }
      }

      // Fallback: if no interfaces detected (common on Android), try common private network ranges
      if (ranges.isEmpty) {
        LogService().log(
          '  No network interfaces detected, adding common private network ranges as fallback',
        );
        // Try to detect subnet from a test connection
        final fallbackSubnet = await _detectSubnetFromConnectivity();
        if (fallbackSubnet != null) {
          ranges.add(fallbackSubnet);
          LogService().log(
            '  Detected subnet from connectivity: $fallbackSubnet',
          );
        } else {
          // Add common home network ranges as last resort
          ranges.add('192.168.1');
          ranges.add('192.168.0');
          ranges.add('192.168.178'); // Common Fritz!Box range
          LogService().log(
            '  Using common fallback ranges: ${ranges.join(", ")}',
          );
        }
      }

      LogService().log(
        'Scanning localhost and ${ranges.length} network ranges: ${ranges.join(", ")}',
      );

      // Always scan localhost first on primary ports
      int foundCount = 0;
      LogService().log(
        '  Scanning localhost (127.0.0.1) on primary ports: ${_primaryPorts.join(", ")}...',
      );
      for (var port in _primaryPorts) {
        final station = await _checkRelay('127.0.0.1', port);
        if (station != null) {
          foundCount++;
          LogService().log('    Found station at localhost:$port');
        }
      }

      // Scan each network range
      for (var range in ranges) {
        LogService().log('  Range: $range.0/24');
        final found = await _scanRange(range);
        foundCount += found;
      }

      LogService().log('');
      LogService().log('Discovery complete: $foundCount station(s) found');
      LogService().log('══════════════════════════════════════');
    } catch (e) {
      LogService().log('Error during discovery: $e');
    } finally {
      _isScanning = false;
    }
  }

  /// Get subnet prefix from IP address (e.g., "192.168.1.100" -> "192.168.1")
  String? _getSubnet(String ipAddress) {
    final parts = ipAddress.split('.');
    if (parts.length != 4) return null;
    return '${parts[0]}.${parts[1]}.${parts[2]}';
  }

  /// Scan a network range for stations
  /// Uses batched connections to avoid exhausting file descriptors
  /// Scans primary ports first, then secondary ports
  Future<int> _scanRange(String subnet) async {
    int foundCount = 0;

    // Scan primary ports first (fast)
    final primaryTargets = <MapEntry<String, int>>[];
    for (int i = 1; i < 255; i++) {
      final ip = '$subnet.$i';
      for (var port in _primaryPorts) {
        primaryTargets.add(MapEntry(ip, port));
      }
    }

    // Process primary ports in batches
    for (
      int batchStart = 0;
      batchStart < primaryTargets.length;
      batchStart += _maxConcurrentConnections
    ) {
      final batchEnd = (batchStart + _maxConcurrentConnections).clamp(
        0,
        primaryTargets.length,
      );
      final batch = primaryTargets.sublist(batchStart, batchEnd);

      final futures = batch.map((target) async {
        final station = await _checkRelay(target.key, target.value);
        if (station != null) {
          foundCount++;
        }
      }).toList();

      await Future.wait(
        futures,
      ).timeout(const Duration(seconds: 5), onTimeout: () => []);
    }

    // Scan secondary ports
    final secondaryTargets = <MapEntry<String, int>>[];
    for (int i = 1; i < 255; i++) {
      final ip = '$subnet.$i';
      for (var port in _secondaryPorts) {
        secondaryTargets.add(MapEntry(ip, port));
      }
    }

    for (
      int batchStart = 0;
      batchStart < secondaryTargets.length;
      batchStart += _maxConcurrentConnections
    ) {
      final batchEnd = (batchStart + _maxConcurrentConnections).clamp(
        0,
        secondaryTargets.length,
      );
      final batch = secondaryTargets.sublist(batchStart, batchEnd);

      final futures = batch.map((target) async {
        final station = await _checkRelay(target.key, target.value);
        if (station != null) {
          foundCount++;
        }
      }).toList();

      await Future.wait(
        futures,
      ).timeout(const Duration(seconds: 5), onTimeout: () => []);
    }

    return foundCount;
  }

  /// Check if a station or desktop client exists at given IP and port
  Future<Station?> _checkRelay(String ip, int port) async {
    try {
      // Use /api/status endpoint for detection (returns JSON)
      final url = 'http://$ip:$port/api/status';
      final response = await http
          .get(Uri.parse(url), headers: {'Accept': 'application/json'})
          .timeout(_requestTimeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final service = data['service'] as String? ?? '';

        // Check if it's a Geogram station
        if (service == 'Geogram Station Server') {
          LogService().log('✓ Found station at $ip:$port');

          // Create station object with callsign
          final station = Station(
            url: 'ws://$ip:$port',
            name:
                data['callsign'] as String? ??
                data['name'] as String? ??
                data['description'] as String? ??
                'Local Station ($ip)',
            callsign: data['callsign'] as String?,
            status: 'available',
            location: _buildLocation(data),
            latitude: _getDouble(data, 'location.latitude'),
            longitude: _getDouble(data, 'location.longitude'),
            connectedDevices: data['connected_devices'] as int?,
          );

          // Add to station service
          await _addDiscoveredRelay(station);

          return station;
        }

        // Check if it's a Geogram Desktop client (for device-to-device DM)
        if (service == 'Geogram Desktop') {
          final callsign = data['callsign'] as String?;
          final name =
              data['nickname'] as String? ??
              data['name'] as String? ??
              callsign;
          final deviceUrl = 'http://$ip:$port';

          if (callsign != null && callsign.isNotEmpty) {
            LogService().log(
              '✓ Found desktop client at $ip:$port - callsign: $callsign',
            );

            // Add to devices service for DM functionality (sets isOnline: true)
            await DevicesService().addDevice(
              callsign,
              name: name,
              url: deviceUrl,
              isOnline: true,
            );

            // Return a dummy station to indicate success (so foundCount is incremented)
            return Station(
              url: deviceUrl,
              name: name ?? callsign,
              callsign: callsign,
              status: 'online',
            );
          }
        }
      }
    } catch (e) {
      // Silently ignore connection errors (most IPs won't respond)
    }

    return null;
  }

  /// Build location string from station status data
  String? _buildLocation(Map<String, dynamic> data) {
    if (data['location'] is Map) {
      final loc = data['location'] as Map<String, dynamic>;
      final city = loc['city'] as String?;
      final country = loc['country'] as String?;

      if (city != null && country != null) {
        return '$city, $country';
      }
    }
    return null;
  }

  /// Get double value from nested map
  double? _getDouble(Map<String, dynamic> data, String path) {
    final parts = path.split('.');
    dynamic current = data;

    for (var part in parts) {
      if (current is Map) {
        current = current[part];
      } else {
        return null;
      }
    }

    if (current is num) {
      return current.toDouble();
    }
    return null;
  }

  /// Add discovered station to station service
  Future<void> _addDiscoveredRelay(Station station) async {
    try {
      final stationService = StationService();
      final existingStations = stationService.getAllStations();

      // Check if station already exists by URL
      final existingByUrl = existingStations.indexWhere(
        (r) => r.url == station.url,
      );
      if (existingByUrl != -1) {
        LogService().log('  Station already exists: ${station.url}');
        // Update cached info (connected devices, location, etc.)
        final existing = existingStations[existingByUrl];
        await stationService.updateStation(
          station.url,
          existing.copyWith(
            name: station.name,
            callsign: station.callsign ?? existing.callsign,
            location: station.location ?? existing.location,
            latitude: station.latitude ?? existing.latitude,
            longitude: station.longitude ?? existing.longitude,
            connectedDevices: station.connectedDevices,
            lastChecked: DateTime.now(),
          ),
        );
        LogService().log(
          '  Updated station cache: ${station.connectedDevices} devices connected',
        );
        return;
      }

      // Check if station already exists by callsign (same station on different IP)
      if (station.callsign != null && station.callsign!.isNotEmpty) {
        final existingByCallsign = existingStations.indexWhere(
          (r) => r.callsign == station.callsign && r.callsign != null,
        );
        if (existingByCallsign != -1) {
          final existing = existingStations[existingByCallsign];
          LogService().log(
            '  Station with callsign ${station.callsign} already exists at ${existing.url}',
          );
          // Prefer non-localhost URL
          if (existing.url.contains('127.0.0.1') &&
              !station.url.contains('127.0.0.1')) {
            // Update existing entry with new URL (prefer LAN IP)
            await stationService.updateStation(
              existing.url,
              existing.copyWith(
                url: station.url,
                location: station.location ?? existing.location,
                latitude: station.latitude ?? existing.latitude,
                longitude: station.longitude ?? existing.longitude,
                connectedDevices: station.connectedDevices,
                lastChecked: DateTime.now(),
              ),
            );
            LogService().log(
              '  Updated station URL from localhost to ${station.url}',
            );
          }
          return;
        }
      }

      // Add the station
      await stationService.addStation(station);
      LogService().log('  Added station: ${station.name}');
      LogService().log('  URL: ${station.url}');
      if (station.location != null) {
        LogService().log('  Location: ${station.location}');
      }

      // If this is the only station, mark it as preferred
      final allStations = stationService.getAllStations();
      final hasPreferred = allStations.any((r) => r.status == 'preferred');

      if (!hasPreferred) {
        await stationService.setPreferred(station.url);
        LogService().log(
          '  ✓ Set as preferred station (first station discovered)',
        );
      }
    } catch (e) {
      LogService().log('  Error adding station: $e');
    }
  }

  /// Get discovery status
  bool get isScanning => _isScanning;

  /// Try to detect the local subnet using local-only methods (no internet required)
  /// This works completely off-grid by using UDP broadcast sockets
  Future<String?> _detectSubnetFromConnectivity() async {
    // Method 1: Bind a UDP socket to broadcast address to detect local IP
    try {
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      // Try to "connect" to broadcast - this doesn't send anything, just sets the route
      socket.broadcastEnabled = true;

      // Get the local address that would be used for LAN communication
      // by checking what interface handles broadcast
      final localAddress = socket.address.address;
      socket.close();

      if (localAddress != '0.0.0.0' && localAddress != '127.0.0.1') {
        LogService().log('  Local IP detected via UDP socket: $localAddress');
        return _getSubnet(localAddress);
      }
    } catch (e) {
      LogService().log('  Could not detect subnet via UDP socket: $e');
    }

    // Method 2: Try connecting to common gateway addresses (local only, no internet)
    // These are typical router IPs on private networks
    final commonGateways = [
      '192.168.1.1',
      '192.168.0.1',
      '192.168.178.1', // Fritz!Box
      '10.0.0.1',
      '192.168.2.1',
      '192.168.10.1',
      '172.16.0.1',
    ];

    for (final gateway in commonGateways) {
      try {
        final socket = await Socket.connect(
          gateway,
          80, // Try HTTP port on router
          timeout: const Duration(milliseconds: 200),
        );
        final localAddress = socket.address.address;
        socket.destroy();

        if (localAddress != '127.0.0.1') {
          LogService().log(
            '  Local IP detected via gateway $gateway: $localAddress',
          );
          return _getSubnet(localAddress);
        }
      } catch (_) {
        // Gateway not reachable, try next
      }
    }

    LogService().log('  Could not auto-detect subnet, will use common ranges');
    return null;
  }
}
