/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:typed_data';

import 'profile_storage.dart' show StorageEntry;

/// Stub migration result — matches the real MigrationResult API
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

/// Stub encrypted storage status — matches the real EncryptedStorageStatus API
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

/// Stub for encrypted storage service - used in CLI/web builds
/// where encrypted_archive (FFI/sqlite3) is not available.
class EncryptedStorageService {
  static final EncryptedStorageService _instance =
      EncryptedStorageService._internal();
  factory EncryptedStorageService() => _instance;
  EncryptedStorageService._internal();

  /// Encrypted storage is never available in stub mode
  bool isEncryptedStorageEnabled(String callsign) => false;

  /// Stub - read file (returns null)
  Future<Uint8List?> readFile(String callsign, String nsec, String relativePath) async {
    return null;
  }

  /// Stub - write file (returns false)
  Future<bool> writeFile(String callsign, String nsec, String relativePath, Uint8List content) async {
    return false;
  }

  /// Stub - delete file (returns false)
  Future<bool> deleteFile(String callsign, String nsec, String relativePath) async {
    return false;
  }

  /// Stub - file exists (returns false)
  Future<bool> fileExists(String callsign, String nsec, String relativePath) async {
    return false;
  }

  /// Stub - list directory (returns null)
  Future<List<StorageEntry>?> listDirectory(
    String callsign,
    String nsec,
    String relativePath, {
    bool recursive = false,
  }) async {
    return null;
  }

  /// Stub - close archive (no-op)
  Future<void> closeArchive(String callsign) async {}

  /// Stub - close all archives (no-op)
  Future<void> closeAllArchives() async {}

  /// Stub - get encryption status
  Future<EncryptedStorageStatus> getStatus(String callsign) async {
    return EncryptedStorageStatus(enabled: false);
  }

  /// Stub - migrate to encrypted storage (no-op)
  Future<MigrationResult> migrateToEncrypted(String callsign, String nsec) async {
    return MigrationResult(success: false, filesProcessed: 0, error: 'Not available on this platform');
  }

  /// Stub - migrate to folders (no-op)
  Future<MigrationResult> migrateToFolders(String callsign, String nsec) async {
    return MigrationResult(success: false, filesProcessed: 0, error: 'Not available on this platform');
  }
}
