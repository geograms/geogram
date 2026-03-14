/// Conference Host Peer Manager — SFU host-side WebRTC manager.
///
/// The host maintains one RTCPeerConnection per participant.
/// Speaker tracks are received and forwarded to all other connections.
/// No audio mixing — individual tracks forwarded as-is.
library;

import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'conference_peer_manager.dart';
import 'log_service.dart';
import 'webrtc_config.dart';

/// Role of a participant in the SFU topology.
enum SfuParticipantRole { speaker, listener }

/// Host-side SFU manager.
///
/// Maintains one [RTCPeerConnection] per participant. Receives audio tracks
/// from speakers via `onTrack` and forwards them to every other connection.
/// Listeners receive all speaker tracks but send no audio.
class ConferenceHostPeerManager {
  WebRTCConfig _config;
  final Map<String, ConferenceAudioPeer> _peers = {};
  final Map<String, SfuParticipantRole> _roles = {};
  MediaStream? _localStream;
  MediaStream? _localScreenStream;
  bool _localMuted = false;

  /// Tracks received from speakers, keyed by callsign.
  final Map<String, MediaStreamTrack> _speakerTracks = {};
  final Map<String, MediaStream> _remoteStreams = {};
  final Map<String, RTCRtpSender> _screenSenders = {};
  MediaStreamTrack? _remoteScreenTrack;
  MediaStream? _remoteScreenStream;
  String? _remoteScreenSharer;

  /// Callback to send signaling messages (set by ConferenceService).
  ConferenceSignalSender? onSendSignal;

  final _eventController = StreamController<ConferenceEvent>.broadcast();
  Stream<ConferenceEvent> get events => _eventController.stream;

  bool get isLocalMuted => _localMuted;
  MediaStream? get localStream => _localStream;
  MediaStream? get localScreenStream => _localScreenStream;
  MediaStream? get remoteScreenStream => _remoteScreenStream;
  String? get remoteScreenSharer => _remoteScreenSharer;
  bool get isLocalScreenSharing => _localScreenStream != null;
  Map<String, MediaStream> get remoteStreams =>
      Map.unmodifiable(_remoteStreams);
  int get peerCount => _peers.length;

  List<String> get connectedPeers =>
      _peers.values.where((p) => p.isConnected).map((p) => p.callsign).toList();

  List<RTCPeerConnection> get activePeerConnections => _peers.values
      .where((p) => p.peerConnection != null)
      .map((p) => p.peerConnection!)
      .toList();

  List<String> get speakerCallsigns => _roles.entries
      .where((e) => e.value == SfuParticipantRole.speaker)
      .map((e) => e.key)
      .toList();

  ConferenceHostPeerManager({WebRTCConfig? config})
    : _config = config ?? const WebRTCConfig();

  void setConfig(WebRTCConfig config) => _config = config;

  void _emitEvent(ConferenceEvent event) {
    if (_eventController.isClosed) {
      return;
    }
    _eventController.add(event);
  }

  // ── Lifecycle ──────────────────────────────────────────────────

  /// Capture the host's local microphone (host is always a speaker).
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

    LogService().log('ConferenceHostPeerManager: Local audio started');
  }

  /// Release all resources.
  Future<void> dispose() async {
    for (final peer in _peers.values.toList()) {
      await _closePeer(peer);
    }
    _peers.clear();
    _roles.clear();
    _speakerTracks.clear();
    _screenSenders.clear();
    for (final stream in _remoteStreams.values) {
      await stream.dispose();
    }
    _remoteStreams.clear();
    _remoteScreenTrack = null;
    await _remoteScreenStream?.dispose();
    _remoteScreenStream = null;
    _remoteScreenSharer = null;

    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream?.dispose();
    _localStream = null;
    _localScreenStream?.getTracks().forEach((t) => t.stop());
    await _localScreenStream?.dispose();
    _localScreenStream = null;

    _eventController.close();
    LogService().log('ConferenceHostPeerManager: Disposed');
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

  Future<void> startLocalScreenShare(MediaStream stream) async {
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
    await _replaceForwardedScreenTrack(
      videoTracks.first,
      stream,
      excludeKey: null,
    );
    _emitEvent(ConferenceEvent('local_screen_stream', 'host', stream));
  }

  Future<void> stopLocalScreenShare() async {
    if (_localScreenStream == null) {
      return;
    }

    await _replaceForwardedScreenTrack(null, null, excludeKey: null);
    _localScreenStream!.getTracks().forEach((track) => track.stop());
    await _localScreenStream!.dispose();
    _localScreenStream = null;
    _emitEvent(ConferenceEvent('local_screen_stream_removed', 'host'));
  }

  // ── Add speaker ────────────────────────────────────────────────

  /// Create a connection for an incoming speaker.
  /// Host offers with offerToReceiveAudio: true.
  /// Adds host's own track + all other speaker tracks to the connection.
  Future<void> addSpeaker(String callsign) async {
    _roles[callsign.toUpperCase()] = SfuParticipantRole.speaker;
    // Connection is established when we receive their offer via handleOffer
    // or when we initiate via _createOfferTo.
    LogService().log(
      'ConferenceHostPeerManager: $callsign registered as speaker',
    );
  }

  // ── Add listener ───────────────────────────────────────────────

  /// Register a listener. The connection is created when their offer arrives.
  Future<void> addListener(String callsign) async {
    _roles[callsign.toUpperCase()] = SfuParticipantRole.listener;
    LogService().log(
      'ConferenceHostPeerManager: $callsign registered as listener',
    );
  }

  // ── Handle incoming offer from a participant ───────────────────

  /// Handle an offer from a joining participant.
  /// The host answers with all speaker tracks attached.
  Future<void> handleOffer(
    String callsign,
    String sessionId,
    Map<String, dynamic> sdp, {
    String? role,
  }) async {
    final key = callsign.toUpperCase();

    // Set role if provided
    if (role != null) {
      _roles[key] = role == 'speaker'
          ? SfuParticipantRole.speaker
          : SfuParticipantRole.listener;
    }

    final isSpeaker = _roles[key] == SfuParticipantRole.speaker;

    final existing = _peers[key];
    late final ConferenceAudioPeer peer;
    final isRenegotiation = existing != null && existing.peerConnection != null;

    if (isRenegotiation) {
      peer = existing;
      peer.sessionId = sessionId;
    } else {
      peer = ConferenceAudioPeer(
        callsign: callsign,
        sessionId: sessionId,
        state: ConferencePeerState.connecting,
      );
      peer.connectionCompleter = Completer<bool>();
      _peers[key] = peer;

      peer.peerConnection = await createPeerConnection(
        _config.toRTCConfiguration(),
      );
      _setupHandlers(peer);

      // Add host's own audio track
      if (_localStream != null) {
        for (final track in _localStream!.getAudioTracks()) {
          await peer.peerConnection!.addTrack(track, _localStream!);
        }
      }

      // Add all other speaker tracks to this connection
      for (final entry in _speakerTracks.entries) {
        if (entry.key != key) {
          await peer.peerConnection!.addTrack(entry.value, _localStream!);
        }
      }

      final localScreenTracks =
          _localScreenStream?.getVideoTracks() ?? const [];
      final screenTrack = localScreenTracks.isNotEmpty
          ? localScreenTracks.first
          : (_remoteScreenSharer == key ? null : _remoteScreenTrack);
      final screenStream = _localScreenStream ?? _remoteScreenStream;
      if (screenTrack != null && screenStream != null) {
        final sender = await peer.peerConnection!.addTrack(
          screenTrack,
          screenStream,
        );
        await configureConferenceScreenSender(
          sender,
          logLabel: 'host screen -> ${peer.callsign}',
        );
        _screenSenders[key] = sender;
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

    // Create answer
    final answer = await peer.peerConnection!.createAnswer({
      'offerToReceiveAudio': isSpeaker,
      'offerToReceiveVideo': true,
    });
    await peer.peerConnection!.setLocalDescription(answer);

    onSendSignal?.call({
      'type': 'webrtc_answer',
      'to_callsign': callsign,
      'session_id': sessionId,
      'sdp': {'type': answer.type, 'sdp': answer.sdp},
    });

    LogService().log(
      'ConferenceHostPeerManager: Answered offer from $callsign (${isSpeaker ? "speaker" : "listener"})',
    );
  }

  /// Handle an answer to our renegotiation offer.
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

    LogService().log('ConferenceHostPeerManager: Set answer from $callsign');
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

    final remoteDescription = await peer.peerConnection?.getRemoteDescription();
    if (remoteDescription != null) {
      await peer.peerConnection!.addCandidate(iceCandidate);
    } else {
      peer.pendingIceCandidates.add(iceCandidate);
    }
  }

  /// Handle a bye signal — close connection to a participant.
  Future<void> handleBye(String callsign) async {
    final key = callsign.toUpperCase();
    final peer = _peers.remove(key);
    if (peer == null) return;

    // Remove speaker track if they were a speaker
    await _removeSpeakerTrack(key);
    if (_remoteScreenSharer == key) {
      await clearRemoteScreenShare(callsign);
    }
    _screenSenders.remove(key);

    _roles.remove(key);
    await _closePeer(peer);
    _emitEvent(ConferenceEvent('peer_disconnected', callsign));
  }

  /// Disconnect from a specific participant.
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

    await _removeSpeakerTrack(key);
    if (_remoteScreenSharer == key) {
      await clearRemoteScreenShare(callsign);
    }
    _screenSenders.remove(key);
    _roles.remove(key);
    await _closePeer(peer);
    _emitEvent(ConferenceEvent('peer_disconnected', callsign));
  }

  // ── Promote / demote ───────────────────────────────────────────

  /// Promote a listener to speaker. Renegotiates the connection to
  /// accept audio, then forwards their track to all others.
  Future<void> promoteToSpeaker(String callsign) async {
    final key = callsign.toUpperCase();
    _roles[key] = SfuParticipantRole.speaker;

    // Renegotiate: create a new offer that accepts audio
    await _renegotiate(key);
    LogService().log(
      'ConferenceHostPeerManager: Promoted $callsign to speaker',
    );
  }

  /// Demote a speaker to listener. Removes their track from all
  /// other connections.
  Future<void> demoteToListener(String callsign) async {
    final key = callsign.toUpperCase();
    _roles[key] = SfuParticipantRole.listener;

    // Remove their track from all other connections
    await _removeSpeakerTrack(key);

    // Renegotiate: create a new offer that doesn't accept audio
    await _renegotiate(key);
    LogService().log(
      'ConferenceHostPeerManager: Demoted $callsign to listener',
    );
  }

  Future<void> clearRemoteScreenShare(String callsign) async {
    final key = callsign.toUpperCase();
    if (_remoteScreenSharer != key) {
      return;
    }

    try {
      await _replaceForwardedScreenTrack(null, null, excludeKey: key);
    } catch (e) {
      LogService().log(
        'ConferenceHostPeerManager: Failed to remove forwarded screen tracks: $e',
      );
    }
    _remoteScreenTrack = null;
    _remoteScreenSharer = null;
    final remoteStream = _remoteScreenStream;
    _remoteScreenStream = null;
    if (remoteStream != null) {
      try {
        await remoteStream.dispose();
      } catch (e) {
        LogService().log(
          'ConferenceHostPeerManager: Failed to dispose remote screen stream: $e',
        );
      }
    }
    _emitEvent(ConferenceEvent('remote_screen_stream_removed', callsign));
  }

  // ── Internal: renegotiation ────────────────────────────────────

  /// Send a new offer to a participant (host always offers during renegotiation).
  Future<void> _renegotiate(String key) async {
    final peer = _peers[key];
    if (peer?.peerConnection == null) return;

    final isSpeaker = _roles[key] == SfuParticipantRole.speaker;
    final pc = peer!.peerConnection!;

    final offer = await pc.createOffer({
      'offerToReceiveAudio': isSpeaker,
      'offerToReceiveVideo': true,
    });
    await pc.setLocalDescription(offer);

    final sessionId = _generateSessionId();
    peer.pendingIceCandidates.clear();

    onSendSignal?.call({
      'type': 'webrtc_offer',
      'to_callsign': peer.callsign,
      'session_id': sessionId,
      'sdp': {'type': offer.type, 'sdp': offer.sdp},
    });

    LogService().log(
      'ConferenceHostPeerManager: Renegotiation offer to ${peer.callsign}',
    );
  }

  Future<void> _replaceForwardedScreenTrack(
    MediaStreamTrack? track,
    MediaStream? stream, {
    required String? excludeKey,
  }) async {
    for (final entry in _peers.entries) {
      if (excludeKey != null && entry.key == excludeKey) {
        continue;
      }

      final pc = entry.value.peerConnection;
      if (pc == null) {
        continue;
      }

      final existingSender = _screenSenders.remove(entry.key);
      if (existingSender != null) {
        try {
          await pc.removeTrack(existingSender);
        } catch (e) {
          LogService().log(
            'ConferenceHostPeerManager: Failed to remove screen sender from ${entry.key}: $e',
          );
        }
      }

      if (track != null && stream != null) {
        try {
          final sender = await pc.addTrack(track, stream);
          await configureConferenceScreenSender(
            sender,
            logLabel: 'forwarded screen -> ${entry.value.callsign}',
          );
          _screenSenders[entry.key] = sender;
        } catch (e) {
          LogService().log(
            'ConferenceHostPeerManager: Failed to add screen sender to ${entry.key}: $e',
          );
        }
      }

      await _renegotiate(entry.key);
    }
  }

  Future<void> _refreshForwardedScreenTrackForPeer(String callsign) async {
    final key = callsign.toUpperCase();
    final peer = _peers[key];
    final pc = peer?.peerConnection;
    if (peer == null || pc == null) {
      return;
    }

    final localScreenTracks = _localScreenStream?.getVideoTracks() ?? const [];
    final screenTrack = localScreenTracks.isNotEmpty
        ? localScreenTracks.first
        : (_remoteScreenSharer == key ? null : _remoteScreenTrack);
    final screenStream = _localScreenStream ?? _remoteScreenStream;
    if (screenTrack == null || screenStream == null) {
      return;
    }

    final existingSender = _screenSenders.remove(key);
    if (existingSender != null) {
      try {
        await pc.removeTrack(existingSender);
      } catch (e) {
        LogService().log(
          'ConferenceHostPeerManager: Failed to remove stale screen sender from $key: $e',
        );
      }
    }

    try {
      final sender = await pc.addTrack(screenTrack, screenStream);
      await configureConferenceScreenSender(
        sender,
        logLabel: 'refreshed screen -> ${peer.callsign}',
      );
      _screenSenders[key] = sender;
      await _renegotiate(key);
    } catch (e) {
      LogService().log(
        'ConferenceHostPeerManager: Failed to refresh forwarded screen track for $key: $e',
      );
    }
  }

  /// Called when a speaker track is received. Stores it and adds
  /// to all other connections, triggering renegotiation for each.
  Future<void> _onSpeakerTrackReceived(
    String key,
    MediaStreamTrack track,
  ) async {
    _speakerTracks[key] = track;

    // Add this track to all OTHER peer connections
    for (final entry in _peers.entries) {
      if (entry.key == key) continue; // Don't send track back to its source
      final pc = entry.value.peerConnection;
      if (pc == null) continue;

      try {
        await pc.addTrack(track, _localStream!);
        // Renegotiate to inform the remote side about the new track
        await _renegotiate(entry.key);
      } catch (e) {
        LogService().log(
          'ConferenceHostPeerManager: Failed to add track to ${entry.key}: $e',
        );
      }
    }

    LogService().log(
      'ConferenceHostPeerManager: Speaker track from $key forwarded to ${_peers.length - 1} peers',
    );
  }

  /// Remove a speaker's track from all connections.
  Future<void> _removeSpeakerTrack(String key) async {
    final track = _speakerTracks.remove(key);
    final remoteStream = _remoteStreams.remove(key);
    if (remoteStream != null) {
      await remoteStream.dispose();
      _emitEvent(ConferenceEvent('remote_stream_removed', key));
    }
    if (track == null) return;

    // Remove from all other connections
    for (final entry in _peers.entries) {
      if (entry.key == key) continue;
      final pc = entry.value.peerConnection;
      if (pc == null) continue;

      try {
        final senders = await pc.getSenders();
        for (final sender in senders) {
          if (sender.track?.id == track.id) {
            await pc.removeTrack(sender);
          }
        }
        await _renegotiate(entry.key);
      } catch (e) {
        LogService().log(
          'ConferenceHostPeerManager: Failed to remove track from ${entry.key}: $e',
        );
      }
    }
  }

  // ── Setup handlers ─────────────────────────────────────────────

  void _setupHandlers(ConferenceAudioPeer peer) {
    final pc = peer.peerConnection!;
    final key = peer.callsign.toUpperCase();

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
        'ConferenceHostPeerManager: ${peer.callsign} connection state: $state',
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
        'ConferenceHostPeerManager: ${peer.callsign} ICE state: $state',
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

    // Remote tracks from participants.
    pc.onTrack = (RTCTrackEvent event) async {
      if (event.track.kind == 'audio' &&
          _roles[key] == SfuParticipantRole.speaker) {
        LogService().log(
          'ConferenceHostPeerManager: Audio track received from ${peer.callsign}',
        );
        MediaStream stream;
        if (event.streams.isNotEmpty) {
          stream = event.streams.first;
        } else {
          stream = await createLocalMediaStream('conference-host-$key');
          await stream.addTrack(event.track);
        }

        final previous = _remoteStreams[key];
        if (previous != null && previous.id != stream.id) {
          await previous.dispose();
        }
        _remoteStreams[key] = stream;
        _emitEvent(ConferenceEvent('remote_stream', peer.callsign, stream));
        await _onSpeakerTrackReceived(key, event.track);
        return;
      }

      if (event.track.kind == 'video') {
        LogService().log(
          'ConferenceHostPeerManager: Screen track received from ${peer.callsign}',
        );
        MediaStream stream;
        if (event.streams.isNotEmpty) {
          stream = event.streams.first;
        } else {
          stream = await createLocalMediaStream('conference-screen-$key');
          await stream.addTrack(event.track);
        }

        if (_remoteScreenSharer != null && _remoteScreenSharer != key) {
          await clearRemoteScreenShare(_remoteScreenSharer!);
        }

        final previous = _remoteScreenStream;
        if (previous != null && previous.id != stream.id) {
          await previous.dispose();
        }
        _remoteScreenSharer = key;
        _remoteScreenTrack = event.track;
        _remoteScreenStream = stream;
        await _replaceForwardedScreenTrack(
          event.track,
          stream,
          excludeKey: key,
        );
        _emitEvent(
          ConferenceEvent('remote_screen_stream', peer.callsign, stream),
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
    if (_localScreenStream != null ||
        (_remoteScreenTrack != null &&
            _remoteScreenSharer != peer.callsign.toUpperCase())) {
      unawaited(_refreshForwardedScreenTrackForPeer(peer.callsign));
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
      LogService().log(
        'ConferenceHostPeerManager: Error closing ${peer.callsign}: $e',
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
