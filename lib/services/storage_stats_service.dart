/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'package:flutter/foundation.dart' show compute, kIsWeb;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'log_service.dart';
import 'profile_service.dart';
import 'storage_config.dart';

/// Data structure for passing category info to isolate
class _CategoryInfo {
  final String id;
  final String fullPath;
  final bool isFile;
  final bool isRemoteCache;
  final bool isPerCallsign;
  final String relativePath;
  final String devicesDir;
  final Set<String> localCallsigns;

  _CategoryInfo({
    required this.id,
    required this.fullPath,
    required this.isFile,
    required this.isRemoteCache,
    required this.isPerCallsign,
    required this.relativePath,
    required this.devicesDir,
    required this.localCallsigns,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'fullPath': fullPath,
    'isFile': isFile,
    'isRemoteCache': isRemoteCache,
    'isPerCallsign': isPerCallsign,
    'relativePath': relativePath,
    'devicesDir': devicesDir,
    'localCallsigns': localCallsigns.toList(),
  };

  factory _CategoryInfo.fromJson(Map<String, dynamic> json) => _CategoryInfo(
    id: json['id'] as String,
    fullPath: json['fullPath'] as String,
    isFile: json['isFile'] as bool,
    isRemoteCache: json['isRemoteCache'] as bool,
    isPerCallsign: json['isPerCallsign'] as bool,
    relativePath: json['relativePath'] as String,
    devicesDir: json['devicesDir'] as String,
    localCallsigns: (json['localCallsigns'] as List).cast<String>().toSet(),
  );
}

/// Input data for the isolate computation
class _ComputeInput {
  final List<Map<String, dynamic>> categories;

  _ComputeInput(this.categories);
}

/// Service for managing storage statistics with background calculation and caching.
///
/// This service:
/// - Runs size calculations in a background isolate to avoid UI blocking
/// - Caches results to JSON for instant display on next load
/// - Provides a Stream for progressive UI updates
class StorageStatsService {
  static final StorageStatsService _instance = StorageStatsService._internal();
  factory StorageStatsService() => _instance;
  StorageStatsService._internal();

  final StorageConfig _storageConfig = StorageConfig();
  final ProfileService _profileService = ProfileService();

  /// Cached sizes loaded from disk
  Map<String, int>? _cachedSizes;

  /// Whether the cache has been loaded
  bool _cacheLoaded = false;

  /// Whether a refresh is currently in progress
  bool _isRefreshing = false;

  /// Stream controller for size updates
  final _sizesController = StreamController<Map<String, int>>.broadcast();

  /// Stream of size updates - emits when sizes are recalculated
  Stream<Map<String, int>> get sizesStream => _sizesController.stream;

  /// Whether a refresh is in progress
  bool get isRefreshing => _isRefreshing;

  /// Path to the cache file
  String get _cacheFilePath =>
      p.join(_storageConfig.baseDir, 'storage_stats.json');

  /// Platform directories (cached after first resolution)
  String? _appSupportDir;
  String? _cacheDir;

  /// Initialize the service and load cached data
  Future<void> initialize() async {
    if (kIsWeb) return;
    await _loadCache();
    await _resolvePlatformDirectories();
  }

  /// Load cached sizes from disk (synchronous after first load)
  Future<void> _loadCache() async {
    if (_cacheLoaded) return;

    try {
      final cacheFile = File(_cacheFilePath);
      if (await cacheFile.exists()) {
        final content = await cacheFile.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;

        if (json['categories'] is Map) {
          final categories = json['categories'] as Map<String, dynamic>;
          _cachedSizes = {};
          for (final entry in categories.entries) {
            if (entry.value is Map && entry.value['size'] is int) {
              _cachedSizes![entry.key] = entry.value['size'] as int;
            }
          }
          LogService().log(
            'StorageStatsService: Loaded ${_cachedSizes!.length} cached sizes',
          );
        }
      }
    } catch (e) {
      LogService().log('StorageStatsService: Error loading cache: $e');
    }

    _cacheLoaded = true;
  }

  /// Resolve platform-specific directories
  Future<void> _resolvePlatformDirectories() async {
    if (kIsWeb) return;

    try {
      if (Platform.isAndroid || Platform.isIOS) {
        final appSupportDir = await getApplicationSupportDirectory();
        _appSupportDir = appSupportDir.path;
      } else {
        _appSupportDir = _storageConfig.baseDir;
      }

      if (Platform.isAndroid) {
        final appCacheDir = await getApplicationCacheDirectory();
        _cacheDir = appCacheDir.path;
      } else {
        final cacheDir = await getTemporaryDirectory();
        _cacheDir = cacheDir.path;
      }
    } catch (e) {
      LogService().log('StorageStatsService: Error resolving directories: $e');
    }
  }

  /// Get cached sizes immediately (returns null if no cache exists)
  Map<String, int>? getCachedSizes() {
    return _cachedSizes != null ? Map<String, int>.from(_cachedSizes!) : null;
  }

  /// Trigger background refresh of all sizes
  Future<void> refreshSizes(List<StorageCategoryDef> categories) async {
    if (kIsWeb || _isRefreshing) return;

    _isRefreshing = true;

    try {
      // Ensure directories are resolved
      if (_appSupportDir == null) {
        await _resolvePlatformDirectories();
      }

      // Get local callsigns for remote cache filtering
      final localCallsigns = _getLocalProfileCallsigns();

      // Build category info list for the isolate
      final categoryInfos = <_CategoryInfo>[];
      for (final cat in categories) {
        final fullPath = _getFullPath(cat);
        if (fullPath != null) {
          categoryInfos.add(
            _CategoryInfo(
              id: cat.id,
              fullPath: fullPath,
              isFile: cat.isFile,
              isRemoteCache: cat.isRemoteCache,
              isPerCallsign: cat.isPerCallsign,
              relativePath: cat.relativePath,
              devicesDir: _storageConfig.devicesDir,
              localCallsigns: localCallsigns,
            ),
          );
        }
      }

      // Convert to JSON-safe format for isolate
      final input = _ComputeInput(
        categoryInfos.map((c) => c.toJson()).toList(),
      );

      // Run computation in isolate
      final results = await compute(_computeStorageSizes, input);

      // Update cache
      _cachedSizes = results;

      // Save to disk
      await _saveCache(results);

      // Emit update
      _sizesController.add(results);

      LogService().log(
        'StorageStatsService: Refreshed ${results.length} category sizes',
      );
    } catch (e) {
      LogService().log('StorageStatsService: Error refreshing sizes: $e');
    } finally {
      _isRefreshing = false;
    }
  }

  /// Get full path for a category
  String? _getFullPath(StorageCategoryDef category) {
    switch (category.root) {
      case StorageRootType.baseDir:
        return p.join(_storageConfig.baseDir, category.relativePath);
      case StorageRootType.appSupport:
        if (_appSupportDir == null) return null;
        return p.join(_appSupportDir!, category.relativePath);
      case StorageRootType.cache:
        return _cacheDir;
    }
  }

  /// Get local profile callsigns
  Set<String> _getLocalProfileCallsigns() {
    final profiles = _profileService.getAllStoredProfiles();
    return profiles.map((p) => p.callsign).toSet();
  }

  /// Save cache to disk
  Future<void> _saveCache(Map<String, int> sizes) async {
    try {
      final cacheData = {
        'version': 1,
        'lastUpdated': DateTime.now().toIso8601String(),
        'categories': sizes.map((key, value) => MapEntry(key, {'size': value})),
      };

      final cacheFile = File(_cacheFilePath);
      await cacheFile.writeAsString(jsonEncode(cacheData));
    } catch (e) {
      LogService().log('StorageStatsService: Error saving cache: $e');
    }
  }

  /// Invalidate cache for a specific category (e.g., after clearing)
  void invalidateCategory(String categoryId) {
    _cachedSizes?.remove(categoryId);
  }

  /// Clear all cached data
  void clearCache() {
    _cachedSizes = null;
    _cacheLoaded = false;
  }

  /// Dispose the service
  void dispose() {
    _sizesController.close();
  }
}

/// Category definition for the service (simplified, without UI fields)
class StorageCategoryDef {
  final String id;
  final String relativePath;
  final StorageRootType root;
  final bool isFile;
  final bool isRemoteCache;
  final bool isPerCallsign;

  const StorageCategoryDef({
    required this.id,
    required this.relativePath,
    this.root = StorageRootType.baseDir,
    this.isFile = false,
    this.isRemoteCache = false,
    this.isPerCallsign = false,
  });
}

/// Storage root type (matches StorageRoot enum in storage_settings_page.dart)
enum StorageRootType { baseDir, appSupport, cache }

/// Isolate worker function - computes sizes for all categories
Future<Map<String, int>> _computeStorageSizes(_ComputeInput input) async {
  final results = <String, int>{};

  for (final catJson in input.categories) {
    final cat = _CategoryInfo.fromJson(catJson);

    try {
      int size;

      if (cat.isFile) {
        size = await _computeFileSize(cat.fullPath);
      } else if (cat.isRemoteCache) {
        size = await _computeRemoteCacheSize(
          cat.devicesDir,
          cat.localCallsigns,
        );
      } else if (cat.isPerCallsign) {
        size = await _computePerCallsignSize(cat.devicesDir, cat.relativePath);
      } else {
        size = await _computeDirectorySize(cat.fullPath);
      }

      results[cat.id] = size;
    } catch (e) {
      results[cat.id] = 0;
    }
  }

  return results;
}

/// Compute size of a single file
Future<int> _computeFileSize(String path) async {
  final file = File(path);
  if (await file.exists()) {
    return await file.length();
  }
  return 0;
}

/// Compute size of a directory recursively
Future<int> _computeDirectorySize(String path) async {
  int totalSize = 0;
  final dir = Directory(path);

  if (!await dir.exists()) return 0;

  await for (final entity in dir.list(recursive: true, followLinks: false)) {
    if (entity is File) {
      try {
        totalSize += await entity.length();
      } catch (e) {
        // Skip files that can't be read
      }
    }
  }

  return totalSize;
}

/// Compute size of remote cache (excludes local callsigns)
Future<int> _computeRemoteCacheSize(
  String devicesDir,
  Set<String> localCallsigns,
) async {
  int totalSize = 0;
  final dir = Directory(devicesDir);

  if (!await dir.exists()) return 0;

  await for (final callsignEntity in dir.list()) {
    if (callsignEntity is Directory) {
      final callsign = p.basename(callsignEntity.path);
      // Skip local profile callsigns
      if (localCallsigns.contains(callsign)) continue;

      await for (final entity in callsignEntity.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) {
          try {
            totalSize += await entity.length();
          } catch (e) {
            // Skip files that can't be read
          }
        }
      }
    }
  }

  return totalSize;
}

/// Compute size for per-callsign categories (e.g., contacts, events)
Future<int> _computePerCallsignSize(String devicesDir, String subFolder) async {
  int totalSize = 0;
  final dir = Directory(devicesDir);

  if (!await dir.exists()) return 0;

  await for (final callsignEntity in dir.list()) {
    if (callsignEntity is Directory) {
      final appDir = Directory(p.join(callsignEntity.path, subFolder));
      if (await appDir.exists()) {
        await for (final entity in appDir.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is File) {
            try {
              totalSize += await entity.length();
            } catch (e) {
              // Skip files that can't be read
            }
          }
        }
      }
    }
  }

  return totalSize;
}
