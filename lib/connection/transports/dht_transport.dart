/// DHT Transport — routes requests to devices discovered via P2P DHT.
///
/// Priority 25: between WebRTC (15) and Station (30).
/// Devices register with their public URL after DHT discovery.
/// Routing uses direct HTTP to the device's URL.
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import '../../api/endpoints/chat_api.dart';
import '../../p2p/dht_node.dart';
import '../../services/log_service.dart';
import '../../services/app_args.dart';
import '../../services/security_service.dart';
import '../../util/managed_http_client.dart';
import '../transport.dart';
import '../transport_message.dart';

class DhtTransport extends Transport with TransportMixin {
  @override
  String get id => 'dht';

  @override
  String get name => 'P2P Direct';

  @override
  int get priority => 25;

  final ManagedHttpClient _client = ManagedHttpClient();

  /// Reference to the DHT node for sending geogram messages via UDP.
  /// Set by P2PService after DHT starts.
  DhtNode? dhtNode;

  @override
  bool get isAvailable {
    if (kIsWeb) return false;
    if (AppArgs().internetOnly) return false;
    if (SecurityService().bleOnlyMode) return false;
    return true;
  }

  @override
  Future<void> initialize() async {
    LogService().log('DhtTransport: Initializing...');
    markInitialized();
    LogService().log('DhtTransport: Initialized');
  }

  @override
  Future<void> dispose() async {
    LogService().log('DhtTransport: Disposing...');
    _client.close();
    await disposeMixin();
    LogService().log('DhtTransport: Disposed');
  }

  @override
  Future<bool> canReach(String callsign) async {
    final info = getDeviceInfo(callsign);
    if (info == null) return false;

    if (info.url == null) return false;
    try {
      final uri = Uri.parse('${info.url}/api/status');
      final response = await _client
          .get(uri)
          .timeout(const Duration(seconds: 3));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<int> getQuality(String callsign) async {
    final reachable = await canReach(callsign);
    return reachable ? 60 : 0;
  }

  @override
  Future<TransportResult> send(
    TransportMessage message, {
    Duration? timeout,
  }) async {
    final effectiveTimeout = timeout ?? const Duration(seconds: 10);
    final stopwatch = Stopwatch()..start();

    try {
      final info = getDeviceInfo(message.targetCallsign);
      if (info == null) {
        return TransportResult.failure(
          error: 'No device info for ${message.targetCallsign}',
          transportUsed: id,
        );
      }

      // Try HTTP first (works on LAN / direct connections)
      if (info.url != null) {
        try {
          return await _sendViaHttp(
            message,
            info.url!,
            effectiveTimeout,
            stopwatch,
          );
        } catch (httpError) {
          LogService().log(
            'DhtTransport: HTTP failed for ${message.targetCallsign}, refreshing endpoint via DHT',
          );
        }
      }

      // Fall back to a geogram identity query on the peer's DHT rendezvous
      // socket. This refreshes the peer's real HTTP port; it does not deliver
      // the original payload over UDP.
      final udpIp = info.metadata['udp_ip'] as String?;
      final udpPort = info.metadata['udp_port'] as int?;
      if (dhtNode != null && udpIp != null && udpPort != null && udpPort > 0) {
        LogService().log(
          'DhtTransport: refreshing ${message.targetCallsign} via DHT at $udpIp:$udpPort',
        );
        final response = await dhtNode!.sendGeogramQuery(udpIp, udpPort);
        if (response != null) {
          final refreshedUrl = _resolveRefreshedUrl(
            message.targetCallsign,
            udpIp,
            response,
          );
          if (refreshedUrl != null) {
            try {
              return await _sendViaHttp(
                message,
                refreshedUrl,
                effectiveTimeout,
                stopwatch,
              );
            } catch (refreshError) {
              LogService().log(
                'DhtTransport: refreshed HTTP endpoint failed for ${message.targetCallsign}: $refreshError',
              );
            }
          }
        }
      }

      stopwatch.stop();
      return TransportResult.failure(
        error: 'No reachable path for ${message.targetCallsign}',
        transportUsed: id,
      );
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

  @override
  Future<void> sendAsync(TransportMessage message) async {
    send(message);
  }

  Future<TransportResult> _sendViaHttp(
    TransportMessage message,
    String baseUrl,
    Duration timeout,
    Stopwatch stopwatch,
  ) {
    switch (message.type) {
      case TransportMessageType.apiRequest:
        return _handleApiRequest(message, baseUrl, timeout, stopwatch);
      case TransportMessageType.directMessage:
      case TransportMessageType.chatMessage:
        return _handleMessagePost(message, baseUrl, timeout, stopwatch);
      default:
        throw UnsupportedError(
          'Unsupported DHT transport message type: ${message.type}',
        );
    }
  }

  Future<TransportResult> _handleApiRequest(
    TransportMessage message,
    String baseUrl,
    Duration timeout,
    Stopwatch stopwatch,
  ) async {
    final uri = Uri.parse('$baseUrl${message.path}');
    final method = message.method?.toUpperCase() ?? 'GET';
    final headers = message.headers ?? {'Content-Type': 'application/json'};

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
      'DhtTransport: $method ${message.path} to ${message.targetCallsign}',
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
      default:
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

  Future<TransportResult> _handleMessagePost(
    TransportMessage message,
    String baseUrl,
    Duration timeout,
    Stopwatch stopwatch,
  ) async {
    String path;
    if (message.type == TransportMessageType.directMessage) {
      final senderCallsign = _extractSenderCallsign(message.signedEvent);
      if (senderCallsign == null) {
        stopwatch.stop();
        final result = TransportResult.failure(
          error: 'Cannot extract sender callsign from signed event',
          transportUsed: id,
        );
        recordMetrics(result);
        return result;
      }
      path = '/api/chat/$senderCallsign/messages';
    } else {
      path = ChatApi.messagesPath(message.path ?? 'general');
    }

    final uri = Uri.parse('$baseUrl$path');
    final body = message.signedEvent != null
        ? jsonEncode({'event': message.signedEvent})
        : jsonEncode(message.payload);

    LogService().log('DhtTransport: POST $path to ${message.targetCallsign}');

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

  bool _isBinaryContentType(String? contentType) {
    if (contentType == null || contentType.isEmpty) return false;
    final normalized = contentType.toLowerCase();
    return normalized.startsWith('image/') ||
        normalized.startsWith('audio/') ||
        normalized.startsWith('video/') ||
        normalized.startsWith('application/octet-stream') ||
        normalized.startsWith('application/pdf');
  }

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

  String? _resolveRefreshedUrl(
    String callsign,
    String fallbackIp,
    Map<String, dynamic> response,
  ) {
    final refreshedInfo = getDeviceInfo(callsign);
    if (refreshedInfo?.url != null) {
      return refreshedInfo!.url;
    }

    final httpPort = response['http_port'];
    if (httpPort is int && httpPort > 0) {
      return 'http://$fallbackIp:$httpPort';
    }

    return null;
  }

  /// Register a device discovered via DHT.
  void registerDhtDevice(
    String callsign,
    String url, {
    String? npub,
    String? udpIp,
    int? udpPort,
  }) {
    final normalizedUdpPort = udpPort != null && udpPort > 0 ? udpPort : null;
    registerDevice(
      callsign,
      url: url,
      metadata: {
        'source': 'dht',
        'npub': npub,
        'udp_ip': normalizedUdpPort != null ? udpIp : null,
        'udp_port': normalizedUdpPort,
        'registered_at': DateTime.now().toIso8601String(),
      },
    );
    LogService().log(
      'DhtTransport: Registered $callsign at $url'
      '${normalizedUdpPort != null ? " (udp: $udpIp:$normalizedUdpPort)" : ""}',
    );
  }
}
