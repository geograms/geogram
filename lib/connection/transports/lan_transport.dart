/// LAN Transport - Direct HTTP communication on local network
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import '../../util/callsign_url.dart';
import '../../util/managed_http_client.dart';
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

  final ManagedHttpClient _client = ManagedHttpClient();

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
    _client.close();
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
      final response = await _client.get(uri).timeout(reachabilityTimeout);
      if (response.statusCode != 200) {
        return false;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final actualCallsign =
          ((data['callsign'] as String?) ??
                  (data['stationCallsign'] as String?))
              ?.trim()
              .toUpperCase();
      if (actualCallsign == null || actualCallsign != callsign.toUpperCase()) {
        LogService().log(
          'LanTransport: Rejecting ${deviceInfo.url} for $callsign '
          '(reported callsign: ${actualCallsign ?? "unknown"})',
        );
        return false;
      }

      final expectedDeviceId =
          (deviceInfo.metadata['expected_device_id'] as String?)?.trim();
      if (expectedDeviceId != null && expectedDeviceId.isNotEmpty) {
        final actualDeviceId = (data['device_id'] as String?)?.trim();
        if (actualDeviceId == null ||
            actualDeviceId.isEmpty ||
            actualDeviceId != expectedDeviceId) {
          LogService().log(
            'LanTransport: Rejecting ${deviceInfo.url} for $callsign '
            '(device_id mismatch: expected $expectedDeviceId, got ${actualDeviceId ?? "missing"})',
          );
          return false;
        }
      } else {
        final expectedNpub = (deviceInfo.metadata['expected_npub'] as String?)
            ?.trim();
        if (expectedNpub != null && expectedNpub.isNotEmpty) {
          final actualNpub = (data['npub'] as String?)?.trim();
          if (actualNpub == null ||
              actualNpub.isEmpty ||
              actualNpub != expectedNpub) {
            LogService().log(
              'LanTransport: Rejecting ${deviceInfo.url} for $callsign '
              '(npub mismatch: expected $expectedNpub, got ${actualNpub ?? "missing"})',
            );
            return false;
          }
        }
      }

      return true;
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
          return await _handleApiRequest(
            message,
            deviceInfo.url!,
            effectiveTimeout,
            stopwatch,
          );

        case TransportMessageType.directMessage:
        case TransportMessageType.chatMessage:
          return await _handleMessagePost(
            message,
            deviceInfo.url!,
            effectiveTimeout,
            stopwatch,
          );

        case TransportMessageType.sync:
          return await _handleSync(
            message,
            deviceInfo.url!,
            effectiveTimeout,
            stopwatch,
          );

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

    LogService().log(
      'LanTransport: $method ${message.path} to ${message.targetCallsign}',
    );

    http.Response response;
    switch (method) {
      case 'POST':
        response = await _client
            .post(uri, headers: headers, body: body)
            .timeout(timeout);
        break;
      case 'PUT':
        response = await _client
            .put(uri, headers: headers, body: body)
            .timeout(timeout);
        break;
      case 'DELETE':
        response = await _client.delete(uri, headers: headers).timeout(timeout);
        break;
      default: // GET
        response = await _client.get(uri, headers: headers).timeout(timeout);
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

    final response = await _client
        .post(uri, headers: {'Content-Type': 'application/json'}, body: body)
        .timeout(timeout);

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
    final targetCallsign = callsignForUrl(message.targetCallsign);
    final uri = Uri.parse('$baseUrl/api/dm/sync/$targetCallsign');

    LogService().log('LanTransport: GET sync from $targetCallsign');

    final response = await _client
        .get(uri, headers: {'Content-Type': 'application/json'})
        .timeout(timeout);

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

  /// Streaming variant of [_handleApiRequest]. Sends an arbitrary request
  /// body as a [Stream] (no in-memory buffering on the sender) and returns
  /// the response body as a [Stream] (no in-memory buffering on the
  /// receiver). Used by the Shared sync engine for binary file transfers
  /// to avoid OOM when pulling/pushing large files.
  ///
  /// Returns null if the device is unreachable or the URL is non-local.
  /// Other transports do NOT implement streaming — callers should fall
  /// back to bulk [send] when this returns null.
  Future<LanStreamingResult?> sendStreaming({
    required String callsign,
    required String method,
    required String path,
    Map<String, String>? headers,
    Stream<List<int>>? bodyStream,
    int? bodyStreamLength,
    Duration? timeout,
  }) async {
    if (kIsWeb) return null;
    final deviceInfo = getDeviceInfo(callsign);
    if (deviceInfo?.url == null) return null;
    if (!_isLocalUrl(deviceInfo!.url!)) return null;

    final uri = Uri.parse('${deviceInfo.url}$path');
    final upperMethod = method.toUpperCase();

    // Build the request: a plain http.Request for methods without a
    // body (GET / DELETE / HEAD) — using StreamedRequest there sends
    // chunked-transfer with no chunks and hangs the server waiting on
    // a terminator. For methods carrying an upload stream, use
    // StreamedRequest and pump the body in the background.
    http.BaseRequest req;
    if (bodyStream == null) {
      req = http.Request(upperMethod, uri);
    } else {
      final streamed = http.StreamedRequest(upperMethod, uri);
      if (bodyStreamLength != null) {
        streamed.contentLength = bodyStreamLength;
      }
      unawaited(() async {
        try {
          await for (final chunk in bodyStream) {
            streamed.sink.add(chunk);
          }
        } catch (e) {
          streamed.sink.addError(e);
        } finally {
          await streamed.sink.close();
        }
      }());
      req = streamed;
    }
    if (headers != null) {
      req.headers.addAll(headers);
    }

    LogService().log(
      'LanTransport: streaming $upperMethod $path to $callsign',
    );

    final effectiveTimeout = timeout ?? this.timeout;
    try {
      final resp = await _client.send(req).timeout(effectiveTimeout);
      return LanStreamingResult(
        statusCode: resp.statusCode,
        headers: Map<String, String>.from(resp.headers),
        bodyStream: resp.stream,
      );
    } catch (e) {
      LogService().log('LanTransport: streaming send failed: $e');
      return null;
    }
  }

  /// Register a device with its local URL
  ///
  /// Call this when a device is discovered on the local network.
  void registerLocalDevice(
    String callsign,
    String url, {
    String? expectedDeviceId,
    String? expectedNpub,
  }) {
    if (_isLocalUrl(url)) {
      registerDevice(
        callsign,
        url: url,
        metadata: {
          'source': 'lan_discovery',
          'registered_at': DateTime.now().toIso8601String(),
          if (expectedDeviceId != null && expectedDeviceId.isNotEmpty)
            'expected_device_id': expectedDeviceId,
          if (expectedNpub != null && expectedNpub.isNotEmpty)
            'expected_npub': expectedNpub,
        },
      );
      LogService().log('LanTransport: Registered $callsign at $url');
    }
  }
}

/// Result of a streaming LAN request. The body is exposed as a [Stream]
/// so callers can pipe it directly to disk without buffering the whole
/// payload in memory.
class LanStreamingResult {
  final int statusCode;
  final Map<String, String> headers;
  final Stream<List<int>> bodyStream;

  const LanStreamingResult({
    required this.statusCode,
    required this.headers,
    required this.bodyStream,
  });
}
