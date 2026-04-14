/*
 * WappInstallerService — writes a freshly compiled wapp into the
 * installed-apps folder and nudges the launcher to rescan.
 *
 * The service is intentionally narrow: it knows nothing about the
 * compiler, only about the shape of an installed wapp directory
 * (`manifest.json`, `app.wasm`, `screens/home.ui.json`). The caller
 * (App Creator's `install` command handler in `wapp_page.dart`)
 * hands over the compiled bytes + the metadata it collected from
 * its own fields.
 *
 * On success, fires `WappLoadedEvent` on the host `EventBus` so
 * `LauncherPage._scanArchiveBody` picks up the new wapp on its next
 * rebuild — no geogram restart required.
 */

import 'dart:convert';
import 'dart:typed_data';

import 'event_bus.dart';
import 'storage_paths.dart';

class InstallResult {
  final bool ok;
  final String wappId;
  final String? error;

  const InstallResult({
    required this.ok,
    required this.wappId,
    this.error,
  });

  factory InstallResult.success(String wappId) =>
      InstallResult(ok: true, wappId: wappId);

  factory InstallResult.failure(String wappId, String message) =>
      InstallResult(ok: false, wappId: wappId, error: message);
}

class WappInstallerService {
  WappInstallerService._();
  static final WappInstallerService instance = WappInstallerService._();

  /// Write a new wapp under `installedAppsStorage()` / `<id>/`.
  ///
  /// [homeScreenJson] is optional — if null the installer drops a
  /// tiny default `home.ui.json` that just shows a label so the wapp
  /// renders without errors when opened.
  ///
  /// [overwrite] must be set explicitly to true to replace an
  /// existing install with the same id. Default false returns a
  /// failure result so the user has to confirm.
  Future<InstallResult> installFromCompiled({
    required String id,
    required String name,
    required String description,
    required Uint8List wasmBytes,
    String version = '1.0.0',
    String? homeScreenJson,
    bool overwrite = false,
  }) async {
    if (id.isEmpty) {
      return InstallResult.failure(id, 'wapp id is required');
    }
    if (wasmBytes.isEmpty) {
      return InstallResult.failure(id, 'wasm bytes are empty');
    }

    // The installer always uses a slug-safe folder name derived from
    // the id. The last dot-separated segment keeps things short and
    // sorts nicely in the launcher grid.
    final folder = _folderFromId(id);

    final installed = installedAppsStorage();
    final exists = await installed.directoryExists(folder);
    if (exists && !overwrite) {
      return InstallResult.failure(
        id,
        'a wapp already exists at apps/$folder — pass overwrite:true to replace',
      );
    }
    if (exists && overwrite) {
      await installed.deleteDirectory(folder, recursive: true);
    }

    // Manifest — mirrors the hand-written manifests in
    // wapps/archive/*/manifest.json. `permissions` stays empty so
    // the user's first wapp is sandboxed by default.
    final manifest = <String, dynamic>{
      'id': id,
      'version': version,
      'kind': 'app',
      'description':
          description.isNotEmpty ? description : 'Created with App Creator',
      'summary': description,
      'icon': null,
      'tags': const ['user'],
      'entry_ui': 'screens/home.ui.json',
      'tick_interval_ms': 5000,
      'permissions': const <String>[],
      'provides': const {
        'functions': [],
        'events': [],
        'variables': [],
      },
      'requires': const {
        'hal': ['log'],
        'events': [],
        'libraries': [],
        'variables': [],
      },
    };

    try {
      await installed.writeBytes('$folder/app.wasm', wasmBytes);
      await installed.writeJson('$folder/manifest.json', manifest);
      await installed.writeString(
        '$folder/screens/home.ui.json',
        homeScreenJson ?? _defaultHomeScreen(name, description),
      );
    } catch (e) {
      return InstallResult.failure(id, 'failed to write wapp files: $e');
    }

    // Nudge the launcher to rescan. `WappLoadedEvent` is the right
    // signal — `LauncherPage` already subscribes to it for other
    // rescan triggers (e.g. when a wapp finishes module_init).
    EventBus().fire(WappLoadedEvent(wappId: id, wappName: name));

    return InstallResult.success(id);
  }

  String _folderFromId(String id) {
    final parts = id.split('.');
    final leaf = parts.isNotEmpty ? parts.last : id;
    // Sanitise — keep alphanumerics, dashes, underscores only.
    final cleaned = leaf.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '-');
    return cleaned.isEmpty ? 'wapp' : cleaned;
  }

  String _defaultHomeScreen(String name, String description) {
    final screen = [
      {
        '\$': 'screen',
        'name': name.isNotEmpty ? name : 'Home',
        'tip': description.isNotEmpty ? description : null,
        'children': [
          {
            '\$': 'label',
            'text': 'Created with App Creator.',
          },
          {
            '\$': 'label',
            'text':
                'This wapp ticks every 5 seconds and writes hal_log output. '
                    'Check the tasks wapp to see its monitored task.',
          },
        ],
      },
    ];
    return const JsonEncoder.withIndent('  ').convert(screen);
  }
}
