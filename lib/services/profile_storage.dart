/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../platform/file_system_service.dart';
// Use stub for CLI/pure Dart builds and web, real implementation for native Flutter
import 'encrypted_storage_stub.dart' if (dart.library.io) 'encrypted_storage_service.dart';
import 'log_service.dart';

/// Entry in a storage directory listing
class StorageEntry {
  final String name;
  final String path;
  final bool isDirectory;
  final int? size;
  final DateTime? modified;

  StorageEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.size,
    this.modified,
  });

  @override
  String toString() => 'StorageEntry($path, isDir: $isDirectory)';
}

/// Abstract interface for profile storage operations.
///
/// This abstraction allows services to work transparently with both
/// filesystem storage and encrypted archive storage.
abstract class ProfileStorage {
  /// The base path for this storage (profile directory or archive path)
  String get basePath;

  /// Whether this storage is encrypted
  bool get isEncrypted;

  // ============ File Operations ============

  /// Read a file as a string
  /// Returns null if the file doesn't exist
  Future<String?> readString(String relativePath);

  /// Read a file as bytes
  /// Returns null if the file doesn't exist
  Future<Uint8List?> readBytes(String relativePath);

  /// Write a string to a file
  /// Creates parent directories if needed
  Future<void> writeString(String relativePath, String content);

  /// Append a string to an existing file
  /// Creates the file if it doesn't exist
  Future<void> appendString(String relativePath, String content);

  /// Write bytes to a file
  /// Creates parent directories if needed
  Future<void> writeBytes(String relativePath, Uint8List bytes);

  /// Check if a file exists
  Future<bool> exists(String relativePath);

  /// Delete a file
  Future<void> delete(String relativePath);

  /// Copy a file from an external path into storage
  Future<void> copyFromExternal(String externalPath, String relativePath);

  /// Copy a file from storage to an external path
  Future<void> copyToExternal(String relativePath, String externalPath);

  // ============ Directory Operations ============

  /// List entries in a directory
  /// Returns empty list if directory doesn't exist
  Future<List<StorageEntry>> listDirectory(String relativePath, {bool recursive = false});

  /// Create a directory (and parents if needed)
  Future<void> createDirectory(String relativePath);

  /// Check if a directory exists
  Future<bool> directoryExists(String relativePath);

  /// Delete a directory
  Future<void> deleteDirectory(String relativePath, {bool recursive = false});

  // ============ Convenience Methods ============

  /// Get the absolute path for a relative path
  /// For encrypted storage, this returns a virtual path
  String getAbsolutePath(String relativePath);

  /// Read a JSON file and decode it
  Future<Map<String, dynamic>?> readJson(String relativePath) async {
    final content = await readString(relativePath);
    if (content == null) return null;
    try {
      return json.decode(content) as Map<String, dynamic>;
    } catch (e) {
      return null;
    }
  }

  /// Write a JSON object to a file
  Future<void> writeJson(String relativePath, Map<String, dynamic> data, {bool pretty = true}) async {
    final content = pretty
        ? const JsonEncoder.withIndent('  ').convert(data)
        : json.encode(data);
    await writeString(relativePath, content);
  }
}

/// Filesystem-based storage implementation
///
/// Wraps FileSystemService for platform-agnostic file operations.
/// Works on native (dart:io) and web (IndexedDB via fs_shim).
class FilesystemProfileStorage extends ProfileStorage {
  final String _basePath;
  final LogService _log = LogService();

  FileSystemService get _fs => FileSystemService.instance;

  FilesystemProfileStorage(this._basePath);

  @override
  String get basePath => p.normalize(_basePath);

  @override
  bool get isEncrypted => false;

  @override
  String getAbsolutePath(String relativePath) {
    if (relativePath.isEmpty) return _basePath;
    return p.normalize(p.join(_basePath, relativePath));
  }

  @override
  Future<String?> readString(String relativePath) async {
    final path = getAbsolutePath(relativePath);
    if (!await _fs.exists(path)) return null;
    try {
      return await _fs.readAsString(path);
    } catch (e) {
      _log.log('FilesystemStorage: Error reading $relativePath: $e');
      return null;
    }
  }

  @override
  Future<Uint8List?> readBytes(String relativePath) async {
    final path = getAbsolutePath(relativePath);
    if (!await _fs.exists(path)) return null;
    try {
      final bytes = await _fs.readAsBytes(path);
      return Uint8List.fromList(bytes);
    } catch (e) {
      _log.log('FilesystemStorage: Error reading bytes $relativePath: $e');
      return null;
    }
  }

  @override
  Future<void> writeString(String relativePath, String content) async {
    final path = getAbsolutePath(relativePath);
    await _fs.createDirectory(_fs.parentPath(path), recursive: true);
    await _fs.writeAsString(path, content);
  }

  @override
  Future<void> appendString(String relativePath, String content) async {
    final path = getAbsolutePath(relativePath);
    await _fs.createDirectory(_fs.parentPath(path), recursive: true);
    String existing = '';
    if (await _fs.exists(path)) {
      existing = await _fs.readAsString(path);
    }
    await _fs.writeAsString(path, existing + content);
  }

  @override
  Future<void> writeBytes(String relativePath, Uint8List bytes) async {
    final path = getAbsolutePath(relativePath);
    await _fs.createDirectory(_fs.parentPath(path), recursive: true);
    await _fs.writeAsBytes(path, bytes);
  }

  @override
  Future<bool> exists(String relativePath) async {
    return _fs.exists(getAbsolutePath(relativePath));
  }

  @override
  Future<void> delete(String relativePath) async {
    final path = getAbsolutePath(relativePath);
    if (await _fs.exists(path)) {
      await _fs.delete(path);
    }
  }

  @override
  Future<void> copyFromExternal(String externalPath, String relativePath) async {
    final destPath = getAbsolutePath(relativePath);
    await _fs.createDirectory(_fs.parentPath(destPath), recursive: true);
    await _fs.copy(externalPath, destPath);
  }

  @override
  Future<void> copyToExternal(String relativePath, String externalPath) async {
    final sourcePath = getAbsolutePath(relativePath);
    await _fs.createDirectory(_fs.parentPath(externalPath), recursive: true);
    await _fs.copy(sourcePath, externalPath);
  }

  @override
  Future<List<StorageEntry>> listDirectory(String relativePath, {bool recursive = false}) async {
    final dirPath = getAbsolutePath(relativePath);
    if (!await _fs.isDirectory(dirPath)) return [];

    final entities = await _fs.list(dirPath, recursive: recursive);
    final entries = <StorageEntry>[];
    for (final entity in entities) {
      final stat = await _fs.stat(entity.path);
      final entityRelPath = p.relative(entity.path, from: _basePath);
      entries.add(StorageEntry(
        name: p.basename(entity.path),
        path: entityRelPath,
        isDirectory: entity.isDirectory,
        size: stat.size,
        modified: stat.modified,
      ));
    }
    return entries;
  }

  @override
  Future<void> createDirectory(String relativePath) async {
    await _fs.createDirectory(getAbsolutePath(relativePath), recursive: true);
  }

  @override
  Future<bool> directoryExists(String relativePath) async {
    return _fs.isDirectory(getAbsolutePath(relativePath));
  }

  @override
  Future<void> deleteDirectory(String relativePath, {bool recursive = false}) async {
    final dirPath = getAbsolutePath(relativePath);
    if (await _fs.isDirectory(dirPath)) {
      await _fs.delete(dirPath, recursive: recursive);
    }
  }
}

/// Encrypted archive-based storage implementation
///
/// Wraps EncryptedStorageService for reading/writing to encrypted archive
class EncryptedProfileStorage extends ProfileStorage {
  final String _callsign;
  final String _nsec;
  final String _basePath; // Virtual base path (profile directory)
  final EncryptedStorageService _encryptedService;
  final LogService _log = LogService();

  EncryptedProfileStorage({
    required String callsign,
    required String nsec,
    required String basePath,
    EncryptedStorageService? encryptedService,
  })  : _callsign = callsign,
        _nsec = nsec,
        _basePath = basePath,
        _encryptedService = encryptedService ?? EncryptedStorageService();

  @override
  String get basePath => p.normalize(_basePath);

  @override
  bool get isEncrypted => true;

  @override
  String getAbsolutePath(String relativePath) {
    // Return virtual path for encrypted storage
    if (relativePath.isEmpty) return _basePath;
    return p.normalize(p.join(_basePath, relativePath));
  }

  @override
  Future<String?> readString(String relativePath) async {
    final bytes = await readBytes(relativePath);
    if (bytes == null) return null;
    try {
      return utf8.decode(bytes);
    } catch (e) {
      _log.log('EncryptedStorage: Error decoding $relativePath as string: $e');
      return null;
    }
  }

  @override
  Future<Uint8List?> readBytes(String relativePath) async {
    return _encryptedService.readFile(_callsign, _nsec, relativePath);
  }

  @override
  Future<void> writeString(String relativePath, String content) async {
    await writeBytes(relativePath, Uint8List.fromList(utf8.encode(content)));
  }

  @override
  Future<void> appendString(String relativePath, String content) async {
    // Encrypted storage can't do atomic append — read-modify-write fallback
    final existing = await readString(relativePath);
    final combined = (existing ?? '') + content;
    await writeString(relativePath, combined);
  }

  @override
  Future<void> writeBytes(String relativePath, Uint8List bytes) async {
    final success = await _encryptedService.writeFile(_callsign, _nsec, relativePath, bytes);
    if (!success) {
      throw Exception('Failed to write to encrypted storage: $relativePath');
    }
  }

  @override
  Future<bool> exists(String relativePath) async {
    return _encryptedService.fileExists(_callsign, _nsec, relativePath);
  }

  @override
  Future<void> delete(String relativePath) async {
    await _encryptedService.deleteFile(_callsign, _nsec, relativePath);
  }

  @override
  Future<void> copyFromExternal(String externalPath, String relativePath) async {
    final fs = FileSystemService.instance;
    final bytes = await fs.readAsBytes(externalPath);
    await writeBytes(relativePath, Uint8List.fromList(bytes));
  }

  @override
  Future<void> copyToExternal(String relativePath, String externalPath) async {
    final bytes = await readBytes(relativePath);
    if (bytes == null) {
      throw Exception('File not found in encrypted storage: $relativePath');
    }
    final fs = FileSystemService.instance;
    await fs.createDirectory(fs.parentPath(externalPath), recursive: true);
    await fs.writeAsBytes(externalPath, bytes);
  }

  @override
  Future<List<StorageEntry>> listDirectory(String relativePath, {bool recursive = false}) async {
    final entries = await _encryptedService.listDirectory(
      _callsign,
      _nsec,
      relativePath,
      recursive: recursive,
    );
    return entries ?? [];
  }

  @override
  Future<void> createDirectory(String relativePath) async {
    // Encrypted archives don't have explicit directories
    // They are created implicitly when files are added
    // This is a no-op for compatibility
  }

  @override
  Future<bool> directoryExists(String relativePath) async {
    // Check if any files exist with this prefix
    final entries = await listDirectory(relativePath);
    return entries.isNotEmpty;
  }

  @override
  Future<void> deleteDirectory(String relativePath, {bool recursive = false}) async {
    if (!recursive) {
      // Check if directory is empty
      final entries = await listDirectory(relativePath);
      if (entries.isNotEmpty) {
        throw Exception('Directory not empty: $relativePath');
      }
      return;
    }

    // Delete all files in directory
    final entries = await listDirectory(relativePath, recursive: true);
    for (final entry in entries) {
      if (!entry.isDirectory) {
        await delete(entry.path);
      }
    }
  }
}

/// Scoped storage that wraps another ProfileStorage with a path prefix.
///
/// This is useful when a service needs to operate within a specific collection
/// directory, using relative paths from that collection root.
///
/// Example:
/// ```dart
/// // Profile storage rooted at /devices/X1ABC123/
/// final profileStorage = AppService().profileStorage;
///
/// // Scoped storage rooted at /devices/X1ABC123/blog-xxx/
/// final blogStorage = ScopedProfileStorage(profileStorage, 'blog-xxx');
///
/// // Now blogStorage.readString('2024/post1/post.md') reads from
/// // /devices/X1ABC123/blog-xxx/2024/post1/post.md
/// ```
class ScopedProfileStorage extends ProfileStorage {
  final ProfileStorage _inner;
  final String _prefix;

  ScopedProfileStorage(this._inner, this._prefix);

  /// Create a scoped storage from an absolute collection path.
  ///
  /// Extracts the relative path by removing the base path prefix.
  factory ScopedProfileStorage.fromAbsolutePath(
    ProfileStorage baseStorage,
    String absoluteAppPath,
  ) {
    final basePath = baseStorage.basePath;
    String relativePath;

    if (absoluteAppPath.startsWith(basePath)) {
      relativePath = absoluteAppPath.substring(basePath.length);
      // Clean up leading/trailing slashes — handle both / and \
      while (relativePath.startsWith('/') || relativePath.startsWith('\\')) {
        relativePath = relativePath.substring(1);
      }
      while (relativePath.endsWith('/') || relativePath.endsWith('\\')) {
        relativePath = relativePath.substring(0, relativePath.length - 1);
      }
    } else {
      // Fallback: use last path component
      relativePath = p.basename(absoluteAppPath);
    }

    return ScopedProfileStorage(baseStorage, relativePath);
  }

  String _prefixPath(String relativePath) {
    if (relativePath.isEmpty) return _prefix;
    if (_prefix.isEmpty) return relativePath;
    return '$_prefix/$relativePath';
  }

  @override
  String get basePath => p.normalize(_inner.getAbsolutePath(_prefix));

  @override
  bool get isEncrypted => _inner.isEncrypted;

  @override
  String getAbsolutePath(String relativePath) {
    return _inner.getAbsolutePath(_prefixPath(relativePath));
  }

  @override
  Future<String?> readString(String relativePath) {
    return _inner.readString(_prefixPath(relativePath));
  }

  @override
  Future<Uint8List?> readBytes(String relativePath) {
    return _inner.readBytes(_prefixPath(relativePath));
  }

  @override
  Future<void> writeString(String relativePath, String content) {
    return _inner.writeString(_prefixPath(relativePath), content);
  }

  @override
  Future<void> appendString(String relativePath, String content) {
    return _inner.appendString(_prefixPath(relativePath), content);
  }

  @override
  Future<void> writeBytes(String relativePath, Uint8List bytes) {
    return _inner.writeBytes(_prefixPath(relativePath), bytes);
  }

  @override
  Future<bool> exists(String relativePath) {
    return _inner.exists(_prefixPath(relativePath));
  }

  @override
  Future<void> delete(String relativePath) {
    return _inner.delete(_prefixPath(relativePath));
  }

  @override
  Future<void> copyFromExternal(String externalPath, String relativePath) {
    return _inner.copyFromExternal(externalPath, _prefixPath(relativePath));
  }

  @override
  Future<void> copyToExternal(String relativePath, String externalPath) {
    return _inner.copyToExternal(_prefixPath(relativePath), externalPath);
  }

  @override
  Future<List<StorageEntry>> listDirectory(String relativePath, {bool recursive = false}) async {
    final entries = await _inner.listDirectory(_prefixPath(relativePath), recursive: recursive);
    // Adjust paths in entries to be relative to scope
    final prefixWithSlash = _prefix.isEmpty ? '' : '$_prefix/';
    return entries.map((e) {
      var path = e.path;
      if (path.startsWith(prefixWithSlash)) {
        path = path.substring(prefixWithSlash.length);
      } else if (path == _prefix) {
        path = '';
      }
      return StorageEntry(
        name: e.name,
        path: path,
        isDirectory: e.isDirectory,
        size: e.size,
        modified: e.modified,
      );
    }).toList();
  }

  @override
  Future<void> createDirectory(String relativePath) {
    return _inner.createDirectory(_prefixPath(relativePath));
  }

  @override
  Future<bool> directoryExists(String relativePath) {
    return _inner.directoryExists(_prefixPath(relativePath));
  }

  @override
  Future<void> deleteDirectory(String relativePath, {bool recursive = false}) {
    return _inner.deleteDirectory(_prefixPath(relativePath), recursive: recursive);
  }
}
