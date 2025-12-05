/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Platform-agnostic file system service abstraction.
 * Uses dart:io on native platforms and fs_shim (IndexedDB) on web.
 */

import 'file_system_native.dart' if (dart.library.html) 'file_system_web.dart'
    as platform;

/// File system entity type
enum FsEntityType {
  file,
  directory,
  notFound,
}

/// File statistics
class FsStat {
  final int size;
  final DateTime modified;
  final DateTime accessed;
  final FsEntityType type;

  FsStat({
    required this.size,
    required this.modified,
    required this.accessed,
    required this.type,
  });

  factory FsStat.notFound() => FsStat(
        size: 0,
        modified: DateTime.now(),
        accessed: DateTime.now(),
        type: FsEntityType.notFound,
      );
}

/// File system entity (file or directory)
class FsEntity {
  final String path;
  final FsEntityType type;
  final String name;

  FsEntity({
    required this.path,
    required this.type,
  }) : name = path.split('/').last;

  bool get isFile => type == FsEntityType.file;
  bool get isDirectory => type == FsEntityType.directory;
}

/// Abstract file system interface for cross-platform file operations.
///
/// This service provides a unified API for file system operations that works
/// on both native platforms (using dart:io) and web (using IndexedDB via fs_shim).
///
/// Usage:
/// ```dart
/// final fs = FileSystemService.instance;
/// await fs.init();
/// await fs.writeAsString('/path/to/file.txt', 'content');
/// final content = await fs.readAsString('/path/to/file.txt');
/// ```
abstract class FileSystemService {
  static FileSystemService? _instance;

  /// Get the singleton instance of the file system service.
  /// Creates the appropriate platform implementation on first access.
  static FileSystemService get instance {
    _instance ??= platform.createFileSystemService();
    return _instance!;
  }

  /// Initialize the file system service.
  /// Must be called before any other operations.
  /// This is fast (<50ms) and just sets up the storage backend.
  Future<void> init();

  /// Whether the file system has been initialized.
  bool get isInitialized;

  /// Check if a file or directory exists at the given path.
  Future<bool> exists(String path);

  /// Check if the path is a file.
  Future<bool> isFile(String path);

  /// Check if the path is a directory.
  Future<bool> isDirectory(String path);

  /// Read file contents as a string.
  Future<String> readAsString(String path);

  /// Write string content to a file.
  /// Creates parent directories if they don't exist.
  Future<void> writeAsString(String path, String content);

  /// Read file contents as bytes.
  Future<List<int>> readAsBytes(String path);

  /// Write bytes to a file.
  /// Creates parent directories if they don't exist.
  Future<void> writeAsBytes(String path, List<int> bytes);

  /// List directory contents.
  /// Returns a list of file system entities (files and directories).
  /// If [recursive] is true, lists all contents recursively.
  Future<List<FsEntity>> list(String path, {bool recursive = false});

  /// List directory contents as a stream for large directories.
  /// More memory efficient than [list] for directories with many entries.
  Stream<FsEntity> listStream(String path, {bool recursive = false});

  /// Create a directory at the given path.
  /// If [recursive] is true, creates parent directories as needed.
  Future<void> createDirectory(String path, {bool recursive = false});

  /// Delete a file or directory.
  /// If [recursive] is true and path is a directory, deletes all contents.
  Future<void> delete(String path, {bool recursive = false});

  /// Get file or directory statistics.
  Future<FsStat> stat(String path);

  /// Copy a file from source to destination.
  Future<void> copy(String source, String destination);

  /// Move or rename a file or directory.
  Future<void> move(String source, String destination);

  /// Get the parent directory path.
  String parentPath(String path) {
    final normalized = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    final lastSlash = normalized.lastIndexOf('/');
    if (lastSlash <= 0) return '/';
    return normalized.substring(0, lastSlash);
  }

  /// Join path segments.
  String joinPath(List<String> segments) {
    return segments
        .map((s) => s.replaceAll(RegExp(r'^/+|/+$'), ''))
        .where((s) => s.isNotEmpty)
        .join('/');
  }

  /// Get the file name from a path.
  String fileName(String path) {
    return path.split('/').last;
  }

  /// Get the file extension from a path.
  String extension(String path) {
    final name = fileName(path);
    final lastDot = name.lastIndexOf('.');
    if (lastDot == -1 || lastDot == 0) return '';
    return name.substring(lastDot);
  }
}
