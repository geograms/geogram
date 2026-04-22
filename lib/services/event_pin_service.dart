/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Local-only pin store for events. Persistence lives in
 * [ConfigService] under `pinnedEvents` (List<String> of keys) so
 * the same key shape works for events the user authored AND for
 * events fetched from another device — pinning has nothing to do
 * with where the event lives, only with what the user wants to
 * keep on top.
 *
 * Key format: `${author}|${eventId}` where `author` is the event
 * author's npub when present, otherwise the author callsign.
 * Same key for the same event encountered through multiple
 * sources (mirror, station relay, etc.) so flipping the pin in
 * one place reflects everywhere.
 */

import '../models/event.dart';
import 'config_service.dart';

class EventPinService {
  EventPinService._();

  static const String _key = 'pinnedEvents';

  /// Stable key for [event] across local + remote views.
  static String keyFor(Event event) {
    final author = (event.npub != null && event.npub!.isNotEmpty)
        ? event.npub!
        : event.author;
    return '$author|${event.id}';
  }

  /// Snapshot of every pinned key. Cheap (small set, in-memory
  /// config). Caller doesn\'t need to subscribe — events_browser_page
  /// rebuilds the list after each toggle and re-reads.
  static Set<String> all() {
    final raw = ConfigService().get(_key, <dynamic>[]) as List<dynamic>;
    return raw.map((e) => e.toString()).toSet();
  }

  static bool isPinned(Event event) => all().contains(keyFor(event));

  /// Flip the pin state for [event]. Returns the new state (true =
  /// now pinned, false = now unpinned).
  static bool toggle(Event event) {
    final key = keyFor(event);
    final current = all();
    final nowPinned = !current.contains(key);
    if (nowPinned) {
      current.add(key);
    } else {
      current.remove(key);
    }
    ConfigService().set(_key, current.toList());
    return nowPinned;
  }
}
