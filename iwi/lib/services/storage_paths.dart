/*
 * Central resolution of geogram storage roots. Every ProfileStorage instance
 * in iwi/lib/ should be obtained through this file so there is exactly one
 * place that knows the on-disk layout.
 *
 * Layout under the user home:
 *
 *   ~/.local/share/geogram/
 *     apps/`<wapp-id>`/          ← extracted .wapp packages (installed wapps)
 *     wapps/`<wapp-id>`/         ← per-wapp runtime data (kv.json, future hal_file_*)
 *
 * The previous "iwi" codename left data under ~/.local/share/iwi/. We do not
 * auto-migrate it; if old data is present the user can copy it manually.
 */

import 'dart:io';

import 'preferences_service.dart';
import 'profile_storage.dart';

String _geogramBaseDir() {
  final home = Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      '/tmp';
  return '$home/.local/share/geogram';
}

/// Root storage — everything the geogram launcher persists lives under this.
ProfileStorage geogramRootStorage() =>
    FilesystemProfileStorage(_geogramBaseDir());

/// Installed-apps directory. Each subdirectory is an extracted .wapp.
ProfileStorage installedAppsStorage() =>
    ScopedProfileStorage(geogramRootStorage(), 'apps');

/// Absolute path to the installed-apps root — used only by code that must
/// hand an absolute path to an external tool (e.g. `unzip -d`).
String installedAppsDirPath() => installedAppsStorage().basePath;

/// Per-wapp runtime data root — honours the user-selectable override from
/// [PreferencesService.wappDataDir] if set, otherwise falls back to the
/// default `wapps/` subfolder.
ProfileStorage wappsDataStorage(PreferencesService prefs) {
  final override = prefs.wappDataDir;
  if (override != null && override.isNotEmpty) {
    return FilesystemProfileStorage(override);
  }
  return ScopedProfileStorage(geogramRootStorage(), 'wapps');
}

/// Storage scoped to a single wapp's runtime data dir.
ProfileStorage wappDataStorageFor(PreferencesService prefs, String wappId) =>
    ScopedProfileStorage(wappsDataStorage(prefs), wappId);

/// Storage rooted at an arbitrary wapp package directory — either a built-in
/// source dir under wapps/archive/<name>/ or an installed-apps entry.
ProfileStorage wappPackageStorage(String wappDir) =>
    FilesystemProfileStorage(wappDir);
