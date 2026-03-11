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

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../models/chat_message.dart';
import '../models/conference_archive_entry.dart';
import '../models/conference_schedule_entry.dart';
import 'app_args.dart';
import 'conference_archive_service.dart';
import 'conference_host_peer_manager.dart';
import 'conference_participant_peer_manager.dart';
import 'conference_peer_manager.dart';
import 'conference_recording_service.dart';
import 'conference_schedule_service.dart';
import 'conference_signaling_server.dart';
import 'conference_web_page_service.dart';
import 'devices_service.dart';
import 'log_service.dart';
import 'profile_service.dart';
import 'station_service.dart';
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
  bool hasPendingSpeakerRequest;
  bool hasPendingScreenShareRequest;
  bool isScreenSharing;

  ConferenceParticipant({
    required this.callsign,
    this.isMuted = false,
    this.isConnected = false,
    this.participantRole = ConferenceParticipantRole.listener,
    this.hasPendingSpeakerRequest = false,
    this.hasPendingScreenShareRequest = false,
    this.isScreenSharing = false,
  });

  bool get isSpeaker => participantRole == ConferenceParticipantRole.speaker;

  Map<String, dynamic> toJson() => {
    'callsign': callsign,
    'is_muted': isMuted,
    'is_connected': isConnected,
    'role': participantRole.name,
    'speaker_request_pending': hasPendingSpeakerRequest,
    'screen_share_request_pending': hasPendingScreenShareRequest,
    'is_screen_sharing': isScreenSharing,
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
  final String chatRoomId;
  int maxSpeakers;
  String? activeScreenSharerCallsign;

  ConferenceRoom({
    required this.roomId,
    required this.roomName,
    required this.hostCallsign,
    required this.signalingMode,
    this.maxSpeakers = 6,
  }) : chatRoomId = roomId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_'),
       startTime = DateTime.now();

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
    'active_screen_sharer': activeScreenSharerCallsign,
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
  final ConferenceArchiveService _archiveService = ConferenceArchiveService();
  final ConferenceScheduleService _scheduleService = ConferenceScheduleService();
  final ConferenceRecordingService _recordingService =
      ConferenceRecordingService();
  ConferenceArchiveEntry? _archiveEntry;
  final List<ChatMessage> _chatMessages = [];
  final Set<String> _chatMessageIds = {};
  Future<void> _messageQueue = Future<void>.value();
  Timer? _remoteScreenRecoveryTimer;
  Timer? _scheduledStartTimer;
  Future<void>? _screenShareStartOperation;
  bool _screenShareApproved = false;

  final _stateController = StreamController<ConferenceState>.broadcast();
  final _eventController = StreamController<ConferenceEvent>.broadcast();

  ConferenceRoom? get room => _room;
  ConferenceRole? get role => _role;
  ConferenceState get state => _state;
  bool get isActive => _state == ConferenceState.active;
  List<ChatMessage> get chatMessages => List.unmodifiable(_chatMessages);
  String? get chatTranscriptPath => _archiveEntry == null
      ? null
      : _archiveService.transcriptAbsolutePath(_archiveEntry!);
  ConferenceArchiveEntry? get archiveEntry => _archiveEntry;
  ConferenceRecordingStatus get recordingStatus => _recordingService.status;
  bool get isRecording => _recordingService.isRecording;
  MediaStream? get localScreenStream {
    if (_hostPeerManager != null) {
      return _hostPeerManager!.localScreenStream;
    }
    if (_participantPeerManager != null) {
      return _participantPeerManager!.localScreenStream;
    }
    return null;
  }

  MediaStream? get remoteScreenStream {
    if (_hostPeerManager != null) {
      return _hostPeerManager!.remoteScreenStream;
    }
    if (_participantPeerManager != null) {
      return _participantPeerManager!.remoteScreenStream;
    }
    return null;
  }

  MediaStream? get activeScreenStream {
    final activeSharer = activeScreenSharer;
    if (activeSharer == null) {
      return null;
    }
    if (activeSharer.toUpperCase() == _myCallsign.toUpperCase()) {
      return localScreenStream;
    }
    return remoteScreenStream;
  }

  List<MediaStream> get remoteAudioStreams {
    if (_hostPeerManager != null) {
      return _hostPeerManager!.remoteStreams.values.toList();
    }
    if (_participantPeerManager != null) {
      return _participantPeerManager!.remoteStreams.values.toList();
    }
    return const [];
  }

  List<String> get pendingSpeakerRequests =>
      _room?.participants.values
          .where((participant) => participant.hasPendingSpeakerRequest)
          .map((participant) => participant.callsign)
          .toList() ??
      const [];

  List<String> get pendingScreenShareRequests =>
      _room?.participants.values
          .where((participant) => participant.hasPendingScreenShareRequest)
          .map((participant) => participant.callsign)
          .toList() ??
      const [];

  String? get activeScreenSharer => _room?.activeScreenSharerCallsign;

  bool get isLocalScreenSharing =>
      activeScreenSharer?.toUpperCase() == _myCallsign.toUpperCase() &&
      localScreenStream != null;

  bool get isLocalMuted {
    if (_hostPeerManager != null) return _hostPeerManager!.isLocalMuted;
    if (_participantPeerManager != null) {
      return _participantPeerManager!.isLocalMuted;
    }
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
    String? roomIdOverride,
  }) async {
    if (_state != ConferenceState.idle) {
      throw StateError('Conference already active');
    }

    _setState(ConferenceState.starting);
    _role = ConferenceRole.host;
    _resetMeetingState();
    await _prepareAudioRouting();
    await _ensureStationConnectionForHosting();

    final roomId = roomIdOverride ?? _generateRoomId();
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
      participantRole:
          ConferenceParticipantRole.speaker, // Host is always a speaker
    );
    await _ensureArchiveForRoom();
    await _loadStoredChatMessages();
    await _scheduleService.markActive(
      roomId,
      stationMeetUrl: shareableStationMeetUrl,
    );
    unawaited(_refreshScheduledAutoStartTimer());

    // Start host peer manager (SFU)
    _hostPeerManager = ConferenceHostPeerManager(config: _buildConfig());
    await _hostPeerManager!.startLocalAudio();
    _listenHostPeerEvents();

    if (mode == ConferenceSignalingMode.lan) {
      await _startLanSignaling(roomId, roomName, callsign, maxSpeakers);
    } else {
      await _startStationSignaling(roomId, roomName, maxSpeakers);
    }

    _setState(ConferenceState.active);
    LogService().log(
      'ConferenceService: Hosting "$roomName" ($mode) as $callsign',
    );
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
    final port = AppArgs().port;
    final code = roomCode ?? '';
    final ips = await _getLocalIPs();
    return ips.map((ip) => 'http://$ip:$port/meet/$code').toList();
  }

  /// Get the station meet URL if connected to a station.
  String? get stationMeetUrl {
    final room = _room;
    if (room == null) return null;
    return _buildMeetUrlFromStationUrl(WebSocketService().connectedUrl, room);
  }

  String? get preferredStationMeetUrl {
    final room = _room;
    if (room == null) {
      return null;
    }
    if (room.signalingMode != ConferenceSignalingMode.station &&
        !WebSocketService().isConnected) {
      return null;
    }
    try {
      return _buildMeetUrlFromStationUrl(
        StationService().getPreferredStation()?.url,
        room,
      );
    } catch (_) {
      return null;
    }
  }

  String? get shareableStationMeetUrl =>
      stationMeetUrl ?? preferredStationMeetUrl;

  String? _buildMeetUrlFromStationUrl(String? stationUrl, ConferenceRoom room) {
    if (stationUrl == null || stationUrl.trim().isEmpty) {
      return null;
    }
    try {
      final uri = Uri.parse(stationUrl);
      final scheme = uri.scheme == 'wss' ? 'https' : 'http';
      final code = _roomCodeFromRoomId(room.roomId);
      final preservedPathSegments = uri.pathSegments.where((segment) {
        if (segment.isEmpty) {
          return false;
        }
        return segment.toLowerCase() != 'ws';
      }).toList();
      final pathSegments = <String>[
        ...preservedPathSegments,
        room.hostCallsign,
        'meet',
        code,
      ];
      return Uri(
        scheme: scheme,
        host: uri.host,
        port: uri.hasPort ? uri.port : null,
        pathSegments: pathSegments,
      ).toString();
    } catch (_) {
      return null;
    }
  }

  Future<ConferenceScheduleEntry> scheduleConference({
    required String roomName,
    int maxSpeakers = 6,
    DateTime? scheduledAt,
  }) async {
    await _ensureStationConnectionForHosting();
    final roomId = _generateRoomId();
    final tempRoom = ConferenceRoom(
      roomId: roomId,
      roomName: roomName,
      hostCallsign: _myCallsign,
      signalingMode: WebSocketService().isConnected
          ? ConferenceSignalingMode.station
          : ConferenceSignalingMode.lan,
      maxSpeakers: maxSpeakers,
    );
    final entry = await _scheduleService.createSchedule(
      roomId: roomId,
      roomName: roomName,
      hostCallsign: _myCallsign,
      maxSpeakers: maxSpeakers,
      scheduledAt: scheduledAt,
      stationMeetUrl: _buildMeetUrlFromStationUrl(
        WebSocketService().connectedUrl ??
            (() {
              try {
                return StationService().getPreferredStation()?.url;
              } catch (_) {
                return null;
              }
            })(),
        tempRoom,
      ),
    );
    await _refreshScheduledAutoStartTimer();
    return entry;
  }

  Future<ConferenceRoom> startScheduledConference(String roomId) async {
    final schedule = await _scheduleService.findScheduleByRoomId(roomId);
    if (schedule == null) {
      throw StateError('Scheduled meeting not found');
    }
    return hostConference(
      roomName: schedule.roomName,
      maxSpeakers: schedule.maxSpeakers,
      roomIdOverride: schedule.roomId,
    );
  }

  Future<void> initializeScheduledMeetings() async {
    await _refreshScheduledAutoStartTimer();
  }

  Future<void> joinStationMeetUrl(
    Uri meetUri, {
    ConferenceParticipantRole participantRole =
        ConferenceParticipantRole.listener,
  }) async {
    final segments = meetUri.pathSegments;
    if (segments.length < 3 || segments[segments.length - 2] != 'meet') {
      throw ArgumentError('Unrecognized meeting URL format: $meetUri');
    }

    final callsign = segments[segments.length - 3];
    final code = segments.last;
    final roomId = '$code@$callsign';
    final targetStationUri = _stationUriFromMeetUri(meetUri);
    final currentStationUrl = WebSocketService().connectedUrl;
    final currentStationUri = currentStationUrl == null
        ? null
        : _normalizeStationUri(Uri.parse(currentStationUrl));

    if (currentStationUri == null ||
        !_isSameStationEndpoint(currentStationUri, targetStationUri)) {
      final connected = await StationService().connectStation(
        targetStationUri.toString(),
      );
      if (!connected) {
        throw StateError(
          'Failed to connect to station ${targetStationUri.host}',
        );
      }
    }

    await joinStation(roomId, participantRole: participantRole);
  }

  Uri _stationUriFromMeetUri(Uri meetUri) {
    final pathSegments = meetUri.pathSegments;
    final prefixSegments = pathSegments.length >= 3
        ? pathSegments.sublist(0, pathSegments.length - 3)
        : const <String>[];
    return _normalizeStationUri(
      meetUri.replace(
        scheme: meetUri.scheme == 'https' ? 'wss' : 'ws',
        pathSegments: prefixSegments,
        query: null,
        fragment: null,
      ),
    );
  }

  Uri _normalizeStationUri(Uri uri) {
    final normalizedPathSegments = uri.pathSegments.where((segment) {
      return segment.isNotEmpty && segment.toLowerCase() != 'ws';
    }).toList();
    return uri.replace(
      pathSegments: normalizedPathSegments,
      query: null,
      fragment: null,
    );
  }

  bool _isSameStationEndpoint(Uri a, Uri b) {
    return a.scheme == b.scheme &&
        a.host.toUpperCase() == b.host.toUpperCase() &&
        a.port == b.port &&
        a.path == b.path;
  }

  // ── Joiner: Join a conference ────────────────────────────────────

  /// Join a LAN-mode conference via WebSocket URL.
  /// Defaults to listener role (no mic access needed).
  Future<void> joinLan(
    String wsUrl, {
    ConferenceParticipantRole participantRole =
        ConferenceParticipantRole.listener,
  }) async {
    if (_state != ConferenceState.idle) {
      throw StateError('Conference already active');
    }

    _setState(ConferenceState.starting);
    _role = ConferenceRole.joiner;
    _resetMeetingState();
    await _prepareAudioRouting();

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
    _lanSocket!.add(
      jsonEncode({
        'type': 'conference_hello',
        'callsign': _myCallsign,
        'role': participantRole.name,
      }),
    );

    LogService().log(
      'ConferenceService: Joining LAN conference at $wsUrl as ${participantRole.name}',
    );
  }

  /// Join a station-mode conference.
  /// Defaults to listener role.
  Future<void> joinStation(
    String roomId, {
    ConferenceParticipantRole participantRole =
        ConferenceParticipantRole.listener,
  }) async {
    if (_state != ConferenceState.idle) {
      throw StateError('Conference already active');
    }

    _setState(ConferenceState.starting);
    _role = ConferenceRole.joiner;
    _resetMeetingState();
    await _prepareAudioRouting();

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

    LogService().log(
      'ConferenceService: Joining station conference $roomId as ${participantRole.name}',
    );
  }

  // ── Discovery: find meeting by room ID ──────────────────────────

  /// Discover and join a meeting from a room ID with `@callsign` suffix.
  Future<void> discoverAndJoin(
    String roomId, {
    ConferenceParticipantRole participantRole =
        ConferenceParticipantRole.listener,
  }) async {
    final atIndex = roomId.indexOf('@');
    if (atIndex < 0) {
      throw ArgumentError('Room ID must contain @callsign: $roomId');
    }
    final hostCallsign = roomId.substring(atIndex + 1);

    LogService().log(
      'ConferenceService: Discovering meeting $roomId '
      '(host: $hostCallsign)',
    );

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
        final response = await http
            .get(uri)
            .timeout(const Duration(seconds: 5));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          final activeRoomId = data['room_id'] as String?;
          final signalingMode = data['signaling_mode'] as String? ?? 'lan';
          final sigPort = data['signaling_port'] as int?;
          final stationMeetUrl = data['station_meet_url'] as String?;

          if (activeRoomId == roomId) {
            if (signalingMode == ConferenceSignalingMode.station.name &&
                stationMeetUrl != null &&
                stationMeetUrl.isNotEmpty) {
              LogService().log(
                'ConferenceService: Found meeting via device API and joining '
                'through station at $stationMeetUrl',
              );
              await joinStationMeetUrl(
                Uri.parse(stationMeetUrl),
                participantRole: participantRole,
              );
              return;
            }
            if (sigPort != null) {
              final host = Uri.parse(baseUrl).host;
              final wsUrl = 'ws://$host:$sigPort/meet/ws';
              LogService().log(
                'ConferenceService: Found meeting via LAN at $wsUrl',
              );
              await joinLan(wsUrl, participantRole: participantRole);
              return;
            }
          }
        }
      } catch (e) {
        LogService().log('ConferenceService: LAN discovery failed: $e');
      }
    }

    // Fallback: try station relay
    final wsService = WebSocketService();
    if (wsService.isConnected) {
      LogService().log('ConferenceService: Trying station relay for $roomId');
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

  Future<void> requestToSpeak() async {
    if (_role != ConferenceRole.joiner) {
      throw StateError('Only joiners can request speaker access');
    }

    final room = _room;
    if (room == null) {
      throw StateError('No active conference');
    }

    final me = room.participants[_myCallsign];
    if (me == null || me.isSpeaker) {
      throw StateError('Only listeners can request speaker access');
    }

    if (me.hasPendingSpeakerRequest) {
      return;
    }

    me.hasPendingSpeakerRequest = true;
    _eventController.add(
      ConferenceEvent('speaker_request_pending', _myCallsign),
    );
    _sendConferenceRoomMessage({
      'type': 'conference_speaker_request',
      'callsign': _myCallsign,
    });
    LogService().log('ConferenceService: Speaker request sent by $_myCallsign');
  }

  Future<void> requestToShareScreen() async {
    if (_role != ConferenceRole.joiner) {
      throw StateError('Only joiners can request screen sharing');
    }

    final room = _room;
    if (room == null) {
      throw StateError('No active conference');
    }

    final me = room.participants[_myCallsign];
    if (me == null) {
      throw StateError('Local participant is not registered');
    }
    if (me.isScreenSharing) {
      return;
    }
    if (room.activeScreenSharerCallsign != null &&
        room.activeScreenSharerCallsign!.toUpperCase() !=
            _myCallsign.toUpperCase()) {
      throw StateError('Another participant is already sharing a screen');
    }
    if (me.hasPendingScreenShareRequest) {
      return;
    }

    me.hasPendingScreenShareRequest = true;
    _screenShareApproved = false;
    _eventController.add(
      ConferenceEvent('screen_share_request_pending', _myCallsign),
    );
    _sendConferenceRoomMessage({
      'type': 'conference_screen_share_request',
      'callsign': _myCallsign,
    });
    LogService().log(
      'ConferenceService: Screen-share request sent by $_myCallsign',
    );
  }

  Future<void> startScreenShare() async {
    if (localScreenStream != null) {
      return;
    }

    final pendingOperation = _screenShareStartOperation;
    if (pendingOperation != null) {
      return pendingOperation;
    }

    late final Future<void> operation;
    operation = _startScreenShareInternal().whenComplete(() {
      if (identical(_screenShareStartOperation, operation)) {
        _screenShareStartOperation = null;
      }
    });
    _screenShareStartOperation = operation;
    return operation;
  }

  Future<void> _startScreenShareInternal() async {
    final room = _room;
    if (room == null) {
      throw StateError('No active conference');
    }

    if (room.activeScreenSharerCallsign != null &&
        room.activeScreenSharerCallsign!.toUpperCase() !=
            _myCallsign.toUpperCase()) {
      throw StateError('Another participant is already sharing a screen');
    }

    if (_role == ConferenceRole.joiner &&
        !_screenShareApproved &&
        room.activeScreenSharerCallsign?.toUpperCase() !=
            _myCallsign.toUpperCase()) {
      throw StateError('Host approval is required before sharing your screen');
    }

    final stream = await _captureDisplayStream();
    final videoTracks = stream.getVideoTracks();
    if (videoTracks.isEmpty) {
      await stream.dispose();
      throw StateError('Screen capture returned no video track');
    }
    final screenTrack = videoTracks.first;

    screenTrack.onEnded = () {
      unawaited(stopScreenShare());
    };

    if (_role == ConferenceRole.host) {
      if (_hostPeerManager == null) {
        await stream.dispose();
        throw StateError('Host peer manager is not available');
      }
      await _hostPeerManager!.startLocalScreenShare(stream);
      _setActiveScreenSharer(_myCallsign);
      _broadcastScreenShareState(_myCallsign, active: true);
      LogService().log('ConferenceService: Host started screen sharing');
      return;
    }

    if (_role != ConferenceRole.joiner || _participantPeerManager == null) {
      await stream.dispose();
      throw StateError('Participant peer manager is not available');
    }

    final me = room.participants[_myCallsign];
    if (me == null) {
      await stream.dispose();
      throw StateError('Local participant is not registered');
    }

    await _participantPeerManager!.startScreenShare(stream);
    _setActiveScreenSharer(_myCallsign);
    _eventController.add(
      ConferenceEvent('local_screen_share_started', _myCallsign, stream),
    );
    LogService().log('ConferenceService: Joiner started screen sharing');
  }

  Future<void> stopScreenShare() async {
    final room = _room;
    if (room == null) {
      return;
    }

    if (room.activeScreenSharerCallsign?.toUpperCase() !=
        _myCallsign.toUpperCase()) {
      return;
    }

    if (_role == ConferenceRole.host) {
      await _hostPeerManager?.stopLocalScreenShare();
      _setActiveScreenSharer(null);
      _broadcastScreenShareState(_myCallsign, active: false);
      LogService().log('ConferenceService: Host stopped screen sharing');
      return;
    }

    await _participantPeerManager?.stopScreenShare();
    _screenShareApproved = false;
    _setActiveScreenSharer(null);
    _sendConferenceRoomMessage({
      'type': 'conference_screen_share_stop',
      'callsign': _myCallsign,
    });
    LogService().log('ConferenceService: Joiner stopped screen sharing');
  }

  Future<void> startRecording() async {
    if (_role != ConferenceRole.host) {
      throw StateError('Only the host can record a meeting');
    }
    if (_archiveEntry == null) {
      throw StateError('Meeting archive is not ready');
    }

    await _recordingService.start();
    _eventController.add(
      ConferenceEvent('recording_started', _myCallsign, recordingStatus.toJson()),
    );
  }

  Future<void> stopRecording() async {
    if (_role != ConferenceRole.host) {
      throw StateError('Only the host can record a meeting');
    }

    final outputPath = await _recordingService.stop();
    final archiveEntry = _archiveEntry;
    if (archiveEntry != null &&
        outputPath != null &&
        outputPath.trim().isNotEmpty) {
      _archiveEntry = await _archiveService.importFileFromExternal(
        archiveEntry,
        outputPath,
        recording: true,
      );
    }
    await _recordingService.clearTempRecording();
    if (_archiveEntry != null) {
      await _syncArchiveMetadata();
    }
    _eventController.add(
      ConferenceEvent('recording_stopped', _myCallsign, recordingStatus.toJson()),
    );
  }

  Future<void> sendChatMessage(String content) async {
    final room = _room;
    final trimmed = content.trim();
    if (room == null || trimmed.isEmpty) {
      return;
    }

    final message = ChatMessage.now(
      author: _myCallsign,
      content: trimmed,
      metadata: {
        'conference_id': _generateChatMessageId(),
        'room_id': room.roomId,
      },
    );

    await _storeIncomingChatMessage(message);
    _sendConferenceRoomMessage({
      'type': 'conference_chat_message',
      'message': _serializeChatMessage(message),
    });
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
      p.hasPendingSpeakerRequest = false;
    }

    // Update the participant first so their next SDP answer includes audio.
    _sendRoleChange(callsign, 'speaker');
    _eventController.add(ConferenceEvent('role_changed', callsign, 'speaker'));

    // Renegotiate the connection after the role change notification.
    await _hostPeerManager!.promoteToSpeaker(callsign);

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
      p.hasPendingSpeakerRequest = false;
    }

    // Update the participant first so they stop sending audio before renegotiation.
    _sendRoleChange(callsign, 'listener');
    _eventController.add(ConferenceEvent('role_changed', callsign, 'listener'));

    // Renegotiate the connection after the role change notification.
    await _hostPeerManager!.demoteToListener(callsign);

    LogService().log('ConferenceService: Demoted $callsign to listener');
  }

  Future<void> approveScreenShare(String callsign) async {
    if (_role != ConferenceRole.host || _hostPeerManager == null) {
      throw StateError('Only the host can approve screen sharing');
    }

    final room = _room;
    if (room == null) {
      throw StateError('No active conference');
    }
    if (room.activeScreenSharerCallsign != null &&
        room.activeScreenSharerCallsign!.toUpperCase() !=
            callsign.toUpperCase()) {
      throw StateError('Another participant is already sharing a screen');
    }

    final participant = room.participants[callsign];
    if (participant == null) {
      throw StateError('Unknown participant: $callsign');
    }

    participant.hasPendingScreenShareRequest = false;
    _sendConferenceRoomMessage({
      'type': 'conference_screen_share_permission',
      'callsign': callsign,
      'approved': true,
    }, toCallsign: callsign);
    _eventController.add(
      ConferenceEvent('screen_share_permission_granted', callsign),
    );
    LogService().log(
      'ConferenceService: Approved screen sharing for $callsign',
    );
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
    final roomId = _room?.roomId;
    final wasHost = _role == ConferenceRole.host;

    try {
      if (_role == ConferenceRole.host &&
          (_recordingService.isRecording ||
              _recordingService.status.tempOutputPath != null)) {
        try {
          await stopRecording();
        } catch (e) {
          LogService().log('ConferenceService: Failed to stop recording: $e');
        }
      }

      // Clean up signaling
      if (_role == ConferenceRole.host) {
        if (_room?.signalingMode == ConferenceSignalingMode.station) {
          try {
            WebSocketService().send({
              'type': 'conference_end',
              'room_id': _room?.roomId,
            });
          } catch (e) {
            LogService().log(
              'ConferenceService: Failed to notify station conference end: $e',
            );
          }
        }
        try {
          await _signalingServer?.stop();
        } catch (e) {
          LogService().log(
            'ConferenceService: Failed to stop signaling server: $e',
          );
        }
        _signalingServer = null;
      } else {
        if (_room?.signalingMode == ConferenceSignalingMode.lan) {
          try {
            _lanSocket?.add(
              jsonEncode({'type': 'conference_leave', 'callsign': _myCallsign}),
            );
          } catch (e) {
            LogService().log(
              'ConferenceService: Failed to notify LAN conference leave: $e',
            );
          }
        } else {
          try {
            WebSocketService().send({
              'type': 'conference_leave',
              'room_id': _room?.roomId,
            });
          } catch (e) {
            LogService().log(
              'ConferenceService: Failed to notify station conference leave: $e',
            );
          }
        }
      }
    } finally {
      _cancelRemoteScreenRecovery();
      await _lanSocketSubscription?.cancel();
      _lanSocketSubscription = null;
      try {
        await _lanSocket?.close();
      } catch (_) {}
      _lanSocket = null;
      await _stationSubscription?.cancel();
      _stationSubscription = null;

      try {
        await _hostPeerManager?.dispose();
      } catch (e) {
        LogService().log(
          'ConferenceService: Failed to dispose host peer manager: $e',
        );
      }
      _hostPeerManager = null;
      try {
        await _participantPeerManager?.dispose();
      } catch (e) {
        LogService().log(
          'ConferenceService: Failed to dispose participant peer manager: $e',
        );
      }
      _participantPeerManager = null;
      try {
        await _finalizeArchive();
      } catch (e) {
        LogService().log('ConferenceService: Failed to finalize archive: $e');
      }
      if (wasHost && roomId != null) {
        try {
          await _scheduleService.markCompleted(roomId);
        } catch (e) {
          LogService().log(
            'ConferenceService: Failed to mark scheduled meeting completed: $e',
          );
        }
      }
      unawaited(_refreshScheduledAutoStartTimer());

      _room = null;
      _role = null;
      _setState(ConferenceState.idle);
      LogService().log('ConferenceService: Conference ended');
    }
  }

  // ── LAN signaling (host) ────────────────────────────────────────

  Future<void> _startLanSignaling(
    String roomId,
    String roomName,
    String callsign,
    int maxSpeakers,
  ) async {
    _signalingServer = ConferenceSignalingServer(
      roomId: roomId,
      roomName: roomName,
      hostCallsign: callsign,
      maxSpeakers: maxSpeakers,
    );

    try {
      final assets = await ConferenceWebPageService().buildJoinPage(
        ConferenceWebPageConfig(
          roomId: roomId,
          roomName: roomName,
          hostCallsign: callsign,
          participantCount: 1,
          maxParticipants: maxSpeakers,
          transportMode: ConferenceSignalingMode.lan.name,
          logoText: roomName,
        ),
      );
      _signalingServer!.setWebClientAssets(
        html: assets.html,
        globalStyles: assets.globalStyles,
        appStyles: assets.appStyles,
      );
    } catch (e) {
      LogService().log(
        'ConferenceService: Failed to build LAN web client assets: $e',
      );
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
    String roomId,
    String roomName,
    int maxSpeakers,
  ) async {
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
    _enqueueMessage(() => _handleLanMessageAsync(raw));
  }

  Future<void> _handleLanMessageAsync(String raw) async {
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
        await _handleWelcome(msg);
      case 'conference_participant_joined':
        _handleParticipantJoined(msg);
      case 'conference_participant_left':
        _handleParticipantLeft(msg);
      case 'conference_end':
        _handleConferenceEnd(msg);
      case 'conference_speaker_request':
        _handleSpeakerRequest(msg);
      case 'conference_screen_share_request':
        _handleScreenShareRequest(msg);
      case 'conference_screen_share_permission':
        await _handleScreenSharePermission(msg);
      case 'conference_screen_share_state':
        await _handleScreenShareState(msg);
      case 'conference_screen_share_stop':
        await _handleScreenShareStop(msg);
      case 'conference_role_change':
        await _handleRoleChange(msg);
      case 'conference_chat_message':
        await _handleConferenceChatMessage(msg);
      case 'conference_chat_history':
        await _handleConferenceChatHistory(msg);
      case 'conference_error':
        LogService().log('ConferenceService: Error: ${msg['error']}');
      // WebRTC signals
      case 'webrtc_offer':
        await _handleWebRTCOffer(msg);
      case 'webrtc_answer':
        await _handleWebRTCAnswer(msg);
      case 'webrtc_ice':
        await _handleWebRTCIce(msg);
      case 'webrtc_bye':
        await _handleWebRTCBye(msg);
    }
  }

  void _handleStationMessage(Map<String, dynamic> msg) {
    _enqueueMessage(() => _handleStationMessageAsync(msg));
  }

  Future<void> _handleStationMessageAsync(Map<String, dynamic> msg) async {
    final type = msg['type'] as String?;
    if (type == null) return;

    switch (type) {
      case 'conference_created':
        LogService().log('ConferenceService: Room created on station');
      case 'conference_welcome':
        await _handleWelcome(msg);
      case 'conference_participant_joined':
        _handleParticipantJoined(msg);
      case 'conference_participant_left':
        _handleParticipantLeft(msg);
      case 'conference_end':
        _handleConferenceEnd(msg);
      case 'conference_speaker_request':
        _handleSpeakerRequest(msg);
      case 'conference_screen_share_request':
        _handleScreenShareRequest(msg);
      case 'conference_screen_share_permission':
        await _handleScreenSharePermission(msg);
      case 'conference_screen_share_state':
        await _handleScreenShareState(msg);
      case 'conference_screen_share_stop':
        await _handleScreenShareStop(msg);
      case 'conference_role_change':
        await _handleRoleChange(msg);
      case 'conference_chat_message':
        await _handleConferenceChatMessage(msg);
      case 'conference_chat_history':
        await _handleConferenceChatHistory(msg);
      case 'conference_error':
        LogService().log('ConferenceService: Station error: ${msg['error']}');
      case 'conference_signal':
        // Unwrap the inner signal type
        final signalType = msg['signal_type'] as String?;
        if (signalType != null) {
          msg['type'] = signalType;
          switch (signalType) {
            case 'webrtc_offer':
              await _handleWebRTCOffer(msg);
            case 'webrtc_answer':
              await _handleWebRTCAnswer(msg);
            case 'webrtc_ice':
              await _handleWebRTCIce(msg);
            case 'webrtc_bye':
              await _handleWebRTCBye(msg);
          }
        }
    }
  }

  Future<void> _handleWelcome(Map<String, dynamic> msg) async {
    final roomId = msg['room_id'] as String? ?? _room?.roomId ?? '';
    final roomName = msg['room_name'] as String? ?? _room?.roomName ?? '';
    final hostCallsign = msg['host_callsign'] as String? ?? '';
    final speakers = (msg['speakers'] as List?)?.cast<String>() ?? [];
    final participants = msg['participants'] as List?;
    final activeScreenSharer = msg['active_screen_sharer'] as String?;

    _room ??= ConferenceRoom(
      roomId: roomId,
      roomName: roomName,
      hostCallsign: hostCallsign,
      signalingMode: _lanSocket != null
          ? ConferenceSignalingMode.lan
          : ConferenceSignalingMode.station,
      maxSpeakers: msg['max_speakers'] as int? ?? 6,
    );

    // Add existing participants with their roles
    if (participants != null) {
      for (final p in participants) {
        final callsign = p is String
            ? p
            : (p as Map<String, dynamic>)['callsign'] as String? ?? '';
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
    _setActiveScreenSharer(activeScreenSharer);
    await _ensureArchiveForRoom();
    await _loadStoredChatMessages();

    // In star topology, participant only connects to host
    if (_role == ConferenceRole.joiner && _participantPeerManager != null) {
      await _participantPeerManager!.connectToHost(hostCallsign);
      _scheduleRemoteScreenRecovery();
    }

    _setState(ConferenceState.active);
    LogService().log(
      'ConferenceService: Welcome received, '
      '${speakers.length} speakers, host=$hostCallsign',
    );
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
    unawaited(_syncArchiveMetadata());
    _eventController.add(ConferenceEvent('participant_joined', callsign));
    if (_role == ConferenceRole.host) {
      _sendChatHistoryToParticipant(callsign);
    }

    // In star topology, the joiner sends the offer to host.
    // Host just waits for the offer.
    LogService().log('ConferenceService: $callsign joined as $role');
  }

  void _handleParticipantLeft(Map<String, dynamic> msg) {
    final callsign = msg['callsign'] as String?;
    if (callsign == null) return;

    _room?.participants.remove(callsign);
    if (_room?.activeScreenSharerCallsign?.toUpperCase() ==
        callsign.toUpperCase()) {
      _setActiveScreenSharer(null);
      if (_role == ConferenceRole.host) {
        unawaited(_hostPeerManager?.clearRemoteScreenShare(callsign));
      } else {
        unawaited(_participantPeerManager?.clearRemoteScreenStream());
      }
    }

    if (_role == ConferenceRole.host) {
      final future = _hostPeerManager?.handleBye(callsign);
      if (future != null) {
        unawaited(future);
      }
    } else if (callsign == _room?.hostCallsign) {
      final future = _participantPeerManager?.handleBye(callsign);
      if (future != null) {
        unawaited(future);
      }
    }

    unawaited(_syncArchiveMetadata());
    _eventController.add(ConferenceEvent('peer_disconnected', callsign));
    LogService().log('ConferenceService: $callsign left');
  }

  void _handleConferenceEnd(Map<String, dynamic> msg) {
    LogService().log('ConferenceService: Conference ended by host');
    unawaited(endConference());
  }

  Future<void> _handleRoleChange(Map<String, dynamic> msg) async {
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
      p.hasPendingSpeakerRequest = false;
    }

    // If this role change is for us (we're a participant)
    if (callsign == _myCallsign && _participantPeerManager != null) {
      if (participantRole == ConferenceParticipantRole.speaker) {
        await _participantPeerManager!.onPromotedToSpeaker();
      } else {
        await _participantPeerManager!.onDemotedToListener();
      }
    }

    unawaited(_syncArchiveMetadata());
    _eventController.add(ConferenceEvent('role_changed', callsign, newRole));
    LogService().log('ConferenceService: $callsign role changed to $newRole');
  }

  // ── WebRTC signal handling ───────────────────────────────────────

  Future<void> _handleWebRTCOffer(Map<String, dynamic> msg) async {
    final from = msg['from_callsign'] as String?;
    final sessionId = msg['session_id'] as String?;
    final sdp = msg['sdp'] as Map<String, dynamic>?;
    if (from == null || sessionId == null || sdp == null) return;

    if (_role == ConferenceRole.host && _hostPeerManager != null) {
      final role = msg['role'] as String?;
      await _hostPeerManager!.handleOffer(from, sessionId, sdp, role: role);
    } else if (_participantPeerManager != null) {
      // Renegotiation offer from host
      await _participantPeerManager!.handleOffer(from, sessionId, sdp);
    }
  }

  Future<void> _handleWebRTCAnswer(Map<String, dynamic> msg) async {
    final from = msg['from_callsign'] as String?;
    final sdp = msg['sdp'] as Map<String, dynamic>?;
    if (from == null || sdp == null) return;

    if (_role == ConferenceRole.host) {
      await _hostPeerManager?.handleAnswer(from, sdp);
    } else {
      await _participantPeerManager?.handleAnswer(from, sdp);
    }
  }

  Future<void> _handleWebRTCIce(Map<String, dynamic> msg) async {
    final from = msg['from_callsign'] as String?;
    final candidate = msg['candidate'] as Map<String, dynamic>?;
    if (from == null || candidate == null) return;

    if (_role == ConferenceRole.host) {
      await _hostPeerManager?.handleIceCandidate(from, candidate);
    } else {
      await _participantPeerManager?.handleIceCandidate(from, candidate);
    }
  }

  Future<void> _handleWebRTCBye(Map<String, dynamic> msg) async {
    final from = msg['from_callsign'] as String?;
    if (from == null) return;

    if (_role == ConferenceRole.host) {
      await _hostPeerManager?.handleBye(from);
    } else if (from == _room?.hostCallsign) {
      await _participantPeerManager?.handleBye(from);
    }
    _room?.participants.remove(from);
  }

  void _handleSpeakerRequest(Map<String, dynamic> msg) {
    final callsign = msg['callsign'] as String?;
    if (callsign == null) return;

    final participant = _room?.participants[callsign];
    if (participant == null || participant.isSpeaker) {
      return;
    }

    participant.hasPendingSpeakerRequest = true;
    _eventController.add(ConferenceEvent('speaker_requested', callsign));
    LogService().log(
      'ConferenceService: Speaker request received from $callsign',
    );
  }

  void _handleScreenShareRequest(Map<String, dynamic> msg) {
    final callsign = msg['callsign'] as String?;
    if (callsign == null) {
      return;
    }

    final participant = _room?.participants[callsign];
    if (participant == null || participant.isScreenSharing) {
      return;
    }

    participant.hasPendingScreenShareRequest = true;
    _eventController.add(ConferenceEvent('screen_share_requested', callsign));
    LogService().log(
      'ConferenceService: Screen-share request received from $callsign',
    );
  }

  Future<void> _handleScreenSharePermission(Map<String, dynamic> msg) async {
    final callsign = msg['callsign'] as String?;
    final approved = msg['approved'] == true;
    if (callsign == null) {
      return;
    }

    final participant = _room?.participants[callsign];
    participant?.hasPendingScreenShareRequest = false;

    if (callsign.toUpperCase() != _myCallsign.toUpperCase()) {
      return;
    }

    if (!approved) {
      _screenShareApproved = false;
      _eventController.add(
        ConferenceEvent('screen_share_permission_denied', callsign),
      );
      return;
    }

    _screenShareApproved = true;
    try {
      await startScreenShare();
    } catch (error) {
      _screenShareApproved = false;
      LogService().log(
        'ConferenceService: Failed to start approved screen share: $error',
      );
    }
  }

  Future<void> _handleScreenShareState(Map<String, dynamic> msg) async {
    final callsign = msg['callsign'] as String?;
    final active = msg['active'] == true;
    if (callsign == null || callsign.isEmpty) {
      return;
    }

    if (!active) {
      _cancelRemoteScreenRecovery();
      if (_room?.activeScreenSharerCallsign?.toUpperCase() !=
          callsign.toUpperCase()) {
        return;
      }
      _setActiveScreenSharer(null);
      if (_role == ConferenceRole.joiner) {
        await _participantPeerManager?.clearRemoteScreenStream();
      }
      _eventController.add(ConferenceEvent('screen_share_stopped', callsign));
      return;
    }

    _setActiveScreenSharer(callsign);
    _scheduleRemoteScreenRecovery();
    _eventController.add(ConferenceEvent('screen_share_started', callsign));
  }

  Future<void> _handleScreenShareStop(Map<String, dynamic> msg) async {
    final callsign = msg['callsign'] as String?;
    if (callsign == null || _role != ConferenceRole.host) {
      return;
    }

    try {
      await _hostPeerManager?.clearRemoteScreenShare(callsign);
    } finally {
      _setActiveScreenSharer(null);
      _broadcastScreenShareState(callsign, active: false);
    }
    unawaited(_syncArchiveMetadata());
    LogService().log(
      'ConferenceService: Cleared remote screen sharing from $callsign',
    );
  }

  Future<void> _handleConferenceChatMessage(Map<String, dynamic> msg) async {
    final payload = msg['message'] as Map<String, dynamic>?;
    if (payload == null) return;
    final message = _deserializeChatMessage(payload);
    await _storeIncomingChatMessage(message);
  }

  Future<void> _handleConferenceChatHistory(Map<String, dynamic> msg) async {
    final messages = (msg['messages'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(_deserializeChatMessage)
        .toList();

    for (final message in messages) {
      await _storeIncomingChatMessage(message);
    }
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
        if (event.type == 'peer_connected' ||
            event.type == 'remote_stream' ||
            event.type == 'remote_screen_stream') {
          p.isConnected = true;
        } else if (event.type == 'peer_disconnected') {
          p.isConnected = false;
        }
      }

      if (event.type == 'remote_screen_stream') {
        _setActiveScreenSharer(event.callsign);
        _broadcastScreenShareState(event.callsign, active: true);
      } else if (event.type == 'remote_screen_stream_removed' &&
          _room?.activeScreenSharerCallsign?.toUpperCase() ==
              event.callsign.toUpperCase()) {
        _setActiveScreenSharer(null);
        _broadcastScreenShareState(event.callsign, active: false);
      }
    });
  }

  void _listenParticipantPeerEvents() {
    _participantPeerManager?.events.listen((event) {
      _eventController.add(event);

      // For participant, the host connection state affects all participants
      if (event.type == 'peer_connected' ||
          event.type == 'remote_stream' ||
          event.type == 'remote_screen_stream') {
        // Mark host as connected
        final p = _room?.participants[event.callsign];
        if (p != null) p.isConnected = true;
      } else if (event.type == 'peer_disconnected') {
        final p = _room?.participants[event.callsign];
        if (p != null) p.isConnected = false;
      }

      if (event.type == 'remote_screen_stream') {
        _cancelRemoteScreenRecovery();
      } else if (event.type == 'peer_connected' ||
          event.type == 'remote_stream') {
        _scheduleRemoteScreenRecovery();
      } else if (event.type == 'peer_disconnected') {
        _cancelRemoteScreenRecovery();
      }
    });
  }

  void _resetMeetingState() {
    _cancelRemoteScreenRecovery();
    _chatMessages.clear();
    _chatMessageIds.clear();
    _messageQueue = Future<void>.value();
    _archiveEntry = null;
    _screenShareStartOperation = null;
    _screenShareApproved = false;
  }

  void _enqueueMessage(Future<void> Function() handler) {
    _messageQueue = _messageQueue
        .catchError((Object error, StackTrace stackTrace) {
          LogService().log(
            'ConferenceService: Previous queued message failed: $error',
          );
        })
        .then((_) => handler())
        .catchError((Object error, StackTrace stackTrace) {
          LogService().log(
            'ConferenceService: Failed to handle queued message: $error',
          );
        });
  }

  void _broadcastScreenShareState(String callsign, {required bool active}) {
    _sendConferenceRoomMessage({
      'type': 'conference_screen_share_state',
      'callsign': callsign,
      'active': active,
    });
  }

  void _setActiveScreenSharer(String? callsign) {
    final room = _room;
    if (room == null) {
      return;
    }

    room.activeScreenSharerCallsign = callsign;
    final activeKey = callsign?.toUpperCase();
    for (final participant in room.participants.values) {
      final isActive =
          activeKey != null && participant.callsign.toUpperCase() == activeKey;
      participant.isScreenSharing = isActive;
      if (isActive) {
        participant.hasPendingScreenShareRequest = false;
      }
    }
    unawaited(_syncArchiveMetadata());
  }

  Future<void> _prepareAudioRouting() async {
    if (kIsWeb) {
      return;
    }
    if (!(Platform.isAndroid || Platform.isIOS || Platform.isMacOS)) {
      return;
    }
    try {
      await Helper.setSpeakerphoneOnButPreferBluetooth();
    } catch (_) {}
    try {
      await Helper.ensureAudioSession();
    } catch (_) {}
  }

  Future<MediaStream> _captureDisplayStream() async {
    if (!kIsWeb && Platform.isLinux) {
      return navigator.mediaDevices.getDisplayMedia({
        'audio': false,
        'video': true,
      });
    }

    const targetScreenShareWidth = 1280;
    const targetScreenShareHeight = 720;
    const targetScreenShareFrameRate = 8;

    if (!kIsWeb && WebRTC.platformIsDesktop) {
      final sources = await desktopCapturer.getSources(
        types: [SourceType.Screen],
      );
      if (sources.isEmpty) {
        throw StateError('No desktop screen sources are available');
      }
      final source = sources.first;
      return navigator.mediaDevices.getDisplayMedia({
        'audio': false,
        'video': {
          'deviceId': {'exact': source.id},
          'width': targetScreenShareWidth,
          'height': targetScreenShareHeight,
          'frameRate': targetScreenShareFrameRate,
          'mandatory': {'frameRate': targetScreenShareFrameRate.toDouble()},
        },
      });
    }

    return navigator.mediaDevices.getDisplayMedia({
      'audio': false,
      'video': {
        'width': targetScreenShareWidth,
        'height': targetScreenShareHeight,
        'frameRate': targetScreenShareFrameRate,
      },
    });
  }

  void _cancelRemoteScreenRecovery() {
    _remoteScreenRecoveryTimer?.cancel();
    _remoteScreenRecoveryTimer = null;
  }

  void _scheduleRemoteScreenRecovery({
    Duration delay = const Duration(seconds: 2),
  }) {
    final room = _room;
    final participantPeerManager = _participantPeerManager;
    if (_role != ConferenceRole.joiner ||
        room == null ||
        participantPeerManager == null) {
      _cancelRemoteScreenRecovery();
      return;
    }

    final activeSharer = room.activeScreenSharerCallsign;
    if (activeSharer == null ||
        activeSharer.toUpperCase() == _myCallsign.toUpperCase() ||
        participantPeerManager.remoteScreenStream != null) {
      _cancelRemoteScreenRecovery();
      return;
    }

    if (_remoteScreenRecoveryTimer?.isActive ?? false) {
      return;
    }

    _remoteScreenRecoveryTimer = Timer(delay, () async {
      _remoteScreenRecoveryTimer = null;

      final latestRoom = _room;
      final latestParticipantPeerManager = _participantPeerManager;
      if (_role != ConferenceRole.joiner ||
          latestRoom == null ||
          latestParticipantPeerManager == null) {
        return;
      }

      final latestSharer = latestRoom.activeScreenSharerCallsign;
      if (latestSharer == null ||
          latestSharer.toUpperCase() == _myCallsign.toUpperCase() ||
          latestParticipantPeerManager.remoteScreenStream != null) {
        return;
      }

      if (latestParticipantPeerManager.connectedPeers.isEmpty) {
        _scheduleRemoteScreenRecovery(delay: const Duration(seconds: 1));
        return;
      }

      try {
        LogService().log(
          'ConferenceService: Retrying remote screen subscription for '
          '$latestSharer',
        );
        await latestParticipantPeerManager.refreshRemoteSubscriptions();
      } catch (e) {
        LogService().log(
          'ConferenceService: Failed to refresh remote screen subscription: $e',
        );
      }
    });
  }

  Future<void> _loadStoredChatMessages() async {
    final archiveEntry = _archiveEntry;
    if (archiveEntry == null) {
      return;
    }

    final stored = await _archiveService.loadMessages(archiveEntry);
    _chatMessages
      ..clear()
      ..addAll(stored);
    _chatMessageIds
      ..clear()
      ..addAll(stored.map(_chatMessageKey));
    if (stored.isNotEmpty) {
      _eventController.add(
        ConferenceEvent(
          'chat_history_loaded',
          archiveEntry.hostCallsign,
          stored,
        ),
      );
    }
  }

  Future<void> _storeIncomingChatMessage(ChatMessage message) async {
    final archiveEntry = _archiveEntry;
    if (archiveEntry == null) {
      return;
    }

    final key = _chatMessageKey(message);
    if (!_chatMessageIds.add(key)) {
      return;
    }

    _chatMessages.add(message);
    _chatMessages.sort();
    _archiveEntry = await _archiveService.saveMessage(archiveEntry, message);
    _eventController.add(
      ConferenceEvent('conference_chat_message', message.author, message),
    );
  }

  void _sendConferenceRoomMessage(
    Map<String, dynamic> message, {
    String? toCallsign,
  }) {
    final room = _room;
    if (room == null) return;

    final payload = Map<String, dynamic>.from(message)
      ..putIfAbsent('room_id', () => room.roomId);
    if (toCallsign != null && toCallsign.isNotEmpty) {
      payload['to_callsign'] = toCallsign;
    }

    if (room.signalingMode == ConferenceSignalingMode.lan) {
      if (_role == ConferenceRole.host) {
        _signalingServer?.sendRoomMessageFromHost(
          payload,
          toCallsign: toCallsign,
        );
      } else {
        _lanSocket?.add(jsonEncode(payload));
      }
      return;
    }

    WebSocketService().send(payload);
  }

  void _sendChatHistoryToParticipant(String callsign) {
    if (_chatMessages.isEmpty) {
      return;
    }

    _sendConferenceRoomMessage({
      'type': 'conference_chat_history',
      'messages': _chatMessages.map(_serializeChatMessage).toList(),
    }, toCallsign: callsign);
  }

  Map<String, dynamic> _serializeChatMessage(ChatMessage message) => {
    'author': message.author,
    'timestamp': message.timestamp,
    'content': message.content,
    'metadata': Map<String, String>.from(message.metadata),
    'reactions': message.reactions.map(
      (key, value) => MapEntry(key, List<String>.from(value)),
    ),
  };

  ChatMessage _deserializeChatMessage(Map<String, dynamic> json) {
    return ChatMessage(
      author: json['author'] as String? ?? '',
      timestamp: json['timestamp'] as String? ?? '',
      content: json['content'] as String? ?? '',
      metadata: Map<String, String>.from(json['metadata'] as Map? ?? const {}),
      reactions: (json['reactions'] as Map? ?? const {}).map(
        (key, value) => MapEntry(
          key.toString(),
          List<String>.from(value as List? ?? const []),
        ),
      ),
    );
  }

  String _chatMessageKey(ChatMessage message) =>
      message.getMeta('conference_id') ??
      '${message.timestamp}|${message.author}|${message.content}';

  String _generateChatMessageId() {
    final now = DateTime.now().microsecondsSinceEpoch;
    final rand = Random().nextInt(1 << 20);
    return '$now-${rand.toRadixString(16)}';
  }

  Future<void> _ensureArchiveForRoom() async {
    final room = _room;
    if (room == null) {
      return;
    }
    final meetUrls =
        room.signalingMode == ConferenceSignalingMode.lan &&
            _role == ConferenceRole.host
        ? await getMeetUrls()
        : const <String>[];

    _archiveEntry = await _archiveService.ensureArchive(
      roomId: room.roomId,
      roomName: room.roomName,
      hostCallsign: room.hostCallsign,
      localCallsign: _myCallsign,
      startedAt: room.startTime,
      hostedByMe: _role == ConferenceRole.host,
      participants: room.participants.keys.toList(),
      speakers: room.speakers
          .map((participant) => participant.callsign)
          .toList(),
      activeScreenSharer: room.activeScreenSharerCallsign,
      signalingMode: room.signalingMode.name,
      stationMeetUrl: shareableStationMeetUrl,
      meetUrls: meetUrls,
    );
  }

  Future<void> _syncArchiveMetadata() async {
    final room = _room;
    final archiveEntry = _archiveEntry;
    if (room == null || archiveEntry == null) {
      return;
    }
    final meetUrls =
        room.signalingMode == ConferenceSignalingMode.lan &&
            _role == ConferenceRole.host
        ? await getMeetUrls()
        : archiveEntry.meetUrls;

    _archiveEntry = await _archiveService.updateArchive(
      archiveEntry,
      roomName: room.roomName,
      hostCallsign: room.hostCallsign,
      localCallsign: _myCallsign,
      hostedByMe: _role == ConferenceRole.host,
      participants: _mergeArchivePeople(
        archiveEntry.participants,
        room.participants.keys,
      ),
      speakers: _mergeArchivePeople(
        archiveEntry.speakers,
        room.speakers.map((participant) => participant.callsign),
      ),
      activeScreenSharer: room.activeScreenSharerCallsign,
      clearActiveScreenSharer: room.activeScreenSharerCallsign == null,
      signalingMode: room.signalingMode.name,
      stationMeetUrl: shareableStationMeetUrl,
      meetUrls: meetUrls,
    );
  }

  Future<void> _finalizeArchive() async {
    final room = _room;
    final archiveEntry = _archiveEntry;
    if (room == null || archiveEntry == null) {
      return;
    }

    _archiveEntry = await _archiveService.markEnded(
      archiveEntry,
      participants: _mergeArchivePeople(
        archiveEntry.participants,
        room.participants.keys,
      ),
      speakers: _mergeArchivePeople(
        archiveEntry.speakers,
        room.speakers.map((participant) => participant.callsign),
      ),
    );
    if (room.activeScreenSharerCallsign == null && _archiveEntry != null) {
      _archiveEntry = await _archiveService.updateArchive(
        _archiveEntry!,
        activeScreenSharer: null,
        clearActiveScreenSharer: true,
        endedAt: _archiveEntry!.endedAt,
      );
    }
  }

  List<String> _mergeArchivePeople(
    Iterable<String> existing,
    Iterable<String> current,
  ) {
    final merged = <String>{
      ...existing,
      ...current,
    }.toList()
      ..sort();
    return merged;
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
      List.generate(4, (_) => r.nextInt(26) + 65),
    );
    final callsign = _myCallsign;
    return '$letters@$callsign';
  }

  String _roomCodeFromRoomId(String roomId) {
    final at = roomId.indexOf('@');
    return at > 0 ? roomId.substring(0, at) : roomId;
  }

  Future<void> _ensureStationConnectionForHosting() async {
    final wsService = WebSocketService();
    if (wsService.isConnected) {
      return;
    }
    final stationService = StationService();
    if (!stationService.isInitialized) {
      await stationService.initialize();
    }
    if (wsService.isConnected) {
      return;
    }
    final preferred = stationService.getPreferredStation();
    if (preferred == null || preferred.url.trim().isEmpty) {
      return;
    }
    try {
      await stationService.connectStation(preferred.url);
    } catch (error) {
      LogService().log(
        'ConferenceService: Preferred station connection failed before hosting: $error',
      );
    }
  }

  Future<void> _refreshScheduledAutoStartTimer() async {
    _scheduledStartTimer?.cancel();
    _scheduledStartTimer = null;

    final schedules = await _scheduleService.listSchedules(
      includeCompleted: false,
    );
    final pending = schedules.where((entry) {
      return entry.isScheduled && entry.scheduledAt != null;
    }).toList()
      ..sort((a, b) => a.scheduledAt!.compareTo(b.scheduledAt!));

    if (pending.isEmpty) {
      return;
    }

    final now = DateTime.now().toLocal();
    final due = pending.where((entry) => !entry.scheduledAt!.isAfter(now)).toList();
    if (due.isNotEmpty) {
      if (_state == ConferenceState.idle) {
        try {
          await startScheduledConference(due.first.roomId);
          return;
        } catch (error) {
          LogService().log(
            'ConferenceService: Failed to auto-start scheduled meeting ${due.first.roomId}: $error',
          );
        }
      }
      _scheduledStartTimer = Timer(
        const Duration(minutes: 1),
        () => unawaited(_refreshScheduledAutoStartTimer()),
      );
      return;
    }

    final next = pending.first;
    final delay = next.scheduledAt!.difference(now);
    _scheduledStartTimer = Timer(
      delay,
      () => unawaited(_refreshScheduledAutoStartTimer()),
    );
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
