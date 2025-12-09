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
  String toString() => 'NetworkScanResult($ip:$port, type=$type, callsign=$callsign)';
}

/// Callback for scan progress updates
typedef ScanProgressCallback = void Function(String message, int scannedHosts, int totalHosts, List<NetworkScanResult> results);

/// Callback to check if scan should be cancelled
typedef ScanCancelCheck = bool Function();

/// Service for automatic discovery of stations on local network
class StationDiscoveryService {
  static final StationDiscoveryService _instance = StationDiscoveryService._internal();
  factory StationDiscoveryService() => _instance;
  StationDiscoveryService._internal();

  Timer? _discoveryTimer;
  bool _isScanning = false;
  final List<int> _ports = [3456, 8080, 80, 8081, 3000, 5000]; // Standard geogram port (3456) first, then common station ports
  final Duration _scanInterval = const Duration(minutes: 5);
  final Duration _requestTimeout = const Duration(milliseconds: 1500); // Increased timeout for reliability
  final Duration _startupDelay = const Duration(seconds: 5);
  final Duration _localhostScanDelay = const Duration(seconds: 10); // Longer delay when scanning localhost for other instances
  static const int _maxConcurrentConnections = 30; // Limit concurrent connections to avoid "too many open files"

  /// Start automatic discovery
  void start() {
    // Network interface scanning not supported on web
    if (kIsWeb) {
      LogService().log('Station auto-discovery not supported on web platform');
      return;
    }

    // Use longer delay when --scan-localhost is enabled to allow other instances to start
    final localhostScanEnabled = AppArgs().scanLocalhostEnabled;
    final initialDelay = localhostScanEnabled ? _localhostScanDelay : _startupDelay;

    if (localhostScanEnabled) {
      final range = AppArgs().scanLocalhostRange;
      LogService().log('StationDiscovery: Localhost port scanning enabled (range: $range)');
      LogService().log('StationDiscovery: Will scan localhost ports in ${initialDelay.inSeconds}s to allow other instances to start');
    }

    LogService().log('Starting station auto-discovery service (delayed ${initialDelay.inSeconds}s)');

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
  }

  /// Manual scan with progress callback - returns list of found devices
  Future<List<NetworkScanResult>> scanWithProgress({
    ScanProgressCallback? onProgress,
    ScanCancelCheck? shouldCancel,
    int timeoutMs = 500,
  }) async {
    if (kIsWeb) {
      onProgress?.call('Network scanning not supported on web', 0, 0, []);
      return [];
    }

    // Force reset if stuck (singleton state could be stale)
    if (_isScanning) {
      LogService().log('Previous scan was stuck, forcing reset');
      _isScanning = false;
    }

    _isScanning = true;
    final results = <NetworkScanResult>[];
    final seenKeys = <String, int>{}; // Maps key -> index in results

    // Helper to add result with real-time deduplication
    void addResult(NetworkScanResult result) {
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

      // Calculate total hosts to scan
      final ranges = <String>{};
      for (var interface in interfaces) {
        for (var addr in interface.addresses) {
          final subnet = _getSubnet(addr.address);
          if (subnet != null) {
            ranges.add(subnet);
          }
        }
      }

      // Check if localhost port range scanning is enabled via --scan-localhost flag
      final localhostPortRange = AppArgs().scanLocalhostPorts;
      final localhostRangeSize = localhostPortRange != null
          ? (localhostPortRange.$2 - localhostPortRange.$1 + 1)
          : 0;

      // Total: localhost ports (x2 for both localhost and 127.0.0.1) + localhost range + (254 hosts * ports per range)
      final totalHosts = (_ports.length * 2) + localhostRangeSize + (ranges.length * 254 * _ports.length);
      int scannedHosts = 0;

      LogService().log('StationDiscovery: Scanning standard localhost ports: ${_ports.join(", ")}');
      onProgress?.call('Scanning localhost...', scannedHosts, totalHosts, results);

      // Always scan localhost first - try both 'localhost' hostname and '127.0.0.1'
      // Some systems resolve localhost to IPv6 ::1, so we need to check both
      int standardLocalhostFound = 0;
      for (var host in ['localhost', '127.0.0.1']) {
        for (var port in _ports) {
          if (shouldCancel?.call() == true) break;
          final result = await _checkGeogramDevice(host, port, timeoutMs);
          if (result != null) {
            standardLocalhostFound++;
            LogService().log('StationDiscovery: Found device at $host:$port - callsign: ${result.callsign ?? "unknown"}, type: ${result.type}');
            addResult(result);
            onProgress?.call('Found: ${result.type} at $host:$port', scannedHosts, totalHosts, results);
          }
          scannedHosts++;
        }
      }
      LogService().log('StationDiscovery: Standard localhost scan found $standardLocalhostFound device(s)');

      // Scan extended localhost port range if --scan-localhost flag is set
      // This is useful for testing with multiple Geogram instances on the same machine
      if (localhostPortRange != null) {
        final (startPort, endPort) = localhostPortRange;
        final portCount = endPort - startPort + 1;
        LogService().log('StationDiscovery: === LOCALHOST SCAN START ===');
        LogService().log('StationDiscovery: Scanning localhost ports $startPort-$endPort ($portCount ports) for other Geogram instances');
        onProgress?.call('Scanning localhost ports $startPort-$endPort...', scannedHosts, totalHosts, results);

        // Build list of localhost ports to scan
        final localhostTargets = <int>[];
        for (int port = startPort; port <= endPort; port++) {
          // Skip ports we already scanned in the standard ports list
          if (!_ports.contains(port)) {
            localhostTargets.add(port);
          }
        }

        LogService().log('StationDiscovery: Will scan ${localhostTargets.length} localhost ports (excluding standard ports)');
        int foundCount = 0;

        // Process localhost ports in batches
        for (int batchStart = 0; batchStart < localhostTargets.length; batchStart += _maxConcurrentConnections) {
          if (shouldCancel?.call() == true) {
            LogService().log('StationDiscovery: Localhost scan cancelled');
            break;
          }

          final batchEnd = (batchStart + _maxConcurrentConnections).clamp(0, localhostTargets.length);
          final batch = localhostTargets.sublist(batchStart, batchEnd);

          final futures = batch.map((port) async {
            final result = await _checkGeogramDevice('127.0.0.1', port, timeoutMs);
            if (result != null) {
              foundCount++;
              LogService().log('StationDiscovery: FOUND Geogram instance at localhost:$port - callsign: ${result.callsign ?? "unknown"}, type: ${result.type}');
              addResult(result);
              onProgress?.call('Found: ${result.type} at localhost:$port', scannedHosts, totalHosts, results);
            }
          }).toList();

          await Future.wait(futures).timeout(
            Duration(milliseconds: timeoutMs * 3),
            onTimeout: () => [],
          );

          scannedHosts += batch.length;
          onProgress?.call('Scanning localhost ports...', scannedHosts, totalHosts, results);
        }

        LogService().log('StationDiscovery: === LOCALHOST SCAN COMPLETE === Found $foundCount device(s)');
      } else {
        LogService().log('StationDiscovery: Localhost port range scanning not enabled (use --scan-localhost=START-END)');
      }

      // Scan each network range
      outerLoop:
      for (var range in ranges) {
        if (shouldCancel?.call() == true) break;
        onProgress?.call('Scanning $range.0/24...', scannedHosts, totalHosts, results);

        // Build list of targets for this range
        final targets = <MapEntry<String, int>>[];
        for (int i = 1; i < 255; i++) {
          final ip = '$range.$i';
          for (var port in _ports) {
            targets.add(MapEntry(ip, port));
          }
        }

        // Process in batches
        for (int batchStart = 0; batchStart < targets.length; batchStart += _maxConcurrentConnections) {
          if (shouldCancel?.call() == true) break outerLoop;

          final batchEnd = (batchStart + _maxConcurrentConnections).clamp(0, targets.length);
          final batch = targets.sublist(batchStart, batchEnd);

          final futures = batch.map((target) async {
            final result = await _checkGeogramDevice(target.key, target.value, timeoutMs);
            if (result != null) {
              addResult(result);
              onProgress?.call('Found: ${result.type} at ${result.ip}:${result.port}', scannedHosts, totalHosts, results);
            }
          }).toList();

          await Future.wait(futures).timeout(
            Duration(milliseconds: timeoutMs * 3),
            onTimeout: () => [],
          );

          scannedHosts += batch.length;
          onProgress?.call('Scanning...', scannedHosts, totalHosts, results);
        }
      }

      // Results are already deduplicated in real-time via addResult()
      final wasCancelled = shouldCancel?.call() == true;
      final message = wasCancelled
          ? 'Scan stopped: ${results.length} device(s) found'
          : 'Scan complete: ${results.length} device(s) found';
      onProgress?.call(message, scannedHosts, totalHosts, results);

      return results;

    } catch (e) {
      LogService().log('Error during scan: $e');
      onProgress?.call('Error: $e', 0, 0, results);
    } finally {
      _isScanning = false;
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

  /// Check if a host:port is a geogram device
  Future<NetworkScanResult?> _checkGeogramDevice(String ip, int port, int timeoutMs) async {
    try {
      final client = http.Client();
      final timeout = Duration(milliseconds: timeoutMs);

      try {
        // Try /api/status endpoint first (preferred)
        final statusUrl = Uri.parse('http://$ip:$port/api/status');
        final response = await client.get(statusUrl).timeout(timeout);

        if (response.statusCode == 200) {
          final body = response.body;
          final data = jsonDecode(body) as Map<String, dynamic>;

          String type = 'unknown';
          final serviceField = data['service'];

          if (body.contains('Geogram Station') || body.contains('geogram-station') ||
              serviceField == 'Geogram Station Server') {
            type = 'station';
          } else if (body.contains('Geogram Desktop') || body.contains('geogram-desktop')) {
            type = 'desktop';
          } else if (body.contains('Geogram') || body.contains('geogram')) {
            type = 'client';
          }

          if (type != 'unknown') {
            client.close();
            return NetworkScanResult(
              ip: ip,
              port: port,
              type: type,
              callsign: data['callsign'] as String? ?? data['stationCallsign'] as String?,
              name: data['name'] as String?,
              version: data['version'] as String?,
              description: data['description'] as String?,
              location: _buildLocation(data),
              latitude: _getDouble(data, 'location.latitude'),
              longitude: _getDouble(data, 'location.longitude'),
              connectedDevices: data['connected_devices'] as int?,
            );
          }
        }
      } catch (_) {
        // Try next endpoint
      }

      try {
        // Try /station/status endpoint (legacy)
        final stationStatusUrl = Uri.parse('http://$ip:$port/station/status');
        final response = await client.get(stationStatusUrl).timeout(timeout);

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          return NetworkScanResult(
            ip: ip,
            port: port,
            type: 'station',
            callsign: data['callsign'] as String?,
            name: data['name'] as String?,
            description: data['description'] as String?,
            connectedDevices: data['connected_devices'] as int?,
          );
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

          // Check if it's a geogram service
          if (body.contains('Geogram Station Server') || body.contains('geogram-station')) {
            final data = jsonDecode(body) as Map<String, dynamic>;
            return NetworkScanResult(
              ip: ip,
              port: port,
              type: 'station',
              callsign: data['callsign'] as String?,
              name: data['name'] as String?,
              version: data['version'] as String?,
              description: data['description'] as String?,
              location: _buildLocation(data),
              latitude: _getDouble(data, 'location.latitude'),
              longitude: _getDouble(data, 'location.longitude'),
              connectedDevices: data['connected_devices'] as int?,
            );
          } else if (body.contains('Geogram Desktop') || body.contains('geogram-desktop')) {
            try {
              final data = jsonDecode(body) as Map<String, dynamic>;
              return NetworkScanResult(
                ip: ip,
                port: port,
                type: 'desktop',
                callsign: data['callsign'] as String?,
                name: data['name'] as String?,
                version: data['version'] as String?,
                description: data['description'] as String?,
              );
            } catch (_) {
              return NetworkScanResult(
                ip: ip,
                port: port,
                type: 'desktop',
              );
            }
          }
        }
      } catch (_) {
        // Not a geogram device
      }

      client.close();
    } catch (_) {
      // Connection failed
    }

    return null;
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
    LogService().log('RELAY AUTO-DISCOVERY');
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
        for (var addr in interface.addresses) {
          final subnet = _getSubnet(addr.address);
          if (subnet != null) {
            ranges.add(subnet);
          }
        }
      }

      LogService().log('Scanning localhost and ${ranges.length} network ranges...');

      // Always scan localhost first
      int foundCount = 0;
      LogService().log('  Scanning localhost (127.0.0.1) on standard ports...');
      for (var port in _ports) {
        final station = await _checkRelay('127.0.0.1', port);
        if (station != null) {
          foundCount++;
          LogService().log('    Found device at localhost:$port');
        }
      }

      // Scan extended localhost port range if --scan-localhost flag is set
      final localhostPortRange = AppArgs().scanLocalhostPorts;
      if (localhostPortRange != null) {
        final (startPort, endPort) = localhostPortRange;
        final portCount = endPort - startPort + 1;
        LogService().log('  Scanning localhost ports $startPort-$endPort ($portCount ports)...');

        // Build list of localhost ports to scan (excluding standard ports)
        final localhostTargets = <int>[];
        for (int port = startPort; port <= endPort; port++) {
          if (!_ports.contains(port)) {
            localhostTargets.add(port);
          }
        }

        // Process localhost ports in batches
        for (int batchStart = 0; batchStart < localhostTargets.length; batchStart += _maxConcurrentConnections) {
          final batchEnd = (batchStart + _maxConcurrentConnections).clamp(0, localhostTargets.length);
          final batch = localhostTargets.sublist(batchStart, batchEnd);

          final futures = batch.map((port) async {
            final station = await _checkRelay('127.0.0.1', port);
            if (station != null) {
              foundCount++;
              LogService().log('    Found Geogram instance at localhost:$port');
            }
          }).toList();

          await Future.wait(futures).timeout(
            const Duration(seconds: 5),
            onTimeout: () => [],
          );
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
  Future<int> _scanRange(String subnet) async {
    int foundCount = 0;

    // Build list of all IP:port combinations to scan
    final targets = <MapEntry<String, int>>[];
    for (int i = 1; i < 255; i++) {
      final ip = '$subnet.$i';
      for (var port in _ports) {
        targets.add(MapEntry(ip, port));
      }
    }

    // Process in batches to avoid "too many open files" error
    for (int batchStart = 0; batchStart < targets.length; batchStart += _maxConcurrentConnections) {
      final batchEnd = (batchStart + _maxConcurrentConnections).clamp(0, targets.length);
      final batch = targets.sublist(batchStart, batchEnd);

      final futures = batch.map((target) async {
        final station = await _checkRelay(target.key, target.value);
        if (station != null) {
          foundCount++;
        }
      }).toList();

      // Wait for this batch to complete before starting the next
      await Future.wait(futures).timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          // Silently continue on timeout
          return [];
        },
      );
    }

    return foundCount;
  }

  /// Check if a station or desktop client exists at given IP and port
  Future<Station?> _checkRelay(String ip, int port) async {
    try {
      // Use /api/status endpoint for detection (returns JSON)
      final url = 'http://$ip:$port/api/status';
      final response = await http.get(
        Uri.parse(url),
        headers: {'Accept': 'application/json'},
      ).timeout(_requestTimeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final service = data['service'] as String? ?? '';

        // Check if it's a Geogram station
        if (service == 'Geogram Station Server') {
          LogService().log('✓ Found station at $ip:$port');

          // Create station object with callsign
          final station = Station(
            url: 'ws://$ip:$port',
            name: data['callsign'] as String? ?? data['name'] as String? ?? data['description'] as String? ?? 'Local Station ($ip)',
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
          final name = data['nickname'] as String? ?? data['name'] as String? ?? callsign;
          final deviceUrl = 'http://$ip:$port';

          if (callsign != null && callsign.isNotEmpty) {
            LogService().log('✓ Found desktop client at $ip:$port - callsign: $callsign');

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
      final existingByUrl = existingStations.indexWhere((r) => r.url == station.url);
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
        LogService().log('  Updated station cache: ${station.connectedDevices} devices connected');
        return;
      }

      // Check if station already exists by callsign (same station on different IP)
      if (station.callsign != null && station.callsign!.isNotEmpty) {
        final existingByCallsign = existingStations.indexWhere(
          (r) => r.callsign == station.callsign && r.callsign != null,
        );
        if (existingByCallsign != -1) {
          final existing = existingStations[existingByCallsign];
          LogService().log('  Station with callsign ${station.callsign} already exists at ${existing.url}');
          // Prefer non-localhost URL
          if (existing.url.contains('127.0.0.1') && !station.url.contains('127.0.0.1')) {
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
            LogService().log('  Updated station URL from localhost to ${station.url}');
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
        LogService().log('  ✓ Set as preferred station (first station discovered)');
      }

    } catch (e) {
      LogService().log('  Error adding station: $e');
    }
  }

  /// Get discovery status
  bool get isScanning => _isScanning;
}
