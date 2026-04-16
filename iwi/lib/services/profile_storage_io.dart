/*
 * Native (dart:io) ProfileStorage backend.
 *
 * Compiled only when `dart.library.io` is available. Exposes the
 * FilesystemProfileStorage concrete implementation plus a factory
 * that storage_paths.dart calls without knowing the platform —
 * the matching stub in `profile_storage_web.dart` returns a
 * MemoryProfileStorage instead.
 */

import 'dart:io';
import 'dart:typed_data';

import 'profile_storage.dart';

ProfileStorage makeFilesystemStorage(String basePath) =>
    FilesystemProfileStorage(basePath);

/// dart:io-backed filesystem storage. Rooted at an absolute path.
class FilesystemProfileStorage extends ProfileStorage {
  final String _basePath;

  FilesystemProfileStorage(String basePath)
      : _basePath = _stripTrailingSlash(basePath);

  static String _stripTrailingSlash(String p) {
    final sep = Platform.pathSeparator;
    while (p.length > 1 && (p.endsWith('/') || p.endsWith(sep))) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  String _resolve(String relativePath) {
    if (relativePath.isEmpty) return _basePath;
    final sep = Platform.pathSeparator;
    final native = relativePath.replaceAll('/', sep);
    if (native.startsWith(sep)) return '$_basePath$native';
    return '$_basePath$sep$native';
  }

  @override
  String get basePath => _basePath;

  @override
  bool get isEncrypted => false;

  @override
  String getAbsolutePath(String relativePath) => _resolve(relativePath);

  // ── File ops ──────────────────────────────────────────────────

  @override
  Future<String?> readString(String relativePath) async {
    final f = File(_resolve(relativePath));
    if (!await f.exists()) return null;
    try {
      return await f.readAsString();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Uint8List?> readBytes(String relativePath) async {
    final f = File(_resolve(relativePath));
    if (!await f.exists()) return null;
    try {
      return await f.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeString(String relativePath, String content) async {
    final f = File(_resolve(relativePath));
    await f.parent.create(recursive: true);
    await f.writeAsString(content);
  }

  @override
  Future<void> writeBytes(String relativePath, Uint8List bytes) async {
    final f = File(_resolve(relativePath));
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes);
  }

  @override
  Future<void> appendString(String relativePath, String content) async {
    final f = File(_resolve(relativePath));
    await f.parent.create(recursive: true);
    await f.writeAsString(content, mode: FileMode.append);
  }

  @override
  Future<bool> exists(String relativePath) =>
      File(_resolve(relativePath)).exists();

  @override
  Future<void> delete(String relativePath) async {
    final f = File(_resolve(relativePath));
    if (await f.exists()) await f.delete();
  }

  @override
  Future<void> copyFromExternal(
      String externalPath, String relativePath) async {
    final dest = File(_resolve(relativePath));
    await dest.parent.create(recursive: true);
    await File(externalPath).copy(dest.path);
  }

  @override
  Future<void> copyToExternal(
      String relativePath, String externalPath) async {
    final src = File(_resolve(relativePath));
    final dest = File(externalPath);
    await dest.parent.create(recursive: true);
    await src.copy(dest.path);
  }

  // ── Directory ops ─────────────────────────────────────────────

  @override
  Future<List<StorageEntry>> listDirectory(String relativePath,
      {bool recursive = false}) async {
    final d = Directory(_resolve(relativePath));
    if (!await d.exists()) return [];
    final out = <StorageEntry>[];
    final sep = Platform.pathSeparator;
    final baseWithSep =
        _basePath.endsWith(sep) ? _basePath : '$_basePath$sep';
    await for (final entity in d.list(recursive: recursive)) {
      FileStat stat;
      try {
        stat = await entity.stat();
      } catch (_) {
        continue;
      }
      var entryRel = entity.path;
      if (entryRel.startsWith(baseWithSep)) {
        entryRel = entryRel.substring(baseWithSep.length);
      }
      entryRel = entryRel.replaceAll(sep, '/');
      out.add(StorageEntry(
        name: entity.path.split(sep).last,
        path: entryRel,
        isDirectory: entity is Directory,
        size: entity is File ? stat.size : null,
        modified: stat.modified,
      ));
    }
    return out;
  }

  @override
  Future<void> createDirectory(String relativePath) async {
    await Directory(_resolve(relativePath)).create(recursive: true);
  }

  @override
  Future<bool> directoryExists(String relativePath) =>
      Directory(_resolve(relativePath)).exists();

  @override
  Future<void> deleteDirectory(String relativePath,
      {bool recursive = false}) async {
    final d = Directory(_resolve(relativePath));
    if (await d.exists()) await d.delete(recursive: recursive);
  }

  // ── Sync variants ─────────────────────────────────────────────

  @override
  Uint8List? readBytesSync(String relativePath) {
    final f = File(_resolve(relativePath));
    if (!f.existsSync()) return null;
    try {
      return f.readAsBytesSync();
    } catch (_) {
      return null;
    }
  }

  @override
  void writeStringSync(String relativePath, String content) {
    final f = File(_resolve(relativePath));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  @override
  void writeBytesSync(String relativePath, Uint8List bytes) {
    final f = File(_resolve(relativePath));
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(bytes);
  }

  @override
  bool existsSync(String relativePath) =>
      File(_resolve(relativePath)).existsSync();
}
