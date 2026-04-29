/*
 * Wapp storage layout
 *
 *   <baseDir>/wapps/<wappId>/        — shared wapp archive (read-only
 *     manifest.json                    package; same files for every
 *     app.wasm                         profile). Built-in wapps that
 *     screens/                         ship with geogram are extracted
 *     media/                           here on first run.
 *     lang/
 *
 *   <baseDir>/devices/<callsign>/<wappId>/   — per-profile wapp data
 *     kv.json                                  (runtime state, cache,
 *     ...                                      user files). Lives at
 *                                              the root of the profile,
 *                                              side-by-side with chat,
 *                                              blog, etc.
 *
 * The shared archive uses a plain filesystem path because it is
 * shared across profiles and cannot live inside any one profile's
 * encrypted SQLite. The per-profile data goes through the parent's
 * dual-backend ProfileStorage so encrypted profiles work
 * transparently.
 */

import 'dart:io' show Directory, File;

import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;

import 'app_service.dart';
import 'profile_storage.dart';
import 'storage_config.dart';

/// Absolute filesystem path to the shared wapps archive directory
/// (`<baseDir>/wapps/`). Returns null when StorageConfig isn't
/// initialised yet.
String? wappArchiveBasePath() {
  try {
    return '${StorageConfig().baseDir}/wapps';
  } catch (_) {
    return null;
  }
}

/// ProfileStorage rooted at `<baseDir>/wapps/`. Plain filesystem
/// (the archive is shared across profiles and cannot be encrypted).
ProfileStorage? wappArchiveStorage() {
  final base = wappArchiveBasePath();
  if (base == null) return null;
  return FilesystemProfileStorage(base);
}

/// When running a debug build from a source checkout, returns the
/// absolute path of the sibling `wapps/<wappId>/` folder if it
/// contains a manifest.json AND a built app.wasm. Else null.
///
/// Layout assumed:
///   geograms/
///   ├── geogram/   ← cwd while running launch-desktop.sh
///   └── wapps/     ← https://github.com/.../wapps
///       └── <wappId>/{manifest.json, app.wasm, screens/, ...}
///
/// Production builds and web targets short-circuit to null so this
/// dev-only filesystem probe never runs in shipped binaries.
String? wappSourceTreePath(String wappId) {
  if (!kDebugMode || kIsWeb) return null;
  final cwd = Directory.current.path;
  final candidates = [
    '$cwd/../wapps/$wappId',     // sibling repo (canonical)
    '$cwd/../../wapps/$wappId',  // nested workspace fallback
    '$cwd/wapps/$wappId',        // legacy in-tree
  ];
  for (final root in candidates) {
    if (File('$root/manifest.json').existsSync() &&
        File('$root/app.wasm').existsSync()) {
      return root;
    }
  }
  return null;
}

/// Read-only storage scoped to one wapp's package directory.
///
/// In debug builds, prefer the sibling source-tree folder (see
/// [wappSourceTreePath]) so edits to a wapp's source are picked
/// up on the next launch / reload without having to bump the
/// version, repackage, and reinstall through the wapp store.
///
/// In release builds — and when no source folder is available —
/// fall back to the shared archive at `<baseDir>/wapps/<wappId>/`.
/// Contents in either case: manifest.json, app.wasm, screens/,
/// media/, lang/, signature.json.
ProfileStorage? wappPackageStorage(String wappId) {
  final src = wappSourceTreePath(wappId);
  if (src != null) return FilesystemProfileStorage(src);

  final archive = wappArchiveStorage();
  if (archive == null) return null;
  return ScopedProfileStorage(archive, wappId);
}

/// Per-profile read-write data folder for a wapp
/// (`<baseDir>/devices/<callsign>/<wappId>/`). Lives at the root of
/// the active profile so it sits next to built-in app folders
/// (chat, blog, places, ...). Holds kv.json and any other state
/// the wapp accumulates at runtime.
///
/// Routed through the active profile's ProfileStorage, so encrypted
/// profiles transparently get encrypted wapp data too.
ProfileStorage? wappDataStorageFor(String wappId) {
  final base = AppService().profileStorage;
  if (base == null) return null;
  return ScopedProfileStorage(base, wappId);
}
