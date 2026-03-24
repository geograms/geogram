/// WebRTC Peer Connection Manager
///
/// Manages WebRTC peer connections for multiple devices.
/// Handles connection lifecycle, data channels, and message routing.
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'webrtc_config.dart';
import 'webrtc_signaling_service.dart';
import 'websocket_service.dart';
import 'log_service.dart';

/// Represents a peer connection to another device
class WebRTCPeerConnection {
  final String callsign;
  final String sessionId;
  RTCPeerConnection? peerConnection;
  RTCDataChannel? dataChannel;
  WebRTCConnectionState state;
  DateTime createdAt;
  DateTime? connectedAt;

  /// Completer for connection establishment
  Completer<bool>? connectionCompleter;

  /// Pending ICE candidates (received before remote description set)
  final List<RTCIceCandidate> pendingIceCandidates = [];

  /// Message queue for messages sent before data channel opened
  final List<String> pendingMessages = [];

  WebRTCPeerConnection({
    required this.callsign,
    required this.sessionId,
    this.state = WebRTCConnectionState.idle,
  }) : createdAt = DateTime.now();

  bool get isConnected => state == WebRTCConnectionState.ready;
  bool get isConnecting => state.isConnecting;

  Duration? get connectionDuration {
    if (connectedAt == null) return null;
    return DateTime.now().difference(connectedAt!);
  }
}

/// WebRTC Peer Manager (Singleton)
///
/// Manages peer connections to multiple devices, handling:
/// - Connection establishment (offers/answers)
/// - ICE candidate exchange
/// - Data channel management
/// - Message routing
class WebRTCPeerManager {
  static final WebRTCPeerManager _instance = WebRTCPeerManager._internal();
  factory WebRTCPeerManager() => _instance;
  WebRTCPeerManager._internal();

  /// Configuration for WebRTC connections
  WebRTCConfig _config = const WebRTCConfig();

  /// Active peer connections by callsign
  final Map<String, WebRTCPeerConnection> _peers = {};

  /// Signaling service for offer/answer/ICE exchange
  final WebRTCSignalingService _signalingService = WebRTCSignalingService();

  /// Stream controller for incoming messages
  final _messageController = StreamController<WebRTCMessage>.broadcast();

  /// Subscription to signaling service
  StreamSubscription<WebRTCSignal>? _signalSubscription;

  /// Whether the manager is initialized
  bool _initialized = false;

  /// Stream of incoming messages from peers
  Stream<WebRTCMessage> get messages => _messageController.stream;

  /// Set the WebRTC configuration
  void setConfig(WebRTCConfig config) {
    _config = config;
  }

  /// Initialize the peer manager
  Future<void> initialize() async {
    if (_initialized) return;

    LogService().log('WebRTCPeerManager: Initializing...');

    // Configure STUN server from station (privacy-preserving alternative to Google STUN)
    _configureStationStun();

    // Initialize signaling service
    _signalingService.initialize();

    // Listen for incoming signals
    _signalSubscription = _signalingService.signals.listen(_handleSignal);

    _initialized = true;
    LogService().log('WebRTCPeerManager: Initialized');
  }

  /// Configure STUN server from connected station for privacy-preserving WebRTC
  void _configureStationStun() {
    final wsService = WebSocketService();
    final stunInfo = wsService.connectedStationStunInfo;
    final stationUrl = wsService.connectedUrl;

    if (stunInfo != null && stunInfo.enabled && stationUrl != null) {
      // Extract host from WebSocket URL
      try {
        final uri = Uri.parse(stationUrl);
        final stationHost = uri.host;
        _config = WebRTCConfig.withStationStun(
          stationHost: stationHost,
          stunPort: stunInfo.port,
        );
        LogService().log(
          'WebRTCPeerManager: Using station STUN at $stationHost:${stunInfo.port}',
        );
      } catch (e) {
        LogService().log(
          'WebRTCPeerManager: Failed to parse station URL, using default config',
        );
      }
    } else {
      // No station STUN available - use empty config (host candidates only)
      LogService().log(
        'WebRTCPeerManager: No station STUN available (LAN connections only)',
      );
    }
  }

  /// Dispose resources
  Future<void> dispose() async {
    LogService().log('WebRTCPeerManager: Disposing...');

    _signalSubscription?.cancel();

    // Close all peer connections
    for (final peer in _peers.values) {
      await _closePeerConnection(peer);
    }
    _peers.clear();

    _messageController.close();
    _signalingService.dispose();

    _initialized = false;
    LogService().log('WebRTCPeerManager: Disposed');
  }

  /// Check if we have an active connection to a callsign
  bool hasActiveConnection(String callsign) {
    final peer = _peers[callsign.toUpperCase()];
    return peer?.isConnected ?? false;
  }

  /// Check if a connection is healthy and ready for reuse
  /// A healthy connection has an active peer, is connected, and the data channel is open
  bool hasHealthyConnection(String callsign) {
    final peer = _peers[callsign.toUpperCase()];
    return peer != null &&
        peer.isConnected &&
        peer.dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen;
  }

  /// Get connection state for a callsign
  WebRTCConnectionState? getConnectionState(String callsign) {
    return _peers[callsign.toUpperCase()]?.state;
  }

  /// Get or create a connection to a device
  ///
  /// Returns true if connection is ready, false if failed.
  Future<bool> ensureConnection(String callsign) async {
    final normalizedCallsign = callsign.toUpperCase();

    // Check for existing connection
    final existingPeer = _peers[normalizedCallsign];
    if (existingPeer != null) {
      if (existingPeer.isConnected) {
        return true;
      }
      if (existingPeer.isConnecting) {
        // Wait for existing connection attempt
        return existingPeer.connectionCompleter?.future ?? Future.value(false);
      }
      // Previous connection failed, clean up and retry
      await _closePeerConnection(existingPeer);
      _peers.remove(normalizedCallsign);
    }

    // Create new connection
    return await _initiateConnection(normalizedCallsign);
  }

  /// Initiate a WebRTC connection to a device
  Future<bool> _initiateConnection(String callsign) async {
    LogService().log('WebRTCPeerManager: Initiating connection to $callsign');

    // Generate session ID
    final sessionId = _signalingService.generateSessionId();

    // Create peer connection
    final peer = WebRTCPeerConnection(
      callsign: callsign,
      sessionId: sessionId,
      state: WebRTCConnectionState.creatingOffer,
    );
    peer.connectionCompleter = Completer<bool>();
    _peers[callsign] = peer;

    try {
      // Create RTCPeerConnection
      peer.peerConnection = await createPeerConnection(
        _config.toRTCConfiguration(),
      );

      // Set up event handlers
      _setupPeerConnectionHandlers(peer);

      // Create data channel (offerer creates)
      peer.dataChannel = await peer.peerConnection!.createDataChannel(
        _config.dataChannelLabel,
        RTCDataChannelInit()
          ..ordered = _config.dataChannelOrdered
          ..protocol = 'geogram-p2p',
      );
      _setupDataChannelHandlers(peer);

      // Create offer
      final offer = await peer.peerConnection!.createOffer();
      await peer.peerConnection!.setLocalDescription(offer);

      peer.state = WebRTCConnectionState.waitingForAnswer;
      LogService().log('WebRTCPeerManager: Created offer for $callsign');

      // Send offer and wait for answer
      final answer = await _signalingService.sendOfferAndWaitForAnswer(
        toCallsign: callsign,
        sessionId: sessionId,
        sdp: {'type': offer.type, 'sdp': offer.sdp},
        timeout: Duration(milliseconds: _config.offerTimeoutMs),
      );

      // Set remote description
      await peer.peerConnection!.setRemoteDescription(
        RTCSessionDescription(answer.sdp!['sdp'], answer.sdp!['type']),
      );

      peer.state = WebRTCConnectionState.connecting;
      LogService().log(
        'WebRTCPeerManager: Set remote description for $callsign',
      );

      // Add any pending ICE candidates
      for (final candidate in peer.pendingIceCandidates) {
        await peer.peerConnection!.addCandidate(candidate);
      }
      peer.pendingIceCandidates.clear();

      // Wait for connection with timeout
      final connected = await peer.connectionCompleter!.future.timeout(
        Duration(milliseconds: _config.connectionTimeoutMs),
        onTimeout: () {
          LogService().log(
            'WebRTCPeerManager: Connection timeout for $callsign',
          );
          return false;
        },
      );

      return connected;
    } catch (e) {
      LogService().log(
        'WebRTCPeerManager: Error initiating connection to $callsign: $e',
      );
      peer.state = WebRTCConnectionState.failed;
      if (!peer.connectionCompleter!.isCompleted) {
        peer.connectionCompleter!.complete(false);
      }
      return false;
    }
  }

  /// Handle incoming WebRTC signal
  void _handleSignal(WebRTCSignal signal) {
    LogService().log(
      'WebRTCPeerManager: Received signal ${signal.type.name} from ${signal.fromCallsign}',
    );

    switch (signal.type) {
      case WebRTCSignalType.offer:
        _handleOffer(signal);
        break;
      case WebRTCSignalType.iceCandidate:
        _handleIceCandidate(signal);
        break;
      case WebRTCSignalType.bye:
        _handleBye(signal);
        break;
      case WebRTCSignalType.answer:
        // Answers are handled in sendOfferAndWaitForAnswer
        break;
    }
  }

  /// Handle incoming offer (we're the answerer)
  Future<void> _handleOffer(WebRTCSignal signal) async {
    final callsign = signal.fromCallsign.toUpperCase();
    LogService().log('WebRTCPeerManager: Handling offer from $callsign');

    // Check if we already have a connection to this peer
    if (_peers.containsKey(callsign)) {
      final existingPeer = _peers[callsign]!;
      if (existingPeer.isConnected) {
        LogService().log(
          'WebRTCPeerManager: Already connected to $callsign, ignoring offer',
        );
        return;
      }
      // Close existing failed/connecting connection
      await _closePeerConnection(existingPeer);
      _peers.remove(callsign);
    }

    // Create peer connection for answering
    final peer = WebRTCPeerConnection(
      callsign: callsign,
      sessionId: signal.sessionId,
      state: WebRTCConnectionState.connecting,
    );
    peer.connectionCompleter = Completer<bool>();
    _peers[callsign] = peer;

    try {
      // Create RTCPeerConnection
      peer.peerConnection = await createPeerConnection(
        _config.toRTCConfiguration(),
      );

      // Set up event handlers
      _setupPeerConnectionHandlers(peer);

      // Set remote description (the offer)
      await peer.peerConnection!.setRemoteDescription(
        RTCSessionDescription(signal.sdp!['sdp'], signal.sdp!['type']),
      );

      // Add any pending ICE candidates
      for (final candidate in peer.pendingIceCandidates) {
        await peer.peerConnection!.addCandidate(candidate);
      }
      peer.pendingIceCandidates.clear();

      // Create answer
      final answer = await peer.peerConnection!.createAnswer();
      await peer.peerConnection!.setLocalDescription(answer);

      // Send answer
      await _signalingService.sendAnswer(
        toCallsign: callsign,
        sessionId: signal.sessionId,
        sdp: {'type': answer.type, 'sdp': answer.sdp},
      );

      LogService().log('WebRTCPeerManager: Sent answer to $callsign');
    } catch (e) {
      LogService().log(
        'WebRTCPeerManager: Error handling offer from $callsign: $e',
      );
      peer.state = WebRTCConnectionState.failed;
      if (!peer.connectionCompleter!.isCompleted) {
        peer.connectionCompleter!.complete(false);
      }
    }
  }

  /// Handle incoming ICE candidate
  Future<void> _handleIceCandidate(WebRTCSignal signal) async {
    final callsign = signal.fromCallsign.toUpperCase();
    final peer = _peers[callsign];

    if (peer == null) {
      LogService().log(
        'WebRTCPeerManager: ICE candidate for unknown peer $callsign',
      );
      return;
    }

    final candidateData = signal.candidate!;
    final candidate = RTCIceCandidate(
      candidateData['candidate'],
      candidateData['sdpMid'],
      candidateData['sdpMLineIndex'],
    );

    // If remote description not yet set, queue the candidate
    if (peer.peerConnection?.getRemoteDescription() == null) {
      peer.pendingIceCandidates.add(candidate);
      LogService().log('WebRTCPeerManager: Queued ICE candidate for $callsign');
    } else {
      await peer.peerConnection!.addCandidate(candidate);
      LogService().log('WebRTCPeerManager: Added ICE candidate for $callsign');
    }
  }

  /// Handle bye signal (peer wants to close)
  Future<void> _handleBye(WebRTCSignal signal) async {
    final callsign = signal.fromCallsign.toUpperCase();
    final peer = _peers.remove(callsign);

    if (peer != null) {
      await _closePeerConnection(peer);
      LogService().log(
        'WebRTCPeerManager: Closed connection to $callsign (bye received)',
      );
    }
  }

  /// Set up event handlers for peer connection
  void _setupPeerConnectionHandlers(WebRTCPeerConnection peer) {
    final pc = peer.peerConnection!;

    // ICE connection state
    pc.onIceConnectionState = (state) {
      LogService().log(
        'WebRTCPeerManager: ICE state for ${peer.callsign}: $state',
      );

      switch (state) {
        case RTCIceConnectionState.RTCIceConnectionStateConnected:
        case RTCIceConnectionState.RTCIceConnectionStateCompleted:
          if (peer.state != WebRTCConnectionState.ready &&
              peer.dataChannel?.state ==
                  RTCDataChannelState.RTCDataChannelOpen) {
            _markConnectionReady(peer);
          }
          break;
        case RTCIceConnectionState.RTCIceConnectionStateFailed:
        case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
        case RTCIceConnectionState.RTCIceConnectionStateClosed:
          if (peer.state != WebRTCConnectionState.closed) {
            peer.state = WebRTCConnectionState.failed;
            if (peer.connectionCompleter != null &&
                !peer.connectionCompleter!.isCompleted) {
              peer.connectionCompleter!.complete(false);
            }
          }
          break;
        default:
          break;
      }
    };

    // ICE candidates - send to peer via signaling
    pc.onIceCandidate = (candidate) {
      if (candidate.candidate != null) {
        if (!_signalingService.canSignalPeer(peer.callsign)) {
          LogService().log(
            'WebRTCPeerManager: Skipping ICE candidate for ${peer.callsign} (no signaling path)',
          );
          return;
        }
        _signalingService.sendIceCandidate(
          toCallsign: peer.callsign,
          sessionId: peer.sessionId,
          candidate: {
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          },
        );
      }
    };

    // Data channel (for answerer - offerer creates it)
    pc.onDataChannel = (channel) {
      LogService().log(
        'WebRTCPeerManager: Data channel received for ${peer.callsign}',
      );
      peer.dataChannel = channel;
      _setupDataChannelHandlers(peer);
    };
  }

  /// Set up event handlers for data channel
  void _setupDataChannelHandlers(WebRTCPeerConnection peer) {
    final dc = peer.dataChannel!;

    dc.onDataChannelState = (state) {
      LogService().log(
        'WebRTCPeerManager: Data channel state for ${peer.callsign}: $state',
      );

      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _markConnectionReady(peer);
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        peer.state = WebRTCConnectionState.closed;
      }
    };

    dc.onMessage = (message) {
      _handleDataChannelMessage(peer, message);
    };
  }

  /// Mark connection as ready and send pending messages
  void _markConnectionReady(WebRTCPeerConnection peer) {
    if (peer.state == WebRTCConnectionState.ready) return;

    peer.state = WebRTCConnectionState.ready;
    peer.connectedAt = DateTime.now();

    if (peer.connectionCompleter != null &&
        !peer.connectionCompleter!.isCompleted) {
      peer.connectionCompleter!.complete(true);
    }

    LogService().log('WebRTCPeerManager: Connection ready to ${peer.callsign}');

    // Send any pending messages
    for (final msg in peer.pendingMessages) {
      peer.dataChannel?.send(RTCDataChannelMessage(msg));
    }
    peer.pendingMessages.clear();
  }

  /// Handle incoming data channel message
  void _handleDataChannelMessage(
    WebRTCPeerConnection peer,
    RTCDataChannelMessage message,
  ) {
    try {
      final data = message.text;
      final json = jsonDecode(data) as Map<String, dynamic>;

      final webrtcMessage = WebRTCMessage(
        fromCallsign: peer.callsign,
        type: json['type'] as String? ?? 'unknown',
        payload: json['payload'],
        messageId: json['message_id'] as String?,
      );

      _messageController.add(webrtcMessage);
      LogService().log(
        'WebRTCPeerManager: Received message from ${peer.callsign}: ${webrtcMessage.type}',
      );
    } catch (e) {
      LogService().log(
        'WebRTCPeerManager: Error parsing message from ${peer.callsign}: $e',
      );
    }
  }

  /// Send a message to a peer
  ///
  /// Returns true if message was sent (or queued), false if connection not available.
  Future<bool> sendMessage(
    String callsign,
    String type,
    dynamic payload, {
    String? messageId,
  }) async {
    final normalizedCallsign = callsign.toUpperCase();
    final peer = _peers[normalizedCallsign];

    if (peer == null || peer.dataChannel == null) {
      return false;
    }

    final message = jsonEncode({
      'type': type,
      'payload': payload,
      'message_id':
          messageId ?? DateTime.now().millisecondsSinceEpoch.toString(),
    });

    if (peer.dataChannel!.state == RTCDataChannelState.RTCDataChannelOpen) {
      peer.dataChannel!.send(RTCDataChannelMessage(message));
      return true;
    } else {
      // Queue message for when channel opens
      peer.pendingMessages.add(message);
      return true;
    }
  }

  /// Close connection to a peer
  Future<void> closeConnection(String callsign) async {
    final normalizedCallsign = callsign.toUpperCase();
    final peer = _peers.remove(normalizedCallsign);

    if (peer != null) {
      // Send bye signal
      await _signalingService.sendBye(
        toCallsign: peer.callsign,
        sessionId: peer.sessionId,
      );

      await _closePeerConnection(peer);
      LogService().log('WebRTCPeerManager: Closed connection to $callsign');
    }
  }

  /// Close a peer connection and clean up resources
  Future<void> _closePeerConnection(WebRTCPeerConnection peer) async {
    peer.state = WebRTCConnectionState.closed;

    try {
      await peer.dataChannel?.close();
      await peer.peerConnection?.close();
    } catch (e) {
      LogService().log('WebRTCPeerManager: Error closing peer connection: $e');
    }

    peer.dataChannel = null;
    peer.peerConnection = null;
  }

  /// Get list of connected callsigns
  List<String> get connectedPeers {
    return _peers.entries
        .where((e) => e.value.isConnected)
        .map((e) => e.key)
        .toList();
  }

  /// Get connection info for debugging
  Map<String, dynamic> getConnectionInfo(String callsign) {
    final peer = _peers[callsign.toUpperCase()];
    if (peer == null) return {'connected': false};

    return {
      'connected': peer.isConnected,
      'state': peer.state.displayName,
      'sessionId': peer.sessionId,
      'createdAt': peer.createdAt.toIso8601String(),
      'connectedAt': peer.connectedAt?.toIso8601String(),
      'connectionDuration': peer.connectionDuration?.inSeconds,
    };
  }
}

/// A message received via WebRTC data channel
class WebRTCMessage {
  final String fromCallsign;
  final String type;
  final dynamic payload;
  final String? messageId;

  WebRTCMessage({
    required this.fromCallsign,
    required this.type,
    this.payload,
    this.messageId,
  });

  @override
  String toString() => 'WebRTCMessage($type from $fromCallsign)';
}
