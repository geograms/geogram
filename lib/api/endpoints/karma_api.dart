/// Client-side API wrapper for karma endpoints.
///
/// Follows the same pattern as ChatApi, FeedbackApi, etc.

import '../api.dart';
import '../../server/karma/karma_models.dart';

export '../../server/karma/karma_models.dart';

class KarmaApi {
  final GeogramApi _api;

  KarmaApi(this._api);

  /// Get a user's karma profile.
  Future<ApiResponse<KarmaProfile>> profile(
    String callsign, {
    String? targetCallsign,
    Map<String, String>? authHeaders,
  }) {
    final target = targetCallsign ?? callsign;
    return _api.get<KarmaProfile>(
      callsign,
      '/api/karma/profile/$target',
      headers: authHeaders,
      fromJson: (json) => KarmaProfile.fromJson(json as Map<String, dynamic>),
    );
  }

  /// Get karma leaderboard for a period.
  /// Period: 'weekly', 'monthly', 'yearly', 'alltime'.
  Future<ApiResponse<List<LeaderboardEntry>>> leaderboard(
    String callsign, {
    String period = 'alltime',
    int limit = 20,
  }) {
    return _api.get<List<LeaderboardEntry>>(
      callsign,
      '/api/karma/leaderboard/$period',
      queryParams: {'limit': limit},
      fromJson: (json) {
        final data = json as Map<String, dynamic>;
        final entries = data['entries'] as List<dynamic>? ?? [];
        return entries
            .map((e) => LeaderboardEntry.fromJson(e as Map<String, dynamic>))
            .toList();
      },
    );
  }

  /// Get karma event history for a user.
  Future<ApiResponse<List<KarmaEvent>>> history(
    String callsign, {
    String? targetCallsign,
    int limit = 50,
    int offset = 0,
    Map<String, String>? authHeaders,
  }) {
    final target = targetCallsign ?? callsign;
    return _api.get<List<KarmaEvent>>(
      callsign,
      '/api/karma/history/$target',
      queryParams: {'limit': limit, 'offset': offset},
      headers: authHeaders,
      fromJson: (json) {
        final data = json as Map<String, dynamic>;
        final events = data['events'] as List<dynamic>? ?? [];
        return events
            .map((e) => KarmaEvent.fromJson(e as Map<String, dynamic>))
            .toList();
      },
    );
  }

  /// Get streak details for a user.
  Future<ApiResponse<StreakData>> streak(
    String callsign, {
    String? targetCallsign,
    Map<String, String>? authHeaders,
  }) {
    final target = targetCallsign ?? callsign;
    return _api.get<StreakData>(
      callsign,
      '/api/karma/streak/$target',
      headers: authHeaders,
      fromJson: (json) => StreakData.fromJson(json as Map<String, dynamic>),
    );
  }

  /// Get station-wide karma stats (public).
  Future<ApiResponse<KarmaStats>> stats(String callsign) {
    return _api.get<KarmaStats>(
      callsign,
      '/api/karma/stats',
      fromJson: (json) {
        final data = json as Map<String, dynamic>;
        return KarmaStats(
          totalUsers: data['total_users'] as int? ?? 0,
          activeToday: data['active_today'] as int? ?? 0,
          topAction: data['top_action'] as String?,
          totalPointsAwarded: data['total_points_awarded'] as int? ?? 0,
        );
      },
    );
  }
}
