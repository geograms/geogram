/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../services/i18n_service.dart';
import '../services/log_service.dart';
import '../services/profile_service.dart';
import '../services/storage_config.dart';
import '../services/storage_stats_service.dart';

/// Where the storage path is rooted
enum StorageRoot {
  /// Relative to StorageConfig.baseDir (geogram folder)
  baseDir,

  /// Relative to getApplicationSupportDirectory (Android: files/)
  appSupport,

  /// The system cache directory
  cache,
}

/// Storage category definition
class StorageCategory {
  final String id;
  final String translationKey;
  final String descriptionKey;
  final IconData icon;
  final String relativePath;
  final Color color;
  final StorageRoot root;
  final bool isFile; // true if this is a single file, not a directory
  final bool
  isAppData; // true if clearing removes entire folder (app becomes unavailable)
  final bool
  isPerCallsign; // true if path is relative to each callsign in devices/
  final bool
  isRemoteCache; // true if this is remote device cache (excludes local profiles)

  const StorageCategory({
    required this.id,
    required this.translationKey,
    required this.descriptionKey,
    required this.icon,
    required this.relativePath,
    required this.color,
    this.root = StorageRoot.baseDir,
    this.isFile = false,
    this.isAppData = false,
    this.isPerCallsign = false,
    this.isRemoteCache = false,
  });
}

/// Available storage categories
const List<StorageCategory> _storageCategories = [
  // APK backups (stored in Android files/ directory)
  StorageCategory(
    id: 'apk_updates',
    translationKey: 'storage_apk_updates',
    descriptionKey: 'storage_apk_updates_description',
    icon: Icons.android,
    relativePath: 'updates',
    color: Colors.green,
    root: StorageRoot.appSupport,
  ),
  // Log file
  StorageCategory(
    id: 'log_file',
    translationKey: 'storage_log_file',
    descriptionKey: 'storage_log_file_description',
    icon: Icons.article,
    relativePath: 'log.txt',
    color: Colors.grey,
    isFile: true,
  ),
  // Map tiles
  StorageCategory(
    id: 'tiles',
    translationKey: 'storage_tiles',
    descriptionKey: 'storage_tiles_description',
    icon: Icons.map,
    relativePath: 'tiles',
    color: Colors.blue,
  ),
  // Apps data
  StorageCategory(
    id: 'apps',
    translationKey: 'storage_apps',
    descriptionKey: 'storage_apps_description',
    icon: Icons.folder_copy,
    relativePath: 'devices',
    color: Colors.amber,
  ),
  // Remote device cache (cached data from other devices, excludes local profiles)
  StorageCategory(
    id: 'remote_cache',
    translationKey: 'storage_remote_cache',
    descriptionKey: 'storage_remote_cache_description',
    icon: Icons.cloud_download,
    relativePath: 'devices',
    color: Colors.blueGrey,
    isRemoteCache: true,
  ),
  // Contacts app data (inside devices/{callsign}/contacts)
  StorageCategory(
    id: 'contacts',
    translationKey: 'storage_contacts',
    descriptionKey: 'storage_contacts_description',
    icon: Icons.contacts,
    relativePath: 'contacts',
    color: Colors.deepOrange,
    isAppData: true,
    isPerCallsign: true,
  ),
  // Events app data (inside devices/{callsign}/events)
  StorageCategory(
    id: 'events',
    translationKey: 'storage_events',
    descriptionKey: 'storage_events_description',
    icon: Icons.event,
    relativePath: 'events',
    color: Colors.red,
    isAppData: true,
    isPerCallsign: true,
  ),
  // Places app data (inside devices/{callsign}/places)
  StorageCategory(
    id: 'places',
    translationKey: 'storage_places',
    descriptionKey: 'storage_places_description',
    icon: Icons.place,
    relativePath: 'places',
    color: Colors.lightGreen,
    isAppData: true,
    isPerCallsign: true,
  ),
  // Tracker app data (inside devices/{callsign}/tracker)
  StorageCategory(
    id: 'tracker',
    translationKey: 'storage_tracker',
    descriptionKey: 'storage_tracker_description',
    icon: Icons.route,
    relativePath: 'tracker',
    color: Colors.blueAccent,
    isAppData: true,
    isPerCallsign: true,
  ),
  // Vision AI models
  StorageCategory(
    id: 'vision_models',
    translationKey: 'storage_vision_models',
    descriptionKey: 'storage_vision_models_description',
    icon: Icons.visibility,
    relativePath: 'bot/models/vision',
    color: Colors.purple,
  ),
  // Whisper speech models
  StorageCategory(
    id: 'whisper_models',
    translationKey: 'storage_whisper_models',
    descriptionKey: 'storage_whisper_models_description',
    icon: Icons.mic,
    relativePath: 'bot/models/whisper',
    color: Colors.orange,
  ),
  // Music models
  StorageCategory(
    id: 'music_models',
    translationKey: 'storage_music_models',
    descriptionKey: 'storage_music_models_description',
    icon: Icons.music_note,
    relativePath: 'bot/models/music',
    color: Colors.pink,
  ),
  // Music tracks
  StorageCategory(
    id: 'music_tracks',
    translationKey: 'storage_music_tracks',
    descriptionKey: 'storage_music_tracks_description',
    icon: Icons.library_music,
    relativePath: 'bot/music/tracks',
    color: Colors.teal,
  ),
  // Vision cache
  StorageCategory(
    id: 'vision_cache',
    translationKey: 'storage_vision_cache',
    descriptionKey: 'storage_vision_cache_description',
    icon: Icons.image,
    relativePath: 'bot/cache/vision',
    color: Colors.indigo,
  ),
  // Console VM
  StorageCategory(
    id: 'console_vm',
    translationKey: 'storage_console_vm',
    descriptionKey: 'storage_console_vm_description',
    icon: Icons.terminal,
    relativePath: 'console/vm',
    color: Colors.brown,
  ),
  // Chat data
  StorageCategory(
    id: 'chat',
    translationKey: 'storage_chat',
    descriptionKey: 'storage_chat_description',
    icon: Icons.chat,
    relativePath: 'chat',
    color: Colors.cyan,
  ),
  // Backups
  StorageCategory(
    id: 'backups',
    translationKey: 'storage_backups',
    descriptionKey: 'storage_backups_description',
    icon: Icons.backup,
    relativePath: 'backups',
    color: Colors.deepPurple,
  ),
  // Transfers
  StorageCategory(
    id: 'transfers',
    translationKey: 'storage_transfers',
    descriptionKey: 'storage_transfers_description',
    icon: Icons.swap_horiz,
    relativePath: 'transfers',
    color: Colors.lime,
  ),
  // System cache
  StorageCategory(
    id: 'cache',
    translationKey: 'storage_cache',
    descriptionKey: 'storage_cache_description',
    icon: Icons.cached,
    relativePath: '',
    color: Colors.blueGrey,
    root: StorageRoot.cache,
  ),
];

/// Page for managing app storage
class StorageSettingsPage extends StatefulWidget {
  const StorageSettingsPage({super.key});

  @override
  State<StorageSettingsPage> createState() => _StorageSettingsPageState();
}

class _StorageSettingsPageState extends State<StorageSettingsPage> {
  final I18nService _i18n = I18nService();
  final StorageConfig _storageConfig = StorageConfig();
  final ProfileService _profileService = ProfileService();
  final StorageStatsService _storageStatsService = StorageStatsService();

  Map<String, int> _categorySizes = {};
  final Map<String, bool> _categoryLoading = {};
  final Map<String, String> _categoryPaths = {};
  bool _isRefreshing = false;
  int _totalSize = 0;

  String? _appSupportDir;
  String? _cacheDir;

  StreamSubscription<Map<String, int>>? _sizesSubscription;

  @override
  void initState() {
    super.initState();
    _initializeStorage();
  }

  Future<void> _initializeStorage() async {
    if (kIsWeb) return;

    // Initialize the stats service
    await _storageStatsService.initialize();

    // Load cached sizes immediately (non-blocking)
    final cached = _storageStatsService.getCachedSizes();
    if (cached != null) {
      setState(() {
        _categorySizes = cached;
        _totalSize = cached.values.fold(0, (sum, size) => sum + size);
      });
    }

    // Resolve paths for category display
    await _resolvePaths();

    // Subscribe to size updates
    _sizesSubscription = _storageStatsService.sizesStream.listen((sizes) {
      if (mounted) {
        setState(() {
          _categorySizes = sizes;
          _totalSize = sizes.values.fold(0, (sum, size) => sum + size);
          _isRefreshing = false;
        });
      }
    });

    // Trigger background refresh
    _refreshSizes();
  }

  @override
  void dispose() {
    _sizesSubscription?.cancel();
    super.dispose();
  }

  /// Resolve platform directories and category paths
  Future<void> _resolvePaths() async {
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        final appSupportDir = await getApplicationSupportDirectory();
        _appSupportDir = appSupportDir.path;
      } else {
        _appSupportDir = _storageConfig.baseDir;
      }

      final cacheDir = await getTemporaryDirectory();
      _cacheDir = cacheDir.path;

      if (Platform.isAndroid) {
        final appCacheDir = await getApplicationCacheDirectory();
        _cacheDir = appCacheDir.path;
      }

      // Cache paths for each category
      for (final category in _storageCategories) {
        final fullPath = _getFullPath(category);
        _categoryPaths[category.id] = fullPath ?? '';
      }
    } catch (e) {
      LogService().log('StorageSettingsPage: Error resolving paths: $e');
    }
  }

  /// Trigger background refresh of sizes
  void _refreshSizes() {
    if (_isRefreshing) return;

    setState(() => _isRefreshing = true);

    // Convert StorageCategory to StorageCategoryDef for the service
    final categoryDefs = _storageCategories
        .map(
          (cat) => StorageCategoryDef(
            id: cat.id,
            relativePath: cat.relativePath,
            root: _convertRoot(cat.root),
            isFile: cat.isFile,
            isRemoteCache: cat.isRemoteCache,
            isPerCallsign: cat.isPerCallsign,
          ),
        )
        .toList();

    _storageStatsService.refreshSizes(categoryDefs);
  }

  /// Convert StorageRoot enum to StorageRootType
  StorageRootType _convertRoot(StorageRoot root) {
    switch (root) {
      case StorageRoot.baseDir:
        return StorageRootType.baseDir;
      case StorageRoot.appSupport:
        return StorageRootType.appSupport;
      case StorageRoot.cache:
        return StorageRootType.cache;
    }
  }

  String? _getFullPath(StorageCategory category) {
    switch (category.root) {
      case StorageRoot.baseDir:
        return p.join(_storageConfig.baseDir, category.relativePath);
      case StorageRoot.appSupport:
        if (_appSupportDir == null) return null;
        return p.join(_appSupportDir!, category.relativePath);
      case StorageRoot.cache:
        return _cacheDir;
    }
  }

  Future<int> _calculateSize(StorageCategory category, String? fullPath) async {
    if (fullPath == null) return 0;

    try {
      if (category.isFile) {
        final file = File(fullPath);
        if (await file.exists()) {
          return await file.length();
        }
        return 0;
      }

      // For remote cache, only count non-local callsign directories
      if (category.isRemoteCache) {
        return await _calculateRemoteCacheSize();
      }

      // For per-callsign categories, scan all callsign directories
      if (category.isPerCallsign) {
        return await _calculatePerCallsignSize(category.relativePath);
      }

      final dir = Directory(fullPath);
      if (!await dir.exists()) {
        return 0;
      }

      int totalSize = 0;
      await for (final entity in dir.list(
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
      return totalSize;
    } catch (e) {
      LogService().log(
        'StorageSettingsPage: Error calculating size for ${category.id}: $e',
      );
      return 0;
    }
  }

  /// Calculate size for categories that exist under each callsign in devices/
  Future<int> _calculatePerCallsignSize(String subFolder) async {
    int totalSize = 0;

    try {
      final devicesDir = Directory(_storageConfig.devicesDir);
      if (!await devicesDir.exists()) return 0;

      await for (final callsignEntity in devicesDir.list()) {
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
    } catch (e) {
      LogService().log(
        'StorageSettingsPage: Error calculating per-callsign size for $subFolder: $e',
      );
    }

    return totalSize;
  }

  /// Clear app data from all callsign directories
  Future<void> _clearPerCallsignData(String subFolder) async {
    try {
      final devicesDir = Directory(_storageConfig.devicesDir);
      if (!await devicesDir.exists()) return;

      await for (final callsignEntity in devicesDir.list()) {
        if (callsignEntity is Directory) {
          final appDir = Directory(p.join(callsignEntity.path, subFolder));
          if (await appDir.exists()) {
            await appDir.delete(recursive: true);
            LogService().log(
              'StorageSettingsPage: Deleted $subFolder from ${callsignEntity.path}',
            );
          }
        }
      }
    } catch (e) {
      LogService().log(
        'StorageSettingsPage: Error clearing per-callsign data for $subFolder: $e',
      );
      rethrow;
    }
  }

  /// Get set of callsigns belonging to local profiles
  Set<String> _getLocalProfileCallsigns() {
    final profiles = _profileService.getAllStoredProfiles();
    return profiles.map((p) => p.callsign).toSet();
  }

  /// Calculate size of remote device cache (excludes local profile callsigns)
  Future<int> _calculateRemoteCacheSize() async {
    int totalSize = 0;
    final localCallsigns = _getLocalProfileCallsigns();

    try {
      final devicesDir = Directory(_storageConfig.devicesDir);
      if (!await devicesDir.exists()) return 0;

      await for (final callsignEntity in devicesDir.list()) {
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
    } catch (e) {
      LogService().log(
        'StorageSettingsPage: Error calculating remote cache size: $e',
      );
    }

    return totalSize;
  }

  /// Clear remote device cache (excludes local profile callsigns)
  Future<void> _clearRemoteCache() async {
    final localCallsigns = _getLocalProfileCallsigns();

    try {
      final devicesDir = Directory(_storageConfig.devicesDir);
      if (!await devicesDir.exists()) return;

      await for (final callsignEntity in devicesDir.list()) {
        if (callsignEntity is Directory) {
          final callsign = p.basename(callsignEntity.path);
          // Skip local profile callsigns - never delete these!
          if (localCallsigns.contains(callsign)) {
            LogService().log(
              'StorageSettingsPage: Skipping local profile: $callsign',
            );
            continue;
          }

          await callsignEntity.delete(recursive: true);
          LogService().log(
            'StorageSettingsPage: Deleted remote cache for: $callsign',
          );
        }
      }
    } catch (e) {
      LogService().log('StorageSettingsPage: Error clearing remote cache: $e');
      rethrow;
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    } else if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    } else if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    } else {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
  }

  /// Get categories sorted by size (largest first)
  List<StorageCategory> _getSortedCategories() {
    final sorted = List<StorageCategory>.from(_storageCategories);
    sorted.sort((a, b) {
      final sizeA = _categorySizes[a.id] ?? 0;
      final sizeB = _categorySizes[b.id] ?? 0;
      return sizeB.compareTo(sizeA); // Descending order
    });
    return sorted;
  }

  Future<void> _clearCategory(StorageCategory category) async {
    final fullPath = _categoryPaths[category.id];
    if (fullPath == null || fullPath.isEmpty) return;

    // Use different confirmation message for app data
    final confirmMessage = category.isAppData
        ? _i18n.t(
            'storage_clear_app_confirm_message',
            params: [_i18n.t(category.translationKey)],
          )
        : _i18n.t(
            'storage_clear_confirm_message',
            params: [_i18n.t(category.translationKey)],
          );

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_i18n.t('storage_clear_confirm_title')),
        content: Text(confirmMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_i18n.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: Text(_i18n.t('delete')),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _categoryLoading[category.id] = true;
    });

    try {
      if (category.isFile) {
        final file = File(fullPath);
        if (await file.exists()) {
          await file.delete();
        }
      } else if (category.isRemoteCache) {
        // For remote cache, delete only non-local callsign directories
        await _clearRemoteCache();
      } else if (category.isPerCallsign) {
        // For per-callsign app data, delete from all callsign directories
        await _clearPerCallsignData(category.relativePath);
      } else if (category.isAppData) {
        // For app data, delete the entire folder (makes app unavailable)
        final dir = Directory(fullPath);
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      } else {
        // For other categories, only delete contents (keep folder)
        final dir = Directory(fullPath);
        if (await dir.exists()) {
          await for (final entity in dir.list(recursive: false)) {
            try {
              await entity.delete(recursive: true);
            } catch (e) {
              LogService().log(
                'StorageSettingsPage: Error deleting ${entity.path}: $e',
              );
            }
          }
        }
      }

      // Recalculate size
      final newSize = await _calculateSize(category, fullPath);
      setState(() {
        final oldSize = _categorySizes[category.id] ?? 0;
        _categorySizes[category.id] = newSize;
        _totalSize = _totalSize - oldSize + newSize;
        _categoryLoading[category.id] = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _i18n.t(
                'storage_cleared_success',
                params: [_i18n.t(category.translationKey)],
              ),
            ),
          ),
        );
      }
    } catch (e) {
      LogService().log(
        'StorageSettingsPage: Error clearing ${category.id}: $e',
      );
      setState(() {
        _categoryLoading[category.id] = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_i18n.t('storage_clear_error')),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (kIsWeb) {
      return Scaffold(
        appBar: AppBar(title: Text(_i18n.t('storage'))),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              _i18n.t('storage_not_available_web'),
              style: theme.textTheme.bodyLarge,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_i18n.t('storage')),
        actions: [
          if (_isRefreshing)
            const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _refreshSizes,
              tooltip: _i18n.t('refresh'),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Total storage card
          _buildTotalStorageCard(theme),
          const SizedBox(height: 24),

          // Section header
          _buildSectionHeader(
            theme,
            _i18n.t('storage_by_category'),
            Icons.folder,
          ),
          const SizedBox(height: 8),

          // Category cards (sorted by size, largest first)
          ..._getSortedCategories().map(
            (category) => _buildCategoryCard(theme, category),
          ),
        ],
      ),
    );
  }

  Widget _buildTotalStorageCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(Icons.storage, size: 48, color: theme.colorScheme.primary),
            const SizedBox(height: 12),
            Text(
              _i18n.t('storage_total_used'),
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              _formatSize(_totalSize),
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _storageConfig.baseDir,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(ThemeData theme, String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 20, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.primary,
          ),
        ),
      ],
    );
  }

  Widget _buildCategoryCard(ThemeData theme, StorageCategory category) {
    final size = _categorySizes[category.id] ?? 0;
    final isLoading = _categoryLoading[category.id] ?? false;
    final hasData = size > 0;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            // Icon
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: category.color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(category.icon, color: category.color, size: 24),
            ),
            const SizedBox(width: 16),

            // Text content
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _i18n.t(category.translationKey),
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _i18n.t(category.descriptionKey),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),

            // Size and clear button
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  _formatSize(size),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: hasData
                        ? theme.colorScheme.primary
                        : theme.colorScheme.outline,
                  ),
                ),
                const SizedBox(height: 4),
                if (isLoading)
                  const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else if (hasData)
                  TextButton(
                    onPressed: () => _clearCategory(category),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.red,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(_i18n.t('clear')),
                  )
                else
                  Text(
                    _i18n.t('empty'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
