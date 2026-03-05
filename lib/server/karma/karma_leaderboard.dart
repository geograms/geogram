/// Leaderboard computation and caching for the Karma system.
///
/// Computes leaderboards from profiles for weekly, monthly, yearly,
/// and all-time periods. Results are cached to disk.

import 'karma_models.dart';
import 'karma_engine.dart';
import 'karma_store.dart';

class KarmaLeaderboard {
  final KarmaStore store;

  KarmaLeaderboard({required this.store});

  static const List<String> periods = ['weekly', 'monthly', 'yearly', 'alltime'];

  /// Recompute and cache all leaderboards from current profiles.
  Future<void> recomputeAll() async {
    final profiles = await store.readAllProfiles();
    if (profiles.isEmpty) return;

    // All-time: just sort by total points
    final allTime = _buildLeaderboard(profiles);
    await store.writeLeaderboard('alltime', allTime);

    // Weekly/monthly/yearly: sum events from the relevant period
    final now = DateTime.now().toUtc();
    for (final period in ['weekly', 'monthly', 'yearly']) {
      final start = _periodStart(period, now);
      final periodProfiles = await _aggregateForPeriod(profiles, start, now);
      final board = _buildLeaderboard(periodProfiles);
      await store.writeLeaderboard(period, board);
    }
  }

  /// Build a ranked leaderboard from profiles.
  List<LeaderboardEntry> _buildLeaderboard(List<KarmaProfile> profiles) {
    profiles.sort((a, b) => b.totalPoints.compareTo(a.totalPoints));
    final entries = <LeaderboardEntry>[];
    for (int i = 0; i < profiles.length; i++) {
      final p = profiles[i];
      final level = KarmaEngine.computeLevel(p.totalPoints);
      entries.add(LeaderboardEntry(
        rank: i + 1,
        callsign: p.callsign,
        points: p.totalPoints,
        level: level.level,
        levelName: level.name,
        streakDays: p.currentStreakDays,
      ));
    }
    return entries;
  }

  /// Aggregate event points for each callsign within a date range.
  Future<List<KarmaProfile>> _aggregateForPeriod(
    List<KarmaProfile> allProfiles,
    DateTime start,
    DateTime end,
  ) async {
    final result = <KarmaProfile>[];
    for (final profile in allProfiles) {
      final events = await _readEventsInRange(profile.callsign, start, end);
      int periodPoints = 0;
      for (final event in events) {
        periodPoints += event.pointsFinal;
      }
      if (periodPoints > 0) {
        result.add(KarmaProfile(
          callsign: profile.callsign,
          totalPoints: periodPoints,
          currentStreakDays: profile.currentStreakDays,
        ));
      }
    }
    return result;
  }

  /// Read events for a callsign within a date range.
  Future<List<KarmaEvent>> _readEventsInRange(
    String callsign,
    DateTime start,
    DateTime end,
  ) async {
    // Determine which months to scan
    final months = <String>[];
    var cursor = DateTime.utc(start.year, start.month, 1);
    while (cursor.isBefore(end) || (cursor.year == end.year && cursor.month == end.month)) {
      months.add('${cursor.year}-${cursor.month.toString().padLeft(2, '0')}');
      cursor = DateTime.utc(cursor.year, cursor.month + 1, 1);
    }

    final events = <KarmaEvent>[];
    for (final month in months) {
      final monthEvents = await store.readEvents(callsign, month: month, limit: 100000);
      for (final event in monthEvents) {
        if (!event.timestamp.isBefore(start) && event.timestamp.isBefore(end)) {
          events.add(event);
        }
      }
    }
    return events;
  }

  DateTime _periodStart(String period, DateTime now) {
    switch (period) {
      case 'weekly':
        return now.subtract(Duration(days: now.weekday - 1)); // Monday
      case 'monthly':
        return DateTime.utc(now.year, now.month, 1);
      case 'yearly':
        return DateTime.utc(now.year, 1, 1);
      default:
        return DateTime.utc(2020, 1, 1);
    }
  }

  /// Get station-wide karma stats.
  Future<KarmaStats> getStationStats() async {
    final profiles = await store.readAllProfiles();
    final now = DateTime.now().toUtc();
    final todayStart = DateTime.utc(now.year, now.month, now.day);

    int activeToday = 0;
    int totalPoints = 0;
    final actionTotals = <String, int>{};

    for (final profile in profiles) {
      totalPoints += profile.totalPoints;
      if (profile.lastActivity != null && !profile.lastActivity!.isBefore(todayStart)) {
        activeToday++;
      }
      for (final entry in profile.actionCountsToday.entries) {
        actionTotals[entry.key] = (actionTotals[entry.key] ?? 0) + entry.value;
      }
    }

    String? topAction;
    int topCount = 0;
    for (final entry in actionTotals.entries) {
      if (entry.value > topCount) {
        topCount = entry.value;
        topAction = entry.key;
      }
    }

    return KarmaStats(
      totalUsers: profiles.length,
      activeToday: activeToday,
      topAction: topAction,
      totalPointsAwarded: totalPoints,
    );
  }
}
