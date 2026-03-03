/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Local backup data models for ZIP archive backup/restore.

/// Manifest embedded inside a local backup ZIP archive.
class LocalBackupManifest {
  /// Manifest format version
  String version;

  /// Profile callsign
  String callsign;

  /// When the backup was created
  DateTime createdAt;

  /// Total number of files in backup
  int totalFiles;

  /// Total bytes (uncompressed)
  int totalBytes;

  /// Whether the profile uses encrypted (SQLite) storage
  bool isEncrypted;

  /// List of file entries
  List<LocalBackupFileEntry> files;

  LocalBackupManifest({
    this.version = '1.0',
    required this.callsign,
    required this.createdAt,
    this.totalFiles = 0,
    this.totalBytes = 0,
    this.isEncrypted = false,
    List<LocalBackupFileEntry>? files,
  }) : files = files ?? [];

  factory LocalBackupManifest.fromJson(Map<String, dynamic> json) {
    return LocalBackupManifest(
      version: json['version'] as String? ?? '1.0',
      callsign: json['callsign'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      totalFiles: json['total_files'] as int? ?? 0,
      totalBytes: json['total_bytes'] as int? ?? 0,
      isEncrypted: json['is_encrypted'] as bool? ?? false,
      files: (json['files'] as List<dynamic>?)
              ?.map((f) => LocalBackupFileEntry.fromJson(f as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'callsign': callsign,
      'created_at': createdAt.toIso8601String(),
      'total_files': totalFiles,
      'total_bytes': totalBytes,
      'is_encrypted': isEncrypted,
      'files': files.map((f) => f.toJson()).toList(),
    };
  }
}

/// A single file entry in the local backup manifest.
class LocalBackupFileEntry {
  /// Relative path within the profile directory
  String path;

  /// SHA1 hash of file content
  String sha1;

  /// File size in bytes
  int size;

  /// File modification time
  DateTime modifiedAt;

  LocalBackupFileEntry({
    required this.path,
    required this.sha1,
    required this.size,
    required this.modifiedAt,
  });

  factory LocalBackupFileEntry.fromJson(Map<String, dynamic> json) {
    return LocalBackupFileEntry(
      path: json['path'] as String,
      sha1: json['sha1'] as String,
      size: json['size'] as int,
      modifiedAt: DateTime.parse(json['modified_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'path': path,
      'sha1': sha1,
      'size': size,
      'modified_at': modifiedAt.toIso8601String(),
    };
  }
}

/// Persisted settings for the local backup feature.
class LocalBackupSettings {
  /// User-selected backup folder path
  String? backupFolderPath;

  /// Whether auto-backup is enabled
  bool autoBackupEnabled;

  /// Auto-backup interval in minutes (default 1440 = 24h)
  int autoBackupIntervalMinutes;

  /// Maximum number of snapshots to retain (oldest pruned)
  int maxSnapshots;

  /// When the last backup completed
  DateTime? lastBackupAt;

  LocalBackupSettings({
    this.backupFolderPath,
    this.autoBackupEnabled = false,
    this.autoBackupIntervalMinutes = 1440,
    this.maxSnapshots = 10,
    this.lastBackupAt,
  });

  factory LocalBackupSettings.fromJson(Map<String, dynamic> json) {
    return LocalBackupSettings(
      backupFolderPath: json['backup_folder_path'] as String?,
      autoBackupEnabled: json['auto_backup_enabled'] as bool? ?? false,
      autoBackupIntervalMinutes: json['auto_backup_interval_minutes'] as int? ?? 1440,
      maxSnapshots: json['max_snapshots'] as int? ?? 10,
      lastBackupAt: json['last_backup_at'] != null
          ? DateTime.parse(json['last_backup_at'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (backupFolderPath != null) 'backup_folder_path': backupFolderPath,
      'auto_backup_enabled': autoBackupEnabled,
      'auto_backup_interval_minutes': autoBackupIntervalMinutes,
      'max_snapshots': maxSnapshots,
      if (lastBackupAt != null) 'last_backup_at': lastBackupAt!.toIso8601String(),
    };
  }

  LocalBackupSettings copyWith({
    String? backupFolderPath,
    bool? autoBackupEnabled,
    int? autoBackupIntervalMinutes,
    int? maxSnapshots,
    DateTime? lastBackupAt,
  }) {
    return LocalBackupSettings(
      backupFolderPath: backupFolderPath ?? this.backupFolderPath,
      autoBackupEnabled: autoBackupEnabled ?? this.autoBackupEnabled,
      autoBackupIntervalMinutes: autoBackupIntervalMinutes ?? this.autoBackupIntervalMinutes,
      maxSnapshots: maxSnapshots ?? this.maxSnapshots,
      lastBackupAt: lastBackupAt ?? this.lastBackupAt,
    );
  }
}

/// Summary of a local backup snapshot (ZIP archive on disk).
class LocalBackupSnapshot {
  /// ZIP file name
  String fileName;

  /// Full path to the ZIP file
  String filePath;

  /// When the backup was created
  DateTime createdAt;

  /// Total files in the backup
  int totalFiles;

  /// Total uncompressed size in bytes
  int totalBytes;

  /// ZIP archive size on disk in bytes
  int archiveSizeBytes;

  LocalBackupSnapshot({
    required this.fileName,
    required this.filePath,
    required this.createdAt,
    this.totalFiles = 0,
    this.totalBytes = 0,
    this.archiveSizeBytes = 0,
  });

  Map<String, dynamic> toJson() {
    return {
      'file_name': fileName,
      'file_path': filePath,
      'created_at': createdAt.toIso8601String(),
      'total_files': totalFiles,
      'total_bytes': totalBytes,
      'archive_size_bytes': archiveSizeBytes,
    };
  }
}

/// Real-time status of a local backup/restore operation.
class LocalBackupStatus {
  /// Whether an operation is in progress
  bool isInProgress;

  /// Progress from 0.0 to 1.0
  double progress;

  /// Files processed so far
  int filesProcessed;

  /// Total files to process
  int filesTotal;

  /// Current file being processed
  String? currentFile;

  /// Error message if failed
  String? error;

  LocalBackupStatus({
    this.isInProgress = false,
    this.progress = 0.0,
    this.filesProcessed = 0,
    this.filesTotal = 0,
    this.currentFile,
    this.error,
  });

  factory LocalBackupStatus.idle() => LocalBackupStatus();

  Map<String, dynamic> toJson() {
    return {
      'is_in_progress': isInProgress,
      'progress': progress,
      'files_processed': filesProcessed,
      'files_total': filesTotal,
      if (currentFile != null) 'current_file': currentFile,
      if (error != null) 'error': error,
    };
  }
}
