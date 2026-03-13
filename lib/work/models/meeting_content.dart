/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';

/// Settings for meeting document
class MeetingSettings {
  final bool showTranscriptions;

  MeetingSettings({
    this.showTranscriptions = true,
  });

  factory MeetingSettings.fromJson(Map<String, dynamic> json) {
    return MeetingSettings(
      showTranscriptions: json['show_transcriptions'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
    'show_transcriptions': showTranscriptions,
  };

  MeetingSettings copyWith({bool? showTranscriptions}) {
    return MeetingSettings(
      showTranscriptions: showTranscriptions ?? this.showTranscriptions,
    );
  }
}

/// A timestamped segment within a meeting transcript
class MeetingTranscriptSegment {
  final Duration from;
  final Duration to;
  final String text;

  const MeetingTranscriptSegment({
    required this.from,
    required this.to,
    required this.text,
  });

  factory MeetingTranscriptSegment.fromJson(Map<String, dynamic> json) {
    return MeetingTranscriptSegment(
      from: Duration(milliseconds: json['from_ms'] as int),
      to: Duration(milliseconds: json['to_ms'] as int),
      text: json['text'] as String,
    );
  }

  Map<String, dynamic> toJson() => {
    'from_ms': from.inMilliseconds,
    'to_ms': to.inMilliseconds,
    'text': text,
  };
}

/// Transcript for a meeting recording
class MeetingTranscript {
  final String text;
  final String model;
  final DateTime transcribedAt;
  final List<MeetingTranscriptSegment> segments;

  MeetingTranscript({
    required this.text,
    required this.model,
    required this.transcribedAt,
    List<MeetingTranscriptSegment>? segments,
  }) : segments = segments ?? [];

  factory MeetingTranscript.fromJson(Map<String, dynamic> json) {
    return MeetingTranscript(
      text: json['text'] as String,
      model: json['model'] as String,
      transcribedAt: DateTime.parse(json['transcribed_at'] as String),
      segments: (json['segments'] as List<dynamic>?)
          ?.map((s) => MeetingTranscriptSegment.fromJson(s as Map<String, dynamic>))
          .toList() ?? [],
    );
  }

  Map<String, dynamic> toJson() => {
    'text': text,
    'model': model,
    'transcribed_at': transcribedAt.toIso8601String(),
    if (segments.isNotEmpty)
      'segments': segments.map((s) => s.toJson()).toList(),
  };
}

/// A single recording within a meeting
class MeetingRecording {
  final String id;
  String title;
  final DateTime recordedAt;
  int durationMs;
  String videoFile;
  MeetingTranscript? transcript;
  int? fileSize;

  MeetingRecording({
    required this.id,
    required this.title,
    required this.recordedAt,
    required this.durationMs,
    required this.videoFile,
    this.transcript,
    this.fileSize,
  });

  factory MeetingRecording.create({
    required String title,
    required int durationMs,
    required String videoFile,
    int? fileSize,
  }) {
    final now = DateTime.now();
    final id = 'rec-${now.millisecondsSinceEpoch.toRadixString(36)}';
    return MeetingRecording(
      id: id,
      title: title,
      recordedAt: now,
      durationMs: durationMs,
      videoFile: videoFile,
      fileSize: fileSize,
    );
  }

  factory MeetingRecording.fromJson(Map<String, dynamic> json) {
    MeetingTranscript? transcript;
    final transcriptJson = json['transcript'] as Map<String, dynamic>?;
    if (transcriptJson != null) {
      transcript = MeetingTranscript.fromJson(transcriptJson);
    }

    return MeetingRecording(
      id: json['id'] as String,
      title: json['title'] as String,
      recordedAt: DateTime.parse(json['recorded_at'] as String),
      durationMs: json['duration_ms'] as int,
      videoFile: json['video_file'] as String,
      transcript: transcript,
      fileSize: (json['file_size'] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'recorded_at': recordedAt.toIso8601String(),
    'duration_ms': durationMs,
    'video_file': videoFile,
    if (transcript != null) 'transcript': transcript!.toJson(),
    if (fileSize != null) 'file_size': fileSize,
  };

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// Get formatted duration string (MM:SS or HH:MM:SS)
  String get durationFormatted {
    final totalSeconds = durationMs ~/ 1000;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  MeetingRecording copyWith({
    String? title,
    int? durationMs,
    String? videoFile,
    MeetingTranscript? transcript,
    bool clearTranscript = false,
    int? fileSize,
  }) {
    return MeetingRecording(
      id: id,
      title: title ?? this.title,
      recordedAt: recordedAt,
      durationMs: durationMs ?? this.durationMs,
      videoFile: videoFile ?? this.videoFile,
      transcript: clearTranscript ? null : (transcript ?? this.transcript),
      fileSize: fileSize ?? this.fileSize,
    );
  }
}

/// Main meeting document content (stored in content/main.json)
class MeetingContent {
  final String id;
  final String schema;
  String title;
  int version;
  final DateTime created;
  DateTime modified;
  String roomId;
  String hostCallsign;
  String localCallsign;
  String signalingMode;
  List<String> participants;
  List<String> speakers;
  List<String> recordings; // List of MeetingRecording IDs
  List<String> tags;
  MeetingSettings settings;

  MeetingContent({
    required this.id,
    this.schema = 'ndf-meeting-1.0',
    required this.title,
    this.version = 1,
    required this.created,
    required this.modified,
    this.roomId = '',
    this.hostCallsign = '',
    this.localCallsign = '',
    this.signalingMode = 'lan',
    List<String>? participants,
    List<String>? speakers,
    List<String>? recordings,
    List<String>? tags,
    MeetingSettings? settings,
  }) : participants = participants ?? [],
       speakers = speakers ?? [],
       recordings = recordings ?? [],
       tags = tags ?? [],
       settings = settings ?? MeetingSettings();

  factory MeetingContent.create({required String title}) {
    final now = DateTime.now();
    final id = 'meeting-${now.millisecondsSinceEpoch.toRadixString(36)}';
    return MeetingContent(
      id: id,
      title: title,
      created: now,
      modified: now,
    );
  }

  factory MeetingContent.fromJson(Map<String, dynamic> json) {
    final now = DateTime.now();
    final id = json['id'] as String? ??
        'meeting-${now.millisecondsSinceEpoch.toRadixString(36)}';
    final createdStr = json['created'] as String?;
    final modifiedStr = json['modified'] as String?;
    final created = createdStr != null ? DateTime.parse(createdStr) : now;
    final modified = modifiedStr != null ? DateTime.parse(modifiedStr) : now;

    MeetingSettings? settings;
    final settingsJson = json['settings'] as Map<String, dynamic>?;
    if (settingsJson != null) {
      settings = MeetingSettings.fromJson(settingsJson);
    }

    return MeetingContent(
      id: id,
      schema: json['schema'] as String? ?? 'ndf-meeting-1.0',
      title: json['title'] as String? ?? 'Untitled Meeting',
      version: json['version'] as int? ?? 1,
      created: created,
      modified: modified,
      roomId: json['room_id'] as String? ?? '',
      hostCallsign: json['host_callsign'] as String? ?? '',
      localCallsign: json['local_callsign'] as String? ?? '',
      signalingMode: json['signaling_mode'] as String? ?? 'lan',
      participants: (json['participants'] as List<dynamic>?)
          ?.map((p) => p as String)
          .toList() ?? [],
      speakers: (json['speakers'] as List<dynamic>?)
          ?.map((s) => s as String)
          .toList() ?? [],
      recordings: (json['recordings'] as List<dynamic>?)
          ?.map((r) => r as String)
          .toList() ?? [],
      tags: (json['tags'] as List<dynamic>?)
          ?.map((t) => t as String)
          .toList() ?? [],
      settings: settings,
    );
  }

  Map<String, dynamic> toJson() => {
    'type': 'meeting',
    'id': id,
    'schema': schema,
    'title': title,
    'version': version,
    'created': created.toIso8601String(),
    'modified': modified.toIso8601String(),
    'room_id': roomId,
    'host_callsign': hostCallsign,
    'local_callsign': localCallsign,
    'signaling_mode': signalingMode,
    if (participants.isNotEmpty) 'participants': participants,
    if (speakers.isNotEmpty) 'speakers': speakers,
    'recordings': recordings,
    if (tags.isNotEmpty) 'tags': tags,
    'settings': settings.toJson(),
  };

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// Touch the modified timestamp and increment version
  void touch() {
    modified = DateTime.now();
    version++;
  }

  /// Add a recording ID
  void addRecording(String recordingId) {
    recordings.add(recordingId);
    touch();
  }

  /// Remove a recording ID
  void removeRecording(String recordingId) {
    recordings.remove(recordingId);
    touch();
  }
}
