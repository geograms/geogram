library;

import 'dart:async';
import 'dart:convert';

import '../../services/log_service.dart';
import '../../services/peer_relay_service.dart';
import '../transport.dart';
import '../transport_message.dart';

class PeerRelayTransport extends Transport with TransportMixin {
  @override
  String get id => 'peer_relay';

  @override
  String get name => 'Peer Relay';

  @override
  int get priority => 27;

  final PeerRelayService _relayService = PeerRelayService();
  final Map<String, _PendingRequest> _pendingRequests = {};
  StreamSubscription<PeerRelayEnvelope>? _incomingSubscription;

  @override
  bool get isAvailable => true;

  @override
  Future<void> initialize() async {
    await _relayService.initialize();
    _incomingSubscription = _relayService.transportEnvelopes.listen(
      _handleIncomingEnvelope,
    );
    markInitialized();
    LogService().log('PeerRelayTransport: Initialized');
  }

  @override
  Future<void> dispose() async {
    await _incomingSubscription?.cancel();
    _incomingSubscription = null;
    for (final pending in _pendingRequests.values) {
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(
          StateError('Peer relay transport disposed'),
        );
      }
    }
    _pendingRequests.clear();
    await disposeMixin();
    LogService().log('PeerRelayTransport: Disposed');
  }

  @override
  Future<bool> canReach(String callsign) async {
    final info = getDeviceInfo(callsign);
    if (info == null) return false;
    return _relayService.canRelayTo(callsign);
  }

  @override
  Future<int> getQuality(String callsign) async {
    final reachable = await canReach(callsign);
    return reachable ? 45 : 0;
  }

  @override
  Future<TransportResult> send(
    TransportMessage message, {
    Duration? timeout,
  }) async {
    final effectiveTimeout = timeout ?? const Duration(seconds: 30);
    final stopwatch = Stopwatch()..start();

    try {
      switch (message.type) {
        case TransportMessageType.apiRequest:
          return await _sendApiRequest(message, effectiveTimeout, stopwatch);
        case TransportMessageType.apiResponse:
          return await _sendSimpleEnvelope(message, stopwatch);
        case TransportMessageType.directMessage:
        case TransportMessageType.chatMessage:
          return await _sendSimpleEnvelope(message, stopwatch);
        default:
          stopwatch.stop();
          final result = TransportResult.failure(
            error: 'Unsupported peer relay message type: ${message.type.name}',
            transportUsed: id,
          );
          recordMetrics(result);
          return result;
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

  @override
  Future<void> sendAsync(TransportMessage message) async {
    await send(message);
  }

  void registerRelayDevice(
    String callsign, {
    String? npub,
    bool canRelay = false,
    String? relayUrl,
  }) {
    registerDevice(
      callsign,
      url: relayUrl,
      metadata: {
        'source': 'peer_relay',
        'npub': npub,
        'can_relay': canRelay,
        'relay_url': relayUrl,
      },
    );
  }

  Future<TransportResult> _sendApiRequest(
    TransportMessage message,
    Duration timeout,
    Stopwatch stopwatch,
  ) async {
    if (message.payload is List<int>) {
      stopwatch.stop();
      final result = TransportResult.failure(
        error: 'Peer relay does not support binary API payloads yet',
        transportUsed: id,
      );
      recordMetrics(result);
      return result;
    }

    final completer = Completer<TransportResult>();
    _pendingRequests[message.id] = _PendingRequest(
      completer: completer,
      stopwatch: stopwatch,
    );

    final sent = await _relayService.sendTransportMessage(message);
    if (!sent) {
      _pendingRequests.remove(message.id);
      stopwatch.stop();
      final result = TransportResult.failure(
        error: 'No peer relay accepted request for ${message.targetCallsign}',
        transportUsed: id,
      );
      recordMetrics(result);
      return result;
    }

    try {
      final result = await completer.future.timeout(
        timeout,
        onTimeout: () {
          _pendingRequests.remove(message.id);
          stopwatch.stop();
          return TransportResult.failure(
            error: 'Peer relay timed out for ${message.targetCallsign}',
            transportUsed: id,
          );
        },
      );
      recordMetrics(result);
      return result;
    } catch (e) {
      _pendingRequests.remove(message.id);
      stopwatch.stop();
      final result = TransportResult.failure(
        error: e.toString(),
        transportUsed: id,
      );
      recordMetrics(result);
      return result;
    }
  }

  Future<TransportResult> _sendSimpleEnvelope(
    TransportMessage message,
    Stopwatch stopwatch,
  ) async {
    if (message.payload is List<int>) {
      stopwatch.stop();
      final result = TransportResult.failure(
        error: 'Peer relay does not support binary payloads yet',
        transportUsed: id,
      );
      recordMetrics(result);
      return result;
    }

    final sent = await _relayService.sendTransportMessage(message);
    stopwatch.stop();
    if (!sent) {
      final result = TransportResult.failure(
        error: 'No peer relay accepted message for ${message.targetCallsign}',
        transportUsed: id,
      );
      recordMetrics(result);
      return result;
    }

    final result = TransportResult.success(
      statusCode: 202,
      transportUsed: id,
      latency: stopwatch.elapsed,
    );
    recordMetrics(result);
    return result;
  }

  void _handleIncomingEnvelope(PeerRelayEnvelope envelope) {
    try {
      final transportTypeName = envelope.transportType;
      if (transportTypeName == null) return;
      final transportType = TransportMessageType.values.firstWhere(
        (value) => value.name == transportTypeName,
      );

      if (transportType == TransportMessageType.apiResponse) {
        final requestId = envelope.requestId;
        if (requestId == null) return;

        final pending = _pendingRequests.remove(requestId);
        if (pending == null || pending.completer.isCompleted) {
          return;
        }

        final payload = _decodeResponsePayload(envelope.payload);
        pending.stopwatch.stop();
        pending.completer.complete(
          TransportResult.success(
            statusCode: payload.statusCode,
            responseData: payload.body,
            transportUsed: id,
            latency: pending.stopwatch.elapsed,
          ),
        );
        return;
      }

      final message = TransportMessage(
        id: envelope.requestId ?? envelope.id,
        targetCallsign: envelope.fromCallsign,
        type: transportType,
        method: envelope.method,
        path: envelope.path,
        headers: envelope.headers,
        payload: envelope.payload,
        signedEvent: envelope.signedEvent,
        sourceTransportId: id,
      );
      emitIncomingMessage(message);
    } catch (e) {
      LogService().log('PeerRelayTransport: Error handling envelope: $e');
    }
  }

  _ApiResponsePayload _decodeResponsePayload(dynamic payload) {
    if (payload is Map<String, dynamic>) {
      final statusCode = payload['statusCode'] as int? ?? 200;
      return _ApiResponsePayload(
        statusCode: statusCode,
        body: payload['body'],
      );
    }

    if (payload is Map) {
      final normalized = payload.map(
        (key, value) => MapEntry(key.toString(), value),
      );
      final statusCode = normalized['statusCode'] as int? ?? 200;
      return _ApiResponsePayload(
        statusCode: statusCode,
        body: normalized['body'],
      );
    }

    if (payload is String && payload.isNotEmpty) {
      try {
        final decoded = jsonDecode(payload);
        if (decoded is Map) {
          final normalized = decoded.map(
            (key, value) => MapEntry(key.toString(), value),
          );
          final statusCode = normalized['statusCode'] as int? ?? 200;
          return _ApiResponsePayload(
            statusCode: statusCode,
            body: normalized['body'],
          );
        }
      } catch (_) {}
    }

    return _ApiResponsePayload(statusCode: 200, body: payload);
  }
}

class _PendingRequest {
  final Completer<TransportResult> completer;
  final Stopwatch stopwatch;

  const _PendingRequest({
    required this.completer,
    required this.stopwatch,
  });
}

class _ApiResponsePayload {
  final int statusCode;
  final dynamic body;

  const _ApiResponsePayload({
    required this.statusCode,
    required this.body,
  });
}
