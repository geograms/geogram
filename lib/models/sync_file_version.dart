/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

/// Why a sync file version was captured.
enum SyncVersionReason {
  modified,
  deleted;

  static SyncVersionReason fromName(String value) {
    return SyncVersionReason.values.firstWhere(
      (reason) => reason.name == value,
      orElse: () => SyncVersionReason.modified,
    );
  }
}

/// A saved copy of a file before sync overwrote or deleted it.
class SyncFileVersion {
  final String id;
  final String folder;
  final String path;
  final SyncVersionReason reason;
  final DateTime createdAt;
  final int size;
  final String sha1;
  final String dataPath;

  const SyncFileVersion({
    required this.id,
    required this.folder,
    required this.path,
    required this.reason,
    required this.createdAt,
    required this.size,
    required this.sha1,
    required this.dataPath,
  });

  factory SyncFileVersion.fromJson(Map<String, dynamic> json) {
    return SyncFileVersion(
      id: json['id'] as String,
      folder: json['folder'] as String,
      path: json['path'] as String,
      reason: SyncVersionReason.fromName(
        json['reason'] as String? ?? SyncVersionReason.modified.name,
      ),
      createdAt: DateTime.parse(json['created_at'] as String),
      size: json['size'] as int? ?? 0,
      sha1: json['sha1'] as String? ?? '',
      dataPath: json['data_path'] as String,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'folder': folder,
        'path': path,
        'reason': reason.name,
        'created_at': createdAt.toUtc().toIso8601String(),
        'size': size,
        'sha1': sha1,
        'data_path': dataPath,
      };
}

/// A deletion marker used by mirror sync to propagate file removals.
class MirrorTombstone {
  final String path;
  final int deletedAt;
  final int? size;
  final String? sha1;

  const MirrorTombstone({
    required this.path,
    required this.deletedAt,
    this.size,
    this.sha1,
  });

  factory MirrorTombstone.fromJson(Map<String, dynamic> json) {
    return MirrorTombstone(
      path: json['path'] as String,
      deletedAt: json['deleted_at'] as int,
      size: json['size'] as int?,
      sha1: json['sha1'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'path': path,
        'deleted_at': deletedAt,
        if (size != null) 'size': size,
        if (sha1 != null) 'sha1': sha1,
      };
}
