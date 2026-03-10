/// Pure business logic for the Karma gamification system.
///
/// Contains point values, daily caps, streak multipliers, anti-gaming
/// validation, and level computation. No I/O — that's in KarmaStore.

import 'dart:math';
import 'karma_models.dart';
import 'karma_store.dart';

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
    'daily_login':       KarmaActionConfig(points: 3,  dailyCap: 1,   category: 'connection'),
    'chat_message':      KarmaActionConfig(points: 1,  dailyCap: 10,  category: 'chat'),
    'chat_reaction':     KarmaActionConfig(points: 1,  dailyCap: 5,   category: 'chat'),
    'blog_published':    KarmaActionConfig(points: 5,  dailyCap: 3,   category: 'content'),
    'place_created':     KarmaActionConfig(points: 5,  dailyCap: 3,   category: 'content'),
    'alert_created':     KarmaActionConfig(points: 5,  dailyCap: 3,   category: 'content'),
    'event_created':     KarmaActionConfig(points: 5,  dailyCap: 2,   category: 'content'),
    'like_given':        KarmaActionConfig(points: 1,  dailyCap: 10,  category: 'social'),
    'like_received':     KarmaActionConfig(points: 1,  dailyCap: 15,  category: 'passive'),
    'comment_given':     KarmaActionConfig(points: 1,  dailyCap: 5,   category: 'social'),
    'comment_received':  KarmaActionConfig(points: 1,  dailyCap: 10,  category: 'passive'),
    'verify_given':      KarmaActionConfig(points: 1,  dailyCap: 5,   category: 'social'),
    'alert_verified':    KarmaActionConfig(points: 2,  dailyCap: 10,  category: 'passive'),
    'feature_diversity': KarmaActionConfig(points: 10, dailyCap: 1,   category: 'bonus'),
  };

  // ============ Level System ============

  static const List<KarmaLevel> levels = [
    KarmaLevel(1,  0,     'Drifter'),
    KarmaLevel(2,  50,    'Scavenger'),
    KarmaLevel(3,  150,   'Survivalist'),
    KarmaLevel(4,  400,   'Prepper'),
    KarmaLevel(5,  800,   'Tracker'),
    KarmaLevel(6,  1500,  'Cypherpunk'),
    KarmaLevel(7,  3000,  'Outlaw'),
    KarmaLevel(8,  5000,  'Warden'),
    KarmaLevel(9,  8000,  'Offgrid'),
    KarmaLevel(10, 12000, 'Cipher'),
    KarmaLevel(11, 18000, 'Ghost'),
    KarmaLevel(12, 25000, 'Sovereign'),
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

  // ============ Daily Missions ============

  /// The canonical list of daily missions and their action keys.
  static const List<KarmaMission> missions = [
    KarmaMission(
      name: 'Chat',
      verb: 'Send Messages',
      description: 'Join a chat room and send messages or react to others\' messages. '
          'Earn 1 point per message (up to 10) and 1 point per reaction (up to 5).',
      actionKeys: ['chat_message', 'chat_reaction'],
      navigateTo: 'chat',
    ),
    KarmaMission(
      name: 'Blog',
      verb: 'Write a Post',
      description: 'Publish a blog post to share your thoughts or experiences. '
          'Earn 5 points per post (up to 3 per day).',
      actionKeys: ['blog_published'],
      navigateTo: 'blog',
    ),
    KarmaMission(
      name: 'Places',
      verb: 'Share a Place',
      description: 'Pin a place on the map to share a location with the community. '
          'Earn 5 points per place (up to 3 per day).',
      actionKeys: ['place_created'],
      navigateTo: 'places',
    ),
    KarmaMission(
      name: 'Alerts',
      verb: 'Report an Alert',
      description: 'Report a local alert (weather, traffic, safety, etc.) to help others nearby. '
          'Earn 5 points per alert (up to 3 per day).',
      actionKeys: ['alert_created'],
      navigateTo: 'alerts',
    ),
    KarmaMission(
      name: 'Social',
      verb: 'Engage Socially',
      description: 'Interact with others\' content: like posts (1 point, up to 10), '
          'leave comments (1 point, up to 5), or verify alerts (1 point, up to 5).',
      actionKeys: ['like_given', 'comment_given', 'verify_given'],
      navigateTo: null,
    ),
    KarmaMission(
      name: 'Events',
      verb: 'Create an Event',
      description: 'Organize a local event for the community to join. '
          'Earn 5 points per event (up to 2 per day).',
      actionKeys: ['event_created'],
      navigateTo: 'events',
    ),
  ];

  /// Count how many missions have been started (at least 1 action performed).
  static int countStartedMissions(Map<String, int> actionCounts) {
    int started = 0;
    for (final m in missions) {
      if (m.isStarted(actionCounts)) started++;
    }
    return started;
  }

  /// Count how many missions have NOT been started yet.
  static int countUnstartedMissions(Map<String, int> actionCounts) {
    return missions.length - countStartedMissions(actionCounts);
  }

  /// Get today's action counts from the store, preferring the cached profile.
  static Future<Map<String, int>> getTodayActionCountsWithFallback(
    KarmaStore store,
    String callsign,
  ) async {
    final profile = await store.readProfile(callsign.toUpperCase());
    if (profile != null) return profile.actionCountsToday;
    return store.getTodayActionCounts(callsign.toUpperCase());
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

/// A daily mission definition with helper methods for progress tracking.
class KarmaMission {
  final String name;
  final String verb;
  final String description;
  final List<String> actionKeys;
  final String? navigateTo;

  const KarmaMission({
    required this.name,
    required this.verb,
    required this.description,
    required this.actionKeys,
    required this.navigateTo,
  });

  /// Maximum points earnable per day for this mission.
  int get maxDailyPoints {
    int total = 0;
    for (final key in actionKeys) {
      final config = KarmaEngine.actions[key];
      if (config != null) {
        total += config.points * config.dailyCap;
      }
    }
    return total;
  }

  /// Points earned today for this mission.
  int todayEarned(Map<String, int> actionCounts) {
    int total = 0;
    for (final key in actionKeys) {
      final config = KarmaEngine.actions[key];
      if (config != null) {
        final count = actionCounts[key] ?? 0;
        final capped = count.clamp(0, config.dailyCap);
        total += config.points * capped;
      }
    }
    return total;
  }

  /// Progress fraction (0.0 to 1.0) for this mission today.
  double progress(Map<String, int> actionCounts) {
    final max = maxDailyPoints;
    if (max == 0) return 0.0;
    return todayEarned(actionCounts) / max;
  }

  /// Whether all action keys have hit their daily cap.
  bool isComplete(Map<String, int> actionCounts) {
    for (final key in actionKeys) {
      final config = KarmaEngine.actions[key];
      if (config != null) {
        final count = actionCounts[key] ?? 0;
        if (count < config.dailyCap) return false;
      }
    }
    return true;
  }

  /// Whether any action in this mission has been performed at least once.
  bool isStarted(Map<String, int> actionCounts) {
    for (final key in actionKeys) {
      if ((actionCounts[key] ?? 0) > 0) return true;
    }
    return false;
  }
}
