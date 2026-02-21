/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import '../models/shared_folder.dart';
import 'log_service.dart';
import 'profile_storage.dart';

/// Service for managing shared folder entries
class SharedFolderService {
  static final SharedFolderService _instance = SharedFolderService._internal();
  factory SharedFolderService() => _instance;
  SharedFolderService._internal();

  /// Profile storage for file operations (encrypted or filesystem)
  late ProfileStorage _storage;

  String? _appPath;

  /// Get the current app path
  String? get appPath => _appPath;

  /// Set the profile storage for file operations
  void setStorage(ProfileStorage storage) {
    _storage = storage;
  }

  /// Initialize shared folder service
  Future<void> initializeApp(String appPath) async {
    LogService().log('SharedFolderService: Initializing with path: $appPath');
    _appPath = appPath;

    // Create root directory
    await _storage.createDirectory('');
    await _storage.createDirectory('extra');

    LogService().log('SharedFolderService: Initialized');
  }

  /// Sanitize name for use as filename
  String _sanitizeFilename(String name) {
    return name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
  }

  /// Get relative path from absolute path
  String _getRelativePath(String fullPath) {
    if (_appPath == null) return fullPath;
    if (fullPath.startsWith(_appPath!)) {
      final rel = fullPath.substring(_appPath!.length);
      return rel.startsWith('/') ? rel.substring(1) : rel;
    }
    return fullPath;
  }

  /// Load all shared folder entries
  Future<List<SharedFolder>> loadAll() async {
    if (_appPath == null) return [];

    final folders = <SharedFolder>[];

    try {
      final entries = await _storage.listDirectory('');

      // Known non-folder JSON files to skip
      const skipFiles = {'tree.json', 'app.js', 'data.js'};

      for (final entry in entries) {
        if (!entry.isDirectory &&
            entry.name.endsWith('.json') &&
            !entry.name.startsWith('.') &&
            !skipFiles.contains(entry.name)) {
          try {
            final content = await _storage.readString(entry.path);
            if (content != null) {
              final fullPath = _storage.getAbsolutePath(entry.path);
              final folder =
                  SharedFolder.fromJsonString(content, filePath: fullPath);
              folders.add(folder);
            }
          } catch (e) {
            LogService()
                .log('SharedFolderService: Error loading ${entry.path}: $e');
          }
        }
      }
    } catch (e) {
      LogService().log('SharedFolderService: Error listing directory: $e');
    }

    // Sort by modification date, newest first
    folders.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));

    return folders;
  }

  /// Save a new shared folder entry
  /// Returns the saved SharedFolder with updated filePath
  Future<SharedFolder> save(SharedFolder folder) async {
    if (_appPath == null) {
      throw StateError('SharedFolderService not initialized');
    }

    // Generate filename from title
    String filename = '${_sanitizeFilename(folder.title)}.json';

    // Check for existing file and add suffix if needed
    String finalPath = filename;
    int counter = 1;
    while (await _storage.exists(finalPath)) {
      final baseName = _sanitizeFilename(folder.title);
      finalPath = '${baseName}_$counter.json';
      counter++;
    }

    final updatedFolder = folder.copyWith(
      filePath: _storage.getAbsolutePath(finalPath),
    );

    await _storage.writeString(finalPath, updatedFolder.toJsonString());

    LogService().log('SharedFolderService: Saved entry to $finalPath');

    return updatedFolder;
  }

  /// Update an existing shared folder entry
  Future<SharedFolder> update(SharedFolder folder) async {
    if (folder.filePath == null) {
      throw ArgumentError('SharedFolder must have a filePath to update');
    }

    final relativePath = _getRelativePath(folder.filePath!);
    final updatedFolder = folder.copyWith(modifiedAt: DateTime.now());

    await _storage.writeString(relativePath, updatedFolder.toJsonString());

    LogService()
        .log('SharedFolderService: Updated entry at $relativePath');

    return updatedFolder;
  }

  /// Delete a shared folder entry (does NOT delete the actual folder on disk)
  Future<void> delete(String filePath) async {
    final relativePath = _getRelativePath(filePath);
    await _storage.delete(relativePath);
    LogService().log('SharedFolderService: Deleted entry at $relativePath');
  }

  /// Load a single shared folder entry by file path
  Future<SharedFolder?> load(String filePath) async {
    try {
      final relativePath = _getRelativePath(filePath);
      final content = await _storage.readString(relativePath);
      if (content == null) return null;

      return SharedFolder.fromJsonString(content, filePath: filePath);
    } catch (e) {
      LogService()
          .log('SharedFolderService: Error loading from $filePath: $e');
      return null;
    }
  }

  /// Migrate legacy shared_folder apps to new format
  /// Scans for folders with app.js containing type: 'shared_folder'
  /// and creates JSON entries in the shared app directory
  Future<int> migrateFromLegacy(ProfileStorage profileStorage) async {
    int migrated = 0;

    try {
      final entries = await profileStorage.listDirectory('');

      for (final entry in entries) {
        if (!entry.isDirectory) continue;
        final folderName = entry.name;

        // Skip known single-instance types and system folders
        if (folderName == 'shared' ||
            folderName == 'files' ||
            folderName == 'logs' ||
            folderName == 'mirror') {
          continue;
        }

        // Check if this folder has an app.js with type shared_folder
        final appJsPath = '$folderName/app.js';
        if (!await profileStorage.exists(appJsPath)) continue;

        try {
          final appJsContent = await profileStorage.readString(appJsPath);
          if (appJsContent == null) continue;

          // Parse app.js - it's a JS file with window.APP_DATA = {...};
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

          // Read visibility from security.json if it exists
          String visibility = 'public';
          List<String> allowedReaders = [];
          final securityPath = '$folderName/extra/security.json';
          if (await profileStorage.exists(securityPath)) {
            try {
              final secContent =
                  await profileStorage.readString(securityPath);
              if (secContent != null) {
                final secData =
                    jsonDecode(secContent) as Map<String, dynamic>;
                visibility = secData['visibility'] as String? ?? 'public';
                allowedReaders =
                    (secData['allowedReaders'] as List<dynamic>?)
                        ?.cast<String>() ??
                    [];
              }
            } catch (_) {}
          }

          // Create a SharedFolder entry
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
