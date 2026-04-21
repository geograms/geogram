/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * SQLite-backed file hash cache for fast mirror sync comparison.
 *
 * Instead of reading every file's bytes and computing SHA1 on every sync,
 * this service caches (sha1, tlsh, size, mtime) per file. Unchanged files
 * (same size + mtime) skip all I/O.
 */

import 'dart:async';
import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import '../models/mirror_config.dart';
import '../models/monitored_task.dart';
import '../util/task_monitor_helpers.dart';
import 'log_service.dart';
import 'profile_storage.dart';
import 'sqlite_loader.dart';

/// Cached file entry returned by [getFolderIndex].
typedef FileIndexEntry = ({int size, int mtime, String sha1});

class FileIndexService {
  Database? _db;

  FileIndexService(String dbPath) {
    _db = SQLiteLoader.openDatabase(dbPath);
    _initSchema();
  }

  void _initSchema() {
    final db = _db;
    if (db == null) return;

    db.execute('''
      CREATE TABLE IF NOT EXISTS file_index (
        folder TEXT NOT NULL,
        path TEXT NOT NULL,
        size INTEGER NOT NULL,
        mtime INTEGER NOT NULL,
        sha1 TEXT NOT NULL,
        tlsh TEXT,
        indexed_at INTEGER NOT NULL,
        PRIMARY KEY (folder, path)
      )
    ''');

    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_file_index_folder
      ON file_index(folder)
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS folder_meta (
        folder TEXT PRIMARY KEY,
        last_indexed_at INTEGER NOT NULL,
        file_count INTEGER NOT NULL DEFAULT 0
      )
    ''');
  }

  /// Returns cached SHA1 if size+mtime match, else null (cache miss).
  String? getHash(String folder, String path, int size, int mtime) {
    final db = _db;
    if (db == null) return null;

    final rows = db.select(
      'SELECT sha1 FROM file_index WHERE folder = ? AND path = ? AND size = ? AND mtime = ?',
      [folder, path, size, mtime],
    );
    if (rows.isEmpty) return null;
    return rows.first['sha1'] as String;
  }

  /// Upsert a file entry in the index.
  void putHash(
    String folder,
    String path,
    int size,
    int mtime,
    String sha1Hash, {
    String? tlsh,
  }) {
    final db = _db;
    if (db == null) return;

    db.execute(
      '''INSERT OR REPLACE INTO file_index (folder, path, size, mtime, sha1, tlsh, indexed_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)''',
      [
        folder,
        path,
        size,
        mtime,
        sha1Hash,
        tlsh,
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ],
    );
  }

  /// Bulk-load all entries for a folder (avoids N individual queries).
  Map<String, FileIndexEntry> getFolderIndex(String folder) {
    final db = _db;
    if (db == null) return {};

    final rows = db.select(
      'SELECT path, size, mtime, sha1 FROM file_index WHERE folder = ?',
      [folder],
    );

    final result = <String, FileIndexEntry>{};
    for (final row in rows) {
      result[row['path'] as String] = (
        size: row['size'] as int,
        mtime: row['mtime'] as int,
        sha1: row['sha1'] as String,
      );
    }
    return result;
  }

  /// Batch-upsert multiple file entries in a single transaction.
  void batchPutHashes(
    String folder,
    List<({String path, int size, int mtime, String sha1, String? tlsh})>
    entries,
  ) {
    final db = _db;
    if (db == null || entries.isEmpty) return;

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    db.execute('BEGIN');
    try {
      final stmt = db.prepare(
        '''INSERT OR REPLACE INTO file_index (folder, path, size, mtime, sha1, tlsh, indexed_at)
           VALUES (?, ?, ?, ?, ?, ?, ?)''',
      );
      for (final e in entries) {
        stmt.execute([folder, e.path, e.size, e.mtime, e.sha1, e.tlsh, now]);
      }
      stmt.dispose();
      db.execute('COMMIT');
    } catch (err) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Delete entries for files that no longer exist.
  void pruneFolder(String folder, Set<String> currentPaths) {
    final db = _db;
    if (db == null) return;

    final existing = db.select('SELECT path FROM file_index WHERE folder = ?', [
      folder,
    ]);

    final toDelete = existing
        .where((row) => !currentPaths.contains(row['path'] as String))
        .toList();
    if (toDelete.isEmpty) return;

    db.execute('BEGIN');
    try {
      final stmt = db.prepare(
        'DELETE FROM file_index WHERE folder = ? AND path = ?',
      );
      for (final row in toDelete) {
        stmt.execute([folder, row['path'] as String]);
      }
      stmt.dispose();
      db.execute('COMMIT');
    } catch (err) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Populate index from a received remote manifest (free data).
  ///
  /// [folder] is the folder name, [files] is a list of maps with keys:
  /// path, size, mtime, sha1.
  void importFromManifest(
    String folder,
    List<({String path, int size, int mtime, String sha1})> files,
  ) {
    final db = _db;
    if (db == null) return;

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    db.execute('BEGIN');
    try {
      final stmt = db.prepare(
        '''INSERT OR IGNORE INTO file_index (folder, path, size, mtime, sha1, tlsh, indexed_at)
           VALUES (?, ?, ?, ?, ?, NULL, ?)''',
      );
      for (final file in files) {
        stmt.execute([
          folder,
          file.path,
          file.size,
          file.mtime,
          file.sha1,
          now,
        ]);
      }
      stmt.dispose();
      db.execute('COMMIT');
    } catch (err) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Returns the most recent indexed_at timestamp for a folder, or null.
  int? getLastIndexedAt(String folder) {
    final db = _db;
    if (db == null) return null;

    final rows = db.select(
      'SELECT last_indexed_at FROM folder_meta WHERE folder = ?',
      [folder],
    );
    if (rows.isEmpty) return null;
    return rows.first['last_indexed_at'] as int;
  }

  /// Store per-folder "last fully indexed" timestamp + file count.
  void setFolderTimestamp(String folder, int timestamp, int fileCount) {
    final db = _db;
    if (db == null) return;

    db.execute(
      '''INSERT OR REPLACE INTO folder_meta (folder, last_indexed_at, file_count)
         VALUES (?, ?, ?)''',
      [folder, timestamp, fileCount],
    );
  }

  /// Get stored file count for a folder.
  int? getFolderFileCount(String folder) {
    final db = _db;
    if (db == null) return null;

    final rows = db.select(
      'SELECT file_count FROM folder_meta WHERE folder = ?',
      [folder],
    );
    if (rows.isEmpty) return null;
    return rows.first['file_count'] as int;
  }

  /// Scan a single folder, update changed entries, prune deleted files.
  ///
  /// [folder] is the folder name (e.g., "blog").
  /// [storage] is the ProfileStorage (already scoped to the callsign).
  Future<void> refreshFolder(String folder, ProfileStorage? storage) async {
    if (_db == null || storage == null) return;

    final exists = await storage.directoryExists(folder);
    if (!exists) return;

    final entries = await storage.listDirectory(folder, recursive: true);
    final currentPaths = <String>{};
    int fileCount = 0;

    final cachedIndex = getFolderIndex(folder);

    for (final entry in entries) {
      if (entry.isDirectory) continue;
      final fullRelPath = entry.path;
      final relativePath = fullRelPath.startsWith('$folder/')
          ? fullRelPath.substring(folder.length + 1)
          : fullRelPath;

      if (relativePath.startsWith('.')) continue;
      if (relativePath == 'log' || relativePath.startsWith('log/')) continue;

      fileCount++;
      currentPaths.add(relativePath);

      final entryMtime = (entry.modified?.millisecondsSinceEpoch ?? 0) ~/ 1000;
      final entrySize = entry.size ?? 0;

      // Dirty-check against cache
      final cached = cachedIndex[relativePath];
      if (cached != null &&
          cached.size == entrySize &&
          cached.mtime == entryMtime) {
        continue; // Cache hit — skip I/O
      }

      // Cache miss — read and hash
      try {
        final bytes = await storage.readBytes(fullRelPath);
        if (bytes == null) continue;
        final sha1Hash = sha1.convert(bytes).toString();
        putHash(folder, relativePath, entrySize, entryMtime, sha1Hash);
      } catch (e) {
        LogService().log('FileIndex: Error indexing $folder/$relativePath: $e');
      }
    }

    pruneFolder(folder, currentPaths);
    setFolderTimestamp(
      folder,
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      fileCount,
    );
  }

  void close() {
    _db?.dispose();
    _db = null;
  }

  // ---------------------------------------------------------------------------
  // Background indexing (singleton timer)
  // ---------------------------------------------------------------------------

  static MonitoredAsyncPeriodicTimer? _bgTimer;
  static FileIndexService? _bgInstance;
  static bool _bgRunning = false;

  /// Start hourly background indexing for the current profile.
  ///
  /// Creates a singleton timer that runs an initial index after a short delay,
  /// then re-indexes every hour. Only re-indexes folders whose files changed
  /// since the last scan (mtime-based).
  static void startBackgroundIndexing({
    required String dbPath,
    required ProfileStorage? storage,
    Duration interval = const Duration(hours: 1),
    Duration initialDelay = const Duration(seconds: 5),
  }) {
    stopBackgroundIndexing();

    _bgInstance = FileIndexService(dbPath);

    // Initial scan after short delay
    Timer(initialDelay, () {
      _runBackgroundScan(storage);
    });

    // Periodic scan
    _bgTimer = MonitoredAsyncPeriodicTimer(
      id: 'file_index.background_scan',
      name: 'File Index',
      description: 'Background file index scan',
      serviceName: 'FileIndexService',
      interval: interval,
      priority: TaskPriority.low,
      callback: (_) async => await _runBackgroundScan(storage),
    );

    LogService().log('FileIndex: background indexing started');
  }

  /// Stop background indexing and close the DB.
  static void stopBackgroundIndexing() {
    _bgTimer?.cancel();
    _bgTimer = null;
    _bgInstance?.close();
    _bgInstance = null;
    _bgRunning = false;
  }

  static Future<void> _runBackgroundScan(ProfileStorage? storage) async {
    final instance = _bgInstance;
    if (instance == null || _bgRunning) return;
    _bgRunning = true;

    try {
      int scanned = 0;
      int skipped = 0;

      for (final folder in kSyncableFolders) {
        if (instance._db == null) break; // Stopped while running

        // Quick change detection: check if folder needs re-indexing
        final needsReindex = await _folderNeedsReindex(
          instance,
          folder,
          storage,
        );
        if (!needsReindex) {
          skipped++;
          continue;
        }

        await instance.refreshFolder(folder, storage);
        scanned++;
      }

      LogService().log(
        'FileIndex: background scan complete — $scanned indexed, $skipped skipped',
      );
    } catch (e) {
      LogService().log('FileIndex: background scan error: $e');
    } finally {
      _bgRunning = false;
    }
  }

  /// Check if a folder needs re-indexing by comparing max mtime and file count.
  static Future<bool> _folderNeedsReindex(
    FileIndexService instance,
    String folder,
    ProfileStorage? storage,
  ) async {
    if (storage == null) return false;

    final exists = await storage.directoryExists(folder);
    if (!exists) return false;

    final entries = await storage.listDirectory(folder, recursive: true);
    int maxMtime = 0;
    int fileCount = 0;

    for (final entry in entries) {
      if (entry.isDirectory) continue;
      final relativePath = entry.path.startsWith('$folder/')
          ? entry.path.substring(folder.length + 1)
          : entry.path;
      if (relativePath.startsWith('.')) continue;
      if (relativePath == 'log' || relativePath.startsWith('log/')) continue;

      fileCount++;
      final mtime = (entry.modified?.millisecondsSinceEpoch ?? 0) ~/ 1000;
      if (mtime > maxMtime) maxMtime = mtime;
    }

    final lastIndexed = instance.getLastIndexedAt(folder);
    final storedCount = instance.getFolderFileCount(folder);

    // Needs re-index if: never indexed, file count changed, or newer files exist
    if (lastIndexed == null) return true;
    if (storedCount != fileCount) return true;
    if (maxMtime > lastIndexed) return true;

    return false;
  }
}
