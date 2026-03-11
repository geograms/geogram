/// Conference Service — orchestrates SFU (star topology) audio conferencing.
///
/// Auto-selects signaling mode:
///   - Station mode: when connected to a station, uses WebSocket signaling
///   - LAN mode: host runs a local signaling server
///
/// The host device acts as the central SFU node. Up to [maxSpeakers] people
/// speak (bidirectional audio with host), everyone else listens (receive-only).
/// All participants connect to the host only — no mesh connections.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'conference_host_peer_manager.dart';
import 'conference_participant_peer_manager.dart';
import 'conference_peer_manager.dart';
import 'conference_signaling_server.dart';
import 'devices_service.dart';
import 'log_service.dart';
import 'profile_service.dart';
import 'websocket_service.dart';
import 'webrtc_config.dart';

/// Signaling mode for the conference.
enum ConferenceSignalingMode { lan, station }

/// Role of the local participant (host vs joiner).
enum ConferenceRole { host, joiner }

/// State of the conference.
enum ConferenceState { idle, starting, active, ending }

/// Whether a participant is a speaker or listener in the SFU topology.
enum ConferenceParticipantRole { speaker, listener }

/// Participant info.
class ConferenceParticipant {
  final String callsign;
  bool isMuted;
  bool isConnected;
  ConferenceParticipantRole participantRole;

  ConferenceParticipant({
    required this.callsign,
    this.isMuted = false,
    this.isConnected = false,
    this.participantRole = ConferenceParticipantRole.listener,
  });

  bool get isSpeaker => participantRole == ConferenceParticipantRole.speaker;

  Map<String, dynamic> toJson() => {
    'callsign': callsign,
    'is_muted': isMuted,
    'is_connected': isConnected,
    'role': participantRole.name,
  };
}

/// Conference room info.
class ConferenceRoom {
  final String roomId;
  final String roomName;
  final String hostCallsign;
  final ConferenceSignalingMode signalingMode;
  final DateTime startTime;
  final Map<String, ConferenceParticipant> participants = {};
  int maxSpeakers;

  ConferenceRoom({
    required this.roomId,
    required this.roomName,
    required this.hostCallsign,
    required this.signalingMode,
    this.maxSpeakers = 6,
  }) : startTime = DateTime.now();

  List<ConferenceParticipant> get speakers =>
      participants.values.where((p) => p.isSpeaker).toList();

  List<ConferenceParticipant> get listeners =>
      participants.values.where((p) => !p.isSpeaker).toList();

  int get speakerCount => speakers.length;
  int get listenerCount => listeners.length;

  Map<String, dynamic> toJson() => {
    'room_id': roomId,
    'room_name': roomName,
    'host_callsign': hostCallsign,
    'signaling_mode': signalingMode.name,
    'participant_count': participants.length,
    'speaker_count': speakerCount,
    'listener_count': listenerCount,
    'participants': participants.values.map((p) => p.toJson()).toList(),
    'max_speakers': maxSpeakers,
    'start_time': startTime.toIso8601String(),
  };
}

/// Singleton service orchestrating audio conferencing with SFU topology.
class ConferenceService {
  static final ConferenceService _instance = ConferenceService._internal();
  factory ConferenceService() => _instance;
  ConferenceService._internal();

  ConferenceRoom? _room;
  ConferenceRole? _role;
  ConferenceState _state = ConferenceState.idle;
  ConferenceSignalingServer? _signalingServer;

  // SFU peer managers (only one is active at a time)
  ConferenceHostPeerManager? _hostPeerManager;
  ConferenceParticipantPeerManager? _participantPeerManager;

  // LAN-mode WebSocket for joiners
  WebSocket? _lanSocket;
  StreamSubscription? _lanSocketSubscription;

  // Station-mode subscription
  StreamSubscription? _stationSubscription;

  final _stateController = StreamController<ConferenceState>.broadcast();
  final _eventController = StreamController<ConferenceEvent>.broadcast();

  ConferenceRoom? get room => _room;
  ConferenceRole? get role => _role;
  ConferenceState get state => _state;
  bool get isActive => _state == ConferenceState.active;

  bool get isLocalMuted {
    if (_hostPeerManager != null) return _hostPeerManager!.isLocalMuted;
    if (_participantPeerManager != null) return _participantPeerManager!.isLocalMuted;
    return false;
  }

  int? get signalingPort => _signalingServer?.port;

  Stream<ConferenceState> get stateStream => _stateController.stream;
  Stream<ConferenceEvent> get events => _eventController.stream;

  String get _myCallsign => ProfileService().getProfile().callsign;

  // ── Host: Create a conference ────────────────────────────────────

  /// Create and host a conference. Auto-selects signaling mode.
  /// The host is always a speaker. [maxSpeakers] limits how many
  /// participants can speak (including the host).
  Future<ConferenceRoom> hostConference({
    required String roomName,
    int maxSpeakers = 6,
  }) async {
    if (_state != ConferenceState.idle) {
      throw StateError('Conference already active');
    }

    _setState(ConferenceState.starting);
    _role = ConferenceRole.host;

    final roomId = _generateRoomId();
    final callsign = _myCallsign;
    final wsService = WebSocketService();
    final mode = wsService.isConnected
        ? ConferenceSignalingMode.station
        : ConferenceSignalingMode.lan;

    _room = ConferenceRoom(
      roomId: roomId,
      roomName: roomName,
      hostCallsign: callsign,
      signalingMode: mode,
      maxSpeakers: maxSpeakers,
    );
    _room!.participants[callsign] = ConferenceParticipant(
      callsign: callsign,
      isConnected: true,
      participantRole: ConferenceParticipantRole.speaker, // Host is always a speaker
    );

    // Start host peer manager (SFU)
    _hostPeerManager = ConferenceHostPeerManager(
      config: _buildConfig(),
    );
    await _hostPeerManager!.startLocalAudio();
    _listenHostPeerEvents();

    if (mode == ConferenceSignalingMode.lan) {
      await _startLanSignaling(roomId, roomName, callsign, maxSpeakers);
    } else {
      await _startStationSignaling(roomId, roomName, maxSpeakers);
    }

    _setState(ConferenceState.active);
    LogService().log('ConferenceService: Hosting "$roomName" ($mode) as $callsign');
    return _room!;
  }

  /// The 4-letter room code (the part before @).
  String? get roomCode {
    final id = _room?.roomId;
    if (id == null) return null;
    final at = id.indexOf('@');
    return at > 0 ? id.substring(0, at) : id;
  }

  /// Get shareable LAN meet URLs (one per local IP).
  Future<List<String>> getMeetUrls() async {
    if (_signalingServer == null || !_signalingServer!.isRunning) return [];
    final port = _signalingServer!.port;
    final code = roomCode ?? '';
    final ips = await _getLocalIPs();
    return ips.map((ip) => 'http://$ip:$port/meet/$code').toList();
  }

  /// Get the station meet URL if connected to a station.
  String? get stationMeetUrl {
    final room = _room;
    if (room == null) return null;
    final stationUrl = WebSocketService().connectedUrl;
    if (stationUrl == null) return null;
    try {
      final uri = Uri.parse(stationUrl);
      final scheme = uri.scheme == 'wss' ? 'https' : 'http';
      final host = uri.host;
      final code = roomCode ?? '';
      return '$scheme://$host/${room.hostCallsign}/meet/$code';
    } catch (_) {
      return null;
    }
  }

  // ── Joiner: Join a conference ────────────────────────────────────

  /// Join a LAN-mode conference via WebSocket URL.
  /// Defaults to listener role (no mic access needed).
  Future<void> joinLan(String wsUrl, {
    ConferenceParticipantRole participantRole = ConferenceParticipantRole.listener,
  }) async {
    if (_state != ConferenceState.idle) {
      throw StateError('Conference already active');
    }

    _setState(ConferenceState.starting);
    _role = ConferenceRole.joiner;

    final sfuRole = participantRole == ConferenceParticipantRole.speaker
        ? SfuParticipantRole.speaker
        : SfuParticipantRole.listener;

    _participantPeerManager = ConferenceParticipantPeerManager(
      config: _buildConfig(),
      role: sfuRole,
    );

    // Only start audio capture for speakers
    if (participantRole == ConferenceParticipantRole.speaker) {
      await _participantPeerManager!.startLocalAudio();
    }
    _listenParticipantPeerEvents();

    // Connect to host's signaling server
    _lanSocket = await WebSocket.connect(wsUrl);
    _lanSocketSubscription = _lanSocket!.listen(
      (data) {
        if (data is String) _handleLanMessage(data);
      },
      onDone: () {
        LogService().log('ConferenceService: LAN signaling disconnected');
        if (_state == ConferenceState.active) {
          endConference();
        }
      },
      onError: (e) {
        LogService().log('ConferenceService: LAN signaling error: $e');
      },
    );

    // Set signaling callback to send through LAN WebSocket
    _participantPeerManager!.onSendSignal = (signal) {
      _lanSocket?.add(jsonEncode(signal));
    };

    // Announce ourselves with role
    _lanSocket!.add(jsonEncode({
      'type': 'conference_hello',
      'callsign': _myCallsign,
      'role': participantRole.name,
    }));

    LogService().log('ConferenceService: Joining LAN conference at $wsUrl as ${participantRole.name}');
  }

  /// Join a station-mode conference.
  /// Defaults to listener role.
  Future<void> joinStation(String roomId, {
    ConferenceParticipantRole participantRole = ConferenceParticipantRole.listener,
  }) async {
    if (_state != ConferenceState.idle) {
      throw StateError('Conference already active');
    }

    _setState(ConferenceState.starting);
    _role = ConferenceRole.joiner;

    final sfuRole = participantRole == ConferenceParticipantRole.speaker
        ? SfuParticipantRole.speaker
        : SfuParticipantRole.listener;

    _participantPeerManager = ConferenceParticipantPeerManager(
      config: _buildConfig(),
      role: sfuRole,
    );

    // Only start audio capture for speakers
    if (participantRole == ConferenceParticipantRole.speaker) {
      await _participantPeerManager!.startLocalAudio();
    }
    _listenParticipantPeerEvents();

    // Set signaling callback to send through station WebSocket
    _participantPeerManager!.onSendSignal = (signal) {
      final originalType = signal['type'] as String;
      signal['room_id'] = roomId;
      signal['signal_type'] = originalType;
      signal['type'] = 'conference_signal';
      WebSocketService().send(signal);
    };

    // Subscribe to station messages
    _stationSubscription = WebSocketService().messages.listen((msg) {
      final type = msg['type'] as String?;
      if (type == null) return;
      if (type.startsWith('conference_') || type.startsWith('webrtc_')) {
        _handleStationMessage(msg);
      }
    });

    // Send join request with role
    WebSocketService().send({
      'type': 'conference_join',
      'room_id': roomId,
      'role': participantRole.name,
    });

    LogService().log('ConferenceService: Joining station conference $roomId as ${participantRole.name}');
  }

  // ── Discovery: find meeting by room ID ──────────────────────────

  /// Discover and join a meeting from a room ID with `@callsign` suffix.
  Future<void> discoverAndJoin(String roomId, {
    ConferenceParticipantRole participantRole = ConferenceParticipantRole.listener,
  }) async {
    final atIndex = roomId.indexOf('@');
    if (atIndex < 0) {
      throw ArgumentError('Room ID must contain @callsign: $roomId');
    }
    final hostCallsign = roomId.substring(atIndex + 1);

    LogService().log('ConferenceService: Discovering meeting $roomId '
        '(host: $hostCallsign)');

    // Try LAN discovery first
    final devices = DevicesService().getAllDevices();
    final hostDevice = devices.cast<RemoteDevice?>().firstWhere(
      (d) => d!.callsign.toUpperCase() == hostCallsign.toUpperCase(),
      orElse: () => null,
    );

    if (hostDevice?.url != null) {
      try {
        final baseUrl = hostDevice!.url!;
        final uri = Uri.parse('$baseUrl/api/meet/active');
        final response = await http.get(uri).timeout(
          const Duration(seconds: 5),
        );

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          final activeRoomId = data['room_id'] as String?;
          final sigPort = data['signaling_port'] as int?;

          if (activeRoomId == roomId && sigPort != null) {
            final host = Uri.parse(baseUrl).host;
            final wsUrl = 'ws://$host:$sigPort/meet/ws';
            LogService().log(
                'ConferenceService: Found meeting via LAN at $wsUrl');
            await joinLan(wsUrl, participantRole: participantRole);
            return;
          }
        }
      } catch (e) {
        LogService().log(
            'ConferenceService: LAN discovery failed: $e');
      }
    }

    // Fallback: try station relay
    final wsService = WebSocketService();
    if (wsService.isConnected) {
      LogService().log(
          'ConferenceService: Trying station relay for $roomId');
      await joinStation(roomId, participantRole: participantRole);
      return;
    }

    throw StateError(
      'Meeting not found. Make sure the host is on the same network '
      'or connected to the same station.',
    );
  }

  // ── Mute ─────────────────────────────────────────────────────────

  void toggleMute() {
    _hostPeerManager?.toggleMute();
    _participantPeerManager?.toggleMute();
  }

  void setMuted(bool muted) {
    _hostPeerManager?.setMuted(muted);
    _participantPeerManager?.setMuted(muted);
  }

  // ── Promote / demote (host only) ─────────────────────────────────

  /// Promote a listener to speaker. Host-only operation.
  Future<void> promoteToSpeaker(String callsign) async {
    if (_role != ConferenceRole.host || _hostPeerManager == null) {
      throw StateError('Only the host can promote participants');
    }

    final room = _room;
    if (room == null) return;

    // Check speaker limit
    if (room.speakerCount >= room.maxSpeakers) {
      throw StateError('Speaker limit reached (${room.maxSpeakers})');
    }

    // Update local state
    final p = room.participants[callsign];
    if (p != null) {
      p.participantRole = ConferenceParticipantRole.speaker;
    }

    // Renegotiate the connection
    await _hostPeerManager!.promoteToSpeaker(callsign);

    // Send role change notification via signaling
    _sendRoleChange(callsign, 'speaker');
    _eventController.add(ConferenceEvent('role_changed', callsign, 'speaker'));

    LogService().log('ConferenceService: Promoted $callsign to speaker');
  }

  /// Demote a speaker to listener. Host-only operation.
  Future<void> demoteToListener(String callsign) async {
    if (_role != ConferenceRole.host || _hostPeerManager == null) {
      throw StateError('Only the host can demote participants');
    }

    final room = _room;
    if (room == null) return;

    // Update local state
    final p = room.participants[callsign];
    if (p != null) {
      p.participantRole = ConferenceParticipantRole.listener;
    }

    // Renegotiate the connection
    await _hostPeerManager!.demoteToListener(callsign);

    // Send role change notification via signaling
    _sendRoleChange(callsign, 'listener');
    _eventController.add(ConferenceEvent('role_changed', callsign, 'listener'));

    LogService().log('ConferenceService: Demoted $callsign to listener');
  }

  void _sendRoleChange(String callsign, String newRole) {
    final msg = {
      'type': 'conference_role_change',
      'callsign': callsign,
      'role': newRole,
    };

    if (_room?.signalingMode == ConferenceSignalingMode.lan) {
      _signalingServer?.broadcastRoleChangeFromHost(callsign, newRole);
    } else {
      msg['room_id'] = _room?.roomId ?? '';
      WebSocketService().send(msg);
    }
  }

  // ── End conference ───────────────────────────────────────────────

  Future<void> endConference() async {
    if (_state == ConferenceState.idle || _state == ConferenceState.ending) {
      return;
    }

    _setState(ConferenceState.ending);

    // Clean up signaling
    if (_role == ConferenceRole.host) {
      if (_room?.signalingMode == ConferenceSignalingMode.station) {
        WebSocketService().send({
          'type': 'conference_end',
          'room_id': _room?.roomId,
        });
      }
      await _signalingServer?.stop();
      _signalingServer = null;
    } else {
      if (_room?.signalingMode == ConferenceSignalingMode.lan) {
        _lanSocket?.add(jsonEncode({
          'type': 'conference_leave',
          'callsign': _myCallsign,
        }));
      } else {
        WebSocketService().send({
          'type': 'conference_leave',
          'room_id': _room?.roomId,
        });
      }
    }

    _lanSocketSubscription?.cancel();
    _lanSocketSubscription = null;
    try { _lanSocket?.close(); } catch (_) {}
    _lanSocket = null;
    _stationSubscription?.cancel();
    _stationSubscription = null;

    await _hostPeerManager?.dispose();
    _hostPeerManager = null;
    await _participantPeerManager?.dispose();
    _participantPeerManager = null;

    _room = null;
    _role = null;
    _setState(ConferenceState.idle);
    LogService().log('ConferenceService: Conference ended');
  }

  // ── LAN signaling (host) ────────────────────────────────────────

  Future<void> _startLanSignaling(
      String roomId, String roomName, String callsign, int maxSpeakers) async {
    _signalingServer = ConferenceSignalingServer(
      roomId: roomId,
      roomName: roomName,
      hostCallsign: callsign,
      maxSpeakers: maxSpeakers,
    );

    // Load and set web client HTML
    try {
      final htmlFile = File('assets/conference/index.html');
      if (await htmlFile.exists()) {
        _signalingServer!.setWebClientHtml(await htmlFile.readAsString());
      }
    } catch (e) {
      LogService().log('ConferenceService: Web client HTML not found: $e');
    }

    final port = await _signalingServer!.start();
    LogService().log('ConferenceService: LAN signaling on port $port');

    _signalingServer!.onHostMessage = (message) {
      _handleLanMessage(jsonEncode(message));
    };

    // LAN host signaling stays in-process; the signaling server relays
    // joiner signals back to the host and tracks the host implicitly.
    _hostPeerManager!.onSendSignal = (signal) {
      _signalingServer?.relayFromHost(signal);
    };
  }

  // ── Station signaling (host) ─────────────────────────────────────

  Future<void> _startStationSignaling(
      String roomId, String roomName, int maxSpeakers) async {
    // Subscribe to station messages
    _stationSubscription = WebSocketService().messages.listen((msg) {
      final type = msg['type'] as String?;
      if (type == null) return;
      if (type.startsWith('conference_') || type.startsWith('webrtc_')) {
        _handleStationMessage(msg);
      }
    });

    // Set signaling callback
    _hostPeerManager!.onSendSignal = (signal) {
      final originalType = signal['type'] as String;
      signal['room_id'] = roomId;
      signal['signal_type'] = originalType;
      signal['type'] = 'conference_signal';
      WebSocketService().send(signal);
    };

    // Create room on station
    WebSocketService().send({
      'type': 'conference_create',
      'room_id': roomId,
      'room_name': roomName,
      'max_speakers': maxSpeakers,
    });
  }

  // ── Message handling ─────────────────────────────────────────────

  void _handleLanMessage(String raw) {
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    final type = msg['type'] as String?;
    if (type == null) return;

    switch (type) {
      case 'conference_welcome':
        _handleWelcome(msg);
      case 'conference_participant_joined':
        _handleParticipantJoined(msg);
      case 'conference_participant_left':
        _handleParticipantLeft(msg);
      case 'conference_end':
        _handleConferenceEnd(msg);
      case 'conference_role_change':
        _handleRoleChange(msg);
      case 'conference_error':
        LogService().log('ConferenceService: Error: ${msg['error']}');
      // WebRTC signals
      case 'webrtc_offer':
        _handleWebRTCOffer(msg);
      case 'webrtc_answer':
        _handleWebRTCAnswer(msg);
      case 'webrtc_ice':
        _handleWebRTCIce(msg);
      case 'webrtc_bye':
        _handleWebRTCBye(msg);
    }
  }

  void _handleStationMessage(Map<String, dynamic> msg) {
    final type = msg['type'] as String?;
    if (type == null) return;

    switch (type) {
      case 'conference_created':
        LogService().log('ConferenceService: Room created on station');
      case 'conference_welcome':
        _handleWelcome(msg);
      case 'conference_participant_joined':
        _handleParticipantJoined(msg);
      case 'conference_participant_left':
        _handleParticipantLeft(msg);
      case 'conference_end':
        _handleConferenceEnd(msg);
      case 'conference_role_change':
        _handleRoleChange(msg);
      case 'conference_error':
        LogService().log('ConferenceService: Station error: ${msg['error']}');
      case 'conference_signal':
        // Unwrap the inner signal type
        final signalType = msg['signal_type'] as String?;
        if (signalType != null) {
          msg['type'] = signalType;
          switch (signalType) {
            case 'webrtc_offer':
              _handleWebRTCOffer(msg);
            case 'webrtc_answer':
              _handleWebRTCAnswer(msg);
            case 'webrtc_ice':
              _handleWebRTCIce(msg);
            case 'webrtc_bye':
              _handleWebRTCBye(msg);
          }
        }
    }
  }

  void _handleWelcome(Map<String, dynamic> msg) {
    final roomId = msg['room_id'] as String? ?? _room?.roomId ?? '';
    final roomName = msg['room_name'] as String? ?? _room?.roomName ?? '';
    final hostCallsign = msg['host_callsign'] as String? ?? '';
    final speakers = (msg['speakers'] as List?)?.cast<String>() ?? [];
    final participants = msg['participants'] as List?;

    if (_room == null) {
      // Joiner — create room info from welcome
      _room = ConferenceRoom(
        roomId: roomId,
        roomName: roomName,
        hostCallsign: hostCallsign,
        signalingMode: _lanSocket != null
            ? ConferenceSignalingMode.lan
            : ConferenceSignalingMode.station,
        maxSpeakers: msg['max_speakers'] as int? ?? 6,
      );
    }

    // Add existing participants with their roles
    if (participants != null) {
      for (final p in participants) {
        final callsign = p is String ? p : (p as Map<String, dynamic>)['callsign'] as String? ?? '';
        if (callsign.isEmpty) continue;
        final isSpeaker = speakers.contains(callsign);
        _room!.participants[callsign] = ConferenceParticipant(
          callsign: callsign,
          participantRole: isSpeaker
              ? ConferenceParticipantRole.speaker
              : ConferenceParticipantRole.listener,
        );
      }
    }

    // Add self
    final myRole = _participantPeerManager?.role == SfuParticipantRole.speaker
        ? ConferenceParticipantRole.speaker
        : ConferenceParticipantRole.listener;
    _room!.participants[_myCallsign] = ConferenceParticipant(
      callsign: _myCallsign,
      isConnected: true,
      participantRole: myRole,
    );

    // In star topology, participant only connects to host
    if (_role == ConferenceRole.joiner && _participantPeerManager != null) {
      _participantPeerManager!.connectToHost(hostCallsign);
    }

    _setState(ConferenceState.active);
    LogService().log('ConferenceService: Welcome received, '
        '${speakers.length} speakers, host=$hostCallsign');
  }

  void _handleParticipantJoined(Map<String, dynamic> msg) {
    final callsign = msg['callsign'] as String?;
    if (callsign == null || callsign == _myCallsign) return;

    final role = msg['role'] as String? ?? 'listener';
    final participantRole = role == 'speaker'
        ? ConferenceParticipantRole.speaker
        : ConferenceParticipantRole.listener;

    _room?.participants[callsign] = ConferenceParticipant(
      callsign: callsign,
      participantRole: participantRole,
    );
    _eventController.add(ConferenceEvent('peer_connected', callsign));

    // In star topology, the joiner sends the offer to host.
    // Host just waits for the offer.
    LogService().log('ConferenceService: $callsign joined as $role');
  }

  void _handleParticipantLeft(Map<String, dynamic> msg) {
    final callsign = msg['callsign'] as String?;
    if (callsign == null) return;

    _room?.participants.remove(callsign);

    if (_role == ConferenceRole.host) {
      _hostPeerManager?.handleBye(callsign);
    } else {
      _participantPeerManager?.handleBye(callsign);
    }

    _eventController.add(ConferenceEvent('peer_disconnected', callsign));
    LogService().log('ConferenceService: $callsign left');
  }

  void _handleConferenceEnd(Map<String, dynamic> msg) {
    LogService().log('ConferenceService: Conference ended by host');
    endConference();
  }

  void _handleRoleChange(Map<String, dynamic> msg) {
    final callsign = msg['callsign'] as String?;
    final newRole = msg['role'] as String?;
    if (callsign == null || newRole == null) return;

    final participantRole = newRole == 'speaker'
        ? ConferenceParticipantRole.speaker
        : ConferenceParticipantRole.listener;

    // Update local participant state
    final p = _room?.participants[callsign];
    if (p != null) {
      p.participantRole = participantRole;
    }

    // If this role change is for us (we're a participant)
    if (callsign == _myCallsign && _participantPeerManager != null) {
      if (participantRole == ConferenceParticipantRole.speaker) {
        _participantPeerManager!.onPromotedToSpeaker();
      } else {
        _participantPeerManager!.onDemotedToListener();
      }
    }

    _eventController.add(ConferenceEvent('role_changed', callsign, newRole));
    LogService().log('ConferenceService: $callsign role changed to $newRole');
  }

  // ── WebRTC signal handling ───────────────────────────────────────

  void _handleWebRTCOffer(Map<String, dynamic> msg) {
    final from = msg['from_callsign'] as String?;
    final sessionId = msg['session_id'] as String?;
    final sdp = msg['sdp'] as Map<String, dynamic>?;
    if (from == null || sessionId == null || sdp == null) return;

    if (_role == ConferenceRole.host && _hostPeerManager != null) {
      final role = msg['role'] as String?;
      _hostPeerManager!.handleOffer(from, sessionId, sdp, role: role);
    } else if (_participantPeerManager != null) {
      // Renegotiation offer from host
      _participantPeerManager!.handleOffer(from, sessionId, sdp);
    }
  }

  void _handleWebRTCAnswer(Map<String, dynamic> msg) {
    final from = msg['from_callsign'] as String?;
    final sdp = msg['sdp'] as Map<String, dynamic>?;
    if (from == null || sdp == null) return;

    if (_role == ConferenceRole.host) {
      _hostPeerManager?.handleAnswer(from, sdp);
    } else {
      _participantPeerManager?.handleAnswer(from, sdp);
    }
  }

  void _handleWebRTCIce(Map<String, dynamic> msg) {
    final from = msg['from_callsign'] as String?;
    final candidate = msg['candidate'] as Map<String, dynamic>?;
    if (from == null || candidate == null) return;

    if (_role == ConferenceRole.host) {
      _hostPeerManager?.handleIceCandidate(from, candidate);
    } else {
      _participantPeerManager?.handleIceCandidate(from, candidate);
    }
  }

  void _handleWebRTCBye(Map<String, dynamic> msg) {
    final from = msg['from_callsign'] as String?;
    if (from == null) return;

    if (_role == ConferenceRole.host) {
      _hostPeerManager?.handleBye(from);
    } else {
      _participantPeerManager?.handleBye(from);
    }
    _room?.participants.remove(from);
  }

  // ── Helpers ──────────────────────────────────────────────────────

  void _setState(ConferenceState s) {
    _state = s;
    _stateController.add(s);
  }

  void _listenHostPeerEvents() {
    _hostPeerManager?.events.listen((event) {
      _eventController.add(event);

      final p = _room?.participants[event.callsign];
      if (p != null) {
        p.isConnected = event.type == 'peer_connected';
      }
    });
  }

  void _listenParticipantPeerEvents() {
    _participantPeerManager?.events.listen((event) {
      _eventController.add(event);

      // For participant, the host connection state affects all participants
      if (event.type == 'peer_connected') {
        // Mark host as connected
        final p = _room?.participants[event.callsign];
        if (p != null) p.isConnected = true;
      }
    });
  }

  WebRTCConfig _buildConfig() {
    final wsService = WebSocketService();
    final stunInfo = wsService.connectedStationStunInfo;
    final stationUrl = wsService.connectedUrl;

    if (stunInfo != null && stunInfo.enabled && stationUrl != null) {
      try {
        final uri = Uri.parse(stationUrl);
        return WebRTCConfig.withStationStun(
          stationHost: uri.host,
          stunPort: stunInfo.port,
        );
      } catch (_) {}
    }
    return const WebRTCConfig();
  }

  String _generateRoomId() {
    final r = Random();
    final letters = String.fromCharCodes(
        List.generate(4, (_) => r.nextInt(26) + 65));
    final callsign = _myCallsign;
    return '$letters@$callsign';
  }

  Future<List<String>> _getLocalIPs() async {
    final interfaces = await NetworkInterface.list();
    return interfaces
        .expand((i) => i.addresses)
        .where((a) => a.type == InternetAddressType.IPv4 && !a.isLoopback)
        .map((a) => a.address)
        .toList();
  }
}
