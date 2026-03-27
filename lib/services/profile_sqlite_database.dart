import 'dart:io' if (dart.library.html) '../platform/io_stub.dart';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'log_service.dart';
import 'profile_storage.dart';
import 'sqlite_loader.dart';

/// Mirrors a profile-scoped SQLite file into a temporary native database.
///
/// `ProfileStorage` may be backed by the real filesystem or an encrypted
/// profile archive. SQLite still needs a native path, so this class extracts
/// the database to a temp file, opens it locally, and flushes checkpoints back
/// into the profile path.
class ProfileSQLiteDatabase {
  final ProfileStorage storage;
  final String relativePath;
  final String? tempLabel;
  final LogService _log = LogService();

  Database? _db;
  Directory? _tempDir;
  bool _dirty = false;

  ProfileSQLiteDatabase({
    required this.storage,
    required this.relativePath,
    this.tempLabel,
  });

  bool get isOpen => _db != null;

  String get storagePath => storage.getAbsolutePath(relativePath);

  String get _tempDirPath {
    final label = (tempLabel ?? p.basenameWithoutExtension(relativePath))
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-')
        .replaceAll(RegExp(r'-{2,}'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final resolvedLabel = label.isEmpty ? 'database' : label;
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    return p.join(
      Directory.systemTemp.path,
      'geogram',
      'profile-sqlite',
      '$resolvedLabel-$timestamp',
    );
  }

  String get _tempDatabasePath {
    final dir = _tempDir;
    if (dir == null) {
      throw StateError('ProfileSQLiteDatabase is not open');
    }
    final name = p.basename(relativePath);
    return p.join(dir.path, name.isEmpty ? 'database.sqlite3' : name);
  }

  Future<Database> open() async {
    if (_db != null) {
      return _db!;
    }

    final tempDir = Directory(_tempDirPath);
    await tempDir.create(recursive: true);
    _tempDir = tempDir;

    final tempDbFile = File(_tempDatabasePath);
    if (await storage.exists(relativePath)) {
      await storage.copyToExternal(relativePath, tempDbFile.path);
    } else {
      await tempDbFile.create(recursive: true);
    }

    final db = SQLiteLoader.openDatabase(tempDbFile.path);
    _configureDatabase(db);
    _db = db;
    _dirty = false;
    return db;
  }

  Future<T> read<T>(T Function(Database db) action) async {
    final db = await open();
    return action(db);
  }

  Future<T> write<T>(
    T Function(Database db) action, {
    bool flush = true,
  }) async {
    final db = await open();
    db.execute('BEGIN IMMEDIATE;');
    try {
      final result = action(db);
      db.execute('COMMIT;');
      _dirty = true;
      if (flush) {
        await this.flush();
      }
      return result;
    } catch (_) {
      try {
        db.execute('ROLLBACK;');
      } catch (_) {
        // Ignore rollback failures from already-aborted transactions.
      }
      rethrow;
    }
  }

  void markDirty() {
    _dirty = true;
  }

  Future<void> flush({bool force = false}) async {
    final db = _db;
    if (db == null) {
      return;
    }
    if (!_dirty && !force) {
      return;
    }

    db.execute('PRAGMA wal_checkpoint(TRUNCATE);');
    await storage.copyFromExternal(_tempDatabasePath, relativePath);
    _dirty = false;
  }

  Future<void> deleteStoredDatabase() async {
    await close();
    if (await storage.exists(relativePath)) {
      await storage.delete(relativePath);
    }
  }

  Future<void> close() async {
    final db = _db;
    if (db == null) {
      await _cleanupTempDir();
      return;
    }

    try {
      await flush();
    } finally {
      db.dispose();
      _db = null;
      await _cleanupTempDir();
    }
  }

  void _configureDatabase(Database db) {
    db.execute('PRAGMA foreign_keys = ON;');
    db.execute('PRAGMA journal_mode = WAL;');
    db.execute('PRAGMA synchronous = NORMAL;');
    db.execute('PRAGMA temp_store = MEMORY;');
    db.execute('PRAGMA busy_timeout = 5000;');
  }

  Future<void> _cleanupTempDir() async {
    final tempDir = _tempDir;
    _tempDir = null;
    if (tempDir == null) {
      return;
    }
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (error) {
      _log.log(
        'ProfileSQLiteDatabase: Failed to remove temp dir ${tempDir.path}: $error',
      );
    }
  }
}
