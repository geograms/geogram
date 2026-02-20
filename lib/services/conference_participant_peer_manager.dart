/// Conference Participant Peer Manager — SFU participant-side WebRTC manager.
///
/// Maintains exactly ONE connection to the host. Receives multiple speaker
/// tracks from the host. Sends local audio only if the participant is a speaker.
library;

import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'conference_host_peer_manager.dart';
import 'conference_peer_manager.dart';
import 'log_service.dart';
import 'webrtc_config.dart';

/// Participant-side SFU manager — single connection to host.
class ConferenceParticipantPeerManager {
  WebRTCConfig _config;
  ConferenceAudioPeer? _hostPeer;
  MediaStream? _localStream;
  bool _localMuted = false;
  SfuParticipantRole _role;

  /// Multiple remote streams from the host (one per speaker track).
  final Map<String, MediaStream> _remoteStreams = {};

  /// Callback to send signaling messages.
  ConferenceSignalSender? onSendSignal;

  final _eventController = StreamController<ConferenceEvent>.broadcast();
  Stream<ConferenceEvent> get events => _eventController.stream;

  bool get isLocalMuted => _localMuted;
  MediaStream? get localStream => _localStream;
  SfuParticipantRole get role => _role;
  int get peerCount => _hostPeer != null ? 1 : 0;

  List<String> get connectedPeers =>
      _hostPeer?.isConnected == true ? [_hostPeer!.callsign] : [];

  ConferenceParticipantPeerManager({
    WebRTCConfig? config,
    SfuParticipantRole role = SfuParticipantRole.listener,
  })  : _config = config ?? const WebRTCConfig(),
        _role = role;

  void setConfig(WebRTCConfig config) => _config = config;

  // ── Lifecycle ──────────────────────────────────────────────────

  /// Start local audio capture (speakers only).
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

    LogService().log('ConferenceParticipantPeerManager: Local audio started');
  }

  /// Stop local audio capture.
  Future<void> stopLocalAudio() async {
    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream?.dispose();
    _localStream = null;
    LogService().log('ConferenceParticipantPeerManager: Local audio stopped');
  }

  /// Release all resources.
  Future<void> dispose() async {
    if (_hostPeer != null) {
      await _closePeer(_hostPeer!);
      _hostPeer = null;
    }
    _remoteStreams.clear();

    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream?.dispose();
    _localStream = null;

    _eventController.close();
    LogService().log('ConferenceParticipantPeerManager: Disposed');
  }

  // ── Mute / unmute ──────────────────────────────────────────────

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

  // ── Connect to host ────────────────────────────────────────────

  /// Create a connection to the host and send an offer.
  /// If speaker, includes local audio track. If listener, no audio sent.
  Future<String> connectToHost(String hostCallsign) async {
    final sessionId = _generateSessionId();
    final peer = ConferenceAudioPeer(
      callsign: hostCallsign,
      sessionId: sessionId,
      state: ConferencePeerState.connecting,
    );
    peer.connectionCompleter = Completer<bool>();
    _hostPeer = peer;

    peer.peerConnection = await createPeerConnection(
      _config.toRTCConfiguration(),
    );
    _setupHandlers(peer);

    // Add local audio tracks only if speaker
    if (_role == SfuParticipantRole.speaker && _localStream != null) {
      for (final track in _localStream!.getAudioTracks()) {
        await peer.peerConnection!.addTrack(track, _localStream!);
      }
    }

    // Create offer
    final offer = await peer.peerConnection!.createOffer({
      'offerToReceiveAudio': true, // Always receive (host sends speaker tracks)
      'offerToReceiveVideo': false,
    });
    await peer.peerConnection!.setLocalDescription(offer);

    onSendSignal?.call({
      'type': 'webrtc_offer',
      'to_callsign': hostCallsign,
      'session_id': sessionId,
      'role': _role == SfuParticipantRole.speaker ? 'speaker' : 'listener',
      'sdp': {'type': offer.type, 'sdp': offer.sdp},
    });

    LogService().log(
        'ConferenceParticipantPeerManager: Sent offer to host $hostCallsign '
        '(role: ${_role.name})');
    return sessionId;
  }

  // ── Handle renegotiation offer from host ───────────────────────

  /// Handle a renegotiation offer from the host (e.g., new speaker track added).
  Future<void> handleOffer(
      String callsign, String sessionId, Map<String, dynamic> sdp) async {
    final peer = _hostPeer;
    if (peer == null || peer.peerConnection == null) return;

    final pc = peer.peerConnection!;

    // Set the new remote description
    await pc.setRemoteDescription(
      RTCSessionDescription(sdp['sdp'] as String?, sdp['type'] as String?),
    );

    // Add any pending ICE candidates
    for (final candidate in peer.pendingIceCandidates) {
      await pc.addCandidate(candidate);
    }
    peer.pendingIceCandidates.clear();

    // Create answer
    final answer = await pc.createAnswer({
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': false,
    });
    await pc.setLocalDescription(answer);

    onSendSignal?.call({
      'type': 'webrtc_answer',
      'to_callsign': callsign,
      'session_id': sessionId,
      'sdp': {'type': answer.type, 'sdp': answer.sdp},
    });

    LogService().log(
        'ConferenceParticipantPeerManager: Answered renegotiation from host');
  }

  /// Handle an answer from the host (to our initial offer).
  Future<void> handleAnswer(String callsign, Map<String, dynamic> sdp) async {
    final peer = _hostPeer;
    if (peer == null) return;

    await peer.peerConnection?.setRemoteDescription(
      RTCSessionDescription(sdp['sdp'] as String?, sdp['type'] as String?),
    );

    // Add any pending ICE candidates
    for (final candidate in peer.pendingIceCandidates) {
      await peer.peerConnection?.addCandidate(candidate);
    }
    peer.pendingIceCandidates.clear();

    LogService().log(
        'ConferenceParticipantPeerManager: Set answer from host');
  }

  /// Handle an incoming ICE candidate from host.
  Future<void> handleIceCandidate(
      String callsign, Map<String, dynamic> candidate) async {
    final peer = _hostPeer;
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

  /// Handle a bye signal from the host.
  Future<void> handleBye(String callsign) async {
    if (_hostPeer == null) return;

    await _closePeer(_hostPeer!);
    _hostPeer = null;
    _eventController.add(ConferenceEvent('peer_disconnected', callsign));
  }

  // ── Role changes ───────────────────────────────────────────────

  /// Called when promoted to speaker. Starts mic and adds track to connection.
  Future<void> onPromotedToSpeaker() async {
    _role = SfuParticipantRole.speaker;

    if (_localStream == null) {
      await startLocalAudio();
    }

    // Add local audio to existing host connection
    final pc = _hostPeer?.peerConnection;
    if (pc != null && _localStream != null) {
      for (final track in _localStream!.getAudioTracks()) {
        await pc.addTrack(track, _localStream!);
      }
    }

    LogService().log('ConferenceParticipantPeerManager: Promoted to speaker');
  }

  /// Called when demoted to listener. Stops mic and removes track.
  Future<void> onDemotedToListener() async {
    _role = SfuParticipantRole.listener;

    // Remove local audio tracks from host connection
    final pc = _hostPeer?.peerConnection;
    if (pc != null) {
      final senders = await pc.getSenders();
      for (final sender in senders) {
        if (sender.track?.kind == 'audio') {
          await pc.removeTrack(sender);
        }
      }
    }

    await stopLocalAudio();
    LogService().log('ConferenceParticipantPeerManager: Demoted to listener');
  }

  // ── Setup handlers ─────────────────────────────────────────────

  void _setupHandlers(ConferenceAudioPeer peer) {
    final pc = peer.peerConnection!;

    // ICE candidate gathering
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
          'ConferenceParticipantPeerManager: Host connection state: $state');

      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          peer.state = ConferencePeerState.connected;
          if (!(peer.connectionCompleter?.isCompleted ?? true)) {
            peer.connectionCompleter!.complete(true);
          }
          _eventController.add(ConferenceEvent('peer_connected', peer.callsign));

        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          peer.state = ConferencePeerState.failed;
          if (!(peer.connectionCompleter?.isCompleted ?? true)) {
            peer.connectionCompleter!.complete(false);
          }
          _eventController.add(ConferenceEvent('peer_disconnected', peer.callsign));

        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          peer.state = ConferencePeerState.closed;
          _eventController.add(ConferenceEvent('peer_disconnected', peer.callsign));

        default:
          break;
      }
    };

    // Remote audio tracks (multiple — one per speaker)
    pc.onTrack = (RTCTrackEvent event) {
      if (event.streams.isNotEmpty) {
        final stream = event.streams.first;
        _remoteStreams[stream.id] = stream;
        _eventController.add(
            ConferenceEvent('remote_stream', peer.callsign, stream));
        LogService().log(
            'ConferenceParticipantPeerManager: Remote audio track from host '
            '(stream: ${stream.id})');
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
          'ConferenceParticipantPeerManager: Error closing: $e');
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
