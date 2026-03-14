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
  MediaStream? _localScreenStream;
  bool _localMuted = false;
  SfuParticipantRole _role;

  /// Multiple remote streams from the host (one per speaker track).
  final Map<String, MediaStream> _remoteStreams = {};
  MediaStream? _remoteScreenStream;

  /// Callback to send signaling messages.
  ConferenceSignalSender? onSendSignal;

  final _eventController = StreamController<ConferenceEvent>.broadcast();
  Stream<ConferenceEvent> get events => _eventController.stream;

  bool get isLocalMuted => _localMuted;
  MediaStream? get localStream => _localStream;
  MediaStream? get localScreenStream => _localScreenStream;
  MediaStream? get remoteScreenStream => _remoteScreenStream;
  bool get isLocalScreenSharing => _localScreenStream != null;
  SfuParticipantRole get role => _role;
  Map<String, MediaStream> get remoteStreams =>
      Map.unmodifiable(_remoteStreams);
  int get peerCount => _hostPeer != null ? 1 : 0;

  List<String> get connectedPeers =>
      _hostPeer?.isConnected == true ? [_hostPeer!.callsign] : [];

  List<RTCPeerConnection> get activePeerConnections =>
      _hostPeer?.peerConnection != null ? [_hostPeer!.peerConnection!] : [];

  ConferenceParticipantPeerManager({
    WebRTCConfig? config,
    SfuParticipantRole role = SfuParticipantRole.listener,
  }) : _config = config ?? const WebRTCConfig(),
       _role = role;

  void setConfig(WebRTCConfig config) => _config = config;

  void _emitEvent(ConferenceEvent event) {
    if (_eventController.isClosed) {
      return;
    }
    _eventController.add(event);
  }

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
    for (final stream in _remoteStreams.values) {
      await stream.dispose();
    }
    _remoteStreams.clear();
    await _remoteScreenStream?.dispose();
    _remoteScreenStream = null;

    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream?.dispose();
    _localStream = null;
    _localScreenStream?.getTracks().forEach((t) => t.stop());
    await _localScreenStream?.dispose();
    _localScreenStream = null;

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

  Future<void> startScreenShare(MediaStream stream) async {
    final videoTracks = stream.getVideoTracks();
    if (videoTracks.isEmpty) {
      await stream.dispose();
      throw StateError('Screen share stream does not contain video');
    }

    if (_localScreenStream != null && _localScreenStream!.id != stream.id) {
      _localScreenStream!.getTracks().forEach((track) => track.stop());
      await _localScreenStream!.dispose();
    }
    _localScreenStream = stream;

    final pc = _hostPeer?.peerConnection;
    if (pc != null) {
      await _removeLocalVideoSenders(pc);
      final sender = await pc.addTrack(videoTracks.first, stream);
      await configureConferenceScreenSender(
        sender,
        logLabel: 'participant screen -> ${_hostPeer?.callsign ?? 'host'}',
      );
      await _renegotiateWithHost();
    }
  }

  Future<void> stopScreenShare() async {
    final pc = _hostPeer?.peerConnection;
    if (pc != null) {
      await _removeLocalVideoSenders(pc);
      await _renegotiateWithHost();
    }

    _localScreenStream?.getTracks().forEach((track) => track.stop());
    await _localScreenStream?.dispose();
    _localScreenStream = null;
    _emitEvent(
      ConferenceEvent('local_screen_stream_removed', _hostPeer?.callsign ?? ''),
    );
  }

  Future<void> clearRemoteScreenStream() async {
    final stream = _remoteScreenStream;
    _remoteScreenStream = null;
    if (stream != null) {
      await stream.dispose();
    }
    _emitEvent(
      ConferenceEvent(
        'remote_screen_stream_removed',
        _hostPeer?.callsign ?? '',
      ),
    );
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

    if (_role == SfuParticipantRole.listener) {
      await peer.peerConnection!.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
    }
    if (_localScreenStream == null) {
      // Late joiners must advertise a recv-only video m-line so an already
      // active host screen share can be attached in the initial answer.
      await peer.peerConnection!.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
    }

    // Add local audio tracks only if speaker
    if (_role == SfuParticipantRole.speaker && _localStream != null) {
      for (final track in _localStream!.getAudioTracks()) {
        await peer.peerConnection!.addTrack(track, _localStream!);
      }
    }
    if (_localScreenStream != null) {
      for (final track in _localScreenStream!.getVideoTracks()) {
        final sender = await peer.peerConnection!.addTrack(
          track,
          _localScreenStream!,
        );
        await configureConferenceScreenSender(
          sender,
          logLabel: 'participant reconnect screen -> $hostCallsign',
        );
      }
    }

    // Create offer
    final offer = await peer.peerConnection!.createOffer({
      'offerToReceiveAudio': true, // Always receive (host sends speaker tracks)
      'offerToReceiveVideo': true,
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
      '(role: ${_role.name})',
    );
    return sessionId;
  }

  // ── Handle renegotiation offer from host ───────────────────────

  /// Handle a renegotiation offer from the host (e.g., new speaker track added).
  Future<void> handleOffer(
    String callsign,
    String sessionId,
    Map<String, dynamic> sdp,
  ) async {
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
      'offerToReceiveVideo': true,
    });
    await pc.setLocalDescription(answer);

    onSendSignal?.call({
      'type': 'webrtc_answer',
      'to_callsign': callsign,
      'session_id': sessionId,
      'sdp': {'type': answer.type, 'sdp': answer.sdp},
    });

    LogService().log(
      'ConferenceParticipantPeerManager: Answered renegotiation from host',
    );
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

    LogService().log('ConferenceParticipantPeerManager: Set answer from host');
  }

  /// Handle an incoming ICE candidate from host.
  Future<void> handleIceCandidate(
    String callsign,
    Map<String, dynamic> candidate,
  ) async {
    final peer = _hostPeer;
    if (peer == null) return;

    final iceCandidate = RTCIceCandidate(
      candidate['candidate'] as String?,
      candidate['sdpMid'] as String?,
      candidate['sdpMLineIndex'] as int?,
    );

    final remoteDescription = await peer.peerConnection?.getRemoteDescription();
    if (remoteDescription != null) {
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
    _emitEvent(ConferenceEvent('peer_disconnected', callsign));
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

  Future<void> _renegotiateWithHost() async {
    final peer = _hostPeer;
    final pc = peer?.peerConnection;
    if (peer == null || pc == null) {
      return;
    }

    final sessionId = _generateSessionId();
    peer.sessionId = sessionId;
    final offer = await pc.createOffer({
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': true,
    });
    await pc.setLocalDescription(offer);

    onSendSignal?.call({
      'type': 'webrtc_offer',
      'to_callsign': peer.callsign,
      'session_id': sessionId,
      'role': _role == SfuParticipantRole.speaker ? 'speaker' : 'listener',
      'sdp': {'type': offer.type, 'sdp': offer.sdp},
    });
  }

  Future<void> refreshRemoteSubscriptions() async {
    await _renegotiateWithHost();
  }

  Future<void> _removeLocalVideoSenders(RTCPeerConnection pc) async {
    final senders = await pc.getSenders();
    for (final sender in senders) {
      if (sender.track?.kind == 'video') {
        await pc.removeTrack(sender);
      }
    }
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
        'ConferenceParticipantPeerManager: Host connection state: $state',
      );

      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _markPeerConnected(peer);

        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          _markPeerDisconnected(peer, failed: true);

        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          _markPeerDisconnected(peer);

        default:
          break;
      }
    };

    pc.onIceConnectionState = (RTCIceConnectionState state) {
      LogService().log(
        'ConferenceParticipantPeerManager: Host ICE state: $state',
      );
      switch (state) {
        case RTCIceConnectionState.RTCIceConnectionStateConnected:
        case RTCIceConnectionState.RTCIceConnectionStateCompleted:
          _markPeerConnected(peer);
          break;
        case RTCIceConnectionState.RTCIceConnectionStateFailed:
          _markPeerDisconnected(peer, failed: true);
          break;
        case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
        case RTCIceConnectionState.RTCIceConnectionStateClosed:
          _markPeerDisconnected(peer);
          break;
        default:
          break;
      }
    };

    // Remote media tracks from the host.
    pc.onTrack = (RTCTrackEvent event) async {
      MediaStream stream;
      if (event.streams.isNotEmpty) {
        stream = event.streams.first;
      } else {
        stream = await createLocalMediaStream(
          'conference-remote-${peer.callsign}-${event.track.id}',
        );
        await stream.addTrack(event.track);
      }

      if (event.track.kind == 'audio') {
        _remoteStreams[stream.id] = stream;
        _emitEvent(ConferenceEvent('remote_stream', peer.callsign, stream));
        LogService().log(
          'ConferenceParticipantPeerManager: Remote audio track from host '
          '(stream: ${stream.id})',
        );
        return;
      }

      if (event.track.kind == 'video') {
        final previous = _remoteScreenStream;
        if (previous != null && previous.id != stream.id) {
          await previous.dispose();
        }
        _remoteScreenStream = stream;
        _emitEvent(
          ConferenceEvent('remote_screen_stream', peer.callsign, stream),
        );
        LogService().log(
          'ConferenceParticipantPeerManager: Remote screen track from host '
          '(stream: ${stream.id})',
        );
      }
    };
  }

  void _markPeerConnected(ConferenceAudioPeer peer) {
    if (peer.state == ConferencePeerState.connected) {
      return;
    }
    peer.state = ConferencePeerState.connected;
    if (!(peer.connectionCompleter?.isCompleted ?? true)) {
      peer.connectionCompleter!.complete(true);
    }
    _emitEvent(ConferenceEvent('peer_connected', peer.callsign));
  }

  void _markPeerDisconnected(ConferenceAudioPeer peer, {bool failed = false}) {
    if (peer.state == ConferencePeerState.closed ||
        peer.state == ConferencePeerState.failed) {
      return;
    }
    peer.state = failed
        ? ConferencePeerState.failed
        : ConferencePeerState.closed;
    if (failed && !(peer.connectionCompleter?.isCompleted ?? true)) {
      peer.connectionCompleter!.complete(false);
    }
    _emitEvent(ConferenceEvent('peer_disconnected', peer.callsign));
  }

  Future<void> _closePeer(ConferenceAudioPeer peer) async {
    try {
      peer.remoteStream?.dispose();
      await peer.peerConnection?.close();
      await peer.peerConnection?.dispose();
    } catch (e) {
      LogService().log('ConferenceParticipantPeerManager: Error closing: $e');
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
