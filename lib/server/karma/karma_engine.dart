/// Pure business logic for the Karma gamification system.
///
/// Contains point values, daily caps, streak multipliers, anti-gaming
/// validation, and level computation. No I/O — that's in KarmaStore.

import 'dart:math';
import 'karma_models.dart';

/// Point values and daily caps for each karma action.
class KarmaActionConfig {
  final int points;
  final int dailyCap;
  final String category;

  const KarmaActionConfig({
    required this.points,
    required this.dailyCap,
    required this.category,
  });
}

/// Level definition.
class KarmaLevel {
  final int level;
  final int pointsRequired;
  final String name;

  const KarmaLevel(this.level, this.pointsRequired, this.name);
}

class KarmaEngine {
  // ============ Action Configuration ============

  static const Map<String, KarmaActionConfig> actions = {
    'daily_login':       KarmaActionConfig(points: 10, dailyCap: 1,   category: 'connection'),
    'chat_message':      KarmaActionConfig(points: 2,  dailyCap: 50,  category: 'chat'),
    'chat_reaction':     KarmaActionConfig(points: 1,  dailyCap: 20,  category: 'chat'),
    'blog_published':    KarmaActionConfig(points: 50, dailyCap: 3,   category: 'content'),
    'place_created':     KarmaActionConfig(points: 30, dailyCap: 5,   category: 'content'),
    'alert_created':     KarmaActionConfig(points: 25, dailyCap: 5,   category: 'content'),
    'event_created':     KarmaActionConfig(points: 30, dailyCap: 3,   category: 'content'),
    'like_given':        KarmaActionConfig(points: 2,  dailyCap: 30,  category: 'social'),
    'like_received':     KarmaActionConfig(points: 3,  dailyCap: 50,  category: 'passive'),
    'comment_given':     KarmaActionConfig(points: 5,  dailyCap: 20,  category: 'social'),
    'comment_received':  KarmaActionConfig(points: 3,  dailyCap: 30,  category: 'passive'),
    'verify_given':      KarmaActionConfig(points: 5,  dailyCap: 10,  category: 'social'),
    'alert_verified':    KarmaActionConfig(points: 10, dailyCap: 999, category: 'passive'),
    'feature_diversity': KarmaActionConfig(points: 15, dailyCap: 1,   category: 'bonus'),
  };

  // ============ Level System ============

  static const List<KarmaLevel> levels = [
    KarmaLevel(1,  0,     'Newcomer'),
    KarmaLevel(2,  50,    'Explorer'),
    KarmaLevel(3,  150,   'Scout'),
    KarmaLevel(4,  400,   'Pathfinder'),
    KarmaLevel(5,  800,   'Navigator'),
    KarmaLevel(6,  1500,  'Surveyor'),
    KarmaLevel(7,  3000,  'Trailblazer'),
    KarmaLevel(8,  5000,  'Cartographer'),
    KarmaLevel(9,  8000,  'Ranger'),
    KarmaLevel(10, 12000, 'Pioneer'),
    KarmaLevel(11, 18000, 'Legend'),
    KarmaLevel(12, 25000, 'Grandmaster'),
  ];

  // ============ Streak Multipliers ============

  /// Get the streak multiplier for a given number of consecutive days.
  static double getStreakMultiplier(int consecutiveDays) {
    if (consecutiveDays >= 90) return 2.5;
    if (consecutiveDays >= 60) return 2.0;
    if (consecutiveDays >= 30) return 1.75;
    if (consecutiveDays >= 14) return 1.5;
    if (consecutiveDays >= 7)  return 1.25;
    if (consecutiveDays >= 3)  return 1.1;
    return 1.0;
  }

  // ============ Anti-Gaming ============

  /// Minimum message length to earn karma.
  static const int minChatLength = 4;

  /// Minimum seconds between same action from same callsign.
  static const int dedupeWindowSeconds = 2;

  /// Number of distinct categories needed for feature_diversity bonus.
  static const int diversityCategoriesRequired = 3;

  // ============ Business Logic ============

  /// Calculate points for an action, applying daily cap and streak multiplier.
  /// Returns null if the action should be rejected (capped or invalid).
  static KarmaEvent? calculatePoints({
    required String action,
    required Map<String, int> actionCountsToday,
    required int currentStreakDays,
    Map<String, dynamic> meta = const {},
  }) {
    final config = actions[action];
    if (config == null) return null;

    final todayCount = actionCountsToday[action] ?? 0;
    if (todayCount >= config.dailyCap) return null;

    final multiplier = getStreakMultiplier(currentStreakDays);
    final pointsFinal = (config.points * multiplier).round();

    return KarmaEvent(
      timestamp: DateTime.now().toUtc(),
      action: action,
      pointsRaw: config.points,
      multiplier: multiplier,
      pointsFinal: pointsFinal,
      meta: meta,
    );
  }

  /// Validate a chat message for karma eligibility.
  static bool isValidChatMessage(String content, String? previousContent) {
    if (content.length < minChatLength) return false;
    if (previousContent != null && content == previousContent) return false;
    return true;
  }

  /// Check if self-interaction (can't like own content).
  static bool isSelfInteraction(String actorCallsign, String ownerCallsign) {
    return actorCallsign.toUpperCase() == ownerCallsign.toUpperCase();
  }

  /// Check if an action is too soon (dedup within 2 seconds).
  static bool isTooSoon(DateTime? lastActionTime) {
    if (lastActionTime == null) return false;
    return DateTime.now().toUtc().difference(lastActionTime).inSeconds < dedupeWindowSeconds;
  }

  /// Compute level from total points.
  static KarmaLevel computeLevel(int totalPoints) {
    KarmaLevel result = levels.first;
    for (final level in levels) {
      if (totalPoints >= level.pointsRequired) {
        result = level;
      } else {
        break;
      }
    }
    return result;
  }

  /// Get points needed for next level. Returns null if at max level.
  static int? pointsToNextLevel(int totalPoints) {
    for (int i = 0; i < levels.length; i++) {
      if (totalPoints < levels[i].pointsRequired) {
        return levels[i].pointsRequired;
      }
    }
    return null; // Already at max
  }

  /// Update streak data for a new activity day.
  /// Returns updated streak data and any bonus points earned.
  static ({StreakData streak, int bonusPoints}) updateStreak(StreakData current) {
    final now = DateTime.now().toUtc();
    final today = DateTime.utc(now.year, now.month, now.day);
    int bonus = 0;

    if (current.lastActiveDate == null) {
      // First ever activity
      return (
        streak: StreakData(
          currentStreak: 1,
          longestStreak: 1,
          lastActiveDate: today,
          weeklyBonusWeeks: 0,
        ),
        bonusPoints: 0,
      );
    }

    final lastDate = DateTime.utc(
      current.lastActiveDate!.year,
      current.lastActiveDate!.month,
      current.lastActiveDate!.day,
    );
    final daysDiff = today.difference(lastDate).inDays;

    if (daysDiff == 0) {
      // Same day — no streak change
      return (streak: current, bonusPoints: 0);
    }

    int newStreak;
    if (daysDiff == 1) {
      // Consecutive day
      newStreak = current.currentStreak + 1;
    } else if (daysDiff == 2) {
      // Missed 1 day — streak drops by 3 but doesn't go below 1
      newStreak = max(1, current.currentStreak - 3);
    } else {
      // Missed 2+ days — full reset
      newStreak = 1;
    }

    // Weekly bonus: 50 points for each week in a 4+ week streak where 100+ points earned
    int newWeeklyBonusWeeks = current.weeklyBonusWeeks;
    if (newStreak >= 28 && newStreak % 7 == 0) {
      newWeeklyBonusWeeks++;
      bonus = 50;
    }

    return (
      streak: StreakData(
        currentStreak: newStreak,
        longestStreak: max(newStreak, current.longestStreak),
        lastActiveDate: today,
        weeklyBonusWeeks: newWeeklyBonusWeeks,
      ),
      bonusPoints: bonus,
    );
  }

  /// Check if feature diversity bonus should be awarded.
  /// Returns true if 3+ distinct categories were used today.
  static bool checkFeatureDiversity(Map<String, int> actionCountsToday) {
    final categoriesUsed = <String>{};
    for (final entry in actionCountsToday.entries) {
      final config = actions[entry.key];
      if (config != null && entry.value > 0 && config.category != 'bonus') {
        categoriesUsed.add(config.category);
      }
    }
    return categoriesUsed.length >= diversityCategoriesRequired;
  }

  /// Build a KarmaProfile from total points and streak data.
  static KarmaProfile buildProfile({
    required String callsign,
    required int totalPoints,
    required StreakData streak,
    required Map<String, int> actionCountsToday,
    DateTime? lastActivity,
    int rank = 0,
  }) {
    final level = computeLevel(totalPoints);
    final nextLevel = pointsToNextLevel(totalPoints);

    return KarmaProfile(
      callsign: callsign,
      totalPoints: totalPoints,
      level: level.level,
      levelName: level.name,
      nextLevelPoints: nextLevel ?? level.pointsRequired,
      currentStreakDays: streak.currentStreak,
      currentMultiplier: getStreakMultiplier(streak.currentStreak),
      actionCountsToday: actionCountsToday,
      lastActivity: lastActivity,
      rank: rank,
    );
  }

  /// Map a feedback action name to the corresponding karma action.
  static String? feedbackToKarmaAction(String feedbackAction, {required bool isGiver}) {
    switch (feedbackAction) {
      case 'like':
      case 'point':
        return isGiver ? 'like_given' : 'like_received';
      case 'comment':
        return isGiver ? 'comment_given' : 'comment_received';
      case 'verify':
        return isGiver ? 'verify_given' : 'alert_verified';
      case 'react':
        return isGiver ? 'chat_reaction' : null;
      default:
        return null;
    }
  }
}
