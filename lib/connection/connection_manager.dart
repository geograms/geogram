/// Connection Manager - Main entry point for transport-agnostic messaging
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:async/async.dart';
import 'package:http/http.dart' as http;
import '../models/monitored_task.dart';
import '../util/managed_http_client.dart';
import '../util/task_monitor_helpers.dart';
import '../services/log_service.dart';
import '../services/log_api_service.dart';
import '../services/power_aware_service.dart';
import '../transfer/services/p2p_transfer_service.dart';
import 'transport.dart';
import 'transport_message.dart';
import 'routing_strategy.dart';
import 'transports/lan_transport.dart';

/// Connection Manager singleton
///
/// Provides transport-agnostic device-to-device communication.
/// Automatically selects the best transport based on availability and priority.
///
/// Usage:
/// ```dart
/// // Initialize on app startup
/// await ConnectionManager().initialize();
///
/// // Send an API request
/// final result = await ConnectionManager().apiRequest(
///   callsign: 'X1ABCD',
///   method: 'GET',
///   path: '/api/status',
/// );
///
/// // Send a direct message
/// final dmResult = await ConnectionManager().sendDM(
///   callsign: 'X1ABCD',
///   signedEvent: signedNostrEvent,
/// );
/// ```
class ConnectionManager {
  static final ConnectionManager _instance = ConnectionManager._internal();
  factory ConnectionManager() => _instance;
  ConnectionManager._internal();

  /// Registered transports (id -> transport)
  final Map<String, Transport> _transports = {};

  /// Routing strategy for transport selection
  RoutingStrategy _routingStrategy = PriorityRoutingStrategy();

  /// Message queue for store-and-forward
  final Queue<TransportMessage> _messageQueue = Queue();

  /// Maximum queue size
  static const int _maxQueueSize = 1000;

  /// Whether the manager has been initialized
  bool _initialized = false;

  /// Stream controller for incoming messages
  StreamGroup<TransportMessage>? _incomingGroup;
  final _incomingController = StreamController<TransportMessage>.broadcast();

  /// Timer for processing queued messages
  MonitoredAsyncPeriodicTimer? _queueProcessTimer;

  /// Shared HTTP client for P2P forwarding (to localhost)
  final ManagedHttpClient _httpClient = ManagedHttpClient();

  /// Power-aware subscription
  StreamSubscription<PowerMode>? _powerSubscription;

  // ============================================================
  // Initialization
  // ============================================================

  /// Initialize the connection manager
  ///
  /// This must be called before using the manager.
  /// Transports should be registered before calling initialize.
  Future<void> initialize() async {
    if (_initialized) return;

    LogService().log('ConnectionManager: Initializing...');

    // Initialize all registered transports
    for (final transport in _transports.values) {
      try {
        await transport.initialize();
        LogService().log('ConnectionManager: Initialized transport: ${transport.id}');
      } catch (e) {
        LogService().log('ConnectionManager: Failed to initialize ${transport.id}: $e');
      }
    }

    // Set up incoming message stream
    _setupIncomingStream();

    // Start queue processor
    _startQueueProcessor();

    // Listen for power mode changes (mobile battery saving)
    _powerSubscription = PowerAwareService().onModeChanged.listen(_onPowerModeChanged);

    _initialized = true;
    LogService().log('ConnectionManager: Initialized with ${_transports.length} transports');
  }

  /// Dispose the connection manager
  Future<void> dispose() async {
    _queueProcessTimer?.cancel();
    _queueProcessTimer = null;
    _powerSubscription?.cancel();
    _powerSubscription = null;

    for (final transport in _transports.values) {
      try {
        await transport.dispose();
      } catch (e) {
        LogService().log('ConnectionManager: Error disposing ${transport.id}: $e');
      }
    }

    _httpClient.close();
    await _incomingGroup?.close();
    await _incomingController.close();

    _transports.clear();
    _messageQueue.clear();
    _initialized = false;
  }

  /// Check if initialized
  bool get isInitialized => _initialized;

  // ============================================================
  // Transport Management
  // ============================================================

  /// Register a transport
  ///
  /// Should be called before [initialize].
  void registerTransport(Transport transport) {
    _transports[transport.id] = transport;
    LogService().log('ConnectionManager: Registered transport: ${transport.id} '
        '(priority: ${transport.priority}, available: ${transport.isAvailable})');

    // If already initialized, initialize the new transport
    if (_initialized && !transport.isInitialized) {
      transport.initialize().then((_) {
        _setupIncomingStream(); // Rebuild stream with new transport
      });
    }
  }

  /// Unregister a transport
  void unregisterTransport(String transportId) {
    final transport = _transports.remove(transportId);
    if (transport != null) {
      transport.dispose();
      _setupIncomingStream();
      LogService().log('ConnectionManager: Unregistered transport: $transportId');
    }
  }

  /// Get a transport by ID
  Transport? getTransport(String id) => _transports[id];

  /// Get all registered transports
  List<Transport> get transports => _transports.values.toList();

  /// Runtime-disabled transport IDs (debug-only override). When a transport
  /// id is in this set the routing strategy treats it as unavailable —
  /// useful for forcing the serverless WebRTC/DHT path during testing
  /// even when LAN/USB would normally win on priority.
  final Set<String> _disabledTransports = <String>{};

  /// Disable a transport at runtime without unregistering it. Reversible
  /// via [enableTransport]. The transport stays initialized — only
  /// routing skips it.
  void disableTransport(String id) {
    _disabledTransports.add(id);
    LogService().log('ConnectionManager: transport "$id" disabled at runtime');
  }

  /// Re-enable a previously runtime-disabled transport.
  void enableTransport(String id) {
    if (_disabledTransports.remove(id)) {
      LogService().log('ConnectionManager: transport "$id" re-enabled');
    }
  }

  /// IDs of transports currently disabled at runtime.
  Set<String> get disabledTransportIds =>
      Set.unmodifiable(_disabledTransports);

  /// Get available transports (on this platform). Excludes any transport
  /// that has been runtime-disabled via [disableTransport].
  List<Transport> get availableTransports => _transports.values
      .where((t) => t.isAvailable && !_disabledTransports.contains(t.id))
      .toList();

  /// Set the routing strategy
  void setRoutingStrategy(RoutingStrategy strategy) {
    _routingStrategy = strategy;
    LogService().log('ConnectionManager: Routing strategy set to ${strategy.runtimeType}');
  }

  // ============================================================
  // Core Messaging API
  // ============================================================

  /// Send a message to a device
  ///
  /// Automatically selects the best transport based on routing strategy.
  /// If [queueIfOffline] is true on the message, queues for later delivery.
  Future<TransportResult> send(
    TransportMessage message, {
    RoutingStrategy? routingStrategy,
    Set<String>? excludeTransports,
  }) async {
    if (!_initialized) {
      return TransportResult.failure(error: 'ConnectionManager not initialized');
    }

    LogService().log('ConnectionManager: Sending ${message.type} to ${message.targetCallsign}');

    // Get ordered list of transports to try
    var transportsToTry = await (routingStrategy ?? _routingStrategy).selectTransports(
      callsign: message.targetCallsign,
      messageType: message.type,
      availableTransports: availableTransports,
    );

    if (excludeTransports != null && excludeTransports.isNotEmpty) {
      transportsToTry = transportsToTry
          .where((transport) => !excludeTransports.contains(transport.id))
          .toList();
    }

    if (transportsToTry.isEmpty) {
      if (message.queueIfOffline) {
        _enqueueMessage(message);
        return TransportResult.queued(transportUsed: 'queue');
      }
      return TransportResult.failure(
        error: 'No transport available for ${message.targetCallsign}',
      );
    }

    // Try each transport in order
    for (final transport in transportsToTry) {
      try {
        LogService().log('ConnectionManager: Trying ${transport.id}...');
        final result = await transport.send(message);

        if (result.success) {
          LogService().log('ConnectionManager: Success via ${transport.id} '
              '(${result.latency?.inMilliseconds ?? "?"}ms)');
          return result;
        }

        LogService().log('ConnectionManager: ${transport.id} failed: ${result.error}');
      } catch (e) {
        LogService().log('ConnectionManager: ${transport.id} exception: $e');
      }
    }

    // All transports failed
    if (message.queueIfOffline) {
      _enqueueMessage(message);
      return TransportResult.queued(transportUsed: 'queue');
    }

    return TransportResult.failure(
      error: 'All transports failed for ${message.targetCallsign}',
    );
  }

  /// Make an API request to a device
  ///
  /// Convenience method for HTTP-style requests.
  Future<TransportResult> apiRequest({
    required String callsign,
    required String method,
    required String path,
    Map<String, String>? headers,
    dynamic body,
    bool queueIfOffline = false,
    Duration timeout = const Duration(seconds: 30),
    RoutingStrategy? routingStrategy,
    Set<String>? excludeTransports,
  }) {
    final message = TransportMessage.apiRequest(
      targetCallsign: callsign,
      method: method,
      path: path,
      headers: headers,
      body: body,
      queueIfOffline: queueIfOffline,
    );

    return send(
      message,
      routingStrategy: routingStrategy,
      excludeTransports: excludeTransports,
    );
  }

  /// Streaming variant of [apiRequest]. The request body and the response
  /// body are both [Stream]s, so neither side has to buffer the full
  /// payload in memory. Currently implemented only for [LanTransport]
  /// (LAN HTTP); other transports cannot stream — for non-LAN paths,
  /// callers must fall back to bulk [apiRequest].
  ///
  /// Returns null if no LAN transport can reach the callsign.
  Future<LanStreamingResult?> streamingApiRequest({
    required String callsign,
    required String method,
    required String path,
    Map<String, String>? headers,
    Stream<List<int>>? bodyStream,
    int? bodyStreamLength,
    Duration? timeout,
  }) async {
    final lan = _transports['lan'];
    if (lan is! LanTransport) return null;
    if (!lan.isAvailable) return null;
    // Don't call lan.canReach() here — it does an HTTP GET to
    // /api/status with a 3 s timeout, and the Shared sync engine
    // already verified reachability once at the top of _syncFolder.
    // Re-checking on every file inside a 200-file folder pull
    // serialized the sync into a 200×{0.1-3 s} crawl.
    return lan.sendStreaming(
      callsign: callsign,
      method: method,
      path: path,
      headers: headers,
      bodyStream: bodyStream,
      bodyStreamLength: bodyStreamLength,
      timeout: timeout,
    );
  }

  /// Send a direct message
  ///
  /// Convenience method for sending NOSTR-signed DMs.
  Future<TransportResult> sendDM({
    required String callsign,
    required Map<String, dynamic> signedEvent,
    bool queueIfOffline = false,
    Duration? ttl,
  }) {
    final message = TransportMessage.directMessage(
      targetCallsign: callsign,
      signedEvent: signedEvent,
      queueIfOffline: queueIfOffline,
      ttl: ttl,
    );

    return send(message);
  }

  /// Send a chat message
  ///
  /// Convenience method for room-based chat.
  Future<TransportResult> sendChat({
    required String callsign,
    required String roomId,
    required Map<String, dynamic> signedEvent,
    bool queueIfOffline = false,
  }) {
    final message = TransportMessage.chatMessage(
      targetCallsign: callsign,
      roomId: roomId,
      signedEvent: signedEvent,
      queueIfOffline: queueIfOffline,
    );

    return send(message);
  }

  // ============================================================
  // Reachability
  // ============================================================

  /// Check if a device is reachable via any transport
  Future<bool> isReachable(String callsign) async {
    if (!_initialized) return false;

    for (final transport in availableTransports) {
      try {
        if (await transport.canReach(callsign).timeout(
          const Duration(seconds: 2),
          onTimeout: () => false,
        )) {
          return true;
        }
      } catch (_) {
        // Continue to next transport
      }
    }

    return false;
  }

  /// Get list of transports that can reach a device
  Future<List<String>> getAvailableTransports(String callsign) async {
    if (!_initialized) return [];

    final result = <String>[];

    for (final transport in availableTransports) {
      try {
        if (await transport.canReach(callsign).timeout(
          const Duration(seconds: 2),
          onTimeout: () => false,
        )) {
          result.add(transport.id);
        }
      } catch (_) {
        // Continue to next transport
      }
    }

    return result;
  }

  // ============================================================
  // Incoming Messages
  // ============================================================

  /// Stream of incoming messages from all transports
  Stream<TransportMessage> get incomingMessages => _incomingController.stream;

  void _setupIncomingStream() {
    // Close existing group
    _incomingGroup?.close();

    // Create new group with all transport streams
    final streams = _transports.values
        .where((t) => t.isAvailable && t.isInitialized)
        .map((t) => t.incomingMessages)
        .toList();

    if (streams.isEmpty) return;

    _incomingGroup = StreamGroup<TransportMessage>();
    for (final stream in streams) {
      _incomingGroup!.add(stream);
    }

    _incomingGroup!.stream.listen(
      (message) {
        // Handle incoming messages (e.g., forward API requests to local server)
        _handleIncomingMessage(message);

        if (!_incomingController.isClosed) {
          _incomingController.add(message);
        }
      },
      onError: (e) {
        LogService().log('ConnectionManager: Incoming stream error: $e');
      },
    );
  }

  /// Handle incoming message from a transport
  ///
  /// Processes incoming API requests by forwarding them to the local HTTP server.
  /// This enables P2P communication (WebRTC, BLE) to work with the same API
  /// as station-proxied requests.
  Future<void> _handleIncomingMessage(TransportMessage message) async {
    LogService().log('ConnectionManager: Received ${message.type.name} from ${message.targetCallsign}');

    switch (message.type) {
      case TransportMessageType.apiRequest:
        await _handleApiRequest(message);
        break;
      case TransportMessageType.directMessage:
        // DM handling - forward to local chat API
        await _handleDirectMessage(message);
        break;
      default:
        // Other message types are handled by subscribers to incomingMessages
        break;
    }
  }

  /// Handle incoming API request by forwarding to local HTTP server
  Future<void> _handleApiRequest(TransportMessage message) async {
    final method = message.method ?? 'GET';
    final path = message.path ?? '/';

    // Only process /api/* requests
    if (!path.startsWith('/api/')) {
      LogService().log('ConnectionManager: Ignoring non-API request: $path');
      return;
    }

    int statusCode = 500;
    String responseBody = '';

    try {
      final localPort = LogApiService().port;

      // Guard: don't forward if the local API server isn't running yet
      if (localPort <= 0) {
        LogService().log('ConnectionManager: Local API server not ready (port=$localPort), returning 503');
        statusCode = 503;
        responseBody = jsonEncode({'error': 'Local API server not ready'});
        await _sendApiResponse(
          requestId: message.id,
          targetCallsign: message.targetCallsign,
          statusCode: statusCode,
          body: responseBody,
          sourceTransportId: message.sourceTransportId,
        );
        return;
      }

      final uri = Uri.parse('http://localhost:$localPort$path');

      // Prepare headers
      final headers = <String, String>{};
      if (message.headers != null) {
        headers.addAll(message.headers!);
      }
      if (!headers.containsKey('Content-Type')) {
        headers['Content-Type'] = message.payload is List<int>
            ? 'application/octet-stream'
            : 'application/json';
      }

      // Prepare body
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

      // Make request to local server
      http.Response response;
      switch (method.toUpperCase()) {
        case 'GET':
          response = await _httpClient.get(uri, headers: headers).timeout(const Duration(seconds: 25));
          break;
        case 'POST':
          response = await _httpClient.post(uri, headers: headers, body: body).timeout(const Duration(seconds: 25));
          break;
        case 'PUT':
          response = await _httpClient.put(uri, headers: headers, body: body).timeout(const Duration(seconds: 25));
          break;
        case 'DELETE':
          response = await _httpClient.delete(uri, headers: headers).timeout(const Duration(seconds: 25));
          break;
        default:
          response = await _httpClient.get(uri, headers: headers).timeout(const Duration(seconds: 25));
      }

      statusCode = response.statusCode;
      responseBody = response.body;

      LogService().log('ConnectionManager: Forwarded P2P request $method $path -> ${response.statusCode}');
    } catch (e) {
      LogService().log('ConnectionManager: Error forwarding P2P API request: $e');
      responseBody = jsonEncode({'error': e.toString()});
    }

    // Send response back to requester via the same transport it arrived on
    try {
      await _sendApiResponse(
        requestId: message.id,
        targetCallsign: message.targetCallsign,
        statusCode: statusCode,
        body: responseBody,
        sourceTransportId: message.sourceTransportId,
      );
    } catch (e) {
      LogService().log('ConnectionManager: Error sending API response back: $e');
    }
  }

  /// Send API response back to the requester
  ///
  /// Prefers the transport the request arrived on ([sourceTransportId]) so that
  /// transports with request/response correlation (BLE, WebRTC, USB) receive
  /// the response on the same channel. Falls back to any reachable transport.
  Future<void> _sendApiResponse({
    required String requestId,
    required String targetCallsign,
    required int statusCode,
    required String body,
    String? sourceTransportId,
  }) async {
    // Encode response as JSON payload
    final responsePayload = jsonEncode({
      'type': 'api_response',
      'id': requestId,
      'statusCode': statusCode,
      'body': body,
    });

    // Create response message
    final responseMessage = TransportMessage(
      id: 'response-$requestId',
      targetCallsign: targetCallsign,
      type: TransportMessageType.apiResponse,
      payload: responsePayload,
    );

    // If we know which transport the request arrived on, try that first
    if (sourceTransportId != null) {
      final sourceTransport = availableTransports
          .where((t) => t.id == sourceTransportId)
          .firstOrNull;
      if (sourceTransport != null) {
        try {
          final canReachDevice = await sourceTransport.canReach(targetCallsign).timeout(
            const Duration(seconds: 2),
            onTimeout: () => false,
          );
          if (canReachDevice) {
            await sourceTransport.sendAsync(responseMessage);
            LogService().log('ConnectionManager: Sent API response to $targetCallsign via ${sourceTransport.id} (source transport)');
            return;
          }
        } catch (e) {
          LogService().log('ConnectionManager: Error sending response via source transport ${sourceTransport.id}: $e');
        }
      }
    }

    // Fall back to any transport that can reach the requester
    for (final transport in availableTransports) {
      if (transport.id == sourceTransportId) continue; // Already tried
      try {
        final canReachDevice = await transport.canReach(targetCallsign).timeout(
          const Duration(seconds: 2),
          onTimeout: () => false,
        );
        if (canReachDevice) {
          await transport.sendAsync(responseMessage);
          LogService().log('ConnectionManager: Sent API response to $targetCallsign via ${transport.id}');
          return;
        }
      } catch (e) {
        LogService().log('ConnectionManager: Error sending response via ${transport.id}: $e');
      }
    }

    LogService().log('ConnectionManager: No transport available to send API response to $targetCallsign');
  }

  /// Handle incoming direct message
  ///
  /// Forwards the signed event to the local chat API for processing.
  /// The sender's callsign becomes the room ID (DM conversation identifier).
  /// Also handles P2P transfer messages (offer, response, progress, complete).
  Future<void> _handleDirectMessage(TransportMessage message) async {
    final senderCallsign = message.targetCallsign;
    LogService().log('ConnectionManager: Received DM from $senderCallsign');

    if (message.signedEvent == null) {
      LogService().log('ConnectionManager: DM has no signed event, ignoring');
      return;
    }

    // Check if this is a P2P transfer message
    try {
      final content = message.signedEvent!['content'] as String?;
      if (content != null) {
        final decoded = jsonDecode(content) as Map<String, dynamic>;
        final messageType = decoded['type'] as String?;

        if (messageType != null) {
          final handled = await _handleP2PTransferMessage(messageType, decoded);
          if (handled) return;
        }
      }
    } catch (_) {
      // Not a P2P message, continue with normal DM handling
    }

    try {
      // Forward to local chat API: POST /api/chat/{senderCallsign}/messages
      // The roomId (path param) is the sender's callsign for DM conversations
      final localPort = LogApiService().port;
      final path = '/api/chat/$senderCallsign/messages';
      final uri = Uri.parse('http://localhost:$localPort$path');

      final body = jsonEncode({
        'event': message.signedEvent,
      });

      LogService().log('ConnectionManager: Forwarding DM to local API: POST $path');

      final response = await _httpClient.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: body,
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        LogService().log('ConnectionManager: DM delivered to local chat API');
      } else {
        LogService().log(
          'ConnectionManager: DM delivery failed: ${response.statusCode} - ${response.body}',
        );
      }
    } catch (e) {
      LogService().log('ConnectionManager: Error forwarding DM: $e');
    }
  }

  /// Handle P2P transfer messages
  ///
  /// Routes transfer_offer, transfer_response, transfer_progress, and
  /// transfer_complete messages to the P2PTransferService.
  Future<bool> _handleP2PTransferMessage(
    String messageType,
    Map<String, dynamic> data,
  ) async {
    final p2pService = P2PTransferService();

    switch (messageType) {
      case 'transfer_offer':
        LogService().log('ConnectionManager: Routing transfer_offer to P2PTransferService');
        p2pService.handleIncomingOffer(data);
        return true;

      case 'transfer_response':
        LogService().log('ConnectionManager: Routing transfer_response to P2PTransferService');
        p2pService.handleTransferResponse(data);
        return true;

      case 'transfer_progress':
        LogService().log('ConnectionManager: Routing transfer_progress to P2PTransferService');
        p2pService.handleProgressUpdate(data);
        return true;

      case 'transfer_complete':
        LogService().log('ConnectionManager: Routing transfer_complete to P2PTransferService');
        p2pService.handleTransferComplete(data);
        return true;

      default:
        return false;
    }
  }

  // ============================================================
  // Message Queue (Store-and-Forward)
  // ============================================================

  /// Get pending messages in the queue
  List<TransportMessage> get pendingMessages => _messageQueue.toList();

  /// Number of pending messages
  int get pendingCount => _messageQueue.length;

  /// Manually retry sending queued messages
  Future<void> retryPending() async {
    if (_messageQueue.isEmpty) return;

    LogService().log('ConnectionManager: Retrying ${_messageQueue.length} queued messages');

    final toRetry = _messageQueue.toList();
    _messageQueue.clear();

    for (final message in toRetry) {
      // Skip expired messages
      if (message.isExpired) {
        LogService().log('ConnectionManager: Dropping expired message ${message.id}');
        continue;
      }

      // Re-send (without queueIfOffline to avoid infinite loop)
      final nonQueuedMessage = message.copyWith(queueIfOffline: false);
      final result = await send(nonQueuedMessage);

      if (!result.success && !result.wasQueued) {
        // Re-queue if still failing and not expired
        if (!message.isExpired) {
          _messageQueue.add(message);
        }
      }
    }
  }

  void _enqueueMessage(TransportMessage message) {
    // Enforce max queue size (drop oldest)
    while (_messageQueue.length >= _maxQueueSize) {
      final dropped = _messageQueue.removeFirst();
      LogService().log('ConnectionManager: Queue full, dropping ${dropped.id}');
    }

    _messageQueue.add(message);
    LogService().log('ConnectionManager: Queued message ${message.id} '
        '(queue size: ${_messageQueue.length})');
  }

  void _startQueueProcessor() {
    _queueProcessTimer?.cancel();

    // Process queue every 30 seconds
    _queueProcessTimer = MonitoredAsyncPeriodicTimer(
      id: 'connection_manager.queue',
      name: 'Connection Queue',
      description: 'Processes pending message delivery queue',
      serviceName: 'ConnectionManager',
      interval: const Duration(seconds: 30),
      priority: TaskPriority.critical,
      callback: (_) async => await _processQueue(),
    );
  }

  /// Adjust queue processing interval based on power mode.
  void _onPowerModeChanged(PowerMode mode) {
    _queueProcessTimer?.cancel();
    _queueProcessTimer = null;

    final Duration interval;
    switch (mode) {
      case PowerMode.foreground:
        interval = const Duration(seconds: 30);
        break;
      case PowerMode.background:
        interval = const Duration(seconds: 60);
        break;
      case PowerMode.doze:
        interval = const Duration(seconds: 120);
        break;
    }

    _queueProcessTimer = MonitoredAsyncPeriodicTimer(
      id: 'connection_manager.queue',
      name: 'Connection Queue',
      description: 'Processes pending message delivery queue',
      serviceName: 'ConnectionManager',
      interval: interval,
      priority: TaskPriority.critical,
      callback: (_) async => await _processQueue(),
    );
    LogService().log('ConnectionManager: ${mode.name} — queue interval ${interval.inSeconds}s');
  }

  Future<void> _processQueue() async {
    if (_messageQueue.isEmpty) return;

    // Remove expired messages
    _messageQueue.removeWhere((m) {
      if (m.isExpired) {
        LogService().log('ConnectionManager: Removing expired message ${m.id}');
        return true;
      }
      return false;
    });

    // Try to send queued messages
    if (_messageQueue.isNotEmpty) {
      await retryPending();
    }
  }

  // ============================================================
  // Utility
  // ============================================================

  /// Get metrics summary for all transports
  Map<String, TransportMetrics> get allMetrics {
    return Map.fromEntries(
      _transports.entries.map((e) => MapEntry(e.key, e.value.metrics)),
    );
  }

  /// Log current state
  void logStatus() {
    LogService().log('ConnectionManager Status:');
    LogService().log('  Initialized: $_initialized');
    LogService().log('  Transports: ${_transports.length}');
    for (final transport in _transports.values) {
      LogService().log('    - ${transport.id}: '
          'available=${transport.isAvailable}, '
          'initialized=${transport.isInitialized}, '
          'priority=${transport.priority}');
    }
    LogService().log('  Queue size: ${_messageQueue.length}');
  }
}
