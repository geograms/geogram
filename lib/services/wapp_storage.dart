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

/// Read-only storage scoped to one wapp's package directory in the
/// shared archive at `<baseDir>/wapps/<wappId>/`. Contents:
/// manifest.json, app.wasm, screens/, media/, lang/, signature.json,
/// source.json.
///
/// The runtime always reads from the local archive — never from the
/// origin source. To pick up changes from a source folder/URL, run
/// [WappInstallerService.reinstall], which re-executes the install
/// from the recorded source and replaces the archive.
ProfileStorage? wappPackageStorage(String wappId) {
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
