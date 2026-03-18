/*
 * Copyright (c) geogram
 * License: Apache-2.0
 *
 * Local Backup Service — create/restore ZIP archives of the active profile.
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../models/local_backup_models.dart';
import '../models/monitored_task.dart';
import '../util/task_monitor_helpers.dart';
import 'app_service.dart';
import 'config_service.dart';
import 'log_service.dart';
import 'storage_config.dart';

/// Singleton service for local ZIP backup/restore of the active profile.
class LocalBackupService {
  static final LocalBackupService _instance = LocalBackupService._internal();
  factory LocalBackupService() => _instance;
  LocalBackupService._internal();

  bool _initialized = false;
  LocalBackupSettings _settings = LocalBackupSettings();
  LocalBackupStatus _status = LocalBackupStatus.idle();
  MonitoredAsyncPeriodicTimer? _autoBackupTimer;

  // --- Public getters ---

  LocalBackupSettings get settings => _settings;
  LocalBackupStatus get status => _status;
  bool get isAutoBackupRunning => _autoBackupTimer != null;

  // --- Lifecycle ---

  void initialize() {
    if (_initialized) return;
    _loadSettings();
    _initialized = true;
    _log('LocalBackupService initialized');

    if (_settings.autoBackupEnabled && _settings.backupFolderPath != null) {
      startAutoBackup();
    }
  }

  void dispose() {
    stopAutoBackup();
  }

  // --- Settings persistence ---

  void _loadSettings() {
    final raw = ConfigService().get('localBackup');
    if (raw is Map<String, dynamic>) {
      _settings = LocalBackupSettings.fromJson(raw);
    }
  }

  void _saveSettings() {
    ConfigService().set('localBackup', _settings.toJson());
  }

  /// Set the backup folder path (usually from a file picker).
  void setBackupFolder(String path) {
    _settings = _settings.copyWith(backupFolderPath: path);
    _saveSettings();
    _log('Backup folder set to: $path');
  }

  /// Update auto-backup settings.
  void updateSettings({
    bool? autoBackupEnabled,
    int? autoBackupIntervalMinutes,
    int? maxSnapshots,
  }) {
    _settings = _settings.copyWith(
      autoBackupEnabled: autoBackupEnabled,
      autoBackupIntervalMinutes: autoBackupIntervalMinutes,
      maxSnapshots: maxSnapshots,
    );
    _saveSettings();

    // Re-evaluate timer
    if (_settings.autoBackupEnabled && _settings.backupFolderPath != null) {
      startAutoBackup();
    } else {
      stopAutoBackup();
    }
  }

  // --- Auto-backup timer ---

  void startAutoBackup() {
    stopAutoBackup();
    if (!_settings.autoBackupEnabled || _settings.backupFolderPath == null) return;

    _autoBackupTimer = MonitoredAsyncPeriodicTimer(
      id: 'local_backup.auto',
      name: 'Auto Backup',
      description: 'Periodic local profile backup',
      serviceName: 'LocalBackupService',
      interval: Duration(minutes: _settings.autoBackupIntervalMinutes),
      priority: TaskPriority.low,
      callback: (_) async => await _onAutoBackupTick(),
    );
    _log('Auto-backup started (every ${_settings.autoBackupIntervalMinutes} min)');
  }

  void stopAutoBackup() {
    _autoBackupTimer?.cancel();
    _autoBackupTimer = null;
  }

  Future<void> _onAutoBackupTick() async {
    if (_status.isInProgress) {
      _log('Auto-backup tick skipped — operation in progress');
      return;
    }
    _log('Auto-backup tick — creating backup');
    await createBackup();
  }

  // --- Core operations ---

  /// Create a local backup ZIP of the active profile.
  Future<LocalBackupSnapshot?> createBackup() async {
    final callsign = AppService().currentCallsign;
    if (callsign == null) {
      _log('Cannot create backup: no active callsign');
      return null;
    }

    final folder = _settings.backupFolderPath;
    if (folder == null || folder.isEmpty) {
      _log('Cannot create backup: no backup folder configured');
      return null;
    }

    if (_status.isInProgress) {
      _log('Backup already in progress');
      return null;
    }

    _status = LocalBackupStatus(isInProgress: true);
    _log('Creating local backup for $callsign');

    try {
      final isEncrypted = StorageConfig().isUsingEncryptedStorage(callsign);
      final now = DateTime.now();
      final timestamp = '${now.year}-${_pad(now.month)}-${_pad(now.day)}-${_pad(now.hour)}${_pad(now.minute)}${_pad(now.second)}';
      final zipName = 'geogram-backup-${callsign.toUpperCase()}-$timestamp.zip';
      final zipPath = p.join(folder, zipName);

      // Ensure backup folder exists
      final backupDir = Directory(folder);
      if (!await backupDir.exists()) {
        await backupDir.create(recursive: true);
      }

      final manifest = LocalBackupManifest(
        callsign: callsign,
        createdAt: now,
        isEncrypted: isEncrypted,
      );

      final encoder = ZipFileEncoder();
      encoder.create(zipPath);

      if (isEncrypted) {
        await _backupEncryptedProfile(callsign, encoder, manifest);
      } else {
        await _backupFilesystemProfile(callsign, encoder, manifest);
      }

      // Write manifest into ZIP
      final manifestJson = jsonEncode(manifest.toJson());
      final manifestBytes = utf8.encode(manifestJson);
      encoder.addArchiveFile(ArchiveFile('manifest.json', manifestBytes.length, manifestBytes));
      encoder.close();

      // Get archive size
      final archiveFile = File(zipPath);
      final archiveSize = await archiveFile.length();

      final snapshot = LocalBackupSnapshot(
        fileName: zipName,
        filePath: zipPath,
        createdAt: now,
        totalFiles: manifest.totalFiles,
        totalBytes: manifest.totalBytes,
        archiveSizeBytes: archiveSize,
      );

      _settings = _settings.copyWith(lastBackupAt: now);
      _saveSettings();

      _status = LocalBackupStatus.idle();
      _log('Local backup created: $zipName (${_formatBytes(archiveSize)})');

      // Prune old snapshots
      await _pruneOldSnapshots(callsign);

      return snapshot;
    } catch (e) {
      _status = LocalBackupStatus(error: e.toString());
      _log('Local backup failed: $e');
      // Clean up partial ZIP
      return null;
    }
  }

  /// Enumerate local backup snapshots for the active callsign.
  Future<List<LocalBackupSnapshot>> listSnapshots() async {
    final callsign = AppService().currentCallsign;
    if (callsign == null) return [];

    final folder = _settings.backupFolderPath;
    if (folder == null || folder.isEmpty) return [];

    final dir = Directory(folder);
    if (!await dir.exists()) return [];

    final prefix = 'geogram-backup-${callsign.toUpperCase()}-';
    final snapshots = <LocalBackupSnapshot>[];

    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (!name.startsWith(prefix) || !name.endsWith('.zip')) continue;

      try {
        final manifest = await _readManifestFromZip(entity.path);
        final archiveSize = await entity.length();

        snapshots.add(LocalBackupSnapshot(
          fileName: name,
          filePath: entity.path,
          createdAt: manifest?.createdAt ?? entity.statSync().modified,
          totalFiles: manifest?.totalFiles ?? 0,
          totalBytes: manifest?.totalBytes ?? 0,
          archiveSizeBytes: archiveSize,
        ));
      } catch (e) {
        // Corrupted ZIP — still list it with basic info
        try {
          final stat = await entity.stat();
          snapshots.add(LocalBackupSnapshot(
            fileName: name,
            filePath: entity.path,
            createdAt: stat.modified,
            archiveSizeBytes: stat.size,
          ));
        } catch (_) {}
      }
    }

    // Sort newest first
    snapshots.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return snapshots;
  }

  /// Restore a snapshot from a ZIP file.
  Future<bool> restoreSnapshot(String zipPath) async {
    final callsign = AppService().currentCallsign;
    if (callsign == null) {
      _log('Cannot restore: no active callsign');
      return false;
    }

    if (_status.isInProgress) {
      _log('Operation already in progress');
      return false;
    }

    _status = LocalBackupStatus(isInProgress: true);
    _log('Restoring local backup from: ${p.basename(zipPath)}');

    try {
      final bytes = await File(zipPath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      // Read manifest
      final manifestEntry = archive.findFile('manifest.json');
      if (manifestEntry == null) {
        throw Exception('No manifest.json found in archive');
      }
      final manifestJson = utf8.decode(manifestEntry.content as List<int>);
      final manifest = LocalBackupManifest.fromJson(
        jsonDecode(manifestJson) as Map<String, dynamic>,
      );

      _status = LocalBackupStatus(
        isInProgress: true,
        filesTotal: manifest.totalFiles,
      );

      if (manifest.isEncrypted) {
        await _restoreEncryptedProfile(callsign, archive, manifest);
      } else {
        await _restoreFilesystemProfile(callsign, archive, manifest);
      }

      _status = LocalBackupStatus.idle();
      _log('Local backup restored successfully (${manifest.totalFiles} files)');
      return true;
    } catch (e) {
      _status = LocalBackupStatus(error: e.toString());
      _log('Local backup restore failed: $e');
      return false;
    }
  }

  /// Delete a snapshot ZIP file.
  Future<bool> deleteSnapshot(String zipPath) async {
    try {
      final file = File(zipPath);
      if (await file.exists()) {
        await file.delete();
        _log('Deleted snapshot: ${p.basename(zipPath)}');
        return true;
      }
      return false;
    } catch (e) {
      _log('Failed to delete snapshot: $e');
      return false;
    }
  }

  // --- Private helpers ---

  /// Backup a filesystem-based profile into the ZIP.
  Future<void> _backupFilesystemProfile(
    String callsign,
    ZipFileEncoder encoder,
    LocalBackupManifest manifest,
  ) async {
    final profileDir = Directory(StorageConfig().getCallsignDir(callsign));
    if (!await profileDir.exists()) {
      throw Exception('Profile directory does not exist: ${profileDir.path}');
    }

    final excludeDirs = {'log', 'backup', 'backups', 'updates', '.dart_tool', 'build'};
    final files = <File>[];

    await for (final entity in profileDir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        final relativePath = p.relative(entity.path, from: profileDir.path);
        final parts = p.split(relativePath);
        if (parts.any((part) => excludeDirs.contains(part))) continue;
        files.add(entity);
      }
    }

    _status = LocalBackupStatus(
      isInProgress: true,
      filesTotal: files.length,
    );

    int totalBytes = 0;
    for (int i = 0; i < files.length; i++) {
      final file = files[i];
      final relativePath = p.relative(file.path, from: profileDir.path);

      _status = LocalBackupStatus(
        isInProgress: true,
        progress: files.isEmpty ? 0 : i / files.length,
        filesProcessed: i,
        filesTotal: files.length,
        currentFile: relativePath,
      );

      try {
        final content = await file.readAsBytes();
        final sha1Hash = sha1.convert(content).toString();
        final stat = await file.stat();

        encoder.addFile(file, relativePath);

        manifest.files.add(LocalBackupFileEntry(
          path: relativePath,
          sha1: sha1Hash,
          size: content.length,
          modifiedAt: stat.modified,
        ));
        totalBytes += content.length;
      } catch (e) {
        _log('Failed to add file $relativePath: $e');
      }
    }

    manifest.totalFiles = manifest.files.length;
    manifest.totalBytes = totalBytes;
  }

  /// Backup an encrypted (SQLite) profile into the ZIP.
  Future<void> _backupEncryptedProfile(
    String callsign,
    ZipFileEncoder encoder,
    LocalBackupManifest manifest,
  ) async {
    final archivePath = StorageConfig().getEncryptedArchivePath(callsign);
    final archiveFile = File(archivePath);

    if (!await archiveFile.exists()) {
      throw Exception('Encrypted archive not found: $archivePath');
    }

    _status = LocalBackupStatus(
      isInProgress: true,
      filesTotal: 1,
      currentFile: '${callsign.toUpperCase()}.sqlite',
    );

    final content = await archiveFile.readAsBytes();
    final sha1Hash = sha1.convert(content).toString();
    final stat = await archiveFile.stat();

    final sqliteName = '${callsign.toUpperCase()}.sqlite';
    encoder.addFile(archiveFile, sqliteName);

    manifest.files.add(LocalBackupFileEntry(
      path: sqliteName,
      sha1: sha1Hash,
      size: content.length,
      modifiedAt: stat.modified,
    ));
    manifest.totalFiles = 1;
    manifest.totalBytes = content.length;

    // Also include any loose files in the callsign directory
    final looseDir = Directory(StorageConfig().getCallsignDir(callsign));
    if (await looseDir.exists()) {
      final excludeDirs = {'log', 'backup', 'backups'};
      await for (final entity in looseDir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          final relativePath = p.relative(entity.path, from: looseDir.path);
          final parts = p.split(relativePath);
          if (parts.any((part) => excludeDirs.contains(part))) continue;

          try {
            final looseContent = await entity.readAsBytes();
            final looseSha1 = sha1.convert(looseContent).toString();
            final looseStat = await entity.stat();

            final zipPath = 'loose/$relativePath';
            encoder.addFile(entity, zipPath);

            manifest.files.add(LocalBackupFileEntry(
              path: zipPath,
              sha1: looseSha1,
              size: looseContent.length,
              modifiedAt: looseStat.modified,
            ));
            manifest.totalFiles++;
            manifest.totalBytes += looseContent.length;
          } catch (e) {
            _log('Failed to add loose file $relativePath: $e');
          }
        }
      }
    }
  }

  /// Restore a filesystem profile from a ZIP archive.
  Future<void> _restoreFilesystemProfile(
    String callsign,
    Archive archive,
    LocalBackupManifest manifest,
  ) async {
    final profileDir = StorageConfig().getCallsignDir(callsign);

    int restored = 0;
    for (final entry in archive.files) {
      if (entry.name == 'manifest.json') continue;
      if (!entry.isFile) continue;

      _status = LocalBackupStatus(
        isInProgress: true,
        progress: manifest.totalFiles > 0 ? restored / manifest.totalFiles : 0,
        filesProcessed: restored,
        filesTotal: manifest.totalFiles,
        currentFile: entry.name,
      );

      final outPath = p.join(profileDir, entry.name);
      final outFile = File(outPath);
      await outFile.parent.create(recursive: true);
      await outFile.writeAsBytes(entry.content as List<int>);
      restored++;
    }
  }

  /// Restore an encrypted profile from a ZIP archive.
  Future<void> _restoreEncryptedProfile(
    String callsign,
    Archive archive,
    LocalBackupManifest manifest,
  ) async {
    // Restore the .sqlite file
    final sqliteName = '${callsign.toUpperCase()}.sqlite';
    final sqliteEntry = archive.findFile(sqliteName);
    if (sqliteEntry != null) {
      final archivePath = StorageConfig().getEncryptedArchivePath(callsign);
      final outFile = File(archivePath);
      await outFile.parent.create(recursive: true);
      await outFile.writeAsBytes(sqliteEntry.content as List<int>);
      _log('Restored encrypted archive: $sqliteName');
    }

    // Restore loose files
    final looseDir = StorageConfig().getCallsignDir(callsign);
    for (final entry in archive.files) {
      if (entry.name == 'manifest.json') continue;
      if (entry.name == sqliteName) continue;
      if (!entry.isFile) continue;

      String outRelative = entry.name;
      if (outRelative.startsWith('loose/')) {
        outRelative = outRelative.substring(6); // strip 'loose/' prefix
      }

      final outPath = p.join(looseDir, outRelative);
      final outFile = File(outPath);
      await outFile.parent.create(recursive: true);
      await outFile.writeAsBytes(entry.content as List<int>);
    }
  }

  /// Read manifest.json from a ZIP without extracting everything.
  Future<LocalBackupManifest?> _readManifestFromZip(String zipPath) async {
    try {
      final bytes = await File(zipPath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      final entry = archive.findFile('manifest.json');
      if (entry == null) return null;
      final json = utf8.decode(entry.content as List<int>);
      return LocalBackupManifest.fromJson(jsonDecode(json) as Map<String, dynamic>);
    } catch (e) {
      _log('Failed to read manifest from $zipPath: $e');
      return null;
    }
  }

  /// Prune old snapshots beyond maxSnapshots.
  Future<void> _pruneOldSnapshots(String callsign) async {
    final snapshots = await listSnapshots();
    if (snapshots.length <= _settings.maxSnapshots) return;

    // Snapshots are sorted newest-first, remove from the end
    final toRemove = snapshots.sublist(_settings.maxSnapshots);
    for (final snapshot in toRemove) {
      await deleteSnapshot(snapshot.filePath);
      _log('Pruned old snapshot: ${snapshot.fileName}');
    }
  }

  String _pad(int n) => n.toString().padLeft(2, '0');

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  void _log(String message) {
    LogService().log('LocalBackup: $message');
  }
}
