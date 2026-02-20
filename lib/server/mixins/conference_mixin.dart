/// Conference Mixin — station-side conference signaling relay (SFU star topology).
///
/// Shared by both `StationServer` (Desktop) and `PureStationServer` (CLI).
/// The station acts as a signaling relay only — no media passes through it.
///
/// In star topology, speakers are limited by [maxSpeakers] but listeners
/// are unlimited. The station tracks speaker/listener roles.
///
/// Message types handled:
///   conference_create       — host announces a conference room
///   conference_join         — joiner requests to join a room
///   conference_signal       — relay WebRTC signaling scoped to a room
///   conference_leave        — participant leaves
///   conference_end          — host ends the conference
///   conference_role_change  — host promotes/demotes a participant
library;

import 'dart:convert';

/// A conference room tracked by the station.
class ConferenceRoomInfo {
  final String roomId;
  final String roomName;
  final String hostCallsign;
  final String hostClientId;
  final int maxSpeakers;
  final DateTime createdAt;
  final Set<String> participantCallsigns = {};
  final Set<String> speakerCallsigns = {};

  ConferenceRoomInfo({
    required this.roomId,
    required this.roomName,
    required this.hostCallsign,
    required this.hostClientId,
    this.maxSpeakers = 6,
  }) : createdAt = DateTime.now() {
    // Host is a participant and a speaker
    participantCallsigns.add(hostCallsign);
    speakerCallsigns.add(hostCallsign);
  }

  int get listenerCount => participantCallsigns.length - speakerCallsigns.length;

  Map<String, dynamic> toJson() => {
    'room_id': roomId,
    'room_name': roomName,
    'host_callsign': hostCallsign,
    'participant_count': participantCallsigns.length,
    'speaker_count': speakerCallsigns.length,
    'listener_count': listenerCount,
    'participants': participantCallsigns.toList(),
    'speakers': speakerCallsigns.toList(),
    'max_speakers': maxSpeakers,
    'created_at': createdAt.toIso8601String(),
  };
}

/// Abstract contract that the station must fulfil for conference relay.
mixin ConferenceMixin {
  // ── Abstract contract ────────────────────────────────────────────

  void conferenceLog(String level, String message);
  bool conferenceSendToClient(String clientId, String data);
  String? conferenceFindClientId(String callsign);
  String? conferenceGetClientCallsign(String clientId);

  // ── State ────────────────────────────────────────────────────────

  final Map<String, ConferenceRoomInfo> _conferenceRooms = {};

  // ── Public API ───────────────────────────────────────────────────

  /// Handle an incoming conference-related WebSocket message.
  bool handleConferenceMessage(String clientId, Map<String, dynamic> message) {
    final type = message['type'] as String?;
    if (type == null) return false;

    switch (type) {
      case 'conference_create':
        _handleCreate(clientId, message);
        return true;
      case 'conference_join':
        _handleJoin(clientId, message);
        return true;
      case 'conference_leave':
        _handleLeave(clientId, message);
        return true;
      case 'conference_end':
        _handleEnd(clientId, message);
        return true;
      case 'conference_signal':
        _handleSignal(clientId, message);
        return true;
      case 'conference_role_change':
        _handleRoleChange(clientId, message);
        return true;
      case 'conference_list':
        _handleList(clientId);
        return true;
      default:
        return false;
    }
  }

  /// Clean up any rooms hosted by a disconnecting client.
  void conferenceHandleClientDisconnect(String clientId) {
    final roomsToRemove = <String>[];
    for (final entry in _conferenceRooms.entries) {
      if (entry.value.hostClientId == clientId) {
        roomsToRemove.add(entry.key);
      } else {
        final callsign = conferenceGetClientCallsign(clientId);
        if (callsign != null) {
          entry.value.participantCallsigns.remove(callsign);
          entry.value.speakerCallsigns.remove(callsign);
          _broadcastToRoom(entry.key, {
            'type': 'conference_participant_left',
            'callsign': callsign,
            'room_id': entry.key,
          }, excludeCallsign: callsign);
        }
      }
    }
    for (final roomId in roomsToRemove) {
      _endRoom(roomId, reason: 'host_disconnected');
    }
  }

  /// Get active conference rooms.
  List<Map<String, dynamic>> getConferenceRooms() {
    return _conferenceRooms.values.map((r) => r.toJson()).toList();
  }

  // ── Message handlers ─────────────────────────────────────────────

  void _handleCreate(String clientId, Map<String, dynamic> message) {
    final roomId = message['room_id'] as String?;
    final roomName = message['room_name'] as String? ?? 'Conference';
    final hostCallsign = conferenceGetClientCallsign(clientId);
    final maxSpeakers = message['max_speakers'] as int? ?? 6;

    if (roomId == null || hostCallsign == null) {
      conferenceSendToClient(clientId, jsonEncode({
        'type': 'conference_error',
        'error': 'invalid_request',
        'message': 'Missing room_id or not authenticated',
      }));
      return;
    }

    if (_conferenceRooms.containsKey(roomId)) {
      conferenceSendToClient(clientId, jsonEncode({
        'type': 'conference_error',
        'error': 'room_exists',
        'room_id': roomId,
      }));
      return;
    }

    final room = ConferenceRoomInfo(
      roomId: roomId,
      roomName: roomName,
      hostCallsign: hostCallsign,
      hostClientId: clientId,
      maxSpeakers: maxSpeakers,
    );
    _conferenceRooms[roomId] = room;

    conferenceSendToClient(clientId, jsonEncode({
      'type': 'conference_created',
      ...room.toJson(),
    }));

    conferenceLog('INFO', 'Conference created: $roomId by $hostCallsign (max $maxSpeakers speakers)');
  }

  void _handleJoin(String clientId, Map<String, dynamic> message) {
    final roomId = message['room_id'] as String?;
    final callsign = conferenceGetClientCallsign(clientId);
    final requestedRole = message['role'] as String? ?? 'listener';

    if (roomId == null || callsign == null) {
      conferenceSendToClient(clientId, jsonEncode({
        'type': 'conference_error',
        'error': 'invalid_request',
      }));
      return;
    }

    final room = _conferenceRooms[roomId];
    if (room == null) {
      conferenceSendToClient(clientId, jsonEncode({
        'type': 'conference_error',
        'error': 'room_not_found',
        'room_id': roomId,
      }));
      return;
    }

    // Determine actual role (enforce speaker limit)
    String actualRole = requestedRole;
    if (requestedRole == 'speaker' &&
        room.speakerCallsigns.length >= room.maxSpeakers) {
      actualRole = 'listener'; // Downgrade
    }

    room.participantCallsigns.add(callsign);
    if (actualRole == 'speaker') {
      room.speakerCallsigns.add(callsign);
    }

    // Send welcome with speaker info
    conferenceSendToClient(clientId, jsonEncode({
      'type': 'conference_welcome',
      ...room.toJson(),
    }));

    // Notify existing participants
    _broadcastToRoom(roomId, {
      'type': 'conference_participant_joined',
      'callsign': callsign,
      'role': actualRole,
      'room_id': roomId,
    }, excludeCallsign: callsign);

    conferenceLog('INFO', 'Conference $roomId: $callsign joined as $actualRole '
        '(${room.speakerCallsigns.length}/${room.maxSpeakers} speakers, '
        '${room.listenerCount} listeners)');
  }

  void _handleLeave(String clientId, Map<String, dynamic> message) {
    final roomId = message['room_id'] as String?;
    final callsign = conferenceGetClientCallsign(clientId);
    if (roomId == null || callsign == null) return;

    final room = _conferenceRooms[roomId];
    if (room == null) return;

    room.participantCallsigns.remove(callsign);
    room.speakerCallsigns.remove(callsign);

    _broadcastToRoom(roomId, {
      'type': 'conference_participant_left',
      'callsign': callsign,
      'room_id': roomId,
    });

    conferenceLog('INFO', 'Conference $roomId: $callsign left');

    if (callsign == room.hostCallsign) {
      _endRoom(roomId, reason: 'host_left');
    }
  }

  void _handleEnd(String clientId, Map<String, dynamic> message) {
    final roomId = message['room_id'] as String?;
    if (roomId == null) return;

    final room = _conferenceRooms[roomId];
    if (room == null) return;

    if (room.hostClientId != clientId) {
      conferenceSendToClient(clientId, jsonEncode({
        'type': 'conference_error',
        'error': 'not_host',
        'room_id': roomId,
      }));
      return;
    }

    _endRoom(roomId, reason: 'host_ended');
  }

  void _handleSignal(String clientId, Map<String, dynamic> message) {
    final roomId = message['room_id'] as String?;
    final toCallsign = message['to_callsign'] as String?;
    final fromCallsign = conferenceGetClientCallsign(clientId);

    if (roomId == null || toCallsign == null || fromCallsign == null) return;

    final room = _conferenceRooms[roomId];
    if (room == null) return;

    if (!room.participantCallsigns.contains(fromCallsign) ||
        !room.participantCallsigns.contains(toCallsign)) {
      return;
    }

    final targetClientId = conferenceFindClientId(toCallsign);
    if (targetClientId == null) return;

    message['from_callsign'] = fromCallsign;
    conferenceSendToClient(targetClientId, jsonEncode(message));
  }

  void _handleRoleChange(String clientId, Map<String, dynamic> message) {
    final roomId = message['room_id'] as String?;
    final targetCallsign = message['callsign'] as String?;
    final newRole = message['role'] as String?;

    if (roomId == null || targetCallsign == null || newRole == null) return;

    final room = _conferenceRooms[roomId];
    if (room == null) return;

    // Only the host can change roles
    if (room.hostClientId != clientId) {
      conferenceSendToClient(clientId, jsonEncode({
        'type': 'conference_error',
        'error': 'not_host',
        'room_id': roomId,
      }));
      return;
    }

    // Enforce speaker limit on promotion
    if (newRole == 'speaker' &&
        !room.speakerCallsigns.contains(targetCallsign) &&
        room.speakerCallsigns.length >= room.maxSpeakers) {
      conferenceSendToClient(clientId, jsonEncode({
        'type': 'conference_error',
        'error': 'speaker_limit_reached',
        'room_id': roomId,
        'max_speakers': room.maxSpeakers,
      }));
      return;
    }

    // Update role
    if (newRole == 'speaker') {
      room.speakerCallsigns.add(targetCallsign);
    } else {
      room.speakerCallsigns.remove(targetCallsign);
    }

    // Broadcast role change to all participants
    _broadcastToRoom(roomId, {
      'type': 'conference_role_change',
      'callsign': targetCallsign,
      'role': newRole,
      'room_id': roomId,
    });

    conferenceLog('INFO', 'Conference $roomId: $targetCallsign role changed to $newRole');
  }

  void _handleList(String clientId) {
    conferenceSendToClient(clientId, jsonEncode({
      'type': 'conference_list',
      'rooms': getConferenceRooms(),
    }));
  }

  // ── Helpers ──────────────────────────────────────────────────────

  void _endRoom(String roomId, {required String reason}) {
    final room = _conferenceRooms.remove(roomId);
    if (room == null) return;

    _broadcastToRoom(roomId, {
      'type': 'conference_end',
      'room_id': roomId,
      'reason': reason,
    }, room: room);

    conferenceLog('INFO', 'Conference $roomId ended: $reason');
  }

  void _broadcastToRoom(
    String roomId,
    Map<String, dynamic> message, {
    String? excludeCallsign,
    ConferenceRoomInfo? room,
  }) {
    final r = room ?? _conferenceRooms[roomId];
    if (r == null) return;

    final data = jsonEncode(message);
    for (final callsign in r.participantCallsigns) {
      if (callsign == excludeCallsign) continue;
      final targetId = conferenceFindClientId(callsign);
      if (targetId != null) {
        conferenceSendToClient(targetId, data);
      }
    }
  }
}
