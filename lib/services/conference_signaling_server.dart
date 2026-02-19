/// Conference Signaling Server (LAN mode)
///
/// Lightweight HTTP + WebSocket server run by the host client to coordinate
/// WebRTC audio conferencing on a local network without a station.
///
/// Endpoints:
///   GET  /meet/{code}      — shareable URL, serves the browser web client
///   GET  /conference/info  — room info (host callsign, room name, participants)
///   WS   /conference/ws    — WebSocket for signaling relay
///   GET  /conference/web   — serves the browser-based web client (legacy)
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
  DateTime connectedAt;

  SignalingParticipant({
    required this.id,
    required this.socket,
    this.callsign,
  }) : connectedAt = DateTime.now();
}

/// Lightweight signaling server for LAN-mode audio conferences.
///
/// The host client starts this server so peers on the same network can
/// exchange WebRTC offers / answers / ICE candidates without a station.
class ConferenceSignalingServer {
  HttpServer? _httpServer;
  final Map<String, SignalingParticipant> _participants = {};
  final String roomId;
  final String roomName;
  final String hostCallsign;
  final int maxParticipants;
  String? _webClientHtml;

  int? get port => _httpServer?.port;
  bool get isRunning => _httpServer != null;
  int get participantCount => _participants.length;
  List<String> get participantCallsigns =>
      _participants.values
          .where((p) => p.callsign != null)
          .map((p) => p.callsign!)
          .toList();

  ConferenceSignalingServer({
    required this.roomId,
    required this.roomName,
    required this.hostCallsign,
    this.maxParticipants = 6,
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

  /// Set the HTML content served at /conference/web.
  void setWebClientHtml(String html) {
    _webClientHtml = html;
  }

  // ── Request routing ──────────────────────────────────────────────

  /// The 4-letter room code (the part before @).
  String get _roomCode {
    final at = roomId.indexOf('@');
    return at > 0 ? roomId.substring(0, at) : roomId;
  }

  void _handleRequest(HttpRequest request) {
    final path = request.uri.path;
    switch (path) {
      case '/conference/info':
        _handleInfo(request);
      case '/conference/ws':
        _handleWebSocket(request);
      case '/conference/web':
        _handleWebClient(request);
      default:
        // Handle /meet/XXXX — serves the web client at the shareable URL
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

  // ── GET /conference/info ─────────────────────────────────────────

  void _handleInfo(HttpRequest request) {
    final info = {
      'room_id': roomId,
      'room_name': roomName,
      'host_callsign': hostCallsign,
      'participant_count': participantCount,
      'participants': participantCallsigns,
      'max_participants': maxParticipants,
    };
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(info))
      ..close();
  }

  // ── GET /conference/web ──────────────────────────────────────────

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

  // ── WS /conference/ws ───────────────────────────────────────────

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
      // Participant announces itself with a callsign
      case 'conference_hello':
        _handleHello(sender, message);

      // WebRTC signaling — relay to target participant
      case 'webrtc_offer':
      case 'webrtc_answer':
      case 'webrtc_ice':
      case 'webrtc_bye':
        _relaySignal(sender, message);

      // Participant leaves
      case 'conference_leave':
        _removeParticipant(sender.id);
    }
  }

  void _handleHello(SignalingParticipant sender, Map<String, dynamic> message) {
    final callsign = message['callsign'] as String?;
    if (callsign == null || callsign.isEmpty) return;

    if (_participants.length > maxParticipants) {
      sender.socket.add(jsonEncode({
        'type': 'conference_error',
        'error': 'room_full',
        'max_participants': maxParticipants,
      }));
      _removeParticipant(sender.id);
      return;
    }

    sender.callsign = callsign;
    LogService().log('Conference participant identified: $callsign');

    // Send the current participant list to the new joiner
    final existing = _participants.values
        .where((p) => p.id != sender.id && p.callsign != null)
        .map((p) => p.callsign!)
        .toList();

    sender.socket.add(jsonEncode({
      'type': 'conference_welcome',
      'room_id': roomId,
      'room_name': roomName,
      'host_callsign': hostCallsign,
      'participants': existing,
    }));

    // Notify existing participants about the new joiner
    _broadcast(
      jsonEncode({
        'type': 'conference_participant_joined',
        'callsign': callsign,
      }),
      excludeId: sender.id,
    );
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
