/*
 * WappInstallerService — install/reinstall wapps from any source.
 *
 * Model
 * -----
 *   SOURCE  : where the wapp came from. URL, local folder, picked
 *             file, or Flutter asset baked into the binary.
 *   ARCHIVE : <baseDir>/wapps/<wappId>/. The local copy. Always
 *             read at runtime — never read from the source.
 *   PROFILE : <baseDir>/devices/<callsign>/<wappId>/. Per-profile
 *             data folder. Created next to the wapp's archive entry
 *             so the launcher grid surfaces it for the active
 *             profile.
 *
 * "Install" means: copy from SOURCE → ARCHIVE, then make sure the
 * active profile's data folder exists. The runtime never reads from
 * the source — it always reads the archive.
 *
 * The source descriptor is persisted alongside manifest.json as
 * `source.json`, so a later "reinstall" can re-execute the original
 * fetch (refetch URL, recopy folder, reload asset, reread file)
 * without the user having to specify it again. That is what the
 * Reload button on a wapp's AppBar uses to refresh after the user
 * edits the source folder or installs a newer .wapp file.
 *
 * Public surface:
 *   - installFromAsset(assetPath, wappId)   ← bundled Wapp Store
 *   - installFromUrl(url, wappId)            ← Wapp Store catalog
 *   - installFromPath(sourceDir, wappId)     ← local-folder dev install
 *   - installFromBytes(zipBytes, wappId, source)  ← picker / generic
 *   - reinstall(wappId)                      ← uses recorded source
 *   - getSource(wappId) / isInstalled(wappId)
 */

import 'dart:io' show File, Directory;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

import 'app_service.dart';
import 'log_service.dart';
import 'profile_storage.dart';
import 'wapp_storage.dart';

/// Where a wapp was installed from. Persisted as
/// `<archive>/<wappId>/source.json` so [WappInstallerService.reinstall]
/// can re-execute the original install path without asking again.
class WappSource {
  static const typeAsset = 'asset';
  static const typeUrl = 'url';
  static const typePath = 'path';
  static const typeFile = 'file';

  /// One of [typeAsset], [typeUrl], [typePath], [typeFile].
  final String type;

  /// Asset path, http(s) URL, local directory path, or local file path.
  final String value;

  const WappSource._(this.type, this.value);

  const WappSource.asset(String assetPath) : this._(typeAsset, assetPath);
  const WappSource.url(String url) : this._(typeUrl, url);
  const WappSource.path(String dirPath) : this._(typePath, dirPath);
  const WappSource.file(String filePath) : this._(typeFile, filePath);

  Map<String, dynamic> toJson() =>
      {'version': 1, 'type': type, 'value': value};

  static WappSource? fromJson(Map<String, dynamic> json) {
    final t = json['type'];
    final v = json['value'];
    if (t is! String || v is! String) return null;
    return WappSource._(t, v);
  }

  @override
  String toString() => '$type:$value';
}

class WappInstallerService {
  WappInstallerService._();
  static final WappInstallerService instance = WappInstallerService._();

  /// True iff the local archive has a manifest for [wappId]. Reads
  /// the archive directly — never falls back to the source.
  Future<bool> isInstalled(String wappId) async {
    final archive = wappArchiveStorage();
    if (archive == null) return false;
    return archive.exists('$wappId/manifest.json');
  }

  /// Read the recorded install source for [wappId], or null when no
  /// source is on disk (legacy install, or the wapp has been wiped).
  Future<WappSource?> getSource(String wappId) async {
    final archive = wappArchiveStorage();
    if (archive == null) return null;
    if (!await archive.exists('$wappId/source.json')) return null;
    final json = await archive.readJson('$wappId/source.json');
    if (json == null) return null;
    return WappSource.fromJson(json);
  }

  // ── Asset (bundled with Geogram) ────────────────────────────────

  /// Install a wapp shipped as a Flutter asset. Idempotent: if the
  /// archive already has a manifest for [wappId] this just makes sure
  /// the per-profile data folder exists.
  Future<bool> installFromAsset({
    required String assetPath,
    required String wappId,
  }) async {
    if (await isInstalled(wappId)) {
      return _ensureProfileFolder(wappId);
    }
    return _doInstallFromAsset(assetPath: assetPath, wappId: wappId);
  }

  Future<bool> _doInstallFromAsset({
    required String assetPath,
    required String wappId,
  }) async {
    try {
      final byteData = await rootBundle.load(assetPath);
      final bytes = byteData.buffer.asUint8List();
      return _replaceArchive(
        wappId: wappId,
        zipBytes: bytes,
        source: WappSource.asset(assetPath),
      );
    } catch (e) {
      LogService().log(
          'WappInstaller: asset load failed for $assetPath: $e');
      return false;
    }
  }

  // ── URL ────────────────────────────────────────────────────────

  /// Download a `.wapp` ZIP from an HTTP(S) URL, extract it into the
  /// archive, and activate it for the active profile. Always
  /// overwrites the archive — that's the point of installing.
  Future<bool> installFromUrl({
    required String wappId,
    required String url,
  }) async {
    final bytes = await _fetchUrl(url);
    if (bytes == null) {
      LogService().log('WappInstaller: download failed for $url');
      return false;
    }
    return _replaceArchive(
      wappId: wappId,
      zipBytes: bytes,
      source: WappSource.url(url),
    );
  }

  // ── Local folder (dev iteration) ────────────────────────────────

  /// Copy every file under [sourceDir] (recursively) into
  /// `<archive>/<wappId>/`, replacing whatever was there before.
  /// Used for the dev workflow: register a sibling source folder as
  /// a wapp's install source, then iterate via the Reload button.
  Future<bool> installFromPath({
    required String wappId,
    required String sourceDir,
  }) async {
    final src = Directory(sourceDir);
    if (!src.existsSync()) {
      LogService().log('WappInstaller: source path missing: $sourceDir');
      return false;
    }
    if (!File('$sourceDir/manifest.json').existsSync()) {
      LogService().log(
          'WappInstaller: $sourceDir has no manifest.json');
      return false;
    }

    final archive = wappArchiveStorage();
    if (archive == null) {
      LogService().log(
          'WappInstaller: shared archive unavailable; cannot install $wappId');
      return false;
    }

    // Wipe any previous install of this id so we re-copy fresh.
    if (await archive.directoryExists(wappId)) {
      try {
        await archive.deleteDirectory(wappId, recursive: true);
      } catch (_) {}
    }
    await archive.createDirectory(wappId);

    var fileCount = 0;
    try {
      for (final entity in src.listSync(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final rel = entity.path
            .substring(sourceDir.length)
            .replaceAll('\\', '/')
            .replaceFirst(RegExp(r'^/+'), '');
        if (rel.isEmpty) continue;
        // Skip the previous install's source.json — we're writing a
        // new one below.
        if (rel == 'source.json') continue;
        final dest = '$wappId/$rel';
        final lastSlash = dest.lastIndexOf('/');
        if (lastSlash > 0) {
          await archive.createDirectory(dest.substring(0, lastSlash));
        }
        await archive.writeBytes(
            dest, Uint8List.fromList(entity.readAsBytesSync()));
        fileCount++;
      }
    } catch (e) {
      LogService().log(
          'WappInstaller: copy from $sourceDir failed: $e');
      return false;
    }

    if (!await archive.exists('$wappId/manifest.json')) {
      LogService()
          .log('WappInstaller: $wappId/manifest.json missing after copy');
      return false;
    }

    await _writeSource(archive, wappId, WappSource.path(sourceDir));
    LogService().log(
        'WappInstaller: copied $fileCount file(s) from $sourceDir into archive/$wappId');
    return _ensureProfileFolder(wappId);
  }

  // ── Raw bytes (file picker, generic) ───────────────────────────

  /// Install from in-memory ZIP bytes. Caller passes the source
  /// descriptor so reinstall can find its way back. When [source] is
  /// null the install still works but Reload becomes a no-op for the
  /// "refetch from origin" path (it just rereads what's already on
  /// disk).
  Future<bool> installFromBytes({
    required String wappId,
    required Uint8List zipBytes,
    WappSource? source,
  }) async {
    return _replaceArchive(
      wappId: wappId,
      zipBytes: zipBytes,
      source: source,
    );
  }

  // ── Reinstall ──────────────────────────────────────────────────

  /// Re-execute the install based on the recorded source. Used by
  /// the Reload button: refetch URL, re-copy folder, reload asset,
  /// reread the original .wapp file, then overwrite the archive.
  /// Returns false when no source is recorded or the source is no
  /// longer reachable.
  Future<bool> reinstall(String wappId) async {
    final source = await getSource(wappId);
    if (source == null) {
      LogService()
          .log('WappInstaller: no source on file for $wappId; cannot reload');
      return false;
    }
    switch (source.type) {
      case WappSource.typeAsset:
        return _doInstallFromAsset(
            assetPath: source.value, wappId: wappId);
      case WappSource.typeUrl:
        return installFromUrl(wappId: wappId, url: source.value);
      case WappSource.typePath:
        return installFromPath(
            wappId: wappId, sourceDir: source.value);
      case WappSource.typeFile:
        final f = File(source.value);
        if (!f.existsSync()) {
          LogService().log(
              'WappInstaller: source file gone: ${source.value}');
          return false;
        }
        final bytes = Uint8List.fromList(f.readAsBytesSync());
        return _replaceArchive(
          wappId: wappId,
          zipBytes: bytes,
          source: source,
        );
      default:
        LogService()
            .log('WappInstaller: unknown source type ${source.type} for $wappId');
        return false;
    }
  }

  // ── Internals ─────────────────────────────────────────────────

  /// Wipe `<archive>/<wappId>/`, extract [zipBytes] into it, write
  /// source.json, and create the per-profile data folder. The atomic
  /// "install or replace" step every public install method funnels
  /// through.
  Future<bool> _replaceArchive({
    required String wappId,
    required Uint8List zipBytes,
    required WappSource? source,
  }) async {
    final archive = wappArchiveStorage();
    if (archive == null) {
      LogService().log(
          'WappInstaller: shared archive unavailable; cannot install $wappId');
      return false;
    }
    if (await archive.directoryExists(wappId)) {
      try {
        await archive.deleteDirectory(wappId, recursive: true);
      } catch (_) {}
    }
    final ok = await _extractZipIntoArchive(wappId, zipBytes);
    if (!ok) return false;
    if (!await archive.exists('$wappId/manifest.json')) {
      LogService()
          .log('WappInstaller: $wappId/manifest.json missing after extract');
      return false;
    }
    if (source != null) {
      await _writeSource(archive, wappId, source);
    }
    return _ensureProfileFolder(wappId);
  }

  Future<bool> _extractZipIntoArchive(
      String wappId, Uint8List zipBytes) async {
    final archive = wappArchiveStorage();
    if (archive == null) return false;
    try {
      final zip = ZipDecoder().decodeBytes(zipBytes);
      await archive.createDirectory(wappId);
      var fileCount = 0;
      for (final file in zip) {
        if (!file.isFile) continue;
        final relPath = file.name
            .replaceAll('\\', '/')
            .replaceAll(RegExp(r'^/+'), '');
        if (relPath.isEmpty) continue;
        // Don't trust source.json embedded inside the package — the
        // host owns that file and writes it after extraction.
        if (relPath == 'source.json') continue;
        final dest = '$wappId/$relPath';
        final lastSlash = dest.lastIndexOf('/');
        if (lastSlash > 0) {
          await archive.createDirectory(dest.substring(0, lastSlash));
        }
        final content = file.content as List<int>;
        await archive.writeBytes(dest, Uint8List.fromList(content));
        fileCount++;
      }
      LogService().log(
          'WappInstaller: extracted $wappId ($fileCount files) into shared archive');
      return fileCount > 0;
    } catch (e) {
      LogService().log('WappInstaller: ZIP extract failed for $wappId: $e');
      return false;
    }
  }

  Future<void> _writeSource(
      ProfileStorage archive, String wappId, WappSource source) async {
    try {
      await archive.writeJson('$wappId/source.json', source.toJson());
    } catch (e) {
      LogService().log(
          'WappInstaller: source.json write failed for $wappId: $e');
    }
  }

  Future<bool> _ensureProfileFolder(String wappId) async {
    final base = AppService().profileStorage;
    if (base == null) {
      LogService()
          .log('WappInstaller: no active profile, cannot activate $wappId');
      return false;
    }
    if (await base.directoryExists(wappId)) return true;
    await base.createDirectory(wappId);
    LogService().log(
        'WappInstaller: activated $wappId for the active profile');
    return true;
  }

  Future<Uint8List?> _fetchUrl(String url) async {
    try {
      final resp = await http.get(Uri.parse(url));
      if (resp.statusCode != 200) {
        LogService().log(
            'WappInstaller: HTTP ${resp.statusCode} fetching $url');
        return null;
      }
      return resp.bodyBytes;
    } catch (e) {
      LogService().log('WappInstaller: fetch error for $url: $e');
      return null;
    }
  }
}
