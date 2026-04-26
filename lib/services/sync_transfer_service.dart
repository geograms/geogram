/*
 * Copyright (c) geogram
 * License: Apache-2.0
 */

import 'dart:async';
import 'dart:io';

import '../models/sync_file_version.dart';
import '../models/monitored_task.dart';
import '../services/app_service.dart';
import '../services/log_service.dart';
import '../services/mirror_discovery_service.dart';
import '../services/mirror_sync_service.dart';
import '../services/profile_storage.dart';
import '../services/profile_service.dart';
import '../services/sync_version_service.dart';
import '../services/task_monitor_service.dart';

/// Immutable progress snapshot emitted by [SyncTransferService].
class SyncTransferProgress {
  final int filesTransferred;
  final int totalFiles;
  final String? currentFile;
  final String? currentDevice;
  final bool isComplete;
  final int failCount;

  const SyncTransferProgress({
    required this.filesTransferred,
    required this.totalFiles,
    this.currentFile,
    this.currentDevice,
    this.isComplete = false,
    this.failCount = 0,
  });

  const SyncTransferProgress.empty()
    : filesTransferred = 0,
      totalFiles = 0,
      currentFile = null,
      currentDevice = null,
      isComplete = false,
      failCount = 0;

  SyncTransferProgress copyWith({
    int? filesTransferred,
    int? totalFiles,
    String? currentFile,
    String? currentDevice,
    bool? isComplete,
    int? failCount,
  }) {
    return SyncTransferProgress(
      filesTransferred: filesTransferred ?? this.filesTransferred,
      totalFiles: totalFiles ?? this.totalFiles,
      currentFile: currentFile ?? this.currentFile,
      currentDevice: currentDevice ?? this.currentDevice,
      isComplete: isComplete ?? this.isComplete,
      failCount: failCount ?? this.failCount,
    );
  }
}

/// Captures all data the service needs to execute a transfer.
class SyncTransferRequest {
  // Single-device fields
  final String? peerUrl;
  final Map<String, String> tokens;
  final Map<String, Set<String>> selectedFiles;
  final Map<String, bool> fileDirections;
  final Map<String, List<FileChange>> diffs;

  // Multi-device fields
  final List<MirrorDevice> mirrors;
  final Map<String, String> peerUrls;
  final Map<String, Map<String, String>> multiTokens;
  final Map<String, Map<String, Set<String>>> deviceNeeds;

  final int totalFiles;
  final bool isMultiMode;

  SyncTransferRequest.single({
    required String this.peerUrl,
    required Map<String, String> tokens,
    required Map<String, Set<String>> selectedFiles,
    required Map<String, bool> fileDirections,
    required Map<String, List<FileChange>> diffs,
  }) : tokens = {for (final e in tokens.entries) e.key: e.value},
       selectedFiles = {
         for (final e in selectedFiles.entries)
           e.key: Set<String>.from(e.value),
       },
       fileDirections = Map<String, bool>.from(fileDirections),
       diffs = {
         for (final e in diffs.entries) e.key: List<FileChange>.from(e.value),
       },
       mirrors = const [],
       peerUrls = const {},
       multiTokens = const {},
       deviceNeeds = const {},
       isMultiMode = false,
       totalFiles = selectedFiles.values.fold<int>(0, (s, v) => s + v.length);

  SyncTransferRequest.multi({
    required List<MirrorDevice> mirrors,
    required Map<String, String> peerUrls,
    required Map<String, Map<String, String>> tokens,
    required Map<String, Map<String, Set<String>>> deviceNeeds,
    required Map<String, Set<String>> selectedFiles,
    required Map<String, List<FileChange>> diffs,
  }) : mirrors = List<MirrorDevice>.from(mirrors),
       peerUrls = Map<String, String>.from(peerUrls),
       multiTokens = {
         for (final e in tokens.entries)
           e.key: Map<String, String>.from(e.value),
       },
       deviceNeeds = {
         for (final e in deviceNeeds.entries)
           e.key: {
             for (final f in e.value.entries) f.key: Set<String>.from(f.value),
           },
       },
       selectedFiles = {
         for (final e in selectedFiles.entries)
           e.key: Set<String>.from(e.value),
       },
       diffs = {
         for (final e in diffs.entries) e.key: List<FileChange>.from(e.value),
       },
       peerUrl = null,
       tokens = const {},
       fileDirections = const {},
       isMultiMode = true,
       totalFiles = _countMultiTransfers(selectedFiles, deviceNeeds);

  static int _countMultiTransfers(
    Map<String, Set<String>> selectedFiles,
    Map<String, Map<String, Set<String>>> deviceNeeds,
  ) {
    int count = 0;
    for (final entry in selectedFiles.entries) {
      final folder = entry.key;
      for (final path in entry.value) {
        for (final needs in deviceNeeds.values) {
          if (needs[folder]?.contains(path) == true) count++;
        }
      }
    }
    return count;
  }
}

/// Background service for mirror sync file transfers.
///
/// Registers as a oneshot task with [TaskMonitorService] and reports progress
/// via a broadcast stream. The user can navigate away from [DeviceSyncPage]
/// and return to see live progress or the completion state.
class SyncTransferService {
  static final instance = SyncTransferService._();
  SyncTransferService._();

  static const _taskId = 'sync_transfer.file_sync';

  bool _isBusy = false;
  SyncTransferProgress _lastProgress = const SyncTransferProgress.empty();

  final _progressController =
      StreamController<SyncTransferProgress>.broadcast();

  Stream<SyncTransferProgress> get progressStream => _progressController.stream;
  bool get isBusy => _isBusy;
  SyncTransferProgress get lastProgress => _lastProgress;

  /// Start a file transfer in the background. Returns false if already busy.
  bool startTransfer(SyncTransferRequest request) {
    if (_isBusy) return false;
    _isBusy = true;
    _lastProgress = const SyncTransferProgress.empty();

    TaskMonitorService().register(
      MonitoredTask(
        id: _taskId,
        name: 'Device Sync',
        description: 'Syncing ${request.totalFiles} file(s)...',
        serviceName: 'SyncTransfer',
        priority: TaskPriority.normal,
        type: TaskType.oneshot,
      ),
    );
    TaskMonitorService().reportStart(_taskId);

    // Fire-and-forget
    _executeTransfer(request);
    return true;
  }

  /// Clear stale completion state (call when the user taps "Done").
  void clearLastProgress() {
    _lastProgress = const SyncTransferProgress.empty();
  }

  // ──────────────────────────────────────────────────────────────
  // Internal
  // ──────────────────────────────────────────────────────────────

  void _emitProgress(SyncTransferProgress progress) {
    _lastProgress = progress;
    _progressController.add(progress);
    final task = TaskMonitorService().getTask(_taskId);
    if (task != null) {
      task.description =
          '${progress.filesTransferred}/${progress.totalFiles}'
          '${progress.currentFile != null ? " \u2014 ${progress.currentFile}" : ""}';
    }
  }

  Future<void> _executeTransfer(SyncTransferRequest request) async {
    try {
      if (request.isMultiMode) {
        await _executeMultiTransfer(request);
      } else {
        await _executeSingleTransfer(request);
      }

      final finalProgress = SyncTransferProgress(
        filesTransferred: _lastProgress.filesTransferred,
        totalFiles: request.totalFiles,
        isComplete: true,
        failCount: _lastProgress.failCount,
      );
      TaskMonitorService().reportSuccess(_taskId);
      TaskMonitorService().unregister(_taskId);
      _isBusy = false;
      _emitProgress(finalProgress);
      AppService().appsNotifier.value++;
    } catch (e) {
      LogService().log('SyncTransferService: Fatal error: $e');
      TaskMonitorService().reportFailure(_taskId, e);
      TaskMonitorService().unregister(_taskId);
      _isBusy = false;
      _emitProgress(
        SyncTransferProgress(
          filesTransferred: _lastProgress.filesTransferred,
          totalFiles: request.totalFiles,
          isComplete: true,
          failCount: _lastProgress.failCount + 1,
        ),
      );
    }
  }

  Future<void> _executeSingleTransfer(SyncTransferRequest request) async {
    final mirror = MirrorSyncService.instance;
    final storage = AppService().profileStorage;
    final profile = ProfileService().getProfile();
    int transferred = 0;
    int failCount = 0;

    for (final entry in request.selectedFiles.entries) {
      final folder = entry.key;
      final files = entry.value;
      final token = request.tokens[folder];
      if (token == null) continue;

      for (final filePath in files) {
        final key = '$folder:$filePath';
        final isPull = request.fileDirections[key] ?? true;
        final localPath = '${profile.callsign}/$folder';

        _emitProgress(
          SyncTransferProgress(
            filesTransferred: transferred,
            totalFiles: request.totalFiles,
            currentFile: '$folder/$filePath',
            failCount: failCount,
          ),
        );

        try {
          bool success;
          if (isPull) {
            final change = request.diffs[folder]
                ?.where((c) => c.path == filePath)
                .firstOrNull;
            if (change?.type == FileChangeType.delete) {
              success = await _deleteLocalFile(
                folder,
                filePath,
                localPath,
                storage,
              );
            } else {
              success = await mirror.downloadFile(
                request.peerUrl!,
                folder,
                filePath,
                localPath,
                token,
                expectedSha1: change?.remoteEntry?.sha1,
                storage: storage,
              );
            }
          } else {
            final change = request.diffs[folder]
                ?.where((c) => c.path == filePath)
                .firstOrNull;
            if (change?.type == FileChangeType.deleteRemote) {
              success = await mirror.deleteRemoteFile(
                request.peerUrl!,
                folder,
                filePath,
                token,
                tombstone: change?.tombstone,
              );
            } else {
              success = await mirror.uploadFile(
                request.peerUrl!,
                folder,
                filePath,
                localPath,
                token,
                sha1Hash: (change?.localEntry?.sha1.isNotEmpty ?? false)
                    ? change!.localEntry!.sha1
                    : null,
                storage: storage,
              );
            }
          }
          if (!success) {
            failCount++;
          }
        } catch (e) {
          LogService().log(
            'SyncTransferService: Transfer failed for $filePath: $e',
          );
          failCount++;
        }

        transferred++;
        _emitProgress(
          SyncTransferProgress(
            filesTransferred: transferred,
            totalFiles: request.totalFiles,
            currentFile: '$folder/$filePath',
            failCount: failCount,
          ),
        );
      }
    }
  }

  Future<void> _executeMultiTransfer(SyncTransferRequest request) async {
    final mirrorService = MirrorSyncService.instance;
    final storage = AppService().profileStorage;
    final profile = ProfileService().getProfile();
    int transferred = 0;
    int failCount = 0;

    for (final entry in request.selectedFiles.entries) {
      final folder = entry.key;
      final files = entry.value;
      final localPath = '${profile.callsign}/$folder';

      for (final filePath in files) {
        for (final mirror in request.mirrors) {
          final deviceId = mirror.deviceId;
          final needs = request.deviceNeeds[deviceId]?[folder];
          if (needs == null || !needs.contains(filePath)) continue;

          final peerUrl = request.peerUrls[deviceId];
          final token = request.multiTokens[deviceId]?[folder];
          if (peerUrl == null || token == null) continue;

          _emitProgress(
            SyncTransferProgress(
              filesTransferred: transferred,
              totalFiles: request.totalFiles,
              currentFile: '$folder/$filePath',
              currentDevice: mirror.displayName,
              failCount: failCount,
            ),
          );

          try {
            final change = request.diffs[folder]
                ?.where((c) => c.path == filePath)
                .firstOrNull;
            final success = await mirrorService.uploadFile(
              peerUrl,
              folder,
              filePath,
              localPath,
              token,
              sha1Hash: (change?.localEntry?.sha1.isNotEmpty ?? false)
                  ? change!.localEntry!.sha1
                  : null,
              storage: storage,
            );
            if (!success) {
              failCount++;
            }
          } catch (e) {
            LogService().log(
              'SyncTransferService: Multi-push failed for $filePath to $deviceId: $e',
            );
            failCount++;
          }

          transferred++;
          _emitProgress(
            SyncTransferProgress(
              filesTransferred: transferred,
              totalFiles: request.totalFiles,
              currentFile: '$folder/$filePath',
              currentDevice: mirror.displayName,
              failCount: failCount,
            ),
          );
        }
      }
    }
  }

  Future<bool> _deleteLocalFile(
    String folder,
    String filePath,
    String localPath,
    ProfileStorage? storage,
  ) async {
    try {
      if (storage != null) {
        final path = '$folder/$filePath';
        if (await storage.exists(path)) {
          final version = await SyncVersionService.instance.archiveProfileFile(
            folder: folder,
            filePath: filePath,
            reason: SyncVersionReason.deleted,
            storage: storage,
          );
          await storage.delete(path);
          await SyncVersionService.instance.recordTombstone(
            folder: folder,
            filePath: filePath,
            size: version?.size,
            sha1Hash: version?.sha1,
            storage: storage,
          );
        }
      } else {
        final file = File('$localPath/$filePath');
        if (await file.exists()) {
          final version = await SyncVersionService.instance.archiveFilesystemFile(
            folder: folder,
            filePath: filePath,
            fullPath: file.path,
            reason: SyncVersionReason.deleted,
          );
          await file.delete();
          await SyncVersionService.instance.recordTombstone(
            folder: folder,
            filePath: filePath,
            size: version?.size,
            sha1Hash: version?.sha1,
          );
        }
      }
      return true;
    } catch (e) {
      LogService().log('SyncTransferService: Local delete failed: $e');
      return false;
    }
  }
}
