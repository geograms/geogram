/// File I/O for the Karma gamification system.
///
/// Storage layout under {dataDir}/karma/:
///   events/{YYYY-MM}/{callsign}.jsonl   — Append-only event log
///   profiles/{callsign}.json            — Cached aggregate profile
///   streaks/{callsign}.json             — Streak tracking
///   leaderboards/{period}.json          — Cached leaderboards

import 'dart:convert';
import 'dart:io';

import 'karma_models.dart';

class KarmaStore {
  final String baseDir;

  KarmaStore({required this.baseDir});

  String get _eventsDir => '$baseDir/events';
  String get _profilesDir => '$baseDir/profiles';
  String get _streaksDir => '$baseDir/streaks';
  String get _leaderboardsDir => '$baseDir/leaderboards';

  // ============ Events (append-only JSONL) ============

  /// Append a karma event to the callsign's monthly log.
  Future<void> appendEvent(String callsign, KarmaEvent event) async {
    final month = '${event.timestamp.year}-${event.timestamp.month.toString().padLeft(2, '0')}';
    final dir = Directory('$_eventsDir/$month');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final file = File('${dir.path}/${callsign.toUpperCase()}.jsonl');
    final line = jsonEncode(event.toJson());
    await file.writeAsString('$line\n', mode: FileMode.append);
  }

  /// Read all events for a callsign, optionally filtered by month.
  /// Returns events sorted newest-first.
  Future<List<KarmaEvent>> readEvents(String callsign, {
    int limit = 50,
    int offset = 0,
    String? month,
  }) async {
    final events = <KarmaEvent>[];
    final cs = callsign.toUpperCase();

    if (month != null) {
      events.addAll(await _readMonthEvents(cs, month));
    } else {
      // Read all months (sorted desc)
      final eventsRoot = Directory(_eventsDir);
      if (!await eventsRoot.exists()) return [];

      final months = <String>[];
      await for (final entity in eventsRoot.list()) {
        if (entity is Directory) {
          months.add(entity.path.split('/').last);
        }
      }
      months.sort((a, b) => b.compareTo(a));

      for (final m in months) {
        events.addAll(await _readMonthEvents(cs, m));
        if (events.length >= offset + limit) break;
      }
    }

    events.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    if (offset >= events.length) return [];
    return events.skip(offset).take(limit).toList();
  }

  Future<List<KarmaEvent>> _readMonthEvents(String callsign, String month) async {
    final file = File('$_eventsDir/$month/$callsign.jsonl');
    if (!await file.exists()) return [];

    final events = <KarmaEvent>[];
    final lines = await file.readAsLines();
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      try {
        events.add(KarmaEvent.fromJson(jsonDecode(line) as Map<String, dynamic>));
      } catch (_) {
        // Skip malformed lines
      }
    }
    return events;
  }

  /// Read today's events for a callsign (for daily cap tracking).
  Future<List<KarmaEvent>> readTodayEvents(String callsign) async {
    final now = DateTime.now().toUtc();
    final month = '${now.year}-${now.month.toString().padLeft(2, '0')}';
    final todayStart = DateTime.utc(now.year, now.month, now.day);
    final events = await _readMonthEvents(callsign.toUpperCase(), month);
    return events.where((e) => !e.timestamp.isBefore(todayStart)).toList();
  }

  /// Build action counts for today from events.
  Future<Map<String, int>> getTodayActionCounts(String callsign) async {
    final events = await readTodayEvents(callsign);
    final counts = <String, int>{};
    for (final event in events) {
      counts[event.action] = (counts[event.action] ?? 0) + 1;
    }
    return counts;
  }

  /// Get the timestamp of the last event for a specific action from a callsign.
  Future<DateTime?> getLastActionTime(String callsign, String action) async {
    final events = await readTodayEvents(callsign);
    DateTime? latest;
    for (final event in events) {
      if (event.action == action) {
        if (latest == null || event.timestamp.isAfter(latest)) {
          latest = event.timestamp;
        }
      }
    }
    return latest;
  }

  // ============ Profiles (cached aggregate) ============

  /// Read a cached karma profile.
  Future<KarmaProfile?> readProfile(String callsign) async {
    final file = File('$_profilesDir/${callsign.toUpperCase()}.json');
    if (!await file.exists()) return null;

    try {
      final content = await file.readAsString();
      return KarmaProfile.fromJson(jsonDecode(content) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Write a cached karma profile.
  Future<void> writeProfile(KarmaProfile profile) async {
    final dir = Directory(_profilesDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final file = File('${dir.path}/${profile.callsign.toUpperCase()}.json');
    await file.writeAsString(jsonEncode(profile.toJson()));
  }

  /// List all callsigns that have profiles.
  Future<List<String>> listProfileCallsigns() async {
    final dir = Directory(_profilesDir);
    if (!await dir.exists()) return [];

    final callsigns = <String>[];
    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.json')) {
        final name = entity.path.split('/').last;
        callsigns.add(name.replaceFirst('.json', ''));
      }
    }
    return callsigns;
  }

  /// Read all profiles.
  Future<List<KarmaProfile>> readAllProfiles() async {
    final callsigns = await listProfileCallsigns();
    final profiles = <KarmaProfile>[];
    for (final cs in callsigns) {
      final profile = await readProfile(cs);
      if (profile != null) {
        profiles.add(profile);
      }
    }
    return profiles;
  }

  // ============ Streaks ============

  /// Read streak data for a callsign.
  Future<StreakData> readStreak(String callsign) async {
    final file = File('$_streaksDir/${callsign.toUpperCase()}.json');
    if (!await file.exists()) return StreakData();

    try {
      final content = await file.readAsString();
      return StreakData.fromJson(jsonDecode(content) as Map<String, dynamic>);
    } catch (_) {
      return StreakData();
    }
  }

  /// Write streak data for a callsign.
  Future<void> writeStreak(String callsign, StreakData streak) async {
    final dir = Directory(_streaksDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final file = File('${dir.path}/${callsign.toUpperCase()}.json');
    await file.writeAsString(jsonEncode(streak.toJson()));
  }

  // ============ Leaderboards ============

  /// Read a cached leaderboard.
  Future<List<LeaderboardEntry>> readLeaderboard(String period) async {
    final file = File('$_leaderboardsDir/$period.json');
    if (!await file.exists()) return [];

    try {
      final content = await file.readAsString();
      final list = jsonDecode(content) as List<dynamic>;
      return list.map((e) => LeaderboardEntry.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  /// Write a cached leaderboard.
  Future<void> writeLeaderboard(String period, List<LeaderboardEntry> entries) async {
    final dir = Directory(_leaderboardsDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final file = File('${dir.path}/$period.json');
    await file.writeAsString(jsonEncode(entries.map((e) => e.toJson()).toList()));
  }

  /// Get today's total points for a callsign.
  Future<int> getTodayPoints(String callsign) async {
    final events = await readTodayEvents(callsign);
    int total = 0;
    for (final event in events) {
      total += event.pointsFinal;
    }
    return total;
  }

  /// Ensure base directories exist.
  Future<void> ensureDirectories() async {
    for (final dir in [_eventsDir, _profilesDir, _streaksDir, _leaderboardsDir]) {
      final d = Directory(dir);
      if (!await d.exists()) {
        await d.create(recursive: true);
      }
    }
  }
}
