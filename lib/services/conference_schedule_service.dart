library;

import '../models/conference_schedule_entry.dart';
import 'app_service.dart';
import 'profile_storage.dart';

class ConferenceScheduleService {
  static final ConferenceScheduleService _instance =
      ConferenceScheduleService._internal();
  factory ConferenceScheduleService() => _instance;
  ConferenceScheduleService._internal();

  static const String scheduleRoot = 'meetings/scheduled';

  Future<ConferenceScheduleEntry> createSchedule({
    required String roomId,
    required String roomName,
    required String hostCallsign,
    required int maxSpeakers,
    DateTime? scheduledAt,
    String? stationMeetUrl,
  }) async {
    final existing = await findScheduleByRoomId(roomId);
    final created = existing ??
        ConferenceScheduleEntry(
          roomId: roomId,
          roomName: roomName,
          hostCallsign: hostCallsign,
          maxSpeakers: maxSpeakers,
          createdAt: DateTime.now().toLocal(),
          scheduledAt: scheduledAt?.toLocal(),
          stationMeetUrl: stationMeetUrl,
        );
    final entry = created.copyWith(
      roomName: roomName,
      hostCallsign: hostCallsign,
      maxSpeakers: maxSpeakers,
      scheduledAt: scheduledAt?.toLocal(),
      status: existing?.status == 'active' ? 'active' : 'scheduled',
      stationMeetUrl: stationMeetUrl,
    );
    await saveSchedule(entry);
    return entry;
  }

  Future<void> saveSchedule(ConferenceScheduleEntry entry) async {
    final storage = _rootStorage();
    await storage.createDirectory(scheduleRoot);
    await storage.writeJson(_relativePathForRoomId(entry.roomId), entry.toJson());
  }

  Future<ConferenceScheduleEntry?> findScheduleByRoomId(String roomId) async {
    final json = await _rootStorage().readJson(_relativePathForRoomId(roomId));
    if (json == null) {
      return null;
    }
    return ConferenceScheduleEntry.fromJson(json);
  }

  Future<List<ConferenceScheduleEntry>> listSchedules({
    bool includeCompleted = true,
  }) async {
    final storage = _rootStorage();
    if (!await storage.directoryExists(scheduleRoot)) {
      return const <ConferenceScheduleEntry>[];
    }

    final entries = await storage.listDirectory(scheduleRoot);
    final schedules = <ConferenceScheduleEntry>[];
    for (final entry in entries.where((entry) => !entry.isDirectory)) {
      final json = await storage.readJson('$scheduleRoot/${entry.name}');
      if (json == null) {
        continue;
      }
      final schedule = ConferenceScheduleEntry.fromJson(json);
      if (!includeCompleted && schedule.isCompleted) {
        continue;
      }
      schedules.add(schedule);
    }

    schedules.sort((a, b) {
      final aDate = a.scheduledAt ?? a.createdAt;
      final bDate = b.scheduledAt ?? b.createdAt;
      return aDate.compareTo(bDate);
    });
    return schedules;
  }

  Future<ConferenceScheduleEntry?> markActive(
    String roomId, {
    DateTime? startedAt,
    String? stationMeetUrl,
  }) async {
    final entry = await findScheduleByRoomId(roomId);
    if (entry == null) {
      return null;
    }
    final updated = entry.copyWith(
      startedAt: (startedAt ?? DateTime.now()).toLocal(),
      stationMeetUrl: stationMeetUrl,
      status: 'active',
    );
    await saveSchedule(updated);
    return updated;
  }

  Future<ConferenceScheduleEntry?> markCompleted(
    String roomId, {
    DateTime? endedAt,
  }) async {
    final entry = await findScheduleByRoomId(roomId);
    if (entry == null) {
      return null;
    }
    final updated = entry.copyWith(
      endedAt: (endedAt ?? DateTime.now()).toLocal(),
      status: 'completed',
    );
    await saveSchedule(updated);
    return updated;
  }

  Future<List<ConferenceScheduleEntry>> dueSchedules(DateTime now) async {
    final schedules = await listSchedules(includeCompleted: false);
    return schedules.where((entry) {
      if (!entry.isScheduled || entry.scheduledAt == null) {
        return false;
      }
      return !entry.scheduledAt!.isAfter(now.toLocal());
    }).toList();
  }

  String _relativePathForRoomId(String roomId) {
    final fileName = roomId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return '$scheduleRoot/$fileName.json';
  }

  ProfileStorage _rootStorage() {
    final storage = AppService().profileStorage;
    if (storage == null) {
      throw StateError('Profile storage not initialized');
    }
    return storage;
  }
}
