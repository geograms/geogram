/// Conference Signaling Server (LAN mode) — SFU star topology.
///
/// Lightweight HTTP + WebSocket server run by the host client to coordinate
/// WebRTC audio conferencing on a local network without a station.
///
/// In star topology, participants connect only to the host. The signaling
/// server relays WebRTC signals between host and each participant.
/// Speakers are limited by [maxSpeakers]; listeners are unlimited.
///
/// Endpoints:
///   GET  /meet/{code}  — shareable URL, serves the browser web client
///   GET  /meet/info    — room info (host, speakers, listener count)
///   WS   /meet/ws      — WebSocket for signaling relay
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'log_service.dart';

/// A participant connected to the signaling server via WebSocket.
class SignalingParticipant {
  final String id;
  final WebSocket socket;
  String? callsign;
  String role; // 'speaker' or 'listener'
  DateTime connectedAt;

  SignalingParticipant({
    required this.id,
    required this.socket,
    this.callsign,
    this.role = 'listener',
  }) : connectedAt = DateTime.now();

  bool get isSpeaker => role == 'speaker';
}

/// Lightweight signaling server for LAN-mode SFU audio conferences.
///
/// The host client starts this server so peers on the same network can
/// exchange WebRTC offers / answers / ICE candidates with the host.
class ConferenceSignalingServer {
  HttpServer? _httpServer;
  final Map<String, SignalingParticipant> _participants = {};
  final String roomId;
  final String roomName;
  final String hostCallsign;
  final int maxSpeakers;
  String? _webClientHtml;

  int? get port => _httpServer?.port;
  bool get isRunning => _httpServer != null;
  int get participantCount => _participants.length;

  List<String> get participantCallsigns =>
      _participants.values
          .where((p) => p.callsign != null)
          .map((p) => p.callsign!)
          .toList();

  List<String> get speakerCallsigns =>
      _participants.values
          .where((p) => p.callsign != null && p.isSpeaker)
          .map((p) => p.callsign!)
          .toList();

  int get listenerCount =>
      _participants.values.where((p) => p.callsign != null && !p.isSpeaker).length;

  int get speakerCount =>
      _participants.values.where((p) => p.callsign != null && p.isSpeaker).length;

  ConferenceSignalingServer({
    required this.roomId,
    required this.roomName,
    required this.hostCallsign,
    this.maxSpeakers = 6,
  });

  /// Start listening on all interfaces at a random available port.
  Future<int> start() async {
    if (_httpServer != null) return _httpServer!.port;

    _httpServer = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    final boundPort = _httpServer!.port;
    LogService().log('Conference signaling server started on port $boundPort');

    _httpServer!.listen(_handleRequest, onError: (e) {
      LogService().log('Conference server error: $e');
    });

    return boundPort;
  }

  /// Stop the signaling server and disconnect all participants.
  Future<void> stop() async {
    // Notify participants before closing
    final bye = jsonEncode({'type': 'conference_end', 'room_id': roomId});
    for (final p in _participants.values) {
      try {
        p.socket.add(bye);
        await p.socket.close();
      } catch (_) {}
    }
    _participants.clear();

    await _httpServer?.close(force: true);
    _httpServer = null;
    LogService().log('Conference signaling server stopped');
  }

  /// Set the HTML content served at /meet/{code}.
  void setWebClientHtml(String html) {
    _webClientHtml = html;
  }

  // ── Request routing ──────────────────────────────────────────────

  void _handleRequest(HttpRequest request) {
    final path = request.uri.path;
    switch (path) {
      case '/meet/info':
        _handleInfo(request);
      case '/meet/ws':
        _handleWebSocket(request);
      default:
        if (path.startsWith('/meet/')) {
          _handleWebClient(request);
        } else {
          request.response
            ..statusCode = HttpStatus.notFound
            ..write('Not found')
            ..close();
        }
    }
  }

  // ── GET /meet/info ─────────────────────────────────────────────

  void _handleInfo(HttpRequest request) {
    final info = {
      'room_id': roomId,
      'room_name': roomName,
      'host_callsign': hostCallsign,
      'participant_count': participantCount,
      'speaker_count': speakerCount,
      'listener_count': listenerCount,
      'speakers': speakerCallsigns,
      'participants': participantCallsigns,
      'max_speakers': maxSpeakers,
    };
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(info))
      ..close();
  }

  // ── GET /meet/{code} ──────────────────────────────────────────

  void _handleWebClient(HttpRequest request) {
    if (_webClientHtml == null) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('Web client not available')
        ..close();
      return;
    }
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType('text', 'html', charset: 'utf-8')
      ..write(_webClientHtml)
      ..close();
  }

  // ── WS /meet/ws ──────────────────────────────────────────────

  Future<void> _handleWebSocket(HttpRequest request) async {
    WebSocket socket;
    try {
      socket = await WebSocketTransformer.upgrade(request);
    } catch (e) {
      LogService().log('Conference WS upgrade failed: $e');
      return;
    }

    final id = '${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(999999)}';
    final participant = SignalingParticipant(id: id, socket: socket);
    _participants[id] = participant;

    LogService().log('Conference participant connected: $id');

    socket.listen(
      (data) {
        if (data is! String) return;
        _handleSignalingMessage(participant, data);
      },
      onDone: () => _removeParticipant(id),
      onError: (_) => _removeParticipant(id),
    );
  }

  // ── Signaling message handling ──────────────────────────────────

  void _handleSignalingMessage(SignalingParticipant sender, String raw) {
    Map<String, dynamic> message;
    try {
      message = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    final type = message['type'] as String?;
    if (type == null) return;

    switch (type) {
      case 'conference_hello':
        _handleHello(sender, message);
      case 'webrtc_offer':
      case 'webrtc_answer':
      case 'webrtc_ice':
      case 'webrtc_bye':
        _relaySignal(sender, message);
      case 'conference_role_change':
        _handleRoleChange(sender, message);
      case 'conference_leave':
        _removeParticipant(sender.id);
    }
  }

  void _handleHello(SignalingParticipant sender, Map<String, dynamic> message) {
    final callsign = message['callsign'] as String?;
    if (callsign == null || callsign.isEmpty) return;

    final requestedRole = message['role'] as String? ?? 'listener';

    // Enforce speaker limit (only for speakers, listeners are unlimited)
    if (requestedRole == 'speaker' && speakerCount >= maxSpeakers) {
      // Downgrade to listener instead of rejecting
      sender.role = 'listener';
      LogService().log(
          'Conference: $callsign wanted speaker but limit reached, joining as listener');
    } else {
      sender.role = requestedRole;
    }

    sender.callsign = callsign;
    LogService().log('Conference participant identified: $callsign (${sender.role})');

    // Send the current participant list to the new joiner
    final existing = _participants.values
        .where((p) => p.id != sender.id && p.callsign != null)
        .map((p) => p.callsign!)
        .toList();

    final speakers = _participants.values
        .where((p) => p.id != sender.id && p.callsign != null && p.isSpeaker)
        .map((p) => p.callsign!)
        .toList();

    sender.socket.add(jsonEncode({
      'type': 'conference_welcome',
      'room_id': roomId,
      'room_name': roomName,
      'host_callsign': hostCallsign,
      'participants': existing,
      'speakers': speakers,
      'listener_count': listenerCount,
      'max_speakers': maxSpeakers,
    }));

    // Notify existing participants about the new joiner
    _broadcast(
      jsonEncode({
        'type': 'conference_participant_joined',
        'callsign': callsign,
        'role': sender.role,
      }),
      excludeId: sender.id,
    );
  }

  void _handleRoleChange(SignalingParticipant sender, Map<String, dynamic> message) {
    final targetCallsign = message['callsign'] as String?;
    final newRole = message['role'] as String?;
    if (targetCallsign == null || newRole == null) return;

    // Only host can change roles
    if (sender.callsign != hostCallsign) return;

    // Update the target's role
    final target = _participants.values.cast<SignalingParticipant?>().firstWhere(
      (p) => p!.callsign?.toLowerCase() == targetCallsign.toLowerCase(),
      orElse: () => null,
    );

    if (target != null) {
      target.role = newRole;
    }

    // Broadcast role change to all participants
    _broadcast(jsonEncode({
      'type': 'conference_role_change',
      'callsign': targetCallsign,
      'role': newRole,
    }));
  }

  /// Relay a WebRTC signal to a specific participant identified by to_callsign.
  void _relaySignal(SignalingParticipant sender, Map<String, dynamic> message) {
    final toCallsign = message['to_callsign'] as String?;
    if (toCallsign == null) return;

    // Ensure from_callsign is set (use sender's callsign)
    message['from_callsign'] = sender.callsign ?? sender.id;

    final target = _participants.values.cast<SignalingParticipant?>().firstWhere(
      (p) => p!.callsign?.toLowerCase() == toCallsign.toLowerCase(),
      orElse: () => null,
    );

    if (target == null) {
      sender.socket.add(jsonEncode({
        'type': 'webrtc_error',
        'error': 'target_not_connected',
        'to_callsign': toCallsign,
      }));
      return;
    }

    try {
      target.socket.add(jsonEncode(message));
    } catch (e) {
      LogService().log('Conference relay failed to $toCallsign: $e');
    }
  }

  void _removeParticipant(String id) {
    final participant = _participants.remove(id);
    if (participant == null) return;

    LogService().log('Conference participant left: ${participant.callsign ?? id}');

    try {
      participant.socket.close();
    } catch (_) {}

    // Notify remaining participants
    if (participant.callsign != null) {
      _broadcast(jsonEncode({
        'type': 'conference_participant_left',
        'callsign': participant.callsign,
        'role': participant.role,
      }));
    }
  }

  void _broadcast(String data, {String? excludeId}) {
    for (final p in _participants.values) {
      if (p.id == excludeId) continue;
      try {
        p.socket.add(data);
      } catch (_) {}
    }
  }
}
