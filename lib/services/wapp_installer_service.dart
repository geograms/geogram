/*
 * WappInstallerService
 *
 * Two-step install:
 *   1. Extract the .wapp ZIP into the shared archive at
 *      <baseDir>/wapps/<wappId>/ (idempotent across all profiles).
 *   2. Create the per-profile data folder
 *      <baseDir>/devices/<callsign>/<wappId>/ so the wapp shows up
 *      on the active profile's launcher grid (idempotent per
 *      profile).
 *
 * Stage 1: install from a Flutter asset path. Stage 2 will add
 * install-from-URL and install-from-local-file flows.
 */

import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'app_service.dart';
import 'log_service.dart';
import 'profile_storage.dart';
import 'wapp_storage.dart';

class WappInstallerService {
  WappInstallerService._();
  static final WappInstallerService instance = WappInstallerService._();

  /// True when [wappId] is present in the shared archive
  /// (<baseDir>/wapps/<wappId>/manifest.json).
  Future<bool> isInArchive(String wappId) async {
    final pkg = wappPackageStorage(wappId);
    if (pkg == null) return false;
    return pkg.exists('manifest.json');
  }

  /// True when [wappId] is "installed" for the active profile —
  /// i.e. the per-profile data folder <profile>/<wappId>/ exists.
  Future<bool> isInstalledForActiveProfile(String wappId) async {
    final base = AppService().profileStorage;
    if (base == null) return false;
    return base.directoryExists(wappId);
  }

  /// Ensure a wapp shipped as a Flutter asset is present in the
  /// shared archive AND visible on the active profile's launcher
  /// grid. Idempotent.
  Future<bool> installFromAsset({
    required String assetPath,
    required String wappId,
  }) async {
    if (!await isInArchive(wappId)) {
      try {
        final byteData = await rootBundle.load(assetPath);
        final bytes = byteData.buffer.asUint8List();
        final ok = await _extractZipIntoArchive(wappId, bytes);
        if (!ok) return false;
      } catch (e) {
        LogService().log(
            'WappInstaller: asset load failed for $assetPath: $e');
        return false;
      }
    }
    return _ensureProfileFolder(wappId);
  }

  /// Activate a wapp that's already in the shared archive for the
  /// active profile (creates the per-profile data folder if
  /// missing).
  Future<bool> activateForActiveProfile(String wappId) async {
    if (!await isInArchive(wappId)) return false;
    return _ensureProfileFolder(wappId);
  }

  /// Extract a .wapp ZIP from in-memory [zipBytes] (e.g. an HTTP
  /// download) into the shared archive at <baseDir>/wapps/<wappId>/
  /// AND activate it for the active profile. Replaces any existing
  /// install of the same wappId.
  Future<bool> installFromBytes({
    required String wappId,
    required Uint8List zipBytes,
  }) async {
    final archive = wappArchiveStorage();
    if (archive == null) {
      LogService()
          .log('WappInstaller: shared archive not available; cannot install $wappId');
      return false;
    }
    // Wipe any previous shared install so we re-extract fresh.
    if (await archive.directoryExists(wappId)) {
      try {
        await archive.deleteDirectory(wappId, recursive: true);
      } catch (_) {}
    }
    final ok = await _extractZipIntoArchive(wappId, zipBytes);
    if (!ok) return false;
    if (!await archive.exists('$wappId/app.wasm')) {
      LogService().log('WappInstaller: $wappId is missing app.wasm');
      return false;
    }
    return _ensureProfileFolder(wappId);
  }

  Future<bool> _extractZipIntoArchive(
      String wappId, Uint8List zipBytes) async {
    final archive = wappArchiveStorage();
    if (archive == null) {
      LogService().log(
          'WappInstaller: shared archive not available; cannot install $wappId');
      return false;
    }
    try {
      final zip = ZipDecoder().decodeBytes(zipBytes);
      await archive.createDirectory(wappId);
      var fileCount = 0;
      for (final file in zip) {
        if (!file.isFile) continue;
        final relPath =
            file.name.replaceAll('\\', '/').replaceAll(RegExp(r'^/+'), '');
        if (relPath.isEmpty) continue;
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
}
