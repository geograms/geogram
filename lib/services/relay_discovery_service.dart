import 'dart:async';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../models/relay.dart';
import '../services/relay_service.dart';
import '../services/log_service.dart';

/// Service for automatic discovery of relays on local network
class RelayDiscoveryService {
  static final RelayDiscoveryService _instance = RelayDiscoveryService._internal();
  factory RelayDiscoveryService() => _instance;
  RelayDiscoveryService._internal();

  Timer? _discoveryTimer;
  bool _isScanning = false;
  final List<int> _ports = [80, 8080];
  final Duration _scanInterval = const Duration(minutes: 5);
  final Duration _requestTimeout = const Duration(seconds: 2);
  final Duration _startupDelay = const Duration(seconds: 5);
  static const int _maxConcurrentConnections = 20; // Limit concurrent connections to avoid "too many open files"

  /// Start automatic discovery
  void start() {
    // Network interface scanning not supported on web
    if (kIsWeb) {
      LogService().log('Relay auto-discovery not supported on web platform');
      return;
    }

    LogService().log('Starting relay auto-discovery service (delayed ${_startupDelay.inSeconds}s)');

    // Delay initial scan to let the app initialize fully
    // This prevents "too many open files" errors on startup
    Timer(_startupDelay, () {
      discover();

      // Schedule periodic scans every 5 minutes
      _discoveryTimer = Timer.periodic(_scanInterval, (_) {
        discover();
      });
    });
  }

  /// Stop automatic discovery
  void stop() {
    LogService().log('Stopping relay auto-discovery service');
    _discoveryTimer?.cancel();
    _discoveryTimer = null;
  }

  /// Discover relays on local network
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

      if (interfaces.isEmpty) {
        LogService().log('No network interfaces found');
        return;
      }

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

      LogService().log('Scanning ${ranges.length} network ranges...');
      for (var range in ranges) {
        LogService().log('  Range: $range.0/24');
      }

      // Scan each range
      int foundCount = 0;
      for (var range in ranges) {
        final found = await _scanRange(range);
        foundCount += found;
      }

      LogService().log('');
      LogService().log('Discovery complete: $foundCount relay(s) found');
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

  /// Scan a network range for relays
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
        final relay = await _checkRelay(target.key, target.value);
        if (relay != null) {
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

  /// Check if a relay exists at given IP and port
  Future<Relay?> _checkRelay(String ip, int port) async {
    try {
      final url = 'http://$ip:$port/';
      final response = await http.get(
        Uri.parse(url),
        headers: {'Accept': 'application/json'},
      ).timeout(_requestTimeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;

        // Check if it's a Geogram relay
        if (data['service'] == 'Geogram Relay Server') {
          LogService().log('✓ Found relay at $ip:$port');

          // Create relay object
          final relay = Relay(
            url: 'ws://$ip:$port',
            name: data['description'] as String? ?? 'Local Relay ($ip)',
            status: 'available',
            location: _buildLocation(data),
            latitude: _getDouble(data, 'location.latitude'),
            longitude: _getDouble(data, 'location.longitude'),
            connectedDevices: data['connected_devices'] as int?,
          );

          // Add to relay service
          await _addDiscoveredRelay(relay);

          return relay;
        }
      }
    } catch (e) {
      // Silently ignore connection errors (most IPs won't respond)
    }

    return null;
  }

  /// Build location string from relay status data
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

  /// Add discovered relay to relay service
  Future<void> _addDiscoveredRelay(Relay relay) async {
    try {
      final relayService = RelayService();
      final existingRelays = relayService.getAllRelays();

      // Check if relay already exists
      final existingIndex = existingRelays.indexWhere((r) => r.url == relay.url);
      if (existingIndex != -1) {
        LogService().log('  Relay already exists: ${relay.url}');
        // Update cached info (connected devices, location, etc.)
        final existing = existingRelays[existingIndex];
        await relayService.updateRelay(
          relay.url,
          existing.copyWith(
            name: relay.name,
            location: relay.location ?? existing.location,
            latitude: relay.latitude ?? existing.latitude,
            longitude: relay.longitude ?? existing.longitude,
            connectedDevices: relay.connectedDevices,
            lastChecked: DateTime.now(),
          ),
        );
        LogService().log('  Updated relay cache: ${relay.connectedDevices} devices connected');
        return;
      }

      // Add the relay
      await relayService.addRelay(relay);
      LogService().log('  Added relay: ${relay.name}');
      LogService().log('  URL: ${relay.url}');
      if (relay.location != null) {
        LogService().log('  Location: ${relay.location}');
      }

      // If this is the only relay, mark it as preferred
      final allRelays = relayService.getAllRelays();
      final hasPreferred = allRelays.any((r) => r.status == 'preferred');

      if (!hasPreferred) {
        await relayService.setPreferred(relay.url);
        LogService().log('  ✓ Set as preferred relay (first relay discovered)');
      }

    } catch (e) {
      LogService().log('  Error adding relay: $e');
    }
  }

  /// Get discovery status
  bool get isScanning => _isScanning;
}
