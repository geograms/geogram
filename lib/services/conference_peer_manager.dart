/// Conference Peer Manager — audio WebRTC mesh connections.
///
/// Manages multiple RTCPeerConnections for audio conferencing.
/// Each pair of participants gets a direct peer connection.
/// Reuses [WebRTCConfig] for ICE configuration.
library;

import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'log_service.dart';
import 'webrtc_config.dart';

/// State of a single audio peer connection.
enum ConferencePeerState { idle, connecting, connected, failed, closed }

/// Represents an audio peer connection to one conference participant.
class ConferenceAudioPeer {
  final String callsign;
  String sessionId;
  RTCPeerConnection? peerConnection;
  MediaStream? remoteStream;
  ConferencePeerState state;
  bool remoteMuted = false;

  /// Pending ICE candidates received before remote description was set.
  final List<RTCIceCandidate> pendingIceCandidates = [];

  Completer<bool>? connectionCompleter;

  ConferenceAudioPeer({
    required this.callsign,
    required this.sessionId,
    this.state = ConferencePeerState.idle,
  });

  bool get isConnected => state == ConferencePeerState.connected;
}

/// Callback signature for sending signaling messages.
typedef ConferenceSignalSender = void Function(Map<String, dynamic> signal);

Future<void> configureConferenceScreenSender(
  RTCRtpSender sender, {
  required String logLabel,
}) async {
  if (sender.track?.kind != 'video') {
    return;
  }

  try {
    final parameters = sender.parameters;
    final encodings =
        parameters.encodings == null || parameters.encodings!.isEmpty
        ? <RTCRtpEncoding>[RTCRtpEncoding()]
        : parameters.encodings!;

    for (final encoding in encodings) {
      encoding.maxBitrate = 1200000;
      encoding.maxFramerate = 8;
      encoding.scaleResolutionDownBy = 2.0;
    }

    parameters.encodings = encodings;
    parameters.degradationPreference = RTCDegradationPreference.BALANCED;

    final applied = await sender.setParameters(parameters);
    if (!applied) {
      LogService().log(
        'ConferencePeerManager: Screen sender tuning was rejected for $logLabel',
      );
    }
  } catch (e) {
    LogService().log(
      'ConferencePeerManager: Failed to tune screen sender for $logLabel: $e',
    );
  }
}

/// Event emitted when conference state changes.
class ConferenceEvent {
  final String
  type; // peer_connected, peer_disconnected, peer_muted, remote_stream
  final String callsign;
  final dynamic data;

  ConferenceEvent(this.type, this.callsign, [this.data]);
}

/// Manages a mesh of audio WebRTC connections for conferencing.
///
/// Unlike [WebRTCPeerManager] (data channels), this class captures microphone
/// audio via `getUserMedia` and exchanges media tracks with each peer.
class ConferencePeerManager {
  WebRTCConfig _config;
  final Map<String, ConferenceAudioPeer> _peers = {};
  MediaStream? _localStream;
  bool _localMuted = false;

  /// Callback to send signaling messages (set by ConferenceService).
  ConferenceSignalSender? onSendSignal;

  final _eventController = StreamController<ConferenceEvent>.broadcast();

  /// Stream of conference events (peer connected/disconnected/muted, etc.).
  Stream<ConferenceEvent> get events => _eventController.stream;

  bool get isLocalMuted => _localMuted;
  MediaStream? get localStream => _localStream;
  List<String> get connectedPeers =>
      _peers.values.where((p) => p.isConnected).map((p) => p.callsign).toList();

  int get peerCount => _peers.length;

  ConferencePeerManager({WebRTCConfig? config})
    : _config = config ?? const WebRTCConfig();

  /// Update the ICE configuration (e.g. after receiving station STUN info).
  void setConfig(WebRTCConfig config) => _config = config;

  void _emitEvent(ConferenceEvent event) {
    if (_eventController.isClosed) {
      return;
    }
    _eventController.add(event);
  }

  // ── Lifecycle ────────────────────────────────────────────────────

  /// Capture the local microphone.
  Future<void> startLocalAudio() async {
    if (_localStream != null) return;

    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      },
      'video': false,
    });

    LogService().log('ConferencePeerManager: Local audio started');
  }

  /// Release the local microphone and close all peer connections.
  Future<void> dispose() async {
    for (final peer in _peers.values.toList()) {
      await _closePeer(peer);
    }
    _peers.clear();

    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream?.dispose();
    _localStream = null;

    _eventController.close();
    LogService().log('ConferencePeerManager: Disposed');
  }

  // ── Mute / unmute ────────────────────────────────────────────────

  void toggleMute() {
    _localMuted = !_localMuted;
    _applyMute();
  }

  void setMuted(bool muted) {
    _localMuted = muted;
    _applyMute();
  }

  void _applyMute() {
    if (_localStream == null) return;
    for (final track in _localStream!.getAudioTracks()) {
      track.enabled = !_localMuted;
    }
  }

  // ── Outgoing connection (create offer) ───────────────────────────

  /// Create an offer to connect to [callsign].
  /// Returns the session ID for this peer connection.
  Future<String> createOffer(String callsign) async {
    final sessionId = _generateSessionId();
    final peer = ConferenceAudioPeer(
      callsign: callsign,
      sessionId: sessionId,
      state: ConferencePeerState.connecting,
    );
    peer.connectionCompleter = Completer<bool>();
    _peers[callsign.toUpperCase()] = peer;

    peer.peerConnection = await createPeerConnection(
      _config.toRTCConfiguration(),
    );
    _setupHandlers(peer);

    // Add local audio tracks
    if (_localStream != null) {
      for (final track in _localStream!.getAudioTracks()) {
        await peer.peerConnection!.addTrack(track, _localStream!);
      }
    }

    // Create and set local description
    final offer = await peer.peerConnection!.createOffer({
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': false,
    });
    await peer.peerConnection!.setLocalDescription(offer);

    // Send via signaling callback
    onSendSignal?.call({
      'type': 'webrtc_offer',
      'to_callsign': callsign,
      'session_id': sessionId,
      'sdp': {'type': offer.type, 'sdp': offer.sdp},
    });

    LogService().log('ConferencePeerManager: Created offer for $callsign');
    return sessionId;
  }

  // ── Incoming connection (handle offer, create answer) ────────────

  /// Handle an incoming offer from [callsign].
  Future<void> handleOffer(
    String callsign,
    String sessionId,
    Map<String, dynamic> sdp,
  ) async {
    final peer = ConferenceAudioPeer(
      callsign: callsign,
      sessionId: sessionId,
      state: ConferencePeerState.connecting,
    );
    peer.connectionCompleter = Completer<bool>();
    _peers[callsign.toUpperCase()] = peer;

    peer.peerConnection = await createPeerConnection(
      _config.toRTCConfiguration(),
    );
    _setupHandlers(peer);

    // Add local audio tracks
    if (_localStream != null) {
      for (final track in _localStream!.getAudioTracks()) {
        await peer.peerConnection!.addTrack(track, _localStream!);
      }
    }

    // Set remote description (the offer)
    await peer.peerConnection!.setRemoteDescription(
      RTCSessionDescription(sdp['sdp'] as String?, sdp['type'] as String?),
    );

    // Add any pending ICE candidates
    for (final candidate in peer.pendingIceCandidates) {
      await peer.peerConnection!.addCandidate(candidate);
    }
    peer.pendingIceCandidates.clear();

    // Create and set answer
    final answer = await peer.peerConnection!.createAnswer({
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': false,
    });
    await peer.peerConnection!.setLocalDescription(answer);

    // Send answer via signaling
    onSendSignal?.call({
      'type': 'webrtc_answer',
      'to_callsign': callsign,
      'session_id': sessionId,
      'sdp': {'type': answer.type, 'sdp': answer.sdp},
    });

    LogService().log('ConferencePeerManager: Answered offer from $callsign');
  }

  // ── Signal handling ──────────────────────────────────────────────

  /// Handle an incoming answer from a peer.
  Future<void> handleAnswer(String callsign, Map<String, dynamic> sdp) async {
    final peer = _peers[callsign.toUpperCase()];
    if (peer == null) return;

    await peer.peerConnection?.setRemoteDescription(
      RTCSessionDescription(sdp['sdp'] as String?, sdp['type'] as String?),
    );

    // Add any pending ICE candidates
    for (final candidate in peer.pendingIceCandidates) {
      await peer.peerConnection?.addCandidate(candidate);
    }
    peer.pendingIceCandidates.clear();

    LogService().log('ConferencePeerManager: Set answer from $callsign');
  }

  /// Handle an incoming ICE candidate.
  Future<void> handleIceCandidate(
    String callsign,
    Map<String, dynamic> candidate,
  ) async {
    final peer = _peers[callsign.toUpperCase()];
    if (peer == null) return;

    final iceCandidate = RTCIceCandidate(
      candidate['candidate'] as String?,
      candidate['sdpMid'] as String?,
      candidate['sdpMLineIndex'] as int?,
    );

    if (peer.peerConnection?.getRemoteDescription() != null) {
      await peer.peerConnection!.addCandidate(iceCandidate);
    } else {
      peer.pendingIceCandidates.add(iceCandidate);
    }
  }

  /// Handle a bye signal — close connection to a peer.
  Future<void> handleBye(String callsign) async {
    final key = callsign.toUpperCase();
    final peer = _peers.remove(key);
    if (peer == null) return;

    await _closePeer(peer);
    _emitEvent(ConferenceEvent('peer_disconnected', callsign));
  }

  /// Disconnect from a specific peer.
  Future<void> removePeer(String callsign) async {
    final key = callsign.toUpperCase();
    final peer = _peers.remove(key);
    if (peer == null) return;

    // Send bye signal
    onSendSignal?.call({
      'type': 'webrtc_bye',
      'to_callsign': callsign,
      'session_id': peer.sessionId,
    });

    await _closePeer(peer);
    _emitEvent(ConferenceEvent('peer_disconnected', callsign));
  }

  // ── Setup handlers ───────────────────────────────────────────────

  void _setupHandlers(ConferenceAudioPeer peer) {
    final pc = peer.peerConnection!;

    // ICE candidate gathering — trickle ICE
    pc.onIceCandidate = (RTCIceCandidate candidate) {
      onSendSignal?.call({
        'type': 'webrtc_ice',
        'to_callsign': peer.callsign,
        'session_id': peer.sessionId,
        'candidate': {
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        },
      });
    };

    // Connection state
    pc.onConnectionState = (RTCPeerConnectionState state) {
      LogService().log(
        'ConferencePeerManager: ${peer.callsign} connection state: $state',
      );

      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          peer.state = ConferencePeerState.connected;
          if (!(peer.connectionCompleter?.isCompleted ?? true)) {
            peer.connectionCompleter!.complete(true);
          }
          _emitEvent(ConferenceEvent('peer_connected', peer.callsign));

        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          peer.state = ConferencePeerState.failed;
          if (!(peer.connectionCompleter?.isCompleted ?? true)) {
            peer.connectionCompleter!.complete(false);
          }
          _emitEvent(ConferenceEvent('peer_disconnected', peer.callsign));

        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          peer.state = ConferencePeerState.closed;
          _emitEvent(ConferenceEvent('peer_disconnected', peer.callsign));

        default:
          break;
      }
    };

    // Remote audio track
    pc.onTrack = (RTCTrackEvent event) {
      if (event.streams.isNotEmpty) {
        peer.remoteStream = event.streams.first;
        _emitEvent(
          ConferenceEvent('remote_stream', peer.callsign, peer.remoteStream),
        );
        LogService().log(
          'ConferencePeerManager: Remote audio track from ${peer.callsign}',
        );
      }
    };
  }

  Future<void> _closePeer(ConferenceAudioPeer peer) async {
    try {
      peer.remoteStream?.dispose();
      await peer.peerConnection?.close();
      await peer.peerConnection?.dispose();
    } catch (e) {
      LogService().log(
        'ConferencePeerManager: Error closing ${peer.callsign}: $e',
      );
    }
    peer.peerConnection = null;
    peer.remoteStream = null;
    peer.state = ConferencePeerState.closed;
  }

  String _generateSessionId() {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final rand = (ts * 31 + 7) % 1000000;
    return '$ts-${rand.toRadixString(16).padLeft(6, '0')}';
  }
}
