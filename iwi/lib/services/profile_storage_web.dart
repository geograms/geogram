/*
 * Web ProfileStorage backend.
 *
 * Selected when `dart.library.io` is NOT available (i.e. Flutter
 * web). Persists to the browser's localStorage so user data — the
 * active profile, installed wapps, wapp KV stores, signatures,
 * settings — survives page reloads exactly as it survives process
 * restarts on desktop.
 *
 * Every call to [makeFilesystemStorage] with the same `basePath`
 * returns the SAME instance (registry pattern), so the archive
 * scan that writes into a wapp package and the later
 * `WappPage._loadWapp` that reads from it share state.
 *
 * Implementation notes:
 *
 * - `localStorage` caps at roughly 5-10 MB per origin. The registry
 *   keys each storage by basePath so per-wapp data is siloed; we
 *   only write the stores that actually got mutated (via the
 *   [MemoryProfileStorage.onMutate] hook). Binary bytes are
 *   base64-encoded because localStorage values are strings.
 *
 * - We *could* swap localStorage for IndexedDB later to avoid the
 *   quota limit and the stringification overhead, but localStorage
 *   keeps the storage layer free of async plumbing and the
 *   factories synchronous, which matches the desktop contract.
 */

import 'dart:convert';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'profile_storage.dart';

final Map<String, ProfileStorage> _registry = {};

ProfileStorage makeFilesystemStorage(String basePath) =>
    _registry.putIfAbsent(
        basePath, () => _LocalStorageProfileStorage(basePath));

/// `localStorage`-persisted variant of [MemoryProfileStorage].
///
/// Loads any existing snapshot from `geogram.storage:<basePath>` in
/// the constructor (synchronous — `localStorage` is a sync API) and
/// flushes the in-memory file map back to the same key on every
/// mutation via [onMutate]. Failures are swallowed so a blown quota
/// degrades to memory-only storage instead of crashing the app.
class _LocalStorageProfileStorage extends MemoryProfileStorage {
  _LocalStorageProfileStorage(String basePath)
      : super(basePath: basePath) {
    _hydrate(basePath);
  }

  /// Key under which this storage lives in localStorage. Prefixed
  /// with `geogram.storage:` so it doesn't collide with
  /// shared_preferences' own entries or anything else.
  String get _storageKey => 'geogram.storage:$basePath';

  void _hydrate(String basePath) {
    try {
      final raw = web.window.localStorage.getItem(_storageKey);
      if (raw == null) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final snapshot = <String, Uint8List>{};
      for (final entry in decoded.entries) {
        final key = entry.key.toString();
        final value = entry.value;
        if (value is! String) continue;
        try {
          snapshot[key] = base64Decode(value);
        } catch (_) {}
      }
      bulkLoad(snapshot);
    } catch (_) {
      // Corrupt localStorage entry — drop it and start fresh.
      try {
        web.window.localStorage.removeItem(_storageKey);
      } catch (_) {}
    }
  }

  @override
  void onMutate() {
    try {
      final snapshot = <String, String>{};
      for (final entry in files.entries) {
        snapshot[entry.key] = base64Encode(entry.value);
      }
      web.window.localStorage.setItem(_storageKey, jsonEncode(snapshot));
    } catch (_) {
      // Quota exceeded / serialization failed — user data for this
      // storage just loses persistence for the session. No crash.
    }
  }
}
