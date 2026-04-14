/*
 * geogram filesystem abstraction
 *
 * Every storage operation in the geogram Flutter host must go through this
 * abstraction. No direct dart:io File/Directory calls anywhere else in
 * iwi/lib/ — not because dart:io is bad, but because the backing store may be
 * an encrypted SQLite archive, a browser IndexedDB tree, or (today) a plain
 * filesystem, and call sites should not care which.
 *
 * This file is API-compatible with the parent repo's
 * lib/services/profile_storage.dart so that when a shared package is
 * extracted later, migration is a single import change.
 */

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One entry returned by [ProfileStorage.listDirectory].
class StorageEntry {
  final String name;
  final String path; // relative to the storage base, forward-slash separated
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

/// Abstract filesystem interface. All paths are forward-slash relative strings
/// rooted at [basePath]. Backing implementations translate them as needed.
abstract class ProfileStorage {
  /// Base path for this storage (absolute on filesystem backends, virtual
  /// otherwise).
  String get basePath;

  /// Whether the backing store is encrypted.
  bool get isEncrypted;

  /// Resolve a relative path to an absolute/virtual path for logging.
  String getAbsolutePath(String relativePath);

  // ── Async file ops ────────────────────────────────────────────────────

  Future<String?> readString(String relativePath);
  Future<Uint8List?> readBytes(String relativePath);
  Future<void> writeString(String relativePath, String content);
  Future<void> writeBytes(String relativePath, Uint8List bytes);
  Future<void> appendString(String relativePath, String content);
  Future<bool> exists(String relativePath);
  Future<void> delete(String relativePath);
  Future<void> copyFromExternal(String externalPath, String relativePath);
  Future<void> copyToExternal(String relativePath, String externalPath);

  // ── Async directory ops ───────────────────────────────────────────────

  Future<List<StorageEntry>> listDirectory(String relativePath,
      {bool recursive = false});
  Future<void> createDirectory(String relativePath);
  Future<bool> directoryExists(String relativePath);
  Future<void> deleteDirectory(String relativePath, {bool recursive = false});

  // ── Sync ops for WASM HAL callbacks ───────────────────────────────────
  //
  // WASM imports run synchronously; Dart Futures cannot be awaited from
  // inside them. These sync variants exist only for those call sites.
  // Non-sync backends (encrypted SQLite, browser IndexedDB) throw
  // [UnsupportedError] — callers must fall back to a message-based async API
  // in that case.

  Uint8List? readBytesSync(String relativePath) =>
      throw UnsupportedError('readBytesSync not supported on $runtimeType');
  void writeStringSync(String relativePath, String content) =>
      throw UnsupportedError('writeStringSync not supported on $runtimeType');
  void writeBytesSync(String relativePath, Uint8List bytes) =>
      throw UnsupportedError('writeBytesSync not supported on $runtimeType');
  bool existsSync(String relativePath) =>
      throw UnsupportedError('existsSync not supported on $runtimeType');

  // ── JSON convenience ──────────────────────────────────────────────────

  Future<Map<String, dynamic>?> readJson(String relativePath) async {
    final content = await readString(relativePath);
    if (content == null) return null;
    try {
      final decoded = json.decode(content);
      if (decoded is Map<String, dynamic>) return decoded;
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> writeJson(
    String relativePath,
    Map<String, dynamic> data, {
    bool pretty = true,
  }) async {
    final content = pretty
        ? const JsonEncoder.withIndent('  ').convert(data)
        : json.encode(data);
    await writeString(relativePath, content);
  }
}

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

  // ── File ops ──────────────────────────────────────────────────────────

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
  Future<void> copyFromExternal(String externalPath, String relativePath) async {
    final dest = File(_resolve(relativePath));
    await dest.parent.create(recursive: true);
    await File(externalPath).copy(dest.path);
  }

  @override
  Future<void> copyToExternal(String relativePath, String externalPath) async {
    final src = File(_resolve(relativePath));
    final dest = File(externalPath);
    await dest.parent.create(recursive: true);
    await src.copy(dest.path);
  }

  // ── Directory ops ─────────────────────────────────────────────────────

  @override
  Future<List<StorageEntry>> listDirectory(String relativePath,
      {bool recursive = false}) async {
    final d = Directory(_resolve(relativePath));
    if (!await d.exists()) return [];
    final out = <StorageEntry>[];
    final sep = Platform.pathSeparator;
    final baseWithSep = _basePath.endsWith(sep) ? _basePath : '$_basePath$sep';
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

  // ── Sync variants ─────────────────────────────────────────────────────

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

/// Wraps another [ProfileStorage] under a path prefix. Every operation
/// forwards to the inner storage with the prefix prepended.
class ScopedProfileStorage extends ProfileStorage {
  final ProfileStorage _inner;
  final String _prefix;

  ScopedProfileStorage(this._inner, String prefix) : _prefix = _normalize(prefix);

  static String _normalize(String p) {
    while (p.startsWith('/')) {
      p = p.substring(1);
    }
    while (p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  String _prefixPath(String rel) {
    if (rel.isEmpty) return _prefix;
    if (_prefix.isEmpty) return rel;
    return '$_prefix/$rel';
  }

  String _stripPrefix(String path) {
    if (_prefix.isEmpty) return path;
    final withSlash = '$_prefix/';
    if (path.startsWith(withSlash)) return path.substring(withSlash.length);
    if (path == _prefix) return '';
    return path;
  }

  @override
  String get basePath => _inner.getAbsolutePath(_prefix);

  @override
  bool get isEncrypted => _inner.isEncrypted;

  @override
  String getAbsolutePath(String relativePath) =>
      _inner.getAbsolutePath(_prefixPath(relativePath));

  @override
  Future<String?> readString(String r) => _inner.readString(_prefixPath(r));

  @override
  Future<Uint8List?> readBytes(String r) => _inner.readBytes(_prefixPath(r));

  @override
  Future<void> writeString(String r, String c) =>
      _inner.writeString(_prefixPath(r), c);

  @override
  Future<void> writeBytes(String r, Uint8List b) =>
      _inner.writeBytes(_prefixPath(r), b);

  @override
  Future<void> appendString(String r, String c) =>
      _inner.appendString(_prefixPath(r), c);

  @override
  Future<bool> exists(String r) => _inner.exists(_prefixPath(r));

  @override
  Future<void> delete(String r) => _inner.delete(_prefixPath(r));

  @override
  Future<void> copyFromExternal(String e, String r) =>
      _inner.copyFromExternal(e, _prefixPath(r));

  @override
  Future<void> copyToExternal(String r, String e) =>
      _inner.copyToExternal(_prefixPath(r), e);

  @override
  Future<List<StorageEntry>> listDirectory(String r,
      {bool recursive = false}) async {
    final entries =
        await _inner.listDirectory(_prefixPath(r), recursive: recursive);
    return entries
        .map((e) => StorageEntry(
              name: e.name,
              path: _stripPrefix(e.path),
              isDirectory: e.isDirectory,
              size: e.size,
              modified: e.modified,
            ))
        .toList();
  }

  @override
  Future<void> createDirectory(String r) =>
      _inner.createDirectory(_prefixPath(r));

  @override
  Future<bool> directoryExists(String r) =>
      _inner.directoryExists(_prefixPath(r));

  @override
  Future<void> deleteDirectory(String r, {bool recursive = false}) =>
      _inner.deleteDirectory(_prefixPath(r), recursive: recursive);

  // ── Sync variants forward through ────────────────────────────────────

  @override
  Uint8List? readBytesSync(String relativePath) =>
      _inner.readBytesSync(_prefixPath(relativePath));

  @override
  void writeStringSync(String relativePath, String content) =>
      _inner.writeStringSync(_prefixPath(relativePath), content);

  @override
  void writeBytesSync(String relativePath, Uint8List bytes) =>
      _inner.writeBytesSync(_prefixPath(relativePath), bytes);

  @override
  bool existsSync(String relativePath) =>
      _inner.existsSync(_prefixPath(relativePath));
}
