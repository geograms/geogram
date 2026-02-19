/// Conference Service — orchestrates P2P audio conferencing.
///
/// Auto-selects signaling mode:
///   • Station mode: when connected to a station, uses WebSocket signaling
///   • LAN mode: host runs a local signaling server
///
/// Manages conference lifecycle for both hosts and joiners.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'conference_peer_manager.dart';
import 'conference_signaling_server.dart';
import 'devices_service.dart';
import 'log_service.dart';
import 'profile_service.dart';
import 'websocket_service.dart';
import 'webrtc_config.dart';

/// Signaling mode for the conference.
enum ConferenceSignalingMode { lan, station }

/// Role of the local participant.
enum ConferenceRole { host, joiner }

/// State of the conference.
enum ConferenceState { idle, starting, active, ending }

/// Participant info.
class ConferenceParticipant {
  final String callsign;
  bool isMuted;
  bool isConnected;

  ConferenceParticipant({
    required this.callsign,
    this.isMuted = false,
    this.isConnected = false,
  });

  Map<String, dynamic> toJson() => {
    'callsign': callsign,
    'is_muted': isMuted,
    'is_connected': isConnected,
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
  int maxParticipants;

  ConferenceRoom({
    required this.roomId,
    required this.roomName,
    required this.hostCallsign,
    required this.signalingMode,
    this.maxParticipants = 6,
  }) : startTime = DateTime.now();

  Map<String, dynamic> toJson() => {
    'room_id': roomId,
    'room_name': roomName,
    'host_callsign': hostCallsign,
    'signaling_mode': signalingMode.name,
    'participant_count': participants.length,
    'participants': participants.values.map((p) => p.toJson()).toList(),
    'max_participants': maxParticipants,
    'start_time': startTime.toIso8601String(),
  };
}

/// Singleton service orchestrating audio conferencing.
class ConferenceService {
  static final ConferenceService _instance = ConferenceService._internal();
  factory ConferenceService() => _instance;
  ConferenceService._internal();

  ConferenceRoom? _room;
  ConferenceRole? _role;
  ConferenceState _state = ConferenceState.idle;
  ConferencePeerManager? _peerManager;
  ConferenceSignalingServer? _signalingServer;

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
  bool get isLocalMuted => _peerManager?.isLocalMuted ?? false;

  int? get signalingPort => _signalingServer?.port;

  Stream<ConferenceState> get stateStream => _stateController.stream;
  Stream<ConferenceEvent> get events => _eventController.stream;

  String get _myCallsign => ProfileService().getProfile().callsign;

  // ── Host: Create a conference ────────────────────────────────────

  /// Create and host a conference. Auto-selects signaling mode.
  Future<ConferenceRoom> hostConference({
    required String roomName,
    int maxParticipants = 6,
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
      maxParticipants: maxParticipants,
    );
    _room!.participants[callsign] = ConferenceParticipant(
      callsign: callsign,
      isConnected: true,
    );

    // Start audio
    _peerManager = ConferencePeerManager(
      config: _buildConfig(),
    );
    await _peerManager!.startLocalAudio();
    _listenPeerEvents();

    if (mode == ConferenceSignalingMode.lan) {
      await _startLanSignaling(roomId, roomName, callsign, maxParticipants);
    } else {
      await _startStationSignaling(roomId, roomName, maxParticipants);
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
  /// Format: http://ip:port/meet/XXXX
  Future<List<String>> getMeetUrls() async {
    if (_signalingServer == null || !_signalingServer!.isRunning) return [];
    final port = _signalingServer!.port;
    final code = roomCode ?? '';
    final ips = await _getLocalIPs();
    return ips.map((ip) => 'http://$ip:$port/meet/$code').toList();
  }

  /// Get the station meet URL if connected to a station.
  /// Format: http://station-host/CALLSIGN/meet/XXXX
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
  Future<void> joinLan(String wsUrl) async {
    if (_state != ConferenceState.idle) {
      throw StateError('Conference already active');
    }

    _setState(ConferenceState.starting);
    _role = ConferenceRole.joiner;

    _peerManager = ConferencePeerManager(config: _buildConfig());
    await _peerManager!.startLocalAudio();
    _listenPeerEvents();

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
    _peerManager!.onSendSignal = (signal) {
      _lanSocket?.add(jsonEncode(signal));
    };

    // Announce ourselves
    _lanSocket!.add(jsonEncode({
      'type': 'conference_hello',
      'callsign': _myCallsign,
    }));

    LogService().log('ConferenceService: Joining LAN conference at $wsUrl');
  }

  /// Join a station-mode conference.
  Future<void> joinStation(String roomId) async {
    if (_state != ConferenceState.idle) {
      throw StateError('Conference already active');
    }

    _setState(ConferenceState.starting);
    _role = ConferenceRole.joiner;

    _peerManager = ConferencePeerManager(config: _buildConfig());
    await _peerManager!.startLocalAudio();
    _listenPeerEvents();

    // Set signaling callback to send through station WebSocket
    _peerManager!.onSendSignal = (signal) {
      signal['room_id'] = roomId;
      signal['type'] = 'conference_signal';
      signal['signal_type'] = signal['type'];
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

    // Send join request
    WebSocketService().send({
      'type': 'conference_join',
      'room_id': roomId,
    });

    LogService().log('ConferenceService: Joining station conference $roomId');
  }

  // ── Discovery: find meeting by room ID ──────────────────────────

  /// Discover and join a meeting from a room ID with `@callsign` suffix.
  /// Tries LAN first (via DevicesService), then falls back to station relay.
  Future<void> discoverAndJoin(String roomId) async {
    final atIndex = roomId.indexOf('@');
    if (atIndex < 0) {
      throw ArgumentError('Room ID must contain @callsign: $roomId');
    }
    final hostCallsign = roomId.substring(atIndex + 1);

    LogService().log('ConferenceService: Discovering meeting $roomId '
        '(host: $hostCallsign)');

    // Try LAN discovery first — look up host device URL
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
            final wsUrl = 'ws://$host:$sigPort/conference/ws';
            LogService().log(
                'ConferenceService: Found meeting via LAN at $wsUrl');
            await joinLan(wsUrl);
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
      await joinStation(roomId);
      return;
    }

    throw StateError(
      'Meeting not found. Make sure the host is on the same network '
      'or connected to the same station.',
    );
  }

  // ── Mute ─────────────────────────────────────────────────────────

  void toggleMute() => _peerManager?.toggleMute();
  void setMuted(bool muted) => _peerManager?.setMuted(muted);

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

    await _peerManager?.dispose();
    _peerManager = null;

    _room = null;
    _role = null;
    _setState(ConferenceState.idle);
    LogService().log('ConferenceService: Conference ended');
  }

  // ── LAN signaling (host) ────────────────────────────────────────

  Future<void> _startLanSignaling(
      String roomId, String roomName, String callsign, int maxP) async {
    _signalingServer = ConferenceSignalingServer(
      roomId: roomId,
      roomName: roomName,
      hostCallsign: callsign,
      maxParticipants: maxP,
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

    // The host also listens on the signaling server for relay
    // Set peer manager signaling to broadcast through local server
    _peerManager!.onSendSignal = (signal) {
      // For the host in LAN mode, signals are relayed by the signaling server.
      // We just forward them into the server's internal relay.
      // But since the host is running the server, we can directly relay via WS.
      // The ConferenceSignalingServer handles relay for all participants.
      // The host doesn't connect to its own server — it intercepts
      // participant signals directly from server events.
      //
      // Actually, the simplest approach: host connects to its own server too.
      _connectHostToOwnServer(port, signal);
    };
  }

  WebSocket? _hostSelfSocket;

  Future<void> _connectHostToOwnServer(int port, Map<String, dynamic> firstSignal) async {
    if (_hostSelfSocket != null) {
      _hostSelfSocket!.add(jsonEncode(firstSignal));
      return;
    }

    try {
      _hostSelfSocket = await WebSocket.connect('ws://127.0.0.1:$port/conference/ws');
      _hostSelfSocket!.listen(
        (data) {
          if (data is String) _handleLanMessage(data);
        },
        onDone: () => _hostSelfSocket = null,
      );

      // Announce ourselves
      _hostSelfSocket!.add(jsonEncode({
        'type': 'conference_hello',
        'callsign': _myCallsign,
      }));

      // Update signaling callback
      _peerManager!.onSendSignal = (signal) {
        _hostSelfSocket?.add(jsonEncode(signal));
      };

      // Send the first signal
      _hostSelfSocket!.add(jsonEncode(firstSignal));
    } catch (e) {
      LogService().log('ConferenceService: Host self-connect failed: $e');
    }
  }

  // ── Station signaling (host) ─────────────────────────────────────

  Future<void> _startStationSignaling(
      String roomId, String roomName, int maxP) async {
    // Subscribe to station messages
    _stationSubscription = WebSocketService().messages.listen((msg) {
      final type = msg['type'] as String?;
      if (type == null) return;
      if (type.startsWith('conference_') || type.startsWith('webrtc_')) {
        _handleStationMessage(msg);
      }
    });

    // Set signaling callback
    _peerManager!.onSendSignal = (signal) {
      signal['room_id'] = roomId;
      // Wrap WebRTC signals as conference_signal for routing
      final originalType = signal['type'] as String;
      signal['signal_type'] = originalType;
      signal['type'] = 'conference_signal';
      WebSocketService().send(signal);
    };

    // Create room on station
    WebSocketService().send({
      'type': 'conference_create',
      'room_id': roomId,
      'room_name': roomName,
      'max_participants': maxP,
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
    final participants = msg['participants'] as List?;
    final roomId = msg['room_id'] as String? ?? _room?.roomId ?? '';
    final roomName = msg['room_name'] as String? ?? _room?.roomName ?? '';
    final hostCallsign = msg['host_callsign'] as String? ?? '';

    if (_room == null) {
      // Joiner — create room info from welcome
      _room = ConferenceRoom(
        roomId: roomId,
        roomName: roomName,
        hostCallsign: hostCallsign,
        signalingMode: _lanSocket != null
            ? ConferenceSignalingMode.lan
            : ConferenceSignalingMode.station,
      );
    }

    // Add existing participants and initiate connections
    if (participants != null) {
      for (final p in participants) {
        final callsign = p as String;
        _room!.participants[callsign] = ConferenceParticipant(
          callsign: callsign,
        );
        // Create offers to existing participants
        _peerManager?.createOffer(callsign);
      }
    }

    // Add self
    _room!.participants[_myCallsign] = ConferenceParticipant(
      callsign: _myCallsign,
      isConnected: true,
    );

    _setState(ConferenceState.active);
    LogService().log('ConferenceService: Welcome received, '
        '${participants?.length ?? 0} existing participants');
  }

  void _handleParticipantJoined(Map<String, dynamic> msg) {
    final callsign = msg['callsign'] as String?;
    if (callsign == null || callsign == _myCallsign) return;

    _room?.participants[callsign] = ConferenceParticipant(callsign: callsign);
    _eventController.add(ConferenceEvent('peer_connected', callsign));

    // The new joiner will send offers to us. We just wait.
    LogService().log('ConferenceService: $callsign joined');
  }

  void _handleParticipantLeft(Map<String, dynamic> msg) {
    final callsign = msg['callsign'] as String?;
    if (callsign == null) return;

    _room?.participants.remove(callsign);
    _peerManager?.handleBye(callsign);
    _eventController.add(ConferenceEvent('peer_disconnected', callsign));
    LogService().log('ConferenceService: $callsign left');
  }

  void _handleConferenceEnd(Map<String, dynamic> msg) {
    LogService().log('ConferenceService: Conference ended by host');
    endConference();
  }

  // ── WebRTC signal handling ───────────────────────────────────────

  void _handleWebRTCOffer(Map<String, dynamic> msg) {
    final from = msg['from_callsign'] as String?;
    final sessionId = msg['session_id'] as String?;
    final sdp = msg['sdp'] as Map<String, dynamic>?;
    if (from == null || sessionId == null || sdp == null) return;

    _peerManager?.handleOffer(from, sessionId, sdp);
  }

  void _handleWebRTCAnswer(Map<String, dynamic> msg) {
    final from = msg['from_callsign'] as String?;
    final sdp = msg['sdp'] as Map<String, dynamic>?;
    if (from == null || sdp == null) return;

    _peerManager?.handleAnswer(from, sdp);
  }

  void _handleWebRTCIce(Map<String, dynamic> msg) {
    final from = msg['from_callsign'] as String?;
    final candidate = msg['candidate'] as Map<String, dynamic>?;
    if (from == null || candidate == null) return;

    _peerManager?.handleIceCandidate(from, candidate);
  }

  void _handleWebRTCBye(Map<String, dynamic> msg) {
    final from = msg['from_callsign'] as String?;
    if (from == null) return;

    _peerManager?.handleBye(from);
    _room?.participants.remove(from);
  }

  // ── Helpers ──────────────────────────────────────────────────────

  void _setState(ConferenceState s) {
    _state = s;
    _stateController.add(s);
  }

  void _listenPeerEvents() {
    _peerManager?.events.listen((event) {
      _eventController.add(event);

      // Update participant connection state
      final p = _room?.participants[event.callsign];
      if (p != null) {
        p.isConnected = event.type == 'peer_connected';
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
