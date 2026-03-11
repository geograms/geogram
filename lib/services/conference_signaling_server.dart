/// Conference Signaling Server (LAN mode) — SFU star topology.
///
/// Lightweight HTTP + WebSocket server run by the host client to coordinate
/// WebRTC audio conferencing on a local network without a station.
///
/// In star topology, participants connect only to the host. The signaling
/// server relays WebRTC signals between host and each participant.
/// Speakers are limited by [maxSpeakers]; listeners are unlimited.
/// At most one participant may share a screen at a time.
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
import '../util/nostr_bundle.dart';

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
  String? _activeScreenSharerCallsign;
  String? _webClientHtml;
  String _webClientGlobalStyles = '';
  String _webClientAppStyles = '';
  void Function(Map<String, dynamic> message)? onHostMessage;

  int? get port => _httpServer?.port;
  bool get isRunning => _httpServer != null;
  int get participantCount => participantCallsigns.length;

  List<String> get participantCallsigns => <String>{
    hostCallsign,
    ..._participants.values
        .where((p) => p.callsign != null)
        .map((p) => p.callsign!),
  }.toList();

  List<String> get speakerCallsigns => <String>{
    hostCallsign,
    ..._participants.values
        .where((p) => p.callsign != null && p.isSpeaker)
        .map((p) => p.callsign!),
  }.toList();

  int get listenerCount => participantCount - speakerCount;

  int get speakerCount => speakerCallsigns.length;

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

    _httpServer!.listen(
      _handleRequest,
      onError: (e) {
        LogService().log('Conference server error: $e');
      },
    );

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

  /// Set the browser client assets served by the LAN signaling server.
  void setWebClientAssets({
    required String html,
    String globalStyles = '',
    String appStyles = '',
  }) {
    _webClientHtml = html;
    _webClientGlobalStyles = globalStyles;
    _webClientAppStyles = appStyles;
  }

  // ── Request routing ──────────────────────────────────────────────

  void _handleRequest(HttpRequest request) {
    final path = request.uri.path;
    switch (path) {
      case '/styles.css':
        _handleStyles(request, _webClientGlobalStyles);
      case '/meet/info':
        _handleInfo(request);
      case '/meet/active':
        _handleActive(request);
      case '/meet/styles.css':
        _handleStyles(request, _webClientAppStyles);
      case '/lib/nostr.bundle.js':
        _handleNostrBundle(request);
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
      'active_screen_sharer': _activeScreenSharerCallsign,
    };
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(info))
      ..close();
  }

  // ── GET /meet/active ───────────────────────────────────────────

  void _handleActive(HttpRequest request) {
    final info = {
      'room_id': roomId,
      'room_name': roomName,
      'host_callsign': hostCallsign,
      'signaling_mode': 'lan',
      'signaling_port': _httpServer?.port,
      'participant_count': participantCount,
      'max_participants': maxSpeakers,
      'active_screen_sharer': _activeScreenSharerCallsign,
    };
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(info))
      ..close();
  }

  void _handleStyles(HttpRequest request, String content) {
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType('text', 'css', charset: 'utf-8')
      ..write(content)
      ..close();
  }

  void _handleNostrBundle(HttpRequest request) {
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType(
        'application',
        'javascript',
        charset: 'utf-8',
      )
      ..headers.set(HttpHeaders.cacheControlHeader, 'public, max-age=86400')
      ..write(getNostrBundleJs())
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

    final id =
        '${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(999999)}';
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
      case 'conference_speaker_request':
        _handleSpeakerRequest(sender);
      case 'conference_screen_share_request':
        _handleScreenShareRequest(sender);
      case 'conference_screen_share_permission':
        _handleScreenSharePermission(sender, message);
      case 'conference_screen_share_state':
        _handleScreenShareState(sender, message);
      case 'conference_screen_share_stop':
        _handleScreenShareStop(sender, message);
      case 'conference_chat_message':
        _handleChatMessage(sender, message);
      case 'conference_chat_history':
        _handleChatHistory(sender, message);
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
        'Conference: $callsign wanted speaker but limit reached, joining as listener',
      );
    } else {
      sender.role = requestedRole;
    }

    sender.callsign = callsign;
    LogService().log(
      'Conference participant identified: $callsign (${sender.role})',
    );

    // Send the current participant list to the new joiner
    final existing = <String>{
      hostCallsign,
      ..._participants.values
          .where((p) => p.id != sender.id && p.callsign != null)
          .map((p) => p.callsign!),
    }.toList();

    final speakers = <String>{
      hostCallsign,
      ..._participants.values
          .where((p) => p.id != sender.id && p.callsign != null && p.isSpeaker)
          .map((p) => p.callsign!),
    }.toList();

    sender.socket.add(
      jsonEncode({
        'type': 'conference_welcome',
        'room_id': roomId,
        'room_name': roomName,
        'host_callsign': hostCallsign,
        'participants': existing,
        'speakers': speakers,
        'listener_count': listenerCount,
        'max_speakers': maxSpeakers,
        'active_screen_sharer': _activeScreenSharerCallsign,
      }),
    );

    // Notify existing participants about the new joiner
    _broadcast(
      jsonEncode({
        'type': 'conference_participant_joined',
        'callsign': callsign,
        'role': sender.role,
      }),
      excludeId: sender.id,
    );
    onHostMessage?.call({
      'type': 'conference_participant_joined',
      'callsign': callsign,
      'role': sender.role,
    });
  }

  void _handleRoleChange(
    SignalingParticipant sender,
    Map<String, dynamic> message,
  ) {
    final targetCallsign = message['callsign'] as String?;
    final newRole = message['role'] as String?;
    if (targetCallsign == null || newRole == null) return;

    // Only host can change roles
    if (sender.callsign != hostCallsign) return;

    // Update the target's role
    final target = _participants.values
        .cast<SignalingParticipant?>()
        .firstWhere(
          (p) => p!.callsign?.toLowerCase() == targetCallsign.toLowerCase(),
          orElse: () => null,
        );

    if (target != null) {
      target.role = newRole;
    }

    // Broadcast role change to all participants
    final roleChange = {
      'type': 'conference_role_change',
      'callsign': targetCallsign,
      'role': newRole,
    };
    _broadcast(jsonEncode(roleChange));
    onHostMessage?.call(roleChange);
  }

  void _handleSpeakerRequest(SignalingParticipant sender) {
    final callsign = sender.callsign;
    if (callsign == null || callsign == hostCallsign) {
      return;
    }

    onHostMessage?.call({
      'type': 'conference_speaker_request',
      'room_id': roomId,
      'callsign': callsign,
    });
  }

  void _handleScreenShareRequest(SignalingParticipant sender) {
    final callsign = sender.callsign;
    if (callsign == null || callsign == hostCallsign) {
      return;
    }

    onHostMessage?.call({
      'type': 'conference_screen_share_request',
      'room_id': roomId,
      'callsign': callsign,
    });
  }

  void _handleScreenSharePermission(
    SignalingParticipant sender,
    Map<String, dynamic> message,
  ) {
    if (sender.callsign != hostCallsign) {
      return;
    }

    final toCallsign = message['to_callsign'] as String?;
    final callsign = message['callsign'] as String?;
    final approved = message['approved'] == true;
    if (toCallsign == null || callsign == null) {
      return;
    }

    sendRoomMessageFromHost({
      'type': 'conference_screen_share_permission',
      'room_id': roomId,
      'callsign': callsign,
      'approved': approved,
    }, toCallsign: toCallsign);
  }

  void _handleScreenShareState(
    SignalingParticipant sender,
    Map<String, dynamic> message,
  ) {
    if (sender.callsign != hostCallsign) {
      return;
    }

    final callsign = message['callsign'] as String?;
    final active = message['active'] == true;
    if (callsign == null || callsign.isEmpty) {
      return;
    }

    _activeScreenSharerCallsign = active ? callsign : null;
    sendRoomMessageFromHost({
      'type': 'conference_screen_share_state',
      'room_id': roomId,
      'callsign': callsign,
      'active': active,
    });
  }

  void _handleScreenShareStop(
    SignalingParticipant sender,
    Map<String, dynamic> message,
  ) {
    final callsign = sender.callsign;
    if (callsign == null || callsign == hostCallsign) {
      return;
    }

    onHostMessage?.call({
      'type': 'conference_screen_share_stop',
      'room_id': roomId,
      'callsign': message['callsign'] as String? ?? callsign,
    });
  }

  void _handleChatMessage(
    SignalingParticipant sender,
    Map<String, dynamic> message,
  ) {
    final callsign = sender.callsign;
    if (callsign == null) return;

    final payload = {
      'type': 'conference_chat_message',
      'room_id': roomId,
      'from_callsign': callsign,
      'message': message['message'],
    };

    if (callsign.toLowerCase() != hostCallsign.toLowerCase()) {
      onHostMessage?.call(payload);
    }
    _broadcast(jsonEncode(payload), excludeId: sender.id);
  }

  void _handleChatHistory(
    SignalingParticipant sender,
    Map<String, dynamic> message,
  ) {
    if (sender.callsign?.toLowerCase() != hostCallsign.toLowerCase()) {
      return;
    }

    final toCallsign = message['to_callsign'] as String?;
    if (toCallsign == null || toCallsign.isEmpty) {
      return;
    }

    sendRoomMessageFromHost({
      'type': 'conference_chat_history',
      'room_id': roomId,
      'messages': message['messages'],
    }, toCallsign: toCallsign);
  }

  /// Relay a WebRTC signal to a specific participant identified by to_callsign.
  void _relaySignal(SignalingParticipant sender, Map<String, dynamic> message) {
    final toCallsign = message['to_callsign'] as String?;
    if (toCallsign == null) return;

    // Ensure from_callsign is set (use sender's callsign)
    message['from_callsign'] = sender.callsign ?? sender.id;

    if (toCallsign.toLowerCase() == hostCallsign.toLowerCase()) {
      onHostMessage?.call(message);
      return;
    }

    final target = _participants.values
        .cast<SignalingParticipant?>()
        .firstWhere(
          (p) => p!.callsign?.toLowerCase() == toCallsign.toLowerCase(),
          orElse: () => null,
        );

    if (target == null) {
      sender.socket.add(
        jsonEncode({
          'type': 'webrtc_error',
          'error': 'target_not_connected',
          'to_callsign': toCallsign,
        }),
      );
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

    LogService().log(
      'Conference participant left: ${participant.callsign ?? id}',
    );

    try {
      participant.socket.close();
    } catch (_) {}

    // Notify remaining participants
    if (participant.callsign != null) {
      if (_activeScreenSharerCallsign?.toLowerCase() ==
          participant.callsign!.toLowerCase()) {
        _activeScreenSharerCallsign = null;
      }
      final leftMessage = {
        'type': 'conference_participant_left',
        'callsign': participant.callsign,
        'role': participant.role,
      };
      _broadcast(jsonEncode(leftMessage));
      onHostMessage?.call(leftMessage);
    }
  }

  /// Relay a host-originated WebRTC signal to a participant.
  void relayFromHost(Map<String, dynamic> message) {
    final toCallsign = message['to_callsign'] as String?;
    if (toCallsign == null || toCallsign.isEmpty) return;

    final target = _participants.values
        .cast<SignalingParticipant?>()
        .firstWhere(
          (p) => p!.callsign?.toLowerCase() == toCallsign.toLowerCase(),
          orElse: () => null,
        );
    if (target == null) return;

    final payload = Map<String, dynamic>.from(message);
    payload['from_callsign'] = hostCallsign;
    try {
      target.socket.add(jsonEncode(payload));
    } catch (e) {
      LogService().log('Conference relay from host failed to $toCallsign: $e');
    }
  }

  void sendRoomMessageFromHost(
    Map<String, dynamic> message, {
    String? toCallsign,
  }) {
    final payload = Map<String, dynamic>.from(message)
      ..putIfAbsent('room_id', () => roomId)
      ..putIfAbsent('from_callsign', () => hostCallsign);

    _applyHostRoomStateMessage(payload);

    if (toCallsign != null && toCallsign.isNotEmpty) {
      final target = _participants.values
          .cast<SignalingParticipant?>()
          .firstWhere(
            (p) => p!.callsign?.toLowerCase() == toCallsign.toLowerCase(),
            orElse: () => null,
          );
      if (target == null) return;
      try {
        target.socket.add(jsonEncode(payload));
      } catch (e) {
        LogService().log(
          'Conference direct room message failed to $toCallsign: $e',
        );
      }
      return;
    }

    _broadcast(jsonEncode(payload));
  }

  void _applyHostRoomStateMessage(Map<String, dynamic> message) {
    final type = message['type'] as String?;
    switch (type) {
      case 'conference_screen_share_state':
        final callsign = message['callsign'] as String?;
        final active = message['active'] == true;
        if (active && callsign != null && callsign.isNotEmpty) {
          _activeScreenSharerCallsign = callsign;
        } else if (!active) {
          _activeScreenSharerCallsign = null;
        }
      case 'conference_screen_share_stop':
        final callsign = message['callsign'] as String?;
        if (callsign == null ||
            _activeScreenSharerCallsign?.toLowerCase() ==
                callsign.toLowerCase()) {
          _activeScreenSharerCallsign = null;
        }
    }
  }

  /// Broadcast a host-originated role change to all participants.
  void broadcastRoleChangeFromHost(String callsign, String newRole) {
    final target = _participants.values
        .cast<SignalingParticipant?>()
        .firstWhere(
          (p) => p!.callsign?.toLowerCase() == callsign.toLowerCase(),
          orElse: () => null,
        );
    if (target != null) {
      target.role = newRole;
    }

    final payload = {
      'type': 'conference_role_change',
      'callsign': callsign,
      'role': newRole,
    };
    _broadcast(jsonEncode(payload));
    onHostMessage?.call(payload);
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
