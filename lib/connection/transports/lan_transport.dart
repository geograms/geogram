/// LAN Transport - Direct HTTP communication on local network
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import '../../services/log_service.dart';
import '../../services/app_args.dart';
import '../transport.dart';
import '../transport_message.dart';

/// LAN Transport for direct HTTP communication with devices on the local network
///
/// This transport has the highest priority (10) as it provides:
/// - Lowest latency
/// - Highest bandwidth
/// - No internet dependency
/// - Works on local network
class LanTransport extends Transport with TransportMixin {
  @override
  String get id => 'lan';

  @override
  String get name => 'Local Network';

  @override
  int get priority => 10; // Highest priority

  @override
  bool get isAvailable {
    // Not available on web (CORS issues) or in internet-only mode
    if (kIsWeb) return false;
    if (AppArgs().internetOnly) return false;
    return true;
  }

  /// HTTP timeout for requests
  final Duration timeout;

  /// HTTP timeout for reachability checks
  final Duration reachabilityTimeout;

  LanTransport({
    this.timeout = const Duration(seconds: 30),
    this.reachabilityTimeout = const Duration(seconds: 3),
  });

  @override
  Future<void> initialize() async {
    LogService().log('LanTransport: Initializing...');
    markInitialized();
    LogService().log('LanTransport: Initialized');
  }

  @override
  Future<void> dispose() async {
    LogService().log('LanTransport: Disposing...');
    await disposeMixin();
    LogService().log('LanTransport: Disposed');
  }

  @override
  Future<bool> canReach(String callsign) async {
    final deviceInfo = getDeviceInfo(callsign);
    if (deviceInfo?.url == null) return false;

    // Only check local URLs
    if (!_isLocalUrl(deviceInfo!.url!)) return false;

    try {
      final uri = Uri.parse('${deviceInfo.url}/api/status');
      final response = await http.get(uri).timeout(reachabilityTimeout);
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<int> getQuality(String callsign) async {
    // For LAN, quality is binary - either reachable (100) or not (0)
    // Could be enhanced to measure actual latency
    final reachable = await canReach(callsign);
    return reachable ? 100 : 0;
  }

  @override
  Future<TransportResult> send(
    TransportMessage message, {
    Duration? timeout,
  }) async {
    final effectiveTimeout = timeout ?? this.timeout;
    final stopwatch = Stopwatch()..start();

    try {
      // Get device URL
      final deviceInfo = getDeviceInfo(message.targetCallsign);
      if (deviceInfo?.url == null) {
        return TransportResult.failure(
          error: 'No URL for device ${message.targetCallsign}',
          transportUsed: id,
        );
      }

      // Verify it's a local URL
      if (!_isLocalUrl(deviceInfo!.url!)) {
        return TransportResult.failure(
          error: 'Not a local URL: ${deviceInfo.url}',
          transportUsed: id,
        );
      }

      // Handle based on message type
      switch (message.type) {
        case TransportMessageType.apiRequest:
          return await _handleApiRequest(message, deviceInfo.url!, effectiveTimeout, stopwatch);

        case TransportMessageType.directMessage:
        case TransportMessageType.chatMessage:
          return await _handleMessagePost(message, deviceInfo.url!, effectiveTimeout, stopwatch);

        case TransportMessageType.sync:
          return await _handleSync(message, deviceInfo.url!, effectiveTimeout, stopwatch);

        default:
          return TransportResult.failure(
            error: 'Unsupported message type for LAN: ${message.type}',
            transportUsed: id,
          );
      }
    } catch (e) {
      stopwatch.stop();
      final result = TransportResult.failure(
        error: e.toString(),
        transportUsed: id,
      );
      recordMetrics(result);
      return result;
    }
  }

  /// Handle API request messages
  Future<TransportResult> _handleApiRequest(
    TransportMessage message,
    String baseUrl,
    Duration timeout,
    Stopwatch stopwatch,
  ) async {
    final uri = Uri.parse('$baseUrl${message.path}');
    final method = message.method?.toUpperCase() ?? 'GET';
    final headers = message.headers ?? {'Content-Type': 'application/json'};
    // payload may already be a JSON string (from DM API) - don't double-encode
    final body = message.payload != null
        ? (message.payload is String ? message.payload : jsonEncode(message.payload))
        : null;

    LogService().log('LanTransport: $method ${message.path} to ${message.targetCallsign}');

    http.Response response;
    switch (method) {
      case 'POST':
        response = await http.post(uri, headers: headers, body: body).timeout(timeout);
        break;
      case 'PUT':
        response = await http.put(uri, headers: headers, body: body).timeout(timeout);
        break;
      case 'DELETE':
        response = await http.delete(uri, headers: headers).timeout(timeout);
        break;
      default: // GET
        response = await http.get(uri, headers: headers).timeout(timeout);
    }

    stopwatch.stop();

    final result = TransportResult.success(
      statusCode: response.statusCode,
      responseData: response.body,
      transportUsed: id,
      latency: stopwatch.elapsed,
    );

    recordMetrics(result);
    return result;
  }

  /// Handle DM and chat message posts
  Future<TransportResult> _handleMessagePost(
    TransportMessage message,
    String baseUrl,
    Duration timeout,
    Stopwatch stopwatch,
  ) async {
    // DMs and chat messages are posted to the device's chat API
    String path;
    if (message.type == TransportMessageType.directMessage) {
      // POST to /api/dm/{callsign}/messages
      path = '/api/dm/${message.targetCallsign}/messages';
    } else {
      // Chat messages use the room path
      path = '/api/chat/${message.path ?? "general"}/messages';
    }

    final uri = Uri.parse('$baseUrl$path');
    final body = message.signedEvent != null
        ? jsonEncode(message.signedEvent)
        : jsonEncode(message.payload);

    LogService().log('LanTransport: POST $path to ${message.targetCallsign}');

    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: body,
    ).timeout(timeout);

    stopwatch.stop();

    final result = TransportResult.success(
      statusCode: response.statusCode,
      responseData: response.body,
      transportUsed: id,
      latency: stopwatch.elapsed,
    );

    recordMetrics(result);
    return result;
  }

  /// Handle sync requests
  Future<TransportResult> _handleSync(
    TransportMessage message,
    String baseUrl,
    Duration timeout,
    Stopwatch stopwatch,
  ) async {
    // Sync requests go to /api/dm/sync/{callsign}
    final uri = Uri.parse('$baseUrl/api/dm/sync/${message.targetCallsign}');

    LogService().log('LanTransport: GET sync from ${message.targetCallsign}');

    final response = await http.get(
      uri,
      headers: {'Content-Type': 'application/json'},
    ).timeout(timeout);

    stopwatch.stop();

    final result = TransportResult.success(
      statusCode: response.statusCode,
      responseData: response.body,
      transportUsed: id,
      latency: stopwatch.elapsed,
    );

    recordMetrics(result);
    return result;
  }

  @override
  Future<void> sendAsync(TransportMessage message) async {
    // Fire and forget - ignore result
    send(message);
  }

  /// Check if a URL is a local network address
  bool _isLocalUrl(String url) {
    try {
      final uri = Uri.parse(url);
      final host = uri.host;

      // Localhost
      if (host == 'localhost' || host == '127.0.0.1') return true;

      // Private IPv4 ranges
      if (host.startsWith('192.168.')) return true;
      if (host.startsWith('10.')) return true;

      // 172.16.0.0 - 172.31.255.255
      if (host.startsWith('172.')) {
        final parts = host.split('.');
        if (parts.length >= 2) {
          final second = int.tryParse(parts[1]);
          if (second != null && second >= 16 && second <= 31) return true;
        }
      }

      // Link-local
      if (host.startsWith('169.254.')) return true;

      return false;
    } catch (e) {
      return false;
    }
  }

  /// Register a device with its local URL
  ///
  /// Call this when a device is discovered on the local network.
  void registerLocalDevice(String callsign, String url) {
    if (_isLocalUrl(url)) {
      registerDevice(callsign, url: url, metadata: {
        'source': 'lan_discovery',
        'registered_at': DateTime.now().toIso8601String(),
      });
      LogService().log('LanTransport: Registered $callsign at $url');
    }
  }
}
