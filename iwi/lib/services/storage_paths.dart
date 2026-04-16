/*
 * Central resolution of geogram storage roots. Every ProfileStorage instance
 * in iwi/lib/ should be obtained through this file so there is exactly one
 * place that knows the on-disk layout.
 *
 * Layout under the user home:
 *
 *   ~/.local/share/geogram/
 *     profiles.json             ← ProfileService state (list + active id)
 *     profiles/<callsign>/
 *       apps/<wapp-id>/         ← extracted .wapp packages (installed wapps)
 *       wapps/<wapp-id>/        ← per-wapp runtime data (kv.json, future hal_file_*)
 *
 * Every path below that resolves to user-owned wapp data goes through the
 * active ProfileService profile, so switching profiles silently switches
 * which `apps/` and `wapps/` folders the launcher sees.
 *
 * The previous "iwi" codename left data under ~/.local/share/iwi/. We do not
 * auto-migrate it; if old data is present the user can copy it manually.
 */

import '../platform/platform.dart' as platform;
import 'preferences_service.dart';
import 'profile_service.dart';
import 'profile_storage.dart';
import 'profile_storage_factory.dart';

String _geogramBaseDir() {
  final home = platform.homeDir() ?? '/tmp';
  return '$home/.local/share/geogram';
}

/// Root storage — everything the geogram launcher persists lives under this.
/// Non-profile data (profiles.json itself, future cross-profile caches)
/// is written directly here; everything else flows through
/// [activeProfileRoot] below. On web the factory returns an in-memory
/// store, so the path string is purely cosmetic there.
ProfileStorage geogramRootStorage() =>
    makeFilesystemStorage(_geogramBaseDir());

/// Root storage for the currently-active profile. Returns a scoped
/// `profiles/<callsign>/` storage when a profile is active, or
/// falls back to a scoped `profiles/_no_profile/` bucket when nothing
/// has been chosen yet (which should only happen during the welcome
/// page lifecycle — any real I/O should go through
/// [ProfileService.instance.activeProfile] first and gate on null).
ProfileStorage activeProfileRoot() {
  final scoped = ProfileService.instance.activeProfileStorage();
  if (scoped != null) return scoped;
  return ScopedProfileStorage(geogramRootStorage(), 'profiles/_no_profile');
}

/// Installed-apps directory for the active profile. Each subdirectory
/// is an extracted .wapp.
ProfileStorage installedAppsStorage() =>
    ScopedProfileStorage(activeProfileRoot(), 'apps');

/// Absolute path to the installed-apps root — used only by code that must
/// hand an absolute path to an external tool (e.g. `unzip -d`).
String installedAppsDirPath() => installedAppsStorage().basePath;

/// Per-wapp runtime data root — honours the user-selectable override from
/// [PreferencesService.wappDataDir] if set, otherwise falls back to the
/// default `wapps/` subfolder inside the active profile.
ProfileStorage wappsDataStorage(PreferencesService prefs) {
  final override = prefs.wappDataDir;
  if (override != null && override.isNotEmpty) {
    return makeFilesystemStorage(override);
  }
  return ScopedProfileStorage(activeProfileRoot(), 'wapps');
}

/// Storage scoped to a single wapp's runtime data dir.
ProfileStorage wappDataStorageFor(PreferencesService prefs, String wappId) =>
    ScopedProfileStorage(wappsDataStorage(prefs), wappId);

/// Storage rooted at an arbitrary wapp package directory — either a built-in
/// source dir under `wapps/archive/<name>/` or an installed-apps entry.
ProfileStorage wappPackageStorage(String wappDir) =>
    makeFilesystemStorage(wappDir);
