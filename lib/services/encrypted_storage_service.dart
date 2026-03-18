/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import 'package:encrypted_archive/encrypted_archive.dart';

import '../models/monitored_task.dart';
import '../util/task_monitor_helpers.dart';
import 'storage_config.dart';
import 'log_service.dart';
import 'profile_storage.dart' show StorageEntry;

/// Callback for migration progress updates
typedef MigrationProgressCallback = void Function(
  int filesProcessed,
  int totalFiles,
  String? currentFile,
);

/// Result of a migration operation
class MigrationResult {
  final bool success;
  final int filesProcessed;
  final String? error;

  MigrationResult({
    required this.success,
    required this.filesProcessed,
    this.error,
  });

  Map<String, dynamic> toJson() => {
    'success': success,
    'files_processed': filesProcessed,
    if (error != null) 'error': error,
  };
}

/// Status of encrypted storage for a profile
class EncryptedStorageStatus {
  final bool enabled;
  final String? archivePath;
  final int? fileCount;
  final int? totalSize;

  EncryptedStorageStatus({
    required this.enabled,
    this.archivePath,
    this.fileCount,
    this.totalSize,
  });

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    if (archivePath != null) 'archive_path': archivePath,
    if (fileCount != null) 'file_count': fileCount,
    if (totalSize != null) 'total_size': totalSize,
  };
}

/// Service for managing encrypted profile storage
///
/// Uses the encrypted_archive package to store profile data in an encrypted
/// SQLite database. The database structure is browsable (files table, chunks table),
/// but the file content is AES-256-GCM encrypted.
///
/// Password is derived from the NOSTR nsec using HKDF.
class EncryptedStorageService {
  static final EncryptedStorageService _instance = EncryptedStorageService._internal();
  factory EncryptedStorageService() => _instance;
  EncryptedStorageService._internal();

  final StorageConfig _storageConfig = StorageConfig();
  final LogService _log = LogService();

  /// Cache of open archive connections by callsign
  final Map<String, EncryptedArchive> _openArchives = {};

  /// Periodic flush timer (30 seconds)
  MonitoredPeriodicTimer? _flushTimer;

  /// Get or open archive for a callsign (reuses existing connection)
  Future<EncryptedArchive?> _getArchive(String callsign, String nsec) async {
    // Return cached archive if available
    if (_openArchives.containsKey(callsign)) {
      final archive = _openArchives[callsign]!;
      if (!archive.isClosed) {
        return archive;
      }
      // Archive was closed externally, remove from cache
      _openArchives.remove(callsign);
    }

    final archivePath = _getArchivePath(callsign);
    if (!await File(archivePath).exists()) {
      return null;
    }

    try {
      final password = _derivePassword(nsec);
      final archive = await EncryptedArchive.open(archivePath, password);
      _openArchives[callsign] = archive;
      _log.log('EncryptedStorage: Opened persistent connection for $callsign');

      // Start periodic flush if not already running
      _startPeriodicFlush();

      return archive;
    } catch (e) {
      _log.log('EncryptedStorage: Failed to open archive for $callsign: $e');
      return null;
    }
  }

  /// Start periodic flush timer to reduce data loss on crash
  void _startPeriodicFlush() {
    if (_flushTimer != null) return; // Already running

    _flushTimer = MonitoredPeriodicTimer(
      id: 'encrypted_storage.flush',
      name: 'Storage Flush',
      description: 'Periodic encrypted storage WAL checkpoint',
      serviceName: 'EncryptedStorageService',
      interval: const Duration(seconds: 30),
      priority: TaskPriority.low,
      callback: (_) => _flushAllArchives(),
    );
    _log.log('EncryptedStorage: Started periodic flush (30s interval)');
  }

  /// Flush all open archives (WAL checkpoint)
  void _flushAllArchives() {
    for (final entry in _openArchives.entries) {
      final archive = entry.value;
      if (!archive.isClosed) {
        try {
          archive.checkpoint();
        } catch (e) {
          _log.log('EncryptedStorage: Checkpoint failed for ${entry.key}: $e');
        }
      }
    }
  }

  /// Close archive when profile switches or app exits
  Future<void> closeArchive(String callsign) async {
    final archive = _openArchives.remove(callsign);
    if (archive != null && !archive.isClosed) {
      await archive.close();
      _log.log('EncryptedStorage: Closed archive for $callsign');
    }

    // Stop periodic flush if no more archives open
    if (_openArchives.isEmpty) {
      _flushTimer?.cancel();
      _flushTimer = null;
      _log.log('EncryptedStorage: Stopped periodic flush (no archives open)');
    }
  }

  /// Close all open archives (for app shutdown)
  Future<void> closeAllArchives() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    for (final callsign in _openArchives.keys.toList()) {
      await closeArchive(callsign);
    }
  }

  /// Derive encryption password from nsec
  /// Uses HKDF with SHA-256 to derive a stable password from the nsec
  String _derivePassword(String nsec) {
    // Use HKDF-like derivation: HMAC-SHA256(nsec, "geogram-encrypted-storage")
    final key = utf8.encode(nsec);
    final info = utf8.encode('geogram-encrypted-storage-v1');
    final hmac = crypto.Hmac(crypto.sha256, key);
    final digest = hmac.convert(info);
    // Return hex-encoded hash as password
    return digest.toString();
  }

  /// Get the archive path for a callsign
  String _getArchivePath(String callsign) {
    return _storageConfig.getEncryptedArchivePath(callsign);
  }

  /// Get the profile folder path for a callsign
  String _getProfilePath(String callsign) {
    return p.join(_storageConfig.devicesDir, callsign);
  }

  /// Check if encrypted storage is enabled for a profile
  bool isEncryptedStorageEnabled(String callsign) {
    final archivePath = _getArchivePath(callsign);
    return File(archivePath).existsSync();
  }

  /// Get status of encrypted storage for a profile
  Future<EncryptedStorageStatus> getStatus(String callsign) async {
    final archivePath = _getArchivePath(callsign);
    final archiveFile = File(archivePath);

    if (!await archiveFile.exists()) {
      return EncryptedStorageStatus(enabled: false);
    }

    // Get file size
    final stat = await archiveFile.stat();

    return EncryptedStorageStatus(
      enabled: true,
      archivePath: archivePath,
      totalSize: stat.size,
    );
  }

  /// Migrate profile from folders to encrypted archive
  Future<MigrationResult> migrateToEncrypted(
    String callsign,
    String nsec, {
    MigrationProgressCallback? onProgress,
  }) async {
    final profilePath = _getProfilePath(callsign);
    final archivePath = _getArchivePath(callsign);
    final profileDir = Directory(profilePath);

    if (!await profileDir.exists()) {
      return MigrationResult(
        success: false,
        filesProcessed: 0,
        error: 'Profile folder does not exist: $profilePath',
      );
    }

    // Check if archive already exists
    if (await File(archivePath).exists()) {
      return MigrationResult(
        success: false,
        filesProcessed: 0,
        error: 'Encrypted archive already exists',
      );
    }

    try {
      final password = _derivePassword(nsec);

      // Pre-scan to count total files
      final filesToProcess = <File>[];
      await for (final entity in profileDir.list(recursive: true)) {
        if (entity is File) {
          final relativePath = p.relative(entity.path, from: profilePath);
          if (!relativePath.startsWith('.') && !relativePath.contains('/.')) {
            filesToProcess.add(entity);
          }
        }
      }
      final totalFiles = filesToProcess.length;

      // Create new encrypted archive
      final archive = await EncryptedArchive.create(
        archivePath,
        password,
        description: 'Geogram profile: $callsign',
      );

      int filesProcessed = 0;

      try {
        // Add all files from profile folder
        for (final file in filesToProcess) {
          final relativePath = p.relative(file.path, from: profilePath);

          _log.log('EncryptedStorage: Adding $relativePath');
          onProgress?.call(filesProcessed, totalFiles, relativePath);

          await archive.addFileFromDisk(relativePath, file.path);
          filesProcessed++;
        }

        // Final progress update
        onProgress?.call(filesProcessed, totalFiles, null);

        await archive.close();

        // Remove the original profile folder after successful migration
        await profileDir.delete(recursive: true);

        _log.log('EncryptedStorage: Migration complete, $filesProcessed files encrypted');

        return MigrationResult(
          success: true,
          filesProcessed: filesProcessed,
        );
      } catch (e) {
        await archive.close();
        // Clean up failed archive
        try {
          await File(archivePath).delete();
        } catch (_) {}
        rethrow;
      }
    } catch (e) {
      _log.log('EncryptedStorage: Migration failed: $e');
      return MigrationResult(
        success: false,
        filesProcessed: 0,
        error: e.toString(),
      );
    }
  }

  /// Migrate profile from encrypted archive back to folders
  Future<MigrationResult> migrateToFolders(
    String callsign,
    String nsec, {
    MigrationProgressCallback? onProgress,
  }) async {
    final profilePath = _getProfilePath(callsign);
    final archivePath = _getArchivePath(callsign);
    final archiveFile = File(archivePath);

    if (!await archiveFile.exists()) {
      return MigrationResult(
        success: false,
        filesProcessed: 0,
        error: 'Encrypted archive does not exist',
      );
    }

    try {
      final password = _derivePassword(nsec);

      // Open encrypted archive
      final archive = await EncryptedArchive.open(archivePath, password);

      try {
        // Create profile directory
        final profileDir = Directory(profilePath);
        if (!await profileDir.exists()) {
          await profileDir.create(recursive: true);
        }

        // Get all file entries and count total
        final entries = await archive.listFiles();
        final fileEntries = entries.where((e) => e.isFile).toList();
        final totalFiles = fileEntries.length;
        int filesProcessed = 0;

        for (final entry in fileEntries) {
          final destPath = p.join(profilePath, entry.path);
          _log.log('EncryptedStorage: Extracting ${entry.path}');
          onProgress?.call(filesProcessed, totalFiles, entry.path);

          await archive.extractFile(entry.path, destPath);
          filesProcessed++;
        }

        // Final progress update
        onProgress?.call(filesProcessed, totalFiles, null);

        await archive.close();

        // Remove the archive after successful extraction
        await archiveFile.delete();

        _log.log('EncryptedStorage: Extraction complete, $filesProcessed files decrypted');

        return MigrationResult(
          success: true,
          filesProcessed: filesProcessed,
        );
      } catch (e) {
        await archive.close();
        rethrow;
      }
    } on ArchiveAuthenticationException {
      _log.log('EncryptedStorage: Invalid password');
      return MigrationResult(
        success: false,
        filesProcessed: 0,
        error: 'Invalid password (nsec mismatch)',
      );
    } catch (e) {
      _log.log('EncryptedStorage: Extraction failed: $e');
      return MigrationResult(
        success: false,
        filesProcessed: 0,
        error: e.toString(),
      );
    }
  }

  /// Read a file from encrypted storage
  /// Returns null if file not found or encrypted storage not enabled
  Future<Uint8List?> readFile(String callsign, String nsec, String relativePath) async {
    try {
      final archive = await _getArchive(callsign, nsec);
      if (archive == null) return null;

      if (!await archive.exists(relativePath)) {
        return null;
      }

      return await archive.readFileBytes(relativePath);
    } catch (e) {
      _log.log('EncryptedStorage: Failed to read $relativePath: $e');
      return null;
    }
  }

  /// Write a file to encrypted storage
  Future<bool> writeFile(String callsign, String nsec, String relativePath, Uint8List content) async {
    try {
      final archive = await _getArchive(callsign, nsec);
      if (archive == null) return false;

      // Delete existing file if present
      if (await archive.exists(relativePath)) {
        await archive.delete(relativePath);
      }

      await archive.addBytes(relativePath, content);
      return true;
    } catch (e) {
      _log.log('EncryptedStorage: Failed to write $relativePath: $e');
      return false;
    }
  }

  /// Delete a file from encrypted storage
  Future<bool> deleteFile(String callsign, String nsec, String relativePath) async {
    try {
      final archive = await _getArchive(callsign, nsec);
      if (archive == null) return false;

      if (await archive.exists(relativePath)) {
        await archive.delete(relativePath);
      }
      return true;
    } catch (e) {
      _log.log('EncryptedStorage: Failed to delete $relativePath: $e');
      return false;
    }
  }

  /// List files in encrypted storage
  Future<List<String>?> listFiles(String callsign, String nsec, {String? prefix}) async {
    try {
      final archive = await _getArchive(callsign, nsec);
      if (archive == null) return null;

      final entries = await archive.listFiles(prefix: prefix);
      return entries.where((e) => e.isFile).map((e) => e.path).toList();
    } catch (e) {
      _log.log('EncryptedStorage: Failed to list files: $e');
      return null;
    }
  }

  /// Check if a file exists in encrypted storage
  Future<bool> fileExists(String callsign, String nsec, String relativePath) async {
    try {
      final archive = await _getArchive(callsign, nsec);
      if (archive == null) return false;

      return await archive.exists(relativePath);
    } catch (e) {
      _log.log('EncryptedStorage: Failed to check existence of $relativePath: $e');
      return false;
    }
  }

  /// List directory contents in encrypted storage
  /// Returns a list of StorageEntry objects for compatibility with ProfileStorage
  Future<List<StorageEntry>?> listDirectory(
    String callsign,
    String nsec,
    String relativePath, {
    bool recursive = false,
  }) async {
    try {
      final archive = await _getArchive(callsign, nsec);
      if (archive == null) return null;

      // Normalize the path prefix
      String prefix = relativePath;
      if (prefix.isNotEmpty && !prefix.endsWith('/')) {
        prefix = '$prefix/';
      }

      final entries = await archive.listFiles(prefix: prefix.isEmpty ? null : prefix);

      final result = <StorageEntry>[];
      final seenDirs = <String>{};

      for (final entry in entries) {
        // Get path relative to the requested directory
        String entryPath = entry.path;
        if (prefix.isNotEmpty && entryPath.startsWith(prefix)) {
          entryPath = entryPath.substring(prefix.length);
        }

        if (entryPath.isEmpty) continue;

        if (!recursive) {
          // For non-recursive, only show immediate children
          final slashIndex = entryPath.indexOf('/');
          if (slashIndex != -1) {
            // This is in a subdirectory - add the directory entry if not seen
            final dirName = entryPath.substring(0, slashIndex);
            final dirPath = prefix.isEmpty ? dirName : '$prefix$dirName';
            if (!seenDirs.contains(dirPath)) {
              seenDirs.add(dirPath);
              result.add(StorageEntry(
                name: dirName,
                path: dirPath,
                isDirectory: true,
              ));
            }
            continue;
          }
        }

        // Add the file entry
        result.add(StorageEntry(
          name: p.basename(entry.path),
          path: entry.path,
          isDirectory: !entry.isFile,
          size: entry.size,
        ));
      }

      return result;
    } catch (e) {
      _log.log('EncryptedStorage: Failed to list directory $relativePath: $e');
      return null;
    }
  }
}
