/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Web file system implementation using fs_shim (IndexedDB backend).
 * Provides virtual file system for browser environment.
 */

import 'dart:async';
import 'dart:typed_data';
import 'package:fs_shim/fs_browser.dart' as fs_shim;
import 'file_system_service.dart';

/// Factory function called by conditional import.
FileSystemService createFileSystemService() => WebFileSystem();

/// Web file system implementation using fs_shim with IndexedDB backend.
///
/// This provides a virtual file system for web browsers, storing all
/// files and directories in IndexedDB. The API matches dart:io closely
/// to minimize changes needed in consuming code.
class WebFileSystem implements FileSystemService {
  fs_shim.FileSystem? _fs;
  bool _initialized = false;

  // Initialization lock to prevent multiple concurrent initializations
  Completer<void>? _initCompleter;

  @override
  Future<void> init() async {
    if (_initialized) return;

    // Handle concurrent init calls
    if (_initCompleter != null) {
      await _initCompleter!.future;
      return;
    }

    _initCompleter = Completer<void>();

    try {
      // Get the default browser file system backed by IndexedDB
      _fs = fs_shim.fileSystemIdb;
      _initialized = true;
      _initCompleter!.complete();
    } catch (e) {
      _initCompleter!.completeError(e);
      _initCompleter = null;
      rethrow;
    }
  }

  @override
  bool get isInitialized => _initialized;

  void _ensureInitialized() {
    if (!_initialized || _fs == null) {
      throw StateError('WebFileSystem not initialized. Call init() first.');
    }
  }

  @override
  Future<bool> exists(String path) async {
    _ensureInitialized();
    final normalizedPath = _normalizePath(path);

    // Check file first, then directory
    final file = _fs!.file(normalizedPath);
    if (await file.exists()) return true;

    final dir = _fs!.directory(normalizedPath);
    return await dir.exists();
  }

  @override
  Future<bool> isFile(String path) async {
    _ensureInitialized();
    final file = _fs!.file(_normalizePath(path));
    return await file.exists();
  }

  @override
  Future<bool> isDirectory(String path) async {
    _ensureInitialized();
    final dir = _fs!.directory(_normalizePath(path));
    return await dir.exists();
  }

  @override
  Future<String> readAsString(String path) async {
    _ensureInitialized();
    final file = _fs!.file(_normalizePath(path));
    return await file.readAsString();
  }

  @override
  Future<void> writeAsString(String path, String content) async {
    _ensureInitialized();
    final normalizedPath = _normalizePath(path);

    // Ensure parent directory exists
    await _ensureParentDirectory(normalizedPath);

    final file = _fs!.file(normalizedPath);
    await file.writeAsString(content);
  }

  @override
  Future<List<int>> readAsBytes(String path) async {
    _ensureInitialized();
    final file = _fs!.file(_normalizePath(path));
    return await file.readAsBytes();
  }

  @override
  Future<void> writeAsBytes(String path, List<int> bytes) async {
    _ensureInitialized();
    final normalizedPath = _normalizePath(path);

    // Ensure parent directory exists
    await _ensureParentDirectory(normalizedPath);

    final file = _fs!.file(normalizedPath);
    await file.writeAsBytes(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
  }

  @override
  Future<List<FsEntity>> list(String path, {bool recursive = false}) async {
    _ensureInitialized();
    final entities = <FsEntity>[];

    await for (final entity in listStream(path, recursive: recursive)) {
      entities.add(entity);
    }

    return entities;
  }

  @override
  Stream<FsEntity> listStream(String path, {bool recursive = false}) async* {
    _ensureInitialized();
    final normalizedPath = _normalizePath(path);
    final dir = _fs!.directory(normalizedPath);

    if (!await dir.exists()) return;

    await for (final entity in dir.list(recursive: recursive, followLinks: false)) {
      yield _toFsEntity(entity);
    }
  }

  FsEntity _toFsEntity(fs_shim.FileSystemEntity entity) {
    FsEntityType type;
    if (entity is fs_shim.File) {
      type = FsEntityType.file;
    } else if (entity is fs_shim.Directory) {
      type = FsEntityType.directory;
    } else {
      type = FsEntityType.file;
    }
    return FsEntity(path: entity.path, type: type);
  }

  @override
  Future<void> createDirectory(String path, {bool recursive = false}) async {
    _ensureInitialized();
    final dir = _fs!.directory(_normalizePath(path));
    await dir.create(recursive: recursive);
  }

  @override
  Future<void> delete(String path, {bool recursive = false}) async {
    _ensureInitialized();
    final normalizedPath = _normalizePath(path);

    // Check if it's a file first
    final file = _fs!.file(normalizedPath);
    if (await file.exists()) {
      await file.delete();
      return;
    }

    // Otherwise try as directory
    final dir = _fs!.directory(normalizedPath);
    if (await dir.exists()) {
      await dir.delete(recursive: recursive);
    }
  }

  @override
  Future<FsStat> stat(String path) async {
    _ensureInitialized();
    final normalizedPath = _normalizePath(path);

    // Check file first
    final file = _fs!.file(normalizedPath);
    if (await file.exists()) {
      final stat = await file.stat();
      return FsStat(
        size: stat.size,
        modified: stat.modified,
        accessed: stat.modified, // fs_shim may not have separate accessed time
        type: FsEntityType.file,
      );
    }

    // Check directory
    final dir = _fs!.directory(normalizedPath);
    if (await dir.exists()) {
      final stat = await dir.stat();
      return FsStat(
        size: stat.size,
        modified: stat.modified,
        accessed: stat.modified,
        type: FsEntityType.directory,
      );
    }

    return FsStat.notFound();
  }

  @override
  Future<void> copy(String source, String destination) async {
    _ensureInitialized();
    final sourcePath = _normalizePath(source);
    final destPath = _normalizePath(destination);

    final sourceFile = _fs!.file(sourcePath);
    if (!await sourceFile.exists()) {
      throw Exception('Source file not found: $source');
    }

    await _ensureParentDirectory(destPath);

    // Read and write (fs_shim may not have direct copy)
    final content = await sourceFile.readAsBytes();
    final destFile = _fs!.file(destPath);
    await destFile.writeAsBytes(content);
  }

  @override
  Future<void> move(String source, String destination) async {
    _ensureInitialized();
    final sourcePath = _normalizePath(source);
    final destPath = _normalizePath(destination);

    await _ensureParentDirectory(destPath);

    // Check if source is a file
    final sourceFile = _fs!.file(sourcePath);
    if (await sourceFile.exists()) {
      await sourceFile.rename(destPath);
      return;
    }

    // Try as directory
    final sourceDir = _fs!.directory(sourcePath);
    if (await sourceDir.exists()) {
      await sourceDir.rename(destPath);
      return;
    }

    throw Exception('Source not found: $source');
  }

  /// Normalize path to ensure consistency.
  String _normalizePath(String path) {
    // Ensure path starts with /
    var normalized = path.startsWith('/') ? path : '/$path';

    // Remove trailing slash (except for root)
    if (normalized.length > 1 && normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }

    // Collapse multiple slashes
    normalized = normalized.replaceAll(RegExp(r'/+'), '/');

    return normalized;
  }

  /// Ensure parent directory exists for a file path.
  Future<void> _ensureParentDirectory(String path) async {
    final parent = parentPath(path);
    if (parent != '/' && parent.isNotEmpty) {
      final dir = _fs!.directory(parent);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
    }
  }

  @override
  String parentPath(String path) {
    final normalized = _normalizePath(path);
    final lastSlash = normalized.lastIndexOf('/');
    if (lastSlash <= 0) return '/';
    return normalized.substring(0, lastSlash);
  }

  @override
  String joinPath(List<String> segments) {
    final joined = segments
        .map((s) => s.replaceAll(RegExp(r'^/+|/+$'), ''))
        .where((s) => s.isNotEmpty)
        .join('/');
    return '/$joined';
  }

  @override
  String fileName(String path) {
    return path.split('/').last;
  }

  @override
  String extension(String path) {
    final name = fileName(path);
    final lastDot = name.lastIndexOf('.');
    if (lastDot == -1 || lastDot == 0) return '';
    return name.substring(lastDot);
  }
}
