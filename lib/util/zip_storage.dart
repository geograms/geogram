/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../services/log_service.dart';
import '../services/profile_storage.dart';

/// ProfileStorage implementation backed by a ZIP archive on disk.
///
/// Keeps the decoded [Archive] in memory and provides filesystem-like CRUD.
/// Call [flush] to write the in-memory state back to the ZIP file on disk.
///
/// Usage:
/// ```dart
/// final storage = await ZipProfileStorage.open('/path/to/archive.ndf');
/// await storage.writeString('content/main.json', jsonString);
/// await storage.flush();
/// await storage.close();
/// ```
class ZipProfileStorage extends ProfileStorage {
  final String _filePath;
  Archive _archive;
  bool _dirty = false;
  final LogService _log = LogService();

  ZipProfileStorage._(this._filePath, this._archive);

  /// Open an existing ZIP file or create a new empty archive.
  static Future<ZipProfileStorage> open(String filePath) async {
    final file = File(filePath);
    Archive archive;
    if (await file.exists()) {
      final bytes = await file.readAsBytes();
      archive = ZipDecoder().decodeBytes(bytes);
    } else {
      archive = Archive();
    }
    return ZipProfileStorage._(filePath, archive);
  }

  /// The on-disk path of this ZIP file.
  @override
  String get basePath => _filePath;

  @override
  bool get isEncrypted => false;

  /// Whether in-memory state differs from what is on disk.
  bool get isDirty => _dirty;

  // ============ File Operations ============

  @override
  Future<String?> readString(String relativePath) async {
    final bytes = await readBytes(relativePath);
    if (bytes == null) return null;
    try {
      return utf8.decode(bytes);
    } catch (e) {
      _log.log('ZipStorage: Error decoding $relativePath as string: $e');
      return null;
    }
  }

  @override
  Future<Uint8List?> readBytes(String relativePath) async {
    final normalized = _normalizePath(relativePath);
    for (final entry in _archive) {
      if (_normalizePath(entry.name) == normalized && entry.isFile) {
        return Uint8List.fromList(entry.content as List<int>);
      }
    }
    return null;
  }

  @override
  Future<void> writeString(String relativePath, String content) async {
    await writeBytes(
      relativePath,
      Uint8List.fromList(utf8.encode(content)),
    );
  }

  @override
  Future<void> appendString(String relativePath, String content) async {
    final existing = await readString(relativePath);
    final combined = (existing ?? '') + content;
    await writeString(relativePath, combined);
  }

  @override
  Future<void> writeBytes(String relativePath, Uint8List bytes) async {
    final normalized = _normalizePath(relativePath);
    _removeEntry(normalized);
    _archive.addFile(ArchiveFile(normalized, bytes.length, bytes));
    _dirty = true;
  }

  @override
  Future<bool> exists(String relativePath) async {
    final normalized = _normalizePath(relativePath);
    return _archive.any(
      (e) => _normalizePath(e.name) == normalized && e.isFile,
    );
  }

  @override
  Future<void> delete(String relativePath) async {
    final normalized = _normalizePath(relativePath);
    if (_removeEntry(normalized)) {
      _dirty = true;
    }
  }

  @override
  Future<void> copyFromExternal(
    String externalPath,
    String relativePath,
  ) async {
    final file = File(externalPath);
    final bytes = await file.readAsBytes();
    final modTime = await file.lastModified();
    final normalized = _normalizePath(relativePath);
    _removeEntry(normalized);
    final archiveFile = ArchiveFile(normalized, bytes.length, bytes);
    archiveFile.lastModTime = modTime.millisecondsSinceEpoch ~/ 1000;
    _archive.addFile(archiveFile);
    _dirty = true;
  }

  @override
  Future<void> copyToExternal(
    String relativePath,
    String externalPath,
  ) async {
    final bytes = await readBytes(relativePath);
    if (bytes == null) {
      throw Exception('File not found in ZIP storage: $relativePath');
    }
    final file = File(externalPath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  // ============ Directory Operations ============

  @override
  Future<List<StorageEntry>> listDirectory(
    String relativePath, {
    bool recursive = false,
  }) async {
    final prefix = _normalizePath(relativePath);
    final prefixWithSlash = prefix.isEmpty ? '' : '$prefix/';
    final seen = <String>{};
    final entries = <StorageEntry>[];

    for (final archiveEntry in _archive) {
      final name = _normalizePath(archiveEntry.name);
      if (!name.startsWith(prefixWithSlash)) continue;

      final remainder = name.substring(prefixWithSlash.length);
      if (remainder.isEmpty) continue;

      if (recursive) {
        if (archiveEntry.isFile && seen.add(name)) {
          entries.add(StorageEntry(
            name: p.basename(name),
            path: name,
            isDirectory: false,
            size: archiveEntry.size,
            modified: DateTime.fromMillisecondsSinceEpoch(
                archiveEntry.lastModTime * 1000),
          ));
        }
      } else {
        // Non-recursive: only direct children
        final slashIndex = remainder.indexOf('/');
        if (slashIndex == -1) {
          // Direct file child
          if (seen.add(name)) {
            entries.add(StorageEntry(
              name: p.basename(name),
              path: name,
              isDirectory: false,
              size: archiveEntry.size,
              modified: DateTime.fromMillisecondsSinceEpoch(
                archiveEntry.lastModTime * 1000),
            ));
          }
        } else {
          // Synthesize directory entry for the immediate subdirectory
          final dirName = remainder.substring(0, slashIndex);
          final dirPath =
              prefixWithSlash.isEmpty ? dirName : '$prefixWithSlash$dirName';
          if (seen.add(dirPath)) {
            entries.add(StorageEntry(
              name: dirName,
              path: dirPath,
              isDirectory: true,
            ));
          }
        }
      }
    }

    return entries;
  }

  @override
  Future<void> createDirectory(String relativePath) async {
    // Directories are implicit in ZIP — no-op
  }

  @override
  Future<bool> directoryExists(String relativePath) async {
    final prefix = _normalizePath(relativePath);
    final prefixWithSlash = '$prefix/';
    return _archive.any((e) => _normalizePath(e.name).startsWith(prefixWithSlash));
  }

  @override
  Future<void> deleteDirectory(
    String relativePath, {
    bool recursive = false,
  }) async {
    final prefix = _normalizePath(relativePath);
    final prefixWithSlash = '$prefix/';

    if (!recursive) {
      final children =
          _archive.where((e) => _normalizePath(e.name).startsWith(prefixWithSlash));
      if (children.isNotEmpty) {
        throw Exception('Directory not empty: $relativePath');
      }
      return;
    }

    final toRemove = _archive
        .where((e) => _normalizePath(e.name).startsWith(prefixWithSlash))
        .map((e) => e.name)
        .toList();
    for (final name in toRemove) {
      _removeEntry(_normalizePath(name));
    }
    if (toRemove.isNotEmpty) {
      _dirty = true;
    }
  }

  // ============ Convenience ============

  @override
  String getAbsolutePath(String relativePath) {
    if (relativePath.isEmpty) return _filePath;
    return '$_filePath!/$relativePath';
  }

  // ============ Flush / Close ============

  /// Write the in-memory archive to disk as a ZIP file.
  Future<void> flush() async {
    if (!_dirty) return;
    final zipData = ZipEncoder().encode(_archive);
    if (zipData == null) {
      throw Exception('Failed to encode ZIP archive');
    }
    final file = File(_filePath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(zipData, flush: true);
    _dirty = false;
  }

  /// Flush if dirty, then release the in-memory archive.
  Future<void> close() async {
    await flush();
    _archive = Archive();
  }

  // ============ Helpers ============

  /// Normalize a path: strip leading/trailing slashes, collapse separators.
  String _normalizePath(String path) {
    var normalized = path.replaceAll('\\', '/');
    while (normalized.startsWith('/')) {
      normalized = normalized.substring(1);
    }
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  /// Remove an entry by normalized name. Returns true if found.
  bool _removeEntry(String normalized) {
    final index = _archive.toList().indexWhere(
      (e) => _normalizePath(e.name) == normalized,
    );
    if (index >= 0) {
      final newArchive = Archive();
      final entries = _archive.toList();
      for (var i = 0; i < entries.length; i++) {
        if (i != index) {
          newArchive.addFile(entries[i]);
        }
      }
      _archive = newArchive;
      return true;
    }
    return false;
  }
}
