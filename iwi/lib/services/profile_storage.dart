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

/// In-memory profile storage. Keeps every write in a `Map<String,
/// Uint8List>` for the lifetime of the process. Used as the web
/// backend where no real filesystem exists, and as a unit-test
/// fixture for any other environment that wants an isolated store
/// without touching disk.
///
/// Paths are forward-slash separated (just like the abstract
/// interface). Directories are implicit — any path with more than
/// one slash segment implies its parents exist, so `listDirectory`
/// and `directoryExists` walk the flat key space and synthesise
/// directory entries on demand.
///
/// Subclasses can override [onMutate] to react to every write /
/// delete — the web backend uses that hook to flush the file table
/// into `localStorage` so user data survives page reloads.
class MemoryProfileStorage extends ProfileStorage {
  final String _basePath;
  final Map<String, Uint8List> _files = {};

  MemoryProfileStorage({String basePath = '/mem'})
      : _basePath = _stripTrailingSlash(basePath);

  /// Read-only view of the in-memory file map. Subclasses (e.g. the
  /// localStorage-backed web variant) use this to serialise the
  /// whole store after every mutation.
  Map<String, Uint8List> get files => _files;

  /// Bulk-seed the file map from a `path → bytes` snapshot. Used by
  /// the localStorage hydrator on startup.
  void bulkLoad(Map<String, Uint8List> snapshot) {
    _files
      ..clear()
      ..addAll(snapshot);
  }

  /// Hook fired after every mutating operation (write, append,
  /// delete, deleteDirectory, sync variants). Default is a no-op;
  /// the web backend overrides it to persist to localStorage.
  void onMutate() {}

  static String _stripTrailingSlash(String p) {
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  String _normalize(String relativePath) {
    var p = relativePath.replaceAll('\\', '/');
    while (p.startsWith('/')) {
      p = p.substring(1);
    }
    while (p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  @override
  String get basePath => _basePath;

  @override
  bool get isEncrypted => false;

  @override
  String getAbsolutePath(String relativePath) {
    final p = _normalize(relativePath);
    return p.isEmpty ? _basePath : '$_basePath/$p';
  }

  // ── File ops ──────────────────────────────────────────────────

  @override
  Future<String?> readString(String relativePath) async {
    final bytes = _files[_normalize(relativePath)];
    if (bytes == null) return null;
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Uint8List?> readBytes(String relativePath) async =>
      _files[_normalize(relativePath)];

  @override
  Future<void> writeString(String relativePath, String content) async {
    _files[_normalize(relativePath)] =
        Uint8List.fromList(utf8.encode(content));
    onMutate();
  }

  @override
  Future<void> writeBytes(String relativePath, Uint8List bytes) async {
    _files[_normalize(relativePath)] = Uint8List.fromList(bytes);
    onMutate();
  }

  @override
  Future<void> appendString(String relativePath, String content) async {
    final key = _normalize(relativePath);
    final existing = _files[key];
    final newBytes = utf8.encode(content);
    if (existing == null) {
      _files[key] = Uint8List.fromList(newBytes);
    } else {
      final merged = Uint8List(existing.length + newBytes.length)
        ..setRange(0, existing.length, existing)
        ..setRange(existing.length, existing.length + newBytes.length, newBytes);
      _files[key] = merged;
    }
    onMutate();
  }

  @override
  Future<bool> exists(String relativePath) async =>
      _files.containsKey(_normalize(relativePath));

  @override
  Future<void> delete(String relativePath) async {
    if (_files.remove(_normalize(relativePath)) != null) onMutate();
  }

  @override
  Future<void> copyFromExternal(
      String externalPath, String relativePath) async {
    throw UnsupportedError(
        'copyFromExternal not supported on MemoryProfileStorage');
  }

  @override
  Future<void> copyToExternal(
      String relativePath, String externalPath) async {
    throw UnsupportedError(
        'copyToExternal not supported on MemoryProfileStorage');
  }

  // ── Directory ops ─────────────────────────────────────────────

  @override
  Future<List<StorageEntry>> listDirectory(String relativePath,
      {bool recursive = false}) async {
    final prefix = _normalize(relativePath);
    final prefixWithSlash = prefix.isEmpty ? '' : '$prefix/';
    final out = <StorageEntry>[];
    final seenDirs = <String>{};
    for (final key in _files.keys) {
      if (prefixWithSlash.isNotEmpty && !key.startsWith(prefixWithSlash)) {
        continue;
      }
      if (prefix.isNotEmpty && key == prefix) continue;
      final tail =
          prefixWithSlash.isEmpty ? key : key.substring(prefixWithSlash.length);
      if (!recursive && tail.contains('/')) {
        final dirName = tail.substring(0, tail.indexOf('/'));
        if (seenDirs.add(dirName)) {
          out.add(StorageEntry(
            name: dirName,
            path: prefixWithSlash + dirName,
            isDirectory: true,
          ));
        }
        continue;
      }
      final bytes = _files[key];
      out.add(StorageEntry(
        name: tail.split('/').last,
        path: key,
        isDirectory: false,
        size: bytes?.length,
      ));
    }
    return out;
  }

  @override
  Future<void> createDirectory(String relativePath) async {
    // Directories are implicit — nothing to do.
  }

  @override
  Future<bool> directoryExists(String relativePath) async {
    final prefix = _normalize(relativePath);
    if (prefix.isEmpty) return true;
    final withSlash = '$prefix/';
    return _files.keys
        .any((k) => k == prefix || k.startsWith(withSlash));
  }

  @override
  Future<void> deleteDirectory(String relativePath,
      {bool recursive = false}) async {
    final prefix = _normalize(relativePath);
    final withSlash = prefix.isEmpty ? '' : '$prefix/';
    final before = _files.length;
    _files.removeWhere((k, _) =>
        k == prefix || (withSlash.isNotEmpty && k.startsWith(withSlash)));
    if (_files.length != before) onMutate();
  }

  // ── Sync variants ─────────────────────────────────────────────

  @override
  Uint8List? readBytesSync(String relativePath) =>
      _files[_normalize(relativePath)];

  @override
  void writeStringSync(String relativePath, String content) {
    _files[_normalize(relativePath)] =
        Uint8List.fromList(utf8.encode(content));
    onMutate();
  }

  @override
  void writeBytesSync(String relativePath, Uint8List bytes) {
    _files[_normalize(relativePath)] = Uint8List.fromList(bytes);
    onMutate();
  }

  @override
  bool existsSync(String relativePath) =>
      _files.containsKey(_normalize(relativePath));
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
