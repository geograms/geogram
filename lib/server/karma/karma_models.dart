/// Data models for the Karma gamification system.
///
/// All karma data is station-global (not per-callsign ProfileStorage).
/// Events are append-only JSONL logs; profiles and streaks are cached aggregates.

/// A single karma-earning event (one line in JSONL log).
class KarmaEvent {
  final DateTime timestamp;
  final String action;
  final int pointsRaw;
  final double multiplier;
  final int pointsFinal;
  final Map<String, dynamic> meta;

  KarmaEvent({
    required this.timestamp,
    required this.action,
    required this.pointsRaw,
    required this.multiplier,
    required this.pointsFinal,
    this.meta = const {},
  });

  factory KarmaEvent.fromJson(Map<String, dynamic> json) {
    return KarmaEvent(
      timestamp: DateTime.parse(json['ts'] as String),
      action: json['action'] as String,
      pointsRaw: json['points_raw'] as int? ?? 0,
      multiplier: (json['multiplier'] as num?)?.toDouble() ?? 1.0,
      pointsFinal: json['points_final'] as int? ?? 0,
      meta: (json['meta'] as Map<String, dynamic>?) ?? {},
    );
  }

  Map<String, dynamic> toJson() => {
    'ts': timestamp.toUtc().toIso8601String(),
    'action': action,
    'points_raw': pointsRaw,
    'multiplier': multiplier,
    'points_final': pointsFinal,
    if (meta.isNotEmpty) 'meta': meta,
  };
}

/// Cached aggregate karma profile for a callsign.
class KarmaProfile {
  final String callsign;
  int totalPoints;
  int level;
  String levelName;
  int nextLevelPoints;
  int currentStreakDays;
  double currentMultiplier;
  Map<String, int> actionCountsToday;
  DateTime? lastActivity;
  int rank;

  KarmaProfile({
    required this.callsign,
    this.totalPoints = 0,
    this.level = 1,
    this.levelName = 'Drifter',
    this.nextLevelPoints = 50,
    this.currentStreakDays = 0,
    this.currentMultiplier = 1.0,
    Map<String, int>? actionCountsToday,
    this.lastActivity,
    this.rank = 0,
  }) : actionCountsToday = actionCountsToday ?? {};

  factory KarmaProfile.fromJson(Map<String, dynamic> json) {
    return KarmaProfile(
      callsign: json['callsign'] as String,
      totalPoints: json['total_points'] as int? ?? 0,
      level: json['level'] as int? ?? 1,
      levelName: json['level_name'] as String? ?? 'Drifter',
      nextLevelPoints: json['next_level_points'] as int? ?? 50,
      currentStreakDays: json['current_streak_days'] as int? ?? 0,
      currentMultiplier: (json['current_multiplier'] as num?)?.toDouble() ?? 1.0,
      actionCountsToday: (json['action_counts_today'] as Map<String, dynamic>?)
          ?.map((k, v) => MapEntry(k, v as int)) ?? {},
      lastActivity: json['last_activity'] != null
          ? DateTime.tryParse(json['last_activity'] as String)
          : null,
      rank: json['rank'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'callsign': callsign,
    'total_points': totalPoints,
    'level': level,
    'level_name': levelName,
    'next_level_points': nextLevelPoints,
    'current_streak_days': currentStreakDays,
    'current_multiplier': currentMultiplier,
    'action_counts_today': actionCountsToday,
    'last_activity': lastActivity?.toUtc().toIso8601String(),
    'rank': rank,
  };
}

/// Streak tracking data for a callsign.
class StreakData {
  int currentStreak;
  int longestStreak;
  DateTime? lastActiveDate;
  int weeklyBonusWeeks;

  StreakData({
    this.currentStreak = 0,
    this.longestStreak = 0,
    this.lastActiveDate,
    this.weeklyBonusWeeks = 0,
  });

  factory StreakData.fromJson(Map<String, dynamic> json) {
    return StreakData(
      currentStreak: json['current_streak'] as int? ?? 0,
      longestStreak: json['longest_streak'] as int? ?? 0,
      lastActiveDate: json['last_active_date'] != null
          ? DateTime.tryParse(json['last_active_date'] as String)
          : null,
      weeklyBonusWeeks: json['weekly_bonus_weeks'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'current_streak': currentStreak,
    'longest_streak': longestStreak,
    'last_active_date': lastActiveDate?.toIso8601String(),
    'weekly_bonus_weeks': weeklyBonusWeeks,
  };
}

/// A single entry in a leaderboard.
class LeaderboardEntry {
  final int rank;
  final String callsign;
  final int points;
  final int level;
  final String levelName;
  final int streakDays;

  LeaderboardEntry({
    required this.rank,
    required this.callsign,
    required this.points,
    required this.level,
    required this.levelName,
    this.streakDays = 0,
  });

  factory LeaderboardEntry.fromJson(Map<String, dynamic> json) {
    return LeaderboardEntry(
      rank: json['rank'] as int? ?? 0,
      callsign: json['callsign'] as String,
      points: json['points'] as int? ?? 0,
      level: json['level'] as int? ?? 1,
      levelName: json['level_name'] as String? ?? 'Drifter',
      streakDays: json['streak_days'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'rank': rank,
    'callsign': callsign,
    'points': points,
    'level': level,
    'level_name': levelName,
    'streak_days': streakDays,
  };
}

/// Station-wide karma statistics.
class KarmaStats {
  final int totalUsers;
  final int activeToday;
  final String? topAction;
  final int totalPointsAwarded;

  KarmaStats({
    this.totalUsers = 0,
    this.activeToday = 0,
    this.topAction,
    this.totalPointsAwarded = 0,
  });

  Map<String, dynamic> toJson() => {
    'total_users': totalUsers,
    'active_today': activeToday,
    'top_action': topAction,
    'total_points_awarded': totalPointsAwarded,
  };
}
