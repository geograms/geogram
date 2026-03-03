/// LAN Transport - Direct HTTP communication on local network
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import '../../services/log_service.dart';
import '../../services/app_args.dart';
import '../../services/security_service.dart';
import '../../api/endpoints/chat_api.dart';
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
    if (SecurityService().bleOnlyMode) return false;
    return true;
  }

  /// HTTP timeout for requests
  final Duration timeout;

  /// HTTP timeout for reachability checks
  final Duration reachabilityTimeout;

  LanTransport({
    this.timeout = const Duration(seconds: 5),
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
    // For LAN transport, we send directly to the device's local server
    // No callsign prefix needed - unlike station relay, we're talking directly to the target
    final uri = Uri.parse('$baseUrl${message.path}');
    final method = message.method?.toUpperCase() ?? 'GET';
    final headers = message.headers ?? {'Content-Type': 'application/json'};
    // payload may already be a JSON string (from DM API) - don't double-encode
    Object? body;
    if (message.payload != null) {
      if (message.payload is List<int>) {
        body = message.payload as List<int>;
      } else if (message.payload is String) {
        body = message.payload as String;
      } else {
        body = jsonEncode(message.payload);
      }
    }

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

    final responseData = _isBinaryContentType(response.headers['content-type'])
        ? response.bodyBytes
        : response.body;

    final result = TransportResult.success(
      statusCode: response.statusCode,
      responseData: responseData,
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
      // DM path: extract sender from signed event, POST to chat API
      // The receiving device's endpoint is /api/chat/{senderCallsign}/messages
      final senderCallsign = _extractSenderCallsign(message.signedEvent);
      if (senderCallsign == null) {
        stopwatch.stop();
        return TransportResult.failure(
          error: 'Cannot extract sender callsign from signed event',
          transportUsed: id,
        );
      }
      path = '/api/chat/$senderCallsign/messages';
    } else {
      // Chat messages use the room path
      path = ChatApi.messagesPath(message.path ?? 'general');
    }

    // For LAN transport, send directly to device - no callsign prefix needed
    final uri = Uri.parse('$baseUrl$path');
    final body = message.signedEvent != null
        ? jsonEncode({'event': message.signedEvent})
        : jsonEncode(message.payload);

    LogService().log('LanTransport: POST $path to ${message.targetCallsign}');

    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: body,
    ).timeout(timeout);

    stopwatch.stop();

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final result = TransportResult.failure(
        error: 'HTTP ${response.statusCode}: ${response.body}',
        statusCode: response.statusCode,
        transportUsed: id,
      );
      recordMetrics(result);
      return result;
    }

    final result = TransportResult.success(
      statusCode: response.statusCode,
      responseData: response.body,
      transportUsed: id,
      latency: stopwatch.elapsed,
    );

    recordMetrics(result);
    return result;
  }

  /// Extract sender callsign from signed event tags
  String? _extractSenderCallsign(Map<String, dynamic>? signedEvent) {
    if (signedEvent == null) return null;
    final tags = signedEvent['tags'] as List<dynamic>?;
    if (tags == null) return null;
    for (final tag in tags) {
      if (tag is List && tag.length >= 2 && tag[0] == 'callsign') {
        return (tag[1] as String).toUpperCase();
      }
    }
    return null;
  }

  /// Handle sync requests
  Future<TransportResult> _handleSync(
    TransportMessage message,
    String baseUrl,
    Duration timeout,
    Stopwatch stopwatch,
  ) async {
    // Sync requests go to /api/dm/sync/{callsign}
    // For LAN transport, send directly to device - no callsign prefix needed
    final targetCallsign = message.targetCallsign.toUpperCase();
    final uri = Uri.parse('$baseUrl/api/dm/sync/$targetCallsign');

    LogService().log('LanTransport: GET sync from $targetCallsign');

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

  bool _isBinaryContentType(String? contentType) {
    if (contentType == null || contentType.isEmpty) return false;
    final normalized = contentType.toLowerCase();
    return normalized.startsWith('image/') ||
        normalized.startsWith('audio/') ||
        normalized.startsWith('video/') ||
        normalized.startsWith('application/octet-stream') ||
        normalized.startsWith('application/pdf');
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
