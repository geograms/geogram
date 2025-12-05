/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Native file system implementation using dart:io.
 * Used on Linux, Windows, macOS, Android, iOS.
 */

import 'dart:io';
import 'file_system_service.dart';

/// Factory function called by conditional import.
FileSystemService createFileSystemService() => NativeFileSystem();

/// Native file system implementation wrapping dart:io.
class NativeFileSystem implements FileSystemService {
  bool _initialized = false;

  @override
  Future<void> init() async {
    // Native file system requires no initialization
    _initialized = true;
  }

  @override
  bool get isInitialized => _initialized;

  @override
  Future<bool> exists(String path) async {
    return await FileSystemEntity.type(path) != FileSystemEntityType.notFound;
  }

  @override
  Future<bool> isFile(String path) => FileSystemEntity.isFile(path);

  @override
  Future<bool> isDirectory(String path) => FileSystemEntity.isDirectory(path);

  @override
  Future<String> readAsString(String path) => File(path).readAsString();

  @override
  Future<void> writeAsString(String path, String content) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  @override
  Future<List<int>> readAsBytes(String path) => File(path).readAsBytes();

  @override
  Future<void> writeAsBytes(String path, List<int> bytes) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
  }

  @override
  Future<List<FsEntity>> list(String path, {bool recursive = false}) async {
    final dir = Directory(path);
    if (!await dir.exists()) return [];

    final entities = <FsEntity>[];
    await for (final entity in dir.list(recursive: recursive, followLinks: false)) {
      entities.add(_toFsEntity(entity));
    }
    return entities;
  }

  @override
  Stream<FsEntity> listStream(String path, {bool recursive = false}) async* {
    final dir = Directory(path);
    if (!await dir.exists()) return;

    await for (final entity in dir.list(recursive: recursive, followLinks: false)) {
      yield _toFsEntity(entity);
    }
  }

  FsEntity _toFsEntity(FileSystemEntity entity) {
    FsEntityType type;
    if (entity is File) {
      type = FsEntityType.file;
    } else if (entity is Directory) {
      type = FsEntityType.directory;
    } else {
      type = FsEntityType.file; // Treat links as files
    }
    return FsEntity(path: entity.path, type: type);
  }

  @override
  Future<void> createDirectory(String path, {bool recursive = false}) async {
    await Directory(path).create(recursive: recursive);
  }

  @override
  Future<void> delete(String path, {bool recursive = false}) async {
    final type = await FileSystemEntity.type(path);
    if (type == FileSystemEntityType.notFound) return;

    if (type == FileSystemEntityType.directory) {
      await Directory(path).delete(recursive: recursive);
    } else {
      await File(path).delete();
    }
  }

  @override
  Future<FsStat> stat(String path) async {
    final stat = await FileStat.stat(path);
    return FsStat(
      size: stat.size,
      modified: stat.modified,
      accessed: stat.accessed,
      type: _toFsEntityType(stat.type),
    );
  }

  FsEntityType _toFsEntityType(FileSystemEntityType type) {
    switch (type) {
      case FileSystemEntityType.file:
        return FsEntityType.file;
      case FileSystemEntityType.directory:
        return FsEntityType.directory;
      default:
        return FsEntityType.notFound;
    }
  }

  @override
  Future<void> copy(String source, String destination) async {
    final sourceFile = File(source);
    if (!await sourceFile.exists()) {
      throw FileSystemException('Source file not found', source);
    }

    final destFile = File(destination);
    await destFile.parent.create(recursive: true);
    await sourceFile.copy(destination);
  }

  @override
  Future<void> move(String source, String destination) async {
    final type = await FileSystemEntity.type(source);
    if (type == FileSystemEntityType.notFound) {
      throw FileSystemException('Source not found', source);
    }

    // Ensure destination parent exists
    final destParent = Directory(parentPath(destination));
    await destParent.create(recursive: true);

    if (type == FileSystemEntityType.directory) {
      await Directory(source).rename(destination);
    } else {
      await File(source).rename(destination);
    }
  }

  @override
  String parentPath(String path) {
    final normalized = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    final lastSlash = normalized.lastIndexOf('/');
    if (lastSlash <= 0) return '/';
    return normalized.substring(0, lastSlash);
  }

  @override
  String joinPath(List<String> segments) {
    return segments
        .map((s) => s.replaceAll(RegExp(r'^/+|/+$'), ''))
        .where((s) => s.isNotEmpty)
        .join('/');
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
