/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import '../models/shared_folder.dart';
import '../models/sync_file_version.dart';
import '../platform/file_system_service.dart';
import 'app_service.dart';
import 'log_service.dart';
import 'profile_storage.dart';
import 'sync_version_service.dart';

class _ResolvedFileRoot {
  final ProfileStorage? storage;
  final String relativePath;
  final String externalPath;

  const _ResolvedFileRoot.profile(this.storage, this.relativePath)
    : externalPath = '';

  const _ResolvedFileRoot.external(this.externalPath)
    : storage = null,
      relativePath = '';

  bool get isProfile => storage != null;
}

class SharedFileSnapshot {
  final String path;
  final int size;
  final DateTime? modified;
  final String? sha1Hash;

  const SharedFileSnapshot({
    required this.path,
    required this.size,
    this.modified,
    this.sha1Hash,
  });

  Map<String, dynamic> toJson() => {
    'path': path,
    'size': size,
    if (modified != null) 'modified': modified!.toIso8601String(),
    if (sha1Hash != null) 'sha1': sha1Hash,
  };
}

/// Folder + local-file CRUD for the Shared app.
///
/// This service is intentionally transport-agnostic. It manages the on-disk
/// folder definitions (JSON files in the shared app storage), the local files
/// each device keeps in its chosen location, and version archiving when files
/// change. The cross-device synchronization itself lives in
/// `SharedSyncService`.
class SharedFolderService {
  static final SharedFolderService _instance = SharedFolderService._internal();
  factory SharedFolderService() => _instance;
  SharedFolderService._internal();

  /// Default-location root inside the profile storage when the user opts for
  /// "automatic" rather than picking a folder.
  static const String _autoLocalRoot = 'shared-local';

  late ProfileStorage _storage;
  String? _appPath;

  String? get appPath => _appPath;

  /// Resolve and initialize the Shared app service for the active profile.
  static Future<SharedFolderService?> forCurrentProfile({
    bool createIfMissing = false,
  }) async {
    final profileStorage = AppService().profileStorage;
    if (profileStorage == null) return null;

    final apps = await AppService().loadApps();
    var sharedApp = apps.where((a) => a.type == 'shared').firstOrNull;
    if (sharedApp == null && createIfMissing) {
      sharedApp = await AppService().createApp(title: 'Shared', type: 'shared');
    }
    final storagePath = sharedApp?.storagePath;
    if (storagePath == null || storagePath.isEmpty) return null;

    final scopedStorage = ScopedProfileStorage.fromAbsolutePath(
      profileStorage,
      storagePath,
    );
    final service = SharedFolderService();
    service.setStorage(scopedStorage);
    await service.initializeApp(storagePath);
    return service;
  }

  void setStorage(ProfileStorage storage) {
    _storage = storage;
  }

  Future<void> initializeApp(String appPath) async {
    LogService().log('SharedFolderService: Initializing with path: $appPath');
    _appPath = appPath;
    await _storage.createDirectory('');
    await _storage.createDirectory('extra');
    LogService().log('SharedFolderService: Initialized');
  }

  // -----------------------------
  // Identity
  // -----------------------------

  String get currentCallsign =>
      (AppService().currentCallsign?.trim().isNotEmpty ?? false)
      ? AppService().currentCallsign!.trim().toUpperCase()
      : 'LOCAL';

  bool isOwnedLocally(SharedFolder folder) =>
      folder.hostCallsign != null &&
      folder.hostCallsign!.toUpperCase() == currentCallsign;

  // -----------------------------
  // Folder CRUD
  // -----------------------------

  String _sanitizeFilename(String name) {
    return name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
  }

  String _getRelativePath(String fullPath) {
    if (_appPath == null) return fullPath;
    if (fullPath.startsWith(_appPath!)) {
      final rel = fullPath.substring(_appPath!.length);
      return rel.startsWith('/') ? rel.substring(1) : rel;
    }
    return fullPath;
  }

  String defaultLocalLocation(String folderId) {
    final rootStorage = AppService().profileStorage;
    final relative = '$_autoLocalRoot/$folderId';
    return (rootStorage ?? _storage).getAbsolutePath(relative);
  }

  /// Ensure the folder has a usable local location and the
  /// `localLocations[currentCallsign]` entry, then ensure the directory
  /// exists. Does not write the folder JSON back to disk; the caller decides
  /// when to persist.
  Future<SharedFolder> ensureLocalLocation(SharedFolder folder) async {
    var location = folder.location;
    if (location.isEmpty) {
      location = defaultLocalLocation(folder.id);
    }
    final localLocations = Map<String, String>.from(folder.localLocations);
    localLocations[currentCallsign] = location;
    final updated = folder.copyWith(
      location: location,
      localLocations: localLocations,
      modifiedAt: folder.modifiedAt,
    );
    await _ensureLocationExists(location);
    return updated;
  }

  /// When loading a folder from disk that may have come from another device,
  /// pick the local path for *this* device.
  SharedFolder _resolveLocalLocation(SharedFolder folder) {
    final mine = folder.localLocations[currentCallsign];
    if (mine != null && mine.isNotEmpty) {
      return folder.copyWith(location: mine, modifiedAt: folder.modifiedAt);
    }
    if (folder.location.isNotEmpty) return folder;
    return folder.copyWith(
      location: defaultLocalLocation(folder.id),
      modifiedAt: folder.modifiedAt,
    );
  }

  Future<List<SharedFolder>> loadAll() async {
    if (_appPath == null) return [];
    final folders = <SharedFolder>[];
    try {
      final entries = await _storage.listDirectory('');
      const skipFiles = {'tree.json', 'app.js', 'data.js', 'invitations.json'};
      for (final entry in entries) {
        if (!entry.isDirectory &&
            entry.name.endsWith('.json') &&
            !entry.name.startsWith('.') &&
            !skipFiles.contains(entry.name)) {
          try {
            final content = await _storage.readString(entry.path);
            if (content != null) {
              final fullPath = _storage.getAbsolutePath(entry.path);
              final folder = SharedFolder.fromJsonString(
                content,
                filePath: fullPath,
              );
              folders.add(_resolveLocalLocation(folder));
            }
          } catch (e) {
            LogService().log(
              'SharedFolderService: Error loading ${entry.path}: $e',
            );
          }
        }
      }
    } catch (e) {
      LogService().log('SharedFolderService: Error listing directory: $e');
    }
    folders.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return folders;
  }

  Future<SharedFolder?> load(String filePath) async {
    try {
      final relativePath = _getRelativePath(filePath);
      final content = await _storage.readString(relativePath);
      if (content == null) return null;
      return _resolveLocalLocation(
        SharedFolder.fromJsonString(content, filePath: filePath),
      );
    } catch (e) {
      LogService().log('SharedFolderService: Error loading from $filePath: $e');
      return null;
    }
  }

  Future<SharedFolder> save(SharedFolder folder) async {
    if (_appPath == null) {
      throw StateError('SharedFolderService not initialized');
    }
    final base = _sanitizeFilename(folder.title);
    String finalPath = '$base.json';
    int counter = 1;
    while (await _storage.exists(finalPath)) {
      finalPath = '${base}_$counter.json';
      counter++;
    }
    final prepared = await _prepareForWrite(folder);
    final updated = prepared.copyWith(
      filePath: _storage.getAbsolutePath(finalPath),
      modifiedAt: prepared.modifiedAt,
    );
    await _storage.writeString(finalPath, updated.toJsonString());
    LogService().log('SharedFolderService: Saved entry to $finalPath');
    return updated;
  }

  Future<SharedFolder> update(SharedFolder folder) async {
    if (folder.filePath == null) {
      throw ArgumentError('SharedFolder must have a filePath to update');
    }
    final relativePath = _getRelativePath(folder.filePath!);
    final prepared = await _prepareForWrite(folder);
    final updated = prepared.copyWith(modifiedAt: DateTime.now());
    await _storage.writeString(relativePath, updated.toJsonString());
    LogService().log('SharedFolderService: Updated entry at $relativePath');
    return updated;
  }

  Future<void> delete(String filePath) async {
    final relativePath = _getRelativePath(filePath);
    await _storage.delete(relativePath);
    LogService().log('SharedFolderService: Deleted entry at $relativePath');
  }

  Future<SharedFolder> _prepareForWrite(SharedFolder folder) async {
    final prepared = await ensureLocalLocation(folder);
    return prepared.copyWith(modifiedAt: prepared.modifiedAt);
  }

  /// Persist any localLocations / location updates this device made to a
  /// folder back to its JSON file. No-op if the folder doesn't have a
  /// filePath (i.e., not yet saved).
  Future<SharedFolder> persistLocalLocation(SharedFolder folder) async {
    final prepared = await ensureLocalLocation(folder);
    if (folder.filePath != null &&
        prepared.toJsonString() != folder.toJsonString()) {
      await _storage.writeString(
        _getRelativePath(folder.filePath!),
        prepared.toJsonString(),
      );
    }
    return prepared;
  }

  /// Lookup a folder by id, exact title, or sanitized title. Returns null if
  /// no match.
  Future<SharedFolder?> findFolder(String idOrTitle) async {
    final query = idOrTitle.trim();
    final lower = query.toLowerCase();
    final folders = await loadAll();
    for (final folder in folders) {
      if (folder.id == query ||
          folder.title.toLowerCase() == lower ||
          folder.sanitizedFilename == lower) {
        return folder;
      }
    }
    return null;
  }

  // -----------------------------
  // Local file operations
  // -----------------------------

  Future<SharedFolder> writeFile({
    required SharedFolder folder,
    required String relativePath,
    required Uint8List bytes,
  }) async {
    final prepared = await persistLocalLocation(folder);
    final relPath = _normalizeRelativePath(relativePath);
    final root = _resolveFileRoot(prepared.location);
    await _archiveBeforeChange(root, prepared, relPath, SyncVersionReason.modified);
    await _writeRootBytes(root, relPath, bytes);
    await SyncVersionService.instance.removeTombstone(
      'shared',
      _versionLabel(prepared, relPath),
      storage: AppService().profileStorage,
    );
    return prepared;
  }

  Future<Uint8List?> readFile({
    required SharedFolder folder,
    required String relativePath,
  }) async {
    final prepared = await ensureLocalLocation(folder);
    final relPath = _normalizeRelativePath(relativePath);
    return _readRootBytes(_resolveFileRoot(prepared.location), relPath);
  }

  Future<bool> fileExists({
    required SharedFolder folder,
    required String relativePath,
  }) async {
    final prepared = await ensureLocalLocation(folder);
    final relPath = _normalizeRelativePath(relativePath);
    return _rootFileExists(_resolveFileRoot(prepared.location), relPath);
  }

  Future<SharedFolder> deleteFile({
    required SharedFolder folder,
    required String relativePath,
  }) async {
    final prepared = await persistLocalLocation(folder);
    final relPath = _normalizeRelativePath(relativePath);
    final root = _resolveFileRoot(prepared.location);
    await _archiveBeforeChange(root, prepared, relPath, SyncVersionReason.deleted);
    await _deleteRootFile(root, relPath);
    await SyncVersionService.instance.recordTombstone(
      folder: 'shared',
      filePath: _versionLabel(prepared, relPath),
      storage: AppService().profileStorage,
    );
    return prepared;
  }

  /// Snapshot of all files inside the folder's local location. Set
  /// [hash] to true to include sha1 of each file (slow on large folders).
  Future<Map<String, SharedFileSnapshot>> snapshotFiles(
    SharedFolder folder, {
    bool hash = false,
  }) async {
    final prepared = await ensureLocalLocation(folder);
    return _listFilesAtRoot(_resolveFileRoot(prepared.location), hash: hash);
  }

  // -----------------------------
  // Path / root helpers
  // -----------------------------

  Future<void> _ensureLocationExists(String location) async {
    if (location.isEmpty) return;
    final root = _resolveFileRoot(location);
    if (root.isProfile) {
      await root.storage!.createDirectory(root.relativePath);
      return;
    }
    final fs = await _fileSystem();
    await fs.createDirectory(location, recursive: true);
  }

  Future<FileSystemService> _fileSystem() async {
    final fs = FileSystemService.instance;
    if (!fs.isInitialized) {
      await fs.init();
    }
    return fs;
  }

  _ResolvedFileRoot _resolveFileRoot(String location) {
    final normalized = _normalizePath(location);
    for (final storage in [
      _storage,
      if (AppService().profileStorage != null) AppService().profileStorage!,
    ]) {
      final basePath = _normalizePath(storage.basePath);
      if (normalized == basePath || normalized.startsWith('$basePath/')) {
        final rel = normalized == basePath
            ? ''
            : normalized.substring(basePath.length + 1);
        return _ResolvedFileRoot.profile(storage, rel);
      }
    }
    return _ResolvedFileRoot.external(location);
  }

  String _normalizePath(String value) =>
      path.normalize(value).replaceAll('\\', '/');

  String _normalizeRelativePath(String value) {
    final normalized = path.posix.normalize(
      value.replaceAll('\\', '/').replaceAll(RegExp(r'^/+'), ''),
    );
    if (normalized == '.' ||
        normalized.isEmpty ||
        normalized.startsWith('../') ||
        normalized == '..' ||
        path.posix.isAbsolute(normalized)) {
      throw ArgumentError('Invalid relative path: $value');
    }
    return normalized;
  }

  String _relativeToRoot(String fullPath, String rootPath) {
    final root = _normalizePath(rootPath);
    final full = _normalizePath(fullPath);
    if (full == root) return '';
    if (!full.startsWith('$root/')) {
      throw ArgumentError('Path is outside shared root: $fullPath');
    }
    return _normalizeRelativePath(full.substring(root.length + 1));
  }

  String _joinRelative(String base, String relativePath) {
    final relPath = _normalizeRelativePath(relativePath);
    if (base.isEmpty) return relPath;
    return '${base.replaceAll(RegExp(r'/+$'), '')}/$relPath';
  }

  /// Stable label used for SyncVersionService tombstones / archives —
  /// `<folderId>/<relativePath>`. Independent of where the file actually
  /// lives on disk, so a follower's archive of the "same" file lines up
  /// with the host's regardless of `localLocations` differences.
  String _versionLabel(SharedFolder folder, String relativePath) =>
      '${folder.id}/$relativePath';

  Future<Map<String, SharedFileSnapshot>> _listFilesAtRoot(
    _ResolvedFileRoot root, {
    bool hash = false,
  }) async {
    final snapshots = <String, SharedFileSnapshot>{};
    if (root.isProfile) {
      await root.storage!.createDirectory(root.relativePath);
      final entries = await root.storage!.listDirectory(
        root.relativePath,
        recursive: true,
      );
      for (final entry in entries) {
        if (entry.isDirectory) continue;
        final relPath = root.relativePath.isEmpty
            ? entry.path
            : entry.path.startsWith('${root.relativePath}/')
                ? entry.path.substring(root.relativePath.length + 1)
                : entry.path;
        final normalized = _normalizeRelativePath(relPath);
        String? sha1Hash;
        if (hash) {
          final bytes = await root.storage!.readBytes(entry.path);
          if (bytes != null) sha1Hash = sha1.convert(bytes).toString();
        }
        snapshots[normalized] = SharedFileSnapshot(
          path: normalized,
          size: entry.size ?? 0,
          modified: entry.modified,
          sha1Hash: sha1Hash,
        );
      }
      return snapshots;
    }

    final fs = await _fileSystem();
    if (!await fs.exists(root.externalPath)) {
      await fs.createDirectory(root.externalPath, recursive: true);
      return snapshots;
    }
    final entries = await fs.list(root.externalPath, recursive: true);
    for (final entry in entries) {
      if (!entry.isFile) continue;
      final normalized = _relativeToRoot(entry.path, root.externalPath);
      final stat = await fs.stat(entry.path);
      String? sha1Hash;
      if (hash) {
        final bytes = await fs.readAsBytes(entry.path);
        sha1Hash = sha1.convert(bytes).toString();
      }
      snapshots[normalized] = SharedFileSnapshot(
        path: normalized,
        size: stat.size,
        modified: stat.modified,
        sha1Hash: sha1Hash,
      );
    }
    return snapshots;
  }

  Future<Uint8List?> _readRootBytes(
    _ResolvedFileRoot root,
    String relativePath,
  ) async {
    final relPath = _normalizeRelativePath(relativePath);
    if (root.isProfile) {
      return root.storage!.readBytes(_joinRelative(root.relativePath, relPath));
    }
    final fs = await _fileSystem();
    final fullPath = path.join(root.externalPath, relPath);
    if (!await fs.exists(fullPath)) return null;
    return Uint8List.fromList(await fs.readAsBytes(fullPath));
  }

  Future<void> _writeRootBytes(
    _ResolvedFileRoot root,
    String relativePath,
    Uint8List bytes,
  ) async {
    final relPath = _normalizeRelativePath(relativePath);
    if (root.isProfile) {
      await root.storage!.writeBytes(
        _joinRelative(root.relativePath, relPath),
        bytes,
      );
      return;
    }
    final fs = await _fileSystem();
    await fs.writeAsBytes(path.join(root.externalPath, relPath), bytes);
  }

  Future<bool> _rootFileExists(
    _ResolvedFileRoot root,
    String relativePath,
  ) async {
    final relPath = _normalizeRelativePath(relativePath);
    if (root.isProfile) {
      return root.storage!.exists(_joinRelative(root.relativePath, relPath));
    }
    final fs = await _fileSystem();
    return fs.exists(path.join(root.externalPath, relPath));
  }

  Future<void> _deleteRootFile(
    _ResolvedFileRoot root,
    String relativePath,
  ) async {
    final relPath = _normalizeRelativePath(relativePath);
    if (root.isProfile) {
      await root.storage!.delete(_joinRelative(root.relativePath, relPath));
      return;
    }
    final fs = await _fileSystem();
    final fullPath = path.join(root.externalPath, relPath);
    if (await fs.exists(fullPath)) await fs.delete(fullPath);
  }

  Future<void> _archiveBeforeChange(
    _ResolvedFileRoot root,
    SharedFolder folder,
    String relativePath,
    SyncVersionReason reason,
  ) async {
    final relPath = _normalizeRelativePath(relativePath);
    if (!await _rootFileExists(root, relPath)) return;
    final label = _versionLabel(folder, relPath);
    if (root.isProfile) {
      final storagePath = _joinRelative(root.relativePath, relPath);
      final split = storagePath.indexOf('/');
      if (split <= 0 || split == storagePath.length - 1) return;
      await SyncVersionService.instance.archiveProfileFile(
        folder: storagePath.substring(0, split),
        filePath: storagePath.substring(split + 1),
        reason: reason,
        storage: root.storage,
      );
      return;
    }
    await SyncVersionService.instance.archiveFilesystemFile(
      folder: 'shared',
      filePath: label,
      fullPath: path.join(root.externalPath, relPath),
      reason: reason,
    );
  }

  // -----------------------------
  // Migration
  // -----------------------------

  /// Migrate legacy shared_folder apps to new format.
  Future<int> migrateFromLegacy(ProfileStorage profileStorage) async {
    int migrated = 0;
    try {
      final entries = await profileStorage.listDirectory('');
      for (final entry in entries) {
        if (!entry.isDirectory) continue;
        final folderName = entry.name;
        if (folderName == 'shared' ||
            folderName == 'files' ||
            folderName == 'logs' ||
            folderName == 'mirror') {
          continue;
        }
        final appJsPath = '$folderName/app.js';
        if (!await profileStorage.exists(appJsPath)) continue;
        try {
          final appJsContent = await profileStorage.readString(appJsPath);
          if (appJsContent == null) continue;
          final jsonMatch = RegExp(
            r'window\.APP_DATA\s*=\s*({[\s\S]*?});',
          ).firstMatch(appJsContent);
          if (jsonMatch == null) continue;
          final appData =
              jsonDecode(jsonMatch.group(1)!) as Map<String, dynamic>;
          final app = appData['app'] as Map<String, dynamic>?;
          if (app == null) continue;
          final type = app['type'] as String?;
          if (type != 'shared_folder') continue;

          String visibility = 'public';
          List<String> allowedReaders = [];
          final securityPath = '$folderName/extra/security.json';
          if (await profileStorage.exists(securityPath)) {
            try {
              final secContent = await profileStorage.readString(securityPath);
              if (secContent != null) {
                final secData = jsonDecode(secContent) as Map<String, dynamic>;
                visibility = secData['visibility'] as String? ?? 'public';
                allowedReaders =
                    (secData['allowedReaders'] as List<dynamic>?)
                            ?.cast<String>() ??
                        [];
              }
            } catch (_) {}
          }

          final title = app['title'] as String? ?? folderName;
          final location = profileStorage.getAbsolutePath(folderName);
          final sharedFolder = SharedFolder(
            title: title,
            location: location,
            visibility: SharedFolderVisibility.fromValue(visibility),
            allowedReaders: allowedReaders,
            description: app['description'] as String? ?? '',
          );
          await save(sharedFolder);
          migrated++;
          LogService().log(
            'SharedFolderService: Migrated legacy shared_folder "$title" from $folderName',
          );
        } catch (e) {
          LogService().log(
            'SharedFolderService: Error migrating $folderName: $e',
          );
        }
      }
    } catch (e) {
      LogService().log('SharedFolderService: Migration error: $e');
    }
    if (migrated > 0) {
      LogService().log(
        'SharedFolderService: Migrated $migrated legacy shared folders',
      );
    }
    return migrated;
  }
}
