/// WebRTC Transport - Direct P2P communication via NAT traversal
library;

import 'dart:async';
import '../../services/log_service.dart';
import '../../services/security_service.dart';
import '../../services/devices_service.dart';
import '../../services/webrtc_peer_manager.dart';
import '../../services/webrtc_signaling_service.dart';
import '../transport.dart';
import '../transport_message.dart';

/// WebRTC Transport for direct peer-to-peer communication
///
/// This transport has medium-high priority (15) as it provides:
/// - Direct P2P connection (no relay bandwidth costs)
/// - Low latency once connected
/// - Works across NAT/firewalls (via STUN/ICE)
///
/// But requires:
/// - A signaling path (station WebSocket or DHT rendezvous)
/// - Initial connection setup time
/// - STUN/TURN or favorable NAT behavior for cross-network peers
class WebRTCTransport extends Transport with TransportMixin {
  @override
  String get id => 'webrtc';

  @override
  String get name => 'Peer-to-Peer';

  @override
  int get priority => 15; // Between LAN (10) and Station (30)

  @override
  bool get isAvailable {
    if (SecurityService().bleOnlyMode) return false;
    return true;
  }

  final WebRTCPeerManager _peerManager = WebRTCPeerManager();
  final WebRTCSignalingService _signalingService = WebRTCSignalingService();
  final DevicesService _devicesService = DevicesService();

  /// Timeout for connection establishment
  final Duration connectionTimeout;

  /// Timeout for message sending
  final Duration sendTimeout;

  /// Subscription to peer manager messages
  StreamSubscription<WebRTCMessage>? _messageSubscription;

  WebRTCTransport({
    this.connectionTimeout = const Duration(seconds: 15),
    this.sendTimeout = const Duration(seconds: 10),
  });

  @override
  Future<void> initialize() async {
    LogService().log('WebRTCTransport: Initializing...');

    // Initialize peer manager
    await _peerManager.initialize();

    // Listen for incoming messages and convert to TransportMessages
    _messageSubscription = _peerManager.messages.listen(_handleIncomingMessage);

    markInitialized();
    LogService().log('WebRTCTransport: Initialized');
  }

  @override
  Future<void> dispose() async {
    LogService().log('WebRTCTransport: Disposing...');

    _messageSubscription?.cancel();
    await _peerManager.dispose();
    await disposeMixin();

    LogService().log('WebRTCTransport: Disposed');
  }

  @override
  Future<bool> canReach(String callsign) async {
    final normalizedCallsign = callsign.toUpperCase();

    // Skip WebRTC attempts when device is currently known as BLE-only.
    if (_isBleOnlyDevice(normalizedCallsign)) {
      return false;
    }

    // Check if we already have an active WebRTC connection
    if (_peerManager.hasActiveConnection(normalizedCallsign)) {
      return true;
    }

    return _signalingService.canSignalPeer(normalizedCallsign);
  }

  bool _isBleOnlyDevice(String callsign) {
    final device = _devicesService.getDevice(callsign);
    if (device == null || device.connectionMethods.isEmpty) {
      return false;
    }

    final methods = device.connectionMethods
        .map((m) => m.toLowerCase())
        .toSet();
    final hasBle = methods.any(
      (m) => m == 'bluetooth' || m == 'ble' || m == 'ble+' || m == 'ble_plus',
    );
    final hasNonBle = methods.any(
      (m) => m != 'bluetooth' && m != 'ble' && m != 'ble+' && m != 'ble_plus',
    );
    return hasBle && !hasNonBle;
  }

  @override
  Future<int> getQuality(String callsign) async {
    final normalizedCallsign = callsign.toUpperCase();

    // If connected, WebRTC has high quality (direct P2P)
    if (_peerManager.hasActiveConnection(normalizedCallsign)) {
      // Use metrics if available
      final latency = metrics.averageLatencyMs;
      if (latency == 0) return 90; // Default high quality

      // Score based on latency
      if (latency < 50) return 100;
      if (latency < 100) return 95;
      if (latency < 200) return 85;
      if (latency < 500) return 70;
      return 50;
    }

    // Not connected yet - medium quality (connection pending)
    return 50;
  }

  @override
  Future<TransportResult> send(
    TransportMessage message, {
    Duration? timeout,
  }) async {
    final stopwatch = Stopwatch()..start();

    try {
      final callsign = message.targetCallsign.toUpperCase();

      // Avoid signaling when there is no way to exchange offers/answers/ICE.
      if (!_peerManager.hasActiveConnection(callsign) &&
          !_signalingService.canSignalPeer(callsign)) {
        stopwatch.stop();
        final result = TransportResult.failure(
          error: 'WebRTC signaling unavailable for $callsign',
          transportUsed: id,
        );
        recordMetrics(result);
        return result;
      }

      // Ensure we have a WebRTC connection
      final connected = await _peerManager
          .ensureConnection(callsign)
          .timeout(connectionTimeout, onTimeout: () => false);

      if (!connected) {
        stopwatch.stop();
        final result = TransportResult.failure(
          error: 'Failed to establish WebRTC connection to $callsign',
          transportUsed: id,
        );
        recordMetrics(result);
        return result;
      }

      // Convert TransportMessage to WebRTC message format
      final webrtcPayload = _buildPayload(message);

      // Send via WebRTC data channel
      final sent = await _peerManager.sendMessage(
        callsign,
        message.type.name,
        webrtcPayload,
        messageId: message.id,
      );

      stopwatch.stop();

      if (!sent) {
        final result = TransportResult.failure(
          error: 'Failed to send message via WebRTC to $callsign',
          transportUsed: id,
        );
        recordMetrics(result);
        return result;
      }

      // For WebRTC, we don't have request/response semantics
      // We just send the message and assume success
      // The response will come as a separate message if needed
      final result = TransportResult.success(
        statusCode: 200,
        responseData: null,
        transportUsed: id,
        latency: stopwatch.elapsed,
      );
      recordMetrics(result);

      LogService().log(
        'WebRTCTransport: Sent ${message.type} to $callsign '
        '(${stopwatch.elapsed.inMilliseconds}ms)',
      );

      return result;
    } catch (e) {
      stopwatch.stop();
      LogService().log(
        'WebRTCTransport: Error sending to ${message.targetCallsign}: $e',
      );

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
    // Fire and forget via WebRTC
    final callsign = message.targetCallsign.toUpperCase();

    // Try to use existing connection, don't wait for new connection
    if (!_peerManager.hasActiveConnection(callsign)) {
      LogService().log(
        'WebRTCTransport: No active connection for async send to $callsign',
      );
      return;
    }

    final webrtcPayload = _buildPayload(message);
    await _peerManager.sendMessage(
      callsign,
      message.type.name,
      webrtcPayload,
      messageId: message.id,
    );
  }

  /// Build payload for WebRTC message from TransportMessage
  Map<String, dynamic> _buildPayload(TransportMessage message) {
    final payload = <String, dynamic>{'message_type': message.type.name};

    switch (message.type) {
      case TransportMessageType.apiRequest:
        payload['method'] = message.method;
        payload['path'] = message.path;
        payload['headers'] = message.headers;
        payload['body'] = message.payload;
        break;

      case TransportMessageType.directMessage:
        payload['signed_event'] = message.signedEvent;
        break;

      case TransportMessageType.chatMessage:
        payload['room'] = message.payload?['room'];
        payload['content'] = message.payload?['content'];
        payload['signed_event'] = message.signedEvent;
        break;

      case TransportMessageType.sync:
        payload['sync_data'] = message.payload;
        break;

      default:
        payload['data'] = message.payload;
    }

    return payload;
  }

  /// Handle incoming WebRTC message and convert to TransportMessage
  void _handleIncomingMessage(WebRTCMessage message) {
    try {
      final payload = message.payload as Map<String, dynamic>?;
      if (payload == null) return;

      final messageTypeName =
          payload['message_type'] as String? ?? message.type;
      final messageType = TransportMessageType.values.firstWhere(
        (t) => t.name == messageTypeName,
        orElse: () => TransportMessageType.apiRequest,
      );

      TransportMessage transportMessage;

      switch (messageType) {
        case TransportMessageType.apiRequest:
          transportMessage = TransportMessage.apiRequest(
            targetCallsign: message.fromCallsign,
            method: payload['method'] as String? ?? 'GET',
            path: payload['path'] as String? ?? '/',
            headers: (payload['headers'] as Map<String, dynamic>?)
                ?.cast<String, String>(),
            body: payload['body'],
          );
          break;

        case TransportMessageType.directMessage:
          final dmEvent = payload['signed_event'] as Map<String, dynamic>?;
          if (dmEvent == null) {
            LogService().log('WebRTCTransport: DM missing signed_event');
            return;
          }
          transportMessage = TransportMessage.directMessage(
            targetCallsign: message.fromCallsign,
            signedEvent: dmEvent,
          );
          break;

        case TransportMessageType.chatMessage:
          final chatEvent = payload['signed_event'] as Map<String, dynamic>?;
          if (chatEvent == null) {
            LogService().log(
              'WebRTCTransport: Chat message missing signed_event',
            );
            return;
          }
          transportMessage = TransportMessage.chatMessage(
            targetCallsign: message.fromCallsign,
            roomId: payload['room'] as String? ?? 'general',
            signedEvent: chatEvent,
          );
          break;

        default:
          // Create a generic message using the base constructor
          transportMessage = TransportMessage(
            id:
                message.messageId ??
                DateTime.now().millisecondsSinceEpoch.toString(),
            targetCallsign: message.fromCallsign,
            type: messageType,
            payload: payload,
            sourceTransportId: id,
          );
      }

      emitIncomingMessage(
        transportMessage.sourceTransportId == null
            ? transportMessage.copyWith(sourceTransportId: id)
            : transportMessage,
      );
      LogService().log(
        'WebRTCTransport: Received ${messageType.name} from ${message.fromCallsign}',
      );
    } catch (e) {
      LogService().log('WebRTCTransport: Error handling incoming message: $e');
    }
  }

  /// Get list of connected peers
  List<String> get connectedPeers => _peerManager.connectedPeers;

  /// Check if connected to a specific peer
  bool isConnectedTo(String callsign) =>
      _peerManager.hasActiveConnection(callsign.toUpperCase());

  /// Close connection to a peer
  Future<void> closeConnection(String callsign) async {
    await _peerManager.closeConnection(callsign);
  }

  /// Get connection info for debugging
  Map<String, dynamic> getConnectionInfo(String callsign) =>
      _peerManager.getConnectionInfo(callsign);
}
