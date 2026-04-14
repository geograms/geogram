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

  /// Write (or overwrite) a wapp under `installedAppsStorage()`.
  ///
  /// Field semantics:
  /// - [title] — human-readable display name. Stored as
  ///   `manifest.description` (matching the existing wapp convention
  ///   where `description` is the short/title and `summary` is the
  ///   longer body).
  /// - [folderName] — slug used as the on-disk directory and the
  ///   per-user data directory key. Sanitised to `[A-Za-z0-9_-]`.
  /// - [id] — reverse-domain identifier stored as `manifest.id`.
  /// - [description] — longer prose, stored as `manifest.summary`.
  /// - [wasmBytes] — the compiled wasm, OR null to reuse whatever
  ///   `app.wasm` is already at `apps/<folderName>/`. This is the
  ///   edit-in-place path: let the user change metadata or the UI
  ///   without recompiling.
  /// - [homeScreenJson] — raw `home.ui.json` to write. Null/empty
  ///   triggers a default label screen.
  /// - [overwrite] — collisions fail unless explicitly allowed.
  Future<InstallResult> installFromCompiled({
    required String id,
    required String title,
    required String folderName,
    required String description,
    Uint8List? wasmBytes,
    String version = '1.0.0',
    String? homeScreenJson,
    bool overwrite = false,
  }) async {
    if (id.isEmpty) {
      return InstallResult.failure(id, 'wapp id is required');
    }

    final folder = _sanitiseFolder(folderName, fallbackId: id);
    final installed = installedAppsStorage();
    final exists = await installed.directoryExists(folder);

    // Resolve the wasm bytes. When the caller passes null (the
    // edit-in-place path) we read the bytes already sitting at
    // apps/<folder>/app.wasm. If neither a fresh compile nor an
    // existing install exists, we have to fail — nothing to write.
    Uint8List? effectiveWasm = wasmBytes;
    if (effectiveWasm == null) {
      effectiveWasm =
          await installed.readBytes('$folder/app.wasm');
      if (effectiveWasm == null || effectiveWasm.isEmpty) {
        return InstallResult.failure(
          id,
          'no compiled wasm and no existing install at apps/$folder — '
              'compile first or fill Name with an installed wapp',
        );
      }
    }
    if (effectiveWasm.isEmpty) {
      return InstallResult.failure(id, 'wasm bytes are empty');
    }

    if (exists && !overwrite) {
      return InstallResult.failure(
        id,
        'a wapp already exists at apps/$folder — pass overwrite:true '
            'to replace (App Creator passes overwrite implicitly)',
      );
    }
    if (exists && overwrite) {
      await installed.deleteDirectory(folder, recursive: true);
    }

    // Manifest — matches the hand-written shapes in
    // wapps/archive/*/manifest.json. `description` carries the short
    // title (what the launcher grid shows); `summary` carries the
    // longer prose.
    final manifest = <String, dynamic>{
      'id': id,
      'version': version,
      'kind': 'app',
      'description': title.isNotEmpty ? title : folder,
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
      await installed.writeBytes('$folder/app.wasm', effectiveWasm);
      await installed.writeJson('$folder/manifest.json', manifest);
      final homeJson = (homeScreenJson ?? '').trim().isEmpty
          ? _defaultHomeScreen(title, description)
          : homeScreenJson!;
      await installed.writeString(
        '$folder/screens/home.ui.json',
        homeJson,
      );
    } catch (e) {
      return InstallResult.failure(id, 'failed to write wapp files: $e');
    }

    // Nudge the launcher to rescan. WappLoadedEvent is the signal
    // LauncherPage already subscribes to for other rescan triggers.
    EventBus().fire(WappLoadedEvent(wappId: id, wappName: title));

    return InstallResult.success(id);
  }

  /// Sanitise a user-provided folder slug. Keeps alphanumerics,
  /// dashes, and underscores; everything else becomes a dash. Falls
  /// back to the id's last dot-segment, then to "wapp".
  String _sanitiseFolder(String name, {required String fallbackId}) {
    String slug = name.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '-');
    while (slug.startsWith('-')) {
      slug = slug.substring(1);
    }
    while (slug.endsWith('-')) {
      slug = slug.substring(0, slug.length - 1);
    }
    if (slug.isNotEmpty) return slug;
    final parts = fallbackId.split('.');
    final leaf = parts.isNotEmpty ? parts.last : fallbackId;
    final clean = leaf.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '-');
    return clean.isEmpty ? 'wapp' : clean;
  }

  String _defaultHomeScreen(String title, String description) {
    final screen = [
      {
        '\$': 'screen',
        'name': title.isNotEmpty ? title : 'Home',
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
