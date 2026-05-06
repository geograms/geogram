/// WebRTC Configuration
///
/// Contains STUN/TURN server configuration, ICE settings,
/// timeouts, and data channel configuration for P2P connections.
///
/// Privacy note: This configuration uses self-hosted STUN servers on
/// Geogram stations instead of third-party STUN servers (Google, Twilio,
/// Mozilla). This prevents leaking client IP addresses to external services.
library;

/// Default STUN servers - empty by default for maximum privacy.
/// Station STUN servers are used when available (from hello_ack).
/// Without station STUN, WebRTC uses host candidates only (LAN-only).
const List<Map<String, dynamic>> defaultStunServers = [];

/// STUN servers used by the BT-DHT-v2 serverless P2P path when no station
/// STUN is in scope (§9.1: "use a privacy-respecting public server. Avoid
/// Google STUN. Mozilla's stun.services.mozilla.com is acceptable.").
/// Used by `WebRTCConfig.serverless()`. Open question §17 to revisit:
/// derive STUN reply from a relay-tier peer once that lands.
const List<Map<String, dynamic>> serverlessStunServers = [
  {'urls': 'stun:stun.services.mozilla.com'},
];

/// STUN server info received from a station
class StationStunInfo {
  final bool enabled;
  final int port;

  const StationStunInfo({
    required this.enabled,
    required this.port,
  });

  factory StationStunInfo.fromJson(Map<String, dynamic> json) {
    return StationStunInfo(
      enabled: json['enabled'] as bool? ?? false,
      port: json['port'] as int? ?? 3478,
    );
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'port': port,
  };
}

/// WebRTC configuration class
class WebRTCConfig {
  /// STUN/TURN servers for ICE
  final List<Map<String, dynamic>> iceServers;

  /// Timeout for ICE candidate gathering (ms)
  final int iceGatheringTimeoutMs;

  /// Timeout for connection establishment (ms)
  final int connectionTimeoutMs;

  /// Timeout for waiting for answer after sending offer (ms)
  final int offerTimeoutMs;

  /// Maximum number of ICE restart attempts
  final int maxIceRestarts;

  /// Whether to use trickle ICE (send candidates as they're gathered)
  final bool useTrickleIce;

  /// Data channel label for geogram messages
  final String dataChannelLabel;

  /// Whether data channel should be ordered (reliable)
  final bool dataChannelOrdered;

  /// Maximum retransmits for data channel (null = unlimited)
  final int? dataChannelMaxRetransmits;

  const WebRTCConfig({
    this.iceServers = defaultStunServers,
    this.iceGatheringTimeoutMs = 5000,
    this.connectionTimeoutMs = 15000,
    this.offerTimeoutMs = 10000,
    this.maxIceRestarts = 2,
    this.useTrickleIce = true,
    this.dataChannelLabel = 'geogram',
    this.dataChannelOrdered = true,
    this.dataChannelMaxRetransmits = null,
  });

  /// Create configuration with custom TURN server
  factory WebRTCConfig.withTurn({
    required String turnUrl,
    required String username,
    required String credential,
    List<Map<String, dynamic>>? additionalStunServers,
  }) {
    final servers = <Map<String, dynamic>>[
      ...defaultStunServers,
      {
        'urls': turnUrl,
        'username': username,
        'credential': credential,
      },
      if (additionalStunServers != null) ...additionalStunServers,
    ];
    return WebRTCConfig(iceServers: servers);
  }

  /// Create configuration with station-hosted STUN server (privacy-preserving)
  ///
  /// Uses the station's self-hosted STUN server instead of third-party servers.
  /// This ensures client IP addresses are not leaked to Google, Twilio, etc.
  ///
  /// [stationHost] - The hostname or IP of the station (extracted from WebSocket URL)
  /// [stunPort] - The UDP port of the STUN server (from hello_ack, usually 3478)
  factory WebRTCConfig.withStationStun({
    required String stationHost,
    required int stunPort,
  }) {
    final servers = <Map<String, dynamic>>[
      {'urls': 'stun:$stationHost:$stunPort'},
    ];
    return WebRTCConfig(iceServers: servers);
  }

  /// Configuration for the BT-DHT-v2 serverless path (§9.1). Uses a
  /// privacy-respecting public STUN server when no station STUN is
  /// available; no TURN servers (relay tier supersedes per §10).
  factory WebRTCConfig.serverless() {
    return const WebRTCConfig(iceServers: serverlessStunServers);
  }

  /// Convert to RTCConfiguration map for flutter_webrtc
  Map<String, dynamic> toRTCConfiguration() {
    return {
      'iceServers': iceServers,
      'iceCandidatePoolSize': 10,
      'bundlePolicy': 'max-bundle',
      'rtcpMuxPolicy': 'require',
      // Prefer UDP over TCP for lower latency
      'iceTransportPolicy': 'all',
    };
  }

  /// Create data channel init options
  Map<String, dynamic> toDataChannelInit() {
    return {
      'ordered': dataChannelOrdered,
      'protocol': 'geogram-p2p',
      if (dataChannelMaxRetransmits != null)
        'maxRetransmits': dataChannelMaxRetransmits,
    };
  }

  /// Create a configuration optimized for audio conferencing.
  ///
  /// Uses shorter timeouts since audio conferences are real-time sensitive.
  factory WebRTCConfig.forConference({
    List<Map<String, dynamic>>? iceServers,
  }) {
    return WebRTCConfig(
      iceServers: iceServers ?? defaultStunServers,
      iceGatheringTimeoutMs: 3000,
      connectionTimeoutMs: 10000,
      offerTimeoutMs: 8000,
      maxIceRestarts: 1,
      useTrickleIce: true,
    );
  }
}

/// Maximum participants in a conference (mesh topology limits).
const int conferenceMaxParticipants = 6;

/// Connection state for a WebRTC peer
enum WebRTCConnectionState {
  /// No connection attempted
  idle,

  /// Creating offer
  creatingOffer,

  /// Offer sent, waiting for answer
  waitingForAnswer,

  /// Answer received, ICE negotiation in progress
  connecting,

  /// ICE connected, data channel opening
  connected,

  /// Connection established, ready for data transfer
  ready,

  /// Connection failed (timeout, ICE failure, etc.)
  failed,

  /// Connection closed gracefully
  closed,
}

/// Extension to get human-readable state names
extension WebRTCConnectionStateExtension on WebRTCConnectionState {
  String get displayName {
    switch (this) {
      case WebRTCConnectionState.idle:
        return 'Idle';
      case WebRTCConnectionState.creatingOffer:
        return 'Creating Offer';
      case WebRTCConnectionState.waitingForAnswer:
        return 'Waiting for Answer';
      case WebRTCConnectionState.connecting:
        return 'Connecting';
      case WebRTCConnectionState.connected:
        return 'Connected';
      case WebRTCConnectionState.ready:
        return 'Ready';
      case WebRTCConnectionState.failed:
        return 'Failed';
      case WebRTCConnectionState.closed:
        return 'Closed';
    }
  }

  bool get isActive {
    return this == WebRTCConnectionState.connected ||
        this == WebRTCConnectionState.ready;
  }

  bool get isConnecting {
    return this == WebRTCConnectionState.creatingOffer ||
        this == WebRTCConnectionState.waitingForAnswer ||
        this == WebRTCConnectionState.connecting ||
        this == WebRTCConnectionState.connected;
  }
}

/// Signaling message types for WebRTC negotiation
enum WebRTCSignalType {
  offer,
  answer,
  iceCandidate,
  bye, // Connection close request
}

/// A WebRTC signaling message
class WebRTCSignal {
  final WebRTCSignalType type;
  final String fromCallsign;
  final String toCallsign;
  final String sessionId;
  final Map<String, dynamic>? sdp;
  final Map<String, dynamic>? candidate;
  final int timestamp;

  WebRTCSignal({
    required this.type,
    required this.fromCallsign,
    required this.toCallsign,
    required this.sessionId,
    this.sdp,
    this.candidate,
    int? timestamp,
  }) : timestamp = timestamp ?? DateTime.now().millisecondsSinceEpoch;

  /// Create an offer signal
  factory WebRTCSignal.offer({
    required String fromCallsign,
    required String toCallsign,
    required String sessionId,
    required Map<String, dynamic> sdp,
  }) {
    return WebRTCSignal(
      type: WebRTCSignalType.offer,
      fromCallsign: fromCallsign,
      toCallsign: toCallsign,
      sessionId: sessionId,
      sdp: sdp,
    );
  }

  /// Create an answer signal
  factory WebRTCSignal.answer({
    required String fromCallsign,
    required String toCallsign,
    required String sessionId,
    required Map<String, dynamic> sdp,
  }) {
    return WebRTCSignal(
      type: WebRTCSignalType.answer,
      fromCallsign: fromCallsign,
      toCallsign: toCallsign,
      sessionId: sessionId,
      sdp: sdp,
    );
  }

  /// Create an ICE candidate signal
  factory WebRTCSignal.iceCandidate({
    required String fromCallsign,
    required String toCallsign,
    required String sessionId,
    required Map<String, dynamic> candidate,
  }) {
    return WebRTCSignal(
      type: WebRTCSignalType.iceCandidate,
      fromCallsign: fromCallsign,
      toCallsign: toCallsign,
      sessionId: sessionId,
      candidate: candidate,
    );
  }

  /// Create a bye signal (close connection)
  factory WebRTCSignal.bye({
    required String fromCallsign,
    required String toCallsign,
    required String sessionId,
  }) {
    return WebRTCSignal(
      type: WebRTCSignalType.bye,
      fromCallsign: fromCallsign,
      toCallsign: toCallsign,
      sessionId: sessionId,
    );
  }

  /// Convert to JSON for WebSocket transmission
  Map<String, dynamic> toJson() {
    final typeString = switch (type) {
      WebRTCSignalType.offer => 'webrtc_offer',
      WebRTCSignalType.answer => 'webrtc_answer',
      WebRTCSignalType.iceCandidate => 'webrtc_ice',
      WebRTCSignalType.bye => 'webrtc_bye',
    };

    return {
      'type': typeString,
      'from_callsign': fromCallsign,
      'to_callsign': toCallsign,
      'session_id': sessionId,
      'timestamp': timestamp,
      if (sdp != null) 'sdp': sdp,
      if (candidate != null) 'candidate': candidate,
    };
  }

  /// Parse from JSON received via WebSocket
  factory WebRTCSignal.fromJson(Map<String, dynamic> json) {
    final typeString = json['type'] as String;
    final type = switch (typeString) {
      'webrtc_offer' => WebRTCSignalType.offer,
      'webrtc_answer' => WebRTCSignalType.answer,
      'webrtc_ice' => WebRTCSignalType.iceCandidate,
      'webrtc_bye' => WebRTCSignalType.bye,
      _ => throw ArgumentError('Unknown WebRTC signal type: $typeString'),
    };

    return WebRTCSignal(
      type: type,
      fromCallsign: json['from_callsign'] as String,
      toCallsign: json['to_callsign'] as String,
      sessionId: json['session_id'] as String,
      sdp: json['sdp'] as Map<String, dynamic>?,
      candidate: json['candidate'] as Map<String, dynamic>?,
      timestamp: json['timestamp'] as int?,
    );
  }

  @override
  String toString() {
    return 'WebRTCSignal(${type.name}: $fromCallsign -> $toCallsign, session: $sessionId)';
  }
}
