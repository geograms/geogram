/// BLE Transport - Bluetooth Low Energy communication
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:io' show Platform;
import '../../services/log_service.dart';
import '../../services/app_args.dart';
import '../../services/devices_service.dart';
import '../../services/ble_discovery_service.dart';
import '../../services/ble_message_service.dart';
import '../transport.dart';
import '../transport_message.dart';

/// Tracking info for a pending API request
class _PendingRequest {
  final Completer<TransportResult> completer;
  final Stopwatch stopwatch;

  _PendingRequest(this.completer, this.stopwatch);
}

/// BLE Transport for Bluetooth Low Energy communication
///
/// This transport has the lowest priority (40) as it:
/// - Is slow and has limited bandwidth
/// - Has limited range (~10-100 meters)
/// - Higher latency than LAN or internet
/// - Best used as offline fallback when no other transport is available
///
/// Platform Support:
/// - Android/iOS: Full support (GATT server + client)
/// - Linux/macOS/Windows: Client only
/// - Web: Not supported
class BleTransport extends Transport with TransportMixin {
  @override
  String get id => 'ble';

  @override
  String get name => 'Bluetooth';

  @override
  int get priority => 40; // Lowest priority - slow, use as last resort

  @override
  bool get isAvailable {
    // Not available on web or in internet-only mode
    if (kIsWeb) return false;
    if (AppArgs().internetOnly) return false;
    return true;
  }

  final BLEDiscoveryService _discoveryService = BLEDiscoveryService();
  final BLEMessageService _messageService = BLEMessageService();
  final DevicesService _devicesService = DevicesService();

  /// Pending API requests waiting for responses (requestId -> pending request info)
  final Map<String, _PendingRequest> _pendingRequests = {};

  /// Timeout for BLE operations
  final Duration timeout;

  /// Stream subscription for incoming messages
  StreamSubscription<BLEChatMessage>? _incomingSubscription;

  /// Stream subscription for incoming messages from GATT client (notifications from server)
  StreamSubscription<Map<String, dynamic>>? _clientNotificationSubscription;

  BleTransport({this.timeout = const Duration(seconds: 30)});

  @override
  Future<void> initialize() async {
    if (!isAvailable) {
      LogService().log('BleTransport: Not available on this platform');
      return;
    }

    LogService().log('BleTransport: [INIT] Starting initialization...');

    // Subscribe to incoming BLE messages from GATT server (we are server receiving from clients)
    _incomingSubscription = _messageService.incomingChats.listen(
      _handleIncomingMessage,
    );
    LogService().log(
      'BleTransport: [INIT] Subscribed to incomingChats (server mode)',
    );

    // Subscribe to incoming messages from GATT client (we are client receiving from server)
    _clientNotificationSubscription = _discoveryService.incomingChatsFromClient
        .listen((msg) {
          LogService().log(
            'BleTransport: [STREAM] Received message from incomingChatsFromClient stream',
          );
          _handleClientNotification(msg);
        });
    LogService().log(
      'BleTransport: [INIT] Subscribed to incomingChatsFromClient (client mode)',
    );

    markInitialized();
    LogService().log(
      'BleTransport: [INIT] Complete (server=${BLEMessageService.canBeServer}, client=${BLEMessageService.canBeClient})',
    );
  }

  @override
  Future<void> dispose() async {
    LogService().log('BleTransport: Disposing...');
    await _incomingSubscription?.cancel();
    _incomingSubscription = null;
    await _clientNotificationSubscription?.cancel();
    _clientNotificationSubscription = null;
    await disposeMixin();
    LogService().log('BleTransport: Disposed');
  }

  @override
  Future<bool> canReach(String callsign) async {
    if (!isInitialized) return false;

    final targetCallsign = callsign.toUpperCase();

    // An already-open BLE link should be treated as immediately reachable.
    if (_discoveryService.hasActiveConnectionForCallsign(targetCallsign)) {
      return true;
    }

    // Check if device is in BLE discovery list
    final devices = _discoveryService.getAllDevices();
    final seenInDiscovery = devices.any(
      (d) => d.callsign?.toUpperCase() == targetCallsign,
    );
    if (seenInDiscovery) {
      return true;
    }

    // If device metadata says BLE should work, run a short refresh scan and re-check.
    final known = _devicesService.getDevice(targetCallsign);
    if (_deviceSupportsBleOnly(known)) {
      // Avoid scan/connect contention when a BLE data link is already active.
      if (!_discoveryService.hasActiveConnections) {
        try {
          await _discoveryService.startScanning(
            timeout: const Duration(seconds: 3),
          );
        } catch (_) {
          // Ignore scan errors and fall back to current discovery cache.
        }
      }

      final refreshed = _discoveryService.getAllDevices();
      return refreshed.any((d) => d.callsign?.toUpperCase() == targetCallsign);
    }

    return false;
  }

  @override
  Future<int> getQuality(String callsign) async {
    if (!isInitialized) return 0;

    // Find device and use RSSI for quality estimation
    final devices = _discoveryService.getAllDevices();
    final device = devices
        .where((d) => d.callsign?.toUpperCase() == callsign.toUpperCase())
        .firstOrNull;

    if (device == null) return 0;

    // Convert RSSI to quality (0-100)
    // RSSI typically ranges from -30 (excellent) to -100 (poor)
    // -30 dBm = 100 quality
    // -100 dBm = 0 quality
    final rssi = device.rssi;
    final quality = ((rssi + 100) / 70 * 100).clamp(0, 100).toInt();

    return quality;
  }

  @override
  Future<TransportResult> send(
    TransportMessage message, {
    Duration? timeout,
  }) async {
    if (!isInitialized) {
      return TransportResult.failure(
        error: 'BLE transport not initialized',
        transportUsed: id,
      );
    }

    final stopwatch = Stopwatch()..start();

    try {
      // Check if device is reachable via BLE
      final canReachDevice = await canReach(message.targetCallsign);
      if (!canReachDevice) {
        return TransportResult.failure(
          error: 'Device ${message.targetCallsign} not in BLE range',
          transportUsed: id,
        );
      }

      // Handle based on message type
      switch (message.type) {
        case TransportMessageType.apiRequest:
          return await _handleApiRequest(message, stopwatch);

        case TransportMessageType.apiResponse:
          return await _handleApiResponse(message, stopwatch);

        case TransportMessageType.directMessage:
          return await _handleDirectMessage(message, stopwatch);

        case TransportMessageType.chatMessage:
          return await _handleChatMessage(message, stopwatch);

        case TransportMessageType.hello:
        case TransportMessageType.ping:
          return await _handleHelloOrPing(message, stopwatch);

        default:
          return TransportResult.failure(
            error: 'Unsupported message type for BLE: ${message.type}',
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
  ///
  /// BLE doesn't natively support HTTP-style requests, so we encode
  /// the request as a JSON message and send via BLE chat channel.
  /// The response is correlated using a Completer that waits for the
  /// response to come back on the _api_response channel.
  Future<TransportResult> _handleApiRequest(
    TransportMessage message,
    Stopwatch stopwatch,
  ) async {
    LogService().log(
      'BleTransport: [API-REQ] START ${message.method} ${message.path} to ${message.targetCallsign}',
    );
    LogService().log('BleTransport: [API-REQ] Request ID: ${message.id}');

    // Create a Completer to track this request
    final completer = Completer<TransportResult>();
    _pendingRequests[message.id] = _PendingRequest(completer, stopwatch);
    LogService().log(
      'BleTransport: [API-REQ] Added to pending requests. Total pending: ${_pendingRequests.length}',
    );

    // Encode API request as JSON payload
    final requestPayload = jsonEncode({
      'type': 'api_request',
      'id': message.id,
      'method': message.method,
      'path': message.path,
      'headers': message.headers,
      'body': message.payload,
    });

    LogService().log(
      'BleTransport: [API-REQ] Payload size: ${requestPayload.length} bytes',
    );

    // Send via BLE using a special channel for API requests
    LogService().log('BleTransport: [API-REQ] Calling sendChatToCallsign...');
    final success = await _messageService.sendChatToCallsign(
      targetCallsign: message.targetCallsign,
      content: requestPayload,
      channel: '_api', // Special channel for API messages
    );

    LogService().log(
      'BleTransport: [API-REQ] sendChatToCallsign returned: $success',
    );

    if (!success) {
      _pendingRequests.remove(message.id);
      stopwatch.stop();
      LogService().log('BleTransport: [API-REQ] FAILED - BLE send failed');
      final result = TransportResult.failure(
        error: 'BLE send failed',
        transportUsed: id,
      );
      recordMetrics(result);
      return result;
    }

    // Wait for response with timeout
    LogService().log(
      'BleTransport: [API-REQ] Send OK, waiting for response (timeout: ${timeout.inSeconds}s)...',
    );
    try {
      final result = await completer.future.timeout(timeout);
      LogService().log('BleTransport: [API-REQ] SUCCESS - Got response');
      recordMetrics(result);
      return result;
    } on TimeoutException {
      _pendingRequests.remove(message.id);
      stopwatch.stop();
      LogService().log(
        'BleTransport: [API-REQ] TIMEOUT after ${timeout.inSeconds}s for ${message.id}',
      );
      LogService().log(
        'BleTransport: [API-REQ] Remaining pending: ${_pendingRequests.keys.toList()}',
      );
      final result = TransportResult.failure(
        error: 'BLE API request timeout',
        transportUsed: id,
      );
      recordMetrics(result);
      return result;
    }
  }

  /// Handle API response messages - send back to requester via BLE
  Future<TransportResult> _handleApiResponse(
    TransportMessage message,
    Stopwatch stopwatch,
  ) async {
    // The payload is already JSON-encoded in ConnectionManager._sendApiResponse
    final content = message.payload is String
        ? message.payload as String
        : jsonEncode(message.payload);

    LogService().log(
      'BleTransport: Sending API response to ${message.targetCallsign}',
    );

    // Send via BLE using a special channel for API responses
    final success = await _messageService.sendChatToCallsign(
      targetCallsign: message.targetCallsign,
      content: content,
      channel: '_api_response', // Special channel for API response messages
    );

    stopwatch.stop();

    if (success) {
      final result = TransportResult.success(
        transportUsed: id,
        latency: stopwatch.elapsed,
      );
      recordMetrics(result);
      return result;
    } else {
      final result = TransportResult.failure(
        error: 'BLE API response send failed',
        transportUsed: id,
      );
      recordMetrics(result);
      return result;
    }
  }

  /// Handle direct message
  Future<TransportResult> _handleDirectMessage(
    TransportMessage message,
    Stopwatch stopwatch,
  ) async {
    if (message.signedEvent == null) {
      return TransportResult.failure(
        error: 'No signed event for BLE DM',
        transportUsed: id,
      );
    }

    LogService().log('BleTransport: DM to ${message.targetCallsign}');

    // Send the signed event via BLE
    final success = await _messageService.sendChatToCallsign(
      targetCallsign: message.targetCallsign,
      content: jsonEncode(message.signedEvent),
      channel: '_dm', // Special channel for DMs
      signature: message.signedEvent!['sig'] as String?,
      npub: message.signedEvent!['pubkey'] as String?,
    );

    stopwatch.stop();

    if (success) {
      final result = TransportResult.success(
        transportUsed: id,
        latency: stopwatch.elapsed,
      );
      recordMetrics(result);
      return result;
    } else {
      final result = TransportResult.failure(
        error: 'BLE DM send failed',
        transportUsed: id,
      );
      recordMetrics(result);
      return result;
    }
  }

  /// Handle chat message
  Future<TransportResult> _handleChatMessage(
    TransportMessage message,
    Stopwatch stopwatch,
  ) async {
    final roomId = message.path ?? 'general';

    LogService().log(
      'BleTransport: Chat to ${message.targetCallsign} room=$roomId',
    );

    // Send chat via BLE
    final content = message.signedEvent != null
        ? jsonEncode(message.signedEvent)
        : jsonEncode(message.payload);

    final success = await _messageService.sendChatToCallsign(
      targetCallsign: message.targetCallsign,
      content: content,
      channel: roomId,
      signature: message.signedEvent?['sig'] as String?,
      npub: message.signedEvent?['pubkey'] as String?,
    );

    stopwatch.stop();

    if (success) {
      final result = TransportResult.success(
        transportUsed: id,
        latency: stopwatch.elapsed,
      );
      recordMetrics(result);
      return result;
    } else {
      final result = TransportResult.failure(
        error: 'BLE chat send failed',
        transportUsed: id,
      );
      recordMetrics(result);
      return result;
    }
  }

  /// Handle hello/ping messages
  Future<TransportResult> _handleHelloOrPing(
    TransportMessage message,
    Stopwatch stopwatch,
  ) async {
    final content = jsonEncode({
      'type': message.type == TransportMessageType.hello ? 'hello' : 'ping',
      'timestamp': DateTime.now().toIso8601String(),
    });

    final success = await _messageService.sendChatToCallsign(
      targetCallsign: message.targetCallsign,
      content: content,
      channel: '_system',
    );

    stopwatch.stop();

    if (success) {
      final result = TransportResult.success(
        transportUsed: id,
        latency: stopwatch.elapsed,
      );
      recordMetrics(result);
      return result;
    } else {
      final result = TransportResult.failure(
        error: 'BLE ${message.type} failed',
        transportUsed: id,
      );
      recordMetrics(result);
      return result;
    }
  }

  @override
  Future<void> sendAsync(TransportMessage message) async {
    // Fire and forget
    send(message);
  }

  /// Handle incoming BLE messages and convert to TransportMessages
  void _handleIncomingMessage(BLEChatMessage bleMessage) {
    try {
      // Determine message type from channel
      TransportMessageType type;
      switch (bleMessage.channel) {
        case '_dm':
          type = TransportMessageType.directMessage;
          break;
        case '_api':
          type = TransportMessageType.apiRequest;
          break;
        case '_api_response':
          type = TransportMessageType.apiResponse;
          break;
        case '_system':
          type = TransportMessageType.ping;
          break;
        default:
          type = TransportMessageType.chatMessage;
      }

      // Try to parse content as JSON for signed events
      Map<String, dynamic>? signedEvent;
      dynamic payload = bleMessage.content;
      try {
        final parsed = jsonDecode(bleMessage.content);
        if (parsed is Map<String, dynamic>) {
          if (parsed.containsKey('sig') && parsed.containsKey('pubkey')) {
            signedEvent = parsed;
          } else {
            payload = parsed;
          }
        }
      } catch (_) {
        // Not JSON, use raw content
      }

      // Handle API responses - complete pending request and don't emit as incoming message
      if (type == TransportMessageType.apiResponse &&
          payload is Map &&
          payload['type'] == 'api_response') {
        final requestId = payload['id']?.toString();
        if (requestId != null) {
          final pendingRequest = _pendingRequests.remove(requestId);
          if (pendingRequest != null) {
            pendingRequest.stopwatch.stop();
            final statusCode = payload['statusCode'] as int? ?? 200;
            final body = payload['body'];
            LogService().log(
              'BleTransport: Received API response for request $requestId (status: $statusCode)',
            );
            pendingRequest.completer.complete(
              TransportResult.success(
                transportUsed: id,
                statusCode: statusCode,
                responseData: body,
                latency: pendingRequest.stopwatch.elapsed,
              ),
            );
            return; // Don't emit as incoming message
          } else {
            LogService().log(
              'BleTransport: Received API response for unknown request $requestId',
            );
          }
        }
        return; // Don't emit orphan API responses
      }

      TransportMessage message;
      if (type == TransportMessageType.apiRequest &&
          payload is Map &&
          payload['type'] == 'api_request') {
        final headers = <String, String>{};
        if (payload['headers'] is Map) {
          (payload['headers'] as Map).forEach((key, value) {
            if (key == null || value == null) return;
            headers[key.toString()] = value.toString();
          });
        }
        message = TransportMessage(
          id:
              payload['id']?.toString() ??
              'ble-${bleMessage.timestamp.millisecondsSinceEpoch}-${bleMessage.deviceId}',
          targetCallsign: bleMessage.author,
          type: TransportMessageType.apiRequest,
          method: payload['method']?.toString(),
          path: payload['path']?.toString(),
          headers: headers.isEmpty ? null : headers,
          payload: payload['body'],
          sourceTransportId: id,
        );
      } else {
        message = TransportMessage(
          id: 'ble-${bleMessage.timestamp.millisecondsSinceEpoch}-${bleMessage.deviceId}',
          targetCallsign: bleMessage.author,
          type: type,
          path: bleMessage.channel,
          payload: payload,
          signedEvent: signedEvent,
          sourceTransportId: id,
        );
      }

      emitIncomingMessage(message);

      // Also register the device
      registerDevice(
        bleMessage.author,
        metadata: {
          'deviceId': bleMessage.deviceId,
          'npub': bleMessage.npub,
          'source': 'ble',
        },
      );
    } catch (e) {
      LogService().log('BleTransport: Error handling incoming message: $e');
    }
  }

  /// Handle incoming notifications from GATT client connections
  /// This is called when we (as GATT client) receive notifications from a GATT server
  void _handleClientNotification(Map<String, dynamic> message) {
    try {
      final deviceId = message['_deviceId'] as String?;
      final messageType = message['type'] as String?;
      final messageId = message['id'] as String?;

      LogService().log(
        'BleTransport: Client notification received (type=$messageType, id=$messageId, deviceId=$deviceId)',
      );

      // Handle API responses
      if (messageType == 'api_response' && messageId != null) {
        final pendingRequest = _pendingRequests.remove(messageId);
        if (pendingRequest != null) {
          pendingRequest.stopwatch.stop();
          final statusCode = message['statusCode'] as int? ?? 200;
          final body = message['body'];
          LogService().log(
            'BleTransport: Completed pending API request $messageId (status: $statusCode)',
          );
          pendingRequest.completer.complete(
            TransportResult.success(
              transportUsed: id,
              statusCode: statusCode,
              responseData: body,
              latency: pendingRequest.stopwatch.elapsed,
            ),
          );
          return;
        } else {
          LogService().log(
            'BleTransport: No pending request for API response $messageId (pending: ${_pendingRequests.keys.toList()})',
          );
        }
      }

      // For non-API messages, we could emit them as incoming messages
      // but for now just log them
      LogService().log(
        'BleTransport: Unhandled client notification type: $messageType',
      );
    } catch (e) {
      LogService().log('BleTransport: Error handling client notification: $e');
    }
  }

  /// Get all discovered BLE devices
  List<BLEDevice> get discoveredDevices => _discoveryService.getAllDevices();

  /// Get device by callsign
  BLEDevice? getDevice(String callsign) {
    final devices = _discoveryService.getAllDevices();
    return devices
        .where((d) => d.callsign?.toUpperCase() == callsign.toUpperCase())
        .firstOrNull;
  }

  /// Check if BLE is scanning
  bool get isScanning => _discoveryService.isScanning;

  /// Start BLE scanning
  Future<void> startScanning() async {
    if (_discoveryService.isScanning) return;
    await _discoveryService.startScanning();
    LogService().log('BleTransport: Started scanning');
  }

  /// Stop BLE scanning
  Future<void> stopScanning() async {
    await _discoveryService.stopScanning();
    LogService().log('BleTransport: Stopped scanning');
  }

  bool _deviceSupportsBleOnly(RemoteDevice? device) {
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

  /// Check if platform supports GATT server (Android/iOS)
  static bool get supportsGattServer {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS;
  }

  /// Check if platform supports GATT client (all non-web)
  static bool get supportsGattClient {
    return !kIsWeb;
  }
}
