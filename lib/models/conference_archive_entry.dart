library;

import 'conference_schedule_entry.dart' show MeetingVisibility;
import '../work/models/meeting_content.dart' show MeetingSession;

class ConferenceArchiveAsset {
  final String name;
  final String relativePath;
  final int? size;
  final DateTime? modifiedAt;
  final Map<String, List<String>> reactions;
  final int viewCount;

  const ConferenceArchiveAsset({
    required this.name,
    required this.relativePath,
    this.size,
    this.modifiedAt,
    this.reactions = const {},
    this.viewCount = 0,
  });

  ConferenceArchiveAsset copyWith({
    String? name,
    String? relativePath,
    int? size,
    DateTime? modifiedAt,
    Map<String, List<String>>? reactions,
    int? viewCount,
  }) {
    return ConferenceArchiveAsset(
      name: name ?? this.name,
      relativePath: relativePath ?? this.relativePath,
      size: size ?? this.size,
      modifiedAt: modifiedAt ?? this.modifiedAt,
      reactions: reactions ??
          Map<String, List<String>>.from(
            this.reactions.map((k, v) => MapEntry(k, List<String>.from(v))),
          ),
      viewCount: viewCount ?? this.viewCount,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'path': relativePath,
    'size': size,
    'modified_at': modifiedAt?.toIso8601String(),
    if (reactions.isNotEmpty) 'reactions': reactions,
    if (viewCount > 0) 'view_count': viewCount,
  };

  factory ConferenceArchiveAsset.fromJson(Map<String, dynamic> json) {
    return ConferenceArchiveAsset(
      name: json['name'] as String? ?? '',
      relativePath: json['path'] as String? ?? '',
      size: (json['size'] as num?)?.toInt(),
      modifiedAt: _parseDateTime(json['modified_at']),
      reactions: _parseReactions(json['reactions']),
      viewCount: (json['view_count'] as num?)?.toInt() ?? 0,
    );
  }
}

class ConferenceArchiveEntry {
  final String relativePath;
  final String roomId;
  final String roomName;
  final String hostCallsign;
  final String localCallsign;
  final bool hostedByMe;
  final String signalingMode;
  final DateTime startedAt;
  final DateTime updatedAt;
  final DateTime? endedAt;
  final List<String> participants;
  final List<String> speakers;
  final String? activeScreenSharer;
  final String? stationMeetUrl;
  final List<String> meetUrls;
  final String transcriptRelativePath;
  final List<ConferenceArchiveAsset> files;
  final List<ConferenceArchiveAsset> recordings;
  final List<ConferenceArchiveAsset> voiceTranscripts;
  final int messageCount;
  final List<String> tags;
  final List<MeetingSession> sessions;
  final Map<String, String> participantNicknames;
  final String? coverImagePath;
  final MeetingVisibility visibility;

  const ConferenceArchiveEntry({
    required this.relativePath,
    required this.roomId,
    required this.roomName,
    required this.hostCallsign,
    required this.localCallsign,
    required this.hostedByMe,
    required this.signalingMode,
    required this.startedAt,
    required this.updatedAt,
    required this.participants,
    required this.speakers,
    required this.transcriptRelativePath,
    this.endedAt,
    this.activeScreenSharer,
    this.stationMeetUrl,
    this.meetUrls = const <String>[],
    this.files = const <ConferenceArchiveAsset>[],
    this.recordings = const <ConferenceArchiveAsset>[],
    this.voiceTranscripts = const <ConferenceArchiveAsset>[],
    this.messageCount = 0,
    this.tags = const <String>[],
    this.sessions = const <MeetingSession>[],
    this.participantNicknames = const <String, String>{},
    this.coverImagePath,
    this.visibility = MeetingVisibility.public,
  });

  bool get isActive => endedAt == null;
  int get fileCount => files.length;
  int get recordingCount => recordings.length;
  int get totalViewCount => recordings.fold(0, (sum, r) => sum + r.viewCount);

  Map<String, dynamic> toJson() => {
    'relative_path': relativePath,
    'room_id': roomId,
    'room_name': roomName,
    'host_callsign': hostCallsign,
    'local_callsign': localCallsign,
    'hosted_by_me': hostedByMe,
    'signaling_mode': signalingMode,
    'started_at': startedAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    'ended_at': endedAt?.toIso8601String(),
    'participants': participants,
    'speakers': speakers,
    'active_screen_sharer': activeScreenSharer,
    'station_meet_url': stationMeetUrl,
    'meet_urls': meetUrls,
    'transcript_path': transcriptRelativePath,
    'files': files.map((asset) => asset.toJson()).toList(),
    'recordings': recordings.map((asset) => asset.toJson()).toList(),
    'voice_transcripts': voiceTranscripts.map((asset) => asset.toJson()).toList(),
    'message_count': messageCount,
    'tags': tags,
    if (sessions.isNotEmpty) 'sessions': sessions.map((s) => s.toJson()).toList(),
    if (participantNicknames.isNotEmpty) 'participant_nicknames': participantNicknames,
    if (coverImagePath != null) 'cover_image_path': coverImagePath,
    'visibility': visibility.name,
  };

  factory ConferenceArchiveEntry.fromJson(Map<String, dynamic> json) {
    return ConferenceArchiveEntry(
      relativePath: json['relative_path'] as String? ?? '',
      roomId: json['room_id'] as String? ?? '',
      roomName: json['room_name'] as String? ?? 'Meeting',
      hostCallsign: json['host_callsign'] as String? ?? '',
      localCallsign: json['local_callsign'] as String? ?? '',
      hostedByMe: json['hosted_by_me'] == true,
      signalingMode: json['signaling_mode'] as String? ?? 'lan',
      startedAt: _parseDateTime(json['started_at']) ?? DateTime.now().toLocal(),
      updatedAt: _parseDateTime(json['updated_at']) ?? DateTime.now().toLocal(),
      endedAt: _parseDateTime(json['ended_at']),
      participants: (json['participants'] as List<dynamic>? ?? const [])
          .map((value) => value.toString())
          .toList(),
      speakers: (json['speakers'] as List<dynamic>? ?? const [])
          .map((value) => value.toString())
          .toList(),
      activeScreenSharer: json['active_screen_sharer'] as String?,
      stationMeetUrl: json['station_meet_url'] as String?,
      meetUrls: (json['meet_urls'] as List<dynamic>? ?? const [])
          .map((value) => value.toString())
          .toList(),
      transcriptRelativePath: json['transcript_path'] as String? ?? '',
      files: (json['files'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ConferenceArchiveAsset.fromJson)
          .toList(),
      recordings: (json['recordings'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ConferenceArchiveAsset.fromJson)
          .toList(),
      voiceTranscripts: (json['voice_transcripts'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ConferenceArchiveAsset.fromJson)
          .toList(),
      messageCount: (json['message_count'] as num?)?.toInt() ?? 0,
      tags: (json['tags'] as List<dynamic>? ?? const [])
          .map((value) => value.toString())
          .toList(),
      sessions: (json['sessions'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(MeetingSession.fromJson)
          .toList(),
      participantNicknames: (json['participant_nicknames'] as Map<String, dynamic>?)
          ?.map((k, v) => MapEntry(k, v.toString())) ?? const {},
      coverImagePath: json['cover_image_path'] as String?,
      visibility: MeetingVisibility.fromString(json['visibility'] as String?),
    );
  }

  ConferenceArchiveEntry copyWith({
    String? relativePath,
    String? roomId,
    String? roomName,
    String? hostCallsign,
    String? localCallsign,
    bool? hostedByMe,
    String? signalingMode,
    DateTime? startedAt,
    DateTime? updatedAt,
    DateTime? endedAt,
    bool clearEndedAt = false,
    List<String>? participants,
    List<String>? speakers,
    String? activeScreenSharer,
    bool clearActiveScreenSharer = false,
    String? stationMeetUrl,
    List<String>? meetUrls,
    String? transcriptRelativePath,
    List<ConferenceArchiveAsset>? files,
    List<ConferenceArchiveAsset>? recordings,
    List<ConferenceArchiveAsset>? voiceTranscripts,
    int? messageCount,
    List<String>? tags,
    List<MeetingSession>? sessions,
    Map<String, String>? participantNicknames,
    String? coverImagePath,
    bool clearCoverImagePath = false,
    MeetingVisibility? visibility,
  }) {
    return ConferenceArchiveEntry(
      relativePath: relativePath ?? this.relativePath,
      roomId: roomId ?? this.roomId,
      roomName: roomName ?? this.roomName,
      hostCallsign: hostCallsign ?? this.hostCallsign,
      localCallsign: localCallsign ?? this.localCallsign,
      hostedByMe: hostedByMe ?? this.hostedByMe,
      signalingMode: signalingMode ?? this.signalingMode,
      startedAt: startedAt ?? this.startedAt,
      updatedAt: updatedAt ?? this.updatedAt,
      endedAt: clearEndedAt ? null : (endedAt ?? this.endedAt),
      participants: participants ?? List<String>.from(this.participants),
      speakers: speakers ?? List<String>.from(this.speakers),
      activeScreenSharer: clearActiveScreenSharer
          ? null
          : (activeScreenSharer ?? this.activeScreenSharer),
      stationMeetUrl: stationMeetUrl ?? this.stationMeetUrl,
      meetUrls: meetUrls ?? List<String>.from(this.meetUrls),
      transcriptRelativePath:
          transcriptRelativePath ?? this.transcriptRelativePath,
      files: files ?? List<ConferenceArchiveAsset>.from(this.files),
      recordings:
          recordings ?? List<ConferenceArchiveAsset>.from(this.recordings),
      voiceTranscripts:
          voiceTranscripts ?? List<ConferenceArchiveAsset>.from(this.voiceTranscripts),
      messageCount: messageCount ?? this.messageCount,
      tags: tags ?? List<String>.from(this.tags),
      sessions: sessions ?? List<MeetingSession>.from(this.sessions),
      participantNicknames: participantNicknames ??
          Map<String, String>.from(this.participantNicknames),
      coverImagePath: clearCoverImagePath
          ? null
          : (coverImagePath ?? this.coverImagePath),
      visibility: visibility ?? this.visibility,
    );
  }
}

DateTime? _parseDateTime(Object? value) {
  if (value is! String || value.isEmpty) {
    return null;
  }
  return DateTime.tryParse(value)?.toLocal();
}

Map<String, List<String>> _parseReactions(Object? value) {
  if (value is! Map<String, dynamic>) return const {};
  return value.map(
    (k, v) => MapEntry(
      k,
      (v as List<dynamic>?)?.map((e) => e.toString()).toList() ?? <String>[],
    ),
  );
}
