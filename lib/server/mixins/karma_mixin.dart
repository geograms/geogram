/// Karma gamification mixin for station servers.
///
/// Provides karmaRecord() for awarding points, HTTP API handlers for
/// karma endpoints, and periodic leaderboard recomputation.
/// Follows the RateLimitMixin pattern: abstract deps, lazy services.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../services/nip05_registry_service.dart';
import '../../util/nostr_crypto.dart';
import '../../util/nostr_event.dart';
import '../karma/karma_engine.dart';
import '../karma/karma_leaderboard.dart';
import '../karma/karma_models.dart';
import '../karma/karma_store.dart';

/// Mixin providing karma gamification for station servers.
mixin KarmaMixin {
  // ============ Abstract Dependencies ============

  void log(String level, String message);
  String? get dataDir;

  /// Send a string payload to all connected clients matching a callsign.
  /// Override in the using class to bridge to whatever client model is used.
  void karmaBroadcastToCallsign(String callsign, String payload);

  // ============ Lazy Services ============

  KarmaStore? _karmaStore;
  KarmaLeaderboard? _karmaLeaderboard;
  Timer? _karmaAggregationTimer;

  /// In-memory cache: callsign -> last action timestamp per action type.
  final Map<String, Map<String, DateTime>> _karmaLastAction = {};

  /// In-memory cache: callsign -> today's action counts.
  final Map<String, Map<String, int>> _karmaTodayCounts = {};

  /// In-memory cache: callsign -> previous chat message content.
  final Map<String, String> _karmaPreviousChatMessage = {};

  /// Date for which _karmaTodayCounts is valid.
  DateTime? _karmaTodayDate;

  KarmaStore get karmaStore {
    _karmaStore ??= KarmaStore(baseDir: '$dataDir/karma');
    return _karmaStore!;
  }

  KarmaLeaderboard get karmaLeaderboard {
    _karmaLeaderboard ??= KarmaLeaderboard(store: karmaStore);
    return _karmaLeaderboard!;
  }

  // ============ Lifecycle ============

  /// Call from onServerStart().
  Future<void> startKarmaService() async {
    if (dataDir == null) return;
    await karmaStore.ensureDirectories();

    // Recompute leaderboards on startup
    try {
      await karmaLeaderboard.recomputeAll();
    } catch (e) {
      log('WARN', 'Karma: failed to compute leaderboards on startup: $e');
    }

    // Periodic recomputation every 5 minutes
    _karmaAggregationTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) async {
        try {
          await karmaLeaderboard.recomputeAll();
        } catch (e) {
          log('WARN', 'Karma: periodic leaderboard recomputation failed: $e');
        }
      },
    );

    log('INFO', 'Karma service started');
  }

  /// Call from onServerStop().
  void stopKarmaService() {
    _karmaAggregationTimer?.cancel();
    _karmaAggregationTimer = null;
    log('INFO', 'Karma service stopped');
  }

  // ============ Core: Record Karma ============

  /// Record a karma event for a callsign.
  /// Returns the points awarded (0 if rejected by caps/validation).
  Future<int> karmaRecord({
    required String callsign,
    required String action,
    Map<String, dynamic> meta = const {},
  }) async {
    if (dataDir == null) return 0;

    try {
      // Reset today's counts if date changed
      _ensureTodayCounts();

      final cs = callsign.toUpperCase();

      // Anti-gaming: dedup within 2 seconds
      final lastTime = _karmaLastAction[cs]?[action];
      if (KarmaEngine.isTooSoon(lastTime)) return 0;

      // Get today's counts from cache
      final todayCounts = _karmaTodayCounts[cs] ??= {};

      // Calculate points (may return null if capped)
      final event = KarmaEngine.calculatePoints(
        action: action,
        actionCountsToday: todayCounts,
        currentStreakDays: await _getStreakDays(cs),
        meta: meta,
      );
      if (event == null) return 0;

      // Persist event
      await karmaStore.appendEvent(cs, event);

      // Update in-memory caches
      todayCounts[action] = (todayCounts[action] ?? 0) + 1;
      _karmaLastAction.putIfAbsent(cs, () => {})[action] = DateTime.now().toUtc();

      // Update streak
      final streakData = await karmaStore.readStreak(cs);
      final streakResult = KarmaEngine.updateStreak(streakData);
      await karmaStore.writeStreak(cs, streakResult.streak);

      // Check feature diversity bonus
      if (todayCounts['feature_diversity'] == null || todayCounts['feature_diversity'] == 0) {
        if (KarmaEngine.checkFeatureDiversity(todayCounts)) {
          // Award diversity bonus (recursive but won't loop — cap is 1)
          await karmaRecord(callsign: cs, action: 'feature_diversity');
        }
      }

      // Update cached profile
      final totalPoints = await _computeTotalPoints(cs);
      final profile = KarmaEngine.buildProfile(
        callsign: cs,
        totalPoints: totalPoints,
        streak: streakResult.streak,
        actionCountsToday: todayCounts,
        lastActivity: DateTime.now().toUtc(),
      );
      await karmaStore.writeProfile(profile);

      // Push real-time update to connected client
      _pushKarmaUpdate(cs, event, profile);

      return event.pointsFinal;
    } catch (e) {
      log('ERROR', 'Karma: failed to record $action for $callsign: $e');
      return 0;
    }
  }

  // ============ HTTP API Handlers ============

  /// Route /api/karma/* requests.
  Future<void> handleKarmaRequest(HttpRequest request) async {
    final path = request.uri.path;
    final segments = request.uri.pathSegments;

    try {
      // /api/karma/stats — public
      if (path == '/api/karma/stats') {
        await _handleKarmaStats(request);
        return;
      }

      // /api/karma/leaderboard/{period} — public
      if (segments.length >= 3 && segments[2] == 'leaderboard') {
        final period = segments.length > 3 ? segments[3] : 'alltime';
        await _handleKarmaLeaderboard(request, period);
        return;
      }

      // Debug endpoints (localhost only)
      if (segments.length >= 3 && segments[2] == 'debug') {
        final remoteAddr = request.connectionInfo?.remoteAddress.address;
        if (remoteAddr == '127.0.0.1' || remoteAddr == '::1') {
          await _handleKarmaDebug(request, segments);
          return;
        }
        _karmaJson(request, 403, {'error': 'Debug endpoints are localhost-only'});
        return;
      }

      // Authenticated endpoints below
      final authCallsign = _verifyKarmaAuth(request);
      if (authCallsign == null) {
        _karmaJson(request, 401, {'error': 'Authentication required'});
        return;
      }

      // /api/karma/profile/{callsign}
      if (segments.length >= 3 && segments[2] == 'profile') {
        final targetCallsign = segments.length > 3 ? segments[3] : authCallsign;
        await _handleKarmaProfile(request, targetCallsign);
        return;
      }

      // /api/karma/history/{callsign}
      if (segments.length >= 3 && segments[2] == 'history') {
        final targetCallsign = segments.length > 3 ? segments[3] : authCallsign;
        await _handleKarmaHistory(request, targetCallsign);
        return;
      }

      // /api/karma/streak/{callsign}
      if (segments.length >= 3 && segments[2] == 'streak') {
        final targetCallsign = segments.length > 3 ? segments[3] : authCallsign;
        await _handleKarmaStreak(request, targetCallsign);
        return;
      }

      _karmaJson(request, 404, {'error': 'Not found'});
    } catch (e) {
      log('ERROR', 'Karma API error: $e');
      _karmaJson(request, 500, {'error': 'Internal server error'});
    }
  }

  Future<void> _handleKarmaStats(HttpRequest request) async {
    final stats = await karmaLeaderboard.getStationStats();
    _karmaJson(request, 200, stats.toJson());
  }

  Future<void> _handleKarmaLeaderboard(HttpRequest request, String period) async {
    if (!KarmaLeaderboard.periods.contains(period)) {
      _karmaJson(request, 400, {'error': 'Invalid period. Use: ${KarmaLeaderboard.periods.join(", ")}'});
      return;
    }

    final limitStr = request.uri.queryParameters['limit'] ?? '20';
    final limit = int.tryParse(limitStr) ?? 20;

    final entries = await karmaStore.readLeaderboard(period);
    final limited = entries.take(limit).toList();
    _karmaJson(request, 200, {
      'period': period,
      'entries': limited.map((e) => e.toJson()).toList(),
      'total': entries.length,
    });
  }

  Future<void> _handleKarmaProfile(HttpRequest request, String callsign) async {
    final cs = callsign.toUpperCase();
    var profile = await karmaStore.readProfile(cs);

    if (profile == null) {
      // Build fresh profile
      final streak = await karmaStore.readStreak(cs);
      final todayCounts = await karmaStore.getTodayActionCounts(cs);
      final totalPoints = await _computeTotalPoints(cs);
      profile = KarmaEngine.buildProfile(
        callsign: cs,
        totalPoints: totalPoints,
        streak: streak,
        actionCountsToday: todayCounts,
      );
    }

    // Add rank from leaderboard
    final allTime = await karmaStore.readLeaderboard('alltime');
    final rankIdx = allTime.indexWhere((e) => e.callsign == cs);
    profile.rank = rankIdx >= 0 ? rankIdx + 1 : 0;

    // Add today's points
    final todayPoints = await karmaStore.getTodayPoints(cs);

    _karmaJson(request, 200, {
      ...profile.toJson(),
      'today_points': todayPoints,
    });
  }

  Future<void> _handleKarmaHistory(HttpRequest request, String callsign) async {
    final limitStr = request.uri.queryParameters['limit'] ?? '50';
    final offsetStr = request.uri.queryParameters['offset'] ?? '0';
    final limit = int.tryParse(limitStr) ?? 50;
    final offset = int.tryParse(offsetStr) ?? 0;

    final events = await karmaStore.readEvents(callsign, limit: limit, offset: offset);
    _karmaJson(request, 200, {
      'callsign': callsign.toUpperCase(),
      'events': events.map((e) => e.toJson()).toList(),
      'limit': limit,
      'offset': offset,
    });
  }

  Future<void> _handleKarmaStreak(HttpRequest request, String callsign) async {
    final streak = await karmaStore.readStreak(callsign);
    _karmaJson(request, 200, {
      'callsign': callsign.toUpperCase(),
      ...streak.toJson(),
      'multiplier': KarmaEngine.getStreakMultiplier(streak.currentStreak),
    });
  }

  // ============ Debug ============

  Future<void> _handleKarmaDebug(HttpRequest request, List<String> segments) async {
    final method = request.method;

    // GET /api/karma/debug — list available debug actions
    if (method == 'GET' && segments.length == 3) {
      _karmaJson(request, 200, {
        'debug_endpoints': {
          'GET /api/karma/debug': 'List debug endpoints',
          'POST /api/karma/debug/award': 'Award karma: {"callsign":"X1XX","action":"daily_login","meta":{}}',
          'GET /api/karma/debug/profile/{callsign}': 'Get profile (no auth needed)',
          'GET /api/karma/debug/history/{callsign}': 'Get history (no auth needed)',
          'POST /api/karma/debug/recompute': 'Force leaderboard recomputation',
        },
      });
      return;
    }

    // POST /api/karma/debug/award — manually award karma
    if (method == 'POST' && segments.length >= 4 && segments[3] == 'award') {
      final body = await utf8.decoder.bind(request).join();
      final data = jsonDecode(body) as Map<String, dynamic>;
      final callsign = data['callsign'] as String?;
      final action = data['action'] as String?;
      final meta = (data['meta'] as Map<String, dynamic>?) ?? {};

      if (callsign == null || action == null) {
        _karmaJson(request, 400, {'error': 'Missing callsign or action'});
        return;
      }

      final points = await karmaRecord(callsign: callsign, action: action, meta: meta);
      _karmaJson(request, 200, {
        'success': true,
        'callsign': callsign.toUpperCase(),
        'action': action,
        'points_awarded': points,
      });
      return;
    }

    // GET /api/karma/debug/profile/{callsign} — no auth needed
    if (method == 'GET' && segments.length >= 5 && segments[3] == 'profile') {
      await _handleKarmaProfile(request, segments[4]);
      return;
    }

    // GET /api/karma/debug/history/{callsign} — no auth needed
    if (method == 'GET' && segments.length >= 5 && segments[3] == 'history') {
      await _handleKarmaHistory(request, segments[4]);
      return;
    }

    // POST /api/karma/debug/recompute — force leaderboard recomputation
    if (method == 'POST' && segments.length >= 4 && segments[3] == 'recompute') {
      await karmaLeaderboard.recomputeAll();
      _karmaJson(request, 200, {'success': true, 'message': 'Leaderboards recomputed'});
      return;
    }

    _karmaJson(request, 404, {'error': 'Unknown debug endpoint'});
  }

  // ============ Auth ============

  /// Verify NOSTR auth header and return the callsign, or null if invalid.
  String? _verifyKarmaAuth(HttpRequest request) {
    final authHeader = request.headers.value('authorization');
    if (authHeader == null || !authHeader.startsWith('Nostr ')) {
      return null;
    }

    try {
      final base64Event = authHeader.substring(6);
      final eventJson = utf8.decode(base64Decode(base64Event));
      final eventData = jsonDecode(eventJson) as Map<String, dynamic>;
      final event = NostrEvent.fromJson(eventData);

      if (!event.verify()) return null;

      // Check freshness (5 minute window)
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if ((now - event.createdAt).abs() > 300) return null;

      // Map npub to callsign via NIP-05 registry
      final npub = NostrCrypto.encodeNpub(event.pubkey);
      final reg = Nip05RegistryService().getRegistrationByNpub(npub);
      return reg?.callsign;
    } catch (e) {
      log('WARN', 'Karma auth failed: $e');
      return null;
    }
  }

  // ============ Helpers ============

  void _karmaJson(HttpRequest request, int status, Map<String, dynamic> body) {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    request.response.close();
  }

  Future<int> _getStreakDays(String callsign) async {
    final streak = await karmaStore.readStreak(callsign);
    return streak.currentStreak;
  }

  Future<int> _computeTotalPoints(String callsign) async {
    // Re-read all events for accuracy
    final events = await karmaStore.readEvents(callsign, limit: 1000000);
    int total = 0;
    for (final event in events) {
      total += event.pointsFinal;
    }
    return total;
  }

  void _ensureTodayCounts() {
    final now = DateTime.now().toUtc();
    final today = DateTime.utc(now.year, now.month, now.day);
    if (_karmaTodayDate == null || _karmaTodayDate != today) {
      _karmaTodayCounts.clear();
      _karmaTodayDate = today;
    }
  }

  /// Push karma_update to the connected WebSocket client.
  void _pushKarmaUpdate(String callsign, KarmaEvent event, KarmaProfile profile) {
    final payload = jsonEncode({
      'type': 'karma_update',
      'points': event.pointsFinal,
      'action': event.action,
      'total': profile.totalPoints,
      'streak': profile.currentStreakDays,
      'level': profile.level,
      'level_name': profile.levelName,
    });
    karmaBroadcastToCallsign(callsign, payload);
  }

  /// Get previous chat message for dedup check.
  String? karmaPreviousChatMessage(String callsign) {
    return _karmaPreviousChatMessage[callsign.toUpperCase()];
  }

  /// Set previous chat message.
  void karmaSetPreviousChatMessage(String callsign, String content) {
    _karmaPreviousChatMessage[callsign.toUpperCase()] = content;
  }
}
