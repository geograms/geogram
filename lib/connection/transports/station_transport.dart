/// Station Transport - Communication via internet relay station
library;

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../services/log_service.dart';
import '../../services/station_service.dart';
import '../../services/websocket_service.dart';
import '../transport.dart';
import '../transport_message.dart';

/// Station Transport for communication via internet relay station
///
/// This transport has lower priority (30) as it requires:
/// - Internet connection
/// - Station relay (p2p.radio)
///
/// But it provides:
/// - Global reachability
/// - Works across networks
/// - Store-and-forward capability
class StationTransport extends Transport with TransportMixin {
  @override
  String get id => 'station';

  @override
  String get name => 'Internet Relay';

  @override
  int get priority => 30; // Lower priority (fallback)

  @override
  bool get isAvailable => true; // Available on all platforms

  final StationService _stationService = StationService();
  final WebSocketService _wsService = WebSocketService();

  /// HTTP timeout for requests
  final Duration timeout;

  StationTransport({
    this.timeout = const Duration(seconds: 30),
  });

  @override
  Future<void> initialize() async {
    LogService().log('StationTransport: Initializing...');

    // Listen to WebSocket messages for incoming messages
    _wsService.messages.listen(_handleWebSocketMessage);

    markInitialized();
    LogService().log('StationTransport: Initialized');
  }

  @override
  Future<void> dispose() async {
    LogService().log('StationTransport: Disposing...');
    await disposeMixin();
    LogService().log('StationTransport: Disposed');
  }

  @override
  Future<bool> canReach(String callsign) async {
    // Station transport can potentially reach any device if we're connected to a station
    // The actual delivery depends on whether the target device is also connected
    // We return true if we have a station connection, and let the send() handle failures
    final station = _stationService.getConnectedRelay();
    if (station == null) return false;

    // If we're connected to a station, we can attempt to reach any device
    // The station will return 404 if the device isn't connected
    return true;
  }

  @override
  Future<int> getQuality(String callsign) async {
    // Station quality is based on WebSocket connection health
    if (!_wsService.isConnected) return 0;

    // Check if device is connected to station
    final reachable = await canReach(callsign);
    if (!reachable) return 0;

    // Use metrics to estimate quality
    final latency = metrics.averageLatencyMs;
    if (latency == 0) return 70; // Default good quality

    // Score based on latency (lower = better)
    // < 100ms = 100, 100-500ms = 80-50, > 500ms = lower
    if (latency < 100) return 100;
    if (latency < 500) return 80 - ((latency - 100) / 10).toInt();
    return 30;
  }

  @override
  Future<TransportResult> send(
    TransportMessage message, {
    Duration? timeout,
  }) async {
    final effectiveTimeout = timeout ?? this.timeout;
    final stopwatch = Stopwatch()..start();

    try {
      // Check station connection
      final station = _stationService.getConnectedRelay();
      if (station == null) {
        return TransportResult.failure(
          error: 'No station connected',
          transportUsed: id,
        );
      }

      // Handle based on message type
      switch (message.type) {
        case TransportMessageType.apiRequest:
          return await _handleApiRequest(message, station.url, effectiveTimeout, stopwatch);

        case TransportMessageType.directMessage:
        case TransportMessageType.chatMessage:
          return await _handleMessageRelay(message, effectiveTimeout, stopwatch);

        case TransportMessageType.sync:
          return await _handleSync(message, station.url, effectiveTimeout, stopwatch);

        default:
          return TransportResult.failure(
            error: 'Unsupported message type for Station: ${message.type}',
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

  /// Handle API request messages via station proxy
  Future<TransportResult> _handleApiRequest(
    TransportMessage message,
    String stationUrl,
    Duration timeout,
    Stopwatch stopwatch,
  ) async {
    final httpUrl = _getStationHttpUrl(stationUrl);
    final targetCallsign = message.targetCallsign.toUpperCase();

    // Use the /{callsign}/api/* proxy format
    final uri = Uri.parse('$httpUrl/$targetCallsign${message.path}');
    final method = message.method?.toUpperCase() ?? 'GET';
    final headers = message.headers ?? {'Content-Type': 'application/json'};
    // payload may already be a JSON string (from DM API) - don't double-encode
    final body = message.payload != null
        ? (message.payload is String ? message.payload : jsonEncode(message.payload))
        : null;

    LogService().log('StationTransport: $method ${message.path} to $targetCallsign via station');

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

    // Check if response indicates success (2xx) or client handled error (4xx)
    // 5xx errors should be treated as transport failures to try next transport
    if (response.statusCode >= 500) {
      final result = TransportResult.failure(
        error: 'Station proxy error: ${response.statusCode}',
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

  /// Handle DM and chat message relay via WebSocket
  Future<TransportResult> _handleMessageRelay(
    TransportMessage message,
    Duration timeout,
    Stopwatch stopwatch,
  ) async {
    if (!_wsService.isConnected) {
      return TransportResult.failure(
        error: 'WebSocket not connected',
        transportUsed: id,
      );
    }

    // For DMs and chat, we relay the signed event through the station
    if (message.signedEvent == null) {
      return TransportResult.failure(
        error: 'No signed event for message relay',
        transportUsed: id,
      );
    }

    final eventId = message.signedEvent!['id'] as String?;
    if (eventId == null) {
      return TransportResult.failure(
        error: 'Signed event missing ID',
        transportUsed: id,
      );
    }

    LogService().log('StationTransport: Relaying ${message.type} to ${message.targetCallsign}');

    // Send via WebSocket and wait for OK
    final wsMessage = {
      'type': 'EVENT',
      'event': message.signedEvent,
    };

    final okResult = await _wsService.sendEventAndWaitForOk(
      wsMessage,
      eventId,
      timeout: timeout,
    );

    stopwatch.stop();

    if (okResult.success) {
      final result = TransportResult.success(
        transportUsed: id,
        latency: stopwatch.elapsed,
      );
      recordMetrics(result);
      return result;
    } else {
      final result = TransportResult.failure(
        error: okResult.message ?? 'Station rejected message',
        transportUsed: id,
      );
      recordMetrics(result);
      return result;
    }
  }

  /// Handle sync requests via station proxy
  Future<TransportResult> _handleSync(
    TransportMessage message,
    String stationUrl,
    Duration timeout,
    Stopwatch stopwatch,
  ) async {
    final httpUrl = _getStationHttpUrl(stationUrl);
    final targetCallsign = message.targetCallsign.toUpperCase();

    // Use station proxy for sync
    final uri = Uri.parse('$httpUrl/$targetCallsign/api/dm/sync/${message.targetCallsign}');

    LogService().log('StationTransport: Sync from $targetCallsign via station');

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
    // Fire and forget via WebSocket
    if (_wsService.isConnected && message.signedEvent != null) {
      _wsService.send({
        'type': 'EVENT',
        'event': message.signedEvent,
      });
    }
  }

  /// Handle incoming WebSocket messages and convert to TransportMessages
  void _handleWebSocketMessage(Map<String, dynamic> wsMessage) {
    try {
      final type = wsMessage['type'] as String?;

      // Handle relayed messages
      if (type == 'EVENT' || type == 'relay_message') {
        final event = wsMessage['event'] as Map<String, dynamic>?;
        if (event == null) return;

        // Extract sender from event tags
        String? senderCallsign;
        final tags = event['tags'] as List<dynamic>?;
        if (tags != null) {
          for (final tag in tags) {
            if (tag is List && tag.length >= 2 && tag[0] == 'callsign') {
              senderCallsign = tag[1] as String?;
              break;
            }
          }
        }

        if (senderCallsign != null) {
          final message = TransportMessage(
            id: event['id'] as String? ?? DateTime.now().millisecondsSinceEpoch.toString(),
            targetCallsign: senderCallsign,
            type: _determineMessageType(event),
            signedEvent: event,
          );
          emitIncomingMessage(message);
        }
      }

      // Handle device connection status updates (for logging/debugging)
      if (type == 'device_status') {
        final callsign = wsMessage['callsign'] as String?;
        final connected = wsMessage['connected'] as bool?;
        if (callsign != null && connected != null) {
          LogService().log('StationTransport: Device $callsign ${connected ? "connected" : "disconnected"}');
        }
      }
    } catch (e) {
      LogService().log('StationTransport: Error handling WebSocket message: $e');
    }
  }

  /// Determine message type from NOSTR event
  TransportMessageType _determineMessageType(Map<String, dynamic> event) {
    final kind = event['kind'] as int?;

    // NOSTR kinds:
    // 4 = Encrypted DM
    // 42 = Channel message
    // 30078 = Application-specific
    switch (kind) {
      case 4:
        return TransportMessageType.directMessage;
      case 42:
        return TransportMessageType.chatMessage;
      default:
        return TransportMessageType.chatMessage;
    }
  }

  /// Convert WebSocket URL to HTTP URL
  String _getStationHttpUrl(String wsUrl) {
    return wsUrl
        .replaceFirst('wss://', 'https://')
        .replaceFirst('ws://', 'http://');
  }

  /// Check if connected to a station
  bool get isConnectedToStation {
    return _stationService.getConnectedRelay() != null && _wsService.isConnected;
  }

  /// Get the currently connected station
  String? get connectedStationUrl {
    return _stationService.getConnectedRelay()?.url;
  }
}
