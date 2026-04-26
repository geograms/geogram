/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

import '../models/sync_file_version.dart';
import 'app_service.dart';
import 'log_service.dart';
import 'mirror_config_service.dart';
import 'profile_storage.dart';

/// Local file version and deletion marker store for mirror sync.
///
/// Versions live under `mirror/versions/` and tombstones under
/// `mirror/tombstones/`, outside the syncable app folders. That keeps rollback
/// metadata local while still allowing tombstones to be advertised in manifests.
class SyncVersionService {
  static final SyncVersionService instance = SyncVersionService._();
  SyncVersionService._();

  static const _indexPath = 'mirror/versions/index.json';
  static const _dataRoot = 'mirror/versions/data';
  static const _tombstoneRoot = 'mirror/tombstones';

  bool get isVersioningEnabled =>
      MirrorConfigService.instance.config?.versioningEnabled ?? true;

  int get retentionDays =>
      MirrorConfigService.instance.config?.versionRetentionDays ?? 30;

  Future<List<SyncFileVersion>> listVersions({
    String? folder,
    String? filePath,
  }) async {
    final storage = AppService().profileStorage;
    if (storage == null) return [];
    final versions = await _readIndex(storage);
    final filtered = versions.where((version) {
      if (folder != null && version.folder != folder) return false;
      if (filePath != null && version.path != filePath) return false;
      return true;
    }).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return filtered;
  }

  Future<bool> restoreVersion(
    String versionId, {
    ProfileStorage? storage,
  }) async {
    final effectiveStorage = storage ?? AppService().profileStorage;
    if (effectiveStorage == null) return false;
    final versions = await _readIndex(effectiveStorage);
    final version = versions.cast<SyncFileVersion?>().firstWhere(
      (v) => v?.id == versionId,
      orElse: () => null,
    );
    if (version == null) return false;
    final bytes = await effectiveStorage.readBytes(version.dataPath);
    if (bytes == null) return false;
    await effectiveStorage.writeBytes('${version.folder}/${version.path}', bytes);
    await removeTombstone(version.folder, version.path, storage: effectiveStorage);
    LogService().log(
      'SyncVersion: Restored ${version.folder}/${version.path} from ${version.id}',
    );
    return true;
  }

  /// Archive an existing profile-storage file before sync overwrites/deletes it.
  Future<SyncFileVersion?> archiveProfileFile({
    required String folder,
    required String filePath,
    required SyncVersionReason reason,
    ProfileStorage? storage,
  }) async {
    if (!isVersioningEnabled || retentionDays <= 0) return null;
    final effectiveStorage = storage ?? AppService().profileStorage;
    if (effectiveStorage == null) return null;

    final relativePath = '$folder/$filePath';
    final bytes = await effectiveStorage.readBytes(relativePath);
    if (bytes == null) return null;
    return _archiveBytes(
      storage: effectiveStorage,
      folder: folder,
      filePath: filePath,
      reason: reason,
      bytes: bytes,
    );
  }

  /// Archive an existing filesystem file before sync overwrites/deletes it.
  Future<SyncFileVersion?> archiveFilesystemFile({
    required String folder,
    required String filePath,
    required String fullPath,
    required SyncVersionReason reason,
  }) async {
    if (!isVersioningEnabled || retentionDays <= 0) return null;
    final storage = AppService().profileStorage;
    if (storage == null) return null;

    final file = io.File(fullPath);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    return _archiveBytes(
      storage: storage,
      folder: folder,
      filePath: filePath,
      reason: reason,
      bytes: Uint8List.fromList(bytes),
    );
  }

  Future<SyncFileVersion?> _archiveBytes({
    required ProfileStorage storage,
    required String folder,
    required String filePath,
    required SyncVersionReason reason,
    required Uint8List bytes,
  }) async {
    final now = DateTime.now().toUtc();
    final id = const Uuid().v4();
    final hash = sha1.convert(bytes).toString();
    final safeName = _safeDataName(filePath);
    final dataPath =
        '$_dataRoot/$folder/${now.millisecondsSinceEpoch}_${id}_$safeName';

    await storage.writeBytes(dataPath, bytes);

    final version = SyncFileVersion(
      id: id,
      folder: folder,
      path: filePath,
      reason: reason,
      createdAt: now,
      size: bytes.length,
      sha1: hash,
      dataPath: dataPath,
    );

    final versions = await _readIndex(storage);
    versions.add(version);
    await _writeIndex(storage, versions);
    await pruneExpired(storage: storage);
    LogService().log(
      'SyncVersion: Archived $folder/$filePath (${reason.name}, ${bytes.length} bytes)',
    );
    return version;
  }

  Future<void> recordTombstone({
    required String folder,
    required String filePath,
    int? size,
    String? sha1Hash,
    int? deletedAt,
    ProfileStorage? storage,
  }) async {
    final effectiveStorage = storage ?? AppService().profileStorage;
    if (effectiveStorage == null) return;
    final tombstones = await listTombstones(folder, storage: effectiveStorage);
    final now = deletedAt ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    tombstones.removeWhere((t) => t.path == filePath);
    tombstones.add(
      MirrorTombstone(
        path: filePath,
        deletedAt: now,
        size: size,
        sha1: sha1Hash,
      ),
    );
    await _writeTombstones(folder, tombstones, storage: effectiveStorage);
    await pruneExpired(storage: effectiveStorage);
  }

  Future<void> removeTombstone(
    String folder,
    String filePath, {
    ProfileStorage? storage,
  }) async {
    final effectiveStorage = storage ?? AppService().profileStorage;
    if (effectiveStorage == null) return;
    final tombstones = await listTombstones(folder, storage: effectiveStorage);
    tombstones.removeWhere((t) => t.path == filePath);
    await _writeTombstones(folder, tombstones, storage: effectiveStorage);
  }

  Future<List<MirrorTombstone>> listTombstones(
    String folder, {
    ProfileStorage? storage,
  }) async {
    final effectiveStorage = storage ?? AppService().profileStorage;
    if (effectiveStorage == null) return [];
    final json = await effectiveStorage.readJson(_tombstonePath(folder));
    if (json == null) return [];
    final tombstones = (json['tombstones'] as List<dynamic>?)
            ?.map((entry) => MirrorTombstone.fromJson(
                  entry as Map<String, dynamic>,
                ))
            .toList() ??
        [];
    tombstones.sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
    return tombstones;
  }

  Future<void> pruneExpired({ProfileStorage? storage}) async {
    final effectiveStorage = storage ?? AppService().profileStorage;
    if (effectiveStorage == null || retentionDays <= 0) return;
    final cutoff = DateTime.now()
            .toUtc()
            .subtract(Duration(days: retentionDays))
            .millisecondsSinceEpoch ~/
        1000;

    final versions = await _readIndex(effectiveStorage);
    final kept = <SyncFileVersion>[];
    for (final version in versions) {
      final created = version.createdAt.toUtc().millisecondsSinceEpoch ~/ 1000;
      if (created >= cutoff) {
        kept.add(version);
        continue;
      }
      try {
        await effectiveStorage.delete(version.dataPath);
      } catch (_) {}
    }
    if (kept.length != versions.length) {
      await _writeIndex(effectiveStorage, kept);
    }

    final tombstoneDirExists =
        await effectiveStorage.directoryExists(_tombstoneRoot);
    if (!tombstoneDirExists) return;

    final entries = await effectiveStorage.listDirectory(_tombstoneRoot);
    for (final entry in entries) {
      if (entry.isDirectory || !entry.name.endsWith('.json')) continue;
      final folder = path.basenameWithoutExtension(entry.name);
      final tombstones = await listTombstones(folder, storage: effectiveStorage);
      final filtered =
          tombstones.where((t) => t.deletedAt >= cutoff).toList();
      if (filtered.length != tombstones.length) {
        await _writeTombstones(folder, filtered, storage: effectiveStorage);
      }
    }
  }

  Future<List<SyncFileVersion>> _readIndex(ProfileStorage storage) async {
    final json = await storage.readJson(_indexPath);
    if (json == null) return [];
    return (json['versions'] as List<dynamic>?)
            ?.map((entry) => SyncFileVersion.fromJson(
                  entry as Map<String, dynamic>,
                ))
            .toList() ??
        [];
  }

  Future<void> _writeIndex(
    ProfileStorage storage,
    List<SyncFileVersion> versions,
  ) async {
    await storage.writeJson(_indexPath, {
      'version': 1,
      'versions': versions.map((version) => version.toJson()).toList(),
    });
  }

  Future<void> _writeTombstones(
    String folder,
    List<MirrorTombstone> tombstones, {
    required ProfileStorage storage,
  }) async {
    await storage.writeJson(_tombstonePath(folder), {
      'version': 1,
      'folder': folder,
      'tombstones': tombstones.map((tombstone) => tombstone.toJson()).toList(),
    });
  }

  String _tombstonePath(String folder) => '$_tombstoneRoot/$folder.json';

  String _safeDataName(String filePath) {
    final name = path.basename(filePath).replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (name.isEmpty) {
      return base64Url.encode(utf8.encode(filePath)).replaceAll('=', '');
    }
    return name.length > 80 ? name.substring(name.length - 80) : name;
  }
}
