/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Generic per-callsign follow store. The user "follows" a remote
 * callsign and the relevant browsers (blog today, future feeds)
 * auto-cache content from those authors so the local copy survives
 * the author going offline.
 *
 * Persistence: [ConfigService] under `followedCallsigns` (List of
 * uppercase callsigns). Lookups + mutations go through this static
 * helper so every consumer sees the same set without an event bus.
 */

import 'config_service.dart';

class FollowService {
  FollowService._();

  static const String _key = 'followedCallsigns';

  /// Snapshot of all currently-followed callsigns (uppercased).
  static Set<String> all() {
    final raw = ConfigService().get(_key, <dynamic>[]) as List<dynamic>;
    return raw
        .map((e) => e.toString().toUpperCase())
        .where((s) => s.isNotEmpty)
        .toSet();
  }

  static bool isFollowing(String callsign) =>
      all().contains(callsign.toUpperCase());

  /// Flip the follow state for [callsign]. Returns the new state
  /// (true = now followed, false = now unfollowed). Empty input is
  /// a no-op returning false.
  static bool toggle(String callsign) {
    final cs = callsign.trim().toUpperCase();
    if (cs.isEmpty) return false;
    final current = all();
    final nowFollowed = !current.contains(cs);
    if (nowFollowed) {
      current.add(cs);
    } else {
      current.remove(cs);
    }
    ConfigService().set(_key, current.toList());
    return nowFollowed;
  }
}
