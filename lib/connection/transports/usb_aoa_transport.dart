/// USB AOA Transport - Android Open Accessory communication
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:io' show Platform;
import '../../services/log_service.dart';
import '../../services/app_args.dart';
import '../../services/security_service.dart';
import '../../services/usb_aoa_service.dart';
import '../../services/app_service.dart';
import '../transport.dart';
import '../transport_message.dart';

/// Tracking info for a pending API request
class _PendingRequest {
  final Completer<TransportResult> completer;
  final Stopwatch stopwatch;

  _PendingRequest(this.completer, this.stopwatch);
}

/// USB AOA Transport for device-to-device communication
///
/// This transport has the highest priority (5) as it:
/// - Is the fastest transport (USB 2.0 High-Speed: ~30-40 MB/s)
/// - Most reliable (wired connection, no interference)
/// - Zero configuration required
/// - Works offline
///
/// Platform Support:
/// - Android: Accessory mode (receives connection from Linux/Android host)
/// - Linux: Host mode (initiates AOA handshake to Android device)
/// - Other platforms: Not supported
class UsbAoaTransport extends Transport with TransportMixin {
  @override
  String get id => 'usb_aoa';

  @override
  String get name => 'USB';

  @override
  int get priority => 5; // Highest priority - fastest and most reliable

  @override
  bool get isAvailable {
    // Not available on web or in internet-only mode
    if (kIsWeb) return false;
    if (AppArgs().internetOnly) return false;
    if (SecurityService().bleOnlyMode) return false;
    // USB AOA: Android (accessory) + Linux (host)
    return Platform.isAndroid || Platform.isLinux;
  }

  final UsbAoaService _usbService = UsbAoaService();

  /// Pending API requests waiting for responses (requestId -> pending request info)
  final Map<String, _PendingRequest> _pendingRequests = {};

  /// Timeout for USB operations
  final Duration timeout;

  /// Buffer for accumulating incoming data (for message framing)
  final List<int> _receiveBuffer = [];

  /// Stream subscription for incoming data
  StreamSubscription<Uint8List>? _dataSubscription;

  /// Stream subscription for connection state
  StreamSubscription<UsbAoaConnectionState>? _connectionSubscription;

  /// Stream subscription for channel ready events (Linux only)
  StreamSubscription<void>? _channelReadySubscription;

  /// Timer for hello retry mechanism
  Timer? _helloRetryTimer;

  /// Count of hello retry attempts
  int _helloRetryCount = 0;

  /// Avoid echoing hello forever on an already-established USB link.
  DateTime? _lastHelloReplyAt;
  DateTime? _lastHelloSentAt;
  static const Duration _helloReplyCooldown = Duration(seconds: 10);
  static const Duration _helloSendDebounce = Duration(milliseconds: 500);
  bool _accessoryHelloSentForConnection = false;

  bool get _shouldRetryHello => Platform.isLinux;

  void _sendAccessoryStartupHello() {
    if (_shouldRetryHello || _accessoryHelloSentForConnection) {
      return;
    }
    _accessoryHelloSentForConnection = true;
    _sendHello();
  }

  UsbAoaTransport({this.timeout = const Duration(seconds: 30)});

  @override
  Future<void> initialize() async {
    if (!isAvailable) {
      LogService().log('UsbAoaTransport: Not available on this platform');
      return;
    }

    LogService().log('UsbAoaTransport: [INIT] Starting initialization...');

    // IMPORTANT: Subscribe to streams BEFORE initializing the USB service.
    // On Android, the native plugin may already be connected and sending data
    // during initialization. Broadcast streams don't buffer, so we must listen first.
    _dataSubscription = _usbService.dataStream.listen(_handleIncomingData);
    LogService().log('UsbAoaTransport: [INIT] Subscribed to data stream');

    // Subscribe to connection state changes
    _connectionSubscription = _usbService.connectionStateStream.listen((state) {
      LogService().log('UsbAoaTransport: Connection state changed to $state');
      if (state == UsbAoaConnectionState.connected) {
        if (_shouldRetryHello) {
          // Linux is the USB host and owns the retry loop. Android may come up
          // much earlier while Linux is still compiling/starting, so letting both
          // sides retry builds up a large backlog of stale hello packets.
          LogService().log(
            'UsbAoaTransport: Connected on host side, waiting for channel ready before hello',
          );
          _startHelloRetry();
        } else {
          LogService().log(
            'UsbAoaTransport: Connected on accessory side, sending a single startup hello',
          );
          _sendAccessoryStartupHello();
        }
      } else if (state == UsbAoaConnectionState.disconnected) {
        // Stop hello retry on disconnect
        _stopHelloRetry();
        _lastHelloReplyAt = null;
        _lastHelloSentAt = null;
        _accessoryHelloSentForConnection = false;
        // Clear pending requests on disconnect
        for (final pending in _pendingRequests.values) {
          pending.stopwatch.stop();
          pending.completer.complete(
            TransportResult.failure(
              error: 'USB connection lost',
              transportUsed: id,
            ),
          );
        }
        _pendingRequests.clear();
        _receiveBuffer.clear();
      }
    });
    LogService().log('UsbAoaTransport: [INIT] Subscribed to connection state');

    // Subscribe to channel ready events (Linux only - fires when Android opens accessory)
    _channelReadySubscription = _usbService.channelReadyStream.listen((_) {
      LogService().log('UsbAoaTransport: Channel ready, sending hello');
      _sendHello();
    });
    LogService().log(
      'UsbAoaTransport: [INIT] Subscribed to channel ready stream',
    );

    // Now initialize the USB AOA service (after subscriptions are set up)
    await _usbService.initialize();
    LogService().log('UsbAoaTransport: [INIT] USB service initialized');

    // Check if already connected (connection may have happened during/after initialization)
    if (_usbService.connectionState == UsbAoaConnectionState.connected) {
      if (_shouldRetryHello) {
        LogService().log(
          'UsbAoaTransport: [INIT] Already connected on host side, sending hello',
        );
        _sendHello();
        _startHelloRetry();
      } else {
        LogService().log(
          'UsbAoaTransport: [INIT] Already connected on accessory side, sending single hello',
        );
        _sendAccessoryStartupHello();
      }
    }

    markInitialized();
    LogService().log('UsbAoaTransport: [INIT] Complete');
  }

  @override
  Future<void> dispose() async {
    LogService().log('UsbAoaTransport: Disposing...');
    _stopHelloRetry();
    await _dataSubscription?.cancel();
    _dataSubscription = null;
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    await _channelReadySubscription?.cancel();
    _channelReadySubscription = null;
    await _usbService.dispose();
    await disposeMixin();
    LogService().log('UsbAoaTransport: Disposed');
  }

  @override
  Future<bool> canReach(String callsign) async {
    if (!isInitialized) {
      LogService().log(
        'UsbAoaTransport: canReach($callsign) = false (not initialized)',
      );
      return false;
    }

    // If USB is connected but handshake is incomplete, allow routing anyway.
    // Messages will be buffered/queued in USB and delivered once handshake completes.
    // This prevents DMs from bypassing USB during the handshake window.
    final remoteCallsign = _usbService.remoteCallsign;
    if (remoteCallsign == null) {
      // Check if USB is physically connected even though handshake is incomplete
      if (_usbService.isConnected) {
        LogService().log(
          'UsbAoaTransport: canReach($callsign) = true (USB connected, handshake pending)',
        );
        return true;
      }
      LogService().log(
        'UsbAoaTransport: canReach($callsign) = false (not connected)',
      );
      return false;
    }

    final matches = remoteCallsign.toUpperCase() == callsign.toUpperCase();
    LogService().log(
      'UsbAoaTransport: canReach($callsign) = $matches (remoteCallsign=$remoteCallsign)',
    );
    return matches;
  }

  @override
  Future<int> getQuality(String callsign) async {
    if (!isInitialized) return 0;

    // USB is always excellent quality when connected
    if (await canReach(callsign)) {
      return 100; // Perfect quality - wired connection
    }
    return 0;
  }

  @override
  Future<TransportResult> send(
    TransportMessage message, {
    Duration? timeout,
  }) async {
    if (!isInitialized) {
      return TransportResult.failure(
        error: 'USB AOA transport not initialized',
        transportUsed: id,
      );
    }

    if (!_usbService.isConnected) {
      return TransportResult.failure(
        error: 'USB not connected',
        transportUsed: id,
      );
    }

    final stopwatch = Stopwatch()..start();

    try {
      // Check if device is reachable via USB
      final canReachDevice = await canReach(message.targetCallsign);
      if (!canReachDevice) {
        return TransportResult.failure(
          error: 'Device ${message.targetCallsign} not connected via USB',
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
            error: 'Unsupported message type for USB: ${message.type}',
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

  /// Send a JSON envelope over USB
  Future<bool> _sendEnvelope(String channel, dynamic content) async {
    final envelope = jsonEncode({
      'channel': channel,
      'content': content is String ? content : jsonEncode(content),
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });

    // Add length prefix for message framing (4 bytes, big-endian)
    final bytes = utf8.encode(envelope);
    final lengthBytes = Uint8List(4)
      ..buffer.asByteData().setUint32(0, bytes.length, Endian.big);

    final framedData = Uint8List(4 + bytes.length);
    framedData.setRange(0, 4, lengthBytes);
    framedData.setRange(4, 4 + bytes.length, bytes);

    return await _usbService.write(framedData);
  }

  /// Send hello message with our callsign
  Future<void> _sendHello({bool isReply = false}) async {
    try {
      final now = DateTime.now();
      if (_lastHelloSentAt != null &&
          now.difference(_lastHelloSentAt!) < _helloSendDebounce) {
        return;
      }
      final callsign = AppService().currentCallsign;
      if (callsign == null || callsign.isEmpty) {
        LogService().log('UsbAoaTransport: No active callsign to send');
        return;
      }

      LogService().log(
        'UsbAoaTransport: Sending ${isReply ? 'hello reply' : 'hello'} with callsign $callsign',
      );
      final success = await _sendEnvelope('_hello', {'callsign': callsign});
      if (success) {
        _lastHelloSentAt = now;
        LogService().log('UsbAoaTransport: Hello sent successfully');
      } else {
        LogService().log('UsbAoaTransport: Failed to send hello');
      }
    } catch (e) {
      LogService().log('UsbAoaTransport: Error sending hello: $e');
    }
  }

  /// Start periodic hello retry mechanism
  ///
  /// Android may take 16+ seconds to open the USB accessory after Linux connects.
  /// The initial hello is sent immediately but may be lost if Android isn't ready.
  /// This retry mechanism sends hello every 2 seconds until Android responds.
  void _startHelloRetry() {
    _helloRetryCount = 0;
    _helloRetryTimer?.cancel();
    _helloRetryTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_usbService.remoteCallsign != null) {
        // Handshake complete, stop retrying
        _stopHelloRetry();
        return;
      }
      _helloRetryCount++;
      LogService().log(
        'UsbAoaTransport: Hello retry #$_helloRetryCount (no response yet)',
      );
      _sendHello();

      // Give up after 30 retries (60 seconds)
      if (_helloRetryCount >= 30) {
        LogService().log(
          'UsbAoaTransport: Hello retry limit reached, giving up',
        );
        _stopHelloRetry();
      }
    });
  }

  /// Stop hello retry mechanism
  void _stopHelloRetry() {
    _helloRetryTimer?.cancel();
    _helloRetryTimer = null;
    if (_helloRetryCount > 0) {
      LogService().log(
        'UsbAoaTransport: Hello retry stopped after $_helloRetryCount attempts',
      );
    }
    _helloRetryCount = 0;
  }

  /// Public method to restart hello retry mechanism (for debugging)
  void restartHelloRetry() {
    LogService().log(
      'UsbAoaTransport: Restarting hello retry (manual trigger)',
    );
    _stopHelloRetry();
    _sendHello();
    _startHelloRetry();
  }

  /// Handle API request messages
  Future<TransportResult> _handleApiRequest(
    TransportMessage message,
    Stopwatch stopwatch,
  ) async {
    LogService().log(
      'UsbAoaTransport: [API-REQ] START ${message.method} ${message.path}',
    );
    LogService().log('UsbAoaTransport: [API-REQ] Request ID: ${message.id}');

    // Create a Completer to track this request
    final completer = Completer<TransportResult>();
    _pendingRequests[message.id] = _PendingRequest(completer, stopwatch);
    LogService().log(
      'UsbAoaTransport: [API-REQ] Added to pending requests. Total: ${_pendingRequests.length}',
    );

    // Encode API request as JSON payload
    final requestPayload = {
      'type': 'api_request',
      'id': message.id,
      'method': message.method,
      'path': message.path,
      'headers': message.headers,
      'body': message.payload,
    };

    LogService().log('UsbAoaTransport: [API-REQ] Sending envelope...');
    final success = await _sendEnvelope('_api', requestPayload);

    if (!success) {
      _pendingRequests.remove(message.id);
      stopwatch.stop();
      LogService().log('UsbAoaTransport: [API-REQ] FAILED - USB send failed');
      final result = TransportResult.failure(
        error: 'USB send failed',
        transportUsed: id,
      );
      recordMetrics(result);
      return result;
    }

    // Wait for response with timeout
    LogService().log(
      'UsbAoaTransport: [API-REQ] Send OK, waiting for response...',
    );
    try {
      final result = await completer.future.timeout(timeout);
      LogService().log('UsbAoaTransport: [API-REQ] SUCCESS - Got response');
      recordMetrics(result);
      return result;
    } on TimeoutException {
      _pendingRequests.remove(message.id);
      stopwatch.stop();
      LogService().log('UsbAoaTransport: [API-REQ] TIMEOUT for ${message.id}');
      final result = TransportResult.failure(
        error: 'USB API request timeout',
        transportUsed: id,
      );
      recordMetrics(result);
      return result;
    }
  }

  /// Handle API response messages
  Future<TransportResult> _handleApiResponse(
    TransportMessage message,
    Stopwatch stopwatch,
  ) async {
    final content = message.payload is String
        ? message.payload as String
        : jsonEncode(message.payload);

    LogService().log('UsbAoaTransport: Sending API response');

    final success = await _sendEnvelope('_api_response', content);

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
        error: 'USB API response send failed',
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
        error: 'No signed event for USB DM',
        transportUsed: id,
      );
    }

    LogService().log('UsbAoaTransport: DM to ${message.targetCallsign}');

    final success = await _sendEnvelope('_dm', message.signedEvent);

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
        error: 'USB DM send failed',
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
      'UsbAoaTransport: Chat to ${message.targetCallsign} room=$roomId',
    );

    final content = message.signedEvent ?? message.payload;
    final success = await _sendEnvelope(roomId, content);

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
        error: 'USB chat send failed',
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
    final content = {
      'type': message.type == TransportMessageType.hello ? 'hello' : 'ping',
      'timestamp': DateTime.now().toIso8601String(),
    };

    final success = await _sendEnvelope('_system', content);

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
        error: 'USB ${message.type} failed',
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

  /// Handle incoming USB data and convert to TransportMessages
  void _handleIncomingData(Uint8List data) {
    try {
      LogService().log(
        'UsbAoaTransport: [RECV] Got ${data.length} bytes from USB',
      );
      // Add to receive buffer
      _receiveBuffer.addAll(data);

      // Guard against corrupted length prefix causing unbounded buffering
      // If the buffer grows beyond 1MB, something went wrong — reset it
      if (_receiveBuffer.length > 1024 * 1024) {
        LogService().log(
          'UsbAoaTransport: Receive buffer overflow (${_receiveBuffer.length} bytes), resetting',
        );
        _receiveBuffer.clear();
        return;
      }

      // Process complete messages from buffer
      while (_receiveBuffer.length >= 4) {
        // Read length prefix (4 bytes, big-endian)
        final lengthBytes = Uint8List.fromList(_receiveBuffer.sublist(0, 4));
        final length = lengthBytes.buffer.asByteData().getUint32(0, Endian.big);

        // Sanity check: reject absurdly large messages (> 512KB)
        if (length > 512 * 1024) {
          LogService().log(
            'UsbAoaTransport: Invalid message length ($length bytes), resetting buffer',
          );
          _receiveBuffer.clear();
          return;
        }

        // Check if we have the complete message
        if (_receiveBuffer.length < 4 + length) {
          break; // Wait for more data
        }

        // Extract message
        final messageBytes = _receiveBuffer.sublist(4, 4 + length);
        _receiveBuffer.removeRange(0, 4 + length);

        try {
          final messageStr = utf8.decode(messageBytes);
          final envelope = jsonDecode(messageStr) as Map<String, dynamic>;
          _processEnvelope(envelope);
        } catch (e) {
          LogService().log('UsbAoaTransport: Error processing message: $e');
        }
      }
    } catch (e) {
      LogService().log(
        'UsbAoaTransport: Unhandled error in _handleIncomingData: $e',
      );
      // Don't let buffer corruption propagate — reset and continue
      _receiveBuffer.clear();
    }
  }

  /// Process a received JSON envelope
  void _processEnvelope(Map<String, dynamic> envelope) {
    try {
      final channel = envelope['channel'] as String?;
      final contentStr = envelope['content'] as String?;

      if (channel == null || contentStr == null) {
        LogService().log(
          'UsbAoaTransport: Invalid envelope - missing channel or content',
        );
        return;
      }

      dynamic content;
      try {
        content = jsonDecode(contentStr);
      } catch (_) {
        content = contentStr;
      }

      // Determine message type from channel
      TransportMessageType type;
      switch (channel) {
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
        case '_hello':
          // Handle callsign exchange
          if (content is Map && content['callsign'] != null) {
            final remoteCallsign = content['callsign'].toString();
            final previousCallsign = _usbService.remoteCallsign;
            _usbService.setRemoteCallsign(remoteCallsign);
            LogService().log(
              'UsbAoaTransport: Received hello from $remoteCallsign',
            );
            _stopHelloRetry(); // Stop retrying - handshake successful

            final now = DateTime.now();
            final shouldReply =
                previousCallsign == null ||
                previousCallsign.toUpperCase() !=
                    remoteCallsign.toUpperCase() ||
                _lastHelloReplyAt == null ||
                now.difference(_lastHelloReplyAt!) >= _helloReplyCooldown;
            if (shouldReply) {
              _lastHelloReplyAt = now;
              LogService().log('UsbAoaTransport: Sending hello reply...');
              _sendHello(isReply: true);
            }
          }
          return; // Don't emit hello messages
        default:
          type = TransportMessageType.chatMessage;
      }

      // Handle API responses - complete pending request
      if (type == TransportMessageType.apiResponse && content is Map) {
        final responseData = content['type'] == 'api_response'
            ? content
            : {'type': 'api_response', ...content};

        final requestId = responseData['id']?.toString();
        if (requestId != null) {
          final pendingRequest = _pendingRequests.remove(requestId);
          if (pendingRequest != null) {
            pendingRequest.stopwatch.stop();
            final statusCode = responseData['statusCode'] as int? ?? 200;
            final body = responseData['body'];
            LogService().log(
              'UsbAoaTransport: Received API response for $requestId (status: $statusCode)',
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
          }
        }
        return; // Don't emit orphan API responses
      }

      // Try to parse content for signed events
      Map<String, dynamic>? signedEvent;
      dynamic payload = content;
      if (content is Map<String, dynamic>) {
        if (content.containsKey('sig') && content.containsKey('pubkey')) {
          signedEvent = content;
        } else {
          payload = content;
        }
      }

      // Build TransportMessage for API requests
      TransportMessage message;
      if (type == TransportMessageType.apiRequest && content is Map) {
        final headers = <String, String>{};
        if (content['headers'] is Map) {
          (content['headers'] as Map).forEach((key, value) {
            if (key == null || value == null) return;
            headers[key.toString()] = value.toString();
          });
        }
        message = TransportMessage(
          id:
              content['id']?.toString() ??
              'usb-${DateTime.now().millisecondsSinceEpoch}',
          targetCallsign: _usbService.remoteCallsign ?? 'USB',
          type: TransportMessageType.apiRequest,
          method: content['method']?.toString(),
          path: content['path']?.toString(),
          headers: headers.isEmpty ? null : headers,
          payload: content['body'],
          sourceTransportId: id,
        );
      } else {
        message = TransportMessage(
          id: 'usb-${DateTime.now().millisecondsSinceEpoch}',
          targetCallsign: _usbService.remoteCallsign ?? 'USB',
          type: type,
          path: channel,
          payload: payload,
          signedEvent: signedEvent,
          sourceTransportId: id,
        );
      }

      emitIncomingMessage(message);

      // Register the device if we know their callsign
      final remoteCallsign = _usbService.remoteCallsign;
      if (remoteCallsign != null) {
        registerDevice(
          remoteCallsign,
          metadata: {
            'source': 'usb',
            'manufacturer': _usbService.accessoryInfo?.manufacturer,
            'model': _usbService.accessoryInfo?.model,
          },
        );
      }
    } catch (e) {
      LogService().log('UsbAoaTransport: Error in _processEnvelope: $e');
    }
  }

  /// Check if USB is currently connected
  bool get isUsbConnected => _usbService.isConnected;

  /// Get the USB service for direct access
  UsbAoaService get usbService => _usbService;
}
