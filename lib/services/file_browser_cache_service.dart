/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import '../models/file_browser_cache_models.dart';
import '../platform/file_system_service.dart';
import 'log_service.dart';
import 'storage_config.dart';

/// Singleton service for caching file browser data persistently across all
/// platforms. Storage goes through [FileSystemService] (dart:io on native,
/// fs_shim/IndexedDB on web) so the cache works in browsers too.
///
/// Thumbnails are stored as raw files at thumbs/{volumeId}/{sha1}.{ext} —
/// one file per thumbnail. The previous ZIP-per-volume layout was rewritten
/// from scratch on every save (O(N²) re-encode); the raw-file layout makes
/// each save O(1).
///
/// Metadata JSON is flushed synchronously on every saveThumbnail call so a
/// generated thumbnail is durable the instant the call returns. The previous
/// 2-second debounced flush would silently drop thumbnails when the picker
/// closed before the timer fired, which is why every reopen re-generated.
class FileBrowserCacheService {
  static final FileBrowserCacheService _instance =
      FileBrowserCacheService._internal();
  factory FileBrowserCacheService() => _instance;
  FileBrowserCacheService._internal();

  final FileSystemService _fs = FileSystemService.instance;
  String? _cacheDir;
  bool _initialized = false;
  Future<void>? _initFuture;

  // In-memory caches loaded from disk.
  final Map<String, VolumeCacheFile> _volumeCaches = {};
  final Map<String, ThumbnailMetaFile> _thumbnailMetas = {};

  // Pending writes for batching (volume directory listings only — thumbnail
  // meta is flushed synchronously per save).
  final Set<String> _dirtyVolumes = {};
  bool _flushScheduled = false;

  /// Initialize the cache service. Idempotent and safe to call concurrently.
  Future<void> initialize() async {
    if (_initialized) return;
    return _initFuture ??= _initializeOnce();
  }

  Future<void> _initializeOnce() async {
    try {
      await _fs.init();
      _cacheDir = StorageConfig().fileBrowserCacheDir;
      if (!await _fs.isDirectory(_cacheDir!)) {
        await _fs.createDirectory(_cacheDir!, recursive: true);
      }
      // Migrate away from the old ZIP-per-volume thumbnail layout. Raw
      // files live under thumbs/{volumeId}/ now; old ZIPs are dead weight.
      await _migrateAwayFromZip();
      _initialized = true;
      LogService().log('FileBrowserCacheService initialized at: $_cacheDir');
    } catch (e) {
      LogService().log('Error initializing FileBrowserCacheService: $e');
    }
  }

  Future<void> _migrateAwayFromZip() async {
    try {
      final entries = await _fs.list(_cacheDir!);
      for (final entry in entries) {
        if (entry.isFile && entry.path.endsWith('.zip')) {
          try {
            await _fs.delete(entry.path);
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// Get the volume ID for a given path. Volumes let us invalidate
  /// per-removable-drive without nuking everything.
  String getVolumeId(String path) {
    if (kIsWeb) return 'web';

    if (path.startsWith('/storage/emulated/0')) {
      return 'internal';
    }

    final sdcardMatch =
        RegExp(r'/storage/([A-F0-9]{4}-[A-F0-9]{4})').firstMatch(path);
    if (sdcardMatch != null) {
      return 'sdcard_${sdcardMatch.group(1)}';
    }

    // Linux home directory — checked via env on native, no-op on web.
    final home = _homeDir();
    if (home != null && path.startsWith(home)) {
      return 'internal';
    }

    final mediaMatch = RegExp(r'/media/[^/]+/([^/]+)').firstMatch(path);
    if (mediaMatch != null) {
      return 'media_${mediaMatch.group(1)}';
    }

    final mntMatch = RegExp(r'/mnt/([^/]+)').firstMatch(path);
    if (mntMatch != null) {
      return 'mnt_${mntMatch.group(1)}';
    }

    final runMediaMatch =
        RegExp(r'/run/media/[^/]+/([^/]+)').firstMatch(path);
    if (runMediaMatch != null) {
      return 'media_${runMediaMatch.group(1)}';
    }

    return 'default';
  }

  String? _homeDir() {
    if (kIsWeb) return null;
    // Avoid a hard dart:io import here — query through StorageConfig which
    // already abstracts platform paths. This is best-effort: a miss just
    // means the path lands in the 'default' bucket, which is harmless.
    final base = StorageConfig().baseDir;
    final lastSlash = base.lastIndexOf('/');
    return lastSlash > 0 ? base.substring(0, lastSlash) : null;
  }

  String _joinPath(List<String> parts) =>
      parts.where((p) => p.isNotEmpty).join('/');

  String _getVolumeCacheFilePath(String volumeId) =>
      _joinPath([_cacheDir!, 'files_$volumeId.json']);

  String _getThumbnailMetaFilePath(String volumeId) =>
      _joinPath([_cacheDir!, 'thumbnails_${volumeId}_meta.json']);

  String _getThumbnailFilePath(
          String volumeId, String hashKey, String extension) =>
      _joinPath([_cacheDir!, 'thumbs', volumeId, '$hashKey.$extension']);

  String _hashPath(String path) =>
      sha1.convert(utf8.encode(path)).toString();

  Future<VolumeCacheFile> _loadVolumeCache(String volumeId) async {
    if (_volumeCaches.containsKey(volumeId)) return _volumeCaches[volumeId]!;

    final filePath = _getVolumeCacheFilePath(volumeId);
    if (await _fs.isFile(filePath)) {
      try {
        final content = await _fs.readAsString(filePath);
        final json = jsonDecode(content) as Map<String, dynamic>;
        final cache = VolumeCacheFile.fromJson(json);
        _volumeCaches[volumeId] = cache;
        return cache;
      } catch (e) {
        LogService().log('Error loading volume cache $volumeId: $e');
      }
    }

    final cache = VolumeCacheFile(
      version: 1,
      volumeId: volumeId,
      directories: {},
    );
    _volumeCaches[volumeId] = cache;
    return cache;
  }

  Future<ThumbnailMetaFile> _loadThumbnailMeta(String volumeId) async {
    if (_thumbnailMetas.containsKey(volumeId)) {
      return _thumbnailMetas[volumeId]!;
    }

    final filePath = _getThumbnailMetaFilePath(volumeId);
    if (await _fs.isFile(filePath)) {
      try {
        final content = await _fs.readAsString(filePath);
        final json = jsonDecode(content) as Map<String, dynamic>;
        final meta = ThumbnailMetaFile.fromJson(json);
        _thumbnailMetas[volumeId] = meta;
        return meta;
      } catch (e) {
        LogService().log('Error loading thumbnail meta $volumeId: $e');
      }
    }

    final meta = ThumbnailMetaFile(
      version: 1,
      volumeId: volumeId,
      thumbnails: {},
    );
    _thumbnailMetas[volumeId] = meta;
    return meta;
  }

  Future<void> _flushThumbnailMeta(String volumeId) async {
    final meta = _thumbnailMetas[volumeId];
    if (meta == null) return;
    try {
      final json = const JsonEncoder.withIndent('  ').convert(meta.toJson());
      await _fs.writeAsString(_getThumbnailMetaFilePath(volumeId), json);
    } catch (e) {
      LogService().log('Error flushing thumbnail meta $volumeId: $e');
    }
  }

  /// Get cached directory listing.
  Future<DirectoryCache?> getDirectoryCache(String path) async {
    if (_cacheDir == null) return null;
    final volumeId = getVolumeId(path);
    final cache = await _loadVolumeCache(volumeId);
    return cache.directories[path];
  }

  /// Save directory cache (debounced flush is fine here — directory
  /// listings re-scan on cache miss, no permanent loss).
  Future<void> saveDirectoryCache(
    String path,
    List<CachedFileEntry> entries,
    DateTime dirModified,
  ) async {
    if (_cacheDir == null) return;

    final volumeId = getVolumeId(path);
    final cache = await _loadVolumeCache(volumeId);

    int totalSize = 0;
    for (final entry in entries) {
      totalSize += entry.size;
    }

    final dirCache = DirectoryCache(
      path: path,
      lastScanned: DateTime.now(),
      directoryModified: dirModified,
      totalSize: totalSize,
      entries: entries,
    );

    final newDirectories = Map<String, DirectoryCache>.from(cache.directories);
    newDirectories[path] = dirCache;
    _volumeCaches[volumeId] = VolumeCacheFile(
      version: cache.version,
      volumeId: volumeId,
      directories: newDirectories,
    );

    _dirtyVolumes.add(volumeId);
    _scheduleFlush();
  }

  /// Check if directory cache is valid (not stale).
  Future<bool> isCacheValid(String path) async {
    if (_cacheDir == null) return false;

    final cache = await getDirectoryCache(path);
    if (cache == null) return false;

    try {
      final stat = await _fs.stat(path);
      return !cache.isStale(stat.modified);
    } catch (_) {
      return false;
    }
  }

  /// Get cached folder size.
  Future<int?> getCachedFolderSize(String folderPath) async {
    if (_cacheDir == null) return null;

    final parentPath = _parentOf(folderPath);
    final cache = await getDirectoryCache(parentPath);
    if (cache == null) return null;

    final entry = cache.entries.where((e) => e.path == folderPath).firstOrNull;
    return entry?.size;
  }

  String _parentOf(String path) {
    final lastSlash = path.lastIndexOf('/');
    if (lastSlash <= 0) return '/';
    return path.substring(0, lastSlash);
  }

  /// Recursively compute the total size of a folder, reusing cached
  /// per-child sizes whose recorded `modified` timestamp still matches
  /// the live mtime.
  ///
  /// One non-recursive `list()` per directory; each subdirectory either
  /// reuses its cached entry (mtime unchanged) or recurses (mtime
  /// advanced). Files contribute `stat.size`. The result writes back
  /// through `saveDirectoryCache`, so subsequent calls hit the cache
  /// and the picker can render last-known sizes near-instantly.
  ///
  /// `seen` is an optional cycle-breaker for symlinked roots; callers
  /// may omit it.
  Future<int> refreshFolderSize(
    String path, {
    Set<String>? seen,
  }) async {
    if (_cacheDir == null) return 0;
    seen ??= <String>{};
    if (seen.contains(path)) return 0;
    seen.add(path);

    final List<FsEntity> entities;
    try {
      entities = await _fs.list(path);
    } catch (_) {
      return 0;
    }

    DateTime? dirModified;
    try {
      dirModified = (await _fs.stat(path)).modified;
    } catch (_) {}

    // Index any existing cached entries by path so we can short-circuit
    // when the child mtime hasn't advanced.
    final existing = await getDirectoryCache(path);
    final cachedByPath = <String, CachedFileEntry>{};
    if (existing != null) {
      for (final e in existing.entries) {
        cachedByPath[e.path] = e;
      }
    }

    final newEntries = <CachedFileEntry>[];
    var total = 0;
    for (final ent in entities) {
      int size;
      DateTime modified;
      try {
        final st = await _fs.stat(ent.path);
        modified = st.modified;
        if (ent.isDirectory) {
          final cached = cachedByPath[ent.path];
          if (cached != null && cached.modified.isAtSameMomentAs(modified)) {
            size = cached.size;
          } else {
            size = await refreshFolderSize(ent.path, seen: seen);
          }
        } else {
          size = st.size;
        }
      } catch (_) {
        size = 0;
        modified = DateTime.fromMillisecondsSinceEpoch(0);
      }

      newEntries.add(CachedFileEntry(
        name: ent.name,
        path: ent.path,
        isDirectory: ent.isDirectory,
        size: size,
        modified: modified,
      ));
      total += size;
    }

    if (dirModified != null) {
      await saveDirectoryCache(path, newEntries, dirModified);
    }

    return total;
  }

  /// Save folder size to cache.
  Future<void> saveFolderSize(String folderPath, int size) async {
    if (_cacheDir == null) return;

    final parentPath = _parentOf(folderPath);
    final volumeId = getVolumeId(parentPath);
    final cache = await _loadVolumeCache(volumeId);
    final dirCache = cache.directories[parentPath];

    if (dirCache == null) return;

    final updatedEntries = dirCache.entries.map((entry) {
      if (entry.path == folderPath) {
        return CachedFileEntry(
          name: entry.name,
          path: entry.path,
          isDirectory: entry.isDirectory,
          size: size,
          modified: entry.modified,
        );
      }
      return entry;
    }).toList();

    final updatedDirCache = DirectoryCache(
      path: dirCache.path,
      lastScanned: dirCache.lastScanned,
      directoryModified: dirCache.directoryModified,
      totalSize: updatedEntries.fold(0, (sum, e) => sum + e.size),
      entries: updatedEntries,
    );

    final newDirectories = Map<String, DirectoryCache>.from(cache.directories);
    newDirectories[parentPath] = updatedDirCache;
    _volumeCaches[volumeId] = VolumeCacheFile(
      version: cache.version,
      volumeId: volumeId,
      directories: newDirectories,
    );

    _dirtyVolumes.add(volumeId);
    _scheduleFlush();
  }

  /// Check if a thumbnail exists in the cache and is up-to-date.
  Future<bool> hasThumbnail(String filePath, DateTime sourceModified) async {
    if (_cacheDir == null) return false;

    final volumeId = getVolumeId(filePath);
    final meta = await _loadThumbnailMeta(volumeId);
    final hashKey = _hashPath(filePath);
    final thumbMeta = meta.thumbnails[hashKey];

    if (thumbMeta == null) return false;
    if (thumbMeta.sourceModified.isBefore(sourceModified)) return false;

    final thumbPath =
        _getThumbnailFilePath(volumeId, hashKey, thumbMeta.extension);
    return _fs.isFile(thumbPath);
  }

  /// Returns a real on-disk path to the cached thumbnail. Returns null on
  /// web (the IndexedDB-backed FileSystemService has no real path) or on
  /// cache miss. Use [getThumbnailBytes] when you need cross-platform
  /// access.
  Future<String?> getThumbnailTempPath(String filePath) async {
    if (kIsWeb || _cacheDir == null) return null;

    final volumeId = getVolumeId(filePath);
    final hashKey = _hashPath(filePath);
    final meta = await _loadThumbnailMeta(volumeId);
    final thumbMeta = meta.thumbnails[hashKey];
    if (thumbMeta == null) return null;

    final thumbPath =
        _getThumbnailFilePath(volumeId, hashKey, thumbMeta.extension);
    if (await _fs.isFile(thumbPath)) return thumbPath;
    return null;
  }

  /// Cross-platform thumbnail access: returns the cached bytes regardless
  /// of platform. Web callers should use this rather than
  /// [getThumbnailTempPath].
  Future<Uint8List?> getThumbnailBytes(String filePath) async {
    if (_cacheDir == null) return null;

    final volumeId = getVolumeId(filePath);
    final hashKey = _hashPath(filePath);
    final meta = await _loadThumbnailMeta(volumeId);
    final thumbMeta = meta.thumbnails[hashKey];
    if (thumbMeta == null) return null;

    final thumbPath =
        _getThumbnailFilePath(volumeId, hashKey, thumbMeta.extension);
    if (!await _fs.isFile(thumbPath)) return null;

    try {
      final bytes = await _fs.readAsBytes(thumbPath);
      return bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    } catch (e) {
      LogService().log('Error reading cached thumbnail $thumbPath: $e');
      return null;
    }
  }

  /// Save a thumbnail to the cache. Metadata flushes synchronously before
  /// returning so the entry is durable even if the app is killed
  /// immediately after (the previous debounced flush silently dropped
  /// thumbnails when the picker closed too quickly).
  Future<void> saveThumbnail(
    String filePath,
    Uint8List bytes,
    DateTime sourceModified, {
    String extension = 'png',
  }) async {
    if (_cacheDir == null) return;

    final volumeId = getVolumeId(filePath);
    final hashKey = _hashPath(filePath);

    final meta = await _loadThumbnailMeta(volumeId);
    final thumbMeta = ThumbnailMeta(
      sourcePath: filePath,
      sourceModified: sourceModified,
      extension: extension,
      hashKey: hashKey,
    );

    final newThumbnails = Map<String, ThumbnailMeta>.from(meta.thumbnails);
    newThumbnails[hashKey] = thumbMeta;
    _thumbnailMetas[volumeId] = ThumbnailMetaFile(
      version: meta.version,
      volumeId: volumeId,
      thumbnails: newThumbnails,
    );

    final thumbPath = _getThumbnailFilePath(volumeId, hashKey, extension);
    try {
      await _fs.writeAsBytes(thumbPath, bytes);
    } catch (e) {
      LogService().log('Error writing thumbnail file $thumbPath: $e');
      return;
    }

    await _flushThumbnailMeta(volumeId);
  }

  void _scheduleFlush() {
    if (_flushScheduled) return;
    _flushScheduled = true;
    Future.delayed(const Duration(seconds: 2), () {
      _flushScheduled = false;
      flush();
    });
  }

  /// Flush pending volume-cache writes. Thumbnail metadata is already
  /// flushed synchronously by [saveThumbnail].
  Future<void> flush() async {
    if (_cacheDir == null) return;

    for (final volumeId in _dirtyVolumes.toList()) {
      final cache = _volumeCaches[volumeId];
      if (cache != null) {
        try {
          final filePath = _getVolumeCacheFilePath(volumeId);
          final json =
              const JsonEncoder.withIndent('  ').convert(cache.toJson());
          await _fs.writeAsString(filePath, json);
        } catch (e) {
          LogService().log('Error flushing volume cache $volumeId: $e');
        }
      }
    }
    _dirtyVolumes.clear();
  }

  /// Clear all cache data for a specific volume.
  Future<void> clearVolumeCache(String volumeId) async {
    if (_cacheDir == null) return;

    _volumeCaches.remove(volumeId);
    _thumbnailMetas.remove(volumeId);
    _dirtyVolumes.remove(volumeId);

    try {
      final cachePath = _getVolumeCacheFilePath(volumeId);
      if (await _fs.isFile(cachePath)) await _fs.delete(cachePath);

      final metaPath = _getThumbnailMetaFilePath(volumeId);
      if (await _fs.isFile(metaPath)) await _fs.delete(metaPath);

      final thumbsDir = _joinPath([_cacheDir!, 'thumbs', volumeId]);
      if (await _fs.isDirectory(thumbsDir)) {
        await _fs.delete(thumbsDir, recursive: true);
      }

      LogService().log('Cleared cache for volume: $volumeId');
    } catch (e) {
      LogService().log('Error clearing volume cache $volumeId: $e');
    }
  }

  /// Clear all cache data.
  Future<void> clearAllCaches() async {
    if (_cacheDir == null) return;

    _volumeCaches.clear();
    _thumbnailMetas.clear();
    _dirtyVolumes.clear();

    try {
      if (await _fs.isDirectory(_cacheDir!)) {
        await _fs.delete(_cacheDir!, recursive: true);
        await _fs.createDirectory(_cacheDir!, recursive: true);
      }
      LogService().log('Cleared all file browser caches');
    } catch (e) {
      LogService().log('Error clearing all caches: $e');
    }
  }
}
