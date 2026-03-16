library;

import '../tracker/models/tracker_visibility.dart';

/// Meeting visibility levels
enum MeetingVisibility {
  /// Anyone can see and join
  public,

  /// Only the host can see (not listed)
  private,

  /// Specific contacts/groups can see and join
  restricted,

  /// Accessible via direct link only (not listed on /meet/)
  unlisted;

  static MeetingVisibility fromString(String? value) {
    if (value == null) return MeetingVisibility.public;
    return MeetingVisibility.values.firstWhere(
      (v) => v.name == value,
      orElse: () => MeetingVisibility.public,
    );
  }
}

class ConferenceScheduleEntry {
  final String roomId;
  final String roomName;
  final String hostCallsign;
  final int maxSpeakers;
  final DateTime createdAt;
  final DateTime? scheduledAt;
  final DateTime? startedAt;
  final DateTime? endedAt;
  final String? stationMeetUrl;
  final String? description;
  final String status;
  final MeetingVisibility visibility;
  final List<AllowedContact> allowedContacts;
  final List<AllowedGroup> allowedGroups;

  const ConferenceScheduleEntry({
    required this.roomId,
    required this.roomName,
    required this.hostCallsign,
    required this.maxSpeakers,
    required this.createdAt,
    this.scheduledAt,
    this.startedAt,
    this.endedAt,
    this.stationMeetUrl,
    this.description,
    this.status = 'scheduled',
    this.visibility = MeetingVisibility.public,
    this.allowedContacts = const [],
    this.allowedGroups = const [],
  });

  bool get isScheduled => status == 'scheduled';
  bool get isActive => status == 'active';
  bool get isCompleted => status == 'completed';
  bool get startsManually => scheduledAt == null;

  Map<String, dynamic> toJson() => {
    'room_id': roomId,
    'room_name': roomName,
    'host_callsign': hostCallsign,
    'max_speakers': maxSpeakers,
    'created_at': createdAt.toIso8601String(),
    'scheduled_at': scheduledAt?.toIso8601String(),
    'started_at': startedAt?.toIso8601String(),
    'ended_at': endedAt?.toIso8601String(),
    'station_meet_url': stationMeetUrl,
    'description': description,
    'status': status,
    'visibility': visibility.name,
    if (allowedContacts.isNotEmpty)
      'allowed_contacts': allowedContacts.map((c) => c.toJson()).toList(),
    if (allowedGroups.isNotEmpty)
      'allowed_groups': allowedGroups.map((g) => g.toJson()).toList(),
  };

  factory ConferenceScheduleEntry.fromJson(Map<String, dynamic> json) {
    return ConferenceScheduleEntry(
      roomId: json['room_id'] as String? ?? '',
      roomName: json['room_name'] as String? ?? 'Meeting',
      hostCallsign: json['host_callsign'] as String? ?? '',
      maxSpeakers: (json['max_speakers'] as num?)?.toInt() ?? 6,
      createdAt:
          _parseDateTime(json['created_at']) ?? DateTime.now().toLocal(),
      scheduledAt: _parseDateTime(json['scheduled_at']),
      startedAt: _parseDateTime(json['started_at']),
      endedAt: _parseDateTime(json['ended_at']),
      stationMeetUrl: json['station_meet_url'] as String?,
      description: json['description'] as String?,
      status: json['status'] as String? ?? 'scheduled',
      visibility: MeetingVisibility.fromString(json['visibility'] as String?),
      allowedContacts: (json['allowed_contacts'] as List<dynamic>?)
          ?.map((c) => AllowedContact.fromJson(c as Map<String, dynamic>))
          .toList() ?? const [],
      allowedGroups: (json['allowed_groups'] as List<dynamic>?)
          ?.map((g) => AllowedGroup.fromJson(g as Map<String, dynamic>))
          .toList() ?? const [],
    );
  }

  ConferenceScheduleEntry copyWith({
    String? roomId,
    String? roomName,
    String? hostCallsign,
    int? maxSpeakers,
    DateTime? createdAt,
    DateTime? scheduledAt,
    bool clearScheduledAt = false,
    DateTime? startedAt,
    bool clearStartedAt = false,
    DateTime? endedAt,
    bool clearEndedAt = false,
    String? stationMeetUrl,
    bool clearStationMeetUrl = false,
    String? description,
    bool clearDescription = false,
    String? status,
    MeetingVisibility? visibility,
    List<AllowedContact>? allowedContacts,
    List<AllowedGroup>? allowedGroups,
  }) {
    return ConferenceScheduleEntry(
      roomId: roomId ?? this.roomId,
      roomName: roomName ?? this.roomName,
      hostCallsign: hostCallsign ?? this.hostCallsign,
      maxSpeakers: maxSpeakers ?? this.maxSpeakers,
      createdAt: createdAt ?? this.createdAt,
      scheduledAt: clearScheduledAt ? null : (scheduledAt ?? this.scheduledAt),
      startedAt: clearStartedAt ? null : (startedAt ?? this.startedAt),
      endedAt: clearEndedAt ? null : (endedAt ?? this.endedAt),
      stationMeetUrl: clearStationMeetUrl
          ? null
          : (stationMeetUrl ?? this.stationMeetUrl),
      description: clearDescription
          ? null
          : (description ?? this.description),
      status: status ?? this.status,
      visibility: visibility ?? this.visibility,
      allowedContacts: allowedContacts ?? this.allowedContacts,
      allowedGroups: allowedGroups ?? this.allowedGroups,
    );
  }
}

DateTime? _parseDateTime(Object? value) {
  if (value is! String || value.isEmpty) {
    return null;
  }
  return DateTime.tryParse(value)?.toLocal();
}
