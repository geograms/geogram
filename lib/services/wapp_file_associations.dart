/*
 * WappFileAssociations — registry that answers
 * "which wapps can open this file?".
 *
 * Wapps declare file-type handlers in their manifest.json under
 * `provides.file_handlers` (see WappFileHandler in
 * models/wapp_manifest.dart). This service scans the shared archive
 * at <baseDir>/wapps/<wappId>/manifest.json, builds an in-memory
 * extension→handler index, and exposes lookup + user-default
 * persistence for "Open with…" pickers.
 *
 * Reads are cached; call [invalidate] after installing/uninstalling
 * a wapp so the next lookup picks up the change. The launcher
 * already fires WappLoadedEvent / WappUnloadedEvent on those edges,
 * so a future stage can wire those events to invalidate
 * automatically.
 */

import 'package:path/path.dart' as p;

import '../models/wapp_manifest.dart';
import '../util/event_bus.dart';
import 'app_service.dart';
import 'log_service.dart';
import 'wapp_storage.dart';

/// One row in the lookup result: a wapp + the specific handler
/// declaration that matched the query.
class WappAssociation {
  /// Folder slug under <baseDir>/wapps/<wappId>/. Same value used by
  /// WappPage to instantiate the engine.
  final String wappId;
  final WappManifest manifest;
  final WappFileHandler handler;

  WappAssociation({
    required this.wappId,
    required this.manifest,
    required this.handler,
  });

  /// Verb shown in the "Open with…" picker. Falls back to the
  /// wapp's title when the handler didn't supply its own label.
  String get label =>
      handler.title.isNotEmpty ? handler.title : manifest.title;
}

class WappFileAssociations {
  WappFileAssociations._() {
    // Catalog edges that affect lookup results: a new install adds
    // handlers, an uninstall removes them. Subscribing here means
    // callers get fresh results without having to remember to call
    // [invalidate] themselves.
    EventBus().on<WappLoadedEvent>((_) => invalidate());
    EventBus().on<WappUnloadedEvent>((_) => invalidate());
  }
  static final WappFileAssociations instance = WappFileAssociations._();

  /// Cache of (wappId → manifest). Invalidated when the catalog
  /// changes (install / uninstall / profile switch).
  Map<String, WappManifest>? _manifestCache;

  /// User-chosen defaults for ambiguous extensions, keyed by the
  /// lowercase extension (no dot). Persisted in the active profile's
  /// KV at <profile>/wapp_associations.kv via ProfileStorage.
  Map<String, String>? _defaultsCache;

  // ── Lookup ─────────────────────────────────────────────────────────

  /// All handler entries that match either [extension] or [mime]
  /// (or both). Optionally filter by [mode] ("view" / "edit"; null =
  /// any). Result is ordered: exact-extension matches first, then
  /// MIME-only matches, then catch-all (`*`) entries.
  Future<List<WappAssociation>> lookup({
    String? extension,
    String? mime,
    String? mode,
  }) async {
    final manifests = await _loadManifests();
    final ext = extension?.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
    final m = mime?.toLowerCase();

    final exact = <WappAssociation>[];
    final mimeMatches = <WappAssociation>[];
    final catchAll = <WappAssociation>[];

    for (final entry in manifests.entries) {
      for (final h in entry.value.fileHandlers) {
        if (mode != null && !h.supportsMode(mode)) continue;
        final hasExtMatch =
            ext != null && ext.isNotEmpty && h.matchesExtension(ext);
        final hasMimeMatch =
            m != null && m.isNotEmpty && h.matchesMime(m);
        final isCatchAll = h.extensions.contains('*') ||
            h.mimeTypes.contains('*') ||
            h.mimeTypes.contains('*/*');

        if (!hasExtMatch && !hasMimeMatch) continue;

        final assoc = WappAssociation(
          wappId: entry.key,
          manifest: entry.value,
          handler: h,
        );

        if (hasExtMatch && !isCatchAll) {
          exact.add(assoc);
        } else if (hasMimeMatch && !isCatchAll) {
          mimeMatches.add(assoc);
        } else {
          catchAll.add(assoc);
        }
      }
    }

    return [...exact, ...mimeMatches, ...catchAll];
  }

  /// Convenience for filenames: derives the extension from [path]
  /// (everything after the last dot). Skips MIME-only handlers
  /// unless [mime] is supplied.
  Future<List<WappAssociation>> lookupForFile(
    String path, {
    String? mime,
    String? mode,
  }) async {
    final ext = p.extension(path);
    return lookup(extension: ext, mime: mime, mode: mode);
  }

  // ── User defaults ──────────────────────────────────────────────────

  /// The wapp the user previously picked for this extension, if any.
  Future<WappAssociation?> defaultFor(
    String extension, {
    String? mode,
  }) async {
    final defaults = await _loadDefaults();
    final ext =
        extension.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
    final wappId = defaults[ext];
    if (wappId == null) return null;

    final manifest = (await _loadManifests())[wappId];
    if (manifest == null) {
      // Stale default — wapp was removed. Drop it so the next picker
      // shows the unbiased list.
      defaults.remove(ext);
      await _saveDefaults();
      return null;
    }
    for (final h in manifest.fileHandlers) {
      if (h.matchesExtension(ext) && (mode == null || h.supportsMode(mode))) {
        return WappAssociation(
          wappId: wappId,
          manifest: manifest,
          handler: h,
        );
      }
    }
    return null;
  }

  /// Persist a user choice. Pass empty [wappId] to clear the
  /// default (next opening of this extension will fall back to the
  /// picker again).
  Future<void> setDefaultFor(String extension, String wappId) async {
    final defaults = await _loadDefaults();
    final ext =
        extension.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
    if (wappId.isEmpty) {
      defaults.remove(ext);
    } else {
      defaults[ext] = wappId;
    }
    await _saveDefaults();
  }

  // ── Cache control ──────────────────────────────────────────────────

  /// Drop both caches. Call after installing or uninstalling a wapp,
  /// or after switching the active profile.
  void invalidate() {
    _manifestCache = null;
    _defaultsCache = null;
  }

  // ── Internals ──────────────────────────────────────────────────────

  Future<Map<String, WappManifest>> _loadManifests() async {
    final cached = _manifestCache;
    if (cached != null) return cached;
    final result = <String, WappManifest>{};
    final archive = wappArchiveStorage();
    if (archive == null) {
      _manifestCache = result;
      return result;
    }
    if (!await archive.directoryExists('')) {
      _manifestCache = result;
      return result;
    }
    final entries = await archive.listDirectory('');
    for (final e in entries) {
      if (!e.isDirectory) continue;
      final manifestPath = '${e.name}/manifest.json';
      if (!await archive.exists(manifestPath)) continue;
      try {
        final json = await archive.readJson(manifestPath);
        if (json == null) continue;
        final manifest = WappManifest.fromJson(
          json,
          archive.getAbsolutePath(e.name),
        );
        result[e.name] = manifest;
      } catch (err) {
        LogService().log(
            'WappFileAssociations: failed to read $manifestPath: $err');
      }
    }
    _manifestCache = result;
    return result;
  }

  Future<Map<String, String>> _loadDefaults() async {
    final cached = _defaultsCache;
    if (cached != null) return cached;
    final result = <String, String>{};
    final storage = AppService().profileStorage;
    if (storage == null) {
      _defaultsCache = result;
      return result;
    }
    try {
      final json = await storage.readJson(_defaultsPath);
      if (json != null) {
        json.forEach((k, v) {
          if (v is String) result[k.toLowerCase()] = v;
        });
      }
    } catch (e) {
      LogService()
          .log('WappFileAssociations: defaults read failed: $e');
    }
    _defaultsCache = result;
    return result;
  }

  Future<void> _saveDefaults() async {
    final defaults = _defaultsCache;
    if (defaults == null) return;
    final storage = AppService().profileStorage;
    if (storage == null) return;
    try {
      await storage.writeJson(_defaultsPath, defaults);
    } catch (e) {
      LogService()
          .log('WappFileAssociations: defaults write failed: $e');
    }
  }

  static const String _defaultsPath = 'wapp_associations.json';
}
